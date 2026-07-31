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
 * Arithmetic Logic Unit (ALU) - single-cycle combinational execution unit.
 * Implements the base integer ISA plus the B-extension (Zba, Zbb, Zbs),
 * Zicond, and Zbkb, XLEN-parametric: at XLEN=64 this includes the 6-bit
 * shift/rotate/bit-index amounts, the W-form word-operation family
 * (32-bit operation, result sign-extended), and the Zba unsigned-word
 * address forms. The ALU also forwards pre-computed link addresses for
 * JAL/JALR, materializes LUI/AUIPC values, and passes CSR read data
 * through for Zicsr ops. M-extension operations never reach this unit:
 * the OoO core routes them to the dedicated multiplier/divider behind
 * int_muldiv_shim, so they fall to the no-write default here.
 *
 * Bit Manipulation Functions:
 * ===========================
 *   CLZ, CTZ, CPOP helper trees are defined in riscv_pkg.sv (Section 10);
 *   the byte-granular ORC.B/REV8/BREV8 helpers below are local and
 *   XLEN-parametric.
 */
module alu #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input riscv_pkg::instr_t i_instruction,
    input riscv_pkg::instr_op_e i_instruction_operation,
    input logic [XLEN-1:0] i_operand_a,  // First operand (typically rs1 value)
    input logic [XLEN-1:0] i_operand_b,  // Second operand (typically rs2 value or immediate)
    input logic [XLEN-1:0] i_program_counter,
    input logic [XLEN-1:0] i_immediate_u_type,  // Upper immediate for LUI/AUIPC
    input logic [XLEN-1:0] i_immediate_i_type,  // I-type immediate
    input logic [XLEN-1:0] i_link_address,  // Pre-computed link address (PC+2 or PC+4)
    // CSR interface (Zicsr extension)
    input logic [XLEN-1:0] i_csr_read_data,  // CSR read value from CSR file
    output logic [XLEN-1:0] o_result,
    output logic o_write_enable  // Whether to write result to register file
);

  logic [XLEN-1:0] operand_b;
  logic [XLEN:0] difference;
  logic sltu;

  function automatic logic op_is_imm_not_reg(input logic [6:0] opcode);
    logic [6:0] unique_opcode_bits;
    unique_opcode_bits = riscv_pkg::OPC_OP_IMM ^ riscv_pkg::OPC_OP;
    op_is_imm_not_reg = (unique_opcode_bits & opcode) ==
                        (unique_opcode_bits & riscv_pkg::OPC_OP_IMM);
  endfunction

  assign operand_b = op_is_imm_not_reg(
      i_instruction.opcode
  ) ? XLEN'(signed'(i_immediate_i_type)) : i_operand_b;

  // Base-shift shift-amount width: RV64 base shifts take 6-bit shamts (the
  // register forms read rs2[5:0]; the immediate forms carry shamt[5] in
  // instruction bit 25, delivered here through funct7[0] by the issue shim).
  // The same channel serves the Zbs bit indices and rotates at XLEN=64.
  localparam int unsigned ShamtMsb = (XLEN == 64) ? 5 : 4;
  logic [ShamtMsb:0] shamt_imm;
  if (XLEN == 64) begin : gen_shamt6_imm
    assign shamt_imm = {i_instruction.funct7[0], i_instruction.source_reg_2};
  end else begin : gen_shamt5_imm
    assign shamt_imm = i_instruction.source_reg_2;
  end

  // RV64 W-form result: operate on the low 32 bits, sign-extend into XLEN.
  // Dead (never decoded) at XLEN=32; the zero-width replication is legal.
  function automatic logic [XLEN-1:0] w_result(input logic [31:0] w);
    w_result = {{(XLEN - 32) {w[31]}}, w};
  endfunction

  // Zba unsigned-word operand: rs1's low 32 bits zero-extended to XLEN.
  // Dead at XLEN=32 (the .UW forms only decode at 64).
  function automatic logic [XLEN-1:0] uw_operand(input logic [XLEN-1:0] a);
    uw_operand = XLEN'(a[31:0]);
  endfunction

  // Byte-granular Zbb/Zbkb helpers, XLEN-parametric (byte count = XLEN/8).
  function automatic logic [XLEN-1:0] orc_b_x(input logic [XLEN-1:0] val);
    for (int i = 0; i < XLEN / 8; i++) orc_b_x[i*8+:8] = {8{|val[i*8+:8]}};
  endfunction
  function automatic logic [XLEN-1:0] rev8_x(input logic [XLEN-1:0] val);
    for (int i = 0; i < XLEN / 8; i++) rev8_x[i*8+:8] = val[(XLEN/8-1-i)*8+:8];
  endfunction
  function automatic logic [XLEN-1:0] brev8_x(input logic [XLEN-1:0] val);
    for (int i = 0; i < XLEN / 8; i++) for (int b = 0; b < 8; b++) brev8_x[i*8+b] = val[i*8+(7-b)];
  endfunction

  assign difference = {i_operand_a[XLEN-1], i_operand_a} - {operand_b[XLEN-1], operand_b};
  assign sltu = i_operand_a[XLEN-1] && !(operand_b[XLEN-1]) ? '0 :
                operand_b[XLEN-1] && !(i_operand_a[XLEN-1]) ? '1 :
                difference[XLEN];

  // Rotate funnel widths: the double-width funnel shifted by (XLEN - shamt)
  // needs a shamt-plus-one-bit subtrahend so shamt=0 maps to a full-XLEN
  // shift (rotate identity).
  localparam int unsigned RotAmtBits = ShamtMsb + 2;

  // Main ALU operation selection and result computation (combinational logic)
  always_comb begin
    o_result = '0;
    o_write_enable = 1'b1;  // Most operations write to register file
    unique case (i_instruction_operation)
      // Base ISA R-type (register-register) arithmetic and logical operations
      riscv_pkg::ADD: o_result = i_operand_a + operand_b;
      riscv_pkg::SUB: o_result = difference[XLEN-1:0];
      riscv_pkg::AND: o_result = i_operand_a & operand_b;
      riscv_pkg::OR: o_result = i_operand_a | operand_b;
      riscv_pkg::XOR: o_result = i_operand_a ^ operand_b;
      riscv_pkg::SLL: o_result = i_operand_a << i_operand_b[ShamtMsb:0];  // Shift left logical
      riscv_pkg::SRL: o_result = i_operand_a >> i_operand_b[ShamtMsb:0];  // Shift right logical
      riscv_pkg::SRA:  // Shift right arithmetic (sign-extend)
      o_result = $signed(i_operand_a) >>> i_operand_b[ShamtMsb:0];
      riscv_pkg::SLT: o_result = XLEN'(difference[XLEN]);  // Set if less than (signed)
      riscv_pkg::SLTU: o_result = XLEN'(sltu);  // Set if less than (unsigned)
      // Base ISA I-type (immediate) operations
      riscv_pkg::ADDI: o_result = i_operand_a + operand_b;
      riscv_pkg::ANDI: o_result = i_operand_a & operand_b;
      riscv_pkg::ORI: o_result = i_operand_a | operand_b;
      riscv_pkg::XORI: o_result = i_operand_a ^ operand_b;
      riscv_pkg::SLTI: o_result = XLEN'(difference[XLEN]);  // Set if less than (signed)
      riscv_pkg::SLTIU: o_result = XLEN'(sltu);  // Set if less than (unsigned)
      // Shift immediate operations - shamt in rs2 field (+bit 25 on RV64)
      riscv_pkg::SLLI: o_result = i_operand_a << shamt_imm;
      riscv_pkg::SRLI: o_result = i_operand_a >> shamt_imm;
      riscv_pkg::SRAI: o_result = $signed(i_operand_a) >>> shamt_imm;
      // RV64 W-form ALU ops: 32-bit operation, result sign-extended to XLEN.
      // Never decoded at XLEN=32 (these arms are dead there).
      riscv_pkg::ADDW, riscv_pkg::ADDIW: o_result = w_result(i_operand_a[31:0] + operand_b[31:0]);
      riscv_pkg::SUBW: o_result = w_result(i_operand_a[31:0] - operand_b[31:0]);
      riscv_pkg::SLLW: o_result = w_result(i_operand_a[31:0] << i_operand_b[4:0]);
      riscv_pkg::SRLW: o_result = w_result(i_operand_a[31:0] >> i_operand_b[4:0]);
      riscv_pkg::SRAW: o_result = w_result(32'($signed(i_operand_a[31:0]) >>> i_operand_b[4:0]));
      riscv_pkg::SLLIW: o_result = w_result(i_operand_a[31:0] << i_instruction.source_reg_2);
      riscv_pkg::SRLIW: o_result = w_result(i_operand_a[31:0] >> i_instruction.source_reg_2);
      riscv_pkg::SRAIW:
      o_result = w_result(32'($signed(i_operand_a[31:0]) >>> i_instruction.source_reg_2));
      // Base ISA U-type (upper immediate) operations
      // Load upper immediate
      riscv_pkg::LUI: o_result = XLEN'(signed'(i_immediate_u_type));
      // Add upper immediate to PC
      riscv_pkg::AUIPC: o_result = i_program_counter + XLEN'(signed'(i_immediate_u_type));
      // Jump operations - save return address for function calls
      // Use pre-computed link address from ID stage (PC+2 for compressed, PC+4 for 32-bit)
      riscv_pkg::JAL: o_result = i_link_address;
      riscv_pkg::JALR: o_result = i_link_address;
      // Zicsr extension - CSR read/modify/write operations
      // All CSR instructions return the old CSR value to rd
      // Write operations are handled in the CSR file (read-only CSRs ignore writes)
      riscv_pkg::CSRRW,
      riscv_pkg::CSRRS,
      riscv_pkg::CSRRC,
      riscv_pkg::CSRRWI,
      riscv_pkg::CSRRSI,
      riscv_pkg::CSRRCI: begin
        o_result = i_csr_read_data;
        o_write_enable = 1'b1;
      end
      // Zba extension - address generation (shift-and-add)
      riscv_pkg::SH1ADD: o_result = (i_operand_a << 1) + i_operand_b;
      riscv_pkg::SH2ADD: o_result = (i_operand_a << 2) + i_operand_b;
      riscv_pkg::SH3ADD: o_result = (i_operand_a << 3) + i_operand_b;
      // Zba extension - RV64 unsigned-word address forms (zext32(rs1) base)
      riscv_pkg::ADD_UW: o_result = uw_operand(i_operand_a) + i_operand_b;
      riscv_pkg::SH1ADD_UW: o_result = (uw_operand(i_operand_a) << 1) + i_operand_b;
      riscv_pkg::SH2ADD_UW: o_result = (uw_operand(i_operand_a) << 2) + i_operand_b;
      riscv_pkg::SH3ADD_UW: o_result = (uw_operand(i_operand_a) << 3) + i_operand_b;
      riscv_pkg::SLLI_UW: o_result = uw_operand(i_operand_a) << shamt_imm;
      // Zbs extension - single-bit operations (register form, rs2 index)
      riscv_pkg::BSET: o_result = i_operand_a | (XLEN'(1) << i_operand_b[ShamtMsb:0]);
      riscv_pkg::BCLR: o_result = i_operand_a & ~(XLEN'(1) << i_operand_b[ShamtMsb:0]);
      riscv_pkg::BINV: o_result = i_operand_a ^ (XLEN'(1) << i_operand_b[ShamtMsb:0]);
      riscv_pkg::BEXT: o_result = XLEN'(i_operand_a[i_operand_b[ShamtMsb:0]]);
      // Zbs extension - single-bit operations (immediate form, 6-bit index on RV64)
      riscv_pkg::BSETI: o_result = i_operand_a | (XLEN'(1) << shamt_imm);
      riscv_pkg::BCLRI: o_result = i_operand_a & ~(XLEN'(1) << shamt_imm);
      riscv_pkg::BINVI: o_result = i_operand_a ^ (XLEN'(1) << shamt_imm);
      riscv_pkg::BEXTI: o_result = XLEN'(i_operand_a[shamt_imm]);
      // Zbb extension - logical with complement
      riscv_pkg::ANDN: o_result = i_operand_a & ~i_operand_b;
      riscv_pkg::ORN: o_result = i_operand_a | ~i_operand_b;
      riscv_pkg::XNOR: o_result = ~(i_operand_a ^ i_operand_b);
      // Zbb extension - min/max comparisons
      riscv_pkg::MAX:
      o_result = ($signed(i_operand_a) > $signed(i_operand_b)) ? i_operand_a : i_operand_b;
      riscv_pkg::MAXU: o_result = (i_operand_a > i_operand_b) ? i_operand_a : i_operand_b;
      riscv_pkg::MIN:
      o_result = ($signed(i_operand_a) < $signed(i_operand_b)) ? i_operand_a : i_operand_b;
      riscv_pkg::MINU: o_result = (i_operand_a < i_operand_b) ? i_operand_a : i_operand_b;
      // Zbb extension - rotations using funnel shifter (single barrel shifter, no OR)
      // ROR: {a,a} >> shamt gives lower XLEN bits as rotated result
      riscv_pkg::ROR: o_result = XLEN'({i_operand_a, i_operand_a} >> i_operand_b[ShamtMsb:0]);
      // ROL: equivalent to ROR by (XLEN - shamt); shamt=0 shifts by XLEN (identity)
      riscv_pkg::ROL:
      o_result = XLEN'({i_operand_a, i_operand_a} >>
                       (RotAmtBits'(XLEN) - RotAmtBits'(i_operand_b[ShamtMsb:0])));
      // RORI: rotate right immediate using funnel shifter (6-bit shamt on RV64)
      riscv_pkg::RORI: o_result = XLEN'({i_operand_a, i_operand_a} >> shamt_imm);
      // Zbb extension - RV64 word rotates (32-bit funnel, sext32 result)
      riscv_pkg::RORW:
      o_result = w_result(32'({i_operand_a[31:0], i_operand_a[31:0]} >> i_operand_b[4:0]));
      riscv_pkg::ROLW:
      o_result = w_result(
          32'({i_operand_a[31:0], i_operand_a[31:0]} >> (6'd32 - {1'b0, i_operand_b[4:0]})));
      riscv_pkg::RORIW:
      o_result =
          w_result(32'({i_operand_a[31:0], i_operand_a[31:0]} >> i_instruction.source_reg_2));
      // Zbb extension - count operations (trees defined in riscv_pkg)
      riscv_pkg::CLZ:
      o_result = (XLEN == 64) ? XLEN'(riscv_pkg::clz64(64'(i_operand_a))) :
          XLEN'(riscv_pkg::clz32(i_operand_a[31:0]));
      riscv_pkg::CTZ:
      o_result = (XLEN == 64) ? XLEN'(riscv_pkg::ctz64(64'(i_operand_a))) :
          XLEN'(riscv_pkg::ctz32(i_operand_a[31:0]));
      riscv_pkg::CPOP:
      o_result = (XLEN == 64) ? XLEN'(riscv_pkg::cpop64(64'(i_operand_a))) :
          XLEN'(riscv_pkg::cpop32(i_operand_a[31:0]));
      // Zbb extension - RV64 word counts (counts are <= 32, so sext == zext)
      riscv_pkg::CLZW: o_result = w_result(riscv_pkg::clz32(i_operand_a[31:0]));
      riscv_pkg::CTZW: o_result = w_result(riscv_pkg::ctz32(i_operand_a[31:0]));
      riscv_pkg::CPOPW: o_result = w_result(riscv_pkg::cpop32(i_operand_a[31:0]));
      // Zbb extension - sign extension
      riscv_pkg::SEXT_B: o_result = {{(XLEN - 8) {i_operand_a[7]}}, i_operand_a[7:0]};
      riscv_pkg::SEXT_H: o_result = {{(XLEN - 16) {i_operand_a[15]}}, i_operand_a[15:0]};
      // Zbb extension - byte operations (XLEN-parametric local helpers)
      riscv_pkg::ORC_B: o_result = orc_b_x(i_operand_a);
      riscv_pkg::REV8: o_result = rev8_x(i_operand_a);
      // Zicond extension - conditional zero
      riscv_pkg::CZERO_EQZ: o_result = (i_operand_b == 0) ? '0 : i_operand_a;
      riscv_pkg::CZERO_NEZ: o_result = (i_operand_b != 0) ? '0 : i_operand_a;
      // Zbkb extension - bit manipulation for crypto
      // PACK: pack low XLEN/2 halves from rs1 and rs2 (zext.h at RV32 is pack rs2=0)
      riscv_pkg::PACK: o_result = {i_operand_b[XLEN/2-1:0], i_operand_a[XLEN/2-1:0]};
      // PACKH: pack low bytes from rs1 and rs2 (zero-extended)
      riscv_pkg::PACKH: o_result = {{(XLEN - 16) {1'b0}}, i_operand_b[7:0], i_operand_a[7:0]};
      // PACKW: RV64 pack low halfwords into a sext32 word (zext.h at RV64)
      riscv_pkg::PACKW: o_result = w_result({i_operand_b[15:0], i_operand_a[15:0]});
      // Zbkb extension - bit permutation operations (use helper functions from riscv_pkg)
      riscv_pkg::BREV8: o_result = brev8_x(i_operand_a);  // Bit-reverse each byte
      // ZIP/UNZIP are RV32-only (the decoder rejects them at XLEN=64)
      riscv_pkg::ZIP: o_result = XLEN'(riscv_pkg::zip32(i_operand_a[31:0]));
      riscv_pkg::UNZIP: o_result = XLEN'(riscv_pkg::unzip32(i_operand_a[31:0]));
      // Zihintpause - PAUSE is a hint, treated as NOP (no register write)
      riscv_pkg::PAUSE: o_write_enable = 1'b0;
      // Default: invalid instruction - don't write to register file.
      // M-extension ops land here by design: they execute in the dedicated
      // multiplier/divider unit behind int_muldiv_shim, never in this ALU.
      default: o_write_enable = 1'b0;
    endcase
  end

endmodule : alu
