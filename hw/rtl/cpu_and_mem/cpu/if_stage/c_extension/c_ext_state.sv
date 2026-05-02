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
  C-Extension State Controller

  Manages the state machine for RISC-V C-extension (compressed instruction) support:
  - Instruction buffer for consecutive compressed instructions in same word

  This module is purely about state management. It does not perform instruction
  selection or PC updates - those are handled by other modules.

  State updates are blocked during flush to prevent garbage instructions (from the
  old PC path) from corrupting C-extension state. The flush signal is high for
  2 cycles after a control flow change, covering the in-flight instruction latency.
*/
module c_ext_state #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,

    // Pipeline control
    input logic i_reset,
    input logic i_stall,
    input logic i_flush,            // Pipeline flush - block state updates during flush
    input logic i_fence_i_flush,    // FENCE.I flush (registered) - for use_buffer_after_* timing
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
    input logic [31:0] i_effective_instr,     // Current effective instruction word
    input logic [31:0] i_instr_next_word,     // Next word from 64-bit fetch (for spanning buffer)
    // BRAM word order doesn't match pc_reg (bank_sel_r ^ pc_reg[2])
    input logic        i_fetch_word_swapped,
    input logic [31:0] i_pc,                  // Current fetch PC
    input logic [31:0] i_pc_reg,              // Registered PC

    // Instruction type detection (from instruction aligner)
    input logic       i_is_compressed,  // Current parcel is compressed
    input logic       i_sel_nop,        // IF is outputting a stale/invalid bubble this cycle
    input logic [1:0] i_instr_sideband, // Predecode sideband from IMEM BRAM

    // Outputs
    output logic [31:0] o_instr_buffer,
    output logic [31:0] o_next_word_buffer,  // Next word captured alongside buffer (for spanning)
    output logic o_prev_was_compressed_at_lo,
    output logic o_is_compressed_for_buffer,  // Stall-restored is_compressed
    output logic o_is_compressed_for_pc,  // Registered is_compressed for PC increment (timing)
    output logic o_use_buffer_after_prediction,  // Use buffer after predicted buffered instruction
    output logic o_is_compressed_saved,  // Saved is_compressed for fast path
    output logic o_saved_values_valid,  // Saved values are valid (not invalidated by control flow)
    output logic [1:0] o_instr_buffer_sideband  // Predecode sideband for instruction buffer
);

  // ===========================================================================
  // Stall State Preservation
  // ===========================================================================
  // Save state at stall start for restoration.

  logic [31:0] effective_instr_saved;
  logic [31:0] next_word_saved;  // BRAM next-word saved at stall start (for spanning)
  logic        is_compressed_saved;
  logic [ 1:0] sideband_saved;  // Predecode sideband saved at stall start
  logic        saved_values_valid;  // Track if saved values are valid (not invalidated by flush)
  logic        invalidate_saved_values_holdoff;
  logic        capture_valid_stall_values;
  logic        is_compressed_for_pc_capture;
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
      next_word_saved       <= '0;
      is_compressed_saved   <= 1'b0;
      sideband_saved        <= 2'b0;
    end else if (i_stall & ~i_stall_registered) begin
      if (capture_valid_stall_values) begin
        // Save real instructions at stall start.
        effective_instr_saved <= i_effective_instr;
        next_word_saved       <= i_instr_next_word;
        is_compressed_saved   <= i_is_compressed;
        sideband_saved        <= i_instr_sideband;
      end else begin
        effective_instr_saved <= '0;
        next_word_saved       <= '0;
        is_compressed_saved   <= 1'b0;
        sideband_saved        <= 2'b0;
      end
    end else if (invalidate_saved_values_holdoff) begin
      effective_instr_saved <= '0;
      next_word_saved       <= '0;
      is_compressed_saved   <= 1'b0;
      sideband_saved        <= 2'b0;
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

  assign effective_instr_for_buffer = use_saved_values ? effective_instr_saved : i_effective_instr;

  // Next-word mux: use saved next_word when restoring from stall, live BRAM otherwise.
  // At stall start the BRAM is aligned with pc_reg; during the stall o_pc advances
  // and the BRAM output changes. The saved snapshot preserves the correct pairing.
  logic [31:0] effective_next_word_for_buffer;
  assign effective_next_word_for_buffer = use_saved_values ? next_word_saved : i_instr_next_word;

  // Sideband mux: use saved sideband when restoring from stall, live BRAM sideband otherwise
  logic [1:0] effective_sideband_for_buffer;
  assign effective_sideband_for_buffer = use_saved_values ? sideband_saved : i_instr_sideband;
  assign is_compressed_for_buffer = use_saved_values ? is_compressed_saved : i_is_compressed;
  assign preserve_lo_compressed_buffer_on_prediction =
      i_prediction_reset_state &&
      is_compressed_for_buffer &&
      !i_pc_reg[1];
  assign capture_pending_prediction_buffer =
      i_pending_prediction_active &&
      i_prediction_holdoff &&
      is_compressed_for_buffer &&
      !i_pc_reg[1];
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

  // TIMING OPTIMIZATION: !i_fence_i_flush instead of !i_flush (same rationale
  // as the original code — breaks mispredict → flush → is_compressed path).
  assign o_use_buffer_after_prediction =
      ((prediction_from_buffer_holdoff_prev && !i_prediction_from_buffer_holdoff) ||
       (pending_prediction_target_holdoff_prev &&
        !i_pending_prediction_target_holdoff)) &&
      !i_fence_i_flush &&
      !i_control_flow_holdoff &&
      !i_prediction_holdoff &&
      !i_prediction_reset_state;

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
      if (capture_pending_prediction_buffer) begin
        o_prev_was_compressed_at_lo <= 1'b1;
      end
    end else if (!i_stall && !i_any_holdoff_safe &&
                 !pending_prediction_target_holdoff_needs_buffer &&
                 !i_prediction_from_buffer_holdoff &&
                 !o_use_buffer_after_prediction &&
                 !i_pending_prediction_active) begin
      o_prev_was_compressed_at_lo <= is_compressed_for_buffer && !i_pc_reg[1];
    end
  end

  // Data register: no reset needed. The control signal o_prev_was_compressed_at_lo gates
  // when buffer data is used, and that signal IS properly reset. After reset, buffer data
  // cannot be selected until valid data has been written. Removing reset from these 32 FFs
  // improves timing/area by eliminating reset tree connectivity.
  // CRITICAL: Include !i_prediction_holdoff to prevent stale instruction data from corrupting
  // the buffer after a prediction redirect. Without this, stale data could be read later
  // when use_instr_buffer is true.
  always_ff @(posedge i_clk) begin
    if (!i_stall && (!i_any_holdoff_safe || capture_pending_prediction_buffer) &&
        !i_flush &&
        !pending_prediction_target_holdoff_needs_buffer &&
        (!i_prediction_holdoff || capture_pending_prediction_buffer) &&
        !i_prediction_from_buffer_holdoff &&
        !prediction_reset_buffer_state &&
        !o_use_buffer_after_prediction &&
        (!i_pending_prediction_active || capture_pending_prediction_buffer)) begin
      o_instr_buffer <= effective_instr_for_buffer;
      o_instr_buffer_sideband <= effective_sideband_for_buffer;
      // Capture the next word from the 64-bit fetch for later spanning assembly.
      // Three hazards prevent updating next_word_buffer:
      //   1. Buffer-active cycles (prev_was_compressed_at_lo && pc_reg[1]):
      //      BRAM is at the fetch lead, not pc_reg's word pair.
      //   2. Fetch-word-swapped cycles (bank_sel_r != pc_reg[2]):
      //      BRAM is one word behind (F=W-1); it has word(W) but NOT word(W+1).
      //      The parity fix selects word(W) for decoding, but the other BRAM half
      //      is word(W-1), not word(W+1). Updating would corrupt the buffer.
      //   3. Stall recovery: effective_next_word_for_buffer uses the snapshot
      //      taken at stall start (before BRAM shifted during the stall).
      // Only update when the instruction buffer is NOT active and the BRAM
      // is correctly aligned.  When the buffer IS active or the BRAM is
      // misaligned, skip the update to preserve the previous correct value.
      // Stall recovery bypasses the alignment check since the saved snapshot
      // was taken when the BRAM was aligned at stall start.
      if (!(o_prev_was_compressed_at_lo && i_pc_reg[1]) &&
          (!i_fetch_word_swapped || use_saved_values))
        o_next_word_buffer <= effective_next_word_for_buffer;
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

endmodule : c_ext_state
