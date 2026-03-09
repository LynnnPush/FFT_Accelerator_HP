/*##########################################################################
###
### Twiddle-preload parallel-butterfly FFT accelerator (v2 – bit-exact)
###
###     Extends the register-file optimisation with two key improvements:
###       1. PER-STAGE TWIDDLE FILL – before each stage's butterflies, the
###          twiddle table tw[0..half-1] is filled by chaining multiplications
###          of that stage's own primitive, matching the baseline's quantisation
###          path exactly (bit-exact with the Python golden reference).
###       2. 2× PARALLEL BUTTERFLIES – two independent butterfly datapaths
###          execute simultaneously each cycle, halving the compute phase.
###
###     FSM phases:
###       INIT → LOAD_TWIDDLE → LOAD_DATA → COMPUTE → STORE_DATA → FINISH
###
###     COMPUTE has two sub-phases per stage:
###       a) FILL:      tw[1..half-1] via chained multiply of prim[stage-1]
###       b) BUTTERFLY:  N/2 butterflies in pairs of 2
###
###     Cycle count for N=32:
###       INIT(1) + LOAD_TW(10) + LOAD_DATA(64)
###       + COMPUTE( stage1: 0+8, stage2: 1+8, stage3: 3+8,
###                  stage4: 7+8, stage5: 15+8 = 66 )
###       + STORE(64) + FINISH(1) = 206
###
###     Interface is 100% compatible with the baseline accelerator.v wrapper.
###     Firmware and memory map are unchanged.
###
###     TU Delft ET4351 – 2026 Project
###
##########################################################################*/

module accelerator_fft #(
    parameter integer LOG_MAX_N   = 32,                // Bit-width to represent max N
    parameter integer MEM_WIDTH   = 32,                // Width of memory data
    parameter integer ADDR_WIDTH  = 32,                // Width of memory address (overridden to 7 by wrapper)
    localparam LOG_MAX_FFT_STAGES = $clog2(LOG_MAX_N)  // Bit-width for stage counter
) (
    input wire clk,
    input wire resetn,

    // Control input
    input wire reset_accel,
    input wire enable_accel,

    // Data input
    input wire [LOG_MAX_N-1:0]          number_data,   // N (number of samples)
    input wire [LOG_MAX_FFT_STAGES-1:0] fft_stages,    // log2(N)

    // Memory inputs/outputs
    output reg  [ 3:0] accel_mem_wstrb,
    input  wire [31:0] accel_mem_rdata,
    output reg  [31:0] accel_mem_wdata,
    output reg  [31:0] accel_mem_addr,

    // Data output
    output reg fft_finished
);

  /*========================================================================================
        PARAMETERS
    ========================================================================================*/
  localparam MAX_FFT_N      = 32;
  localparam MAX_FFT_STAGES = $clog2(MAX_FFT_N);           // = 5
  localparam HALF_N         = MAX_FFT_N / 2;               // = 16
  localparam IDX_W          = $clog2(MAX_FFT_N);            // = 5 (index width for data reg file)
  localparam IO_CNT_W       = $clog2(2 * MAX_FFT_N) + 1;   // = 7 (counter width for LOAD/STORE)
  localparam SCALE          = 12;
  localparam P              = 2;                            // Parallel butterfly units

  /*========================================================================================
        FSM STATE ENCODING  (6 states → 3-bit encoding)
    ========================================================================================*/
  localparam [2:0] S_INIT         = 3'd0,
                   S_LOAD_TWIDDLE = 3'd1,
                   S_LOAD_DATA    = 3'd2,
                   S_COMPUTE      = 3'd3,
                   S_STORE_DATA   = 3'd4,
                   S_FINISH       = 3'd5;

  reg [2:0] state_reg;
  reg [2:0] next_state;

  /*========================================================================================
        DATA REGISTER FILE  (32 complex values = 64 × 32-bit)
    ========================================================================================*/
  reg signed [MEM_WIDTH-1:0] data_re [0:MAX_FFT_N-1];
  reg signed [MEM_WIDTH-1:0] data_im [0:MAX_FFT_N-1];

  /*========================================================================================
        TWIDDLE STORAGE
        – prim_re/im[0..4]: 5 primitive twiddle factors loaded from SRAM
                             (prim[s-1] = W^1_{2^s} for stage s)
        – tw_re/im[0..15]:  per-stage twiddle table, filled before each
                             stage's butterflies with W^0 … W^{half-1}
    ========================================================================================*/
  reg signed [MEM_WIDTH-1:0] prim_re [0:MAX_FFT_STAGES-1];
  reg signed [MEM_WIDTH-1:0] prim_im [0:MAX_FFT_STAGES-1];

  reg signed [MEM_WIDTH-1:0] tw_re [0:HALF_N-1];
  reg signed [MEM_WIDTH-1:0] tw_im [0:HALF_N-1];

  /*========================================================================================
        COUNTERS & COMPUTE SUB-PHASE
    ========================================================================================*/
  reg [IO_CNT_W-1:0]           io_cnt;        // shared for LOAD_TWIDDLE / LOAD_DATA / STORE_DATA
  reg [LOG_MAX_FFT_STAGES-1:0] stage;         // current FFT stage (1 … fft_stages)
  reg [IDX_W-1:0]              bf_cnt;        // linear butterfly index within a stage (0,2,4,…)
  reg [IDX_W-1:0]              fill_cnt;      // twiddle-fill counter (1 … half-1)
  reg                          compute_phase; // 0 = fill twiddles, 1 = butterflies

  /*========================================================================================
        ADDRESS HELPERS
    ========================================================================================*/
  wire [31:0] start_input_address;
  assign start_input_address = fft_stages << 1;  // = 2 * fft_stages

  wire [IO_CNT_W-1:0] tw_total;
  wire [IO_CNT_W-1:0] data_total;
  assign tw_total   = fft_stages << 1;                     // = 2 * fft_stages (10 for 5 stages)
  assign data_total  = number_data[IDX_W:0] << 1;          // = 2 * N          (64 for N=32)

  // Number of butterflies per stage = N/2
  wire [IDX_W-1:0] half_n;
  assign half_n = number_data[IDX_W:1];                    // = N / 2 (16 for N=32)

  // Half-span for the current stage = 1 << (stage - 1)
  wire [IDX_W-1:0] half_cur;
  assign half_cur = 1 << (stage - 1);

  /*========================================================================================
        TWIDDLE FILL DATAPATH  (combinational)

        Computes tw[fill_cnt] = tw[fill_cnt-1] × prim[stage-1]
        This chains from the per-stage primitive, exactly matching the
        baseline's twiddle rotation sequence for bit-exact results.
    ========================================================================================*/
  wire signed [MEM_WIDTH-1:0] fill_prim_re;
  wire signed [MEM_WIDTH-1:0] fill_prim_im;
  assign fill_prim_re = prim_re[stage - 1];
  assign fill_prim_im = prim_im[stage - 1];

  wire signed [MEM_WIDTH-1:0] fill_src_re;
  wire signed [MEM_WIDTH-1:0] fill_src_im;
  assign fill_src_re = tw_re[fill_cnt - 1];
  assign fill_src_im = tw_im[fill_cnt - 1];

  reg signed [MEM_WIDTH-1:0] fill_next_re;
  reg signed [MEM_WIDTH-1:0] fill_next_im;

  always @(*) begin
    fill_next_re = (fill_src_re * fill_prim_re - fill_src_im * fill_prim_im) >>> SCALE;
    fill_next_im = (fill_src_re * fill_prim_im + fill_src_im * fill_prim_re) >>> SCALE;
  end

  /*========================================================================================
        PARALLEL BUTTERFLY ADDRESSING  (combinational)

        For a linear butterfly index j at stage s (1-indexed):
          group  = j >> (s-1)
          k_loc  = j & ((1 << (s-1)) - 1)
          idx_u  = (group << s) | k_loc
          idx_v  = idx_u | (1 << (s-1))
          tw_idx = k_loc                  (direct index into per-stage table)

        Two butterfly units: bf0 uses j = bf_cnt, bf1 uses j = bf_cnt + 1.
    ========================================================================================*/

  // ----- Butterfly 0 (j = bf_cnt) -----
  wire [IDX_W-1:0] bf0_j;
  wire [IDX_W-1:0] bf0_group;
  wire [IDX_W-1:0] bf0_k_loc;
  wire [IDX_W-1:0] bf0_idx_u;
  wire [IDX_W-1:0] bf0_idx_v;
  wire [IDX_W-1:0] bf0_tw_idx;

  assign bf0_j      = bf_cnt; // Absolute linear index of the butterfly being processed in the current stage.

  // The specific FFT group (or block) this butterfly belongs to. 
  // Sequential butterflies are grouped into distinct memory partitions in size of half_cur.
  // Right-shifting by (stage - 1) is equivalent to integer division by half_cur.
  assign bf0_group   = bf0_j >> (stage - 1);

  // The local offset (or position) of the butterfly within its specific group.
  // The bitwise AND with (half_cur - 1) acts as a modulo operation, restricting 
  // the index to sweep from 0 to half_cur - 1
  assign bf0_k_loc   = bf0_j & (half_cur - 1);

  // The exact memory address for the "top" leg of the butterfly's data.
  // (bf0_group << stage) calculates the base memory address of the group, and 
  // bitwise ORing bf0_k_loc adds the local offset within that group's memory block
  assign bf0_idx_u   = (bf0_group << stage) | bf0_k_loc;
  
  assign bf0_idx_v   = bf0_idx_u | half_cur; // bottom leg is always separated from the top leg by a distance of half_cur
  assign bf0_tw_idx  = bf0_k_loc; // Maps directly to the butterfly's local position within the group.

  // ----- Butterfly 1 (j = bf_cnt + 1) -----
  wire [IDX_W-1:0] bf1_j;
  wire [IDX_W-1:0] bf1_group;
  wire [IDX_W-1:0] bf1_k_loc;
  wire [IDX_W-1:0] bf1_idx_u;
  wire [IDX_W-1:0] bf1_idx_v;
  wire [IDX_W-1:0] bf1_tw_idx;

  assign bf1_j      = bf_cnt + 1;
  assign bf1_group   = bf1_j >> (stage - 1);
  assign bf1_k_loc   = bf1_j & (half_cur - 1);
  assign bf1_idx_u   = (bf1_group << stage) | bf1_k_loc;
  assign bf1_idx_v   = bf1_idx_u | half_cur;
  assign bf1_tw_idx  = bf1_k_loc;

  /*========================================================================================
        PARALLEL BUTTERFLY DATAPATHS  (combinational)
    ========================================================================================*/

  // ----- Butterfly 0 -----
  reg signed [MEM_WIDTH-1:0] bf0_t_re, bf0_t_im;
  reg signed [MEM_WIDTH-1:0] bf0_e_re, bf0_e_im;
  reg signed [MEM_WIDTH-1:0] bf0_o_re, bf0_o_im;

  always @(*) begin
    bf0_t_re = (data_re[bf0_idx_v] * tw_re[bf0_tw_idx] - data_im[bf0_idx_v] * tw_im[bf0_tw_idx]) >>> SCALE;
    bf0_t_im = (data_re[bf0_idx_v] * tw_im[bf0_tw_idx] + data_im[bf0_idx_v] * tw_re[bf0_tw_idx]) >>> SCALE;

    bf0_e_re = data_re[bf0_idx_u] + bf0_t_re;
    bf0_e_im = data_im[bf0_idx_u] + bf0_t_im;
    bf0_o_re = data_re[bf0_idx_u] - bf0_t_re;
    bf0_o_im = data_im[bf0_idx_u] - bf0_t_im;
  end

  // ----- Butterfly 1 -----
  reg signed [MEM_WIDTH-1:0] bf1_t_re, bf1_t_im;
  reg signed [MEM_WIDTH-1:0] bf1_e_re, bf1_e_im;
  reg signed [MEM_WIDTH-1:0] bf1_o_re, bf1_o_im;

  always @(*) begin
    bf1_t_re = (data_re[bf1_idx_v] * tw_re[bf1_tw_idx] - data_im[bf1_idx_v] * tw_im[bf1_tw_idx]) >>> SCALE;
    bf1_t_im = (data_re[bf1_idx_v] * tw_im[bf1_tw_idx] + data_im[bf1_idx_v] * tw_re[bf1_tw_idx]) >>> SCALE;

    bf1_e_re = data_re[bf1_idx_u] + bf1_t_re;
    bf1_e_im = data_im[bf1_idx_u] + bf1_t_im;
    bf1_o_re = data_re[bf1_idx_u] - bf1_t_re;
    bf1_o_im = data_im[bf1_idx_u] - bf1_t_im;
  end

  /*========================================================================================
        COMPUTE PHASE TERMINATION SIGNALS
    ========================================================================================*/
  wire bf_pair_is_last;
  wire stage_is_last;

  assign bf_pair_is_last = (bf_cnt + P >= half_n);
  assign stage_is_last   = (stage == fft_stages);

  /*========================================================================================
        FSM – STATE REGISTER
    ========================================================================================*/
  always @(posedge clk) begin
    if (reset_accel)
      state_reg <= S_INIT;
    else
      state_reg <= next_state;
  end

  /*========================================================================================
        FSM – NEXT-STATE LOGIC  (combinational)
    ========================================================================================*/
  always @(*) begin
    case (state_reg)

      S_INIT:
        if (enable_accel)
          if (number_data[LOG_MAX_N-1:1] == 0)
            next_state = S_FINISH;
          else
            next_state = S_LOAD_TWIDDLE;
        else
          next_state = S_INIT;

      S_LOAD_TWIDDLE:
        if (io_cnt == tw_total - 1)
          next_state = S_LOAD_DATA;
        else
          next_state = S_LOAD_TWIDDLE;

      S_LOAD_DATA:
        if (io_cnt == data_total - 1)
          next_state = S_COMPUTE;
        else
          next_state = S_LOAD_DATA;

      S_COMPUTE:
        if (compute_phase == 1 && bf_pair_is_last && stage_is_last)
          next_state = S_STORE_DATA;
        else
          next_state = S_COMPUTE;

      S_STORE_DATA:
        if (io_cnt == data_total - 1)
          next_state = S_FINISH;
        else
          next_state = S_STORE_DATA;

      S_FINISH:
        if (!enable_accel)
          next_state = S_INIT;
        else
          next_state = S_FINISH;

      default:
        next_state = S_INIT;

    endcase
  end

  /*========================================================================================
        FSM – OUTPUT / MEMORY INTERFACE  (combinational)
    ========================================================================================*/
  always @(*) begin
    accel_mem_wstrb = 4'b0000;
    accel_mem_wdata = 32'd0;
    accel_mem_addr  = 32'd0;

    case (state_reg)

      S_INIT: ;

      S_LOAD_TWIDDLE: begin
        accel_mem_addr = {{(32 - IO_CNT_W){1'b0}}, io_cnt};
      end

      S_LOAD_DATA: begin
        accel_mem_addr = start_input_address + {{(32 - IO_CNT_W){1'b0}}, io_cnt};
      end

      S_COMPUTE: ;   // no SRAM access

      S_STORE_DATA: begin
        accel_mem_wstrb = 4'b1111;
        accel_mem_addr  = start_input_address + {{(32 - IO_CNT_W){1'b0}}, io_cnt};
        if (io_cnt[0] == 1'b0)
          accel_mem_wdata = data_re[io_cnt[IO_CNT_W-1:1]];
        else
          accel_mem_wdata = data_im[io_cnt[IO_CNT_W-1:1]];
      end

      S_FINISH: ;
      default:  ;

    endcase
  end

  /*========================================================================================
        FSM – SEQUENTIAL DATAPATH  (posedge clk)
    ========================================================================================*/
  integer i;

  always @(posedge clk) begin
    if (reset_accel) begin
      stage         <= 'b1;
      bf_cnt        <= '0;
      fill_cnt      <= 'd1;
      compute_phase <= 1'b1;     // stage 1 skips fill (half=1, only tw[0] needed)
      io_cnt        <= '0;
      fft_finished  <= 1'b0;

      for (i = 0; i < MAX_FFT_N; i = i + 1) begin
        data_re[i] <= 32'sd0;
        data_im[i] <= 32'sd0;
      end
      for (i = 0; i < MAX_FFT_STAGES; i = i + 1) begin
        prim_re[i] <= 32'sd0;
        prim_im[i] <= 32'sd0;
      end
      for (i = 0; i < HALF_N; i = i + 1) begin
        tw_re[i] <= 32'sd0;
        tw_im[i] <= 32'sd0;
      end

    end else begin
      case (state_reg)

        // ==============================================================
        //  INIT
        // ==============================================================
        S_INIT: begin
          stage         <= 'b1;
          bf_cnt        <= '0;
          fill_cnt      <= 'd1;
          compute_phase <= 1'b1;  // stage 1 skips fill
          io_cnt        <= '0;
          fft_finished  <= 1'b0;

          // Seed tw[0] = 1 + 0j  (constant across all stages)
          tw_re[0] <= 32'sd1 << SCALE;
          tw_im[0] <= 32'sd0;
        end

        // ==============================================================
        //  LOAD_TWIDDLE – capture 5 primitive twiddle factors from SRAM
        // ==============================================================
        S_LOAD_TWIDDLE: begin
          if (io_cnt[0] == 1'b0)
            prim_re[io_cnt[IO_CNT_W-1:1]] <= accel_mem_rdata;
          else
            prim_im[io_cnt[IO_CNT_W-1:1]] <= accel_mem_rdata;

          if (io_cnt == tw_total - 1)
            io_cnt <= '0;
          else
            io_cnt <= io_cnt + 1;
        end

        // ==============================================================
        //  LOAD_DATA – capture input data from SRAM
        // ==============================================================
        S_LOAD_DATA: begin
          if (io_cnt[0] == 1'b0)
            data_re[io_cnt[IO_CNT_W-1:1]] <= accel_mem_rdata;
          else
            data_im[io_cnt[IO_CNT_W-1:1]] <= accel_mem_rdata;

          if (io_cnt == data_total - 1)
            io_cnt <= '0;
          else
            io_cnt <= io_cnt + 1;
        end

        // ==============================================================
        //  COMPUTE – per-stage: fill twiddles then parallel butterflies
        //
        //  compute_phase=0 (FILL):
        //    Fills tw[1..half-1] by chaining: tw[k] = tw[k-1] × prim[stage-1]
        //    This reproduces the baseline's per-stage twiddle rotation
        //    exactly, so quantisation errors match bit-for-bit.
        //
        //  compute_phase=1 (BUTTERFLY):
        //    Two butterflies per cycle using tw[k_loc] lookup.
        // ==============================================================
        S_COMPUTE: begin

          if (compute_phase == 1'b0) begin
            // ============ FILL SUB-PHASE ============
            // Compute tw[fill_cnt] = tw[fill_cnt-1] × prim[stage-1]
            tw_re[fill_cnt] <= fill_next_re;
            tw_im[fill_cnt] <= fill_next_im;

            if (fill_cnt == half_cur - 1) begin
              // Fill complete → switch to butterfly sub-phase
              compute_phase <= 1'b1;
              bf_cnt        <= '0;
            end else begin
              fill_cnt <= fill_cnt + 1;
            end

          end else begin
            // ============ BUTTERFLY SUB-PHASE ============
            // ---- Write butterfly 0 results ----
            data_re[bf0_idx_u] <= bf0_e_re;
            data_im[bf0_idx_u] <= bf0_e_im;
            data_re[bf0_idx_v] <= bf0_o_re;
            data_im[bf0_idx_v] <= bf0_o_im;

            // ---- Write butterfly 1 results ----
            data_re[bf1_idx_u] <= bf1_e_re;
            data_im[bf1_idx_u] <= bf1_e_im;
            data_re[bf1_idx_v] <= bf1_o_re;
            data_im[bf1_idx_v] <= bf1_o_im;

            // ---- Update counters ----
            if (bf_pair_is_last && stage_is_last) begin
              // FFT complete → next state handles transition
            end else if (bf_pair_is_last) begin
              // Advance to next stage
              stage         <= stage + 1;
              // Next stage always has half >= 2, so enter fill sub-phase
              compute_phase <= 1'b0;
              fill_cnt      <= 'd1;
            end else begin
              bf_cnt <= bf_cnt + P;
            end
          end

        end

        // ==============================================================
        //  STORE_DATA
        // ==============================================================
        S_STORE_DATA: begin
          if (io_cnt == data_total - 1)
            io_cnt <= '0;
          else
            io_cnt <= io_cnt + 1;
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