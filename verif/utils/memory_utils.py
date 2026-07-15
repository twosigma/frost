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

"""Memory access utilities and alignment helpers.

Memory Utils
============

This module provides utilities for memory operations including:
- Address alignment checking and enforcement
- Byte mask calculation for store operations
- Address constraint helpers for random generation
"""

from config import (
    BYTE_ALIGNMENT,
    HALFWORD_ALIGNMENT,
    WORD_ALIGNMENT,
    MEMORY_BYTE_OFFSET_MASK,
)
from exceptions import AlignmentError


def align_address(address: int, alignment: int) -> int:
    """Align address down to specified boundary.

    Args:
        address: Address to align
        alignment: Alignment requirement in bytes (1, 2, or 4)

    Returns:
        Address aligned down to the nearest alignment boundary

    Examples:
        >>> align_address(0x1003, 4)  # Word align
        0x1000
        >>> align_address(0x1003, 2)  # Halfword align
        0x1002
    """
    return address & ~(alignment - 1)


def is_aligned(address: int, alignment: int) -> bool:
    """Check if address is properly aligned.

    Args:
        address: Address to check
        alignment: Required alignment in bytes (1, 2, or 4)

    Returns:
        True if address meets alignment requirement, False otherwise

    Examples:
        >>> is_aligned(0x1000, 4)
        True
        >>> is_aligned(0x1002, 4)
        False
        >>> is_aligned(0x1002, 2)
        True
    """
    return (address % alignment) == 0


def ensure_aligned(address: int, alignment: int, operation: str) -> int:
    """Ensure address is aligned, raise AlignmentError if not.

    Args:
        address: Address to validate
        alignment: Required alignment in bytes
        operation: Operation name for error message (e.g., "lw", "sh")

    Returns:
        The address (unchanged) if properly aligned

    Raises:
        AlignmentError: If address doesn't meet alignment requirement

    Examples:
        >>> ensure_aligned(0x1000, 4, "lw")
        0x1000
        >>> ensure_aligned(0x1002, 4, "lw")  # doctest: +SKIP
        Traceback: AlignmentError
    """
    if not is_aligned(address, alignment):
        raise AlignmentError(
            f"{operation} requires {alignment}-byte alignment, got address 0x{address:08x}",
            address=address,
            required_alignment=alignment,
        )
    return address


def get_byte_offset(address: int) -> int:
    """Get byte offset within word (bits [1:0] of address).

    Args:
        address: Memory address

    Returns:
        Byte offset (0-3) within the containing word

    Examples:
        >>> get_byte_offset(0x1000)
        0
        >>> get_byte_offset(0x1003)
        3
    """
    return address & MEMORY_BYTE_OFFSET_MASK


def calculate_byte_mask_for_store(operation: str, byte_offset: int) -> int:
    """Calculate byte-enable mask for store operations.

    RISC-V stores write to a 32-bit word-aligned memory interface.
    The byte mask indicates which bytes within that word should be updated.
    Each bit corresponds to one byte: bit 0 = byte 0, bit 1 = byte 1, etc.

    Memory Layout (little-endian):
        Byte:     3        2        1        0
        Bits:  [31:24]  [23:16]  [15:8]   [7:0]
        Mask:  0b1000   0b0100   0b0010   0b0001

    Store Types:
        SB (store byte):     Write 1 byte  -> mask has 1 bit set
        SH (store halfword): Write 2 bytes -> mask has 2 consecutive bits set
        SW (store word):     Write 4 bytes -> mask = 0b1111

    Args:
        operation: Store operation ("sb", "sh", or "sw")
        byte_offset: Byte offset within word (0-3), from address[1:0]

    Returns:
        4-bit mask indicating which bytes to write

    Raises:
        ValueError: If operation is not a valid store instruction

    Examples:
        >>> calculate_byte_mask_for_store("sb", 0)  # Store to byte 0
        1  # 0b0001
        >>> calculate_byte_mask_for_store("sb", 3)  # Store to byte 3
        8  # 0b1000
        >>> calculate_byte_mask_for_store("sh", 0)  # Store halfword at bytes 0-1
        3  # 0b0011
        >>> calculate_byte_mask_for_store("sh", 2)  # Store halfword at bytes 2-3
        12  # 0b1100
        >>> calculate_byte_mask_for_store("sw", 0)  # Store full word
        15  # 0b1111
    """
    if operation == "sb":
        # Store byte: Write single byte at position specified by byte_offset
        # Offset 0 -> 0b0001, offset 1 -> 0b0010, offset 2 -> 0b0100, offset 3 -> 0b1000
        return 1 << byte_offset

    elif operation == "sh":
        # Store halfword: Write 2 consecutive bytes
        # Halfwords must be 2-byte aligned, so offset is 0, 1, 2, or 3
        # But actual halfword addresses are offset 0 or 2 (aligned)
        # Offset 0 or 1 -> bytes 0,1 (0b0011)
        # Offset 2 or 3 -> bytes 2,3 (0b1100)
        return 0b1100 if byte_offset > 1 else 0b0011

    elif operation == "sw":
        # Store word: Write all 4 bytes
        return 0b1111

    else:
        raise ValueError(f"Unknown store operation: {operation}")


def get_alignment_for_operation(operation: str) -> int:
    """Get required alignment for a memory operation.

    Args:
        operation: Memory operation mnemonic (load or store)

    Returns:
        Required alignment in bytes (1, 2, or 4)

    Raises:
        ValueError: If operation is not recognized

    Examples:
        >>> get_alignment_for_operation("lw")
        4
        >>> get_alignment_for_operation("sh")
        2
        >>> get_alignment_for_operation("lb")
        1
    """
    if operation in ("lw", "sw"):
        return WORD_ALIGNMENT
    elif operation in ("lh", "lhu", "sh"):
        return HALFWORD_ALIGNMENT
    elif operation in ("lb", "lbu", "sb"):
        return BYTE_ALIGNMENT
    else:
        raise ValueError(f"Unknown memory operation: {operation}")


def constrain_address_to_range(
    address: int, max_address: int, alignment: int = 1
) -> int:
    """Constrain address to valid range and alignment.

    Useful for random address generation to ensure addresses fall within
    allocated memory space and meet alignment requirements.

    Args:
        address: Original address
        max_address: Maximum valid address (exclusive)
        alignment: Required alignment in bytes (default: 1)

    Returns:
        Address constrained to [0, max_address) and aligned

    Examples:
        >>> constrain_address_to_range(0x5000, 0x2000, 4)
        0x1000
        >>> constrain_address_to_range(0x100, 0x2000, 4)
        0x100
    """
    # First constrain to range
    constrained = address % max_address
    # Then align
    return align_address(constrained, alignment)


def generate_aligned_immediate(
    base_value: int,
    target_alignment: int,
    immediate_min: int = -2048,
    immediate_max: int = 2047,
    memory_size_constraint: int | None = None,
) -> int:
    """Generate an immediate value that produces aligned address when added to base.

    Uses rejection sampling to efficiently find a valid immediate value.

    Args:
        base_value: Base register value
        target_alignment: Required alignment for final address (2 or 4)
        immediate_min: Minimum immediate value (default: -2048 for 12-bit signed)
        immediate_max: Maximum immediate value (default: 2047 for 12-bit signed)
        memory_size_constraint: If provided, ensures (base + imm) falls within
                               allocated memory space [0, memory_size)

    Returns:
        Immediate value that, when added to base, produces aligned address

    Examples:
        >>> base = 0x1001
        >>> imm = generate_aligned_immediate(base, 4)
        >>> is_aligned((base + imm) & 0xFFFFFFFF, 4)
        True
    """
    import random

    # Rejection sampling is more efficient than pre-computing all valid values
    max_attempts = 1000  # Safety limit to prevent infinite loops

    for _ in range(max_attempts):
        immediate_value = random.randint(immediate_min, immediate_max)
        effective_address = (base_value + immediate_value) & 0xFFFFFFFF

        # Check alignment requirement
        if effective_address % target_alignment != 0:
            continue

        # Check memory size constraint if provided
        if memory_size_constraint is not None:
            constrained_address = effective_address % memory_size_constraint
            if constrained_address >= memory_size_constraint:
                continue

        # Found valid immediate
        return immediate_value

    # Fallback: calculate offset needed for alignment (ignore memory constraint)
    misalignment = base_value % target_alignment
    offset_needed = (target_alignment - misalignment) % target_alignment

    if immediate_min <= offset_needed <= immediate_max:
        return offset_needed
    else:
        # Last resort: return minimum value
        return immediate_min
