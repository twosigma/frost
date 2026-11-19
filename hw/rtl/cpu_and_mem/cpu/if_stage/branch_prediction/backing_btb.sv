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

/*
 * Backing BTB: a set-associative second level behind the fast direct-mapped
 * BTB, 1024 entries in two ways by default (four ways for measurement). It
 * holds jumps: IF trains it with the BTB updates of JALs and JALRs, and
 * looks it up for the packet IF serves. PD turns a hit on a JAL or JALR that
 * fast prediction did not take into a PD redirect, with the return address
 * stack operation that the instruction's own encoding names, and refreshes
 * the entry that served it (hw/rtl/cpu_and_mem/cpu/README.md, "Backing
 * BTB").
 *
 * Sets are indexed by PC word bits, like the fast BTB. An entry's tag holds
 * the PC bits above the index and PC[1], with the size and return type; its
 * payload holds the target. The target keeps its low TARGET_BITS bits; the
 * upper bits come from the jump's PC, and training with a target in another
 * region invalidates the entry, as in the fast BTB.
 *
 * Lookup. The caller supplies the set index of the fetch PC register. The
 * tag arrays read it without a clock and register the tags; the payload
 * arrays read it on the clock edge. In the next cycle IF serves the window
 * of that fetch, normally at i_packet_pc, and the registered tags are
 * compared with the packet's PC, so the hit, size and return type come from
 * registers and only the target from the payload arrays. Each lookup reads
 * two sets: the packet's word and the word after it, for a slot 2 there.
 * The second image of each array stores set S at row S-1, so both read at
 * the same index. A packet whose set is not the one read gets no hit, and
 * neither does a slot 2 in the word after the last set, which belongs to
 * the next block of sets.
 *
 * Shifted read. When the read's set is the one before the packet's word (the
 * fetch PC at a halfword of the word before the window IF then serves, common
 * in compressed code), the second image holds the packet word's set: slot 1,
 * and a slot 2 in the same word, are served from it.
 *
 * Held read. The response also keeps the last read whose set was the one of
 * the packet IF served in its response cycle, or the one before it: its tags and targets, and its
 * set index. When the newest read is for another set and the held one is for
 * the packet's set, the held read answers, compared with the packet's PC like
 * the newest. A packet that IF serves only after a holdoff, while the fetch
 * PC has already moved on to the next window, then keeps the hit it had in
 * its first cycle. A held read can be older than training writes made since;
 * an entry it still shows costs at most a misprediction, which execution
 * corrects like any wrong prediction.
 *
 * Training. An update registers and reads its set from a third payload
 * array that also holds the tags, valid bits and replacement state; the
 * next stage finds its way and registers it, and the last writes the whole
 * set into every array. A hit rewrites its way and a miss replaces an
 * invalid way or the way the replacement state names; replacement then
 * points away from the written way. A refresh takes the same stages when no
 * update arrives: a hit writes the set back with replacement pointing away
 * from the hit way, and a miss writes nothing. A request to the set written
 * on the edge it reads takes the written set instead, and one to the set
 * that the update a stage ahead writes is dropped; a refresh a stage ahead
 * drops nothing, so only its replacement change can be lost. Lookups and
 * training share no state across an edge: a lookup reads the arrays as they
 * were before that edge's write.
 *
 * Reset clears one set per cycle, all sets in 2**IndexBits cycles. Lookups
 * read while clearing miss, and updates arriving then are dropped.
 */
module backing_btb #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned ENTRIES = riscv_pkg::BackingBtbEntries,
    parameter int unsigned WAYS = riscv_pkg::BackingBtbWays,
    parameter int unsigned TARGET_BITS = riscv_pkg::PhysAddrBits
) (
    input logic i_clk,
    input logic i_reset,
    input logic i_redirect, // The fetch request before this edge is discarded.

    // Lookup: the set of the fetch PC register's word. The response, one
    // cycle later, is for the packet IF serves then.
    input logic [$clog2(ENTRIES/WAYS)-1:0] i_lookup_index,
    // Slot 1's PC and size in the response cycle. Slot 2 follows slot 1.
    input logic [XLEN-1:0] i_packet_pc,
    input logic i_packet_compressed,
    // Per slot (index 0 is slot 1): a hit, the size and return type the
    // entry was trained with, and the stored target bits [TARGET_BITS-1:1].
    output logic [1:0] o_hit,
    output logic [1:0] o_compressed,
    output logic [1:0] o_return,
    output logic [1:0][TARGET_BITS-2:0] o_target,
    // Slot 2's return type and target for each size of slot 1, indexed by
    // i_packet_compressed's value: o_return[1] and o_target[1] are the entries
    // at i_packet_compressed. They let a consumer select by slot 1's size last.
    output logic [1:0] o_slot2_return_by_size,
    output logic [1:0][TARGET_BITS-2:0] o_slot2_target_by_size,

    // Training: a jump's update from the one ex_comb_synthesizer selects,
    // at most one per cycle
    input logic            i_update,
    input logic [XLEN-1:0] i_update_pc,
    input logic [XLEN-1:0] i_update_target,
    input logic            i_update_compressed,
    input logic            i_update_return,
    // Refresh: the PC of an entry that served a prediction. A hit there
    // points replacement away from its way. Dropped in a cycle with an
    // update.
    input logic            i_refresh,
    input logic [XLEN-1:0] i_refresh_pc
);

  localparam int unsigned Sets = ENTRIES / WAYS;
  localparam int unsigned IndexBits = $clog2(Sets);
  localparam int unsigned WayBits = $clog2(WAYS);
  // PC bits above the index; PC[1] is stored beside them.
  localparam int unsigned UpperBits = XLEN - IndexBits - 2;
  localparam int unsigned ReplBits = WAYS - 1;
  // Four ways: bit 0 picks a pair of ways, bits 1 and 2 a way in each pair.
  // The indices stay in range for two ways, where only bit 0 exists.
  localparam int unsigned LowPairBit = (ReplBits > 1) ? 1 : 0;
  localparam int unsigned HighPairBit = (ReplBits > 2) ? 2 : 0;

  typedef struct packed {
    logic valid;
    logic [UpperBits-1:0] upper;
    logic halfword;
    logic compressed;
    logic is_return;
  } tag_t;

  typedef struct packed {logic [TARGET_BITS-2:0] target;} payload_t;

  // A set is {replacement, the ways' tags, the ways' payloads}, way 0 lowest
  // in each field. The widths are written out rather than taken with $bits
  // of the types; the simulation checks below pin them to the structs.
  localparam int unsigned TagEntryBits = UpperBits + 4;
  localparam int unsigned PayloadEntryBits = TARGET_BITS - 1;
  localparam int unsigned TagRowBits = WAYS * TagEntryBits;
  localparam int unsigned PayloadRowBits = WAYS * PayloadEntryBits;
  localparam int unsigned SetBits = ReplBits + TagRowBits + PayloadRowBits;

  // ===========================================================================
  // Replacement: a bit per set for two ways, a three-bit tree for four ways
  // ===========================================================================
  function automatic logic [WayBits-1:0] victim(input logic [ReplBits-1:0] state);
    if (WAYS == 2) victim = WayBits'(state[0]);
    else victim = WayBits'({state[0], state[0] ? state[HighPairBit] : state[LowPairBit]});
  endfunction

  function automatic logic [ReplBits-1:0] touch(input logic [ReplBits-1:0] state,
                                                input logic [WayBits-1:0] way);
    logic [ReplBits-1:0] result;
    result = state;
    if (WAYS == 2) result[0] = !way[0];
    else begin
      result[0] = !way[WayBits-1];
      if (way[WayBits-1]) result[HighPairBit] = !way[0];
      else result[LowPairBit] = !way[0];
    end
    touch = result;
  endfunction

  // ===========================================================================
  // Reset sweep
  // ===========================================================================
  logic sweep_active;
  logic [IndexBits-1:0] sweep_index;
  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      sweep_active <= 1'b1;
      sweep_index  <= '0;
    end else if (sweep_active) begin
      sweep_index <= sweep_index + IndexBits'(1);
      if (sweep_index == IndexBits'(Sets - 1)) sweep_active <= 1'b0;
    end
  end

  // ===========================================================================
  // Training
  // ===========================================================================
  // Stage A registers the request (an update, else a refresh) and reads its
  // set, stage B finds its way, and stage C writes the set.
  logic [XLEN-1:0] request_pc;
  assign request_pc = i_update ? i_update_pc : i_refresh_pc;
  logic a_valid;
  logic a_refresh;
  logic [IndexBits-1:0] a_index;
  logic [UpperBits-1:0] a_upper;
  logic a_halfword;
  logic [TARGET_BITS-2:0] a_target;
  logic a_region_ok;
  logic a_compressed, a_return;
  always_ff @(posedge i_clk) begin
    a_valid      <= (i_update || i_refresh) && !i_reset && !sweep_active;
    a_refresh    <= !i_update;
    a_index      <= request_pc[IndexBits+1:2];
    a_upper      <= request_pc[XLEN-1:IndexBits+2];
    a_halfword   <= request_pc[1];
    a_target     <= i_update_target[TARGET_BITS-1:1];
    a_region_ok  <= i_update_pc[XLEN-1:TARGET_BITS] == i_update_target[XLEN-1:TARGET_BITS];
    a_compressed <= i_update_compressed;
    a_return     <= i_update_return;
  end

  logic b_valid;
  logic b_refresh;
  logic [IndexBits-1:0] b_index;
  logic [UpperBits-1:0] b_upper;
  logic b_halfword;
  logic [TARGET_BITS-2:0] b_target;
  logic b_region_ok;
  logic b_compressed, b_return;
  always_ff @(posedge i_clk) begin
    b_valid      <= a_valid && !i_reset;
    b_refresh    <= a_refresh;
    b_index      <= a_index;
    b_upper      <= a_upper;
    b_halfword   <= a_halfword;
    b_target     <= a_target;
    b_region_ok  <= a_region_ok;
    b_compressed <= a_compressed;
    b_return     <= a_return;
  end

  // A request to the set written on the edge that read it takes the written
  // set. One to the set that the update a stage ahead is writing is dropped;
  // a refresh a stage ahead changes only replacement state, so the request
  // behind it proceeds.
  logic b_forward_q;
  logic [SetBits-1:0] forward_set_q;
  logic [SetBits-1:0] update_set_raw;
  logic [SetBits-1:0] update_set_read;
  logic [SetBits-1:0] b_set;
  assign b_set = b_forward_q ? forward_set_q : update_set_read;

  logic [ReplBits-1:0] b_replacement;
  logic [WAYS-1:0] b_way_valid;
  logic [WAYS-1:0] b_way_match;
  assign b_replacement = b_set[SetBits-1-:ReplBits];
  for (genvar way = 0; way < WAYS; way++) begin : gen_update_match
    tag_t tag;
    assign tag = b_set[PayloadRowBits+way*TagEntryBits+:TagEntryBits];
    assign b_way_valid[way] = tag.valid;
    assign b_way_match[way] = tag.valid && tag.upper == b_upper && tag.halfword == b_halfword;
  end

  // The hit way, else the lowest invalid way, else the replacement victim.
  logic b_hit;
  logic [WayBits-1:0] b_way;
  always_comb begin
    b_hit = |b_way_match;
    b_way = victim(b_replacement);
    for (int way = WAYS - 1; way >= 0; way--) begin
      if (!b_way_valid[way]) b_way = WayBits'(way);
    end
    for (int way = WAYS - 1; way >= 0; way--) begin
      if (b_way_match[way]) b_way = WayBits'(way);
    end
  end

  // Stage C registers the set, the chosen way and the request, then writes.
  // A refresh that misses writes nothing.
  logic c_valid;
  logic c_refresh;
  logic [IndexBits-1:0] c_index;
  logic [SetBits-1:0] c_set;
  logic c_hit;
  logic [WayBits-1:0] c_way;
  logic [UpperBits-1:0] c_upper;
  logic c_halfword;
  logic [TARGET_BITS-2:0] c_target;
  logic c_region_ok;
  logic c_compressed, c_return;
  logic b_accepted;
  assign b_accepted = b_valid && !(c_valid && !c_refresh && c_index == b_index) &&
                      !(b_refresh && !b_hit);
  always_ff @(posedge i_clk) begin
    c_valid      <= b_accepted && !i_reset;
    c_refresh    <= b_refresh;
    c_index      <= b_index;
    c_set        <= b_set;
    c_hit        <= b_hit;
    c_way        <= b_way;
    c_upper      <= b_upper;
    c_halfword   <= b_halfword;
    c_target     <= b_target;
    c_region_ok  <= b_region_ok;
    c_compressed <= b_compressed;
    c_return     <= b_return;
  end

  // An update writes its way, a hit or an allocation, only for a target in
  // the jump's region. A hit with a target outside it is invalidated, and a
  // miss with one writes its set back as read. A refresh writes its set back
  // as read apart from replacement.
  logic [ReplBits-1:0] c_replacement;
  logic [TagRowBits-1:0] write_tags;
  logic [PayloadRowBits-1:0] write_payloads;
  logic [ReplBits-1:0] write_replacement;
  assign c_replacement = c_set[SetBits-1-:ReplBits];
  for (genvar way = 0; way < WAYS; way++) begin : gen_update_write
    tag_t old_tag, new_tag;
    payload_t old_payload, new_payload;
    assign old_tag = c_set[PayloadRowBits+way*TagEntryBits+:TagEntryBits];
    assign old_payload = c_set[way*PayloadEntryBits+:PayloadEntryBits];
    always_comb begin
      new_tag = old_tag;
      new_payload = old_payload;
      if (!c_refresh && c_way == WayBits'(way)) begin
        if (c_region_ok) begin
          new_tag.valid = 1'b1;
          new_tag.upper = c_upper;
          new_tag.halfword = c_halfword;
          new_tag.compressed = c_compressed;
          new_tag.is_return = c_return;
          new_payload.target = c_target;
        end else if (c_hit) begin
          new_tag.valid = 1'b0;
        end
      end
    end
    assign write_tags[way*TagEntryBits+:TagEntryBits] = sweep_active ? '0 : new_tag;
    assign write_payloads[way*PayloadEntryBits+:PayloadEntryBits] = sweep_active ? '0 : new_payload;
  end
  assign write_replacement = sweep_active ? '0 : ((c_refresh || c_region_ok) ? touch(
      c_replacement, c_way
  ) : c_replacement);

  logic [SetBits-1:0] write_set;
  logic write_enable;
  logic [IndexBits-1:0] write_index;
  assign write_set = {write_replacement, write_tags, write_payloads};
  assign write_enable = sweep_active || c_valid;
  assign write_index = sweep_active ? sweep_index : c_index;

  always_ff @(posedge i_clk) begin
    b_forward_q   <= write_enable && (write_index == a_index);
    forward_set_q <= write_set;
  end

  sdp_block_ram #(
      .ADDR_WIDTH(IndexBits),
      .DATA_WIDTH(SetBits)
  ) u_update_ram (
      .i_clk,
      .i_write_enable(write_enable),
      .i_bulk_clear(1'b0),
      .i_write_address(write_index),
      .i_read_address(a_index),
      .i_write_data(write_set),
      .o_read_data(update_set_raw)
  );

  // ===========================================================================
  // Lookup images
  // ===========================================================================
  // A read on an edge that clears a set, or during reset, can return what
  // that edge clears; its response is dropped.
  logic [IndexBits-1:0] request_index_q;
  logic request_valid_q;
  always_ff @(posedge i_clk) begin
    request_index_q <= i_lookup_index;
    if (i_reset) request_valid_q <= 1'b0;
    else request_valid_q <= !sweep_active && !i_redirect;
  end

  logic [1:0][TagRowBits-1:0] tags_q;
  logic [1:0][PayloadRowBits-1:0] payload_rows;
  // The held read: the last response aligned with its packet.
  logic held_valid_q;
  logic [IndexBits-1:0] held_index_q;
  logic [1:0][TagRowBits-1:0] held_tags_q;
  logic [1:0][PayloadRowBits-1:0] held_payload_q;
  for (genvar image = 0; image < 2; image++) begin : gen_image
    // Image 1 stores set S at row S-1, so its row Q holds the set after Q.
    logic [ IndexBits-1:0] image_write_index;
    logic [TagRowBits-1:0] tag_row;
    assign image_write_index = write_index - IndexBits'(image);
    sdp_dist_ram #(
        .ADDR_WIDTH(IndexBits),
        .DATA_WIDTH(TagRowBits)
    ) u_tag_ram (
        .i_clk,
        .i_write_enable(write_enable),
        .i_write_address(image_write_index),
        .i_read_address(i_lookup_index),
        .i_write_data(write_tags),
        .o_read_data(tag_row)
    );
    always_ff @(posedge i_clk) tags_q[image] <= tag_row;

    sdp_block_ram #(
        .ADDR_WIDTH(IndexBits),
        .DATA_WIDTH(PayloadRowBits)
    ) u_payload_ram (
        .i_clk,
        .i_write_enable(write_enable),
        .i_bulk_clear(1'b0),
        .i_write_address(image_write_index),
        .i_read_address(i_lookup_index),
        .i_write_data(write_payloads),
        .o_read_data(payload_rows[image])
    );
  end

  // ===========================================================================
  // Response
  // ===========================================================================
  // Matches, sizes and return types come from registers and the packet PC;
  // the payload arrays' outputs, or the held targets, supply the targets.
  logic aligned;
  logic held_aligned;
  logic shifted;  // the read's set is the one before the packet's word
  logic held_shifted;
  logic last_set;
  logic held_last_set;
  assign aligned = request_valid_q && (request_index_q == i_packet_pc[IndexBits+1:2]);
  assign held_aligned = held_valid_q && (held_index_q == i_packet_pc[IndexBits+1:2]);
  assign shifted = request_valid_q &&
      ((request_index_q + IndexBits'(1)) == i_packet_pc[IndexBits+1:2]);
  assign held_shifted = held_valid_q &&
      ((held_index_q + IndexBits'(1)) == i_packet_pc[IndexBits+1:2]);
  assign last_set = &request_index_q;
  assign held_last_set = &held_index_q;

  // The newest read is held whenever it covers the packet, aligned or
  // shifted. A redirect discards reads from the previous fetch path; only the
  // valid flag needs that kill, keeping redirect logic off the data enables.
  always_ff @(posedge i_clk) begin
    if (i_reset || sweep_active || i_redirect) begin
      held_valid_q <= 1'b0;
    end else if (aligned || shifted) begin
      held_valid_q <= 1'b1;
    end
  end
  always_ff @(posedge i_clk) begin
    if (aligned || shifted) begin
      held_index_q   <= request_index_q;
      held_tags_q    <= tags_q;
      held_payload_q <= payload_rows;
    end
  end

  // Slot 1 is the packet word's halfword at PC[1]. Slot 2 starts 2 or 4
  // bytes later: the packet word's upper halfword after a compressed slot 1
  // at a word boundary, otherwise a halfword of the next word. Slot 2's
  // fields are formed for each size of slot 1 (index 1 compressed, index 0
  // native) from the registered tags and the packet PC alone, and the
  // packet's size selects between them last.
  logic slot1_halfword;
  logic slot2_image;
  logic slot2_halfword;
  logic [1:0] slot2_image_by_size;
  logic [1:0] slot2_halfword_by_size;
  assign slot1_halfword = i_packet_pc[1];
  assign slot2_image = i_packet_pc[1] || !i_packet_compressed;
  assign slot2_halfword = i_packet_pc[1] ^ i_packet_compressed;
  assign slot2_image_by_size = {i_packet_pc[1], 1'b1};
  assign slot2_halfword_by_size = {!i_packet_pc[1], i_packet_pc[1]};

  // Each read's result per slot (index 0 the newest read, 1 the held one):
  // the matches compare that read's tags with the packet's PC.
  logic [1:0][1:0][TagRowBits-1:0] src_tags;
  logic [1:0][1:0][PayloadRowBits-1:0] src_payloads;
  logic [1:0] src_last_set;
  assign src_tags = {held_tags_q, tags_q};
  assign src_payloads = {held_payload_q, payload_rows};
  assign src_last_set = {held_last_set, last_set};
  logic [1:0] shift_hit, shift_compressed, shift_return;
  logic [1:0][TARGET_BITS-2:0] shift_target;
  logic [1:0][1:0] shift_slot2_hit_by_size, shift_slot2_compressed_by_size;
  logic [1:0][1:0] shift_slot2_return_by_size;
  logic [1:0][1:0][TARGET_BITS-2:0] shift_slot2_target_by_size;
  // [read][image][way]
  logic [1:0][1:0][WAYS-1:0] upper_match;
  logic [1:0][1:0][WAYS-1:0] entry_halfword;
  logic [1:0][1:0][WAYS-1:0] entry_compressed;
  logic [1:0][1:0][WAYS-1:0] entry_return;
  logic [1:0][1:0][WAYS-1:0][TARGET_BITS-2:0] entry_target;
  logic [1:0][WAYS-1:0] slot1_way_match;
  // [read][slot-1 size][image][way]
  logic [1:0][1:0][1:0][WAYS-1:0] slot2_way_match_by_size;
  // Shifted: both slots from image 1, slot 2 only in the packet's word
  // ([read][way], slot 2 [read][slot-1 size][way]).
  logic [1:0][WAYS-1:0] slot1_way_match_shifted;
  logic [1:0][1:0][WAYS-1:0] slot2_way_match_shifted_by_size;
  for (genvar src = 0; src < 2; src++) begin : gen_src
    for (genvar image = 0; image < 2; image++) begin : gen_entry
      for (genvar way = 0; way < WAYS; way++) begin : gen_way
        tag_t tag;
        payload_t payload;
        assign tag = src_tags[src][image][way*TagEntryBits+:TagEntryBits];
        assign payload = src_payloads[src][image][way*PayloadEntryBits+:PayloadEntryBits];
        assign upper_match[src][image][way] = tag.valid &&
            (tag.upper == i_packet_pc[XLEN-1:IndexBits+2]);
        assign entry_halfword[src][image][way] = tag.halfword;
        assign entry_compressed[src][image][way] = tag.compressed;
        assign entry_return[src][image][way] = tag.is_return;
        assign entry_target[src][image][way] = payload.target;
        // Slot 1 reads image 0. The set after the last one is set 0 of the
        // next block, whose tags this block's upper PC bits do not name.
        if (image == 0) begin : gen_slot1
          assign slot1_way_match[src][way] = upper_match[src][0][way] &&
              (entry_halfword[src][0][way] == slot1_halfword);
        end
        for (genvar size = 0; size < 2; size++) begin : gen_size
          assign slot2_way_match_by_size[src][size][image][way] = upper_match[src][image][way] &&
              (slot2_image_by_size[size] == 1'(image)) &&
              (entry_halfword[src][image][way] == slot2_halfword_by_size[size]) &&
              !(image == 1 && src_last_set[src]);
        end
        // Image 1 of a shifted read is the packet word's own set, also after
        // the last set, since the packet's PC names its block.
        if (image == 1) begin : gen_shifted
          assign slot1_way_match_shifted[src][way] = upper_match[src][1][way] &&
              (entry_halfword[src][1][way] == slot1_halfword);
          for (genvar size = 0; size < 2; size++) begin : gen_shifted_size
            assign slot2_way_match_shifted_by_size[src][size][way] = upper_match[src][1][way] &&
                !slot2_image_by_size[size] &&
                (entry_halfword[src][1][way] == slot2_halfword_by_size[size]);
          end
        end
      end
    end
  end

  // At most one way of a set holds a tag (training finds the hit way first),
  // so the field selects are AND-OR reductions.
  logic [1:0] src_hit, src_compressed, src_return;
  logic [1:0][TARGET_BITS-2:0] src_target;
  logic [1:0][1:0] src_slot2_hit_by_size, src_slot2_compressed_by_size, src_slot2_return_by_size;
  logic [1:0][1:0][TARGET_BITS-2:0] src_slot2_target_by_size;
  logic held_select;
  logic shift_select;  // the held read's shifted form answers
  logic shift_answer;  // a shifted read answers
  assign held_select  = !aligned && held_aligned;
  assign shift_select = !shifted;
  assign shift_answer = !(aligned || held_aligned) && (shifted || held_shifted);
  always_comb begin
    src_hit = '0;
    src_compressed = '0;
    src_return = '0;
    src_target = '0;
    src_slot2_hit_by_size = '0;
    src_slot2_compressed_by_size = '0;
    src_slot2_return_by_size = '0;
    src_slot2_target_by_size = '0;
    for (int src = 0; src < 2; src++) begin
      for (int way = 0; way < WAYS; way++) begin
        if (slot1_way_match[src][way]) begin
          src_hit[src] = 1'b1;
          src_compressed[src] = src_compressed[src] || entry_compressed[src][0][way];
          src_return[src] = src_return[src] || entry_return[src][0][way];
          src_target[src] = src_target[src] | entry_target[src][0][way];
        end
        for (int size = 0; size < 2; size++) begin
          for (int image = 0; image < 2; image++) begin
            if (slot2_way_match_by_size[src][size][image][way]) begin
              src_slot2_hit_by_size[src][size] = 1'b1;
              src_slot2_compressed_by_size[src][size] =
                  src_slot2_compressed_by_size[src][size] || entry_compressed[src][image][way];
              src_slot2_return_by_size[src][size] =
                  src_slot2_return_by_size[src][size] || entry_return[src][image][way];
              src_slot2_target_by_size[src][size] =
                  src_slot2_target_by_size[src][size] | entry_target[src][image][way];
            end
          end
        end
      end
    end
  end

  always_comb begin
    shift_hit = '0;
    shift_compressed = '0;
    shift_return = '0;
    shift_target = '0;
    shift_slot2_hit_by_size = '0;
    shift_slot2_compressed_by_size = '0;
    shift_slot2_return_by_size = '0;
    shift_slot2_target_by_size = '0;
    for (int src = 0; src < 2; src++) begin
      for (int way = 0; way < WAYS; way++) begin
        if (slot1_way_match_shifted[src][way]) begin
          shift_hit[src] = 1'b1;
          shift_compressed[src] = shift_compressed[src] || entry_compressed[src][1][way];
          shift_return[src] = shift_return[src] || entry_return[src][1][way];
          shift_target[src] = shift_target[src] | entry_target[src][1][way];
        end
        for (int size = 0; size < 2; size++) begin
          if (slot2_way_match_shifted_by_size[src][size][way]) begin
            shift_slot2_hit_by_size[src][size] = 1'b1;
            shift_slot2_compressed_by_size[src][size] =
                shift_slot2_compressed_by_size[src][size] || entry_compressed[src][1][way];
            shift_slot2_return_by_size[src][size] =
                shift_slot2_return_by_size[src][size] || entry_return[src][1][way];
            shift_slot2_target_by_size[src][size] =
                shift_slot2_target_by_size[src][size] | entry_target[src][1][way];
          end
        end
      end
    end
  end

  // The newest read answers when it is aligned, else an aligned held read,
  // else a shifted newest read, else a shifted held read. Slot 2's fields
  // for each slot-1 size come from the answering read, and the packet's size
  // selects between them last.
  always_comb begin
    o_hit = '0;
    o_compressed[0] = src_compressed[held_select];
    o_return[0] = src_return[held_select];
    o_target[0] = src_target[held_select];
    o_slot2_return_by_size = src_slot2_return_by_size[held_select];
    o_slot2_target_by_size = src_slot2_target_by_size[held_select];
    o_compressed[1] = src_slot2_compressed_by_size[held_select][i_packet_compressed];
    o_return[1] = o_slot2_return_by_size[i_packet_compressed];
    o_target[1] = o_slot2_target_by_size[i_packet_compressed];
    if (aligned || held_aligned) begin
      o_hit[0] = src_hit[held_select];
      o_hit[1] = src_slot2_hit_by_size[held_select][i_packet_compressed];
    end else if (shift_answer) begin
      o_hit[0] = shift_hit[shift_select];
      o_compressed[0] = shift_compressed[shift_select];
      o_return[0] = shift_return[shift_select];
      o_target[0] = shift_target[shift_select];
      o_slot2_return_by_size = shift_slot2_return_by_size[shift_select];
      o_slot2_target_by_size = shift_slot2_target_by_size[shift_select];
      o_compressed[1] = shift_slot2_compressed_by_size[shift_select][i_packet_compressed];
      o_return[1] = o_slot2_return_by_size[i_packet_compressed];
      o_target[1] = o_slot2_target_by_size[i_packet_compressed];
      o_hit[1] = shift_slot2_hit_by_size[shift_select][i_packet_compressed];
    end
  end

  // Whether a set's tag row holds each valid tag once.
  function automatic logic tags_unique(input logic [TagRowBits-1:0] tags);
    tag_t first, second;
    tags_unique = 1'b1;
    for (int first_way = 0; first_way < WAYS; first_way++) begin
      for (int second_way = first_way + 1; second_way < WAYS; second_way++) begin
        first  = tags[first_way*TagEntryBits+:TagEntryBits];
        second = tags[second_way*TagEntryBits+:TagEntryBits];
        if (first.valid && second.valid && first.upper == second.upper &&
            first.halfword == second.halfword)
          tags_unique = 1'b0;
      end
    end
  endfunction

`ifndef SYNTHESIS
  tag_t check_tag;
  payload_t check_payload;
  initial begin
`ifdef FROST_SIM_ASSERTIONS
    if (!(WAYS == 2 || WAYS == 4)) $fatal(1, "backing_btb: invalid static configuration");
`else
    assert (WAYS == 2 || WAYS == 4);
`endif
`ifdef FROST_SIM_ASSERTIONS
    if (!(ENTRIES % WAYS == 0 && (1 << IndexBits) == Sets))
      $fatal(1, "backing_btb: invalid static configuration");
`else
    assert (ENTRIES % WAYS == 0 && (1 << IndexBits) == Sets);
`endif
`ifdef FROST_SIM_ASSERTIONS
    if (!(TARGET_BITS > 1 && TARGET_BITS < XLEN))
      $fatal(1, "backing_btb: invalid static configuration");
`else
    assert (TARGET_BITS > 1 && TARGET_BITS < XLEN);
`endif
`ifdef FROST_SIM_ASSERTIONS
    if (!($bits(check_tag) == TagEntryBits)) $fatal(1, "backing_btb: invalid static configuration");
`else
    assert ($bits(check_tag) == TagEntryBits);
`endif
`ifdef FROST_SIM_ASSERTIONS
    if (!($bits(check_payload) == PayloadEntryBits))
      $fatal(1, "backing_btb: invalid static configuration");
`else
    assert ($bits(check_payload) == PayloadEntryBits);
`endif
  end

  // A set never holds one tag in two ways. The registers and arrays power up
  // arbitrary, so the check begins at the first reset.
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_reset) reset_seen_q <= 1'b1;
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_reset && !sweep_active && c_valid) begin
      p_backing_btb_unique_tags : assert (tags_unique(write_tags));
    end
  end
`endif

`ifdef FORMAL
  // ===========================================================================
  // Formal model (formal/backing_btb.sby)
  // ===========================================================================
  // formal_sets mirrors the update array: every write lands there on its
  // edge. Its reads are read-old, like the arrays'. The bounded tasks check
  // the update array and both lookup images against it, image 1 one set
  // ahead. The proofs define BACKING_BTB_FORMAL_MIRROR_READ, so training
  // reads the mirror itself and the tag invariants below are inductive
  // without the arrays' rows; the arrays then only feed the lookup.
  logic [SetBits-1:0] formal_sets[Sets];
  logic [SetBits-1:0] formal_update_read_q;
  logic [1:0][SetBits-1:0] formal_lookup_q;
  // The mirror's sets as of the held read's request edge.
  logic [1:0][SetBits-1:0] formal_held_q;
  always_ff @(posedge i_clk) begin
    if (!(i_reset || sweep_active || i_redirect) && (aligned || shifted))
      formal_held_q <= formal_lookup_q;
  end
  initial for (int set = 0; set < Sets; set++) formal_sets[set] = '0;
  always_ff @(posedge i_clk) begin
    if (write_enable) formal_sets[write_index] <= write_set;
    formal_update_read_q <= formal_sets[a_index];
    formal_lookup_q[0]   <= formal_sets[i_lookup_index];
    formal_lookup_q[1]   <= formal_sets[i_lookup_index+IndexBits'(1)];
  end

  // Every set the sweep has cleared holds each valid tag once.
  logic formal_cleared_sets_unique;
  always_comb begin
    formal_cleared_sets_unique = 1'b1;
    for (int set = 0; set < Sets; set++) begin
      if ((!sweep_active || set < int'(sweep_index)) && !tags_unique(
              formal_sets[set][PayloadRowBits+:TagRowBits]
          ))
        formal_cleared_sets_unique = 1'b0;
    end
  end

  // The lookup reference: the mirror's sets as of the request edge, read at
  // each slot's own PC. A slot 2 in the word after the last set gets no hit.
  logic [1:0] formal_hit;
  logic [1:0] formal_compressed;
  logic [1:0] formal_return;
  logic [1:0][TARGET_BITS-2:0] formal_target;
  for (genvar slot = 0; slot < 2; slot++) begin : gen_formal_slot
    logic [XLEN-1:0] pc;
    logic same_word;
    logic crosses_block;
    logic [SetBits-1:0] set;
    logic [WAYS-1:0] match;
    logic [WAYS-1:0] way_compressed;
    logic [WAYS-1:0] way_return;
    // Target bits of the matching ways ORed so far, TARGET_BITS-1 per step.
    logic [(WAYS+1)*(TARGET_BITS-1)-1:0] target_or;
    assign pc = (slot == 0) ? i_packet_pc :
        i_packet_pc + (i_packet_compressed ? XLEN'(2) : XLEN'(4));
    assign same_word = pc[XLEN-1:2] == i_packet_pc[XLEN-1:2];
    assign crosses_block = !same_word && (&i_packet_pc[IndexBits+1:2]);
    // The newest read when it is aligned, else the held read; a shifted
    // read serves only the packet's word, from the set after the read one.
    assign set = aligned ? (same_word ? formal_lookup_q[0] : formal_lookup_q[1]) :
        held_aligned ? (same_word ? formal_held_q[0] : formal_held_q[1]) :
        shifted ? formal_lookup_q[1] : formal_held_q[1];
    for (genvar way = 0; way < WAYS; way++) begin : gen_way
      tag_t tag;
      assign tag = set[PayloadRowBits+way*TagEntryBits+:TagEntryBits];
      assign match[way] = tag.valid && (tag.upper == pc[XLEN-1:IndexBits+2]) &&
          (tag.halfword == pc[1]);
      assign way_compressed[way] = match[way] && tag.compressed;
      assign way_return[way] = match[way] && tag.is_return;
      assign target_or[(way+1)*(TARGET_BITS-1)+:TARGET_BITS-1] =
          target_or[way*(TARGET_BITS-1)+:TARGET_BITS-1] |
          (match[way] ? set[way*PayloadEntryBits+:PayloadEntryBits] : '0);
    end
    assign target_or[TARGET_BITS-2:0] = '0;
    assign formal_hit[slot] = (aligned || held_aligned) ? (!crosses_block && |match) :
        ((shifted || held_shifted) && same_word && |match);
    assign formal_compressed[slot] = |way_compressed;
    assign formal_return[slot] = |way_return;
    assign formal_target[slot] = target_or[WAYS*(TARGET_BITS-1)+:TARGET_BITS-1];
  end

  // Slot 2's {hit, size, type, target} as one AND-OR reduction over the
  // ways whose halfword is slot 2's for a given slot-1 size: the form that
  // the per-size reductions and the size select replace. Index 0 and 1 fix
  // the size; index 2 takes the packet's own. The checks below have no reset
  // qualifier, so their first step covers every value of the tag, payload
  // and request registers.
  localparam int unsigned FormalSlot2RefBits = TARGET_BITS + 2;
  logic [3*FormalSlot2RefBits-1:0] formal_slot2_ref;
  for (genvar k = 0; k < 3; k++) begin : gen_formal_slot2_ref
    logic size;
    logic image_select;
    logic halfword_select;
    logic [2*WAYS-1:0] match;
    // Fields of the matching ways ORed so far, one step per image and way.
    logic [2*WAYS:0] hit_or;
    logic [2*WAYS:0] compressed_or;
    logic [2*WAYS:0] return_or;
    logic [(2*WAYS+1)*(TARGET_BITS-1)-1:0] target_or;
    assign size = (k == 2) ? i_packet_compressed : 1'(k);
    assign image_select = i_packet_pc[1] || !size;
    assign halfword_select = i_packet_pc[1] ^ size;
    logic ref_src;
    assign ref_src = shift_answer ? shift_select : held_select;
    assign hit_or[0] = 1'b0;
    assign compressed_or[0] = 1'b0;
    assign return_or[0] = 1'b0;
    assign target_or[TARGET_BITS-2:0] = '0;
    for (genvar image = 0; image < 2; image++) begin : gen_image
      for (genvar way = 0; way < WAYS; way++) begin : gen_way
        localparam int unsigned Step = image * WAYS + way;
        // The answering read: a shifted one matches image 1 only, for a
        // slot 2 in the packet's word.
        assign match[Step] = upper_match[ref_src][image][way] &&
            (entry_halfword[ref_src][image][way] == halfword_select) &&
            (shift_answer ? (image == 1 && !image_select) :
                            ((image_select == 1'(image)) &&
                             !(image == 1 && src_last_set[ref_src])));
        assign hit_or[Step+1] = hit_or[Step] || match[Step];
        assign compressed_or[Step+1] = compressed_or[Step] ||
            (match[Step] && entry_compressed[ref_src][image][way]);
        assign return_or[Step+1] = return_or[Step] ||
            (match[Step] && entry_return[ref_src][image][way]);
        assign target_or[(Step+1)*(TARGET_BITS-1)+:TARGET_BITS-1] =
            target_or[Step*(TARGET_BITS-1)+:TARGET_BITS-1] |
            (match[Step] ? entry_target[ref_src][image][way] : '0);
      end
    end
    assign formal_slot2_ref[k*FormalSlot2RefBits+:FormalSlot2RefBits] = {
      (aligned || held_aligned || shifted || held_shifted) && hit_or[2*WAYS],
      compressed_or[2*WAYS],
      return_or[2*WAYS],
      target_or[2*WAYS*(TARGET_BITS-1)+:TARGET_BITS-1]
    };
  end

  always_comb begin
    p_formal_slot2_fields_equal_single_reduction :
    assert ({o_hit[1], o_compressed[1], o_return[1], o_target[1]} ==
            formal_slot2_ref[2*FormalSlot2RefBits+:FormalSlot2RefBits]);
    p_formal_slot2_after_native_equal_single_reduction :
    assert ({o_slot2_return_by_size[0], o_slot2_target_by_size[0]} ==
            formal_slot2_ref[0+:TARGET_BITS]);
    p_formal_slot2_after_compressed_equal_single_reduction :
    assert ({o_slot2_return_by_size[1], o_slot2_target_by_size[1]} ==
            formal_slot2_ref[FormalSlot2RefBits+:TARGET_BITS]);
  end

  logic formal_past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    formal_past_valid <= 1'b1;
    if (!formal_past_valid) assume (i_reset);
  end

  always_comb begin
    if (formal_past_valid) begin
      p_formal_mirror_tags_unique : assert (formal_cleared_sets_unique);
      // The sweep runs alone.
      if (sweep_active) begin
        p_formal_sweep_runs_alone : assert (!a_valid && !b_valid && !c_valid);
      end
      // A request in stage B holds its set as the arrays hold it in the same
      // cycle, and one in stage C the tags and targets of it: only a refresh,
      // which changes replacement state alone, writes the set in between.
      if (b_valid) begin
        p_formal_stage_b_set_current : assert (b_set == formal_sets[b_index]);
      end
      if (c_valid) begin
        p_formal_stage_c_entries_current :
        assert (c_set[TagRowBits+PayloadRowBits-1:0] ==
                formal_sets[c_index][TagRowBits+PayloadRowBits-1:0]);
      end
      // A refresh writes its set back with only replacement changed.
      if (c_valid && c_refresh && !sweep_active) begin
        p_formal_refresh_keeps_entries :
        assert (write_set[TagRowBits+PayloadRowBits-1:0] == c_set[TagRowBits+PayloadRowBits-1:0]);
      end
      // A hit needs a request read outside reset and the sweep, for the set
      // of the packet's word, the newest or the held one, and no slot-2 hit
      // comes from the word after the last set.
      if (o_hit != 2'b00) begin
        p_formal_hit_needs_aligned_request :
        assert (aligned || held_aligned || shifted || held_shifted);
      end
      if (&i_packet_pc[IndexBits+1:2] && slot2_image) begin
        p_formal_no_slot2_hit_past_last_set : assert (!o_hit[1]);
      end
      // The held read is always a set read outside reset and the sweep.
      if (held_valid_q) begin
        p_formal_held_read_after_sweep : assert (!sweep_active);
      end
`ifndef BACKING_BTB_FORMAL_MIRROR_READ
      // The arrays equal the mirror: the update array's read, and each slot's
      // lookup result against the reference over the mirror.
      p_formal_update_read_matches_mirror : assert (update_set_raw == formal_update_read_q);
      p_formal_hit_matches_reference : assert (o_hit == formal_hit);
      if (o_hit[0]) begin
        p_formal_slot1_fields_match_reference :
        assert (o_compressed[0] == formal_compressed[0] && o_return[0] == formal_return[0] &&
                o_target[0] == formal_target[0]);
      end
      if (o_hit[1]) begin
        p_formal_slot2_fields_match_reference :
        assert (o_compressed[1] == formal_compressed[1] && o_return[1] == formal_return[1] &&
                o_target[1] == formal_target[1]);
      end
`endif
    end
  end

  always_ff @(posedge i_clk) begin
    if (formal_past_valid) begin
      // No hit for a read during reset or the sweep, the last sweep edge
      // included.
      if ($past(i_reset || sweep_active)) begin
        p_formal_no_hit_after_reset_or_sweep : assert (o_hit == 2'b00);
      end
      if ($past(i_redirect)) begin
        p_formal_redirect_discards_reads :
        assert (!request_valid_q && !held_valid_q && (o_hit == 2'b00));
      end
      cover ($past(i_redirect) && i_redirect && !held_valid_q);
      cover (o_hit[0] && !$past(i_update || i_refresh));
      cover (o_hit[1] && !slot2_image);
      cover (o_hit[1] && slot2_image);
      cover (o_hit[0] && !aligned && held_aligned);
      cover (o_hit[1] && !aligned && held_aligned);
      cover (o_hit[0] && !aligned && !held_aligned && shifted);
      cover (o_hit[1] && !aligned && !held_aligned && shifted);
      cover (o_hit[0] && !aligned && !held_aligned && !shifted && held_shifted);
      cover (c_valid && c_refresh);
      cover (b_valid && b_refresh && !b_hit);
      cover (b_valid && !b_accepted && c_valid && !c_refresh);
      cover (b_valid && b_forward_q);
      cover (b_valid && !b_refresh && !b_hit && &b_way_valid);
    end
  end
`endif

`ifdef BACKING_BTB_FORMAL_MIRROR_READ
  assign update_set_read = formal_update_read_q;
`else
  assign update_set_read = update_set_raw;
`endif

endmodule : backing_btb
