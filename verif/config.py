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

"""Central configuration for verification environment.

Configuration
=============

This module contains all configuration constants used throughout the verification
framework. Centralizing these values improves maintainability and makes it easier
to reconfigure the testbench for different CPU implementations.

Organization:
    Constants are organized into logical sections:
    - Memory Configuration (address width, masks, sizes)
    - Register File Configuration (count, indices)
    - RISC-V Data Type Masks (32-bit, 33-bit, 64-bit)
    - Alignment Requirements (byte, halfword, word)
    - Immediate Field Constraints (ranges, masks)
    - DUT Signal Path Configuration
    - Test Configuration Defaults
    - RISC-V ISA Constants

Usage:
    Import specific constants as needed:
    >>> from config import MASK32, IMM_12BIT_MIN, IMM_12BIT_MAX
    >>> result = (value + immediate) & MASK32
    >>> if not (IMM_12BIT_MIN <= imm <= IMM_12BIT_MAX):
    ...     raise ValueError("Immediate out of range")

    Or import the dataclass for signal path configuration:
    >>> from config import DUTSignalPaths
    >>> custom_paths = DUTSignalPaths(regfile_ram_rs1_path="my.path.here")

Customization:
    To adapt for a different CPU implementation:
    1. Modify MEMORY_ADDRESS_WIDTH for different address space
    2. Adjust DUTSignalPaths for different hierarchy
    3. Change test defaults (NUM_LOOPS, MEMORY_INIT_SIZE, etc.)
"""

from dataclasses import dataclass
from typing import Final

# ============================================================================
# Memory Configuration
# ============================================================================

MEMORY_ADDRESS_WIDTH: Final[int] = 16
"""Width of memory address bus in bits (default: 16-bit = 64KB address space)."""

MEMORY_WORD_SIZE_BYTES: Final[int] = 4
"""Size of a memory word in bytes (32-bit words)."""

MEMORY_ADDRESS_MASK: Final[int] = (1 << MEMORY_ADDRESS_WIDTH) - 1
"""Mask for valid memory addresses (0xFFFF for 16-bit addresses)."""

MEMORY_WORD_ALIGN_MASK: Final[int] = 0xFFFFFFFC
"""Mask for word-aligning addresses (clear bottom 2 bits, 32-bit safe)."""

MEMORY_HALFWORD_ALIGN_MASK: Final[int] = 0xFFFFFFFE
"""Mask for halfword-aligning addresses (clear bottom bit, 32-bit safe)."""

MEMORY_BYTE_OFFSET_MASK: Final[int] = 0x3
"""Mask to extract byte offset within a word (bits [1:0])."""

MEMORY_SIZE_WORDS: Final[int] = 2**14
"""Size of memory in words (16K words = 64KB for 16-bit address space)."""

# ============================================================================
# Register File Configuration
# ============================================================================

NUM_REGISTERS: Final[int] = 32
"""Number of general-purpose registers in RISC-V (x0-x31)."""

REGISTER_WIDTH_BITS: Final[int] = 32
"""Width of each register in bits."""

FIRST_WRITABLE_REGISTER: Final[int] = 1
"""First writable register index (x0 is hardwired to zero)."""

LAST_REGISTER: Final[int] = 31
"""Last register index."""

# ============================================================================
# RISC-V Data Type Masks
# ============================================================================

MASK32: Final[int] = (1 << 32) - 1
"""32-bit mask (0xFFFF_FFFF)."""

MASK33: Final[int] = (1 << 33) - 1
"""33-bit mask (used for extended multiply operations)."""

MASK64: Final[int] = (1 << 64) - 1
"""64-bit mask."""

# ============================================================================
# Alignment Requirements
# ============================================================================

BYTE_ALIGNMENT: Final[int] = 1
"""Byte alignment requirement (always aligned)."""

HALFWORD_ALIGNMENT: Final[int] = 2
"""Halfword alignment requirement (2-byte boundary)."""

WORD_ALIGNMENT: Final[int] = 4
"""Word alignment requirement (4-byte boundary)."""

DOUBLEWORD_ALIGNMENT: Final[int] = 8
"""Doubleword alignment requirement (8-byte boundary)."""

# ============================================================================
# Immediate Field Constraints
# ============================================================================

IMM_12BIT_MIN: Final[int] = -2048
"""Minimum value for 12-bit signed immediate (-2^11)."""

IMM_12BIT_MAX: Final[int] = 2047
"""Maximum value for 12-bit signed immediate (2^11 - 1)."""

IMM_12BIT_MASK: Final[int] = 0xFFF
"""Mask for 12-bit immediate values."""

SHIFT_AMOUNT_BITS: Final[int] = 5
"""Number of bits used for shift amount (5 bits = 0-31)."""

SHIFT_AMOUNT_MASK: Final[int] = 0x1F
"""Mask for shift amount (5 bits)."""

BRANCH_OFFSET_MIN: Final[int] = -4096
"""Minimum branch offset in bytes (-2^12)."""

BRANCH_OFFSET_MAX: Final[int] = 4094
"""Maximum branch offset in bytes (2^12 - 2, must be even)."""

JAL_OFFSET_MIN: Final[int] = -1048576
"""Minimum JAL offset in bytes (-2^20)."""

JAL_OFFSET_MAX: Final[int] = 1048574
"""Maximum JAL offset in bytes (2^20 - 2, must be even)."""

# ============================================================================
# DUT Signal Path Configuration
# ============================================================================


@dataclass
class DUTSignalPaths:
    """Configurable paths to DUT internal signals.

    This allows the testbench to adapt to different DUT hierarchies without
    changing test code. Override these paths if your DUT has a different
    internal structure.

    Path Format:
        Paths are dot-separated strings representing hierarchy traversal.
        Example: "device_under_test.regfile_inst.ram" means
        dut.device_under_test.regfile_inst.ram

    Default Paths:
        These paths match the Frost CPU's default hierarchy. If your DUT
        has different module names or hierarchy, create a custom instance:

        >>> custom_paths = DUTSignalPaths(
        ...     regfile_ram_rs1_path="cpu_core.registers.port_a.data",
        ...     regfile_ram_rs2_path="cpu_core.registers.port_b.data"
        ... )
        >>> dut_if = DUTInterface(dut, signal_paths=custom_paths)
    """

    regfile_ram_rs1_path: str = (
        "device_under_test.regfile_inst.source_register_1_ram.ram"
    )
    """Path to integer register file RAM for rs1 read port."""

    regfile_ram_rs2_path: str = (
        "device_under_test.regfile_inst.source_register_2_ram.ram"
    )
    """Path to integer register file RAM for rs2 read port."""

    fp_regfile_ram_fs1_path: str = (
        "device_under_test.fp_regfile_inst.fp_source_reg_1_ram.ram"
    )
    """Path to FP register file RAM for fs1 read port."""

    fp_regfile_ram_fs2_path: str = (
        "device_under_test.fp_regfile_inst.fp_source_reg_2_ram.ram"
    )
    """Path to FP register file RAM for fs2 read port."""

    fp_regfile_ram_fs3_path: str = (
        "device_under_test.fp_regfile_inst.fp_source_reg_3_ram.ram"
    )
    """Path to FP register file RAM for fs3 read port (for FMA instructions)."""

    data_memory_path: str = "data_memory_for_simulation.memory"
    """Path to data memory array in testbench."""


# ============================================================================
# Test Configuration Defaults
# ============================================================================

DEFAULT_NUM_TEST_LOOPS: Final[int] = 16000
"""Default number of random instructions to generate in tests."""

DEFAULT_MIN_COVERAGE_COUNT: Final[int] = 80
"""Default minimum execution count per instruction for coverage."""

DEFAULT_MEMORY_INIT_SIZE: Final[int] = 0x2000
"""Default size of initialized memory region (8KB)."""

DEFAULT_CLOCK_PERIOD_NS: Final[int] = 3
"""Default clock period in nanoseconds."""

DEFAULT_RESET_CYCLES: Final[int] = 3
"""Default number of clock cycles to hold reset."""

# ============================================================================
# RISC-V ISA Constants
# ============================================================================

XLEN: Final[int] = 32
"""RISC-V XLEN parameter (32 for RV32)."""

# ============================================================================
# Pipeline Configuration
# ============================================================================

PIPELINE_DEPTH: Final[int] = 6
"""Number of pipeline stages (IF-PD-ID-EX-MA-WB)."""

PIPELINE_FLUSH_CYCLES: Final[int] = 3
"""Number of cycles to flush pipeline on branch/jump (instructions before EX)."""

PIPELINE_IF_TO_EX_CYCLES: Final[int] = 3
"""Cycles from instruction fetch to execute stage."""

PIPELINE_IF_TO_MA_CYCLES: Final[int] = 4
"""Cycles from instruction fetch to memory access stage."""

PIPELINE_IF_TO_WB_CYCLES: Final[int] = 5
"""Cycles from instruction fetch to writeback stage."""

# ============================================================================
# Division Edge Cases (RISC-V Spec)
# ============================================================================

DIVISION_OVERFLOW_DIVIDEND: Final[int] = -0x80000000
"""Most negative 32-bit signed integer (triggers overflow with divisor=-1)."""

DIVISION_OVERFLOW_DIVISOR: Final[int] = -1
"""Divisor that causes overflow when dividing most negative number."""

DIVISION_BY_ZERO_QUOTIENT: Final[int] = 0xFFFFFFFF
"""RISC-V spec result for division by zero: -1 (all 1s)."""
