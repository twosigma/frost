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

  Manages the state machines for RISC-V C-extension (compressed instruction) support:
  1. Spanning instruction handling - 32-bit instructions that cross word boundaries
  2. Instruction buffer - for consecutive compressed instructions in same word

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
    input logic i_stall_registered,

    // Control flow signals (from control flow tracker)
    input logic i_control_flow_holdoff,  // Registered: stale instruction cycle
    input logic i_any_holdoff_safe,  // Holdoff using only registered signals
    input logic i_prediction_holdoff,  // Registered: prediction happened last cycle (clear state)

    // Instruction data
    input logic [31:0] i_effective_instr,  // Current effective instruction word
    input logic [31:0] i_pc_reg,           // Registered PC

    // Instruction type detection (from instruction aligner)
    input logic i_is_compressed,     // Current parcel is compressed
    input logic i_is_32bit_spanning, // Detected spanning this cycle

    // Outputs
    output logic o_spanning_wait_for_fetch,
    output logic o_spanning_in_progress,
    output logic [15:0] o_spanning_buffer,
    output logic [15:0] o_spanning_second_half,
    output logic [XLEN-1:0] o_spanning_pc,
    output logic [31:0] o_instr_buffer,
    output logic o_prev_was_compressed_at_lo,
    output logic o_spanning_to_halfword,
    output logic o_spanning_to_halfword_registered,
    output logic o_is_compressed_for_buffer,  // Stall-restored is_compressed
    output logic o_is_compressed_for_pc,  // Registered is_compressed for PC increment (timing)
    output logic o_use_buffer_after_spanning  // Use buffer after spanning_to_halfword holdoff
);

  // ===========================================================================
  // Spanning Instruction State Machine
  // ===========================================================================
  // Three states:
  //   1. is_32bit_spanning (input): Detected spanning, save first half, advance PC
  //   2. spanning_wait_for_fetch: Waiting for BRAM to return second word
  //   3. spanning_in_progress: Second word available, combine and output

  logic spanning_in_progress_next;

  // Compute next state for spanning_in_progress
  // TIMING OPTIMIZATION: Removed i_flush check to break timing path from branch_taken.
  // State will be cleared on next cycle via control_flow_holdoff (in any_holdoff_safe).
  always_comb begin
    spanning_in_progress_next = 1'b0;
    if (!i_stall && !i_reset && !i_any_holdoff_safe) begin
      spanning_in_progress_next = o_spanning_wait_for_fetch;
    end
  end

  // ===========================================================================
  // Stall State Preservation (needed before spanning state machine)
  // ===========================================================================
  // Save state at stall start for restoration. This must be defined before the
  // spanning state machine because instr_lo/instr_hi use effective_instr_for_buffer.

  logic [31:0] effective_instr_saved;
  logic        is_compressed_saved;
  logic        saved_values_valid;  // Track if saved values are valid (not invalidated by flush)

  // TIMING OPTIMIZATION: Use registered i_control_flow_holdoff instead of combinational
  // i_flush to break the critical path from branch_taken. The state will be cleared
  // one cycle later, but that's functionally safe because:
  // 1. During the flush cycle, saved values are gated by flush elsewhere anyway
  // 2. The following cycle, i_control_flow_holdoff clears the state
  // Note: i_prediction_holdoff is already registered (from branch_prediction_controller).
  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      effective_instr_saved <= '0;
      is_compressed_saved <= 1'b0;
      saved_values_valid <= 1'b0;
    end else if (i_control_flow_holdoff || i_prediction_holdoff) begin
      // Registered control flow change invalidates saved values.
      // We've jumped to a different PC, so saved values are stale.
      // Also clear the data to prevent any stale data from persisting.
      effective_instr_saved <= '0;
      is_compressed_saved <= 1'b0;
      saved_values_valid <= 1'b0;
    end else if (i_stall & ~i_stall_registered) begin
      // Save at stall start
      effective_instr_saved <= i_effective_instr;
      is_compressed_saved <= i_is_compressed;
      saved_values_valid <= 1'b1;
    end
  end

  // Use saved values when coming out of stall.
  //
  // TIMING OPTIMIZATION: Use only registered signals for the mux select to break
  // the critical timing path from trap_taken → stall → is_compressed_for_buffer → PC.
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

  assign effective_instr_for_buffer = use_saved_values ? effective_instr_saved : i_effective_instr;
  assign is_compressed_for_buffer   = use_saved_values ? is_compressed_saved : i_is_compressed;

  // Export stall-restored is_compressed for use by pc_controller and spanning detection
  assign o_is_compressed_for_buffer = is_compressed_for_buffer;

  // Extract instruction halves for spanning
  // Use effective_instr_for_buffer to handle stall restoration correctly.
  logic [15:0] instr_lo, instr_hi;
  assign instr_lo = effective_instr_for_buffer[15:0];
  assign instr_hi = effective_instr_for_buffer[31:16];

  // Spanning state register updates
  // TIMING OPTIMIZATION: Removed combinational i_flush check. The registered
  // i_control_flow_holdoff and i_prediction_holdoff handle state clearing safely.
  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      o_spanning_wait_for_fetch <= 1'b0;
      o_spanning_in_progress <= 1'b0;
      o_spanning_buffer <= 16'b0;
      o_spanning_second_half <= 16'b0;
      o_spanning_pc <= '0;
    end else if (i_control_flow_holdoff || i_prediction_holdoff) begin
      // Cancel spanning on control flow change or prediction
      // control_flow_holdoff is registered to break timing path from branch_taken
      // i_prediction_holdoff clears stale state after branch prediction redirect
      // Also clear data buffers to prevent any stale data from persisting
      o_spanning_wait_for_fetch <= 1'b0;
      o_spanning_in_progress <= 1'b0;
      o_spanning_buffer <= 16'b0;
      o_spanning_second_half <= 16'b0;
      o_spanning_pc <= '0;
    end else if (!i_stall && !i_any_holdoff_safe) begin
      // State transitions
      o_spanning_wait_for_fetch <= i_is_32bit_spanning && !o_spanning_wait_for_fetch;
      o_spanning_in_progress <= spanning_in_progress_next;

      if (i_is_32bit_spanning && !o_spanning_wait_for_fetch) begin
        // Save upper 16 bits and PC when first detecting spanning
        o_spanning_buffer <= instr_hi;
        o_spanning_pc <= i_pc_reg;
      end

      if (o_spanning_wait_for_fetch) begin
        // During wait cycle, memory returns second word - save lower half
        o_spanning_second_half <= instr_lo;
      end
    end
  end

  // ===========================================================================
  // Spanning to Halfword Detection
  // ===========================================================================
  // Detect when completing a spanning instruction leads to another halfword PC.
  // This requires an extra holdoff cycle for the correct word to be fetched.
  //
  // After the holdoff cycle, we need to use the instruction buffer (which was
  // preserved during spanning_in_progress) because BRAM has advanced past the
  // word we need.

  logic [XLEN-1:0] next_pc_after_spanning;
  assign next_pc_after_spanning = i_pc_reg + riscv_pkg::PcIncrement32bit;
  assign o_spanning_to_halfword = o_spanning_in_progress && next_pc_after_spanning[1];

  // TIMING OPTIMIZATION: Use registered i_control_flow_holdoff instead of combinational
  // i_flush to break the critical path from branch_taken.
  always_ff @(posedge i_clk) begin
    if (i_reset || i_control_flow_holdoff) o_spanning_to_halfword_registered <= 1'b0;
    else if (!i_stall) o_spanning_to_halfword_registered <= o_spanning_to_halfword;
  end

  // Track when we're coming out of spanning_to_halfword holdoff.
  // On this cycle, we need to use the instruction buffer because BRAM has
  // advanced past the word containing the next instruction.
  logic spanning_to_halfword_registered_prev;
  always_ff @(posedge i_clk) begin
    if (i_reset || i_control_flow_holdoff) spanning_to_halfword_registered_prev <= 1'b0;
    else if (!i_stall) spanning_to_halfword_registered_prev <= o_spanning_to_halfword_registered;
  end

  // Use buffer on the cycle immediately after spanning_to_halfword holdoff ends
  assign o_use_buffer_after_spanning = spanning_to_halfword_registered_prev &&
                                       !o_spanning_to_halfword_registered;

  // ===========================================================================
  // Instruction Buffer State Machine
  // ===========================================================================
  // Buffer the current word when processing a compressed instruction at instr_lo,
  // so the next instruction (at instr_hi) can access the same word.
  //
  // Note: The stall state preservation logic (effective_instr_saved, just_unstalled,
  // effective_instr_for_buffer, etc.) is defined earlier in the file because the
  // spanning state machine needs instr_lo/instr_hi which depend on it.

  // Buffer state register updates
  // Note: Block updates during spanning_to_halfword (combinational) to preserve the buffer
  // for the next instruction after a spanning instruction that ends at a halfword boundary.
  // The buffer contains the word needed for the upper-half instruction.

  // Control register: must be reset and cleared on control flow changes
  always_ff @(posedge i_clk) begin
    if (i_reset || i_control_flow_holdoff || i_flush || i_prediction_holdoff) begin
      o_prev_was_compressed_at_lo <= 1'b0;
    end else if (!i_stall && !i_any_holdoff_safe && !o_spanning_to_halfword) begin
      o_prev_was_compressed_at_lo <= is_compressed_for_buffer &&
                                     !i_pc_reg[1] &&
                                     !o_spanning_in_progress;
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
    if (!i_stall && !i_any_holdoff_safe && !o_spanning_to_halfword && !i_prediction_holdoff) begin
      o_instr_buffer <= effective_instr_for_buffer;
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
  // Functional correctness: The PC increment only matters for sequential execution.
  // When control flow changes (branch, trap, prediction), we select a different
  // target and the sequential PC value is discarded. On holdoff cycles, we force
  // pc_increment=4 anyway. So using a 1-cycle-stale is_compressed is safe.
  //
  // Reset to 0 (assume 32-bit = increment by 4) for conservative behavior.
  // TIMING OPTIMIZATION: Removed combinational i_flush to break path from branch_taken.
  always_ff @(posedge i_clk) begin
    if (i_reset || i_control_flow_holdoff || i_prediction_holdoff) begin
      o_is_compressed_for_pc <= 1'b0;
    end else if (!i_stall) begin
      o_is_compressed_for_pc <= is_compressed_for_buffer;
    end
  end

endmodule : c_ext_state
