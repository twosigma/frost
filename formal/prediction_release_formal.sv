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

// Formal integration harness for IF pending-prediction invariants: an atomic
// target handoff suppresses stale old-path buffer validity, and every
// pending-state consumer is masked outside a live episode. It keeps the
// production pc_controller and c_ext_state state machines intact. Predictor
// lookup details are conservatively abstracted to arbitrary requests. The
// omitted lookup, buffer, and progress blockers, together with the broader
// PD-redirect clear, admit extra behavior; that makes the safety proof harder
// rather than assuming away a production trace.
module prediction_release_formal (
    input logic i_clk
);

  localparam int unsigned XLEN = riscv_pkg::XLEN;

  (* anyseq *) logic i_reset;
  (* anyseq *) logic i_stall;
  (* anyseq *) logic i_fetch_progress;
  (* anyseq *) logic i_frontend_flush_request;
  (* anyseq *) logic i_fence_i_flush;
  (* anyseq *) logic [XLEN-1:0] i_fence_i_target;
  (* anyseq *) logic i_branch_taken;
  (* anyseq *) logic [XLEN-1:0] i_branch_target;
  (* anyseq *) logic i_pd_redirect;
  (* anyseq *) logic [XLEN-1:0] i_pd_redirect_target;
  (* anyseq *) logic i_window_resteer_qualifier;
  (* anyseq *) logic i_window_cannot_serve_raw;
  (* anyseq *) logic i_trap_taken;
  (* anyseq *) logic i_mret_taken;
  (* anyseq *) logic [XLEN-1:0] i_trap_target;
  (* anyseq *) logic i_is_compressed;
  (* anyseq *) logic i_slot2_valid;
  (* anyseq *) logic i_slot2_is_compressed;
  (* anyseq *) logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel;
  (* anyseq *) logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel;
  (* anyseq *) logic i_prediction_request;
  (* anyseq *) logic [XLEN-1:0] i_predicted_target;
  (* anyseq *) logic i_ras_predicted;
  (* anyseq *) logic i_prediction_requires_pc_reg_handoff;
  (* anyseq *) logic i_use_instr_buffer;
  (* anyseq *) logic i_prediction_already_emitted;
  (* anyseq *) logic i_sel_nop;
  (* anyseq *) logic i_slot2_prediction_request;
  (* anyseq *) logic [XLEN-1:0] i_slot2_predicted_target;

  logic f_past_valid;
  logic stall_registered;
  logic prediction_used;
  logic prediction_used_for_pc;
  logic prediction_used_from_buffer;
  logic prediction_holdoff;
  logic prediction_from_buffer_holdoff;
  logic prediction_reset_state;
  logic prediction_used_r;
  logic sel_prediction_r;
  logic [XLEN-1:0] predicted_target_r;
  logic slot2_prediction_used;
  logic slot2_prediction_used_for_pc;
  logic i_flush;
  logic i_window_cannot_serve;

  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] pc_reg;
  logic control_flow_holdoff;
  logic any_holdoff_safe;
  logic pending_prediction_active;
  logic pending_prediction_target_handoff;
  logic pending_prediction_target_holdoff;
  logic pending_prediction_fetch_holdoff;
  logic pending_prediction_fetch_holdoff_wcs0;
  logic pending_prediction_fetch_holdoff_wcs;

  logic [31:0] instr_buffer;
  logic prev_was_compressed_at_lo;
  logic is_compressed_for_buffer;
  logic is_compressed_for_pc;
  logic use_buffer_after_prediction;
  logic use_buffer_after_prediction_timing;
  logic is_compressed_saved;
  logic saved_values_valid;
  logic [riscv_pkg::ImemSidebandWidth-1:0] instr_buffer_sideband;
  logic [1:0] instr_buffer_fault;

  initial begin
    f_past_valid = 1'b0;
    assume (i_reset);
  end

  // These are wiring identities in the production integration, expressed as
  // logic instead of assumptions: every FENCE-class event is part of the full
  // frontend flush, and a resteer is a qualification of the raw mismatch.
  assign i_flush = i_frontend_flush_request || i_fence_i_flush;
  assign i_window_cannot_serve = i_window_cannot_serve_raw && i_window_resteer_qualifier;

  // Conservatively model the IF-stage boundary without importing the BTB, RAS,
  // or instruction aligner.  The request remains arbitrary and production-only
  // blockers are omitted.
  assign prediction_used_for_pc =
      i_prediction_request && !i_reset && !i_trap_taken && !i_mret_taken &&
      !stall_registered && !any_holdoff_safe && !prediction_holdoff;
  assign prediction_used = prediction_used_for_pc && !i_branch_taken && !i_stall;
  assign prediction_used_from_buffer = prediction_used && i_use_instr_buffer;
  assign slot2_prediction_used_for_pc =
      i_slot2_prediction_request && !i_reset && !i_trap_taken && !i_mret_taken &&
      !stall_registered && !any_holdoff_safe && !prediction_holdoff;
  assign slot2_prediction_used = slot2_prediction_used_for_pc && !i_branch_taken && !i_stall;

  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    stall_registered <= i_stall;

    // One startup reset edge is sufficient to initialize every state element.
    if (f_past_valid) assume (!i_reset);

    if (i_reset || i_flush || i_pd_redirect) begin
      prediction_holdoff <= 1'b0;
    end else if (!i_stall && i_fetch_progress) begin
      prediction_holdoff <= prediction_used;
    end

    if (i_reset || i_flush) begin
      prediction_from_buffer_holdoff <= 1'b0;
    end else if (!i_stall && i_fetch_progress) begin
      prediction_from_buffer_holdoff <= prediction_used_from_buffer;
    end

    if (i_reset) prediction_reset_state <= 1'b0;
    else prediction_reset_state <= prediction_used || slot2_prediction_used;

    if (i_reset || i_flush || i_pd_redirect || slot2_prediction_used) begin
      prediction_used_r <= 1'b0;
      sel_prediction_r  <= 1'b0;
    end else if (!i_stall && i_fetch_progress) begin
      prediction_used_r <= prediction_used;
      sel_prediction_r  <= prediction_used;
    end
    if (!i_stall && i_fetch_progress) predicted_target_r <= i_predicted_target;
  end

  pc_controller #(
      .XLEN(XLEN)
  ) u_pc_controller (
      .i_clk,
      .i_reset,
      .i_stall,
      .i_stall_registered(stall_registered),
      .i_fetch_progress,
      .i_flush,
      .i_fence_i_flush,
      .i_fence_i_target,
      .i_branch_taken,
      .i_branch_target,
      .i_pd_redirect,
      .i_pd_redirect_target,
      .i_window_cannot_serve,
      .i_window_cannot_serve_raw,
      .i_trap_taken,
      .i_mret_taken,
      .i_trap_target,
      .i_is_compressed,
      .i_is_compressed_for_pc(is_compressed_for_pc),
      .i_slot2_valid,
      .i_slot2_is_compressed,
      .i_pc_fetch_advance_sel,
      .i_pc_reg_advance_sel,
      // The selects' i_sel_nop cofactors only reach the abstracted
      // calculator; the merged selects stand in for both.
      .i_pc_fetch_advance_sel_run(i_pc_fetch_advance_sel),
      .i_pc_fetch_advance_sel_nop(i_pc_fetch_advance_sel),
      .i_pc_reg_advance_sel_run(i_pc_reg_advance_sel),
      .i_pc_reg_advance_sel_nop(i_pc_reg_advance_sel),
      .i_predicted_taken(prediction_used_for_pc),
      .i_predicted_target,
      .i_predicted_target_r(predicted_target_r),
      .i_prediction_used(prediction_used),
      .i_prediction_used_for_pc(prediction_used_for_pc),
      .i_ras_predicted,
      .i_sel_prediction_r(sel_prediction_r),
      .i_prediction_requires_pc_reg_handoff,
      .i_prediction_holdoff(prediction_holdoff),
      .i_prediction_from_buffer_holdoff(prediction_from_buffer_holdoff),
      .i_prediction_used_from_buffer(prediction_used_from_buffer),
      .i_prediction_already_emitted,
      .i_sel_nop,
      .i_slot2_prediction_used(slot2_prediction_used),
      .i_slot2_prediction_used_for_pc(slot2_prediction_used_for_pc),
      .i_slot2_predicted_target,
      .o_slot2_redirect_q(),
      .o_pc(pc),
      .o_pc_reg(pc_reg),
      .o_control_flow_change(),
      .o_control_flow_holdoff(control_flow_holdoff),
      .o_control_flow_to_halfword(),
      .o_control_flow_to_halfword_r(),
      .o_reset_holdoff(),
      .o_any_holdoff(),
      .o_any_holdoff_safe(any_holdoff_safe),
      .o_mid_32bit_correction(),
      .o_pending_prediction_active(pending_prediction_active),
      .o_pending_prediction_pc(),
      .o_pending_prediction_target_handoff(pending_prediction_target_handoff),
      .o_pending_prediction_holdoff(),
      .o_pending_prediction_holdoff_wcs0(),
      .o_pending_prediction_holdoff_wcs(),
      .o_pending_prediction_fetch_holdoff(pending_prediction_fetch_holdoff),
      .o_pending_prediction_fetch_holdoff_wcs0(pending_prediction_fetch_holdoff_wcs0),
      .o_pending_prediction_fetch_holdoff_wcs(pending_prediction_fetch_holdoff_wcs),
      .o_pending_prediction_target_holdoff(pending_prediction_target_holdoff),
      .o_pending_prediction_redirect_kill(),
      // Translation starts from registered o_pc. The next-PC value and the
      // retained selector-observation ports are irrelevant to this release
      // proof, so they stay unconnected.
      .o_next_pc(),
      .o_next_pc_holds(),
      .o_pc_update_en(),
      .o_npc_sel(),
      .o_npc_seq(),
      .o_npc_cmp_val(),
      .o_npc_seq_verdict(),
      .o_npc_val()
  );

  c_ext_state #(
      .XLEN(XLEN)
  ) u_c_ext_state (
      .i_clk,
      .i_reset,
      .i_stall,
      .i_flush,
      .i_fence_i_flush,
      .i_stall_registered(stall_registered),
      .i_control_flow_holdoff(control_flow_holdoff),
      .i_any_holdoff_safe(any_holdoff_safe),
      .i_prediction_holdoff(prediction_holdoff),
      .i_prediction_reset_state(prediction_reset_state),
      .i_pending_prediction_active(pending_prediction_active),
      .i_pending_prediction_target_handoff(pending_prediction_target_handoff),
      .i_pending_prediction_target_holdoff(pending_prediction_target_holdoff),
      .i_prediction_from_buffer_holdoff(prediction_from_buffer_holdoff),
      .i_effective_instr('0),
      .i_fetch_word_swapped(1'b0),
      .i_pc(pc),
      .i_pc_reg(pc_reg),
      .i_is_compressed,
      .i_sel_nop,
      .i_fetch_progress,
      .i_instr_sideband('0),
      .i_instr_fault('0),
      .i_slot2_valid,
      .o_instr_buffer(instr_buffer),
      .o_prev_was_compressed_at_lo(prev_was_compressed_at_lo),
      .o_is_compressed_for_buffer(is_compressed_for_buffer),
      .o_is_compressed_for_pc(is_compressed_for_pc),
      .o_use_buffer_after_prediction(use_buffer_after_prediction),
      .o_use_buffer_after_prediction_timing(use_buffer_after_prediction_timing),
      .o_is_compressed_saved(is_compressed_saved),
      .o_saved_values_valid(saved_values_valid),
      .o_instr_buffer_sideband(instr_buffer_sideband),
      .o_instr_buffer_fault(instr_buffer_fault)
  );

endmodule : prediction_release_formal
