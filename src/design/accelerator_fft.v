/*##########################################################################
###
### SW-twiddle-preload parallel-butterfly FFT accelerator (v6 — 1-Throughput)
###
###     Builds on v5 with a fully overlapped, 1-throughput pipeline:
###
###       Phase 0 (FETCH): Comb. address gen. Latch operands from SRAM/CSR.
###       Phase 1 (MUL1):  Raw multiplication (rr, ii, ri, ir).
###       Phase 2 (MUL2):  Add/sub products and >>> SCALE. Latch t values.
###       Phase 3 (ADD):   Final butterfly (e = u+t, o = u-t). Write back.
###
###     FSM now fires a new butterfly pair EVERY clock cycle.
###     Total cycles per stage for N=32: 8 fetch cycles + 3 drain cycles = 11.
###     Total compute cycles: 11 * 5 stages = 55 cycles (down from 80!).
###
##########################################################################*/

module accelerator_fft #(
    parameter integer LOG_MAX_N   = 32,                
    parameter integer MEM_WIDTH   = 32,                
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

    // SRAM interface
    output reg  [ 3:0] accel_mem_wstrb,
    input  wire [31:0] accel_mem_rdata,
    output reg  [31:0] accel_mem_wdata,
    output reg  [31:0] accel_mem_addr,

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
  localparam MAX_FFT_STAGES = $clog2(MAX_FFT_N);           
  localparam HALF_N         = MAX_FFT_N / 2;
  localparam IDX_W          = $clog2(MAX_FFT_N);
  localparam IO_CNT_W       = $clog2(2 * MAX_FFT_N) + 1;
  localparam SCALE          = 12;
  localparam P              = 2;

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
        DATA REGISTER FILE  (32 complex values = 64 x 32-bit)
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
  wire [IO_CNT_W-1:0] data_total = number_data[IDX_W:0] << 1;          
  wire [IDX_W-1:0] half_n        = number_data[IDX_W:1];                    
  wire [IDX_W-1:0] half_cur      = 1 << (stage - 1);
  wire [LOG_MAX_FFT_STAGES-1:0] tw_stride = fft_stages - stage;

  /*========================================================================================
        PARALLEL BUTTERFLY ADDRESSING  (combinational)
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
        PIPELINE REGISTERS
    ========================================================================================*/
  // ---- STAGE 1 (Latched Operands from SRAM/CSR) ----
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
        COMPUTE PHASE TERMINATION / PUMP LOGIC
    ========================================================================================*/
  // 'pump' drives new data into the pipeline every cycle until the stage limit is reached
  wire pump          = (state_reg == S_COMPUTE) && (bf_cnt < half_n);
  // 'pipe_last_drain' signals that the pipeline will drain out in next cycle, and ready for new stage pump if needed.
  wire pipe_last_drain = (pipe_vld == 3'b100) && !pump;
  wire stage_is_last = (stage == fft_stages);

  /*========================================================================================
        FSM — NEXT-STATE LOGIC
    ========================================================================================*/
  always @(*) begin
    next_state = state_reg;
    case (state_reg)
      S_INIT:       if (enable_accel)                               next_state = S_LOAD_DATA;
      S_LOAD_DATA:  if (io_cnt == data_total - 1)                   next_state = S_COMPUTE;
      // Wait for pipeline to drain completely before moving to store
      S_COMPUTE:    if (pipe_last_drain && stage_is_last)           next_state = S_STORE_DATA;
      S_STORE_DATA: if (io_cnt == data_total - 1)                   next_state = S_FINISH;
      S_FINISH:     if (!enable_accel)                              next_state = S_INIT;
      default:                                                      next_state = S_INIT;
    endcase
  end

  /*========================================================================================
        OUTPUT LOGIC  (SRAM Read/Write)
    ========================================================================================*/
  always @(*) begin
    accel_mem_wstrb = 4'b0000;
    accel_mem_wdata = 32'd0;
    accel_mem_addr  = 32'd0;

    case (state_reg)
      S_LOAD_DATA: accel_mem_addr = {{(32-IO_CNT_W){1'b0}}, io_cnt};
      S_STORE_DATA: begin
        accel_mem_addr  = {{(32-IO_CNT_W){1'b0}}, io_cnt};
        accel_mem_wstrb = 4'b1111;
        if (io_cnt[0] == 1'b0) accel_mem_wdata = data_re[io_cnt[IO_CNT_W-1:1]];
        else                   accel_mem_wdata = data_im[io_cnt[IO_CNT_W-1:1]];
      end
      default: ;
    endcase
  end

  /*========================================================================================
        SEQUENTIAL DATAPATH
    ========================================================================================*/
  always @(posedge clk) begin
    if (!resetn || reset_accel) begin
      state_reg    <= S_INIT;
      io_cnt       <= '0;
      stage        <= 'b1;
      bf_cnt       <= '0;
      pipe_vld     <= 3'b000;
      fft_finished <= 1'b0;
      // Pipeline reset (optional, but good for sim)
      stg1_bf0_idx_u <= '0; stg1_bf1_idx_u <= '0;
      stg2_bf0_idx_u <= '0; stg2_bf1_idx_u <= '0;
      stg3_bf0_idx_u <= '0; stg3_bf1_idx_u <= '0;
    end else begin
      state_reg <= next_state;

      case (state_reg)
        S_INIT: begin
          stage        <= 'b1;
          bf_cnt       <= '0;
          io_cnt       <= '0;
          pipe_vld     <= 3'b000;
          fft_finished <= 1'b0;
        end

        S_LOAD_DATA: begin
          if (io_cnt[0] == 1'b0) data_re[io_cnt[IO_CNT_W-1:1]] <= accel_mem_rdata;
          else                   data_im[io_cnt[IO_CNT_W-1:1]] <= accel_mem_rdata;
            
          if (io_cnt == data_total - 1) io_cnt <= '0;
          else                          io_cnt <= io_cnt + 1;
        end

        S_COMPUTE: begin
          // 0. Advance pipeline valid shift register
          pipe_vld <= {pipe_vld[1:0], pump};

          // 1. FETCH -> LATCH (Stage 1)
          // Comb logic generates addresses. If 'pump' is true, latch operands and advance counter.
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

          // 2. MUL1 -> LATCH (Stage 2)
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

          // 3. MUL2 / SCALE -> LATCH (Stage 3)
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

          // 4. ADD / WRITEBACK -> SRAM
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
          // Once the pipeline is completely empty, it is safe to bump to the next FFT stage.
          if (pipe_last_drain && !stage_is_last) begin
            stage  <= stage + 1;
            bf_cnt <= '0;
          end
        end

        S_STORE_DATA: begin
          if (io_cnt == data_total - 1) io_cnt <= '0;
          else                          io_cnt <= io_cnt + 1;
        end

        S_FINISH: begin
          fft_finished <= 1'b1;
        end

        default: ;
      endcase
    end
  end

endmodule