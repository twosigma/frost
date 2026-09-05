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

// Store-and-forward XGMII receive MAC. MAX_FRAME_BYTES counts destination
// address through payload/padding, excluding the four-byte FCS. A circular
// word buffer and packet descriptor queue retain complete validated packets.
// AXI Stream handshakes every clock, independently of i_enable; i_enable
// qualifies only incoming XGMII words. Bad packets are discarded before
// publication, so m_axis_tuser is always zero. No address filtering, pause
// processing, minimum IFG enforcement, or FCS forwarding is performed.
//
// o_bad_frame covers malformed, runt, overlength, FCS, and buffer-full drops.
// o_bad_fcs additionally identifies CRC failures; o_overflow identifies drops
// for lack of storage, at /S/ or during a packet. Pulses last one clock, even
// when i_enable is low. Error drops roll back speculative buffer allocation.
module eth10g_mac_rx #(
    parameter int unsigned MAX_FRAME_BYTES = 9216
) (
    input  logic        i_clk,
    input  logic        i_rst,
    input  logic        i_enable,
    input  logic [63:0] i_xgmii_data,
    input  logic [ 7:0] i_xgmii_ctrl,
    output logic [63:0] m_axis_tdata,
    output logic [ 7:0] m_axis_tkeep,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,
    output logic        m_axis_tuser,
    output logic        o_bad_frame,
    output logic        o_bad_fcs,
    output logic        o_overflow
);
  import eth10g_crc_pkg::*;

  localparam int unsigned CountWidth = $clog2(MAX_FRAME_BYTES + 5);
  localparam int unsigned MemoryAddrWidth = $clog2(2 * ((MAX_FRAME_BYTES + 11) / 8));
  localparam int unsigned MemoryWords = 1 << MemoryAddrWidth;
  // Every accepted frame occupies at least eight words (64 bytes with FCS),
  // so this queue cannot run out before the data memory does.
  localparam int unsigned DescriptorAddrWidth = MemoryAddrWidth - 3;
  localparam int unsigned DescriptorSlots = 1 << DescriptorAddrWidth;

  typedef enum logic [1:0] {
    IDLE,
    PREAMBLE,
    FRAME,
    DISCARD
  } state_t;
  state_t state, next_state;
  logic [2:0] preamble_count, next_preamble_count;
  logic [CountWidth-1:0] byte_count, next_byte_count;
  logic [31:0] crc, next_crc;
  logic [MemoryAddrWidth-1:0] write_word, next_write_word;
  logic [MemoryAddrWidth-1:0] read_word, next_read_word;
  logic [MemoryAddrWidth:0] free_words, next_free_words;
  logic [MemoryAddrWidth:0] reserved_words, next_reserved_words;
  logic [DescriptorAddrWidth-1:0] descriptor_write, next_descriptor_write;
  logic [DescriptorAddrWidth-1:0] descriptor_read, next_descriptor_read;
  logic [DescriptorAddrWidth:0] descriptor_count, next_descriptor_count;
  logic [CountWidth-1:0] read_count, next_read_count;
  logic bad_frame_event, bad_fcs_event, overflow_event;

  logic [CountWidth-1:0] packet_length[DescriptorSlots];
  logic [MemoryAddrWidth:0] packet_words[DescriptorSlots];
  logic descriptor_write_enable;
  logic [DescriptorAddrWidth-1:0] descriptor_write_address;
  logic [CountWidth-1:0] descriptor_write_length;
  logic [MemoryAddrWidth:0] descriptor_write_words;

  // Each of the eight byte lanes has one write port. Asynchronous reads are
  // portable but generally infer distributed RAM; a future device-specific
  // wrapper can replace these memories with synchronous block RAM.
  logic [7:0] packet_memory[8][MemoryWords];
  logic [7:0] memory_write_enable;
  logic [7:0] memory_write_data[8];
  logic [MemoryAddrWidth-1:0] memory_write_address[8];

  always_comb begin
    m_axis_tvalid = descriptor_count != 0;
    m_axis_tdata  = '0;
    m_axis_tkeep  = '0;
    m_axis_tlast  = 1'b0;
    m_axis_tuser  = 1'b0;
    if (m_axis_tvalid) begin
      m_axis_tlast = (int'(read_count) + 8 >= int'(packet_length[descriptor_read]));
      for (int lane = 0; lane < 8; lane++) begin
        if (int'(read_count) + lane < int'(packet_length[descriptor_read])) begin
          m_axis_tkeep[lane] = 1'b1;
          m_axis_tdata[lane*8+:8] = packet_memory[lane][read_word];
        end
      end
    end
  end

  always_comb begin
    next_state = state;
    next_preamble_count = preamble_count;
    next_byte_count = byte_count;
    next_crc = crc;
    next_write_word = write_word;
    next_read_word = read_word;
    next_free_words = free_words;
    next_reserved_words = reserved_words;
    next_descriptor_write = descriptor_write;
    next_descriptor_read = descriptor_read;
    next_descriptor_count = descriptor_count;
    next_read_count = read_count;
    bad_frame_event = 1'b0;
    bad_fcs_event = 1'b0;
    overflow_event = 1'b0;
    descriptor_write_enable = 1'b0;
    descriptor_write_address = descriptor_write;
    descriptor_write_length = '0;
    descriptor_write_words = '0;
    memory_write_enable = '0;
    for (int lane = 0; lane < 8; lane++) begin
      memory_write_data[lane] = '0;
      memory_write_address[lane] = '0;
    end

    if (m_axis_tvalid && m_axis_tready) begin
      if (m_axis_tlast) begin
        // Free the final payload word and any extra word occupied only by
        // FCS. Frame starts are word-aligned; read_count counts payload only.
        next_free_words = next_free_words + packet_words[descriptor_read] -
                          (MemoryAddrWidth+1)'(int'(read_count)/8);
        next_read_word = read_word + MemoryAddrWidth'(
            int'(packet_words[descriptor_read]) - int'(read_count)/8);
        next_descriptor_read = descriptor_read + 1'b1;
        next_descriptor_count = descriptor_count - 1'b1;
        next_read_count = '0;
      end else begin
        next_read_count = read_count + CountWidth'(8);
        next_read_word  = read_word + 1'b1;
        next_free_words = next_free_words + 1'b1;
      end
    end

    if (i_enable) begin
      for (int lane = 0; lane < 8; lane++) begin
        // A new legal start also recovers from an unterminated packet.
        if (i_xgmii_ctrl[lane] && i_xgmii_data[lane*8+:8] == 8'hfb &&
            (lane == 0 || lane == 4)) begin
          if (next_state == PREAMBLE || next_state == FRAME) bad_frame_event = 1'b1;
          next_free_words = next_free_words + next_reserved_words;
          next_reserved_words = '0;
          next_preamble_count = '0;
          next_byte_count = '0;
          next_crc = 32'hffffffff;
          if (next_free_words == 0 || int'(next_descriptor_count) == DescriptorSlots) begin
            next_state = DISCARD;
            bad_frame_event = 1'b1;
            overflow_event = 1'b1;
          end else begin
            next_state = PREAMBLE;
          end
        end else begin
          case (next_state)
            PREAMBLE: begin
              if (i_xgmii_ctrl[lane] ||
                  i_xgmii_data[lane*8+:8] !=
                  (next_preamble_count == 6 ? 8'hd5 : 8'h55)) begin
                next_state = DISCARD;
                bad_frame_event = 1'b1;
              end else if (next_preamble_count == 6) begin
                next_state = FRAME;
              end else begin
                next_preamble_count = next_preamble_count + 1'b1;
              end
            end

            FRAME: begin
              if (!i_xgmii_ctrl[lane]) begin
                if (int'(next_byte_count) >= MAX_FRAME_BYTES + 4) begin
                  next_state = DISCARD;
                  bad_frame_event = 1'b1;
                end else if (next_byte_count[2:0] == 0 && next_free_words == 0) begin
                  next_state = DISCARD;
                  bad_frame_event = 1'b1;
                  overflow_event = 1'b1;
                end else begin
                  if (next_byte_count[2:0] == 0) begin
                    next_free_words = next_free_words - 1'b1;
                    next_reserved_words = next_reserved_words + 1'b1;
                  end
                  memory_write_enable[next_byte_count[2:0]] = 1'b1;
                  memory_write_data[next_byte_count[2:0]] = i_xgmii_data[lane*8+:8];
                  memory_write_address[next_byte_count[2:0]] =
                      next_write_word + MemoryAddrWidth'(int'(next_byte_count)/8);
                  next_crc = crc32_byte(next_crc, i_xgmii_data[lane*8+:8]);
                  next_byte_count = next_byte_count + 1'b1;
                end
              end else if (i_xgmii_data[lane*8+:8] == 8'hfd) begin
                next_state = IDLE;
                if (int'(next_byte_count) < 64 || next_crc != 32'hdebb20e3) begin
                  bad_frame_event = 1'b1;
                  if (int'(next_byte_count) >= 4 && next_crc != 32'hdebb20e3) bad_fcs_event = 1'b1;
                  next_free_words = next_free_words + next_reserved_words;
                end else begin
                  descriptor_write_enable = 1'b1;
                  descriptor_write_address = next_descriptor_write;
                  descriptor_write_length = next_byte_count - CountWidth'(4);
                  descriptor_write_words = next_reserved_words;
                  next_descriptor_write = next_descriptor_write + 1'b1;
                  next_descriptor_count = next_descriptor_count + 1'b1;
                  next_write_word = next_write_word + MemoryAddrWidth'(next_reserved_words);
                end
                next_reserved_words = '0;
              end else begin
                next_state = DISCARD;
                bad_frame_event = 1'b1;
              end
              // Roll back an overlength, buffer-full, or control-error drop
              // immediately, retaining space for the next legal /S/.
              if (next_state == DISCARD) begin
                next_free_words = next_free_words + next_reserved_words;
                next_reserved_words = '0;
              end
            end

            DISCARD: begin
              if (i_xgmii_ctrl[lane] && i_xgmii_data[lane*8+:8] == 8'hfd) next_state = IDLE;
            end

            default: next_state = IDLE;
          endcase
        end
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state <= IDLE;
      preamble_count <= '0;
      byte_count <= '0;
      crc <= 32'hffffffff;
      write_word <= '0;
      read_word <= '0;
      free_words <= (MemoryAddrWidth + 1)'(MemoryWords);
      reserved_words <= '0;
      descriptor_write <= '0;
      descriptor_read <= '0;
      descriptor_count <= '0;
      read_count <= '0;
      o_bad_frame <= 1'b0;
      o_bad_fcs <= 1'b0;
      o_overflow <= 1'b0;
    end else begin
      state <= next_state;
      preamble_count <= next_preamble_count;
      byte_count <= next_byte_count;
      crc <= next_crc;
      write_word <= next_write_word;
      read_word <= next_read_word;
      free_words <= next_free_words;
      reserved_words <= next_reserved_words;
      descriptor_write <= next_descriptor_write;
      descriptor_read <= next_descriptor_read;
      descriptor_count <= next_descriptor_count;
      read_count <= next_read_count;
      o_bad_frame <= bad_frame_event;
      o_bad_fcs <= bad_fcs_event;
      o_overflow <= overflow_event;
    end
  end

  // Memory contents are deliberately not reset. The reset descriptor count
  // hides stale data and permits inference of FPGA RAM.
  always_ff @(posedge i_clk) begin
    if (!i_rst && descriptor_write_enable) begin
      packet_length[descriptor_write_address] <= descriptor_write_length;
      packet_words[descriptor_write_address]  <= descriptor_write_words;
    end
  end
  for (genvar lane = 0; lane < 8; lane++) begin : g_memory_lane
    always_ff @(posedge i_clk) begin
      if (!i_rst && memory_write_enable[lane])
        packet_memory[lane][memory_write_address[lane]] <= memory_write_data[lane];
    end
  end
endmodule : eth10g_mac_rx
