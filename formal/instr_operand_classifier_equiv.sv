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

// Checks instr_operand_classifier, which classifies operands directly from
// the instruction fields, against a reference that decodes the operation enum
// with instr_decoder and classifies it by operation lists. Covers every
// instruction bit pattern and every combination of injected NOP, illegal
// flag, and fetch fault.
module instr_operand_classifier_equiv (
    input riscv_pkg::instr_t i_instr,
    input logic i_inject_nop,
    input logic i_pd_illegal,
    input logic i_fetch_fault
);
  riscv_pkg::instr_t instruction;
  riscv_pkg::instr_op_e instruction_operation;
  logic decoder_illegal, is_illegal_instruction, is_fetch_fault;
  assign instruction = i_inject_nop ? riscv_pkg::NOP : i_instr;
  assign is_illegal_instruction = decoder_illegal || i_pd_illegal;
  assign is_fetch_fault = i_fetch_fault;
  instr_decoder decoder (
      .i_instr(instruction),
      .o_instr_op(instruction_operation),
      .o_illegal(decoder_illegal)
  );
  riscv_pkg::instr_op_e op_for_pre_decode;
  assign op_for_pre_decode = is_fetch_fault ? riscv_pkg::FETCH_FAULT :
      is_illegal_instruction ? riscv_pkg::ILLEGAL : instruction_operation;

  logic has_int_dest_pre;
  logic has_fp_dest_pre;
  logic uses_int_rs1_pre;
  logic uses_int_rs2_pre;
  logic uses_fp_rs1_pre;
  logic uses_fp_rs2_pre;
  logic uses_fp_rs3_pre;
  logic [2:0] rs_type_pre;
  logic is_int_store_pre;
  logic is_branch_or_jump_pre;
  logic is_fence_pre;
  logic is_fence_i_pre;
  logic is_sfence_vma_pre;
  logic is_csr_imm_pre;
  logic has_fp_flags_pre;
  logic needs_lq_pre;
  logic needs_sq_pre;

  always_comb begin
    case (op_for_pre_decode)
      riscv_pkg::ADD, riscv_pkg::SUB, riscv_pkg::AND,
      riscv_pkg::OR, riscv_pkg::XOR, riscv_pkg::SLL,
      riscv_pkg::SRL, riscv_pkg::SRA,
      riscv_pkg::SLT, riscv_pkg::SLTU,
      riscv_pkg::ADDI, riscv_pkg::ANDI, riscv_pkg::ORI,
      riscv_pkg::XORI, riscv_pkg::SLTI,
      riscv_pkg::SLTIU, riscv_pkg::SLLI,
      riscv_pkg::SRLI, riscv_pkg::SRAI,
      riscv_pkg::LUI, riscv_pkg::AUIPC, riscv_pkg::JALR,
      riscv_pkg::BEQ, riscv_pkg::BNE, riscv_pkg::BLT,
      riscv_pkg::BGE, riscv_pkg::BLTU, riscv_pkg::BGEU,
      riscv_pkg::SH1ADD, riscv_pkg::SH2ADD,
      riscv_pkg::SH3ADD,
      riscv_pkg::BSET, riscv_pkg::BCLR,
      riscv_pkg::BINV, riscv_pkg::BEXT,
      riscv_pkg::BSETI, riscv_pkg::BCLRI,
      riscv_pkg::BINVI, riscv_pkg::BEXTI,
      riscv_pkg::ANDN, riscv_pkg::ORN,
      riscv_pkg::XNOR, riscv_pkg::CLZ,
      riscv_pkg::CTZ, riscv_pkg::CPOP,
      riscv_pkg::MAX, riscv_pkg::MAXU,
      riscv_pkg::MIN, riscv_pkg::MINU,
      riscv_pkg::SEXT_B, riscv_pkg::SEXT_H,
      riscv_pkg::ROL, riscv_pkg::ROR, riscv_pkg::RORI,
      riscv_pkg::ORC_B, riscv_pkg::REV8,
      riscv_pkg::CZERO_EQZ, riscv_pkg::CZERO_NEZ,
      riscv_pkg::PACK, riscv_pkg::PACKH,
      riscv_pkg::BREV8,
      riscv_pkg::ADDIW, riscv_pkg::SLLIW, riscv_pkg::SRLIW, riscv_pkg::SRAIW,
      riscv_pkg::SLLI_UW, riscv_pkg::RORIW,
      riscv_pkg::CLZW, riscv_pkg::CTZW, riscv_pkg::CPOPW,
      riscv_pkg::ADDW, riscv_pkg::SUBW,
      riscv_pkg::SLLW, riscv_pkg::SRLW, riscv_pkg::SRAW,
      riscv_pkg::ADD_UW, riscv_pkg::SH1ADD_UW,
      riscv_pkg::SH2ADD_UW, riscv_pkg::SH3ADD_UW,
      riscv_pkg::ROLW, riscv_pkg::RORW, riscv_pkg::PACKW,
      riscv_pkg::CSRRW, riscv_pkg::CSRRS,
      riscv_pkg::CSRRC, riscv_pkg::CSRRWI,
      riscv_pkg::CSRRSI, riscv_pkg::CSRRCI,
      riscv_pkg::ECALL, riscv_pkg::EBREAK, riscv_pkg::ILLEGAL,
      riscv_pkg::PAUSE:
      rs_type_pre = riscv_pkg::RS_INT;

      riscv_pkg::MUL, riscv_pkg::MULH,
      riscv_pkg::MULHSU, riscv_pkg::MULHU,
      riscv_pkg::DIV, riscv_pkg::DIVU,
      riscv_pkg::REM, riscv_pkg::REMU,
      riscv_pkg::MULW, riscv_pkg::DIVW, riscv_pkg::DIVUW,
      riscv_pkg::REMW, riscv_pkg::REMUW:
      rs_type_pre = riscv_pkg::RS_MUL;

      riscv_pkg::LB, riscv_pkg::LH, riscv_pkg::LW,
      riscv_pkg::LBU, riscv_pkg::LHU,
      riscv_pkg::LWU, riscv_pkg::LD,
      riscv_pkg::SB, riscv_pkg::SH, riscv_pkg::SW,
      riscv_pkg::SD,
      riscv_pkg::FLW, riscv_pkg::FSW,
      riscv_pkg::FLD, riscv_pkg::FSD,
      riscv_pkg::LR_W, riscv_pkg::SC_W,
      riscv_pkg::AMOSWAP_W, riscv_pkg::AMOADD_W,
      riscv_pkg::AMOXOR_W, riscv_pkg::AMOAND_W,
      riscv_pkg::AMOOR_W,
      riscv_pkg::AMOMIN_W, riscv_pkg::AMOMAX_W,
      riscv_pkg::AMOMINU_W, riscv_pkg::AMOMAXU_W,
      riscv_pkg::LR_D, riscv_pkg::SC_D,
      riscv_pkg::AMOSWAP_D, riscv_pkg::AMOADD_D,
      riscv_pkg::AMOXOR_D, riscv_pkg::AMOAND_D,
      riscv_pkg::AMOOR_D,
      riscv_pkg::AMOMIN_D, riscv_pkg::AMOMAX_D,
      riscv_pkg::AMOMINU_D, riscv_pkg::AMOMAXU_D,
      riscv_pkg::FENCE, riscv_pkg::FENCE_I, riscv_pkg::SFENCE_VMA:
      rs_type_pre = riscv_pkg::RS_MEM;

      riscv_pkg::FADD_S, riscv_pkg::FSUB_S,
      riscv_pkg::FADD_D, riscv_pkg::FSUB_D,
      riscv_pkg::FMIN_S, riscv_pkg::FMAX_S,
      riscv_pkg::FMIN_D, riscv_pkg::FMAX_D,
      riscv_pkg::FEQ_S, riscv_pkg::FLT_S,
      riscv_pkg::FLE_S, riscv_pkg::FEQ_D,
      riscv_pkg::FLT_D, riscv_pkg::FLE_D,
      riscv_pkg::FCVT_W_S, riscv_pkg::FCVT_WU_S, riscv_pkg::FCVT_S_W, riscv_pkg::FCVT_S_WU,
      riscv_pkg::FCVT_W_D, riscv_pkg::FCVT_WU_D, riscv_pkg::FCVT_D_W, riscv_pkg::FCVT_D_WU,
      riscv_pkg::FCVT_L_S, riscv_pkg::FCVT_LU_S, riscv_pkg::FCVT_S_L, riscv_pkg::FCVT_S_LU,
      riscv_pkg::FCVT_L_D, riscv_pkg::FCVT_LU_D, riscv_pkg::FCVT_D_L, riscv_pkg::FCVT_D_LU,
      riscv_pkg::FCVT_S_D, riscv_pkg::FCVT_D_S,
      riscv_pkg::FMV_X_W, riscv_pkg::FMV_W_X, riscv_pkg::FMV_X_D, riscv_pkg::FMV_D_X,
      riscv_pkg::FCLASS_S, riscv_pkg::FCLASS_D,
      riscv_pkg::FSGNJ_S, riscv_pkg::FSGNJN_S, riscv_pkg::FSGNJX_S,
      riscv_pkg::FSGNJ_D, riscv_pkg::FSGNJN_D, riscv_pkg::FSGNJX_D:
      rs_type_pre = riscv_pkg::RS_FP;

      riscv_pkg::FMUL_S, riscv_pkg::FMUL_D,
      riscv_pkg::FMADD_S, riscv_pkg::FMSUB_S,
      riscv_pkg::FNMADD_S, riscv_pkg::FNMSUB_S,
      riscv_pkg::FMADD_D, riscv_pkg::FMSUB_D,
      riscv_pkg::FNMADD_D, riscv_pkg::FNMSUB_D:
      rs_type_pre = riscv_pkg::RS_FMUL;

      riscv_pkg::FDIV_S, riscv_pkg::FSQRT_S, riscv_pkg::FDIV_D, riscv_pkg::FSQRT_D:
      rs_type_pre = riscv_pkg::RS_FDIV;

      riscv_pkg::JAL, riscv_pkg::WFI, riscv_pkg::MRET, riscv_pkg::SRET, riscv_pkg::DRET:
      rs_type_pre = riscv_pkg::RS_NONE;

      default: rs_type_pre = riscv_pkg::RS_INT;
    endcase

    case (op_for_pre_decode)
      riscv_pkg::SB, riscv_pkg::SH, riscv_pkg::SW, riscv_pkg::SD: is_int_store_pre = 1'b1;
      default: is_int_store_pre = 1'b0;
    endcase

    case (op_for_pre_decode)
      riscv_pkg::LB, riscv_pkg::LH, riscv_pkg::LW, riscv_pkg::LBU, riscv_pkg::LHU,
      riscv_pkg::LWU, riscv_pkg::LD, riscv_pkg::FLW, riscv_pkg::FLD,
      riscv_pkg::LR_W, riscv_pkg::LR_D,
      riscv_pkg::AMOSWAP_W, riscv_pkg::AMOADD_W, riscv_pkg::AMOXOR_W,
      riscv_pkg::AMOAND_W, riscv_pkg::AMOOR_W, riscv_pkg::AMOMIN_W,
      riscv_pkg::AMOMAX_W, riscv_pkg::AMOMINU_W, riscv_pkg::AMOMAXU_W,
      riscv_pkg::AMOSWAP_D, riscv_pkg::AMOADD_D, riscv_pkg::AMOXOR_D,
      riscv_pkg::AMOAND_D, riscv_pkg::AMOOR_D, riscv_pkg::AMOMIN_D,
      riscv_pkg::AMOMAX_D, riscv_pkg::AMOMINU_D, riscv_pkg::AMOMAXU_D:
      needs_lq_pre = 1'b1;
      default: needs_lq_pre = 1'b0;
    endcase

    case (op_for_pre_decode)
      riscv_pkg::SB, riscv_pkg::SH, riscv_pkg::SW, riscv_pkg::SD,
      riscv_pkg::FSW, riscv_pkg::FSD, riscv_pkg::SC_W, riscv_pkg::SC_D:
      needs_sq_pre = 1'b1;
      default: needs_sq_pre = 1'b0;
    endcase

    case (op_for_pre_decode)
      riscv_pkg::BEQ, riscv_pkg::BNE, riscv_pkg::BLT, riscv_pkg::BGE,
      riscv_pkg::BLTU, riscv_pkg::BGEU, riscv_pkg::JAL, riscv_pkg::JALR:
      is_branch_or_jump_pre = 1'b1;
      default: is_branch_or_jump_pre = 1'b0;
    endcase

    is_fence_pre = op_for_pre_decode == riscv_pkg::FENCE;
    // SFENCE.VMA uses the FENCE.I path: FENCE.I's back-end serialization and
    // cache sync are a superset of what it needs. is_sfence_vma_pre marks it
    // for the TVM/U-mode privilege check and the TLB invalidate.
    is_fence_i_pre = (op_for_pre_decode == riscv_pkg::FENCE_I) ||
                     (op_for_pre_decode == riscv_pkg::SFENCE_VMA);
    is_sfence_vma_pre = op_for_pre_decode == riscv_pkg::SFENCE_VMA;
    is_csr_imm_pre = op_for_pre_decode == riscv_pkg::CSRRWI ||
                     op_for_pre_decode == riscv_pkg::CSRRSI ||
                     op_for_pre_decode == riscv_pkg::CSRRCI;

    case (op_for_pre_decode)
      riscv_pkg::FADD_S, riscv_pkg::FSUB_S, riscv_pkg::FMUL_S, riscv_pkg::FDIV_S,
      riscv_pkg::FSQRT_S, riscv_pkg::FADD_D, riscv_pkg::FSUB_D,
      riscv_pkg::FMUL_D, riscv_pkg::FDIV_D, riscv_pkg::FSQRT_D,
      riscv_pkg::FMADD_S, riscv_pkg::FMSUB_S, riscv_pkg::FNMADD_S,
      riscv_pkg::FNMSUB_S, riscv_pkg::FMADD_D, riscv_pkg::FMSUB_D,
      riscv_pkg::FNMADD_D, riscv_pkg::FNMSUB_D,
      riscv_pkg::FMIN_S, riscv_pkg::FMAX_S, riscv_pkg::FMIN_D, riscv_pkg::FMAX_D,
      riscv_pkg::FEQ_S, riscv_pkg::FLT_S, riscv_pkg::FLE_S,
      riscv_pkg::FEQ_D, riscv_pkg::FLT_D, riscv_pkg::FLE_D,
      riscv_pkg::FCVT_W_S, riscv_pkg::FCVT_WU_S, riscv_pkg::FCVT_S_W,
      riscv_pkg::FCVT_S_WU, riscv_pkg::FCVT_W_D, riscv_pkg::FCVT_WU_D,
      riscv_pkg::FCVT_D_W, riscv_pkg::FCVT_D_WU,
      riscv_pkg::FCVT_L_S, riscv_pkg::FCVT_LU_S, riscv_pkg::FCVT_S_L,
      riscv_pkg::FCVT_S_LU, riscv_pkg::FCVT_L_D, riscv_pkg::FCVT_LU_D,
      riscv_pkg::FCVT_D_L, riscv_pkg::FCVT_D_LU,
      riscv_pkg::FCVT_S_D, riscv_pkg::FCVT_D_S,
      riscv_pkg::FCLASS_S, riscv_pkg::FCLASS_D,
      riscv_pkg::FSGNJ_S, riscv_pkg::FSGNJN_S, riscv_pkg::FSGNJX_S,
      riscv_pkg::FSGNJ_D, riscv_pkg::FSGNJN_D, riscv_pkg::FSGNJX_D,
      riscv_pkg::FMV_X_W, riscv_pkg::FMV_W_X,
      riscv_pkg::FMV_X_D, riscv_pkg::FMV_D_X:
      has_fp_flags_pre = 1'b1;
      default: has_fp_flags_pre = 1'b0;
    endcase

    case (op_for_pre_decode)
      riscv_pkg::FLW, riscv_pkg::FLD,
      riscv_pkg::FADD_S, riscv_pkg::FSUB_S,
      riscv_pkg::FMUL_S, riscv_pkg::FDIV_S, riscv_pkg::FSQRT_S,
      riscv_pkg::FADD_D, riscv_pkg::FSUB_D,
      riscv_pkg::FMUL_D, riscv_pkg::FDIV_D, riscv_pkg::FSQRT_D,
      riscv_pkg::FMADD_S, riscv_pkg::FMSUB_S, riscv_pkg::FNMADD_S, riscv_pkg::FNMSUB_S,
      riscv_pkg::FMADD_D, riscv_pkg::FMSUB_D, riscv_pkg::FNMADD_D, riscv_pkg::FNMSUB_D,
      riscv_pkg::FMIN_S, riscv_pkg::FMAX_S, riscv_pkg::FMIN_D, riscv_pkg::FMAX_D,
      riscv_pkg::FSGNJ_S, riscv_pkg::FSGNJN_S, riscv_pkg::FSGNJX_S,
      riscv_pkg::FSGNJ_D, riscv_pkg::FSGNJN_D, riscv_pkg::FSGNJX_D,
      riscv_pkg::FCVT_S_W, riscv_pkg::FCVT_S_WU, riscv_pkg::FCVT_D_W, riscv_pkg::FCVT_D_WU,
      riscv_pkg::FCVT_S_L, riscv_pkg::FCVT_S_LU, riscv_pkg::FCVT_D_L, riscv_pkg::FCVT_D_LU,
      riscv_pkg::FCVT_S_D, riscv_pkg::FCVT_D_S,
      riscv_pkg::FMV_W_X, riscv_pkg::FMV_D_X:
      has_fp_dest_pre = 1'b1;
      default: has_fp_dest_pre = 1'b0;
    endcase

    case (op_for_pre_decode)
      riscv_pkg::ADD, riscv_pkg::SUB, riscv_pkg::AND,
      riscv_pkg::OR, riscv_pkg::XOR, riscv_pkg::SLL,
      riscv_pkg::SRL, riscv_pkg::SRA,
      riscv_pkg::SLT, riscv_pkg::SLTU,
      riscv_pkg::ADDI, riscv_pkg::ANDI, riscv_pkg::ORI,
      riscv_pkg::XORI, riscv_pkg::SLTI,
      riscv_pkg::SLTIU, riscv_pkg::SLLI,
      riscv_pkg::SRLI, riscv_pkg::SRAI,
      riscv_pkg::LUI, riscv_pkg::AUIPC,
      riscv_pkg::JAL, riscv_pkg::JALR,
      riscv_pkg::SH1ADD, riscv_pkg::SH2ADD, riscv_pkg::SH3ADD,
      riscv_pkg::BSET, riscv_pkg::BCLR, riscv_pkg::BINV, riscv_pkg::BEXT,
      riscv_pkg::BSETI, riscv_pkg::BCLRI, riscv_pkg::BINVI, riscv_pkg::BEXTI,
      riscv_pkg::ANDN, riscv_pkg::ORN, riscv_pkg::XNOR,
      riscv_pkg::CLZ, riscv_pkg::CTZ, riscv_pkg::CPOP,
      riscv_pkg::MAX, riscv_pkg::MAXU, riscv_pkg::MIN, riscv_pkg::MINU,
      riscv_pkg::SEXT_B, riscv_pkg::SEXT_H,
      riscv_pkg::ROL, riscv_pkg::ROR, riscv_pkg::RORI,
      riscv_pkg::ORC_B, riscv_pkg::REV8,
      riscv_pkg::CZERO_EQZ, riscv_pkg::CZERO_NEZ,
      riscv_pkg::PACK, riscv_pkg::PACKH,
      riscv_pkg::BREV8,
      riscv_pkg::ADDIW, riscv_pkg::SLLIW, riscv_pkg::SRLIW, riscv_pkg::SRAIW,
      riscv_pkg::SLLI_UW, riscv_pkg::RORIW,
      riscv_pkg::CLZW, riscv_pkg::CTZW, riscv_pkg::CPOPW,
      riscv_pkg::ADDW, riscv_pkg::SUBW,
      riscv_pkg::SLLW, riscv_pkg::SRLW, riscv_pkg::SRAW,
      riscv_pkg::ADD_UW, riscv_pkg::SH1ADD_UW,
      riscv_pkg::SH2ADD_UW, riscv_pkg::SH3ADD_UW,
      riscv_pkg::ROLW, riscv_pkg::RORW, riscv_pkg::PACKW,
      riscv_pkg::MUL, riscv_pkg::MULH, riscv_pkg::MULHSU, riscv_pkg::MULHU,
      riscv_pkg::DIV, riscv_pkg::DIVU, riscv_pkg::REM, riscv_pkg::REMU,
      riscv_pkg::MULW, riscv_pkg::DIVW, riscv_pkg::DIVUW,
      riscv_pkg::REMW, riscv_pkg::REMUW,
      riscv_pkg::LB, riscv_pkg::LH, riscv_pkg::LW, riscv_pkg::LBU, riscv_pkg::LHU,
      riscv_pkg::LWU, riscv_pkg::LD,
      riscv_pkg::LR_W, riscv_pkg::SC_W,
      riscv_pkg::AMOSWAP_W, riscv_pkg::AMOADD_W,
      riscv_pkg::AMOXOR_W, riscv_pkg::AMOAND_W, riscv_pkg::AMOOR_W,
      riscv_pkg::AMOMIN_W, riscv_pkg::AMOMAX_W,
      riscv_pkg::AMOMINU_W, riscv_pkg::AMOMAXU_W,
      riscv_pkg::LR_D, riscv_pkg::SC_D,
      riscv_pkg::AMOSWAP_D, riscv_pkg::AMOADD_D,
      riscv_pkg::AMOXOR_D, riscv_pkg::AMOAND_D, riscv_pkg::AMOOR_D,
      riscv_pkg::AMOMIN_D, riscv_pkg::AMOMAX_D,
      riscv_pkg::AMOMINU_D, riscv_pkg::AMOMAXU_D,
      riscv_pkg::CSRRW, riscv_pkg::CSRRS, riscv_pkg::CSRRC,
      riscv_pkg::CSRRWI, riscv_pkg::CSRRSI, riscv_pkg::CSRRCI,
      riscv_pkg::FEQ_S, riscv_pkg::FLT_S, riscv_pkg::FLE_S,
      riscv_pkg::FEQ_D, riscv_pkg::FLT_D, riscv_pkg::FLE_D,
      riscv_pkg::FCLASS_S, riscv_pkg::FCLASS_D,
      riscv_pkg::FCVT_W_S, riscv_pkg::FCVT_WU_S,
      riscv_pkg::FCVT_W_D, riscv_pkg::FCVT_WU_D,
      riscv_pkg::FCVT_L_S, riscv_pkg::FCVT_LU_S,
      riscv_pkg::FCVT_L_D, riscv_pkg::FCVT_LU_D,
      riscv_pkg::FMV_X_W, riscv_pkg::FMV_X_D:
      has_int_dest_pre = 1'b1;
      default: has_int_dest_pre = 1'b0;
    endcase

    case (op_for_pre_decode)
      riscv_pkg::FADD_S, riscv_pkg::FSUB_S,
      riscv_pkg::FMUL_S, riscv_pkg::FDIV_S, riscv_pkg::FSQRT_S,
      riscv_pkg::FADD_D, riscv_pkg::FSUB_D,
      riscv_pkg::FMUL_D, riscv_pkg::FDIV_D, riscv_pkg::FSQRT_D,
      riscv_pkg::FMADD_S, riscv_pkg::FMSUB_S, riscv_pkg::FNMADD_S, riscv_pkg::FNMSUB_S,
      riscv_pkg::FMADD_D, riscv_pkg::FMSUB_D, riscv_pkg::FNMADD_D, riscv_pkg::FNMSUB_D,
      riscv_pkg::FMIN_S, riscv_pkg::FMAX_S, riscv_pkg::FMIN_D, riscv_pkg::FMAX_D,
      riscv_pkg::FSGNJ_S, riscv_pkg::FSGNJN_S, riscv_pkg::FSGNJX_S,
      riscv_pkg::FSGNJ_D, riscv_pkg::FSGNJN_D, riscv_pkg::FSGNJX_D,
      riscv_pkg::FEQ_S, riscv_pkg::FLT_S, riscv_pkg::FLE_S,
      riscv_pkg::FEQ_D, riscv_pkg::FLT_D, riscv_pkg::FLE_D,
      riscv_pkg::FCLASS_S, riscv_pkg::FCLASS_D,
      riscv_pkg::FCVT_W_S, riscv_pkg::FCVT_WU_S,
      riscv_pkg::FCVT_W_D, riscv_pkg::FCVT_WU_D,
      riscv_pkg::FCVT_L_S, riscv_pkg::FCVT_LU_S,
      riscv_pkg::FCVT_L_D, riscv_pkg::FCVT_LU_D,
      riscv_pkg::FMV_X_W, riscv_pkg::FMV_X_D,
      riscv_pkg::FCVT_S_D, riscv_pkg::FCVT_D_S:
      uses_fp_rs1_pre = 1'b1;
      default: uses_fp_rs1_pre = 1'b0;
    endcase

    case (op_for_pre_decode)
      riscv_pkg::FADD_S, riscv_pkg::FSUB_S, riscv_pkg::FMUL_S, riscv_pkg::FDIV_S,
      riscv_pkg::FADD_D, riscv_pkg::FSUB_D, riscv_pkg::FMUL_D, riscv_pkg::FDIV_D,
      riscv_pkg::FMADD_S, riscv_pkg::FMSUB_S, riscv_pkg::FNMADD_S, riscv_pkg::FNMSUB_S,
      riscv_pkg::FMADD_D, riscv_pkg::FMSUB_D, riscv_pkg::FNMADD_D, riscv_pkg::FNMSUB_D,
      riscv_pkg::FMIN_S, riscv_pkg::FMAX_S, riscv_pkg::FMIN_D, riscv_pkg::FMAX_D,
      riscv_pkg::FSGNJ_S, riscv_pkg::FSGNJN_S, riscv_pkg::FSGNJX_S,
      riscv_pkg::FSGNJ_D, riscv_pkg::FSGNJN_D, riscv_pkg::FSGNJX_D,
      riscv_pkg::FEQ_S, riscv_pkg::FLT_S, riscv_pkg::FLE_S,
      riscv_pkg::FEQ_D, riscv_pkg::FLT_D, riscv_pkg::FLE_D,
      riscv_pkg::FSW, riscv_pkg::FSD:
      uses_fp_rs2_pre = 1'b1;
      default: uses_fp_rs2_pre = 1'b0;
    endcase

    case (op_for_pre_decode)
      riscv_pkg::FMADD_S, riscv_pkg::FMSUB_S,
      riscv_pkg::FNMADD_S, riscv_pkg::FNMSUB_S,
      riscv_pkg::FMADD_D, riscv_pkg::FMSUB_D,
      riscv_pkg::FNMADD_D, riscv_pkg::FNMSUB_D:
      uses_fp_rs3_pre = 1'b1;
      default: uses_fp_rs3_pre = 1'b0;
    endcase

    // INT rs1: most ops, except pure-FP-rs1 / PC-relative / system / CSR-imm.
    uses_int_rs1_pre = !uses_fp_rs1_pre && (
      op_for_pre_decode != riscv_pkg::LUI &&
      op_for_pre_decode != riscv_pkg::AUIPC &&
      op_for_pre_decode != riscv_pkg::JAL &&
      op_for_pre_decode != riscv_pkg::ECALL &&
      op_for_pre_decode != riscv_pkg::EBREAK &&
      op_for_pre_decode != riscv_pkg::FENCE &&
      op_for_pre_decode != riscv_pkg::FENCE_I &&
      op_for_pre_decode != riscv_pkg::WFI &&
      op_for_pre_decode != riscv_pkg::MRET &&
      op_for_pre_decode != riscv_pkg::SRET &&
      op_for_pre_decode != riscv_pkg::DRET &&
      op_for_pre_decode != riscv_pkg::SFENCE_VMA &&
      op_for_pre_decode != riscv_pkg::PAUSE &&
      op_for_pre_decode != riscv_pkg::CSRRWI &&
      op_for_pre_decode != riscv_pkg::CSRRSI &&
      op_for_pre_decode != riscv_pkg::CSRRCI &&
      op_for_pre_decode != riscv_pkg::ILLEGAL &&
      op_for_pre_decode != riscv_pkg::FETCH_FAULT);

    // INT rs2: branches, R-type ALU, integer stores, AMO/SC.
    case (op_for_pre_decode)
      riscv_pkg::BEQ, riscv_pkg::BNE, riscv_pkg::BLT,
      riscv_pkg::BGE, riscv_pkg::BLTU, riscv_pkg::BGEU,
      riscv_pkg::ADD, riscv_pkg::SUB, riscv_pkg::AND,
      riscv_pkg::OR, riscv_pkg::XOR, riscv_pkg::SLL,
      riscv_pkg::SRL, riscv_pkg::SRA,
      riscv_pkg::SLT, riscv_pkg::SLTU,
      riscv_pkg::MUL, riscv_pkg::MULH, riscv_pkg::MULHSU, riscv_pkg::MULHU,
      riscv_pkg::DIV, riscv_pkg::DIVU, riscv_pkg::REM, riscv_pkg::REMU,
      riscv_pkg::MULW, riscv_pkg::DIVW, riscv_pkg::DIVUW,
      riscv_pkg::REMW, riscv_pkg::REMUW,
      riscv_pkg::SH1ADD, riscv_pkg::SH2ADD, riscv_pkg::SH3ADD,
      riscv_pkg::BSET, riscv_pkg::BCLR, riscv_pkg::BINV, riscv_pkg::BEXT,
      riscv_pkg::ANDN, riscv_pkg::ORN, riscv_pkg::XNOR,
      riscv_pkg::MAX, riscv_pkg::MAXU, riscv_pkg::MIN, riscv_pkg::MINU,
      riscv_pkg::ROL, riscv_pkg::ROR,
      riscv_pkg::CZERO_EQZ, riscv_pkg::CZERO_NEZ,
      riscv_pkg::PACK, riscv_pkg::PACKH,
      riscv_pkg::ADDW, riscv_pkg::SUBW,
      riscv_pkg::SLLW, riscv_pkg::SRLW, riscv_pkg::SRAW,
      riscv_pkg::ADD_UW, riscv_pkg::SH1ADD_UW,
      riscv_pkg::SH2ADD_UW, riscv_pkg::SH3ADD_UW,
      riscv_pkg::ROLW, riscv_pkg::RORW, riscv_pkg::PACKW,
      riscv_pkg::SB, riscv_pkg::SH, riscv_pkg::SW, riscv_pkg::SD,
      riscv_pkg::SC_W,
      riscv_pkg::AMOSWAP_W, riscv_pkg::AMOADD_W,
      riscv_pkg::AMOXOR_W, riscv_pkg::AMOAND_W, riscv_pkg::AMOOR_W,
      riscv_pkg::AMOMIN_W, riscv_pkg::AMOMAX_W,
      riscv_pkg::AMOMINU_W, riscv_pkg::AMOMAXU_W,
      riscv_pkg::SC_D,
      riscv_pkg::AMOSWAP_D, riscv_pkg::AMOADD_D,
      riscv_pkg::AMOXOR_D, riscv_pkg::AMOAND_D, riscv_pkg::AMOOR_D,
      riscv_pkg::AMOMIN_D, riscv_pkg::AMOMAX_D,
      riscv_pkg::AMOMINU_D, riscv_pkg::AMOMAXU_D:
      uses_int_rs2_pre = !uses_fp_rs2_pre;
      default: uses_int_rs2_pre = 1'b0;
    endcase
  end

  logic has_int_dest_direct;
  logic has_fp_dest_direct;
  logic uses_int_rs1_direct;
  logic uses_int_rs2_direct;
  logic uses_fp_rs1_direct;
  logic uses_fp_rs2_direct;
  logic uses_fp_rs3_direct;
  logic [2:0] rs_type_direct;
  logic is_int_store_direct;
  logic is_branch_or_jump_direct;
  logic is_fence_direct;
  logic is_fence_i_direct;
  logic is_sfence_vma_direct;
  logic is_csr_imm_direct;
  logic has_fp_flags_direct;
  logic needs_lq_direct;
  logic needs_sq_direct;
  instr_operand_classifier dut (
      .i_instr,
      .i_inject_nop,
      .i_illegal(is_illegal_instruction),
      .i_fetch_fault,
      .o_has_int_dest(has_int_dest_direct),
      .o_has_fp_dest(has_fp_dest_direct),
      .o_uses_int_rs1(uses_int_rs1_direct),
      .o_uses_int_rs2(uses_int_rs2_direct),
      .o_uses_fp_rs1(uses_fp_rs1_direct),
      .o_uses_fp_rs2(uses_fp_rs2_direct),
      .o_uses_fp_rs3(uses_fp_rs3_direct),
      .o_rs_type(rs_type_direct),
      .o_is_int_store(is_int_store_direct),
      .o_is_branch_or_jump(is_branch_or_jump_direct),
      .o_is_fence(is_fence_direct),
      .o_is_fence_i(is_fence_i_direct),
      .o_is_sfence_vma(is_sfence_vma_direct),
      .o_is_csr_imm(is_csr_imm_direct),
      .o_has_fp_flags(has_fp_flags_direct),
      .o_needs_lq(needs_lq_direct),
      .o_needs_sq(needs_sq_direct)
  );
  always_comb begin
    p_has_int_dest : assert (has_int_dest_direct == has_int_dest_pre);
    p_has_fp_dest : assert (has_fp_dest_direct == has_fp_dest_pre);
    p_uses_int_rs1 : assert (uses_int_rs1_direct == uses_int_rs1_pre);
    p_uses_int_rs2 : assert (uses_int_rs2_direct == uses_int_rs2_pre);
    p_uses_fp_rs1 : assert (uses_fp_rs1_direct == uses_fp_rs1_pre);
    p_uses_fp_rs2 : assert (uses_fp_rs2_direct == uses_fp_rs2_pre);
    p_uses_fp_rs3 : assert (uses_fp_rs3_direct == uses_fp_rs3_pre);
    p_rs_type : assert (rs_type_direct == rs_type_pre);
    p_is_int_store : assert (is_int_store_direct == is_int_store_pre);
    p_is_branch_or_jump : assert (is_branch_or_jump_direct == is_branch_or_jump_pre);
    p_is_fence : assert (is_fence_direct == is_fence_pre);
    p_is_fence_i : assert (is_fence_i_direct == is_fence_i_pre);
    p_is_sfence_vma : assert (is_sfence_vma_direct == is_sfence_vma_pre);
    p_is_csr_imm : assert (is_csr_imm_direct == is_csr_imm_pre);
    p_has_fp_flags : assert (has_fp_flags_direct == has_fp_flags_pre);
    p_needs_lq : assert (needs_lq_direct == needs_lq_pre);
    p_needs_sq : assert (needs_sq_direct == needs_sq_pre);
  end
endmodule : instr_operand_classifier_equiv
