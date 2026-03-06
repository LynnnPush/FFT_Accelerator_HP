/*##########################################################################
###
### Register-file FFT accelerator (data-reuse optimisation)
###
###     Replaces the baseline's per-butterfly SRAM read/write pattern with
###     three bulk phases:
###       1. LOAD  – read twiddles + input data from SRAM into registers
###       2. COMPUTE – all 5 FFT stages execute from a 32×2 register file
###       3. STORE – write results back to SRAM
###
###     Expected cycle count for N=32:
###       INIT(1) + LOAD_TW(10) + LOAD_DATA(64) + COMPUTE(80) + STORE(64) + FINISH(1) = 220
###
###     Interface is 100% compatible with the baseline accelerator.v wrapper.
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
  // Register file dimensioning – sized for max 32-point FFT
  localparam MAX_FFT_N      = 32;
  localparam MAX_FFT_STAGES = $clog2(MAX_FFT_N);           // = 5
  localparam IDX_W          = $clog2(MAX_FFT_N);            // = 5  (index width for reg file)
  localparam IO_CNT_W       = $clog2(2 * MAX_FFT_N) + 1;   // = 7  (counter width for LOAD/STORE)

  // Fixed-point scale (must match firmware)
  localparam SCALE = 12;

  /*========================================================================================
        FSM STATE ENCODING
    ========================================================================================*/
  localparam [2:0] S_INIT         = 3'd0,
                   S_LOAD_TWIDDLE = 3'd1,
                   S_LOAD_DATA    = 3'd2,
                   S_COMPUTE      = 3'd3,
                   S_STORE_DATA   = 3'd4,
                   S_FINISH       = 3'd5;

  reg [2:0] state_reg;
  reg [2:0] next_state;   // combinational – declared reg for always-block usage

  /*========================================================================================
        REGISTER FILE  (the core of the optimisation)
    ========================================================================================*/
  // Data register file: 32 complex values = 64 × 32-bit registers
  reg signed [MEM_WIDTH-1:0] data_re [0:MAX_FFT_N-1];
  reg signed [MEM_WIDTH-1:0] data_im [0:MAX_FFT_N-1];

  // Twiddle register file: up to 5 complex twiddle factors = 10 × 32-bit registers
  reg signed [MEM_WIDTH-1:0] tw_re [0:MAX_FFT_STAGES-1];
  reg signed [MEM_WIDTH-1:0] tw_im [0:MAX_FFT_STAGES-1];

  /*========================================================================================
        LOAD / STORE COUNTER
    ========================================================================================*/
  reg [IO_CNT_W-1:0] io_cnt;    // shared counter for LOAD_TWIDDLE, LOAD_DATA, STORE_DATA

  /*========================================================================================
        FFT LOOP VARIABLES  (identical semantics to baseline)
    ========================================================================================*/
  reg [LOG_MAX_FFT_STAGES-1:0] stage;   // current FFT stage  (1 … fft_stages)
  reg [LOG_MAX_N-1:0]          m;       // butterflies span    (2, 4, 8, …, N)
  reg [LOG_MAX_N-2:0]          half;    // half-span           (1, 2, 4, …, N/2)
  reg [LOG_MAX_N-1:0]          base;    // base group start    (0, m, 2m, …)
  reg [LOG_MAX_N-2:0]          k;       // butterfly index within group  (0 … half-1)
  reg signed [MEM_WIDTH-1:0]   w_re;    // running twiddle factor (real)
  reg signed [MEM_WIDTH-1:0]   w_im;    // running twiddle factor (imag)

  // Loop termination wires (same as baseline)
  wire [LOG_MAX_N-2:0]          next_k;
  wire [LOG_MAX_N-1:0]          next_base;
  wire [LOG_MAX_FFT_STAGES-1:0] next_stage;
  wire butterfly_loop_finished;
  wire base_loop_finished;
  wire stage_loop_finished;

  assign next_k    = k + 1;
  assign next_base = base + m;
  assign next_stage = stage + 1;
  assign butterfly_loop_finished = (next_k == half);
  assign base_loop_finished      = (next_base == number_data);
  assign stage_loop_finished     = (stage == fft_stages);

  /*========================================================================================
        ADDRESS HELPERS
    ========================================================================================*/
  // Twiddle factors occupy SRAM[0 … 2*fft_stages - 1]
  // Input data occupies  SRAM[2*fft_stages … 2*fft_stages + 2*N - 1]
  wire [31:0] start_input_address;
  assign start_input_address = fft_stages << 1;   // = 2 * fft_stages

  // LOAD/STORE totals
  wire [IO_CNT_W-1:0] tw_total;
  wire [IO_CNT_W-1:0] data_total;
  assign tw_total   = fft_stages << 1;             // = 2 * fft_stages  (10 for 5 stages)
  assign data_total  = number_data[IDX_W:0] << 1;  // = 2 * N           (64 for N=32)

  /*========================================================================================
        BUTTERFLY COMPUTATION  (purely combinational)
    ========================================================================================*/
  // Register-file read indices (combinational from loop variables)
  wire [IDX_W-1:0] idx_u;
  wire [IDX_W-1:0] idx_v;
  assign idx_u = base[IDX_W-1:0] + k[IDX_W-1:0];
  assign idx_v = base[IDX_W-1:0] + k[IDX_W-1:0] + half[IDX_W-1:0];

  // Combinational butterfly datapath
  reg signed [MEM_WIDTH-1:0] t_re, t_im;
  reg signed [MEM_WIDTH-1:0] bf_e_re, bf_e_im;
  reg signed [MEM_WIDTH-1:0] bf_o_re, bf_o_im;
  reg signed [MEM_WIDTH-1:0] w_re_next, w_im_next;

  always @(*) begin
    // --- Twiddle × v multiplication ---
    t_re = (data_re[idx_v] * w_re - data_im[idx_v] * w_im) >>> SCALE;
    t_im = (data_re[idx_v] * w_im + data_im[idx_v] * w_re) >>> SCALE;

    // --- Butterfly add / subtract ---
    bf_e_re = data_re[idx_u] + t_re;
    bf_e_im = data_im[idx_u] + t_im;
    bf_o_re = data_re[idx_u] - t_re;
    bf_o_im = data_im[idx_u] - t_im;

    // --- Twiddle rotation: w' = w × w_m (for next butterfly) ---
    w_re_next = (w_re * tw_re[stage - 1] - w_im * tw_im[stage - 1]) >>> SCALE;
    w_im_next = (w_re * tw_im[stage - 1] + w_im * tw_re[stage - 1]) >>> SCALE;
  end

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
            next_state = S_FINISH;               // N < 2 → nothing to do
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
        if (butterfly_loop_finished && base_loop_finished && stage_loop_finished)
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
    // Safe defaults: no memory write, address 0
    accel_mem_wstrb = 4'b0000;
    accel_mem_wdata = 32'd0;
    accel_mem_addr  = 32'd0;

    case (state_reg)

      S_INIT: ;   // no memory access

      // ---- LOAD: present read address, SRAM responds combinationally ----
      S_LOAD_TWIDDLE: begin
        accel_mem_addr = {{(32 - IO_CNT_W){1'b0}}, io_cnt};   // addr = io_cnt (0..9)
      end

      S_LOAD_DATA: begin
        accel_mem_addr = start_input_address + {{(32 - IO_CNT_W){1'b0}}, io_cnt};
      end

      S_COMPUTE: ;  // no SRAM access – everything in register file

      // ---- STORE: drive write address + data ----
      S_STORE_DATA: begin
        accel_mem_wstrb = 4'b1111;
        accel_mem_addr  = start_input_address + {{(32 - IO_CNT_W){1'b0}}, io_cnt};
        if (io_cnt[0] == 1'b0)
          accel_mem_wdata = data_re[io_cnt[IO_CNT_W-1:1]];    // even → real
        else
          accel_mem_wdata = data_im[io_cnt[IO_CNT_W-1:1]];    // odd  → imag
      end

      S_FINISH: ;
      default:  ;

    endcase
  end

  /*========================================================================================
        FSM – SEQUENTIAL DATAPATH  (posedge clk)
    ========================================================================================*/
  integer i;   // for loop in reset

  always @(posedge clk) begin
    if (reset_accel) begin
      // ---- Reset loop variables (same initial values as baseline) ----
      stage <= 'b1;
      m     <= 'd2;
      half  <= 'b1;
      base  <= '0;
      k     <= '0;
      w_re  <= 'b1 << SCALE;
      w_im  <= '0;
      io_cnt <= '0;
      fft_finished <= 1'b0;

      // ---- Zero-initialise register files (avoid X in simulation) ----
      for (i = 0; i < MAX_FFT_N; i = i + 1) begin
        data_re[i] <= 32'sd0;
        data_im[i] <= 32'sd0;
      end
      for (i = 0; i < MAX_FFT_STAGES; i = i + 1) begin
        tw_re[i] <= 32'sd0;
        tw_im[i] <= 32'sd0;
      end

    end else begin
      case (state_reg)

        // ==============================================================
        //  INIT – re-initialise all loop variables for a fresh FFT run
        // ==============================================================
        S_INIT: begin
          stage <= 'b1;
          m     <= 'd2;
          half  <= 'b1;
          base  <= '0;
          k     <= '0;
          w_re  <= 'b1 << SCALE;
          w_im  <= '0;
          io_cnt <= '0;
          fft_finished <= 1'b0;
        end

        // ==============================================================
        //  LOAD_TWIDDLE – capture twiddle factors from SRAM
        //  SRAM layout: [tw[0].re, tw[0].im, tw[1].re, tw[1].im, …]
        //  accelerator_mem has async read → rdata valid same cycle
        // ==============================================================
        S_LOAD_TWIDDLE: begin
          if (io_cnt[0] == 1'b0)
            tw_re[io_cnt[IO_CNT_W-1:1]] <= accel_mem_rdata;   // even addr → real
          else
            tw_im[io_cnt[IO_CNT_W-1:1]] <= accel_mem_rdata;   // odd addr  → imag

          if (io_cnt == tw_total - 1)
            io_cnt <= '0;          // reset counter for LOAD_DATA
          else
            io_cnt <= io_cnt + 1;
        end

        // ==============================================================
        //  LOAD_DATA – capture input data from SRAM into register file
        //  SRAM layout: [X[0].re, X[0].im, X[1].re, X[1].im, …]
        // ==============================================================
        S_LOAD_DATA: begin
          if (io_cnt[0] == 1'b0)
            data_re[io_cnt[IO_CNT_W-1:1]] <= accel_mem_rdata;
          else
            data_im[io_cnt[IO_CNT_W-1:1]] <= accel_mem_rdata;

          if (io_cnt == data_total - 1)
            io_cnt <= '0;          // reset counter for STORE_DATA (after COMPUTE)
          else
            io_cnt <= io_cnt + 1;
        end

        // ==============================================================
        //  COMPUTE – one butterfly per cycle, purely register-to-register
        // ==============================================================
        S_COMPUTE: begin
          // ---- Write butterfly results to register file ----
          data_re[idx_u] <= bf_e_re;
          data_im[idx_u] <= bf_e_im;
          data_re[idx_v] <= bf_o_re;
          data_im[idx_v] <= bf_o_im;

          // ---- Update loop variables (mirrors baseline logic) ----
          if (butterfly_loop_finished && base_loop_finished && stage_loop_finished) begin
            // FFT complete – no counter update needed; next state → STORE_DATA
          end else if (butterfly_loop_finished && base_loop_finished) begin
            // ---- Advance to next stage ----
            stage <= next_stage;
            m     <= 1 << next_stage;
            half  <= 1 << stage;        // stage hasn't updated yet → this is correct
            base  <= '0;
            k     <= '0;
            w_re  <= 'b1 << SCALE;
            w_im  <= '0;
          end else if (butterfly_loop_finished) begin
            // ---- Advance to next base group (same stage) ----
            base  <= next_base;
            k     <= '0;
            w_re  <= 'b1 << SCALE;
            w_im  <= '0;
          end else begin
            // ---- Next butterfly in current group ----
            k    <= next_k;
            w_re <= w_re_next;
            w_im <= w_im_next;
          end
        end

        // ==============================================================
        //  STORE_DATA – write register file contents back to SRAM
        //  Write strobe + data driven by combinational output block above
        // ==============================================================
        S_STORE_DATA: begin
          if (io_cnt == data_total - 1)
            io_cnt <= '0;
          else
            io_cnt <= io_cnt + 1;
        end

        // ==============================================================
        //  FINISH – assert done flag, wait for CPU to de-assert enable
        // ==============================================================
        S_FINISH: begin
          fft_finished <= 1'b1;
        end

        default: ;

      endcase
    end
  end

endmodule