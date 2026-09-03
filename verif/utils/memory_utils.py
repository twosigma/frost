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

"""Memory access and alignment helpers.

Alignment checks and enforcement, the byte strobe and data replication a store
needs on the 64-bit data-tier beat, and address/immediate constraints for
random stimulus.
"""

from config import (
    BYTE_ALIGNMENT,
    HALFWORD_ALIGNMENT,
    WORD_ALIGNMENT,
    MASK32,
    MASK64,
    MASK_XLEN,
    MEMORY_BEAT_OFFSET_MASK,
)
from exceptions import AlignmentError


def align_address(address: int, alignment: int) -> int:
    """Align address down to specified boundary.

    Args:
        address: Address to align
        alignment: Alignment in bytes; must be a power of two

    Returns:
        Address aligned down to the nearest alignment boundary

    Examples:
        >>> hex(align_address(0x1003, 4))  # Word align
        '0x1000'
        >>> hex(align_address(0x1003, 2))  # Halfword align
        '0x1002'
    """
    return address & ~(alignment - 1)


def is_aligned(address: int, alignment: int) -> bool:
    """Check whether address is a multiple of alignment.

    Args:
        address: Address to check
        alignment: Required alignment in bytes

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
        The address, unchanged

    Raises:
        AlignmentError: If address doesn't meet alignment requirement

    Examples:
        >>> hex(ensure_aligned(0x1000, 4, "lw"))
        '0x1000'
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


def get_beat_byte_offset(address: int) -> int:
    """Get byte offset within the data-tier beat (bits [2:0] of address).

    Args:
        address: Memory address

    Returns:
        Byte offset (0-7) within the containing aligned dword

    Examples:
        >>> get_beat_byte_offset(0x1000)
        0
        >>> get_beat_byte_offset(0x1007)
        7
    """
    return address & MEMORY_BEAT_OFFSET_MASK


def calculate_byte_mask_for_store(operation: str, beat_offset: int) -> int:
    """Calculate the 8-lane byte strobe for a store on the data-tier beat.

    The data tier carries aligned 64-bit beats with one strobe bit per byte
    lane (hw/rtl/README.md "Data-tier bus contract"; mirrors riscv_pkg::mem_strobe_for).
    Bit i of the mask selects byte address {addr[31:3], i}.

    Store Types:
        SB (store byte):     1 lane   -> 0x01 << offset
        SH (store halfword): 2 lanes  -> 0x03 << (offset & ~1)
        SW/FSW (word):       4 lanes  -> 0x0F or 0xF0 by addr[2]
        FSD (double):        all 8 lanes -> 0xFF

    Args:
        operation: Store operation ("sb", "sh", "sw", "fsw", or "fsd")
        beat_offset: Byte offset within the beat (0-7), from address[2:0]

    Returns:
        8-bit strobe indicating which beat lanes to write

    Raises:
        ValueError: If operation is not a valid store instruction

    Examples:
        >>> calculate_byte_mask_for_store("sb", 0)   # Lane 0 -> 0x01
        1
        >>> calculate_byte_mask_for_store("sb", 7)   # Lane 7 -> 0x80
        128
        >>> calculate_byte_mask_for_store("sh", 6)   # Lanes 6-7 -> 0xC0
        192
        >>> calculate_byte_mask_for_store("sw", 0)   # Low word -> 0x0F
        15
        >>> calculate_byte_mask_for_store("sw", 4)   # High word -> 0xF0
        240
        >>> calculate_byte_mask_for_store("fsd", 0)  # Full beat -> 0xFF
        255
    """
    if operation == "sb":
        return 1 << beat_offset

    elif operation == "sh":
        return 0b11 << (beat_offset & ~1)

    elif operation in ("sw", "fsw"):
        return 0xF0 if beat_offset & 0x4 else 0x0F

    elif operation == "fsd":
        return 0xFF

    else:
        raise ValueError(f"Unknown store operation: {operation}")


def replicate_store_data_for_beat(operation: str, value: int) -> int:
    """Position store data on the beat by replication (bus contract).

    The RTL replicates sub-beat store data across all 64 bits and lets the byte
    strobes pick the addressed lanes: {8{byte}}, {4{half}}, {2{word}}, dword
    pass-through, in store_queue.gen_write_data. The expected-write monitor
    compares the whole beat, so this model reproduces the replication rather
    than zeroing the unselected lanes.

    Args:
        operation: Store operation ("sb", "sh", "sw", "fsw", or "fsd")
        value: Store data (low bits used per the operation's size)

    Returns:
        64-bit beat image with the data replicated across the beat

    Examples:
        >>> hex(replicate_store_data_for_beat("sb", 0xAB))
        '0xabababababababab'
        >>> hex(replicate_store_data_for_beat("sh", 0x1234))
        '0x1234123412341234'
        >>> hex(replicate_store_data_for_beat("sw", 0xDEADBEEF))
        '0xdeadbeefdeadbeef'
        >>> hex(replicate_store_data_for_beat("fsd", 0x0123456789ABCDEF))
        '0x123456789abcdef'
    """
    if operation == "sb":
        byte = value & 0xFF
        return int.from_bytes(bytes([byte]) * 8, "little")

    elif operation == "sh":
        half = value & 0xFFFF
        return half | half << 16 | half << 32 | half << 48

    elif operation in ("sw", "fsw"):
        word = value & MASK32
        return word | word << 32

    elif operation == "fsd":
        return value & MASK64

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

    Used by random address generation to keep an address inside the allocated
    memory space and on the alignment the operation requires.

    Args:
        address: Original address
        max_address: Maximum valid address (exclusive)
        alignment: Required alignment in bytes (default: 1)

    Returns:
        Address constrained to [0, max_address) and aligned

    Examples:
        >>> hex(constrain_address_to_range(0x5000, 0x2000, 4))
        '0x1000'
        >>> hex(constrain_address_to_range(0x100, 0x2000, 4))
        '0x100'
    """
    constrained = address % max_address
    return align_address(constrained, alignment)


def generate_aligned_immediate(
    base_value: int,
    target_alignment: int,
    immediate_min: int = -2048,
    immediate_max: int = 2047,
    memory_size_constraint: int | None = None,
) -> int:
    """Generate an immediate that gives an aligned address when added to base.

    With a memory-size constraint, chooses from all representable immediates
    that satisfy both requirements. Without one, rejection-samples for speed
    and falls back to enumerating the representable range.

    Args:
        base_value: Base register value
        target_alignment: Required alignment for the final address
        immediate_min: Minimum immediate value (default: -2048 for 12-bit signed)
        immediate_max: Maximum immediate value (default: 2047 for 12-bit signed)
        memory_size_constraint: If provided, ensures (base + imm) falls within
                               allocated memory space [0, memory_size)

    Returns:
        Immediate value that, when added to base, produces aligned address

    Raises:
        ValueError: If the immediate range contains no value satisfying the
            alignment and optional memory-size constraint

    Examples:
        >>> base = 0x1001
        >>> imm = generate_aligned_immediate(base, 4)
        >>> is_aligned((base + imm) & 0xFFFFFFFF, 4)
        True
    """
    import random

    if immediate_min > immediate_max:
        raise ValueError("immediate_min must not exceed immediate_max")
    if target_alignment <= 0:
        raise ValueError("target_alignment must be positive")
    if memory_size_constraint is not None:
        if memory_size_constraint <= 0:
            raise ValueError("memory_size_constraint must be positive")
        valid_immediates = [
            immediate_value
            for immediate_value in range(immediate_min, immediate_max + 1)
            if ((base_value + immediate_value) & MASK_XLEN) % target_alignment == 0
            and ((base_value + immediate_value) & MASK_XLEN) < memory_size_constraint
        ]
        if not valid_immediates:
            raise ValueError(
                "no immediate in the requested range reaches the constrained memory"
            )
        return random.choice(valid_immediates)

    # Rejection sampling is cheaper than enumerating every valid immediate.
    max_attempts = 1000  # Safety limit to prevent infinite loops

    for _ in range(max_attempts):
        immediate_value = random.randint(immediate_min, immediate_max)
        effective_address = (base_value + immediate_value) & 0xFFFFFFFF

        if effective_address % target_alignment != 0:
            continue

        return immediate_value

    valid_immediates = [
        immediate_value
        for immediate_value in range(immediate_min, immediate_max + 1)
        if ((base_value + immediate_value) & MASK_XLEN) % target_alignment == 0
    ]
    if not valid_immediates:
        raise ValueError("no immediate in the requested range produces alignment")
    return random.choice(valid_immediates)
