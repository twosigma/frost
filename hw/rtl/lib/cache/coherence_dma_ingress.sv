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
  typedef enum logic [1:0] {
    Demand,
    Grant,
    Complete,
    Release
  } phase_t;
  phase_t phase_q;
  logic [ADDR_WIDTH+311:0] queue_q[4];
  coh_d_t incoming, demand;
  coh_g_t grant_in, grant_q;
  coh_c_t completion;
  coh_u_t release_in;
  logic [1:0] head_q, tail_q;
  logic [ 2:0] count_q;
  logic [15:0] occupied_q;
  logic accept_request, release_request;
  always_comb begin
    incoming = '0;
    incoming.opcode = i_req_write ? coherence_pkg::DMAWrite : coherence_pkg::DMARead;
    incoming.q = {2'd2, 2'd3, i_req_id, 1'b0};
    incoming.addr = i_req_addr;
    incoming.size = 3'd5;
    incoming.mask = i_req_mask;
    incoming.wdata = i_req_data;
  end
  assign demand = queue_q[head_q];
  assign grant_in = i_g;
  assign release_in = i_u;
  assign o_req_ready = !i_rst && !i_fatal_stop && count_q < 4 && !occupied_q[i_req_id];
  assign accept_request = i_req_valid && o_req_ready;
  assign release_request = i_u_valid && o_u_ready;
  assign o_d_valid = !i_rst && !i_fatal_stop && count_q != 0 && phase_q == Demand;
  assign o_d = demand;
  assign o_g_ready = !i_rst && phase_q == Grant && grant_in.q == demand.q &&
      grant_in.addr == demand.addr;
  assign completion = {
    demand.q,
    grant_q.tid,
    demand.addr,
    grant_q.error ? coherence_pkg::Error : coherence_pkg::Consumed,
    1'b1
  };
  assign o_c_valid = !i_rst && phase_q == Complete;
  assign o_c = completion;
  assign o_u_ready = !i_rst && phase_q == Release && release_in.q == demand.q &&
      release_in.tid == grant_q.tid && release_in.addr == demand.addr;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      phase_q <= Demand;
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
      occupied_q <= '0;
      grant_q <= '0;
      o_resp_valid <= 1'b0;
      o_resp_id <= '0;
      o_resp_data <= '0;
      o_resp_error <= 1'b0;
    end else begin
      o_resp_valid <= 1'b0;
      if (o_resp_valid) occupied_q[o_resp_id] <= 1'b0;
      if (accept_request) begin
        queue_q[tail_q] <= incoming;
        tail_q <= tail_q + 1'b1;
        occupied_q[i_req_id] <= 1'b1;
      end
      case ({
        accept_request, release_request
      })
        2'b10: count_q <= count_q + 1'b1;
        2'b01: count_q <= count_q - 1'b1;
        default: begin
        end
      endcase
      case (phase_q)
        Demand:   if (o_d_valid && i_d_ready) phase_q <= Grant;
        Grant:
        if (i_g_valid && o_g_ready) begin
          grant_q <= grant_in;
          phase_q <= Complete;
        end
        Complete: if (i_c_ready) phase_q <= Release;
        Release:
        if (release_request) begin
          o_resp_valid <= 1'b1;
          o_resp_id <= demand.q.id;
          o_resp_data <= grant_q.data;
          o_resp_error <= grant_q.error;
          head_q <= head_q + 1'b1;
          phase_q <= Demand;
        end
        default:  phase_q <= Demand;
      endcase
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (accept_request) assert (i_req_addr[4:0] == 0);
      assert (count_q <= 4);
    end
  end
`endif
`ifdef FORMAL
  function automatic logic [3:0] packet_id(input coh_d_t packet);
    packet_id = packet.q.id;
  endfunction
  logic f_past_valid = 1'b0;
  logic [2:0] f_outstanding;
  logic [15:0] f_occupied;
  logic [3:0] f_queued;
  (* anyconst *) logic [3:0] f_id;
  coh_d_t f_payload;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (i_rst) begin
      f_outstanding <= '0;
      f_occupied <= '0;
      f_queued <= '0;
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
      if (o_resp_valid) f_occupied[o_resp_id] <= 1'b0;
      if (release_request) f_queued[head_q] <= 1'b0;
      if (accept_request) begin
        assert (!f_occupied[i_req_id]);
        f_occupied[i_req_id] <= 1'b1;
        f_queued[tail_q] <= 1'b1;
        if (i_req_id == f_id) f_payload <= incoming;
      end
      assert (f_outstanding <= 4);
      assert (f_outstanding == count_q + 3'(o_resp_valid));
      assert (occupied_q == f_occupied);
      assert (f_outstanding == $countones(occupied_q));
      assert (count_q == $countones(f_queued));
      assert (tail_q == 2'(head_q + count_q));
      for (int offset = 0; offset < 4; offset++)
      assert (f_queued[2'(head_q+offset)] == (count_q > offset));
      if (count_q != 0) assert (f_queued[head_q]);
      if (count_q < 4) assert (!f_queued[tail_q]);
      if (phase_q != Demand) assert (count_q != 0);
      if (phase_q == Complete || phase_q == Release) begin
        assert (grant_q.q == demand.q);
        assert (grant_q.addr == demand.addr);
      end
      for (int slot = 0; slot < 4; slot++) begin
        if (f_queued[slot]) begin
          assert (occupied_q[packet_id(queue_q[slot])]);
          if (packet_id(queue_q[slot]) == f_id) assert (queue_q[slot] == f_payload);
          for (int other = slot + 1; other < 4; other++)
          if (f_queued[other]) assert (packet_id(queue_q[slot]) != packet_id(queue_q[other]));
        end
      end
      if (o_resp_valid) begin
        assert (occupied_q[o_resp_id]);
        for (int slot = 0; slot < 4; slot++)
        if (f_queued[slot]) assert (packet_id(queue_q[slot]) != o_resp_id);
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
      if (o_resp_valid) begin
        assert ($past(release_request));
        assert (o_resp_id == $past(demand.q.id));
        assert (o_resp_data == $past(grant_q.data));
        assert (o_resp_error == $past(grant_q.error));
      end
      if (o_c_valid) begin
        assert (completion.q == grant_q.q);
        assert (completion.addr == grant_q.addr);
      end
      cover (count_q == 4 && !i_d_ready);
      cover (o_resp_valid && o_resp_error && count_q != 0);
    end
  end
`endif
endmodule
