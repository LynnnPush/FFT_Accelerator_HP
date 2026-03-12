/*##########################################################################
###
### SW-twiddle-preload parallel-butterfly FFT accelerator (v3)
###
###     Builds on the v2 register-file design with a key simplification:
###       1. ALL N/2 twiddle factors W_N^k (k=0..N/2-1) are pre-computed
###          by firmware and loaded into CSR registers BEFORE enable_accel.
###          This moves twiddle derivation entirely out of the timed window.
###       2. The accelerator uses a single global twiddle table with
###          stage-dependent indexing:
###            tw_idx = k_loc << (fft_stages - stage)
###          This maps per-stage twiddle needs into the global W_N^k table.
###       3. No LOAD_TWIDDLE state.  No FILL sub-phase.
###       4. 2x parallel butterflies (unchanged from v2).
###
###     FSM phases:
###       INIT -> LOAD_DATA -> COMPUTE -> STORE_DATA -> FINISH
###
###     Cycle count for N=32:
###       INIT(1) + LOAD_DATA(64) + COMPUTE(5*8 = 40) + STORE(64) + FINISH(1)
###       = 170 cycles
###
###     Twiddle data arrives via packed flat buses from the wrapper's CSR
###     registers.  Interface is compatible with accelerator.v wrapper.
###
###     TU Delft ET4351 - 2026 Project
###
##########################################################################*/

module accelerator_fft #(
    parameter integer LOG_MAX_N   = 32,                // Bit-width of number_data port
    parameter integer MEM_WIDTH   = 32,                // Width of memory data word
    parameter integer ADDR_WIDTH  = 32,                // Width of memory address
    parameter integer NUM_TW      = 16,                // Number of twiddle pairs (= MAX_FFT_N / 2)
    localparam LOG_MAX_FFT_STAGES = $clog2(LOG_MAX_N)  // Bit-width for fft_stages port
) (
    input wire clk,
    input wire resetn,

    // Control
    input wire reset_accel,
    input wire enable_accel,

    // Configuration
    input wire [LOG_MAX_N-1:0]          number_data,   // N (e.g. 32)
    input wire [LOG_MAX_FFT_STAGES-1:0] fft_stages,    // log2(N) (e.g. 5)

    // SRAM interface
    output reg  [ 3:0] accel_mem_wstrb,
    input  wire [31:0] accel_mem_rdata,
    output reg  [31:0] accel_mem_wdata,
    output reg  [31:0] accel_mem_addr,

    // Pre-loaded twiddle factors from CSR (packed flat bus)
    //   tw_re_packed = { tw_re[NUM_TW-1], ..., tw_re[1], tw_re[0] }
    //   Each slice is MEM_WIDTH bits wide.
    input wire [MEM_WIDTH * NUM_TW - 1 : 0] tw_re_packed,
    input wire [MEM_WIDTH * NUM_TW - 1 : 0] tw_im_packed,

    // Status
    output reg fft_finished
);

  /*========================================================================================
        DERIVED PARAMETERS
    ========================================================================================*/
  localparam MAX_FFT_N      = 32;                          // Maximum FFT size
  localparam MAX_FFT_STAGES = $clog2(MAX_FFT_N);           // = 5
  localparam HALF_N         = MAX_FFT_N / 2;               // = 16
  localparam IDX_W          = $clog2(MAX_FFT_N);            // = 5  (data index width)
  localparam IO_CNT_W       = $clog2(2 * MAX_FFT_N) + 1;   // = 7  (LOAD/STORE counter)
  localparam SCALE          = 12;
  localparam P              = 2;                            // Parallel butterfly units

  /*========================================================================================
        UNPACK TWIDDLE FLAT BUS -> ARRAY OF WIRES
    ========================================================================================*/
  wire signed [MEM_WIDTH-1:0] tw_re [0:HALF_N-1];
  wire signed [MEM_WIDTH-1:0] tw_im [0:HALF_N-1];

  genvar gi;
  generate
    for (gi = 0; gi < HALF_N; gi = gi + 1) begin : gen_tw_unpack
      assign tw_re[gi] = $signed(tw_re_packed[MEM_WIDTH*gi +: MEM_WIDTH]);
      assign tw_im[gi] = $signed(tw_im_packed[MEM_WIDTH*gi +: MEM_WIDTH]);
    end
  endgenerate

  /*========================================================================================
        FSM STATE ENCODING  (5 states)
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
        COUNTERS
    ========================================================================================*/
  reg [IO_CNT_W-1:0]           io_cnt;   // shared for LOAD_DATA / STORE_DATA
  reg [LOG_MAX_FFT_STAGES-1:0] stage;    // current FFT stage (1 .. fft_stages)
  reg [IDX_W-1:0]              bf_cnt;   // linear butterfly index within a stage (0,2,4,...)

  /*========================================================================================
        ADDRESS / COUNT HELPERS
    ========================================================================================*/
  // Data occupies SRAM[0 .. 2*N-1]  (no twiddle offset; twiddles are in CSR)
  wire [IO_CNT_W-1:0] data_total;
  assign data_total = number_data[IDX_W:0] << 1;          // = 2 * N  (64 for N=32)

  // Number of butterflies per stage = N/2
  wire [IDX_W-1:0] half_n;
  assign half_n = number_data[IDX_W:1];                    // = N / 2 (16 for N=32)

  // Half-span for the current stage = 1 << (stage - 1)
  wire [IDX_W-1:0] half_cur;
  assign half_cur = 1 << (stage - 1);

  // Twiddle stride: how much to left-shift k_loc to index into global table
  //   stride = fft_stages - stage
  //   e.g. stage 1 -> stride 4, stage 5 -> stride 0
  wire [LOG_MAX_FFT_STAGES-1:0] tw_stride;
  assign tw_stride = fft_stages - stage;

  /*========================================================================================
        PARALLEL BUTTERFLY ADDRESSING  (combinational)

        For a linear butterfly index j at stage s (1-indexed):
          group  = j >> (s-1)
          k_loc  = j & ((1 << (s-1)) - 1)
          idx_u  = (group << s) | k_loc
          idx_v  = idx_u | (1 << (s-1))

        Global twiddle index:
          tw_idx = k_loc << (fft_stages - stage)

        Two butterfly units: bf0 uses j = bf_cnt, bf1 uses j = bf_cnt + 1.
    ========================================================================================*/

  // ----- Butterfly 0 (j = bf_cnt) -----
  wire [IDX_W-1:0] bf0_j;
  wire [IDX_W-1:0] bf0_group;
  wire [IDX_W-1:0] bf0_k_loc;
  wire [IDX_W-1:0] bf0_idx_u;
  wire [IDX_W-1:0] bf0_idx_v;
  wire [IDX_W-1:0] bf0_tw_idx;

  assign bf0_j       = bf_cnt;
  assign bf0_group    = bf0_j >> (stage - 1);
  assign bf0_k_loc    = bf0_j & (half_cur - 1);
  assign bf0_idx_u    = (bf0_group << stage) | bf0_k_loc;
  assign bf0_idx_v    = bf0_idx_u | half_cur;
  assign bf0_tw_idx   = bf0_k_loc << tw_stride;   // Global twiddle index

  // ----- Butterfly 1 (j = bf_cnt + 1) -----
  wire [IDX_W-1:0] bf1_j;
  wire [IDX_W-1:0] bf1_group;
  wire [IDX_W-1:0] bf1_k_loc;
  wire [IDX_W-1:0] bf1_idx_u;
  wire [IDX_W-1:0] bf1_idx_v;
  wire [IDX_W-1:0] bf1_tw_idx;

  assign bf1_j       = bf_cnt + 1;
  assign bf1_group    = bf1_j >> (stage - 1);
  assign bf1_k_loc    = bf1_j & (half_cur - 1);
  assign bf1_idx_u    = (bf1_group << stage) | bf1_k_loc;
  assign bf1_idx_v    = bf1_idx_u | half_cur;
  assign bf1_tw_idx   = bf1_k_loc << tw_stride;   // Global twiddle index

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
        END-OF-PHASE DETECTION
    ========================================================================================*/
  wire bf_pair_is_last;
  wire stage_is_last;

  assign bf_pair_is_last = (bf_cnt + P >= half_n);
  assign stage_is_last   = (stage == fft_stages);

  /*========================================================================================
        NEXT-STATE LOGIC  (combinational)
    ========================================================================================*/
  always @(*) begin
    next_state = state_reg;
    case (state_reg)
      S_INIT:       if (enable_accel)                       next_state = S_LOAD_DATA;
      S_LOAD_DATA:  if (io_cnt == data_total - 1)           next_state = S_COMPUTE;
      S_COMPUTE:    if (bf_pair_is_last && stage_is_last)   next_state = S_STORE_DATA;
      S_STORE_DATA: if (io_cnt == data_total - 1)           next_state = S_FINISH;
      S_FINISH:     if (!enable_accel)                      next_state = S_INIT;
      default:                                              next_state = S_INIT;
    endcase
  end

  /*========================================================================================
        OUTPUT LOGIC  (combinational — SRAM address, write-strobe, write-data)
    ========================================================================================*/
  always @(*) begin
    accel_mem_wstrb = 4'b0000;
    accel_mem_wdata = 32'd0;
    accel_mem_addr  = 32'd0;

    case (state_reg)
      // ------- LOAD_DATA: read from SRAM into register file -------
      S_LOAD_DATA: begin
        accel_mem_addr = {{(32-IO_CNT_W){1'b0}}, io_cnt};
      end

      // ------- STORE_DATA: write register file back to SRAM -------
      S_STORE_DATA: begin
        accel_mem_addr  = {{(32-IO_CNT_W){1'b0}}, io_cnt};
        accel_mem_wstrb = 4'b1111;
        if (io_cnt[0] == 1'b0)
          accel_mem_wdata = data_re[io_cnt[IO_CNT_W-1:1]];
        else
          accel_mem_wdata = data_im[io_cnt[IO_CNT_W-1:1]];
      end

      default: ;
    endcase
  end

  /*========================================================================================
        STATE REGISTER + SEQUENTIAL DATAPATH
    ========================================================================================*/
  always @(posedge clk) begin
    if (!resetn || reset_accel) begin
      state_reg    <= S_INIT;
      io_cnt       <= '0;
      stage        <= 'b1;
      bf_cnt       <= '0;
      fft_finished <= 1'b0;
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
          fft_finished <= 1'b0;
        end

        // ==============================================================
        //  LOAD_DATA — capture input data from SRAM into register file
        //  SRAM layout: re[0], im[0], re[1], im[1], ..., re[N-1], im[N-1]
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
        //  COMPUTE — pure butterfly, no fill sub-phase
        //
        //  Two butterflies per cycle. Twiddle lookup uses global table
        //  with index = k_loc << (fft_stages - stage).
        // ==============================================================
        S_COMPUTE: begin
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
            // FFT complete — next state transition handled above
            io_cnt <= '0;        // prep for STORE_DATA
          end else if (bf_pair_is_last) begin
            // Advance to next stage
            stage  <= stage + 1;
            bf_cnt <= '0;
          end else begin
            bf_cnt <= bf_cnt + P;
          end
        end

        // ==============================================================
        //  STORE_DATA — write register file back to SRAM
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