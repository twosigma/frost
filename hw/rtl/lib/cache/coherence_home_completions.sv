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

`include "coherence_types.svh"

// Request identities and way pins survive result delivery through Release.
module coherence_home_completions #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 64,
    parameter int unsigned CACHE_BYTES = 2 * 1024 * 1024,
    parameter int unsigned WAYS = 4,
    parameter int unsigned SLOTS = coherence_pkg::completion_count(1),
    parameter int unsigned RESULT_SLOTS = 8,
    // When nonzero, the last PREFETCH_SLOTS slots admit only prefetch
    // requests (source 3) and the others only the rest, so each kind has
    // capacity of its own. The table then takes every G from a prefetch slot
    // as accepted when presented: the consumer must keep i_g_ready set while
    // a source-3 G is valid.
    parameter int unsigned PREFETCH_SLOTS = coherence_pkg::PrefetchIds,
    localparam int unsigned WayBits = WAYS > 1 ? $clog2(WAYS) : 1,
    localparam int unsigned SlotBits = SLOTS > 1 ? $clog2(SLOTS) : 1,
    localparam int unsigned ResultBits = RESULT_SLOTS > 1 ? $clog2(RESULT_SLOTS) : 1
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_fatal_stop,
    input logic i_d_valid,
    output logic o_d_ready,
    input logic [ADDR_WIDTH+311:0] i_d,
    output logic o_work_valid,
    // o_work_valid and o_waiting without the reset term, for consumers whose
    // state is cleared by the same reset.
    output logic o_work_offer,
    input logic i_work_ready,
    output logic [ADDR_WIDTH+311:0] o_work,
    output logic [5:0] o_work_tid,
    output logic [ResultBits-1:0] o_work_buffer,
    output logic o_work_error,
    output logic o_work_counted,
    // The work is a prefetch whose block a non-prefetch request held live
    // before the prefetch's dispatch: it must not allocate a fill.
    output logic o_work_nofill,
    // A registered copy of D acceptance: the strobe on the cycle after it,
    // with the accepted request's opcode, identity and address.
    output logic o_accepted,
    output logic [3:0] o_accepted_opcode,
    output logic [8:0] o_accepted_q,
    output logic [ADDR_WIDTH-1:0] o_accepted_addr,
    input logic i_count_valid,
    input logic [5:0] i_count_tid,
    output logic [SLOTS-1:0] o_waiting,
    output logic [SLOTS-1:0] o_waiting_offer,
    output logic [SLOTS-1:0][ADDR_WIDTH+311:0] o_waiting_request,
    input logic [SLOTS-1:0] i_park,
    input logic [SLOTS-1:0] i_wake,
    input logic [SLOTS-1:0] i_wake_error,
    input logic i_retry_park,
    output logic [ResultBits-1:0] o_image_index,
    // One-hot form of o_image_index, all zero when no result awaits G.
    output logic [RESULT_SLOTS-1:0] o_image_select,
    input logic [255:0] i_image_data,
    input logic i_retry_valid,
    input logic [5:0] i_retry_tid,
    input logic i_pin_valid,
    input logic [5:0] i_pin_tid,
    input logic [WayBits-1:0] i_pin_way,
    input logic [ADDR_WIDTH-1:0] i_query_addr,
    output logic [WAYS-1:0] o_exclude,
    // o_put_busy reports a live slot in the same 32-byte sector as the put
    // address. i_next_put_addr is the put address of the next cycle; its
    // sector comparisons are registered, so o_put_busy answers for it then.
    input logic [ADDR_WIDTH-1:0] i_next_put_addr,
    output logic o_put_busy,
    input logic i_result_valid,
    output logic o_result_ready,
    input logic [ADDR_WIDTH+274:0] i_result,
    output logic o_g_valid,
    input logic i_g_ready,
    output logic [ADDR_WIDTH+274:0] o_g,
    input logic i_c_valid,
    output logic o_c_ready,
    input logic [ADDR_WIDTH+17:0] i_c,
    output logic o_u_valid,
    input logic i_u_ready,
`ifdef COHERENCE_HOME_CONTROL
    input logic [SLOTS-1:0] i_fill_waiting,
    input logic [SLOTS-1:0] i_fill_seated,
    input logic [RESULT_SLOTS-1:0] i_engine_busy,
    input logic [RESULT_SLOTS-1:0] i_engine_unpinned,
    input logic [RESULT_SLOTS-1:0] i_engine_pinned,
    input logic [RESULT_SLOTS-1:0] i_engine_initial_error,
    input logic [RESULT_SLOTS-1:0][5:0] i_engine_tid,
    input logic [RESULT_SLOTS-1:0][ADDR_WIDTH-1:0] i_engine_addr,
    input logic i_query_held,
`endif
    output logic [ADDR_WIDTH+14:0] o_u
);
`ifndef SYNTHESIS
  // Registers power up arbitrary and the reset can reach this module a few
  // cycles after the first edge, so the simulation checks begin at the first
  // reset.
`ifdef FORMAL
  // Formal tasks start from a reset or from an induction state; the checks
  // apply in both.
  wire sim_reset_seen_q = 1'b1;
`else
  logic sim_reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) sim_reset_seen_q <= 1'b1;
`endif
`endif
  `FROST_COHERENCE_TYPES(ADDR_WIDTH)
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);
  localparam int unsigned Sets = CACHE_BYTES / (LINE_BYTES * WAYS);
  localparam int unsigned SetBits = $clog2(Sets);
  logic [SLOTS-1:0] live, request_ready, work_valid, work_offer, grant_valid;
  (* keep = "true" *) logic [SLOTS-1:0] completion_ready;
  logic [SLOTS-1:0] release_valid, release_offer, release_ready, release_fire;
  logic [SLOTS-1:0] issued_q, buffer_owned_q, result_valid_q, pin_valid_q, error_q;
  logic [SLOTS-1:0] predecessors_q[SLOTS];
  // A DMA request's result completes its effect on the sector: its bytes and
  // probe results are in the array, and it keeps no private copy. From the
  // cycle after that result until its release, handed_q no longer orders
  // younger requests behind it. Hart requests keep their order through U,
  // since their grant installs after the result. A prefetch changes nothing
  // a client sees, so it neither waits for nor orders other requests.
  logic [SLOTS-1:0] handed_q;
  logic [SLOTS-1:0] parked_q, ready_q, wake_error_q, counted_q;
  // nofill_q[slot], while the slot is live: it holds a prefetch, and a
  // non-prefetch request for its block was live at the prefetch's admission
  // or was admitted after it. The work carries the flag; such a prefetch
  // allocates no fill. Admission sets the flag afresh.
  logic [SLOTS-1:0] nofill_q;
  localparam int unsigned MainSlots = SLOTS - PREFETCH_SLOTS;
  // The prefetch partition, and the slots that may hold a prefetch.
  localparam logic [SLOTS-1:0] PrefetchSlot = ~((SLOTS'(1) << MainSlots) - SLOTS'(1));
  logic [SLOTS-1:0] slot_prefetch;
  logic [ResultBits-1:0] work_buffer_q;
  logic [SLOTS-1:0][ADDR_WIDTH+311:0] work;
  logic [SLOTS-1:0][ADDR_WIDTH+14:0] releases;
  logic [SLOTS-1:0][8:0] work_identity;
  logic [SLOTS-1:0][ADDR_WIDTH-1:0] work_address;
  logic [ResultBits-1:0] buffer_index_q[SLOTS];
  logic [WayBits-1:0] way_q[SLOTS];
  logic [RESULT_SLOTS-1:0] buffer_live_q, buffer_live_next;
  logic [ADDR_WIDTH+274:0] buffer_q[RESULT_SLOTS];
  logic free_slot, duplicate, free_buffer, incoming_prefetch;
  logic [  SlotBits-1:0] free_slot_index;
  logic [ResultBits-1:0] free_buffer_index;
  logic work_selected_q, work_found;
  logic [SLOTS-1:0] work_eligible;
  logic [SlotBits-1:0] work_slot_q, work_pick;
  // Work rotates over positions: one per main slot, then one for all the
  // prefetch slots. The prefetch position offers prefetch_work_slot_q, an
  // eligible prefetch slot registered from the previous cycle, so every
  // selector input is a register. That choice leaves out the slot being
  // dispatched, and a pick needs an idle selection, which follows a
  // dispatch by a cycle, so the registered choice is eligible whenever it
  // can be picked. work_later_q[position] holds position >= work_next_q.
  localparam int unsigned WorkPositions = PREFETCH_SLOTS != 0 ? MainSlots + 1 : SLOTS;
  logic [WorkPositions-1:0] work_position_eligible, work_position_ready, work_later_q;
  logic [SlotBits-1:0] work_next_q, work_position;
  logic prefetch_work_found_q;
  logic [SlotBits-1:0] prefetch_work_slot_q;
  // Grants rotate among the result buffers, so the G path does not grow with
  // the slot count. buffer_ready_q marks a buffer whose result awaits its G
  // (its owner's result_valid_q); buffer_zero_q marks one whose grant carries
  // zero data, an error or a GrantAck; buffer_later_q[index] holds index >=
  // grant_next_q, and grant_buffer_q is the selected grant's buffer.
  logic grant_selected_q, grant_found, grant_after, grant_zero;
  logic [SlotBits-1:0] grant_slot_q, grant_pick;
  logic [ResultBits-1:0] grant_next_q, grant_buffer_q;
  logic [RESULT_SLOTS-1:0] buffer_ready_q, buffer_zero_q, buffer_later_q;
  logic [RESULT_SLOTS-1:0] buffer_later_first, buffer_ready_first;
  (* keep = "true" *) logic [RESULT_SLOTS-1:0] buffer_later;
  // G readiness depends on the clients' own comparisons with the presented
  // grant, so every register it changes takes it as the last term: the
  // grant's slot and buffer decodes, and each register's next state without
  // the grant, are kept nodes.
  (* keep = "true" *) logic [SLOTS-1:0] grant_slot_held, result_valid_hold, buffer_owned_hold;
  (* keep = "true" *) logic [RESULT_SLOTS-1:0] grant_buffer_held, buffer_live_hold;
  (* keep = "true" *) logic [RESULT_SLOTS-1:0] buffer_ready_hold;
  coh_g_t grant_q, result, grant_payload;
  coh_d_t incoming;
  logic result_matches;
  logic [SLOTS-1:0] result_hit;
  logic [SlotBits-1:0] result_slot;
  logic accept_request, accept_work, accept_result, accept_grant;

  function automatic logic [2:0] grant_opcode(input coh_g_t packet);
    grant_opcode = packet.opcode;
  endfunction
  function automatic logic [ADDR_WIDTH+15:0] result_identity(input coh_g_t packet);
    result_identity = {packet.q, packet.tid, packet.addr, packet.error};
  endfunction
  function automatic logic [8:0] request_q(input coh_d_t packet);
    request_q = packet.q;
  endfunction
  function automatic logic [ADDR_WIDTH-1:0] request_addr(input coh_d_t packet);
    request_addr = packet.addr;
  endfunction

  assign incoming = i_d;
  assign result = i_result;
  assign release_fire = release_valid & release_ready;
  assign accept_request = i_d_valid && o_d_ready;
  assign accept_work = o_work_offer && i_work_ready;
  assign accept_result = i_result_valid && o_result_ready;
  assign accept_grant = o_g_valid && i_g_ready;
  // The slot whose G is accepted. A prefetch slot's G is taken whenever it
  // is presented (see PREFETCH_SLOTS), so only the other slots wait on G
  // readiness.
  logic [SLOTS-1:0] grant_taken;
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_grant_taken
    assign grant_slot_held[slot] = grant_selected_q && grant_slot_q == SlotBits'(slot);
    assign grant_taken[slot] = grant_slot_held[slot] && (PrefetchSlot[slot] || i_g_ready);
  end

  // Sector comparisons with the next put address are registered. A slot
  // live across the edge keeps its address unless its release was accepted
  // on the edge; a slot admitted on the edge takes the accepted request's
  // address. o_put_busy therefore reads registers only.
  // A prefetch holds no copy and no permission, so prefetch slots never make
  // a put wait.
  logic [SLOTS-1:0] put_sector_live_q, released_q;
  logic put_incoming_sector_q, request_accepted_q;
  logic [3:0] accepted_opcode_q;
  logic [8:0] accepted_q_q;
  logic [ADDR_WIDTH-1:0] accepted_addr_q;
  always_ff @(posedge i_clk) begin
    put_incoming_sector_q <= (incoming.addr >> 5) == (i_next_put_addr >> 5) && !incoming_prefetch;
    request_accepted_q <= accept_request;
    accepted_opcode_q <= incoming.opcode;
    accepted_q_q <= incoming.q;
    accepted_addr_q <= incoming.addr;
    released_q <= release_fire;
    for (int slot = 0; slot < SLOTS; slot++)
    put_sector_live_q[slot] <= live[slot] && !slot_prefetch[slot] &&
        (work_address[slot] >> 5) == (i_next_put_addr >> 5);
  end
  assign o_put_busy = |(put_sector_live_q & ~released_q) ||
      (request_accepted_q && put_incoming_sector_q);
  assign o_accepted = request_accepted_q;
  assign o_accepted_opcode = accepted_opcode_q;
  assign o_accepted_q = accepted_q_q;
  assign o_accepted_addr = accepted_addr_q;
  // Each slot's set comparison with the query is registered. A pinned slot
  // keeps its address across the edge, so o_exclude is exact whenever the
  // query's set is unchanged, as it is from tag selection through response.
  logic [SLOTS-1:0] query_set_q;
  always_ff @(posedge i_clk) begin
    for (int slot = 0; slot < SLOTS; slot++)
    query_set_q[slot] <= work_address[slot][OffsetBits+:SetBits] ==
        i_query_addr[OffsetBits+:SetBits];
  end
  // The lowest idle slot of the presented request's partition.
  logic main_free, prefetch_free;
  logic [SlotBits-1:0] main_free_index, prefetch_free_index;
  always_comb begin
    main_free = 1'b0;
    main_free_index = '0;
    prefetch_free = 1'b0;
    prefetch_free_index = '0;
    free_buffer = 1'b0;
    free_buffer_index = '0;
    o_exclude = '0;
    for (int slot = SLOTS - 1; slot >= 0; slot--) begin
      if (!live[slot] && !PrefetchSlot[slot]) begin
        main_free = 1'b1;
        main_free_index = SlotBits'(slot);
      end
      if (!live[slot] && PrefetchSlot[slot]) begin
        prefetch_free = 1'b1;
        prefetch_free_index = SlotBits'(slot);
      end
      for (int way = 0; way < WAYS; way++) begin
        if (pin_valid_q[slot] && way_q[slot] == WayBits'(way) && query_set_q[slot])
          o_exclude[way] = 1'b1;
      end
    end
    for (int index = RESULT_SLOTS - 1; index >= 0; index--) begin
      if (!buffer_live_q[index]) begin
        free_buffer = 1'b1;
        free_buffer_index = ResultBits'(index);
      end
    end
  end
  assign incoming_prefetch = incoming.q.src == 2'd3;
  assign free_slot = PREFETCH_SLOTS != 0 && incoming_prefetch ? prefetch_free : main_free;
  assign free_slot_index = PREFETCH_SLOTS != 0 && incoming_prefetch ? prefetch_free_index :
      main_free_index;

  // A request whose identity matches a live slot waits. Each slot compares
  // the nine identity bits in three-bit chunks, and the slot terms reduce
  // through kept nodes of at most six inputs, so the check is a fixed tree:
  // chunk compares, slot terms, nodes, then the duplicate.
  (* keep = "true" *) logic [SLOTS-1:0] duplicates;
  (* keep = "true" *) logic [SLOTS-1:0][2:0] identity_chunk_match;
  localparam int unsigned DuplicateNodes = (SLOTS + 5) / 6;
  (* keep = "true" *) logic [DuplicateNodes-1:0] duplicate_nodes;
  wire [8:0] incoming_identity = incoming.q;
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_duplicate
    for (genvar chunk = 0; chunk < 3; chunk++) begin : gen_chunk
      assign identity_chunk_match[slot][chunk] =
          work_identity[slot][3*chunk+:3] == incoming_identity[3*chunk+:3];
    end
    assign duplicates[slot] = live[slot] && &identity_chunk_match[slot];
  end
  for (genvar node = 0; node < DuplicateNodes; node++) begin : gen_duplicate_node
    localparam int unsigned Bits = SLOTS - 6 * node < 6 ? SLOTS - 6 * node : 6;
    assign duplicate_nodes[node] = |duplicates[6*node+:Bits];
  end
  assign duplicate = |duplicate_nodes;
  // An idle endpoint of the request's partition admits exactly the requests
  // that pass these checks, so D readiness takes them once from the request,
  // beside the free-slot summaries and the duplicate check, rather than
  // from each endpoint's readiness.
  wire request_q_legal = coherence_pkg::legal_q(incoming.q);
  wire request_opcode_legal = coherence_pkg::legal_opcode(incoming.q, incoming.opcode);
  wire request_legal = request_q_legal && request_opcode_legal && incoming.q.epoch == 1'b0 &&
      (incoming.q.src == 2'd0 || incoming.q.src >= 2'd2) && incoming.addr[4:0] == 0;
  assign o_d_ready = !i_rst && !i_fatal_stop && !duplicate && request_legal && free_slot;
  assign o_work_offer = !i_fatal_stop && work_selected_q && !parked_q[work_slot_q];
  assign o_work_valid = !i_rst && o_work_offer;
  assign o_work = work[work_slot_q];
  assign o_work_tid = 6'(work_slot_q);
  assign o_work_buffer = work_buffer_q;
  assign o_work_error = wake_error_q[work_slot_q];
  assign o_work_counted = counted_q[work_slot_q];
  assign o_work_nofill = nofill_q[work_slot_q];
  assign o_waiting_request = work;
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_waiting
    assign o_waiting_offer[slot] = work_offer[slot] && !issued_q[slot] &&
        !parked_q[slot] && !ready_q[slot] &&
        !(work_selected_q && work_slot_q == SlotBits'(slot));
    assign o_waiting[slot] = !i_rst && o_waiting_offer[slot];
  end
  // A presented result matches at most one slot, the one its tid names:
  // that slot's identity, address and state are selected by the tid and
  // compared once.
  assign result_slot = SlotBits'(result.tid);
  wire result_tid_valid = int'(result.tid) < SLOTS;
  assign result_matches = result_tid_valid && issued_q[result_slot] &&
      buffer_owned_q[result_slot] && !result_valid_q[result_slot] &&
      result.opcode <= coherence_pkg::GrantFail && result.q == work_identity[result_slot] &&
      result.addr == work_address[result_slot];
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_result_hit
    assign result_hit[slot] = result_matches && result_slot == SlotBits'(slot);
  end
  assign o_result_ready = !i_rst && result_matches;
  // The selected grant's endpoint is in Work with a matching result, so the
  // grant register alone presents G. Every G consumer applies the same reset.
  assign o_g_valid = grant_selected_q;
  assign o_g = grant_q;
  // Each endpoint's C readiness is kept, and the readiness reduces through
  // kept nodes of at most six slots, so C acceptance has a fixed depth.
  localparam int unsigned CompletionNodes = (SLOTS + 5) / 6;
  (* keep = "true" *) logic [CompletionNodes-1:0] completion_nodes;
  (* keep = "true" *) logic c_ready_final;
  for (genvar node = 0; node < CompletionNodes; node++) begin : gen_completion_node
    localparam int unsigned Bits = SLOTS - 6 * node < 6 ? SLOTS - 6 * node : 6;
    assign completion_nodes[node] = |completion_ready[6*node+:Bits];
  end
  assign c_ready_final = |completion_nodes;
  assign o_c_ready = c_ready_final;

  // pred_clear_q[slot] holds predecessors_q[slot] == 0, registered from the
  // predecessors' next state, so eligibility reads one flag per slot.
  logic [SLOTS-1:0] pred_clear_q, incoming_sectors, incoming_blocks, incoming_orders;
  // A release fires for the arbiter's selected offering slot when the U
  // channel is ready. The clear flags are prepared for both outcomes, with
  // and without an accepted request, and the U ready selects last.
  logic [SLOTS-1:0] release_selected, release_candidate;
  (* keep = "true" *) logic [SLOTS-1:0] clear_if_hold, clear_if_release;
  (* keep = "true" *) logic accepted_clear_if_hold, accepted_clear_if_release;
  wire release_go = !i_rst && i_u_ready;
  assign release_candidate = release_valid & release_selected;
  assign accepted_clear_if_hold = !(|(live & ~handed_q & incoming_orders));
  assign accepted_clear_if_release = !(|(live & ~handed_q & ~release_candidate & incoming_orders));
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_clear_choice
    assign clear_if_hold[slot] = (predecessors_q[slot] & ~handed_q) == 0;
    assign clear_if_release[slot] = (predecessors_q[slot] & ~handed_q & ~release_candidate) == 0;
  end
`ifndef SYNTHESIS
  always_comb
    if (sim_reset_seen_q) assert (release_fire == (release_candidate & {SLOTS{release_go}}));
`endif
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_work_eligible
    // A slot's L2 block matches the presented request's; the sector match
    // adds the sector bit of a 64-byte line.
    assign incoming_blocks[slot] = (work_address[slot] >> OffsetBits) ==
        (incoming.addr >> OffsetBits);
    assign incoming_sectors[slot] = incoming_blocks[slot] &&
        (OffsetBits == 5 || work_address[slot][5] == incoming.addr[5]);
    // The slot orders the presented request: same sector, neither a prefetch.
    assign incoming_orders[slot] = incoming_sectors[slot] && !slot_prefetch[slot] &&
        !incoming_prefetch;
    assign work_eligible[slot] = work_offer[slot] && !issued_q[slot] && !parked_q[slot] &&
        pred_clear_q[slot];
  end
  for (genvar position = 0; position < WorkPositions; position++) begin : gen_work_position
    if (PREFETCH_SLOTS != 0 && position == MainSlots) begin : gen_prefetch_position
      assign work_position_eligible[position] = prefetch_work_found_q;
      assign work_position_ready[position] = 1'b0;
    end else begin : gen_slot_position
      assign work_position_eligible[position] = work_eligible[position];
      assign work_position_ready[position] = ready_q[position];
    end
  end
  coherence_work_select #(
      .SLOTS(WorkPositions),
      .LAST_CODED(PREFETCH_SLOTS != 0),
      .CODE_BITS(SlotBits)
  ) work_selector (
      .i_eligible(work_position_eligible),
      .i_ready(work_position_ready),
      .i_later(work_later_q),
      .i_last_code(prefetch_work_slot_q),
      .o_found(work_found),
      .o_pick(work_pick)
  );
  // The selected slot's position in the rotation.
  assign work_position = PREFETCH_SLOTS != 0 && int'(work_slot_q) >= MainSlots ?
      SlotBits'(MainSlots) : work_slot_q;
  if (PREFETCH_SLOTS != 0) begin : gen_prefetch_work
    // The prefetch slots rotate among themselves: the first offered slot at
    // or after the one after the last prefetch dispatched. The home parks no
    // prefetch, so the offer reads registers only.
    logic [PREFETCH_SLOTS-1:0] offered, later_q, later, later_first, offered_first;
    logic [SlotBits-1:0] pick;
    for (genvar index = 0; index < PREFETCH_SLOTS; index++) begin : gen_offered
      assign offered[index] = work_eligible[MainSlots+index] &&
          !(work_selected_q && int'(work_slot_q) == MainSlots + index);
    end
    assign later = offered & later_q;
    always_comb begin
      pick = '0;
      for (int index = 0; index < PREFETCH_SLOTS; index++) begin
        later_first[index]   = later[index];
        offered_first[index] = offered[index];
        for (int lower = 0; lower < index; lower++) begin
          if (later[lower]) later_first[index] = 1'b0;
          if (offered[lower]) offered_first[index] = 1'b0;
        end
      end
      for (int index = 0; index < PREFETCH_SLOTS; index++)
      if (|later ? later_first[index] : offered_first[index]) pick = SlotBits'(MainSlots + index);
    end
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        prefetch_work_found_q <= 1'b0;
        prefetch_work_slot_q <= SlotBits'(MainSlots);
        later_q <= '1;
      end else begin
        prefetch_work_found_q <= |offered;
        prefetch_work_slot_q  <= pick;
        if (accept_work && int'(work_slot_q) >= MainSlots)
          for (int index = 0; index < PREFETCH_SLOTS; index++)
          later_q[index] <= int'(work_slot_q) == SLOTS - 1 || MainSlots + index > int'(work_slot_q);
      end
    end
`ifndef SYNTHESIS
    always_ff @(posedge i_clk)
      if (sim_reset_seen_q && !i_rst && prefetch_work_found_q)
        assert (int'(prefetch_work_slot_q) >= MainSlots && int'(prefetch_work_slot_q) < SLOTS &&
            (work_eligible[prefetch_work_slot_q] ||
             (work_selected_q && work_slot_q == prefetch_work_slot_q)));
`endif
`ifdef FORMAL
    // Two prefetch slots offered, and the rotation prefers the second.
    if (PREFETCH_SLOTS > 1) begin : gen_rotation_cover
      always_ff @(posedge i_clk) if (!i_rst) cover (&offered[1:0] && !later_q[0] && later_q[1]);
    end
`endif
  end else begin : gen_no_prefetch_work
    assign prefetch_work_found_q = 1'b0;
    assign prefetch_work_slot_q  = '0;
  end
  // Grants rotate among the buffers holding ready results: the lowest ready
  // buffer at or after grant_next_q, else the lowest ready buffer. The pick is
  // one-hot and selects the buffer's payload directly; the payload's tid is
  // the slot.
  assign buffer_later = buffer_ready_q & buffer_later_q;
  always_comb begin
    for (int index = 0; index < RESULT_SLOTS; index++) begin
      buffer_later_first[index] = buffer_later[index];
      buffer_ready_first[index] = buffer_ready_q[index];
      for (int lower = 0; lower < index; lower++) begin
        if (buffer_later[lower]) buffer_later_first[index] = 1'b0;
        if (buffer_ready_q[lower]) buffer_ready_first[index] = 1'b0;
      end
    end
  end
  assign grant_after = |buffer_later;
  assign grant_found = |buffer_ready_q;
  assign o_image_select = grant_after ? buffer_later_first : buffer_ready_first;
  always_comb begin
    grant_zero = |(o_image_select & buffer_zero_q);
    grant_payload = '0;
    o_image_index = '0;
    for (int index = 0; index < RESULT_SLOTS; index++) begin
      grant_payload |= {(ADDR_WIDTH + 275) {o_image_select[index]}} & buffer_q[index];
      if (o_image_select[index]) o_image_index |= ResultBits'(index);
    end
    grant_pick = SlotBits'(grant_payload.tid);
  end

  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_endpoint
    assign work_identity[slot] = request_q(work[slot]);
    assign work_address[slot] = request_addr(work[slot]);
    assign slot_prefetch[slot] = PREFETCH_SLOTS != 0 ? PrefetchSlot[slot] :
        work_identity[slot][8:7] == 2'd3;
    coherence_home_endpoint #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_HARTS(1),
        .L2_NUM_MSHR(4),
        .TID(slot),
        .CLASS(PREFETCH_SLOTS == 0 ? 0 : PrefetchSlot[slot] ? 2 : 1)
    ) endpoint (
        .i_clk,
        .i_rst,
        .i_epoch(1'b0),
        .i_d_valid(i_d_valid && !i_fatal_stop && free_slot && !duplicate &&
            free_slot_index == SlotBits'(slot)),
        .o_d_ready(request_ready[slot]),
        .i_d,
        .o_work_valid(work_valid[slot]),
        .o_work_offer(work_offer[slot]),
        .o_work(work[slot]),
        .i_result_valid(grant_selected_q && grant_slot_q == SlotBits'(slot)),
        .o_result_ready(),
        .i_result(grant_q),
        .o_g_valid(grant_valid[slot]),
        // Only the selected endpoint sees a valid result; G readiness needs
        // no further qualification. The prefetcher takes every G addressed
        // to source 3 when it is presented, so a prefetch slot's grant
        // capture leaves G readiness out.
        .i_g_ready(PrefetchSlot[slot] ? 1'b1 : i_g_ready),
        .o_g(),
        .i_c_valid,
        .i_error_disposed(error_q[slot]),
        .o_c_ready(completion_ready[slot]),
        .i_c,
        .i_absorb_valid(1'b0),
        .o_absorb_ready(),
        .i_absorb('0),
        .i_cancel_valid(1'b0),
        .i_cancel('0),
        .o_u_valid(release_valid[slot]),
        .o_u_offer(release_offer[slot]),
        .i_u_ready(release_ready[slot]),
        .o_u(releases[slot]),
        .o_live(live[slot]),
        .o_pending()
    );
  end

  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 15),
      .PORTS(SLOTS)
  ) release_arbiter (
      .i_clk,
      .i_rst,
      // The release arbiter applies reset to its selection and handshake.
      .i_valid(release_offer),
      .o_ready(release_ready),
      .i_payload(releases),
      .o_valid(o_u_valid),
      .o_offer(),
      .o_selected(release_selected),
      .i_ready(i_u_ready),
`ifdef COHERENCE_HOME_CONTROL
      .i_service_stop(1'b0),
`endif
      .o_payload(o_u)
  );

  for (genvar buffer_idx = 0; buffer_idx < RESULT_SLOTS; buffer_idx++) begin : gen_buffer_lifetime
    wire allocated = accept_work && work_buffer_q == ResultBits'(buffer_idx);
    wire retried = i_retry_valid && int'(i_retry_tid) < SLOTS &&
        buffer_index_q[SlotBits'(i_retry_tid)] == ResultBits'(buffer_idx);
    wire written = accept_result && buffer_index_q[result_slot] == ResultBits'(buffer_idx);
    // The selected grant's buffer is its slot's (buffer_index_q[grant_slot_q]).
    assign grant_buffer_held[buffer_idx] = grant_selected_q &&
        grant_buffer_q == ResultBits'(buffer_idx);
    assign buffer_live_hold[buffer_idx] = (buffer_live_q[buffer_idx] || allocated) && !retried;
    assign buffer_live_next[buffer_idx] = buffer_live_hold[buffer_idx] &&
        !(grant_buffer_held[buffer_idx] && i_g_ready);
    assign buffer_ready_hold[buffer_idx] = buffer_ready_q[buffer_idx] || written;
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        buffer_live_q[buffer_idx]  <= 1'b0;
        buffer_ready_q[buffer_idx] <= 1'b0;
      end else begin
        buffer_live_q[buffer_idx] <= buffer_live_next[buffer_idx];
        buffer_ready_q[buffer_idx] <= buffer_ready_hold[buffer_idx] &&
            !(grant_buffer_held[buffer_idx] && i_g_ready);
      end
    end
  end
  // A slot's result waits from its result until its G is taken; its buffer
  // is owned from its issue until that G or a retry.
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_result_state
    assign result_valid_hold[slot] = result_valid_q[slot] || (i_result_valid && result_hit[slot]);
    assign buffer_owned_hold[slot] = (buffer_owned_q[slot] ||
        (accept_work && work_slot_q == SlotBits'(slot))) &&
        !(i_retry_valid && i_retry_tid == 6'(slot));
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        result_valid_q[slot] <= 1'b0;
        buffer_owned_q[slot] <= 1'b0;
      end else begin
        result_valid_q[slot] <= result_valid_hold[slot] && !grant_taken[slot];
        buffer_owned_q[slot] <= buffer_owned_hold[slot] && !grant_taken[slot];
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      issued_q <= '0;
      pin_valid_q <= '0;
      error_q <= '0;
      parked_q <= '0;
      counted_q <= '0;
      nofill_q <= '0;
      ready_q <= '0;
      wake_error_q <= '0;
      work_buffer_q <= '0;
      work_selected_q <= 1'b0;
      work_slot_q <= '0;
      work_next_q <= '0;
      work_later_q <= '1;
      grant_selected_q <= 1'b0;
      grant_slot_q <= '0;
      grant_next_q <= '0;
      grant_buffer_q <= '0;
      buffer_later_q <= '1;
      buffer_zero_q <= '0;
      grant_q <= '0;
      pred_clear_q <= '1;
      handed_q <= '0;
      for (int slot = 0; slot < SLOTS; slot++) begin
        predecessors_q[slot] <= '0;
        buffer_index_q[slot] <= '0;
        way_q[slot] <= '0;
      end
      for (int index = 0; index < RESULT_SLOTS; index++) buffer_q[index] <= '0;
    end else begin
      if (!work_selected_q && work_found && free_buffer) begin
        work_selected_q <= 1'b1;
        work_slot_q <= work_pick;
        work_buffer_q <= free_buffer_index;
      end
      if (work_selected_q && parked_q[work_slot_q]) work_selected_q <= 1'b0;
      if (accept_work) begin
        work_selected_q <= 1'b0;
        work_next_q <= work_position == SlotBits'(WorkPositions - 1) ? '0 : work_position + 1'b1;
        for (int position = 0; position < WorkPositions; position++)
        work_later_q[position] <= work_position == SlotBits'(WorkPositions - 1) ||
            position > int'(work_position);
        issued_q[work_slot_q] <= 1'b1;
        buffer_index_q[work_slot_q] <= work_buffer_q;
        ready_q[work_slot_q] <= 1'b0;
      end
      for (int slot = 0; slot < SLOTS; slot++)
      if (i_result_valid && result_hit[slot]) error_q[slot] <= result.error;
      if (accept_result) begin
        buffer_q[buffer_index_q[result_slot]] <= {
          result.opcode, result.q, result.tid, result.addr, 256'b0, result.error
        };
        buffer_zero_q[buffer_index_q[result_slot]] <=
            result.error || result.opcode == coherence_pkg::GrantAck;
      end
      if (!grant_selected_q && !grant_found && accept_result) begin
        grant_selected_q <= 1'b1;
        grant_slot_q <= result_slot;
        grant_buffer_q <= buffer_index_q[result_slot];
        grant_q <= result;
        grant_q.data <= result.error || result.opcode == coherence_pkg::GrantAck ?
            256'b0 : result.data;
      end
      if (!grant_selected_q && grant_found) begin
        grant_selected_q <= 1'b1;
        grant_slot_q <= grant_pick;
        grant_buffer_q <= o_image_index;
        grant_q <= grant_payload;
        grant_q.data <= grant_zero ? 256'b0 : i_image_data;
      end
      if (accept_grant) begin
        grant_selected_q <= 1'b0;
        grant_next_q <= grant_buffer_q == ResultBits'(RESULT_SLOTS - 1) ? '0 :
            grant_buffer_q + 1'b1;
        for (int index = 0; index < RESULT_SLOTS; index++)
        buffer_later_q[index] <= grant_buffer_q == ResultBits'(RESULT_SLOTS - 1) ||
            index > int'(grant_buffer_q);
      end
      handed_q <= (handed_q | ({SLOTS{accept_result && work_identity[result_slot][8:7] == 2'd2}} &
          (SLOTS'(1) << result_slot))) & ~release_fire;
      for (int slot = 0; slot < SLOTS; slot++) begin
        predecessors_q[slot] <= predecessors_q[slot] & ~release_fire & ~handed_q;
        if (release_fire[slot]) begin
          issued_q[slot] <= 1'b0;
          pin_valid_q[slot] <= 1'b0;
          error_q[slot] <= 1'b0;
          wake_error_q[slot] <= 1'b0;
          counted_q[slot] <= 1'b0;
          ready_q[slot] <= 1'b0;
        end
        if (accept_request && free_slot_index == SlotBits'(slot)) begin
          for (int older = 0; older < SLOTS; older++) begin
            predecessors_q[slot][older] <= live[older] && !release_fire[older] &&
                !handed_q[older] && incoming_orders[older];
          end
          nofill_q[slot] <= incoming_prefetch && |(live & ~slot_prefetch & incoming_blocks);
        end else if (accept_request && !incoming_prefetch && incoming_blocks[slot] &&
                     live[slot] && slot_prefetch[slot]) begin
          nofill_q[slot] <= 1'b1;
        end
        pred_clear_q[slot] <= accept_request && free_slot_index == SlotBits'(slot) ?
            (release_go ? accepted_clear_if_release : accepted_clear_if_hold) :
            (release_go ? clear_if_release[slot] : clear_if_hold[slot]);
        if (i_count_valid && i_count_tid == 6'(slot)) counted_q[slot] <= 1'b1;
        if (i_park[slot]) parked_q[slot] <= 1'b1;
        if (i_wake[slot]) begin
          parked_q[slot] <= 1'b0;
          ready_q[slot] <= 1'b1;
          wake_error_q[slot] <= i_wake_error[slot];
        end
        if (i_pin_valid && i_pin_tid == 6'(slot)) begin
          pin_valid_q[slot] <= 1'b1;
          way_q[slot] <= i_pin_way;
        end
        if (i_retry_valid && i_retry_tid == 6'(slot)) begin
          issued_q[slot] <= 1'b0;
          parked_q[slot] <= i_retry_park;
        end
      end
    end
  end

  if (SLOTS < 1 || SLOTS > coherence_pkg::completion_count(
          1
      ) || RESULT_SLOTS < 1 || RESULT_SLOTS > SLOTS || Sets < 2 || PREFETCH_SLOTS >
          coherence_pkg::PrefetchIds || PREFETCH_SLOTS >= SLOTS) begin : gen_invalid
    initial $fatal(1, "coherence_home_completions: invalid capacity");
  end
`ifndef SYNTHESIS
  logic [RESULT_SLOTS-1:0] reference_buffer_live;
  always_comb begin
    reference_buffer_live = buffer_live_q;
    if (accept_work) reference_buffer_live[work_buffer_q] = 1'b1;
    if (accept_grant) reference_buffer_live[buffer_index_q[grant_slot_q]] = 1'b0;
    for (int slot = 0; slot < SLOTS; slot++)
    if (i_retry_valid && i_retry_tid == 6'(slot))
      reference_buffer_live[buffer_index_q[slot]] = 1'b0;
    if (sim_reset_seen_q && !i_rst) assert (buffer_live_next == reference_buffer_live);
  end
  always_ff @(posedge i_clk) begin
    if (sim_reset_seen_q && !i_rst)
      assert (o_d_ready == (!i_fatal_stop && free_slot && !duplicate &&
          request_ready[free_slot_index]));
  end
  // Prefetch slots: the partition holds, a prefetch's flag is set whenever a
  // non-prefetch request for its block is live, and the slot's G is taken
  // exactly when the table accepts it.
  always_ff @(posedge i_clk) begin
    if (sim_reset_seen_q && !i_rst) begin
      assert (|grant_taken == accept_grant);
      for (int slot = 0; slot < SLOTS; slot++) begin
        // A live slot holds the legal request it admitted.
        if (live[slot])
          assert (coherence_pkg::legal_opcode(work_identity[slot], work[slot][ADDR_WIDTH+311-:4]));
        if (PREFETCH_SLOTS != 0 && live[slot])
          assert (PrefetchSlot[slot] == (work_identity[slot][8:7] == 2'd3));
        if (nofill_q[slot] && live[slot]) assert (slot_prefetch[slot]);
        // The pairwise check compares every two slots' blocks; the proof runs
        // it in a task of its own with the addresses in a small window.
`ifndef FORMAL
        `define COMPLETIONS_PAIR_CHECK
`elsif COHERENCE_COMPLETIONS_PAIRS
        `define COMPLETIONS_PAIR_CHECK
`endif
`ifdef COMPLETIONS_PAIR_CHECK
        for (int other = 0; other < SLOTS; other++)
        if (live[slot] && slot_prefetch[slot] && live[other] && !slot_prefetch[other] &&
            (work_address[slot] >> OffsetBits) == (work_address[other] >> OffsetBits))
          assert (nofill_q[slot]);
        `undef COMPLETIONS_PAIR_CHECK
`endif
      end
    end
  end
`ifdef FORMAL
  // The consumer's side of PREFETCH_SLOTS: a prefetch slot's G is accepted
  // when presented.
  always_comb
    if (!i_rst && PREFETCH_SLOTS != 0 && o_g_valid && PrefetchSlot[grant_slot_q])
      assume (i_g_ready);
`else
  always_ff @(posedge i_clk)
    if (sim_reset_seen_q && !i_rst && PREFETCH_SLOTS != 0 && o_g_valid &&
        PrefetchSlot[grant_slot_q])
      assert (i_g_ready);
`endif
`ifndef FORMAL
  // Simulation checks o_put_busy against the direct comparison. The proof
  // leaves this check out: its engine does not close the address relation.
  logic [ADDR_WIDTH-1:0] reference_put_addr_q;
  logic reference_put_valid_q;
  logic [SLOTS-1:0] reference_put_conflicts;
  always_ff @(posedge i_clk) begin
    reference_put_addr_q  <= i_next_put_addr;
    reference_put_valid_q <= !i_rst;
    if (sim_reset_seen_q && !i_rst && reference_put_valid_q)
      assert (o_put_busy == (|reference_put_conflicts));
  end
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_reference_put_conflict
    assign reference_put_conflicts[slot] = live[slot] && !slot_prefetch[slot] &&
        (work_address[slot] >> 5) == (reference_put_addr_q >> 5);
  end
`endif
  logic [SetBits-1:0] reference_query_set_q;
  logic [WAYS-1:0] reference_exclude;
  always_comb begin
    reference_exclude = '0;
    for (int slot = 0; slot < SLOTS; slot++)
    if (pin_valid_q[slot] &&
        work_address[slot][OffsetBits+:SetBits] == i_query_addr[OffsetBits+:SetBits])
      reference_exclude[way_q[slot]] = 1'b1;
  end
  always_ff @(posedge i_clk) begin
    reference_query_set_q <= i_query_addr[OffsetBits+:SetBits];
    if (sim_reset_seen_q && !i_rst && reference_query_set_q == i_query_addr[OffsetBits+:SetBits])
      assert (o_exclude == reference_exclude);
`ifdef COHERENCE_HOME_CONTROL
    if (!i_rst && i_query_held) assert (o_exclude == reference_exclude);
`endif
  end
  // The buffers holding ready results, and the first of them at or after
  // grant_next_q in circular order.
  logic [RESULT_SLOTS-1:0] reference_buffer_ready;
  logic [  ResultBits-1:0] reference_grant_buffer;
  always_comb begin
    reference_buffer_ready = '0;
    for (int slot = 0; slot < SLOTS; slot++)
    if (result_valid_q[slot] && buffer_owned_q[slot])
      reference_buffer_ready[buffer_index_q[slot]] = 1'b1;
    reference_grant_buffer = '0;
    for (int offset = RESULT_SLOTS - 1; offset >= 0; offset--)
    if (buffer_ready_q[(int'(grant_next_q)+offset)%RESULT_SLOTS])
      reference_grant_buffer = ResultBits'((int'(grant_next_q) + offset) % RESULT_SLOTS);
  end
  always_ff @(posedge i_clk) begin
    if (sim_reset_seen_q && !i_rst) begin
      for (int slot = 0; slot < SLOTS; slot++) begin
        assert (pred_clear_q[slot] == (predecessors_q[slot] == 0));
        // Only a live DMA request hands its sector to younger requests early,
        // and a prefetch has no predecessor and is no one's.
        if (handed_q[slot]) assert (live[slot] && work_identity[slot][8:7] == 2'd2);
        if (slot_prefetch[slot] && live[slot]) assert (predecessors_q[slot] == 0);
        for (int other = 0; other < SLOTS; other++)
        if (slot_prefetch[other] && live[other]) assert (!predecessors_q[slot][other]);
      end
      if (accept_result) assert (result_hit == SLOTS'(1) << result_slot);
      for (int slot = 0; slot < SLOTS; slot++)
      assert (result_hit[slot] == (result.tid == 6'(slot) && issued_q[slot] &&
          buffer_owned_q[slot] && !result_valid_q[slot] &&
          result.opcode <= coherence_pkg::GrantFail && result.q == work_identity[slot] &&
          result.addr == work_address[slot]));
      assert (int'(grant_next_q) < RESULT_SLOTS && int'(work_next_q) < WorkPositions);
      for (int position = 0; position < WorkPositions; position++)
      assert (work_later_q[position] == (position >= int'(work_next_q)));
      // The selector picks an eligible slot.
      if (!work_selected_q && work_found && free_buffer)
        assert (int'(work_pick) < SLOTS && work_eligible[work_pick]);
      // A ready buffer holds the result of the slot that owns it.
      for (int index = 0; index < RESULT_SLOTS; index++) begin
        assert (buffer_later_q[index] == (index >= int'(grant_next_q)));
        assert (buffer_ready_q[index] == reference_buffer_ready[index]);
        if (buffer_ready_q[index])
          assert (buffer_zero_q[index] == (buffer_q[index][0] || grant_opcode(
              buffer_q[index]
          ) == coherence_pkg::GrantAck));
      end
      assert (grant_found == (|result_valid_q));
      if (grant_found) begin
        assert (o_image_select == RESULT_SLOTS'(1) << reference_grant_buffer);
        assert (o_image_index == reference_grant_buffer);
        assert (grant_payload == buffer_q[reference_grant_buffer]);
        assert (int'(grant_pick) < SLOTS && result_valid_q[grant_pick] &&
            buffer_index_q[grant_pick] == reference_grant_buffer);
        assert (grant_zero == (error_q[grant_pick] || grant_opcode(
            buffer_q[reference_grant_buffer]
        ) == coherence_pkg::GrantAck));
      end else begin
        assert (o_image_select == '0);
      end
      if (grant_selected_q) assert (buffer_index_q[grant_slot_q] == grant_buffer_q);
      assert ($onehot0(grant_valid));
      assert (o_g_valid == (|grant_valid));
      assert (grant_valid == grant_slot_held);
      if (grant_selected_q) begin
        assert (grant_q.opcode <= coherence_pkg::GrantFail);
        assert (grant_q.q == work_identity[grant_slot_q]);
        assert (grant_q.tid == 6'(grant_slot_q));
        assert (grant_q.addr == work_address[grant_slot_q]);
        assert (grant_q.error == error_q[grant_slot_q]);
      end
      assert ($onehot0(completion_ready));
      assert ($countones(buffer_live_q) == $countones(buffer_owned_q));
      if (accept_work) begin
        assert (predecessors_q[work_slot_q] == 0);
        assert (!buffer_live_q[work_buffer_q] && !parked_q[work_slot_q]);
      end
      for (int slot = 0; slot < SLOTS; slot++) begin
        assert (!predecessors_q[slot][slot]);
        if (i_park[slot]) assert (o_waiting[slot]);
        if (i_wake[slot]) assert (parked_q[slot]);
        if (parked_q[slot]) assert (work_valid[slot] && !issued_q[slot]);
        assert ((predecessors_q[slot] & ~live) == 0);
        if (buffer_owned_q[slot]) begin
          assert (issued_q[slot] && work_valid[slot]);
          assert (buffer_live_q[buffer_index_q[slot]]);
          for (int other = slot + 1; other < SLOTS; other++)
          if (buffer_owned_q[other]) assert (buffer_index_q[slot] != buffer_index_q[other]);
        end
        if (result_valid_q[slot]) begin
          assert (grant_opcode(buffer_q[buffer_index_q[slot]]) <= coherence_pkg::GrantFail);
          assert (buffer_owned_q[slot] && work_valid[slot]);
          assert (result_identity(
              buffer_q[buffer_index_q[slot]]
          ) == {work_identity[slot], 6'(slot), work_address[slot], error_q[slot]});
        end
        if (pin_valid_q[slot]) assert (issued_q[slot] && live[slot]);
        if (release_fire[slot]) assert (!buffer_owned_q[slot]);
        if (i_retry_valid && i_retry_tid == 6'(slot))
          assert (issued_q[slot] && buffer_owned_q[slot] && !pin_valid_q[slot] &&
              !result_valid_q[slot]);
        if (i_pin_valid && i_pin_tid == 6'(slot))
          assert (issued_q[slot] && buffer_owned_q[slot] && !result_valid_q[slot] &&
              !pin_valid_q[slot] && int'(i_pin_way) < WAYS);
      end
    end
  end
`endif
`ifdef COHERENCE_HOME_CONTROL
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      assert ((ready_q & ~live) == 0 && (wake_error_q & ~live) == 0);
      // The home never parks or wakes a prefetch.
      for (int slot = 0; slot < SLOTS; slot++)
      if (live[slot] && work_identity[slot][8:7] == 2'd3) begin
        assert (!parked_q[slot] && !wake_error_q[slot] && !ready_q[slot]);
        assert (!i_park[slot]);
      end
      assert (int'(work_slot_q) < SLOTS && int'(work_buffer_q) < RESULT_SLOTS);
      assert ((i_fill_waiting & ~parked_q) == 0);
      assert ((i_fill_seated & (~work_valid | pin_valid_q | result_valid_q)) == 0);
      assert ((i_fill_seated & wake_error_q) == 0);
      assert ((wake_error_q & ~(ready_q | issued_q)) == 0);
      if (grant_selected_q) assert (result_valid_q[grant_slot_q] && buffer_owned_q[grant_slot_q]);
      if (work_selected_q) begin
        assert (work_valid[work_slot_q] && !issued_q[work_slot_q]);
        assert (!buffer_owned_q[work_slot_q]);
        assert (!buffer_live_q[work_buffer_q]);
      end
      for (int engine = 0; engine < RESULT_SLOTS; engine++) begin
        if (i_engine_busy[engine]) begin
          assert (int'(i_engine_tid[engine]) < SLOTS);
          assert (issued_q[SlotBits'(i_engine_tid[engine])]);
          assert (buffer_owned_q[SlotBits'(i_engine_tid[engine])]);
          assert (!result_valid_q[SlotBits'(i_engine_tid[engine])]);
          if (i_engine_unpinned[engine]) assert (!pin_valid_q[SlotBits'(i_engine_tid[engine])]);
          if (i_engine_pinned[engine]) assert (pin_valid_q[SlotBits'(i_engine_tid[engine])]);
          assert (i_engine_initial_error[engine] == wake_error_q[SlotBits'(i_engine_tid[engine])]);
          assert (buffer_index_q[SlotBits'(i_engine_tid[engine])] == ResultBits'(engine));
          assert (work_address[SlotBits'(i_engine_tid[engine])] == i_engine_addr[engine]);
        end
      end
    end
  end
`else
`ifdef FORMAL
  logic f_past_valid = 1'b0;
  logic [SLOTS-1:0] f_granted_q;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (i_rst) f_granted_q <= '0;
    else begin
      for (int slot = 0; slot < SLOTS; slot++) begin
        if (accept_request && free_slot_index == SlotBits'(slot)) f_granted_q[slot] <= 0;
        if (accept_grant && grant_slot_q == SlotBits'(slot)) f_granted_q[slot] <= 1;
        if (release_fire[slot]) f_granted_q[slot] <= 0;
      end
    end
    if (!i_rst) begin
`ifdef COHERENCE_COMPLETIONS_PAIRS
      // Four blocks in two sets cover every block relation of the slots.
      if (i_d_valid) assume (incoming.addr[ADDR_WIDTH-1:8] == '0);
`endif
      if (i_count_valid) begin
        assume (int'(i_count_tid) < SLOTS);
        assume (issued_q[SlotBits'(i_count_tid)]);
      end
      assume ((i_park & ~o_waiting) == 0);
      assume ((i_wake & ~parked_q) == 0);
      assume ((i_park & i_wake) == 0);
      // The home parks no prefetch (its composed proof asserts this), so a
      // prefetch is never READY.
      assume ((i_park & slot_prefetch & live) == 0);
      if (i_pin_valid) begin
        assume (int'(i_pin_tid) < SLOTS && int'(i_pin_way) < WAYS);
        assume (issued_q[SlotBits'(i_pin_tid)] && buffer_owned_q[SlotBits'(i_pin_tid)]);
        assume (!pin_valid_q[SlotBits'(i_pin_tid)] && !result_valid_q[SlotBits'(i_pin_tid)]);
      end
      if (i_retry_valid) begin
        assume (int'(i_retry_tid) < SLOTS);
        assume (issued_q[SlotBits'(i_retry_tid)] && buffer_owned_q[SlotBits'(i_retry_tid)]);
        assume (!pin_valid_q[SlotBits'(i_retry_tid)] && !result_valid_q[SlotBits'(i_retry_tid)]);
        assume (!i_pin_valid || i_pin_tid != i_retry_tid);
        assume (!accept_result || result.tid != i_retry_tid);
      end
    end
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      for (int slot = 0; slot < SLOTS; slot++) begin
        if ($past(live[slot]) && !live[slot]) assert ($past(release_fire[slot]));
        if ($past(pin_valid_q[slot]) && !$past(release_fire[slot])) begin
          assert (pin_valid_q[slot]);
          assert (way_q[slot] == $past(way_q[slot]));
        end
        if (release_fire[slot]) assert (f_granted_q[slot]);
        if (live[slot]) begin
          for (int other = slot + 1; other < SLOTS; other++)
          if (live[other]) assert (work_identity[slot] != work_identity[other]);
        end
        if (issued_q[slot]) assert (predecessors_q[slot] == 0);
      end
      if ($past(o_g_valid && !i_g_ready)) begin
        assert (o_g_valid && o_g == $past(o_g));
      end
      if ($past(o_u_valid && !i_u_ready)) begin
        assert (o_u_valid && o_u == $past(o_u));
      end
      if ($past(o_work_valid && !i_work_ready) && !i_fatal_stop) begin
        assert (o_work_valid && o_work == $past(o_work));
        assert (o_work_tid == $past(o_work_tid));
        assert (o_work_buffer == $past(o_work_buffer));
        assert (o_work_error == $past(o_work_error));
      end
      cover ($countones(live) == SLOTS && $countones(buffer_owned_q) == RESULT_SLOTS);
      cover (accept_work && |f_granted_q);
      cover (o_u_valid && |result_valid_q && i_u_ready);
      // A prefetch dispatched with no fill, and a handed DMA request beside a
      // live prefetch.
      cover (accept_work && o_work_nofill);
      cover (|(handed_q & live) && |(slot_prefetch & live));
    end
  end
  if (PREFETCH_SLOTS != 0) begin : gen_prefetch_slot_cover
    // A prefetch slot's G taken.
    always_ff @(posedge i_clk)
      if (f_past_valid && !i_rst && !$past(i_rst))
        cover (accept_grant && PrefetchSlot[grant_slot_q]);
  end
`endif
`endif
endmodule
