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
  C-extension instruction-buffer state; parcel selection and PC updates live
  elsewhere.

  State updates are blocked during flush to prevent garbage instructions (from the
  old PC path) from corrupting state. i_flush is if_stage's
  frontend_state_flush: a short registered pulse per event (mispredict recovery,
  FENCE-class recovery, trap, MRET). It is NOT asserted for BTB/RAS predictions or PD
  redirects; control_flow_tracker handles those changes with
  holdoffs.
*/
module c_ext_state #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,

    // Pipeline control
    input logic i_reset,
    input logic i_stall,
    input logic i_flush,            // Pipeline flush - block state updates during flush
    input logic i_fence_i_flush,    // Registered FENCE-class frontend flush
    input logic i_stall_registered,

    // Control flow signals (from control flow tracker)
    input logic i_control_flow_holdoff,  // Registered: stale instruction cycle
    input logic i_any_holdoff_safe,  // Holdoff using only registered signals
    input logic i_prediction_holdoff,  // Registered: prediction happened last cycle (clear state)
    input logic i_prediction_reset_state,  // Non-buffer prediction redirected fetch this cycle
    input logic i_pending_prediction_active,  // pc_reg still consumes old-path instruction sizes
    input logic i_pending_prediction_target_handoff,  // Old-path control-flow op just redirected
    input logic i_pending_prediction_target_holdoff,  // Bubble while halfword branch PC catches up
    input logic i_prediction_from_buffer_holdoff,  // Need buffered old-path word next cycle

    // Instruction data
    input logic [    31:0] i_effective_instr,     // Current effective instruction word
    // BRAM word order doesn't match pc_reg (bank_sel_r ^ pc_reg[2])
    input logic            i_fetch_word_swapped,
    input logic [XLEN-1:0] i_pc,                  // Current fetch PC
    input logic [XLEN-1:0] i_pc_reg,              // Registered PC

    // Instruction type detection (from instruction aligner)
    input logic i_is_compressed,  // Current parcel is compressed
    input logic i_sel_nop,  // IF is outputting a stale/invalid bubble this cycle
    // Fetch progress (live window valid OR stall-replay bundle presented).
    // The buffer state machines below enumerate registered bubble sources
    // individually (instead of consuming the BRAM-late i_sel_nop); a
    // no-progress fetch cycle is a new bubble source they must also
    // exclude, except when the consumed data comes from the saved stall
    // snapshot.
    input logic i_fetch_progress,
    input logic [riscv_pkg::ImemSidebandWidth-1:0] i_instr_sideband,
    // Fetch-fault status of the current effective word ({fault, page kind};
    // Phase 3 M5), captured beside the word so a buffered faulted word
    // still delivers a fault-tagged bundle.
    input logic [1:0] i_instr_fault,

    // 2-wide bundle metadata: slot-2 valid this cycle.  When set
    // and slot-1 is RVC at lo, slot-2 has already consumed the upper half so
    // we must NOT arm the "previously compressed at lo" buffer state.
    input logic i_slot2_valid,

    // Outputs
    output logic [31:0] o_instr_buffer,
    output logic o_prev_was_compressed_at_lo,
    output logic o_is_compressed_for_buffer,  // Stall-restored is_compressed
    output logic o_is_compressed_for_pc,  // Registered is_compressed for PC increment (timing)
    output logic o_use_buffer_after_prediction,  // Use buffer after predicted buffered instruction
    // Exact F=0,H=0,R=0 cofactor of o_use_buffer_after_prediction, where F is
    // the registered FENCE-class flush, H is the registered control-flow
    // holdoff, and R is the registered prediction reset. Served-window
    // coverage and the aligner's fast-size selector consume this timing-only
    // companion; architectural buffer selection keeps all three masks.
    output logic o_use_buffer_after_prediction_timing,
    // The two holdoff-release edges of the cofactor above without its
    // i_prediction_holdoff mask, so if_stage can apply that late mask in the
    // last LUT of its coverage qualification.
    output logic o_use_buffer_after_prediction_edge,
    output logic o_is_compressed_saved,  // Saved is_compressed for fast path
    output logic o_saved_values_valid,  // Saved values are valid (not invalidated by control flow)
    output logic [riscv_pkg::ImemSidebandWidth-1:0] o_instr_buffer_sideband,
    output logic [1:0] o_instr_buffer_fault  // {fault, page kind} of the buffered word
);

  // ===========================================================================
  // Stall State Preservation
  // ===========================================================================
  // Save state at stall start for restoration.

  logic [31:0] effective_instr_saved;
  logic is_compressed_saved;
  logic [riscv_pkg::ImemSidebandWidth-1:0] sideband_saved;
  logic [1:0] fault_saved;
  logic saved_values_valid;  // Track if saved values are valid (not invalidated by flush)
  logic invalidate_saved_values_holdoff;
  logic capture_valid_stall_values;
  logic is_compressed_for_pc_capture;
  // A stall-captured IF word must remain replayable for the rest of the stall.
  // Registered prediction/control-flow holdoffs can arrive a cycle later than
  // the captured instruction; if they clear saved_values_valid mid-stall, IF
  // falls back to the live BRAM word while PC metadata remains held, creating
  // wrong PC/instruction pairings like 0x78 -> 0x38.
  assign invalidate_saved_values_holdoff =
      !i_stall_registered &&
      (i_control_flow_holdoff || i_prediction_holdoff || i_prediction_reset_state);
  assign capture_valid_stall_values = i_stall && !i_stall_registered && !i_sel_nop;
  assign is_compressed_for_pc_capture = is_compressed_for_buffer;

  // Flush must clear saved state immediately on redirects. The one-cycle-delayed
  // control_flow_holdoff cleanup is not sufficient for redirects that land on a
  // halfword boundary immediately after a spanning instruction.
  always_ff @(posedge i_clk) begin
    if (i_flush) begin
      // Registered control flow change invalidates saved values.
      // We've jumped to a different PC, so saved values are stale.
      // Also clear the data to prevent any stale data from persisting.
      effective_instr_saved <= '0;
      is_compressed_saved   <= 1'b0;
      sideband_saved        <= '0;
      fault_saved           <= '0;
    end else if (i_stall & ~i_stall_registered) begin
      if (capture_valid_stall_values) begin
        // Save real instructions at stall start.
        effective_instr_saved <= i_effective_instr;
        is_compressed_saved   <= i_is_compressed;
        sideband_saved        <= i_instr_sideband;
        fault_saved           <= i_instr_fault;
      end else begin
        effective_instr_saved <= '0;
        is_compressed_saved   <= 1'b0;
        sideband_saved        <= '0;
        fault_saved           <= '0;
      end
    end else if (invalidate_saved_values_holdoff) begin
      effective_instr_saved <= '0;
      is_compressed_saved   <= 1'b0;
      sideband_saved        <= '0;
      fault_saved           <= '0;
    end
  end
  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      saved_values_valid <= 1'b0;
    end else if (i_stall & ~i_stall_registered) begin
      saved_values_valid <= capture_valid_stall_values;
    end else if (i_flush || invalidate_saved_values_holdoff) begin
      saved_values_valid <= 1'b0;
    end
  end

  // Use saved values when coming out of stall.
  //
  // TIMING OPTIMIZATION: Use only registered signals for the mux select to break
  // the critical timing path from trap_taken -> stall -> is_compressed_for_buffer -> PC.
  //
  // The key insight: when stall_registered && saved_values_valid, we should use
  // saved values. We don't need to check ~i_stall because:
  //   - If unstalling: saved values are correct
  //   - If still stalled: value isn't consumed anyway (gated by ~stall elsewhere)
  //   - If wasn't stalled: saved_values_valid is false, so live values are used
  //
  // This replaces: just_unstalled = ~i_stall && i_stall_registered && saved_values_valid
  // The ~i_stall check was in the critical path.
  logic use_saved_values;
  assign use_saved_values = i_stall_registered && saved_values_valid;

  logic [31:0] effective_instr_for_buffer;
  logic        is_compressed_for_buffer;
  logic        preserve_lo_compressed_buffer_on_prediction;
  logic        prediction_reset_buffer_state;
  logic        capture_pending_prediction_buffer;
  logic        capture_pending_prediction_buffer_state;

  assign effective_instr_for_buffer = use_saved_values ? effective_instr_saved : i_effective_instr;

  // Sideband mux: use saved sideband when restoring from stall, live BRAM sideband otherwise
  logic [riscv_pkg::ImemSidebandWidth-1:0] effective_sideband_for_buffer;
  assign effective_sideband_for_buffer = use_saved_values ? sideband_saved : i_instr_sideband;
  logic [1:0] effective_fault_for_buffer;
  assign effective_fault_for_buffer = use_saved_values ? fault_saved : i_instr_fault;
  assign is_compressed_for_buffer = use_saved_values ? is_compressed_saved : i_is_compressed;
  assign preserve_lo_compressed_buffer_on_prediction =
      i_prediction_reset_state &&
      is_compressed_for_buffer &&
      !i_pc_reg[1];
  // While a pending prediction merely walks an older compressed low parcel,
  // preserve its upper sibling for the next sequential packet. Keep the raw
  // data capture independent of the handoff control cone: stale payload is
  // harmless whenever its one-bit valid state is clear.
  assign capture_pending_prediction_buffer =
      i_pending_prediction_active &&
      i_prediction_holdoff &&
      is_compressed_for_buffer &&
      !i_pc_reg[1];
  // If the exact owner and target handoff are consumed atomically, that upper
  // sibling is wrong-path. Let the handoff clear dominate only the validity
  // override so no broad data/sideband/fault CE inherits the PC apply cone.
  assign capture_pending_prediction_buffer_state =
      capture_pending_prediction_buffer &&
      !i_pending_prediction_target_handoff;
  assign prediction_reset_buffer_state =
      i_prediction_reset_state && !preserve_lo_compressed_buffer_on_prediction;

  // Export stall-restored is_compressed for use by pc_controller and spanning detection
  assign o_is_compressed_for_buffer = is_compressed_for_buffer;

  // Export saved values for instruction_aligner's fast path
  assign o_is_compressed_saved = is_compressed_saved;
  assign o_saved_values_valid = saved_values_valid;

  // ===========================================================================
  // Pending Prediction Target Holdoff — Buffer Preservation
  // ===========================================================================
  // When a pending halfword-aligned prediction target holdoff is active and the
  // buffer is needed (prev_was_compressed_at_lo && pc_reg[1]), preserve the
  // buffer across the holdoff so it's available when the holdoff ends.
  logic pending_prediction_target_holdoff_needs_buffer;
  logic pending_prediction_target_holdoff_prev;
  assign pending_prediction_target_holdoff_needs_buffer =
      i_pending_prediction_target_holdoff &&
      o_prev_was_compressed_at_lo &&
      i_pc_reg[1];

  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush || i_control_flow_holdoff || i_prediction_holdoff ||
        i_prediction_reset_state)
      pending_prediction_target_holdoff_prev <= 1'b0;
    else if (!i_stall)
      pending_prediction_target_holdoff_prev <= pending_prediction_target_holdoff_needs_buffer;
  end

  // ===========================================================================
  // Use Buffer After Prediction
  // ===========================================================================
  // After a prediction fires while using the instruction buffer (for example a
  // compressed return in the upper half of a word), the next cycle is a NOP
  // holdoff, but the buffered old-path word must remain available for one more
  // cycle so the predicted instruction itself can still be decoded correctly.
  logic prediction_from_buffer_holdoff_prev;
  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush || i_control_flow_holdoff || i_prediction_holdoff ||
        i_prediction_reset_state)
      prediction_from_buffer_holdoff_prev <= 1'b0;
    else if (!i_stall) prediction_from_buffer_holdoff_prev <= i_prediction_from_buffer_holdoff;
  end

  // TIMING: expose the exact i_fence_i_flush=0,
  // i_control_flow_holdoff=0, i_prediction_reset_state=0 cofactor separately.
  // The caller proves that R implies H and that F/H squash every fast-size and
  // coverage consumer. Prediction-delivery cycles remain masked by
  // i_prediction_holdoff in this companion and in the canonical aligner
  // selection. Keep this masked function as the single shared companion for
  // the aligner, branch predictor, and served-window comparators. Equivalent
  // per-consumer copies change synthesis partitioning and lengthen the PC
  // recurrence on X3.
  assign o_use_buffer_after_prediction_edge =
      (prediction_from_buffer_holdoff_prev && !i_prediction_from_buffer_holdoff) ||
      (pending_prediction_target_holdoff_prev && !i_pending_prediction_target_holdoff);
  assign o_use_buffer_after_prediction_timing =
      o_use_buffer_after_prediction_edge && !i_prediction_holdoff;
  assign o_use_buffer_after_prediction =
      o_use_buffer_after_prediction_timing && !i_prediction_reset_state &&
      !i_fence_i_flush && !i_control_flow_holdoff;

`ifndef SYNTHESIS
  always_comb begin
    if (!$isunknown(
            {
              o_use_buffer_after_prediction_timing,
              i_prediction_holdoff,
              i_prediction_reset_state,
              i_fence_i_flush,
              i_control_flow_holdoff,
              o_use_buffer_after_prediction
            }
        )) begin
      p_use_buffer_after_prediction_timing_cofactor_exact :
      assert (o_use_buffer_after_prediction ==
              (o_use_buffer_after_prediction_timing && !i_prediction_reset_state &&
               !i_fence_i_flush && !i_control_flow_holdoff));
      p_use_buffer_after_prediction_implies_timing_companion :
      assert (!o_use_buffer_after_prediction || o_use_buffer_after_prediction_timing);
    end
    if (!$isunknown(
            {i_pending_prediction_target_handoff, capture_pending_prediction_buffer_state}
        )) begin
      // An atomically consumed owner makes its upper-half sibling wrong-path.
      // The handoff clear must dominate the older-packet preservation path or
      // that stale sibling can be released as the first target instruction.
      p_pending_handoff_excludes_old_path_buffer_valid :
      assert (!(i_pending_prediction_target_handoff && capture_pending_prediction_buffer_state));
    end
  end
`endif

  // ===========================================================================
  // Instruction Buffer State Machine
  // ===========================================================================
  // Buffer the current word when processing a compressed instruction at instr_lo,
  // so the next instruction (at instr_hi) can access the same word.
  //
  // Note: The stall state preservation logic (effective_instr_saved, just_unstalled,
  // effective_instr_for_buffer, etc.) is defined earlier in the file because other
  // logic depends on it.

  // Buffer state register updates
  //
  // A BTB prediction can fire on the next word while IF is still outputting the
  // low half of a compressed pair. In that case the upper-half sibling still
  // needs the current buffer state for one more cycle, so preserve only the
  // buffer bookkeeping across the immediate prediction reset. The regular
  // prediction_holdoff in the following cycle still clears the state before the
  // predicted target starts executing.

  // Control register: must be reset and cleared on control flow changes
  always_ff @(posedge i_clk) begin
    if (i_reset || i_control_flow_holdoff || i_flush || i_prediction_holdoff ||
        prediction_reset_buffer_state || i_pending_prediction_target_handoff) begin
      o_prev_was_compressed_at_lo <= 1'b0;
      if (capture_pending_prediction_buffer_state) begin
        o_prev_was_compressed_at_lo <= 1'b1;
      end
    end else if (!i_stall && (i_fetch_progress || use_saved_values) && !i_any_holdoff_safe &&
                 !pending_prediction_target_holdoff_needs_buffer &&
                 !i_prediction_from_buffer_holdoff &&
                 !o_use_buffer_after_prediction &&
                 !i_pending_prediction_active) begin
      // 2-wide: when slot-1 is RVC at lo and slot-2 fired at hi, both halves
      // of the current word are consumed this cycle so the buffer is not
      // needed next cycle.  i_slot2_valid drops the buffer arm in that case.
      o_prev_was_compressed_at_lo <= is_compressed_for_buffer && !i_pc_reg[1] && !i_slot2_valid;
    end
  end

  // Data register: no reset needed. The control signal o_prev_was_compressed_at_lo gates
  // when buffer data is used, and that signal IS properly reset. After reset, buffer data
  // cannot be selected until valid data has been written. Removing reset from these 32 FFs
  // improves timing/area by eliminating reset tree connectivity.
  // Exclude prediction holdoff so stale post-redirect data cannot enter the
  // buffer and later be selected by use_instr_buffer.
  always_ff @(posedge i_clk) begin
    if (!i_stall && (i_fetch_progress || use_saved_values) &&
        (!i_any_holdoff_safe || capture_pending_prediction_buffer) &&
        !i_flush &&
        !pending_prediction_target_holdoff_needs_buffer &&
        (!i_prediction_holdoff || capture_pending_prediction_buffer) &&
        !i_prediction_from_buffer_holdoff &&
        !prediction_reset_buffer_state &&
        !o_use_buffer_after_prediction &&
        (!i_pending_prediction_active || capture_pending_prediction_buffer)) begin
      o_instr_buffer <= effective_instr_for_buffer;
      o_instr_buffer_sideband <= effective_sideband_for_buffer;
      o_instr_buffer_fault <= effective_fault_for_buffer;
    end
  end

  // ===========================================================================
  // Registered is_compressed for PC Increment (Timing Optimization)
  // ===========================================================================
  // Register is_compressed for use in the PC increment calculation path.
  //
  // TIMING OPTIMIZATION: The PC increment feeds into a 32-bit adder (CARRY8 chain)
  // which is in the critical path. By using a registered is_compressed, we break
  // the path from stall logic through is_compressed to the PC adder.
  //
  // Reset to 0 (assume 32-bit = increment by 4) for conservative behavior.
  // Keep the old-path size alive through the immediate prediction cycle: if IF
  // has already fetched ahead to a predicted branch, pc_reg may still need one
  // more compressed +2 step before it reaches the branch PC.
  //
  // Do not sample is_compressed_for_buffer on sel_nop cycles. Those bubbles can
  // still carry stale BRAM bytes from an old control-flow path; latching their
  // apparent 16-bit parcel size corrupts pc_reg and shifts later instruction PCs.
  always_ff @(posedge i_clk) begin
    if (i_reset || i_control_flow_holdoff) begin
      o_is_compressed_for_pc <= 1'b0;
    end else if (!i_pending_prediction_active &&
                 ((!i_stall && !i_sel_nop) || capture_valid_stall_values)) begin
      o_is_compressed_for_pc <= is_compressed_for_pc_capture;
    end
  end

`ifdef FORMAL
  // The integrated producer relationships keep both legacy buffer-release
  // history sources clear. In particular, an atomic target handoff may still
  // capture the raw owner word, but it must suppress the one-bit valid-state
  // override that formerly made the wrong-path upper sibling selectable.
  // Exercise both cofactors so the clear-dominance proof is non-vacuous.
  always_ff @(posedge i_clk) begin
    if (!i_reset) begin
      // Both upstream holdoff registers advance on the same delivery enable,
      // and prediction-from-buffer is a subset of prediction-used.  Redirect
      // cases that clear only prediction_holdoff also assert the control-flow
      // holdoff, so this history source can never become set.
      p_prediction_from_buffer_release_source_stays_clear :
      assert (!prediction_from_buffer_holdoff_prev);
      // The applied handoff clears valid state on the edge before its target
      // bubble. Even if target data rearms state on the following edge, that
      // coincides with the holdoff dropping and cannot create a release pulse.
      p_pending_target_release_source_stays_clear :
      assert (!pending_prediction_target_holdoff_prev);
      p_integrated_buffer_release_edge_stays_clear : assert (!o_use_buffer_after_prediction_edge);

      cover_pending_prediction_episode : cover (i_pending_prediction_active);
      cover_pending_buffer_capture_without_handoff :
      cover (capture_pending_prediction_buffer && !i_pending_prediction_target_handoff &&
             capture_pending_prediction_buffer_state);
      cover_pending_buffer_capture_with_handoff :
      cover (capture_pending_prediction_buffer && i_pending_prediction_target_handoff &&
             !capture_pending_prediction_buffer_state);
    end
  end
`endif

endmodule : c_ext_state
