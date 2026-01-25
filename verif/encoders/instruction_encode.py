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

"""RISC-V instruction format encoding with improved abstractions.

Instruction Formats
===================

This module implements encoders for all RISC-V instruction formats. Each
encoder takes instruction parameters (registers, immediates, offsets) and
packs them into a 32-bit binary instruction according to RISC-V ISA spec.

RISC-V Instruction Formats:
    R-type: register-register operations (ADD, SUB, AND, MUL, etc.)
    I-type: immediate operations and loads (ADDI, LW, JALR)
    S-type: store operations (SW, SH, SB)
    B-type: conditional branches (BEQ, BNE, BLT, etc.)
    J-type: unconditional jumps (JAL)

Format Details:
    All formats are 32 bits with fields at specific bit positions:
    - opcode[6:0]: Determines instruction category
    - rd[11:7]: Destination register (except S-type and B-type)
    - funct3[14:12]: Sub-operation specifier
    - rs1[19:15]: First source register
    - rs2[24:20]: Second source register (R-type, S-type, B-type)
    - funct7[31:25]: Additional operation bits (R-type)
    - imm: Immediate value (different layouts per format)

Usage Example:
    >>> # Encode ADD x5, x3, x4 (R-type: add rd, rs1, rs2)
    >>> instruction = RType.encode(
    ...     funct7_code=0x00,           # ADD function
    ...     source_register_2=4,        # x4
    ...     source_register_1=3,        # x3
    ...     funct3_code=0x0,            # ADD function
    ...     destination_register=5,     # x5
    ...     opcode=0x33                 # ALU register-register
    ... )
    >>> hex(instruction)
    '0x004181b3'
"""

from dataclasses import dataclass
from enum import IntEnum
from typing import ClassVar


class Opcode(IntEnum):
    """RISC-V opcodes."""

    LOAD = 0x03
    MISC_MEM = 0x0F  # FENCE, FENCE.I (Zifencei)
    STORE = 0x23
    ALU_IMM = 0x13
    ALU_REG = 0x33
    LUI = 0x37  # Load Upper Immediate
    AUIPC = 0x17  # Add Upper Immediate to PC
    AMO = 0x2F  # A extension (atomics)
    BRANCH = 0x63
    JALR = 0x67
    JAL = 0x6F
    SYSTEM = 0x73  # CSR instructions (Zicsr)
    # F extension (single-precision floating-point)
    LOAD_FP = 0x07  # FLW
    STORE_FP = 0x27  # FSW
    FMADD = 0x43  # FMADD.S
    FMSUB = 0x47  # FMSUB.S
    FNMSUB = 0x4B  # FNMSUB.S
    FNMADD = 0x4F  # FNMADD.S
    OP_FP = 0x53  # FADD.S, FSUB.S, FMUL.S, etc.


class Funct3(IntEnum):
    """3-bit function codes."""

    # ALU operations
    ADD_SUB = 0x0
    SLL = 0x1
    SLT = 0x2
    SLTU = 0x3
    XOR = 0x4
    SRL_SRA = 0x5
    OR = 0x6
    AND = 0x7

    # Load/Store widths
    BYTE = 0x0
    HALFWORD = 0x1
    WORD = 0x2
    DOUBLEWORD = 0x3
    BYTE_U = 0x4
    HALFWORD_U = 0x5

    # Branch conditions
    BEQ = 0x0
    BNE = 0x1
    BLT = 0x4
    BGE = 0x5
    BLTU = 0x6
    BGEU = 0x7

    # Memory ordering (Zifencei)
    FENCE = 0x0
    FENCE_I = 0x1

    # CSR instructions (Zicsr)
    CSRRW = 0x1  # Read/Write
    CSRRS = 0x2  # Read/Set bits
    CSRRC = 0x3  # Read/Clear bits
    CSRRWI = 0x5  # Read/Write Immediate
    CSRRSI = 0x6  # Read/Set bits Immediate
    CSRRCI = 0x7  # Read/Clear bits Immediate


class Funct7(IntEnum):
    """7-bit function codes."""

    DEFAULT = 0x00
    ALTERNATE = 0x20  # Used for SUB, SRA
    MULDIV = 0x01


class FPFunct7(IntEnum):
    """7-bit function codes for F extension operations."""

    FADD_S = 0x00
    FADD_D = 0x01
    FSUB_S = 0x04
    FSUB_D = 0x05
    FMUL_S = 0x08
    FMUL_D = 0x09
    FDIV_S = 0x0C
    FDIV_D = 0x0D
    FSQRT_S = 0x2C  # rs2=0
    FSQRT_D = 0x2D  # rs2=0
    FSGNJ_S = 0x10  # funct3 selects FSGNJ/FSGNJN/FSGNJX
    FSGNJ_D = 0x11  # funct3 selects FSGNJ/FSGNJN/FSGNJX
    FMIN_MAX_S = 0x14  # funct3 selects FMIN/FMAX
    FMIN_MAX_D = 0x15  # funct3 selects FMIN/FMAX
    FCVT_W_S = 0x60  # FP to int, rs2=0 for W, rs2=1 for WU
    FCVT_W_D = 0x61  # FP to int, rs2=0 for W, rs2=1 for WU
    FCVT_S_W = 0x68  # Int to FP, rs2=0 for W, rs2=1 for WU
    FCVT_D_W = 0x69  # Int to FP, rs2=0 for W, rs2=1 for WU
    FCVT_S_D = 0x20  # FP to FP, rs2 selects source (D=1)
    FCVT_D_S = 0x21  # FP to FP, rs2 selects source (S=0)
    FMV_X_W = 0x70  # Move FP to int (rs2=0, funct3=0)
    FCLASS_S = 0x70  # Classify (rs2=0, funct3=1)
    FCLASS_D = 0x71  # Classify (rs2=0, funct3=1)
    FMV_W_X = 0x78  # Move int to FP (rs2=0, funct3=0)
    FCMP_S = 0x50  # Compare, funct3 selects FEQ/FLT/FLE
    FCMP_D = 0x51  # Compare, funct3 selects FEQ/FLT/FLE


class Funct5(IntEnum):
    """5-bit function codes for AMO operations (A extension)."""

    LR = 0x02  # Load-Reserved
    SC = 0x03  # Store-Conditional
    AMOSWAP = 0x01
    AMOADD = 0x00
    AMOXOR = 0x04
    AMOAND = 0x0C
    AMOOR = 0x08
    AMOMIN = 0x10
    AMOMAX = 0x14
    AMOMINU = 0x18
    AMOMAXU = 0x1C


@dataclass
class InstructionEncoder:
    """Base class for instruction encoding."""

    @staticmethod
    def _pack_bits(*fields: tuple[int, int, int]) -> int:
        """Pack bit fields into instruction word.

        Takes multiple (value, position, mask) tuples and packs them into
        a single 32-bit instruction word by masking and shifting each field
        into its correct bit position.

        Args:
            fields: Variable number of tuples, each containing:
                - value: The value to insert
                - position: Bit position (LSB) where field starts
                - mask: Bit mask for the field width

        Returns:
            32-bit packed instruction word

        Example:
            >>> # Pack rd=5 at bits[11:7] and opcode=0x33 at bits[6:0]
            >>> InstructionEncoder._pack_bits(
            ...     (5, 7, 0x1F),      # rd: 5-bit value at position 7
            ...     (0x33, 0, 0x7F)    # opcode: 7-bit value at position 0
            ... )
            0x000002b3  # Binary: ...0000 0010 1011 0011
                        #         rd=5 ^^^^^ opcode=0x33 ^^^^^^^
        """
        result = 0
        for value, position, mask in fields:
            result |= (value & mask) << position
        return result


class RType(InstructionEncoder):
    """R-type instruction format encoder.

    Format: funct7[31:25] | rs2[24:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]
    Used for: register-register operations (ADD, SUB, AND, OR, XOR, shifts, etc.)
    """

    @staticmethod
    def encode(
        funct7_code: int,
        source_register_2: int,
        source_register_1: int,
        funct3_code: int,
        destination_register: int,
        opcode: int,
    ) -> int:
        """Encode R-type instruction into 32-bit word."""
        return InstructionEncoder._pack_bits(
            (funct7_code, 25, 0x7F),
            (source_register_2, 20, 0x1F),
            (source_register_1, 15, 0x1F),
            (funct3_code, 12, 0x7),
            (destination_register, 7, 0x1F),
            (opcode, 0, 0x7F),
        )


class IType(InstructionEncoder):
    """I-type instruction format encoder.

    Format: imm[31:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]
    Used for: immediate operations (ADDI, ANDI, etc.), loads (LW, LH, LB), JALR
    """

    @staticmethod
    def encode(
        immediate_12bit: int,
        source_register_1: int,
        funct3_code: int,
        destination_register: int,
        opcode: int,
    ) -> int:
        """Encode I-type instruction into 32-bit word."""
        return InstructionEncoder._pack_bits(
            (immediate_12bit, 20, 0xFFF),
            (source_register_1, 15, 0x1F),
            (funct3_code, 12, 0x7),
            (destination_register, 7, 0x1F),
            (opcode, 0, 0x7F),
        )


class SType(InstructionEncoder):
    """S-type instruction format encoder.

    Format: imm[11:5][31:25] | rs2[24:20] | rs1[19:15] | funct3[14:12] | imm[4:0][11:7] | opcode[6:0]
    Used for: store operations (SW, SH, SB)
    Note: Immediate is split between two fields
    """

    @staticmethod
    def encode(
        immediate_12bit: int,
        source_register_2: int,
        source_register_1: int,
        funct3_code: int,
        opcode: int,
    ) -> int:
        """Encode S-type instruction into 32-bit word."""
        immediate_value = immediate_12bit & 0xFFF
        immediate_upper_bits = (immediate_value >> 5) & 0x7F  # Bits [11:5]
        immediate_lower_bits = immediate_value & 0x1F  # Bits [4:0]

        return InstructionEncoder._pack_bits(
            (immediate_upper_bits, 25, 0x7F),
            (source_register_2, 20, 0x1F),
            (source_register_1, 15, 0x1F),
            (funct3_code, 12, 0x7),
            (immediate_lower_bits, 7, 0x1F),
            (opcode, 0, 0x7F),
        )


class BType(InstructionEncoder):
    """B-type instruction format encoder.

    Format: imm[12|10:5][31:25] | rs2[24:20] | rs1[19:15] | funct3[14:12] | imm[4:1|11][11:7] | opcode[6:0]
    Used for: conditional branch instructions (BEQ, BNE, BLT, BGE, BLTU, BGEU)
    Note: 13-bit immediate is scrambled across multiple fields, bit 0 is implicit (always 0)
    """

    MINIMUM_BRANCH_OFFSET: ClassVar[int] = -4096  # -2^12
    MAXIMUM_BRANCH_OFFSET: ClassVar[int] = 4094  # 2^12 - 2

    @staticmethod
    def encode(
        branch_offset: int,
        source_register_2: int,
        source_register_1: int,
        funct3_code: int,
        opcode: int,
    ) -> int:
        """Encode B-type instruction into 32-bit word."""
        from utils.validation import ValidationError

        if branch_offset % 2 != 0:
            raise ValidationError(
                "Branch offset must be even (bit 0 is implicit)",
                branch_offset=branch_offset,
            )
        if not (
            BType.MINIMUM_BRANCH_OFFSET <= branch_offset <= BType.MAXIMUM_BRANCH_OFFSET
        ):
            raise ValidationError(
                "Branch offset out of range",
                branch_offset=branch_offset,
                min_offset=BType.MINIMUM_BRANCH_OFFSET,
                max_offset=BType.MAXIMUM_BRANCH_OFFSET,
            )

        immediate_13bit = branch_offset & 0x1FFF
        return InstructionEncoder._pack_bits(
            ((immediate_13bit >> 12) & 1, 31, 0x1),  # imm[12] - sign bit
            ((immediate_13bit >> 5) & 0x3F, 25, 0x3F),  # imm[10:5]
            (source_register_2, 20, 0x1F),
            (source_register_1, 15, 0x1F),
            (funct3_code, 12, 0x7),
            ((immediate_13bit >> 1) & 0xF, 8, 0xF),  # imm[4:1]
            ((immediate_13bit >> 11) & 1, 7, 0x1),  # imm[11]
            (opcode, 0, 0x7F),
        )


class JType(InstructionEncoder):
    """J-type instruction format encoder.

    Format: imm[20|10:1|11|19:12][31:12] | rd[11:7] | opcode[6:0]
    Used for: unconditional jump (JAL instruction)
    Note: 21-bit immediate is scrambled across fields, bit 0 is implicit (always 0)
    """

    MINIMUM_JUMP_OFFSET: ClassVar[int] = -1048576  # -2^20
    MAXIMUM_JUMP_OFFSET: ClassVar[int] = 1048574  # 2^20 - 2

    @staticmethod
    def encode(jump_offset: int, destination_register: int, opcode: int) -> int:
        """Encode J-type instruction into 32-bit word."""
        from utils.validation import ValidationError

        if jump_offset % 2 != 0:
            raise ValidationError(
                "Jump offset must be even (bit 0 is implicit)",
                jump_offset=jump_offset,
            )
        if not (JType.MINIMUM_JUMP_OFFSET <= jump_offset <= JType.MAXIMUM_JUMP_OFFSET):
            raise ValidationError(
                "Jump offset out of range",
                jump_offset=jump_offset,
                min_offset=JType.MINIMUM_JUMP_OFFSET,
                max_offset=JType.MAXIMUM_JUMP_OFFSET,
            )

        immediate_21bit = jump_offset & 0x1FFFFF
        return InstructionEncoder._pack_bits(
            ((immediate_21bit >> 20) & 1, 31, 0x1),  # imm[20] - sign bit
            ((immediate_21bit >> 1) & 0x3FF, 21, 0x3FF),  # imm[10:1]
            ((immediate_21bit >> 11) & 1, 20, 0x1),  # imm[11]
            ((immediate_21bit >> 12) & 0xFF, 12, 0xFF),  # imm[19:12]
            (destination_register, 7, 0x1F),
            (opcode, 0, 0x7F),
        )


class AMOType(InstructionEncoder):
    """AMO-type instruction format encoder (A extension - atomics).

    Format: funct5[31:27] | aq[26] | rl[25] | rs2[24:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]
    Used for: atomic memory operations (LR.W, SC.W, AMO*.W)

    Note: aq (acquire) and rl (release) bits control memory ordering.
    For single-core implementations, these can be ignored (set to 0).
    """

    @staticmethod
    def encode(
        funct5_code: int,
        source_register_2: int,
        source_register_1: int,
        destination_register: int,
        aq: int = 0,
        rl: int = 0,
    ) -> int:
        """Encode AMO-type instruction into 32-bit word.

        Args:
            funct5_code: 5-bit function code identifying the AMO operation
            source_register_2: rs2 register (value for AMO, 0 for LR.W)
            source_register_1: rs1 register (memory address)
            destination_register: rd register (receives old memory value)
            aq: Acquire bit (memory ordering, default 0)
            rl: Release bit (memory ordering, default 0)

        Returns:
            32-bit encoded instruction
        """
        return InstructionEncoder._pack_bits(
            (funct5_code, 27, 0x1F),  # funct5[31:27]
            (aq, 26, 0x1),  # aq[26]
            (rl, 25, 0x1),  # rl[25]
            (source_register_2, 20, 0x1F),  # rs2[24:20]
            (source_register_1, 15, 0x1F),  # rs1[19:15]
            (Funct3.WORD, 12, 0x7),  # funct3[14:12] = 010 for .W
            (destination_register, 7, 0x1F),  # rd[11:7]
            (Opcode.AMO, 0, 0x7F),  # opcode[6:0]
        )


class R4Type(InstructionEncoder):
    """R4-type instruction format encoder (F extension - FMA operations).

    Format: rs3[31:27] | fmt[26:25] | rs2[24:20] | rs1[19:15] | rm[14:12] | rd[11:7] | opcode[6:0]
    Used for: fused multiply-add operations (FMADD.S, FMSUB.S, FNMADD.S, FNMSUB.S)

    Note: fmt=00 for single-precision (S), rm is rounding mode (typically 111=dynamic)
    """

    @staticmethod
    def encode(
        source_register_3: int,
        source_register_2: int,
        source_register_1: int,
        rounding_mode: int,
        destination_register: int,
        opcode: int,
        fmt: int = 0,
    ) -> int:
        """Encode R4-type instruction into 32-bit word.

        Args:
            source_register_3: rs3 register (addend for FMA)
            source_register_2: rs2 register (multiplier)
            source_register_1: rs1 register (multiplicand)
            rounding_mode: Rounding mode (0-4, or 7 for dynamic)
            destination_register: rd register
            opcode: Instruction opcode
            fmt: Format (0=S single-precision)

        Returns:
            32-bit encoded instruction
        """
        return InstructionEncoder._pack_bits(
            (source_register_3, 27, 0x1F),  # rs3[31:27]
            (fmt, 25, 0x3),  # fmt[26:25]
            (source_register_2, 20, 0x1F),  # rs2[24:20]
            (source_register_1, 15, 0x1F),  # rs1[19:15]
            (rounding_mode, 12, 0x7),  # rm[14:12]
            (destination_register, 7, 0x1F),  # rd[11:7]
            (opcode, 0, 0x7F),  # opcode[6:0]
        )


class FPType(InstructionEncoder):
    """F extension instruction format encoder.

    Uses R-type format with funct7 encoding the operation.
    Format: funct7[31:25] | rs2[24:20] | rs1[19:15] | rm[14:12] | rd[11:7] | opcode[6:0]
    """

    @staticmethod
    def encode(
        funct7_code: int,
        source_register_2: int,
        source_register_1: int,
        rounding_mode: int,
        destination_register: int,
    ) -> int:
        """Encode FP R-type instruction into 32-bit word."""
        return InstructionEncoder._pack_bits(
            (funct7_code, 25, 0x7F),
            (source_register_2, 20, 0x1F),
            (source_register_1, 15, 0x1F),
            (rounding_mode, 12, 0x7),
            (destination_register, 7, 0x1F),
            (Opcode.OP_FP, 0, 0x7F),
        )


class UType(InstructionEncoder):
    """U-type instruction format encoder.

    Format: imm[31:12][31:12] | rd[11:7] | opcode[6:0]
    Used for: LUI (Load Upper Immediate), AUIPC (Add Upper Immediate to PC)
    The 20-bit immediate is placed in the upper 20 bits of the destination register.
    """

    @staticmethod
    def encode(
        immediate_20bit: int,
        destination_register: int,
        opcode: int,
    ) -> int:
        """Encode U-type instruction into 32-bit word.

        Args:
            immediate_20bit: 20-bit immediate value (placed in bits [31:12])
            destination_register: Destination register (rd)
            opcode: Instruction opcode (LUI=0x37, AUIPC=0x17)

        Returns:
            32-bit encoded instruction
        """
        return InstructionEncoder._pack_bits(
            (immediate_20bit, 12, 0xFFFFF),  # imm[31:12]
            (destination_register, 7, 0x1F),  # rd[11:7]
            (opcode, 0, 0x7F),  # opcode[6:0]
        )


# Convenience functions for encoding instructions (maintain API compatibility)
def enc_r(funct7: int, rs2: int, rs1: int, funct3: int, rd: int) -> int:
    """Encode R-type register-register instruction (opcode 0x33 - ALU operations)."""
    return RType.encode(funct7, rs2, rs1, funct3, rd, Opcode.ALU_REG)


def enc_i(immediate: int, rs1: int, funct3: int, rd: int) -> int:
    """Encode I-type ALU immediate instruction (opcode 0x13 - ADDI, ANDI, etc.)."""
    return IType.encode(immediate & 0xFFF, rs1, funct3, rd, Opcode.ALU_IMM)


def enc_i_load(immediate: int, rs1: int, funct3: int, rd: int) -> int:
    """Encode I-type load instruction (opcode 0x03 - LW, LH, LB, etc.)."""
    return IType.encode(immediate & 0xFFF, rs1, funct3, rd, Opcode.LOAD)


def enc_i_jalr(immediate: int, rs1: int, rd: int) -> int:
    """Encode I-type jump-and-link-register instruction (opcode 0x67 - JALR)."""
    return IType.encode(immediate & 0xFFF, rs1, 0x0, rd, Opcode.JALR)


def enc_s(rs2: int, rs1: int, funct3: int, immediate: int) -> int:
    """Encode S-type store instruction (opcode 0x23 - SW, SH, SB)."""
    return SType.encode(immediate, rs2, rs1, funct3, Opcode.STORE)


def enc_b(rs2: int, rs1: int, funct3: int, branch_offset: int) -> int:
    """Encode B-type branch instruction (opcode 0x63 - BEQ, BNE, BLT, etc.)."""
    return BType.encode(branch_offset, rs2, rs1, funct3, Opcode.BRANCH)


def enc_j(rd: int, jump_offset: int) -> int:
    """Encode J-type jump-and-link instruction (opcode 0x6F - JAL)."""
    return JType.encode(jump_offset, rd, Opcode.JAL)


def enc_lui(rd: int, immediate_20bit: int) -> int:
    """Encode LUI (Load Upper Immediate) instruction (opcode 0x37).

    LUI places the 20-bit immediate value into the upper 20 bits of rd,
    filling the lower 12 bits with zeros.

    Args:
        rd: Destination register
        immediate_20bit: 20-bit immediate value (upper 20 bits of result)

    Returns:
        32-bit encoded instruction
    """
    return UType.encode(immediate_20bit & 0xFFFFF, rd, Opcode.LUI)


def enc_auipc(rd: int, immediate_20bit: int) -> int:
    """Encode AUIPC (Add Upper Immediate to PC) instruction (opcode 0x17).

    AUIPC forms a 32-bit offset from the 20-bit immediate (filling low 12 bits
    with zeros), adds it to the PC of the AUIPC instruction, and stores the
    result in rd.

    Args:
        rd: Destination register
        immediate_20bit: 20-bit immediate value

    Returns:
        32-bit encoded instruction
    """
    return UType.encode(immediate_20bit & 0xFFFFF, rd, Opcode.AUIPC)


def enc_fence() -> int:
    """Encode FENCE instruction (opcode 0x0F, funct3 0x0).

    FENCE orders memory operations. In simple implementations without
    out-of-order execution or caches, this is effectively a NOP.

    Format: imm[11:0] | rs1 | funct3 | rd | opcode
    Standard encoding: 0x0ff0000f (pred=0xf, succ=0xf, rs1=0, rd=0)
    """
    # Standard FENCE with pred=0xF (all prior), succ=0xF (all subsequent)
    # imm[11:8]=pred, imm[7:4]=succ, imm[3:0]=0
    return IType.encode(0x0FF, 0, Funct3.FENCE, 0, Opcode.MISC_MEM)


def enc_fence_i() -> int:
    """Encode FENCE.I instruction (opcode 0x0F, funct3 0x1).

    FENCE.I synchronizes instruction and data streams. In implementations
    without instruction cache, this is effectively a NOP.

    Format: imm[11:0] | rs1 | funct3 | rd | opcode
    Standard encoding: 0x0000100f (imm=0, rs1=0, rd=0)
    """
    return IType.encode(0, 0, Funct3.FENCE_I, 0, Opcode.MISC_MEM)


def enc_pause() -> int:
    """Encode PAUSE instruction (Zihintpause extension).

    PAUSE is a hint instruction for spin-wait loops. It is encoded as a
    FENCE with pred=W (0001), succ=0, and all other fields zero.

    In simple implementations, PAUSE is effectively a NOP.

    Encoding: 0x0100000f (imm=0x010, rs1=0, funct3=0, rd=0)
    """
    # imm[11:8]=pred=0001, imm[7:4]=succ=0000, imm[3:0]=0 -> imm=0x010
    return IType.encode(0x010, 0, Funct3.FENCE, 0, Opcode.MISC_MEM)


# Zicsr CSR addresses (Zicntr counters)
class CSRAddress(IntEnum):
    """CSR addresses for Zicntr extension and M-mode CSRs."""

    # Zicntr counters (read-only)
    CYCLE = 0xC00  # Cycle counter (low 32 bits)
    TIME = 0xC01  # Timer (low 32 bits)
    INSTRET = 0xC02  # Instructions retired (low 32 bits)
    CYCLEH = 0xC80  # Cycle counter (high 32 bits)
    TIMEH = 0xC81  # Timer (high 32 bits)
    INSTRETH = 0xC82  # Instructions retired (high 32 bits)

    # Machine-mode CSRs (for RTOS support)
    MSTATUS = 0x300  # Machine status (MIE, MPIE, MPP)
    MISA = 0x301  # ISA description (read-only)
    MIE = 0x304  # Machine interrupt enable
    MTVEC = 0x305  # Machine trap vector base
    MSCRATCH = 0x340  # Machine scratch register
    MEPC = 0x341  # Machine exception program counter
    MCAUSE = 0x342  # Machine trap cause
    MTVAL = 0x343  # Machine trap value
    MIP = 0x344  # Machine interrupt pending (read-only)
    MVENDORID = 0xF11  # Vendor ID (read-only)
    MARCHID = 0xF12  # Architecture ID (read-only)
    MIMPID = 0xF13  # Implementation ID (read-only)
    MHARTID = 0xF14  # Hardware thread ID (read-only)


def enc_csr(csr_address: int, rs1: int, funct3: int, rd: int) -> int:
    """Encode CSR instruction (Zicsr extension).

    CSR instructions use I-type format with CSR address in immediate field.
    Format: csr[31:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]

    Args:
        csr_address: 12-bit CSR address
        rs1: Source register (or zimm for immediate variants)
        funct3: CSR operation (CSRRW=1, CSRRS=2, CSRRC=3, CSRRWI=5, CSRRSI=6, CSRRCI=7)
        rd: Destination register

    Returns:
        32-bit encoded instruction
    """
    return IType.encode(csr_address & 0xFFF, rs1, funct3, rd, Opcode.SYSTEM)


def enc_csrrw(rd: int, csr: int, rs1: int) -> int:
    """Encode CSRRW (CSR Read/Write) instruction."""
    return enc_csr(csr, rs1, Funct3.CSRRW, rd)


def enc_csrrs(rd: int, csr: int, rs1: int) -> int:
    """Encode CSRRS (CSR Read/Set) instruction."""
    return enc_csr(csr, rs1, Funct3.CSRRS, rd)


def enc_csrrc(rd: int, csr: int, rs1: int) -> int:
    """Encode CSRRC (CSR Read/Clear) instruction."""
    return enc_csr(csr, rs1, Funct3.CSRRC, rd)


def enc_csrrwi(rd: int, csr: int, zimm: int) -> int:
    """Encode CSRRWI (CSR Read/Write Immediate) instruction."""
    return enc_csr(csr, zimm & 0x1F, Funct3.CSRRWI, rd)


def enc_csrrsi(rd: int, csr: int, zimm: int) -> int:
    """Encode CSRRSI (CSR Read/Set Immediate) instruction."""
    return enc_csr(csr, zimm & 0x1F, Funct3.CSRRSI, rd)


def enc_csrrci(rd: int, csr: int, zimm: int) -> int:
    """Encode CSRRCI (CSR Read/Clear Immediate) instruction."""
    return enc_csr(csr, zimm & 0x1F, Funct3.CSRRCI, rd)


# A extension (atomics) encoder functions
def enc_lr_w(rd: int, rs1: int, aq: int = 0, rl: int = 0) -> int:
    """Encode LR.W (Load-Reserved Word) instruction.

    Loads a word from memory at rs1 and sets a reservation.
    rd receives the loaded value. rs2 is always 0 for LR.W.
    """
    return AMOType.encode(Funct5.LR, 0, rs1, rd, aq, rl)


def enc_sc_w(rd: int, rs2: int, rs1: int, aq: int = 0, rl: int = 0) -> int:
    """Encode SC.W (Store-Conditional Word) instruction.

    Attempts to store rs2 to memory at rs1 if reservation is valid.
    rd receives 0 on success, non-zero on failure.
    """
    return AMOType.encode(Funct5.SC, rs2, rs1, rd, aq, rl)


def enc_amoswap_w(rd: int, rs2: int, rs1: int, aq: int = 0, rl: int = 0) -> int:
    """Encode AMOSWAP.W (Atomic Swap Word) instruction.

    Atomically swaps memory at rs1 with rs2. rd receives old memory value.
    """
    return AMOType.encode(Funct5.AMOSWAP, rs2, rs1, rd, aq, rl)


def enc_amoadd_w(rd: int, rs2: int, rs1: int, aq: int = 0, rl: int = 0) -> int:
    """Encode AMOADD.W (Atomic Add Word) instruction.

    Atomically adds rs2 to memory at rs1. rd receives old memory value.
    """
    return AMOType.encode(Funct5.AMOADD, rs2, rs1, rd, aq, rl)


def enc_amoxor_w(rd: int, rs2: int, rs1: int, aq: int = 0, rl: int = 0) -> int:
    """Encode AMOXOR.W (Atomic XOR Word) instruction.

    Atomically XORs memory at rs1 with rs2. rd receives old memory value.
    """
    return AMOType.encode(Funct5.AMOXOR, rs2, rs1, rd, aq, rl)


def enc_amoand_w(rd: int, rs2: int, rs1: int, aq: int = 0, rl: int = 0) -> int:
    """Encode AMOAND.W (Atomic AND Word) instruction.

    Atomically ANDs memory at rs1 with rs2. rd receives old memory value.
    """
    return AMOType.encode(Funct5.AMOAND, rs2, rs1, rd, aq, rl)


def enc_amoor_w(rd: int, rs2: int, rs1: int, aq: int = 0, rl: int = 0) -> int:
    """Encode AMOOR.W (Atomic OR Word) instruction.

    Atomically ORs memory at rs1 with rs2. rd receives old memory value.
    """
    return AMOType.encode(Funct5.AMOOR, rs2, rs1, rd, aq, rl)


def enc_amomin_w(rd: int, rs2: int, rs1: int, aq: int = 0, rl: int = 0) -> int:
    """Encode AMOMIN.W (Atomic Minimum Word) instruction.

    Atomically stores minimum of memory at rs1 and rs2 (signed comparison).
    rd receives old memory value.
    """
    return AMOType.encode(Funct5.AMOMIN, rs2, rs1, rd, aq, rl)


def enc_amomax_w(rd: int, rs2: int, rs1: int, aq: int = 0, rl: int = 0) -> int:
    """Encode AMOMAX.W (Atomic Maximum Word) instruction.

    Atomically stores maximum of memory at rs1 and rs2 (signed comparison).
    rd receives old memory value.
    """
    return AMOType.encode(Funct5.AMOMAX, rs2, rs1, rd, aq, rl)


def enc_amominu_w(rd: int, rs2: int, rs1: int, aq: int = 0, rl: int = 0) -> int:
    """Encode AMOMINU.W (Atomic Minimum Unsigned Word) instruction.

    Atomically stores minimum of memory at rs1 and rs2 (unsigned comparison).
    rd receives old memory value.
    """
    return AMOType.encode(Funct5.AMOMINU, rs2, rs1, rd, aq, rl)


def enc_amomaxu_w(rd: int, rs2: int, rs1: int, aq: int = 0, rl: int = 0) -> int:
    """Encode AMOMAXU.W (Atomic Maximum Unsigned Word) instruction.

    Atomically stores maximum of memory at rs1 and rs2 (unsigned comparison).
    rd receives old memory value.
    """
    return AMOType.encode(Funct5.AMOMAXU, rs2, rs1, rd, aq, rl)


# Machine-mode trap instructions
def enc_ecall() -> int:
    """Encode ECALL (Environment Call) instruction.

    Generates a synchronous exception to request a service from the
    execution environment (e.g., OS system call).

    Encoding: 0x00000073
        imm[11:0]=0x000, rs1=0, funct3=0, rd=0, opcode=0x73
    """
    return IType.encode(0x000, 0, 0, 0, Opcode.SYSTEM)


def enc_ebreak() -> int:
    """Encode EBREAK (Environment Breakpoint) instruction.

    Generates a breakpoint exception for debugging.

    Encoding: 0x00100073
        imm[11:0]=0x001, rs1=0, funct3=0, rd=0, opcode=0x73
    """
    return IType.encode(0x001, 0, 0, 0, Opcode.SYSTEM)


def enc_mret() -> int:
    """Encode MRET (Machine Return) instruction.

    Returns from a machine-mode trap handler. Restores PC from mepc,
    restores mstatus.MIE from mstatus.MPIE.

    Encoding: 0x30200073
        funct7=0b0011000, rs2=0b00010, rs1=0, funct3=0, rd=0, opcode=0x73
        This is imm[11:0]=0x302
    """
    return IType.encode(0x302, 0, 0, 0, Opcode.SYSTEM)


def enc_wfi() -> int:
    """Encode WFI (Wait For Interrupt) instruction.

    Stalls the processor until an interrupt is pending.
    Used for low-power idle loops.

    Encoding: 0x10500073
        funct7=0b0001000, rs2=0b00101, rs1=0, funct3=0, rd=0, opcode=0x73
        This is imm[11:0]=0x105
    """
    return IType.encode(0x105, 0, 0, 0, Opcode.SYSTEM)


# ============================================================================
# F/D extensions (single/double-precision floating-point) encoder functions
# ============================================================================


def enc_flw(rd: int, rs1: int, imm: int) -> int:
    """Encode FLW (Load Float Word) instruction.

    Loads a 32-bit value from memory at rs1+imm into FP register rd.
    """
    return IType.encode(imm & 0xFFF, rs1, Funct3.WORD, rd, Opcode.LOAD_FP)


def enc_fsw(rs2: int, rs1: int, imm: int) -> int:
    """Encode FSW (Store Float Word) instruction.

    Stores FP register rs2 to memory at rs1+imm.
    """
    return SType.encode(imm, rs2, rs1, Funct3.WORD, Opcode.STORE_FP)


def enc_fld(rd: int, rs1: int, imm: int) -> int:
    """Encode FLD (Load Float Doubleword) instruction.

    Loads a 64-bit value from memory at rs1+imm into FP register rd.
    """
    return IType.encode(imm & 0xFFF, rs1, Funct3.DOUBLEWORD, rd, Opcode.LOAD_FP)


def enc_fsd(rs2: int, rs1: int, imm: int) -> int:
    """Encode FSD (Store Float Doubleword) instruction.

    Stores FP register rs2 to memory at rs1+imm.
    """
    return SType.encode(imm, rs2, rs1, Funct3.DOUBLEWORD, Opcode.STORE_FP)


def enc_fadd_s(rd: int, rs1: int, rs2: int, rm: int = 7) -> int:
    """Encode FADD.S (Floating-point Add Single) instruction."""
    return FPType.encode(FPFunct7.FADD_S, rs2, rs1, rm, rd)


def enc_fsub_s(rd: int, rs1: int, rs2: int, rm: int = 7) -> int:
    """Encode FSUB.S (Floating-point Subtract Single) instruction."""
    return FPType.encode(FPFunct7.FSUB_S, rs2, rs1, rm, rd)


def enc_fmul_s(rd: int, rs1: int, rs2: int, rm: int = 7) -> int:
    """Encode FMUL.S (Floating-point Multiply Single) instruction."""
    return FPType.encode(FPFunct7.FMUL_S, rs2, rs1, rm, rd)


def enc_fdiv_s(rd: int, rs1: int, rs2: int, rm: int = 7) -> int:
    """Encode FDIV.S (Floating-point Divide Single) instruction."""
    return FPType.encode(FPFunct7.FDIV_S, rs2, rs1, rm, rd)


def enc_fsqrt_s(rd: int, rs1: int, rm: int = 7) -> int:
    """Encode FSQRT.S (Floating-point Square Root Single) instruction."""
    return FPType.encode(FPFunct7.FSQRT_S, 0, rs1, rm, rd)


def enc_fadd_d(rd: int, rs1: int, rs2: int, rm: int = 7) -> int:
    """Encode FADD.D (Floating-point Add Double) instruction."""
    return FPType.encode(FPFunct7.FADD_D, rs2, rs1, rm, rd)


def enc_fsub_d(rd: int, rs1: int, rs2: int, rm: int = 7) -> int:
    """Encode FSUB.D (Floating-point Subtract Double) instruction."""
    return FPType.encode(FPFunct7.FSUB_D, rs2, rs1, rm, rd)


def enc_fmul_d(rd: int, rs1: int, rs2: int, rm: int = 7) -> int:
    """Encode FMUL.D (Floating-point Multiply Double) instruction."""
    return FPType.encode(FPFunct7.FMUL_D, rs2, rs1, rm, rd)


def enc_fdiv_d(rd: int, rs1: int, rs2: int, rm: int = 7) -> int:
    """Encode FDIV.D (Floating-point Divide Double) instruction."""
    return FPType.encode(FPFunct7.FDIV_D, rs2, rs1, rm, rd)


def enc_fsqrt_d(rd: int, rs1: int, rm: int = 7) -> int:
    """Encode FSQRT.D (Floating-point Square Root Double) instruction."""
    return FPType.encode(FPFunct7.FSQRT_D, 0, rs1, rm, rd)


def enc_fmadd_s(rd: int, rs1: int, rs2: int, rs3: int, rm: int = 7) -> int:
    """Encode FMADD.S: rd = rs1 * rs2 + rs3."""
    return R4Type.encode(rs3, rs2, rs1, rm, rd, Opcode.FMADD)


def enc_fmsub_s(rd: int, rs1: int, rs2: int, rs3: int, rm: int = 7) -> int:
    """Encode FMSUB.S: rd = rs1 * rs2 - rs3."""
    return R4Type.encode(rs3, rs2, rs1, rm, rd, Opcode.FMSUB)


def enc_fnmadd_s(rd: int, rs1: int, rs2: int, rs3: int, rm: int = 7) -> int:
    """Encode FNMADD.S: rd = -(rs1 * rs2) - rs3."""
    return R4Type.encode(rs3, rs2, rs1, rm, rd, Opcode.FNMADD)


def enc_fnmsub_s(rd: int, rs1: int, rs2: int, rs3: int, rm: int = 7) -> int:
    """Encode FNMSUB.S: rd = -(rs1 * rs2) + rs3."""
    return R4Type.encode(rs3, rs2, rs1, rm, rd, Opcode.FNMSUB)


def enc_fmadd_d(rd: int, rs1: int, rs2: int, rs3: int, rm: int = 7) -> int:
    """Encode FMADD.D: rd = rs1 * rs2 + rs3."""
    return R4Type.encode(rs3, rs2, rs1, rm, rd, Opcode.FMADD, fmt=1)


def enc_fmsub_d(rd: int, rs1: int, rs2: int, rs3: int, rm: int = 7) -> int:
    """Encode FMSUB.D: rd = rs1 * rs2 - rs3."""
    return R4Type.encode(rs3, rs2, rs1, rm, rd, Opcode.FMSUB, fmt=1)


def enc_fnmadd_d(rd: int, rs1: int, rs2: int, rs3: int, rm: int = 7) -> int:
    """Encode FNMADD.D: rd = -(rs1 * rs2) - rs3."""
    return R4Type.encode(rs3, rs2, rs1, rm, rd, Opcode.FNMADD, fmt=1)


def enc_fnmsub_d(rd: int, rs1: int, rs2: int, rs3: int, rm: int = 7) -> int:
    """Encode FNMSUB.D: rd = -(rs1 * rs2) + rs3."""
    return R4Type.encode(rs3, rs2, rs1, rm, rd, Opcode.FNMSUB, fmt=1)


def enc_fsgnj_s(rd: int, rs1: int, rs2: int) -> int:
    """Encode FSGNJ.S (Sign Inject): rd = |rs1| with sign of rs2."""
    return FPType.encode(FPFunct7.FSGNJ_S, rs2, rs1, 0, rd)


def enc_fsgnjn_s(rd: int, rs1: int, rs2: int) -> int:
    """Encode FSGNJN.S (Sign Inject Negated): rd = |rs1| with negated sign of rs2."""
    return FPType.encode(FPFunct7.FSGNJ_S, rs2, rs1, 1, rd)


def enc_fsgnjx_s(rd: int, rs1: int, rs2: int) -> int:
    """Encode FSGNJX.S (Sign Inject XOR): rd = rs1 with sign XORed with rs2's sign."""
    return FPType.encode(FPFunct7.FSGNJ_S, rs2, rs1, 2, rd)


def enc_fsgnj_d(rd: int, rs1: int, rs2: int) -> int:
    """Encode FSGNJ.D (Sign Inject): rd = |rs1| with sign of rs2."""
    return FPType.encode(FPFunct7.FSGNJ_D, rs2, rs1, 0, rd)


def enc_fsgnjn_d(rd: int, rs1: int, rs2: int) -> int:
    """Encode FSGNJN.D (Sign Inject Negated): rd = |rs1| with negated sign of rs2."""
    return FPType.encode(FPFunct7.FSGNJ_D, rs2, rs1, 1, rd)


def enc_fsgnjx_d(rd: int, rs1: int, rs2: int) -> int:
    """Encode FSGNJX.D (Sign Inject XOR): rd = rs1 with sign XORed with rs2's sign."""
    return FPType.encode(FPFunct7.FSGNJ_D, rs2, rs1, 2, rd)


def enc_fmin_s(rd: int, rs1: int, rs2: int) -> int:
    """Encode FMIN.S (Floating-point Minimum Single) instruction."""
    return FPType.encode(FPFunct7.FMIN_MAX_S, rs2, rs1, 0, rd)


def enc_fmax_s(rd: int, rs1: int, rs2: int) -> int:
    """Encode FMAX.S (Floating-point Maximum Single) instruction."""
    return FPType.encode(FPFunct7.FMIN_MAX_S, rs2, rs1, 1, rd)


def enc_fmin_d(rd: int, rs1: int, rs2: int) -> int:
    """Encode FMIN.D (Floating-point Minimum Double) instruction."""
    return FPType.encode(FPFunct7.FMIN_MAX_D, rs2, rs1, 0, rd)


def enc_fmax_d(rd: int, rs1: int, rs2: int) -> int:
    """Encode FMAX.D (Floating-point Maximum Double) instruction."""
    return FPType.encode(FPFunct7.FMIN_MAX_D, rs2, rs1, 1, rd)


def enc_fcvt_w_s(rd: int, rs1: int, rm: int = 7) -> int:
    """Encode FCVT.W.S (Convert Float to Signed Int) instruction."""
    return FPType.encode(FPFunct7.FCVT_W_S, 0, rs1, rm, rd)


def enc_fcvt_wu_s(rd: int, rs1: int, rm: int = 7) -> int:
    """Encode FCVT.WU.S (Convert Float to Unsigned Int) instruction."""
    return FPType.encode(FPFunct7.FCVT_W_S, 1, rs1, rm, rd)


def enc_fcvt_s_w(rd: int, rs1: int, rm: int = 7) -> int:
    """Encode FCVT.S.W (Convert Signed Int to Float) instruction."""
    return FPType.encode(FPFunct7.FCVT_S_W, 0, rs1, rm, rd)


def enc_fcvt_s_wu(rd: int, rs1: int, rm: int = 7) -> int:
    """Encode FCVT.S.WU (Convert Unsigned Int to Float) instruction."""
    return FPType.encode(FPFunct7.FCVT_S_W, 1, rs1, rm, rd)


def enc_fcvt_w_d(rd: int, rs1: int, rm: int = 7) -> int:
    """Encode FCVT.W.D (Convert Double to Signed Int) instruction."""
    return FPType.encode(FPFunct7.FCVT_W_D, 0, rs1, rm, rd)


def enc_fcvt_wu_d(rd: int, rs1: int, rm: int = 7) -> int:
    """Encode FCVT.WU.D (Convert Double to Unsigned Int) instruction."""
    return FPType.encode(FPFunct7.FCVT_W_D, 1, rs1, rm, rd)


def enc_fcvt_d_w(rd: int, rs1: int, rm: int = 7) -> int:
    """Encode FCVT.D.W (Convert Signed Int to Double) instruction."""
    return FPType.encode(FPFunct7.FCVT_D_W, 0, rs1, rm, rd)


def enc_fcvt_d_wu(rd: int, rs1: int, rm: int = 7) -> int:
    """Encode FCVT.D.WU (Convert Unsigned Int to Double) instruction."""
    return FPType.encode(FPFunct7.FCVT_D_W, 1, rs1, rm, rd)


def enc_fcvt_s_d(rd: int, rs1: int, rm: int = 7) -> int:
    """Encode FCVT.S.D (Convert Double to Single) instruction."""
    return FPType.encode(FPFunct7.FCVT_S_D, 1, rs1, rm, rd)


def enc_fcvt_d_s(rd: int, rs1: int, rm: int = 7) -> int:
    """Encode FCVT.D.S (Convert Single to Double) instruction."""
    return FPType.encode(FPFunct7.FCVT_D_S, 0, rs1, rm, rd)


def enc_fmv_x_w(rd: int, rs1: int) -> int:
    """Encode FMV.X.W (Move Float Bits to Int Register) instruction."""
    return FPType.encode(FPFunct7.FMV_X_W, 0, rs1, 0, rd)


def enc_fmv_w_x(rd: int, rs1: int) -> int:
    """Encode FMV.W.X (Move Int Bits to Float Register) instruction."""
    return FPType.encode(FPFunct7.FMV_W_X, 0, rs1, 0, rd)


def enc_fclass_s(rd: int, rs1: int) -> int:
    """Encode FCLASS.S (Classify Floating-point Value) instruction."""
    return FPType.encode(FPFunct7.FCLASS_S, 0, rs1, 1, rd)


def enc_fclass_d(rd: int, rs1: int) -> int:
    """Encode FCLASS.D (Classify Floating-point Value) instruction."""
    return FPType.encode(FPFunct7.FCLASS_D, 0, rs1, 1, rd)


def enc_feq_s(rd: int, rs1: int, rs2: int) -> int:
    """Encode FEQ.S (Floating-point Equal) instruction. rd = (rs1 == rs2) ? 1 : 0."""
    return FPType.encode(FPFunct7.FCMP_S, rs2, rs1, 2, rd)


def enc_flt_s(rd: int, rs1: int, rs2: int) -> int:
    """Encode FLT.S (Floating-point Less Than) instruction. rd = (rs1 < rs2) ? 1 : 0."""
    return FPType.encode(FPFunct7.FCMP_S, rs2, rs1, 1, rd)


def enc_fle_s(rd: int, rs1: int, rs2: int) -> int:
    """Encode FLE.S (Floating-point Less or Equal) instruction. rd = (rs1 <= rs2) ? 1 : 0."""
    return FPType.encode(FPFunct7.FCMP_S, rs2, rs1, 0, rd)


def enc_feq_d(rd: int, rs1: int, rs2: int) -> int:
    """Encode FEQ.D (Floating-point Equal) instruction. rd = (rs1 == rs2) ? 1 : 0."""
    return FPType.encode(FPFunct7.FCMP_D, rs2, rs1, 2, rd)


def enc_flt_d(rd: int, rs1: int, rs2: int) -> int:
    """Encode FLT.D (Floating-point Less Than) instruction. rd = (rs1 < rs2) ? 1 : 0."""
    return FPType.encode(FPFunct7.FCMP_D, rs2, rs1, 1, rd)


def enc_fle_d(rd: int, rs1: int, rs2: int) -> int:
    """Encode FLE.D (Floating-point Less or Equal) instruction. rd = (rs1 <= rs2) ? 1 : 0."""
    return FPType.encode(FPFunct7.FCMP_D, rs2, rs1, 0, rd)
