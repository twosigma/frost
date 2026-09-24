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
// when i_enable is low; causes within one word share one pulse. Error drops
// roll back speculative buffer allocation.
//
// The logic is staged for the 10GBASE-R word rate. A decode stage registers
// each enabled word with its symbol classes and CRC contributions. The word
// stage then decides the whole word from registers: every lane's candidate
// event is computed in parallel and the first one selects the outcome, so no
// count, CRC or free-space value is carried from lane to lane. A reader copies
// published beats into a two-entry output register, and only that register
// sees m_axis_tready. Observable consequences:
// - Events for an XGMII word, and publication of a packet it completes, are
//   registered on the clock after the word is sampled. The packet's first
//   beat reaches m_axis_* at least one clock after publication.
// - Storage and descriptors freed by an output handshake serve words sampled
//   on later clocks; a word sampled on the handshake's own clock still finds
//   them occupied. Capacity is otherwise unchanged.
// - An /S/ in the same word as a /T/ that ends a frame is ignored. No Clause 49
//   block carries both. An /S/ on lane 4 after other control in lanes 0-3 has
//   dropped a frame still starts one.
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
  localparam logic [31:0] CrcResidue = 32'hdebb20e3;

  // CRC state after `count` zero bytes, for count <= 8. A CRC over a run of
  // bytes is linear in its seed: crc32(seed, run) = crc32_advance(seed, n) ^
  // crc32(0, run) for an n-byte run. Every call below has a constant count, so
  // each result bit is an XOR of at most 19 seed bits.
  function automatic logic [31:0] crc32_advance(input logic [31:0] seed, input int unsigned count);
    logic [31:0] value;
    value = seed;
    for (int step = 0; step < 8; step++) begin
      if (step < count) value = crc32_byte(value, 8'h00);
    end
    return value;
  endfunction

  // ---- Decode stage ----------------------------------------------------------------------
  // decode_crc_check[n] is crc32(0, lanes 0..n-1) ^ residue: a frame whose /T/
  // is on lane n of a frame word has a good FCS exactly when
  // crc32_advance(crc, n) == decode_crc_check[n]. Each prefix is an XOR of
  // independent per-lane contributions.
  logic decode_valid;
  logic [63:0] decode_data;
  logic [7:0] decode_control, decode_terminate, decode_preamble;
  logic [1:0] decode_start;  // legal /S/: [0] on lane 0, [1] on lane 4
  logic [1:0] decode_sfd;  // 0xd5 data: [0] on lane 3, [1] on lane 7
  logic [31:0] decode_crc_check[8];
  logic [31:0] decode_crc_word;  // crc32(0, lanes 0-7)
  logic [31:0] decode_crc_upper;  // crc32(all ones, lanes 4-7)

  logic [31:0] lane_crc[8];
  logic [31:0] prefix_crc[9];
  logic [31:0] upper_crc;
  always_comb begin
    for (int lane = 0; lane < 8; lane++) begin
      lane_crc[lane] = crc32_byte(32'h0, i_xgmii_data[lane*8+:8]);
    end
    for (int count = 0; count < 9; count++) begin
      prefix_crc[count] = '0;
      for (int lane = 0; lane < count; lane++) begin
        prefix_crc[count] ^= crc32_advance(lane_crc[lane], count - 1 - lane);
      end
    end
    upper_crc = crc32_advance(32'hffffffff, 4);
    for (int lane = 4; lane < 8; lane++) begin
      upper_crc ^= crc32_advance(lane_crc[lane], 7 - lane);
    end
  end

  always_ff @(posedge i_clk) begin
    decode_valid <= !i_rst && i_enable;
    decode_data <= i_xgmii_data;
    decode_control <= i_xgmii_ctrl;
    for (int lane = 0; lane < 8; lane++) begin
      decode_terminate[lane] <= i_xgmii_ctrl[lane] && i_xgmii_data[lane*8+:8] == 8'hfd;
      decode_preamble[lane]  <= !i_xgmii_ctrl[lane] && i_xgmii_data[lane*8+:8] == 8'h55;
      decode_crc_check[lane] <= prefix_crc[lane] ^ CrcResidue;
    end
    decode_start[0] <= i_xgmii_ctrl[0] && i_xgmii_data[7:0] == 8'hfb;
    decode_start[1] <= i_xgmii_ctrl[4] && i_xgmii_data[39:32] == 8'hfb;
    decode_sfd[0] <= !i_xgmii_ctrl[3] && i_xgmii_data[31:24] == 8'hd5;
    decode_sfd[1] <= !i_xgmii_ctrl[7] && i_xgmii_data[63:56] == 8'hd5;
    decode_crc_word <= prefix_crc[8];
    decode_crc_upper <= upper_crc;
  end

  // ---- Word stage state ------------------------------------------------------------------
  // PREAMBLE at a word boundary always follows an /S/ on lane 4 with three
  // preamble bytes seen: /S/ on lane 0 completes or fails its preamble within
  // its own word. A frame word begins at byte_count % 8 == 0 for /S/ on lane 0
  // and at 4 for lane 4, so byte_count[2] is the frame's storage rotation.
  // IDLE also covers a discarded frame: both wait for a legal /S/ only.
  typedef enum logic [1:0] {
    IDLE,
    PREAMBLE,
    FRAME
  } state_t;
  state_t state, next_state;
  logic [CountWidth-1:0] byte_count, next_byte_count;
  logic [31:0] crc, next_crc;
  // byte_count + lane >= MAX_FRAME_BYTES + 4 for each lane of the next frame
  // word, maintained with byte_count.
  logic [7:0] frame_overlength, next_frame_overlength;
  // write_word is the current frame's first word and next_word follows its
  // last reserved word. Storage lanes 0-3 of a frame word always land in
  // next_word, and so do lanes 4-7 unless the frame is rotated, when they
  // complete previous_word (next_word - 1, set by the reservation that
  // claimed it).
  logic [MemoryAddrWidth-1:0] write_word, next_write_word;
  logic [MemoryAddrWidth-1:0] next_word, next_next_word;
  logic [MemoryAddrWidth-1:0] previous_word, next_previous_word;
  // rollback_free_words is free_words plus the words reserved by the frame in
  // progress: the free count a drop restores, and the count a legal /S/ is
  // admitted against. Keeping both counts avoids adding them per word. The
  // empty flags are maintained with their counters so admission and
  // reservation decisions start from flops.
  logic [MemoryAddrWidth:0] free_words, next_free_words;
  logic [MemoryAddrWidth:0] rollback_free_words, next_rollback_free_words;
  logic free_empty, next_free_empty;
  logic rollback_free_empty, next_rollback_free_empty;
  logic descriptors_full, next_descriptors_full;
  logic [DescriptorAddrWidth-1:0] descriptor_write;
  // descriptor_count counts published packets whose final beat has not been
  // consumed at the output, and gates admission; descriptor_avail counts those
  // the reader has not finished copying, and drives the reader.
  logic [DescriptorAddrWidth:0] descriptor_count, next_descriptor_count;
  logic [DescriptorAddrWidth:0] descriptor_avail, next_descriptor_avail;
  logic bad_frame_event, bad_fcs_event, overflow_event;

  logic [CountWidth-1:0] packet_length[DescriptorSlots];
  logic descriptor_write_enable;
  logic [CountWidth-1:0] descriptor_write_length;

  // Output handshake credit, applied by the word stage one clock later:
  // credit_words is 0, 1 or 2 and released marks a consumed final beat.
  logic [1:0] credit_words;
  logic released;

  // ---- Word stage: per-lane candidates ----------------------------------------------------
  // A frame word carries frame byte byte_count + lane on each lane until its
  // first event: a control byte (legal /S/ on lane 4, /T/, or any other), a
  // data byte beyond MAX_FRAME_BYTES plus FCS, or the byte that must reserve a
  // new storage word while none is free. Overlength outranks no-space on the
  // same byte. A /T/ decides length and CRC over exactly the bytes before it,
  // with no space check.
  logic [7:0] frame_event, frame_first, frame_data;
  logic [7:0] frame_long_enough, frame_fcs_counted, frame_crc_ok;
  logic [CountWidth-1:0] frame_length[8];
  always_comb begin
    for (int lane = 0; lane < 8; lane++) begin
      frame_event[lane] = decode_control[lane] || frame_overlength[lane] ||
          (free_empty && lane == (byte_count[2] ? 4 : 0));
      frame_long_enough[lane] = int'(byte_count) + lane >= 64;
      frame_fcs_counted[lane] = int'(byte_count) + lane >= 4;
      frame_crc_ok[lane] = crc32_advance(crc, lane) == decode_crc_check[lane];
      frame_length[lane] = byte_count + CountWidth'(lane) - CountWidth'(4);
    end
    for (int lane = 0; lane < 8; lane++) begin
      // Masks select the lanes before this one and through this one.
      frame_first[lane] = frame_event[lane] && (frame_event & ~(8'hff << lane)) == 8'h0;
      frame_data[lane]  = (frame_event & (8'hff >> (7 - lane))) == 8'h0;
    end
  end

  // Outcomes of a frame word, each selected by its first event.
  logic frame_continue, frame_commit, frame_fcs_error, frame_no_space;
  logic frame_terminated_early, frame_took_word;
  // A PREAMBLE word ends the preamble on lanes 0-3 (55 55 55 d5) and carries the
  // frame's first four bytes on lanes 4-7, where the storage word is claimed on
  // lane 4. No overlength or CRC decision is possible in those four bytes.
  logic sfd_match, upper_continue, upper_no_space;
  logic [3:0] upper_event, upper_data;  // bit k: lane 4 + k
  logic lower_preamble, tail_preamble;
  always_comb begin
    frame_continue = frame_event == 0;
    frame_commit = |(frame_first & decode_terminate & frame_long_enough & frame_crc_ok);
    frame_fcs_error = |(frame_first & decode_terminate & frame_fcs_counted & ~frame_crc_ok);
    frame_no_space = |(frame_first & ~decode_control & ~frame_overlength);
    frame_terminated_early = |(frame_first[3:0] & decode_terminate[3:0]);
    // The reservation byte is lane 0, or lane 4 for a rotated frame.
    frame_took_word = byte_count[2] ? frame_event[4:0] == 0 : !frame_event[0];

    sfd_match = decode_preamble[2:0] == 3'b111 && decode_sfd[0];
    upper_event = {decode_control[7:5], decode_control[4] || free_empty};
    for (int k = 0; k < 4; k++) begin
      upper_data[k] = sfd_match && (upper_event & ~(4'hf << (k + 1))) == 4'h0;
    end
    upper_continue = sfd_match && upper_event == 4'h0;
    upper_no_space = sfd_match && !decode_control[4] && free_empty;

    // /S/ on lane 0 completes its preamble on lanes 1-7; /S/ on lane 4 starts
    // one on lanes 5-7.
    lower_preamble = decode_preamble[6:1] == 6'h3f && decode_sfd[1];
    tail_preamble  = decode_preamble[7:5] == 3'b111;
  end

  // ---- Word stage: selection -------------------------------------------------------------
  // A legal /S/ always restarts: it reports the frame or preamble it abandons,
  // and returns that frame's reserved words, including any reserved earlier in
  // the same word. Its admission therefore always sees rollback_free_words at
  // the word boundary; the /S/ on lane 4 that could have seen a same-word
  // commit is the ignored one.
  logic start_lower, start_upper, in_frame, in_preamble;
  logic admit, commit, rollback, take_word, credit_none;
  logic [MemoryAddrWidth:0] free_credited, rollback_credited;
  always_comb begin
    start_lower = decode_valid && decode_start[0];
    in_frame = decode_valid && !decode_start[0] && state == FRAME;
    in_preamble = decode_valid && !decode_start[0] && state == PREAMBLE;
    start_upper = decode_valid && decode_start[1] && !(in_frame && frame_terminated_early);
    admit = !rollback_free_empty && !descriptors_full;
    commit = in_frame && frame_commit;
    // Every frame outcome other than continuing or committing returns the
    // frame's words. Outside FRAME no words are reserved.
    rollback = start_lower || (in_frame && !frame_continue && !frame_commit);
    take_word = (in_preamble && upper_continue) ||
        (in_frame && frame_took_word && (frame_continue || frame_commit));

    next_state = state;
    if (start_upper) next_state = admit && tail_preamble ? PREAMBLE : IDLE;
    else if (start_lower) next_state = admit && lower_preamble ? FRAME : IDLE;
    else if (in_frame) next_state = frame_continue ? FRAME : IDLE;
    else if (in_preamble) next_state = upper_continue ? FRAME : IDLE;

    bad_frame_event = (start_lower && (state != IDLE || !admit || decode_start[1] ||
                                       !lower_preamble)) ||
        (start_upper && (!admit || !tail_preamble)) || (in_preamble && !upper_continue) ||
        (in_frame && !frame_continue && !frame_commit);
    bad_fcs_event = in_frame && frame_fcs_error;
    overflow_event = ((start_lower || start_upper) && !admit) ||
        (in_preamble && upper_no_space) || (in_frame && frame_no_space);

    next_byte_count = byte_count;
    next_crc = crc;
    next_frame_overlength = frame_overlength;
    if (in_frame && frame_continue) begin
      next_byte_count = byte_count + CountWidth'(8);
      next_crc = crc32_advance(crc, 8) ^ decode_crc_word;
      for (int lane = 0; lane < 8; lane++) begin
        next_frame_overlength[lane] = int'(byte_count) >= int'(MAX_FRAME_BYTES) - 4 - lane;
      end
    end else if (in_preamble && upper_continue) begin
      // The first frame word after /S/ on lane 4 begins at byte 4. With the
      // MAC's minimum MAX_FRAME_BYTES of 60, no lane of it is overlength.
      next_byte_count = CountWidth'(4);
      next_crc = decode_crc_upper;
      next_frame_overlength = '0;
    end else if (decode_valid) begin
      next_byte_count = '0;
      next_crc = 32'hffffffff;
      next_frame_overlength = '0;
    end

    // Every count's candidates are registers plus small constants, computed
    // in parallel; the word's outcome only selects among them. A take happens
    // only when free_words is nonzero.
    credit_none = credit_words == 2'd0;
    free_credited = free_words + (MemoryAddrWidth + 1)'(credit_words);
    rollback_credited = rollback_free_words + (MemoryAddrWidth + 1)'(credit_words);
    if (rollback) begin
      next_free_words = rollback_credited;
      next_free_empty = rollback_free_empty && credit_none;
    end else if (take_word) begin
      next_free_words = free_credited - 1'b1;
      next_free_empty = free_words == 1 && credit_none;
    end else begin
      next_free_words = free_credited;
      next_free_empty = free_empty && credit_none;
    end
    // A commit releases the frame's reservation; otherwise the rollback count
    // changes only by credit (a take moves a word from free to reserved).
    if (commit) begin
      next_rollback_free_words = next_free_words;
      next_rollback_free_empty = next_free_empty;
    end else begin
      next_rollback_free_words = rollback_credited;
      next_rollback_free_empty = rollback_free_empty && credit_none;
    end
    next_write_word = write_word;
    next_next_word = next_word;
    next_previous_word = previous_word;
    if (rollback) begin
      next_next_word = write_word;
    end else if (take_word) begin
      next_next_word = next_word + 1'b1;
      next_previous_word = next_word;
    end
    if (commit) next_write_word = take_word ? next_word + 1'b1 : next_word;

    descriptor_write_enable = commit;
    // frame_first is one-hot when anything is written, so OR its selections.
    descriptor_write_length = '0;
    for (int lane = 0; lane < 8; lane++) begin
      descriptor_write_length |= frame_length[lane] & {CountWidth{frame_first[lane]}};
    end
    next_descriptor_count = descriptor_count;
    next_descriptors_full = descriptors_full;
    if (commit && !released) begin
      next_descriptor_count = descriptor_count + 1'b1;
      next_descriptors_full = int'(descriptor_count) == DescriptorSlots - 1;
    end else if (!commit && released) begin
      next_descriptor_count = descriptor_count - 1'b1;
      next_descriptors_full = 1'b0;
    end
  end

  // ---- Lane memories ---------------------------------------------------------------------
  // Each of the eight byte lanes is one simple dual-port memory: a write port
  // and a synchronous read port, so FPGA synthesis infers block RAM. Storage
  // lane k holds frame bytes whose offset is k mod 8; a rotated frame writes
  // storage lane k from XGMII lane k + 4 mod 8.
  //
  // The read port samples next_read_word on every clock, and the reader copies
  // read_data only for a published packet. A packet is published on or after
  // the edge that writes its last bytes, and its words are never written again
  // until the output handshake has consumed them, so every copied word was
  // fetched after its final write. Its first word completes at least seven
  // word-stage edges before publication, since every accepted frame spans at
  // least eight words. Fetches while nothing is published may collide with
  // writes; the reader does not copy them, and the fetch repeats every clock.
  // The simulation check at the end of the file reports any violation.
  logic [7:0] memory_write_enable;
  logic [7:0] memory_write_data[8];
  logic [MemoryAddrWidth-1:0] memory_write_address[8];
  logic [MemoryAddrWidth-1:0] read_word, next_read_word;
  logic [7:0] read_data[8];
  logic [63:0] stored_data;
  always_comb begin
    // A PREAMBLE word stores lanes 4-7, the frame's first four bytes, in
    // storage lanes 0-3; so does every later word of that rotated frame.
    memory_write_enable = '0;
    if (in_frame) begin
      memory_write_enable = byte_count[2] ? {frame_data[3:0], frame_data[7:4]} : frame_data;
    end else if (in_preamble) begin
      memory_write_enable = {4'h0, upper_data};
    end
    stored_data = state == PREAMBLE || byte_count[2] ? {decode_data[31:0], decode_data[63:32]} :
        decode_data;
    for (int lane = 0; lane < 8; lane++) begin
      memory_write_data[lane] = stored_data[lane*8+:8];
      memory_write_address[lane] = lane >= 4 && byte_count[2] ? previous_word : next_word;
    end
  end

  // ---- Reader ----------------------------------------------------------------------------
  // The reader copies the published beat at read_word into the output register
  // whenever that register has room. A packet of length L occupies ceil((L +
  // 4) / 8) words from a word-aligned start: one per beat plus an extra FCS-only
  // word when L mod 8 is 0 or above 4. The reader skips that extra word after
  // the final beat, and the beat carries it as credit.
  //
  // read_beat never passes the final beat, whose index is L / 8 rounded down,
  // less one when L mod 8 is 0. Finding the final beat is therefore an equality
  // with the stored length, and only that beat keeps fewer than eight bytes.
  logic [DescriptorAddrWidth-1:0] descriptor_read;
  logic [CountWidth-4:0] read_beat, read_beat_next;
  logic [CountWidth-1:0] read_length;
  logic reader_capture, reader_last, reader_extra;
  logic [63:0] reader_data;
  logic [7:0] reader_keep, final_keep;
  logic [1:0] skid_valid;  // [0] drives m_axis_*; [1] holds a second beat
  always_comb begin
    read_length = packet_length[descriptor_read];
    reader_capture = descriptor_avail != 0 && !skid_valid[1];
    read_beat_next = read_beat + 1'b1;
    if (read_length[2:0] == 3'd0) begin
      reader_last = read_length[CountWidth-1:3] == read_beat_next;
      final_keep  = 8'hff;
    end else begin
      reader_last = read_length[CountWidth-1:3] == read_beat;
      final_keep  = ~(8'hff << read_length[2:0]);
    end
    reader_extra = read_length[2:0] == 3'd0 || read_length[2:0] > 3'd4;
    reader_keep  = reader_last ? final_keep : 8'hff;
    for (int lane = 0; lane < 8; lane++) begin
      reader_data[lane*8+:8] = reader_keep[lane] ? read_data[lane] : 8'h00;
    end
    // Both advances are computed from the register; the beat only selects.
    next_read_word = read_word;
    if (reader_capture && reader_last && reader_extra) begin
      next_read_word = read_word + MemoryAddrWidth'(2);
    end else if (reader_capture) begin
      next_read_word = read_word + 1'b1;
    end
    next_descriptor_avail = descriptor_avail;
    if (commit && !(reader_capture && reader_last)) begin
      next_descriptor_avail = descriptor_avail + 1'b1;
    end else if (!commit && reader_capture && reader_last) begin
      next_descriptor_avail = descriptor_avail - 1'b1;
    end
  end

  // ---- Output register ---------------------------------------------------------------------
  // Two entries: the first drives the AXI Stream output and changes only when
  // empty or accepted, so data, keep and last hold while stalled. The reader
  // fills whichever entry is free and stops when both are full, without looking
  // at m_axis_tready. Each entry carries its storage credit to the handshake.
  logic [63:0] skid_data[2];
  logic [ 7:0] skid_keep[2];
  logic [1:0] skid_last, skid_extra;
  logic output_handshake;
  assign output_handshake = skid_valid[0] && m_axis_tready;
  assign m_axis_tvalid = skid_valid[0];
  assign m_axis_tdata = skid_data[0];
  assign m_axis_tkeep = skid_keep[0];
  assign m_axis_tlast = skid_last[0];
  assign m_axis_tuser = 1'b0;

  always_ff @(posedge i_clk) begin
    if (!skid_valid[0] || output_handshake) begin
      if (skid_valid[1]) begin
        skid_data[0]  <= skid_data[1];
        skid_keep[0]  <= skid_keep[1];
        skid_last[0]  <= skid_last[1];
        skid_extra[0] <= skid_extra[1];
      end else begin
        skid_data[0]  <= reader_data;
        skid_keep[0]  <= reader_keep;
        skid_last[0]  <= reader_last;
        skid_extra[0] <= reader_last && reader_extra;
      end
    end
    if (reader_capture) begin
      skid_data[1]  <= reader_data;
      skid_keep[1]  <= reader_keep;
      skid_last[1]  <= reader_last;
      skid_extra[1] <= reader_last && reader_extra;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state <= IDLE;
      byte_count <= '0;
      crc <= 32'hffffffff;
      write_word <= '0;
      next_word <= '0;
      previous_word <= '0;
      frame_overlength <= '0;
      free_words <= (MemoryAddrWidth + 1)'(MemoryWords);
      free_empty <= 1'b0;
      rollback_free_words <= (MemoryAddrWidth + 1)'(MemoryWords);
      rollback_free_empty <= 1'b0;
      descriptor_write <= '0;
      descriptor_count <= '0;
      descriptors_full <= 1'b0;
      descriptor_avail <= '0;
      descriptor_read <= '0;
      read_word <= '0;
      read_beat <= '0;
      skid_valid <= '0;
      credit_words <= '0;
      released <= 1'b0;
      o_bad_frame <= 1'b0;
      o_bad_fcs <= 1'b0;
      o_overflow <= 1'b0;
    end else begin
      state <= next_state;
      byte_count <= next_byte_count;
      crc <= next_crc;
      write_word <= next_write_word;
      next_word <= next_next_word;
      previous_word <= next_previous_word;
      frame_overlength <= next_frame_overlength;
      free_words <= next_free_words;
      free_empty <= next_free_empty;
      rollback_free_words <= next_rollback_free_words;
      rollback_free_empty <= next_rollback_free_empty;
      if (commit) descriptor_write <= descriptor_write + 1'b1;
      descriptor_count <= next_descriptor_count;
      descriptors_full <= next_descriptors_full;
      descriptor_avail <= next_descriptor_avail;
      read_word <= next_read_word;
      if (reader_capture) read_beat <= reader_last ? '0 : read_beat_next;
      if (reader_capture && reader_last) descriptor_read <= descriptor_read + 1'b1;
      if (!skid_valid[0] || output_handshake) skid_valid <= {1'b0, skid_valid[1] || reader_capture};
      else if (reader_capture) skid_valid[1] <= 1'b1;
      credit_words <= output_handshake ? (skid_extra[0] ? 2'd2 : 2'd1) : 2'd0;
      released <= output_handshake && skid_last[0];
      o_bad_frame <= bad_frame_event;
      o_bad_fcs <= bad_fcs_event;
      o_overflow <= overflow_event;
    end
  end

  // Memory contents are not reset, so synthesis can infer FPGA RAM; the reset
  // descriptor counts hide stale data.
  always_ff @(posedge i_clk) begin
    if (!i_rst && descriptor_write_enable) begin
      packet_length[descriptor_write] <= descriptor_write_length;
    end
  end
  for (genvar lane = 0; lane < 8; lane++) begin : g_memory_lane
    (* ram_style = "block" *) logic [7:0] packet_memory[MemoryWords];
    always_ff @(posedge i_clk) begin
      if (!i_rst && memory_write_enable[lane])
        packet_memory[memory_write_address[lane]] <= memory_write_data[lane];
      read_data[lane] <= packet_memory[next_read_word];
    end
  end

`ifndef SYNTHESIS
  // Read-during-write check for the lane memories. The lanes are simple
  // dual-port RAMs with no read-during-write guarantee, which is legal only
  // because the reader never copies a word fetched on the edge that wrote it
  // (see the argument above the lane declarations). A fetch on the same edge
  // as a write to its address is recorded, and copying the beat that fetch
  // produced is an error. A beat already copied into the output register is
  // unaffected by later fetches, so a stalled output beat does not count; a
  // collision while nothing is published is harmless, since that fetch
  // repeats every clock before a packet becomes visible.
  logic fetch_write_collision;
  always_comb begin
    fetch_write_collision = 1'b0;
    for (int lane = 0; lane < 8; lane++) begin
      if (memory_write_enable[lane] && (memory_write_address[lane] == next_read_word))
        fetch_write_collision = 1'b1;
    end
  end

  logic fetched_word_was_written;
  always_ff @(posedge i_clk) begin
    if (i_rst) fetched_word_was_written <= 1'b0;
    else fetched_word_was_written <= fetch_write_collision;
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst && reader_capture && fetched_word_was_written)
      $error("eth10g_mac_rx: word %0d was written on the edge that fetched it", read_word);
  end

  // The output register must hold a stalled beat unchanged.
  logic stalled;
  logic [72:0] stalled_beat;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      stalled <= 1'b0;
    end else begin
      if (stalled && !(m_axis_tvalid && {m_axis_tlast, m_axis_tkeep, m_axis_tdata} == stalled_beat))
        $error("eth10g_mac_rx: AXI Stream output changed while stalled");
      stalled <= m_axis_tvalid && !m_axis_tready;
      stalled_beat <= {m_axis_tlast, m_axis_tkeep, m_axis_tdata};
    end
  end
`endif
endmodule : eth10g_mac_rx
