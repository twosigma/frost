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
// and control hold while disabled, except in reset. o_drop is a single i_clk-cycle
// event.
// /S/ always occupies lane zero; short packets are padded to 60 bytes, followed
// by little-endian Ethernet FCS. One or two complete idle words follow /T/,
// providing 12..19 idle bytes (conservative IFG; no deficit-idle counting).
//
// Transmission is decided from registers for the 10GBASE-R word rate. Starting
// a frame loads its payload and padded lengths as word counts and end lanes,
// and each word registers the lane classes of the next, so no length is
// compared per lane. A word's FCS bytes select among its prefix CRCs rather
// than following a CRC carried from lane to lane.
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
  // A padded frame's first FCS byte is in word PaddedWords or earlier.
  localparam int unsigned PaddedWords = ((MAX_FRAME_BYTES > 60) ? MAX_FRAME_BYTES : 60) / 8;
  localparam int unsigned DataWordsWidth = $clog2(PaddedWords);
  localparam logic [63:0] IdleWord = 64'h0707070707070707;
  localparam logic [63:0] StartWord = 64'hd5555555555555fb;

  typedef enum logic [1:0] {
    TX_IDLE,
    TX_DATA,
    TX_GAP
  } tx_state_t;

  // Packet memory is deliberately not reset; buffer_full controls visibility.
  // The synchronous read is prefetched during preamble and each payload word.
  // One array holds both frame buffers, the buffer select as the top address
  // bit, with one write port and one read port behind a muxed address:
  // synthesis infers block RAM for it, where a two-dimensional array of
  // buffers falls back to registers and a second read port to distributed RAM.
  (* ram_style = "block" *) logic [63:0] frame_memory[2 << WordIndexWidth];
  logic [1:0] buffer_full;
  int unsigned frame_length[2];
  logic write_buffer;
  logic read_buffer;
  int unsigned write_length;
  logic write_discard;
  tx_state_t tx_state;
  logic [31:0] tx_crc;
  logic gap_remaining;

  // The frame being transmitted, loaded when it starts; the counts refer to
  // the words after the current one. fetch_word is the next word to fetch.
  // payload_words counts words that still carry payload, the last of them on
  // last_payload_lanes. data_words counts words of payload and padding only;
  // the word after them holds the first FCS byte, on fcs_lane.
  logic [WordIndexWidth-1:0] fetch_word;
  logic [WordIndexWidth-1:0] payload_words;
  logic [7:0] last_payload_lanes;
  logic [DataWordsWidth-1:0] data_words;
  logic [2:0] fcs_lane;
  // Lane classes of the current word. Payload lanes carry payload bytes and
  // control lanes /T/ or idle; other lanes carry padding or FCS. fcs_start is
  // one-hot at 4 plus the lane of the first FCS byte, -4..-1 when the FCS began
  // in the previous word, and zero in a word of payload and padding only. Its
  // bits 0-7 therefore also mark the /T/ lane.
  logic [7:0] payload_lanes;
  logic [7:0] control_lanes;
  logic [11:0] fcs_start;

  int unsigned input_bytes;
  logic bad_beat;
  logic [63:0] payload_word;

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

  // A starting frame's buffer is full, so ingress cannot change its length
  // before its /T/ releases the buffer.
  int unsigned start_length;
  int unsigned start_padded;
  logic [WordIndexWidth-1:0] start_payload_words;
  logic [7:0] start_last_payload_lanes;
  always_comb begin
    start_length = frame_length[read_buffer];
    start_padded = (start_length < 60) ? 60 : start_length;
    start_payload_words = WordIndexWidth'((start_length - 1) >> 3);
    start_last_payload_lanes = 8'hff >> (7 - ((start_length - 1) & 7));
  end

  // prefix_crc[count] is the CRC through the current word's first count lanes,
  // with padding lanes as zero. CRC is linear in seed and data, so each of its
  // bits is the XOR of a fixed selection of {tx_crc, data_word} bits:
  // PrefixMasks[count][bit], found by passing every input bit alone through
  // crc32_byte. Each prefix bit is one flat XOR, not the end of a lane chain.
  function automatic logic [8:0][31:0][95:0] prefix_masks();
    logic [8:0][31:0][95:0] masks;
    logic [95:0][31:0] state;  // CRC so far with only one input bit set
    logic [7:0] lane_byte;
    for (int input_bit = 0; input_bit < 96; input_bit++) begin
      state[input_bit] = (input_bit >= 64) ? 32'h1 << (input_bit - 64) : 32'h0;
    end
    for (int count = 0; count < 9; count++) begin
      for (int crc_bit = 0; crc_bit < 32; crc_bit++) begin
        for (int input_bit = 0; input_bit < 96; input_bit++) begin
          masks[count][crc_bit][input_bit] = state[input_bit][crc_bit];
        end
      end
      for (int input_bit = 0; input_bit < 96; input_bit++) begin
        lane_byte = (input_bit < 64 && input_bit / 8 == count) ? 8'h1 << (input_bit % 8) : 8'h00;
        state[input_bit] = crc32_byte(state[input_bit], lane_byte);
      end
    end
    return masks;
  endfunction
  localparam logic [8:0][31:0][95:0] PrefixMasks = prefix_masks();

  logic [63:0] data_word;
  logic [31:0] prefix_crc[9];
  always_comb begin
    for (int lane = 0; lane < 8; lane++) begin
      data_word[lane*8+:8] = payload_word[lane*8+:8] & {8{payload_lanes[lane]}};
    end
    for (int count = 0; count < 9; count++) begin
      for (int crc_bit = 0; crc_bit < 32; crc_bit++) begin
        prefix_crc[count][crc_bit] = ^({tx_crc, data_word} & PrefixMasks[count][crc_bit]);
      end
    end
  end

  // The lane classes are exclusive, so each lane ORs its selected sources. FCS
  // byte k on a lane is byte k of the complemented CRC over the lanes before
  // the FCS start, prefix_crc[lane - k], or of tx_crc when the FCS began in the
  // previous word. tx_crc follows the payload and padding lanes of each word.
  logic [63:0] next_data;
  logic [31:0] next_crc;
  logic [31:0] fcs;
  logic [3:0] fcs_count;
  logic terminate_word;
  always_comb begin
    for (int lane = 0; lane < 8; lane++) begin
      next_data[lane*8+:8] = data_word[lane*8+:8] |
          ({8{control_lanes[lane]}} & (fcs_start[lane] ? 8'hfd : 8'h07));
      for (int k = 0; k < 4; k++) begin
        fcs_count = (lane > k) ? 4'(lane - k) : 4'd0;
        fcs = ~prefix_crc[fcs_count];
        next_data[lane*8+:8] |= fcs[8*k+:8] & {8{fcs_start[lane-k+4]}};
      end
    end
    next_crc = (prefix_crc[8] & {32{fcs_start == 0}}) | (tx_crc & {32{fcs_start[4:0] != 0}});
    for (int count = 1; count < 8; count++) begin
      next_crc |= prefix_crc[count] & {32{fcs_start[count+4]}};
    end
    terminate_word = fcs_start[7:0] != 0;
  end

  // Lane classes of the next word. An FCS that begins on lanes 4-7 leaves its
  // /T/, and from lane 5 its last bytes, to the next word, where it began eight
  // lanes earlier.
  logic [ 7:0] next_payload_lanes;
  logic [ 7:0] next_control_lanes;
  logic [11:0] next_fcs_start;
  always_comb begin
    if (payload_words > 1) begin
      next_payload_lanes = 8'hff;
    end else if (payload_words == 1) begin
      next_payload_lanes = last_payload_lanes;
    end else begin
      next_payload_lanes = 8'h00;
    end
    if (fcs_start != 0) begin
      next_fcs_start = fcs_start >> 8;
    end else if (data_words != 0) begin
      next_fcs_start = '0;
    end else begin
      next_fcs_start = 12'h010 << fcs_lane;
    end
    for (int lane = 0; lane < 8; lane++) begin
      next_control_lanes[lane] = (next_fcs_start[7:0] & (8'hff >> (7 - lane))) != 0;
    end
  end

  // RAM read port: prefetch word zero while /S/ and preamble are emitted,
  // then fetch each succeeding word one enabled clock before it is needed.
  // No reset on the data register, allowing FPGA block-RAM inference.
  logic read_enable;
  logic [WordIndexWidth:0] read_address;
  always_comb begin
    read_enable  = 1'b0;
    read_address = {read_buffer, WordIndexWidth'(0)};
    if (i_enable) begin
      if (tx_state == TX_IDLE && buffer_full[read_buffer]) begin
        read_enable = 1'b1;
      end else if (tx_state == TX_DATA && payload_words != 0) begin
        read_enable  = 1'b1;
        read_address = {read_buffer, fetch_word};
      end
    end
  end
  always_ff @(posedge i_clk) begin
    if (read_enable) payload_word <= frame_memory[read_address];
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
      tx_crc <= 32'hffffffff;
      gap_remaining <= 0;
      fetch_word <= '0;
      payload_words <= '0;
      last_payload_lanes <= '0;
      data_words <= '0;
      fcs_lane <= '0;
      payload_lanes <= '0;
      control_lanes <= '0;
      fcs_start <= '0;
      o_xgmii_data <= IdleWord;
      o_xgmii_ctrl <= 8'hff;
      o_drop <= 0;
    end else begin
      o_drop <= 0;
      if (i_enable) begin
        if (s_axis_tvalid && s_axis_tready) begin
          if (!write_discard && !bad_beat) begin
            frame_memory[{write_buffer, WordIndexWidth'(write_length>>3)}] <= s_axis_tdata;
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
              tx_crc <= 32'hffffffff;
              fetch_word <= WordIndexWidth'(1);
              payload_words <= start_payload_words;
              last_payload_lanes <= start_last_payload_lanes;
              data_words <= DataWordsWidth'((start_padded >> 3) - 1);
              fcs_lane <= 3'(start_padded);
              payload_lanes <= (start_payload_words != 0) ? 8'hff : start_last_payload_lanes;
              control_lanes <= '0;
              fcs_start <= '0;
              tx_state <= TX_DATA;
            end
          end
          TX_DATA: begin
            o_xgmii_data <= next_data;
            o_xgmii_ctrl <= control_lanes;
            tx_crc <= next_crc;
            fetch_word <= fetch_word + 1'b1;
            if (payload_words != 0) payload_words <= payload_words - 1'b1;
            if (fcs_start == 0 && data_words != 0) data_words <= data_words - 1'b1;
            payload_lanes <= next_payload_lanes;
            control_lanes <= next_control_lanes;
            fcs_start <= next_fcs_start;
            if (terminate_word) begin
              buffer_full[read_buffer] <= 0;
              read_buffer <= !read_buffer;
              // /T/ in lanes 0..3 leaves enough trailing idles that one
              // additional word gives >=12 idles. Later lanes need two.
              gap_remaining <= fcs_start[7:4] != 0;
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
