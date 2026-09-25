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
  C-extension fetch state: the instruction buffer that keeps a word after a
  compressed instruction in its low half, so the next instruction can come from
  the high half, and the fetch word saved at stall entry for replay. Parcel
  selection and PC updates live elsewhere.

  State updates are blocked during flush so garbage instructions from the old
  PC path cannot corrupt state. i_flush is if_stage's frontend_state_flush: a
  short pulse, decoded from registered state, per event (mispredict recovery,
  FENCE-class recovery, trap, xRET). It is not asserted for BTB/RAS predictions
  or PD redirects; control_flow_tracker handles those changes with holdoffs.
*/
module c_ext_state #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,

    // Pipeline control
    input logic i_reset,
    input logic i_stall,
    input logic i_flush,  // Frontend flush: blocks state updates
    input logic i_stall_registered,

    // Control flow signals (from control flow tracker)
    input logic i_control_flow_holdoff,  // Registered: stale instruction cycle
    input logic i_any_holdoff_safe,  // Holdoff using only registered signals
    input logic i_prediction_holdoff,  // Registered: prediction happened last cycle (clear state)
    input logic i_prediction_reset_state,  // Registered: slot-1 or slot-2 prediction last cycle
    input logic i_pending_prediction_active,  // pc_reg still consumes old-path instruction sizes
    input logic i_pending_prediction_target_handoff,  // Old-path control-flow op just redirected
    input logic i_pending_prediction_target_holdoff,  // Bubble while halfword branch PC catches up

    // Instruction data
    input logic [    31:0] i_effective_instr,  // Current effective instruction word
    input logic [XLEN-1:0] i_pc_reg,           // Registered PC

    // Instruction type detection (from instruction aligner)
    input logic i_is_compressed,  // Current parcel is compressed
    input logic i_sel_nop,  // IF is outputting a stale/invalid bubble this cycle
    // Fetch progress: a live window is valid, or a stall-replay bundle is
    // presented. The buffer state machines below enumerate registered bubble
    // sources one at a time rather than consuming the BRAM-late i_sel_nop. A
    // no-progress fetch cycle is another bubble source they must exclude,
    // except when the consumed data comes from the saved stall snapshot.
    input logic i_fetch_progress,
    input logic [riscv_pkg::ImemSidebandWidth-1:0] i_instr_sideband,
    // Fetch-fault status of the current effective word ({fault, page kind}).
    // Captured beside the word so a buffered faulted word still delivers a
    // fault-tagged bundle.
    input logic [1:0] i_instr_fault,

    // 2-wide bundle metadata: slot-2 valid this cycle.  When it is set and
    // slot-1 is RVC at lo, slot-2 has already consumed the upper half, so the
    // "previously compressed at lo" buffer state stays clear.
    input logic i_slot2_valid,

    // Outputs
    output logic [31:0] o_instr_buffer,
    output logic o_prev_was_compressed_at_lo,
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
  // A stall-captured IF word must remain replayable for the rest of the stall.
  // Registered prediction/control-flow holdoffs can arrive a cycle later than
  // the captured instruction; if they cleared saved_values_valid mid-stall, IF
  // would fall back to the live BRAM word while the PC metadata stays held,
  // pairing an instruction with the wrong PC. So they invalidate the saved
  // values only outside a registered stall.
  assign invalidate_saved_values_holdoff =
      !i_stall_registered &&
      (i_control_flow_holdoff || i_prediction_holdoff || i_prediction_reset_state);
  assign capture_valid_stall_values = i_stall && !i_stall_registered && !i_sel_nop;

  // Flush must clear saved state immediately on redirects. The one-cycle-delayed
  // control_flow_holdoff cleanup is not sufficient for redirects that land on a
  // halfword boundary immediately after a spanning instruction.
  always_ff @(posedge i_clk) begin
    if (i_flush) begin
      // A registered control-flow change means fetch went to a different PC,
      // so the saved word is stale. The data is cleared here, the valid bit in
      // the block below.
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

  // Use saved values when coming out of stall. The mux select uses only
  // registered signals, which breaks the critical path
  // trap_taken -> stall -> is_compressed_for_buffer -> PC.
  //
  // Testing ~i_stall as well would be redundant:
  //   - If unstalling: saved values are correct
  //   - If still stalled: value isn't consumed anyway (gated by ~stall elsewhere)
  //   - If no stall is registered: live values are used
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
  // While a pending prediction waits and pc_reg is at an older compressed
  // instruction in a low half, keep the word so its upper sibling is available
  // to the next sequential packet. Keep the raw data capture independent of
  // the handoff control cone: stale payload is harmless whenever its one-bit
  // valid state is clear.
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

  // Export saved values for instruction_aligner's fast path
  assign o_is_compressed_saved = is_compressed_saved;
  assign o_saved_values_valid = saved_values_valid;

  // ===========================================================================
  // Pending Prediction Target Holdoff: Buffer Preservation
  // ===========================================================================
  // When a pending halfword-aligned prediction target holdoff is active and the
  // buffer is needed (prev_was_compressed_at_lo && pc_reg[1]), preserve the
  // buffer across the holdoff so it's available when the holdoff ends.
  logic pending_prediction_target_holdoff_needs_buffer;
  assign pending_prediction_target_holdoff_needs_buffer =
      i_pending_prediction_target_holdoff &&
      o_prev_was_compressed_at_lo &&
      i_pc_reg[1];

`ifndef SYNTHESIS
  always_comb begin
    if (!$isunknown(
            {i_pending_prediction_target_handoff, capture_pending_prediction_buffer_state}
        )) begin
      // An atomically consumed owner makes its upper-half sibling wrong-path.
      // The handoff clear must dominate the older-packet preservation path or
      // that stale sibling can be selected as the first target instruction.
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
  // A BTB prediction can fire on the next word while IF is still outputting the
  // low half of a compressed pair. In that case the upper-half sibling still
  // needs the current buffer state for one more cycle, so preserve only the
  // buffer bookkeeping across the immediate prediction reset. The regular
  // prediction_holdoff in the following cycle still clears the state before the
  // predicted target starts executing.

  // i_slot2_valid arrives late, from alignment and holdoff arbitration, so
  // compute the next buffer-valid state for both of its values, including the
  // pending handoff clear, and select last. prev_was_compressed_at_lo_without_handoff
  // (the next state before the handoff clear) feeds only the simulation check.
  logic prev_was_compressed_at_lo_without_handoff;
  logic [1:0] prev_without_handoff_cases;
  (* keep = "true" *) logic [1:0] prev_compressed_next_cases;
  logic prev_compressed_next;
  for (genvar slot2 = 0; slot2 < 2; slot2++) begin : gen_buffer_slot2_case
    always_comb begin
      prev_without_handoff_cases[slot2] = o_prev_was_compressed_at_lo;
      if (i_reset || i_control_flow_holdoff || i_flush || i_prediction_holdoff ||
        prediction_reset_buffer_state) begin
        prev_without_handoff_cases[slot2] = capture_pending_prediction_buffer;
      end else if (!i_stall && (i_fetch_progress || use_saved_values) && !i_any_holdoff_safe &&
                 !pending_prediction_target_holdoff_needs_buffer &&
                 !i_pending_prediction_active) begin
        // Slot 2 has already consumed the upper sibling when both parcels emit.
        prev_without_handoff_cases[slot2] = is_compressed_for_buffer && !i_pc_reg[1] && !slot2;
      end
    end

    assign prev_compressed_next_cases[slot2] =
        prev_without_handoff_cases[slot2] && !i_pending_prediction_target_handoff;
  end
  assign prev_was_compressed_at_lo_without_handoff = prev_without_handoff_cases[i_slot2_valid];
  assign prev_compressed_next = prev_compressed_next_cases[i_slot2_valid];

  always_ff @(posedge i_clk) begin
    o_prev_was_compressed_at_lo <= prev_compressed_next;
  end

`ifndef SYNTHESIS
  // Reference priority equation for the next buffer-valid state, checked
  // against the split form every cycle. The check needs no assumptions about
  // upstream controls or the current buffer state, including simultaneous
  // reset, capture, and handoff.
  logic prev_was_compressed_at_lo_priority_ref;
  always_comb begin
    prev_was_compressed_at_lo_priority_ref = o_prev_was_compressed_at_lo;
    if (i_reset || i_control_flow_holdoff || i_flush || i_prediction_holdoff ||
        prediction_reset_buffer_state || i_pending_prediction_target_handoff) begin
      prev_was_compressed_at_lo_priority_ref = 1'b0;
      if (capture_pending_prediction_buffer_state) begin
        prev_was_compressed_at_lo_priority_ref = 1'b1;
      end
    end else if (!i_stall && (i_fetch_progress || use_saved_values) && !i_any_holdoff_safe &&
                 !pending_prediction_target_holdoff_needs_buffer &&
                 !i_pending_prediction_active) begin
      prev_was_compressed_at_lo_priority_ref =
          is_compressed_for_buffer && !i_pc_reg[1] && !i_slot2_valid;
    end
    if (!$isunknown(
            {
              prev_was_compressed_at_lo_priority_ref,
              prev_was_compressed_at_lo_without_handoff,
              i_pending_prediction_target_handoff
            }
        )) begin
      p_buffer_handoff_cofactor_matches_priority :
      assert (prev_was_compressed_at_lo_priority_ref ==
              (prev_was_compressed_at_lo_without_handoff &&
               !i_pending_prediction_target_handoff));
    end
  end
`endif

  // Data register: no reset needed. o_prev_was_compressed_at_lo gates when
  // buffer data is used, and that signal is reset. After reset, buffer data
  // cannot be selected until valid data has been written. Leaving these FFs
  // off the reset tree helps timing and area. Exclude prediction holdoff so
  // stale post-redirect data cannot enter the buffer and later be selected by
  // use_instr_buffer.
  always_ff @(posedge i_clk) begin
    if (!i_stall && (i_fetch_progress || use_saved_values) &&
        (!i_any_holdoff_safe || capture_pending_prediction_buffer) &&
        !i_flush &&
        !pending_prediction_target_holdoff_needs_buffer &&
        (!i_prediction_holdoff || capture_pending_prediction_buffer) &&
        !prediction_reset_buffer_state &&
        (!i_pending_prediction_active || capture_pending_prediction_buffer)) begin
      o_instr_buffer <= effective_instr_for_buffer;
      o_instr_buffer_sideband <= effective_sideband_for_buffer;
      o_instr_buffer_fault <= effective_fault_for_buffer;
    end
  end

`ifdef FORMAL
`ifndef C_EXT_STATE_LOCAL_PROOF
  // With the real producers (the prediction_release and prediction_handoff
  // targets), a pending buffer capture is reachable both with and without a
  // coinciding target handoff. c_ext_buffer_next proves for any inputs that
  // the handoff leaves the buffer's valid state clear, so the owner's raw
  // word may be captured but its wrong-path upper sibling never selected.
  always_ff @(posedge i_clk) begin
    if (!i_reset) begin
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
`endif

`ifdef C_EXT_BUFFER_LOCAL_PROOF
  logic f_buffer_priority_ref;
  always_comb begin
    f_buffer_priority_ref = o_prev_was_compressed_at_lo;
    if (i_reset || i_control_flow_holdoff || i_flush || i_prediction_holdoff ||
        prediction_reset_buffer_state || i_pending_prediction_target_handoff) begin
      f_buffer_priority_ref = 1'b0;
      if (capture_pending_prediction_buffer_state) begin
        f_buffer_priority_ref = 1'b1;
      end
    end else if (!i_stall && (i_fetch_progress || use_saved_values) && !i_any_holdoff_safe &&
                 !pending_prediction_target_holdoff_needs_buffer &&
                 !i_pending_prediction_active) begin
      f_buffer_priority_ref = is_compressed_for_buffer && !i_pc_reg[1] && !i_slot2_valid;
    end
    p_buffer_next_exact : assert (prev_compressed_next == f_buffer_priority_ref);
  end
`endif

endmodule : c_ext_state
