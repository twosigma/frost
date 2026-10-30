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
    parameter int unsigned SLOTS = 19,
    parameter int unsigned RESULT_SLOTS = 8,
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
  `FROST_COHERENCE_TYPES(ADDR_WIDTH)
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);
  localparam int unsigned Sets = CACHE_BYTES / (LINE_BYTES * WAYS);
  localparam int unsigned SetBits = $clog2(Sets);
  logic [SLOTS-1:0] live, request_ready, work_valid, work_offer, grant_valid, completion_ready;
  logic [SLOTS-1:0] release_valid, release_ready, release_fire;
  logic [SLOTS-1:0] issued_q, buffer_owned_q, result_valid_q, pin_valid_q, error_q;
  logic [SLOTS-1:0] predecessors_q[SLOTS];
  logic [SLOTS-1:0] parked_q, ready_q, wake_error_q, counted_q;
  logic [ResultBits-1:0] work_buffer_q;
  logic [SLOTS-1:0][ADDR_WIDTH+311:0] work;
  logic [SLOTS-1:0][ADDR_WIDTH+14:0] releases;
  logic [SLOTS-1:0][8:0] work_identity;
  logic [SLOTS-1:0][ADDR_WIDTH-1:0] work_address;
  logic [ResultBits-1:0] buffer_index_q[SLOTS];
  logic [WayBits-1:0] way_q[SLOTS];
  logic [RESULT_SLOTS-1:0] buffer_live_q, buffer_live_next;
  logic [ADDR_WIDTH+274:0] buffer_q[RESULT_SLOTS];
  logic free_slot, duplicate, free_buffer;
  logic [  SlotBits-1:0] free_slot_index;
  logic [ResultBits-1:0] free_buffer_index;
  logic work_selected_q, work_found;
  logic [SLOTS-1:0] work_eligible;
  logic [SlotBits-1:0] work_slot_q, work_next_q, work_pick;
  localparam int unsigned GrantGroupBits = 6;
  localparam int unsigned GrantGroups = (SLOTS + GrantGroupBits - 1) / GrantGroupBits;
  logic grant_selected_q, grant_found, grant_after, grant_zero;
  logic [SlotBits-1:0] grant_slot_q, grant_next_q, grant_pick;
  // grant_later_q[slot] holds slot >= grant_next_q. buffer_select_q is the
  // one-hot form of buffer_index_q. grant_zero_q marks a ready result whose
  // grant carries zero data: an error or a GrantAck.
  logic [SLOTS-1:0] grant_later_q, grant_zero_q, grant_later_first, grant_ready_first;
  logic [SLOTS-1:0][RESULT_SLOTS-1:0] buffer_select_q;
  (* keep = "true" *) logic [SLOTS-1:0] grant_later, grant_select;
  (* keep = "true" *) logic [GrantGroups-1:0] grant_later_groups, grant_ready_groups;
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

  // Sector comparisons with the next put address are registered. A slot
  // live across the edge keeps its address; a slot admitted on the edge
  // takes the accepted request's address; a released slot is not live.
  logic [SLOTS-1:0] put_sector_live_q;
  logic put_incoming_sector_q, request_accepted_q;
  always_ff @(posedge i_clk) begin
    put_incoming_sector_q <= (incoming.addr >> 5) == (i_next_put_addr >> 5);
    request_accepted_q <= accept_request;
    for (int slot = 0; slot < SLOTS; slot++)
    put_sector_live_q[slot] <= live[slot] && (work_address[slot] >> 5) == (i_next_put_addr >> 5);
  end
  assign o_put_busy = |(live & put_sector_live_q) || (request_accepted_q && put_incoming_sector_q);
  // Each slot's set comparison with the query is registered. A pinned slot
  // keeps its address across the edge, so o_exclude is exact whenever the
  // query's set is unchanged, as it is from tag selection through response.
  logic [SLOTS-1:0] query_set_q;
  always_ff @(posedge i_clk) begin
    for (int slot = 0; slot < SLOTS; slot++)
    query_set_q[slot] <= work_address[slot][OffsetBits+:SetBits] ==
        i_query_addr[OffsetBits+:SetBits];
  end
  always_comb begin
    free_slot = 1'b0;
    free_slot_index = '0;
    duplicate = 1'b0;
    free_buffer = 1'b0;
    free_buffer_index = '0;
    o_exclude = '0;
    for (int slot = SLOTS - 1; slot >= 0; slot--) begin
      if (!live[slot]) begin
        free_slot = 1'b1;
        free_slot_index = SlotBits'(slot);
      end
      if (live[slot]) duplicate |= work_identity[slot] == incoming.q;
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

  // Every idle endpoint applies the same admission checks to the request, so
  // any idle endpoint's readiness stands for the free slot's.
  assign o_d_ready = !i_rst && !i_fatal_stop && !duplicate && |(request_ready & ~live);
  assign o_work_offer = !i_fatal_stop && work_selected_q && !parked_q[work_slot_q];
  assign o_work_valid = !i_rst && o_work_offer;
  assign o_work = work[work_slot_q];
  assign o_work_tid = 6'(work_slot_q);
  assign o_work_buffer = work_buffer_q;
  assign o_work_error = wake_error_q[work_slot_q];
  assign o_work_counted = counted_q[work_slot_q];
  assign o_waiting_request = work;
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_waiting
    assign o_waiting_offer[slot] = work_offer[slot] && !issued_q[slot] &&
        !parked_q[slot] && !ready_q[slot] &&
        !(work_selected_q && work_slot_q == SlotBits'(slot));
    assign o_waiting[slot] = !i_rst && o_waiting_offer[slot];
  end
  // A presented result matches at most one slot: the one its tid names.
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_result_hit
    assign result_hit[slot] = result.tid == 6'(slot) && issued_q[slot] &&
        buffer_owned_q[slot] && !result_valid_q[slot] &&
        result.opcode <= coherence_pkg::GrantFail && result.q == work_identity[slot] &&
        result.addr == work_address[slot];
  end
  assign result_matches = |result_hit;
  assign result_slot = SlotBits'(result.tid);
  assign o_result_ready = !i_rst && result_matches;
  // The selected grant's endpoint is in Work with a matching result, so the
  // grant register alone presents G. Every G consumer applies the same reset.
  assign o_g_valid = grant_selected_q;
  assign o_g = grant_q;
  assign o_c_ready = |completion_ready;

  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_work_eligible
    assign work_eligible[slot] = work_offer[slot] && !issued_q[slot] && !parked_q[slot] &&
        predecessors_q[slot] == 0;
  end
  coherence_work_select #(
      .SLOTS(SLOTS)
  ) work_selector (
      .i_eligible(work_eligible),
      .i_ready(ready_q),
      .i_next(work_next_q),
      .o_found(work_found),
      .o_pick(work_pick)
  );
  // Grants rotate among ready results: the lowest ready slot at or after
  // grant_next_q, else the lowest ready slot. Each slot's priority comes from
  // six-slot group summaries and its own group's lower slots; the pick, its
  // result buffer, its zero-data condition and its payload are one-hot.
  assign grant_later = result_valid_q & grant_later_q;
  for (genvar group_index = 0; group_index < GrantGroups; group_index++) begin : gen_grant_group
    localparam int unsigned Base  = group_index * GrantGroupBits;
    localparam int unsigned Width = SLOTS - Base < GrantGroupBits ? SLOTS - Base : GrantGroupBits;
    assign grant_later_groups[group_index] = |grant_later[Base+:Width];
    assign grant_ready_groups[group_index] = |result_valid_q[Base+:Width];
  end
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_grant_first
    localparam int unsigned Group  = slot / GrantGroupBits;
    localparam int unsigned Offset = slot % GrantGroupBits;
    logic later_below, ready_below;
    always_comb begin
      later_below = 1'b0;
      ready_below = 1'b0;
      for (int group_index = 0; group_index < int'(Group); group_index++) begin
        later_below |= grant_later_groups[group_index];
        ready_below |= grant_ready_groups[group_index];
      end
      for (int lower = 0; lower < int'(Offset); lower++) begin
        later_below |= grant_later[Group*GrantGroupBits+lower];
        ready_below |= result_valid_q[Group*GrantGroupBits+lower];
      end
    end
    assign grant_later_first[slot] = grant_later[slot] && !later_below;
    assign grant_ready_first[slot] = result_valid_q[slot] && !ready_below;
  end
  assign grant_after  = |grant_later_groups;
  assign grant_found  = |grant_ready_groups;
  assign grant_select = grant_after ? grant_later_first : grant_ready_first;
  always_comb begin
    grant_pick = '0;
    grant_zero = |(grant_select & grant_zero_q);
    for (int slot = 0; slot < SLOTS; slot++) if (grant_select[slot]) grant_pick |= SlotBits'(slot);
    for (int index = 0; index < RESULT_SLOTS; index++) begin
      o_image_select[index] = 1'b0;
      for (int slot = 0; slot < SLOTS; slot++)
      if (grant_select[slot] && buffer_select_q[slot][index]) o_image_select[index] = 1'b1;
    end
    grant_payload = '0;
    o_image_index = '0;
    for (int index = 0; index < RESULT_SLOTS; index++) begin
      grant_payload |= {(ADDR_WIDTH + 275) {o_image_select[index]}} & buffer_q[index];
      if (o_image_select[index]) o_image_index |= ResultBits'(index);
    end
  end

  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_endpoint
    assign work_identity[slot] = request_q(work[slot]);
    assign work_address[slot]  = request_addr(work[slot]);
    coherence_home_endpoint #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_HARTS(1),
        .L2_NUM_MSHR(4),
        .TID(slot)
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
        .i_g_ready(i_g_ready && grant_selected_q && grant_slot_q == SlotBits'(slot)),
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
      .i_valid(release_valid),
      .o_ready(release_ready),
      .i_payload(releases),
      .o_valid(o_u_valid),
      .o_offer(),
      .i_ready(i_u_ready),
`ifdef COHERENCE_HOME_CONTROL
      .i_service_stop(1'b0),
`endif
      .o_payload(o_u)
  );

  for (genvar buffer_idx = 0; buffer_idx < RESULT_SLOTS; buffer_idx++) begin : gen_buffer_lifetime
    wire allocated = accept_work && work_buffer_q == ResultBits'(buffer_idx);
    wire granted = accept_grant && buffer_index_q[grant_slot_q] == ResultBits'(buffer_idx);
    wire retried = i_retry_valid && int'(i_retry_tid) < SLOTS &&
        buffer_index_q[SlotBits'(i_retry_tid)] == ResultBits'(buffer_idx);
    assign buffer_live_next[buffer_idx] =
        (buffer_live_q[buffer_idx] || allocated) && !granted && !retried;
    always_ff @(posedge i_clk) begin
      if (i_rst) buffer_live_q[buffer_idx] <= 1'b0;
      else buffer_live_q[buffer_idx] <= buffer_live_next[buffer_idx];
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      issued_q <= '0;
      buffer_owned_q <= '0;
      result_valid_q <= '0;
      pin_valid_q <= '0;
      error_q <= '0;
      parked_q <= '0;
      counted_q <= '0;
      ready_q <= '0;
      wake_error_q <= '0;
      work_buffer_q <= '0;
      work_selected_q <= 1'b0;
      work_slot_q <= '0;
      work_next_q <= '0;
      grant_selected_q <= 1'b0;
      grant_slot_q <= '0;
      grant_next_q <= '0;
      grant_later_q <= '1;
      grant_zero_q <= '0;
      grant_q <= '0;
      for (int slot = 0; slot < SLOTS; slot++) begin
        predecessors_q[slot] <= '0;
        buffer_index_q[slot] <= '0;
        buffer_select_q[slot] <= RESULT_SLOTS'(1);
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
        work_next_q <= work_slot_q == SlotBits'(SLOTS - 1) ? '0 : work_slot_q + 1'b1;
        issued_q[work_slot_q] <= 1'b1;
        buffer_owned_q[work_slot_q] <= 1'b1;
        buffer_index_q[work_slot_q] <= work_buffer_q;
        buffer_select_q[work_slot_q] <= RESULT_SLOTS'(1) << work_buffer_q;
        ready_q[work_slot_q] <= 1'b0;
      end
      for (int slot = 0; slot < SLOTS; slot++)
      if (i_result_valid && result_hit[slot]) begin
        result_valid_q[slot] <= 1'b1;
        error_q[slot] <= result.error;
        grant_zero_q[slot] <= result.error || result.opcode == coherence_pkg::GrantAck;
      end
      if (accept_result) begin
        buffer_q[buffer_index_q[result_slot]] <= {
          result.opcode, result.q, result.tid, result.addr, 256'b0, result.error
        };
      end
      if (!grant_selected_q && !grant_found && accept_result) begin
        grant_selected_q <= 1'b1;
        grant_slot_q <= result_slot;
        grant_q <= result;
        grant_q.data <= result.error || result.opcode == coherence_pkg::GrantAck ?
            256'b0 : result.data;
      end
      if (!grant_selected_q && grant_found) begin
        grant_selected_q <= 1'b1;
        grant_slot_q <= grant_pick;
        grant_q <= grant_payload;
        grant_q.data <= grant_zero ? 256'b0 : i_image_data;
      end
      if (accept_grant) begin
        grant_selected_q <= 1'b0;
        grant_next_q <= grant_slot_q == SlotBits'(SLOTS - 1) ? '0 : grant_slot_q + 1'b1;
        for (int slot = 0; slot < SLOTS; slot++)
        grant_later_q[slot] <= grant_slot_q == SlotBits'(SLOTS - 1) || slot > int'(grant_slot_q);
        result_valid_q[grant_slot_q] <= 1'b0;
        buffer_owned_q[grant_slot_q] <= 1'b0;
      end
      for (int slot = 0; slot < SLOTS; slot++) begin
        predecessors_q[slot] <= predecessors_q[slot] & ~release_fire;
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
                (work_address[older] >> 5) == (incoming.addr >> 5);
          end
        end
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
          buffer_owned_q[slot] <= 1'b0;
        end
      end
    end
  end

  if (SLOTS < 1 || SLOTS > coherence_pkg::completion_count(
          1
      ) || RESULT_SLOTS < 1 || RESULT_SLOTS > SLOTS || Sets < 2) begin : gen_invalid
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
    assert (buffer_live_next == reference_buffer_live);
  end
  always_ff @(posedge i_clk) begin
    if (!i_rst)
      assert (o_d_ready == (!i_fatal_stop && free_slot && !duplicate &&
          request_ready[free_slot_index]));
  end
`ifndef FORMAL
  // Simulation checks o_put_busy against the direct comparison. The proof
  // leaves this check out: its engine does not close the address relation.
  logic [ADDR_WIDTH-1:0] reference_put_addr_q;
  logic reference_put_valid_q;
  logic [SLOTS-1:0] reference_put_conflicts;
  always_ff @(posedge i_clk) begin
    reference_put_addr_q  <= i_next_put_addr;
    reference_put_valid_q <= !i_rst;
    if (!i_rst && reference_put_valid_q) assert (o_put_busy == (|reference_put_conflicts));
  end
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_reference_put_conflict
    assign reference_put_conflicts[slot] = live[slot] &&
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
    if (!i_rst && reference_query_set_q == i_query_addr[OffsetBits+:SetBits])
      assert (o_exclude == reference_exclude);
`ifdef COHERENCE_HOME_CONTROL
    if (!i_rst && i_query_held) assert (o_exclude == reference_exclude);
`endif
  end
  logic [SlotBits-1:0] reference_grant_pick;
  always_comb begin
    reference_grant_pick = '0;
    for (int offset = SLOTS - 1; offset >= 0; offset--)
    if (result_valid_q[(int'(grant_next_q)+offset)%SLOTS])
      reference_grant_pick = SlotBits'((int'(grant_next_q) + offset) % SLOTS);
  end
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (accept_result) assert (result_hit == SLOTS'(1) << result_slot);
      assert (int'(grant_next_q) < SLOTS);
      for (int slot = 0; slot < SLOTS; slot++) begin
        assert (grant_later_q[slot] == (slot >= int'(grant_next_q)));
        assert (buffer_select_q[slot] == RESULT_SLOTS'(1) << buffer_index_q[slot]);
        if (result_valid_q[slot])
          assert (grant_zero_q[slot] == (error_q[slot] || grant_opcode(
              buffer_q[buffer_index_q[slot]]
          ) == coherence_pkg::GrantAck));
      end
      assert (grant_found == (|result_valid_q));
      if (grant_found) begin
        assert (grant_pick == reference_grant_pick);
        assert (grant_select == SLOTS'(1) << grant_pick);
        assert (o_image_select == RESULT_SLOTS'(1) << buffer_index_q[grant_pick]);
        assert (o_image_index == buffer_index_q[grant_pick]);
        assert (grant_payload == buffer_q[buffer_index_q[grant_pick]]);
        assert (grant_zero == (error_q[grant_pick] || grant_opcode(
            buffer_q[buffer_index_q[grant_pick]]
        ) == coherence_pkg::GrantAck));
      end else begin
        assert (grant_select == '0 && o_image_select == '0);
      end
      assert ($onehot0(grant_valid));
      assert (o_g_valid == (|grant_valid));
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
      if (i_count_valid) begin
        assume (int'(i_count_tid) < SLOTS);
        assume (issued_q[SlotBits'(i_count_tid)]);
      end
      assume ((i_park & ~o_waiting) == 0);
      assume ((i_wake & ~parked_q) == 0);
      assume ((i_park & i_wake) == 0);
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
    end
  end
`endif
`endif
endmodule
