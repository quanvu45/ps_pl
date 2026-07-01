// =============================================================================
// msg_shared_mem.v
//
// Shared Memory module for PS-PL message communication on DE1-SoC.
// Implements a 256x32-bit (1KB) dual-port RAM:
//   Port A: Avalon-MM slave — accessed by HPS via Lightweight bridge
//   Port B: Conduit         — accessed by FPGA custom logic
//
// Memory Layout (word addresses):
//   TX Region (PS → PL): 0x00 - 0x7F
//     [0x00] TX_FLAG      — 1 = message ready, 0 = empty
//     [0x01] TX_HEADER    — [31:24]=0xAB, [23:16]=msg_type, [15:0]=payload_len
//     [0x02] TX_CHECKSUM  — XOR checksum (header ^ all payload words)
//     [0x03] (reserved)
//     [0x04 - 0x7F] TX_PAYLOAD — up to 124 words (496 bytes)
//
//   RX Region (PL → PS): 0x80 - 0xFF
//     [0x80] RX_FLAG      — 1 = message ready, 0 = empty
//     [0x81] RX_HEADER    — same format as TX_HEADER
//     [0x82] RX_CHECKSUM  — XOR checksum
//     [0x83] (reserved)
//     [0x84 - 0xFF] RX_PAYLOAD — up to 124 words (496 bytes)
//
// =============================================================================

module msg_shared_mem (
    // Clock and Reset
    input             clk,
    input             reset,

    // ---- Avalon-MM Slave Interface (HPS side — Port A) ----
    input      [7:0]  avl_address,
    input             avl_read,
    input             avl_write,
    input      [31:0] avl_writedata,
    output reg [31:0] avl_readdata,

    // ---- FPGA-side Memory Access (Conduit — Port B) ----
    input      [7:0]  coe_address,
    input             coe_read,
    input             coe_write,
    input      [31:0] coe_writedata,
    output reg [31:0] coe_readdata
);

// -------------------------------------------------------------------------
// Dual-port RAM — 256 words × 32 bits = 1 KB
// Infers true dual-port block RAM (M10K) on Cyclone V.
// -------------------------------------------------------------------------
(* ramstyle = "no_rw_check" *)
reg [31:0] mem [0:255];

// Initialize memory to zero
integer i;
initial begin
    for (i = 0; i < 256; i = i + 1)
        mem[i] = 32'h00000000;
end

// ---- Port A : Avalon-MM (HPS access) ----
// Read latency = 1 clock cycle (matches TCL readLatency setting)
always @(posedge clk) begin
    if (avl_write)
        mem[avl_address] <= avl_writedata;

    avl_readdata <= mem[avl_address];   // always read, data valid 1 cycle later
end

// ---- Port B : FPGA logic access ----
// Read latency = 1 clock cycle
always @(posedge clk) begin
    if (coe_write)
        mem[coe_address] <= coe_writedata;

    coe_readdata <= mem[coe_address];   // always read, data valid 1 cycle later
end

endmodule
