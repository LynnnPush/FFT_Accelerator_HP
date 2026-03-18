/*##########################################################################
###
### Accelerator wrapper (wide-port variant)
###
###     Bridges the PicoRV32 iomem bus (32-bit) to the FFT core's wide
###     paired SRAM interface (64-bit).  The key change from the v6 wrapper:
###
###       - The CPU accesses accelerator_mem through the NARROW port
###         (32-bit, byte-enable writes, combinational reads).
###       - The FFT core accesses accelerator_mem through the WIDE port
###         (64-bit paired, one re+im pair per cycle).
###       - No shared address/data mux — the two paths are independent
###         and mutually exclusive (CPU writes before enable, FFT after).
###
###     CSR interface, twiddle packing, and memory map are unchanged.
###
###     TU Delft ET4351 – 2026 Project
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
  localparam LOG_MAX_N          = 32;
  localparam LOG_MAX_FFT_STAGES = $clog2(LOG_MAX_N);    // = 5
  localparam MAX_FFT_N          = 32;
  localparam NUM_TW             = MAX_FFT_N / 2;        // = 16

  // CSR configuration registers:  3 config + 2*NUM_TW twiddle words
  localparam NUM_CFG_REGS   = 3;
  localparam NUM_TW_REGS    = 2 * NUM_TW;               // = 32
  localparam NUM_REGS       = NUM_CFG_REGS + NUM_TW_REGS; // = 35
  localparam NUM_REGS_WIDTH = $clog2(NUM_REGS);         // = 6

  // Accelerator internal memory (data only — no twiddles)
  localparam MEM_DEPTH  = 2 * MAX_FFT_N;                // = 64  (re+im interleaved)
  localparam ADDR_WIDTH = $clog2(MEM_DEPTH);             // = 6
  localparam PAIR_ADDR_WIDTH = ADDR_WIDTH - 1;           // = 5

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

  // ---- Narrow port signals (CPU → memory) ----
  wire [ADDR_WIDTH-1:0] cpu_mem_addr;
  wire [31:0]           cpu_mem_rdata;
  wire [31:0]           cpu_mem_wdata;
  wire [ 3:0]           cpu_mem_wstrb;

  // ---- Wide port signals (FFT → memory) ----
  wire [ 3:0] accel_mem_wstrb_lo;
  wire [ 3:0] accel_mem_wstrb_hi;
  wire [31:0] accel_mem_rdata_lo;
  wire [31:0] accel_mem_rdata_hi;
  wire [31:0] accel_mem_wdata_lo;
  wire [31:0] accel_mem_wdata_hi;
  wire [31:0] accel_mem_pair_addr;

  // CPU → accelerator access decoding
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
        TWIDDLE PACKING:  CSR array → flat bus for FFT core
    ----------------------------------------------------------------------------------------*/
  wire [32 * NUM_TW - 1 : 0] tw_re_packed;
  wire [32 * NUM_TW - 1 : 0] tw_im_packed;

  genvar gi;
  generate
    for (gi = 0; gi < NUM_TW; gi = gi + 1) begin : gen_tw_pack
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
      .clk       (clk),

      // Narrow port → CPU
      .wen       (cpu_mem_wstrb),
      .addr      (cpu_mem_addr),
      .wdata     (cpu_mem_wdata),
      .rdata     (cpu_mem_rdata),

      // Wide port → FFT core
      .wen_lo    (accel_mem_wstrb_lo),
      .wen_hi    (accel_mem_wstrb_hi),
      .pair_addr (accel_mem_pair_addr[PAIR_ADDR_WIDTH-1:0]),
      .wdata_lo  (accel_mem_wdata_lo),
      .wdata_hi  (accel_mem_wdata_hi),
      .rdata_lo  (accel_mem_rdata_lo),
      .rdata_hi  (accel_mem_rdata_hi)
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

      // Wide paired SRAM interface
      .accel_mem_wstrb_lo (accel_mem_wstrb_lo),
      .accel_mem_wstrb_hi (accel_mem_wstrb_hi),
      .accel_mem_rdata_lo (accel_mem_rdata_lo),
      .accel_mem_rdata_hi (accel_mem_rdata_hi),
      .accel_mem_wdata_lo (accel_mem_wdata_lo),
      .accel_mem_wdata_hi (accel_mem_wdata_hi),
      .accel_mem_pair_addr(accel_mem_pair_addr),

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

  // Address decoding (unchanged)
  assign iomem_access_accelerator = iomem_valid && iomem_addr[31:24] == 8'h03;
  assign iomem_access_conf = iomem_access_accelerator && (iomem_addr[23:0] >> 2) < NUM_REGS;
  assign iomem_access_mem  = iomem_access_accelerator && (iomem_addr[23:0] >> 2) >= NUM_REGS;

  // Ready/data mux — CPU reads go through the narrow port
  assign iomem_ready = iomem_access_conf ? iomem_conf_ready
                     : (iomem_access_mem  ? iomem_mem_ready : 1'b0);
  assign iomem_rdata = iomem_access_conf ? iomem_conf_rdata
                     : (iomem_access_mem  ? cpu_mem_rdata : 32'b0);

  // ---- Narrow port routing (CPU only) ----
  //   Address: convert byte address → word index, subtract CSR offset
  assign iomem_accel_addr = iomem_addr >> 2;
  assign cpu_mem_addr  = iomem_access_mem ? (iomem_addr[23:2] - NUM_REGS) : {ADDR_WIDTH{1'b0}};
  assign cpu_mem_wdata = iomem_wdata;
  assign cpu_mem_wstrb = iomem_access_mem ? iomem_wstrb : 4'b0000;

  // ---- Wide port routing (FFT only) ----
  //   Directly driven by accelerator_fft — no mux needed.
  //   FFT write strobes are only non-zero during S_STORE_DATA,
  //   which is mutually exclusive with CPU access by protocol.

  /*----------------------------------------------------------------------------------------
        IOMEM HANDSHAKE LOGIC  (unchanged from v6)
    ----------------------------------------------------------------------------------------*/
  always @(posedge clk) begin
    if (!resetn) begin
      iomem_conf_ready <= 0;
      iomem_mem_ready  <= 0;
      iomem_conf_rdata <= 0;
      for (i = 0; i < NUM_REGS; i = i + 1)
        iomem_accel[i] <= 32'd0;
    end else begin
      iomem_conf_ready <= 0;
      iomem_mem_ready  <= 0;

      // CSR read/write
      if (iomem_access_conf && !iomem_conf_ready) begin
        iomem_conf_ready <= 1;
        if (iomem_accel_addr == 0)
          iomem_conf_rdata <= {iomem_accel[0][31:3], finished_accel, iomem_accel[0][1:0]};
        else
          iomem_conf_rdata <= iomem_accel[iomem_accel_addr];

        if (iomem_wstrb[0]) iomem_accel[iomem_accel_addr][ 7: 0] <= iomem_wdata[ 7: 0];
        if (iomem_wstrb[1]) iomem_accel[iomem_accel_addr][15: 8] <= iomem_wdata[15: 8];
        if (iomem_wstrb[2]) iomem_accel[iomem_accel_addr][23:16] <= iomem_wdata[23:16];
        if (iomem_wstrb[3]) iomem_accel[iomem_accel_addr][31:24] <= iomem_wdata[31:24];
      end

      // Memory read/write — narrow port serves CPU path
      if (iomem_access_mem && !iomem_mem_ready) begin
        iomem_mem_ready <= 1;
        // Write handled by cpu_mem_wstrb going to the narrow port
        // Read data available combinationally via cpu_mem_rdata
      end
    end
  end

endmodule