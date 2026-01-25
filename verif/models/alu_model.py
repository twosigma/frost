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

"""Enhanced ALU operations with better abstractions.

ALU Operations
==============

This module provides reference implementations for all ALU operations supported
by the Frost CPU, including load operations that read from memory.

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
    SHIFT_AMOUNT_MASK,
    DIVISION_OVERFLOW_DIVIDEND,
    DIVISION_OVERFLOW_DIVISOR,
    DIVISION_BY_ZERO_QUOTIENT,
)
from utils.riscv_utils import (
    to_signed32,
    to_unsigned32,
    to_signed33,
    sign_extend,
)


class MemoryReader(Protocol):
    """Protocol for objects that can read from memory.

    This protocol allows load operations to work with any object that
    provides read_byte and read_word methods, not just MemoryModel.
    """

    def read_byte(self, address: int) -> int:
        """Read a single byte from memory."""
        ...

    def read_word(self, address: int) -> int:
        """Read a 32-bit word from memory."""
        ...


# Decorators for common RISC-V operation patterns
def mask_to_32_bits(function: Callable) -> Callable:
    """Mask operation result to 32 bits for overflow wrapping."""

    @wraps(function)
    def wrapper(*args: int, **kwargs: int) -> int:
        result = function(*args, **kwargs)
        return result & MASK32  # Keep only lower 32 bits

    return wrapper


def limit_shift_amount(function: Callable) -> Callable:
    """Limit shift amount to 5 bits per RISC-V specification."""

    @wraps(function)
    def wrapper(value: int, shift_amount: int) -> int:
        return function(value, shift_amount & SHIFT_AMOUNT_MASK)  # Only use bits [4:0]

    return wrapper


# Protocols for ALU operations
class BinaryOperation(Protocol):
    """Protocol for binary ALU operations (two operands)."""

    def __call__(self, operand_a: int, operand_b: int) -> int:
        """Execute binary operation on two operands."""
        ...


class UnaryOperation(Protocol):
    """Protocol for unary ALU operations (one operand)."""

    def __call__(self, value: int) -> int:
        """Execute unary operation on one operand."""
        ...


# Base integer ALU operations (RV32I)
@mask_to_32_bits
def add(operand_a: int, operand_b: int) -> int:
    """Add two 32-bit values (wraps on overflow)."""
    return operand_a + operand_b


@mask_to_32_bits
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


@mask_to_32_bits
@limit_shift_amount
def sll(value: int, shift_amount: int) -> int:
    """Shift left logical - shifts value left, filling with zeros."""
    return value << shift_amount


@mask_to_32_bits
@limit_shift_amount
def srl(value: int, shift_amount: int) -> int:
    """Shift right logical - shifts value right, filling with zeros."""
    return value >> shift_amount


@mask_to_32_bits
@limit_shift_amount
def sra(value: int, shift_amount: int) -> int:
    """Shift right arithmetic - shifts right, preserving sign bit."""
    return to_signed32(value) >> shift_amount


def slt(operand_a: int, operand_b: int) -> int:
    """Set if less than (signed comparison) - returns 1 if a < b, else 0."""
    return int(to_signed32(operand_a) < to_signed32(operand_b))


def sltu(operand_a: int, operand_b: int) -> int:
    """Set if less than unsigned - returns 1 if a < b (unsigned), else 0."""
    return int((operand_a & MASK32) < (operand_b & MASK32))


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
        32-bit value (sign-extended or zero-extended halfword)
    """
    aligned_address = memory_address & ~0x1  # Align to 2-byte boundary
    # Read two bytes in little-endian order
    halfword_value = memory.read_byte(aligned_address) | (
        memory.read_byte(aligned_address + 1) << 8
    )
    if is_signed:
        return sign_extend(halfword_value, 16) & MASK32
    return halfword_value & MASK32


# Load operations (I-type instructions)
# These functions take a MemoryReader to avoid global state.
def lw(memory: MemoryReader, memory_address: int) -> int:
    """Load word - read 32-bit word from memory (LW instruction).

    Args:
        memory: Memory model to read from
        memory_address: Byte address (will be aligned to 4-byte boundary)

    Returns:
        32-bit word value from memory
    """
    return memory.read_word(memory_address & ~0x3)  # Align to 4-byte boundary


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
        Sign-extended 32-bit value
    """
    return sign_extend(memory.read_byte(memory_address), 8) & MASK32


def lbu(memory: MemoryReader, memory_address: int) -> int:
    """Load byte unsigned - read byte and zero-extend to 32 bits (LBU instruction).

    Args:
        memory: Memory model to read from
        memory_address: Byte address to load from

    Returns:
        Zero-extended 32-bit value
    """
    return memory.read_byte(memory_address) & MASK32


def lh(memory: MemoryReader, memory_address: int) -> int:
    """Load halfword signed - read 16 bits and sign-extend (LH instruction).

    Args:
        memory: Memory model to read from
        memory_address: Byte address (will be aligned to 2-byte boundary)

    Returns:
        Sign-extended 32-bit value
    """
    return _load_halfword_from_memory(memory, memory_address, is_signed=True)


def lhu(memory: MemoryReader, memory_address: int) -> int:
    """Load halfword unsigned - read 16 bits and zero-extend (LHU instruction).

    Args:
        memory: Memory model to read from
        memory_address: Byte address (will be aligned to 2-byte boundary)

    Returns:
        Zero-extended 32-bit value
    """
    return _load_halfword_from_memory(memory, memory_address, is_signed=False)


# M-extension multiply operations (RV32M)
@mask_to_32_bits
def mul(operand_a: int, operand_b: int) -> int:
    """Multiply (signed × signed) - return lower 32 bits of 64-bit product (MUL instruction)."""
    return to_signed32(operand_a) * to_signed32(operand_b)


@mask_to_32_bits
def mulh(operand_a: int, operand_b: int) -> int:
    """Multiply high (signed × signed) - return upper 32 bits of 64-bit product (MULH instruction)."""
    product_64_bit = to_signed33(operand_a) * to_signed33(operand_b)
    return product_64_bit >> 32  # Return upper 32 bits


@mask_to_32_bits
def mulhsu(operand_a: int, operand_b: int) -> int:
    """Multiply high (signed × unsigned) - return upper 32 bits (MULHSU instruction)."""
    product_64_bit = to_signed33(operand_a) * to_unsigned32(operand_b)
    return product_64_bit >> 32


@mask_to_32_bits
def mulhu(operand_a: int, operand_b: int) -> int:
    """Multiply high (unsigned × unsigned) - return upper 32 bits (MULHU instruction)."""
    product_64_bit = to_unsigned32(operand_a) * to_unsigned32(operand_b)
    return product_64_bit >> 32


# M-extension division/remainder operations (RV32M)
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
        signed_dividend = to_signed32(dividend)
        signed_divisor = to_signed32(divisor)

        # Edge case: division by zero
        if signed_divisor == 0:
            return DIVISION_BY_ZERO_QUOTIENT

        # Edge case: overflow (most negative number divided by -1)
        if (
            signed_dividend == DIVISION_OVERFLOW_DIVIDEND
            and signed_divisor == DIVISION_OVERFLOW_DIVISOR
        ):
            return 0x80000000  # Return most negative number

        return int(signed_dividend / signed_divisor) & MASK32

    @classmethod
    def divu(cls, dividend: int, divisor: int) -> int:
        """Unsigned division (DIVU instruction) - quotient of dividend / divisor."""
        unsigned_dividend = to_unsigned32(dividend)
        unsigned_divisor = to_unsigned32(divisor)

        # Edge case: division by zero
        if unsigned_divisor == 0:
            return DIVISION_BY_ZERO_QUOTIENT

        return (unsigned_dividend // unsigned_divisor) & MASK32

    @classmethod
    def rem(cls, dividend: int, divisor: int) -> int:
        """Signed remainder (REM instruction) - remainder of dividend / divisor."""
        signed_dividend = to_signed32(dividend)
        signed_divisor = to_signed32(divisor)

        # Edge case: division by zero - return dividend unchanged
        if signed_divisor == 0:
            return dividend & MASK32

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
        return remainder & MASK32

    @classmethod
    def remu(cls, dividend: int, divisor: int) -> int:
        """Unsigned remainder (REMU instruction) - remainder of dividend / divisor."""
        unsigned_dividend = to_unsigned32(dividend)
        unsigned_divisor = to_unsigned32(divisor)

        # Edge case: division by zero - return dividend unchanged
        if unsigned_divisor == 0:
            return unsigned_dividend

        return (unsigned_dividend % unsigned_divisor) & MASK32


# Export division operations as module-level functions for convenience
div = DivisionOperations.div
divu = DivisionOperations.divu
rem = DivisionOperations.rem
remu = DivisionOperations.remu


# Zba extension - address generation operations
@mask_to_32_bits
def sh1add(operand_a: int, operand_b: int) -> int:
    """Shift left by 1 and add (SH1ADD instruction).

    Computes (rs1 << 1) + rs2, useful for array indexing with 2-byte elements.
    """
    return (operand_a << 1) + operand_b


@mask_to_32_bits
def sh2add(operand_a: int, operand_b: int) -> int:
    """Shift left by 2 and add (SH2ADD instruction).

    Computes (rs1 << 2) + rs2, useful for array indexing with 4-byte elements.
    """
    return (operand_a << 2) + operand_b


@mask_to_32_bits
def sh3add(operand_a: int, operand_b: int) -> int:
    """Shift left by 3 and add (SH3ADD instruction).

    Computes (rs1 << 3) + rs2, useful for array indexing with 8-byte elements.
    """
    return (operand_a << 3) + operand_b


# Zbs extension - single-bit operations
@mask_to_32_bits
def bset(operand_a: int, operand_b: int) -> int:
    """Set single bit (BSET/BSETI instruction).

    Sets bit at position (operand_b & 31) in operand_a.
    """
    bit_position = operand_b & SHIFT_AMOUNT_MASK
    return operand_a | (1 << bit_position)


@mask_to_32_bits
def bclr(operand_a: int, operand_b: int) -> int:
    """Clear single bit (BCLR/BCLRI instruction).

    Clears bit at position (operand_b & 31) in operand_a.
    """
    bit_position = operand_b & SHIFT_AMOUNT_MASK
    return operand_a & ~(1 << bit_position)


@mask_to_32_bits
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
    return operand_a & (~operand_b & MASK32)


def orn(operand_a: int, operand_b: int) -> int:
    """OR with complement (ORN instruction).

    Computes rs1 | ~rs2.
    """
    return (operand_a | (~operand_b & MASK32)) & MASK32


def xnor(operand_a: int, operand_b: int) -> int:
    """Exclusive NOR (XNOR instruction).

    Computes ~(rs1 ^ rs2).
    """
    return (~(operand_a ^ operand_b)) & MASK32


def max_rv(operand_a: int, operand_b: int) -> int:
    """Maximum signed (MAX instruction).

    Returns the larger of rs1 and rs2 (signed comparison).
    """
    signed_a = to_signed32(operand_a)
    signed_b = to_signed32(operand_b)
    return operand_a if signed_a > signed_b else operand_b


def maxu(operand_a: int, operand_b: int) -> int:
    """Maximum unsigned (MAXU instruction).

    Returns the larger of rs1 and rs2 (unsigned comparison).
    """
    unsigned_a = operand_a & MASK32
    unsigned_b = operand_b & MASK32
    return operand_a if unsigned_a > unsigned_b else operand_b


def min_rv(operand_a: int, operand_b: int) -> int:
    """Minimum signed (MIN instruction).

    Returns the smaller of rs1 and rs2 (signed comparison).
    """
    signed_a = to_signed32(operand_a)
    signed_b = to_signed32(operand_b)
    return operand_a if signed_a < signed_b else operand_b


def minu(operand_a: int, operand_b: int) -> int:
    """Minimum unsigned (MINU instruction).

    Returns the smaller of rs1 and rs2 (unsigned comparison).
    """
    unsigned_a = operand_a & MASK32
    unsigned_b = operand_b & MASK32
    return operand_a if unsigned_a < unsigned_b else operand_b


@mask_to_32_bits
@limit_shift_amount
def rol(value: int, shift_amount: int) -> int:
    """Rotate left (ROL instruction).

    Rotates value left by shift_amount bits.
    """
    return (value << shift_amount) | (value >> (32 - shift_amount))


@mask_to_32_bits
@limit_shift_amount
def ror(value: int, shift_amount: int) -> int:
    """Rotate right (ROR/RORI instruction).

    Rotates value right by shift_amount bits.
    """
    return (value >> shift_amount) | (value << (32 - shift_amount))


def clz(value: int) -> int:
    """Count leading zeros (CLZ instruction).

    Returns the number of leading zero bits in value. Returns 32 if value is 0.
    """
    value = value & MASK32
    if value == 0:
        return 32
    count = 0
    for i in range(31, -1, -1):
        if value & (1 << i):
            break
        count += 1
    return count


def ctz(value: int) -> int:
    """Count trailing zeros (CTZ instruction).

    Returns the number of trailing zero bits in value. Returns 32 if value is 0.
    """
    value = value & MASK32
    if value == 0:
        return 32
    count = 0
    for i in range(32):
        if value & (1 << i):
            break
        count += 1
    return count


def cpop(value: int) -> int:
    """Count population / popcount (CPOP instruction).

    Returns the number of set bits in value.
    """
    value = value & MASK32
    return bin(value).count("1")


def sext_b(value: int) -> int:
    """Sign-extend byte (SEXT.B instruction).

    Sign-extends the lowest byte to 32 bits.
    """
    return sign_extend(value & 0xFF, 8) & MASK32


def sext_h(value: int) -> int:
    """Sign-extend halfword (SEXT.H instruction).

    Sign-extends the lowest halfword (16 bits) to 32 bits.
    """
    return sign_extend(value & 0xFFFF, 16) & MASK32


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
    for i in range(4):
        byte_val = (value >> (i * 8)) & 0xFF
        if byte_val != 0:
            result |= 0xFF << (i * 8)
    return result


def rev8(value: int) -> int:
    """Byte-reverse (REV8 instruction).

    Reverses the byte order (byte 0 ↔ byte 3, byte 1 ↔ byte 2).
    """
    value = value & MASK32
    byte0 = (value >> 0) & 0xFF
    byte1 = (value >> 8) & 0xFF
    byte2 = (value >> 16) & 0xFF
    byte3 = (value >> 24) & 0xFF
    return (byte0 << 24) | (byte1 << 16) | (byte2 << 8) | byte3


# Zicond extension - conditional operations
def czero_eqz(operand_a: int, operand_b: int) -> int:
    """Conditional zero if equal to zero (CZERO.EQZ instruction).

    Returns 0 if rs2 == 0, otherwise returns rs1.
    """
    return 0 if (operand_b & MASK32) == 0 else (operand_a & MASK32)


def czero_nez(operand_a: int, operand_b: int) -> int:
    """Conditional zero if not equal to zero (CZERO.NEZ instruction).

    Returns 0 if rs2 != 0, otherwise returns rs1.
    """
    return 0 if (operand_b & MASK32) != 0 else (operand_a & MASK32)


# Zbkb extension - bit manipulation for cryptography
def pack(operand_a: int, operand_b: int) -> int:
    """Pack lower halfwords (PACK instruction).

    Packs the lower 16 bits of rs1 into the lower 16 bits of rd,
    and the lower 16 bits of rs2 into the upper 16 bits of rd.
    Note: zext.h is pack rd, rs1, x0 (rs2=0).
    """
    return ((operand_b & 0xFFFF) << 16) | (operand_a & 0xFFFF)


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
    value = value & MASK32
    result = 0
    for byte_idx in range(4):
        byte_val = (value >> (byte_idx * 8)) & 0xFF
        # Reverse bits within the byte
        reversed_byte = 0
        for bit in range(8):
            if byte_val & (1 << bit):
                reversed_byte |= 1 << (7 - bit)
        result |= reversed_byte << (byte_idx * 8)
    return result


def zip_rv(value: int) -> int:
    """Bit interleave (ZIP instruction, RV32 only).

    Interleaves bits from the lower and upper halves:
    rd[2i] = rs[i], rd[2i+1] = rs[i+16] for i = 0..15.
    """
    value = value & MASK32
    result = 0
    for i in range(16):
        # rd[2i] = rs[i]
        if value & (1 << i):
            result |= 1 << (2 * i)
        # rd[2i+1] = rs[i+16]
        if value & (1 << (i + 16)):
            result |= 1 << (2 * i + 1)
    return result


def unzip(value: int) -> int:
    """Bit deinterleave (UNZIP instruction, RV32 only).

    Deinterleaves bits to lower and upper halves (inverse of ZIP):
    rd[i] = rs[2i], rd[i+16] = rs[2i+1] for i = 0..15.
    """
    value = value & MASK32
    result = 0
    for i in range(16):
        # rd[i] = rs[2i]
        if value & (1 << (2 * i)):
            result |= 1 << i
        # rd[i+16] = rs[2i+1]
        if value & (1 << (2 * i + 1)):
            result |= 1 << (i + 16)
    return result


# A extension (atomics) - AMO operation evaluators
# These compute the new value to write to memory given old_value and rs2.
# The rd register always receives old_value (the value loaded from memory).


def amoswap(old_value: int, rs2_value: int) -> int:
    """Atomic swap (AMOSWAP.W instruction).

    Atomically swaps memory value with rs2. Returns new value for memory.
    rd receives old_value separately.
    """
    return rs2_value & MASK32


@mask_to_32_bits
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
