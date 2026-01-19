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
 * Branch Redirect Unit for RISC-V Pipeline
 *
 * This combinational module handles branch prediction verification and misprediction
 * recovery for the EX stage. It combines BTB and RAS predictions, detects mispredictions,
 * and generates redirect/recovery signals.
 *
 * Functionality:
 *   - BTB prediction verification (for both JALR and non-JALR instructions)
 *   - RAS prediction verification (for return instructions)
 *   - Misprediction detection and redirect target selection
 *   - BTB update signal generation
 *   - RAS recovery signal generation
 *
 * TIMING OPTIMIZATIONS:
 * Multiple values are pre-computed in ID stage to reduce EX critical path:
 *   - is_ras_return, is_ras_call: Pre-computed RAS instruction detection
 *   - ras_expected_rs1, btb_expected_rs1: Algebraic transformation for target verification
 *   - btb_correct_non_jalr: Pre-computed BTB correctness for PC-relative instructions
 *   - ras_predicted_target_nonzero: Pre-computed zero check
 */
module branch_redirect_unit #(
    parameter int unsigned XLEN = 32,
    parameter int unsigned RasPtrBits = 3
) (
    // Instruction info from ID stage
    input logic                        [XLEN-1:0] i_program_counter,
    input logic                        [XLEN-1:0] i_link_address,
    input logic                                   i_is_jump_and_link,
    input logic                                   i_is_jump_and_link_register,
    input riscv_pkg::branch_taken_op_e            i_branch_operation,

    // Forwarded operand value
    input logic [XLEN-1:0] i_forwarded_rs1,

    // Branch/jump resolution from branch_jump_unit
    input logic            i_actual_branch_taken,
    input logic [XLEN-1:0] i_actual_branch_target,

    // BTB prediction metadata
    input logic            i_btb_predicted_taken,
    input logic [XLEN-1:0] i_btb_predicted_target,

    // RAS prediction metadata
    input logic                  i_ras_predicted,
    input logic [      XLEN-1:0] i_ras_predicted_target,
    input logic [RasPtrBits-1:0] i_ras_checkpoint_tos,
    input logic [  RasPtrBits:0] i_ras_checkpoint_valid_count,

    // Pre-computed values from ID stage (timing optimizations)
    input logic            i_is_ras_return,
    input logic            i_is_ras_call,
    input logic            i_ras_predicted_target_nonzero,
    input logic [XLEN-1:0] i_ras_expected_rs1,
    input logic            i_btb_correct_non_jalr,
    input logic [XLEN-1:0] i_btb_expected_rs1,

    // Redirect outputs
    output logic            o_branch_taken,
    output logic [XLEN-1:0] o_branch_target_address,

    // BTB update outputs
    output logic            o_btb_update,
    output logic [XLEN-1:0] o_btb_update_pc,
    output logic [XLEN-1:0] o_btb_update_target,
    output logic            o_btb_update_taken,

    // RAS recovery outputs
    output logic                  o_ras_misprediction,
    output logic [RasPtrBits-1:0] o_ras_restore_tos,
    output logic [  RasPtrBits:0] o_ras_restore_valid_count,
    output logic                  o_ras_pop_after_restore
);

  // ===========================================================================
  // Branch Prediction Misprediction Recovery
  // ===========================================================================
  // Redirect is needed only when the predicted path differs from the actual path.
  //
  // Cases:
  //   1. Not predicted, not taken     -> No redirect (correct)
  //   2. Not predicted, taken         -> Redirect to actual target
  //   3. Predicted taken, taken same  -> No redirect (correct prediction!)
  //   4. Predicted taken, taken diff  -> Redirect to actual target
  //   5. Predicted taken, not taken   -> Redirect to sequential PC (link_address)
  //
  // Key insight: If we predicted taken correctly (same target), we're already on
  // the right path and should NOT flush the pipeline.

  logic predicted_taken;
  // Include RAS predictions in predicted_taken
  assign predicted_taken = i_btb_predicted_taken || i_ras_predicted;

  // Correct prediction: predicted taken AND actually taken to same target
  // Check both BTB and RAS predictions
  //
  // TIMING OPTIMIZATION: BTB comparison uses pre-computed values from ID stage.
  // For JALR: Compare forwarded_rs1 with btb_expected_rs1 (= btb_predicted_target - imm)
  //   This removes the JALR adder (3 CARRY8 chains) from the critical path.
  //   Math: (rs1 + imm == predicted) iff (rs1 == predicted - imm)
  // For non-JALR (JAL/branches): Target comparison is pre-computed in ID stage
  //   (btb_correct_non_jalr flag). No EX stage target comparison needed.
  //
  // Note: For JALR, actual_branch_taken is always true (unconditional jump).
  logic btb_correct_for_jalr;
  assign btb_correct_for_jalr = i_btb_predicted_taken &&
                                i_is_jump_and_link_register &&
                                (i_forwarded_rs1 == i_btb_expected_rs1);

  logic btb_correct_for_non_jalr;
  assign btb_correct_for_non_jalr = i_btb_predicted_taken &&
                                    !i_is_jump_and_link_register &&
                                    i_actual_branch_taken &&
                                    i_btb_correct_non_jalr;

  logic btb_correct;
  assign btb_correct = btb_correct_for_jalr || btb_correct_for_non_jalr;

  logic ras_correct;
  // RAS correct requires: IF detected return (ras_predicted), EX confirms return (is_ras_return),
  // target matches prediction, AND target is non-zero (valid).
  // The non-zero check guards against stale zero-initialized values in the pipeline.
  //
  // TIMING OPTIMIZATION: Multiple optimizations to reduce EX stage critical path:
  // 1. is_ras_return and ras_predicted_target_nonzero are pre-computed in ID stage
  // 2. Instead of (actual_branch_target == ras_predicted_target), we compare
  //    (forwarded_rs1 == ras_expected_rs1) where ras_expected_rs1 = predicted_target - imm
  //    This removes the JALR adder (CARRY8 chain) from the comparison critical path.
  //    Math: actual_target = rs1 + imm, so (rs1 + imm == predicted) iff (rs1 == predicted - imm)
  // 3. Removed actual_branch_taken from the AND chain - it's redundant because:
  //    is_ras_return implies the instruction is a JALR, and JALR always "takes" (unconditional).
  assign ras_correct = i_ras_predicted &&
                       i_is_ras_return &&
                       (i_forwarded_rs1 == i_ras_expected_rs1) &&
                       i_ras_predicted_target_nonzero;

  logic correct_prediction;
  // Include both BTB and RAS correct predictions
  assign correct_prediction = btb_correct || ras_correct;

  // Need redirect when:
  // - Actual branch taken but prediction was wrong (not predicted, or wrong target)
  // - Predicted taken but actually not taken
  //
  // TIMING OPTIMIZATION: Separate JALR and non-JALR paths.
  // For JALR: actual_branch_taken is always true (unconditional jump), so we can
  // compute need_redirect directly from btb_correct_for_jalr and ras_correct without
  // waiting for actual_branch_taken. This removes actual_branch_taken from the
  // JALR critical path.
  // For non-JALR: need actual_branch_taken for branch condition evaluation.
  logic need_redirect_jalr;
  assign need_redirect_jalr = i_is_jump_and_link_register && !btb_correct_for_jalr && !ras_correct;

  logic need_redirect_non_jalr;
  assign need_redirect_non_jalr = !i_is_jump_and_link_register &&
                                  ((i_actual_branch_taken && !btb_correct_for_non_jalr) ||
                                   (predicted_taken && !i_actual_branch_taken));

  logic need_redirect;
  assign need_redirect = need_redirect_jalr || need_redirect_non_jalr;

  // Redirect target:
  // - If predicted taken but not taken: sequential PC (link_address)
  // - Otherwise: actual branch target
  assign o_branch_taken = need_redirect;
  assign o_branch_target_address = (predicted_taken && !i_actual_branch_taken) ?
                                   i_link_address :
                                   i_actual_branch_target;

  // ===========================================================================
  // BTB Update Logic (Branch Prediction)
  // ===========================================================================
  // Update BTB when a branch or jump instruction resolves.
  // This includes: conditional branches (BEQ, BNE, etc.), JAL, JALR.
  // Note: NULL branch_operation indicates no branch/jump instruction.
  //
  // IMPORTANT: Use actual_branch_taken/actual_branch_target for BTB update,
  // NOT the combined signals that include misprediction recovery redirect.
  // The BTB should learn the true branch behavior, not the recovery action.

  logic is_branch_or_jump;
  assign is_branch_or_jump = (i_branch_operation != riscv_pkg::NULL) ||
                             i_is_jump_and_link ||
                             i_is_jump_and_link_register;

  // Detect false prediction: BTB predicted taken, but instruction is not a branch/jump.
  // This can happen due to BTB aliasing (different instruction with same index/tag).
  // We must update the BTB to clear this stale entry, otherwise the same false
  // prediction will repeat indefinitely.
  logic btb_false_prediction;
  assign btb_false_prediction = i_btb_predicted_taken && !is_branch_or_jump;

  // Update BTB when:
  // 1. Any branch/jump instruction resolves (normal case - learn actual outcome)
  // 2. Non-branch was falsely predicted as taken (clear stale prediction)
  assign o_btb_update = is_branch_or_jump || btb_false_prediction;
  assign o_btb_update_pc = i_program_counter;
  assign o_btb_update_target = i_actual_branch_target;
  // For false predictions on non-branches, mark as not-taken to prevent repeated mispredictions
  assign o_btb_update_taken = is_branch_or_jump ? i_actual_branch_taken : 1'b0;

  // ===========================================================================
  // RAS (Return Address Stack) Misprediction Detection
  // ===========================================================================
  // Detect when RAS prediction was wrong and signal recovery.
  //
  // RAS misprediction occurs when:
  //   1. RAS predicted a return address (ras_predicted = 1), AND
  //   2. Either:
  //      a. The instruction is actually a return but target differs, OR
  //      b. The instruction is not actually a return (false positive)
  //
  // Recovery: Restore RAS state from checkpoint passed through pipeline.

  // Detect if current instruction is actually a return (JALR with rs1 = x1/x5, rd = x0)
  // TIMING OPTIMIZATION: Use pre-computed flag from ID stage instead of inline computation.
  // This removes (rs1 == x1/x5), (rd == x0), and (imm == 0) comparisons from EX critical path.
  logic actual_is_return;
  assign actual_is_return = i_is_ras_return;

  // Detect if current instruction is actually a call (JAL/JALR with rd = x1/x5)
  // Calls push to the RAS and should NOT trigger a restore when they redirect.
  // TIMING OPTIMIZATION: Use pre-computed flag from ID stage.
  logic actual_is_call;
  assign actual_is_call = i_is_ras_call;

  // Output RAS recovery signals
  // Restore RAS on redirects, EXCEPT for call instructions.
  // - Call instructions push to RAS at IF stage. When they reach EX and trigger
  //   a redirect (to jump to the call target), we must NOT restore - the push
  //   was correct and should be kept.
  // - For all other redirects (branch misprediction, trap, RAS misprediction),
  //   we restore from the checkpoint to undo any speculative RAS operations.
  assign o_ras_misprediction = need_redirect && !actual_is_call;
  assign o_ras_restore_tos = i_ras_checkpoint_tos;
  assign o_ras_restore_valid_count = i_ras_checkpoint_valid_count;

  // Pop after restore: When a return instruction triggers ras_misprediction, we need to pop.
  // This handles two cases:
  // - Non-spanning returns that popped in IF but mispredicted: restore undoes pop, then re-pop
  // - Spanning returns that couldn't pop in IF: restore (noop on pop), then pop
  // This ensures every return "consumes" exactly one stack entry.
  // Pop after restore for returns that trigger misprediction (spanning or wrong prediction)
  assign o_ras_pop_after_restore = o_ras_misprediction && actual_is_return;

endmodule : branch_redirect_unit
