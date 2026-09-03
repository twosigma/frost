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
 * Combinational BEQ/BNE/BLT/BGE/BLTU/BGEU and JAL/JALR resolution. ID
 * precomputes branch and JAL PC-relative targets; JALR computes
 * (rs1 + imm_i) & ~1 here because it needs the forwarded rs1 value.
 */
module branch_jump_unit #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    // Branch operation type (decoded from funct3)
    input riscv_pkg::branch_taken_op_e i_branch_operation,

    // Jump instruction flags
    input logic i_is_jump_and_link,          // JAL instruction (PC-relative)
    input logic i_is_jump_and_link_register, // JALR instruction (rs1-relative)

    // Operands for comparison from the issuing reservation station
    input logic [XLEN-1:0] i_operand_a,  // rs1 value (also used for JALR base)
    input logic [XLEN-1:0] i_operand_b,  // rs2 value (for branch comparisons)

    // Pre-computed targets from ID stage (reduces EX critical path)
    input logic [XLEN-1:0] i_branch_target_precomputed,  // PC + imm_b
    input logic [XLEN-1:0] i_jal_target_precomputed,     // PC + imm_j

    // JALR offset (I-type immediate, sign-extended)
    input logic [XLEN-1:0] i_immediate_i_type,

    // Outputs
    output logic            o_branch_taken,          // Branch/jump should be taken
    output logic [XLEN-1:0] o_branch_target_address  // Target PC
);

  // JALR target computed here (needs forwarded rs1 value)
  logic [XLEN-1:0] jalr_target;
  logic [XLEN-1:0] target_selected;
  assign jalr_target = (i_operand_a + XLEN'(signed'(i_immediate_i_type))) & ~XLEN'(1);

  // Share comparators across branch types to reduce logic depth.
  logic operands_equal;
  logic signed_less_than;
  logic unsigned_less_than;

  assign operands_equal = i_operand_a == i_operand_b;
  assign signed_less_than = $signed(i_operand_a) < $signed(i_operand_b);
  assign unsigned_less_than = i_operand_a < i_operand_b;

  always_comb begin
    unique case (i_branch_operation)
      riscv_pkg::BREQ:  o_branch_taken = operands_equal;
      riscv_pkg::BRNE:  o_branch_taken = !operands_equal;
      riscv_pkg::BRLT:  o_branch_taken = signed_less_than;
      riscv_pkg::BRGE:  o_branch_taken = !signed_less_than;
      riscv_pkg::BRLTU: o_branch_taken = unsigned_less_than;
      riscv_pkg::BRGEU: o_branch_taken = !unsigned_less_than;
      riscv_pkg::JUMP:  o_branch_taken = i_is_jump_and_link_register | i_is_jump_and_link;
      riscv_pkg::NULL:  o_branch_taken = i_is_jump_and_link;  // JAL may use NULL; always taken
    endcase

    unique case ({
      i_is_jump_and_link, i_is_jump_and_link_register
    })
      2'b10:   target_selected = i_jal_target_precomputed;  // JAL: use pre-computed
      2'b01:   target_selected = jalr_target;  // JALR: computed here
      default: target_selected = i_branch_target_precomputed;  // Branch: use pre-computed
    endcase

    // Phase 3 M2: the resolved target flows at full width, with no masking.
    // A wild JALR target reaches the PC unchanged and page/PMA-faults at
    // fetch instead of aliasing, and predictor-trained targets compare
    // against the full architectural value.
    o_branch_target_address = target_selected;
  end

endmodule : branch_jump_unit
