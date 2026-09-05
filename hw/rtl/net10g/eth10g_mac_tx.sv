/*
 *    Copyright 2026 Two Sigma Open Source, LLC
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

// Store-and-forward Ethernet transmitter. AXIS packets contain destination MAC
// through payload, without preamble or FCS. Byte lane zero is transmitted first.
// Two frame buffers allow concurrent ingress and transmission; MAX_FRAME_BYTES
// excludes FCS. Nonfinal beats must have keep=ff; final keep must be contiguous
// from lane zero and nonempty. Invalid, aborted and oversized packets are drained
// through tlast and generate one o_drop pulse without emitting a partial frame.
//
// i_enable advances one XGMII word and gates AXIS handshakes. Both interfaces
// share i_clk; i_enable is a clock enable, not wire-side flow control. XGMII data
// and control hold while disabled. o_drop is a single i_clk-cycle event.
// /S/ always occupies lane zero; short packets are padded to 60 bytes, followed
// by little-endian Ethernet FCS. One or two complete idle words follow /T/,
// providing 12..19 idle bytes (conservative IFG; no deficit-idle counting).
module eth10g_mac_tx #(
    parameter int unsigned MAX_FRAME_BYTES = 9216
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_enable,

    input  logic [63:0] s_axis_tdata,
    input  logic [ 7:0] s_axis_tkeep,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,
    input  logic        s_axis_tuser,

    output logic [63:0] o_xgmii_data,
    output logic [ 7:0] o_xgmii_ctrl,
    output logic        o_drop
);
  import eth10g_crc_pkg::*;

  localparam int unsigned FrameWords = (MAX_FRAME_BYTES + 7) / 8;
  localparam int unsigned WordIndexWidth = (FrameWords > 1) ? $clog2(FrameWords) : 1;
  localparam logic [63:0] IdleWord = 64'h0707070707070707;
  localparam logic [63:0] StartWord = 64'hd5555555555555fb;

  typedef enum logic [1:0] {
    TX_IDLE,
    TX_DATA,
    TX_GAP
  } tx_state_t;

  // Packet memory is deliberately not reset; buffer_full controls visibility.
  // The synchronous read is prefetched during preamble and each payload word.
  logic [63:0] frame_memory[2][FrameWords];
  logic [1:0] buffer_full;
  int unsigned frame_length[2];
  logic write_buffer;
  logic read_buffer;
  int unsigned write_length;
  logic write_discard;
  tx_state_t tx_state;
  int unsigned tx_position;
  logic [31:0] tx_crc;
  logic gap_remaining;

  int unsigned input_bytes;
  logic bad_beat;
  logic [63:0] payload_word;
  logic [63:0] next_data;
  logic [7:0] next_ctrl;
  logic [31:0] next_crc;
  logic terminate_word;
  int unsigned padded_length;

  assign s_axis_tready = i_enable && !i_rst && !buffer_full[write_buffer];

  always_comb begin
    input_bytes = 0;
    for (int lane = 0; lane < 8; lane++) begin
      input_bytes += int'(s_axis_tkeep[lane]);
    end
    bad_beat = s_axis_tuser || (s_axis_tkeep == 0) ||
               ((s_axis_tkeep & (s_axis_tkeep + 8'd1)) != 0) ||
               (!s_axis_tlast && s_axis_tkeep != 8'hff) ||
               (write_length + input_bytes > MAX_FRAME_BYTES);
  end

  always_comb begin
    padded_length = (frame_length[read_buffer] < 60) ? 60 : frame_length[read_buffer];
    next_data = IdleWord;
    next_ctrl = 8'hff;
    next_crc = tx_crc;
    terminate_word = 1'b0;
    for (int lane = 0; lane < 8; lane++) begin
      if (tx_position + unsigned'(lane) < padded_length) begin
        if (tx_position + unsigned'(lane) < frame_length[read_buffer]) begin
          next_data[lane*8+:8] = payload_word[lane*8+:8];
        end else begin
          next_data[lane*8+:8] = 8'h00;
        end
        next_ctrl[lane] = 1'b0;
        next_crc = crc32_byte(next_crc, next_data[lane*8+:8]);
      end else if (tx_position + unsigned'(lane) < padded_length + 4) begin
        next_data[lane*8+:8] = 8'((~next_crc) >>
                                (8 * (tx_position + unsigned'(lane) - padded_length)));
        next_ctrl[lane] = 1'b0;
      end else if (tx_position + unsigned'(lane) == padded_length + 4) begin
        next_data[lane*8+:8] = 8'hfd;
        terminate_word = 1'b1;
      end
    end
  end

  // RAM read port: prefetch word zero while /S/ and preamble are emitted,
  // then fetch each succeeding word one enabled clock before it is needed.
  // No reset on the data register, allowing FPGA block-RAM inference.
  always_ff @(posedge i_clk) begin
    if (i_enable) begin
      if (tx_state == TX_IDLE && buffer_full[read_buffer]) begin
        payload_word <= frame_memory[read_buffer][0];
      end else if (tx_state == TX_DATA && tx_position + 8 < frame_length[read_buffer]) begin
        payload_word <= frame_memory[read_buffer][WordIndexWidth'((tx_position+8)>>3)];
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      buffer_full <= 0;
      frame_length[0] <= 0;
      frame_length[1] <= 0;
      write_buffer <= 0;
      read_buffer <= 0;
      write_length <= 0;
      write_discard <= 0;
      tx_state <= TX_IDLE;
      tx_position <= 0;
      tx_crc <= 32'hffffffff;
      gap_remaining <= 0;
      o_xgmii_data <= IdleWord;
      o_xgmii_ctrl <= 8'hff;
      o_drop <= 0;
    end else begin
      o_drop <= 0;
      if (i_enable) begin
        if (s_axis_tvalid && s_axis_tready) begin
          if (!write_discard && !bad_beat) begin
            frame_memory[write_buffer][WordIndexWidth'(write_length>>3)] <= s_axis_tdata;
            write_length <= write_length + input_bytes;
          end
          if (s_axis_tlast) begin
            if (write_discard || bad_beat) begin
              o_drop <= 1;
            end else begin
              frame_length[write_buffer] <= write_length + input_bytes;
              buffer_full[write_buffer] <= 1;
              write_buffer <= !write_buffer;
            end
            write_length  <= 0;
            write_discard <= 0;
          end else if (bad_beat) begin
            write_discard <= 1;
          end
        end

        case (tx_state)
          TX_IDLE: begin
            o_xgmii_data <= IdleWord;
            o_xgmii_ctrl <= 8'hff;
            if (buffer_full[read_buffer]) begin
              o_xgmii_data <= StartWord;
              o_xgmii_ctrl <= 8'h01;
              tx_position <= 0;
              tx_crc <= 32'hffffffff;
              tx_state <= TX_DATA;
            end
          end
          TX_DATA: begin
            o_xgmii_data <= next_data;
            o_xgmii_ctrl <= next_ctrl;
            tx_crc <= next_crc;
            tx_position <= tx_position + 8;
            if (terminate_word) begin
              buffer_full[read_buffer] <= 0;
              read_buffer <= !read_buffer;
              // /T/ in lanes 0..3 leaves enough trailing idles that one
              // additional word gives >=12 idles. Later lanes need two.
              gap_remaining <= ((padded_length + 4) & 7) >= 4;
              tx_state <= TX_GAP;
            end
          end
          TX_GAP: begin
            o_xgmii_data <= IdleWord;
            o_xgmii_ctrl <= 8'hff;
            if (gap_remaining) begin
              gap_remaining <= 0;
            end else begin
              tx_state <= TX_IDLE;
            end
          end
          default: begin
            tx_state <= TX_IDLE;
            o_xgmii_data <= IdleWord;
            o_xgmii_ctrl <= 8'hff;
          end
        endcase
      end
    end
  end
endmodule
