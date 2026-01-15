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
 * RAS Instruction Detector
 *
 * Detects function call and return patterns from instruction bits for
 * Return Address Stack (RAS) prediction.
 *
 * RISC-V Link Registers: x1 (ra) and x5 (t0)
 * These are the canonical return address registers per the RISC-V spec.
 *
 * Detection Rules (per RISC-V calling convention hints):
 * ======================================================
 *   Call:      JAL/JALR with rd in {x1, x5}
 *              - Saves return address to link register
 *              - RAS should PUSH the link address
 *
 *   Return:    JALR with rs1 in {x1, x5} AND rd = x0 AND imm = 0
 *              - Jumps to saved return address without saving new address
 *              - RAS should POP and predict target
 *
 *   Coroutine: JALR with rd in {x1, x5} AND rs1 in {x1, x5} AND rd != rs1 AND imm = 0
 *              - Swaps return addresses (used in coroutine switching)
 *              - RAS should POP then PUSH (effectively swap)
 *
 * Compressed Instruction Support:
 * ==============================
 *   C.JR:   1000_rs1_00000_10 -> JALR x0, rs1, 0  (RETURN if rs1 in {x1, x5})
 *   C.JALR: 1001_rs1_00000_10 -> JALR x1, rs1, 0  (CALL, COROUTINE if rs1 in {x1, x5})
 *   C.JAL:  001_imm_01        -> JAL x1, imm      (CALL, RV32 only)
 *
 * IMPORTANT: In this design, decompression happens in PD stage, so IF stage
 * must detect compressed patterns directly from the raw 16-bit parcel.
 *
 * TIMING: Pure combinational logic on instruction bits. Should be fast
 * since it only examines opcode, rd, rs1, and funct3 fields.
 */
module ras_detector (
    // Instruction to analyze (32-bit for non-compressed instructions)
    input riscv_pkg::instr_t i_instruction,

    // Raw 16-bit parcel (for compressed instruction detection)
    input logic [15:0] i_raw_parcel,

    // Whether current instruction is compressed (use i_raw_parcel for detection)
    input logic i_is_compressed,

    // Is this instruction valid (not NOP, not holdoff, not flush)
    input logic i_instruction_valid,

    // Detection outputs
    output logic o_is_call,      // Push to RAS
    output logic o_is_return,    // Pop from RAS (predict target)
    output logic o_is_coroutine  // Pop then push (swap)
);

  // ===========================================================================
  // 32-bit Instruction Field Extraction
  // ===========================================================================
  logic [6:0] opcode;
  logic [4:0] rd;
  logic [4:0] rs1;
  logic [2:0] funct3;
  logic imm_i_is_zero;

  assign opcode = i_instruction.opcode;
  assign rd = i_instruction.dest_reg;
  assign rs1 = i_instruction.source_reg_1;
  assign funct3 = i_instruction.funct3;
  // JALR uses I-type immediate in bits [31:20]; returns require imm == 0.
  assign imm_i_is_zero = (i_instruction.funct7 == 7'b0000000) &&
                         (i_instruction.source_reg_2 == 5'b00000);

  // ===========================================================================
  // Link Register Detection (32-bit)
  // ===========================================================================
  // RISC-V ABI defines x1 (ra) as the return address register.
  // x5 (t0) is also recognized as an alternate link register for millicode.

  logic rd_is_link;
  logic rs1_is_link;
  logic rd_is_zero;

  assign rd_is_link  = (rd == 5'd1) || (rd == 5'd5);
  assign rs1_is_link = (rs1 == 5'd1) || (rs1 == 5'd5);
  assign rd_is_zero  = (rd == 5'd0);

  // ===========================================================================
  // 32-bit Instruction Type Detection
  // ===========================================================================
  logic is_jal;
  logic is_jalr;

  assign is_jal  = (opcode == riscv_pkg::OPC_JAL);
  assign is_jalr = (opcode == riscv_pkg::OPC_JALR) && (funct3 == 3'b000);

  // ===========================================================================
  // Compressed Instruction Detection (16-bit parcel)
  // ===========================================================================
  // C.JR:   funct4=1000, rs2=00000, op=10 -> JALR x0, rs1, 0
  // C.JALR: funct4=1001, rs2=00000, op=10 -> JALR x1, rs1, 0
  // C.JAL:  funct3=001, op=01             -> JAL x1, imm (RV32 only)

  logic [3:0] c_funct4;
  logic [4:0] c_rs1;
  logic [4:0] c_rs2;
  logic [1:0] c_op;
  logic [2:0] c_funct3;

  assign c_funct4 = i_raw_parcel[15:12];
  assign c_rs1    = i_raw_parcel[11:7];
  assign c_rs2    = i_raw_parcel[6:2];
  assign c_op     = i_raw_parcel[1:0];
  assign c_funct3 = i_raw_parcel[15:13];

  // Link register detection for compressed instructions
  logic c_rs1_is_link;
  logic c_rs1_is_nonzero;

  assign c_rs1_is_link = (c_rs1 == 5'd1) || (c_rs1 == 5'd5);
  assign c_rs1_is_nonzero = (c_rs1 != 5'd0);

  // Compressed instruction type detection
  // C.JR:   1000_rs1_00000_10 (rs1 != 0)
  logic is_c_jr;
  assign is_c_jr = (c_funct4 == 4'b1000) && (c_rs2 == 5'b00000) &&
                   (c_op == 2'b10) && c_rs1_is_nonzero;

  // C.JALR: 1001_rs1_00000_10 (rs1 != 0)
  logic is_c_jalr;
  assign is_c_jalr = (c_funct4 == 4'b1001) && (c_rs2 == 5'b00000) &&
                     (c_op == 2'b10) && c_rs1_is_nonzero;

  // C.JAL:  001_imm_01 (RV32 only - always saves to x1)
  logic is_c_jal;
  assign is_c_jal = (c_funct3 == 3'b001) && (c_op == 2'b01);

  // ===========================================================================
  // Call/Return/Coroutine Classification
  // ===========================================================================

  // 32-bit detection
  logic is_call_32;
  logic is_return_32;
  logic is_coroutine_32;

  // Call: JAL or JALR that saves to a link register
  assign is_call_32 = (is_jal && rd_is_link) || (is_jalr && rd_is_link);

  // Return: JALR using link register as source, not saving return address
  assign is_return_32 = is_jalr && rs1_is_link && rd_is_zero && imm_i_is_zero;

  // Coroutine: JALR with both rd and rs1 as link registers, but different
  assign is_coroutine_32 = is_jalr && rd_is_link && rs1_is_link && (rd != rs1) && imm_i_is_zero;

  // Compressed detection
  logic is_call_c;
  logic is_return_c;
  logic is_coroutine_c;

  // C.JAL is always a call (rd=x1 implicit)
  // C.JALR is a call (rd=x1 implicit), and also coroutine if rs1 is a link reg
  assign is_call_c = is_c_jal || is_c_jalr;

  // C.JR is a return if rs1 is a link register (rd=x0 implicit)
  assign is_return_c = is_c_jr && c_rs1_is_link;

  // C.JALR with rs1 as a link register is a coroutine (rd=x1, rs1 in {x1, x5})
  // Only coroutine if rd != rs1, which means rs1 must be x5 (since rd is always x1)
  assign is_coroutine_c = is_c_jalr && (c_rs1 == 5'd5);

  // ===========================================================================
  // Final Output Mux
  // ===========================================================================

  assign o_is_call = i_instruction_valid && (i_is_compressed ? is_call_c : is_call_32);

  assign o_is_return = i_instruction_valid && (i_is_compressed ? is_return_c : is_return_32);

  assign o_is_coroutine = i_instruction_valid &&
                          (i_is_compressed ? is_coroutine_c : is_coroutine_32);

endmodule : ras_detector
