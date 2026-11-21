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

module wfi_commit_guard_formal (
    input logic i_clk,
    input logic i_rst,

    input logic i_legal_head_wfi,
    input logic i_head_stored_ready,
    input logic i_slot1_ready,
    input logic i_unrelated_commit_hold,
    input logic i_jal_mispredict_retired,
    input logic i_commit_recovery,
    input logic i_full_flush,

    input logic i_debug_allows_seed,
    input logic i_higher_arm_d,
    input logic i_wfi_arm_q,

    input logic i_valid_wfi_head,
    input logic i_slot1_retires,
    input logic i_serializer_ready,
    input logic i_partial_flush,
    input logic i_full_flush_request,
    input logic i_commit_redirect,
    input logic i_early_redirect,
    input logic i_early_recovery_hold,
    input logic i_early_flush_request
);
  logic reset_seen = 1'b0;

  typedef enum logic [1:0] {
    RetirementOpen,
    RetirementRecovery,
    RetirementFullFlush
  } retirement_window_t;
  retirement_window_t reference_window;

  // An accepted flush or redirect owns the next retirement window. A
  // full flush also discards a commit redirect received during that window.
  always_ff @(posedge i_clk) begin
    if (i_rst) reference_window <= RetirementOpen;
    else if (i_full_flush_request) reference_window <= RetirementFullFlush;
    else if (i_early_flush_request) reference_window <= RetirementRecovery;
    else if (i_commit_redirect && reference_window != RetirementFullFlush)
      reference_window <= RetirementRecovery;
    else reference_window <= RetirementOpen;
  end

  // The early redirect closes retirement in its own cycle, before the
  // registered backend flush takes over.
  wire registered_window_open = reference_window == RetirementOpen;
  wire reference_open = registered_window_open && !i_early_redirect;
  wire flush_pending = i_commit_recovery || i_full_flush || i_partial_flush;
  wire early_recovery_idle = !i_early_recovery_hold && !i_early_flush_request;
  wire jal_redirect = i_commit_redirect && i_jal_mispredict_retired;
  wire wfi_otherwise_ready = i_legal_head_wfi && i_head_stored_ready && i_serializer_ready &&
      !i_unrelated_commit_hold;

  always_ff @(posedge i_clk) begin
    if (reset_seen && !i_rst) begin
      p_retirement_reference_matches_pending_flush :
      assert (reference_open == !(flush_pending || i_early_recovery_hold));

      if (i_valid_wfi_head && !reference_open)
        p_retirement_no_wfi_during_flush : assert (!i_slot1_retires);

      // A complete WFI can receive its wake in any closed window.
      if (!reference_open && wfi_otherwise_ready) begin
        if (early_recovery_idle) begin
          c_retirement_wfi_in_commit_recovery :
          cover (i_commit_recovery && i_partial_flush && !i_full_flush && $past(jal_redirect));
          c_retirement_wfi_in_early_flush :
          cover (i_partial_flush && !i_commit_recovery && !i_full_flush);
          c_retirement_wfi_in_full_flush : cover (i_full_flush && !i_commit_recovery);
        end
        c_retirement_wfi_in_early_redirect :
        cover (registered_window_open && i_early_recovery_hold && !flush_pending);
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) reset_seen <= 1'b1;
    // The mux selects a registered arm. Use the ROB gate from the edge
    // that captured this arm and its head.
    if (reset_seen && i_wfi_arm_q) p_wfi_arm_passes_slot1_gate : assert ($past(i_slot1_ready));

    if (reset_seen && !i_rst) begin
      // Isolate the recovery and full-flush retirement gates.
      a_other_commit_causes_idle : assume (!i_unrelated_commit_hold && early_recovery_idle);
      // A legal WFI completes at allocation and has no held result. The
      // serializer can still wait for an interrupt.
      if (i_legal_head_wfi) a_wfi_complete : assume (i_head_stored_ready);

      c_wfi_arm : cover (i_wfi_arm_q);
      // Cover each blocked head with the higher-priority arms idle.
      if (i_legal_head_wfi && i_debug_allows_seed && !i_higher_arm_d && !i_slot1_ready) begin
        c_wfi_head_in_commit_recovery :
        cover (i_commit_recovery && !i_full_flush && $past(i_jal_mispredict_retired));
        c_wfi_head_in_full_flush : cover (i_full_flush && !i_commit_recovery);
      end
    end
  end
endmodule

bind cpu_ooo wfi_commit_guard_formal wfi_guard (
    .i_clk(i_clk),
    .i_rst(i_rst),
    .i_legal_head_wfi(head_valid && rob_head_is_wfi && rob_trap_cause == '0),
    .i_head_stored_ready(u_tomasulo.u_rob.head_stored_ready),
    .i_slot1_ready(u_tomasulo.u_rob.commit_ready_early),
    .i_unrelated_commit_hold(i_fatal_stop || csr_commit_fire || trap_mret_commit_hold_q ||
                            coherent_retire_hold || vec_commit_hold),
    .i_jal_mispredict_retired(rob_commit_misprediction_raw && rob_commit_comb.is_jal &&
                              !rob_commit_comb.is_wfi),
    .i_commit_recovery(mispredict_recovery_pending),
    .i_full_flush(flush_all),
    .i_debug_allows_seed(!csr_debug_mode && !step_armed_q),
    .i_higher_arm_d(trap_or_xret_taken || rob_commit_2_valid_raw || rob_commit_valid_raw),
    // Use the registered selects in interrupt_resume_pc's priority order.
    .i_wfi_arm_q(resume_wfi_q && !(resume_take_q || resume_commit_2_q || resume_commit_q)),
    .i_valid_wfi_head(head_valid && rob_head_is_wfi),
    .i_slot1_retires(rob_commit_valid_raw),
    .i_serializer_ready(!u_tomasulo.u_rob.commit_stall_for_retire),
    .i_partial_flush(flush_en),
    .i_full_flush_request(trap_taken || xret_taken || fence_class_flush_event),
    .i_commit_redirect(misprediction_flush_controller_inst.commit_is_misprediction),
    .i_early_redirect(early_mispredict_active),
    .i_early_recovery_hold(u_tomasulo.u_rob.i_early_recovery_en),
    .i_early_flush_request(early_backend_recovery_pending_next)
);
