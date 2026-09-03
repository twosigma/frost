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

"""Map instruction mnemonics to encoders and reference evaluators.

Each entry connects a mnemonic such as ``add``, ``lw``, or ``beq`` to an encoder
that turns instruction parameters into raw instruction bits and, where the
instruction writes a register, an evaluator that computes the expected result in
software. An instruction that writes no register has an encoder alone.

    - R_ALU: register-register operations (add, sub, mul, div, ...)
    - I_ALU: immediate ALU operations (addi, andi, slli, ...)
    - LOADS: loads (lw, lh, lb, lhu, lbu)
    - STORES: stores (sw, sh, sb), encoder only
    - BRANCHES: conditional branches (beq, bne, blt, ...), encoder only
    - JUMPS: jumps (jal, jalr)

The tables keep test selection data-driven: adding an entry requires no test-loop
changes.

Example::

    >>> # Look up ADD instruction
    >>> encoder, evaluator = R_ALU["add"]
    >>> # Encode: add x5, x3, x4
    >>> binary = encoder(rd=5, rs1=3, rs2=4)
    >>> # Evaluate: compute result
    >>> result = evaluator(register[3], register[4])

To add an instruction, write its evaluator in alu_model.py if one does not exist
yet, then add the entry to the table it belongs in here.
"""

from collections.abc import Callable


from encoders.instruction_encode import (
    enc_r,
    enc_i,
    enc_i_load,
    enc_i_jalr,
    enc_s,
    enc_b,
    enc_j,
    enc_fence,
    enc_fence_i,
    enc_pause,
    enc_csrrw,
    enc_csrrs,
    enc_csrrc,
    enc_csrrwi,
    enc_csrrsi,
    enc_csrrci,
    CSRAddress,
    # A extension (atomics)
    enc_lr_w,
    enc_sc_w,
    enc_amoswap_w,
    enc_amoadd_w,
    enc_amoxor_w,
    enc_amoand_w,
    enc_amoor_w,
    enc_amomin_w,
    enc_amomax_w,
    enc_amominu_w,
    enc_amomaxu_w,
    # Machine-mode trap instructions
    enc_ecall,
    enc_ebreak,
    enc_mret,
    enc_wfi,
    # F extension (floating-point)
    enc_flw,
    enc_fsw,
    enc_fld,
    enc_fsd,
    enc_fadd_s,
    enc_fsub_s,
    enc_fmul_s,
    enc_fdiv_s,
    enc_fsqrt_s,
    enc_fadd_d,
    enc_fsub_d,
    enc_fmul_d,
    enc_fdiv_d,
    enc_fsqrt_d,
    enc_fmadd_s,
    enc_fmsub_s,
    enc_fnmadd_s,
    enc_fnmsub_s,
    enc_fmadd_d,
    enc_fmsub_d,
    enc_fnmadd_d,
    enc_fnmsub_d,
    enc_fsgnj_s,
    enc_fsgnjn_s,
    enc_fsgnjx_s,
    enc_fsgnj_d,
    enc_fsgnjn_d,
    enc_fsgnjx_d,
    enc_fmin_s,
    enc_fmax_s,
    enc_fmin_d,
    enc_fmax_d,
    enc_fcvt_w_s,
    enc_fcvt_wu_s,
    enc_fcvt_s_w,
    enc_fcvt_s_wu,
    enc_fcvt_w_d,
    enc_fcvt_wu_d,
    enc_fcvt_d_w,
    enc_fcvt_d_wu,
    enc_fcvt_s_d,
    enc_fcvt_d_s,
    enc_fmv_x_w,
    enc_fmv_w_x,
    enc_fclass_s,
    enc_fclass_d,
    enc_feq_s,
    enc_flt_s,
    enc_fle_s,
    enc_feq_d,
    enc_flt_d,
    enc_fle_d,
)
from encoders.compressed_encode import (
    # C extension (compressed instructions)
    enc_c_addi,
    enc_c_li,
    enc_c_slli,
    enc_c_srli,
    enc_c_srai,
    enc_c_andi,
    enc_c_mv,
    enc_c_add,
    enc_c_sub,
    enc_c_xor,
    enc_c_or,
    enc_c_and,
    enc_c_lw,
    enc_c_sw,
    enc_c_lwsp,
    enc_c_swsp,
    enc_c_j,
    enc_c_jr,
    enc_c_jalr,
    enc_c_beqz,
    enc_c_bnez,
)
from models.alu_model import (
    add,
    sub,
    and_rv,
    or_rv,
    xor,
    sll,
    srl,
    sra,
    slt,
    sltu,
    mul,
    mulh,
    mulhsu,
    mulhu,
    div,
    divu,
    rem,
    remu,
    lw,
    lb,
    lbu,
    lh,
    lhu,
    # Zba extension
    sh1add,
    sh2add,
    sh3add,
    # Zbs extension
    bset,
    bclr,
    binv,
    bext,
    # Zbb extension
    andn,
    orn,
    xnor,
    max_rv,
    maxu,
    min_rv,
    minu,
    rol,
    ror,
    clz,
    ctz,
    cpop,
    sext_b,
    sext_h,
    zext_h,
    orc_b,
    rev8,
    # Zicond extension
    czero_eqz,
    czero_nez,
    # Zbkb extension
    pack,
    packh,
    brev8,
    # A extension (atomics)
    amoswap,
    amoadd,
    amoxor,
    amoand,
    amoor,
    amomin,
    amomax,
    amominu,
    amomaxu,
)
from models.fp_model import (
    box32,
    unbox32,
    # F extension - arithmetic
    fadd_s,
    fsub_s,
    fmul_s,
    fdiv_s,
    fsqrt_s,
    fmadd_s,
    fmsub_s,
    fnmadd_s,
    fnmsub_s,
    # D extension - arithmetic
    fadd_d,
    fsub_d,
    fmul_d,
    fdiv_d,
    fsqrt_d,
    fmadd_d,
    fmsub_d,
    fnmadd_d,
    fnmsub_d,
    # F extension - sign manipulation
    fsgnj_s,
    fsgnjn_s,
    fsgnjx_s,
    # D extension - sign manipulation
    fsgnj_d,
    fsgnjn_d,
    fsgnjx_d,
    # F extension - min/max
    fmin_s,
    fmax_s,
    # D extension - min/max
    fmin_d,
    fmax_d,
    # F extension - comparison
    feq_s,
    flt_s,
    fle_s,
    # D extension - comparison
    feq_d,
    flt_d,
    fle_d,
    # F extension - conversion
    fcvt_w_s,
    fcvt_wu_s,
    fcvt_s_w,
    fcvt_s_wu,
    # D extension - conversion
    fcvt_w_d,
    fcvt_wu_d,
    fcvt_d_w,
    fcvt_d_wu,
    fcvt_s_d,
    fcvt_d_s,
    # F extension - move
    fmv_x_w,
    fmv_w_x,
    # F extension - classify
    fclass_s,
    # D extension - classify
    fclass_d,
    # FP loads
    fld,
)


def make_r_encoder(f7: int, f3: int) -> Callable:
    """Create R-type instruction encoders."""
    return lambda rd, rs1, rs2: enc_r(f7, rs2, rs1, f3, rd)


def make_i_encoder(f3: int) -> Callable:
    """Create I-type ALU instruction encoders."""
    return lambda rd, rs1, imm: enc_i(imm, rs1, f3, rd)


def make_i_shift_encoder(f3: int, f7: int) -> Callable:
    """Create I-type shift instruction encoders."""
    return lambda rd, rs1, sh: enc_i((sh & 0x1F) | (f7 << 5), rs1, f3, rd)


def make_i_unary_encoder(f3: int, f7: int, rs2_field: int) -> Callable:
    """Create I-type unary instruction encoders (Zbb clz, ctz, cpop, sext.b, sext.h).

    These instructions encode the operation type in both funct7 and rs2 field,
    and only take one source register operand.
    """
    return lambda rd, rs1: enc_i((rs2_field & 0x1F) | (f7 << 5), rs1, f3, rd)


def make_i_fixed_encoder(f3: int, f7: int, rs2_field: int) -> Callable:
    """Create I-type instruction encoders with fixed rs2 field (Zbb orc.b, rev8).

    These instructions use a fixed value in the rs2 field.
    """
    return lambda rd, rs1: enc_i((rs2_field & 0x1F) | (f7 << 5), rs1, f3, rd)


def make_r_unary_encoder(f7: int, f3: int) -> Callable:
    """Create an R-type unary instruction encoder (zext.h, with rs2 tied to 0)."""
    return lambda rd, rs1: enc_r(f7, 0, rs1, f3, rd)


def make_load_encoder(f3: int) -> Callable:
    """Create load instruction encoders."""
    return lambda rd, rs1, imm: enc_i_load(imm, rs1, f3, rd)


def make_store_encoder(f3: int) -> Callable:
    """Create store instruction encoders."""
    return lambda rs2, rs1, imm: enc_s(rs2, rs1, f3, imm)


def make_branch_encoder(f3: int) -> Callable:
    """Create branch instruction encoders."""
    return lambda rs2, rs1, offset: enc_b(rs2, rs1, f3, offset)


# Operation tables: mnemonic -> (encoder, evaluator). The encoder builds the raw
# bits driven into the DUT. The evaluator models the expected result.
R_ALU: dict[str, tuple[Callable, Callable]] = {
    # base-ISA
    "add": (make_r_encoder(0x00, 0x0), add),
    "sub": (make_r_encoder(0x20, 0x0), sub),
    "and": (make_r_encoder(0x00, 0x7), and_rv),
    "or": (make_r_encoder(0x00, 0x6), or_rv),
    "xor": (make_r_encoder(0x00, 0x4), xor),
    "sll": (make_r_encoder(0x00, 0x1), sll),
    "srl": (make_r_encoder(0x00, 0x5), srl),
    "sra": (make_r_encoder(0x20, 0x5), sra),
    "slt": (make_r_encoder(0x00, 0x2), slt),
    "sltu": (make_r_encoder(0x00, 0x3), sltu),
    # M-extension
    "mul": (make_r_encoder(0x01, 0x0), mul),
    "mulh": (make_r_encoder(0x01, 0x1), mulh),
    "mulhsu": (make_r_encoder(0x01, 0x2), mulhsu),
    "mulhu": (make_r_encoder(0x01, 0x3), mulhu),
    "div": (make_r_encoder(0x01, 0x4), div),
    "divu": (make_r_encoder(0x01, 0x5), divu),
    "rem": (make_r_encoder(0x01, 0x6), rem),
    "remu": (make_r_encoder(0x01, 0x7), remu),
    # Zba extension - address generation
    "sh1add": (make_r_encoder(0x10, 0x2), sh1add),
    "sh2add": (make_r_encoder(0x10, 0x4), sh2add),
    "sh3add": (make_r_encoder(0x10, 0x6), sh3add),
    # Zbs extension - single-bit operations (register form)
    "bset": (make_r_encoder(0x14, 0x1), bset),
    "bclr": (make_r_encoder(0x24, 0x1), bclr),
    "binv": (make_r_encoder(0x34, 0x1), binv),
    "bext": (make_r_encoder(0x24, 0x5), bext),
    # Zbb extension - logical with complement
    "andn": (make_r_encoder(0x20, 0x7), andn),
    "orn": (make_r_encoder(0x20, 0x6), orn),
    "xnor": (make_r_encoder(0x20, 0x4), xnor),
    # Zbb extension - min/max comparisons
    "max": (make_r_encoder(0x05, 0x6), max_rv),
    "maxu": (make_r_encoder(0x05, 0x7), maxu),
    "min": (make_r_encoder(0x05, 0x4), min_rv),
    "minu": (make_r_encoder(0x05, 0x5), minu),
    # Zbb extension - rotations (register form)
    "rol": (make_r_encoder(0x30, 0x1), rol),
    "ror": (make_r_encoder(0x30, 0x5), ror),
    # Zicond extension - conditional operations
    "czero.eqz": (make_r_encoder(0x07, 0x5), czero_eqz),
    "czero.nez": (make_r_encoder(0x07, 0x7), czero_nez),
    # Zbkb extension - bit manipulation for crypto
    "pack": (make_r_encoder(0x04, 0x4), pack),
    "packh": (make_r_encoder(0x04, 0x7), packh),
}

I_ALU: dict[str, tuple[Callable, Callable]] = {
    "addi": (make_i_encoder(0x0), add),
    "andi": (make_i_encoder(0x7), and_rv),
    "ori": (make_i_encoder(0x6), or_rv),
    "xori": (make_i_encoder(0x4), xor),
    "slli": (make_i_shift_encoder(0x1, 0x00), sll),
    "srli": (make_i_shift_encoder(0x5, 0x00), srl),
    "srai": (make_i_shift_encoder(0x5, 0x20), sra),
    "slti": (make_i_encoder(0x2), slt),
    "sltiu": (make_i_encoder(0x3), sltu),
    # Zbs extension - single-bit operations (immediate form)
    "bseti": (make_i_shift_encoder(0x1, 0x14), bset),
    "bclri": (make_i_shift_encoder(0x1, 0x24), bclr),
    "binvi": (make_i_shift_encoder(0x1, 0x34), binv),
    "bexti": (make_i_shift_encoder(0x5, 0x24), bext),
    # Zbb extension - rotate immediate
    "rori": (make_i_shift_encoder(0x5, 0x30), ror),
}

LOADS: dict[str, tuple[Callable, Callable]] = {
    "lw": (make_load_encoder(0x2), lw),
    "lb": (make_load_encoder(0x0), lb),
    "lbu": (make_load_encoder(0x4), lbu),
    "lh": (make_load_encoder(0x1), lh),
    "lhu": (make_load_encoder(0x5), lhu),
}

STORES: dict[str, Callable] = {
    "sw": make_store_encoder(0x2),
    "sb": make_store_encoder(0x0),
    "sh": make_store_encoder(0x1),
}

BRANCHES: dict[str, Callable] = {
    "beq": make_branch_encoder(0x0),
    "bne": make_branch_encoder(0x1),
    "blt": make_branch_encoder(0x4),
    "bge": make_branch_encoder(0x5),
    "bltu": make_branch_encoder(0x6),
    "bgeu": make_branch_encoder(0x7),
}

JUMPS: dict[str, Callable] = {
    "jal": lambda rd, offset: enc_j(rd, offset),
    "jalr": lambda rd, rs1, imm: enc_i_jalr(imm, rs1, rd),
}

# Zifencei memory-ordering instructions. They write no register, so the table
# carries an encoder and no evaluator.
FENCES: dict[str, Callable] = {
    "fence": enc_fence,
    "fence.i": enc_fence_i,
    # Zihintpause extension
    "pause": enc_pause,
}

# Zicsr read/modify/write instructions. Each writes the old CSR value into rd.
# The encoder takes (rd, csr_address, rs1_or_zimm). Against the read-only Zicntr
# counters the random stream passes rs1=x0 or zimm=0, which reads the CSR without
# modifying it (the csrr pseudo-instruction).
CSRS: dict[str, Callable] = {
    "csrrw": enc_csrrw,
    "csrrs": enc_csrrs,
    "csrrc": enc_csrrc,
    "csrrwi": enc_csrrwi,
    "csrrsi": enc_csrrsi,
    "csrrci": enc_csrrci,
}

# Zicntr CSR addresses the random stream may read. CYCLE and TIME increment every
# clock cycle, so their values are unpredictable once a mul or div stalls. Only
# INSTRET is listed: it advances once per retired instruction. The rv32-era
# high-half counters do not exist at rv64, where reads of them trap.
ZICNTR_CSRS: list[int] = [
    CSRAddress.INSTRET,
]

# Zbb unary bit-manipulation operations. Each takes a single source register
# (rd, rs1) and encodes the operation in funct7 plus the rs2 field.
I_UNARY: dict[str, tuple[Callable, Callable]] = {
    # funct3=1, funct7=0x30, rs2 encodes operation
    "clz": (make_i_unary_encoder(0x1, 0x30, 0), clz),
    "ctz": (make_i_unary_encoder(0x1, 0x30, 1), ctz),
    "cpop": (make_i_unary_encoder(0x1, 0x30, 2), cpop),
    "sext.b": (make_i_unary_encoder(0x1, 0x30, 4), sext_b),
    "sext.h": (make_i_unary_encoder(0x1, 0x30, 5), sext_h),
    # zext.h is R-type (opcode 0x33) with funct7=0x04, funct3=4, rs2=0
    "zext.h": (make_r_unary_encoder(0x04, 0x4), zext_h),
    # funct3=5, fixed rs2 value
    "orc.b": (make_i_fixed_encoder(0x5, 0x14, 7), orc_b),
    "rev8": (make_i_fixed_encoder(0x5, 0x34, 0x18), rev8),
    # Zbkb extension - bit manipulation for crypto
    "brev8": (make_i_fixed_encoder(0x5, 0x34, 7), brev8),
}

# A extension. An AMO atomically loads a word, applies an operation to it, and
# stores the result back. rd receives the original memory value.
#
# LR.W loads a word and sets a reservation. SC.W stores only if the reservation
# still holds, and writes 0 to rd on success or 1 on failure. Both are encoders
# only; the directed atomics test models their memory and rd effects.
#
# AMO entries are (encoder, evaluator):
#   encoder:   lambda rd, rs2, rs1 -> 32-bit instruction
#   evaluator: lambda old_value, rs2_value -> new value for memory
AMO_LR_SC: dict[str, Callable] = {
    "lr.w": enc_lr_w,
    "sc.w": enc_sc_w,
}

AMO: dict[str, tuple[Callable, Callable]] = {
    "amoswap.w": (enc_amoswap_w, amoswap),
    "amoadd.w": (enc_amoadd_w, amoadd),
    "amoxor.w": (enc_amoxor_w, amoxor),
    "amoand.w": (enc_amoand_w, amoand),
    "amoor.w": (enc_amoor_w, amoor),
    "amomin.w": (enc_amomin_w, amomin),
    "amomax.w": (enc_amomax_w, amomax),
    "amominu.w": (enc_amominu_w, amominu),
    "amomaxu.w": (enc_amomaxu_w, amomaxu),
}

# Machine-mode trap instructions, encoder only. The random stream leaves them out
# because they change control flow and need a trap handler set up first. Directed
# tests cover them instead.
#
# ECALL: environment call, raises an exception and jumps to mtvec.
# EBREAK: breakpoint exception, raises an exception and jumps to mtvec.
# MRET: returns from a trap, restoring the PC from mepc and restoring mstatus.
# WFI: waits for an interrupt, stalling until one is pending.
TRAP_INSTRS: dict[str, Callable] = {
    "ecall": enc_ecall,
    "ebreak": enc_ebreak,
    "mret": enc_mret,
    "wfi": enc_wfi,
}

# =============================================================================
# C extension (compressed instructions)
# =============================================================================
#
# Compressed instructions are 16-bit encodings that the front end expands to their
# 32-bit equivalents, so they reuse the base-ISA evaluators.
#
# Their operands are constrained: many forms reach only x8-x15 (the compressed
# register encoding), and immediate ranges are narrower than the 32-bit forms.
#
# The encoders return 16-bit values. The test framework packs them into 32-bit
# words according to PC alignment.

# C extension ALU operations (register-register, using x8-x15)
# encoder: lambda rd', rs2' -> 16-bit instruction (rd' and rs2' must be 8-15)
C_ALU_REG: dict[str, tuple[Callable, Callable]] = {
    "c.sub": (lambda rd, rs2: enc_c_sub(rd, rs2), sub),
    "c.xor": (lambda rd, rs2: enc_c_xor(rd, rs2), xor),
    "c.or": (lambda rd, rs2: enc_c_or(rd, rs2), or_rv),
    "c.and": (lambda rd, rs2: enc_c_and(rd, rs2), and_rv),
}

# C extension ALU operations (full register set)
C_ALU_FULL: dict[str, tuple[Callable, Callable]] = {
    "c.mv": (lambda rd, rs2: enc_c_mv(rd, rs2), add),  # add rd, x0, rs2
    "c.add": (lambda rd, rs2: enc_c_add(rd, rs2), add),  # add rd, rd, rs2
}

# C extension immediate ALU operations (limited register set x8-x15)
C_ALU_IMM_LIMITED: dict[str, tuple[Callable, Callable]] = {
    "c.srli": (lambda rd, shamt: enc_c_srli(rd, shamt), srl),
    "c.srai": (lambda rd, shamt: enc_c_srai(rd, shamt), sra),
    "c.andi": (lambda rd, imm: enc_c_andi(rd, imm), and_rv),
}

# C extension immediate ALU operations (full register set)
C_ALU_IMM_FULL: dict[str, tuple[Callable, Callable]] = {
    "c.addi": (lambda rd, imm: enc_c_addi(rd, imm), add),
    "c.li": (lambda rd, imm: enc_c_li(rd, imm), add),  # addi rd, x0, imm
    "c.slli": (lambda rd, shamt: enc_c_slli(rd, shamt), sll),
}

# C extension load/store operations (limited register set x8-x15)
C_LOADS_LIMITED: dict[str, tuple[Callable, Callable]] = {
    "c.lw": (lambda rd, rs1, uimm: enc_c_lw(rd, rs1, uimm), lw),
}

C_STORES_LIMITED: dict[str, Callable] = {
    "c.sw": lambda rs1, rs2, uimm: enc_c_sw(rs1, rs2, uimm),
}

# C extension stack-relative load/store operations (full register set)
C_LOADS_STACK: dict[str, tuple[Callable, Callable]] = {
    "c.lwsp": (lambda rd, uimm: enc_c_lwsp(rd, uimm), lw),
}

C_STORES_STACK: dict[str, Callable] = {
    "c.swsp": lambda rs2, uimm: enc_c_swsp(rs2, uimm),
}

# C extension branch operations (limited register set x8-x15). Encoder only: the
# test checks taken/not-taken rather than a register result.
C_BRANCHES: dict[str, Callable] = {
    "c.beqz": lambda rs1, offset: enc_c_beqz(rs1, offset),
    "c.bnez": lambda rs1, offset: enc_c_bnez(rs1, offset),
}

# C extension jump operations
C_JUMPS: dict[str, Callable] = {
    "c.j": lambda offset: enc_c_j(offset),
    "c.jr": lambda rs1: enc_c_jr(rs1),
    "c.jalr": lambda rs1: enc_c_jalr(rs1),
}

# =============================================================================
# F and D extensions (floating-point instructions)
# =============================================================================
#
# The F extension adds 32 floating-point registers (f0-f31) and single-precision
# (32-bit) IEEE 754 operations. The D extension adds the double-precision forms,
# which appear in the same tables with a .d suffix.
#
# FP instruction categories:
#   - FP_ARITH_2OP: two-operand arithmetic (rd, rs1, rs2)
#   - FP_ARITH_1OP: single-operand arithmetic (rd, rs1), such as fsqrt
#   - FP_FMA: fused multiply-add (rd, rs1, rs2, rs3)
#   - FP_SGNJ: sign injection (rd, rs1, rs2)
#   - FP_MINMAX: min/max (rd, rs1, rs2)
#   - FP_CMP: comparison (rd, rs1, rs2), result in an integer register
#   - FP_CVT_F2I: FP to int conversion (rd=int, rs1=fp)
#   - FP_CVT_I2F: int to FP conversion (rd=fp, rs1=int)
#   - FP_CVT_F2F: FP to FP conversion (rd=fp, rs1=fp)
#   - FP_MV_F2I: move FP bits to int (rd=int, rs1=fp)
#   - FP_MV_I2F: move int bits to FP (rd=fp, rs1=int)
#   - FP_CLASS: classify an FP value (rd=int, rs1=fp)
#   - FP_LOADS: load from memory into an FP register (rd=fp, rs1=int, imm)
#   - FP_STORES: store an FP register to memory (rs2=fp, rs1=int, imm)
#
# Entries are (encoder, evaluator):
#   encoder: lambda rd, rs1, rs2 -> 32-bit instruction
#   evaluator: lambda rs1_bits, rs2_bits -> result_bits

# FP arithmetic operations (two FP operands -> FP result)
FP_ARITH_2OP: dict[str, tuple[Callable, Callable]] = {
    "fadd.s": (
        lambda rd, rs1, rs2: enc_fadd_s(rd, rs1, rs2),
        lambda a, b: box32(fadd_s(unbox32(a), unbox32(b))),
    ),
    "fsub.s": (
        lambda rd, rs1, rs2: enc_fsub_s(rd, rs1, rs2),
        lambda a, b: box32(fsub_s(unbox32(a), unbox32(b))),
    ),
    "fmul.s": (
        lambda rd, rs1, rs2: enc_fmul_s(rd, rs1, rs2),
        lambda a, b: box32(fmul_s(unbox32(a), unbox32(b))),
    ),
    "fdiv.s": (
        lambda rd, rs1, rs2: enc_fdiv_s(rd, rs1, rs2),
        lambda a, b: box32(fdiv_s(unbox32(a), unbox32(b))),
    ),
    "fadd.d": (lambda rd, rs1, rs2: enc_fadd_d(rd, rs1, rs2), fadd_d),
    "fsub.d": (lambda rd, rs1, rs2: enc_fsub_d(rd, rs1, rs2), fsub_d),
    "fmul.d": (lambda rd, rs1, rs2: enc_fmul_d(rd, rs1, rs2), fmul_d),
    "fdiv.d": (lambda rd, rs1, rs2: enc_fdiv_d(rd, rs1, rs2), fdiv_d),
}

# FP single-operand arithmetic (one FP operand -> FP result)
FP_ARITH_1OP: dict[str, tuple[Callable, Callable]] = {
    "fsqrt.s": (
        lambda rd, rs1: enc_fsqrt_s(rd, rs1),
        lambda a: box32(fsqrt_s(unbox32(a))),
    ),
    "fsqrt.d": (lambda rd, rs1: enc_fsqrt_d(rd, rs1), fsqrt_d),
}

# FP fused multiply-add (three FP operands -> FP result)
#   encoder: lambda rd, rs1, rs2, rs3 -> 32-bit instruction
#   evaluator: lambda rs1_bits, rs2_bits, rs3_bits -> result_bits
FP_FMA: dict[str, tuple[Callable, Callable]] = {
    "fmadd.s": (
        lambda rd, rs1, rs2, rs3: enc_fmadd_s(rd, rs1, rs2, rs3),
        lambda a, b, c: box32(fmadd_s(unbox32(a), unbox32(b), unbox32(c))),
    ),
    "fmsub.s": (
        lambda rd, rs1, rs2, rs3: enc_fmsub_s(rd, rs1, rs2, rs3),
        lambda a, b, c: box32(fmsub_s(unbox32(a), unbox32(b), unbox32(c))),
    ),
    "fnmadd.s": (
        lambda rd, rs1, rs2, rs3: enc_fnmadd_s(rd, rs1, rs2, rs3),
        lambda a, b, c: box32(fnmadd_s(unbox32(a), unbox32(b), unbox32(c))),
    ),
    "fnmsub.s": (
        lambda rd, rs1, rs2, rs3: enc_fnmsub_s(rd, rs1, rs2, rs3),
        lambda a, b, c: box32(fnmsub_s(unbox32(a), unbox32(b), unbox32(c))),
    ),
    "fmadd.d": (lambda rd, rs1, rs2, rs3: enc_fmadd_d(rd, rs1, rs2, rs3), fmadd_d),
    "fmsub.d": (lambda rd, rs1, rs2, rs3: enc_fmsub_d(rd, rs1, rs2, rs3), fmsub_d),
    "fnmadd.d": (
        lambda rd, rs1, rs2, rs3: enc_fnmadd_d(rd, rs1, rs2, rs3),
        fnmadd_d,
    ),
    "fnmsub.d": (
        lambda rd, rs1, rs2, rs3: enc_fnmsub_d(rd, rs1, rs2, rs3),
        fnmsub_d,
    ),
}

# FP sign injection (two FP operands -> FP result)
FP_SGNJ: dict[str, tuple[Callable, Callable]] = {
    "fsgnj.s": (
        lambda rd, rs1, rs2: enc_fsgnj_s(rd, rs1, rs2),
        lambda a, b: box32(fsgnj_s(unbox32(a), unbox32(b))),
    ),
    "fsgnjn.s": (
        lambda rd, rs1, rs2: enc_fsgnjn_s(rd, rs1, rs2),
        lambda a, b: box32(fsgnjn_s(unbox32(a), unbox32(b))),
    ),
    "fsgnjx.s": (
        lambda rd, rs1, rs2: enc_fsgnjx_s(rd, rs1, rs2),
        lambda a, b: box32(fsgnjx_s(unbox32(a), unbox32(b))),
    ),
    "fsgnj.d": (lambda rd, rs1, rs2: enc_fsgnj_d(rd, rs1, rs2), fsgnj_d),
    "fsgnjn.d": (lambda rd, rs1, rs2: enc_fsgnjn_d(rd, rs1, rs2), fsgnjn_d),
    "fsgnjx.d": (lambda rd, rs1, rs2: enc_fsgnjx_d(rd, rs1, rs2), fsgnjx_d),
}

# FP min/max (two FP operands -> FP result)
FP_MINMAX: dict[str, tuple[Callable, Callable]] = {
    "fmin.s": (
        lambda rd, rs1, rs2: enc_fmin_s(rd, rs1, rs2),
        lambda a, b: box32(fmin_s(unbox32(a), unbox32(b))),
    ),
    "fmax.s": (
        lambda rd, rs1, rs2: enc_fmax_s(rd, rs1, rs2),
        lambda a, b: box32(fmax_s(unbox32(a), unbox32(b))),
    ),
    "fmin.d": (lambda rd, rs1, rs2: enc_fmin_d(rd, rs1, rs2), fmin_d),
    "fmax.d": (lambda rd, rs1, rs2: enc_fmax_d(rd, rs1, rs2), fmax_d),
}

# FP comparison: two FP operands, integer result of 0 or 1 written to an integer
# register.
FP_CMP: dict[str, tuple[Callable, Callable]] = {
    "feq.s": (
        lambda rd, rs1, rs2: enc_feq_s(rd, rs1, rs2),
        lambda a, b: feq_s(unbox32(a), unbox32(b)),
    ),
    "flt.s": (
        lambda rd, rs1, rs2: enc_flt_s(rd, rs1, rs2),
        lambda a, b: flt_s(unbox32(a), unbox32(b)),
    ),
    "fle.s": (
        lambda rd, rs1, rs2: enc_fle_s(rd, rs1, rs2),
        lambda a, b: fle_s(unbox32(a), unbox32(b)),
    ),
    "feq.d": (lambda rd, rs1, rs2: enc_feq_d(rd, rs1, rs2), feq_d),
    "flt.d": (lambda rd, rs1, rs2: enc_flt_d(rd, rs1, rs2), flt_d),
    "fle.d": (lambda rd, rs1, rs2: enc_fle_d(rd, rs1, rs2), fle_d),
}

# FP to integer conversion: FP operand, result written to an integer register.
FP_CVT_F2I: dict[str, tuple[Callable, Callable]] = {
    "fcvt.w.s": (lambda rd, rs1: enc_fcvt_w_s(rd, rs1), lambda a: fcvt_w_s(unbox32(a))),
    "fcvt.wu.s": (
        lambda rd, rs1: enc_fcvt_wu_s(rd, rs1),
        lambda a: fcvt_wu_s(unbox32(a)),
    ),
    "fcvt.w.d": (lambda rd, rs1: enc_fcvt_w_d(rd, rs1), fcvt_w_d),
    "fcvt.wu.d": (lambda rd, rs1: enc_fcvt_wu_d(rd, rs1), fcvt_wu_d),
}

# Integer to FP conversion: source is an integer register, result an FP register.
FP_CVT_I2F: dict[str, tuple[Callable, Callable]] = {
    "fcvt.s.w": (
        lambda rd, rs1: enc_fcvt_s_w(rd, rs1),
        lambda a: box32(fcvt_s_w(a)),
    ),
    "fcvt.s.wu": (
        lambda rd, rs1: enc_fcvt_s_wu(rd, rs1),
        lambda a: box32(fcvt_s_wu(a)),
    ),
    "fcvt.d.w": (lambda rd, rs1: enc_fcvt_d_w(rd, rs1), fcvt_d_w),
    "fcvt.d.wu": (lambda rd, rs1: enc_fcvt_d_wu(rd, rs1), fcvt_d_wu),
}

# FP to FP conversion (single <-> double)
FP_CVT_F2F: dict[str, tuple[Callable, Callable]] = {
    "fcvt.s.d": (
        lambda rd, rs1: enc_fcvt_s_d(rd, rs1),
        lambda a: box32(fcvt_s_d(a)),
    ),
    "fcvt.d.s": (
        lambda rd, rs1: enc_fcvt_d_s(rd, rs1),
        lambda a: fcvt_d_s(unbox32(a)),
    ),
}

# FP to integer move: copies bits without conversion into an integer register.
FP_MV_F2I: dict[str, tuple[Callable, Callable]] = {
    "fmv.x.w": (lambda rd, rs1: enc_fmv_x_w(rd, rs1), lambda a: fmv_x_w(unbox32(a))),
}

# Integer to FP move: copies bits without conversion from an integer register into
# an FP register.
FP_MV_I2F: dict[str, tuple[Callable, Callable]] = {
    "fmv.w.x": (lambda rd, rs1: enc_fmv_w_x(rd, rs1), lambda a: box32(fmv_w_x(a))),
}

# FP classify: FP operand, integer bitmask result written to an integer register.
FP_CLASS: dict[str, tuple[Callable, Callable]] = {
    "fclass.s": (lambda rd, rs1: enc_fclass_s(rd, rs1), lambda a: fclass_s(unbox32(a))),
    "fclass.d": (lambda rd, rs1: enc_fclass_d(rd, rs1), fclass_d),
}

# FP load (memory -> FP register)
#   encoder: lambda rd, rs1, imm -> 32-bit instruction
#   evaluator: lambda memory, address -> loaded bits (lw for flw, fld for fld)
FP_LOADS: dict[str, tuple[Callable, Callable]] = {
    "flw": (lambda rd, rs1, imm: enc_flw(rd, rs1, imm), lambda m, a: box32(lw(m, a))),
    "fld": (lambda rd, rs1, imm: enc_fld(rd, rs1, imm), fld),
}

# FP store (FP register -> memory). Encoder only: a store writes no register.
#   encoder: lambda rs2, rs1, imm -> 32-bit instruction
FP_STORES: dict[str, Callable] = {
    "fsw": lambda rs2, rs1, imm: enc_fsw(rs2, rs1, imm),
    "fsd": lambda rs2, rs1, imm: enc_fsd(rs2, rs1, imm),
}
