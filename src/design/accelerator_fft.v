/*##########################################################################
###
### SW-twiddle-preload parallel-butterfly FFT accelerator
###     (v7 — 1-Throughput pipeline + wide memory interface)
###
###     Builds on v6 with a WIDE PAIRED SRAM INTERFACE (Option B):
###
###       The FFT core reads/writes one complex pair (re + im) per cycle
###       during LOAD and STORE phases, halving the memory transfer time.
###
###     Compute pipeline is unchanged from v6:
###       Phase 0 (FETCH): Comb. address gen. Latch operands from regfile/CSR.
###       Phase 1 (MUL1):  Raw multiplication (rr, ii, ri, ir).
###       Phase 2 (MUL2):  Add/sub products and >>> SCALE. Latch t values.
###       Phase 3 (ADD):   Final butterfly (e = u+t, o = u-t). Write back.
###
###     Cycle count for N=32:
###       INIT(1) + LOAD_DATA(32) + COMPUTE(55) + STORE_DATA(32) + FINISH(1) = 121
###
###     Down from 185 cycles (v6).  LOAD+STORE drops from 128 to 64 cycles.
###
##########################################################################*/

module accelerator_fft #(
    parameter integer LOG_MAX_N   = 32,
    parameter integer MEM_WIDTH   = 24,
    parameter integer ADDR_WIDTH  = 32,
    parameter integer NUM_TW      = 16,
    parameter integer TW_WIDTH    = 16,
    localparam LOG_MAX_FFT_STAGES = $clog2(LOG_MAX_N)
) (
    input wire clk,
    input wire resetn,

    // Control
    input wire reset_accel,
    input wire enable_accel,

    // Configuration
    input wire [LOG_MAX_N-1:0]          number_data,
    input wire [LOG_MAX_FFT_STAGES-1:0] fft_stages,

    // Wide paired SRAM interface  (reads/writes one complex pair per cycle)
    output reg  [ 2:0] accel_mem_wstrb_lo,          // write strobe, even word (re)
    output reg  [ 2:0] accel_mem_wstrb_hi,          // write strobe, odd  word (im)
    input  wire [MEM_WIDTH-1:0] accel_mem_rdata_lo,  // read data,  even word (re)
    input  wire [MEM_WIDTH-1:0] accel_mem_rdata_hi,  // read data,  odd  word (im)
    output reg  [MEM_WIDTH-1:0] accel_mem_wdata_lo,  // write data, even word (re)
    output reg  [MEM_WIDTH-1:0] accel_mem_wdata_hi,  // write data, odd  word (im)
    output reg  [31:0] accel_mem_pair_addr,          // pair index (not byte address)

    // Pre-loaded twiddle factors from CSR
    input wire [MEM_WIDTH * NUM_TW - 1 : 0] tw_re_packed,
    input wire [MEM_WIDTH * NUM_TW - 1 : 0] tw_im_packed,

    // Status
    output reg fft_finished
);

  /*========================================================================================
        DERIVED PARAMETERS
    ========================================================================================*/
  localparam MAX_FFT_N      = 32;
  localparam MAX_FFT_STAGES = $clog2(MAX_FFT_N);           // = 5
  localparam HALF_N         = MAX_FFT_N / 2;               // = 16
  localparam IDX_W          = $clog2(MAX_FFT_N);            // = 5
  localparam IO_CNT_W       = $clog2(MAX_FFT_N) + 1;       // = 6 (counts 0..N-1 = 0..31)
  localparam SCALE          = 12;
  localparam P              = 2;                            // parallel butterfly units

  /*========================================================================================
        UNPACK TWIDDLE FLAT BUS
    ========================================================================================*/
  wire signed [TW_WIDTH-1:0] tw_re [0:HALF_N-1];
  wire signed [TW_WIDTH-1:0] tw_im [0:HALF_N-1];

  genvar gi;
  generate
    for (gi = 0; gi < HALF_N; gi = gi + 1) begin : gen_tw_unpack
      assign tw_re[gi] = $signed(tw_re_packed[MEM_WIDTH*gi +: TW_WIDTH]);
      assign tw_im[gi] = $signed(tw_im_packed[MEM_WIDTH*gi +: TW_WIDTH]);
    end
  endgenerate

  /*========================================================================================
        FSM STATE ENCODING
    ========================================================================================*/
  localparam [2:0] S_INIT       = 3'd0,
                   S_LOAD_DATA  = 3'd1,
                   S_COMPUTE    = 3'd2,
                   S_STORE_DATA = 3'd3,
                   S_FINISH     = 3'd4;
  reg [2:0] state_reg;
  reg [2:0] next_state;

  /*========================================================================================
        DATA REGISTER FILE  (32 complex values = 64 × 24-bit)
    ========================================================================================*/
  reg signed [MEM_WIDTH-1:0] data_re [0:MAX_FFT_N-1];
  reg signed [MEM_WIDTH-1:0] data_im [0:MAX_FFT_N-1];

  /*========================================================================================
        COUNTERS & CONTROL
    ========================================================================================*/
  reg [IO_CNT_W-1:0]           io_cnt;
  reg [LOG_MAX_FFT_STAGES-1:0] stage;
  reg [IDX_W-1:0]              bf_cnt;

  // Pipeline Tracking Shift Register (1 bit per pipeline stage active)
  reg [2:0] pipe_vld;

  /*========================================================================================
        ADDRESS / COUNT HELPERS
    ========================================================================================*/
  // pair_total = N  (number of complex pairs to transfer)
  wire [IO_CNT_W-1:0] pair_total = number_data[IDX_W:0];   // = 32 for N=32

  wire [IDX_W-1:0] half_n    = number_data[IDX_W:1];       // = N/2 = 16
  wire [IDX_W-1:0] half_cur  = 1 << (stage - 1);
  wire [LOG_MAX_FFT_STAGES-1:0] tw_stride = fft_stages - stage;

  /*========================================================================================
        PARALLEL BUTTERFLY ADDRESSING  (combinational, unchanged from v6)
    ========================================================================================*/
  // ----- Butterfly 0 -----
  wire [IDX_W-1:0] bf0_j       = bf_cnt;
  wire [IDX_W-1:0] bf0_group   = bf0_j >> (stage - 1);
  wire [IDX_W-1:0] bf0_k_loc   = bf0_j & (half_cur - 1);
  wire [IDX_W-1:0] bf0_idx_u   = (bf0_group << stage) | bf0_k_loc;
  wire [IDX_W-1:0] bf0_idx_v   = bf0_idx_u | half_cur;
  wire [IDX_W-1:0] bf0_tw_idx  = bf0_k_loc << tw_stride;

  // ----- Butterfly 1 -----
  wire [IDX_W-1:0] bf1_j       = bf_cnt + 1;
  wire [IDX_W-1:0] bf1_group   = bf1_j >> (stage - 1);
  wire [IDX_W-1:0] bf1_k_loc   = bf1_j & (half_cur - 1);
  wire [IDX_W-1:0] bf1_idx_u   = (bf1_group << stage) | bf1_k_loc;
  wire [IDX_W-1:0] bf1_idx_v   = bf1_idx_u | half_cur;
  wire [IDX_W-1:0] bf1_tw_idx  = bf1_k_loc << tw_stride;

  /*========================================================================================
        PIPELINE REGISTERS  (unchanged from v6)
    ========================================================================================*/
  // ---- STAGE 1 (Latched Operands from regfile/CSR) ----
  reg signed [MEM_WIDTH-1:0] stg1_bf0_u_re, stg1_bf0_u_im, stg1_bf1_u_re, stg1_bf1_u_im;
  reg signed [MEM_WIDTH-1:0] stg1_bf0_v_re, stg1_bf0_v_im, stg1_bf1_v_re, stg1_bf1_v_im;
  reg signed [TW_WIDTH-1:0]  stg1_bf0_tw_re, stg1_bf0_tw_im, stg1_bf1_tw_re, stg1_bf1_tw_im;
  reg [IDX_W-1:0]            stg1_bf0_idx_u, stg1_bf0_idx_v, stg1_bf1_idx_u, stg1_bf1_idx_v;

  // ---- STAGE 2 (Raw Multiply Products) ----
  reg signed [MEM_WIDTH+TW_WIDTH-1:0] stg2_bf0_rr, stg2_bf0_ii, stg2_bf0_ri, stg2_bf0_ir;
  reg signed [MEM_WIDTH+TW_WIDTH-1:0] stg2_bf1_rr, stg2_bf1_ii, stg2_bf1_ri, stg2_bf1_ir;
  reg signed [MEM_WIDTH-1:0]          stg2_bf0_u_re, stg2_bf0_u_im, stg2_bf1_u_re, stg2_bf1_u_im;
  reg [IDX_W-1:0]                     stg2_bf0_idx_u, stg2_bf0_idx_v, stg2_bf1_idx_u, stg2_bf1_idx_v;

  // ---- STAGE 3 (Scaled Products) ----
  reg signed [MEM_WIDTH-1:0] stg3_bf0_t_re, stg3_bf0_t_im, stg3_bf1_t_re, stg3_bf1_t_im;
  reg signed [MEM_WIDTH-1:0] stg3_bf0_u_re, stg3_bf0_u_im, stg3_bf1_u_re, stg3_bf1_u_im;
  reg [IDX_W-1:0]            stg3_bf0_idx_u, stg3_bf0_idx_v, stg3_bf1_idx_u, stg3_bf1_idx_v;

  /*========================================================================================
        COMPUTE PHASE TERMINATION / PUMP LOGIC  (unchanged from v6)
    ========================================================================================*/
  wire pump          = (state_reg == S_COMPUTE) && (bf_cnt < half_n);
  wire pipe_last_drain = (pipe_vld == 3'b100) && !pump;
  wire stage_is_last = (stage == fft_stages);

  /*========================================================================================
        FSM — NEXT-STATE LOGIC
    ========================================================================================*/
  always @(*) begin
    next_state = state_reg;
    case (state_reg)
      S_INIT:       if (enable_accel)                               next_state = S_LOAD_DATA;
      S_LOAD_DATA:  if (io_cnt == pair_total - 1)                   next_state = S_COMPUTE;
      S_COMPUTE:    if (pipe_last_drain && stage_is_last)           next_state = S_STORE_DATA;
      S_STORE_DATA: if (io_cnt == pair_total - 1)                   next_state = S_FINISH;
      S_FINISH:     if (!enable_accel)                              next_state = S_INIT;
      default:                                                      next_state = S_INIT;
    endcase
  end

  /*========================================================================================
        OUTPUT LOGIC  (Wide SRAM Read/Write — combinational)
    ========================================================================================*/
  always @(*) begin
    accel_mem_wstrb_lo = 3'b000;
    accel_mem_wstrb_hi = 3'b000;
    accel_mem_wdata_lo = {MEM_WIDTH{1'b0}};
    accel_mem_wdata_hi = {MEM_WIDTH{1'b0}};
    accel_mem_pair_addr = 32'd0;

    case (state_reg)
      // LOAD: present pair address, memory responds combinationally
      S_LOAD_DATA: begin
        accel_mem_pair_addr = {{(32-IO_CNT_W){1'b0}}, io_cnt};
      end

      // STORE: drive pair address + both write data + strobes
      //   Sign-extend MEM_WIDTH → 32 for the bus interface
      S_STORE_DATA: begin
        accel_mem_pair_addr = {{(32-IO_CNT_W){1'b0}}, io_cnt};
        accel_mem_wstrb_lo  = 3'b111;
        accel_mem_wstrb_hi  = 3'b111;
        accel_mem_wdata_lo  = data_re[io_cnt[IDX_W-1:0]];
        accel_mem_wdata_hi  = data_im[io_cnt[IDX_W-1:0]];
      end

      default: ;
    endcase
  end

  /*========================================================================================
        SEQUENTIAL DATAPATH
    ========================================================================================*/
  integer i;

  always @(posedge clk) begin
    if (!resetn || reset_accel) begin
      state_reg    <= S_INIT;
      io_cnt       <= '0;
      stage        <= 'b1;
      bf_cnt       <= '0;
      pipe_vld     <= 3'b000;
      fft_finished <= 1'b0;
      stg1_bf0_idx_u <= '0; stg1_bf1_idx_u <= '0;
      stg2_bf0_idx_u <= '0; stg2_bf1_idx_u <= '0;
      stg3_bf0_idx_u <= '0; stg3_bf1_idx_u <= '0;
    end else begin
      state_reg <= next_state;

      case (state_reg)

        // ==============================================================
        //  INIT
        // ==============================================================
        S_INIT: begin
          stage        <= 'b1;
          bf_cnt       <= '0;
          io_cnt       <= '0;
          pipe_vld     <= 3'b000;
          fft_finished <= 1'b0;
        end

        // ==============================================================
        //  LOAD_DATA — capture one complex pair per cycle via wide port
        //    Pair k arrives as {rdata_hi=im[k], rdata_lo=re[k]}
        // ==============================================================
        S_LOAD_DATA: begin
          data_re[io_cnt[IDX_W-1:0]] <= accel_mem_rdata_lo;    // even → re
          data_im[io_cnt[IDX_W-1:0]] <= accel_mem_rdata_hi;    // odd  → im

          if (io_cnt == pair_total - 1) io_cnt <= '0;
          else                          io_cnt <= io_cnt + 1;
        end

        // ==============================================================
        //  COMPUTE — 4-stage pipelined butterfly (unchanged from v6)
        // ==============================================================
        S_COMPUTE: begin
          // 0. Advance pipeline valid shift register
          pipe_vld <= {pipe_vld[1:0], pump};

          // 1. FETCH → LATCH (Stage 1)
          if (pump) begin
            bf_cnt <= bf_cnt + P;

            stg1_bf0_u_re  <= data_re[bf0_idx_u];
            stg1_bf0_u_im  <= data_im[bf0_idx_u];
            stg1_bf0_v_re  <= data_re[bf0_idx_v];
            stg1_bf0_v_im  <= data_im[bf0_idx_v];
            stg1_bf0_tw_re <= tw_re[bf0_tw_idx];
            stg1_bf0_tw_im <= tw_im[bf0_tw_idx];
            stg1_bf0_idx_u <= bf0_idx_u;
            stg1_bf0_idx_v <= bf0_idx_v;

            stg1_bf1_u_re  <= data_re[bf1_idx_u];
            stg1_bf1_u_im  <= data_im[bf1_idx_u];
            stg1_bf1_v_re  <= data_re[bf1_idx_v];
            stg1_bf1_v_im  <= data_im[bf1_idx_v];
            stg1_bf1_tw_re <= tw_re[bf1_tw_idx];
            stg1_bf1_tw_im <= tw_im[bf1_tw_idx];
            stg1_bf1_idx_u <= bf1_idx_u;
            stg1_bf1_idx_v <= bf1_idx_v;
          end

          // 2. MUL1 → LATCH (Stage 2)
          if (pipe_vld[0]) begin
            stg2_bf0_rr    <= stg1_bf0_v_re * stg1_bf0_tw_re;
            stg2_bf0_ii    <= stg1_bf0_v_im * stg1_bf0_tw_im;
            stg2_bf0_ri    <= stg1_bf0_v_re * stg1_bf0_tw_im;
            stg2_bf0_ir    <= stg1_bf0_v_im * stg1_bf0_tw_re;
            stg2_bf0_u_re  <= stg1_bf0_u_re;
            stg2_bf0_u_im  <= stg1_bf0_u_im;
            stg2_bf0_idx_u <= stg1_bf0_idx_u;
            stg2_bf0_idx_v <= stg1_bf0_idx_v;

            stg2_bf1_rr    <= stg1_bf1_v_re * stg1_bf1_tw_re;
            stg2_bf1_ii    <= stg1_bf1_v_im * stg1_bf1_tw_im;
            stg2_bf1_ri    <= stg1_bf1_v_re * stg1_bf1_tw_im;
            stg2_bf1_ir    <= stg1_bf1_v_im * stg1_bf1_tw_re;
            stg2_bf1_u_re  <= stg1_bf1_u_re;
            stg2_bf1_u_im  <= stg1_bf1_u_im;
            stg2_bf1_idx_u <= stg1_bf1_idx_u;
            stg2_bf1_idx_v <= stg1_bf1_idx_v;
          end

          // 3. MUL2 / SCALE → LATCH (Stage 3)
          if (pipe_vld[1]) begin
            stg3_bf0_t_re  <= (stg2_bf0_rr - stg2_bf0_ii) >>> SCALE;
            stg3_bf0_t_im  <= (stg2_bf0_ri + stg2_bf0_ir) >>> SCALE;
            stg3_bf0_u_re  <= stg2_bf0_u_re;
            stg3_bf0_u_im  <= stg2_bf0_u_im;
            stg3_bf0_idx_u <= stg2_bf0_idx_u;
            stg3_bf0_idx_v <= stg2_bf0_idx_v;

            stg3_bf1_t_re  <= (stg2_bf1_rr - stg2_bf1_ii) >>> SCALE;
            stg3_bf1_t_im  <= (stg2_bf1_ri + stg2_bf1_ir) >>> SCALE;
            stg3_bf1_u_re  <= stg2_bf1_u_re;
            stg3_bf1_u_im  <= stg2_bf1_u_im;
            stg3_bf1_idx_u <= stg2_bf1_idx_u;
            stg3_bf1_idx_v <= stg2_bf1_idx_v;
          end

          // 4. ADD / WRITEBACK → register file
          if (pipe_vld[2]) begin
            data_re[stg3_bf0_idx_u] <= stg3_bf0_u_re + stg3_bf0_t_re;
            data_im[stg3_bf0_idx_u] <= stg3_bf0_u_im + stg3_bf0_t_im;
            data_re[stg3_bf0_idx_v] <= stg3_bf0_u_re - stg3_bf0_t_re;
            data_im[stg3_bf0_idx_v] <= stg3_bf0_u_im - stg3_bf0_t_im;

            data_re[stg3_bf1_idx_u] <= stg3_bf1_u_re + stg3_bf1_t_re;
            data_im[stg3_bf1_idx_u] <= stg3_bf1_u_im + stg3_bf1_t_im;
            data_re[stg3_bf1_idx_v] <= stg3_bf1_u_re - stg3_bf1_t_re;
            data_im[stg3_bf1_idx_v] <= stg3_bf1_u_im - stg3_bf1_t_im;
          end

          // 5. Stage Progress Control
          if (pipe_last_drain && !stage_is_last) begin
            stage  <= stage + 1;
            bf_cnt <= '0;
          end
        end

        // ==============================================================
        //  STORE_DATA — one complex pair per cycle via wide port
        //    Write strobes and data driven by combinational output block
        // ==============================================================
        S_STORE_DATA: begin
          if (io_cnt == pair_total - 1) io_cnt <= '0;
          else                          io_cnt <= io_cnt + 1;
        end

        // ==============================================================
        //  FINISH
        // ==============================================================
        S_FINISH: begin
          fft_finished <= 1'b1;
        end

        default: ;
      endcase
    end
  end

endmodule