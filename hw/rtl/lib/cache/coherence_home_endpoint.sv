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

module coherence_home_endpoint #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned NUM_HARTS = 2,
    parameter int unsigned L2_NUM_MSHR = 4,
    parameter int unsigned TID = 0
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_epoch,
    input logic i_d_valid,
    output logic o_d_ready,
    input logic [ADDR_WIDTH+311:0] i_d,
    output logic o_work_valid,
    // o_work_valid without the reset term, for selection logic whose state
    // is cleared by the same reset.
    output logic o_work_offer,
    output logic [ADDR_WIDTH+311:0] o_work,
    input logic i_result_valid,
    output logic o_result_ready,
    input logic [ADDR_WIDTH+274:0] i_result,
    output logic o_g_valid,
    input logic i_g_ready,
    output logic [ADDR_WIDTH+274:0] o_g,
    input logic i_c_valid,
    input logic i_error_disposed,
    output logic o_c_ready,
    input logic [ADDR_WIDTH+17:0] i_c,
    input logic i_absorb_valid,
    output logic o_absorb_ready,
    input logic [ADDR_WIDTH+274:0] i_absorb,
    input logic i_cancel_valid,
    input logic [ADDR_WIDTH+10:0] i_cancel,
    output logic o_u_valid,
    input logic i_u_ready,
    output logic [ADDR_WIDTH+14:0] o_u,
    output logic o_live,
    output logic [3:0] o_pending
);
  `FROST_COHERENCE_TYPES(ADDR_WIDTH)
  typedef enum logic [2:0] {
    Idle,
    Work,
    WaitC,
    Cancel,
    SendU
  } phase_t;
  // One-hot state keeps each transition, including G acceptance, to a
  // single term of its next state.
  (* fsm_encoding = "one_hot" *) phase_t phase_q;
  coh_d_t demand_in, demand_q;
  coh_g_t result_in;
  logic [2:0] grant_opcode_q;
  logic grant_error_q;
  logic result_matches;
  coh_c_t completion_in;
  coh_r_t absorb_in;
  coh_wa_t cancel_in;
  logic [3:0] pending_q;
  logic [3:0] seen_q;
  logic [3:0] cancelled_q;
  logic [1:0] absorb_slot, cancel_slot;
  assign demand_in = i_d;
  assign result_in = i_result;
  assign completion_in = i_c;
  assign absorb_in = i_absorb;
  assign cancel_in = i_cancel;
  assign absorb_slot = {absorb_in.hart, absorb_in.put_id};
  assign cancel_slot = {cancel_in.hart, cancel_in.put_id};
  assign o_live = phase_q != Idle;
  assign o_pending = pending_q;
  assign o_work = demand_q;
  assign o_work_offer = phase_q == Work;
  assign o_work_valid = !i_rst && o_work_offer;
  assign o_d_ready = !i_rst && phase_q == Idle && coherence_pkg::legal_q(
      demand_in.q
  ) && demand_in.q.epoch == i_epoch &&
      (int'(demand_in.q.src) < NUM_HARTS || demand_in.q.src >= 2) && coherence_pkg::legal_opcode(
      demand_in.q, demand_in.opcode
  ) && demand_in.addr[4:0] == 0;
  assign result_matches = result_in.q == demand_q.q &&
      result_in.tid == 6'(TID) && result_in.addr == demand_q.addr &&
      result_in.opcode <= coherence_pkg::GrantFail;
  assign o_g_valid = !i_rst && phase_q == Work && i_result_valid && result_matches;
  // G readiness is the last term of result acceptance.
  (* keep = "true" *) logic result_take;
  assign result_take = !i_rst && phase_q == Work && result_matches;
  assign o_result_ready = result_take && i_g_ready;
  assign o_g = result_in;
  localparam int unsigned CompletionKeyWidth = ADDR_WIDTH + 15;
  localparam int unsigned CompletionParts = (CompletionKeyWidth + 2) / 3;
  localparam int unsigned CompletionGroups = (CompletionParts + 5) / 6;
  wire [CompletionKeyWidth-1:0] completion_key =
      {completion_in.q, completion_in.tid, completion_in.addr};
  wire [CompletionKeyWidth-1:0] expected_completion_key =
      {demand_q.q, 6'(TID), demand_q.addr};
  (* keep = "true" *) logic [CompletionParts-1:0] completion_parts;
  (* keep = "true" *) logic [CompletionGroups-1:0] completion_groups;
  logic completion_matches;
  for (genvar part = 0; part < CompletionParts; part++) begin : gen_completion_part
    localparam int unsigned Bits = CompletionKeyWidth - 3 * part < 3 ?
        CompletionKeyWidth - 3 * part : 3;
    assign completion_parts[part] = completion_key[3*part+:Bits] ==
        expected_completion_key[3*part+:Bits];
  end
  for (
      genvar group_index = 0; group_index < CompletionGroups; group_index++
  ) begin : gen_completion_group
    localparam int unsigned Parts = CompletionParts - 6 * group_index < 6 ?
        CompletionParts - 6 * group_index : 6;
    assign completion_groups[group_index] = &completion_parts[6*group_index+:Parts];
  end
  assign completion_matches = &completion_groups;
  // The status check depends on the C status bits and this endpoint's
  // registers only, so it forms beside the key comparison.
  wire irrevocable_demand = coherence_pkg::irrevocable(demand_q.opcode);
  wire completion_status_ok = completion_in.status <= coherence_pkg::Error &&
      ((completion_in.status != coherence_pkg::Error && !grant_error_q) || i_error_disposed) &&
      !(grant_error_q && completion_in.status == coherence_pkg::Consumed) &&
      !(irrevocable_demand && completion_in.status == coherence_pkg::Killed) &&
      !(irrevocable_demand && completion_in.status == coherence_pkg::Consumed &&
        !grant_error_q && grant_opcode_q != coherence_pkg::GrantFail &&
        !completion_in.write_done);
  wire waiting_completion = phase_q == WaitC;
  assign o_c_ready = !i_rst && waiting_completion && completion_matches && completion_status_ok;
  assign o_absorb_ready = !i_rst && phase_q == Work && absorb_in.absorbed &&
      absorb_in.opcode == coherence_pkg::ProbeData && absorb_in.data_valid && !absorb_in.error &&
      absorb_in.tid == 6'(TID) && absorb_in.epoch == demand_q.q.epoch &&
      absorb_in.put_epoch == demand_q.q.epoch && absorb_in.addr == demand_q.addr &&
      int'(absorb_in.hart) < NUM_HARTS && !seen_q[absorb_slot];
  assign o_u_valid = !i_rst && phase_q == SendU;
  assign o_u = {demand_q.q, 6'(TID), demand_q.addr};

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      phase_q <= Idle;
      demand_q <= '0;
      grant_opcode_q <= '0;
      grant_error_q <= 1'b0;
      pending_q <= '0;
      seen_q <= '0;
      cancelled_q <= '0;
    end else begin
      if (i_absorb_valid && o_absorb_ready) begin
        pending_q[absorb_slot] <= !cancelled_q[absorb_slot];
        seen_q[absorb_slot] <= 1'b1;
      end
      if (i_cancel_valid && o_live && cancel_in.absorbed && !cancel_in.error &&
          cancel_in.tid == 6'(TID) && cancel_in.epoch == demand_q.q.epoch &&
          cancel_in.addr == demand_q.addr) begin
        pending_q[cancel_slot]   <= 1'b0;
        cancelled_q[cancel_slot] <= 1'b1;
      end
      case (phase_q)
        Idle:
        if (i_d_valid && o_d_ready) begin
          demand_q <= demand_in;
          pending_q <= '0;
          seen_q <= '0;
          cancelled_q <= '0;
          phase_q <= Work;
        end
        Work:
        if (i_result_valid && o_result_ready) begin
          grant_opcode_q <= result_in.opcode;
          grant_error_q <= result_in.error;
          phase_q <= WaitC;
        end
        WaitC:   if (i_c_valid && o_c_ready) phase_q <= pending_q == 0 ? SendU : Cancel;
        Cancel:  if (pending_q == 0) phase_q <= SendU;
        SendU:   if (i_u_ready) phase_q <= Idle;
        default: phase_q <= Idle;
      endcase
    end
  end
  if (ADDR_WIDTH < 32 || ADDR_WIDTH > 56 || NUM_HARTS < 1 || NUM_HARTS > 2 ||
      L2_NUM_MSHR < 1 || L2_NUM_MSHR > 64 ||
      coherence_pkg::home_count(
          NUM_HARTS, L2_NUM_MSHR
      ) > 64 || TID >= coherence_pkg::completion_count(
          NUM_HARTS
      )) begin : gen_invalid_config
    initial $fatal(1, "coherence_home_endpoint: invalid parameters");
  end
`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (!i_rst) assert (phase_q <= SendU);
  end
`ifdef FORMAL
  always_comb
`else
  always @(posedge i_clk)
`endif
  begin
    p_completion_key_exact : assert (completion_matches ==
        (completion_in.q == demand_q.q && completion_in.tid == 6'(TID) &&
         completion_in.addr == demand_q.addr));
  end
`endif
`ifdef FORMAL
`ifndef COHERENCE_HOME_CONTROL
  logic f_past_valid = 1'b0;
  logic f_granted, f_completed, f_early_cancel;
  always_ff @(posedge i_clk) begin
    if (i_rst || (i_d_valid && o_d_ready)) begin
      f_granted <= 1'b0;
      f_completed <= 1'b0;
      f_early_cancel <= 1'b0;
    end else begin
      if (i_cancel_valid && o_live && cancel_in.absorbed && !cancel_in.error &&
          cancel_in.tid == 6'(TID) && cancel_in.epoch == demand_q.q.epoch &&
          cancel_in.addr == demand_q.addr && !seen_q[cancel_slot] && !i_absorb_valid)
        f_early_cancel <= 1'b1;
      if (o_g_valid && i_g_ready) f_granted <= 1'b1;
      if (i_c_valid && o_c_ready) f_completed <= 1'b1;
    end
  end
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      if ($past(i_d_valid && o_d_ready)) assert (demand_q == $past(i_d));
      if ($past(i_result_valid && !o_result_ready)) begin
        assume (i_result_valid);
        assume (i_result == $past(i_result));
      end
      if ($past(o_g_valid && !i_g_ready)) begin
        assert (o_g_valid);
        assert (o_g == $past(o_g));
      end
      if ($past(o_u_valid && !i_u_ready)) begin
        assert (o_u_valid);
        assert (o_u == $past(o_u));
      end
      assert (phase_q <= SendU);
      if (phase_q == Idle) assert (pending_q == 0);
      if (phase_q == WaitC || phase_q == Cancel || phase_q == SendU) assert (f_granted);
      if (phase_q == Cancel || phase_q == SendU) assert (f_completed);
      if (o_u_valid) begin
        assert (pending_q == 0);
        assert (f_granted && f_completed);
      end
      if ($past(i_c_valid && o_c_ready && pending_q == 0)) assert (o_u_valid);
      for (int slot = 0; slot < 4; slot++) begin
        if ($past(pending_q[slot]) && !pending_q[slot]) begin
          assert ($past(i_cancel_valid && cancel_in.absorbed && !cancel_in.error));
          assert ($past(cancel_slot) == 2'(slot));
          assert ($past(cancel_in.tid) == 6'(TID));
          assert ($past(cancel_in.epoch) == $past(demand_q.q.epoch));
          assert ($past(cancel_in.addr) == $past(demand_q.addr));
        end
      end
      if ($past(o_live) && !o_live) assert ($past(o_u_valid && i_u_ready));
      assert ((pending_q & ~seen_q) == 0);
      assert ((pending_q & cancelled_q) == 0);
      if (o_c_ready && grant_error_q) assert (i_error_disposed);
      cover (o_u_valid && i_u_ready && seen_q != 0);
      cover (o_u_valid && i_u_ready && seen_q != 0 && f_early_cancel);
    end
  end
`endif
`endif
endmodule
