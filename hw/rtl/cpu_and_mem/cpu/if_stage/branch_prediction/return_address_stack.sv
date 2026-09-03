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
 * Return address stack: predicts the target of JALR returns.
 *
 * RAS_DEPTH entries (8 by default) held in a circular buffer addressed by a
 * top-of-stack pointer. ras_detector classifies the IF instruction and drives
 * the three operation inputs:
 *
 *   call       JAL/JALR with rd in {x1, x5}                     push
 *   return     JALR with rs1 = x1, rd = x0, imm = 0             pop
 *   coroutine  JALR with rd in {x1, x5}, rs1 = x1, rd != rs1,   pop then push
 *              imm = 0 (32-bit only; C.JALR is always a call)
 *
 * tos and valid_count are exposed as a checkpoint. The pipeline carries the
 * checkpoint alongside the instruction and hands it back on i_restore_* when
 * EX reports a misprediction, which rewinds the speculative pushes and pops.
 *
 * Push and pop are registered; the lookup is combinational. Gating uses the
 * same signals as the BTB, so the two predictors keep the same timing.
 */
module return_address_stack #(
    parameter int unsigned RAS_DEPTH = 8,
    parameter int unsigned RAS_PTR_BITS = $clog2(RAS_DEPTH)
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_stall_registered,

    // Instruction type detection (from ras_detector)
    input logic i_is_call,      // JAL/JALR with rd in {x1, x5} - PUSH
    input logic i_is_return,    // JALR with rs1 = x1, rd = x0 - POP
    input logic i_is_coroutine, // JALR with both rd and rs1 as link regs - POP then PUSH

    // Link address to push (pre-computed in IF stage as PC+2/4)
    input logic [riscv_pkg::XLEN-1:0] i_link_address,

    // Prediction gating (same as BTB)
    input logic i_prediction_allowed,
    // Write-side prediction gating with only registered stall state. This keeps
    // the late backend stall cone off the distributed RAM write enable.
    input logic i_prediction_allowed_for_write,
    // BTB-only prediction holdoff: unused, kept for interface compatibility.
    // It used to allow a RAS pop while the BTB predicted, which corrupted the
    // stack when a trap, mret or branch_taken landed during the holdoff (see
    // the pop_allowed comment). A pop now requires prediction_allowed, and
    // recovery handles the rest.
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

  assign tos_plus_one = tos + RAS_PTR_BITS'(1);  // Wraps for the circular buffer
  assign tos_minus_one = tos - RAS_PTR_BITS'(1);
  assign stack_not_empty = (valid_count != '0);

  // ===========================================================================
  // Operation Selection
  // ===========================================================================
  // Push every valid call regardless of prediction_allowed; its delayed
  // holdoff could otherwise miss a push. Checkpoint restore undoes speculative
  // pushes. Pops require prediction_allowed because they consume a prediction.
  //
  // Priority:
  //   1. Coroutine (pop then push) - both return and call semantics
  //   2. Return (pop only) - predict and consume TOS
  //   3. Call (push only) - save link address

  logic do_push, do_pop, do_pop_then_push, do_pop_then_push_write;
  logic capture_op_inputs;
  logic do_restore_push;
  logic restore_swap_req, do_restore_swap;

  // Keep the stack write side independent of the live backend stall signal.
  // During a registered stall, IF replays saved inputs; the stack consumes the
  // replay after stall_registered drops, so calls are still pushed once without
  // placing the dispatch/fullness cone on the RAS RAM write enable.
  assign capture_op_inputs = !i_stall_registered;

  // Do not pop during btb_only_prediction_holdoff: a simultaneous redirect can
  // flush the instruction before EX recovery, leaving the RAS corrupted. EX
  // handles the pop during ras_pop_after_restore.
  logic pop_allowed;
  logic pop_possible;
  logic pop_possible_for_write;
  assign pop_allowed = i_prediction_allowed;
  assign pop_possible = pop_allowed && stack_not_empty;
  assign pop_possible_for_write = i_prediction_allowed_for_write && stack_not_empty;

  // Coroutine: pop then push, which replaces the top entry. The pop half needs
  // a non-empty stack, so both the live and the write-side form require it.
  assign do_pop_then_push = i_is_coroutine && pop_possible;
  assign do_pop_then_push_write = i_is_coroutine && pop_possible_for_write;

  // Return: pop only, when the instruction is not also a coroutine swap.
  assign do_pop = i_is_return && !i_is_coroutine && pop_possible;

  // Push calls on the first cycle they are observed, including stall-entry.
  // Replay after stall does not re-push because capture_op_inputs is false once
  // stall_registered takes over.
  assign do_push = i_is_call && !i_is_coroutine && capture_op_inputs;
  // Coroutine replay after a checkpoint restore.  {pop,push}_after_restore ==
  // 2'b11 is the reserved swap encoding (ex_comb_synthesizer): pop then push,
  // which replaces the restored top entry and leaves the depth unchanged.  An
  // empty restored stack has nothing to pop and IF performs neither half in
  // that case, so suppress the write and leave the checkpoint as restored.
  assign restore_swap_req = i_pop_after_restore && i_push_after_restore;
  assign do_restore_swap = i_misprediction && restore_swap_req && (i_restore_valid_count != '0);
  assign do_restore_push = i_misprediction && i_push_after_restore && !restore_swap_req;

  assign ras_write_enable = !i_rst &&
                            (do_restore_push || do_restore_swap ||
                             (!i_misprediction &&
                              (do_pop_then_push_write || do_push)));
  // The swap writes at the restored TOS, replacing that entry, which mirrors
  // the live coroutine path's write at `tos`. A plain restore-push writes above
  // it. On the normal arm the registered coroutine classification is enough to
  // choose TOS versus TOS+1 whenever WE is asserted: normal WE is either a
  // coroutine replacement or a non-coroutine call push. Keeping the
  // write-permission cone out of the address mux shortens the replicated RAM
  // WADR path and preserves the existing restore priority.
  assign ras_write_address = do_restore_push ? (i_restore_tos + RAS_PTR_BITS'(1)) :
                             do_restore_swap ? i_restore_tos :
                             (i_is_coroutine ? tos : tos_plus_one);
  assign ras_write_data = (do_restore_push || do_restore_swap) ?
                              i_push_address_after_restore : i_link_address;

`ifndef SYNTHESIS
  // Exact oracle for the former normal-address expression. Outside WE the
  // optimized address is unconstrained, and no RAM state can change.
  logic [RAS_PTR_BITS-1:0] ras_write_address_legacy;
  assign ras_write_address_legacy =
      do_restore_push ? (i_restore_tos + RAS_PTR_BITS'(1)) :
      do_restore_swap ? i_restore_tos :
      (do_pop_then_push_write ? tos : tos_plus_one);

  always_comb begin
    if (ras_write_enable && !$isunknown({ras_write_address, ras_write_address_legacy})) begin
      p_ras_write_address_matches_legacy_when_enabled :
      assert (ras_write_address == ras_write_address_legacy);
    end
  end
`endif

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
  // Predicted return address for returns and coroutines, valid whenever the
  // stack is not empty.
  //
  // Return/coroutine predictions must stay aligned with the current IF
  // instruction. Delaying the classification by a cycle makes the RAS
  // predicted-taken metadata and recovery checkpoint attach to the following
  // instruction instead of the return itself, which corrupts commit-time
  // recovery on tightly-packed call/return thunks.
  // o_ras_valid does not gate on i_prediction_allowed. The consumer already
  // does: sel_ras_prediction gates ras_valid with ras_prediction_allowed,
  // which includes prediction_common. Leaving the gate out
  // here keeps o_ras_valid on registered signals, is_return and is_coroutine
  // from the pipelined detector and stack_not_empty from the registered
  // valid_count, which breaks the deep combinational path
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
      // Restore the checkpoint. This takes priority over the normal operations.
      // With pop_after_restore set, also decrement for the return that caused
      // the restore. That covers two cases:
      //   - A non-spanning return that popped and then mispredicted: the
      //     restore undoes the pop, and this re-pops.
      //   - A spanning return that could not pop: the restore is a noop, and
      //     this performs the pop.
      if (restore_swap_req) begin
        // Coroutine replay: pop then push is net-zero on depth and only
        // replaces the top entry, so both pointers stay at the checkpoint.
        // With an empty restored stack IF performs neither half, same result.
        tos <= i_restore_tos;
        valid_count <= i_restore_valid_count;
      end else if (i_pop_after_restore && i_restore_valid_count != '0) begin
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
        // Coroutine: the pop and the push cancel, so TOS keeps its position
        // and valid_count keeps its value.
      end else if (do_push) begin
        tos <= tos_plus_one;
        // A push onto a full stack overwrites the oldest entry, so the count
        // saturates at RAS_DEPTH.
        if (valid_count != RAS_DEPTH[RAS_PTR_BITS:0]) begin
          valid_count <= valid_count + (RAS_PTR_BITS + 1)'(1);
        end
      end else if (do_pop && !i_stall_registered) begin
        tos <= tos_minus_one;
        valid_count <= valid_count - (RAS_PTR_BITS + 1)'(1);
      end
    end
  end

endmodule : return_address_stack
