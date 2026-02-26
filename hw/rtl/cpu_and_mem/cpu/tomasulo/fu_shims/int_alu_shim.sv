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
 * Integer ALU Shim
 *
 * Translates rs_issue_t from the INT reservation station into the ALU's
 * native port interface, instantiates the ALU, and packs the result into
 * fu_complete_t for the CDB adapter / arbiter.
 *
 * Signal flow:  INT_RS -> int_alu_shim (translate + ALU) -> fu_complete_t
 *
 * The ALU is single-cycle for all INT_RS operations (ADD, SUB, shifts,
 * LUI, AUIPC, JAL/JALR link, CSR read, bit-manipulation).  MUL/DIV are
 * routed to MUL_RS, so the internal multiplier/divider are never triggered
 * (i_is_multiply_operation = 0, i_is_divide_operation = 0).
 *
 * Key translations:
 *   - i_instruction.opcode : OPC_OP_IMM when use_imm, else OPC_OP
 *     (controls the ALU's internal operand_b mux)
 *   - i_instruction.source_reg_2 : imm[4:0] for shift-amount in SLLI/SRLI/
 *     SRAI/BSETI/BCLRI/BINVI/BEXTI/RORI
 *   - i_link_address : pc + 4 for JAL/JALR
 *   - Branch ops hit the ALU's default case (o_write_enable = 0), producing
 *     fu_complete.valid = 0.  Branch resolution uses a separate path.
 */
module int_alu_shim (
    input logic i_clk,
    input logic i_rst_n,

    // From INT reservation station (issue output)
    input riscv_pkg::rs_issue_t i_rs_issue,

    // CSR read data from external CSR file
    input logic [riscv_pkg::XLEN-1:0] i_csr_read_data,

    // FU completion to CDB adapter
    output riscv_pkg::fu_complete_t o_fu_complete,

    // Back-pressure: ALU is single-cycle, always ready
    output logic o_fu_busy
);

  // ---------------------------------------------------------------------------
  // Reconstruct instruction fields needed by the ALU
  // ---------------------------------------------------------------------------
  riscv_pkg::instr_t alu_instruction;

  always_comb begin
    alu_instruction              = '0;
    // Opcode controls the ALU's internal operand_b mux:
    //   OPC_OP_IMM -> use sign-extended i_immediate_i_type
    //   OPC_OP     -> use i_operand_b (register value)
    alu_instruction.opcode       = i_rs_issue.use_imm ? riscv_pkg::OPC_OP_IMM : riscv_pkg::OPC_OP;
    // source_reg_2 provides the shift amount for immediate-shift operations
    // (SLLI, SRLI, SRAI, BSETI, BCLRI, BINVI, BEXTI, RORI)
    alu_instruction.source_reg_2 = i_rs_issue.imm[4:0];
  end

  // ---------------------------------------------------------------------------
  // ALU instantiation
  // ---------------------------------------------------------------------------
  logic [riscv_pkg::XLEN-1:0] alu_result;
  logic                       alu_write_enable;
  logic                       alu_stall;  // unused (no MUL/DIV)
  logic                       alu_mul_completing;  // unused

  alu #(
      .XLEN(riscv_pkg::XLEN)
  ) u_alu (
      .i_clk(i_clk),
      .i_rst(~i_rst_n),  // ALU uses active-high reset
      .i_instruction(alu_instruction),
      .i_instruction_operation(i_rs_issue.op),
      .i_operand_a(i_rs_issue.src1_value[riscv_pkg::XLEN-1:0]),
      .i_operand_b(i_rs_issue.src2_value[riscv_pkg::XLEN-1:0]),
      .i_program_counter(i_rs_issue.pc),
      .i_immediate_u_type(i_rs_issue.imm),
      .i_immediate_i_type(i_rs_issue.imm),
      .i_is_multiply_operation(1'b0),
      .i_is_divide_operation(1'b0),
      .i_link_address(i_rs_issue.pc + 32'd4),
      .i_csr_read_data(i_csr_read_data),
      .o_result(alu_result),
      .o_write_enable(alu_write_enable),
      .o_stall_for_multiply_divide(alu_stall),
      .o_multiply_completing_next_cycle(alu_mul_completing)
  );

  // ---------------------------------------------------------------------------
  // Pack output into fu_complete_t
  // ---------------------------------------------------------------------------
  always_comb begin
    o_fu_complete.valid     = i_rs_issue.valid & alu_write_enable;
    o_fu_complete.tag       = i_rs_issue.rob_tag;
    o_fu_complete.value     = {{(riscv_pkg::FLEN - riscv_pkg::XLEN) {1'b0}}, alu_result};
    o_fu_complete.exception = 1'b0;
    o_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
    o_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'('0);
  end

  // ALU is single-cycle for INT_RS ops; never busy
  assign o_fu_busy = 1'b0;

endmodule : int_alu_shim
