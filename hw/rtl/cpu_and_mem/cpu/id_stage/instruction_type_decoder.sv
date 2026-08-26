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
 * Parallel combinational decode of timing-critical instruction classes,
 * bypassing the main decoder's dependency chain.
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
    parameter int unsigned XLEN = riscv_pkg::XLEN
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
  // CSR instructions use OPC_CSR (SYSTEM) with funct3 != 000.
  // Privileged instructions (ECALL, EBREAK, MRET, WFI) share the same opcode
  // but have funct3=000 — they are NOT CSR instructions.
  assign o_is_csr_instruction = (i_instruction.opcode == riscv_pkg::OPC_CSR) &&
                                (i_instruction.funct3 != 3'b000);
  assign o_csr_address = {
    i_instruction.funct7, i_instruction.source_reg_2
  };  // CSR address in bits [31:20]
  assign o_csr_imm = i_instruction.source_reg_1;  // Zero-extended imm for CSRRWI/CSRRSI/CSRRCI

  // A extension (atomics) detection - decode directly from instruction bits
  assign o_is_amo_instruction = i_instruction.opcode == riscv_pkg::OPC_AMO;
  // LR: funct7[6:2]=00010; SC: funct7[6:2]=00011. funct3 selects the width:
  // 010 = .W (both XLENs), 011 = .D (rv64 only). The width term must accept
  // both at 64 — a funct3==010-only decode leaves is_lr/is_sc FALSE for
  // LR.D/SC.D, which then route as generic AMOs: SC.D completes with the
  // LOADED DATA as its "success code" and writes memory with no reservation
  // check (caught by rv64_amo_test test 6 — sc.d returned the old dword).
  logic amo_width_valid;
  assign amo_width_valid = (i_instruction.funct3 == 3'b010) || (i_instruction.funct3 == 3'b011);
  assign o_is_lr = o_is_amo_instruction && amo_width_valid &&
                   (i_instruction.funct7[6:2] == 5'b00010);
  assign o_is_sc = o_is_amo_instruction && amo_width_valid &&
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
  // SRET: funct7=0001000, rs2=00010. id_stage folds this into the is_mret
  // pipeline flag (SRET rides the MRET machinery) and carries o_is_sret as
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
  // is_ras_return: JALR with rs1 = x1, rd = x0, imm = 0
  // is_ras_call: JAL/JALR with rd in {x1, x5}
  //
  // These MUST match if_stage/branch_prediction/ras_detector.sv: the front end
  // uses that detector to drive the RAS, and these flags ride the ROB so
  // commit-time recovery can replay the same push/pop after restoring a
  // checkpoint. Any divergence desynchronizes the RAS from the real call stack.
  // In particular, the return test is rs1 == x1 ONLY -- ras_detector.sv
  // deliberately excludes x5/t0 (a common indirect-jump scratch register) from
  // the return classification, so `jr t0` must not be treated as a return here.
  // That costs a pop for a genuine x5-linked return, which is the accepted
  // trade: the encoding cannot distinguish the two, and a false pop is worse.
  //
  // SWAP ENCODING: ras_detector also classifies a coroutine (`jalr x5, x1, 0`
  // -- rd and rs1 both link registers but different) as pop-then-push.  A plain
  // return needs rd == x0 and a plain call needs rd in {x1, x5}, so the two
  // flags can never both be set by those two cases; {is_ras_return, is_ras_call}
  // = 2'b11 is therefore a free encoding, and it is what carries the coroutine
  // downstream.  This keeps the ROB entry, the commit bus and the recovery
  // registers exactly as wide as before.  ex_comb_synthesizer decodes it back
  // into a swap; return_address_stack replays it.

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

  // Return: JALR with rs1 = x1, rd = x0, imm = 0 -- or the swap encoding.
  // The immediate for JALR is in I-type format: funct7[6:0] ++ source_reg_2[4:0]
  assign o_is_ras_return = (o_is_jalr &&
                            rs1_is_return_link &&
                            (i_instruction.dest_reg == 5'd0) &&
                            (i_immediate_i_type == '0)) || is_ras_coroutine;

  // Call: JAL or JALR with rd in {x1, x5}.  A coroutine already satisfies this
  // (its rd is a link register), so it needs no extra term here -- asserting
  // o_is_ras_return alongside is what forms the 2'b11 swap encoding.
  assign o_is_ras_call = (o_is_jal || o_is_jalr) && rd_is_link_reg;

endmodule : instruction_type_decoder
