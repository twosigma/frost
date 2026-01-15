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
 * Execute (EX) Stage - Fourth stage of the 6-stage RISC-V pipeline
 *
 * This stage performs the core computational work of the processor:
 *   - ALU operations for arithmetic, logical, and bit manipulation
 *   - Branch/jump condition evaluation and target selection
 *   - Memory address calculation for loads and stores
 *   - Exception detection (ECALL, EBREAK, misaligned accesses)
 *
 * Submodule Hierarchy:
 * ====================
 *   ex_stage
 *   ├── alu/                       Arithmetic/Logic Unit
 *   │   ├── alu.sv                     Main ALU (RV32I + B extensions)
 *   │   ├── multiplier.sv              2-cycle pipelined multiply
 *   │   └── divider.sv                 17-cycle pipelined divide
 *   ├── branch_jump_unit.sv        Branch condition eval, target mux
 *   ├── store_unit.sv              Store address calc, byte-enable generation
 *   └── exception_detector.sv      ECALL, EBREAK, misaligned access detection
 *
 * Block Diagram:
 * ==============
 *   +-------------------------------------------------------------------------+
 *   |                              EX Stage                                   |
 *   |                                                                         |
 *   |  from ID ----+--------------------------------------------------------->|
 *   |              |                                                          |
 *   |              v                                                          |
 *   |  +----------------------------------------------------------------------+
 *   |  |                            ALU                                   |   |
 *   |  |  +------------------------------------------------------------+  |   |
 *   |  |  |   Main ALU (RV32I + Zba + Zbb + Zbs + Zicond + Zbkb)       |  |   |
 *   |  |  +---------------------------+--------------------------------+  |   |
 *   |  |                              |                                   |   |
 *   |  |        +---------------------+---------------------+             |   |
 *   |  |        v                     |                     v             |   |
 *   |  |   +----------+               |              +-----------+        |   |
 *   |  |   |multiplier|               |              |  divider  |        |   |
 *   |  |   | 2-cycle  |               |              | 17-cycle  |        |   |
 *   |  |   +----------+               |              +-----------+        |   |
 *   |  +------------------------------+-----------------------------------+   |
 *   |                                 |                                       |
 *   |                                 v alu_result                            |
 *   |                                 |                                       |
 *   |  +-----------------+     +------+------+     +---------------------+    |
 *   |  |branch_jump_unit |     |   Output    |     | exception_detector  |    |
 *   |  |                 |---->|    Mux      |<----|  ECALL/EBREAK/      |    |
 *   |  | condition eval  |     |             |     | misaligned access   |    |
 *   |  +-----------------+     +------+------+     +----------+----------+    |
 *   |                                 |                       |               |
 *   |  +-----------------+            |                       | exceptions    |
 *   |  |   store_unit    |------------+-----------------------+----------> MA |
 *   |  | addr/byte-en    |            |                       |               |
 *   |  +-----------------+            +-----------------------+----------> MA |
 *   |                                                                         |
 *   |  BTB update <------------------------------------------------------- IF |
 *   +-------------------------------------------------------------------------+
 *
 * Timing Notes:
 * =============
 *   - Branch/JAL targets pre-computed in ID stage (reduces EX critical path)
 *   - Only JALR target computed here (requires forwarded rs1 value)
 *   - Multiply stall uses registered prediction signal for timing optimization
 *
 * Related Modules:
 * ================
 *   - id_stage.sv: Provides decoded instruction data and pre-computed targets
 *   - ma_stage.sv: Receives EX results for memory operations and writeback
 *   - forwarding_unit.sv: Provides resolved operand values via i_fwd_to_ex
 *   - hazard_resolution_unit.sv: Uses o_from_ex_comb for stall/flush decisions
 */
module ex_stage #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,

    // Pipeline control (stall, flush, reset)
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,

    // Decoded instruction data from ID stage
    input riscv_pkg::from_id_to_ex_t i_from_id_to_ex,

    // Forwarded operand values (resolved by forwarding unit)
    input riscv_pkg::fwd_to_ex_t i_fwd_to_ex,

    // CSR read data for Zicsr instructions (CSRRW, CSRRS, CSRRC, etc.)
    input logic [XLEN-1:0] i_csr_read_data,

    // LR/SC reservation state for A-extension atomic operations
    input riscv_pkg::reservation_t i_reservation,

    // Combinational outputs (used by forwarding, hazard detection, control flow)
    /* verilator lint_off UNOPTFLAT */
    output riscv_pkg::from_ex_comb_t o_from_ex_comb,
    /* verilator lint_on UNOPTFLAT */

    // Registered outputs to MA stage (pipeline register)
    output riscv_pkg::from_ex_to_ma_t o_from_ex_to_ma
);

  // Arithmetic Logic Unit - performs all computational operations
  alu #(
      .XLEN(XLEN)
  ) alu_inst (
      .i_clk,
      .i_rst(i_pipeline_ctrl.reset),
      .i_instruction(i_from_id_to_ex.instruction),
      .i_instruction_operation(i_from_id_to_ex.instruction_operation),
      .i_operand_a(i_fwd_to_ex.source_reg_1_value),
      .i_operand_b(i_fwd_to_ex.source_reg_2_value),
      .i_program_counter(i_from_id_to_ex.program_counter),
      .i_immediate_u_type(i_from_id_to_ex.immediate_u_type),
      .i_immediate_i_type(i_from_id_to_ex.immediate_i_type),
      .i_is_multiply_operation(i_from_id_to_ex.is_multiply),
      .i_is_divide_operation(i_from_id_to_ex.is_divide),
      .i_link_address(i_from_id_to_ex.link_address),
      .i_csr_read_data(i_csr_read_data),
      .o_result(o_from_ex_comb.alu_result),
      .o_stall_for_multiply_divide(o_from_ex_comb.stall_for_multiply_divide),
      .o_write_enable(o_from_ex_comb.regfile_write_enable),
      .o_multiply_completing_next_cycle(o_from_ex_comb.multiply_completing_next_cycle)
  );

  // Branch and jump resolution unit - determines if branch/jump taken and selects target
  // Note: Branch/JAL targets pre-computed in ID stage; only JALR target computed here
  logic            actual_branch_taken;
  logic [XLEN-1:0] actual_branch_target;

  branch_jump_unit #(
      .XLEN(XLEN)
  ) branch_jump_unit_inst (
      .i_branch_operation(i_from_id_to_ex.branch_operation),
      .i_is_jump_and_link(i_from_id_to_ex.is_jump_and_link),
      .i_is_jump_and_link_register(i_from_id_to_ex.is_jump_and_link_register),
      .i_operand_a(i_fwd_to_ex.source_reg_1_value),
      .i_operand_b(i_fwd_to_ex.source_reg_2_value),
      // Pre-computed targets from ID stage (branches and JAL use PC-relative addressing)
      .i_branch_target_precomputed(i_from_id_to_ex.branch_target_precomputed),
      .i_jal_target_precomputed(i_from_id_to_ex.jal_target_precomputed),
      // JALR still needs i_type immediate since it uses forwarded rs1
      .i_immediate_i_type(i_from_id_to_ex.immediate_i_type),
      .o_branch_taken(actual_branch_taken),
      .o_branch_target_address(actual_branch_target)
  );

  // ===========================================================================
  // Branch Prediction Misprediction Recovery
  // ===========================================================================
  // Redirect is needed only when the predicted path differs from the actual path.
  //
  // Cases:
  //   1. Not predicted, not taken     → No redirect (correct)
  //   2. Not predicted, taken         → Redirect to actual target
  //   3. Predicted taken, taken same  → No redirect (correct prediction!)
  //   4. Predicted taken, taken diff  → Redirect to actual target
  //   5. Predicted taken, not taken   → Redirect to sequential PC (link_address)
  //
  // Key insight: If we predicted taken correctly (same target), we're already on
  // the right path and should NOT flush the pipeline.

  logic predicted_taken;
  // Include RAS predictions in predicted_taken
  assign predicted_taken = i_from_id_to_ex.btb_predicted_taken || i_from_id_to_ex.ras_predicted;

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
  assign btb_correct_for_jalr = i_from_id_to_ex.btb_predicted_taken &&
                                i_from_id_to_ex.is_jump_and_link_register &&
                                (i_fwd_to_ex.source_reg_1_value ==
                                 i_from_id_to_ex.btb_expected_rs1);

  logic btb_correct_for_non_jalr;
  assign btb_correct_for_non_jalr = i_from_id_to_ex.btb_predicted_taken &&
                                    !i_from_id_to_ex.is_jump_and_link_register &&
                                    actual_branch_taken &&
                                    i_from_id_to_ex.btb_correct_non_jalr;

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
  assign ras_correct = i_from_id_to_ex.ras_predicted &&
                       i_from_id_to_ex.is_ras_return &&
                       (i_fwd_to_ex.source_reg_1_value == i_from_id_to_ex.ras_expected_rs1) &&
                       i_from_id_to_ex.ras_predicted_target_nonzero;

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
  assign need_redirect_jalr = i_from_id_to_ex.is_jump_and_link_register &&
                              !btb_correct_for_jalr && !ras_correct;

  logic need_redirect_non_jalr;
  assign need_redirect_non_jalr = !i_from_id_to_ex.is_jump_and_link_register &&
                                  ((actual_branch_taken && !btb_correct_for_non_jalr) ||
                                   (predicted_taken && !actual_branch_taken));

  logic need_redirect;
  assign need_redirect = need_redirect_jalr || need_redirect_non_jalr;

  // Redirect target:
  // - If predicted taken but not taken: sequential PC (link_address)
  // - Otherwise: actual branch target
  assign o_from_ex_comb.branch_taken = need_redirect;
  assign o_from_ex_comb.branch_target_address = (predicted_taken && !actual_branch_taken) ?
                                                 i_from_id_to_ex.link_address :
                                                 actual_branch_target;

  // Store unit - calculates memory addresses and prepares data for writes
  // TIMING OPTIMIZATION: data_memory_address_low computed without CARRY8 chain
  // for faster misalignment detection
  logic [1:0] data_memory_address_low;

  store_unit #(
      .XLEN(XLEN)
  ) store_unit_inst (
      .i_store_operation(i_from_id_to_ex.store_operation),
      .i_source_reg_1_value(i_fwd_to_ex.source_reg_1_value),
      .i_source_reg_2_value(i_fwd_to_ex.source_reg_2_value),
      .i_immediate_s_type(i_from_id_to_ex.immediate_s_type),
      .i_immediate_i_type(i_from_id_to_ex.immediate_i_type),
      .i_is_load_instruction(i_from_id_to_ex.is_load_instruction),
      .i_is_load_halfword(i_from_id_to_ex.is_load_halfword),
      .i_is_amo_instruction(i_from_id_to_ex.is_amo_instruction),
      .i_is_sc(i_from_id_to_ex.is_sc),
      .i_reservation(i_reservation),
      .o_data_memory_address(o_from_ex_comb.data_memory_address),
      .o_data_memory_write_data(o_from_ex_comb.data_memory_write_data),
      .o_data_memory_byte_write_enable(o_from_ex_comb.data_memory_byte_write_enable),
      .o_sc_success(o_from_ex_comb.sc_success),
      .o_data_memory_address_low(data_memory_address_low)
  );

  // Exception detection - detects ECALL, EBREAK, and misaligned memory accesses
  exception_detector #(
      .XLEN(XLEN)
  ) exception_detector_inst (
      .i_is_ecall(i_from_id_to_ex.is_ecall),
      .i_is_ebreak(i_from_id_to_ex.is_ebreak),
      .i_is_load_instruction(i_from_id_to_ex.is_load_instruction),
      .i_is_load_halfword(i_from_id_to_ex.is_load_halfword),
      .i_is_load_byte(i_from_id_to_ex.is_load_byte),
      .i_store_operation(i_from_id_to_ex.store_operation),
      .i_program_counter(i_from_id_to_ex.program_counter),
      .i_data_memory_address(o_from_ex_comb.data_memory_address),
      .i_data_memory_address_low(data_memory_address_low),
      .o_exception_valid(o_from_ex_comb.exception_valid),
      .o_exception_cause(o_from_ex_comb.exception_cause),
      .o_exception_tval(o_from_ex_comb.exception_tval)
  );

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
  assign is_branch_or_jump = (i_from_id_to_ex.branch_operation != riscv_pkg::NULL) ||
                             i_from_id_to_ex.is_jump_and_link ||
                             i_from_id_to_ex.is_jump_and_link_register;

  // Detect false prediction: BTB predicted taken, but instruction is not a branch/jump.
  // This can happen due to BTB aliasing (different instruction with same index/tag).
  // We must update the BTB to clear this stale entry, otherwise the same false
  // prediction will repeat indefinitely.
  logic btb_false_prediction;
  assign btb_false_prediction = i_from_id_to_ex.btb_predicted_taken && !is_branch_or_jump;

  // Update BTB when:
  // 1. Any branch/jump instruction resolves (normal case - learn actual outcome)
  // 2. Non-branch was falsely predicted as taken (clear stale prediction)
  assign o_from_ex_comb.btb_update = is_branch_or_jump || btb_false_prediction;
  assign o_from_ex_comb.btb_update_pc = i_from_id_to_ex.program_counter;
  assign o_from_ex_comb.btb_update_target = actual_branch_target;
  // For false predictions on non-branches, mark as not-taken to prevent repeated mispredictions
  assign o_from_ex_comb.btb_update_taken = is_branch_or_jump ? actual_branch_taken : 1'b0;

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
  assign actual_is_return = i_from_id_to_ex.is_ras_return;

  // Detect if current instruction is actually a call (JAL/JALR with rd = x1/x5)
  // Calls push to the RAS and should NOT trigger a restore when they redirect.
  // TIMING OPTIMIZATION: Use pre-computed flag from ID stage.
  logic actual_is_call;
  assign actual_is_call = i_from_id_to_ex.is_ras_call;

  // RAS prediction was wrong if:
  // - RAS predicted (took a prediction), AND
  // - Either: instruction is not actually a return, OR target doesn't match
  logic ras_prediction_wrong;
  assign ras_prediction_wrong = i_from_id_to_ex.ras_predicted &&
                                (!actual_is_return ||
                                 (actual_is_return &&
                                  actual_branch_target != i_from_id_to_ex.ras_predicted_target));

  // Output RAS recovery signals
  // Restore RAS on redirects, EXCEPT for call instructions.
  // - Call instructions push to RAS at IF stage. When they reach EX and trigger
  //   a redirect (to jump to the call target), we must NOT restore - the push
  //   was correct and should be kept.
  // - For all other redirects (branch misprediction, trap, RAS misprediction),
  //   we restore from the checkpoint to undo any speculative RAS operations.
  assign o_from_ex_comb.ras_misprediction = need_redirect && !actual_is_call;
  assign o_from_ex_comb.ras_restore_tos = i_from_id_to_ex.ras_checkpoint_tos;
  assign o_from_ex_comb.ras_restore_valid_count = i_from_id_to_ex.ras_checkpoint_valid_count;

  // Pop after restore: When a return instruction triggers ras_misprediction, we need to pop.
  // This handles two cases:
  // - Non-spanning returns that popped in IF but mispredicted: restore undoes pop, then re-pop
  // - Spanning returns that couldn't pop in IF: restore (noop on pop), then pop
  // This ensures every return "consumes" exactly one stack entry.
  // Pop after restore for returns that trigger misprediction (spanning or wrong prediction)
  assign o_from_ex_comb.ras_pop_after_restore =
      o_from_ex_comb.ras_misprediction && actual_is_return;

  // Pipeline register logic to next stage
  always_ff @(posedge i_clk) begin
    // Reset control signals (instruction metadata and enables)
    if (i_pipeline_ctrl.reset) begin
      o_from_ex_to_ma.is_load_instruction <= 1'b0;
      o_from_ex_to_ma.is_load_byte <= 1'b0;
      o_from_ex_to_ma.is_load_halfword <= 1'b0;
      o_from_ex_to_ma.is_load_unsigned <= 1'b0;
      o_from_ex_to_ma.instruction <= riscv_pkg::NOP;
      o_from_ex_to_ma.regfile_write_enable <= 1'b0;
      // A extension (atomics)
      o_from_ex_to_ma.is_amo_instruction <= 1'b0;
      o_from_ex_to_ma.is_lr <= 1'b0;
      o_from_ex_to_ma.is_sc <= 1'b0;
      o_from_ex_to_ma.sc_success <= 1'b0;
      o_from_ex_to_ma.instruction_operation <= riscv_pkg::ADDI;
    end else if (~i_pipeline_ctrl.stall) begin
      o_from_ex_to_ma.is_load_instruction <= i_from_id_to_ex.is_load_instruction;
      o_from_ex_to_ma.is_load_byte <= i_from_id_to_ex.is_load_byte;
      o_from_ex_to_ma.is_load_halfword <= i_from_id_to_ex.is_load_halfword;
      o_from_ex_to_ma.is_load_unsigned <= i_from_id_to_ex.is_load_unsigned;
      o_from_ex_to_ma.instruction <= i_from_id_to_ex.instruction;
      // Register write enable is set if ALU writes OR if this is a load OR if AMO (writes result to rd)
      o_from_ex_to_ma.regfile_write_enable <= o_from_ex_comb.regfile_write_enable |
                                              i_from_id_to_ex.is_load_instruction |
                                              i_from_id_to_ex.is_amo_instruction;
      // A extension (atomics)
      o_from_ex_to_ma.is_amo_instruction <= i_from_id_to_ex.is_amo_instruction;
      o_from_ex_to_ma.is_lr <= i_from_id_to_ex.is_lr;
      o_from_ex_to_ma.is_sc <= i_from_id_to_ex.is_sc;
      o_from_ex_to_ma.sc_success <= o_from_ex_comb.sc_success;
      o_from_ex_to_ma.instruction_operation <= i_from_id_to_ex.instruction_operation;
    end
    // Datapath signals are not reset (only affected by stall)
    if (~i_pipeline_ctrl.stall) begin
      o_from_ex_to_ma.alu_result <= o_from_ex_comb.alu_result;
      o_from_ex_to_ma.data_memory_address <= o_from_ex_comb.data_memory_address;
      // A extension: rs2 value needed for SC and AMO operations
      o_from_ex_to_ma.rs2_value <= i_fwd_to_ex.source_reg_2_value;
    end
  end

endmodule : ex_stage
