/*##########################################################################
###
### Register-file memory for the accelerator (Wide-port variant)
###
###     Adds a 48-bit paired (wide) interface alongside the original 32-bit
###     narrow interface.  The narrow port serves CPU (iomem) accesses;
###     the wide port serves the FFT core's LOAD/STORE phases.
###
###     Option B design: the wide port addresses *pairs* of consecutive
###     words — {mem[pair_addr,1], mem[pair_addr,0]} — exploiting the
###     interleaved re/im layout.  This uses 32:1 mux trees (one pair-
###     select per bit) instead of two independent 64:1 trees.
###
###     Narrow and wide writes are mutually exclusive by protocol
###     (CPU writes before enable_accel; FFT writes after).
###
###     Synthesises to flip-flops — combinational read, synchronous write.
###
##########################################################################*/

module accelerator_mem #(
    parameter  MEM_DEPTH       = 64,
    parameter  DATA_WIDTH      = 24,                         // internal word width
    localparam ADDR_MEM_WIDTH  = $clog2(MEM_DEPTH),          // = 6 for 64
    localparam PAIR_ADDR_WIDTH = ADDR_MEM_WIDTH - 1,          // = 5 for 64 (32 pairs)
    localparam WSTRB_WIDTH     = DATA_WIDTH / 8               // = 3 for 24-bit
) (
    input  wire                      clk,

    // ---- Narrow port (32-bit bus, CPU path) ----
    input  wire [3:0]                wen,
    input  wire [ADDR_MEM_WIDTH-1:0] addr,
    input  wire [31:0]               wdata,
    output wire [31:0]               rdata,

    // ---- Wide port (paired, FFT path) — DATA_WIDTH per word ----
    input  wire [WSTRB_WIDTH-1:0]     wen_lo,
    input  wire [WSTRB_WIDTH-1:0]     wen_hi,
    input  wire [PAIR_ADDR_WIDTH-1:0] pair_addr,
    input  wire [DATA_WIDTH-1:0]      wdata_lo,
    input  wire [DATA_WIDTH-1:0]      wdata_hi,
    output wire [DATA_WIDTH-1:0]      rdata_lo,
    output wire [DATA_WIDTH-1:0]      rdata_hi
);

    reg [DATA_WIDTH-1:0] mem [0:MEM_DEPTH-1];

    // ---------- Narrow read (sign-extend DATA_WIDTH → 32) ----------
    assign rdata    = {{(32-DATA_WIDTH){mem[addr][DATA_WIDTH-1]}}, mem[addr]};

    // ---------- Wide read (direct DATA_WIDTH, paired) ----------
    assign rdata_lo = mem[{pair_addr, 1'b0}];
    assign rdata_hi = mem[{pair_addr, 1'b1}];

    // ---------- Write logic ----------
    //   Narrow port: only the lower DATA_WIDTH bits (3 bytes) are stored; wen[3] is ignored.
    //   Wide port: DATA_WIDTH-wide, all bytes are meaningful.
    wire [ADDR_MEM_WIDTH-1:0] wide_addr_lo = {pair_addr, 1'b0};
    wire [ADDR_MEM_WIDTH-1:0] wide_addr_hi = {pair_addr, 1'b1};

    always @(posedge clk) begin
        // Narrow write (CPU path) — 3 bytes
        if (wen[0]) mem[addr][ 7: 0] <= wdata[ 7: 0];
        if (wen[1]) mem[addr][15: 8] <= wdata[15: 8];
        if (wen[2]) mem[addr][23:16] <= wdata[23:16];

        // Wide write — even word (re), 3 bytes
        if (wen_lo[0]) mem[wide_addr_lo][ 7: 0] <= wdata_lo[ 7: 0];
        if (wen_lo[1]) mem[wide_addr_lo][15: 8] <= wdata_lo[15: 8];
        if (wen_lo[2]) mem[wide_addr_lo][23:16] <= wdata_lo[23:16];

        // Wide write — odd word (im), 3 bytes
        if (wen_hi[0]) mem[wide_addr_hi][ 7: 0] <= wdata_hi[ 7: 0];
        if (wen_hi[1]) mem[wide_addr_hi][15: 8] <= wdata_hi[15: 8];
        if (wen_hi[2]) mem[wide_addr_hi][23:16] <= wdata_hi[23:16];
    end

endmodule