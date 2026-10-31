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

// Accepted line identities remain occupied until their slot frees: at the
// later of the external response edge and the home's U. A read responds from
// the cycle after its G, which carries its final data; a write responds after
// its U.
module coherence_dma_ingress #(
    parameter int unsigned ADDR_WIDTH = 32,
    // Admission credits: line slots held from acceptance through the later of
    // the external response and U. A power of two, 2 to 16.
    parameter int unsigned SLOTS = 4
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_fatal_stop,
    input logic i_req_valid,
    output logic o_req_ready,
    input logic i_req_write,
    input logic [ADDR_WIDTH-1:0] i_req_addr,
    input logic [255:0] i_req_data,
    input logic [31:0] i_req_mask,
    input logic [3:0] i_req_id,
    output logic o_resp_valid,
    output logic [255:0] o_resp_data,
    output logic [3:0] o_resp_id,
    output logic o_resp_error,
    output logic o_d_valid,
    input logic i_d_ready,
    output logic [ADDR_WIDTH+311:0] o_d,
    input logic i_g_valid,
    output logic o_g_ready,
    input logic [ADDR_WIDTH+274:0] i_g,
    output logic o_c_valid,
    input logic i_c_ready,
    output logic [ADDR_WIDTH+17:0] o_c,
    input logic i_u_valid,
    output logic o_u_ready,
    input logic [ADDR_WIDTH+14:0] i_u
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
  typedef enum logic [2:0] {
    Free,
    Queued,
    Sent,
    HaveGrant,
    WaitRelease,
    Respond
  } phase_t;
  localparam int unsigned SlotBits  = $clog2(SLOTS);
  localparam int unsigned CountBits = $clog2(SLOTS + 1);
  if (SLOTS < 2 || SLOTS > 16 || (SLOTS & (SLOTS - 1)) != 0) begin : gen_invalid_slots
    initial $fatal(1, "coherence_dma_ingress: SLOTS must be a power of two, 2 to 16");
  end
  phase_t phase_q[SLOTS];
  logic [ADDR_WIDTH+311:0] packet_q[SLOTS];
  logic [255:0] data_q[SLOTS];
  logic [5:0] tid_q[SLOTS];
  logic [SLOTS-1:0] error_q;
  // The slot's response is in the response register or has been sent.
  logic [SLOTS-1:0] responded_q;
  logic [SlotBits-1:0] queue_q[SLOTS];
  logic [SlotBits-1:0] head_q, tail_q, free_slot, response_slot_q;
  logic [CountBits-1:0] count_q, queued_q;
  logic [15:0] occupied_q;
  logic available;
  logic [SLOTS-1:0] grant_match, release_match, c_valid, c_ready;
  logic [SLOTS-1:0][ADDR_WIDTH+17:0] completions;
  coh_d_t incoming, demand;
  coh_g_t grant_in;
  coh_u_t release_in;
  logic accept_request, accept_demand, release_request;
  logic [SLOTS-1:0] early_due, release_due, release_free, early_first, pick_onehot;
  logic pick_valid, pulse_free;
  logic [SlotBits-1:0] pick_slot;
  logic [255:0] pick_data;
  logic [3:0] pick_id;
  logic pick_error;

  function automatic logic [3:0] packet_id(input coh_d_t packet);
    packet_id = packet.q.id;
  endfunction
  function automatic logic packet_write(input coh_d_t packet);
    packet_write = packet.opcode == coherence_pkg::DMAWrite;
  endfunction

  always_comb begin
    incoming = '0;
    incoming.opcode = i_req_write ? coherence_pkg::DMAWrite : coherence_pkg::DMARead;
    incoming.q = {2'd2, 2'd3, i_req_id, 1'b0};
    incoming.addr = i_req_addr;
    incoming.size = 3'd5;
    incoming.mask = i_req_mask;
    incoming.wdata = i_req_data;
    available = 1'b0;
    free_slot = '0;
    for (int slot = SLOTS - 1; slot >= 0; slot--) begin
      if (phase_q[slot] == Free) begin
        available = 1'b1;
        free_slot = SlotBits'(slot);
      end
    end
  end
  assign demand = packet_q[queue_q[head_q]];
  assign grant_in = i_g;
  assign release_in = i_u;
  assign o_req_ready = !i_rst && !i_fatal_stop && available && !occupied_q[i_req_id];
  assign accept_request = i_req_valid && o_req_ready;
  assign accept_demand = o_d_valid && i_d_ready;
  logic [SLOTS-1:0] head_slot;
  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_head_slot
    assign head_slot[slot] = queue_q[head_q] == SlotBits'(slot);
  end
  assign release_request = i_u_valid && o_u_ready;
  assign o_d_valid = !i_rst && !i_fatal_stop && queued_q != 0;
  assign o_d = demand;
  assign o_g_ready = !i_rst && |grant_match;
  assign o_u_ready = !i_rst && |release_match;

  for (genvar slot = 0; slot < SLOTS; slot++) begin : gen_slot
    coh_d_t request_packet;
    assign request_packet = packet_q[slot];
    assign grant_match[slot] = phase_q[slot] == Sent &&
        grant_in.q == request_packet.q && grant_in.addr == request_packet.addr &&
        grant_in.opcode == (request_packet.opcode == coherence_pkg::DMAWrite ?
            coherence_pkg::GrantAck : coherence_pkg::GrantData);
    assign release_match[slot] = phase_q[slot] == WaitRelease &&
        release_in.q == request_packet.q && release_in.addr == request_packet.addr &&
        release_in.tid == tid_q[slot];
    // A read may respond once its G data is held; the U's slot responds next
    // when it has not responded, and frees now when it has.
    assign early_due[slot] = request_packet.opcode != coherence_pkg::DMAWrite &&
        (phase_q[slot] == HaveGrant || phase_q[slot] == WaitRelease) && !responded_q[slot];
    assign release_due[slot] = release_request && release_match[slot] && !responded_q[slot];
    assign release_free[slot] = release_request && release_match[slot] && responded_q[slot];
    // A slot offers C from the cycle after its G, from registered state, so
    // the G comparison does not reach the C arbiter.
    assign c_valid[slot] = !i_rst && phase_q[slot] == HaveGrant;
    assign completions[slot] = {
      request_packet.q,
      tid_q[slot],
      request_packet.addr,
      error_q[slot] ? coherence_pkg::Error : coherence_pkg::Consumed,
      1'b1
    };
  end

  // One response per cycle: the U's slot first, so no response is later than
  // the cycle after its U; otherwise the lowest-numbered early read. The U's
  // slot and the early read each select their own payload, and the U's
  // presence chooses between the two selections last.
  logic release_pick;
  logic [SlotBits-1:0] release_slot, early_slot;
  logic [255:0] release_data, early_data;
  logic [3:0] release_id, early_id;
  logic release_error, early_error;
  always_comb begin
    early_first = '0;
    for (int slot = SLOTS - 1; slot >= 0; slot--) begin
      if (early_due[slot]) begin
        early_first = '0;
        early_first[slot] = 1'b1;
      end
    end
    release_pick = |release_due;
    release_slot = '0;
    release_data = '0;
    release_id = '0;
    release_error = 1'b0;
    early_slot = '0;
    early_data = '0;
    early_id = '0;
    early_error = 1'b0;
    for (int slot = 0; slot < SLOTS; slot++) begin
      release_slot |= SlotBits'(slot) & {SlotBits{release_due[slot]}};
      release_data |= data_q[slot] & {256{release_due[slot]}};
      release_id |= packet_id(packet_q[slot]) & {4{release_due[slot]}};
      release_error |= error_q[slot] && release_due[slot];
      early_slot |= SlotBits'(slot) & {SlotBits{early_first[slot]}};
      early_data |= data_q[slot] & {256{early_first[slot]}};
      early_id |= packet_id(packet_q[slot]) & {4{early_first[slot]}};
      early_error |= error_q[slot] && early_first[slot];
    end
    pick_onehot = release_pick ? release_due : early_first;
    pick_valid = release_pick || |early_first;
    pick_slot = release_pick ? release_slot : early_slot;
    pick_data = release_pick ? release_data : early_data;
    pick_id = release_pick ? release_id : early_id;
    pick_error = release_pick ? release_error : early_error;
  end
  // The response pulse frees a slot whose U has already been accepted.
  assign pulse_free = o_resp_valid && phase_q[response_slot_q] == Respond;
  // A slot offering C stays in HaveGrant until its C is accepted.
  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 18),
      .PORTS(SLOTS),
      .HOLD_VALID(1)
  ) completion_arbiter (
      .i_clk,
      .i_rst,
      .i_valid(c_valid),
      .o_ready(c_ready),
      .i_payload(completions),
      .o_valid(o_c_valid),
      .o_offer(),
      .o_selected(),
      .i_ready(i_c_ready),
      .o_payload(o_c)
  );
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
      queued_q <= '0;
      occupied_q <= '0;
      error_q <= '0;
      responded_q <= '0;
      response_slot_q <= '0;
      o_resp_valid <= 1'b0;
      o_resp_id <= '0;
      o_resp_data <= '0;
      o_resp_error <= 1'b0;
      for (int slot = 0; slot < SLOTS; slot++) begin
        phase_q[slot] <= Free;
        tid_q[slot]   <= '0;
      end
    end else begin
      o_resp_valid <= pick_valid;
      if (pick_valid) response_slot_q <= pick_slot;
      for (int slot = 0; slot < SLOTS; slot++) begin
        if (release_due[slot] || (early_first[slot] && !release_pick)) responded_q[slot] <= 1'b1;
      end
      o_resp_id <= pick_id;
      o_resp_data <= pick_data;
      o_resp_error <= pick_error;
      if (pulse_free) begin
        occupied_q[o_resp_id] <= 1'b0;
        phase_q[response_slot_q] <= Free;
        responded_q[response_slot_q] <= 1'b0;
      end
      if (accept_request) begin
        packet_q[free_slot] <= incoming;
        phase_q[free_slot] <= Queued;
        queue_q[tail_q] <= free_slot;
        tail_q <= tail_q + 1'b1;
        occupied_q[i_req_id] <= 1'b1;
      end
      count_q <= count_q + CountBits'(accept_request) - CountBits'(pulse_free) -
          CountBits'(|release_free);
      case ({
        accept_request, accept_demand
      })
        2'b10: queued_q <= queued_q + 1'b1;
        2'b01: queued_q <= queued_q - 1'b1;
        default: begin
        end
      endcase
      if (accept_demand) head_q <= head_q + 1'b1;
      for (int slot = 0; slot < SLOTS; slot++) begin
        if (i_g_valid && grant_match[slot]) begin
          data_q[slot]  <= grant_in.data;
          tid_q[slot]   <= grant_in.tid;
          error_q[slot] <= grant_in.error;
          phase_q[slot] <= HaveGrant;
        end
        if (c_valid[slot] && c_ready[slot]) phase_q[slot] <= WaitRelease;
        if (release_due[slot]) phase_q[slot] <= Respond;
        if (release_free[slot]) begin
          phase_q[slot] <= Free;
          occupied_q[packet_id(packet_q[slot])] <= 1'b0;
          responded_q[slot] <= 1'b0;
        end
        // The queue head is Queued, so no other transition applies to it;
        // D acceptance, which arrives last, selects its next phase last.
        if (head_slot[slot] && accept_demand) phase_q[slot] <= Sent;
      end
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (sim_reset_seen_q && !i_rst) begin
      if (accept_request) assert (i_req_addr[4:0] == 0);
      assert (count_q <= CountBits'(SLOTS) && queued_q <= count_q);
      assert ($onehot0(grant_match));
      assert ($onehot0(release_match));
      if (accept_demand) assert (phase_q[queue_q[head_q]] == Queued);
      if (o_resp_valid) assert (phase_q[response_slot_q] != Free && responded_q[response_slot_q]);
      assert ($onehot0(pick_onehot));
      for (int slot = 0; slot < SLOTS; slot++) begin
        if (phase_q[slot] == Respond) assert (responded_q[slot]);
        if (responded_q[slot])
          assert (phase_q[slot] == Respond || phase_q[slot] == HaveGrant ||
            phase_q[slot] == WaitRelease);
      end
    end
  end
`endif
`ifdef FORMAL
  logic f_past_valid = 1'b0;
  logic [CountBits-1:0] f_outstanding;
  logic [15:0] f_occupied;
  logic [SLOTS-1:0] f_queued, f_sent, f_granted, f_completed, f_released;
  logic [SLOTS-1:0] f_queue_live;
  (* anyconst *) logic [3:0] f_id;
  coh_d_t f_payload, f_reference_request, f_presented_request;
  coh_g_t f_presented_grant;
  coh_c_t f_presented_completion;
  coh_u_t f_presented_release;
  logic [3:0] f_issue_id_q[SLOTS];
  logic [SlotBits-1:0] f_issue_head_q, f_issue_tail_q;
  logic [CountBits-1:0] f_issue_count_q;
  logic [255:0] f_reference_data_q;
  logic [5:0] f_reference_tid_q;
  logic f_reference_error_q, f_reference_sent_q, f_reference_granted_q;
  logic f_reference_completed_q, f_reference_released_q, f_reference_responded_q;
  logic f_reference_live_q;
  assign f_presented_request = o_d;
  assign f_presented_grant = i_g;
  assign f_presented_completion = o_c;
  assign f_presented_release = i_u;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      f_issue_head_q <= '0;
      f_issue_tail_q <= '0;
      f_issue_count_q <= '0;
      f_reference_sent_q <= 1'b0;
      f_reference_granted_q <= 1'b0;
      f_reference_completed_q <= 1'b0;
      f_reference_released_q <= 1'b0;
      f_reference_responded_q <= 1'b0;
      f_reference_live_q <= 1'b0;
    end else begin
      case ({
        accept_request, accept_demand
      })
        2'b10: f_issue_count_q <= f_issue_count_q + 1'b1;
        2'b01: f_issue_count_q <= f_issue_count_q - 1'b1;
        default: begin
        end
      endcase
      if (accept_request) begin
        f_issue_id_q[f_issue_tail_q] <= i_req_id;
        f_issue_tail_q <= f_issue_tail_q + 1'b1;
        if (i_req_id == f_id) begin
          f_reference_request <= '0;
          f_reference_request.opcode <= i_req_write ? coherence_pkg::DMAWrite :
              coherence_pkg::DMARead;
          f_reference_request.q.src <= 2;
          f_reference_request.q.port_class <= 3;
          f_reference_request.q.id <= i_req_id;
          f_reference_request.addr <= i_req_addr;
          f_reference_request.size <= 5;
          f_reference_request.mask <= i_req_mask;
          f_reference_request.wdata <= i_req_data;
          f_reference_sent_q <= 1'b0;
          f_reference_granted_q <= 1'b0;
          f_reference_completed_q <= 1'b0;
          f_reference_released_q <= 1'b0;
          f_reference_responded_q <= 1'b0;
          f_reference_live_q <= 1'b1;
        end
      end
      if (accept_demand) begin
        assert (f_issue_count_q != 0);
        assert (f_presented_request.q.id == f_issue_id_q[f_issue_head_q]);
        f_issue_head_q <= f_issue_head_q + 1'b1;
        if (f_issue_id_q[f_issue_head_q] == f_id) begin
          assert (o_d == f_reference_request);
          f_reference_sent_q <= 1'b1;
        end
      end
      if (i_g_valid && o_g_ready && f_presented_grant.q.id == f_id) begin
        assert (f_reference_sent_q && !f_reference_granted_q);
        assert (f_presented_grant.q == f_reference_request.q);
        assert (f_presented_grant.addr == f_reference_request.addr);
        assert (f_presented_grant.opcode ==
            (f_reference_request.opcode == coherence_pkg::DMAWrite ?
             coherence_pkg::GrantAck : coherence_pkg::GrantData));
        f_reference_data_q <= f_presented_grant.data;
        f_reference_error_q <= f_presented_grant.error;
        f_reference_tid_q <= f_presented_grant.tid;
        f_reference_granted_q <= 1'b1;
      end
      if (o_c_valid && i_c_ready && f_presented_completion.q.id == f_id) begin
        assert (f_reference_granted_q && !f_reference_completed_q);
        assert (f_presented_completion.q == f_reference_request.q);
        assert (f_presented_completion.addr == f_reference_request.addr);
        assert (f_presented_completion.tid == f_reference_tid_q);
        assert (f_presented_completion.status ==
            (f_reference_error_q ? coherence_pkg::Error : coherence_pkg::Consumed));
        assert (f_presented_completion.write_done);
        f_reference_completed_q <= 1'b1;
      end
      if (i_u_valid && o_u_ready && f_presented_release.q.id == f_id) begin
        assert (f_reference_completed_q && !f_reference_released_q);
        assert (f_presented_release.q == f_reference_request.q);
        assert (f_presented_release.addr == f_reference_request.addr);
        assert (f_presented_release.tid == f_reference_tid_q);
        f_reference_released_q <= 1'b1;
      end
      if (o_resp_valid && o_resp_id == f_id) begin
        // A write responds after its U; a read once its G data is held.
        assert (f_reference_request.opcode == coherence_pkg::DMAWrite ?
            f_reference_released_q : f_reference_granted_q);
        assert (!f_reference_responded_q);
        assert (o_resp_data == f_reference_data_q);
        assert (o_resp_error == f_reference_error_q);
        f_reference_responded_q <= 1'b1;
      end
      // The watched ID stays held from acceptance until both its response and
      // its U have been seen at the interfaces.
      assert (occupied_q[f_id] ==
          (f_reference_live_q && !(f_reference_responded_q && f_reference_released_q)));
      assert (f_issue_count_q == queued_q);
      assert (f_issue_head_q == head_q && f_issue_tail_q == tail_q);
      for (int index = 0; index < SLOTS; index++)
      if (f_queue_live[index]) assert (f_issue_id_q[index] == packet_id(packet_q[queue_q[index]]));
      for (int slot = 0; slot < SLOTS; slot++) begin
        if (phase_q[slot] != Free && packet_id(packet_q[slot]) == f_id) begin
          assert (packet_q[slot] == f_reference_request);
          assert (f_sent[slot] == f_reference_sent_q);
          assert (f_granted[slot] == f_reference_granted_q);
          assert (f_completed[slot] == f_reference_completed_q);
          assert (f_released[slot] == f_reference_released_q);
          // The response register is loaded one edge before its pulse.
          assert (responded_q[slot] == (f_reference_responded_q ||
              (o_resp_valid && response_slot_q == SlotBits'(slot))));
          if (f_reference_responded_q) assert (f_reference_granted_q);
          if (f_granted[slot]) begin
            assert (data_q[slot] == f_reference_data_q);
            assert (error_q[slot] == f_reference_error_q);
            assert (tid_q[slot] == f_reference_tid_q);
          end
        end
      end
    end
  end
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (i_rst) begin
      f_outstanding <= '0;
      f_occupied <= '0;
      f_queued <= '0;
      f_queue_live <= '0;
      f_sent <= '0;
      f_granted <= '0;
      f_completed <= '0;
      f_released <= '0;
    end else begin
      if (accept_request) assume (i_req_addr[4:0] == 0);
      f_outstanding <= f_outstanding + CountBits'(accept_request) - CountBits'(pulse_free) -
          CountBits'(|release_free);
      if (pulse_free) begin
        f_occupied[o_resp_id] <= 1'b0;
        f_queued[response_slot_q] <= 1'b0;
        f_sent[response_slot_q] <= 1'b0;
        f_granted[response_slot_q] <= 1'b0;
        f_completed[response_slot_q] <= 1'b0;
        f_released[response_slot_q] <= 1'b0;
      end
      if (accept_request) begin
        assert (!f_occupied[i_req_id]);
        f_occupied[i_req_id] <= 1'b1;
        f_queued[free_slot]  <= 1'b1;
        f_queue_live[tail_q] <= 1'b1;
        if (i_req_id == f_id) f_payload <= incoming;
      end
      if (accept_demand) begin
        f_sent[queue_q[head_q]] <= 1'b1;
        f_queue_live[head_q] <= 1'b0;
      end
      assert (f_outstanding <= CountBits'(SLOTS));
      assert (f_outstanding == count_q);
      assert (occupied_q == f_occupied);
      assert (f_outstanding == $countones(occupied_q));
      assert (count_q == $countones(f_queued));
      assert (queued_q == $countones(f_queue_live));
      assert (tail_q == SlotBits'(head_q + queued_q));
      for (int offset = 0; offset < SLOTS; offset++) begin
        assert (f_queue_live[SlotBits'(head_q+offset)] == (queued_q > offset));
        if (f_queue_live[offset]) assert (phase_q[queue_q[offset]] == Queued);
        for (int other = offset + 1; other < SLOTS; other++)
        if (f_queue_live[offset] && f_queue_live[other]) assert (queue_q[offset] != queue_q[other]);
      end
      for (int slot = 0; slot < SLOTS; slot++) begin
        if (i_g_valid && grant_match[slot]) f_granted[slot] <= 1'b1;
        if (c_valid[slot] && c_ready[slot]) f_completed[slot] <= 1'b1;
        if (release_due[slot]) f_released[slot] <= 1'b1;
        if (release_free[slot]) begin
          f_occupied[packet_id(packet_q[slot])] <= 1'b0;
          f_queued[slot] <= 1'b0;
          f_sent[slot] <= 1'b0;
          f_granted[slot] <= 1'b0;
          f_completed[slot] <= 1'b0;
        end
        assert (f_queued[slot] == (phase_q[slot] != Free));
        assert (f_sent[slot] == (phase_q[slot] >= Sent));
        assert (f_granted[slot] == (phase_q[slot] >= HaveGrant));
        assert (f_completed[slot] == (phase_q[slot] >= WaitRelease));
        assert (f_released[slot] == (phase_q[slot] == Respond));
        if (f_queued[slot]) begin
          assert (occupied_q[packet_id(packet_q[slot])]);
          if (packet_id(packet_q[slot]) == f_id) assert (packet_q[slot] == f_payload);
          for (int other = slot + 1; other < SLOTS; other++)
          if (f_queued[other]) assert (packet_id(packet_q[slot]) != packet_id(packet_q[other]));
        end
      end
      if (o_resp_valid) begin
        assert (occupied_q[o_resp_id] && (f_released[response_slot_q] ||
            (f_granted[response_slot_q] && !packet_write(
            packet_q[response_slot_q]
        ))));
        assert (o_resp_id == packet_id(packet_q[response_slot_q]));
        assert (o_resp_data == data_q[response_slot_q]);
        assert (o_resp_error == error_q[response_slot_q]);
      end
    end
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      if ($past(o_d_valid && !i_d_ready) && !i_fatal_stop) begin
        assert (o_d_valid);
        assert (o_d == $past(o_d));
      end
      if ($past(o_c_valid && !i_c_ready)) begin
        assert (o_c_valid);
        assert (o_c == $past(o_c));
      end
      assert (o_resp_valid == $past(pick_valid));
      // A slot whose U arrives before its response responds the next cycle.
      if ($past(|release_due))
        assert (o_resp_valid && $past(release_due) == (SLOTS'(1) << response_slot_q));
      cover (o_resp_valid && phase_q[response_slot_q] != Respond);
      cover (pulse_free && |release_free);
      cover (count_q == CountBits'(SLOTS) && queued_q == 0);
      cover (o_resp_valid && o_resp_error && count_q != 0);
      cover (o_resp_valid && accept_request && accept_demand && release_request);
    end
  end
`endif
endmodule
