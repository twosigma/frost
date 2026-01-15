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
 * Return Address Stack (RAS) - Function Call/Return Prediction
 *
 * An 8-entry circular buffer for predicting function return addresses.
 * Improves branch prediction for JALR instructions used for function returns.
 *
 * Design:
 * =======
 *   - 8 entries (configurable via RAS_DEPTH parameter)
 *   - Circular buffer with TOS (top-of-stack) pointer
 *   - Checkpointing for speculative execution recovery
 *   - Call detection: JAL/JALR with rd in {x1, x5}
 *   - Return detection: JALR with rs1 in {x1, x5} AND rd = x0
 *   - Coroutine support: JALR with rd in {x1, x5} AND rs1 in {x1, x5} AND rd != rs1
 *
 * Operations:
 * ===========
 *   PUSH: Save link address when function call detected
 *   POP:  Predict return target from TOS
 *   POP_THEN_PUSH: Coroutine pattern - swap return addresses
 *
 * Checkpointing:
 * ==============
 *   On each prediction, the current state (tos, valid_count) is output as a
 *   checkpoint. This checkpoint propagates through the pipeline and is used
 *   for recovery on misprediction from EX stage.
 *
 * TIMING: Uses the same gating signals as the BTB to maintain consistent timing.
 * Push/pop operations are synchronous (registered), lookup is combinational.
 */
module return_address_stack #(
    parameter int unsigned RAS_DEPTH = 8,
    parameter int unsigned RAS_PTR_BITS = $clog2(RAS_DEPTH)
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_stall,

    // Instruction type detection (from ras_detector)
    input logic i_is_call,      // JAL/JALR with rd in {x1, x5} - PUSH
    input logic i_is_return,    // JALR with rs1 in {x1, x5}, rd = x0 - POP
    input logic i_is_coroutine, // JALR with both rd and rs1 as link regs - POP then PUSH

    // Link address to push (pre-computed in IF stage as PC+2/4)
    input logic [riscv_pkg::XLEN-1:0] i_link_address,

    // Prediction gating (same as BTB)
    input logic i_prediction_allowed,
    // BTB-only prediction holdoff: UNUSED - kept for interface compatibility.
    // Previously used to allow RAS pop when BTB predicted, but this caused bugs
    // when trap/mret/branch_taken occurred during holdoff (see pop_allowed comment).
    // Pop now only happens when prediction_allowed is true; recovery handles the rest.
    input logic i_btb_only_prediction_holdoff,

    // Misprediction recovery from EX stage
    input logic i_misprediction,
    input logic [RAS_PTR_BITS-1:0] i_restore_tos,
    input logic [RAS_PTR_BITS:0] i_restore_valid_count,
    input logic i_pop_after_restore,  // Pop after restoring (for returns that triggered restore)

    // Prediction outputs
    output logic o_ras_valid,  // RAS has valid prediction for return
    output logic [riscv_pkg::XLEN-1:0] o_ras_target,  // Predicted return address

    // Checkpoint outputs (to pass through pipeline for recovery)
    output logic [RAS_PTR_BITS-1:0] o_checkpoint_tos,
    output logic [  RAS_PTR_BITS:0] o_checkpoint_valid_count
);

  // ===========================================================================
  // RAS Storage
  // ===========================================================================
  logic [riscv_pkg::XLEN-1:0] ras_stack[RAS_DEPTH];
  logic [RAS_PTR_BITS-1:0] tos;  // Top of stack pointer (points to current top entry)
  logic [RAS_PTR_BITS:0] valid_count;  // Number of valid entries (0 to RAS_DEPTH)

  // ===========================================================================
  // Combinational Signals
  // ===========================================================================
  logic [RAS_PTR_BITS-1:0] tos_plus_one;
  logic [RAS_PTR_BITS-1:0] tos_minus_one;
  logic stack_not_empty;

  assign tos_plus_one = tos + RAS_PTR_BITS'(1);  // Wraps naturally for circular buffer
  assign tos_minus_one = tos - RAS_PTR_BITS'(1);
  assign stack_not_empty = (valid_count != '0);

  // ===========================================================================
  // Operation Selection
  // ===========================================================================
  // Determine what operation to perform this cycle based on instruction type.
  //
  // IMPORTANT: Push must happen on ANY valid call, not gated by prediction_allowed.
  // The prediction_allowed signal uses timing-optimized (delayed) holdoff signals,
  // which can cause missed pushes when holdoff ends. Checkpoint/restore handles
  // any speculative pushes that need to be undone on misprediction.
  //
  // Pop operations ARE gated by prediction_allowed since they're part of making
  // a prediction - if we can't predict, we shouldn't consume a RAS entry.
  //
  // Priority:
  //   1. Coroutine (pop then push) - both return and call semantics
  //   2. Return (pop only) - predict and consume TOS
  //   3. Call (push only) - save link address

  logic do_push, do_pop, do_pop_then_push;

  // Register RAS operation inputs to break the EX->IF timing path into the RAM.
  // Predictions remain combinational; only stack updates are pipelined by 1 cycle.
  logic is_call_r;
  logic is_return_r;
  logic is_coroutine_r;
  logic prediction_allowed_r;
  logic [riscv_pkg::XLEN-1:0] link_address_r;

  always_ff @(posedge i_clk) begin
    if (i_rst || i_misprediction) begin
      is_call_r <= 1'b0;
      is_return_r <= 1'b0;
      is_coroutine_r <= 1'b0;
      prediction_allowed_r <= 1'b0;
      link_address_r <= '0;
    end else if (!i_stall) begin
      is_call_r <= i_is_call;
      is_return_r <= i_is_return;
      is_coroutine_r <= i_is_coroutine;
      prediction_allowed_r <= i_prediction_allowed;
      link_address_r <= i_link_address;
    end
  end

  // Pop is allowed only when prediction_allowed is true.
  // NOTE: We previously included btb_only_prediction_holdoff here to allow RAS pop
  // when BTB predicted a return. However, this caused a bug: if trap/mret/branch_taken
  // occurs during btb_only_prediction_holdoff, the instruction is flushed before
  // reaching EX stage, so no recovery happens, but RAS already popped, corrupting state.
  // The safe approach is to only pop when prediction_allowed is true (which includes
  // !trap_taken && !mret_taken && !branch_taken gates). For btb_only_prediction_holdoff
  // cases, the pop will happen during recovery in EX stage via ras_pop_after_restore.
  logic pop_allowed;
  logic pop_possible;
  logic is_call_only;
  assign pop_allowed = prediction_allowed_r;
  assign pop_possible = pop_allowed && stack_not_empty;
  assign is_call_only = is_call_r && !is_coroutine_r;

  // Coroutine: pop then push (effectively replaces TOS) - needs pop_possible for pop
  assign do_pop_then_push = is_coroutine_r && pop_possible;

  // Return: pop only (when not coroutine) - needs pop_possible for pop
  assign do_pop = is_return_r && !is_coroutine_r && pop_possible;

  // Call: push only - NOT gated by prediction_allowed (i_is_call includes instruction validity)
  assign do_push = is_call_only;

  // ===========================================================================
  // Prediction Output
  // ===========================================================================
  // Provide predicted return address for returns and coroutines.
  // Valid when stack is not empty and prediction is allowed.

  assign o_ras_valid = (i_is_return || i_is_coroutine) && stack_not_empty && i_prediction_allowed;
  assign o_ras_target = ras_stack[tos];

  // ===========================================================================
  // Checkpoint Output
  // ===========================================================================
  // Output current state for pipeline passthrough. On misprediction, the
  // checkpoint from the mispredicted instruction is used to restore state.

  assign o_checkpoint_tos = tos;
  assign o_checkpoint_valid_count = valid_count;

  // ===========================================================================
  // Stack Update Logic
  // ===========================================================================
  // Update TOS and valid_count based on operation. Recovery from misprediction
  // takes priority over normal operations.

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      tos <= '0;
      valid_count <= '0;
    end else if (i_misprediction) begin
      // Restore checkpoint on misprediction - highest priority
      // If pop_after_restore is set, also decrement for the return that triggered this.
      // This handles:
      // - Non-spanning returns that popped but mispredicted: restore undoes pop, then re-pop
      // - Spanning returns that couldn't pop: restore (noop), then pop
      if (i_pop_after_restore && i_restore_valid_count != '0) begin
        tos <= i_restore_tos - RAS_PTR_BITS'(1);
        valid_count <= i_restore_valid_count - (RAS_PTR_BITS + 1)'(1);
      end else begin
        tos <= i_restore_tos;
        valid_count <= i_restore_valid_count;
      end
    end else if (!i_stall) begin
      if (do_pop_then_push) begin
        // Coroutine: pop then push - TOS stays same position, just update value
        ras_stack[tos] <= link_address_r;
        // valid_count unchanged (pop + push = net zero change)
      end else if (do_push) begin
        // Push: write to next slot, increment TOS
        ras_stack[tos_plus_one] <= link_address_r;
        tos <= tos_plus_one;
        // Increment valid_count if not full (if full, oldest entry overwritten)
        if (valid_count != RAS_DEPTH[RAS_PTR_BITS:0]) begin
          valid_count <= valid_count + (RAS_PTR_BITS + 1)'(1);
        end
      end else if (do_pop) begin
        // Pop: decrement TOS and valid_count
        tos <= tos_minus_one;
        valid_count <= valid_count - (RAS_PTR_BITS + 1)'(1);
      end
    end
  end

endmodule : return_address_stack
