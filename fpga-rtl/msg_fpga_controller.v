// =============================================================================
// msg_fpga_controller.v
//
// FPGA-side controller for message processing.
// Polls shared memory TX_FLAG, reads PS messages, verifies checksum,
// creates echo response in RX region, and signals PS via RX_FLAG.
//
// Operation:
//   1. Poll TX_FLAG every ~256 clock cycles
//   2. If TX_FLAG==1: read header, copy payload to RX, verify checksum
//   3. Write echo response: RX_HEADER (msg_type | 0x80), same payload, new CRC
//   4. Set RX_FLAG=1, clear TX_FLAG=0
//
// Status outputs drive HEX displays in ghrd_top.v.
// =============================================================================

module msg_fpga_controller (
    input             clk,
    input             reset_n,

    // ---- Shared memory FPGA-side port ----
    output reg [7:0]  mem_address,
    output reg        mem_read,
    output reg        mem_write,
    output reg [31:0] mem_writedata,
    input      [31:0] mem_readdata,

    // ---- Status outputs ----
    output reg [7:0]  last_msg_type,    // Last received msg_type (for HEX)
    output reg [15:0] msg_count,        // Total messages processed
    output reg        checksum_err,     // Checksum mismatch flag
    output reg        busy,             // Currently processing a message
    output reg        irq_pulse         // 1-cycle pulse to trigger PIO interrupt
);

// =========================================================================
// Memory map constants (must match msg_protocol.h / msg_shared_mem.v)
// =========================================================================
localparam TX_FLAG     = 8'h00;
localparam TX_HEADER   = 8'h01;
localparam TX_CHECKSUM = 8'h02;
localparam TX_PAYLOAD  = 8'h04;   // first payload word

localparam RX_FLAG     = 8'h80;
localparam RX_HEADER   = 8'h81;
localparam RX_CHECKSUM = 8'h82;
localparam RX_PAYLOAD  = 8'h84;   // first payload word

// =========================================================================
// Function: Convert ASCII lowercase to uppercase
// =========================================================================
function [7:0] to_upper;
    input [7:0] char;
    begin
        if (char >= 8'h61 && char <= 8'h7A)  // 'a' (0x61) to 'z' (0x7A)
            to_upper = char - 8'h20;
        else
            to_upper = char;
    end
endfunction

// =========================================================================
// State encoding
// =========================================================================
localparam S_IDLE       = 4'd0;   // Waiting, poll periodically
localparam S_RD_FLAG_W  = 4'd1;   // Wait for TX_FLAG read (1-cycle latency)
localparam S_CHK_FLAG   = 4'd2;   // Check TX_FLAG value
localparam S_RD_HDR_W   = 4'd3;   // Wait for TX_HEADER read
localparam S_GOT_HDR    = 4'd4;   // Process header, decide next step
localparam S_RD_PL_W    = 4'd5;   // Wait for TX payload word read
localparam S_GOT_PL     = 4'd6;   // Got payload word → write to RX
localparam S_WR_PL_NEXT = 4'd7;   // Advance to next payload word or CRC
localparam S_RD_CRC_W   = 4'd8;   // Wait for TX_CHECKSUM read
localparam S_VERIFY     = 4'd9;   // Compare checksums
localparam S_WR_RX_HDR  = 4'd10;  // Write RX_HEADER
localparam S_WR_RX_CRC  = 4'd11;  // Write RX_CHECKSUM
localparam S_WR_RX_FLAG = 4'd12;  // Set RX_FLAG = 1
localparam S_CLR_TX     = 4'd13;  // Clear TX_FLAG = 0
localparam S_DONE       = 4'd14;  // Return to idle

// =========================================================================
// Internal registers
// =========================================================================
reg [3:0]  state;
reg [7:0]  poll_timer;       // Counts up; polls at rollover (every 256 cycles)
reg [31:0] tx_header;        // Captured TX header
reg [31:0] rx_header;        // Echo response header
reg [15:0] payload_len;      // Number of payload words
reg [15:0] word_idx;         // Current payload word index
reg [31:0] tx_calc_crc;      // Running XOR for TX verification
reg [31:0] rx_calc_crc;      // Running XOR for RX response CRC

// =========================================================================
// State Machine
// =========================================================================
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        state        <= S_IDLE;
        mem_address  <= 8'h00;
        mem_read     <= 1'b0;
        mem_write    <= 1'b0;
        mem_writedata<= 32'h0;
        last_msg_type<= 8'h00;
        msg_count    <= 16'h0;
        checksum_err <= 1'b0;
        busy         <= 1'b0;
        poll_timer   <= 8'h00;
        tx_header    <= 32'h0;
        rx_header    <= 32'h0;
        payload_len  <= 16'h0;
        word_idx     <= 16'h0;
        tx_calc_crc  <= 32'h0;
        rx_calc_crc  <= 32'h0;
        irq_pulse    <= 1'b0;
    end else begin
        // Default: deassert bus control signals every cycle
        mem_read  <= 1'b0;
        mem_write <= 1'b0;
        irq_pulse <= 1'b0; // Default to 0, only pulse 1 cycle when needed

        case (state)
            // =============================================================
            // IDLE — poll TX_FLAG every 256 clock cycles (~5.12 µs @ 50 MHz)
            // =============================================================
            S_IDLE: begin
                busy <= 1'b0;
                poll_timer <= poll_timer + 8'd1;
                if (poll_timer == 8'hFF) begin
                    mem_address <= TX_FLAG;
                    mem_read    <= 1'b1;
                    state       <= S_RD_FLAG_W;
                end
            end

            // Wait 1 cycle for read latency
            S_RD_FLAG_W: begin
                state <= S_CHK_FLAG;
            end

            // Check whether PS has posted a new message
            S_CHK_FLAG: begin
                if (mem_readdata[0] == 1'b1) begin
                    // Message available — start reading
                    busy         <= 1'b1;
                    checksum_err <= 1'b0;
                    mem_address  <= TX_HEADER;
                    mem_read     <= 1'b1;
                    state        <= S_RD_HDR_W;
                end else begin
                    state <= S_IDLE;
                end
            end

            // Wait for header read
            S_RD_HDR_W: begin
                state <= S_GOT_HDR;
            end

            // Process TX header
            S_GOT_HDR: begin
                tx_header     <= mem_readdata;
                payload_len   <= mem_readdata[15:0];
                last_msg_type <= mem_readdata[23:16];
                tx_calc_crc   <= mem_readdata;       // init CRC with header

                // Build echo RX header: same magic & length, msg_type | 0x80
                rx_header   <= {mem_readdata[31:24],
                                mem_readdata[23:16] | 8'h80,
                                mem_readdata[15:0]};
                rx_calc_crc <= {mem_readdata[31:24],
                                mem_readdata[23:16] | 8'h80,
                                mem_readdata[15:0]};

                word_idx <= 16'd0;

                if (mem_readdata[15:0] > 16'd0) begin
                    // Payload present — read first word
                    mem_address <= TX_PAYLOAD;
                    mem_read    <= 1'b1;
                    state       <= S_RD_PL_W;
                end else begin
                    // No payload — go straight to checksum
                    mem_address <= TX_CHECKSUM;
                    mem_read    <= 1'b1;
                    state       <= S_RD_CRC_W;
                end
            end

            // Wait for payload word read
            S_RD_PL_W: begin
                state <= S_GOT_PL;
            end

            // Got a payload word — accumulate CRCs, write copy to RX area
            S_GOT_PL: begin
                tx_calc_crc <= tx_calc_crc ^ mem_readdata;
                
                // Convert 4 bytes (1 word) to uppercase simultaneously
                mem_writedata <= { to_upper(mem_readdata[31:24]),
                                   to_upper(mem_readdata[23:16]),
                                   to_upper(mem_readdata[15:8]),
                                   to_upper(mem_readdata[7:0]) };
                
                // RX CRC must be calculated on the NEW uppercase data!
                rx_calc_crc <= rx_calc_crc ^ { to_upper(mem_readdata[31:24]),
                                               to_upper(mem_readdata[23:16]),
                                               to_upper(mem_readdata[15:8]),
                                               to_upper(mem_readdata[7:0]) };

                // Write this uppercase word to the RX payload region
                mem_address   <= RX_PAYLOAD + word_idx[7:0];
                mem_write     <= 1'b1;

                state <= S_WR_PL_NEXT;
            end

            // Decide: more payload words, or move to checksum
            S_WR_PL_NEXT: begin
                word_idx <= word_idx + 16'd1;
                if (word_idx + 16'd1 >= payload_len) begin
                    // All payload copied — read TX checksum
                    mem_address <= TX_CHECKSUM;
                    mem_read    <= 1'b1;
                    state       <= S_RD_CRC_W;
                end else begin
                    // Read next payload word
                    mem_address <= TX_PAYLOAD + word_idx[7:0] + 8'd1;
                    mem_read    <= 1'b1;
                    state       <= S_RD_PL_W;
                end
            end

            // Wait for TX_CHECKSUM read
            S_RD_CRC_W: begin
                state <= S_VERIFY;
            end

            // Compare calculated CRC with stored CRC
            S_VERIFY: begin
                if (tx_calc_crc == mem_readdata) begin
                    // ✓ Checksum OK — write RX header
                    mem_address   <= RX_HEADER;
                    mem_write     <= 1'b1;
                    mem_writedata <= rx_header;
                    state         <= S_WR_RX_HDR;
                end else begin
                    // ✗ Checksum mismatch — flag error, clear TX
                    checksum_err  <= 1'b1;
                    mem_address   <= TX_FLAG;
                    mem_write     <= 1'b1;
                    mem_writedata <= 32'd0;
                    state         <= S_DONE;
                end
            end

            // RX header written — now write RX checksum
            S_WR_RX_HDR: begin
                mem_address   <= RX_CHECKSUM;
                mem_write     <= 1'b1;
                mem_writedata <= rx_calc_crc;
                state         <= S_WR_RX_CRC;
            end

            // RX checksum written — set RX_FLAG
            S_WR_RX_CRC: begin
                mem_address   <= RX_FLAG;
                mem_write     <= 1'b1;
                mem_writedata <= 32'd1;
                state         <= S_WR_RX_FLAG;
            end

            // RX_FLAG set — clear TX_FLAG
            S_WR_RX_FLAG: begin
                mem_address   <= TX_FLAG;
                mem_write     <= 1'b1;
                mem_writedata <= 32'd0;
                msg_count     <= msg_count + 16'd1;
                irq_pulse     <= 1'b1; // Trigger PIO interrupt
                state         <= S_CLR_TX;
            end

            // TX_FLAG cleared — done
            S_CLR_TX: begin
                state <= S_DONE;
            end

            // Return to idle
            S_DONE: begin
                poll_timer <= 8'd0;
                state      <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
