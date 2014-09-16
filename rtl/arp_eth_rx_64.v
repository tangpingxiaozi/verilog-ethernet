/*

Copyright (c) 2014 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`timescale 1ns / 1ps

/*
 * ARP ethernet frame receiver (Ethernet frame in, ARP frame out, 64 bit datapath)
 */
module arp_eth_rx_64
(
    input  wire        clk,
    input  wire        rst,

    /*
     * Ethernet frame input
     */
    input  wire        input_eth_hdr_valid,
    output wire        input_eth_hdr_ready,
    input  wire [47:0] input_eth_dest_mac,
    input  wire [47:0] input_eth_src_mac,
    input  wire [15:0] input_eth_type,
    input  wire [63:0] input_eth_payload_tdata,
    input  wire [7:0]  input_eth_payload_tkeep,
    input  wire        input_eth_payload_tvalid,
    output wire        input_eth_payload_tready,
    input  wire        input_eth_payload_tlast,
    input  wire        input_eth_payload_tuser,

    /*
     * ARP frame output
     */
    output wire        output_frame_valid,
    input  wire        output_frame_ready,
    output wire [47:0] output_eth_dest_mac,
    output wire [47:0] output_eth_src_mac,
    output wire [15:0] output_eth_type,
    output wire [15:0] output_arp_htype,
    output wire [15:0] output_arp_ptype,
    output wire [7:0]  output_arp_hlen,
    output wire [7:0]  output_arp_plen,
    output wire [15:0] output_arp_oper,
    output wire [47:0] output_arp_sha,
    output wire [31:0] output_arp_spa,
    output wire [47:0] output_arp_tha,
    output wire [31:0] output_arp_tpa,

    /*
     * Status signals
     */
    output wire        busy,
    output wire        error_header_early_termination,
    output wire        error_invalid_header
);

/*

ARP Frame

 Field                       Length
 Destination MAC address     6 octets
 Source MAC address          6 octets
 Ethertype (0x0806)          2 octets
 HTYPE (1)                   2 octets
 PTYPE (0x0800)              2 octets
 HLEN (6)                    1 octets
 PLEN (4)                    1 octets
 OPER                        2 octets
 SHA Sender MAC              6 octets
 SPA Sender IP               4 octets
 THA Target MAC              6 octets
 TPA Target IP               4 octets

This module receives an Ethernet frame with decoded fields and decodes
the ARP packet format.  If the Ethertype does not match, the packet is
discarded.

*/

localparam [2:0]
    STATE_IDLE = 3'd0,
    STATE_READ_HEADER = 3'd1,
    STATE_WAIT_LAST = 3'd2;

reg [2:0] state_reg = STATE_IDLE, state_next;

// datapath control signals
reg store_eth_hdr;
reg store_arp_hdr_word_0;
reg store_arp_hdr_word_1;
reg store_arp_hdr_word_2;
reg store_arp_hdr_word_3;

reg [7:0] frame_ptr_reg = 0, frame_ptr_next;

reg input_eth_hdr_ready_reg = 0;
reg input_eth_payload_tready_reg = 0;

reg output_frame_valid_reg = 0, output_frame_valid_next;
reg [47:0] output_eth_dest_mac_reg = 0;
reg [47:0] output_eth_src_mac_reg = 0;
reg [15:0] output_eth_type_reg = 0;
reg [15:0] output_arp_htype_reg = 0;
reg [15:0] output_arp_ptype_reg = 0;
reg [7:0]  output_arp_hlen_reg = 0;
reg [7:0]  output_arp_plen_reg = 0;
reg [15:0] output_arp_oper_reg = 0;
reg [47:0] output_arp_sha_reg = 0;
reg [31:0] output_arp_spa_reg = 0;
reg [47:0] output_arp_tha_reg = 0;
reg [31:0] output_arp_tpa_reg = 0;

reg busy_reg = 0;
reg error_header_early_termination_reg = 0, error_header_early_termination_next;
reg error_invalid_header_reg = 0, error_invalid_header_next;

assign input_eth_hdr_ready = input_eth_hdr_ready_reg;
assign input_eth_payload_tready = input_eth_payload_tready_reg;

assign output_frame_valid = output_frame_valid_reg;
assign output_eth_dest_mac = output_eth_dest_mac_reg;
assign output_eth_src_mac = output_eth_src_mac_reg;
assign output_eth_type = output_eth_type_reg;
assign output_arp_htype = output_arp_htype_reg;
assign output_arp_ptype = output_arp_ptype_reg;
assign output_arp_hlen = output_arp_hlen_reg;
assign output_arp_plen = output_arp_plen_reg;
assign output_arp_oper = output_arp_oper_reg;
assign output_arp_sha = output_arp_sha_reg;
assign output_arp_spa = output_arp_spa_reg;
assign output_arp_tha = output_arp_tha_reg;
assign output_arp_tpa = output_arp_tpa_reg;

assign busy = busy_reg;
assign error_header_early_termination = error_header_early_termination_reg;
assign error_invalid_header = error_invalid_header_reg;

always @* begin
    state_next = 2'bz;

    store_eth_hdr = 0;
    store_arp_hdr_word_0 = 0;
    store_arp_hdr_word_1 = 0;
    store_arp_hdr_word_2 = 0;
    store_arp_hdr_word_3 = 0;

    frame_ptr_next = frame_ptr_reg;

    output_frame_valid_next = output_frame_valid_reg & ~output_frame_ready;

    error_header_early_termination_next = 0;
    error_invalid_header_next = 0;

    case (state_reg)
        STATE_IDLE: begin
            // idle state - wait for data
            frame_ptr_next = 0;

            if (input_eth_hdr_ready & input_eth_hdr_valid) begin
                frame_ptr_next = 0;
                store_eth_hdr = 1;
                state_next = STATE_READ_HEADER;
            end else begin
                state_next = STATE_IDLE;
            end
        end
        STATE_READ_HEADER: begin
            // read header state
            if (input_eth_payload_tvalid) begin
                // word transfer in - store it
                frame_ptr_next = frame_ptr_reg+1;
                state_next = STATE_READ_HEADER;
                case (frame_ptr_reg)
                    8'h00: store_arp_hdr_word_0 = 1;
                    8'h01: store_arp_hdr_word_1 = 1;
                    8'h02: store_arp_hdr_word_2 = 1;
                    8'h03: begin
                        store_arp_hdr_word_3 = 1;
                        state_next = STATE_WAIT_LAST;
                    end
                endcase
                if (input_eth_payload_tlast) begin
                    state_next = STATE_IDLE;
                    if (frame_ptr_reg != 8'h03 | (input_eth_payload_tkeep & 8'h0F) != 8'h0F) begin
                        error_header_early_termination_next = 1;
                    end else if (output_arp_hlen != 6 || output_arp_plen != 4) begin
                        error_invalid_header_next = 1;
                    end else begin
                        output_frame_valid_next = ~input_eth_payload_tuser;
                    end
                end
            end else begin
                state_next = STATE_READ_HEADER;
            end
        end
        STATE_WAIT_LAST: begin
            // read last payload word; data in output register; do not accept new data
            if (input_eth_payload_tvalid) begin
                // word transfer out - done
                if (input_eth_payload_tlast) begin
                    if (output_arp_hlen != 6 || output_arp_plen != 4) begin
                        error_invalid_header_next = 1;
                    end else begin
                        output_frame_valid_next = ~input_eth_payload_tuser;
                    end
                    state_next = STATE_IDLE;
                end else begin
                    state_next = STATE_WAIT_LAST;
                end
            end else begin
                // wait for end of frame; read and discard
                state_next = STATE_WAIT_LAST;
            end
        end
    endcase
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state_reg <= STATE_IDLE;
        frame_ptr_reg <= 0;
        input_eth_payload_tready_reg <= 0;
        output_frame_valid_reg <= 0;
        output_eth_dest_mac_reg <= 0;
        output_eth_src_mac_reg <= 0;
        output_eth_type_reg <= 0;
        busy_reg <= 0;
        error_header_early_termination_reg <= 0;
        error_invalid_header_reg <= 0;
    end else begin
        state_reg <= state_next;

        frame_ptr_reg <= frame_ptr_next;

        output_frame_valid_reg <= output_frame_valid_next;

        error_header_early_termination_reg <= error_header_early_termination_next;
        error_invalid_header_reg <= error_invalid_header_next;

        busy_reg <= state_next != STATE_IDLE;

        // generate valid outputs
        case (state_next)
            STATE_IDLE: begin
                // idle; accept new data
                input_eth_hdr_ready_reg <= ~output_frame_valid;
                input_eth_payload_tready_reg <= 0;
            end
            STATE_READ_HEADER: begin
                // read header; accept new data
                input_eth_hdr_ready_reg <= 0;
                input_eth_payload_tready_reg <= 1;
            end
            STATE_WAIT_LAST: begin
                // wait for end of frame; read and discard
                input_eth_hdr_ready_reg <= 0;
                input_eth_payload_tready_reg <= 1;
            end
        endcase

        // datapath
        if (store_eth_hdr) begin
            output_eth_dest_mac_reg <= input_eth_dest_mac;
            output_eth_src_mac_reg <= input_eth_src_mac;
            output_eth_type_reg <= input_eth_type;
        end

        if (store_arp_hdr_word_0) begin
            output_arp_htype_reg[15: 8] <= input_eth_payload_tdata[ 7: 0];
            output_arp_htype_reg[ 7: 0] <= input_eth_payload_tdata[15: 8];
            output_arp_ptype_reg[15: 8] <= input_eth_payload_tdata[23:16];
            output_arp_ptype_reg[ 7: 0] <= input_eth_payload_tdata[31:24];
            output_arp_hlen_reg <= input_eth_payload_tdata[39:32];
            output_arp_plen_reg <= input_eth_payload_tdata[47:40];
            output_arp_oper_reg[15: 8] <= input_eth_payload_tdata[55:48];
            output_arp_oper_reg[ 7: 0] <= input_eth_payload_tdata[63:56];
        end
        if (store_arp_hdr_word_1) begin
            output_arp_sha_reg[47:40] <= input_eth_payload_tdata[ 7: 0];
            output_arp_sha_reg[39:32] <= input_eth_payload_tdata[15: 8];
            output_arp_sha_reg[31:24] <= input_eth_payload_tdata[23:16];
            output_arp_sha_reg[23:16] <= input_eth_payload_tdata[31:24];
            output_arp_sha_reg[15: 8] <= input_eth_payload_tdata[39:32];
            output_arp_sha_reg[ 7: 0] <= input_eth_payload_tdata[47:40];
            output_arp_spa_reg[31:24] <= input_eth_payload_tdata[55:48];
            output_arp_spa_reg[23:16] <= input_eth_payload_tdata[63:56];
        end
        if (store_arp_hdr_word_2) begin
            output_arp_spa_reg[15: 8] <= input_eth_payload_tdata[ 7: 0];
            output_arp_spa_reg[ 7: 0] <= input_eth_payload_tdata[15: 8];
            output_arp_tha_reg[47:40] <= input_eth_payload_tdata[23:16];
            output_arp_tha_reg[39:32] <= input_eth_payload_tdata[31:24];
            output_arp_tha_reg[31:24] <= input_eth_payload_tdata[39:32];
            output_arp_tha_reg[23:16] <= input_eth_payload_tdata[47:40];
            output_arp_tha_reg[15: 8] <= input_eth_payload_tdata[55:48];
            output_arp_tha_reg[ 7: 0] <= input_eth_payload_tdata[63:56];
        end
        if (store_arp_hdr_word_3) begin
            output_arp_tpa_reg[31:24] <= input_eth_payload_tdata[ 7: 0];
            output_arp_tpa_reg[23:16] <= input_eth_payload_tdata[15: 8];
            output_arp_tpa_reg[15: 8] <= input_eth_payload_tdata[23:16];
            output_arp_tpa_reg[ 7: 0] <= input_eth_payload_tdata[31:24];
        end
    end
end

endmodule
