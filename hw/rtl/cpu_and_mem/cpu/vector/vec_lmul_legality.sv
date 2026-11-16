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
  Instruction-side arithmetic legality, precomputed before the decoded queue.
  Bits 31:0 index {vsew[1:0], vlmul}; bit 32 says whether vill or an
  unsupported SEW makes this instruction illegal. Whole-register moves do
  not depend on vtype. Dispatch selects a bit from the registered lookup.
*/
module vec_lmul_legality (
    input logic [31:0] i_insn,
    input riscv_pkg::instr_op_e i_op,
    input logic i_is_illegal,
    input logic i_is_fetch_fault,
    output logic [32:0] o_illegal,
    output logic o_mem_illegal
);

  // Vector loads and stores trap at the ROB head. This instruction-only
  // rejection travels beside the LMUL classes; it does not depend on vtype.
  // Decode illegality (including VS Off) and fetch faults keep their own cause.
  assign o_mem_illegal = !i_is_illegal && !i_is_fetch_fault &&
      ((i_op == riscv_pkg::VLOAD) || (i_op == riscv_pkg::VSTORE));

  assign o_illegal[32] = !((i_insn[14:12] == 3'b011) && (i_insn[31:26] == 6'h27));
  for (genvar k = 0; k < 32; k++) begin : gen_class
    assign o_illegal[k] = riscv_pkg::vector_arith_illegal(9'(k), i_insn);
  end
endmodule
