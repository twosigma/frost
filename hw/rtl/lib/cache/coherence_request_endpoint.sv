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
    parameter int unsigned SLOT = 0,
    parameter bit LOCAL_PHASE_UPDATES = 1'b0
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
    input logic i_c_ready,
    output logic [ADDR_WIDTH+17:0] o_c,
    input logic i_u_valid,
    output logic o_u_ready,
    input logic [ADDR_WIDTH+14:0] i_u,
`ifdef FORMAL
    output logic [6:0] o_phase,
    output logic [2:0] o_formal_phase,
`endif
`ifdef COH_MAINT_OWNED
    output logic [6:0] o_maint_phase,
`endif
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
  logic idle_phase, send_d_phase, wait_g_phase, grant_phase;
  logic done_phase, send_c_phase, wait_u_phase;
`ifdef FORMAL
  // Harnesses read the encoded phase in either form of the phase state.
  if (LOCAL_PHASE_UPDATES) begin : gen_formal_local_phase
    assign o_formal_phase = {
      done_phase || send_c_phase || wait_u_phase,
      wait_g_phase || grant_phase || wait_u_phase,
      send_d_phase || grant_phase || send_c_phase
    };
  end else begin : gen_formal_encoded_phase
    assign o_formal_phase = phase_q;
  end
`endif
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
  assign o_live = !idle_phase;
  assign o_request_ready = idle_phase && request.q == identity && coherence_pkg::legal_q(
      request.q
  ) && coherence_pkg::legal_opcode(
      request.q, request.opcode
  ) && request.addr[4:0] == 0;
  assign o_d_valid = send_d_phase;
  assign o_g_ready = wait_g_phase && grant_in.q == demand_q.q &&
      grant_in.addr == demand_q.addr && grant_in.opcode <= coherence_pkg::GrantFail;
  assign o_grant_valid = grant_phase;
  assign o_done_ready = done_phase && i_done_status <= coherence_pkg::Error &&
      ((i_done_status != coherence_pkg::Error && !grant_q.error) || i_error_disposed) &&
      !(grant_q.error && i_done_status == coherence_pkg::Consumed) &&
      !(coherence_pkg::irrevocable(
      demand_q.opcode
  ) && i_done_status == coherence_pkg::Killed) && !(coherence_pkg::irrevocable(
      demand_q.opcode
  ) && i_done_status == coherence_pkg::Consumed && !grant_q.error &&
      grant_q.opcode != coherence_pkg::GrantFail && !i_write_done);
  assign o_c_valid = send_c_phase;
  assign o_u_ready = wait_u_phase && release_in.q == demand_q.q &&
      release_in.tid == grant_q.tid && release_in.addr == demand_q.addr;
  if (LOCAL_PHASE_UPDATES) begin : gen_local_phases
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        idle_phase <= 1'b1;
        send_d_phase <= 1'b0;
        wait_g_phase <= 1'b0;
        grant_phase <= 1'b0;
        done_phase <= 1'b0;
        send_c_phase <= 1'b0;
        wait_u_phase <= 1'b0;
        demand_q <= '0;
        grant_q <= '0;
        completion_q <= '0;
      end else begin
        if (i_request_valid && o_request_ready) begin
          idle_phase <= 1'b0;
          send_d_phase <= 1'b1;
          demand_q <= request;
        end
        if (send_d_phase && i_d_ready) begin
          send_d_phase <= 1'b0;
          wait_g_phase <= 1'b1;
        end
        if (i_g_valid && o_g_ready) begin
          wait_g_phase <= 1'b0;
          grant_phase <= 1'b1;
          grant_q <= grant_in;
        end
        if (grant_phase && i_grant_ready) begin
          grant_phase <= 1'b0;
          done_phase  <= 1'b1;
        end
        if (i_done_valid && o_done_ready) begin
          done_phase   <= 1'b0;
          send_c_phase <= 1'b1;
          completion_q <= {demand_q.q, grant_q.tid, demand_q.addr, i_done_status, i_write_done};
        end
        if (send_c_phase && i_c_ready) begin
          send_c_phase <= 1'b0;
          wait_u_phase <= 1'b1;
        end
        if (i_u_valid && o_u_ready) begin
          wait_u_phase <= 1'b0;
          idle_phase   <= 1'b1;
        end
      end
    end
  end else begin : gen_encoded_phases
    assign idle_phase   = phase_q == Idle;
    assign send_d_phase = phase_q == SendD;
    assign wait_g_phase = phase_q == WaitG;
    assign grant_phase  = phase_q == Grant;
    assign done_phase   = phase_q == Done;
    assign send_c_phase = phase_q == SendC;
    assign wait_u_phase = phase_q == WaitU;
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
  end
  localparam bit LegalIdentity =
      (SOURCE < 2 && ((PORT_CLASS == 0 && SLOT < 8) ||
                     ((PORT_CLASS == 1 || PORT_CLASS == 2) && SLOT < 2))) ||
      (SOURCE == 2 && PORT_CLASS == 3 && SLOT < 16) ||
      (SOURCE == 3 && PORT_CLASS == 3 && SLOT < 4);
  if (ADDR_WIDTH < 32 || ADDR_WIDTH > 56 || !LegalIdentity) begin : gen_invalid_config
    initial $fatal(1, "coherence_request_endpoint: invalid parameters");
  end
`ifdef FORMAL
  assign o_phase = {
    wait_u_phase, send_c_phase, done_phase, grant_phase, wait_g_phase, send_d_phase, idle_phase
  };
  always_comb begin
    if (!i_rst) p_grant_live : assert (!o_grant_valid || o_live);
  end
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (f_past_valid) p_phase_onehot : assert ($onehot(o_phase));
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
`ifdef COH_MAINT_OWNED
  always_ff @(posedge i_clk)
    if (!i_rst) begin
      p_maint_owned_ep_phase :
      assert ($onehot(
          {
            idle_phase,
            send_d_phase,
            wait_g_phase,
            grant_phase,
            done_phase,
            send_c_phase,
            wait_u_phase
          }
      ));
      if (o_live) p_maint_owned_ep_identity : assert (demand_q.q == identity);
      if (!$past(i_rst)) begin
        if ($past(o_d_valid && !i_d_ready))
          p_maint_owned_ep_d_hold : assert (o_d_valid && o_d == $past(o_d));
        if ($past(o_c_valid && !i_c_ready))
          p_maint_owned_ep_c_hold : assert (o_c_valid && o_c == $past(o_c));
      end
    end
`endif
`ifdef COH_MAINT_OWNED
  assign o_maint_phase = {
    wait_u_phase, send_c_phase, done_phase, grant_phase, wait_g_phase, send_d_phase, idle_phase
  };
`endif
endmodule
