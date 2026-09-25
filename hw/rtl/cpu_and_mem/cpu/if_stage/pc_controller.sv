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

/*
  IF PC controller: the fetch PC (o_pc), which addresses instruction memory
  and the slot-1 BTB lookup, and pc_reg (o_pc_reg), the PC of the packet IF
  emits. Next fetch PC priority: reset, trap or xRET, FENCE-class flush,
  misprediction recovery, PD redirect, served-window resteer, hold while no
  window arrives, slot-2 prediction, slot-1 prediction, the pending-prediction
  and halfword catch-up arms, then the sequential PC. pc_reg takes a slot-1
  prediction one cycle later, after the branch itself is emitted. See
  hw/rtl/cpu_and_mem/cpu/README.md, "Pending-prediction handoff" and
  "Served-window check and retries". "Raw WCS" below means
  i_window_cannot_serve_raw.
*/
module pc_controller #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    // Set to 1 by a caller that disables prediction while a pending handoff
    // is ready, as if_stage does (a ready handoff asserts both prediction
    // holdoff outputs). A ready handoff then never meets a slot-2 prediction
    // and need not check for one. The default keeps the check for standalone
    // use.
    parameter bit PENDING_HANDOFF_EXCLUDES_SLOT2 = 1'b0
) (
    input logic i_clk,

    // Pipeline control
    input logic i_reset,
    input logic i_stall,
    input logic i_stall_registered,
    // Fetch progress: the live window is valid, or the stall-replay bundle is
    // being presented (see if_stage). When low, the fetch PC freezes through
    // its mux hold arm, pc_reg through its load enable, and the pending-
    // prediction state through the fetch_stall gating below. Redirects still
    // land. The provider keeps serving the owed fetch address while o_pc
    // holds, so no request is skipped.
    input logic i_fetch_progress,
    input logic i_flush,  // Pipeline flush: blocks state updates from garbage instructions
    // Registered FENCE-class flush pulse: FENCE.I, SFENCE.VMA, or a CSR
    // instruction that accesses satp or writes mstatus or sstatus.
    input logic i_fence_i_flush,
    input logic [XLEN-1:0] i_fence_i_target,

    // Misprediction recovery (early or at commit) for a JAL, JALR, or
    // conditional branch, from ex_comb_synthesizer. A correctly predicted
    // branch causes no redirect here.
    input logic            i_branch_taken,
    input logic [XLEN-1:0] i_branch_target,

    // PD predicted-taken BTB-miss redirect (from pd_stage)
    input logic i_pd_redirect,
    input logic [XLEN-1:0] i_pd_redirect_target,
    input logic i_window_cannot_serve,  // Served window cannot hold pc_reg -> resteer+hold
    // Raw WCS: the served-window mismatch before if_stage's other squash
    // terms qualify it. It limits the immediate-predecessor release (see
    // pim_base) to cases where the predecessor would otherwise be dropped.
    input logic i_window_cannot_serve_raw,

    // Trap control
    input logic            i_trap_taken,
    input logic            i_mret_taken,
    input logic [XLEN-1:0] i_trap_target,

    // C-extension state
    input logic i_is_compressed,  // Slot-1 size; used by the halfword catch-up arm

    // Bundle advance: +2 or +4 for one instruction, +4, +6, or +8 for two.
    // i_slot2_valid and i_slot2_is_compressed are not used; if_stage folds
    // them into the advance selects.
    input logic i_slot2_valid,
    input logic i_slot2_is_compressed,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel,
    // The two selects above for i_sel_nop = 0 and 1, which
    // pc_increment_calculator uses; the merged selects feed only its
    // simulation reference.
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel_run,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel_nop,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel_run,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel_nop,

    // Branch prediction (from branch_prediction_controller)
    input logic i_predicted_taken,  // BTB predicts taken (not used)
    input logic [XLEN-1:0] i_predicted_target,  // Predicted target address (combinational)
    input logic [XLEN-1:0] i_predicted_target_r,  // Predicted target address (registered)
    input logic i_prediction_used,  // Prediction consumed this cycle
    input logic i_prediction_used_for_pc,  // Stall-ungated select for PC D mux only
    input logic i_ras_predicted,  // Prediction came from RAS/return detection
    input logic i_sel_prediction_r,  // Registered prediction used (for pc_reg)
    // Predicted op must still execute in IF/PD/ID
    input logic i_prediction_requires_pc_reg_handoff,
    input logic i_prediction_holdoff,  // Registered: the cycle after a prediction
    input logic i_prediction_from_buffer_holdoff,  // RAS predicted from buffer, stale cycle
    input logic i_prediction_used_from_buffer,  // Current prediction came from IF buffer
    // The predicted branch's own packet is being emitted this cycle, because
    // variable fetch latency closed the gap between o_pc and pc_reg. The
    // registered target handoff covers it, so the prediction never pends, even
    // with a halfword target.
    input logic i_prediction_already_emitted,
    input logic i_sel_nop,

    // Slot-2 prediction redirect, from the staged BTB lookup or its live
    // fallback. Like a PD redirect, a taken slot-2 prediction moves both o_pc
    // and pc_reg to the target at once. The lookup happens in cycle N+1, when
    // the slot-2 instruction is in IF, but fetch has already requested the
    // next sequential window, so the window in N+2 is wrong-path;
    // o_slot2_redirect_q marks that cycle for if_stage's sel_nop.
    input  logic            i_slot2_prediction_used,
    // Slot-2 PC-mux arm select (stall-ungated; branch/span kills already applied).
    input  logic            i_slot2_prediction_used_for_pc,
    input  logic [XLEN-1:0] i_slot2_predicted_target,
    // The same slot-2 prediction, split for pc_reg timing. The staged select
    // does not depend on the live-PC alias check. The live select is computed
    // as if i_slot1_aliases_slot2_candidate were true, so that slow
    // full-address compare only picks the final pc_reg value instead of
    // passing through the pc_reg priority mux. o_pc and all control use the
    // combined signals above.
    input  logic            i_slot2_staged_prediction_used_for_pc,
    input  logic            i_slot1_aliases_slot2_candidate,
    input  logic            i_slot2_live_target_used_for_pc_cofactor,
    input  logic [XLEN-1:0] i_slot2_staged_predicted_target,
    input  logic [XLEN-1:0] i_slot2_live_predicted_target,
    output logic            o_slot2_redirect_q,

    // Outputs
    output logic [XLEN-1:0] o_pc,
    output logic [XLEN-1:0] o_pc_reg,
    // A separate register copy of o_pc_reg[1] for if_stage's instruction-size
    // and served-window checks. Those checks feed every fetch and pc_reg
    // update, so giving them their own low-fanout register keeps the
    // high-fanout o_pc_reg[1] from launching all of those paths.
    output logic o_pc_reg_high_for_coverage,
    // High after a served-window resteer from a pc_reg in the upper half of a
    // word, while o_pc still names the lower parcel of that word. That parcel
    // is off the program path, so its BTB lookup must be ignored, and IF
    // gives the packet a not-taken direction. The flag holds through fetch
    // gaps, stalls, and NOP cycles, and comes from a register set by the
    // resteer arm, so it adds no wide PC compare to the prediction path.
    output logic o_fetch_lookup_is_lower_parcel,
    output logic o_control_flow_change,
    output logic o_control_flow_holdoff,
    output logic o_control_flow_to_halfword,
    output logic o_control_flow_to_halfword_r,
    output logic o_reset_holdoff,
    output logic o_any_holdoff,
    output logic o_any_holdoff_safe,
    output logic o_mid_32bit_correction,
    output logic o_pending_prediction_active,
    // PC of the branch the pending prediction belongs to. IF compares packets
    // with it, so the older predecessor released early (see pim_base) cannot
    // take the branch's prediction metadata.
    output logic [XLEN-1:0] o_pending_prediction_pc,
    // o_pending_prediction_pc - 2 and - 4: the slot-1 PC when the pending
    // branch is in slot 2 behind a compressed or a 32-bit instruction. IF
    // compares pc_reg with both and selects with the late slot-1 size, which
    // keeps that bit out of a 64-bit add and compare.
    output logic [XLEN-1:0] o_pending_prediction_prev_pc,
    output logic [XLEN-1:0] o_pending_prediction_prev_native_pc,
    output logic o_pending_prediction_target_handoff,
    output logic o_pending_prediction_holdoff,
    // o_pending_prediction_holdoff with raw WCS forced to 0 and to 1. IF builds
    // its prediction disable from the WCS=0 version and disables prediction
    // outright when raw WCS is 1. Both are outputs so the combined hold can be
    // checked against them.
    output logic o_pending_prediction_holdoff_wcs0,
    output logic o_pending_prediction_holdoff_wcs,
    output logic o_pending_prediction_fetch_holdoff,
    // o_pending_prediction_fetch_holdoff with raw WCS forced to 0. IF ORs raw
    // WCS into sel_nop last, which makes this version exact there.
    output logic o_pending_prediction_fetch_holdoff_wcs0,
    // o_pending_prediction_fetch_holdoff with raw WCS forced to 1. IF builds
    // the window-resteer qualifier from it while the served-window compare is
    // still settling.
    output logic o_pending_prediction_fetch_holdoff_wcs,
    output logic o_pending_prediction_target_holdoff,
    // Kills prediction_metadata_tracker's saved metadata for the pending
    // prediction. It fires on every event that clears the pending state here
    // other than the target handoff: each redirect, and pc_reg passing the
    // branch. The metadata says fetch has already redirected for the branch,
    // so it must not outlive that redirect, or a later replay attaches it to
    // the refetched branch. For example, a JAL whose pending state a PD
    // redirect killed would re-emit marked as correctly predicted, the ROB
    // would see no misprediction, and the lost fetch redirect would never be
    // recovered.
    output logic o_pending_prediction_redirect_kill,
    // Observation outputs for tests: the next fetch PC, and whether it is a
    // hold because no window arrived. o_pc_update_en is the fetch PC's load
    // enable, which if_stage uses to qualify its registered fetch-redirect
    // pulses.
    output logic [XLEN-1:0] o_next_pc,
    output logic o_next_pc_holds,
    output logic o_pc_update_en,
    // Next-PC arms, one bit or entry per arm in priority order: each arm's
    // request (o_npc_cond), the one-hot winner (o_npc_sel), and which arms are
    // o_pc plus a small sequential step (o_npc_seq). if_stage uses the
    // requests and o_npc_seq to tell provider retargets from sequential
    // advances; taking the raw requests lets its registered classifier finish
    // the prediction cases before the late prediction requests settle.
    // o_npc_cmp_val, o_npc_val, and o_npc_seq_verdict are observation outputs
    // for tests and the simulation checks below.
    output logic [riscv_pkg::PcNextArms-1:0] o_npc_cond,
    output logic [riscv_pkg::PcNextArms-1:0] o_npc_sel,
    output logic [riscv_pkg::PcNextArms-1:0] o_npc_seq,
    // Each arm's early operand: its value, except that an arm that can be
    // either sequential or not always shows its non-sequential operand.
    output logic [riscv_pkg::PcNextArms-1:0][XLEN-1:0] o_npc_cmp_val,
    // Every arm's value. next_pc is their one-hot selection.
    output logic [riscv_pkg::PcNextArms-1:0][XLEN-1:0] o_npc_val,
    // For the o_npc_seq arms: the riscv_pkg::fetch_verdict of the arm's value.
    output riscv_pkg::fetch_verdict_t [riscv_pkg::PcNextArms-1:0] o_npc_seq_verdict
);

  // ===========================================================================
  // Control Flow Tracker - Holdoff Signal Generation
  // ===========================================================================
  // The window in IF is stale for one or two cycles after a PC change;
  // control_flow_tracker generates the holdoffs that squash it.

  // Fetch-invalid cycles freeze the pending-prediction walk and the redirect
  // bubble bookkeeping exactly like a stall: nothing was delivered, so none
  // of the per-delivery state may advance.
  logic fetch_stall;
  assign fetch_stall = i_stall || !i_fetch_progress;

  control_flow_tracker #(
      .XLEN(XLEN)
  ) control_flow_tracker_inst (
      .i_clk,
      .i_reset,
      .i_stall,
      .i_fetch_progress,
      .i_flush,
      .i_fence_i_flush,
      // Control flow sources
      .i_trap_taken,
      .i_mret_taken,
      .i_branch_taken,
      .i_pd_redirect,
      .i_pd_redirect_target,
      .i_prediction_used,
      .i_slot2_prediction_used,
      .i_slot2_predicted_target,
      .i_branch_target,
      .i_trap_target,
      .i_predicted_target,
      // Outputs
      .o_control_flow_change,
      .o_control_flow_holdoff,
      .o_reset_holdoff,
      .o_any_holdoff,
      .o_any_holdoff_safe,
      .o_control_flow_to_halfword,
      .o_control_flow_to_halfword_r
  );

  // ===========================================================================
  // Slot-2 Redirect Bubble Register
  // ===========================================================================
  // A taken slot-2 prediction in cycle N+1 redirects fetch after the next
  // sequential window was already requested, so the window that arrives in
  // N+2 is wrong-path. o_slot2_redirect_q marks that cycle (holding through
  // stalls) so if_stage's sel_nop squashes the window, as pd_redirect_q does
  // for a PD redirect. Reset, flush, and every higher-priority redirect clear
  // it.
  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush || i_trap_taken || i_mret_taken || i_branch_taken ||
        i_pd_redirect || i_fence_i_flush) begin
      o_slot2_redirect_q <= 1'b0;
    end else if (!fetch_stall) begin
      o_slot2_redirect_q <= i_slot2_prediction_used;
    end
  end

  // ===========================================================================
  // PC Increment Calculator - Sequential PC Computation
  // ===========================================================================
  // Computes the next sequential PC values with parallel adders for timing.
  // See pc_increment_calculator.sv.

  logic [XLEN-1:0] seq_next_pc, seq_next_pc_plus_2, seq_next_pc_reg;
  logic seq_next_pc_reg_neq_pc;
  riscv_pkg::fetch_verdict_t seq_next_pc_verdict, seq_next_pc_plus_2_verdict;

  pc_increment_calculator #(
      .XLEN(XLEN)
  ) pc_increment_calculator_inst (
      // Current PC values
      .i_pc(o_pc),
      .i_pc_reg(o_pc_reg),

      // C-extension state signals
      .i_is_compressed,
      .i_sel_nop,
      .i_pc_fetch_advance_sel,
      .i_pc_reg_advance_sel,
      .i_pc_fetch_advance_sel_run,
      .i_pc_fetch_advance_sel_nop,
      .i_pc_reg_advance_sel_run,
      .i_pc_reg_advance_sel_nop,

      // Holdoff and control signals
      // The pending branch's immediate predecessor is the one packet allowed
      // through the registered post-prediction holdoff, and its release must
      // advance pc_reg on the same edge; otherwise a later fetch gap can set
      // carve_out_engaged_q and dispatch that predecessor twice. The raw-WCS=0
      // version of the release keeps the served-window compare off the
      // sequential-PC path; a raw mismatch still holds both PCs through the
      // higher-priority served-window arm.
      .i_any_holdoff_safe(o_any_holdoff_safe && !pending_predecessor_release_wcs0),
      .i_prediction_holdoff,
      .i_prediction_from_buffer_holdoff,
      .i_control_flow_to_halfword_r(o_control_flow_to_halfword_r),
      .i_stall_registered,

      // Mid-32bit correction
      .i_mid_32bit_correction(o_mid_32bit_correction),

      // Outputs
      .o_seq_next_pc(seq_next_pc),
      .o_seq_next_pc_plus_2(seq_next_pc_plus_2),
      .o_seq_next_pc_verdict(seq_next_pc_verdict),
      .o_seq_next_pc_plus_2_verdict(seq_next_pc_plus_2_verdict),
      .o_seq_next_pc_reg(seq_next_pc_reg),
      .o_seq_next_pc_reg_neq_pc(seq_next_pc_reg_neq_pc)
  );

  // ===========================================================================
  // Mid-32bit Correction Detection: disabled with 64-bit fetch
  // ===========================================================================
  // With 64-bit fetch, 32-bit instructions at PC[1]=1 are assembled
  // immediately from both words. There is no "landing in the middle" of a
  // 32-bit instruction, so the mid-32bit correction is never needed.
  assign o_mid_32bit_correction = 1'b0;

  // ===========================================================================
  // Final PC Selection - Priority Muxes
  // ===========================================================================
  // next_pc_reg is a priority mux over the values that load. Its holds for a
  // served-window resteer and for no fetch progress are moved onto
  // o_pc_reg's load enable, which keeps those late controls off the wide data
  // path. The fetch-PC mux applies its late terms, including both current
  // predictions, last (see next_pc below).

  // pc_reg lags o_pc by a cycle, so it takes a slot-1 prediction from the
  // registered prediction. For a taken prediction made in cycle N:
  //   - next_pc is the target in N (fetch from the target in N+1);
  //   - next_pc_reg stays sequential in N, while IF emits the packet before
  //     the branch;
  //   - next_pc_reg is the target in N+1, while IF emits the branch, from the
  //     registered prediction (i_sel_prediction_r).
  // This registered handoff must also work in the post-prediction holdoff
  // cycle; otherwise pc_reg keeps stepping sequentially after fetch has
  // redirected.
  //
  // A prediction pends instead, as a {branch PC, target} pair, when the
  // branch is in the upper half of a word, the target is a halfword address,
  // or pc_reg's next step would not land on the branch (prediction_needs_pending
  // has the exact conditions). A compressed branch in the upper half of a
  // word, for example, can let pc_reg step past the branch PC before the
  // registered pulse lines up. When pc_reg is about to cross from the lower
  // halfword to the pending branch PC, it lands on the branch PC first, so IF
  // emits the branch itself before pc_reg moves to the target.
  //
  // sel_prediction_r is suppressed while a prediction is pending, and:
  //   - in the cycle after a redirect killed the pending state
  //     (redirect_kill_pending_q), so a wrong-path BTB prediction made in the
  //     same cycle as a PD redirect cannot move pc_reg to its target;
  //   - during the slot-2 redirect bubble. When slot 1 (at the wrong-path
  //     next-window PC) and slot 2 both hit in one cycle, slot 1's registered
  //     handoff in N+2 would otherwise move pc_reg off the slot-2 target.
  logic sel_prediction_r;
  assign sel_prediction_r = !i_reset && i_sel_prediction_r &&
                            !pending_prediction_valid && !redirect_kill_pending_q &&
                            !o_slot2_redirect_q;

  logic            pending_prediction_valid;
  logic [XLEN-1:0] pending_prediction_pc;
  // Capture both possible slot-1 predecessors beside pending_prediction_pc so
  // the pc_reg control logic needs only parallel equality compares. The keep
  // attributes stop synthesis from rebuilding either tag as arithmetic on
  // pending_prediction_pc, which would put a carry chain back after the late
  // instruction-size decision.
  (* keep = "true" *)logic [XLEN-1:0] pending_prediction_prev_pc;
  (* keep = "true" *)logic [XLEN-1:0] pending_prediction_prev_native_pc;
  logic [XLEN-1:0] pending_prediction_target;
  logic            pending_prediction_effective;
  logic            pending_imm_pred_emit;
  logic            pending_predecessor_release_wcs0;
  logic            pim_base;  // pending, not ready, and pc_reg at the branch's predecessor
  logic            carve_out_engaged_q;  // raw WCS seen while pim_base held
  logic            pending_prediction_from_buffer;
  logic            prediction_needs_pending;
  logic            use_pending_prediction_for_pc_reg;
  logic            pending_prediction_crossing_pc_reg;
  logic            pending_prediction_target_handoff;
  logic            pending_prediction_target_handoff_applies;
  logic            pending_prediction_ready_without_effective;
  logic            pending_prediction_allow_cross;
  (* keep = "true", max_fanout = 16 *)logic            pending_prediction_allow_cross_pc_mux_q;
  logic            stale_pending_prediction;
  logic            hold_pending_prediction_fetch;
  logic            hold_pending_prediction_consume_fetch;
  logic            pending_prediction_cross_handoff_pc_mux;
  logic            pending_prediction_target_handoff_pc_mux;
  logic            use_pending_prediction_for_pc_reg_pc_mux;
  logic            hold_pending_prediction_fetch_pc_mux;
  (* max_fanout = 16 *)logic            pending_wcs_seq_override_pc_mux;
  logic            pending_prediction_target_holdoff_q;
  logic            pending_prediction_target_holdoff_prev_q;
  logic            pending_prediction_pc_ready_q;
  logic            redirect_kill_pending_q;
  logic [XLEN-2:0] pending_prediction_pc_hw;
  logic [XLEN-1:0] pending_prediction_target_next_word;
  logic [XLEN-2:0] pc_reg_hw;
  logic            pc_reg_before_pending;
  logic            pc_reg_at_pending;
  logic            pc_reg_after_pending;
  logic            seq_reaches_pending;
  logic            pc_reg_at_pending_predecessor;
  logic            pending_predecessor_needs_emit;
  logic [XLEN-2:0] seq_next_pc_reg_hw_q;
  logic            halfword_target_lead_catchup;
  logic            fetch_is_halfword_ahead;
  logic            lower_parcel_window_resteer_q;
  logic            same_word_lower_parcel_catchup;
  logic            clear_pending_prediction_state;

  assign pending_prediction_pc_hw = pending_prediction_pc[XLEN-1:1];
  assign pending_prediction_target_next_word =
      {pending_prediction_target[XLEN-1:2], 2'b00} + riscv_pkg::PcIncrement32bit;
  assign pc_reg_hw = o_pc_reg[XLEN-1:1];
  assign pc_reg_before_pending = pc_reg_hw < pending_prediction_pc_hw;
  assign pc_reg_at_pending = o_pc_reg == pending_prediction_pc;
  assign pc_reg_after_pending = pc_reg_hw > pending_prediction_pc_hw;
  assign seq_reaches_pending = seq_next_pc_reg_hw_q >= pending_prediction_pc_hw;
  assign pc_reg_at_pending_predecessor = o_pc_reg == pending_prediction_prev_pc;
  // A == B + 2 (mod 2^XLEN) exactly when A ^ B is 2'b10 in bits [1:0] and,
  // in each higher bit k, the carry into bit k, B[k-1] & !A[k-1]. Comparing
  // that pattern avoids an incrementer before the catch-up compare on the
  // fetch-PC feedback path (checked by fetch_pc_mux).
  logic [XLEN-1:0] fetch_arch_pc_xor;
  logic [XLEN-2:0] fetch_arch_pc_carry;
  assign fetch_arch_pc_xor = o_pc ^ o_pc_reg;
  assign fetch_arch_pc_carry = o_pc_reg[XLEN-2:0] & ~o_pc[XLEN-2:0];
  assign fetch_is_halfword_ahead = fetch_arch_pc_xor == {fetch_arch_pc_carry[XLEN-2:1], 2'b10};
  assign pending_predecessor_needs_emit =
      i_window_cannot_serve_raw || carve_out_engaged_q || i_prediction_holdoff;

  // seq_next_pc_reg is registered before the pending-prediction crossing
  // compare, which keeps the path from recovery through the flush, the
  // instruction size, and the pc_reg adders off that compare. The one-cycle-old
  // value is safe because stale_pending_prediction and redirect_kill_pending_q
  // cover a late crossing. A served-window resteer (i_window_cannot_serve)
  // holds pc_reg, so it holds this register too; otherwise the rejected
  // sequential value could make a pending branch in the upper half of a word
  // look crossed before its predecessor was emitted.
  always_ff @(posedge i_clk) begin
    if (i_flush || i_branch_taken || i_pd_redirect || i_trap_taken || i_mret_taken)
      seq_next_pc_reg_hw_q <= '0;
    else if (!fetch_stall && !i_window_cannot_serve)
      seq_next_pc_reg_hw_q <= seq_next_pc_reg[XLEN-1:1];
  end
  // A prediction at a word-aligned fetch PC with a word-aligned target pends
  // only when pc_reg's next step would not land on the branch. Pending every
  // such prediction would break ordinary taken calls: pc_reg would be forced
  // back through a needless pending handoff and could later mark
  // non-control-flow PCs as predicted taken.
  // No prediction pends when slot 2 redirects in the same cycle. The slot-2
  // arm wins next_pc and next_pc_reg then, the slot-1 hit (at the wrong-path
  // next-window PC) is moot, and a pending state from its halfword target
  // would conflict with the slot-2 redirect bubble in cycle N+2.
  //
  // The miss test is the full (seq_next_pc_reg != o_pc). pc_reg can be two or
  // more words behind the word-aligned fetch PC, where bit 1 alone would
  // report no miss and the prediction would be applied without the pc_reg
  // handoff, sending fetch to the wrong PC. (When the branch's own packet is
  // emitted this cycle, i_prediction_already_emitted keeps it from pending.)
  // For timing, pc_increment_calculator precomputes the compare for each
  // advance candidate from registered operands (o_seq_next_pc_reg_neq_pc,
  // equal to the full compare), so the late advance select drives a 1-bit mux
  // here instead of a wide compare on the pending-valid path.
  logic pc_reg_next_misses_fetch_pc_for_prediction;
  assign pc_reg_next_misses_fetch_pc_for_prediction = seq_next_pc_reg_neq_pc;

  assign prediction_needs_pending =
      i_prediction_used && !i_prediction_already_emitted &&
      !i_ras_predicted && !i_slot2_prediction_used &&
      (o_pc[1] || i_predicted_target[1] ||
       (pc_reg_next_misses_fetch_pc_for_prediction &&
        i_prediction_requires_pc_reg_handoff));
  // The gate omits i_flush, which keeps the flush from misprediction recovery
  // off this path. It is not needed: i_branch_taken covers a misprediction,
  // i_trap_taken and i_mret_taken cover traps and xRET, and the FENCE-class
  // pulse, already registered, is gated directly.
  assign pending_prediction_effective = pending_prediction_valid && !redirect_kill_pending_q &&
                                        !i_fence_i_flush && !i_branch_taken &&
                                        !i_trap_taken && !i_mret_taken;
  assign o_pending_prediction_active = pending_prediction_effective;
  assign o_pending_prediction_pc = pending_prediction_pc;

  // A compressed branch or return can be predicted in the upper half of a
  // fetch word. pc_reg may then advance from the lower half to the next word
  // and never equal the branch PC exactly. Treat crossing the pending
  // halfword as ready to apply, and clear a pending branch that is already
  // behind pc_reg so a stale redirect cannot hold fetch forever. Because the
  // before/at/after relations are mutually exclusive, the handoff logic need
  // not re-test conditions its selected relation already implies.
  assign pending_prediction_crossing_pc_reg =
      pending_prediction_effective &&
      pending_prediction_allow_cross &&
      pc_reg_before_pending &&
      seq_reaches_pending;
  // A word-aligned pending branch can reach pc_reg in the first cycle its
  // prediction is pending, before pending_prediction_pc_ready_q has seen fetch
  // return to its PC. i_prediction_holdoff marks that cycle, in which the
  // branch's target and predictor metadata still line up. A prediction made
  // from the instruction buffer is excluded: it has its own registered
  // stale-buffer holdoff, and its packet is not yet a real output. For any
  // other branch, the apply gate below either emits it and moves pc_reg to
  // the target on the same edge, or keeps the prediction pending through a
  // stall, a served-window resteer, or a higher-priority arm.
  assign pending_prediction_target_handoff =
      pending_prediction_effective && pc_reg_at_pending &&
      (pending_prediction_allow_cross || pending_prediction_pc_ready_q ||
       (i_prediction_holdoff && !i_prediction_from_buffer_holdoff));
  // A ready handoff is applied, and the pending state consumed, only when no
  // stall or higher-priority arm blocks it. A variable-latency provider can
  // return the target window in the same cycle pc_reg reaches the still-owed
  // branch; the served-window resteer then wins and sends fetch back to the
  // branch, and consuming the pending state on that edge would lose the
  // branch while next_pc_reg stays behind. The other non-redirect arms above
  // the pending-target arm defer the handoff for the same reason. With
  // PENDING_HANDOFF_EXCLUDES_SLOT2 the slot-2 check is left out: a ready
  // handoff asserts both prediction holdoff outputs, so if_stage disables the
  // staged and live slot-2 predictions, and leaving the check out keeps the
  // prediction and PMA logic from feeding back into the pending-state update.
  assign pending_prediction_target_handoff_applies =
      pending_prediction_target_handoff && !fetch_stall &&
      !i_window_cannot_serve &&
      (PENDING_HANDOFF_EXCLUDES_SLOT2 || !i_slot2_prediction_used_for_pc) &&
      !o_pending_prediction_target_holdoff;
  assign use_pending_prediction_for_pc_reg =
      pending_prediction_effective && pending_prediction_ready_without_effective;
  assign pending_prediction_ready_without_effective =
      ((pending_prediction_allow_cross && pc_reg_before_pending && seq_reaches_pending) ||
       (pc_reg_at_pending &&
        (pending_prediction_allow_cross || pending_prediction_pc_ready_q ||
         (i_prediction_holdoff && !i_prediction_from_buffer_holdoff))));
  assign stale_pending_prediction = pending_prediction_effective && pc_reg_after_pending;
  // A pending prediction must not skip the compressed instruction just before
  // the branch, at pc_reg (pending_prediction_pc == o_pc_reg + 2).
  // pending_imm_pred_emit releases the fetch holdoff and blocks the
  // land-on-branch step so that instruction emits first; the prediction stays
  // pending until pc_reg reaches the branch.
  //
  // Only registered PC state is used here. seq_next_pc_reg depends on
  // sel_nop, which this predicate controls, so using it would form a
  // combinational loop. A 32-bit predecessor is not released: the
  // instruction-size signals are unreliable when the served-window check
  // fails in the same cycle.
  //
  // The predecessor is released only when raw WCS shows it was squashed, or
  // in the first prediction-holdoff cycle, while the branch's prediction is
  // being armed. Releasing it in other cycles can advance a two-wide bundle
  // past the branch, and exempting it from the holdoff in general can expose
  // the branch itself before the target handoff consumes its metadata,
  // dispatching the branch twice.
  assign pim_base =
      pending_prediction_effective && !use_pending_prediction_for_pc_reg &&
      !pc_reg_after_pending && pc_reg_at_pending_predecessor;
  // The predecessor is dropped only when the served window cannot deliver it
  // (raw WCS = 1), but it can emit only in the next cycle, after the resteer,
  // when raw WCS is 0; gating the release on raw WCS alone would squash it
  // again then. So carve_out_engaged_q latches raw WCS once seen and holds it
  // until pim_base falls (pc_reg reaches the branch) or a redirect arrives. It
  // does not hold pc_reg, which still advances through the release, so it
  // cannot deadlock, and it never sets while raw WCS stays 0. Raw WCS does not
  // depend on sel_nop, so there is no combinational loop.
  assign pending_imm_pred_emit = pim_base && pending_predecessor_needs_emit;
  // pending_imm_pred_emit with raw WCS = 0: the only case in which the
  // released predecessor is a real packet, so it also lifts the registered
  // control-flow holdoff in pc_increment_calculator. Leaving raw WCS out keeps
  // the served-window compare off the sequential-PC path.
  assign pending_predecessor_release_wcs0 =
      pim_base && (carve_out_engaged_q || i_prediction_holdoff);
  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush || i_trap_taken || i_mret_taken || i_branch_taken ||
        i_pd_redirect || i_fence_i_flush || !pim_base) begin
      carve_out_engaged_q <= 1'b0;
    end else if (!fetch_stall && i_window_cannot_serve_raw) begin
      carve_out_engaged_q <= 1'b1;
    end
  end
  assign hold_pending_prediction_fetch =
      pending_prediction_effective && !use_pending_prediction_for_pc_reg &&
      !pc_reg_after_pending &&
      !(pc_reg_at_pending_predecessor && pending_predecessor_needs_emit);
  assign hold_pending_prediction_consume_fetch = use_pending_prediction_for_pc_reg;
  // A separate copy of the pending-handoff logic for the PC muxes, built on
  // pending_prediction_allow_cross_pc_mux_q, so synthesis can place it next to
  // the next_pc and next_pc_reg muxes instead of routing the shared version
  // back across the IF control logic. These nodes have no keep attribute on
  // purpose: flattening them is the timing goal.
  assign pending_prediction_cross_handoff_pc_mux =
      pending_prediction_effective &&
      pending_prediction_allow_cross_pc_mux_q &&
      pc_reg_before_pending &&
      seq_reaches_pending;
  // The same equation as pending_prediction_target_handoff, on the register
  // copy of allow_cross. Sharing one ready net with that logic would bring
  // back a widely routed select on the timing-critical PC mux path.
  assign pending_prediction_target_handoff_pc_mux =
      pending_prediction_effective && pc_reg_at_pending &&
      (pending_prediction_allow_cross_pc_mux_q || pending_prediction_pc_ready_q ||
       (i_prediction_holdoff && !i_prediction_from_buffer_holdoff));
  assign use_pending_prediction_for_pc_reg_pc_mux =
      pending_prediction_effective &&
      ((pending_prediction_allow_cross_pc_mux_q && pc_reg_before_pending &&
        seq_reaches_pending) ||
       (pc_reg_at_pending &&
        (pending_prediction_allow_cross_pc_mux_q || pending_prediction_pc_ready_q ||
         (i_prediction_holdoff && !i_prediction_from_buffer_holdoff))));
  // Raw WCS enters the pending-hold arm's value, not its request, which keeps
  // it off the one-hot priority logic. With H0 the hold without raw WCS, X the
  // predecessor term, and W raw WCS, the hold is H = H0 & !(W & X), and
  // H ? V : SEQ equals H0 ? ((W & X) ? SEQ : V) : SEQ.
  // The fanout cap lets Vivado replicate the override beside each PC-arm copy.
  assign pending_wcs_seq_override_pc_mux = i_window_cannot_serve_raw && pim_base;
  assign hold_pending_prediction_fetch_pc_mux =
      pending_prediction_effective &&
      !use_pending_prediction_for_pc_reg_pc_mux &&
      !pc_reg_after_pending &&
      !pending_predecessor_release_wcs0;
  // Readiness and the immediate-predecessor exception depend on the
  // effective pending state in several nested places. Factor that common
  // enable out completely: E && ((!U && A && !exception) || U) reduces to
  // E && (R || (A && !predecessor_exception)), where U = E && R, so a late
  // recovery or redirect kill enters only the final AND.
  (* keep = "true" *)logic pending_prediction_holdoff_without_effective;
  (* keep = "true" *)logic pending_prediction_holdoff_wcs0_without_effective;
  (* keep = "true" *)logic pending_prediction_holdoff_wcs_without_effective;
  // While a prediction is pending, prev_pc = pc - 2 (mod 2^XLEN), so pc_reg
  // is never at both the branch and its predecessor. At the predecessor,
  // !after also implies before, including wraparound: a wrapped predecessor
  // is after and is excluded. So crossing matters only when it cancels the
  // predecessor exception. Completing that exception before the address
  // compares keeps the separate before comparator out of these prediction
  // holdoffs. The fetch holdoffs below do not rely on this tag relation.
  (* keep = "true" *)logic pending_pred_block;
  (* keep = "true" *)logic pending_pred_block_wcs0;
  (* keep = "true" *)logic pending_pred_block_wcs;
  assign pending_pred_block = pending_predecessor_needs_emit &&
      !(pending_prediction_allow_cross && seq_reaches_pending);
  assign pending_pred_block_wcs0 = (carve_out_engaged_q || i_prediction_holdoff) &&
      !(pending_prediction_allow_cross && seq_reaches_pending);
  assign pending_pred_block_wcs = !(pending_prediction_allow_cross && seq_reaches_pending);
  assign pending_prediction_holdoff_without_effective =
      !pc_reg_after_pending && !(pc_reg_at_pending_predecessor && pending_pred_block);
  assign o_pending_prediction_holdoff =
      pending_prediction_effective && pending_prediction_holdoff_without_effective;
  // The raw-WCS = 0 and = 1 versions keep the same predecessor exception.
  assign pending_prediction_holdoff_wcs0_without_effective =
      !pc_reg_after_pending && !(pc_reg_at_pending_predecessor && pending_pred_block_wcs0);
  assign pending_prediction_holdoff_wcs_without_effective =
      !pc_reg_after_pending && !(pc_reg_at_pending_predecessor && pending_pred_block_wcs);
  assign o_pending_prediction_holdoff_wcs0 =
      pending_prediction_effective && pending_prediction_holdoff_wcs0_without_effective;
  assign o_pending_prediction_holdoff_wcs =
      pending_prediction_effective && pending_prediction_holdoff_wcs_without_effective;
`ifndef SYNTHESIS
  always_comb begin
    if (!$isunknown(
            {
              i_window_cannot_serve_raw,
              o_pending_prediction_holdoff,
              o_pending_prediction_holdoff_wcs0,
              o_pending_prediction_holdoff_wcs
            }
        )) begin
      p_pending_prediction_holdoff_cofactors_exact :
      assert (o_pending_prediction_holdoff ==
              (i_window_cannot_serve_raw ? o_pending_prediction_holdoff_wcs :
                                           o_pending_prediction_holdoff_wcs0));
    end
  end
`endif
  assign o_pending_prediction_target_handoff = pending_prediction_target_handoff_applies;
  // The fetch holdoff differs from the prediction holdoff only in which ready
  // handoffs squash the current packet. It is also completed without the late
  // pending_prediction_effective enable, so recovery does not pass through the
  // predecessor exception and then sel_nop and slot-2 validity. A ready branch
  // exactly at pc_reg is emitted, not squashed, and a crossing branch squashes
  // the packet regardless of the predecessor exception. With these mutually
  // exclusive address relations separated before the final holdoff LUT:
  // H = !after && !owner_ready && (!predecessor_exception || before && cross).
  // This holds for any tag values, including mismatched low bits; it does not
  // rely on the predecessor-tag relation.
  (* keep = "true" *)logic pending_fetch_owner_ready;
  (* keep = "true" *)logic pending_fetch_cross_permission;
  assign pending_fetch_owner_ready = pc_reg_at_pending &&
      (pending_prediction_allow_cross || pending_prediction_pc_ready_q ||
       (i_prediction_holdoff && !i_prediction_from_buffer_holdoff));
  assign pending_fetch_cross_permission = pending_prediction_allow_cross && seq_reaches_pending;
  (* keep = "true" *)logic pending_prediction_fetch_holdoff_without_effective;
  (* keep = "true" *)logic pending_prediction_fetch_holdoff_wcs0_without_effective;
  (* keep = "true" *)logic pending_prediction_fetch_holdoff_wcs_without_effective;
  assign pending_prediction_fetch_holdoff_without_effective =
      !pc_reg_after_pending && !pending_fetch_owner_ready &&
      (!(pc_reg_at_pending_predecessor && pending_predecessor_needs_emit) ||
       (pc_reg_before_pending && pending_fetch_cross_permission));
  assign o_pending_prediction_fetch_holdoff =
      pending_prediction_effective && pending_prediction_fetch_holdoff_without_effective;
  // The same with raw WCS = 0. The predecessor exception then depends only on
  // registered state (carve_out_engaged_q or the first prediction-holdoff
  // cycle). IF computes sel_nop as W | E(W) = W | E(0), so raw WCS does not
  // pass through this pending-prediction logic on the sel_nop path.
  assign pending_prediction_fetch_holdoff_wcs0_without_effective =
      !pc_reg_after_pending && !pending_fetch_owner_ready &&
      (!(pc_reg_at_pending_predecessor && (carve_out_engaged_q || i_prediction_holdoff)) ||
       (pc_reg_before_pending && pending_fetch_cross_permission));
  assign o_pending_prediction_fetch_holdoff_wcs0 =
      pending_prediction_effective && pending_prediction_fetch_holdoff_wcs0_without_effective;
  // The same with raw WCS = 1. pending_predecessor_needs_emit is then true,
  // so the predecessor exception removes the fetch hold regardless of
  // carve_out_engaged_q.
  assign pending_prediction_fetch_holdoff_wcs_without_effective =
      !pc_reg_after_pending && !pending_fetch_owner_ready &&
      (!pc_reg_at_pending_predecessor ||
       (pc_reg_before_pending && pending_fetch_cross_permission));
  assign o_pending_prediction_fetch_holdoff_wcs =
      pending_prediction_effective && pending_prediction_fetch_holdoff_wcs_without_effective;
  assign o_pending_prediction_target_holdoff = pending_prediction_target_holdoff_q;
  assign halfword_target_lead_catchup =
      pending_prediction_target_holdoff_prev_q &&
      !pending_prediction_target_holdoff_q &&
      !pending_prediction_effective &&
      !i_sel_nop &&
      i_is_compressed &&
      o_pc_reg[1] &&
      fetch_is_halfword_ahead;
  // A served-window resteer from a pc_reg in the upper half of a word moves
  // the fetch PC back one parcel, to the start of the word. IF ignores that
  // parcel's BTB entry, and once the real packet is emitted the catch-up arm
  // (sequential + 2) restores the usual fetch PC and pc_reg relationship in
  // one cycle.
  assign o_fetch_lookup_is_lower_parcel = lower_parcel_window_resteer_q && !o_pc[1] && o_pc_reg[1];
  assign same_word_lower_parcel_catchup =
      o_fetch_lookup_is_lower_parcel && !pending_prediction_effective && !i_sel_nop;

  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush || i_trap_taken || i_mret_taken || i_branch_taken ||
        i_pd_redirect || i_fence_i_flush) begin
      pending_prediction_target_holdoff_q <= 1'b0;
    end else if (!fetch_stall) begin
      // One target bubble follows a non-crossing pending handoff. With fetch
      // going no further than the word after the target, that gives the
      // target word time to arrive while keeping the usual one-word fetch
      // lead. A crossing handoff gets no bubble: when pc_reg lands on the
      // branch PC, IF must still emit the branch itself.
      pending_prediction_target_holdoff_q <=
          pending_prediction_target_handoff_applies && !pending_prediction_allow_cross;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush || i_trap_taken || i_mret_taken || i_branch_taken ||
        i_pd_redirect || i_fence_i_flush) begin
      pending_prediction_target_holdoff_prev_q <= 1'b0;
    end else if (!fetch_stall) begin
      pending_prediction_target_holdoff_prev_q <= pending_prediction_target_holdoff_q;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_reset) redirect_kill_pending_q <= 1'b0;
    else
      redirect_kill_pending_q <= i_flush || i_branch_taken || i_pd_redirect ||
                                     i_trap_taken || i_mret_taken || i_fence_i_flush;
  end

  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush || i_trap_taken || i_mret_taken || i_branch_taken ||
        i_pd_redirect || i_fence_i_flush) begin
      pending_prediction_pc_ready_q <= 1'b0;
    end else if (!fetch_stall) begin
      if (redirect_kill_pending_q || pending_prediction_target_handoff_applies ||
          stale_pending_prediction) begin
        pending_prediction_pc_ready_q <= 1'b0;
      end else if (pending_prediction_effective && !pending_prediction_allow_cross &&
                   (o_pc == pending_prediction_pc)) begin
        pending_prediction_pc_ready_q <= 1'b1;
      end
    end
  end

  // The target-handoff consume uses the same !fetch_stall enable as the
  // pc_reg register it hands off to (pending_prediction_target_handoff_applies
  // includes it). Consuming during a stall would drop the pending target
  // while pc_reg is frozen: pc_reg would then step sequentially past the
  // branch while fetch follows the target, and the aligner would pair
  // target-path bytes with sequential PCs. Decode would then build bogus
  // instructions from that pairing, and a non-branch could dispatch as a
  // taken branch, mispredict, and redirect to a garbage address. The crossing
  // case needs no gate: it consumes through stale_pending_prediction only
  // after pc_reg advances.
  assign clear_pending_prediction_state =
      redirect_kill_pending_q || pending_prediction_target_handoff_applies ||
      stale_pending_prediction;

  // Fires in the cycle of each event that kills the pending state, except the
  // target handoff, where the tracker itself attaches the metadata to the
  // branch being emitted. The redirect terms fire in the redirect cycle, one
  // cycle before redirect_kill_pending_q, because the tracker's pending-save
  // capture in that same cycle reads the prediction and fetch-holdoff values
  // from before the kill.
  assign o_pending_prediction_redirect_kill =
      i_flush || i_trap_taken || i_mret_taken || i_branch_taken ||
      i_pd_redirect || i_fence_i_flush || stale_pending_prediction;

`ifndef SYNTHESIS
  // A ready handoff is consumed exactly when no higher-priority non-redirect
  // arm keeps it from reaching next_pc_reg (redirects kill the pending state
  // separately). These checks catch a priority change that would consume a
  // handoff without applying it.
  always_comb begin
    if (PENDING_HANDOFF_EXCLUDES_SLOT2 && !$isunknown(
            {pending_prediction_target_handoff, i_slot2_prediction_used_for_pc}
        )) begin
      p_integrated_pending_handoff_excludes_slot2 :
      assert (!(pending_prediction_target_handoff && i_slot2_prediction_used_for_pc));
    end
    if (pending_prediction_target_handoff && !fetch_stall && !i_reset && !$isunknown(
            {i_window_cannot_serve, i_slot2_prediction_used_for_pc,
                     o_pending_prediction_target_holdoff}
        )) begin
      p_handoff_apply_matches_priority :
      assert (pending_prediction_target_handoff_applies ==
              (!i_window_cannot_serve && !i_slot2_prediction_used_for_pc &&
               !o_pending_prediction_target_holdoff));
    end
    if (pending_prediction_effective && pc_reg_at_pending && i_prediction_holdoff &&
        !i_prediction_from_buffer_holdoff &&
        !fetch_stall && !$isunknown(
            {i_window_cannot_serve, i_slot2_prediction_used_for_pc,
             o_pending_prediction_target_holdoff}
        )) begin
      p_first_cycle_exact_owner_handoffs_when_unblocked :
      assert (i_window_cannot_serve || i_slot2_prediction_used_for_pc ||
              o_pending_prediction_target_holdoff ||
              pending_prediction_target_handoff_applies);
    end
  end
`endif

  // The pending-valid next state is computed for both values of the late
  // miss compare (pc_reg_next_misses_fetch_pc_for_prediction), which then
  // selects one bit without passing through the prediction qualification and
  // the clear/set/hold priority. pc_pending_capture checks it against the
  // reference below.
  (* keep = "true" *) logic [1:0] pending_valid_by_miss;
  logic pending_valid_next;
  for (genvar miss = 0; miss < 2; miss++) begin : gen_pending_valid_by_miss
    wire capture = !fetch_stall && i_prediction_used &&
        !i_prediction_already_emitted && !i_ras_predicted && !i_slot2_prediction_used &&
        (o_pc[1] || i_predicted_target[1] ||
         ((miss != 0) && i_prediction_requires_pc_reg_handoff));
    assign pending_valid_by_miss[miss] =
        !(i_reset || i_flush || i_trap_taken || i_mret_taken || i_branch_taken ||
          i_pd_redirect || i_fence_i_flush || clear_pending_prediction_state) &&
        (pending_prediction_valid || capture);
  end
  assign pending_valid_next = pc_reg_next_misses_fetch_pc_for_prediction ?
      pending_valid_by_miss[1] : pending_valid_by_miss[0];
  always_ff @(posedge i_clk) begin
    pending_prediction_valid <= pending_valid_next;
  end

`ifdef PC_PENDING_CAPTURE_LOCAL_PROOF
  logic pending_valid_reference;
  always_comb begin
    pending_valid_reference = pending_prediction_valid;
    if (i_reset || i_flush || i_trap_taken || i_mret_taken || i_branch_taken ||
        i_pd_redirect || i_fence_i_flush || clear_pending_prediction_state) begin
      pending_valid_reference = 1'b0;
    end else if (!fetch_stall && prediction_needs_pending) begin
      pending_valid_reference = 1'b1;
    end
    assert (pending_valid_next == pending_valid_reference);
  end
`endif

  // These registers capture on every non-stalled cycle while no prediction is
  // pending, not only when prediction_needs_pending fires, which keeps the
  // path from the fetch window through sel_nop and the pc_reg compare off
  // their enable. That is safe because prediction_needs_pending can fire only
  // while pending_prediction_valid is 0 (fetch is held while a prediction is
  // pending, so no new BTB hit can occur), and the captured data is ready when
  // the valid bit sets. They have no reset or clear: their values matter only
  // while the valid bit is set.
  always_ff @(posedge i_clk) begin
    if (!fetch_stall && !pending_prediction_valid) begin
      pending_prediction_pc                   <= o_pc;
      pending_prediction_prev_pc              <= o_pc - riscv_pkg::PcIncrementCompressed;
      pending_prediction_prev_native_pc       <= o_pc - riscv_pkg::PcIncrement32bit;
      pending_prediction_target               <= i_predicted_target;
      pending_prediction_allow_cross          <= o_pc[1];
      pending_prediction_allow_cross_pc_mux_q <= o_pc[1];
      pending_prediction_from_buffer          <= i_prediction_used_from_buffer;
    end
  end

  logic [XLEN-1:0] next_pc, next_pc_reg;
  (* keep = "true" *) logic [XLEN-1:0] pc_reg_nonseq_without_slot2;
  logic trap_or_mret;
  assign trap_or_mret = i_trap_taken || i_mret_taken;

  // The pending terms for the fetch-PC data (pending_mux_*) ignore this
  // cycle's redirects. The higher-priority redirect arms still win, so their
  // late qualifiers need not pass through the pending logic first.
  logic pending_mux_valid;
  logic pending_mux_cross, pending_mux_target, pending_mux_use;
  logic pending_mux_predecessor, pending_mux_release, pending_mux_emit;
  logic pending_mux_hold, pending_mux_consume_is_seq;
  assign pending_mux_valid = pending_prediction_valid && !redirect_kill_pending_q;
  assign pending_mux_cross = pending_mux_valid && pending_prediction_allow_cross_pc_mux_q &&
      pc_reg_before_pending && seq_reaches_pending;
  assign pending_mux_target = pending_mux_valid && pc_reg_at_pending &&
      (pending_prediction_allow_cross_pc_mux_q || pending_prediction_pc_ready_q ||
       (i_prediction_holdoff && !i_prediction_from_buffer_holdoff));
  assign pending_mux_use = pending_mux_cross || pending_mux_target;
  // The predecessor exception uses pending_prediction_allow_cross itself, as
  // pim_base does, not its _pc_mux_q copy; the local mux proofs do not assume
  // the two copies are equal.
  assign pending_mux_predecessor = pending_mux_valid &&
      !pending_prediction_ready_without_effective && !pc_reg_after_pending &&
      pc_reg_at_pending_predecessor;
  assign pending_mux_release = pending_mux_predecessor &&
      (carve_out_engaged_q || i_prediction_holdoff);
  assign pending_mux_emit = pending_mux_predecessor && pending_predecessor_needs_emit;
  assign pending_mux_hold = pending_mux_valid && !pending_mux_use &&
      !pc_reg_after_pending && !pending_mux_release;
  assign pending_mux_consume_is_seq = pending_prediction_allow_cross_pc_mux_q &&
      pending_mux_target && !pending_prediction_from_buffer && pending_prediction_fetch_at_target;

  // ---------------------------------------------------------------------------
  // next_pc. npc_cond, npc_val, and npc_sel describe the arms in priority
  // order and the one-hot winner. The fetch-PC data mux does not reduce them
  // directly: it takes the late sequential data and the two prediction
  // requests out of the arm reduction and applies them last. Simulation
  // compares it with a reference priority chain (npc_ref), and the
  // fetch_pc_mux formal target with an equivalent chain (fetch_ref) and the
  // one-hot reduction.
  // ---------------------------------------------------------------------------
  localparam int unsigned NPcArms = riscv_pkg::PcNextArms;
  logic [NPcArms-1:0] npc_cond;  // raw arm conditions, priority order
  logic [NPcArms-1:0] npc_sel;  // one-hot winner
  logic [XLEN-1:0] npc_val[NPcArms];
  // Which arms are o_pc + d, each arm's early operand, and the fetch_verdict
  // of each sequential arm (see the o_npc_* port comments).
  logic [NPcArms-1:0] npc_seq;
  logic [NPcArms-1:0][XLEN-1:0] npc_cmp_val;
  riscv_pkg::fetch_verdict_t [NPcArms-1:0] npc_seq_verdict;
  // fetch_verdict of o_pc itself, for the arms that hold at it.
  riscv_pkg::fetch_verdict_t pc_verdict;
  assign pc_verdict = riscv_pkg::fetch_verdict(o_pc);

  // The pending consume arm's value, computed here so the arm value is a
  // single signal like every other arm's. npc_consume_is_seq names its
  // sequential case so if_stage can classify the arm (o_npc_seq).
  //
  // A pending branch in the upper half of a word normally hands off while
  // fetch already waits at the target, so fetch advances sequentially and
  // keeps its one-window lead. After a served-window resteer, fetch was sent
  // back to the branch's word instead; advancing sequentially from there
  // would fetch the branch again and repeat the same prediction forever. So
  // the sequential form is used only while fetch is still at the saved
  // target; otherwise the handoff moves fetch to the target too.
  logic pending_prediction_fetch_at_target;
  logic npc_consume_is_seq;
  logic [XLEN-1:0] npc_consume_val;
  assign pending_prediction_fetch_at_target = o_pc == pending_prediction_target;
  assign npc_consume_is_seq = pending_prediction_allow_cross_pc_mux_q &&
      pending_prediction_target_handoff_pc_mux && !pending_prediction_from_buffer &&
      pending_prediction_fetch_at_target;
  assign npc_consume_val = npc_consume_is_seq ? seq_next_pc : pending_prediction_target;

  always_comb begin
    npc_cond[0] = i_reset;
    npc_cond[1] = trap_or_mret;
    npc_cond[2] = i_fence_i_flush;
    npc_cond[3] = i_branch_taken;
    npc_cond[4] = i_pd_redirect;
    npc_cond[5] = i_window_cannot_serve;
    npc_cond[6] = !i_fetch_progress;
    npc_cond[7] = i_slot2_prediction_used_for_pc;
    npc_cond[8] = i_prediction_used_for_pc;
    npc_cond[9] = o_pending_prediction_target_holdoff;
    npc_cond[10] = use_pending_prediction_for_pc_reg_pc_mux;
    npc_cond[11] = halfword_target_lead_catchup || same_word_lower_parcel_catchup;
    npc_cond[12] = hold_pending_prediction_fetch_pc_mux;
    npc_cond[13] = 1'b1;  // default arm: sequential

    npc_val[0] = '0;
    npc_val[1] = i_trap_target;
    npc_val[2] = i_fence_i_target;
    npc_val[3] = i_branch_target;
    npc_val[4] = i_pd_redirect_target;
    npc_val[5] = {o_pc_reg[XLEN-1:2], 2'b00};
    npc_val[6] = o_pc;
    npc_val[7] = i_slot2_predicted_target;
    npc_val[8] = i_predicted_target;
    npc_val[9] = pending_prediction_fetch_at_target ? pending_prediction_target_next_word : o_pc;
    npc_val[10] = npc_consume_val;
    npc_val[11] = seq_next_pc_plus_2;
    npc_val[12] = pending_wcs_seq_override_pc_mux ? seq_next_pc :
        (pending_prediction_allow_cross_pc_mux_q ? pending_prediction_target :
         pending_prediction_pc);
    npc_val[13] = seq_next_pc;

    // Arms whose value is o_pc + d with 0 <= d < 16: the no-progress hold
    // (d = 0), the target-holdoff arm when it holds at o_pc, the consume
    // arm's sequential case, the pending-hold arm's raw-WCS override, and the
    // catch-up and sequential arms (seq_next_pc and seq_next_pc_plus_2 are
    // o_pc + 2 to o_pc + 10; the mid-32-bit correction, which is not relative
    // to o_pc, is tied off). Every other arm is represented by its early
    // operand: a redirect target, pc_reg's word, or a registered pending
    // address. Arms 9, 10, and 12 are sequential only in the cases listed,
    // and their npc_cmp_val entry is always the pending operand.
    npc_seq = '0;
    npc_seq[6] = 1'b1;
    npc_seq[9] = !pending_prediction_fetch_at_target;
    npc_seq[10] = npc_consume_is_seq;
    npc_seq[11] = 1'b1;
    npc_seq[12] = pending_wcs_seq_override_pc_mux;
    npc_seq[13] = 1'b1;
    for (int unsigned k = 0; k < NPcArms; k++) npc_cmp_val[k] = npc_val[k];
    npc_cmp_val[9] = pending_prediction_target_next_word;
    npc_cmp_val[10] = pending_prediction_target;
    // Arm 12's compare operand is don't-care during its sequential override.
    // Keep raw WCS out of this wide observation output and show the pending
    // operand of the non-sequential case.
    npc_cmp_val[12] = pending_prediction_allow_cross_pc_mux_q ? pending_prediction_target :
        pending_prediction_pc;
    // fetch_verdict of each sequential arm (don't-care elsewhere).
    npc_seq_verdict = '0;
    npc_seq_verdict[6] = pc_verdict;
    npc_seq_verdict[9] = pc_verdict;
    npc_seq_verdict[10] = seq_next_pc_verdict;
    npc_seq_verdict[11] = seq_next_pc_plus_2_verdict;
    npc_seq_verdict[12] = seq_next_pc_verdict;
    npc_seq_verdict[13] = seq_next_pc_verdict;
  end
  assign o_npc_cond = npc_cond;
  assign o_npc_sel = npc_sel;
  assign o_npc_seq = npc_seq;
  assign o_npc_cmp_val = npc_cmp_val;
  always_comb begin
    for (int unsigned k = 0; k < NPcArms; k++) o_npc_val[k] = npc_val[k];
  end
  assign o_npc_seq_verdict = npc_seq_verdict;

  // One-hot: arm k wins when it asks and no higher-priority arm does. The
  // kill term is a plain OR reduce of the strictly-higher-priority bits, so
  // the tool is free to balance it instead of chaining.
  always_comb begin
    for (int unsigned k = 0; k < NPcArms; k++) begin
      npc_sel[k] = npc_cond[k] && !(|(npc_cond & ((1 << k) - 1)));
    end
  end

  // Set by a served-window resteer from a pc_reg in the upper half of a word,
  // which leaves o_pc one parcel behind pc_reg. It holds through fetch gaps,
  // stalls, and NOP cycles, and clears on a redirect or on the first real
  // packet, which takes the catch-up arm unless a higher-priority arm wins.
  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush || i_trap_taken || i_mret_taken || i_branch_taken ||
        i_pd_redirect || i_fence_i_flush) begin
      lower_parcel_window_resteer_q <= 1'b0;
    end else if (!fetch_stall) begin
      if (npc_sel[5] && o_pc_reg[1]) lower_parcel_window_resteer_q <= 1'b1;
      else if (!i_sel_nop) lower_parcel_window_resteer_q <= 1'b0;
    end
  end

  // Fetch-PC data for the non-sequential arms, computed with reset, the
  // served-window resteer, the no-progress hold, the catch-up arm, and both
  // current predictions removed. The purely sequential arms contribute zero
  // here, and the consume and pending-hold arms always give their
  // non-sequential value; their sequential cases select
  // next_pc_sequential_target below instead, so no consume or raw-WCS term
  // needs a wide mux here.
  // The winners among these arms, with the catch-up request, also decide when
  // the sequential value is used: npc_base_sequential_request, which includes
  // the consume arm's sequential case, and npc_raw_wcs_sequential_permission
  // for the pending-hold arm's raw-WCS override. The final muxes below then
  // apply the resteer, the no-progress hold, and both predictions, each only
  // when no redirect is present, and reset. npc_sel and the observation
  // outputs are unaffected.
  logic [NPcArms-1:0] npc_cond_without_prediction;
  logic [NPcArms-1:0] npc_sel_without_prediction;
  logic [XLEN-1:0] npc_val_without_sequential[NPcArms];
  (* keep = "true" *) logic [XLEN-1:0] next_pc_without_prediction_or_sequential;
  (* keep = "true" *) logic [XLEN-1:0] next_pc_sequential_target;
  always_comb begin
    npc_cond_without_prediction = npc_cond;
    npc_cond_without_prediction[0] = 1'b0;
    npc_cond_without_prediction[5] = 1'b0;
    npc_cond_without_prediction[6] = 1'b0;
    npc_cond_without_prediction[7] = 1'b0;
    npc_cond_without_prediction[8] = 1'b0;
    npc_cond_without_prediction[10] = pending_mux_use;
    npc_cond_without_prediction[11] = 1'b0;
    npc_cond_without_prediction[12] = pending_mux_hold;
    for (int unsigned k = 0; k < NPcArms; k++) npc_val_without_sequential[k] = npc_val[k];
    npc_val_without_sequential[10] = pending_prediction_target;
    npc_val_without_sequential[11] = '0;
    npc_val_without_sequential[12] = pending_prediction_allow_cross_pc_mux_q ?
        pending_prediction_target : pending_prediction_pc;
    npc_val_without_sequential[13] = '0;
    next_pc_without_prediction_or_sequential = '0;
    for (int unsigned k = 0; k < NPcArms; k++) begin
      npc_sel_without_prediction[k] = npc_cond_without_prediction[k] &&
          !(|(npc_cond_without_prediction & ((1 << k) - 1)));
      next_pc_without_prediction_or_sequential |=
          {XLEN{npc_sel_without_prediction[k]}} & npc_val_without_sequential[k];
    end
  end
  // The catch-up arm ranks below every earlier arm, including slot 1 and the
  // pending consume. Its permission is computed without the late NOP,
  // served-window, and slot-1 terms, which are applied after it. Slot 2 wins
  // at the final mux anyway, so it is left out too. Reset is applied only at
  // the final mux.
  (* keep = "true" *)logic npc_catchup_permission_without_nop_or_wcs;
  (* keep = "true" *)logic npc_catchup_request_without_slot1;
  assign npc_catchup_permission_without_nop_or_wcs =
      !(|npc_cond[4:1]) && !(|npc_cond[10:9]) &&
      !pending_prediction_effective &&
      (o_fetch_lookup_is_lower_parcel ||
       (pending_prediction_target_holdoff_prev_q &&
        !pending_prediction_target_holdoff_q && i_is_compressed && o_pc_reg[1] &&
        fetch_is_halfword_ahead));
  assign npc_catchup_request_without_slot1 =
      npc_catchup_permission_without_nop_or_wcs && !i_sel_nop;
  // The raw-WCS term stays separate from the rest of the sequential request.
  // The final muxes apply slot-1 priority, fetch progress, and the qualified
  // resteer. When catch-up and an ordinary sequential request both fire,
  // catch-up picks the sequential value; slot 2 still wins at the final mux.
  (* keep = "true" *)logic npc_base_sequential_request;
  (* keep = "true" *)logic npc_raw_wcs_sequential_permission;
  assign npc_base_sequential_request =
      (npc_sel_without_prediction[10] && pending_mux_consume_is_seq) ||
      npc_sel_without_prediction[13] || npc_catchup_request_without_slot1;
  assign npc_raw_wcs_sequential_permission =
      npc_sel_without_prediction[12] && pending_mux_predecessor;
  assign next_pc_sequential_target =
      npc_catchup_request_without_slot1 ? seq_next_pc_plus_2 : seq_next_pc;
  // Per bit: the redirect, resteer, and progress-hold data first, then slot 1
  // in a one-bit mux, then a final mux that takes reset, slot 2, the
  // sequential value, or that result. The sequential value enters only the
  // final mux, which keeps a wide stage off the bundle-size path. Slot 2 has
  // priority over the sequential request, and slot 1 blocks only the
  // sequential one.
  // With FROST_XILINX_PRIMS the three stages are explicit LUTs with the same
  // function as the portable muxes in the `else` branch.
  (* keep = "true" *) logic [XLEN-1:0] npc_final_nonseq_data;
  (* keep = "true" *) logic [XLEN-1:0] npc_slot1_or_nonseq_data;
  // Declare the shared control before the primitive generate below. Otherwise
  // Vivado creates undriven per-iteration implicit nets for its LUT input.
  (* keep = "true" *) logic pc_reg_live_redirect_permission;
  (* keep = "true" *) logic npc_prediction_permission;
  (* keep = "true" *) logic npc_final_slot2_request;
  (* keep = "true" *) logic npc_final_sequential_request;
  assign npc_prediction_permission = pc_reg_live_redirect_permission &&
      i_fetch_progress && !i_window_cannot_serve;
  assign npc_final_slot2_request = npc_prediction_permission && npc_cond[7];
  assign npc_final_sequential_request = npc_prediction_permission && !npc_cond[8] &&
      (npc_base_sequential_request ||
       (npc_raw_wcs_sequential_permission && i_window_cannot_serve_raw));
`ifdef FROST_XILINX_PRIMS
  for (genvar bit_idx = 0; bit_idx < XLEN; bit_idx++) begin : gen_fetch_pc_bit_mux
    (* dont_touch = "true" *)
    LUT6 #(
        .INIT(64'hffb05f10efa04f00)
    ) u_nonseq (
        .I0(i_window_cannot_serve),
        .I1(i_fetch_progress),
        .I2(pc_reg_live_redirect_permission),
        .I3(next_pc_without_prediction_or_sequential[bit_idx]),
        .I4(bit_idx < 2 ? 1'b0 : o_pc_reg[bit_idx]),
        .I5(o_pc[bit_idx]),
        .O (npc_final_nonseq_data[bit_idx])
    );
    (* dont_touch = "true" *)
    LUT4 #(
        .INIT(16'hf780)
    ) u_slot1 (
        .I0(npc_prediction_permission),
        .I1(npc_cond[8]),
        .I2(npc_val[8][bit_idx]),
        .I3(npc_final_nonseq_data[bit_idx]),
        .O (npc_slot1_or_nonseq_data[bit_idx])
    );
    (* dont_touch = "true" *)
    LUT6 #(
        .INIT(64'h5511450154104400)
    ) u_mux (
        .I0(i_reset),
        .I1(npc_final_slot2_request),
        .I2(npc_final_sequential_request),
        .I3(npc_val[7][bit_idx]),
        .I4(next_pc_sequential_target[bit_idx]),
        .I5(npc_slot1_or_nonseq_data[bit_idx]),
        .O (next_pc[bit_idx])
    );
  end
`else
  assign npc_final_nonseq_data = !pc_reg_live_redirect_permission ?
      next_pc_without_prediction_or_sequential : i_window_cannot_serve ?
      {o_pc_reg[XLEN-1:2], 2'b00} : !i_fetch_progress ? o_pc :
      next_pc_without_prediction_or_sequential;
  assign npc_slot1_or_nonseq_data = npc_prediction_permission && npc_cond[8] ?
      npc_val[8] : npc_final_nonseq_data;
  assign next_pc = i_reset ? '0 : npc_final_slot2_request ? npc_val[7] :
      npc_final_sequential_request ? next_pc_sequential_target : npc_slot1_or_nonseq_data;
`endif

  // The pc_reg priority mux without reset, the slot-2 arms, and the
  // sequential arm, which the muxes below add. Slot-1 BTB and RAS predictions
  // both reach pc_reg through the registered handoff (sel_prediction_r; see
  // the timeline above it), which keeps the current fetch response off the
  // pc_reg data path.
  always_comb begin
    if (trap_or_mret) pc_reg_nonseq_without_slot2 = i_trap_target;
    else if (i_fence_i_flush) pc_reg_nonseq_without_slot2 = i_fence_i_target;
    else if (i_branch_taken) pc_reg_nonseq_without_slot2 = i_branch_target;
    else if (i_pd_redirect) pc_reg_nonseq_without_slot2 = i_pd_redirect_target;
    // After a non-crossing pending handoff, the first target cycle is a bubble
    // while the target word arrives. pc_reg holds on the target then;
    // advancing would pair the arriving target word with the next halfword PC
    // and break compressed-instruction alignment on loop back-edges.
    else if (o_pending_prediction_target_holdoff) pc_reg_nonseq_without_slot2 = o_pc_reg;
    // Land on the pending branch PC, except when the predecessor is released
    // (pending_imm_pred_emit): pc_reg then advances sequentially, to
    // seq_next_pc_reg, which equals pending_prediction_pc here, so the
    // predecessor emits first. The prediction stays pending, so the target
    // handoff below still fires when pc_reg reaches the branch.
    else if (pending_prediction_effective && !pending_prediction_allow_cross_pc_mux_q &&
             !use_pending_prediction_for_pc_reg_pc_mux && !pending_imm_pred_emit)
      pc_reg_nonseq_without_slot2 = pending_prediction_pc;
    else if (pending_prediction_cross_handoff_pc_mux)
      pc_reg_nonseq_without_slot2 = pending_prediction_pc;
    else if (pending_prediction_target_handoff_pc_mux)
      pc_reg_nonseq_without_slot2 = pending_prediction_target;
    else if (sel_prediction_r) pc_reg_nonseq_without_slot2 = i_predicted_target_r;
    // This value is unused when the final sequential arm wins.
    else
      pc_reg_nonseq_without_slot2 = o_pc_reg;
  end

  // Finish the staged/sequential/base value before the live slot-2 choice.
  // The first LUT selects staged > sequential > base; the final LUT applies
  // reset > redirect > aliased live slot 2 > that value. Slot-2 validity
  // never gates the sequential select ahead of the data mux. The redirect
  // check is needed only in the final LUT: when a redirect is present,
  // pc_reg_nonseq_without_slot2 already holds its target.
  (* keep = "true" *) logic pc_reg_live_candidate;
  (* keep = "true" *) logic pc_reg_seq_candidate;
  (* keep = "true" *) logic [XLEN-1:0] pc_reg_staged_or_sequential;
  assign pc_reg_live_redirect_permission =
      !trap_or_mret && !i_fence_i_flush && !i_branch_taken && !i_pd_redirect;
  assign pc_reg_live_candidate = i_slot1_aliases_slot2_candidate &&
      i_slot2_live_target_used_for_pc_cofactor;
  assign pc_reg_seq_candidate =
      !o_pending_prediction_target_holdoff &&
      !(pending_prediction_effective && !pending_prediction_allow_cross_pc_mux_q &&
        !use_pending_prediction_for_pc_reg_pc_mux && !pending_imm_pred_emit) &&
      !pending_prediction_cross_handoff_pc_mux && !pending_prediction_target_handoff_pc_mux &&
      !sel_prediction_r;
`ifdef FROST_XILINX_PRIMS
  for (genvar bit_idx = 0; bit_idx < XLEN; bit_idx++) begin : gen_arch_pc_bit_mux
    LUT5 #(
        .INIT(32'hf5b1e4a0)
    ) u_staged_seq (
        .I0(i_slot2_staged_prediction_used_for_pc),
        .I1(pc_reg_seq_candidate),
        .I2(i_slot2_staged_predicted_target[bit_idx]),
        .I3(seq_next_pc_reg[bit_idx]),
        .I4(pc_reg_nonseq_without_slot2[bit_idx]),
        .O (pc_reg_staged_or_sequential[bit_idx])
    );
    LUT6 #(
        .INIT(64'h5515511144044000)
    ) u_final (
        .I0(i_reset),
        .I1(pc_reg_live_redirect_permission),
        .I2(pc_reg_live_candidate),
        .I3(i_slot2_live_predicted_target[bit_idx]),
        .I4(pc_reg_staged_or_sequential[bit_idx]),
        .I5(pc_reg_nonseq_without_slot2[bit_idx]),
        .O (next_pc_reg[bit_idx])
    );
  end
`else
  assign pc_reg_staged_or_sequential = i_slot2_staged_prediction_used_for_pc ?
      i_slot2_staged_predicted_target :
      pc_reg_seq_candidate ? seq_next_pc_reg : pc_reg_nonseq_without_slot2;
  assign next_pc_reg = i_reset ? '0 : !pc_reg_live_redirect_permission ?
      pc_reg_nonseq_without_slot2 : pc_reg_live_candidate ?
      i_slot2_live_predicted_target : pc_reg_staged_or_sequential;
`endif

  // PC registers
  logic pc_update_en;
  logic pc_reg_redirect;
  logic pc_reg_load_en;
  assign pc_update_en = i_reset || trap_or_mret || i_fence_i_flush || !i_stall;
  // Reset and the redirect arms above the fetch holds must still land even if
  // the served window is unusable or no fetch response arrived. Branch and PD
  // redirects retain the outer pc_update_en stall qualification;
  // reset, trap/xRET, and FENCE-class redirects retain their stall override.
  assign pc_reg_redirect =
      i_reset || trap_or_mret || i_fence_i_flush || i_branch_taken || i_pd_redirect;
  assign pc_reg_load_en =
      pc_update_en &&
      (pc_reg_redirect || (!i_window_cannot_serve && i_fetch_progress));

  // A separate register, not an alias: it has the same enable and data as
  // o_pc_reg[1], so it always equals that bit. The attributes stop synthesis
  // from merging the two, so the served-window check keeps its own low-fanout
  // source after opt_design.
  (* keep = "true", equivalent_register_removal = "no", max_fanout = 16 *)
  logic pc_reg_high_for_coverage_q;
  assign o_pc_reg_high_for_coverage = pc_reg_high_for_coverage_q;

  // Observation outputs and the fetch-PC load enable (see the port comments).
  assign o_next_pc = next_pc;
  assign o_next_pc_holds = !i_reset && !trap_or_mret && !i_fence_i_flush && !i_branch_taken &&
      !i_pd_redirect && !i_window_cannot_serve && !i_fetch_progress;
  assign o_pc_update_en = pc_update_en;
  assign o_pending_prediction_prev_pc = pending_prediction_prev_pc;
  assign o_pending_prediction_prev_native_pc = pending_prediction_prev_native_pc;

  // The PC registers hold the full XLEN-bit value, unmasked. An out-of-map PC
  // is compared with the 32-bit fetch addresses through if_stage's truncated
  // copy (pc_reg_serve_view), gets a fault-tagged packet, and raises a precise
  // instruction access fault through the FETCH_FAULT pseudo-op, so it never
  // silently aliases an in-map address.
  always_ff @(posedge i_clk) begin
    if (pc_update_en) o_pc <= next_pc;
    if (pc_reg_load_en) begin
      o_pc_reg                   <= next_pc_reg;
      pc_reg_high_for_coverage_q <= next_pc_reg[1];
    end
  end

`ifndef SYNTHESIS
  // Reference for next_pc_reg: the full priority chain, including the
  // served-window and no-progress holds that the load enable implements. The
  // checks compare the effective next state (the load data is don't-care
  // while the enable is low) across redirects, stalls, invalid windows, fetch
  // gaps, predictions, and sequential advance.
  logic [XLEN-1:0] next_pc_reg_priority_ref;
  always_comb begin
    if (i_reset) next_pc_reg_priority_ref = '0;
    else if (trap_or_mret) next_pc_reg_priority_ref = i_trap_target;
    else if (i_fence_i_flush) next_pc_reg_priority_ref = i_fence_i_target;
    else if (i_branch_taken) next_pc_reg_priority_ref = i_branch_target;
    else if (i_pd_redirect) next_pc_reg_priority_ref = i_pd_redirect_target;
    else if (i_window_cannot_serve) next_pc_reg_priority_ref = o_pc_reg;
    else if (!i_fetch_progress) next_pc_reg_priority_ref = o_pc_reg;
    else if (i_slot2_prediction_used_for_pc) next_pc_reg_priority_ref = i_slot2_predicted_target;
    else if (o_pending_prediction_target_holdoff) next_pc_reg_priority_ref = o_pc_reg;
    else if (pending_prediction_effective && !pending_prediction_allow_cross_pc_mux_q &&
             !use_pending_prediction_for_pc_reg_pc_mux && !pending_imm_pred_emit)
      next_pc_reg_priority_ref = pending_prediction_pc;
    else if (pending_prediction_cross_handoff_pc_mux)
      next_pc_reg_priority_ref = pending_prediction_pc;
    else if (pending_prediction_target_handoff_pc_mux)
      next_pc_reg_priority_ref = pending_prediction_target;
    else if (sel_prediction_r) next_pc_reg_priority_ref = i_predicted_target_r;
    else next_pc_reg_priority_ref = seq_next_pc_reg;
  end

  always_comb begin
    if (!$isunknown(
            {pc_update_en, pc_reg_load_en, o_pc_reg, next_pc_reg, next_pc_reg_priority_ref}
        )) begin
      p_pc_reg_clock_enable_factoring_exact :
      assert ((pc_reg_load_en ? next_pc_reg : o_pc_reg) ==
              (pc_update_en ? next_pc_reg_priority_ref : o_pc_reg));
      p_pc_reg_live_slot2_split_exact :
      assert (!pc_reg_load_en || (next_pc_reg == next_pc_reg_priority_ref));
    end
  end

  always_comb begin
    if (!$isunknown({o_pc_reg[1], o_pc_reg_high_for_coverage})) begin
      p_pc_reg_high_coverage_replica_exact : assert (o_pc_reg_high_for_coverage == o_pc_reg[1]);
    end
  end

  // lower_parcel_window_resteer_q stands in for a full-width same-word
  // compare. Check that it means exactly that, and that the catch-up arm
  // brings next_pc back to next_pc_reg.
  always_comb begin
    if (!$isunknown({lower_parcel_window_resteer_q, o_pc, o_pc_reg})) begin
      p_lower_parcel_resteer_state_remains_public :
      assert (!lower_parcel_window_resteer_q || o_fetch_lookup_is_lower_parcel);
      p_lower_parcel_resteer_state_is_exact_predecessor :
      assert (!lower_parcel_window_resteer_q ||
              o_pc + riscv_pkg::PcIncrementCompressed == o_pc_reg);
      p_lower_parcel_lookup_is_exact_same_word_predecessor :
      assert (!o_fetch_lookup_is_lower_parcel ||
              (!o_pc[1] && o_pc_reg[1] &&
               o_pc[XLEN-1:2] == o_pc_reg[XLEN-1:2]));
    end
    if (npc_sel[11] && same_word_lower_parcel_catchup && !$isunknown(
            {next_pc, next_pc_reg, sel_prediction_r}
        )) begin
      p_lower_parcel_catchup_has_no_stale_registered_handoff : assert (!sel_prediction_r);
      p_lower_parcel_catchup_rejoins_pc_reg : assert (next_pc == next_pc_reg);
    end
  end

  // The predecessor tags are don't-care while no prediction is pending. While
  // one is, they equal pending_prediction_pc - 2 and - 4 (mod 2^XLEN) through
  // holds, stalls, and redirect kill cycles, and comparing pc_reg with a tag
  // equals comparing pc_reg + 2 or + 4 with the branch PC.
  always_ff @(posedge i_clk) begin
    if (!i_reset && pending_prediction_valid) begin
      p_pending_prediction_prev_pc_matches_capture :
      assert (pending_prediction_prev_pc ==
              (pending_prediction_pc - riscv_pkg::PcIncrementCompressed));

      p_pending_prediction_prev_pc_predicate_equivalent :
      assert ((o_pc_reg == pending_prediction_prev_pc) ==
              (pending_prediction_pc ==
               (o_pc_reg + riscv_pkg::PcIncrementCompressed)));

      p_pending_prediction_prev_native_pc_matches_capture :
      assert (pending_prediction_prev_native_pc ==
              (pending_prediction_pc - riscv_pkg::PcIncrement32bit));

      p_pending_prediction_prev_native_pc_predicate_equivalent :
      assert ((o_pc_reg == pending_prediction_prev_native_pc) ==
              (pending_prediction_pc ==
               (o_pc_reg + riscv_pkg::PcIncrement32bit)));
    end
  end

  // Check the precomputed miss test against the full compare in the cycles
  // where prediction_needs_pending relies on it: a slot-1 BTB prediction that
  // needs the pc_reg handoff, at a word-aligned fetch PC with a word-aligned
  // target, with no slot-2 prediction, pc_reg not at the fetch PC, and no
  // reset, stall, holdoff, or NOP.
  always_ff @(posedge i_clk) begin
    if (!i_reset && !fetch_stall && !o_any_holdoff_safe && !i_sel_nop &&
        i_prediction_used && !i_ras_predicted &&
        !i_slot2_prediction_used && !o_pc[1] && !i_predicted_target[1] &&
        (o_pc_reg != o_pc) &&
        i_prediction_requires_pc_reg_handoff) begin
      p_pending_prediction_fast_miss_matches_full :
      assert (pc_reg_next_misses_fetch_pc_for_prediction == (seq_next_pc_reg != o_pc));
    end
  end
`endif

`ifndef SYNTHESIS
  // Reference pending-handoff equations in serial form. The synthesized
  // equations above rely on the before/at/after PC relations being mutually
  // exclusive; these checks compare them with the reference for every fully
  // known input.
  logic pending_crossing_ref;
  logic pending_cross_handoff_ref;
  logic pending_target_handoff_ref;
  logic pending_use_ref;
  logic pending_stale_ref;
  logic pending_pim_base_ref;
  logic pending_emit_ref;
  logic pending_hold_fetch_ref;
  logic pending_hold_consume_ref;
  logic pending_crossing_pc_mux_ref;
  logic pending_cross_handoff_pc_mux_ref;
  logic pending_target_handoff_pc_mux_ref;
  logic pending_use_pc_mux_ref;
  logic pending_stale_pc_mux_ref;
  logic pending_hold_fetch_pc_mux_ref;
  logic pending_hold_consume_pc_mux_ref;
  logic npc_consume_is_seq_ref;

  always_comb begin
    pending_crossing_ref = pending_prediction_effective && pending_prediction_allow_cross &&
                           pc_reg_before_pending && seq_reaches_pending;
    pending_cross_handoff_ref = pending_prediction_effective &&
                                pending_prediction_allow_cross && pending_crossing_ref;
    pending_target_handoff_ref = pending_prediction_effective &&
        (pending_prediction_allow_cross ?
             (pc_reg_at_pending && !pending_crossing_ref) :
             (pc_reg_at_pending &&
              (pending_prediction_pc_ready_q ||
               (i_prediction_holdoff && !i_prediction_from_buffer_holdoff))));
    pending_use_ref = pending_cross_handoff_ref || pending_target_handoff_ref;
    pending_stale_ref = pending_prediction_effective && !pending_use_ref && pc_reg_after_pending;
    pending_pim_base_ref = pending_prediction_effective && !pending_use_ref &&
                           !pending_stale_ref && pc_reg_at_pending_predecessor;
    pending_emit_ref = pending_pim_base_ref && pending_predecessor_needs_emit;
    pending_hold_fetch_ref = pending_prediction_effective && !pending_use_ref &&
                             !pending_stale_ref && !pending_emit_ref;
    pending_hold_consume_ref = pending_prediction_effective && pending_use_ref;

    pending_crossing_pc_mux_ref = pending_prediction_effective &&
                                  pending_prediction_allow_cross_pc_mux_q &&
                                  pc_reg_before_pending && seq_reaches_pending;
    pending_cross_handoff_pc_mux_ref = pending_prediction_effective &&
        pending_prediction_allow_cross_pc_mux_q && pending_crossing_pc_mux_ref;
    pending_target_handoff_pc_mux_ref = pending_prediction_effective &&
        (pending_prediction_allow_cross_pc_mux_q ?
             (pc_reg_at_pending && !pending_crossing_pc_mux_ref) :
             (pc_reg_at_pending &&
              (pending_prediction_pc_ready_q ||
               (i_prediction_holdoff && !i_prediction_from_buffer_holdoff))));
    pending_use_pc_mux_ref = pending_cross_handoff_pc_mux_ref || pending_target_handoff_pc_mux_ref;
    pending_stale_pc_mux_ref = pending_prediction_effective && !pending_use_pc_mux_ref &&
                               pc_reg_after_pending;
    pending_hold_fetch_pc_mux_ref = pending_prediction_effective &&
                                    !pending_use_pc_mux_ref &&
                                    !pending_stale_pc_mux_ref && !pending_emit_ref;
    pending_hold_consume_pc_mux_ref = pending_prediction_effective && pending_use_pc_mux_ref;
    npc_consume_is_seq_ref = !pending_cross_handoff_pc_mux_ref &&
                             pending_prediction_allow_cross_pc_mux_q &&
                             pending_target_handoff_pc_mux_ref &&
                             !pending_prediction_from_buffer &&
                             pending_prediction_fetch_at_target;
  end

  always_comb begin
    if (!$isunknown(
            {
              pending_prediction_effective,
              pending_prediction_allow_cross,
              pending_prediction_allow_cross_pc_mux_q,
              o_pc,
              o_pc_reg,
              pending_prediction_pc,
              pending_prediction_target,
              pending_prediction_prev_pc,
              pending_prediction_prev_native_pc,
              seq_next_pc_reg_hw_q,
              pending_prediction_pc_ready_q,
              i_window_cannot_serve_raw,
              carve_out_engaged_q,
              i_prediction_holdoff,
              pending_prediction_from_buffer
            }
        )) begin
      p_pending_crossing_reduction_exact :
      assert (pending_prediction_crossing_pc_reg == pending_crossing_ref);
      p_pending_target_reduction_exact :
      assert (pending_prediction_target_handoff == pending_target_handoff_ref);
      p_pending_use_reduction_exact : assert (use_pending_prediction_for_pc_reg == pending_use_ref);
      p_pending_stale_reduction_exact : assert (stale_pending_prediction == pending_stale_ref);
      p_pending_pim_reduction_exact : assert (pim_base == pending_pim_base_ref);
      p_pending_emit_reduction_exact : assert (pending_imm_pred_emit == pending_emit_ref);
      p_pending_hold_reduction_exact :
      assert (hold_pending_prediction_fetch == pending_hold_fetch_ref);
      p_pending_fetch_holdoff_wcs0_cofactor_exact :
      assert (i_window_cannot_serve_raw ||
              o_pending_prediction_fetch_holdoff_wcs0 ==
              o_pending_prediction_fetch_holdoff);
      p_pending_fetch_holdoff_wcs_cofactor_exact :
      assert (!i_window_cannot_serve_raw ||
              o_pending_prediction_fetch_holdoff_wcs ==
              o_pending_prediction_fetch_holdoff);
      p_pending_consume_reduction_exact :
      assert (hold_pending_prediction_consume_fetch == pending_hold_consume_ref);
      p_pending_cross_pc_mux_reduction_exact :
      assert (pending_prediction_cross_handoff_pc_mux == pending_cross_handoff_pc_mux_ref);
      p_pending_target_pc_mux_reduction_exact :
      assert (pending_prediction_target_handoff_pc_mux == pending_target_handoff_pc_mux_ref);
      p_pending_use_pc_mux_reduction_exact :
      assert (use_pending_prediction_for_pc_reg_pc_mux == pending_use_pc_mux_ref);
      p_pending_hold_pc_mux_cofactor_exact :
      assert (
        pending_hold_fetch_pc_mux_ref ==
        (hold_pending_prediction_fetch_pc_mux && !pending_wcs_seq_override_pc_mux)
      );
      p_pending_consume_pc_mux_reduction_exact :
      assert (use_pending_prediction_for_pc_reg_pc_mux == pending_hold_consume_pc_mux_ref);
      p_npc_consume_seq_reduction_exact : assert (npc_consume_is_seq == npc_consume_is_seq_ref);

      // A FENCE-class redirect must disable every raw-WCS consumer in this
      // controller, independent of the served-window comparator result.
      p_fence_masks_raw_window_pending_state :
      assert (!i_fence_i_flush ||
              (!pending_prediction_effective && !pim_base &&
               !pending_imm_pred_emit && !hold_pending_prediction_fetch &&
               !hold_pending_prediction_fetch_pc_mux &&
               !hold_pending_prediction_consume_fetch &&
               !pending_wcs_seq_override_pc_mux &&
               !o_pending_prediction_fetch_holdoff &&
               !o_pending_prediction_fetch_holdoff_wcs0 &&
               !o_pending_prediction_fetch_holdoff_wcs));
      p_fence_target_wins_both_pc_muxes :
      assert (!i_fence_i_flush || i_reset || trap_or_mret ||
              (next_pc == i_fence_i_target && next_pc_reg == i_fence_i_target));
    end
  end

  // carve_out_engaged_q may still hold its old value in the FENCE-class flush
  // cycle, but its synchronous clear must remove it by the next cycle.
  logic fence_i_flush_q;
  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      fence_i_flush_q <= 1'b0;
    end else begin
      if (fence_i_flush_q) begin
        p_fence_clears_carve_latch : assert (!carve_out_engaged_q);
      end
      fence_i_flush_q <= i_fence_i_flush;
    end
  end

  // Reference for next_pc: the arms as a serial priority chain (simulation
  // only). The checks compare the factored mux with it every cycle, including
  // the arm order that makes redirects beat predictions, so a divergence
  // fails at once instead of surfacing later as a fetch bug.
  logic [XLEN-1:0] npc_ref;
  always_comb begin
    if (i_reset) npc_ref = '0;
    else if (trap_or_mret) npc_ref = i_trap_target;
    else if (i_fence_i_flush) npc_ref = i_fence_i_target;
    else if (i_branch_taken) npc_ref = i_branch_target;
    else if (i_pd_redirect) npc_ref = i_pd_redirect_target;
    else if (i_window_cannot_serve) npc_ref = {o_pc_reg[XLEN-1:2], 2'b00};
    else if (!i_fetch_progress) npc_ref = o_pc;
    else if (i_slot2_prediction_used_for_pc) npc_ref = i_slot2_predicted_target;
    else if (i_prediction_used_for_pc) npc_ref = i_predicted_target;
    else if (o_pending_prediction_target_holdoff)
      npc_ref = pending_prediction_fetch_at_target ? pending_prediction_target_next_word : o_pc;
    else if (use_pending_prediction_for_pc_reg_pc_mux) npc_ref = npc_consume_val;
    else if (halfword_target_lead_catchup || same_word_lower_parcel_catchup)
      npc_ref = seq_next_pc_plus_2;
    else if (pending_hold_fetch_pc_mux_ref)
      npc_ref = pending_prediction_allow_cross_pc_mux_q ? pending_prediction_target :
          pending_prediction_pc;
    else npc_ref = seq_next_pc;
  end

  always_comb begin
    p_next_pc_onehot : assert ($onehot(npc_sel));
    p_next_pc_matches_priority : assert (next_pc == npc_ref);
  end

  // Arm-observation contract: a sequential arm is o_pc + d, 0 <= d < 16;
  // every other arm's early operand is its value.
  always_ff @(posedge i_clk) begin
    if (!i_reset && !$isunknown({o_pc, npc_seq, npc_cmp_val})) begin
      for (int unsigned k = 0; k < NPcArms; k++) begin
        if (npc_seq[k]) begin
          p_npc_seq_arm_is_pc_plus_small : assert ((npc_val[k] - o_pc) < 64'd16);
          p_npc_seq_verdict_exact :
          assert (npc_seq_verdict[k] == riscv_pkg::fetch_verdict(npc_val[k]));
        end else begin
          p_npc_cmp_val_is_arm_value : assert (npc_cmp_val[k] == npc_val[k]);
        end
      end
    end
  end
`endif

`ifdef PC_MUX_LOCAL_PROOF
  // Reference for next_pc_reg (formal target pc_register_mux): the nested
  // priority mux, with all inputs free.
  logic [XLEN-1:0] pc_mux_nested_reference_without_live_slot2;
  logic [XLEN-1:0] pc_mux_nested_reference;
  always_comb begin
    if (i_reset) pc_mux_nested_reference_without_live_slot2 = '0;
    else if (trap_or_mret) pc_mux_nested_reference_without_live_slot2 = i_trap_target;
    else if (i_fence_i_flush) pc_mux_nested_reference_without_live_slot2 = i_fence_i_target;
    else if (i_branch_taken) pc_mux_nested_reference_without_live_slot2 = i_branch_target;
    else if (i_pd_redirect) pc_mux_nested_reference_without_live_slot2 = i_pd_redirect_target;
    // Staged slot-2 BTB prediction: pc_reg moves to the slot-2 target at
    // once, as for a PD redirect. The next cycle is squashed through the
    // control-flow holdoff (seq_sel_holdoff holds pc_reg at the target), and
    // the target window arrives the cycle after that.
    else if (i_slot2_staged_prediction_used_for_pc)
      pc_mux_nested_reference_without_live_slot2 = i_slot2_staged_predicted_target;
    // The next two arms match pc_reg_nonseq_without_slot2 (see the comments
    // there).
    else if (o_pending_prediction_target_holdoff)
      pc_mux_nested_reference_without_live_slot2 = o_pc_reg;
    else if (pending_prediction_effective && !pending_prediction_allow_cross_pc_mux_q &&
             !use_pending_prediction_for_pc_reg_pc_mux && !pending_imm_pred_emit)
      pc_mux_nested_reference_without_live_slot2 = pending_prediction_pc;
    else if (pending_prediction_cross_handoff_pc_mux)
      pc_mux_nested_reference_without_live_slot2 = pending_prediction_pc;
    else if (pending_prediction_target_handoff_pc_mux)
      pc_mux_nested_reference_without_live_slot2 = pending_prediction_target;
    else if (sel_prediction_r) pc_mux_nested_reference_without_live_slot2 = i_predicted_target_r;
    else pc_mux_nested_reference_without_live_slot2 = seq_next_pc_reg;
  end

  // The live slot-2 fallback has the same priority as the staged slot-2 arm:
  // below every redirect and above the pending, registered-prediction, and
  // sequential choices. Its select without the alias check and both candidate
  // values settle in parallel, so the full-address alias compare only selects
  // the last 2:1 instead of heading the pc_reg priority chain.
  logic pc_mux_nested_reference_live_override;
  logic [XLEN-1:0] pc_mux_nested_reference_if_alias;
  assign pc_mux_nested_reference_live_override =
      i_slot2_live_target_used_for_pc_cofactor &&
      !i_reset && !trap_or_mret && !i_fence_i_flush &&
      !i_branch_taken && !i_pd_redirect;
  assign pc_mux_nested_reference_if_alias = pc_mux_nested_reference_live_override ?
      i_slot2_live_predicted_target : pc_mux_nested_reference_without_live_slot2;
  assign pc_mux_nested_reference = i_slot1_aliases_slot2_candidate ?
      pc_mux_nested_reference_if_alias : pc_mux_nested_reference_without_live_slot2;

  always_comb begin
    p_pc_register_slot2_mux_matches_nested_original :
    assert (next_pc_reg == pc_mux_nested_reference);
  end
`endif

`ifdef FORMAL
  // Check the holdoff outputs against their reference equations. The
  // prediction holdoffs also rely on the predecessor-tag relation, which
  // pc_holdoff_tag proves from the valid bit's reset value. The three
  // fetch-holdoff identities hold for any register state (pc_holdoff_cofactor).
  always_comb begin
`ifndef PC_FETCH_HOLDOFF_ONLY
    // Before the first reset the valid bit and the tags are arbitrary; the tag
    // relation, and so these checks, hold once reset has cleared the valid
    // bit.
    if (!i_reset) begin
      p_pending_holdoff_effective_cofactor_matches_original :
      assert (o_pending_prediction_holdoff ==
            (hold_pending_prediction_fetch || hold_pending_prediction_consume_fetch));
      p_pending_holdoff_wcs0_effective_cofactor_matches_original :
      assert (o_pending_prediction_holdoff_wcs0 ==
            ((pending_prediction_effective && !use_pending_prediction_for_pc_reg &&
              !pc_reg_after_pending && !pending_predecessor_release_wcs0) ||
             hold_pending_prediction_consume_fetch));
      p_pending_holdoff_wcs_effective_cofactor_matches_original :
      assert (o_pending_prediction_holdoff_wcs ==
            ((pending_prediction_effective && !use_pending_prediction_for_pc_reg &&
              !pc_reg_after_pending && !pc_reg_at_pending_predecessor) ||
             hold_pending_prediction_consume_fetch));
    end
`endif
    p_pending_fetch_holdoff_effective_cofactor_matches_original :
    assert (o_pending_prediction_fetch_holdoff ==
            (hold_pending_prediction_fetch ||
             (hold_pending_prediction_consume_fetch && pending_prediction_allow_cross &&
              (o_pc_reg != pending_prediction_pc))));
    p_pending_fetch_holdoff_wcs0_effective_cofactor_matches_original :
    assert (o_pending_prediction_fetch_holdoff_wcs0 ==
            ((pending_prediction_effective && !use_pending_prediction_for_pc_reg &&
              !pc_reg_after_pending && !pending_predecessor_release_wcs0) ||
             (hold_pending_prediction_consume_fetch && pending_prediction_allow_cross &&
              (o_pc_reg != pending_prediction_pc))));
    p_pending_fetch_holdoff_wcs_effective_cofactor_matches_original :
    assert (o_pending_prediction_fetch_holdoff_wcs ==
            ((pending_prediction_effective && !use_pending_prediction_for_pc_reg &&
              !pc_reg_after_pending && !pc_reg_at_pending_predecessor) ||
             (hold_pending_prediction_consume_fetch && pending_prediction_allow_cross &&
              (o_pc_reg != pending_prediction_pc))));
  end

`ifndef PC_HOLDOFF_LOCAL_PROOF
  // Once reset has established the tag relation, a ready handoff asserts both
  // prediction holdoff outputs, whatever raw WCS and the predecessor
  // exception are.
  always_comb begin
    if (!i_reset) begin
      p_pending_handoff_asserts_both_prediction_holdoffs :
      assert (!pending_prediction_target_handoff ||
            (o_pending_prediction_holdoff_wcs0 && o_pending_prediction_holdoff_wcs));
      if (PENDING_HANDOFF_EXCLUDES_SLOT2) begin
        p_formal_integrated_pending_handoff_excludes_slot2 :
        assert (!(pending_prediction_target_handoff && i_slot2_prediction_used_for_pc));
        p_formal_integrated_handoff_matches_generic_priority :
        assert (pending_prediction_target_handoff_applies ==
              (pending_prediction_target_handoff && !fetch_stall &&
               !i_window_cannot_serve && !i_slot2_prediction_used_for_pc &&
               !o_pending_prediction_target_holdoff));
      end
    end
  end

  // pending_predecessor_needs_emit includes raw WCS. Everything that uses it
  // must be masked while no prediction is pending, including the PC-mux copy;
  // check that directly instead of relying on how the equations are
  // factored. c_ext_state's properties separately cover old-path buffer state
  // at a handoff.
  always_comb begin
    if (!pending_prediction_effective) begin
      p_inactive_pending_masks_predecessor_base : assert (!pim_base);
      p_inactive_pending_masks_predecessor_emit : assert (!pending_imm_pred_emit);
      p_inactive_pending_masks_predecessor_hold : assert (!hold_pending_prediction_fetch);
      p_inactive_pending_masks_predecessor_pc_mux : assert (!hold_pending_prediction_fetch_pc_mux);
      p_inactive_pending_masks_wcs_pc_override : assert (!pending_wcs_seq_override_pc_mux);
      p_inactive_pending_masks_fetch_holdoff : assert (!o_pending_prediction_fetch_holdoff);
      p_inactive_pending_masks_fetch_holdoff_wcs0 :
      assert (!o_pending_prediction_fetch_holdoff_wcs0);
      p_inactive_pending_masks_fetch_holdoff_wcs : assert (!o_pending_prediction_fetch_holdoff_wcs);
    end
  end

  always_ff @(posedge i_clk) begin
    if (!i_reset) begin
      // IF relies on the register copy of pc_reg[1] and on the precomputed
      // tags; check them in formal as well as in simulation.
      p_formal_pc_reg_high_coverage_replica_exact :
      assert (o_pc_reg_high_for_coverage == o_pc_reg[1]);
      if (pending_prediction_valid) begin
        p_formal_pending_prediction_prev_pc_matches_capture :
        assert (pending_prediction_prev_pc ==
                (pending_prediction_pc - riscv_pkg::PcIncrementCompressed));
        p_formal_pending_prediction_prev_native_pc_matches_capture :
        assert (pending_prediction_prev_native_pc ==
                (pending_prediction_pc - riscv_pkg::PcIncrement32bit));
      end

      // While o_fetch_lookup_is_lower_parcel is set, o_pc is in the lower half
      // of a word and pc_reg in the upper half. In the cycle after the
      // resteer, when neither PC comes from the increment logic, also check
      // that both are in the same word. The later catch-up result is not
      // checked, because prediction_release's stand-in for
      // pc_increment_calculator (prediction_release_pc_increment) leaves that
      // arithmetic free.
      p_formal_lower_parcel_lookup_has_opposite_halfword_lanes :
      assert (!o_fetch_lookup_is_lower_parcel || (!o_pc[1] && o_pc_reg[1]));
      if ($past(!i_flush && !fetch_stall && npc_sel[5] && o_pc_reg[1])) begin
        p_formal_lower_parcel_resteer_capture_has_exact_geometry :
        assert (o_fetch_lookup_is_lower_parcel && o_pc[XLEN-1:2] == o_pc_reg[XLEN-1:2]);
      end

      cover_pending_predecessor_emit :
      cover (pending_prediction_effective && pending_predecessor_needs_emit);
      cover_pending_compressed_predecessor_tag :
      cover (pending_prediction_valid && o_pc_reg == pending_prediction_prev_pc);
      cover_pending_native_predecessor_tag :
      cover (pending_prediction_valid && o_pc_reg == pending_prediction_prev_native_pc);
      cover_lower_parcel_lookup : cover (o_fetch_lookup_is_lower_parcel);
    end
  end
`endif

`endif

`ifdef PC_HOLDOFF_TAG_PROOF
  // The only initial-state assumption: the valid bit starts clear, its reset
  // value.
  initial assume (!pending_prediction_valid);
  logic [XLEN-1:0] tag_capture_prev_reference;
  assign tag_capture_prev_reference =
      XLEN'(pending_prediction_pc - riscv_pkg::PcIncrementCompressed);
  always_comb begin
    p_tag_capture_relation :
    assert (!pending_prediction_valid || pending_prediction_prev_pc == tag_capture_prev_reference);
    p_tag_capture_distinct :
    assert (!pending_prediction_valid || pending_prediction_prev_pc != pending_prediction_pc);
    cover_tag_zero_owner :
    cover (pending_prediction_valid && pending_prediction_pc == '0 && pc_reg_at_pending &&
           o_pending_prediction_holdoff_wcs0 && o_pending_prediction_holdoff_wcs);
    cover_tag_odd_wrapped_owner :
    cover (pending_prediction_valid && pending_prediction_pc == XLEN'(1) && pc_reg_at_pending &&
           pending_prediction_prev_pc == '1 && o_pending_prediction_holdoff_wcs0 &&
           o_pending_prediction_holdoff_wcs);
    cover_tag_wrapped_predecessor :
    cover (pending_prediction_valid && pending_prediction_pc == '0 &&
           pc_reg_at_pending_predecessor && !o_pending_prediction_holdoff_wcs);
  end
`endif


`ifdef FETCH_MUX_LOCAL_PROOF
  // References for next_pc (formal target fetch_pc_mux): the one-hot
  // reduction of the arms and the serial priority chain.
  always_comb begin
    p_catchup_increment_equality :
    assert (fetch_is_halfword_ahead == (o_pc == (o_pc_reg + riscv_pkg::PcIncrementCompressed)));
  end
  logic [XLEN-1:0] fetch_mux_onehot_reference;
  logic [XLEN-1:0] fetch_ref;
  logic fetch_mux_original_pending_hold;
  assign fetch_mux_original_pending_hold =
      pending_prediction_effective && !use_pending_prediction_for_pc_reg_pc_mux &&
      !pc_reg_after_pending && !pending_imm_pred_emit;
  always_comb begin
    fetch_mux_onehot_reference = '0;
    for (int unsigned k = 0; k < NPcArms; k++) begin
      fetch_mux_onehot_reference |= {XLEN{npc_sel[k]}} & npc_val[k];
    end
  end
  always_comb begin
    if (i_reset) fetch_ref = '0;
    else if (trap_or_mret) fetch_ref = i_trap_target;
    else if (i_fence_i_flush) fetch_ref = i_fence_i_target;
    else if (i_branch_taken) fetch_ref = i_branch_target;
    else if (i_pd_redirect) fetch_ref = i_pd_redirect_target;
    else if (i_window_cannot_serve) fetch_ref = {o_pc_reg[XLEN-1:2], 2'b00};
    else if (!i_fetch_progress) fetch_ref = o_pc;
    else if (i_slot2_prediction_used_for_pc) fetch_ref = i_slot2_predicted_target;
    else if (i_prediction_used_for_pc) fetch_ref = i_predicted_target;
    else if (o_pending_prediction_target_holdoff)
      fetch_ref = pending_prediction_fetch_at_target ? pending_prediction_target_next_word : o_pc;
    else if (use_pending_prediction_for_pc_reg_pc_mux) fetch_ref = npc_consume_val;
    else if (halfword_target_lead_catchup || same_word_lower_parcel_catchup)
      fetch_ref = seq_next_pc_plus_2;
    else if (fetch_mux_original_pending_hold)
      fetch_ref = pending_prediction_allow_cross_pc_mux_q ? pending_prediction_target :
          pending_prediction_pc;
    else fetch_ref = seq_next_pc;
  end

  always_comb begin
    p_fetch_mux_matches_onehot_original : assert (next_pc == fetch_mux_onehot_reference);
    p_fetch_mux_matches_priority_original : assert (next_pc == fetch_ref);
    p_fetch_mux_preserves_onehot_winner : assert ($onehot(npc_sel));
  end
`endif

endmodule : pc_controller
