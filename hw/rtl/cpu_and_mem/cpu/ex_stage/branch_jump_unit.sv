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
 * Branch and Jump Resolution Unit - Control flow decision logic
 *
 * Evaluates branch conditions and selects target addresses for all RISC-V
 * control flow instructions. This is purely combinational logic with no
 * internal state.
 *
 * Supported Instructions:
 *   Conditional Branches (B-type):
 *     BEQ   - Branch if Equal              (rs1 == rs2)
 *     BNE   - Branch if Not Equal          (rs1 != rs2)
 *     BLT   - Branch if Less Than          (signed rs1 < rs2)
 *     BGE   - Branch if Greater or Equal   (signed rs1 >= rs2)
 *     BLTU  - Branch if Less Than Unsigned (unsigned rs1 < rs2)
 *     BGEU  - Branch if Greater or Equal U (unsigned rs1 >= rs2)
 *
 *   Unconditional Jumps:
 *     JAL   - Jump and Link                (always taken, PC-relative)
 *     JALR  - Jump and Link Register       (always taken, rs1-relative)
 *
 * Pipeline Balancing:
 *   - Branch/JAL targets: Pre-computed in ID stage (PC + immediate)
 *   - JALR target: Computed here (requires forwarded rs1 value)
 *
 * Target Address Selection:
 *   +------------------------------------------------------------+
 *   | Instruction | Target Computation                           |
 *   +-------------+----------------------------------------------+
 *   | Branches    | i_branch_target_precomputed (from ID)        |
 *   | JAL         | i_jal_target_precomputed (from ID)           |
 *   | JALR        | (rs1 + imm_i) & ~1  (computed here)          |
 *   +------------------------------------------------------------+
 *
 * Related Modules:
 *   - id_stage.sv: Pre-computes branch_target and jal_target
 *   - ex_stage.sv: Instantiates this unit
 *   - pc_controller.sv: Uses branch_taken and target to update PC
 *   - hazard_resolution_unit.sv: Uses branch_taken for pipeline flush
 */
module branch_jump_unit #(
    parameter int unsigned XLEN = 32
) (
    // Branch operation type (decoded from funct3)
    input riscv_pkg::branch_taken_op_e i_branch_operation,

    // Jump instruction flags
    input logic i_is_jump_and_link,          // JAL instruction (PC-relative)
    input logic i_is_jump_and_link_register, // JALR instruction (rs1-relative)

    // Operands for comparison (forwarded values from forwarding unit)
    input logic [XLEN-1:0] i_operand_a,  // rs1 value (also used for JALR base)
    input logic [XLEN-1:0] i_operand_b,  // rs2 value (for branch comparisons)

    // Pre-computed targets from ID stage (reduces EX critical path)
    input logic [XLEN-1:0] i_branch_target_precomputed,  // PC + imm_b
    input logic [XLEN-1:0] i_jal_target_precomputed,     // PC + imm_j

    // JALR offset (I-type immediate, sign-extended)
    input logic [31:0] i_immediate_i_type,

    // Outputs
    output logic            o_branch_taken,          // Branch/jump should be taken
    output logic [XLEN-1:0] o_branch_target_address  // Target PC
);

  // JALR target computed here (needs forwarded rs1 value)
  logic [XLEN-1:0] jalr_target;
  assign jalr_target = (i_operand_a + XLEN'(signed'(i_immediate_i_type))) & ~XLEN'(1);

  // Share comparators across branch types to reduce logic depth.
  logic operands_equal;
  logic signed_less_than;
  logic unsigned_less_than;

  assign operands_equal = i_operand_a == i_operand_b;
  assign signed_less_than = $signed(i_operand_a) < $signed(i_operand_b);
  assign unsigned_less_than = i_operand_a < i_operand_b;

  // Combinational logic for branch/jump resolution
  always_comb begin
    // Evaluate branch condition based on operation type
    unique case (i_branch_operation)
      riscv_pkg::BREQ: o_branch_taken = operands_equal;  // Branch if equal
      riscv_pkg::BRNE: o_branch_taken = !operands_equal;  // Branch if not equal
      riscv_pkg::BRLT: o_branch_taken = signed_less_than;  // Branch if less than (signed)
      riscv_pkg::BRGE: o_branch_taken = !signed_less_than;  // Branch if greater/equal (signed)
      riscv_pkg::BRLTU: o_branch_taken = unsigned_less_than;  // Branch if less than (unsigned)
      riscv_pkg::BRGEU: o_branch_taken = !unsigned_less_than;  // Branch if greater/equal (unsigned)
      // Unconditional jump (JAL/JALR)
      riscv_pkg::JUMP: o_branch_taken = i_is_jump_and_link_register | i_is_jump_and_link;
      riscv_pkg::NULL: o_branch_taken = i_is_jump_and_link;  // JAL may use NULL; always taken
    endcase

    // Select target address based on instruction type
    // JAL and branch targets are pre-computed in ID stage; only JALR computed here
    unique case ({
      i_is_jump_and_link, i_is_jump_and_link_register
    })
      2'b10:   o_branch_target_address = i_jal_target_precomputed;  // JAL: use pre-computed
      2'b01:   o_branch_target_address = jalr_target;  // JALR: computed here
      default: o_branch_target_address = i_branch_target_precomputed;  // Branch: use pre-computed
    endcase
  end

endmodule : branch_jump_unit
