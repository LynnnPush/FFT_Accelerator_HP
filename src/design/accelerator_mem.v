/*##########################################################################
###
### Register-file memory for the accelerator (Wide-port variant)
###
###     Adds a 64-bit paired (wide) interface alongside the original 32-bit
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
    localparam ADDR_MEM_WIDTH  = $clog2(MEM_DEPTH),        // = 6 for 64
    localparam PAIR_ADDR_WIDTH = ADDR_MEM_WIDTH - 1         // = 5 for 64 (32 pairs)
) (
    input  wire                      clk,

    // ---- Narrow port (32-bit, CPU path) ----
    input  wire [3:0]                wen,
    input  wire [ADDR_MEM_WIDTH-1:0] addr,
    input  wire [31:0]               wdata,
    output wire [31:0]               rdata,

    // ---- Wide port (64-bit paired, FFT path) ----
    input  wire [3:0]                 wen_lo,       // write strobe for even word (re)
    input  wire [3:0]                 wen_hi,       // write strobe for odd  word (im)
    input  wire [PAIR_ADDR_WIDTH-1:0] pair_addr,    // selects which pair (0..31)
    input  wire [31:0]                wdata_lo,     // write data for even word (re)
    input  wire [31:0]                wdata_hi,     // write data for odd  word (im)
    output wire [31:0]                rdata_lo,     // read data  even word (re)
    output wire [31:0]                rdata_hi      // read data  odd  word (im)
);

    reg [31:0] mem [0:MEM_DEPTH-1];

    // ---------- Narrow read (combinational) ----------
    assign rdata = mem[addr];

    // ---------- Wide read (combinational, paired) ----------
    //   pair_addr selects a pair; bit-0 distinguishes even(re)/odd(im).
    //   Synthesis sees 32 × (MEM_DEPTH/2):1 mux trees per output bit,
    //   sharing the pair_addr decode between rdata_lo and rdata_hi.
    assign rdata_lo = mem[{pair_addr, 1'b0}];   // even address → re
    assign rdata_hi = mem[{pair_addr, 1'b1}];   // odd  address → im

    // ---------- Write logic ----------
    //   Narrow and wide writes are mutually exclusive by system protocol.
    //   The wrapper guarantees wen==0 when wen_lo/wen_hi are active,
    //   and vice versa.
    wire [ADDR_MEM_WIDTH-1:0] wide_addr_lo = {pair_addr, 1'b0};
    wire [ADDR_MEM_WIDTH-1:0] wide_addr_hi = {pair_addr, 1'b1};

    always @(posedge clk) begin
        // Narrow write (CPU path)
        if (wen[0]) mem[addr][ 7: 0] <= wdata[ 7: 0];
        if (wen[1]) mem[addr][15: 8] <= wdata[15: 8];
        if (wen[2]) mem[addr][23:16] <= wdata[23:16];
        if (wen[3]) mem[addr][31:24] <= wdata[31:24];

        // Wide write — even word (re)
        if (wen_lo[0]) mem[wide_addr_lo][ 7: 0] <= wdata_lo[ 7: 0];
        if (wen_lo[1]) mem[wide_addr_lo][15: 8] <= wdata_lo[15: 8];
        if (wen_lo[2]) mem[wide_addr_lo][23:16] <= wdata_lo[23:16];
        if (wen_lo[3]) mem[wide_addr_lo][31:24] <= wdata_lo[31:24];

        // Wide write — odd word (im)
        if (wen_hi[0]) mem[wide_addr_hi][ 7: 0] <= wdata_hi[ 7: 0];
        if (wen_hi[1]) mem[wide_addr_hi][15: 8] <= wdata_hi[15: 8];
        if (wen_hi[2]) mem[wide_addr_hi][23:16] <= wdata_hi[23:16];
        if (wen_hi[3]) mem[wide_addr_hi][31:24] <= wdata_hi[31:24];
    end

endmodule