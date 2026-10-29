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

// Accepted line identities remain occupied through the external response edge.
module coherence_dma_ingress #(
    parameter int unsigned ADDR_WIDTH = 32
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
  `FROST_COHERENCE_TYPES(ADDR_WIDTH)
  typedef enum logic [2:0] {
    Free,
    Queued,
    Sent,
    HaveGrant,
    WaitRelease,
    Respond
  } phase_t;
  phase_t phase_q[4];
  logic [ADDR_WIDTH+311:0] packet_q[4];
  logic [255:0] data_q[4];
  logic [5:0] tid_q[4];
  logic [3:0] error_q;
  logic [1:0] queue_q[4];
  logic [1:0] head_q, tail_q, free_slot, response_slot_q;
  logic [2:0] count_q, queued_q;
  logic [15:0] occupied_q;
  logic available;
  logic [3:0] grant_match, release_match, c_valid, c_ready;
  logic [3:0][ADDR_WIDTH+17:0] completions;
  coh_d_t incoming, demand;
  coh_g_t grant_in;
  coh_u_t release_in;
  logic accept_request, accept_demand, release_request;

  function automatic logic [3:0] packet_id(input coh_d_t packet);
    packet_id = packet.q.id;
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
    for (int slot = 3; slot >= 0; slot--) begin
      if (phase_q[slot] == Free) begin
        available = 1'b1;
        free_slot = 2'(slot);
      end
    end
  end
  assign demand = packet_q[queue_q[head_q]];
  assign grant_in = i_g;
  assign release_in = i_u;
  assign o_req_ready = !i_rst && !i_fatal_stop && available && !occupied_q[i_req_id];
  assign accept_request = i_req_valid && o_req_ready;
  assign accept_demand = o_d_valid && i_d_ready;
  assign release_request = i_u_valid && o_u_ready;
  assign o_d_valid = !i_rst && !i_fatal_stop && queued_q != 0;
  assign o_d = demand;
  assign o_g_ready = !i_rst && |grant_match;
  assign o_u_ready = !i_rst && |release_match;

  for (genvar slot = 0; slot < 4; slot++) begin : gen_slot
    coh_d_t request_packet;
    assign request_packet = packet_q[slot];
    assign grant_match[slot] = phase_q[slot] == Sent &&
        grant_in.q == request_packet.q && grant_in.addr == request_packet.addr &&
        grant_in.opcode == (request_packet.opcode == coherence_pkg::DMAWrite ?
            coherence_pkg::GrantAck : coherence_pkg::GrantData);
    assign release_match[slot] = phase_q[slot] == WaitRelease &&
        release_in.q == request_packet.q && release_in.addr == request_packet.addr &&
        release_in.tid == tid_q[slot];
    assign c_valid[slot] = !i_rst && phase_q[slot] == HaveGrant;
    assign completions[slot] = {
      request_packet.q,
      tid_q[slot],
      request_packet.addr,
      error_q[slot] ? coherence_pkg::Error : coherence_pkg::Consumed,
      1'b1
    };
  end

  coherence_d_arbiter #(
      .WIDTH(ADDR_WIDTH + 18),
      .PORTS(4)
  ) completion_arbiter (
      .i_clk,
      .i_rst,
      .i_valid  (c_valid),
      .o_ready  (c_ready),
      .i_payload(completions),
      .o_valid  (o_c_valid),
      .i_ready  (i_c_ready),
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
      response_slot_q <= '0;
      o_resp_valid <= 1'b0;
      o_resp_id <= '0;
      o_resp_data <= '0;
      o_resp_error <= 1'b0;
      for (int slot = 0; slot < 4; slot++) begin
        phase_q[slot] <= Free;
        tid_q[slot]   <= '0;
      end
    end else begin
      o_resp_valid <= release_request;
      if (o_resp_valid) begin
        occupied_q[o_resp_id] <= 1'b0;
        phase_q[response_slot_q] <= Free;
      end
      if (accept_request) begin
        packet_q[free_slot] <= incoming;
        phase_q[free_slot] <= Queued;
        queue_q[tail_q] <= free_slot;
        tail_q <= tail_q + 1'b1;
        occupied_q[i_req_id] <= 1'b1;
      end
      case ({
        accept_request, o_resp_valid
      })
        2'b10: count_q <= count_q + 1'b1;
        2'b01: count_q <= count_q - 1'b1;
        default: begin
        end
      endcase
      case ({
        accept_request, accept_demand
      })
        2'b10: queued_q <= queued_q + 1'b1;
        2'b01: queued_q <= queued_q - 1'b1;
        default: begin
        end
      endcase
      if (accept_demand) begin
        phase_q[queue_q[head_q]] <= Sent;
        head_q <= head_q + 1'b1;
      end
      for (int slot = 0; slot < 4; slot++) begin
        if (i_g_valid && grant_match[slot]) begin
          data_q[slot]  <= grant_in.data;
          tid_q[slot]   <= grant_in.tid;
          error_q[slot] <= grant_in.error;
          phase_q[slot] <= HaveGrant;
        end
        if (c_valid[slot] && c_ready[slot]) phase_q[slot] <= WaitRelease;
        if (i_u_valid && release_match[slot]) begin
          phase_q[slot] <= Respond;
          response_slot_q <= 2'(slot);
          o_resp_id <= packet_id(packet_q[slot]);
          o_resp_data <= data_q[slot];
          o_resp_error <= error_q[slot];
        end
      end
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (accept_request) assert (i_req_addr[4:0] == 0);
      assert (count_q <= 4 && queued_q <= count_q);
      assert ($onehot0(grant_match));
      assert ($onehot0(release_match));
      if (accept_demand) assert (phase_q[queue_q[head_q]] == Queued);
      if (o_resp_valid) assert (phase_q[response_slot_q] == Respond);
    end
  end
`endif
`ifdef FORMAL
  logic f_past_valid = 1'b0;
  logic [2:0] f_outstanding;
  logic [15:0] f_occupied;
  logic [3:0] f_queued, f_sent, f_granted, f_completed, f_released;
  logic [3:0] f_queue_live;
  (* anyconst *)logic [3:0] f_id;
  coh_d_t f_payload, f_reference_request, f_presented_request;
  coh_g_t f_presented_grant;
  coh_c_t f_presented_completion;
  coh_u_t f_presented_release;
  logic [3:0] f_issue_id_q[4];
  logic [1:0] f_issue_head_q, f_issue_tail_q;
  logic [  2:0] f_issue_count_q;
  logic [255:0] f_reference_data_q;
  logic [  5:0] f_reference_tid_q;
  logic f_reference_error_q, f_reference_sent_q, f_reference_granted_q;
  logic f_reference_completed_q, f_reference_released_q;
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
        assert (f_reference_released_q);
        assert (o_resp_data == f_reference_data_q);
        assert (o_resp_error == f_reference_error_q);
      end
      assert (f_issue_count_q == queued_q);
      assert (f_issue_head_q == head_q && f_issue_tail_q == tail_q);
      for (int index = 0; index < 4; index++)
      if (f_queue_live[index]) assert (f_issue_id_q[index] == packet_id(packet_q[queue_q[index]]));
      for (int slot = 0; slot < 4; slot++) begin
        if (phase_q[slot] != Free && packet_id(packet_q[slot]) == f_id) begin
          assert (packet_q[slot] == f_reference_request);
          assert (f_sent[slot] == f_reference_sent_q);
          assert (f_granted[slot] == f_reference_granted_q);
          assert (f_completed[slot] == f_reference_completed_q);
          assert (f_released[slot] == f_reference_released_q);
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
      case ({
        accept_request, o_resp_valid
      })
        2'b10: f_outstanding <= f_outstanding + 1'b1;
        2'b01: f_outstanding <= f_outstanding - 1'b1;
        default: begin
        end
      endcase
      if (o_resp_valid) begin
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
      assert (f_outstanding <= 4);
      assert (f_outstanding == count_q);
      assert (occupied_q == f_occupied);
      assert (f_outstanding == $countones(occupied_q));
      assert (count_q == $countones(f_queued));
      assert (queued_q == $countones(f_queue_live));
      assert (tail_q == 2'(head_q + queued_q));
      for (int offset = 0; offset < 4; offset++) begin
        assert (f_queue_live[2'(head_q+offset)] == (queued_q > offset));
        if (f_queue_live[offset]) assert (phase_q[queue_q[offset]] == Queued);
        for (int other = offset + 1; other < 4; other++)
        if (f_queue_live[offset] && f_queue_live[other]) assert (queue_q[offset] != queue_q[other]);
      end
      for (int slot = 0; slot < 4; slot++) begin
        if (i_g_valid && grant_match[slot]) f_granted[slot] <= 1'b1;
        if (c_valid[slot] && c_ready[slot]) f_completed[slot] <= 1'b1;
        if (i_u_valid && release_match[slot]) f_released[slot] <= 1'b1;
        assert (f_queued[slot] == (phase_q[slot] != Free));
        assert (f_sent[slot] == (phase_q[slot] >= Sent));
        assert (f_granted[slot] == (phase_q[slot] >= HaveGrant));
        assert (f_completed[slot] == (phase_q[slot] >= WaitRelease));
        assert (f_released[slot] == (phase_q[slot] == Respond));
        if (f_queued[slot]) begin
          assert (occupied_q[packet_id(packet_q[slot])]);
          if (packet_id(packet_q[slot]) == f_id) assert (packet_q[slot] == f_payload);
          for (int other = slot + 1; other < 4; other++)
          if (f_queued[other]) assert (packet_id(packet_q[slot]) != packet_id(packet_q[other]));
        end
      end
      if (o_resp_valid) begin
        assert (occupied_q[o_resp_id] && f_released[response_slot_q]);
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
      assert (o_resp_valid == $past(release_request));
      cover (count_q == 4 && queued_q == 0);
      cover (o_resp_valid && o_resp_error && count_q != 0);
      cover (o_resp_valid && accept_request && accept_demand && release_request);
    end
  end
`endif
endmodule
