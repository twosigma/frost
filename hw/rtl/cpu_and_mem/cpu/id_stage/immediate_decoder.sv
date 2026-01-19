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
 * Immediate Value Decoder for RISC-V Instructions
 *
 * This combinational module extracts and sign-extends immediate values from
 * RISC-V instructions. It decodes all five immediate formats in parallel:
 *   - I-type: 12-bit signed immediate for loads, ALU-immediate, JALR
 *   - S-type: 12-bit signed immediate for stores
 *   - B-type: 13-bit signed immediate (x2) for conditional branches
 *   - U-type: 20-bit upper immediate for LUI/AUIPC
 *   - J-type: 21-bit signed immediate (x2) for JAL
 *
 * All immediate values are sign-extended to 32 bits.
 */
module immediate_decoder #(
    parameter int unsigned XLEN = 32
) (
    input riscv_pkg::instr_t i_instruction,
    output logic [XLEN-1:0] o_immediate_i_type,
    output logic [XLEN-1:0] o_immediate_s_type,
    output logic [XLEN-1:0] o_immediate_b_type,
    output logic [XLEN-1:0] o_immediate_u_type,
    output logic [XLEN-1:0] o_immediate_j_type
);

  // I-type: 12-bit immediate in bits [31:20]
  // Used by: loads, ALU-immediate, JALR
  assign o_immediate_i_type = {
    {20{i_instruction.funct7[6]}}, i_instruction.funct7, i_instruction.source_reg_2
  };

  // S-type: 12-bit immediate split between bits [31:25] and [11:7]
  // Used by: stores
  assign o_immediate_s_type = {
    {20{i_instruction.funct7[6]}}, i_instruction.funct7, i_instruction.dest_reg
  };

  // B-type: 13-bit immediate (branch offset) scrambled in instruction
  // Bits: imm[12|10:5] in funct7, imm[4:1|11] in dest_reg, imm[0]=0
  // Used by: conditional branches
  assign o_immediate_b_type = {
    {19{i_instruction.funct7[6]}},
    i_instruction.funct7[6],
    i_instruction.dest_reg[0],
    i_instruction.funct7[5:0],
    i_instruction.dest_reg[4:1],
    1'b0
  };

  // U-type: 20-bit immediate in upper bits, lower 12 bits are zero
  // Used by: LUI, AUIPC
  assign o_immediate_u_type = {i_instruction[31:12], 12'h0};

  // J-type: 21-bit jump offset scrambled in instruction
  // Bits: imm[20|10:1|11|19:12], imm[0]=0
  // Used by: JAL
  assign o_immediate_j_type = {
    {11{i_instruction[31]}},
    i_instruction[31],
    i_instruction[19:12],
    i_instruction[20],
    i_instruction[30:21],
    1'b0
  };

endmodule : immediate_decoder
