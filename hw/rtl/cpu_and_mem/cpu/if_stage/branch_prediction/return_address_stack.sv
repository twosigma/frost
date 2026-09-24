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
 * The operation inputs describe the packet IF registered the cycle before, so
 * the live BTB lookup's slot-1/slot-2 alias check does not gate them. Push and
 * pop update the state at the clock edge; the lookup is combinational. Both
 * the registered state and a next-state checkpoint that includes this cycle's
 * operation are exported. IF gives the next-state form to the younger packet
 * it emits alongside, so recovery keeps older pipelined pushes and pops
 * (hw/rtl/cpu_and_mem/cpu/README.md, "Return address stack recovery").
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
    input logic i_is_coroutine, // JALR with rd = x5, rs1 = x1 - POP then PUSH

    // Link address to push (pre-computed in IF stage as PC+2/4)
    input logic [riscv_pkg::XLEN-1:0] i_link_address,

    // Pop permission; pushes do not depend on it
    input logic i_prediction_allowed,
    // Write-side prediction gating with only registered stall state. This keeps
    // the late backend stall cone off the distributed RAM write enable.
    input logic i_prediction_allowed_for_write,
    // BTB-only prediction holdoff: unused, kept for interface compatibility.
    // Pops are blocked during it through i_prediction_allowed (see
    // pop_allowed).
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

    // Raw checkpoint outputs expose the currently registered state.  The next
    // outputs include the operation that will commit on this edge, for a
    // younger packet being emitted alongside an older pipelined RAS operation.
    output logic [RAS_PTR_BITS-1:0] o_checkpoint_tos,
    output logic [  RAS_PTR_BITS:0] o_checkpoint_valid_count,
    output logic [RAS_PTR_BITS-1:0] o_checkpoint_tos_next,
    output logic [  RAS_PTR_BITS:0] o_checkpoint_valid_count_next
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
  logic [RAS_PTR_BITS-1:0] tos_next;
  logic [RAS_PTR_BITS:0] valid_count_next;

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

  // Do not pop during the BTB-only prediction holdoff: a redirect in the same
  // cycle can flush the instruction before recovery, leaving the stack
  // corrupted. Recovery performs the pop instead (i_pop_after_restore).
  // i_prediction_allowed is low during that holdoff, so it alone gates pops.
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

  // Push a call on any cycle without a registered stall (see
  // capture_op_inputs).
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
  // A restore swap writes at the restored TOS, replacing that entry like the
  // live coroutine's write at `tos`; a restore push writes above it. On the
  // normal path i_is_coroutine alone picks TOS or TOS+1, because a normal
  // write is either a coroutine replacement or a non-coroutine call push.
  // Keeping the write-permission terms out of this mux shortens the RAM
  // write-address path.
  assign ras_write_address = do_restore_push ? (i_restore_tos + RAS_PTR_BITS'(1)) :
                             do_restore_swap ? i_restore_tos :
                             (i_is_coroutine ? tos : tos_plus_one);
  assign ras_write_data = (do_restore_push || do_restore_swap) ?
                              i_push_address_after_restore : i_link_address;

`ifndef SYNTHESIS
  // Reference write address, choosing TOS by do_pop_then_push_write. It must
  // match whenever the write enable is set; otherwise the address has no
  // effect.
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
  // Predicted return address for the return or coroutine on the
  // classification inputs, valid whenever the stack is not empty.
  //
  // o_ras_valid is not gated by i_prediction_allowed; the consumer applies
  // that gate (sel_ras_prediction uses ras_prediction_allowed, which includes
  // prediction_common). Leaving it out keeps o_ras_valid a function of
  // registered signals (the pipelined classification and valid_count), off
  // the prediction_common -> ras_prediction_allowed -> sel_ras_prediction path.
  assign o_ras_valid = (i_is_return || i_is_coroutine) && stack_not_empty;
  assign o_ras_target = ras_read_data;

  // ===========================================================================
  // Checkpoint Output
  // ===========================================================================
  // The raw outputs expose the registered state for diagnostics and tests.
  // The next-state checkpoint is the state after this edge's operation. IF
  // attaches it to the younger packet emitted alongside, so if that packet
  // later mispredicts, an older delayed call stays pushed and an older delayed
  // return stays popped.

  assign o_checkpoint_tos = tos;
  assign o_checkpoint_valid_count = valid_count;
  assign o_checkpoint_tos_next = tos_next;
  assign o_checkpoint_valid_count_next = valid_count_next;

  // ===========================================================================
  // Stack Update Logic
  // ===========================================================================
  // Compute the next state once and use it for both the state flops and the
  // next-state checkpoint, so the two cannot differ. Recovery takes priority
  // over normal operations. i_prediction_allowed arrives late, so compute the
  // next state for both of its values (k = 0 blocks pops, k = 1 allows them)
  // and select once at the end.
  (* keep = "true" *)logic [RAS_PTR_BITS-1:0] tos_candidate  [2];
  (* keep = "true" *)logic [  RAS_PTR_BITS:0] count_candidate[2];
  for (genvar k = 0; k < 2; k++) begin : gen_checkpoint_permission
    always_comb begin
      tos_candidate[k]   = tos;
      count_candidate[k] = valid_count;

      if (i_rst) begin
        tos_candidate[k]   = '0;
        count_candidate[k] = '0;
      end else if (i_misprediction) begin
        // Restore the checkpoint, which excludes the mispredicted instruction's
        // own operation, then apply that operation: pop_after_restore pops for
        // a return, push_after_restore pushes for a call, and both together are
        // a coroutine swap.
        if (restore_swap_req) begin
          // Coroutine replay: pop then push is net-zero on depth and only
          // replaces the top entry, so both pointers stay at the checkpoint.
          // With an empty restored stack IF performs neither half, same result.
          tos_candidate[k]   = i_restore_tos;
          count_candidate[k] = i_restore_valid_count;
        end else if (i_pop_after_restore && i_restore_valid_count != '0) begin
          tos_candidate[k]   = i_restore_tos - RAS_PTR_BITS'(1);
          count_candidate[k] = i_restore_valid_count - (RAS_PTR_BITS + 1)'(1);
        end else if (i_push_after_restore) begin
          tos_candidate[k] = i_restore_tos + RAS_PTR_BITS'(1);
          if (i_restore_valid_count != RAS_DEPTH[RAS_PTR_BITS:0]) begin
            count_candidate[k] = i_restore_valid_count + (RAS_PTR_BITS + 1)'(1);
          end else begin
            count_candidate[k] = i_restore_valid_count;
          end
        end else begin
          tos_candidate[k]   = i_restore_tos;
          count_candidate[k] = i_restore_valid_count;
        end
      end else begin
        if (i_is_coroutine && (k != 0) && stack_not_empty && !i_stall_registered) begin
          // Coroutine: the pop and the push cancel, so TOS keeps its position
          // and valid_count keeps its value.
        end else if (do_push) begin
          tos_candidate[k] = tos_plus_one;
          // A push onto a full stack overwrites the oldest entry, so the count
          // saturates at RAS_DEPTH.
          if (valid_count != RAS_DEPTH[RAS_PTR_BITS:0]) begin
            count_candidate[k] = valid_count + (RAS_PTR_BITS + 1)'(1);
          end
        end else if (i_is_return && !i_is_coroutine && (k != 0) &&
                     stack_not_empty && !i_stall_registered) begin
          tos_candidate[k]   = tos_minus_one;
          count_candidate[k] = valid_count - (RAS_PTR_BITS + 1)'(1);
        end
      end
    end
  end
  assign tos_next = i_prediction_allowed ? tos_candidate[1] : tos_candidate[0];
  assign valid_count_next = i_prediction_allowed ? count_candidate[1] : count_candidate[0];

`ifdef RAS_CHECKPOINT_LOCAL_PROOF
  // Reference next state for the ras_checkpoint formal target: the same
  // priority written once, with do_pop and do_pop_then_push (which include
  // i_prediction_allowed) in place of the two candidates.
  logic [RAS_PTR_BITS-1:0] tos_next_reference;
  logic [  RAS_PTR_BITS:0] valid_count_next_reference;
  always_comb begin
    tos_next_reference = tos;
    valid_count_next_reference = valid_count;

    if (i_rst) begin
      tos_next_reference = '0;
      valid_count_next_reference = '0;
    end else if (i_misprediction) begin
      if (restore_swap_req) begin
        tos_next_reference = i_restore_tos;
        valid_count_next_reference = i_restore_valid_count;
      end else if (i_pop_after_restore && i_restore_valid_count != '0) begin
        tos_next_reference = i_restore_tos - RAS_PTR_BITS'(1);
        valid_count_next_reference = i_restore_valid_count - (RAS_PTR_BITS + 1)'(1);
      end else if (i_push_after_restore) begin
        tos_next_reference = i_restore_tos + RAS_PTR_BITS'(1);
        if (i_restore_valid_count != RAS_DEPTH[RAS_PTR_BITS:0]) begin
          valid_count_next_reference = i_restore_valid_count + (RAS_PTR_BITS + 1)'(1);
        end else begin
          valid_count_next_reference = i_restore_valid_count;
        end
      end else begin
        tos_next_reference = i_restore_tos;
        valid_count_next_reference = i_restore_valid_count;
      end
    end else begin
      if (do_pop_then_push && !i_stall_registered) begin
        // Coroutine: no change.
      end else if (do_push) begin
        tos_next_reference = tos_plus_one;
        if (valid_count != RAS_DEPTH[RAS_PTR_BITS:0]) begin
          valid_count_next_reference = valid_count + (RAS_PTR_BITS + 1)'(1);
        end
      end else if (do_pop && !i_stall_registered) begin
        tos_next_reference = tos_minus_one;
        valid_count_next_reference = valid_count - (RAS_PTR_BITS + 1)'(1);
      end
    end
  end
  always_comb begin
    assert ({tos_next, valid_count_next} == {tos_next_reference, valid_count_next_reference});
  end
`endif

  always_ff @(posedge i_clk) begin
    tos <= tos_next;
    valid_count <= valid_count_next;
  end

endmodule : return_address_stack
