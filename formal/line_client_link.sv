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

// The hart's line client (coherence_dma_ingress under a hart source and port
// class 3) with its four links to the home at STAGES register stages, against
// an abstract home that admits D, answers each admitted identity with one G,
// takes its C and then sends one U. The properties hold at the home's side:
// every demand carries a legal hart line-client identity, an identity is never
// presented again while it is live at the home, and C and U are well formed;
// and at the client's side: every G and U an always-taken link presents is
// taken, and each accepted request gets exactly one response.
module line_client_link #(
    parameter int unsigned STAGES = 0,
    parameter int unsigned IDS = 2,
    localparam int unsigned P = 32
) (
    input logic i_clk,
    input logic i_rst,
    // Requester.
    input logic i_req_valid,
    input logic i_req_write,
    input logic [P-1:0] i_req_addr,
    input logic [255:0] i_req_data,
    input logic [31:0] i_req_mask,
    input logic [3:0] i_req_id,
    // Home choices.
    input logic i_home_d_ready,
    input logic i_home_c_ready,
    input logic i_home_g_valid,
    input logic [3:0] i_home_g_id,
    input logic [255:0] i_home_g_data,
    input logic i_home_g_error,
    input logic i_home_u_valid,
    input logic [3:0] i_home_u_id
);
  `FROST_COHERENCE_TYPES(P)
  coh_d_t client_d, home_d;
  coh_c_t client_c, home_c;
  coh_g_t home_g, client_g;
  coh_u_t home_u, client_u;
  logic client_d_valid, client_d_ready, home_d_valid, home_d_ready;
  logic client_c_valid, client_c_ready, home_c_valid, home_c_ready;
  logic client_g_valid, client_g_ready, client_u_valid, client_u_ready;
  logic home_g_valid, home_u_valid;
  logic req_ready, resp_valid, resp_error;
  logic [  3:0] resp_id;
  logic [255:0] resp_data;

  coherence_dma_ingress #(
      .ADDR_WIDTH(P),
      .SOURCE(2'd0),
      .PORT_CLASS(2'd3),
      .SLOTS(IDS)
  ) client (
      .i_clk,
      .i_rst,
      .i_fatal_stop(1'b0),
      .i_req_valid,
      .o_req_ready(req_ready),
      .i_req_write,
      .i_req_addr,
      .i_req_data,
      .i_req_mask,
      .i_req_id,
      .i_req_non_alloc(1'b0),
      .o_resp_valid(resp_valid),
      .o_resp_data(resp_data),
      .o_resp_id(resp_id),
      .o_resp_error(resp_error),
      .o_d_valid(client_d_valid),
      .i_d_ready(client_d_ready),
      .o_d(client_d),
      .i_g_valid(client_g_valid),
      .o_g_ready(client_g_ready),
      .i_g(client_g),
      .o_c_valid(client_c_valid),
      .i_c_ready(client_c_ready),
      .o_c(client_c),
      .i_u_valid(client_u_valid),
      .o_u_ready(client_u_ready),
      .i_u(client_u)
  );
  coherence_link #(
      .WIDTH (P + 312),
      .STAGES(STAGES),
      .KIND  (1)
  ) link_d (
      .i_clk,
      .i_rst,
      .i_stopped(1'b0),
      .i_valid  (client_d_valid),
      .o_ready  (client_d_ready),
      .i_payload(client_d),
      .o_valid  (home_d_valid),
      .i_ready  (home_d_ready),
      .o_payload(home_d)
  );
  coherence_link #(
      .WIDTH (P + 18),
      .STAGES(STAGES),
      .KIND  (1)
  ) link_c (
      .i_clk,
      .i_rst,
      .i_stopped(1'b0),
      .i_valid  (client_c_valid),
      .o_ready  (client_c_ready),
      .i_payload(client_c),
      .o_valid  (home_c_valid),
      .i_ready  (home_c_ready),
      .o_payload(home_c)
  );
  coherence_link #(
      .WIDTH (P + 275),
      .STAGES(STAGES),
      .KIND  (0)
  ) link_g (
      .i_clk,
      .i_rst,
      .i_stopped(1'b0),
      .i_valid  (home_g_valid),
      .o_ready  (),
      .i_payload(home_g),
      .o_valid  (client_g_valid),
      .i_ready  (client_g_ready),
      .o_payload(client_g)
  );
  coherence_link #(
      .WIDTH (P + 15),
      .STAGES(STAGES),
      .KIND  (0)
  ) link_u (
      .i_clk,
      .i_rst,
      .i_stopped(1'b0),
      .i_valid  (home_u_valid),
      .o_ready  (),
      .i_payload(home_u),
      .o_valid  (client_u_valid),
      .i_ready  (client_u_ready),
      .o_payload(client_u)
  );

  // Abstract home: one record per identity.
  typedef enum logic [1:0] {
    HomeIdle,
    HomeAdmitted,
    HomeGranted,
    HomeCompleted
  } home_state_e;
  home_state_e home_state_q[16];
  logic [8:0] home_q_q[16];
  logic [P-1:0] home_addr_q[16];
  logic [15:0] home_write_q;
  assign home_d_ready = i_home_d_ready;
  assign home_c_ready = i_home_c_ready;
  assign home_g_valid = i_home_g_valid;
  assign home_u_valid = i_home_u_valid;
  always_comb begin
    home_g = '0;
    home_g.q = home_q_q[i_home_g_id];
    home_g.tid = 6'(i_home_g_id);
    home_g.addr = home_addr_q[i_home_g_id];
    home_g.data = home_write_q[i_home_g_id] ? '0 : i_home_g_data;
    home_g.error = i_home_g_error;
    home_g.opcode = home_write_q[i_home_g_id] ? coherence_pkg::GrantAck : coherence_pkg::GrantData;
    home_u = '0;
    home_u.q = home_q_q[i_home_u_id];
    home_u.tid = 6'(i_home_u_id);
    home_u.addr = home_addr_q[i_home_u_id];
  end
  wire  d_take = home_d_valid && home_d_ready;
  wire  c_take = home_c_valid && home_c_ready;
  logic f_past_valid = 1'b0;
  // Requester and home protocol.
  always_comb begin
    if (!f_past_valid) assume (i_rst);
    if (i_req_valid) assume (int'(i_req_id) < IDS && i_req_addr[4:0] == 0);
    // Data and masks do not reach any property; holding them at zero keeps
    // the solver to the control state.
    assume (i_req_data == '0 && i_req_mask == '0 && i_home_g_data == '0);
    if (i_home_g_valid) assume (home_state_q[i_home_g_id] == HomeAdmitted);
    if (i_home_u_valid) assume (home_state_q[i_home_u_id] == HomeCompleted);
    if (i_home_g_valid && i_home_u_valid) assume (i_home_g_id != i_home_u_id);
  end
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (i_rst) begin
      for (int id = 0; id < 16; id++) home_state_q[id] <= HomeIdle;
    end else begin
      if (d_take) begin
        home_state_q[home_d.q.id] <= HomeAdmitted;
        home_q_q[home_d.q.id] <= home_d.q;
        home_addr_q[home_d.q.id] <= home_d.addr;
        home_write_q[home_d.q.id] <= home_d.opcode == coherence_pkg::DMAWrite;
      end
      if (i_home_g_valid) home_state_q[i_home_g_id] <= HomeGranted;
      if (c_take) home_state_q[home_c.q.id] <= HomeCompleted;
      if (i_home_u_valid) home_state_q[i_home_u_id] <= HomeIdle;
    end
  end

  // Requester-side bookkeeping: identities with a response owed.
  logic [15:0] owed_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) owed_q <= '0;
    else begin
      if (i_req_valid && req_ready) owed_q[i_req_id] <= 1'b1;
      if (resp_valid) owed_q[resp_id] <= 1'b0;
    end
  end

  always_ff @(posedge i_clk) begin
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      // Demands carry a legal hart line-client identity and a DMA opcode, and
      // an identity is never presented while the home holds it.
      if (home_d_valid) begin
        p_d_identity :
        assert (home_d.q.src == 2'd0 && home_d.q.port_class == 2'd3 &&
                               int'(home_d.q.id) < IDS && home_d.q.epoch == 1'b0 &&
                               (IDS > coherence_pkg::HartLineIds ||
                                coherence_pkg::legal_q(
            home_d.q
        )) && coherence_pkg::legal_opcode(
            home_d.q, home_d.opcode
        ));
        p_d_not_live : assert (home_state_q[home_d.q.id] == HomeIdle);
        p_d_sector : assert (home_d.addr[4:0] == 0);
      end
      // C follows its G, names its identity's tid and address, and U follows C.
      if (home_c_valid) begin
        p_c_after_g : assert (home_state_q[home_c.q.id] == HomeGranted);
        p_c_identity :
        assert (home_c.q == home_q_q[home_c.q.id] &&
                               home_c.tid == 6'(home_c.q.id) &&
                               home_c.addr == home_addr_q[home_c.q.id]);
      end
      // Every G and U that an always-taken link presents is taken.
      if (client_g_valid) p_g_taken : assert (client_g_ready);
      if (client_u_valid) p_u_taken : assert (client_u_ready);
      // One response per accepted request, with its own identity.
      if (resp_valid) p_resp_owed : assert (owed_q[resp_id]);
      if (i_req_valid && req_ready) p_req_not_owed : assert (!owed_q[i_req_id]);
    end
  end

  always_comb begin
    if (!i_rst) begin
      cover_two_live :
      cover (owed_q[0] && owed_q[1] && home_state_q[0] == HomeGranted &&
                              home_state_q[1] == HomeAdmitted);
      cover_write_done : cover (resp_valid && home_write_q[resp_id]);
    end
  end
endmodule
