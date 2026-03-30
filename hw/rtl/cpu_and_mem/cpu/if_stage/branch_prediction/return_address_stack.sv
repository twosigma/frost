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
    input logic i_stall_registered,

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
    input logic i_push_after_restore,  // Push after restoring (for calls that triggered restore)
    input logic [riscv_pkg::XLEN-1:0] i_push_address_after_restore,

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
  logic [riscv_pkg::XLEN-1:0] ras_read_data;
  logic ras_write_enable;
  logic [RAS_PTR_BITS-1:0] ras_write_address;
  logic [riscv_pkg::XLEN-1:0] ras_write_data;
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
  logic capture_op_inputs;
  logic do_restore_push;

  // Capture call/return classification on the stall-entry cycle as well as on
  // normal advancing cycles. IF replays that same instruction from saved
  // values after the stall, so dropping the stall-entry classification loses
  // the corresponding push/pop entirely.
  assign capture_op_inputs = !i_stall || (i_stall && !i_stall_registered);

  // Pop is allowed only when prediction is allowed in the current cycle.
  // NOTE: We previously included btb_only_prediction_holdoff here to allow RAS pop
  // when BTB predicted a return. However, this caused a bug: if trap/mret/branch_taken
  // occurs during btb_only_prediction_holdoff, the instruction is flushed before
  // reaching EX stage, so no recovery happens, but RAS already popped, corrupting state.
  // For btb_only_prediction_holdoff cases, the pop will happen during recovery
  // in EX stage via ras_pop_after_restore.
  logic pop_allowed;
  logic pop_possible;
  assign pop_allowed = i_prediction_allowed;
  assign pop_possible = pop_allowed && stack_not_empty;

  // Coroutine: pop then push (effectively replaces TOS) - needs pop_possible for pop
  assign do_pop_then_push = i_is_coroutine && pop_possible;

  // Return: pop only (when not coroutine) - needs pop_possible for pop
  assign do_pop = i_is_return && !i_is_coroutine && pop_possible;

  // Push calls on the first cycle they are observed, including stall-entry.
  // Replay after stall does not re-push because capture_op_inputs is false once
  // stall_registered takes over.
  assign do_push = i_is_call && !i_is_coroutine && capture_op_inputs;
  assign do_restore_push = i_misprediction && i_push_after_restore;

  assign ras_write_enable = !i_rst &&
                            (do_restore_push ||
                             (!i_misprediction &&
                              ((do_pop_then_push && !i_stall_registered) || do_push)));
  assign ras_write_address = do_restore_push ? (i_restore_tos + RAS_PTR_BITS'(1)) :
                             (do_pop_then_push ? tos : tos_plus_one);
  assign ras_write_data = do_restore_push ? i_push_address_after_restore : i_link_address;

  sdp_dist_ram #(
      .ADDR_WIDTH(RAS_PTR_BITS),
      .DATA_WIDTH(riscv_pkg::XLEN)
  ) ras_ram (
      .i_clk,
      .i_write_enable(ras_write_enable),
      .i_write_address(ras_write_address),
      .i_write_data(ras_write_data),
      .i_read_address(tos),
      .o_read_data(ras_read_data)
  );

  // ===========================================================================
  // Prediction Output
  // ===========================================================================
  // Provide predicted return address for returns and coroutines.
  // Valid when stack is not empty and prediction is allowed.
  //
  // Return/coroutine predictions must stay aligned with the current IF
  // instruction. Delaying the classification by a cycle makes the RAS
  // predicted-taken metadata and recovery checkpoint attach to the following
  // instruction instead of the return itself, which corrupts commit-time
  // recovery on tightly-packed call/return thunks.
  // TIMING OPTIMIZATION: Removed i_prediction_allowed from o_ras_valid.
  // It was redundant: sel_ras_prediction = ras_prediction_allowed && ras_valid
  // already gates on ras_prediction_allowed (which includes prediction_common).
  // Removing it here makes o_ras_valid depend only on registered signals
  // (is_return/is_coroutine from pipelined detector, stack_not_empty from
  // registered valid_count), breaking the deep combinational path:
  // prediction_common → ras_prediction_allowed → o_ras_valid → sel_ras_prediction
  assign o_ras_valid = (i_is_return || i_is_coroutine) && stack_not_empty;
  assign o_ras_target = ras_read_data;

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
      end else if (i_push_after_restore) begin
        tos <= i_restore_tos + RAS_PTR_BITS'(1);
        if (i_restore_valid_count != RAS_DEPTH[RAS_PTR_BITS:0]) begin
          valid_count <= i_restore_valid_count + (RAS_PTR_BITS + 1)'(1);
        end else begin
          valid_count <= i_restore_valid_count;
        end
      end else begin
        tos <= i_restore_tos;
        valid_count <= i_restore_valid_count;
      end
    end else begin
      if (do_pop_then_push && !i_stall_registered) begin
        // Coroutine: pop then push - TOS stays same position
        // valid_count unchanged (pop + push = net zero change)
      end else if (do_push) begin
        // Push: write to next slot, increment TOS
        tos <= tos_plus_one;
        // Increment valid_count if not full (if full, oldest entry overwritten)
        if (valid_count != RAS_DEPTH[RAS_PTR_BITS:0]) begin
          valid_count <= valid_count + (RAS_PTR_BITS + 1)'(1);
        end
      end else if (do_pop && !i_stall_registered) begin
        // Pop: decrement TOS and valid_count
        tos <= tos_minus_one;
        valid_count <= valid_count - (RAS_PTR_BITS + 1)'(1);
      end
    end
  end

endmodule : return_address_stack
