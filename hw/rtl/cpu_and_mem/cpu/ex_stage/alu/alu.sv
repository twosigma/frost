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
 * Arithmetic logic unit: single-cycle combinational execution unit for the
 * base integer ISA plus Zba, Zbb, Zbs, Zbkb, and Zicond. At XLEN=64 that
 * includes the 6-bit shift, rotate, and bit-index amounts, the W-form word
 * operations (32-bit operation, result sign-extended to XLEN), and the Zba
 * unsigned-word address forms. The unit also forwards the pre-computed link
 * address for JAL/JALR, materializes LUI/AUIPC values, and passes CSR read
 * data through for Zicsr ops. M-extension operations do not execute here.
 * They run in the multiplier and divider behind int_muldiv_shim.
 *
 * The CLZ, CTZ, and CPOP helper trees live in riscv_pkg.sv (Section 10). The
 * byte-granular ORC.B, REV8, and BREV8 helpers below are local and
 * XLEN-parametric.
 * At XLEN=64, base shifts and rotates share a right-funnel barrel per width,
 * with bit reversal for left operations. Projected operation controls avoid a late
 * full-enum decoder; symbolic assertions pin every consuming enum value.
 * This is purely combinational sharing: no issue or completion cycle changes.
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
  localparam int unsigned ShamtMsb = 5;
  logic [ShamtMsb:0] shamt_imm;
  assign shamt_imm = {i_instruction.funct7[0], i_instruction.source_reg_2};

  // RV64 W-form result: operate on the low 32 bits, sign-extend into XLEN.
  function automatic logic [XLEN-1:0] w_result(input logic [31:0] w);
    w_result = {{(XLEN - 32) {w[31]}}, w};
  endfunction

  // Zba unsigned-word operand: rs1's low 32 bits zero-extended to XLEN.
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

  // Legacy non-64-bit ROL fallback width: preserve the original subtraction
  // and oversized-shift behavior rather than reducing its amount modulo XLEN.
  localparam int unsigned RotAmtBits = ShamtMsb + 2;

  // Share register/immediate shift hardware by selecting the amount before
  // the operation family. Decode the operation itself: instruction opcode
  // fields are independent of the operation enum at this module interface.
  logic shift_uses_immediate;
  logic [ShamtMsb:0] shared_shift_amount;
  logic [XLEN-1:0] shared_left_result;
  logic [XLEN-1:0] shared_right_result;
  logic [XLEN-1:0] shared_arithmetic_right_result;
  logic [31:0] shared_word_left_result;
  logic [31:0] shared_word_right_result;
  logic [31:0] shared_word_arithmetic_right_result;
  logic [XLEN-1:0] shared_rotate_result;
  logic [XLEN-1:0] shared_rotate_left_result;
  logic [31:0] shared_word_rotate_result;

  // The barrel result is consumed only by the nine full-width or nine word
  // shift/rotate operations listed in the result case. Projected predicates
  // agree with the symbolic opcode tests on those domains; their values for
  // every other opcode are known 0/1 but unobserved. No opcode is renumbered.
  // The checks below pin this dependency on the established enum encoding.
  // Return {full_left, full_rotate, full_arithmetic, word_left, word_rotate,
  // word_arithmetic, immediate_amount}. The same helper is used by the
  // unconditional symbolic enum-contract assertions below.
  function automatic logic [6:0] projected_shift_controls(input riscv_pkg::instr_op_e op_bits);
    projected_shift_controls[6] = !op_bits[1] && (op_bits[0] ^ (op_bits[4] || op_bits[6]));
    projected_shift_controls[5] = op_bits[6];
    projected_shift_controls[4] = op_bits[1] && (op_bits[0] || op_bits[4]);
    projected_shift_controls[3] = !op_bits[2] && (op_bits[0] ~^ op_bits[1]);
    projected_shift_controls[2] = op_bits[3] && op_bits[4];
    projected_shift_controls[1] = (!op_bits[3] && op_bits[1]) || (op_bits[2] && op_bits[0]);
    projected_shift_controls[0] = (op_bits[3] && op_bits[1]) ||
        (op_bits[7] ? (op_bits[3] && op_bits[2]) : !op_bits[2]);
  endfunction
  logic [6:0] shift_controls;
  assign shift_controls = projected_shift_controls(i_instruction_operation);
  assign shift_uses_immediate = shift_controls[0];

  assign shared_shift_amount = shift_uses_immediate ? shamt_imm : i_operand_b[ShamtMsb:0];

  // Shared right-funnel barrel per width. Left shifts/rotates reverse bits
  // before and after the same barrel; logical, signed, and rotating forms
  // differ only in their upper-half fill.
  logic full_left_mode, full_rotate_mode, full_arithmetic_mode;
  logic word_left_mode, word_rotate_mode, word_arithmetic_mode;
  logic [XLEN-1:0] full_reversed_source, full_barrel_source, full_barrel_fill;
  logic [XLEN-1:0] full_barrel_shifted, full_barrel_result;
  logic [31:0] word_reversed_source, word_barrel_source, word_barrel_fill;
  logic [31:0] word_barrel_shifted, word_barrel_result;

  // Four or fewer opcode bits per mode fit a single LUT. The shared amount
  // selector likewise has four opcode inputs, leaving two LUT6 inputs for
  // the register/immediate data bit; do not preserve an intermediate decoder.
  assign full_left_mode = shift_controls[6];
  assign full_rotate_mode = shift_controls[5];
  assign full_arithmetic_mode = shift_controls[4];
  assign word_left_mode = shift_controls[3];
  assign word_rotate_mode = shift_controls[2];
  assign word_arithmetic_mode = shift_controls[1];

  for (genvar bit_idx = 0; bit_idx < XLEN; bit_idx++) begin : gen_full_reverse
    assign full_reversed_source[bit_idx] = i_operand_a[XLEN-1-bit_idx];
    assign full_barrel_result[bit_idx] = full_left_mode ?
        full_barrel_shifted[XLEN-1-bit_idx] : full_barrel_shifted[bit_idx];
  end
  assign full_barrel_source = full_left_mode ? full_reversed_source : i_operand_a;
  assign full_barrel_fill = full_rotate_mode ? full_barrel_source :
      {XLEN{full_arithmetic_mode && i_operand_a[XLEN-1]}};
  assign full_barrel_shifted = XLEN'({full_barrel_fill, full_barrel_source} >> shared_shift_amount);

  for (genvar bit_idx = 0; bit_idx < 32; bit_idx++) begin : gen_word_reverse
    assign word_reversed_source[bit_idx] = i_operand_a[31-bit_idx];
    assign word_barrel_result[bit_idx] = word_left_mode ?
        word_barrel_shifted[31-bit_idx] : word_barrel_shifted[bit_idx];
  end
  assign word_barrel_source = word_left_mode ? word_reversed_source : i_operand_a[31:0];
  assign word_barrel_fill = word_rotate_mode ? word_barrel_source :
      {32{word_arithmetic_mode && i_operand_a[31]}};
  assign word_barrel_shifted =
      32'({word_barrel_fill, word_barrel_source} >> shared_shift_amount[4:0]);

  // Preserve the legacy full-width rotate behavior for XLEN != 64. In
  // particular, XLEN=32 still accepts six-bit amounts, whose out-of-word
  // behavior differs from modulo32 rotation.
  generate
    if (XLEN == 64) begin : gen_shared_full_barrel64
      assign shared_left_result = full_barrel_result;
      assign shared_right_result = full_barrel_result;
      assign shared_arithmetic_right_result = full_barrel_result;
      assign shared_rotate_result = full_barrel_result;
      assign shared_rotate_left_result = full_barrel_result;
    end else begin : gen_legacy_full_width
      assign shared_left_result = i_operand_a << shared_shift_amount;
      assign shared_right_result = i_operand_a >> shared_shift_amount;
      assign shared_arithmetic_right_result = $signed(i_operand_a) >>> shared_shift_amount;
      assign shared_rotate_result = XLEN'({i_operand_a, i_operand_a} >> shared_shift_amount);
      assign shared_rotate_left_result = XLEN'({i_operand_a, i_operand_a} >>
          (RotAmtBits'(XLEN) - RotAmtBits'(i_operand_b[ShamtMsb:0])));
    end
  endgenerate
  assign shared_word_left_result = word_barrel_result;
  assign shared_word_right_result = word_barrel_result;
  assign shared_word_arithmetic_right_result = word_barrel_result;
  assign shared_word_rotate_result = word_barrel_result;

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
      riscv_pkg::SLL: o_result = shared_left_result;
      riscv_pkg::SRL: o_result = shared_right_result;
      riscv_pkg::SRA:  // Shift right arithmetic (sign-extend)
      o_result = shared_arithmetic_right_result;
      riscv_pkg::SLT: o_result = XLEN'(difference[XLEN]);
      riscv_pkg::SLTU: o_result = XLEN'(sltu);
      // Base ISA I-type (immediate) operations
      riscv_pkg::ADDI: o_result = i_operand_a + operand_b;
      riscv_pkg::ANDI: o_result = i_operand_a & operand_b;
      riscv_pkg::ORI: o_result = i_operand_a | operand_b;
      riscv_pkg::XORI: o_result = i_operand_a ^ operand_b;
      riscv_pkg::SLTI: o_result = XLEN'(difference[XLEN]);
      riscv_pkg::SLTIU: o_result = XLEN'(sltu);
      // Shift immediate operations - shamt in rs2 field (+bit 25 on RV64)
      riscv_pkg::SLLI: o_result = shared_left_result;
      riscv_pkg::SRLI: o_result = shared_right_result;
      riscv_pkg::SRAI: o_result = shared_arithmetic_right_result;
      // RV64 W-form ALU ops: 32-bit operation, result sign-extended to XLEN.
      riscv_pkg::ADDW, riscv_pkg::ADDIW: o_result = w_result(i_operand_a[31:0] + operand_b[31:0]);
      riscv_pkg::SUBW: o_result = w_result(i_operand_a[31:0] - operand_b[31:0]);
      riscv_pkg::SLLW: o_result = w_result(shared_word_left_result);
      riscv_pkg::SRLW: o_result = w_result(shared_word_right_result);
      riscv_pkg::SRAW: o_result = w_result(shared_word_arithmetic_right_result);
      riscv_pkg::SLLIW: o_result = w_result(shared_word_left_result);
      riscv_pkg::SRLIW: o_result = w_result(shared_word_right_result);
      riscv_pkg::SRAIW: o_result = w_result(shared_word_arithmetic_right_result);
      // Base ISA U-type (upper immediate) operations
      riscv_pkg::LUI: o_result = XLEN'(signed'(i_immediate_u_type));
      riscv_pkg::AUIPC: o_result = i_program_counter + XLEN'(signed'(i_immediate_u_type));
      // Jumps write the link address the ID stage precomputed: PC+2 for a
      // compressed instruction, PC+4 otherwise.
      riscv_pkg::JAL: o_result = i_link_address;
      riscv_pkg::JALR: o_result = i_link_address;
      // Zicsr extension: rd gets the old CSR value. The CSR file performs the
      // write side, where read-only CSRs ignore writes.
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
      riscv_pkg::ROR: o_result = shared_rotate_result;
      // ROL shares the full-width barrel through bit reversal at XLEN=64.
      riscv_pkg::ROL: o_result = shared_rotate_left_result;
      // RORI: rotate right immediate using funnel shifter (6-bit shamt on RV64)
      riscv_pkg::RORI: o_result = shared_rotate_result;
      // Zbb extension - RV64 word rotates (32-bit funnel, sext32 result)
      riscv_pkg::RORW: o_result = w_result(shared_word_rotate_result);
      riscv_pkg::ROLW: o_result = w_result(shared_word_rotate_result);
      riscv_pkg::RORIW: o_result = w_result(shared_word_rotate_result);
      // Zbb extension - count operations (trees defined in riscv_pkg)
      riscv_pkg::CLZ: o_result = XLEN'(riscv_pkg::clz64(64'(i_operand_a)));
      riscv_pkg::CTZ: o_result = XLEN'(riscv_pkg::ctz64(64'(i_operand_a)));
      riscv_pkg::CPOP: o_result = XLEN'(riscv_pkg::cpop64(64'(i_operand_a)));
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
      // PACK: pack low XLEN/2 halves from rs1 and rs2
      riscv_pkg::PACK: o_result = {i_operand_b[XLEN/2-1:0], i_operand_a[XLEN/2-1:0]};
      // PACKH: pack low bytes from rs1 and rs2 (zero-extended)
      riscv_pkg::PACKH: o_result = {{(XLEN - 16) {1'b0}}, i_operand_b[7:0], i_operand_a[7:0]};
      // PACKW: RV64 pack low halfwords into a sext32 word (zext.h at RV64)
      riscv_pkg::PACKW: o_result = w_result({i_operand_b[15:0], i_operand_a[15:0]});
      // Zbkb extension - bit permutation (local XLEN-parametric helper)
      riscv_pkg::BREV8: o_result = brev8_x(i_operand_a);
      // Zihintpause - PAUSE is a hint, treated as NOP (no register write)
      riscv_pkg::PAUSE: o_write_enable = 1'b0;
      // Anything not listed above leaves rd untouched. The M-extension ops
      // have no arm here: they execute in the multiplier and divider behind
      // int_muldiv_shim, and a simulation assert in int_alu_shim catches any
      // that issue here.
      default: o_write_enable = 1'b0;
    endcase
  end

`ifndef SYNTHESIS
  // Encoding dependency tripwires use symbolic enum members, so enum edits
  // cannot silently change a projected predicate on a consuming operation.
  // Check every named consumer at time zero, even if no stimulus ever
  // executes that opcode. These are constants, not coverage-dependent checks.
  localparam logic [6:0] ControlsSLL = projected_shift_controls(riscv_pkg::SLL);
  localparam logic [6:0] ControlsSRL = projected_shift_controls(riscv_pkg::SRL);
  localparam logic [6:0] ControlsSRA = projected_shift_controls(riscv_pkg::SRA);
  localparam logic [6:0] ControlsSLLI = projected_shift_controls(riscv_pkg::SLLI);
  localparam logic [6:0] ControlsSRLI = projected_shift_controls(riscv_pkg::SRLI);
  localparam logic [6:0] ControlsSRAI = projected_shift_controls(riscv_pkg::SRAI);
  localparam logic [6:0] ControlsROL = projected_shift_controls(riscv_pkg::ROL);
  localparam logic [6:0] ControlsROR = projected_shift_controls(riscv_pkg::ROR);
  localparam logic [6:0] ControlsRORI = projected_shift_controls(riscv_pkg::RORI);
  localparam logic [6:0] ControlsSLLW = projected_shift_controls(riscv_pkg::SLLW);
  localparam logic [6:0] ControlsSRLW = projected_shift_controls(riscv_pkg::SRLW);
  localparam logic [6:0] ControlsSRAW = projected_shift_controls(riscv_pkg::SRAW);
  localparam logic [6:0] ControlsSLLIW = projected_shift_controls(riscv_pkg::SLLIW);
  localparam logic [6:0] ControlsSRLIW = projected_shift_controls(riscv_pkg::SRLIW);
  localparam logic [6:0] ControlsSRAIW = projected_shift_controls(riscv_pkg::SRAIW);
  localparam logic [6:0] ControlsROLW = projected_shift_controls(riscv_pkg::ROLW);
  localparam logic [6:0] ControlsRORW = projected_shift_controls(riscv_pkg::RORW);
  localparam logic [6:0] ControlsRORIW = projected_shift_controls(riscv_pkg::RORIW);
  always_comb begin
    assert (riscv_pkg::InstrOpWidth == 8);
    assert ({ControlsSLL[6:4], ControlsSLL[0]} == 4'b1000);
    assert ({ControlsSRL[6:4], ControlsSRL[0]} == 4'b0000);
    assert ({ControlsSRA[6:4], ControlsSRA[0]} == 4'b0010);
    assert ({ControlsSLLI[6:4], ControlsSLLI[0]} == 4'b1001);
    assert ({ControlsSRLI[6:4], ControlsSRLI[0]} == 4'b0001);
    assert ({ControlsSRAI[6:4], ControlsSRAI[0]} == 4'b0011);
    assert ({ControlsROL[6:4], ControlsROL[0]} == 4'b1100);
    assert ({ControlsROR[6:4], ControlsROR[0]} == 4'b0100);
    assert ({ControlsRORI[6:4], ControlsRORI[0]} == 4'b0101);
    assert ({ControlsSLLW[3:1], ControlsSLLW[0]} == 4'b1000);
    assert ({ControlsSRLW[3:1], ControlsSRLW[0]} == 4'b0000);
    assert ({ControlsSRAW[3:1], ControlsSRAW[0]} == 4'b0010);
    assert ({ControlsSLLIW[3:1], ControlsSLLIW[0]} == 4'b1001);
    assert ({ControlsSRLIW[3:1], ControlsSRLIW[0]} == 4'b0001);
    assert ({ControlsSRAIW[3:1], ControlsSRAIW[0]} == 4'b0011);
    assert ({ControlsROLW[3:1], ControlsROLW[0]} == 4'b1100);
    assert ({ControlsRORW[3:1], ControlsRORW[0]} == 4'b0100);
    assert ({ControlsRORIW[3:1], ControlsRORIW[0]} == 4'b0101);
  end
  always_comb begin
    case (i_instruction_operation)
      riscv_pkg::SLL, riscv_pkg::SRL, riscv_pkg::SRA,
      riscv_pkg::SLLI, riscv_pkg::SRLI, riscv_pkg::SRAI,
      riscv_pkg::ROL, riscv_pkg::ROR, riscv_pkg::RORI: begin
        assert (full_left_mode == (i_instruction_operation == riscv_pkg::SLL ||
            i_instruction_operation == riscv_pkg::SLLI ||
            i_instruction_operation == riscv_pkg::ROL));
        assert (full_rotate_mode == (i_instruction_operation == riscv_pkg::ROL ||
            i_instruction_operation == riscv_pkg::ROR ||
            i_instruction_operation == riscv_pkg::RORI));
        assert (full_arithmetic_mode == (i_instruction_operation == riscv_pkg::SRA ||
            i_instruction_operation == riscv_pkg::SRAI));
        assert (shift_uses_immediate == (i_instruction_operation == riscv_pkg::SLLI ||
            i_instruction_operation == riscv_pkg::SRLI ||
            i_instruction_operation == riscv_pkg::SRAI ||
            i_instruction_operation == riscv_pkg::RORI));
      end
      riscv_pkg::SLLW, riscv_pkg::SRLW, riscv_pkg::SRAW,
      riscv_pkg::SLLIW, riscv_pkg::SRLIW, riscv_pkg::SRAIW,
      riscv_pkg::ROLW, riscv_pkg::RORW, riscv_pkg::RORIW: begin
        assert (word_left_mode == (i_instruction_operation == riscv_pkg::SLLW ||
            i_instruction_operation == riscv_pkg::SLLIW ||
            i_instruction_operation == riscv_pkg::ROLW));
        assert (word_rotate_mode == (i_instruction_operation == riscv_pkg::ROLW ||
            i_instruction_operation == riscv_pkg::RORW ||
            i_instruction_operation == riscv_pkg::RORIW));
        assert (word_arithmetic_mode == (i_instruction_operation == riscv_pkg::SRAW ||
            i_instruction_operation == riscv_pkg::SRAIW));
        assert (shift_uses_immediate == (i_instruction_operation == riscv_pkg::SLLIW ||
            i_instruction_operation == riscv_pkg::SRLIW ||
            i_instruction_operation == riscv_pkg::SRAIW ||
            i_instruction_operation == riscv_pkg::RORIW));
      end
      default: begin
      end
    endcase
  end
`endif

endmodule : alu
