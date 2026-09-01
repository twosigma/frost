#    Copyright 2026 Two Sigma Open Source, LLC
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

"""Typed Dispatch DUT access and packed-struct conversion helpers.

Verilator flattens packed structs into bit vectors, so this interface packs
and unpacks their fields.
"""

from typing import Any

from cocotb.triggers import RisingEdge, FallingEdge
from config import FLEN, INSTR_OP_WIDTH, STORE_OP_WIDTH, XLEN

from ..fu_shims.fp_add_shim_interface import _parse_instr_op_enum

# =============================================================================
# Width constants from riscv_pkg
# =============================================================================
ROB_TAG_WIDTH = 5
REG_ADDR_WIDTH = 5
CHECKPOINT_ID_WIDTH = 3
RAS_PTR_BITS = 3
BP_DIR_IDX_BITS = 10

MASK_TAG = (1 << ROB_TAG_WIDTH) - 1
MASK32 = (1 << XLEN) - 1
MASK64 = (1 << FLEN) - 1

# instr_op_e: explicit 8-bit, two-state unsigned enum in riscv_pkg
OP_WIDTH = INSTR_OP_WIDTH
MASK_OP = (1 << OP_WIDTH) - 1

# rs_type_e: 3 bits
RS_TYPE_WIDTH = 3

# mem_size_e: 2 bits
MEM_SIZE_WIDTH = 2

# branch_taken_op_e: 3 bits
BRANCH_OP_WIDTH = 3

# store_op_e: STORE_OP_WIDTH comes from config (3 bits since M2's STD)

# instr_t: 32 bits packed struct
INSTR_WIDTH = 32

# =============================================================================
# RS type constants
# =============================================================================
RS_INT = 0
RS_MUL = 1
RS_MEM = 2
RS_FP = 3
RS_FMUL = 4
RS_FDIV = 5
RS_NONE = 6

# =============================================================================
# mem_size_e constants
# =============================================================================
MEM_SIZE_BYTE = 0
MEM_SIZE_HALF = 1
MEM_SIZE_WORD = 2
MEM_SIZE_DOUBLE = 3

# =============================================================================
# instr_op_e constants — parsed from riscv_pkg.sv so every value tracks the
# RTL enum. Hardcoded indices go stale on any mid-enum insertion: the M3
# .D-atomics insertion shifted everything after AMOMAXU_W by 11, silently
# invalidating the old FLW..FCLASS_D block.
# =============================================================================
_INSTR_OPS = _parse_instr_op_enum()
# base-ISA integer ops
ADD = _INSTR_OPS["ADD"]
SUB = _INSTR_OPS["SUB"]
AND = _INSTR_OPS["AND"]
OR = _INSTR_OPS["OR"]
XOR = _INSTR_OPS["XOR"]
SLL = _INSTR_OPS["SLL"]
SRL = _INSTR_OPS["SRL"]
SRA = _INSTR_OPS["SRA"]
SLT = _INSTR_OPS["SLT"]
SLTU = _INSTR_OPS["SLTU"]
ADDI = _INSTR_OPS["ADDI"]
ANDI = _INSTR_OPS["ANDI"]
ORI = _INSTR_OPS["ORI"]
XORI = _INSTR_OPS["XORI"]
SLTI = _INSTR_OPS["SLTI"]
SLTIU = _INSTR_OPS["SLTIU"]
SLLI = _INSTR_OPS["SLLI"]
SRLI = _INSTR_OPS["SRLI"]
SRAI = _INSTR_OPS["SRAI"]
# upper-imm/jumps
LUI = _INSTR_OPS["LUI"]
AUIPC = _INSTR_OPS["AUIPC"]
JAL = _INSTR_OPS["JAL"]
JALR = _INSTR_OPS["JALR"]
# branches
BEQ = _INSTR_OPS["BEQ"]
BNE = _INSTR_OPS["BNE"]
BLT = _INSTR_OPS["BLT"]
BGE = _INSTR_OPS["BGE"]
BLTU = _INSTR_OPS["BLTU"]
BGEU = _INSTR_OPS["BGEU"]
# loads/stores
LB = _INSTR_OPS["LB"]
LH = _INSTR_OPS["LH"]
LW = _INSTR_OPS["LW"]
LBU = _INSTR_OPS["LBU"]
LHU = _INSTR_OPS["LHU"]
SB = _INSTR_OPS["SB"]
SH = _INSTR_OPS["SH"]
SW = _INSTR_OPS["SW"]
# M-extension
MUL = _INSTR_OPS["MUL"]
MULH = _INSTR_OPS["MULH"]
MULHSU = _INSTR_OPS["MULHSU"]
MULHU = _INSTR_OPS["MULHU"]
DIV = _INSTR_OPS["DIV"]
DIVU = _INSTR_OPS["DIVU"]
REM = _INSTR_OPS["REM"]
REMU = _INSTR_OPS["REMU"]
# Zifencei
FENCE = _INSTR_OPS["FENCE"]
FENCE_I = _INSTR_OPS["FENCE_I"]
# Zicsr
CSRRW = _INSTR_OPS["CSRRW"]
CSRRS = _INSTR_OPS["CSRRS"]
CSRRC = _INSTR_OPS["CSRRC"]
CSRRWI = _INSTR_OPS["CSRRWI"]
CSRRSI = _INSTR_OPS["CSRRSI"]
CSRRCI = _INSTR_OPS["CSRRCI"]
# Zba
SH1ADD = _INSTR_OPS["SH1ADD"]
SH2ADD = _INSTR_OPS["SH2ADD"]
SH3ADD = _INSTR_OPS["SH3ADD"]
# Zbs
BSET = _INSTR_OPS["BSET"]
BCLR = _INSTR_OPS["BCLR"]
BINV = _INSTR_OPS["BINV"]
BEXT = _INSTR_OPS["BEXT"]
BSETI = _INSTR_OPS["BSETI"]
BCLRI = _INSTR_OPS["BCLRI"]
BINVI = _INSTR_OPS["BINVI"]
BEXTI = _INSTR_OPS["BEXTI"]
# Zbb
ANDN = _INSTR_OPS["ANDN"]
ORN = _INSTR_OPS["ORN"]
XNOR_OP = _INSTR_OPS["XNOR"]
CLZ = _INSTR_OPS["CLZ"]
CTZ = _INSTR_OPS["CTZ"]
CPOP = _INSTR_OPS["CPOP"]
MAX_OP = _INSTR_OPS["MAX"]
MAXU = _INSTR_OPS["MAXU"]
MIN_OP = _INSTR_OPS["MIN"]
MINU = _INSTR_OPS["MINU"]
SEXT_B = _INSTR_OPS["SEXT_B"]
SEXT_H = _INSTR_OPS["SEXT_H"]
ROL = _INSTR_OPS["ROL"]
ROR = _INSTR_OPS["ROR"]
RORI = _INSTR_OPS["RORI"]
ORC_B = _INSTR_OPS["ORC_B"]
REV8 = _INSTR_OPS["REV8"]
# Zicond
CZERO_EQZ = _INSTR_OPS["CZERO_EQZ"]
CZERO_NEZ = _INSTR_OPS["CZERO_NEZ"]
# Zbkb
PACK = _INSTR_OPS["PACK"]
PACKH = _INSTR_OPS["PACKH"]
BREV8 = _INSTR_OPS["BREV8"]
# Zihintpause
PAUSE = _INSTR_OPS["PAUSE"]
# Privileged
MRET = _INSTR_OPS["MRET"]
SRET = _INSTR_OPS["SRET"]
SFENCE_VMA = _INSTR_OPS["SFENCE_VMA"]
WFI = _INSTR_OPS["WFI"]
ECALL = _INSTR_OPS["ECALL"]
EBREAK = _INSTR_OPS["EBREAK"]
DRET = _INSTR_OPS["DRET"]
# A extension
LR_W = _INSTR_OPS["LR_W"]
SC_W = _INSTR_OPS["SC_W"]
AMOSWAP_W = _INSTR_OPS["AMOSWAP_W"]
AMOADD_W = _INSTR_OPS["AMOADD_W"]
AMOXOR_W = _INSTR_OPS["AMOXOR_W"]
AMOAND_W = _INSTR_OPS["AMOAND_W"]
AMOOR_W = _INSTR_OPS["AMOOR_W"]
AMOMIN_W = _INSTR_OPS["AMOMIN_W"]
AMOMAX_W = _INSTR_OPS["AMOMAX_W"]
AMOMINU_W = _INSTR_OPS["AMOMINU_W"]
AMOMAXU_W = _INSTR_OPS["AMOMAXU_W"]
# F extension
FLW = _INSTR_OPS["FLW"]
FSW = _INSTR_OPS["FSW"]
FADD_S = _INSTR_OPS["FADD_S"]
FSUB_S = _INSTR_OPS["FSUB_S"]
FMUL_S = _INSTR_OPS["FMUL_S"]
FDIV_S = _INSTR_OPS["FDIV_S"]
FSQRT_S = _INSTR_OPS["FSQRT_S"]
FMADD_S = _INSTR_OPS["FMADD_S"]
FMSUB_S = _INSTR_OPS["FMSUB_S"]
FNMADD_S = _INSTR_OPS["FNMADD_S"]
FNMSUB_S = _INSTR_OPS["FNMSUB_S"]
FSGNJ_S = _INSTR_OPS["FSGNJ_S"]
FSGNJN_S = _INSTR_OPS["FSGNJN_S"]
FSGNJX_S = _INSTR_OPS["FSGNJX_S"]
FMIN_S = _INSTR_OPS["FMIN_S"]
FMAX_S = _INSTR_OPS["FMAX_S"]
FCVT_W_S = _INSTR_OPS["FCVT_W_S"]
FCVT_WU_S = _INSTR_OPS["FCVT_WU_S"]
FCVT_S_W = _INSTR_OPS["FCVT_S_W"]
FCVT_S_WU = _INSTR_OPS["FCVT_S_WU"]
FMV_X_W = _INSTR_OPS["FMV_X_W"]
FMV_W_X = _INSTR_OPS["FMV_W_X"]
FEQ_S = _INSTR_OPS["FEQ_S"]
FLT_S = _INSTR_OPS["FLT_S"]
FLE_S = _INSTR_OPS["FLE_S"]
FCLASS_S = _INSTR_OPS["FCLASS_S"]
# D extension
FLD = _INSTR_OPS["FLD"]
FSD = _INSTR_OPS["FSD"]
FADD_D = _INSTR_OPS["FADD_D"]
FSUB_D = _INSTR_OPS["FSUB_D"]
FMUL_D = _INSTR_OPS["FMUL_D"]
FDIV_D = _INSTR_OPS["FDIV_D"]
FSQRT_D = _INSTR_OPS["FSQRT_D"]
FMADD_D = _INSTR_OPS["FMADD_D"]
FMSUB_D = _INSTR_OPS["FMSUB_D"]
FNMADD_D = _INSTR_OPS["FNMADD_D"]
FNMSUB_D = _INSTR_OPS["FNMSUB_D"]
FSGNJ_D = _INSTR_OPS["FSGNJ_D"]
FSGNJN_D = _INSTR_OPS["FSGNJN_D"]
FSGNJX_D = _INSTR_OPS["FSGNJX_D"]
FMIN_D = _INSTR_OPS["FMIN_D"]
FMAX_D = _INSTR_OPS["FMAX_D"]
FCVT_W_D = _INSTR_OPS["FCVT_W_D"]
FCVT_WU_D = _INSTR_OPS["FCVT_WU_D"]
FCVT_D_W = _INSTR_OPS["FCVT_D_W"]
FCVT_D_WU = _INSTR_OPS["FCVT_D_WU"]
FCVT_S_D = _INSTR_OPS["FCVT_S_D"]
FCVT_D_S = _INSTR_OPS["FCVT_D_S"]
FEQ_D = _INSTR_OPS["FEQ_D"]
FLT_D = _INSTR_OPS["FLT_D"]
FLE_D = _INSTR_OPS["FLE_D"]
FCLASS_D = _INSTR_OPS["FCLASS_D"]
# RV64 F/D conversions and moves (M3)
FCVT_L_S = _INSTR_OPS["FCVT_L_S"]
FCVT_LU_S = _INSTR_OPS["FCVT_LU_S"]
FCVT_S_L = _INSTR_OPS["FCVT_S_L"]
FCVT_S_LU = _INSTR_OPS["FCVT_S_LU"]
FCVT_L_D = _INSTR_OPS["FCVT_L_D"]
FCVT_LU_D = _INSTR_OPS["FCVT_LU_D"]
FCVT_D_L = _INSTR_OPS["FCVT_D_L"]
FCVT_D_LU = _INSTR_OPS["FCVT_D_LU"]
FMV_X_D = _INSTR_OPS["FMV_X_D"]
FMV_D_X = _INSTR_OPS["FMV_D_X"]


# =============================================================================
# from_id_to_ex_t field table
# =============================================================================
# List of (field_name, bit_width) in declaration order (first = MSB).
# SystemVerilog packed structs place the first-declared field at the highest
# bit positions.  We pack from LSB (last field) to MSB (first field).

FROM_ID_TO_EX_FIELDS = [
    ("program_counter", XLEN),
    ("immediate_i_type", XLEN),
    ("immediate_s_type", XLEN),
    ("immediate_b_type", XLEN),
    ("immediate_u_type", XLEN),
    ("immediate_j_type", XLEN),
    ("source_reg_1_data", XLEN),
    ("source_reg_2_data", XLEN),
    ("source_reg_1_is_x0", 1),
    ("source_reg_2_is_x0", 1),
    ("is_load_instruction", 1),
    ("is_load_byte", 1),
    ("is_load_halfword", 1),
    ("is_load_unsigned", 1),
    ("instruction_operation", OP_WIDTH),
    ("branch_operation", BRANCH_OP_WIDTH),
    ("store_operation", STORE_OP_WIDTH),
    ("rs_type", RS_TYPE_WIDTH),
    ("is_int_store", 1),
    ("is_branch_or_jump", 1),
    ("is_fence", 1),
    ("is_fence_i", 1),
    ("is_csr_imm", 1),
    ("has_fp_flags", 1),
    ("is_jump_and_link", 1),
    ("is_jump_and_link_register", 1),
    ("is_multiply", 1),
    ("is_divide", 1),
    ("is_csr_instruction", 1),
    ("csr_address", 12),
    ("csr_imm", 5),
    ("is_amo_instruction", 1),
    ("is_lr", 1),
    ("is_sc", 1),
    ("is_mret", 1),
    ("is_sret", 1),
    ("is_dret", 1),
    ("is_sfence_vma", 1),
    ("is_wfi", 1),
    ("is_ecall", 1),
    ("is_ebreak", 1),
    ("is_illegal_instruction", 1),
    ("is_fetch_fault", 1),
    ("is_fetch_fault_page", 1),
    ("is_fetch_fault_hi", 1),
    ("is_fp_instruction", 1),
    ("is_fp_load", 1),
    ("is_fp_store", 1),
    ("is_fp_load_double", 1),
    ("is_fp_store_double", 1),
    ("is_fp_compute", 1),
    ("is_pipelined_fp_op", 1),
    ("fp_rm", 3),
    ("is_fp_to_int", 1),
    ("is_int_to_fp", 1),
    ("fp_source_reg_1_data", FLEN),
    ("fp_source_reg_2_data", FLEN),
    ("fp_source_reg_3_data", FLEN),
    ("link_address", XLEN),
    ("is_compressed", 1),
    ("branch_target_precomputed", XLEN),
    ("jal_target_precomputed", XLEN),
    ("instruction", INSTR_WIDTH),
    ("btb_hit", 1),
    ("btb_predicted_taken", 1),
    ("btb_predicted_target", XLEN),
    ("ras_predicted", 1),
    ("ras_predicted_target", XLEN),
    ("ras_checkpoint_tos", RAS_PTR_BITS),
    ("ras_checkpoint_valid_count", RAS_PTR_BITS + 1),
    ("bp_dir_idx", BP_DIR_IDX_BITS),
    ("is_ras_return", 1),
    ("is_ras_call", 1),
    ("ras_predicted_target_nonzero", 1),
    ("ras_expected_rs1", XLEN),
    ("btb_correct_non_jalr", 1),
    ("btb_expected_rs1", XLEN),
    # Pre-decoded operand-classification flags (timing optimization).
    # Dispatch reads these instead of re-decoding instruction_operation.
    ("has_int_dest", 1),
    ("has_fp_dest", 1),
    ("uses_int_rs1", 1),
    ("uses_int_rs2", 1),
    ("uses_fp_rs1", 1),
    ("uses_fp_rs2", 1),
    ("uses_fp_rs3", 1),
    ("is_not_nop", 1),
]

# Compute total width and per-field offsets (bit offset from LSB)
_FROM_ID_TO_EX_TOTAL_WIDTH = sum(w for _, w in FROM_ID_TO_EX_FIELDS)

# Build offset map: field_name -> (bit_offset_from_lsb, width)
_FROM_ID_TO_EX_OFFSETS: dict[str, tuple[int, int]] = {}
_offset = _FROM_ID_TO_EX_TOTAL_WIDTH
for _name, _width in FROM_ID_TO_EX_FIELDS:
    _offset -= _width
    _FROM_ID_TO_EX_OFFSETS[_name] = (_offset, _width)
assert _offset == 0, f"Offset mismatch: {_offset}"


# =============================================================================
# Pre-decoded operand-classification helpers
# =============================================================================
# These mirror the riscv_pkg.sv functions of the same names so that
# build_from_id_to_ex can populate the registered flags from instruction_operation
# without each test having to set them individually.  The DUT's id_stage runs
# the same decode and registers the result; dispatch then reads the registered
# flag instead of re-decoding.
_HAS_FP_DEST_OPS: frozenset[int] = frozenset(
    {
        FLW,
        FLD,
        FADD_S,
        FSUB_S,
        FMUL_S,
        FDIV_S,
        FSQRT_S,
        FADD_D,
        FSUB_D,
        FMUL_D,
        FDIV_D,
        FSQRT_D,
        FMADD_S,
        FMSUB_S,
        FNMADD_S,
        FNMSUB_S,
        FMADD_D,
        FMSUB_D,
        FNMADD_D,
        FNMSUB_D,
        FMIN_S,
        FMAX_S,
        FMIN_D,
        FMAX_D,
        FSGNJ_S,
        FSGNJN_S,
        FSGNJX_S,
        FSGNJ_D,
        FSGNJN_D,
        FSGNJX_D,
        FCVT_S_W,
        FCVT_S_WU,
        FCVT_D_W,
        FCVT_D_WU,
        FCVT_S_L,
        FCVT_S_LU,
        FCVT_D_L,
        FCVT_D_LU,
        FCVT_S_D,
        FCVT_D_S,
        FMV_W_X,
        FMV_D_X,
    }
)

_HAS_INT_DEST_OPS: frozenset[int] = frozenset(
    {
        ADD,
        SUB,
        AND,
        OR,
        XOR,
        SLL,
        SRL,
        SRA,
        SLT,
        SLTU,
        ADDI,
        ANDI,
        ORI,
        XORI,
        SLTI,
        SLTIU,
        SLLI,
        SRLI,
        SRAI,
        LUI,
        AUIPC,
        JAL,
        JALR,
        SH1ADD,
        SH2ADD,
        SH3ADD,
        BSET,
        BCLR,
        BINV,
        BEXT,
        BSETI,
        BCLRI,
        BINVI,
        BEXTI,
        ANDN,
        ORN,
        XNOR_OP,
        CLZ,
        CTZ,
        CPOP,
        MAX_OP,
        MAXU,
        MIN_OP,
        MINU,
        SEXT_B,
        SEXT_H,
        ROL,
        ROR,
        RORI,
        ORC_B,
        REV8,
        CZERO_EQZ,
        CZERO_NEZ,
        PACK,
        PACKH,
        BREV8,
        MUL,
        MULH,
        MULHSU,
        MULHU,
        DIV,
        DIVU,
        REM,
        REMU,
        LB,
        LH,
        LW,
        LBU,
        LHU,
        LR_W,
        SC_W,
        AMOSWAP_W,
        AMOADD_W,
        AMOXOR_W,
        AMOAND_W,
        AMOOR_W,
        AMOMIN_W,
        AMOMAX_W,
        AMOMINU_W,
        AMOMAXU_W,
        CSRRW,
        CSRRS,
        CSRRC,
        CSRRWI,
        CSRRSI,
        CSRRCI,
        FEQ_S,
        FLT_S,
        FLE_S,
        FEQ_D,
        FLT_D,
        FLE_D,
        FCLASS_S,
        FCLASS_D,
        FCVT_W_S,
        FCVT_WU_S,
        FCVT_W_D,
        FCVT_WU_D,
        FCVT_L_S,
        FCVT_LU_S,
        FCVT_L_D,
        FCVT_LU_D,
        FMV_X_W,
        FMV_X_D,
    }
)

_USES_FP_RS1_OPS: frozenset[int] = frozenset(
    {
        FADD_S,
        FSUB_S,
        FMUL_S,
        FDIV_S,
        FSQRT_S,
        FADD_D,
        FSUB_D,
        FMUL_D,
        FDIV_D,
        FSQRT_D,
        FMADD_S,
        FMSUB_S,
        FNMADD_S,
        FNMSUB_S,
        FMADD_D,
        FMSUB_D,
        FNMADD_D,
        FNMSUB_D,
        FMIN_S,
        FMAX_S,
        FMIN_D,
        FMAX_D,
        FSGNJ_S,
        FSGNJN_S,
        FSGNJX_S,
        FSGNJ_D,
        FSGNJN_D,
        FSGNJX_D,
        FEQ_S,
        FLT_S,
        FLE_S,
        FEQ_D,
        FLT_D,
        FLE_D,
        FCLASS_S,
        FCLASS_D,
        FCVT_W_S,
        FCVT_WU_S,
        FCVT_W_D,
        FCVT_WU_D,
        FCVT_L_S,
        FCVT_LU_S,
        FCVT_L_D,
        FCVT_LU_D,
        FMV_X_W,
        FMV_X_D,
        FCVT_S_D,
        FCVT_D_S,
    }
)

_USES_FP_RS2_OPS: frozenset[int] = frozenset(
    {
        FADD_S,
        FSUB_S,
        FMUL_S,
        FDIV_S,
        FADD_D,
        FSUB_D,
        FMUL_D,
        FDIV_D,
        FMADD_S,
        FMSUB_S,
        FNMADD_S,
        FNMSUB_S,
        FMADD_D,
        FMSUB_D,
        FNMADD_D,
        FNMSUB_D,
        FMIN_S,
        FMAX_S,
        FMIN_D,
        FMAX_D,
        FSGNJ_S,
        FSGNJN_S,
        FSGNJX_S,
        FSGNJ_D,
        FSGNJN_D,
        FSGNJX_D,
        FEQ_S,
        FLT_S,
        FLE_S,
        FEQ_D,
        FLT_D,
        FLE_D,
        FSW,
        FSD,
    }
)

_USES_FP_RS3_OPS: frozenset[int] = frozenset(
    {
        FMADD_S,
        FMSUB_S,
        FNMADD_S,
        FNMSUB_S,
        FMADD_D,
        FMSUB_D,
        FNMADD_D,
        FNMSUB_D,
    }
)

# uses_int_rs1: most ops, except pure-FP-rs1 / PC-relative / system / CSR-imm.
_NOT_USES_INT_RS1_OPS: frozenset[int] = frozenset(
    {
        LUI,
        AUIPC,
        JAL,
        ECALL,
        EBREAK,
        FENCE,
        FENCE_I,
        SFENCE_VMA,
        WFI,
        MRET,
        SRET,
        DRET,
        PAUSE,
        CSRRWI,
        CSRRSI,
        CSRRCI,
    }
)

_USES_INT_RS2_OPS: frozenset[int] = frozenset(
    {
        BEQ,
        BNE,
        BLT,
        BGE,
        BLTU,
        BGEU,
        ADD,
        SUB,
        AND,
        OR,
        XOR,
        SLL,
        SRL,
        SRA,
        SLT,
        SLTU,
        MUL,
        MULH,
        MULHSU,
        MULHU,
        DIV,
        DIVU,
        REM,
        REMU,
        SH1ADD,
        SH2ADD,
        SH3ADD,
        BSET,
        BCLR,
        BINV,
        BEXT,
        ANDN,
        ORN,
        XNOR_OP,
        MAX_OP,
        MAXU,
        MIN_OP,
        MINU,
        ROL,
        ROR,
        CZERO_EQZ,
        CZERO_NEZ,
        PACK,
        PACKH,
        SB,
        SH,
        SW,
        SC_W,
        AMOSWAP_W,
        AMOADD_W,
        AMOXOR_W,
        AMOAND_W,
        AMOOR_W,
        AMOMIN_W,
        AMOMAX_W,
        AMOMINU_W,
        AMOMAXU_W,
    }
)

_RS_MUL_OPS: frozenset[int] = frozenset(
    {MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU}
)

_RS_MEM_OPS: frozenset[int] = frozenset(
    {
        LB,
        LH,
        LW,
        LBU,
        LHU,
        SB,
        SH,
        SW,
        FLW,
        FSW,
        FLD,
        FSD,
        LR_W,
        SC_W,
        AMOSWAP_W,
        AMOADD_W,
        AMOXOR_W,
        AMOAND_W,
        AMOOR_W,
        AMOMIN_W,
        AMOMAX_W,
        AMOMINU_W,
        AMOMAXU_W,
        FENCE,
        FENCE_I,
        SFENCE_VMA,
    }
)

_RS_FP_OPS: frozenset[int] = frozenset(
    {
        FADD_S,
        FSUB_S,
        FADD_D,
        FSUB_D,
        FMIN_S,
        FMAX_S,
        FMIN_D,
        FMAX_D,
        FEQ_S,
        FLT_S,
        FLE_S,
        FEQ_D,
        FLT_D,
        FLE_D,
        FCVT_W_S,
        FCVT_WU_S,
        FCVT_S_W,
        FCVT_S_WU,
        FCVT_W_D,
        FCVT_WU_D,
        FCVT_D_W,
        FCVT_D_WU,
        FCVT_L_S,
        FCVT_LU_S,
        FCVT_S_L,
        FCVT_S_LU,
        FCVT_L_D,
        FCVT_LU_D,
        FCVT_D_L,
        FCVT_D_LU,
        FCVT_S_D,
        FCVT_D_S,
        FMV_X_W,
        FMV_W_X,
        FMV_X_D,
        FMV_D_X,
        FCLASS_S,
        FCLASS_D,
        FSGNJ_S,
        FSGNJN_S,
        FSGNJX_S,
        FSGNJ_D,
        FSGNJN_D,
        FSGNJX_D,
    }
)

_RS_FMUL_OPS: frozenset[int] = frozenset(
    {
        FMUL_S,
        FMUL_D,
        FMADD_S,
        FMSUB_S,
        FNMADD_S,
        FNMSUB_S,
        FMADD_D,
        FMSUB_D,
        FNMADD_D,
        FNMSUB_D,
    }
)

_RS_FDIV_OPS: frozenset[int] = frozenset({FDIV_S, FSQRT_S, FDIV_D, FSQRT_D})

_RS_NONE_OPS: frozenset[int] = frozenset({JAL, WFI, MRET, SRET, DRET, PAUSE})

_INT_STORE_OPS: frozenset[int] = frozenset({SB, SH, SW})

_BRANCH_OR_JUMP_OPS: frozenset[int] = frozenset(
    {BEQ, BNE, BLT, BGE, BLTU, BGEU, JAL, JALR}
)

_CSR_IMM_OPS: frozenset[int] = frozenset({CSRRWI, CSRRSI, CSRRCI})

_HAS_FP_FLAGS_OPS: frozenset[int] = frozenset(
    {
        FADD_S,
        FSUB_S,
        FMUL_S,
        FDIV_S,
        FSQRT_S,
        FADD_D,
        FSUB_D,
        FMUL_D,
        FDIV_D,
        FSQRT_D,
        FMADD_S,
        FMSUB_S,
        FNMADD_S,
        FNMSUB_S,
        FMADD_D,
        FMSUB_D,
        FNMADD_D,
        FNMSUB_D,
        FMIN_S,
        FMAX_S,
        FMIN_D,
        FMAX_D,
        FEQ_S,
        FLT_S,
        FLE_S,
        FEQ_D,
        FLT_D,
        FLE_D,
        FCVT_W_S,
        FCVT_WU_S,
        FCVT_S_W,
        FCVT_S_WU,
        FCVT_W_D,
        FCVT_WU_D,
        FCVT_D_W,
        FCVT_D_WU,
        FCVT_L_S,
        FCVT_LU_S,
        FCVT_S_L,
        FCVT_S_LU,
        FCVT_L_D,
        FCVT_LU_D,
        FCVT_D_L,
        FCVT_D_LU,
        FCVT_S_D,
        FCVT_D_S,
        FCLASS_S,
        FCLASS_D,
        FSGNJ_S,
        FSGNJN_S,
        FSGNJX_S,
        FSGNJ_D,
        FSGNJN_D,
        FSGNJX_D,
        FMV_X_W,
        FMV_W_X,
        FMV_X_D,
        FMV_D_X,
    }
)

_LOAD_OPS: frozenset[int] = frozenset({LB, LH, LW, LBU, LHU})
_LOAD_BYTE_OPS: frozenset[int] = frozenset({LB, LBU})
_LOAD_HALFWORD_OPS: frozenset[int] = frozenset({LH, LHU})
_LOAD_UNSIGNED_OPS: frozenset[int] = frozenset({LBU, LHU})
_MUL_OPS: frozenset[int] = frozenset({MUL, MULH, MULHSU, MULHU})
_DIV_OPS: frozenset[int] = frozenset({DIV, DIVU, REM, REMU})
_CSR_OPS: frozenset[int] = frozenset({CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI})
_AMO_OPS: frozenset[int] = frozenset(
    {
        LR_W,
        SC_W,
        AMOSWAP_W,
        AMOADD_W,
        AMOXOR_W,
        AMOAND_W,
        AMOOR_W,
        AMOMIN_W,
        AMOMAX_W,
        AMOMINU_W,
        AMOMAXU_W,
    }
)
_FP_LOAD_OPS: frozenset[int] = frozenset({FLW, FLD})
_FP_STORE_OPS: frozenset[int] = frozenset({FSW, FSD})
_FP_INSTRUCTION_OPS: frozenset[int] = frozenset(
    _FP_LOAD_OPS
    | _FP_STORE_OPS
    | _HAS_FP_FLAGS_OPS
    | _HAS_FP_DEST_OPS
    | _USES_FP_RS1_OPS
    | _USES_FP_RS2_OPS
    | _USES_FP_RS3_OPS
)
_FP_COMPUTE_OPS: frozenset[int] = _HAS_FP_FLAGS_OPS
_FP_TO_INT_OPS: frozenset[int] = frozenset(
    {
        FCVT_W_S,
        FCVT_WU_S,
        FCVT_W_D,
        FCVT_WU_D,
        FMV_X_W,
        FCVT_L_S,
        FCVT_LU_S,
        FCVT_L_D,
        FCVT_LU_D,
        FMV_X_D,
    }
)
_INT_TO_FP_OPS: frozenset[int] = frozenset(
    {
        FCVT_S_W,
        FCVT_S_WU,
        FCVT_D_W,
        FCVT_D_WU,
        FMV_W_X,
        FCVT_S_L,
        FCVT_S_LU,
        FCVT_D_L,
        FCVT_D_LU,
        FMV_D_X,
    }
)


def _derive_rs_type(op: int) -> int:
    """Compute the pre-decoded RS type from instruction_operation."""
    if op in _RS_NONE_OPS:
        return RS_NONE
    if op in _RS_MUL_OPS:
        return RS_MUL
    if op in _RS_MEM_OPS:
        return RS_MEM
    if op in _RS_FP_OPS:
        return RS_FP
    if op in _RS_FMUL_OPS:
        return RS_FMUL
    if op in _RS_FDIV_OPS:
        return RS_FDIV
    return RS_INT


def _derive_pre_decoded_flags(op: int) -> dict[str, int]:
    """Compute pre-decoded dispatch fields from instruction_operation."""
    has_fp_dest = 1 if op in _HAS_FP_DEST_OPS else 0
    has_int_dest = 1 if op in _HAS_INT_DEST_OPS else 0
    uses_fp_rs1 = 1 if op in _USES_FP_RS1_OPS else 0
    uses_fp_rs2 = 1 if op in _USES_FP_RS2_OPS else 0
    uses_fp_rs3 = 1 if op in _USES_FP_RS3_OPS else 0
    uses_int_rs1 = 0 if (uses_fp_rs1 or op in _NOT_USES_INT_RS1_OPS) else 1
    uses_int_rs2 = 1 if (not uses_fp_rs2 and op in _USES_INT_RS2_OPS) else 0
    return {
        "has_fp_dest": has_fp_dest,
        "has_int_dest": has_int_dest,
        "uses_fp_rs1": uses_fp_rs1,
        "uses_fp_rs2": uses_fp_rs2,
        "uses_fp_rs3": uses_fp_rs3,
        "uses_int_rs1": uses_int_rs1,
        "uses_int_rs2": uses_int_rs2,
        "rs_type": _derive_rs_type(op),
        "is_int_store": 1 if op in _INT_STORE_OPS else 0,
        "is_branch_or_jump": 1 if op in _BRANCH_OR_JUMP_OPS else 0,
        "is_fence": 1 if op == FENCE else 0,
        "is_fence_i": 1 if op in {FENCE_I, SFENCE_VMA} else 0,
        "is_csr_imm": 1 if op in _CSR_IMM_OPS else 0,
        "has_fp_flags": 1 if op in _HAS_FP_FLAGS_OPS else 0,
        "is_load_instruction": 1 if op in _LOAD_OPS else 0,
        "is_load_byte": 1 if op in _LOAD_BYTE_OPS else 0,
        "is_load_halfword": 1 if op in _LOAD_HALFWORD_OPS else 0,
        "is_load_unsigned": 1 if op in _LOAD_UNSIGNED_OPS else 0,
        "is_jump_and_link": 1 if op == JAL else 0,
        "is_jump_and_link_register": 1 if op == JALR else 0,
        "is_multiply": 1 if op in _MUL_OPS else 0,
        "is_divide": 1 if op in _DIV_OPS else 0,
        "is_csr_instruction": 1 if op in _CSR_OPS else 0,
        "is_amo_instruction": 1 if op in _AMO_OPS else 0,
        "is_lr": 1 if op == LR_W else 0,
        "is_sc": 1 if op == SC_W else 0,
        "is_mret": 1 if op in {MRET, SRET, DRET} else 0,
        "is_sret": 1 if op == SRET else 0,
        "is_dret": 1 if op == DRET else 0,
        "is_sfence_vma": 1 if op == SFENCE_VMA else 0,
        "is_wfi": 1 if op == WFI else 0,
        "is_ecall": 1 if op == ECALL else 0,
        "is_ebreak": 1 if op == EBREAK else 0,
        "is_fp_instruction": 1 if op in _FP_INSTRUCTION_OPS else 0,
        "is_fp_load": 1 if op in _FP_LOAD_OPS else 0,
        "is_fp_store": 1 if op in _FP_STORE_OPS else 0,
        "is_fp_load_double": 1 if op == FLD else 0,
        "is_fp_store_double": 1 if op == FSD else 0,
        "is_fp_compute": 1 if op in _FP_COMPUTE_OPS else 0,
        "is_pipelined_fp_op": 1 if op in (_RS_FMUL_OPS | _RS_FDIV_OPS) else 0,
        "is_fp_to_int": 1 if op in _FP_TO_INT_OPS else 0,
        "is_int_to_fp": 1 if op in _INT_TO_FP_OPS else 0,
        # id_stage registers is_not_nop = (instruction != NOP) for every real
        # instruction it presents (id_stage.sv). Keep packed test packets
        # faithful to that boundary even though dispatch qualifies slot-2
        # admission with i_valid_2. Pass is_not_nop=0 explicitly to model a
        # NOP bubble.
        "is_not_nop": 1,
    }


def build_from_id_to_ex(**kwargs: int) -> int:
    """Pack from_id_to_ex_t fields into a single bit vector.

    All fields default to 0.  Pass keyword arguments matching field names
    from the struct definition to set specific fields.

    Pre-decoded dispatch fields are auto-populated from instruction_operation
    when not explicitly set, mirroring what id_stage computes and registers in
    real hardware.
    """
    derived = _derive_pre_decoded_flags(int(kwargs.get("instruction_operation", 0)))
    for name, value in derived.items():
        kwargs.setdefault(name, value)

    val = 0
    for name, (offset, width) in _FROM_ID_TO_EX_OFFSETS.items():
        field_val = int(kwargs.get(name, 0))
        mask = (1 << width) - 1
        val |= (field_val & mask) << offset
    return val


def pack_instr_t(
    funct7: int = 0,
    source_reg_2: int = 0,
    source_reg_1: int = 0,
    funct3: int = 0,
    dest_reg: int = 0,
    opcode: int = 0,
) -> int:
    """Pack instr_t (32 bits).

    funct7[31:25] | rs2[24:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0].
    """
    val = 0
    val |= opcode & 0x7F
    val |= (dest_reg & 0x1F) << 7
    val |= (funct3 & 0x7) << 12
    val |= (source_reg_1 & 0x1F) << 15
    val |= (source_reg_2 & 0x1F) << 20
    val |= (funct7 & 0x7F) << 25
    return val


# =============================================================================
# ROB alloc_req_t field table (for unpacking output)
# =============================================================================
# reorder_buffer_alloc_req_t: MSB-first packed struct
ROB_ALLOC_REQ_FIELDS = [
    ("alloc_valid", 1),
    ("pc", XLEN),
    ("rs_type", 3),
    ("dest_rf", 1),
    ("dest_reg", REG_ADDR_WIDTH),
    ("dest_valid", 1),
    ("is_store", 1),
    ("is_fp_store", 1),
    ("is_fp_instruction", 1),
    ("is_branch", 1),
    ("predicted_taken", 1),
    ("predicted_target", XLEN),
    ("branch_target", XLEN),
    ("is_call", 1),
    ("is_return", 1),
    ("link_addr", XLEN),
    ("is_jal", 1),
    ("is_jalr", 1),
    ("is_csr", 1),
    ("is_fence", 1),
    ("is_fence_i", 1),
    ("is_wfi", 1),
    ("is_mret", 1),
    ("is_sret", 1),
    ("is_dret", 1),
    ("is_sfence_vma", 1),
    ("is_amo", 1),
    ("is_lr", 1),
    ("is_sc", 1),
    ("is_compressed", 1),
    ("csr_write_intent", 1),
    ("csr_addr", 12),
    ("csr_op", 3),
    ("csr_write_data", XLEN),
    ("has_fp_flags", 1),
]

ROB_ALLOC_REQ_WIDTH = sum(w for _, w in ROB_ALLOC_REQ_FIELDS)

_ROB_ALLOC_REQ_OFFSETS: dict[str, tuple[int, int]] = {}
_offset = ROB_ALLOC_REQ_WIDTH
for _name, _width in ROB_ALLOC_REQ_FIELDS:
    _offset -= _width
    _ROB_ALLOC_REQ_OFFSETS[_name] = (_offset, _width)
assert _offset == 0


def unpack_rob_alloc_req(raw: int) -> dict[str, int]:
    """Unpack o_rob_alloc_req bit vector into a dictionary."""
    result: dict[str, int] = {}
    for name, (offset, width) in _ROB_ALLOC_REQ_OFFSETS.items():
        mask = (1 << width) - 1
        result[name] = (raw >> offset) & mask
    return result


# =============================================================================
# ROB alloc_resp_t packing (7 bits input to DUT)
# =============================================================================
# reorder_buffer_alloc_resp_t: {alloc_ready, alloc_tag[4:0], full}
ALLOC_RESP_WIDTH = 7


def pack_rob_alloc_resp(
    alloc_ready: int = 0,
    alloc_tag: int = 0,
    full: int = 0,
) -> int:
    """Pack reorder_buffer_alloc_resp_t (7 bits MSB-first)."""
    val = 0
    val |= full & 1
    val |= (alloc_tag & MASK_TAG) << 1
    val |= (alloc_ready & 1) << 6
    return val


# =============================================================================
# rat_lookup_t packing (70 bits input to DUT)
# =============================================================================
# rat_lookup_t: {renamed[69], tag[68:64], value[63:0]}
RAT_LOOKUP_WIDTH = 70


def pack_rat_lookup(
    renamed: int = 0,
    tag: int = 0,
    value: int = 0,
) -> int:
    """Pack rat_lookup_t (70 bits MSB-first)."""
    val = 0
    val |= value & MASK64
    val |= (tag & MASK_TAG) << FLEN
    val |= (renamed & 1) << (FLEN + ROB_TAG_WIDTH)
    return val


# =============================================================================
# rs_dispatch_t field table (for unpacking output)
# =============================================================================
RS_DISPATCH_FIELDS = [
    ("valid", 1),
    ("rs_type", RS_TYPE_WIDTH),
    ("rob_tag", ROB_TAG_WIDTH),
    ("op", OP_WIDTH),
    ("src1_ready", 1),
    ("src1_tag", ROB_TAG_WIDTH),
    ("src1_value", FLEN),
    ("src2_ready", 1),
    ("src2_tag", ROB_TAG_WIDTH),
    ("src2_value", FLEN),
    ("src3_ready", 1),
    ("src3_tag", ROB_TAG_WIDTH),
    ("src3_value", FLEN),
    ("imm", XLEN),
    ("use_imm", 1),
    ("rm", 3),
    ("branch_target", XLEN),
    ("predicted_taken", 1),
    ("predicted_target", XLEN),
    ("is_fp_mem", 1),
    ("mem_needs_lq", 1),
    ("mem_needs_sq", 1),
    ("mem_size", MEM_SIZE_WIDTH),
    ("mem_signed", 1),
    ("csr_addr", 12),
    ("csr_imm", 5),
    ("pc", XLEN),
    ("link_addr", XLEN),
    ("has_checkpoint", 1),
    ("checkpoint_id", CHECKPOINT_ID_WIDTH),
    ("is_call", 1),
    ("is_return", 1),
]

RS_DISPATCH_WIDTH = sum(w for _, w in RS_DISPATCH_FIELDS)

_RS_DISPATCH_OFFSETS: dict[str, tuple[int, int]] = {}
_offset = RS_DISPATCH_WIDTH
for _name, _width in RS_DISPATCH_FIELDS:
    _offset -= _width
    _RS_DISPATCH_OFFSETS[_name] = (_offset, _width)
assert _offset == 0


def unpack_rs_dispatch(raw: int) -> dict[str, int]:
    """Unpack o_rs_dispatch bit vector into a dictionary."""
    result: dict[str, int] = {}
    for name, (offset, width) in _RS_DISPATCH_OFFSETS.items():
        mask = (1 << width) - 1
        result[name] = (raw >> offset) & mask
    return result


# =============================================================================
# DUT Interface Class
# =============================================================================


class DispatchInterface:
    """Interface to the Dispatch DUT.

    Handles packing/unpacking of struct signals automatically since
    Verilator flattens packed structs into single bit vectors.
    """

    def __init__(self, dut: Any) -> None:
        """Initialize interface with DUT handle."""
        self.dut = dut

    @property
    def clock(self) -> Any:
        """Return clock signal."""
        return self.dut.i_clk

    async def reset_dut(self, cycles: int = 5) -> None:
        """Reset the DUT and initialize all inputs.

        After reset, returns at falling edge so signals driven immediately
        after reset are stable before the next rising edge.
        """
        self._init_inputs()
        self.dut.i_rst_n.value = 0

        for _ in range(cycles):
            await RisingEdge(self.clock)

        self.dut.i_rst_n.value = 1
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

    async def step(self) -> None:
        """Advance one cycle: rising edge then falling edge."""
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

    def _init_inputs(self) -> None:
        """Initialize all input signals to safe defaults."""
        self.dut.i_from_id_to_ex.value = 0
        self.dut.i_valid.value = 0
        # Slot-2 instruction (2-wide dispatch).  Default inactive; tests that
        # exercise 2-wide behavior drive it explicitly.
        self.dut.i_from_id_to_ex_2.value = 0
        self.dut.i_valid_2.value = 0
        self.dut.i_rs1_addr.value = 0
        self.dut.i_rs2_addr.value = 0
        self.dut.i_fp_rs3_addr.value = 0
        # Slot-2 source register addresses (2-wide dispatch).
        self.dut.i_rs1_addr_2.value = 0
        self.dut.i_rs2_addr_2.value = 0
        self.dut.i_fp_rs3_addr_2.value = 0
        self.dut.i_frm_csr.value = 0
        self.dut.i_rob_alloc_resp.value = 0
        # Slot-2 ROB alloc resp (2-wide dispatch).
        self.dut.i_rob_alloc_resp_2.value = 0
        self.dut.i_int_src1.value = 0
        self.dut.i_int_src2.value = 0
        self.dut.i_fp_src1.value = 0
        self.dut.i_fp_src2.value = 0
        self.dut.i_fp_src3.value = 0
        # Slot-2 RAT lookup results (raw, before intra-bundle RAW bypass).
        self.dut.i_int_src1_2.value = 0
        self.dut.i_int_src2_2.value = 0
        self.dut.i_fp_src1_2.value = 0
        self.dut.i_fp_src2_2.value = 0
        self.dut.i_fp_src3_2.value = 0
        self.dut.i_checkpoint_available.value = 0
        self.dut.i_checkpoint_alloc_id.value = 0
        self.dut.i_ras_tos.value = 0
        self.dut.i_ras_valid_count.value = 0
        self.dut.i_rob_full.value = 0
        self.dut.i_int_rs_full.value = 0
        self.dut.i_mul_rs_full.value = 0
        self.dut.i_mem_rs_full.value = 0
        self.dut.i_fp_rs_full.value = 0
        self.dut.i_fmul_rs_full.value = 0
        self.dut.i_fdiv_rs_full.value = 0
        self.dut.i_lq_full.value = 0
        self.dut.i_sq_full.value = 0
        # Slot-2 "room for 2" status inputs.  Default to room available.
        self.dut.i_rob_full_for_2.value = 0
        self.dut.i_int_rs_full_for_2.value = 0
        self.dut.i_mul_rs_full_for_2.value = 0
        self.dut.i_mem_rs_full_for_2.value = 0
        self.dut.i_fp_rs_full_for_2.value = 0
        self.dut.i_fmul_rs_full_for_2.value = 0
        self.dut.i_fdiv_rs_full_for_2.value = 0
        self.dut.i_lq_full_for_2.value = 0
        self.dut.i_sq_full_for_2.value = 0
        self.dut.i_flush.value = 0
        self.dut.i_hold.value = 0

    # =========================================================================
    # Instruction Input
    # =========================================================================

    def drive_instruction(
        self,
        valid: bool = True,
        rs1_addr: int = 0,
        rs2_addr: int = 0,
        fp_rs3_addr: int = 0,
        **kwargs: int,
    ) -> None:
        """Drive the instruction input and associated signals.

        ``kwargs`` are passed to ``build_from_id_to_ex`` to pack the
        ``i_from_id_to_ex`` bitvector.
        """
        self.dut.i_valid.value = 1 if valid else 0
        self.dut.i_rs1_addr.value = rs1_addr & 0x1F
        self.dut.i_rs2_addr.value = rs2_addr & 0x1F
        self.dut.i_fp_rs3_addr.value = fp_rs3_addr & 0x1F
        self.dut.i_from_id_to_ex.value = build_from_id_to_ex(**kwargs)

    def drive_instruction_2(
        self,
        valid: bool = True,
        rs1_addr: int = 0,
        rs2_addr: int = 0,
        fp_rs3_addr: int = 0,
        **kwargs: int,
    ) -> None:
        """Drive the slot-2 instruction input and associated signals."""
        self.dut.i_valid_2.value = 1 if valid else 0
        self.dut.i_rs1_addr_2.value = rs1_addr & 0x1F
        self.dut.i_rs2_addr_2.value = rs2_addr & 0x1F
        self.dut.i_fp_rs3_addr_2.value = fp_rs3_addr & 0x1F
        self.dut.i_from_id_to_ex_2.value = build_from_id_to_ex(**kwargs)

    # =========================================================================
    # FRM CSR
    # =========================================================================

    def set_frm_csr(self, frm: int) -> None:
        """Set the FRM CSR value."""
        self.dut.i_frm_csr.value = frm & 0x7

    # =========================================================================
    # ROB Allocation Response
    # =========================================================================

    def drive_rob_alloc_resp(
        self, alloc_ready: int = 1, alloc_tag: int = 0, full: int = 0
    ) -> None:
        """Drive the ROB allocation response input."""
        self.dut.i_rob_alloc_resp.value = pack_rob_alloc_resp(
            alloc_ready=alloc_ready, alloc_tag=alloc_tag, full=full
        )

    def drive_rob_alloc_resp_2(
        self, alloc_ready: int = 1, alloc_tag: int = 0, full: int = 0
    ) -> None:
        """Drive the slot-2 ROB allocation response input."""
        self.dut.i_rob_alloc_resp_2.value = pack_rob_alloc_resp(
            alloc_ready=alloc_ready, alloc_tag=alloc_tag, full=full
        )

    # =========================================================================
    # RAT Source Lookups
    # =========================================================================

    def drive_int_src1(self, renamed: int = 0, tag: int = 0, value: int = 0) -> None:
        """Drive integer source 1 RAT lookup result."""
        self.dut.i_int_src1.value = pack_rat_lookup(renamed, tag, value)

    def drive_int_src2(self, renamed: int = 0, tag: int = 0, value: int = 0) -> None:
        """Drive integer source 2 RAT lookup result."""
        self.dut.i_int_src2.value = pack_rat_lookup(renamed, tag, value)

    def drive_int_src1_2(self, renamed: int = 0, tag: int = 0, value: int = 0) -> None:
        """Drive slot-2 integer source 1 RAT lookup result."""
        self.dut.i_int_src1_2.value = pack_rat_lookup(renamed, tag, value)

    # =========================================================================
    # Resource Status
    # =========================================================================

    def set_rob_full(self, full: bool) -> None:
        """Set ROB full signal."""
        self.dut.i_rob_full.value = 1 if full else 0

    def set_int_rs_full(self, full: bool) -> None:
        """Set INT RS full signal."""
        self.dut.i_int_rs_full.value = 1 if full else 0

    def set_mul_rs_full(self, full: bool) -> None:
        """Set MUL RS full signal."""
        self.dut.i_mul_rs_full.value = 1 if full else 0

    def set_mem_rs_full(self, full: bool) -> None:
        """Set MEM RS full signal."""
        self.dut.i_mem_rs_full.value = 1 if full else 0

    def set_lq_full(self, full: bool) -> None:
        """Set LQ full signal."""
        self.dut.i_lq_full.value = 1 if full else 0

    def set_sq_full(self, full: bool) -> None:
        """Set SQ full signal."""
        self.dut.i_sq_full.value = 1 if full else 0

    def set_int_rs_full_for_2(self, full: bool) -> None:
        """Set INT RS room-for-2 full signal."""
        self.dut.i_int_rs_full_for_2.value = 1 if full else 0

    def set_mul_rs_full_for_2(self, full: bool) -> None:
        """Set MUL RS room-for-2 full signal."""
        self.dut.i_mul_rs_full_for_2.value = 1 if full else 0

    # =========================================================================
    # Checkpoint
    # =========================================================================

    def drive_checkpoint(self, available: bool = True, alloc_id: int = 0) -> None:
        """Drive checkpoint availability and allocation ID."""
        self.dut.i_checkpoint_available.value = 1 if available else 0
        self.dut.i_checkpoint_alloc_id.value = alloc_id & (
            (1 << CHECKPOINT_ID_WIDTH) - 1
        )

    # =========================================================================
    # RAS State
    # =========================================================================

    # =========================================================================
    # Flush
    # =========================================================================

    def set_flush(self, flush: bool) -> None:
        """Set flush signal."""
        self.dut.i_flush.value = 1 if flush else 0

    # =========================================================================
    # Output Readers
    # =========================================================================

    def read_rob_alloc_req(self) -> dict[str, int]:
        """Read and unpack o_rob_alloc_req."""
        return unpack_rob_alloc_req(int(self.dut.o_rob_alloc_req.value))

    def read_rob_alloc_req_2(self) -> dict[str, int]:
        """Read and unpack o_rob_alloc_req_2."""
        return unpack_rob_alloc_req(int(self.dut.o_rob_alloc_req_2.value))

    def read_rs_dispatch(self) -> dict[str, int]:
        """Read and unpack o_rs_dispatch."""
        return unpack_rs_dispatch(int(self.dut.o_rs_dispatch.value))

    def read_int_rs_dispatch(self) -> dict[str, int]:
        """Read and unpack o_int_rs_dispatch."""
        return unpack_rs_dispatch(int(self.dut.o_int_rs_dispatch.value))

    def read_int_rs_dispatch_2(self) -> dict[str, int]:
        """Read and unpack o_int_rs_dispatch_2."""
        return unpack_rs_dispatch(int(self.dut.o_int_rs_dispatch_2.value))

    def read_mul_rs_dispatch_2(self) -> dict[str, int]:
        """Read and unpack o_mul_rs_dispatch_2."""
        return unpack_rs_dispatch(int(self.dut.o_mul_rs_dispatch_2.value))

    def read_mem_rs_dispatch_2(self) -> dict[str, int]:
        """Read and unpack o_mem_rs_dispatch_2."""
        return unpack_rs_dispatch(int(self.dut.o_mem_rs_dispatch_2.value))

    def read_fp_rs_dispatch_2(self) -> dict[str, int]:
        """Read and unpack o_fp_rs_dispatch_2."""
        return unpack_rs_dispatch(int(self.dut.o_fp_rs_dispatch_2.value))

    @property
    def stall(self) -> bool:
        """Read o_stall output."""
        return bool(self.dut.o_stall.value)

    @property
    def rat_alloc_valid(self) -> bool:
        """Read o_rat_alloc_valid output."""
        return bool(self.dut.o_rat_alloc_valid.value)

    @property
    def rat_alloc_dest_rf(self) -> int:
        """Read o_rat_alloc_dest_rf output (0=INT, 1=FP)."""
        return int(self.dut.o_rat_alloc_dest_rf.value)

    @property
    def rat_alloc_dest_reg(self) -> int:
        """Read o_rat_alloc_dest_reg output."""
        return int(self.dut.o_rat_alloc_dest_reg.value)

    @property
    def rat_alloc_rob_tag(self) -> int:
        """Read o_rat_alloc_rob_tag output."""
        return int(self.dut.o_rat_alloc_rob_tag.value)

    @property
    def rat_alloc_valid_2(self) -> bool:
        """Read o_rat_alloc_valid_2 output."""
        return bool(self.dut.o_rat_alloc_valid_2.value)

    @property
    def rat_alloc_dest_reg_2(self) -> int:
        """Read o_rat_alloc_dest_reg_2 output."""
        return int(self.dut.o_rat_alloc_dest_reg_2.value)

    @property
    def rat_alloc_rob_tag_2(self) -> int:
        """Read o_rat_alloc_rob_tag_2 output."""
        return int(self.dut.o_rat_alloc_rob_tag_2.value)

    @property
    def checkpoint_save(self) -> bool:
        """Read o_checkpoint_save output."""
        return bool(self.dut.o_checkpoint_save.value)

    @property
    def checkpoint_save_for_slot2(self) -> bool:
        """Read o_checkpoint_save_for_slot2 output."""
        return bool(self.dut.o_checkpoint_save_for_slot2.value)

    @property
    def checkpoint_id(self) -> int:
        """Read o_checkpoint_id output."""
        return int(self.dut.o_checkpoint_id.value)

    @property
    def checkpoint_branch_tag(self) -> int:
        """Read o_checkpoint_branch_tag output."""
        return int(self.dut.o_checkpoint_branch_tag.value)

    @property
    def rob_checkpoint_valid(self) -> bool:
        """Read o_rob_checkpoint_valid output."""
        return bool(self.dut.o_rob_checkpoint_valid.value)

    @property
    def rob_checkpoint_id(self) -> int:
        """Read o_rob_checkpoint_id output."""
        return int(self.dut.o_rob_checkpoint_id.value)

    @property
    def ras_tos_out(self) -> int:
        """Read o_ras_tos output."""
        return int(self.dut.o_ras_tos.value)

    @property
    def ras_valid_count_out(self) -> int:
        """Read o_ras_valid_count output."""
        return int(self.dut.o_ras_valid_count.value)
