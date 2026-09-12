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

// Both instances are the actual ALU. All op bits, operands and instruction
// fields remain symbolic. The hinted instance receives the exact local
// effective amount; the generic instance receives arbitrary ignored hints.
// This proves the combinational consumer contract, not RS temporal capture.
module alu_shift_hint (
    input riscv_pkg::instr_t instruction,
    input riscv_pkg::instr_op_e op,
    input logic [63:0] a,
    b,
    pc,
    imm_u,
    imm_i,
    link,
    csr,
    input logic [5:0] unused_hint
);
  logic [6:0] controls;
  logic [5:0] effective_amount;
  logic [63:0] generic_result, hinted_result;
  logic generic_write, hinted_write;
  assign controls = riscv_pkg::projected_shift_controls(op);
  assign effective_amount = controls[0] ?
      {instruction.funct7[0], instruction.source_reg_2} : b[5:0];

  alu #(
      .XLEN(64)
  ) generic_alu (
      .i_instruction(instruction),
      .i_instruction_operation(op),
      .i_operand_a(a),
      .i_operand_b(b),
      .i_shift_amount_hint(unused_hint),
      .i_program_counter(pc),
      .i_immediate_u_type(imm_u),
      .i_immediate_i_type(imm_i),
      .i_link_address(link),
      .i_csr_read_data(csr),
      .o_result(generic_result),
      .o_write_enable(generic_write)
  );
  alu #(
      .XLEN(64),
      .USE_SHIFT_AMOUNT_HINT(1'b1)
  ) hinted_alu (
      .i_instruction(instruction),
      .i_instruction_operation(op),
      .i_operand_a(a),
      .i_operand_b(b),
      .i_shift_amount_hint(effective_amount),
      .i_program_counter(pc),
      .i_immediate_u_type(imm_u),
      .i_immediate_i_type(imm_i),
      .i_link_address(link),
      .i_csr_read_data(csr),
      .o_result(hinted_result),
      .o_write_enable(hinted_write)
  );
  always_comb begin
    p_result_equal : assert (hinted_result == generic_result);
    p_write_equal : assert (hinted_write == generic_write);
  end
endmodule
