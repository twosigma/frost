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
//
// /S/ always occupies lane zero; short packets are padded to 60 bytes, followed
// by little-endian Ethernet FCS. One or two complete idle words follow /T/,
// providing 12..19 idle bytes (conservative IFG; no deficit-idle counting).
//
// Frame start records payload and padded lengths as word counts and end lanes.
// Each word registers the next word's lane classes. FCS bytes select the CRC
// prefix ending at the first FCS lane.
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

    // Transmit checksum offload, off when i_csum_en is zero. Sampled with a
    // frame's first accepted beat. The 16-bit ones-complement sum of the frame
    // from byte i_csum_start to its end replaces the two bytes at byte
    // i_csum_start + i_csum_offset, as for Linux CHECKSUM_PARTIAL: the field
    // holds the pseudo-header sum on entry and is part of the sum. Both byte
    // values must be even, the offset nonzero, and the field inside the frame;
    // otherwise the frame goes out unchanged.
    input logic       i_csum_en,
    input logic [7:0] i_csum_start,
    input logic [7:0] i_csum_offset,

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

  // buffer_full hides uninitialized memory. The frame RAM uses buffer select
  // as its top address bit and prefetches during preamble and payload.
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

  // The MAC bench checks that no beat is taken in reset.
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

  // ---- transmit checksum offload ------------------------------------------------------
  // Ingress adds the frame's 16-bit words (first byte high) from the start byte
  // on, four per beat. A finished frame keeps its sum and field position with
  // its buffer; the read side patches the two field bytes into the word before
  // the CRC sees it, so the FCS covers the new bytes. A zero result goes out as
  // 0xffff, which is the same ones-complement value and is also valid for UDP.
  logic csum_en_q;  // the frame being written
  logic [7:0] csum_start_q;
  logic [7:0] csum_offset_q;
  logic [15:0] csum_acc_q;
  logic csum_valid_q[2];  // per frame buffer
  logic [15:0] csum_value_q[2];
  logic [8:0] csum_pos_q[2];  // field byte position, start + offset

  // The beat's sum is registered before it joins the accumulator, which takes
  // the fold off the path from write_length. A frame's value reaches
  // csum_value_q one cycle after its tlast beat; the read side first uses it
  // one cycle after that, when buffer_full has started the frame and word 0
  // is on its way out.
  logic stage_beat_q;  // a beat was accepted last cycle
  logic stage_stored_q;  // ... and went into the frame RAM
  logic stage_last_q;  // ... and ended the frame
  logic stage_buffer_q;  // frame buffer of that beat
  logic [19:0] stage_sum_q;
  logic stage_valid_q;
  logic [8:0] stage_pos_q;

  logic stored_beat;  // a beat that goes into the frame RAM
  logic first_beat;
  logic eff_en;
  logic [7:0] eff_start;
  logic [7:0] eff_offset;
  logic [8:0] field_pos;
  logic [19:0] beat_sum;
  logic [19:0] total_sum;
  logic [16:0] fold_one;
  logic [15:0] fold_two;
  logic [15:0] csum_final;
  assign stored_beat = i_enable && s_axis_tvalid && s_axis_tready && !write_discard && !bad_beat;
  assign first_beat  = (write_length == 0);
  assign eff_en      = first_beat ? i_csum_en : csum_en_q;
  assign eff_start   = first_beat ? i_csum_start : csum_start_q;
  assign eff_offset  = first_beat ? i_csum_offset : csum_offset_q;
  assign field_pos   = {1'b0, eff_start} + {1'b0, eff_offset};
  always_comb begin
    beat_sum = 20'd0;
    for (int w = 0; w < 4; w++) begin
      logic [7:0] hi, lo;
      hi = s_axis_tkeep[2*w] ? s_axis_tdata[(2*w)*8+:8] : 8'h00;
      lo = s_axis_tkeep[2*w+1] ? s_axis_tdata[(2*w+1)*8+:8] : 8'h00;
      if (eff_en && (write_length + 2 * w) >= int'(eff_start)) beat_sum += {4'b0, hi, lo};
    end
    total_sum  = {4'b0, csum_acc_q} + stage_sum_q;
    fold_one   = {1'b0, total_sum[15:0]} + {13'b0, total_sum[19:16]};
    fold_two   = fold_one[15:0] + {15'b0, fold_one[16]};
    csum_final = (fold_two == 16'hffff) ? 16'hffff : ~fold_two;
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      csum_en_q <= 0;
      csum_start_q <= 0;
      csum_offset_q <= 0;
      csum_acc_q <= 0;
      csum_valid_q[0] <= 0;
      csum_valid_q[1] <= 0;
      csum_value_q[0] <= 0;
      csum_value_q[1] <= 0;
      csum_pos_q[0] <= 0;
      csum_pos_q[1] <= 0;
      stage_beat_q <= 0;
      stage_stored_q <= 0;
      stage_last_q <= 0;
      stage_buffer_q <= 0;
      stage_sum_q <= 0;
      stage_valid_q <= 0;
      stage_pos_q <= 0;
    end else begin
      stage_beat_q <= i_enable && s_axis_tvalid && s_axis_tready;
      stage_stored_q <= stored_beat;
      stage_last_q <= s_axis_tlast;
      stage_buffer_q <= write_buffer;
      stage_sum_q <= beat_sum;
      stage_valid_q <= eff_en && (eff_offset != 0) && !field_pos[0] && !eff_start[0] &&
          (int'(field_pos) + 2 <= write_length + input_bytes);
      stage_pos_q <= field_pos;
      if (stored_beat && first_beat) begin
        csum_en_q     <= i_csum_en;
        csum_start_q  <= i_csum_start;
        csum_offset_q <= i_csum_offset;
      end
      if (stage_beat_q) begin
        if (stage_stored_q) csum_acc_q <= fold_two;
        if (stage_last_q) begin
          csum_acc_q <= 0;
          if (stage_stored_q) begin
            csum_valid_q[stage_buffer_q] <= stage_valid_q;
            csum_value_q[stage_buffer_q] <= csum_final;
            csum_pos_q[stage_buffer_q]   <= stage_pos_q;
          end
        end
      end
    end
  end

  // The word being sent is word fetch_word - 1 (word 0 is prefetched while /S/
  // goes out). The field is even-aligned, so it never splits across two words.
  logic [WordIndexWidth-1:0] current_word;
  logic                      patch_hit;
  logic [              63:0] patched_word;
  logic [               2:0] patch_lane;
  assign current_word = fetch_word - 1'b1;
  assign patch_lane = csum_pos_q[read_buffer][2:0];
  assign patch_hit    = (tx_state == TX_DATA) && csum_valid_q[read_buffer] &&
      (current_word == WordIndexWidth'(csum_pos_q[read_buffer][8:3]));
  always_comb begin
    patched_word = payload_word;
    if (patch_hit) begin
      patched_word[patch_lane*8+:8] = csum_value_q[read_buffer][15:8];
      patched_word[(patch_lane+3'd1)*8+:8] = csum_value_q[read_buffer][7:0];
    end
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

  // prefix_crc[count] covers the first count lanes, with zero padding.
  // CRC linearity lets each result bit XOR a fixed subset of {tx_crc,
  // data_word}. PrefixMasks finds those subsets by applying crc32_byte to
  // each input bit separately.
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
      data_word[lane*8+:8] = patched_word[lane*8+:8] & {8{payload_lanes[lane]}};
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
  sdp_block_ram_dc_init #(
      .ADDR_WIDTH(WordIndexWidth + 1),
      .DATA_WIDTH(64)
  ) u_frame_memory (
      .i_write_clock(i_clk),
      // The frame memory has no reset.
      .i_write_enable(!i_rst && i_enable && s_axis_tvalid && s_axis_tready && !write_discard &&
                      !bad_beat),
      .i_write_address({write_buffer, WordIndexWidth'(write_length >> 3)}),
      .i_write_data(s_axis_tdata),
      .i_read_clock(i_clk),
      .i_read_enable(read_enable),
      .i_read_address(read_address),
      .o_read_data(payload_word)
  );

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
