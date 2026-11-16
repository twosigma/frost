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

module vec_legality_reference (
    input logic [31:0] i_insn,
    input logic [8:0] i_vtype,
    output logic o_illegal
);
  riscv_pkg::instr_op_e op;
  logic decode_illegal;
  instr_decoder decoder (
      .i_instr(riscv_pkg::instr_t'(i_insn)),
      .i_cbo_inval_flush(1'b0),
      .o_instr_op(op),
      .o_illegal(decode_illegal)
  );
  always_comb begin
    o_illegal = decode_illegal;
    case (op)
      riscv_pkg::VARITH, riscv_pkg::VARITH_X:
      o_illegal |= riscv_pkg::vector_arith_illegal(i_vtype, i_insn);
      riscv_pkg::VTOX: o_illegal |= i_vtype[8];
      default: o_illegal = 1'b1;
    endcase
  end
endmodule
