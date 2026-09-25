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

// Shift-amount hint equivalence for the ALU. Both instances are the real ALU,
// and all operation bits, operands and instruction fields are unconstrained.
// The hinted instance (USE_SHIFT_AMOUNT_HINT=1) gets the amount the generic
// one selects for itself, the immediate shamt or b[5:0]; the generic instance
// gets an arbitrary hint, which it ignores. Their results and write enables
// must match, and for every operation that reads the shared shift amount the
// generic ALU must match a plain shift and rotate reference and write its
// result. This checks the ALU's combinational use of the hint, not how the
// reservation station captures and holds it (the rs_issue2_shamt cocotb test
// covers that).
module alu_shift_hint (
    input riscv_pkg::instr_t instruction,
    input riscv_pkg::instr_op_e op,
    input logic [63:0] a,
    b,
    imm_u,
    imm_i,
    link,
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
      .i_immediate_u_type(imm_u),
      .i_immediate_i_type(imm_i),
      .i_link_address(link),
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
      .i_immediate_u_type(imm_u),
      .i_immediate_i_type(imm_i),
      .i_link_address(link),
      .o_result(hinted_result),
      .o_write_enable(hinted_write)
  );
  logic [ 5:0] oracle_amount;
  logic [63:0] oracle_result;
  logic [31:0] oracle_word;
  logic oracle_consumer, oracle_word_consumer;
  always_comb begin
    oracle_amount = b[5:0];
    case (op)
      riscv_pkg::SLLI, riscv_pkg::SRLI, riscv_pkg::SRAI, riscv_pkg::RORI,
      riscv_pkg::SLLIW, riscv_pkg::SRLIW, riscv_pkg::SRAIW, riscv_pkg::RORIW:
      oracle_amount = {instruction.funct7[0], instruction.source_reg_2};
      default: ;
    endcase
    oracle_result = '0;
    oracle_word = '0;
    oracle_consumer = 1'b1;
    oracle_word_consumer = 1'b0;
    case (op)
      riscv_pkg::SLL, riscv_pkg::SLLI: oracle_result = a << oracle_amount;
      riscv_pkg::SRL, riscv_pkg::SRLI: oracle_result = a >> oracle_amount;
      riscv_pkg::SRA, riscv_pkg::SRAI: oracle_result = $signed(a) >>> oracle_amount;
      riscv_pkg::ROL: oracle_result = (a << oracle_amount) | (a >> (7'd64 - {1'b0, oracle_amount}));
      riscv_pkg::ROR, riscv_pkg::RORI:
      oracle_result = (a >> oracle_amount) | (a << (7'd64 - {1'b0, oracle_amount}));
      riscv_pkg::SLLW, riscv_pkg::SLLIW,
      riscv_pkg::SRLW, riscv_pkg::SRLIW,
      riscv_pkg::SRAW, riscv_pkg::SRAIW,
      riscv_pkg::ROLW, riscv_pkg::RORW, riscv_pkg::RORIW: begin
        oracle_word_consumer = 1'b1;
        case (op)
          riscv_pkg::SLLW, riscv_pkg::SLLIW: oracle_word = a[31:0] << oracle_amount[4:0];
          riscv_pkg::SRLW, riscv_pkg::SRLIW: oracle_word = a[31:0] >> oracle_amount[4:0];
          riscv_pkg::SRAW, riscv_pkg::SRAIW: oracle_word = $signed(a[31:0]) >>> oracle_amount[4:0];
          riscv_pkg::ROLW:
          oracle_word = (a[31:0] << oracle_amount[4:0]) |
                          (a[31:0] >> (6'd32 - {1'b0, oracle_amount[4:0]}));
          default:
          oracle_word = (a[31:0] >> oracle_amount[4:0]) |
                          (a[31:0] << (6'd32 - {1'b0, oracle_amount[4:0]}));
        endcase
      end
      default: oracle_consumer = 1'b0;
    endcase
    if (oracle_word_consumer) oracle_result = {{32{oracle_word[31]}}, oracle_word};
    if (oracle_consumer) begin
      p_barrel_reference : assert (generic_result == oracle_result);
      p_barrel_writes : assert (generic_write);
    end
  end
  always_comb begin
    p_result_equal : assert (hinted_result == generic_result);
    p_write_equal : assert (hinted_write == generic_write);
  end
endmodule
