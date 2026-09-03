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
 * Combinational RAS hint detection using link registers x1 and x5:
 *   - JAL/JALR writing either link register pushes.
 *   - JALR x0, x1, 0 pops and predicts the return.
 *   - JALR with rs1=x1 and a distinct link rd pops then pushes for a
 *     coroutine swap.
 * C.JR and C.JALR are detected directly from the raw parcel because
 * decompression occurs in PD. C.JALR is a call, never a coroutine.
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
  logic rs1_is_return_link;
  logic rd_is_zero;

  assign rd_is_link = (rd == 5'd1) || (rd == 5'd5);
  assign rs1_is_link = (rs1 == 5'd1) || (rs1 == 5'd5);
  assign rs1_is_return_link = (rs1 == 5'd1);
  assign rd_is_zero = (rd == 5'd0);

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
  logic c_rs1_is_return_link;
  logic c_rs1_is_nonzero;

  assign c_rs1_is_link = (c_rs1 == 5'd1) || (c_rs1 == 5'd5);
  assign c_rs1_is_return_link = (c_rs1 == 5'd1);
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

  // No C.JAL on RV64: its RV32 encoding (001_imm_01) is C.ADDIW here and
  // must never push the RAS, so compressed calls are C.JALR only.

  // ===========================================================================
  // Call/Return/Coroutine Classification
  // ===========================================================================

  // 32-bit detection
  logic is_call_32;
  logic is_return_32;
  logic is_coroutine_32;

  // Call: JAL or JALR that saves to a link register
  assign is_call_32 = (is_jal && rd_is_link) || (is_jalr && rd_is_link);

  // Return: JALR x0, x1, 0, reading ra without writing a link register.
  assign is_return_32 = is_jalr && rs1_is_return_link && rd_is_zero && imm_i_is_zero;

  // Coroutine: JALR reads ra and writes the other link register (x5), with a
  // zero displacement.
  assign is_coroutine_32 = is_jalr && rd_is_link && rs1_is_return_link && (rd != rs1) &&
                           imm_i_is_zero;

  // Compressed detection
  logic is_call_c;
  logic is_return_c;
  logic is_coroutine_c;

  // RV64 compressed calls are C.JALR (rd=x1 implicit); C.JAL is not an RV64
  // instruction. C.JALR is never a coroutine (see is_coroutine_c below).
  assign is_call_c = is_c_jalr;

  // C.JR is a return only for x1/ra. Real code commonly uses x5/t0 as an
  // indirect jump scratch register, and treating that as a return poisons the RAS.
  assign is_return_c = is_c_jr && c_rs1_is_return_link;

  // Treat compressed C.JALR as a plain call, even when rs1=x5. In real code
  // x5/t0 is commonly used as a temporary indirect-call target register, and
  // classifying that pattern as a coroutine hint causes the RAS to skip the
  // required call push for sequences like "la t0, label; c.jalr t0".
  assign is_coroutine_c = 1'b0;

  // ===========================================================================
  // Final Output Mux
  // ===========================================================================

  assign o_is_call = i_instruction_valid && (i_is_compressed ? is_call_c : is_call_32);

  assign o_is_return = i_instruction_valid && (i_is_compressed ? is_return_c : is_return_32);

  assign o_is_coroutine = i_instruction_valid &&
                          (i_is_compressed ? is_coroutine_c : is_coroutine_32);

endmodule : ras_detector
