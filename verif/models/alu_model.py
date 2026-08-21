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

"""Reference models for Frost ALU and load operations.

Load operations (lw, lh, lhu, lb, lbu) require a MemoryReader protocol that
provides read_byte and read_word methods. This avoids global state and makes
dependencies explicit.
"""

from collections.abc import Callable
from typing import Protocol
from functools import wraps
from config import (
    MASK32,
    MASK64,
    MASK_XLEN,
    XLEN,
    SHIFT_AMOUNT_MASK,
    SHIFT_AMOUNT_MASK_W,
    DIVISION_OVERFLOW_DIVIDEND,
    DIVISION_OVERFLOW_DIVISOR,
    DIVISION_BY_ZERO_QUOTIENT,
)
from utils.riscv_utils import (
    to_signed32,
    to_signed_xlen,
    to_unsigned_xlen,
    sign_extend,
)


class MemoryReader(Protocol):
    """Load-model interface, implemented by ``MemoryModel`` or another reader."""

    def read_byte(self, address: int) -> int:
        """Read a single byte from memory."""
        ...

    def read_word(self, address: int) -> int:
        """Read a 32-bit word from memory."""
        ...


# Decorators for common RISC-V operation patterns
def mask_to_xlen(function: Callable) -> Callable:
    """Mask operation result to the active XLEN for overflow wrapping."""

    @wraps(function)
    def wrapper(*args: int, **kwargs: int) -> int:
        result = function(*args, **kwargs)
        return result & MASK_XLEN  # Keep only the low XLEN bits

    return wrapper


def limit_shift_amount(function: Callable) -> Callable:
    """Limit shift amount to SHIFT_AMOUNT_BITS per the RISC-V specification."""

    @wraps(function)
    def wrapper(value: int, shift_amount: int) -> int:
        return function(value, shift_amount & SHIFT_AMOUNT_MASK)  # bits [5:0]

    return wrapper


# Base integer ALU operations
@mask_to_xlen
def add(operand_a: int, operand_b: int) -> int:
    """Add two 32-bit values (wraps on overflow)."""
    return operand_a + operand_b


@mask_to_xlen
def sub(operand_a: int, operand_b: int) -> int:
    """Subtract operand_b from operand_a (wraps on underflow)."""
    return operand_a - operand_b


def and_rv(operand_a: int, operand_b: int) -> int:
    """Bitwise AND of two values."""
    return operand_a & operand_b


def or_rv(operand_a: int, operand_b: int) -> int:
    """Bitwise OR of two values."""
    return operand_a | operand_b


def xor(operand_a: int, operand_b: int) -> int:
    """Bitwise XOR (exclusive OR) of two values."""
    return operand_a ^ operand_b


@mask_to_xlen
@limit_shift_amount
def sll(value: int, shift_amount: int) -> int:
    """Shift left logical - shifts value left, filling with zeros."""
    return value << shift_amount


@mask_to_xlen
@limit_shift_amount
def srl(value: int, shift_amount: int) -> int:
    """Shift right logical - shifts value right, filling with zeros."""
    return value >> shift_amount


@mask_to_xlen
@limit_shift_amount
def sra(value: int, shift_amount: int) -> int:
    """Shift right arithmetic - shifts right, preserving sign bit."""
    return to_signed_xlen(value) >> shift_amount


def slt(operand_a: int, operand_b: int) -> int:
    """Set if less than (signed comparison) - returns 1 if a < b, else 0."""
    return int(to_signed_xlen(operand_a) < to_signed_xlen(operand_b))


def sltu(operand_a: int, operand_b: int) -> int:
    """Set if less than unsigned - returns 1 if a < b (unsigned), else 0."""
    return int((operand_a & MASK_XLEN) < (operand_b & MASK_XLEN))


# Load operations helper function
def _load_halfword_from_memory(
    memory: MemoryReader, memory_address: int, is_signed: bool
) -> int:
    """Load 16-bit halfword from memory with optional sign extension.

    Args:
        memory: Memory model to read from
        memory_address: Byte address to load from
        is_signed: If True, sign-extend; if False, zero-extend

    Returns:
        XLEN-wide value (sign- or zero-extended halfword; identical at
        XLEN=32, sign bits reach 63 at XLEN=64)
    """
    aligned_address = memory_address & ~0x1  # Align to 2-byte boundary
    # Read two bytes in little-endian order
    halfword_value = memory.read_byte(aligned_address) | (
        memory.read_byte(aligned_address + 1) << 8
    )
    if is_signed:
        return sign_extend(halfword_value, 16) & MASK_XLEN
    return halfword_value & MASK_XLEN


# Load operations (I-type instructions)
# These functions take a MemoryReader to avoid global state.
def lw(memory: MemoryReader, memory_address: int) -> int:
    """Load word - read 32-bit word from memory (LW instruction).

    Args:
        memory: Memory model to read from
        memory_address: Byte address (will be aligned to 4-byte boundary)

    Returns:
        Word value sign-extended to XLEN (identity at XLEN=32; RV64 LW
        sign-extends into rd)
    """
    aligned_word = memory.read_word(memory_address & ~0x3)  # 4-byte aligned
    return sign_extend(aligned_word, 32) & MASK_XLEN


def ld(memory: MemoryReader, memory_address: int) -> int:
    """Load doubleword - read 64-bit value from memory (LD instruction).

    Args:
        memory: Memory model to read from
        memory_address: Byte address (will be aligned to 8-byte boundary)

    Returns:
        64-bit value from memory (little-endian)
    """
    aligned_address = memory_address & ~0x7
    low_word = memory.read_word(aligned_address)
    high_word = memory.read_word(aligned_address + 4)
    return ((high_word << 32) | low_word) & MASK64


def lb(memory: MemoryReader, memory_address: int) -> int:
    """Load byte signed - read byte and sign-extend to 32 bits (LB instruction).

    Args:
        memory: Memory model to read from
        memory_address: Byte address to load from

    Returns:
        Byte value sign-extended to XLEN (identity at XLEN=32)
    """
    return sign_extend(memory.read_byte(memory_address), 8) & MASK_XLEN


def lbu(memory: MemoryReader, memory_address: int) -> int:
    """Load byte unsigned - read byte and zero-extend to 32 bits (LBU instruction).

    Args:
        memory: Memory model to read from
        memory_address: Byte address to load from

    Returns:
        Byte value zero-extended to XLEN
    """
    return memory.read_byte(memory_address) & MASK_XLEN


def lh(memory: MemoryReader, memory_address: int) -> int:
    """Load halfword signed - read 16 bits and sign-extend (LH instruction).

    Args:
        memory: Memory model to read from
        memory_address: Byte address (will be aligned to 2-byte boundary)

    Returns:
        Halfword value sign-extended to XLEN (identity at XLEN=32)
    """
    return _load_halfword_from_memory(memory, memory_address, is_signed=True)


def lhu(memory: MemoryReader, memory_address: int) -> int:
    """Load halfword unsigned - read 16 bits and zero-extend (LHU instruction).

    Args:
        memory: Memory model to read from
        memory_address: Byte address (will be aligned to 2-byte boundary)

    Returns:
        Halfword value zero-extended to XLEN
    """
    return _load_halfword_from_memory(memory, memory_address, is_signed=False)


# M-extension multiply operations (M extension)
@mask_to_xlen
def mul(operand_a: int, operand_b: int) -> int:
    """Multiply - the low XLEN product bits (signedness is irrelevant there)."""
    return operand_a * operand_b


@mask_to_xlen
def mulh(operand_a: int, operand_b: int) -> int:
    """Multiply high (signed × signed) - upper XLEN bits of the 2*XLEN product."""
    product = to_signed_xlen(operand_a) * to_signed_xlen(operand_b)
    return product >> XLEN


@mask_to_xlen
def mulhsu(operand_a: int, operand_b: int) -> int:
    """Multiply high (signed × unsigned) - upper XLEN bits (MULHSU instruction)."""
    product = to_signed_xlen(operand_a) * to_unsigned_xlen(operand_b)
    return product >> XLEN


@mask_to_xlen
def mulhu(operand_a: int, operand_b: int) -> int:
    """Multiply high (unsigned × unsigned) - upper XLEN bits (MULHU instruction)."""
    product = to_unsigned_xlen(operand_a) * to_unsigned_xlen(operand_b)
    return product >> XLEN


# M-extension division/remainder operations (M extension)
# Implements RISC-V specification-compliant edge case handling
class DivisionOperations:
    """Division and remainder operations with RISC-V spec-compliant edge cases.

    RISC-V division edge cases:
    - Division by zero: quotient = -1 (all 1s), remainder = dividend
    - Overflow (most negative / -1): quotient = most negative, remainder = 0
    """

    @classmethod
    def div(cls, dividend: int, divisor: int) -> int:
        """Signed division (DIV instruction) - quotient of dividend / divisor."""
        signed_dividend = to_signed_xlen(dividend)
        signed_divisor = to_signed_xlen(divisor)

        # Edge case: division by zero
        if signed_divisor == 0:
            return DIVISION_BY_ZERO_QUOTIENT

        # Edge case: overflow (most negative number divided by -1)
        if (
            signed_dividend == DIVISION_OVERFLOW_DIVIDEND
            and signed_divisor == DIVISION_OVERFLOW_DIVISOR
        ):
            return DIVISION_OVERFLOW_DIVIDEND & MASK_XLEN  # Most negative number

        return int(signed_dividend / signed_divisor) & MASK_XLEN

    @classmethod
    def divu(cls, dividend: int, divisor: int) -> int:
        """Unsigned division (DIVU instruction) - quotient of dividend / divisor."""
        unsigned_dividend = to_unsigned_xlen(dividend)
        unsigned_divisor = to_unsigned_xlen(divisor)

        # Edge case: division by zero
        if unsigned_divisor == 0:
            return DIVISION_BY_ZERO_QUOTIENT

        return (unsigned_dividend // unsigned_divisor) & MASK_XLEN

    @classmethod
    def rem(cls, dividend: int, divisor: int) -> int:
        """Signed remainder (REM instruction) - remainder of dividend / divisor."""
        signed_dividend = to_signed_xlen(dividend)
        signed_divisor = to_signed_xlen(divisor)

        # Edge case: division by zero - return dividend unchanged
        if signed_divisor == 0:
            return dividend & MASK_XLEN

        # Edge case: overflow case - remainder is 0
        if (
            signed_dividend == DIVISION_OVERFLOW_DIVIDEND
            and signed_divisor == DIVISION_OVERFLOW_DIVISOR
        ):
            return 0

        # Compute quotient truncated toward zero
        quotient = int(signed_dividend / signed_divisor)
        # Remainder follows sign of dividend (RISC-V spec)
        remainder = signed_dividend - signed_divisor * quotient
        return remainder & MASK_XLEN

    @classmethod
    def remu(cls, dividend: int, divisor: int) -> int:
        """Unsigned remainder (REMU instruction) - remainder of dividend / divisor."""
        unsigned_dividend = to_unsigned_xlen(dividend)
        unsigned_divisor = to_unsigned_xlen(divisor)

        # Edge case: division by zero - return dividend unchanged
        if unsigned_divisor == 0:
            return unsigned_dividend

        return (unsigned_dividend % unsigned_divisor) & MASK_XLEN


# Export division operations as module-level functions for convenience
div = DivisionOperations.div
divu = DivisionOperations.divu
rem = DivisionOperations.rem
remu = DivisionOperations.remu


# Zba extension - address generation operations
@mask_to_xlen
def sh1add(operand_a: int, operand_b: int) -> int:
    """Shift left by 1 and add (SH1ADD instruction).

    Computes (rs1 << 1) + rs2, useful for array indexing with 2-byte elements.
    """
    return (operand_a << 1) + operand_b


@mask_to_xlen
def sh2add(operand_a: int, operand_b: int) -> int:
    """Shift left by 2 and add (SH2ADD instruction).

    Computes (rs1 << 2) + rs2, useful for array indexing with 4-byte elements.
    """
    return (operand_a << 2) + operand_b


@mask_to_xlen
def sh3add(operand_a: int, operand_b: int) -> int:
    """Shift left by 3 and add (SH3ADD instruction).

    Computes (rs1 << 3) + rs2, useful for array indexing with 8-byte elements.
    """
    return (operand_a << 3) + operand_b


# Zbs extension - single-bit operations
@mask_to_xlen
def bset(operand_a: int, operand_b: int) -> int:
    """Set single bit (BSET/BSETI instruction).

    Sets bit at position (operand_b & 31) in operand_a.
    """
    bit_position = operand_b & SHIFT_AMOUNT_MASK
    return operand_a | (1 << bit_position)


@mask_to_xlen
def bclr(operand_a: int, operand_b: int) -> int:
    """Clear single bit (BCLR/BCLRI instruction).

    Clears bit at position (operand_b & 31) in operand_a.
    """
    bit_position = operand_b & SHIFT_AMOUNT_MASK
    return operand_a & ~(1 << bit_position)


@mask_to_xlen
def binv(operand_a: int, operand_b: int) -> int:
    """Invert single bit (BINV/BINVI instruction).

    Inverts bit at position (operand_b & 31) in operand_a.
    """
    bit_position = operand_b & SHIFT_AMOUNT_MASK
    return operand_a ^ (1 << bit_position)


def bext(operand_a: int, operand_b: int) -> int:
    """Extract single bit (BEXT/BEXTI instruction).

    Extracts bit at position (operand_b & 31) from operand_a, returns 0 or 1.
    """
    bit_position = operand_b & SHIFT_AMOUNT_MASK
    return (operand_a >> bit_position) & 1


# Zbb extension - basic bit manipulation operations
def andn(operand_a: int, operand_b: int) -> int:
    """AND with complement (ANDN instruction).

    Computes rs1 & ~rs2.
    """
    return (operand_a & ~operand_b) & MASK_XLEN


def orn(operand_a: int, operand_b: int) -> int:
    """OR with complement (ORN instruction).

    Computes rs1 | ~rs2.
    """
    return (operand_a | (~operand_b & MASK_XLEN)) & MASK_XLEN


def xnor(operand_a: int, operand_b: int) -> int:
    """Exclusive NOR (XNOR instruction).

    Computes ~(rs1 ^ rs2).
    """
    return (~(operand_a ^ operand_b)) & MASK_XLEN


def max_rv(operand_a: int, operand_b: int) -> int:
    """Maximum signed (MAX instruction).

    Returns the larger of rs1 and rs2 (signed comparison).
    """
    signed_a = to_signed_xlen(operand_a)
    signed_b = to_signed_xlen(operand_b)
    return operand_a if signed_a > signed_b else operand_b


def maxu(operand_a: int, operand_b: int) -> int:
    """Maximum unsigned (MAXU instruction).

    Returns the larger of rs1 and rs2 (unsigned comparison).
    """
    unsigned_a = operand_a & MASK_XLEN
    unsigned_b = operand_b & MASK_XLEN
    return operand_a if unsigned_a > unsigned_b else operand_b


def min_rv(operand_a: int, operand_b: int) -> int:
    """Minimum signed (MIN instruction).

    Returns the smaller of rs1 and rs2 (signed comparison).
    """
    signed_a = to_signed_xlen(operand_a)
    signed_b = to_signed_xlen(operand_b)
    return operand_a if signed_a < signed_b else operand_b


def minu(operand_a: int, operand_b: int) -> int:
    """Minimum unsigned (MINU instruction).

    Returns the smaller of rs1 and rs2 (unsigned comparison).
    """
    unsigned_a = operand_a & MASK_XLEN
    unsigned_b = operand_b & MASK_XLEN
    return operand_a if unsigned_a < unsigned_b else operand_b


@mask_to_xlen
@limit_shift_amount
def rol(value: int, shift_amount: int) -> int:
    """Rotate left (ROL instruction).

    Rotates value left by shift_amount bits.
    """
    return (value << shift_amount) | (value >> (XLEN - shift_amount))


@mask_to_xlen
@limit_shift_amount
def ror(value: int, shift_amount: int) -> int:
    """Rotate right (ROR/RORI instruction).

    Rotates value right by shift_amount bits.
    """
    return (value >> shift_amount) | (value << (XLEN - shift_amount))


def clz(value: int) -> int:
    """Count leading zeros (CLZ instruction).

    Returns the number of leading zero bits in value. Returns XLEN if value is 0.
    """
    value = value & MASK_XLEN
    if value == 0:
        return XLEN
    count = 0
    for i in range(XLEN - 1, -1, -1):
        if value & (1 << i):
            break
        count += 1
    return count


def ctz(value: int) -> int:
    """Count trailing zeros (CTZ instruction).

    Returns the number of trailing zero bits in value. Returns XLEN if value is 0.
    """
    value = value & MASK_XLEN
    if value == 0:
        return XLEN
    count = 0
    for i in range(XLEN):
        if value & (1 << i):
            break
        count += 1
    return count


def cpop(value: int) -> int:
    """Count population / popcount (CPOP instruction).

    Returns the number of set bits in value.
    """
    value = value & MASK_XLEN
    return bin(value).count("1")


def sext_b(value: int) -> int:
    """Sign-extend byte (SEXT.B instruction).

    Sign-extends the lowest byte to 32 bits.
    """
    return sign_extend(value & 0xFF, 8) & MASK_XLEN


def sext_h(value: int) -> int:
    """Sign-extend halfword (SEXT.H instruction).

    Sign-extends the lowest halfword (16 bits) to 32 bits.
    """
    return sign_extend(value & 0xFFFF, 16) & MASK_XLEN


def zext_h(value: int) -> int:
    """Zero-extend halfword (ZEXT.H instruction).

    Zero-extends the lowest halfword (16 bits) to 32 bits.
    """
    return value & 0xFFFF


def orc_b(value: int) -> int:
    """OR-combine bytes (ORC.B instruction).

    For each byte, if any bit is set, all bits in that byte become 1.
    """
    result = 0
    for i in range(XLEN // 8):
        byte_val = (value >> (i * 8)) & 0xFF
        if byte_val != 0:
            result |= 0xFF << (i * 8)
    return result


def rev8(value: int) -> int:
    """Byte-reverse (REV8 instruction).

    Reverses the byte order (byte 0 ↔ byte 3, byte 1 ↔ byte 2).
    """
    value = value & MASK_XLEN
    num_bytes = XLEN // 8
    result = 0
    for i in range(num_bytes):
        byte_val = (value >> (i * 8)) & 0xFF
        result |= byte_val << ((num_bytes - 1 - i) * 8)
    return result


# Zicond extension - conditional operations
def czero_eqz(operand_a: int, operand_b: int) -> int:
    """Conditional zero if equal to zero (CZERO.EQZ instruction).

    Returns 0 if rs2 == 0, otherwise returns rs1.
    """
    return 0 if (operand_b & MASK_XLEN) == 0 else (operand_a & MASK_XLEN)


def czero_nez(operand_a: int, operand_b: int) -> int:
    """Conditional zero if not equal to zero (CZERO.NEZ instruction).

    Returns 0 if rs2 != 0, otherwise returns rs1.
    """
    return 0 if (operand_b & MASK_XLEN) != 0 else (operand_a & MASK_XLEN)


# Zbkb extension - bit manipulation for cryptography
def pack(operand_a: int, operand_b: int) -> int:
    """Pack lower halfwords (PACK instruction).

    Packs the lower 16 bits of rs1 into the lower 16 bits of rd,
    and the lower 16 bits of rs2 into the upper 16 bits of rd.
    Note: zext.h is pack rd, rs1, x0 (rs2=0).
    """
    half = XLEN // 2
    half_mask = (1 << half) - 1
    return ((operand_b & half_mask) << half) | (operand_a & half_mask)


def packh(operand_a: int, operand_b: int) -> int:
    """Pack lower bytes (PACKH instruction).

    Packs the lower 8 bits of rs1 into bits [7:0] of rd,
    and the lower 8 bits of rs2 into bits [15:8] of rd.
    Upper 16 bits are zero.
    """
    return ((operand_b & 0xFF) << 8) | (operand_a & 0xFF)


def brev8(value: int) -> int:
    """Bit-reverse each byte (BREV8 instruction).

    Reverses the bit order within each byte independently.
    """
    value = value & MASK_XLEN
    result = 0
    for byte_idx in range(XLEN // 8):
        byte_val = (value >> (byte_idx * 8)) & 0xFF
        # Reverse bits within the byte
        reversed_byte = 0
        for bit in range(8):
            if byte_val & (1 << bit):
                reversed_byte |= 1 << (7 - bit)
        result |= reversed_byte << (byte_idx * 8)
    return result


# RV64 W-form and unsigned-word evaluators (all dead at XLEN=32: the
# decoder never produces these ops there).
def _sext32_to_xlen(value: int) -> int:
    """Sign-extend a 32-bit result into the active XLEN."""
    return sign_extend(value & MASK32, 32) & MASK_XLEN


def addw(operand_a: int, operand_b: int) -> int:
    """ADDW/ADDIW: 32-bit add, result sign-extended to XLEN."""
    return _sext32_to_xlen((operand_a + operand_b) & MASK32)


def subw(operand_a: int, operand_b: int) -> int:
    """SUBW: 32-bit subtract, result sign-extended to XLEN."""
    return _sext32_to_xlen((operand_a - operand_b) & MASK32)


def sllw(value: int, shift_amount: int) -> int:
    """SLLW/SLLIW: 32-bit shift left, sext32 result (5-bit shamt)."""
    return _sext32_to_xlen((value << (shift_amount & SHIFT_AMOUNT_MASK_W)) & MASK32)


def srlw(value: int, shift_amount: int) -> int:
    """SRLW/SRLIW: 32-bit logical shift right, sext32 result."""
    return _sext32_to_xlen((value & MASK32) >> (shift_amount & SHIFT_AMOUNT_MASK_W))


def sraw(value: int, shift_amount: int) -> int:
    """SRAW/SRAIW: 32-bit arithmetic shift right, sext32 result."""
    return _sext32_to_xlen(
        (to_signed32(value) >> (shift_amount & SHIFT_AMOUNT_MASK_W)) & MASK32
    )


def add_uw(operand_a: int, operand_b: int) -> int:
    """ADD.UW (Zba): zext32(rs1) + rs2 at full XLEN."""
    return ((operand_a & MASK32) + operand_b) & MASK_XLEN


def sh1add_uw(operand_a: int, operand_b: int) -> int:
    """SH1ADD.UW (Zba): (zext32(rs1) << 1) + rs2."""
    return (((operand_a & MASK32) << 1) + operand_b) & MASK_XLEN


def sh2add_uw(operand_a: int, operand_b: int) -> int:
    """SH2ADD.UW (Zba): (zext32(rs1) << 2) + rs2."""
    return (((operand_a & MASK32) << 2) + operand_b) & MASK_XLEN


def sh3add_uw(operand_a: int, operand_b: int) -> int:
    """SH3ADD.UW (Zba): (zext32(rs1) << 3) + rs2."""
    return (((operand_a & MASK32) << 3) + operand_b) & MASK_XLEN


def slli_uw(value: int, shift_amount: int) -> int:
    """SLLI.UW (Zba): zext32(rs1) << shamt (6-bit shamt) at full XLEN."""
    return ((value & MASK32) << (shift_amount & SHIFT_AMOUNT_MASK)) & MASK_XLEN


def rolw(value: int, shift_amount: int) -> int:
    """ROLW (Zbb): 32-bit rotate left, sext32 result (5-bit shamt)."""
    sh = shift_amount & SHIFT_AMOUNT_MASK_W
    word = value & MASK32
    return _sext32_to_xlen(((word << sh) | (word >> (32 - sh))) & MASK32)


def rorw(value: int, shift_amount: int) -> int:
    """RORW/RORIW (Zbb): 32-bit rotate right, sext32 result (5-bit shamt)."""
    sh = shift_amount & SHIFT_AMOUNT_MASK_W
    word = value & MASK32
    return _sext32_to_xlen(((word >> sh) | (word << (32 - sh))) & MASK32)


def clzw(value: int) -> int:
    """CLZW (Zbb): count leading zeros in the low word (0..32)."""
    word = value & MASK32
    if word == 0:
        return 32
    count = 0
    for i in range(31, -1, -1):
        if word & (1 << i):
            break
        count += 1
    return count


def ctzw(value: int) -> int:
    """CTZW (Zbb): count trailing zeros in the low word (0..32)."""
    word = value & MASK32
    if word == 0:
        return 32
    count = 0
    for i in range(32):
        if word & (1 << i):
            break
        count += 1
    return count


def cpopw(value: int) -> int:
    """CPOPW (Zbb): population count of the low word."""
    return bin(value & MASK32).count("1")


def packw(operand_a: int, operand_b: int) -> int:
    """PACKW (Zbkb): pack low halfwords into a sext32 word (zext.h at RV64)."""
    return _sext32_to_xlen(((operand_b & 0xFFFF) << 16) | (operand_a & 0xFFFF))


# RV64M word-form evaluators (dead at XLEN=32).
def mulw(operand_a: int, operand_b: int) -> int:
    """MULW: sext32 of the low 32 bits of the product."""
    return _sext32_to_xlen((operand_a * operand_b) & MASK32)


def divw(dividend: int, divisor: int) -> int:
    """DIVW: 32-bit signed divide, sext32 result (spec edge cases)."""
    sd = sign_extend(dividend & MASK32, 32)
    sv = sign_extend(divisor & MASK32, 32)
    if sv == 0:
        return MASK_XLEN  # -1
    if sd == -(1 << 31) and sv == -1:
        return _sext32_to_xlen(1 << 31)
    return _sext32_to_xlen(int(sd / sv) & MASK32)


def divuw(dividend: int, divisor: int) -> int:
    """DIVUW: 32-bit unsigned divide, sext32 result."""
    ud = dividend & MASK32
    uv = divisor & MASK32
    if uv == 0:
        return MASK_XLEN  # sext32(2^32 - 1)
    return _sext32_to_xlen(ud // uv)


def remw(dividend: int, divisor: int) -> int:
    """REMW: 32-bit signed remainder, sext32 result."""
    sd = sign_extend(dividend & MASK32, 32)
    sv = sign_extend(divisor & MASK32, 32)
    if sv == 0:
        return _sext32_to_xlen(sd & MASK32)
    if sd == -(1 << 31) and sv == -1:
        return 0
    quotient = int(sd / sv)
    return _sext32_to_xlen((sd - sv * quotient) & MASK32)


def remuw(dividend: int, divisor: int) -> int:
    """REMUW: 32-bit unsigned remainder, sext32 result."""
    ud = dividend & MASK32
    uv = divisor & MASK32
    if uv == 0:
        return _sext32_to_xlen(ud)
    return _sext32_to_xlen(ud % uv)


# A extension (atomics) - AMO operation evaluators
# These compute the new value to write to memory given old_value and rs2.
# The rd register always receives old_value (the value loaded from memory).


def amoswap(old_value: int, rs2_value: int) -> int:
    """Atomic swap (AMOSWAP.W instruction).

    Atomically swaps memory value with rs2. Returns new value for memory.
    rd receives old_value separately.
    """
    return rs2_value & MASK32


@mask_to_xlen
def amoadd(old_value: int, rs2_value: int) -> int:
    """Atomic add (AMOADD.W instruction).

    Atomically adds rs2 to memory value. Returns new value for memory.
    """
    return old_value + rs2_value


def amoxor(old_value: int, rs2_value: int) -> int:
    """Atomic XOR (AMOXOR.W instruction).

    Atomically XORs memory value with rs2. Returns new value for memory.
    """
    return (old_value ^ rs2_value) & MASK32


def amoand(old_value: int, rs2_value: int) -> int:
    """Atomic AND (AMOAND.W instruction).

    Atomically ANDs memory value with rs2. Returns new value for memory.
    """
    return (old_value & rs2_value) & MASK32


def amoor(old_value: int, rs2_value: int) -> int:
    """Atomic OR (AMOOR.W instruction).

    Atomically ORs memory value with rs2. Returns new value for memory.
    """
    return (old_value | rs2_value) & MASK32


def amomin(old_value: int, rs2_value: int) -> int:
    """Atomic minimum signed (AMOMIN.W instruction).

    Atomically stores minimum of memory value and rs2 (signed comparison).
    Returns new value for memory.
    """
    signed_old = to_signed32(old_value)
    signed_rs2 = to_signed32(rs2_value)
    return (old_value if signed_old < signed_rs2 else rs2_value) & MASK32


def amomax(old_value: int, rs2_value: int) -> int:
    """Atomic maximum signed (AMOMAX.W instruction).

    Atomically stores maximum of memory value and rs2 (signed comparison).
    Returns new value for memory.
    """
    signed_old = to_signed32(old_value)
    signed_rs2 = to_signed32(rs2_value)
    return (old_value if signed_old > signed_rs2 else rs2_value) & MASK32


def amominu(old_value: int, rs2_value: int) -> int:
    """Atomic minimum unsigned (AMOMINU.W instruction).

    Atomically stores minimum of memory value and rs2 (unsigned comparison).
    Returns new value for memory.
    """
    unsigned_old = old_value & MASK32
    unsigned_rs2 = rs2_value & MASK32
    return old_value if unsigned_old < unsigned_rs2 else rs2_value


def amomaxu(old_value: int, rs2_value: int) -> int:
    """Atomic maximum unsigned (AMOMAXU.W instruction).

    Atomically stores maximum of memory value and rs2 (unsigned comparison).
    Returns new value for memory.
    """
    unsigned_old = old_value & MASK32
    unsigned_rs2 = rs2_value & MASK32
    return old_value if unsigned_old > unsigned_rs2 else rs2_value
