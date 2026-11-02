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

module coherence_request_endpoint #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned SOURCE = 0,
    parameter int unsigned PORT_CLASS = 0,
    parameter int unsigned SLOT = 0
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_epoch,
    input logic i_request_valid,
    output logic o_request_ready,
    input logic [ADDR_WIDTH+311:0] i_request,
    output logic o_d_valid,
    input logic i_d_ready,
    output logic [ADDR_WIDTH+311:0] o_d,
    input logic i_g_valid,
    output logic o_g_ready,
    input logic [ADDR_WIDTH+274:0] i_g,
    output logic o_grant_valid,
    input logic i_grant_ready,
    output logic [ADDR_WIDTH+274:0] o_grant,
    input logic i_done_valid,
    output logic o_done_ready,
    input logic [1:0] i_done_status,
    input logic i_write_done,
    input logic i_error_disposed,
    output logic o_c_valid,
    output logic o_c_selected,
    input logic i_c_ready,
    output logic [ADDR_WIDTH+17:0] o_c,
    input logic i_u_valid,
    output logic o_u_ready,
    input logic [ADDR_WIDTH+14:0] i_u,
    output logic o_live
);
  `FROST_COHERENCE_TYPES(ADDR_WIDTH)
  typedef enum logic [2:0] {
    Idle,
    SendD,
    WaitG,
    Grant,
    Done,
    SendC,
    WaitU
  } phase_t;
  phase_t phase_q;
  coh_d_t request, demand_q;
  coh_g_t grant_in, grant_q;
  coh_c_t completion_q;
  coh_u_t release_in;
  coherence_pkg::q_t identity;
  assign identity = {2'(SOURCE), 2'(PORT_CLASS), 4'(SLOT), i_epoch};
  assign request = i_request;
  assign grant_in = i_g;
  assign release_in = i_u;
  assign o_d = demand_q;
  assign o_grant = grant_q;
  assign o_c = completion_q;
  assign o_live = phase_q != Idle;
  assign o_request_ready = !i_rst && phase_q == Idle && request.q == identity &&
      coherence_pkg::legal_q(
      request.q
  ) && coherence_pkg::legal_opcode(
      request.q, request.opcode
  ) && request.addr[4:0] == 0;
  assign o_d_valid = !i_rst && phase_q == SendD;
  assign o_g_ready = !i_rst && phase_q == WaitG && grant_in.q == demand_q.q &&
      grant_in.addr == demand_q.addr && grant_in.opcode <= coherence_pkg::GrantFail;
  assign o_grant_valid = !i_rst && phase_q == Grant;
  assign o_done_ready = !i_rst && phase_q == Done && i_done_status <= coherence_pkg::Error &&
      ((i_done_status != coherence_pkg::Error && !grant_q.error) || i_error_disposed) &&
      !(grant_q.error && i_done_status == coherence_pkg::Consumed) &&
      !(coherence_pkg::irrevocable(
      demand_q.opcode
  ) && i_done_status == coherence_pkg::Killed) && !(coherence_pkg::irrevocable(
      demand_q.opcode
  ) && i_done_status == coherence_pkg::Consumed && !grant_q.error &&
      grant_q.opcode != coherence_pkg::GrantFail && !i_write_done);
  assign o_c_selected = phase_q == SendC;
  assign o_c_valid = !i_rst && phase_q == SendC;
  assign o_u_ready = !i_rst && phase_q == WaitU && release_in.q == demand_q.q &&
      release_in.tid == grant_q.tid && release_in.addr == demand_q.addr;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      phase_q <= Idle;
      demand_q <= '0;
      grant_q <= '0;
      completion_q <= '0;
    end else begin
      case (phase_q)
        Idle:
        if (i_request_valid && o_request_ready) begin
          demand_q <= request;
          phase_q  <= SendD;
        end
        SendD:   if (i_d_ready) phase_q <= WaitG;
        WaitG:
        if (i_g_valid && o_g_ready) begin
          grant_q <= grant_in;
          phase_q <= Grant;
        end
        Grant:   if (i_grant_ready) phase_q <= Done;
        Done:
        if (i_done_valid && o_done_ready) begin
          completion_q <= {demand_q.q, grant_q.tid, demand_q.addr, i_done_status, i_write_done};
          phase_q <= SendC;
        end
        SendC:   if (i_c_ready) phase_q <= WaitU;
        WaitU:   if (i_u_valid && o_u_ready) phase_q <= Idle;
        default: phase_q <= Idle;
      endcase
    end
  end

  localparam bit LegalIdentity =
      (SOURCE < 2 && ((PORT_CLASS == 0 && SLOT < 8) ||
                     (PORT_CLASS == 1 && SLOT < 2) || (PORT_CLASS == 2 && SLOT == 0))) ||
      (SOURCE == 2 && PORT_CLASS == 3 && SLOT < 16) ||
      (SOURCE == 3 && PORT_CLASS == 3 && SLOT < 4);
  if (ADDR_WIDTH < 32 || ADDR_WIDTH > 56 || !LegalIdentity) begin : gen_invalid_config
    initial $fatal(1, "coherence_request_endpoint: invalid parameters");
  end
`ifdef FORMAL
  always_comb begin
    p_c_selected_exact : assert (o_c_valid == (!i_rst && o_c_selected));
  end
  always_comb begin
    p_grant_live : assert (!o_grant_valid || o_live);
  end
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      if (o_done_ready && grant_q.error) assert (i_error_disposed);
      if ($past(i_request_valid && o_request_ready)) assert (demand_q == $past(i_request));
      if ($past(i_g_valid && o_g_ready)) assert (grant_q == $past(i_g));
      if ($past(i_done_valid && o_done_ready)) begin
        assert (completion_q.status == $past(i_done_status));
        assert (completion_q.write_done == $past(i_write_done));
      end
      if ($past(o_d_valid && !i_d_ready)) begin
        assert (o_d_valid);
        assert (o_d == $past(o_d));
      end
      if ($past(o_c_valid && !i_c_ready)) begin
        assert (o_c_valid);
        assert (o_c == $past(o_c));
      end
      if ($past(o_grant_valid && !i_grant_ready)) begin
        assert (o_grant_valid);
        assert (o_grant == $past(o_grant));
      end
      if ($past(o_live) && !o_live) assert ($past(i_u_valid && o_u_ready));
      if ($past(o_live)) assert (!o_request_ready || !o_live);
      if (o_c_valid) begin
        assert (completion_q.q == demand_q.q);
        assert (completion_q.tid == grant_q.tid);
        assert (completion_q.addr == demand_q.addr);
      end
      cover (o_u_ready && i_u_valid);
    end
  end
`endif
endmodule
