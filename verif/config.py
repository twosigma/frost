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

"""Shared verification constants and DUT signal-path configuration.

Sections, in file order: memory, register file, data type masks, alignment,
immediate fields, DUT signal paths, test defaults, ISA constants, pipeline
offsets, and division edge cases.

Usage::

    >>> from config import MASK32, IMM_12BIT_MIN, IMM_12BIT_MAX
    >>> result = (value + immediate) & MASK32
    >>> if not (IMM_12BIT_MIN <= imm <= IMM_12BIT_MAX):
    ...     raise ValueError("Immediate out of range")

    >>> from config import DUTSignalPaths
    >>> custom_paths = DUTSignalPaths(regfile_ram_rs1_path="my.path.here")

Retargeting the framework to another DUT means changing three things:
MEMORY_ADDRESS_WIDTH for a different address space, DUTSignalPaths for a
different hierarchy, and the DEFAULT_* constants for test length, memory
init size, coverage floor, clock period, and reset length.
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

MEMORY_SIZE_WORDS: Final[int] = 2**14
"""Size of memory in words (16K words = 64KB for 16-bit address space)."""

# ----------------------------------------------------------------------------
# Data-tier beat contract (hw/rtl/README.md, "Data-tier bus contract"): every
# data-side bus carries the aligned dword at addr[31:3] with 8 byte-lane
# strobes. Store data is replicated across the beat and the strobes select the
# lanes.
# ----------------------------------------------------------------------------

MEM_DATA_BITS: Final[int] = 64
"""Data-tier beat width in bits (mirrors riscv_pkg::MemDataBits)."""

MEM_STRB_BITS: Final[int] = MEM_DATA_BITS // 8
"""Byte-lane strobe count per beat (mirrors riscv_pkg::MemStrbBits)."""

MEMORY_DWORD_ALIGN_MASK: Final[int] = 0xFFFFFFF8
"""Mask for dword-aligning addresses (clear bottom 3 bits, 32-bit safe)."""

MEMORY_BEAT_OFFSET_MASK: Final[int] = 0x7
"""Mask to extract the byte offset within a beat (bits [2:0])."""

MEMORY_SIZE_DWORDS: Final[int] = MEMORY_SIZE_WORDS // 2
"""Size of memory in dword rows (the simulation data BRAM's row count)."""

MMIO_BASE_ADDR: Final[int] = 0x40000000
"""Base address of MMIO peripheral range (UART, CLINT timer, etc.)."""

# ============================================================================
# Register File Configuration
# ============================================================================

NUM_REGISTERS: Final[int] = 32
"""Number of general-purpose registers in RISC-V (x0-x31)."""

FIRST_WRITABLE_REGISTER: Final[int] = 1
"""First writable register index (x0 is hardwired to zero)."""

LAST_REGISTER: Final[int] = 31
"""Last register index."""

# ============================================================================
# RISC-V Data Type Masks
# ============================================================================

MASK32: Final[int] = (1 << 32) - 1
"""32-bit mask (0xFFFF_FFFF)."""

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

SHIFT_AMOUNT_BITS: Final[int] = 6
"""Number of bits in a base shift amount (6 at XLEN=64)."""

SHIFT_AMOUNT_MASK: Final[int] = (1 << SHIFT_AMOUNT_BITS) - 1
"""Mask for a base shift amount (0x3F at XLEN=64)."""

SHIFT_AMOUNT_MASK_W: Final[int] = 0x1F
"""Mask for RV64 W-form shift amounts (always 5 bits)."""

BRANCH_OFFSET_MIN: Final[int] = -4096
"""Minimum branch offset in bytes (-2^12)."""

BRANCH_OFFSET_MAX: Final[int] = 4094
"""Maximum branch offset in bytes (2^12 - 2, must be even)."""

JAL_OFFSET_MIN: Final[int] = -1048576
"""Minimum JAL offset in bytes (-2^20)."""

JAL_OFFSET_MAX: Final[int] = 1048574
"""Maximum JAL offset in bytes (2^20 - 2, must be even)."""

STORE_OP_WIDTH: Final[int] = 3
"""Packed width of riscv_pkg::store_op_e (grew STD for RV64 SD in M2)."""

INSTR_OP_WIDTH: Final[int] = 8
"""Packed width of riscv_pkg::instr_op_e (live ordinals through 206; 86/87 reserved)."""

# ============================================================================
# DUT Signal Path Configuration
# ============================================================================


@dataclass
class DUTSignalPaths:
    """Configurable paths to DUT internal signals.

    Tests reach DUT internals through these paths, so a different hierarchy
    only needs a new DUTSignalPaths instance; test code stays the same.

    A path is a dot-separated hierarchy traversal. For instance
    "device_under_test.ooo_register_files_inst.regfile_inst" resolves to
    dut.device_under_test.ooo_register_files_inst.regfile_inst.

    The defaults point at the cpu_ooo architectural register files under
    ``ooo_register_files_inst``; ROB commit writes them. Each generic_regfile
    read port owns a RAM inside a ``gen_multi_write`` scope
    (mwp_dist_ram: one bank per commit write port plus a per-address
    live-value table), so a committed register value has to be read through
    the LVT. Call ``cocotb_tests.test_helpers.read_port_ram_entry`` instead
    of indexing the handle. For different module names or hierarchy, build a
    custom instance:

        >>> custom_paths = DUTSignalPaths(
        ...     regfile_ram_rs1_path="cpu_core.registers.port_a.data",
        ...     regfile_ram_rs2_path="cpu_core.registers.port_b.data"
        ... )
        >>> dut_if = DUTInterface(dut, signal_paths=custom_paths)
    """

    regfile_ram_rs1_path: str = (
        "device_under_test.ooo_register_files_inst.regfile_inst"
        ".gen_read_port[0].gen_multi_write.read_port_ram"
    )
    """Path to the integer register file read-port-0 RAM (banked, LVT-steered)."""

    regfile_ram_rs2_path: str = (
        "device_under_test.ooo_register_files_inst.regfile_inst"
        ".gen_read_port[1].gen_multi_write.read_port_ram"
    )
    """Path to the integer register file read-port-1 RAM (banked, LVT-steered)."""

    fp_regfile_ram_fs1_path: str = (
        "device_under_test.ooo_register_files_inst.fp_regfile_inst"
        ".gen_read_port[0].gen_multi_write.read_port_ram"
    )
    """Path to the FP register file read-port-0 RAM (banked, LVT-steered)."""

    fp_regfile_ram_fs2_path: str = (
        "device_under_test.ooo_register_files_inst.fp_regfile_inst"
        ".gen_read_port[1].gen_multi_write.read_port_ram"
    )
    """Path to the FP register file read-port-1 RAM (banked, LVT-steered)."""

    fp_regfile_ram_fs3_path: str = (
        "device_under_test.ooo_register_files_inst.fp_regfile_inst"
        ".gen_read_port[2].gen_multi_write.read_port_ram"
    )
    """Path to the FP register file read-port-2 RAM (banked, LVT-steered)."""

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

XLEN: Final[int] = 64
"""RISC-V XLEN parameter.

Single source of truth for the verification side, matching riscv_pkg's
XLEN localparam (the core is RV64-only; rv32 support was retired after
Phase 1). Every cocotb
interface/model imports XLEN/FLEN from here rather than keeping a
private copy.
"""

MASK_XLEN: Final[int] = (1 << XLEN) - 1
"""All-ones mask at XLEN (MASK64)."""

FLEN: Final[int] = 64
"""FP register width (FLEN): 64 for the D extension."""

NOP_INSTRUCTION: Final[int] = 0x00000013
"""32-bit NOP encoding (addi x0, x0, 0)."""

# ============================================================================
# Pipeline Configuration
# ============================================================================

PIPELINE_DEPTH: Final[int] = 6
"""Warmup/drain cycles used by the CPU cocotb monitor alignment model."""

PIPELINE_FLUSH_CYCLES: Final[int] = 3
"""Branch/jump recovery padding cycles used by the random-instruction model."""

PIPELINE_IF_TO_EX_CYCLES: Final[int] = 3
"""Monitor offset from fetch to branch/CSR resolution."""

PIPELINE_IF_TO_MA_CYCLES: Final[int] = 4
"""Monitor offset from fetch to memory-observation point."""

PIPELINE_IF_TO_WB_CYCLES: Final[int] = 5
"""Monitor offset from fetch to architectural writeback observation."""

# ============================================================================
# Division Edge Cases (RISC-V Spec)
# ============================================================================

DIVISION_OVERFLOW_DIVIDEND: Final[int] = -(1 << (XLEN - 1))
"""Most negative XLEN-bit signed integer (triggers overflow with divisor=-1)."""

DIVISION_OVERFLOW_DIVISOR: Final[int] = -1
"""Divisor that causes overflow when dividing most negative number."""

DIVISION_BY_ZERO_QUOTIENT: Final[int] = (1 << XLEN) - 1
"""RISC-V spec result for division by zero: -1 (all 1s at XLEN)."""
