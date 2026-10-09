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
 * Decode instruction classes directly from the fields, in parallel with
 * instr_decoder's operation decode.
 */
module instruction_type_decoder #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input riscv_pkg::instr_t i_instruction,
    input logic [XLEN-1:0] i_immediate_i_type,

    // Load type detection
    output logic o_is_load_instruction,
    output logic o_is_load_unsigned,

    // CSR instruction fields
    output logic        o_is_csr_instruction,
    output logic [11:0] o_csr_address,
    output logic [ 4:0] o_csr_imm,

    // A-extension (atomics) detection
    output logic o_is_amo_instruction,
    output logic o_is_lr,
    output logic o_is_sc,

    // Privileged instruction detection
    output logic o_is_mret,
    output logic o_is_sret,
    output logic o_is_dret,
    output logic o_is_wfi,

    // JAL/JALR detection
    output logic o_is_jal,
    output logic o_is_jalr,

    // RAS instruction type detection
    output logic o_is_ras_return,
    output logic o_is_ras_call
);

  assign o_is_load_instruction = i_instruction.opcode == riscv_pkg::OPC_LOAD;

  // Load funct3: 000=LB, 001=LH, 010=LW, 011=LD, 100=LBU, 101=LHU, 110=LWU
  assign o_is_load_unsigned = o_is_load_instruction && i_instruction.funct3[2];

  // Zicsr: funct3 != 000 distinguishes CSR operations from privileged
  // instructions sharing the SYSTEM opcode.
  assign o_is_csr_instruction = (i_instruction.opcode == riscv_pkg::OPC_CSR) &&
                                (i_instruction.funct3 != 3'b000);
  assign o_csr_address = {
    i_instruction.funct7, i_instruction.source_reg_2
  };  // CSR address in bits [31:20]
  assign o_csr_imm = i_instruction.source_reg_1;  // Unsigned 5-bit CSR immediate

  assign o_is_amo_instruction = i_instruction.opcode == riscv_pkg::OPC_AMO;
  // LR: funct7[6:2]=00010; SC: funct7[6:2]=00011. Accept both .W (funct3=010)
  // and RV64 .D (011), so neither width routes as an ordinary AMO without
  // reservation handling.
  logic amo_width_valid;
  assign amo_width_valid = (i_instruction.funct3 == 3'b010) || (i_instruction.funct3 == 3'b011);
  assign o_is_lr = o_is_amo_instruction && amo_width_valid &&
                   (i_instruction.funct7[6:2] == 5'b00010);
  assign o_is_sc = o_is_amo_instruction && amo_width_valid &&
                   (i_instruction.funct7[6:2] == 5'b00011);

  // Privileged instructions all use opcode=SYSTEM (1110011) with funct3=000
  logic is_priv_instruction;
  assign is_priv_instruction = (i_instruction.opcode == riscv_pkg::OPC_CSR) &&
                               (i_instruction.funct3 == 3'b000);
  // MRET: funct7=0011000, rs2=00010
  assign o_is_mret = is_priv_instruction &&
                     (i_instruction.funct7 == 7'b0011000) &&
                     (i_instruction.source_reg_2 == 5'b00010);
  // SRET: funct7=0001000, rs2=00010. SRET rides the MRET machinery: id_stage
  // folds it into the is_mret pipeline flag and carries o_is_sret alongside as
  // the qualifying sideband.
  assign o_is_sret = is_priv_instruction &&
                     (i_instruction.funct7 == 7'b0001000) &&
                     (i_instruction.source_reg_2 == 5'b00010);
  // DRET: funct7=0111101, rs2=10010 (0x7b200073). Like SRET it rides the
  // is_mret pipeline flag with o_is_dret as the qualifying sideband.
  assign o_is_dret = is_priv_instruction &&
                     (i_instruction.funct7 == 7'b0111101) &&
                     (i_instruction.source_reg_2 == 5'b10010);
  // WFI: funct7=0001000, rs2=00101
  assign o_is_wfi = is_priv_instruction &&
                    (i_instruction.funct7 == 7'b0001000) &&
                    (i_instruction.source_reg_2 == 5'b00101);

  assign o_is_jal = i_instruction.opcode == riscv_pkg::OPC_JAL;
  assign o_is_jalr = (i_instruction.opcode == riscv_pkg::OPC_JALR) &&
                     (i_instruction.funct3 == 3'b000);

  // ===========================================================================
  // RAS call/return classification
  // ===========================================================================
  // These flags accompany the instruction through the ROB for RAS recovery
  // and BTB training. Only x1 is a return source: treating x5/t0 as one would
  // pop the stack for indirect jumps through that scratch register. Returns
  // through x5 therefore do not pop it.
  //
  // {is_ras_return, is_ras_call} = 2'b11 encodes the coroutine
  // `jalr x5, x1, 0`: pop then push. Plain returns require rd == x0, while
  // calls require rd in {x1, x5}, so they cannot otherwise set both flags.
  // ex_comb_synthesizer decodes the pair for return_address_stack to replay.

  logic rs1_is_return_link;
  logic rd_is_link_reg;
  logic is_ras_coroutine;

  assign rs1_is_return_link = (i_instruction.source_reg_1 == 5'd1);
  assign rd_is_link_reg = (i_instruction.dest_reg == 5'd1) || (i_instruction.dest_reg == 5'd5);

  // The supported coroutine form is JALR with rd = x5, rs1 = x1, imm = 0.
  assign is_ras_coroutine = o_is_jalr &&
                            rd_is_link_reg &&
                            rs1_is_return_link &&
                            (i_instruction.dest_reg != i_instruction.source_reg_1) &&
                            (i_immediate_i_type == '0);

  // Return: JALR with rs1 = x1, rd = x0, imm = 0, or the swap encoding.
  assign o_is_ras_return = (o_is_jalr &&
                            rs1_is_return_link &&
                            (i_instruction.dest_reg == 5'd0) &&
                            (i_immediate_i_type == '0)) || is_ras_coroutine;

  // A coroutine already meets the call condition through its link-register rd.
  assign o_is_ras_call = (o_is_jal || o_is_jalr) && rd_is_link_reg;

endmodule : instruction_type_decoder
