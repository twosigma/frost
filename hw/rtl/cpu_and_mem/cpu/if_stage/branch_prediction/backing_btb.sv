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
 * is trained by every BTB update and looked up for the packet IF serves. PD
 * turns a taken hit on a JAL or JALR that fast prediction did not take into
 * a PD redirect, with the return address stack operation that the
 * instruction's own encoding names (hw/rtl/cpu_and_mem/cpu/README.md,
 * "Backing BTB").
 *
 * Sets are indexed by PC word bits, like the fast BTB. An entry's tag holds
 * the PC bits above the index, and its payload holds PC[1] with the target,
 * counter, size and type. The target keeps its low TARGET_BITS bits; the
 * upper bits come from the branch's PC, and training with a target in
 * another region invalidates the entry, as in the fast BTB.
 *
 * Lookup. The caller supplies the set index of the fetch PC register. The
 * tag arrays read it without a clock and register the tags; the payload
 * arrays read it on the clock edge. In the next cycle IF serves the window
 * of that fetch, normally at i_packet_pc, and the registered tags are
 * compared with the packet's PC. Each lookup reads two sets: the packet's
 * word and the word after it, for a slot 2 there. The second image of each
 * array stores set S at row S-1, so both read at the same index. A packet
 * whose set is not the one read gets no hit, and neither does a slot 2 in
 * the word after the last set, which belongs to the next block of sets.
 *
 * Training. An update registers and reads its set from a third payload
 * array that also holds the tags, valid bits and replacement state; the
 * next stage finds its way and registers it, and the last writes the whole
 * set into every array. An update to the set written on the edge it reads
 * takes the written set instead, and one to the set that the update a stage
 * ahead writes is dropped. A hit trains the counter, a miss replaces an
 * invalid way or the way the replacement state names, and replacement then
 * points away from the written way. Lookups and training share no state
 * across an edge: a lookup reads the arrays as they were before that edge's
 * write.
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

    // Lookup: the set of the fetch PC register's word. The response, one
    // cycle later, is for the packet IF serves then.
    input logic [$clog2(ENTRIES/WAYS)-1:0] i_lookup_index,
    // Slot 1's PC and size in the response cycle. Slot 2 follows slot 1.
    input logic [XLEN-1:0] i_packet_pc,
    input logic i_packet_compressed,
    // Per slot (index 0 is slot 1): a hit predicting taken, the size the
    // entry was trained with, and the stored target bits [TARGET_BITS-1:1].
    output logic [1:0] o_hit,
    output logic [1:0] o_compressed,
    output logic [1:0][TARGET_BITS-2:0] o_target,

    // Training, the update ex_comb_synthesizer selects, at most one per cycle
    input logic            i_update,
    input logic [XLEN-1:0] i_update_pc,
    input logic [XLEN-1:0] i_update_target,
    input logic            i_update_taken,
    input logic            i_update_compressed,
    input logic            i_update_call,
    input logic            i_update_return
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
  } tag_t;

  typedef struct packed {
    logic halfword;
    logic [TARGET_BITS-2:0] target;
    logic [1:0] counter;
    logic compressed;
    logic is_call;
    logic is_return;
  } payload_t;

  // A set is {replacement, the ways' tags, the ways' payloads}, way 0 lowest
  // in each field. The widths are written out rather than taken with $bits
  // of the types; the simulation checks below pin them to the structs.
  localparam int unsigned TagEntryBits = UpperBits + 1;
  localparam int unsigned PayloadEntryBits = TARGET_BITS + 5;
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

  function automatic logic [1:0] train_counter(input logic [1:0] counter, input logic taken);
    if (taken) train_counter = (counter == 2'b11) ? counter : counter + 2'b01;
    else train_counter = (counter == 2'b00) ? counter : counter - 2'b01;
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
  // Stage A registers the update and reads its set; stage B writes the set.
  logic a_valid;
  logic [IndexBits-1:0] a_index;
  logic [UpperBits-1:0] a_upper;
  logic a_halfword;
  logic [TARGET_BITS-2:0] a_target;
  logic a_region_ok;
  logic a_taken, a_compressed, a_call, a_return;
  always_ff @(posedge i_clk) begin
    a_valid      <= i_update && !i_reset && !sweep_active;
    a_index      <= i_update_pc[IndexBits+1:2];
    a_upper      <= i_update_pc[XLEN-1:IndexBits+2];
    a_halfword   <= i_update_pc[1];
    a_target     <= i_update_target[TARGET_BITS-1:1];
    a_region_ok  <= i_update_pc[XLEN-1:TARGET_BITS] == i_update_target[XLEN-1:TARGET_BITS];
    a_taken      <= i_update_taken;
    a_compressed <= i_update_compressed;
    a_call       <= i_update_call;
    a_return     <= i_update_return;
  end

  logic b_valid;
  logic [IndexBits-1:0] b_index;
  logic [UpperBits-1:0] b_upper;
  logic b_halfword;
  logic [TARGET_BITS-2:0] b_target;
  logic b_region_ok;
  logic b_taken, b_compressed, b_call, b_return;
  always_ff @(posedge i_clk) begin
    b_valid      <= a_valid && !i_reset;
    b_index      <= a_index;
    b_upper      <= a_upper;
    b_halfword   <= a_halfword;
    b_target     <= a_target;
    b_region_ok  <= a_region_ok;
    b_taken      <= a_taken;
    b_compressed <= a_compressed;
    b_call       <= a_call;
    b_return     <= a_return;
  end

  // An update to the set written on the edge that read it takes the written
  // set. One to the set that the update a stage ahead is writing is dropped.
  logic b_forward_q;
  logic [SetBits-1:0] forward_set_q;
  logic [SetBits-1:0] update_set_raw;
  logic [SetBits-1:0] b_set;
  assign b_set = b_forward_q ? forward_set_q : update_set_raw;

  logic [ReplBits-1:0] b_replacement;
  logic [WAYS-1:0] b_way_valid;
  logic [WAYS-1:0] b_way_match;
  assign b_replacement = b_set[SetBits-1-:ReplBits];
  for (genvar way = 0; way < WAYS; way++) begin : gen_update_match
    tag_t tag;
    payload_t payload;
    assign tag = b_set[PayloadRowBits+way*TagEntryBits+:TagEntryBits];
    assign payload = b_set[way*PayloadEntryBits+:PayloadEntryBits];
    assign b_way_valid[way] = tag.valid;
    assign b_way_match[way] = tag.valid && tag.upper == b_upper && payload.halfword == b_halfword;
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

  // Stage C registers the set, the chosen way and the update, then writes.
  logic c_valid;
  logic [IndexBits-1:0] c_index;
  logic [SetBits-1:0] c_set;
  logic c_hit;
  logic [WayBits-1:0] c_way;
  logic [UpperBits-1:0] c_upper;
  logic c_halfword;
  logic [TARGET_BITS-2:0] c_target;
  logic c_region_ok;
  logic c_taken, c_compressed, c_call, c_return;
  always_ff @(posedge i_clk) begin
    c_valid      <= b_valid && !i_reset && !(c_valid && c_index == b_index);
    c_index      <= b_index;
    c_set        <= b_set;
    c_hit        <= b_hit;
    c_way        <= b_way;
    c_upper      <= b_upper;
    c_halfword   <= b_halfword;
    c_target     <= b_target;
    c_region_ok  <= b_region_ok;
    c_taken      <= b_taken;
    c_compressed <= b_compressed;
    c_call       <= b_call;
    c_return     <= b_return;
  end

  // A hit trains its counter and a miss allocates, both only for a target in
  // the branch's region. A hit with a target outside it is invalidated, and
  // a miss with one writes its set unchanged.
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
      if (c_way == WayBits'(way)) begin
        if (c_region_ok) begin
          new_tag.valid = 1'b1;
          new_tag.upper = c_upper;
          new_payload.halfword = c_halfword;
          new_payload.target = c_target;
          new_payload.counter = c_hit ?
              train_counter(old_payload.counter, c_taken) : (c_taken ? 2'b10 : 2'b01);
          new_payload.compressed = c_compressed;
          new_payload.is_call = c_call;
          new_payload.is_return = c_return;
        end else if (c_hit) begin
          new_tag.valid = 1'b0;
        end
      end
    end
    assign write_tags[way*TagEntryBits+:TagEntryBits] = sweep_active ? '0 : new_tag;
    assign write_payloads[way*PayloadEntryBits+:PayloadEntryBits] = sweep_active ? '0 : new_payload;
  end
  assign write_replacement = sweep_active ? '0 : (c_region_ok ? touch(
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
    request_valid_q <= !i_reset && !sweep_active;
  end

  logic [1:0][TagRowBits-1:0] tags_q;
  logic [1:0][PayloadRowBits-1:0] payload_rows;
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
  // Tag matches come from registers and the packet PC; the payload arrays'
  // outputs only qualify a hit and supply its fields.
  logic aligned;
  logic last_set;
  assign aligned  = request_valid_q && (request_index_q == i_packet_pc[IndexBits+1:2]);
  assign last_set = &request_index_q;

  logic [1:0][WAYS-1:0] upper_match;
  logic [1:0][WAYS-1:0] entry_halfword;
  logic [1:0][WAYS-1:0] entry_usable;
  logic [1:0][WAYS-1:0] entry_compressed;
  logic [1:0][WAYS-1:0][TARGET_BITS-2:0] entry_target;
  for (genvar image = 0; image < 2; image++) begin : gen_entry
    for (genvar way = 0; way < WAYS; way++) begin : gen_way
      tag_t tag;
      payload_t payload;
      assign tag = tags_q[image][way*TagEntryBits+:TagEntryBits];
      assign payload = payload_rows[image][way*PayloadEntryBits+:PayloadEntryBits];
      assign upper_match[image][way] = tag.valid && (tag.upper == i_packet_pc[XLEN-1:IndexBits+2]);
      assign entry_halfword[image][way] = payload.halfword;
      assign entry_usable[image][way] = payload.counter[1];
      assign entry_compressed[image][way] = payload.compressed;
      assign entry_target[image][way] = payload.target;
    end
  end

  // Slot 1 is the packet word's halfword at PC[1]. Slot 2 starts 2 or 4
  // bytes later: the packet word's upper halfword after a compressed slot 1
  // at a word boundary, otherwise a halfword of the next word.
  logic slot1_halfword;
  logic slot2_image;
  logic slot2_halfword;
  assign slot1_halfword = i_packet_pc[1];
  assign slot2_image = i_packet_pc[1] || !i_packet_compressed;
  assign slot2_halfword = i_packet_pc[1] ^ i_packet_compressed;

  logic [WAYS-1:0] slot1_way_match;
  logic [1:0][WAYS-1:0] slot2_way_match;
  for (genvar way = 0; way < WAYS; way++) begin : gen_slot_match
    assign slot1_way_match[way] = upper_match[0][way] && (entry_halfword[0][way] == slot1_halfword);
    // The set after the last one is set 0 of the next block, whose tags this
    // block's upper PC bits do not name.
    for (genvar image = 0; image < 2; image++) begin : gen_image
      assign slot2_way_match[image][way] = upper_match[image][way] &&
          (slot2_image == 1'(image)) && (entry_halfword[image][way] == slot2_halfword) &&
          !(image == 1 && last_set);
    end
  end

  // At most one way of a set holds a tag (training finds the hit way first),
  // so the field selects are AND-OR reductions.
  always_comb begin
    o_hit = '0;
    o_compressed = '0;
    o_target = '0;
    for (int way = 0; way < WAYS; way++) begin
      if (slot1_way_match[way]) begin
        o_hit[0] = o_hit[0] || entry_usable[0][way];
        o_compressed[0] = o_compressed[0] || entry_compressed[0][way];
        o_target[0] = o_target[0] | entry_target[0][way];
      end
      for (int image = 0; image < 2; image++) begin
        if (slot2_way_match[image][way]) begin
          o_hit[1] = o_hit[1] || entry_usable[image][way];
          o_compressed[1] = o_compressed[1] || entry_compressed[image][way];
          o_target[1] = o_target[1] | entry_target[image][way];
        end
      end
    end
    if (!aligned) o_hit = 2'b00;
  end

`ifndef SYNTHESIS
  tag_t check_tag;
  payload_t check_payload;
  initial begin
    assert (WAYS == 2 || WAYS == 4);
    assert (ENTRIES % WAYS == 0 && (1 << IndexBits) == Sets);
    assert (TARGET_BITS > 1 && TARGET_BITS < XLEN);
    assert ($bits(check_tag) == TagEntryBits);
    assert ($bits(check_payload) == PayloadEntryBits);
  end

  // A set never holds one tag in two ways.
  always_ff @(posedge i_clk) begin
    if (!i_reset && !sweep_active && c_valid) begin
      for (int first = 0; first < WAYS; first++) begin
        for (int second = first + 1; second < WAYS; second++) begin
          p_backing_btb_unique_tags :
          assert (!(write_tags[first*TagEntryBits+TagEntryBits-1] &&
                    write_tags[second*TagEntryBits+TagEntryBits-1] &&
                    write_tags[first*TagEntryBits+:TagEntryBits] ==
                    write_tags[second*TagEntryBits+:TagEntryBits] &&
                    write_payloads[first*PayloadEntryBits+PayloadEntryBits-1] ==
                    write_payloads[second*PayloadEntryBits+PayloadEntryBits-1]));
        end
      end
    end
  end
`endif

endmodule : backing_btb
