/*##########################################################################
###
### FFT Accelerator Wrapper (v3 — SW twiddle preload)
###
###     TU Delft ET4351 - 2026 Project
###
###     Memory Map:
###       CSR registers (written by firmware BEFORE enable):
###         iomem_accel[ 0] | 0x0300_0000 : Config & Status Register
###             Bit 0  : Reset  (active-high)
###             Bit 1  : Enable (active-high)
###             Bit 2  : Done   (read-only, set by HW)
###         iomem_accel[ 1] | 0x0300_0004 : Number of data entries (N)
###         iomem_accel[ 2] | 0x0300_0008 : Number of FFT stages (log2 N)
###         iomem_accel[ 3] | 0x0300_000C : tw_re[0]     (W_N^0  real)
###         iomem_accel[ 4] | 0x0300_0010 : tw_im[0]     (W_N^0  imag)
###         iomem_accel[ 5] | 0x0300_0014 : tw_re[1]     (W_N^1  real)
###         iomem_accel[ 6] | 0x0300_0018 : tw_im[1]     (W_N^1  imag)
###           ...
###         iomem_accel[33] | 0x0300_0084 : tw_re[15]    (W_N^15 real)
###         iomem_accel[34] | 0x0300_0088 : tw_im[15]    (W_N^15 imag)
###
###       SRAM (data only — twiddles are in CSR):
###         MEM[ 0] | 0x0300_008C : data word 0  (re[0])
###         MEM[ 1] | 0x0300_0090 : data word 1  (im[0])
###           ...
###         MEM[63] | 0x0300_0188 : data word 63 (im[31])
###
##########################################################################*/

module accelerator (
    input  wire        clk,
    input  wire        resetn,
    input  wire        iomem_valid,
    output wire        iomem_ready,
    input  wire [ 3:0] iomem_wstrb,
    input  wire [31:0] iomem_addr,
    input  wire [31:0] iomem_wdata,
    output wire [31:0] iomem_rdata
);

  /*----------------------------------------------------------------------------------------
        LOCAL PARAMETERS
    ----------------------------------------------------------------------------------------*/
  // Application specifications
  localparam LOG_MAX_N          = 32;                   // Bit-width for number_data
  localparam LOG_MAX_FFT_STAGES = $clog2(LOG_MAX_N);    // = 5
  localparam MAX_FFT_N          = 32;                   // Maximum N
  localparam NUM_TW             = MAX_FFT_N / 2;        // = 16 twiddle pairs

  // CSR configuration registers:  3 config + 2*NUM_TW twiddle words
  localparam NUM_CFG_REGS   = 3;
  localparam NUM_TW_REGS    = 2 * NUM_TW;               // = 32
  localparam NUM_REGS       = NUM_CFG_REGS + NUM_TW_REGS; // = 35
  localparam NUM_REGS_WIDTH = $clog2(NUM_REGS);         // = 6

  // Accelerator internal memory (data only — no twiddles)
  localparam MEM_DEPTH  = 2 * MAX_FFT_N;                // = 64  (re+im interleaved)
  localparam ADDR_WIDTH = $clog2(MEM_DEPTH);             // = 6

  integer i;

  /*----------------------------------------------------------------------------------------
        SIGNAL DECLARATIONS
    ----------------------------------------------------------------------------------------*/
  // Accelerator control
  wire reset_accel;
  wire enable_accel;
  wire finished_accel;

  // FFT configuration
  wire [LOG_MAX_N-1:0]          number_data;
  wire [LOG_MAX_FFT_STAGES-1:0] fft_stages;

  // Internal memory signals
  wire [ADDR_WIDTH-1:0] mem_addr;
  wire [31:0]           mem_rdata;
  wire [31:0]           mem_wdata;
  wire [ 3:0]           mem_wstrb;

  // FFT core -> memory signals
  wire [ 3:0] accel_mem_wstrb;
  wire [31:0] accel_mem_wdata;
  wire [31:0] accel_mem_addr;

  // CPU -> accelerator access decoding
  wire iomem_access_accelerator;
  wire iomem_access_conf;
  wire iomem_access_mem;
  reg  iomem_conf_ready;
  reg  iomem_mem_ready;
  reg  [31:0] iomem_conf_rdata;

  // CSR register array
  reg [31:0] iomem_accel [NUM_REGS-1:0];
  wire [NUM_REGS_WIDTH-1:0] iomem_accel_addr;

  /*----------------------------------------------------------------------------------------
        TWIDDLE PACKING:  CSR array -> flat bus for FFT core
    ----------------------------------------------------------------------------------------*/
  wire [32 * NUM_TW - 1 : 0] tw_re_packed;
  wire [32 * NUM_TW - 1 : 0] tw_im_packed;

  genvar gi;
  generate
    for (gi = 0; gi < NUM_TW; gi = gi + 1) begin : gen_tw_pack
      // CSR layout: iomem_accel[3 + 2*k] = tw_re[k], iomem_accel[3 + 2*k + 1] = tw_im[k]
      assign tw_re_packed[32*gi +: 32] = iomem_accel[NUM_CFG_REGS + 2*gi];
      assign tw_im_packed[32*gi +: 32] = iomem_accel[NUM_CFG_REGS + 2*gi + 1];
    end
  endgenerate

  /*----------------------------------------------------------------------------------------
        MEMORY AND ACCELERATOR INSTANTIATION
    ----------------------------------------------------------------------------------------*/
  accelerator_mem #(
      .MEM_DEPTH(MEM_DEPTH)
  ) mem (
      .clk  (clk),
      .wen  (mem_wstrb),
      .addr (mem_addr),
      .wdata(mem_wdata),
      .rdata(mem_rdata)
  );

  accelerator_fft #(
      .LOG_MAX_N (LOG_MAX_N),
      .MEM_WIDTH (32),
      .ADDR_WIDTH(ADDR_WIDTH),
      .NUM_TW    (NUM_TW)
  ) fft (
      .clk     (clk),
      .resetn  (resetn),

      .reset_accel  (reset_accel),
      .enable_accel (enable_accel),

      .number_data (number_data),
      .fft_stages  (fft_stages[LOG_MAX_FFT_STAGES-1:0]),

      .accel_mem_wstrb (accel_mem_wstrb),
      .accel_mem_rdata (mem_rdata),
      .accel_mem_wdata (accel_mem_wdata),
      .accel_mem_addr  (accel_mem_addr),

      .tw_re_packed (tw_re_packed),
      .tw_im_packed (tw_im_packed),

      .fft_finished (finished_accel)
  );

  /*----------------------------------------------------------------------------------------
        INTERFACE LOGIC
    ----------------------------------------------------------------------------------------*/
  // Extract configuration from CSR registers
  assign reset_accel  = iomem_accel[0][0];
  assign enable_accel = iomem_accel[0][1];
  assign number_data  = iomem_accel[1][LOG_MAX_N-1:0];
  assign fft_stages   = iomem_accel[2][LOG_MAX_FFT_STAGES-1:0];

  // Address decoding
  assign iomem_access_accelerator = iomem_valid && iomem_addr[31:24] == 8'h03;
  assign iomem_access_conf = iomem_access_accelerator && (iomem_addr[23:0] >> 2) < NUM_REGS;
  assign iomem_access_mem  = iomem_access_accelerator && (iomem_addr[23:0] >> 2) >= NUM_REGS;

  // Ready/data mux
  assign iomem_ready = iomem_access_conf ? iomem_conf_ready
                     : (iomem_access_mem  ? iomem_mem_ready : 1'b0);
  assign iomem_rdata = iomem_access_conf ? iomem_conf_rdata
                     : (iomem_access_mem  ? mem_rdata : 32'b0);

  // Address computation
  assign iomem_accel_addr = iomem_addr >> 2;
  assign mem_addr = iomem_access_mem ? (iomem_addr[23:2] - NUM_REGS) : accel_mem_addr[ADDR_WIDTH-1:0];

  // Write mux:  CPU vs accelerator
  assign mem_wdata = iomem_access_mem ? iomem_wdata : accel_mem_wdata;
  assign mem_wstrb = iomem_access_mem ? iomem_wstrb : accel_mem_wstrb;

  /*----------------------------------------------------------------------------------------
        CSR REGISTER MANAGEMENT
    ----------------------------------------------------------------------------------------*/
  always @(posedge clk) begin
    if (!resetn) begin
      for (i = 0; i < NUM_REGS; i = i + 1) iomem_accel[i] <= 0;

      iomem_conf_ready <= 0;
      iomem_mem_ready  <= 0;
    end else begin
      // Hardware-driven: update Done flag from accelerator
      iomem_accel[0][2] <= finished_accel;

      // ---- Configuration register access ----
      if (iomem_access_conf && !iomem_conf_ready) begin
        iomem_conf_ready <= 1;

        iomem_conf_rdata <= iomem_accel[iomem_accel_addr];
        if (iomem_wstrb[0]) iomem_accel[iomem_accel_addr][ 7: 0] <= iomem_wdata[ 7: 0];
        if (iomem_wstrb[1]) iomem_accel[iomem_accel_addr][15: 8] <= iomem_wdata[15: 8];
        if (iomem_wstrb[2]) iomem_accel[iomem_accel_addr][23:16] <= iomem_wdata[23:16];
        if (iomem_wstrb[3]) iomem_accel[iomem_accel_addr][31:24] <= iomem_wdata[31:24];
      end else begin
        iomem_conf_ready <= 0;
      end

      // ---- Accelerator memory access ----
      if (iomem_access_mem && !iomem_mem_ready) begin
        iomem_mem_ready <= 1'b1;
      end else begin
        iomem_mem_ready <= 1'b0;
      end
    end
  end

endmodule