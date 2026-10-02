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
 * unsigned-word address forms. The unit also returns the precomputed link
 * address for JAL/JALR and the LUI/AUIPC values (ID precomputes AUIPC's
 * PC + imm_u and dispatch passes it in the U-immediate, so the unit has no PC
 * input). M-extension operations never execute here; they run in the
 * multiplier and divider behind int_muldiv_shim. Zicsr operations have no
 * result of their own here either: int_alu_shim supplies the CSR write operand
 * through i_side_result (below), and the CSR is read and written at commit.
 *
 * At XLEN=64, the base shifts and the Zbb rotates of each width share one
 * left and one right funnel shifter. Their controls come from
 * riscv_pkg::projected_shift_controls, where each control reads at most four
 * operation-enum bits instead of decoding the full enum; the assertions at
 * the bottom check the controls this unit uses for each of those operations.
 *
 * Result selection. Each operation group (logic, Zbs, immediates and links,
 * byte and pack, ORC.B, base and W add/sub, Zba, shifts and rotates, min/max
 * and CZERO, counts, set-less-than and BEXT) forms its own result bus, masked
 * to zero unless the operation is one of the group's. The shallow groups and
 * i_side_result pre-merge into result_early and the deep ones join it at the
 * final OR, so each result bit ends in one OR of at most six buses instead of
 * a wide per-bit case mux. An operation no group lists, PAUSE among them,
 * returns i_side_result, which the caller drives to zero for every operation
 * that has a group.
 *
 * i_side_result is the caller's own value for operations without a group
 * (int_alu_shim: the CSR write operand and the fetch-fault value). Taking it
 * into result_early, instead of muxing it in after o_result, keeps the
 * caller's override off the result's last LUT level. keep_hierarchy keeps
 * that boundary and the group buses intact in the core, where synthesis would
 * otherwise re-factor them with the shim and the reservation station.
 */

(* keep_hierarchy = "yes" *)
module alu #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    // 1: shift by i_shift_amount_hint, which the caller computes with its
    // issue operands and must equal the amount this unit would select. 0
    // selects the amount locally.
    parameter bit USE_SHIFT_AMOUNT_HINT = 1'b0
) (
    input riscv_pkg::instr_t i_instruction,
    input riscv_pkg::instr_op_e i_instruction_operation,
    input logic [XLEN-1:0] i_operand_a,  // First operand (typically rs1 value)
    input logic [XLEN-1:0] i_operand_b,  // Second operand (typically rs2 value or immediate)
    input logic [5:0] i_shift_amount_hint,
    input logic [XLEN-1:0] i_immediate_u_type,  // Upper immediate for LUI/AUIPC
    input logic [XLEN-1:0] i_immediate_i_type,  // I-type immediate
    input logic [XLEN-1:0] i_link_address,  // Pre-computed link address (PC+2 or PC+4)
    // OR'ed into the result; zero for every operation that has a group (see
    // the header). Callers without such operations tie it to zero.
    input logic [XLEN-1:0] i_side_result,
    output logic [XLEN-1:0] o_result
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

  // Width of the XLEN != 64 ROL amount subtraction (XLEN - amount); the
  // amount is not reduced modulo XLEN.
  localparam int unsigned RotAmtBits = ShamtMsb + 2;

  // Register and immediate shifts share the shift hardware: the amount is
  // selected first. Decode the operation itself: at this module interface
  // the instruction's opcode field is independent of the operation enum.
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

  // Only the nine full-width and nine word shift/rotate operations in the
  // result selection consume the barrel results. On those operations the
  // projected controls equal the symbolic operation tests; for any other
  // operation their values are unobserved. The checks below tie this to the
  // current enum encoding. The RS computes the INT port-1 shift-amount hint
  // with the same package function, so these checks cover it too.
  logic [6:0] shift_controls;
  assign shift_controls = riscv_pkg::projected_shift_controls(i_instruction_operation);
  assign shift_uses_immediate = shift_controls[0];

  assign shared_shift_amount = USE_SHIFT_AMOUNT_HINT ? i_shift_amount_hint :
      (shift_uses_immediate ? shamt_imm : i_operand_b[ShamtMsb:0]);

  // The left and right funnels share the effective amount. Logical,
  // arithmetic, and rotate forms differ only in the fill, so no data is
  // selected or reversed by direction before or after the shift tree.
  logic full_rotate_mode, full_arithmetic_mode;
  logic word_rotate_mode, word_arithmetic_mode;
  logic [XLEN-1:0] full_barrel_fill;
  logic [XLEN-1:0] full_barrel_result;
  logic [31:0] word_barrel_fill;
  logic [31:0] word_barrel_result;

  // Each mode reads four or fewer operation bits, so it fits a single LUT.
  // The shared amount select also reads four operation bits, leaving two
  // LUT6 inputs for the register and immediate amount bits; do not preserve
  // an intermediate decoder.
  assign full_rotate_mode = shift_controls[5];
  assign full_arithmetic_mode = shift_controls[4];
  assign word_rotate_mode = shift_controls[2];
  assign word_arithmetic_mode = shift_controls[1];

  // Take the high half of a left funnel and the low half of a right funnel.
  // A zero amount returns the source, including both rotate directions.
  logic [2*XLEN-1:0] full_left_wide;
  logic [XLEN-1:0] full_left_result;
  logic [63:0] word_left_wide;
  logic [31:0] word_left_result;
  assign full_barrel_fill = full_rotate_mode ? i_operand_a :
      {XLEN{full_arithmetic_mode && i_operand_a[XLEN-1]}};
  assign full_barrel_result = XLEN'({full_barrel_fill, i_operand_a} >> shared_shift_amount);
  assign full_left_wide =
      {i_operand_a, full_rotate_mode ? i_operand_a : {XLEN{1'b0}}} << shared_shift_amount;
  assign full_left_result = full_left_wide[2*XLEN-1:XLEN];
  assign word_barrel_fill = word_rotate_mode ? i_operand_a[31:0] :
      {32{word_arithmetic_mode && i_operand_a[31]}};
  assign word_barrel_result =
      32'({word_barrel_fill, i_operand_a[31:0]} >> shared_shift_amount[4:0]);
  assign word_left_wide =
      {i_operand_a[31:0], word_rotate_mode ? i_operand_a[31:0] : 32'b0} << shared_shift_amount[4:0];
  assign word_left_result = word_left_wide[63:32];

  // For XLEN != 64 the full-width results use plain shift operators. At
  // XLEN=32 the amounts are six bits wide, and amounts past the word do not
  // behave like rotation modulo 32.
  generate
    if (XLEN == 64) begin : gen_shared_full_barrel64
      assign shared_left_result = full_left_result;
      assign shared_right_result = full_barrel_result;
      assign shared_arithmetic_right_result = full_barrel_result;
      assign shared_rotate_result = full_barrel_result;
      assign shared_rotate_left_result = full_left_result;
    end else begin : gen_legacy_full_width
      assign shared_left_result = i_operand_a << shared_shift_amount;
      assign shared_right_result = i_operand_a >> shared_shift_amount;
      assign shared_arithmetic_right_result = $signed(i_operand_a) >>> shared_shift_amount;
      assign shared_rotate_result = XLEN'({i_operand_a, i_operand_a} >> shared_shift_amount);
      assign shared_rotate_left_result = XLEN'({i_operand_a, i_operand_a} >>
          (RotAmtBits'(XLEN) - RotAmtBits'(i_operand_b[ShamtMsb:0])));
    end
  endgenerate
  assign shared_word_left_result = word_left_result;
  assign shared_word_right_result = word_barrel_result;
  assign shared_word_arithmetic_right_result = word_barrel_result;
  assign shared_word_rotate_result = word_barrel_result;

  // Explicit masks make unselected leaves zero, even when their data is X.
  // Passing each value as a function argument evaluates it at XLEN bits.
  function automatic logic [XLEN-1:0] mask_result(input logic enable, input logic [XLEN-1:0] value);
    mask_result = {XLEN{enable}} & value;
  endfunction

  // Base logic uses opcode-selected operand_b; complemented logic uses raw rs2.
  logic [5:0] select_logic;
  (* keep = "true" *) logic [XLEN-1:0] result_logic;
  assign select_logic[0] = (i_instruction_operation == riscv_pkg::AND) ||
      (i_instruction_operation == riscv_pkg::ANDI);
  assign select_logic[1] = (i_instruction_operation == riscv_pkg::OR) ||
      (i_instruction_operation == riscv_pkg::ORI);
  assign select_logic[2] = (i_instruction_operation == riscv_pkg::XOR) ||
      (i_instruction_operation == riscv_pkg::XORI);
  assign select_logic[3] = (i_instruction_operation == riscv_pkg::ANDN);
  assign select_logic[4] = (i_instruction_operation == riscv_pkg::ORN);
  assign select_logic[5] = (i_instruction_operation == riscv_pkg::XNOR);
  // Truth-table order is {a,b} = 00, 01, 10, 11. Every inactive
  // operation supplies four zeros, so this LUT also masks the result.
  logic [3:0] logic_truth;
  logic [XLEN-1:0] logic_operand_b;
  assign logic_operand_b = ((|select_logic[2:0]) && op_is_imm_not_reg(
      i_instruction.opcode
  )) ? i_immediate_i_type : i_operand_b;
  assign logic_truth[0] = select_logic[4] | select_logic[5];
  assign logic_truth[1] = select_logic[1] | select_logic[2];
  assign logic_truth[2] = select_logic[1] | select_logic[2] | select_logic[3] | select_logic[4];
  assign logic_truth[3] = select_logic[0] | select_logic[1] | select_logic[4] | select_logic[5];
  for (genvar bit_index = 0; bit_index < XLEN; bit_index++) begin : gen_logic_truth
    assign result_logic[bit_index] = i_operand_a[bit_index] ?
        (logic_operand_b[bit_index] ? logic_truth[3] : logic_truth[2]) :
        (logic_operand_b[bit_index] ? logic_truth[1] : logic_truth[0]);
  end

  // Zbs register forms index with rs2[5:0], immediate forms with the shamt field.
  logic [5:0] select_zbs;
  (* keep = "true" *) logic [XLEN-1:0] result_zbs;
  assign select_zbs[0] = (i_instruction_operation == riscv_pkg::BSET);
  assign select_zbs[1] = (i_instruction_operation == riscv_pkg::BSETI);
  assign select_zbs[2] = (i_instruction_operation == riscv_pkg::BCLR);
  assign select_zbs[3] = (i_instruction_operation == riscv_pkg::BCLRI);
  assign select_zbs[4] = (i_instruction_operation == riscv_pkg::BINV);
  assign select_zbs[5] = (i_instruction_operation == riscv_pkg::BINVI);
  // Each update has one enabled mask. With bit m selected:
  // BSET preserves a and sets m; BCLR removes m; BINV toggles m.
  logic [XLEN-1:0] zbs_register_mask, zbs_immediate_mask;
  logic [XLEN-1:0] zbs_set_mask, zbs_clear_mask, zbs_invert_mask;
  assign zbs_register_mask = XLEN'(1) << i_operand_b[ShamtMsb:0];
  assign zbs_immediate_mask = XLEN'(1) << shamt_imm;
  assign zbs_set_mask = mask_result(
      select_zbs[0], zbs_register_mask
  ) | mask_result(
      select_zbs[1], zbs_immediate_mask
  );
  assign zbs_clear_mask = mask_result(
      select_zbs[2], zbs_register_mask
  ) | mask_result(
      select_zbs[3], zbs_immediate_mask
  );
  assign zbs_invert_mask = mask_result(
      select_zbs[4], zbs_register_mask
  ) | mask_result(
      select_zbs[5], zbs_immediate_mask
  );
  assign result_zbs = (mask_result(
      |select_zbs, i_operand_a
  ) & ~(zbs_clear_mask | zbs_invert_mask)) | (~i_operand_a & zbs_invert_mask) | zbs_set_mask;

  // AUIPC is already PC + imm_u; JAL/JALR use the supplied link address.
  logic [1:0] select_immediate;
  (* keep = "true" *) logic [XLEN-1:0] result_immediate;
  assign select_immediate[0] = (i_instruction_operation == riscv_pkg::LUI) ||
      (i_instruction_operation == riscv_pkg::AUIPC);
  assign select_immediate[1] = (i_instruction_operation == riscv_pkg::JAL) ||
      (i_instruction_operation == riscv_pkg::JALR);
  assign result_immediate = mask_result(
      select_immediate[0], XLEN'(signed'(i_immediate_u_type))
  ) | mask_result(
      select_immediate[1], i_link_address
  );

  // Byte permutations, sign extensions, and packs.
  logic [6:0] select_byte;
  (* keep = "true" *) logic [XLEN-1:0] result_byte;
  assign select_byte[0] = (i_instruction_operation == riscv_pkg::SEXT_B);
  assign select_byte[1] = (i_instruction_operation == riscv_pkg::SEXT_H);
  assign select_byte[2] = (i_instruction_operation == riscv_pkg::REV8);
  assign select_byte[3] = (i_instruction_operation == riscv_pkg::PACK);
  assign select_byte[4] = (i_instruction_operation == riscv_pkg::PACKH);
  assign select_byte[5] = (i_instruction_operation == riscv_pkg::PACKW);
  assign select_byte[6] = (i_instruction_operation == riscv_pkg::BREV8);
  assign result_byte = mask_result(
      select_byte[0], {{(XLEN - 8) {i_operand_a[7]}}, i_operand_a[7:0]}
  ) | mask_result(
      select_byte[1], {{(XLEN - 16) {i_operand_a[15]}}, i_operand_a[15:0]}
  ) | mask_result(
      select_byte[2], rev8_x(i_operand_a)
  ) | mask_result(
      select_byte[3], {i_operand_b[XLEN/2-1:0], i_operand_a[XLEN/2-1:0]}
  ) | mask_result(
      select_byte[4], {{(XLEN - 16) {1'b0}}, i_operand_b[7:0], i_operand_a[7:0]}
  ) | mask_result(
      select_byte[5], w_result({i_operand_b[15:0], i_operand_a[15:0]})
  ) | mask_result(
      select_byte[6], brev8_x(i_operand_a)
  );

  // Keep byte OR-reduction out of the byte/pack selection tree.
  logic [0:0] select_orc;
  (* keep = "true" *) logic [XLEN-1:0] result_orc;
  assign select_orc[0] = (i_instruction_operation == riscv_pkg::ORC_B);
  assign result_orc = mask_result(select_orc[0], orc_b_x(i_operand_a));

  // Base and W add/sub results run in parallel on the shared operand_b.
  logic [3:0] select_arithmetic;
  (* keep = "true" *) logic [XLEN-1:0] result_arithmetic;
  assign select_arithmetic[0] = (i_instruction_operation == riscv_pkg::ADD) ||
      (i_instruction_operation == riscv_pkg::ADDI);
  assign select_arithmetic[1] = (i_instruction_operation == riscv_pkg::SUB);
  assign select_arithmetic[2] = (i_instruction_operation == riscv_pkg::ADDW) ||
      (i_instruction_operation == riscv_pkg::ADDIW);
  assign select_arithmetic[3] = (i_instruction_operation == riscv_pkg::SUBW);
  assign result_arithmetic = mask_result(
      select_arithmetic[0], i_operand_a + operand_b
  ) | mask_result(
      select_arithmetic[1], difference[XLEN-1:0]
  ) | mask_result(
      select_arithmetic[2], w_result(i_operand_a[31:0] + operand_b[31:0])
  ) | mask_result(
      select_arithmetic[3], w_result(i_operand_a[31:0] - operand_b[31:0])
  );

  // Zba adders have a separate late result bus.
  logic [6:0] select_zba;
  (* keep = "true" *) logic [XLEN-1:0] result_zba;
  assign select_zba[0] = (i_instruction_operation == riscv_pkg::SH1ADD);
  assign select_zba[1] = (i_instruction_operation == riscv_pkg::SH2ADD);
  assign select_zba[2] = (i_instruction_operation == riscv_pkg::SH3ADD);
  assign select_zba[3] = (i_instruction_operation == riscv_pkg::ADD_UW);
  assign select_zba[4] = (i_instruction_operation == riscv_pkg::SH1ADD_UW);
  assign select_zba[5] = (i_instruction_operation == riscv_pkg::SH2ADD_UW);
  assign select_zba[6] = (i_instruction_operation == riscv_pkg::SH3ADD_UW);
  assign result_zba = mask_result(
      select_zba[0], (i_operand_a << 1) + i_operand_b
  ) | mask_result(
      select_zba[1], (i_operand_a << 2) + i_operand_b
  ) | mask_result(
      select_zba[2], (i_operand_a << 3) + i_operand_b
  ) | mask_result(
      select_zba[3], uw_operand(i_operand_a) + i_operand_b
  ) | mask_result(
      select_zba[4], (uw_operand(i_operand_a) << 1) + i_operand_b
  ) | mask_result(
      select_zba[5], (uw_operand(i_operand_a) << 2) + i_operand_b
  ) | mask_result(
      select_zba[6], (uw_operand(i_operand_a) << 3) + i_operand_b
  );

  // Shifts and rotates take their results from the shared funnels above.
  logic [9:0] select_shift;
  (* keep = "true" *) logic [XLEN-1:0] result_shift;
  assign select_shift[0] = (i_instruction_operation == riscv_pkg::SLL) ||
      (i_instruction_operation == riscv_pkg::SLLI);
  assign select_shift[1] = (i_instruction_operation == riscv_pkg::SRL) ||
      (i_instruction_operation == riscv_pkg::SRLI);
  assign select_shift[2] = (i_instruction_operation == riscv_pkg::SRA) ||
      (i_instruction_operation == riscv_pkg::SRAI);
  assign select_shift[3] = (i_instruction_operation == riscv_pkg::ROL);
  assign select_shift[4] = (i_instruction_operation == riscv_pkg::ROR) ||
      (i_instruction_operation == riscv_pkg::RORI);
  assign select_shift[5] = (i_instruction_operation == riscv_pkg::SLLW) ||
      (i_instruction_operation == riscv_pkg::SLLIW) ||
      (i_instruction_operation == riscv_pkg::ROLW);
  assign select_shift[6] = (i_instruction_operation == riscv_pkg::SRLW) ||
      (i_instruction_operation == riscv_pkg::SRLIW);
  assign select_shift[7] = (i_instruction_operation == riscv_pkg::SRAW) ||
      (i_instruction_operation == riscv_pkg::SRAIW);
  assign select_shift[8] = (i_instruction_operation == riscv_pkg::RORW) ||
      (i_instruction_operation == riscv_pkg::RORIW);
  assign select_shift[9] = (i_instruction_operation == riscv_pkg::SLLI_UW);
  // Each width selects its direction first, so the group combines three buses.
  logic [XLEN-1:0] selected_full_shift;
  logic [XLEN-1:0] selected_word_shift;
  generate
    if (XLEN == 64) begin : gen_select_full_shift64
      assign selected_full_shift = mask_result(
          |select_shift[4:0],
          (select_shift[0] | select_shift[3]) ? shared_left_result : shared_right_result
      );
    end else begin : gen_select_legacy_full_shift
      assign selected_full_shift = mask_result(
          select_shift[0], shared_left_result
      ) | mask_result(
          select_shift[1], shared_right_result
      ) | mask_result(
          select_shift[2], shared_arithmetic_right_result
      ) | mask_result(
          select_shift[3], shared_rotate_left_result
      ) | mask_result(
          select_shift[4], shared_rotate_result
      );
    end
  endgenerate
  assign selected_word_shift = mask_result(
      |select_shift[8:5],
      w_result(
          select_shift[5] ? shared_word_left_result : shared_word_right_result)
  );
  assign result_shift = selected_full_shift | selected_word_shift | mask_result(
      select_shift[9], uw_operand(i_operand_a) << shamt_imm
  );

  // Min/max and CZERO select raw rs1/rs2 data.
  logic [5:0] select_minmax;
  (* keep = "true" *) logic [XLEN-1:0] result_minmax;
  assign select_minmax[0] = (i_instruction_operation == riscv_pkg::MAX);
  assign select_minmax[1] = (i_instruction_operation == riscv_pkg::MAXU);
  assign select_minmax[2] = (i_instruction_operation == riscv_pkg::MIN);
  assign select_minmax[3] = (i_instruction_operation == riscv_pkg::MINU);
  assign select_minmax[4] = (i_instruction_operation == riscv_pkg::CZERO_EQZ);
  assign select_minmax[5] = (i_instruction_operation == riscv_pkg::CZERO_NEZ);
  assign result_minmax = mask_result(
      select_minmax[0], ($signed(i_operand_a) > $signed(i_operand_b)) ? i_operand_a : i_operand_b
  ) | mask_result(
      select_minmax[1], (i_operand_a > i_operand_b) ? i_operand_a : i_operand_b
  ) | mask_result(
      select_minmax[2], ($signed(i_operand_a) < $signed(i_operand_b)) ? i_operand_a : i_operand_b
  ) | mask_result(
      select_minmax[3], (i_operand_a < i_operand_b) ? i_operand_a : i_operand_b
  ) | mask_result(
      select_minmax[4], (i_operand_b == 0) ? '0 : i_operand_a
  ) | mask_result(
      select_minmax[5], (i_operand_b != 0) ? '0 : i_operand_a
  );

  // Counts use the package trees; the W forms sign-extend their 32-bit counts.
  logic [5:0] select_count;
  (* keep = "true" *) logic [XLEN-1:0] result_count;
  assign select_count[0] = (i_instruction_operation == riscv_pkg::CLZ);
  assign select_count[1] = (i_instruction_operation == riscv_pkg::CTZ);
  assign select_count[2] = (i_instruction_operation == riscv_pkg::CPOP);
  assign select_count[3] = (i_instruction_operation == riscv_pkg::CLZW);
  assign select_count[4] = (i_instruction_operation == riscv_pkg::CTZW);
  assign select_count[5] = (i_instruction_operation == riscv_pkg::CPOPW);
  // Keep each full/word count pair local before the three-way merge.
  (* keep = "true" *) logic [XLEN-1:0] result_clz, result_ctz, result_cpop;
  assign result_clz = mask_result(
      select_count[0], XLEN'(riscv_pkg::clz64(64'(i_operand_a)))
  ) | mask_result(
      select_count[3], w_result(riscv_pkg::clz32(i_operand_a[31:0]))
  );
  assign result_ctz = mask_result(
      select_count[1], XLEN'(riscv_pkg::ctz64(64'(i_operand_a)))
  ) | mask_result(
      select_count[4], w_result(riscv_pkg::ctz32(i_operand_a[31:0]))
  );
  assign result_cpop = mask_result(
      select_count[2], XLEN'(riscv_pkg::cpop64(64'(i_operand_a)))
  ) | mask_result(
      select_count[5], w_result(riscv_pkg::cpop32(i_operand_a[31:0]))
  );
  assign result_count = result_clz | result_ctz | result_cpop;

  // SLT and SLTU use difference (operand_b); BEXT indexes with raw i_operand_b.
  logic [3:0] select_condition;
  (* keep = "true" *) logic [XLEN-1:0] result_condition;
  assign select_condition[0] = (i_instruction_operation == riscv_pkg::SLT) ||
      (i_instruction_operation == riscv_pkg::SLTI);
  assign select_condition[1] = (i_instruction_operation == riscv_pkg::SLTU) ||
      (i_instruction_operation == riscv_pkg::SLTIU);
  assign select_condition[2] = (i_instruction_operation == riscv_pkg::BEXT);
  assign select_condition[3] = (i_instruction_operation == riscv_pkg::BEXTI);
  assign result_condition = mask_result(
      select_condition[0], XLEN'(difference[XLEN])
  ) | mask_result(
      select_condition[1], XLEN'(sltu)
  ) | mask_result(
      select_condition[2], XLEN'(i_operand_a[i_operand_b[ShamtMsb:0]])
  ) | mask_result(
      select_condition[3], XLEN'(i_operand_a[shamt_imm])
  );

  // The count bus is zero above bit 6; the predicate bus is zero above bit 0.
  // Arithmetic bit zero has no carry propagation: pre-merge just its two
  // groups, allowing every other group to enter the final OR directly. The
  // caller's side result is shallow too and fills result_early's sixth input.
  (* keep = "true" *) logic [XLEN-1:0] result_early;
  (* keep = "true" *) logic result_low_arithmetic;
  assign result_early = result_logic | result_zbs | result_immediate | result_byte | result_orc |
      i_side_result;
  assign result_low_arithmetic = result_arithmetic[0] | result_zba[0];
  assign o_result[0] = result_early[0] | result_low_arithmetic | result_shift[0] |
      result_minmax[0] | result_count[0] | result_condition[0];
  assign o_result[XLEN-1:1] = result_early[XLEN-1:1] | result_arithmetic[XLEN-1:1] |
      result_zba[XLEN-1:1] | result_shift[XLEN-1:1] |
      result_minmax[XLEN-1:1] | result_count[XLEN-1:1];

`ifndef SYNTHESIS
  // These checks name each consuming operation by its enum member, so an enum
  // change that alters a projected control for any of them fails at time
  // zero, whether or not a test ever executes that operation.
  localparam logic [6:0] ControlsSLL   = riscv_pkg::projected_shift_controls(riscv_pkg::SLL);
  localparam logic [6:0] ControlsSRL   = riscv_pkg::projected_shift_controls(riscv_pkg::SRL);
  localparam logic [6:0] ControlsSRA   = riscv_pkg::projected_shift_controls(riscv_pkg::SRA);
  localparam logic [6:0] ControlsSLLI  = riscv_pkg::projected_shift_controls(riscv_pkg::SLLI);
  localparam logic [6:0] ControlsSRLI  = riscv_pkg::projected_shift_controls(riscv_pkg::SRLI);
  localparam logic [6:0] ControlsSRAI  = riscv_pkg::projected_shift_controls(riscv_pkg::SRAI);
  localparam logic [6:0] ControlsROL   = riscv_pkg::projected_shift_controls(riscv_pkg::ROL);
  localparam logic [6:0] ControlsROR   = riscv_pkg::projected_shift_controls(riscv_pkg::ROR);
  localparam logic [6:0] ControlsRORI  = riscv_pkg::projected_shift_controls(riscv_pkg::RORI);
  localparam logic [6:0] ControlsSLLW  = riscv_pkg::projected_shift_controls(riscv_pkg::SLLW);
  localparam logic [6:0] ControlsSRLW  = riscv_pkg::projected_shift_controls(riscv_pkg::SRLW);
  localparam logic [6:0] ControlsSRAW  = riscv_pkg::projected_shift_controls(riscv_pkg::SRAW);
  localparam logic [6:0] ControlsSLLIW = riscv_pkg::projected_shift_controls(riscv_pkg::SLLIW);
  localparam logic [6:0] ControlsSRLIW = riscv_pkg::projected_shift_controls(riscv_pkg::SRLIW);
  localparam logic [6:0] ControlsSRAIW = riscv_pkg::projected_shift_controls(riscv_pkg::SRAIW);
  localparam logic [6:0] ControlsROLW  = riscv_pkg::projected_shift_controls(riscv_pkg::ROLW);
  localparam logic [6:0] ControlsRORW  = riscv_pkg::projected_shift_controls(riscv_pkg::RORW);
  localparam logic [6:0] ControlsRORIW = riscv_pkg::projected_shift_controls(riscv_pkg::RORIW);
  always_comb begin
    assert (riscv_pkg::InstrOpWidth == 8);
    assert ({ControlsSLL[5:4], ControlsSLL[0]} == 3'b000);
    assert ({ControlsSRL[5:4], ControlsSRL[0]} == 3'b000);
    assert ({ControlsSRA[5:4], ControlsSRA[0]} == 3'b010);
    assert ({ControlsSLLI[5:4], ControlsSLLI[0]} == 3'b001);
    assert ({ControlsSRLI[5:4], ControlsSRLI[0]} == 3'b001);
    assert ({ControlsSRAI[5:4], ControlsSRAI[0]} == 3'b011);
    assert ({ControlsROL[5:4], ControlsROL[0]} == 3'b100);
    assert ({ControlsROR[5:4], ControlsROR[0]} == 3'b100);
    assert ({ControlsRORI[5:4], ControlsRORI[0]} == 3'b101);
    assert ({ControlsSLLW[2:1], ControlsSLLW[0]} == 3'b000);
    assert ({ControlsSRLW[2:1], ControlsSRLW[0]} == 3'b000);
    assert ({ControlsSRAW[2:1], ControlsSRAW[0]} == 3'b010);
    assert ({ControlsSLLIW[2:1], ControlsSLLIW[0]} == 3'b001);
    assert ({ControlsSRLIW[2:1], ControlsSRLIW[0]} == 3'b001);
    assert ({ControlsSRAIW[2:1], ControlsSRAIW[0]} == 3'b011);
    assert ({ControlsROLW[2:1], ControlsROLW[0]} == 3'b100);
    assert ({ControlsRORW[2:1], ControlsRORW[0]} == 3'b100);
    assert ({ControlsRORIW[2:1], ControlsRORIW[0]} == 3'b101);
  end
  always_comb begin
    case (i_instruction_operation)
      riscv_pkg::SLL, riscv_pkg::SRL, riscv_pkg::SRA,
      riscv_pkg::SLLI, riscv_pkg::SRLI, riscv_pkg::SRAI,
      riscv_pkg::ROL, riscv_pkg::ROR, riscv_pkg::RORI: begin
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
