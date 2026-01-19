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
 * Instruction Type Decoder for RISC-V Instructions
 *
 * This combinational module provides direct instruction type detection from
 * instruction bits, bypassing the main instruction decoder for timing optimization.
 * By decoding in parallel with the main instruction decoder, we break dependency
 * chains and reduce critical path delays.
 *
 * Decoded instruction types:
 *   - Load types (byte, halfword, unsigned)
 *   - M-extension (multiply, divide)
 *   - CSR instructions (address extraction)
 *   - A-extension atomics (LR, SC)
 *   - Privileged instructions (ECALL, EBREAK, MRET, WFI)
 *   - JAL/JALR detection
 */
module instruction_type_decoder #(
    parameter int unsigned XLEN = 32
) (
    input riscv_pkg::instr_t i_instruction,
    input logic [XLEN-1:0] i_immediate_i_type,

    // Load type detection
    output logic o_is_load_instruction,
    output logic o_is_load_byte,
    output logic o_is_load_halfword,
    output logic o_is_load_unsigned,

    // M-extension detection
    output logic o_is_multiply,
    output logic o_is_divide,

    // CSR instruction fields
    output logic        o_is_csr_instruction,
    output logic [11:0] o_csr_address,
    output logic [ 4:0] o_csr_imm,

    // A-extension (atomics) detection
    output logic o_is_amo_instruction,
    output logic o_is_lr,
    output logic o_is_sc,

    // Privileged instruction detection
    output logic o_is_ecall,
    output logic o_is_ebreak,
    output logic o_is_mret,
    output logic o_is_wfi,

    // JAL/JALR detection
    output logic o_is_jal,
    output logic o_is_jalr,

    // RAS instruction type detection
    output logic o_is_ras_return,
    output logic o_is_ras_call
);

  // Load instruction detection
  assign o_is_load_instruction = i_instruction.opcode == riscv_pkg::OPC_LOAD;

  // Direct decode of load type from instruction bits (parallel with instruction_operation)
  // This breaks the dependency chain: instruction -> instruction_operation -> is_load_*
  // Load funct3: 000=LB, 001=LH, 010=LW, 100=LBU, 101=LHU
  assign o_is_load_byte = o_is_load_instruction &&
                          (i_instruction.funct3 == 3'b000 || i_instruction.funct3 == 3'b100);
  assign o_is_load_halfword = o_is_load_instruction &&
                              (i_instruction.funct3 == 3'b001 || i_instruction.funct3 == 3'b101);
  assign o_is_load_unsigned = o_is_load_instruction && i_instruction.funct3[2];

  // Direct decode of multiply/divide from instruction bits
  // M-extension uses opcode=OP (0110011), funct7=0000001
  logic is_m_extension;
  assign is_m_extension = (i_instruction.opcode == riscv_pkg::OPC_OP) &&
                          (i_instruction.funct7 == 7'b0000001);
  assign o_is_multiply = is_m_extension && !i_instruction.funct3[2];  // funct3[2]=0 for MUL*
  assign o_is_divide = is_m_extension && i_instruction.funct3[2];  // funct3[2]=1 for DIV/REM

  // CSR instruction detection and field extraction (Zicsr extension)
  assign o_is_csr_instruction = i_instruction.opcode == riscv_pkg::OPC_CSR;
  assign o_csr_address = {
    i_instruction.funct7, i_instruction.source_reg_2
  };  // CSR address in bits [31:20]
  assign o_csr_imm = i_instruction.source_reg_1;  // Zero-extended imm for CSRRWI/CSRRSI/CSRRCI

  // A extension (atomics) detection - decode directly from instruction bits
  assign o_is_amo_instruction = i_instruction.opcode == riscv_pkg::OPC_AMO;
  // LR.W: funct7[6:2]=00010, funct3=010
  // SC.W: funct7[6:2]=00011, funct3=010
  assign o_is_lr = o_is_amo_instruction && (i_instruction.funct3 == 3'b010) &&
                   (i_instruction.funct7[6:2] == 5'b00010);
  assign o_is_sc = o_is_amo_instruction && (i_instruction.funct3 == 3'b010) &&
                   (i_instruction.funct7[6:2] == 5'b00011);

  // Privileged instruction detection - decode directly from instruction bits
  // All use opcode=SYSTEM (1110011), funct3=000
  logic is_priv_instruction;
  assign is_priv_instruction = (i_instruction.opcode == riscv_pkg::OPC_CSR) &&
                               (i_instruction.funct3 == 3'b000);
  // ECALL: funct7=0000000, rs2=00000
  assign o_is_ecall = is_priv_instruction &&
                      (i_instruction.funct7 == 7'b0000000) &&
                      (i_instruction.source_reg_2 == 5'b00000);
  // EBREAK: funct7=0000000, rs2=00001
  assign o_is_ebreak = is_priv_instruction &&
                       (i_instruction.funct7 == 7'b0000000) &&
                       (i_instruction.source_reg_2 == 5'b00001);
  // MRET: funct7=0011000, rs2=00010
  assign o_is_mret = is_priv_instruction &&
                     (i_instruction.funct7 == 7'b0011000) &&
                     (i_instruction.source_reg_2 == 5'b00010);
  // WFI: funct7=0001000, rs2=00101
  assign o_is_wfi = is_priv_instruction &&
                    (i_instruction.funct7 == 7'b0001000) &&
                    (i_instruction.source_reg_2 == 5'b00101);

  // Direct decode of JAL/JALR for timing - don't depend on instruction_operation
  assign o_is_jal = i_instruction.opcode == riscv_pkg::OPC_JAL;
  assign o_is_jalr = (i_instruction.opcode == riscv_pkg::OPC_JALR) &&
                     (i_instruction.funct3 == 3'b000);

  // ===========================================================================
  // TIMING OPTIMIZATION: Pre-compute RAS instruction type detection
  // ===========================================================================
  // These flags are computed here (ID stage) from registered inputs and passed
  // to EX stage to remove comparisons from the critical ras_correct path.
  //
  // is_ras_return: JALR with rs1 in {x1, x5}, rd = x0, imm = 0
  // is_ras_call: JAL/JALR with rd in {x1, x5}

  logic rs1_is_link_reg;
  logic rd_is_link_reg;

  assign rs1_is_link_reg = (i_instruction.source_reg_1 == 5'd1) ||
                           (i_instruction.source_reg_1 == 5'd5);
  assign rd_is_link_reg = (i_instruction.dest_reg == 5'd1) || (i_instruction.dest_reg == 5'd5);

  // Return: JALR with rs1 in {x1, x5}, rd = x0, imm = 0
  // The immediate for JALR is in I-type format: funct7[6:0] ++ source_reg_2[4:0]
  assign o_is_ras_return = o_is_jalr &&
                           rs1_is_link_reg &&
                           (i_instruction.dest_reg == 5'd0) &&
                           (i_immediate_i_type == 32'b0);

  // Call: JAL or JALR with rd in {x1, x5}
  assign o_is_ras_call = (o_is_jal || o_is_jalr) && rd_is_link_reg;

endmodule : instruction_type_decoder
