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

"""RISC-V conversion helpers.

- Sign extension for arbitrary bit widths
- Signed/unsigned 32-bit integer conversions
- 33-bit conversions for multiply operations

Constants like MASK32, XLEN, etc. should be imported from config.
"""

from config import MASK32, MASK_XLEN, XLEN

__all__ = [
    "sign_extend",
    "to_signed32",
    "to_unsigned32",
    "to_signed33",
    "to_signed_xlen",
    "to_unsigned_xlen",
]


def sign_extend(val: int, bits: int) -> int:
    """Sign extend a value to a specified length in bits.

    Args:
        val: Value to sign-extend
        bits: Number of bits in the original value

    Returns:
        Sign-extended value as a Python int (unbounded)

    Example:
        >>> sign_extend(0xFF, 8)  # Extend 8-bit -1 to full width
        -1
        >>> sign_extend(0x7F, 8)  # Extend 8-bit +127 to full width
        127
    """
    sign = 1 << (bits - 1)
    return (val & (sign - 1)) - (val & sign)


def to_signed_xlen(val: int) -> int:
    """Cast to a signed integer at the active XLEN (32 or 64).

    Args:
        val: Value to convert.

    Returns:
        Signed XLEN-bit integer.
    """
    return sign_extend(val & MASK_XLEN, XLEN)


def to_unsigned_xlen(val: int) -> int:
    """Cast to an unsigned integer at the active XLEN (32 or 64).

    Args:
        val: Value to convert.

    Returns:
        Unsigned XLEN-bit integer (0 to 2**XLEN - 1).
    """
    return val & MASK_XLEN


def to_signed32(val: int) -> int:
    """Cast to signed 32-bit integer.

    Args:
        val: Value to convert (any int)

    Returns:
        Signed 32-bit integer representation
    """
    return sign_extend(val & MASK32, 32)


def to_unsigned32(val: int) -> int:
    """Cast to unsigned 32-bit integer.

    Args:
        val: Value to convert (any int)

    Returns:
        Unsigned 32-bit integer (0 to 2^32-1)
    """
    return val & MASK32


def to_signed33(val: int) -> int:
    """Sign-extend a 32-bit value to a Python signed integer.

    Used for multiply-high operations (MULH, MULHSU) where we need the
    32-bit operand to be treated as signed for the 64-bit multiplication.

    Args:
        val: 32-bit value to sign-extend

    Returns:
        Python integer with correct sign (negative if bit 31 was set)
    """
    # Just use sign_extend to get an actual negative Python int
    return sign_extend(val & MASK32, 32)
