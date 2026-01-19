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
 *   - Branch prediction verification and misprediction recovery
 *
 * Submodule Hierarchy:
 * ====================
 *   ex_stage
 *   ├── alu/                       Arithmetic/Logic Unit
 *   │   ├── alu.sv                     Main ALU (RV32I + B extensions)
 *   │   ├── multiplier.sv              2-cycle pipelined multiply
 *   │   └── divider.sv                 17-cycle pipelined divide
 *   ├── branch_jump_unit.sv        Branch condition eval, target mux
 *   ├── branch_redirect_unit.sv    Misprediction detection, BTB/RAS recovery
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
 *   |          |                      |                       |               |
 *   |          v                      |                       | exceptions    |
 *   |  +-------------------+          |                       |               |
 *   |  |branch_redirect_   |----------+-----------------------+----------> MA |
 *   |  |unit (BTB/RAS)     |          |                       |               |
 *   |  +-------------------+          +-----------------------+----------> MA |
 *   |                                                                         |
 *   |  +-----------------+                                                    |
 *   |  |   store_unit    |---------------------------------------------> MA   |
 *   |  | addr/byte-en    |                                                    |
 *   |  +-----------------+                                                    |
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

  // ===========================================================================
  // Submodule Instantiations
  // ===========================================================================

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

  // Branch redirect unit - handles misprediction detection and BTB/RAS recovery
  branch_redirect_unit #(
      .XLEN(XLEN),
      .RasPtrBits(riscv_pkg::RasPtrBits)
  ) branch_redirect_unit_inst (
      // Instruction info from ID stage
      .i_program_counter(i_from_id_to_ex.program_counter),
      .i_link_address(i_from_id_to_ex.link_address),
      .i_is_jump_and_link(i_from_id_to_ex.is_jump_and_link),
      .i_is_jump_and_link_register(i_from_id_to_ex.is_jump_and_link_register),
      .i_branch_operation(i_from_id_to_ex.branch_operation),
      // Forwarded operand value
      .i_forwarded_rs1(i_fwd_to_ex.source_reg_1_value),
      // Branch/jump resolution from branch_jump_unit
      .i_actual_branch_taken(actual_branch_taken),
      .i_actual_branch_target(actual_branch_target),
      // BTB prediction metadata
      .i_btb_predicted_taken(i_from_id_to_ex.btb_predicted_taken),
      .i_btb_predicted_target(i_from_id_to_ex.btb_predicted_target),
      // RAS prediction metadata
      .i_ras_predicted(i_from_id_to_ex.ras_predicted),
      .i_ras_predicted_target(i_from_id_to_ex.ras_predicted_target),
      .i_ras_checkpoint_tos(i_from_id_to_ex.ras_checkpoint_tos),
      .i_ras_checkpoint_valid_count(i_from_id_to_ex.ras_checkpoint_valid_count),
      // Pre-computed values from ID stage (timing optimizations)
      .i_is_ras_return(i_from_id_to_ex.is_ras_return),
      .i_is_ras_call(i_from_id_to_ex.is_ras_call),
      .i_ras_predicted_target_nonzero(i_from_id_to_ex.ras_predicted_target_nonzero),
      .i_ras_expected_rs1(i_from_id_to_ex.ras_expected_rs1),
      .i_btb_correct_non_jalr(i_from_id_to_ex.btb_correct_non_jalr),
      .i_btb_expected_rs1(i_from_id_to_ex.btb_expected_rs1),
      // Redirect outputs
      .o_branch_taken(o_from_ex_comb.branch_taken),
      .o_branch_target_address(o_from_ex_comb.branch_target_address),
      // BTB update outputs
      .o_btb_update(o_from_ex_comb.btb_update),
      .o_btb_update_pc(o_from_ex_comb.btb_update_pc),
      .o_btb_update_target(o_from_ex_comb.btb_update_target),
      .o_btb_update_taken(o_from_ex_comb.btb_update_taken),
      // RAS recovery outputs
      .o_ras_misprediction(o_from_ex_comb.ras_misprediction),
      .o_ras_restore_tos(o_from_ex_comb.ras_restore_tos),
      .o_ras_restore_valid_count(o_from_ex_comb.ras_restore_valid_count),
      .o_ras_pop_after_restore(o_from_ex_comb.ras_pop_after_restore)
  );

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
  // Pipeline Register
  // ===========================================================================
  // Latch results and pass to Memory Access stage

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
