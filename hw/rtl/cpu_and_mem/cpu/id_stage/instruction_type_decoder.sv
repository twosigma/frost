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
 * Combinational decode of the timing-critical instruction classes. Every flag
 * comes straight from the instruction bits rather than from instr_decoder's
 * instruction_operation, so the two decodes run in parallel.
 *
 * Decoded instruction types:
 *   - Loads (any load, unsigned)
 *   - CSR instructions (address extraction)
 *   - A-extension atomics (LR, SC)
 *   - Privileged instructions (MRET, SRET, DRET, WFI)
 *   - JAL/JALR detection
 *   - RAS returns and calls, including the coroutine swap encoding
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

  // Load signedness comes straight from funct3, avoiding the serial chain
  // instruction -> instruction_operation -> is_load_*.
  // Load funct3: 000=LB, 001=LH, 010=LW, 011=LD, 100=LBU, 101=LHU, 110=LWU
  assign o_is_load_unsigned = o_is_load_instruction && i_instruction.funct3[2];

  // Zicsr: CSR instructions use OPC_CSR (SYSTEM) with funct3 != 000. The
  // privileged instructions share that opcode with funct3=000, so the funct3
  // term is what keeps them out of the CSR path.
  assign o_is_csr_instruction = (i_instruction.opcode == riscv_pkg::OPC_CSR) &&
                                (i_instruction.funct3 != 3'b000);
  assign o_csr_address = {
    i_instruction.funct7, i_instruction.source_reg_2
  };  // CSR address in bits [31:20]
  assign o_csr_imm = i_instruction.source_reg_1;  // Zero-extended imm for CSRRWI/CSRRSI/CSRRCI

  assign o_is_amo_instruction = i_instruction.opcode == riscv_pkg::OPC_AMO;
  // LR: funct7[6:2]=00010; SC: funct7[6:2]=00011. funct3 selects the width:
  // 010 = .W (both XLENs), 011 = .D (rv64 only), so at rv64 the width term
  // accepts both. If LR.D and SC.D missed is_lr/is_sc they would route as
  // ordinary AMOs, and SC.D would write memory with no reservation check and
  // return the loaded data as its success code.
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

  // JAL/JALR from the opcode, again without waiting on instruction_operation
  assign o_is_jal = i_instruction.opcode == riscv_pkg::OPC_JAL;
  assign o_is_jalr = (i_instruction.opcode == riscv_pkg::OPC_JALR) &&
                     (i_instruction.funct3 == 3'b000);

  // ===========================================================================
  // RAS call/return classification
  // ===========================================================================
  // is_ras_return: JALR with rs1 = x1, rd = x0, imm = 0
  // is_ras_call: JAL/JALR with rd in {x1, x5}
  //
  // These have to match if_stage/branch_prediction/ras_detector.sv. The front
  // end uses that detector to drive the RAS, and dispatch passes these flags
  // to the ROB so commit-time recovery can replay the same push/pop after
  // restoring a checkpoint. Any divergence desynchronizes the RAS from the real
  // call stack. In particular, the return test is rs1 == x1 alone.
  // ras_detector.sv excludes x5/t0, a common indirect-jump scratch register,
  // from the return classification, so `jr t0` must not be treated as a return
  // here. A genuine return through x5 is therefore not popped: the encoding
  // cannot tell it from `jr t0`, and a false pop is worse.
  //
  // ras_detector also classifies a coroutine (`jalr x5, x1, 0`, where rd and
  // rs1 are both link registers but different) as pop-then-push.  A plain
  // return needs rd == x0 and a plain call needs rd in {x1, x5}, so no plain
  // call or return sets both flags, and {is_ras_return, is_ras_call} = 2'b11
  // carries the coroutine downstream without widening the ROB entry, the
  // commit bus, or the recovery registers.  ex_comb_synthesizer decodes it
  // back into a swap; return_address_stack replays it.

  logic rs1_is_return_link;
  logic rd_is_link_reg;
  logic is_ras_coroutine;

  assign rs1_is_return_link = (i_instruction.source_reg_1 == 5'd1);
  assign rd_is_link_reg = (i_instruction.dest_reg == 5'd1) || (i_instruction.dest_reg == 5'd5);

  // Coroutine (swap): JALR with rd and rs1 both link registers but different,
  // imm = 0.  Mirrors ras_detector.sv's is_coroutine_32 exactly.
  assign is_ras_coroutine = o_is_jalr &&
                            rd_is_link_reg &&
                            rs1_is_return_link &&
                            (i_instruction.dest_reg != i_instruction.source_reg_1) &&
                            (i_immediate_i_type == '0);

  // Return: JALR with rs1 = x1, rd = x0, imm = 0, or the swap encoding.
  // The immediate for JALR is in I-type format: funct7[6:0] ++ source_reg_2[4:0]
  assign o_is_ras_return = (o_is_jalr &&
                            rs1_is_return_link &&
                            (i_instruction.dest_reg == 5'd0) &&
                            (i_immediate_i_type == '0)) || is_ras_coroutine;

  // Call: JAL or JALR with rd in {x1, x5}.  A coroutine's rd is a link
  // register, so it already satisfies this and needs no extra term. Asserting
  // o_is_ras_return alongside is what forms the 2'b11 swap encoding.
  assign o_is_ras_call = (o_is_jal || o_is_jalr) && rd_is_link_reg;

endmodule : instruction_type_decoder
