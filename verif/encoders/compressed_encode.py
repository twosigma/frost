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

"""RISC-V Compressed (C extension) instruction encoders.

Compressed Instruction Encoding
===============================

This module implements encoders for RV32C compressed (16-bit) instructions.
Compressed instructions are recognized by bits [1:0] != 2'b11.

The C extension defines three quadrants based on bits [1:0]:
    - Quadrant 0 (00): Stack-relative loads/stores, wide immediates
    - Quadrant 1 (01): Control flow, arithmetic, immediates
    - Quadrant 2 (10): Register ops, stack-pointer-relative ops

Register Mapping:
    Compressed instructions use 3-bit register fields that map to x8-x15:
    - rd' = {2'b01, 3-bit-field} (i.e., add 8 to the 3-bit value)
    - This covers s0-s1 (x8-x9) and a0-a5 (x10-x15)

Example Usage:
    >>> # Encode C.ADDI x10, 5
    >>> instr = enc_c_addi(rd=10, nzimm=5)
    >>> hex(instr)
    '0x0515'  # 16-bit compressed instruction

Note:
    All encoders return 16-bit values. The test framework is responsible
    for packing these into 32-bit words based on PC alignment.
"""

from dataclasses import dataclass


@dataclass
class CompressedEncoder:
    """Base class for compressed instruction encoding."""

    @staticmethod
    def _pack_bits(*fields: tuple[int, int, int]) -> int:
        """Pack bit fields into 16-bit instruction word.

        Args:
            fields: Variable number of tuples, each containing:
                - value: The value to insert
                - position: Bit position (LSB) where field starts
                - mask: Bit mask for the field width

        Returns:
            16-bit packed instruction word
        """
        result = 0
        for value, position, mask in fields:
            result |= (value & mask) << position
        return result


def compress_reg(reg: int) -> int:
    """Convert full register index (8-15) to compressed 3-bit field.

    Args:
        reg: Register index (must be 8-15 for compressed encoding)

    Returns:
        3-bit compressed register field

    Raises:
        AssertionError: If register is not in range 8-15
    """
    assert 8 <= reg <= 15, f"Compressed register must be x8-x15, got x{reg}"
    return reg - 8


def is_compressible_reg(reg: int) -> bool:
    """Check if register can be used in compressed instructions.

    Args:
        reg: Register index (0-31)

    Returns:
        True if register is x8-x15 (compressible)
    """
    return 8 <= reg <= 15


# =============================================================================
# Quadrant 0 (bits [1:0] = 00)
# =============================================================================


def enc_c_addi4spn(rd_prime: int, nzuimm: int) -> int:
    """Encode C.ADDI4SPN: addi rd', sp, nzuimm.

    Adds a zero-extended non-zero immediate, scaled by 4, to the stack pointer,
    and writes the result to rd'. Used to generate pointers to stack-allocated
    variables.

    Args:
        rd_prime: Destination register (x8-x15, will be compressed)
        nzuimm: Non-zero unsigned immediate, must be multiple of 4, range [4, 1020]

    Returns:
        16-bit encoded instruction
    """
    assert 8 <= rd_prime <= 15, f"rd' must be x8-x15, got x{rd_prime}"
    assert nzuimm != 0 and nzuimm % 4 == 0, "nzuimm must be non-zero multiple of 4"
    assert 4 <= nzuimm <= 1020, f"nzuimm out of range: {nzuimm}"

    # Immediate encoding: nzuimm[5:4|9:6|2|3]
    # Bits [12:5] = nzuimm[5:4] | nzuimm[9:6] | nzuimm[2] | nzuimm[3]
    imm = nzuimm
    return CompressedEncoder._pack_bits(
        ((imm >> 4) & 0x3, 11, 0x3),  # nzuimm[5:4] -> bits [12:11]
        ((imm >> 6) & 0xF, 7, 0xF),  # nzuimm[9:6] -> bits [10:7]
        ((imm >> 2) & 0x1, 6, 0x1),  # nzuimm[2] -> bit [6]
        ((imm >> 3) & 0x1, 5, 0x1),  # nzuimm[3] -> bit [5]
        (compress_reg(rd_prime), 2, 0x7),  # rd' -> bits [4:2]
        (0b00, 0, 0x3),  # opcode quadrant 0
    )


def enc_c_lw(rd_prime: int, rs1_prime: int, uimm: int) -> int:
    """Encode C.LW: lw rd', offset(rs1').

    Loads a 32-bit value from memory into rd'.

    Args:
        rd_prime: Destination register (x8-x15)
        rs1_prime: Base address register (x8-x15)
        uimm: Unsigned offset, must be multiple of 4, range [0, 124]

    Returns:
        16-bit encoded instruction
    """
    assert 8 <= rd_prime <= 15 and 8 <= rs1_prime <= 15
    assert uimm % 4 == 0 and 0 <= uimm <= 124, "uimm must be 0-124, multiple of 4"

    # uimm[5:3|2|6] encoding
    return CompressedEncoder._pack_bits(
        (0b010, 13, 0x7),  # funct3
        ((uimm >> 6) & 0x1, 5, 0x1),  # uimm[6] -> bit [5]
        ((uimm >> 3) & 0x7, 10, 0x7),  # uimm[5:3] -> bits [12:10]
        (compress_reg(rs1_prime), 7, 0x7),  # rs1' -> bits [9:7]
        ((uimm >> 2) & 0x1, 6, 0x1),  # uimm[2] -> bit [6]
        (compress_reg(rd_prime), 2, 0x7),  # rd' -> bits [4:2]
        (0b00, 0, 0x3),  # opcode quadrant 0
    )


def enc_c_sw(rs1_prime: int, rs2_prime: int, uimm: int) -> int:
    """Encode C.SW: sw rs2', offset(rs1').

    Stores a 32-bit value from rs2' to memory.

    Args:
        rs1_prime: Base address register (x8-x15)
        rs2_prime: Source register (x8-x15)
        uimm: Unsigned offset, must be multiple of 4, range [0, 124]

    Returns:
        16-bit encoded instruction
    """
    assert 8 <= rs1_prime <= 15 and 8 <= rs2_prime <= 15
    assert uimm % 4 == 0 and 0 <= uimm <= 124

    # uimm[5:3|2|6] encoding (same as C.LW)
    return CompressedEncoder._pack_bits(
        (0b110, 13, 0x7),  # funct3
        ((uimm >> 6) & 0x1, 5, 0x1),  # uimm[6] -> bit [5]
        ((uimm >> 3) & 0x7, 10, 0x7),  # uimm[5:3] -> bits [12:10]
        (compress_reg(rs1_prime), 7, 0x7),  # rs1' -> bits [9:7]
        ((uimm >> 2) & 0x1, 6, 0x1),  # uimm[2] -> bit [6]
        (compress_reg(rs2_prime), 2, 0x7),  # rs2' -> bits [4:2]
        (0b00, 0, 0x3),  # opcode quadrant 0
    )


def enc_c_flw(rd_prime: int, rs1_prime: int, uimm: int) -> int:
    """Encode C.FLW: flw rd', offset(rs1').

    Loads a 32-bit floating-point value from memory into FP register rd'.

    Args:
        rd_prime: Destination FP register (f8-f15, encoded as 8-15)
        rs1_prime: Base address integer register (x8-x15)
        uimm: Unsigned offset, must be multiple of 4, range [0, 124]

    Returns:
        16-bit encoded instruction
    """
    assert 8 <= rd_prime <= 15 and 8 <= rs1_prime <= 15
    assert uimm % 4 == 0 and 0 <= uimm <= 124, "uimm must be 0-124, multiple of 4"

    # uimm[5:3|2|6] encoding (same as C.LW)
    return CompressedEncoder._pack_bits(
        (0b011, 13, 0x7),  # funct3 for C.FLW
        ((uimm >> 6) & 0x1, 5, 0x1),  # uimm[6] -> bit [5]
        ((uimm >> 3) & 0x7, 10, 0x7),  # uimm[5:3] -> bits [12:10]
        (compress_reg(rs1_prime), 7, 0x7),  # rs1' -> bits [9:7]
        ((uimm >> 2) & 0x1, 6, 0x1),  # uimm[2] -> bit [6]
        (compress_reg(rd_prime), 2, 0x7),  # rd' -> bits [4:2]
        (0b00, 0, 0x3),  # opcode quadrant 0
    )


def enc_c_fsw(rs1_prime: int, rs2_prime: int, uimm: int) -> int:
    """Encode C.FSW: fsw rs2', offset(rs1').

    Stores a 32-bit floating-point value from FP register rs2' to memory.

    Args:
        rs1_prime: Base address integer register (x8-x15)
        rs2_prime: Source FP register (f8-f15, encoded as 8-15)
        uimm: Unsigned offset, must be multiple of 4, range [0, 124]

    Returns:
        16-bit encoded instruction
    """
    assert 8 <= rs1_prime <= 15 and 8 <= rs2_prime <= 15
    assert uimm % 4 == 0 and 0 <= uimm <= 124

    # uimm[5:3|2|6] encoding (same as C.SW)
    return CompressedEncoder._pack_bits(
        (0b111, 13, 0x7),  # funct3 for C.FSW
        ((uimm >> 6) & 0x1, 5, 0x1),  # uimm[6] -> bit [5]
        ((uimm >> 3) & 0x7, 10, 0x7),  # uimm[5:3] -> bits [12:10]
        (compress_reg(rs1_prime), 7, 0x7),  # rs1' -> bits [9:7]
        ((uimm >> 2) & 0x1, 6, 0x1),  # uimm[2] -> bit [6]
        (compress_reg(rs2_prime), 2, 0x7),  # rs2' -> bits [4:2]
        (0b00, 0, 0x3),  # opcode quadrant 0
    )


# =============================================================================
# Quadrant 1 (bits [1:0] = 01)
# =============================================================================


def enc_c_nop() -> int:
    """Encode C.NOP: no operation.

    Returns:
        16-bit encoded instruction (0x0001)
    """
    return 0x0001  # C.NOP is C.ADDI x0, 0


def enc_c_addi(rd: int, nzimm: int) -> int:
    """Encode C.ADDI: addi rd, rd, nzimm.

    Adds sign-extended 6-bit immediate to rd.

    Args:
        rd: Destination/source register (x1-x31, x0 gives C.NOP)
        nzimm: Non-zero signed immediate, range [-32, 31]

    Returns:
        16-bit encoded instruction
    """
    assert 0 <= rd <= 31
    assert -32 <= nzimm <= 31

    # Sign-extend handling: use 6-bit two's complement
    imm6 = nzimm & 0x3F

    return CompressedEncoder._pack_bits(
        (0b000, 13, 0x7),  # funct3
        ((imm6 >> 5) & 0x1, 12, 0x1),  # nzimm[5] -> bit [12]
        (rd, 7, 0x1F),  # rd -> bits [11:7]
        (imm6 & 0x1F, 2, 0x1F),  # nzimm[4:0] -> bits [6:2]
        (0b01, 0, 0x3),  # opcode quadrant 1
    )


def enc_c_jal(imm: int) -> int:
    """Encode C.JAL: jal ra, offset (RV32 only).

    Jump and link with ra as implicit destination.

    Args:
        imm: Signed offset, must be even, range [-2048, 2046]

    Returns:
        16-bit encoded instruction
    """
    assert imm % 2 == 0, "Jump offset must be even"
    assert -2048 <= imm <= 2046, f"Jump offset out of range: {imm}"

    # imm[11|4|9:8|10|6|7|3:1|5] encoding
    imm12 = imm & 0xFFF

    return CompressedEncoder._pack_bits(
        (0b001, 13, 0x7),  # funct3
        ((imm12 >> 11) & 0x1, 12, 0x1),  # imm[11] -> bit [12]
        ((imm12 >> 4) & 0x1, 11, 0x1),  # imm[4] -> bit [11]
        ((imm12 >> 8) & 0x3, 9, 0x3),  # imm[9:8] -> bits [10:9]
        ((imm12 >> 10) & 0x1, 8, 0x1),  # imm[10] -> bit [8]
        ((imm12 >> 6) & 0x1, 7, 0x1),  # imm[6] -> bit [7]
        ((imm12 >> 7) & 0x1, 6, 0x1),  # imm[7] -> bit [6]
        ((imm12 >> 1) & 0x7, 3, 0x7),  # imm[3:1] -> bits [5:3]
        ((imm12 >> 5) & 0x1, 2, 0x1),  # imm[5] -> bit [2]
        (0b01, 0, 0x3),  # opcode quadrant 1
    )


def enc_c_li(rd: int, imm: int) -> int:
    """Encode C.LI: addi rd, x0, imm.

    Load immediate into rd.

    Args:
        rd: Destination register (x1-x31)
        imm: Signed immediate, range [-32, 31]

    Returns:
        16-bit encoded instruction
    """
    assert 1 <= rd <= 31, "rd must be x1-x31 for C.LI"
    assert -32 <= imm <= 31

    imm6 = imm & 0x3F

    return CompressedEncoder._pack_bits(
        (0b010, 13, 0x7),  # funct3
        ((imm6 >> 5) & 0x1, 12, 0x1),  # imm[5] -> bit [12]
        (rd, 7, 0x1F),  # rd -> bits [11:7]
        (imm6 & 0x1F, 2, 0x1F),  # imm[4:0] -> bits [6:2]
        (0b01, 0, 0x3),  # opcode quadrant 1
    )


def enc_c_lui(rd: int, nzimm: int) -> int:
    """Encode C.LUI: lui rd, nzimm.

    Load upper immediate.

    Args:
        rd: Destination register (x1-x31, except x2)
        nzimm: Non-zero immediate for bits [17:12], range [-32, 31] (sign-extended)

    Returns:
        16-bit encoded instruction
    """
    assert 1 <= rd <= 31 and rd != 2, "rd must be x1-x31 except x2"
    assert nzimm != 0, "nzimm must be non-zero for C.LUI"
    assert -32 <= nzimm <= 31

    imm6 = nzimm & 0x3F

    return CompressedEncoder._pack_bits(
        (0b011, 13, 0x7),  # funct3
        ((imm6 >> 5) & 0x1, 12, 0x1),  # nzimm[5] -> bit [12] (sign bit)
        (rd, 7, 0x1F),  # rd -> bits [11:7]
        (imm6 & 0x1F, 2, 0x1F),  # nzimm[4:0] -> bits [6:2]
        (0b01, 0, 0x3),  # opcode quadrant 1
    )


def enc_c_addi16sp(nzimm: int) -> int:
    """Encode C.ADDI16SP: addi sp, sp, nzimm*16.

    Add scaled immediate to stack pointer. Used for stack frame setup/teardown.

    Args:
        nzimm: Non-zero immediate, scaled by 16, range [-512, 496]

    Returns:
        16-bit encoded instruction
    """
    assert nzimm != 0 and nzimm % 16 == 0, "nzimm must be non-zero multiple of 16"
    assert -512 <= nzimm <= 496, f"nzimm out of range: {nzimm}"

    # nzimm[9|4|6|8:7|5] encoding
    imm = nzimm & 0x3FF

    return CompressedEncoder._pack_bits(
        (0b011, 13, 0x7),  # funct3
        ((imm >> 9) & 0x1, 12, 0x1),  # nzimm[9] -> bit [12] (sign)
        (2, 7, 0x1F),  # rd=x2 (sp) -> bits [11:7]
        ((imm >> 4) & 0x1, 6, 0x1),  # nzimm[4] -> bit [6]
        ((imm >> 6) & 0x1, 5, 0x1),  # nzimm[6] -> bit [5]
        ((imm >> 7) & 0x3, 3, 0x3),  # nzimm[8:7] -> bits [4:3]
        ((imm >> 5) & 0x1, 2, 0x1),  # nzimm[5] -> bit [2]
        (0b01, 0, 0x3),  # opcode quadrant 1
    )


def enc_c_srli(rd_prime: int, shamt: int) -> int:
    """Encode C.SRLI: srli rd', rd', shamt.

    Logical right shift by immediate.

    Args:
        rd_prime: Destination/source register (x8-x15)
        shamt: Shift amount (1-31 for RV32)

    Returns:
        16-bit encoded instruction
    """
    assert 8 <= rd_prime <= 15
    assert 1 <= shamt <= 31, "shamt must be 1-31 for RV32"

    return CompressedEncoder._pack_bits(
        (0b100, 13, 0x7),  # funct3
        (0, 12, 0x1),  # shamt[5]=0 for RV32
        (0b00, 10, 0x3),  # funct2 for SRLI
        (compress_reg(rd_prime), 7, 0x7),  # rd'/rs1' -> bits [9:7]
        (shamt & 0x1F, 2, 0x1F),  # shamt[4:0] -> bits [6:2]
        (0b01, 0, 0x3),  # opcode quadrant 1
    )


def enc_c_srai(rd_prime: int, shamt: int) -> int:
    """Encode C.SRAI: srai rd', rd', shamt.

    Arithmetic right shift by immediate.

    Args:
        rd_prime: Destination/source register (x8-x15)
        shamt: Shift amount (1-31 for RV32)

    Returns:
        16-bit encoded instruction
    """
    assert 8 <= rd_prime <= 15
    assert 1 <= shamt <= 31

    return CompressedEncoder._pack_bits(
        (0b100, 13, 0x7),  # funct3
        (0, 12, 0x1),  # shamt[5]=0 for RV32
        (0b01, 10, 0x3),  # funct2 for SRAI
        (compress_reg(rd_prime), 7, 0x7),  # rd'/rs1' -> bits [9:7]
        (shamt & 0x1F, 2, 0x1F),  # shamt[4:0] -> bits [6:2]
        (0b01, 0, 0x3),  # opcode quadrant 1
    )


def enc_c_andi(rd_prime: int, imm: int) -> int:
    """Encode C.ANDI: andi rd', rd', imm.

    AND with sign-extended 6-bit immediate.

    Args:
        rd_prime: Destination/source register (x8-x15)
        imm: Signed immediate, range [-32, 31]

    Returns:
        16-bit encoded instruction
    """
    assert 8 <= rd_prime <= 15
    assert -32 <= imm <= 31

    imm6 = imm & 0x3F

    return CompressedEncoder._pack_bits(
        (0b100, 13, 0x7),  # funct3
        ((imm6 >> 5) & 0x1, 12, 0x1),  # imm[5] -> bit [12]
        (0b10, 10, 0x3),  # funct2 for ANDI
        (compress_reg(rd_prime), 7, 0x7),  # rd'/rs1' -> bits [9:7]
        (imm6 & 0x1F, 2, 0x1F),  # imm[4:0] -> bits [6:2]
        (0b01, 0, 0x3),  # opcode quadrant 1
    )


def enc_c_sub(rd_prime: int, rs2_prime: int) -> int:
    """Encode C.SUB: sub rd', rd', rs2'."""
    assert 8 <= rd_prime <= 15 and 8 <= rs2_prime <= 15

    return CompressedEncoder._pack_bits(
        (0b100, 13, 0x7),  # funct3
        (0, 12, 0x1),  # bit [12] = 0
        (0b11, 10, 0x3),  # funct2
        (compress_reg(rd_prime), 7, 0x7),  # rd'/rs1'
        (0b00, 5, 0x3),  # funct2 for SUB
        (compress_reg(rs2_prime), 2, 0x7),  # rs2'
        (0b01, 0, 0x3),  # opcode quadrant 1
    )


def enc_c_xor(rd_prime: int, rs2_prime: int) -> int:
    """Encode C.XOR: xor rd', rd', rs2'."""
    assert 8 <= rd_prime <= 15 and 8 <= rs2_prime <= 15

    return CompressedEncoder._pack_bits(
        (0b100, 13, 0x7),
        (0, 12, 0x1),
        (0b11, 10, 0x3),
        (compress_reg(rd_prime), 7, 0x7),
        (0b01, 5, 0x3),  # funct2 for XOR
        (compress_reg(rs2_prime), 2, 0x7),
        (0b01, 0, 0x3),
    )


def enc_c_or(rd_prime: int, rs2_prime: int) -> int:
    """Encode C.OR: or rd', rd', rs2'."""
    assert 8 <= rd_prime <= 15 and 8 <= rs2_prime <= 15

    return CompressedEncoder._pack_bits(
        (0b100, 13, 0x7),
        (0, 12, 0x1),
        (0b11, 10, 0x3),
        (compress_reg(rd_prime), 7, 0x7),
        (0b10, 5, 0x3),  # funct2 for OR
        (compress_reg(rs2_prime), 2, 0x7),
        (0b01, 0, 0x3),
    )


def enc_c_and(rd_prime: int, rs2_prime: int) -> int:
    """Encode C.AND: and rd', rd', rs2'."""
    assert 8 <= rd_prime <= 15 and 8 <= rs2_prime <= 15

    return CompressedEncoder._pack_bits(
        (0b100, 13, 0x7),
        (0, 12, 0x1),
        (0b11, 10, 0x3),
        (compress_reg(rd_prime), 7, 0x7),
        (0b11, 5, 0x3),  # funct2 for AND
        (compress_reg(rs2_prime), 2, 0x7),
        (0b01, 0, 0x3),
    )


def enc_c_j(imm: int) -> int:
    """Encode C.J: jal x0, offset.

    Unconditional jump (no link).

    Args:
        imm: Signed offset, must be even, range [-2048, 2046]

    Returns:
        16-bit encoded instruction
    """
    assert imm % 2 == 0
    assert -2048 <= imm <= 2046

    # Same encoding as C.JAL but with funct3=101
    imm12 = imm & 0xFFF

    return CompressedEncoder._pack_bits(
        (0b101, 13, 0x7),  # funct3 for C.J
        ((imm12 >> 11) & 0x1, 12, 0x1),
        ((imm12 >> 4) & 0x1, 11, 0x1),
        ((imm12 >> 8) & 0x3, 9, 0x3),
        ((imm12 >> 10) & 0x1, 8, 0x1),
        ((imm12 >> 6) & 0x1, 7, 0x1),
        ((imm12 >> 7) & 0x1, 6, 0x1),
        ((imm12 >> 1) & 0x7, 3, 0x7),
        ((imm12 >> 5) & 0x1, 2, 0x1),
        (0b01, 0, 0x3),
    )


def enc_c_beqz(rs1_prime: int, imm: int) -> int:
    """Encode C.BEQZ: beq rs1', x0, offset.

    Branch if rs1' equals zero.

    Args:
        rs1_prime: Source register (x8-x15)
        imm: Signed offset, must be even, range [-256, 254]

    Returns:
        16-bit encoded instruction
    """
    assert 8 <= rs1_prime <= 15
    assert imm % 2 == 0
    assert -256 <= imm <= 254

    # imm[8|4:3|7:6|2:1|5] encoding
    imm9 = imm & 0x1FF

    return CompressedEncoder._pack_bits(
        (0b110, 13, 0x7),  # funct3
        ((imm9 >> 8) & 0x1, 12, 0x1),  # imm[8] -> bit [12]
        ((imm9 >> 3) & 0x3, 10, 0x3),  # imm[4:3] -> bits [11:10]
        (compress_reg(rs1_prime), 7, 0x7),  # rs1' -> bits [9:7]
        ((imm9 >> 6) & 0x3, 5, 0x3),  # imm[7:6] -> bits [6:5]
        ((imm9 >> 1) & 0x3, 3, 0x3),  # imm[2:1] -> bits [4:3]
        ((imm9 >> 5) & 0x1, 2, 0x1),  # imm[5] -> bit [2]
        (0b01, 0, 0x3),
    )


def enc_c_bnez(rs1_prime: int, imm: int) -> int:
    """Encode C.BNEZ: bne rs1', x0, offset.

    Branch if rs1' not equals zero.

    Args:
        rs1_prime: Source register (x8-x15)
        imm: Signed offset, must be even, range [-256, 254]

    Returns:
        16-bit encoded instruction
    """
    assert 8 <= rs1_prime <= 15
    assert imm % 2 == 0
    assert -256 <= imm <= 254

    imm9 = imm & 0x1FF

    return CompressedEncoder._pack_bits(
        (0b111, 13, 0x7),  # funct3 for BNEZ
        ((imm9 >> 8) & 0x1, 12, 0x1),
        ((imm9 >> 3) & 0x3, 10, 0x3),
        (compress_reg(rs1_prime), 7, 0x7),
        ((imm9 >> 6) & 0x3, 5, 0x3),
        ((imm9 >> 1) & 0x3, 3, 0x3),
        ((imm9 >> 5) & 0x1, 2, 0x1),
        (0b01, 0, 0x3),
    )


# =============================================================================
# Quadrant 2 (bits [1:0] = 10)
# =============================================================================


def enc_c_slli(rd: int, shamt: int) -> int:
    """Encode C.SLLI: slli rd, rd, shamt.

    Logical left shift by immediate.

    Args:
        rd: Destination/source register (x1-x31)
        shamt: Shift amount (1-31 for RV32)

    Returns:
        16-bit encoded instruction
    """
    assert 1 <= rd <= 31
    assert 1 <= shamt <= 31

    return CompressedEncoder._pack_bits(
        (0b000, 13, 0x7),  # funct3
        (0, 12, 0x1),  # shamt[5]=0 for RV32
        (rd, 7, 0x1F),  # rd -> bits [11:7]
        (shamt & 0x1F, 2, 0x1F),  # shamt[4:0] -> bits [6:2]
        (0b10, 0, 0x3),  # opcode quadrant 2
    )


def enc_c_lwsp(rd: int, uimm: int) -> int:
    """Encode C.LWSP: lw rd, offset(sp).

    Load word from stack-pointer-relative address.

    Args:
        rd: Destination register (x1-x31)
        uimm: Unsigned offset, must be multiple of 4, range [0, 252]

    Returns:
        16-bit encoded instruction
    """
    assert 1 <= rd <= 31
    assert uimm % 4 == 0 and 0 <= uimm <= 252

    # uimm[5|4:2|7:6] encoding
    return CompressedEncoder._pack_bits(
        (0b010, 13, 0x7),  # funct3
        ((uimm >> 5) & 0x1, 12, 0x1),  # uimm[5] -> bit [12]
        (rd, 7, 0x1F),  # rd -> bits [11:7]
        ((uimm >> 2) & 0x7, 4, 0x7),  # uimm[4:2] -> bits [6:4]
        ((uimm >> 6) & 0x3, 2, 0x3),  # uimm[7:6] -> bits [3:2]
        (0b10, 0, 0x3),  # opcode quadrant 2
    )


def enc_c_jr(rs1: int) -> int:
    """Encode C.JR: jalr x0, rs1, 0.

    Jump register (no link).

    Args:
        rs1: Jump target register (x1-x31)

    Returns:
        16-bit encoded instruction
    """
    assert 1 <= rs1 <= 31

    return CompressedEncoder._pack_bits(
        (0b100, 13, 0x7),  # funct3
        (0, 12, 0x1),  # bit [12] = 0 for JR/MV
        (rs1, 7, 0x1F),  # rs1 -> bits [11:7]
        (0, 2, 0x1F),  # rs2 = 0 for JR
        (0b10, 0, 0x3),  # opcode quadrant 2
    )


def enc_c_mv(rd: int, rs2: int) -> int:
    """Encode C.MV: add rd, x0, rs2.

    Move register.

    Args:
        rd: Destination register (x1-x31)
        rs2: Source register (x1-x31)

    Returns:
        16-bit encoded instruction
    """
    assert 1 <= rd <= 31 and 1 <= rs2 <= 31

    return CompressedEncoder._pack_bits(
        (0b100, 13, 0x7),  # funct3
        (0, 12, 0x1),  # bit [12] = 0 for JR/MV
        (rd, 7, 0x1F),  # rd -> bits [11:7]
        (rs2, 2, 0x1F),  # rs2 -> bits [6:2]
        (0b10, 0, 0x3),  # opcode quadrant 2
    )


def enc_c_ebreak() -> int:
    """Encode C.EBREAK: ebreak.

    Returns:
        16-bit encoded instruction (0x9002)
    """
    return 0x9002


def enc_c_jalr(rs1: int) -> int:
    """Encode C.JALR: jalr ra, rs1, 0.

    Jump and link register.

    Args:
        rs1: Jump target register (x1-x31)

    Returns:
        16-bit encoded instruction
    """
    assert 1 <= rs1 <= 31

    return CompressedEncoder._pack_bits(
        (0b100, 13, 0x7),  # funct3
        (1, 12, 0x1),  # bit [12] = 1 for JALR/ADD
        (rs1, 7, 0x1F),  # rs1 -> bits [11:7]
        (0, 2, 0x1F),  # rs2 = 0 for JALR
        (0b10, 0, 0x3),  # opcode quadrant 2
    )


def enc_c_add(rd: int, rs2: int) -> int:
    """Encode C.ADD: add rd, rd, rs2.

    Add registers.

    Args:
        rd: Destination/first source register (x1-x31)
        rs2: Second source register (x1-x31)

    Returns:
        16-bit encoded instruction
    """
    assert 1 <= rd <= 31 and 1 <= rs2 <= 31

    return CompressedEncoder._pack_bits(
        (0b100, 13, 0x7),  # funct3
        (1, 12, 0x1),  # bit [12] = 1 for JALR/ADD
        (rd, 7, 0x1F),  # rd -> bits [11:7]
        (rs2, 2, 0x1F),  # rs2 -> bits [6:2]
        (0b10, 0, 0x3),  # opcode quadrant 2
    )


def enc_c_swsp(rs2: int, uimm: int) -> int:
    """Encode C.SWSP: sw rs2, offset(sp).

    Store word to stack-pointer-relative address.

    Args:
        rs2: Source register (x0-x31)
        uimm: Unsigned offset, must be multiple of 4, range [0, 252]

    Returns:
        16-bit encoded instruction
    """
    assert 0 <= rs2 <= 31
    assert uimm % 4 == 0 and 0 <= uimm <= 252

    # uimm[5:2|7:6] encoding
    return CompressedEncoder._pack_bits(
        (0b110, 13, 0x7),  # funct3
        ((uimm >> 2) & 0xF, 9, 0xF),  # uimm[5:2] -> bits [12:9]
        ((uimm >> 6) & 0x3, 7, 0x3),  # uimm[7:6] -> bits [8:7]
        (rs2, 2, 0x1F),  # rs2 -> bits [6:2]
        (0b10, 0, 0x3),  # opcode quadrant 2
    )


def enc_c_flwsp(rd: int, uimm: int) -> int:
    """Encode C.FLWSP: flw rd, offset(sp).

    Load floating-point word from stack-pointer-relative address.

    Args:
        rd: Destination FP register (f0-f31)
        uimm: Unsigned offset, must be multiple of 4, range [0, 252]

    Returns:
        16-bit encoded instruction
    """
    assert 0 <= rd <= 31
    assert uimm % 4 == 0 and 0 <= uimm <= 252

    # uimm[5|4:2|7:6] encoding (same as C.LWSP)
    return CompressedEncoder._pack_bits(
        (0b011, 13, 0x7),  # funct3 for C.FLWSP
        ((uimm >> 5) & 0x1, 12, 0x1),  # uimm[5] -> bit [12]
        (rd, 7, 0x1F),  # rd -> bits [11:7]
        ((uimm >> 2) & 0x7, 4, 0x7),  # uimm[4:2] -> bits [6:4]
        ((uimm >> 6) & 0x3, 2, 0x3),  # uimm[7:6] -> bits [3:2]
        (0b10, 0, 0x3),  # opcode quadrant 2
    )


def enc_c_fswsp(rs2: int, uimm: int) -> int:
    """Encode C.FSWSP: fsw rs2, offset(sp).

    Store floating-point word to stack-pointer-relative address.

    Args:
        rs2: Source FP register (f0-f31)
        uimm: Unsigned offset, must be multiple of 4, range [0, 252]

    Returns:
        16-bit encoded instruction
    """
    assert 0 <= rs2 <= 31
    assert uimm % 4 == 0 and 0 <= uimm <= 252

    # uimm[5:2|7:6] encoding (same as C.SWSP)
    return CompressedEncoder._pack_bits(
        (0b111, 13, 0x7),  # funct3 for C.FSWSP
        ((uimm >> 2) & 0xF, 9, 0xF),  # uimm[5:2] -> bits [12:9]
        ((uimm >> 6) & 0x3, 7, 0x3),  # uimm[7:6] -> bits [8:7]
        (rs2, 2, 0x1F),  # rs2 -> bits [6:2]
        (0b10, 0, 0x3),  # opcode quadrant 2
    )
