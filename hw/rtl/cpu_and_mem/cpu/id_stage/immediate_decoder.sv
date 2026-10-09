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
 * Combinational RISC-V immediate decode. Results are sign-extended to XLEN;
 * B- and J-type offsets include the implicit low zero bit, and U-type
 * results have 12 low zero bits.
 */
module immediate_decoder #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input riscv_pkg::instr_t i_instruction,
    output logic [XLEN-1:0] o_immediate_i_type,
    output logic [XLEN-1:0] o_immediate_s_type,
    output logic [XLEN-1:0] o_immediate_b_type,
    output logic [XLEN-1:0] o_immediate_u_type,
    output logic [XLEN-1:0] o_immediate_j_type
);

  // I-type: 12-bit immediate in bits [31:20]
  assign o_immediate_i_type = {
    {(XLEN - 12) {i_instruction.funct7[6]}}, i_instruction.funct7, i_instruction.source_reg_2
  };

  // S-type: 12-bit immediate split between bits [31:25] and [11:7]
  assign o_immediate_s_type = {
    {(XLEN - 12) {i_instruction.funct7[6]}}, i_instruction.funct7, i_instruction.dest_reg
  };

  // B-type: 13-bit immediate (branch offset) scrambled in instruction
  // Bits: imm[12|10:5] in funct7, imm[4:1|11] in dest_reg, imm[0]=0
  assign o_immediate_b_type = {
    {(XLEN - 13) {i_instruction.funct7[6]}},
    i_instruction.funct7[6],
    i_instruction.dest_reg[0],
    i_instruction.funct7[5:0],
    i_instruction.dest_reg[4:1],
    1'b0
  };

  // U-type: sign-extend bit 31 and append 12 zero bits for LUI and AUIPC.
  assign o_immediate_u_type = {{(XLEN - 31) {i_instruction[31]}}, i_instruction[30:12], 12'h0};

  // J-type: 21-bit jump offset scrambled in instruction
  // Bits: imm[20|10:1|11|19:12], imm[0]=0
  assign o_immediate_j_type = {
    {(XLEN - 21) {i_instruction[31]}},
    i_instruction[31],
    i_instruction[19:12],
    i_instruction[20],
    i_instruction[30:21],
    1'b0
  };

endmodule : immediate_decoder
