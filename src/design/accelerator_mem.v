// Register-file memory for the accelerator
// (Synthesises to flip-flops — combinational read, synchronous write)

module accelerator_mem #(
    parameter  MEM_DEPTH = 64,                          // 2*N for data-only (twiddles in CSR)
    localparam ADDR_MEM_WIDTH = $clog2(MEM_DEPTH)       // = 6 for MEM_DEPTH=64
) (
    input  wire                      clk,
    input  wire [3:0]                wen,
    input  wire [ADDR_MEM_WIDTH-1:0] addr,
    input  wire [31:0]               wdata,
    output wire [31:0]               rdata
);
    reg [31:0] mem [0:MEM_DEPTH-1];

    // Combinational (async) read — critical for single-cycle LOAD captures
    assign rdata = mem[addr];

    // Synchronous byte-enable write
    always @(posedge clk) begin
        if (wen[0]) mem[addr][ 7: 0] <= wdata[ 7: 0];
        if (wen[1]) mem[addr][15: 8] <= wdata[15: 8];
        if (wen[2]) mem[addr][23:16] <= wdata[23:16];
        if (wen[3]) mem[addr][31:24] <= wdata[31:24];
    end
endmodule