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

"""DUT interface for fp_add_shim verification.

Provides packing/unpacking for rs_issue_t and fu_complete_t structs,
and transaction helpers for driving stimulus and reading results.
"""

import re
from pathlib import Path
from typing import Any

from cocotb.triggers import FallingEdge, RisingEdge

# =============================================================================
# Width constants from riscv_pkg
# =============================================================================
ROB_TAG_WIDTH = 5
XLEN = 32
FLEN = 64

MASK_TAG = (1 << ROB_TAG_WIDTH) - 1  # 0x1F
MASK32 = (1 << XLEN) - 1
MASK64 = (1 << FLEN) - 1

# instr_op_e: typedef enum (no explicit type) -> 32-bit int in SystemVerilog
OP_WIDTH = 32
MASK_OP = (1 << OP_WIDTH) - 1

# rs_type_e: 3 bits
RS_TYPE_WIDTH = 3

# mem_size_e: 2 bits
MEM_SIZE_WIDTH = 2

# exc_cause_t: 5 bits
EXC_CAUSE_WIDTH = 5

# fp_flags_t: 5 bits
FP_FLAGS_WIDTH = 5

# fu_complete_t total width
FU_COMPLETE_WIDTH = FP_FLAGS_WIDTH + EXC_CAUSE_WIDTH + 1 + FLEN + ROB_TAG_WIDTH + 1

# NaN-boxing mask: upper 32 bits all-ones for single-precision in FLEN=64
NAN_BOX_MASK = 0xFFFF_FFFF_0000_0000


# =============================================================================
# Struct Packing/Unpacking
# =============================================================================
# SystemVerilog packed structs are MSB-first (first field at highest bits).
# We pack from LSB to MSB (reverse order of struct declaration).


def pack_rs_issue(
    valid: bool = False,
    rob_tag: int = 0,
    op: int = 0,
    src1_value: int = 0,
    src2_value: int = 0,
    src3_value: int = 0,
    imm: int = 0,
    use_imm: bool = False,
    rm: int = 0,
    branch_target: int = 0,
    predicted_taken: bool = False,
    predicted_target: int = 0,
    is_fp_mem: bool = False,
    mem_size: int = 0,
    mem_signed: bool = False,
    csr_addr: int = 0,
    csr_imm: int = 0,
    pc: int = 0,
) -> int:
    """Pack rs_issue_t fields into a bit vector for driving i_rs_issue.

    rs_issue_t is the ISSUED struct (from RS to FU), NOT rs_dispatch_t.
    It does NOT contain rs_type, src*_tag, or src*_ready fields.

    Field order (LSB to MSB, reverse of struct declaration):
    pc(32) | csr_imm(5) | csr_addr(12) | mem_signed(1) | mem_size(2) |
    is_fp_mem(1) | predicted_target(32) | predicted_taken(1) |
    branch_target(32) | rm(3) | use_imm(1) | imm(32) | src3_value(64) |
    src2_value(64) | src1_value(64) | op(32) | rob_tag(5) | valid(1)
    Total: 384 bits.
    """
    val = 0
    bit = 0

    # Pack from LSB to MSB (reverse of struct declaration order)
    val |= (pc & MASK32) << bit
    bit += XLEN
    val |= (csr_imm & 0x1F) << bit
    bit += 5
    val |= (csr_addr & 0xFFF) << bit
    bit += 12
    val |= (1 if mem_signed else 0) << bit
    bit += 1
    val |= (mem_size & 0x3) << bit
    bit += MEM_SIZE_WIDTH
    val |= (1 if is_fp_mem else 0) << bit
    bit += 1
    val |= (predicted_target & MASK32) << bit
    bit += XLEN
    val |= (1 if predicted_taken else 0) << bit
    bit += 1
    val |= (branch_target & MASK32) << bit
    bit += XLEN
    val |= (rm & 0x7) << bit
    bit += 3
    val |= (1 if use_imm else 0) << bit
    bit += 1
    val |= (imm & MASK32) << bit
    bit += XLEN
    val |= (src3_value & MASK64) << bit
    bit += FLEN
    val |= (src2_value & MASK64) << bit
    bit += FLEN
    val |= (src1_value & MASK64) << bit
    bit += FLEN
    val |= (op & MASK_OP) << bit
    bit += OP_WIDTH
    val |= (rob_tag & MASK_TAG) << bit
    bit += ROB_TAG_WIDTH
    val |= (1 if valid else 0) << bit
    bit += 1

    return val


def unpack_fu_complete(raw: int) -> dict:
    """Unpack a fu_complete_t bit vector into a dict.

    Field order (LSB to MSB):
    fp_flags(5) | exc_cause(5) | exception(1) | value(64) | tag(5) | valid(1)
    """
    bit = 0

    fp_flags = (raw >> bit) & 0x1F
    bit += FP_FLAGS_WIDTH
    exc_cause = (raw >> bit) & 0x1F
    bit += EXC_CAUSE_WIDTH
    exception = bool((raw >> bit) & 1)
    bit += 1
    value = (raw >> bit) & MASK64
    bit += FLEN
    tag = (raw >> bit) & MASK_TAG
    bit += ROB_TAG_WIDTH
    valid = bool((raw >> bit) & 1)

    return {
        "valid": valid,
        "tag": tag,
        "value": value,
        "exception": exception,
        "exc_cause": exc_cause,
        "fp_flags": fp_flags,
    }


# =============================================================================
# IEEE 754 single-precision constants (NaN-boxed in 64-bit FLEN)
# =============================================================================
def nan_box_f32(f32_bits: int) -> int:
    """NaN-box a 32-bit single-precision float into a 64-bit FLEN value.

    Upper 32 bits are set to all-ones per RISC-V NaN-boxing convention.
    """
    return NAN_BOX_MASK | (f32_bits & MASK32)


# =============================================================================
# Parse instr_op_e from riscv_pkg.sv
# =============================================================================


def _parse_instr_op_enum() -> dict[str, int]:
    """Parse the instr_op_e enum from riscv_pkg.sv and return name->value map.

    Handles both implicit sequential values and explicit assignments
    (e.g. ``FOO = 5``, ``BAR = 32'HDEAD_BEEF``).  Raises RuntimeError
    on parse failures so silent mis-numbering cannot occur.
    """
    pkg_path = (
        Path(__file__).resolve().parents[4]
        / "hw"
        / "rtl"
        / "cpu_and_mem"
        / "cpu"
        / "riscv_pkg.sv"
    )
    text = pkg_path.read_text()
    # Extract the enum body between 'typedef enum {' and '} instr_op_e;'
    m = re.search(r"typedef\s+enum\s*\{(.*?)\}\s*instr_op_e\s*;", text, re.DOTALL)
    if not m:
        raise RuntimeError("Could not find instr_op_e enum in riscv_pkg.sv")
    body = m.group(1)
    result: dict[str, int] = {}
    next_val = 0
    for line in body.splitlines():
        line = re.sub(r"//.*", "", line)  # strip comments
        line = re.sub(r"/\*.*?\*/", "", line)  # strip inline /* */
        line = line.strip().rstrip(",")
        if not line:
            continue
        # NAME = VALUE  (explicit assignment)
        # Supports: plain decimal (5), sized (8'd5, 32'hFF), unsized ('hFF),
        # octal (8'o17), binary (4'b1010), with optional _ separators.
        em = re.fullmatch(
            r"([A-Z_][A-Z0-9_]*)\s*=\s*(?:\d*'[bBdDhHoO])?([0-9a-fA-F_]+)",
            line,
        )
        if em:
            digits = em.group(2).replace("_", "")
            base = 10
            # Detect base from the format specifier preceding the digits
            bm = re.search(r"'([bBdDhHoO])", line)
            if bm:
                base = {"b": 2, "d": 10, "h": 16, "o": 8}[bm.group(1).lower()]
            try:
                next_val = int(digits, base)
            except ValueError as exc:
                raise RuntimeError(f"Cannot parse instr_op_e value: {line!r}") from exc
            result[em.group(1)] = next_val
            next_val += 1
            continue
        # NAME  (implicit sequential)
        if re.fullmatch(r"[A-Z_][A-Z0-9_]*", line):
            result[line] = next_val
            next_val += 1
            continue
        # Unrecognised non-blank line inside the enum -- fail loudly
        raise RuntimeError(f"Cannot parse instr_op_e entry: {line!r}")
    if not result:
        raise RuntimeError("instr_op_e enum body is empty")
    return result


# =============================================================================
# DUT Interface Class
# =============================================================================


class FpAddShimInterface:
    """Interface to the fp_add_shim DUT.

    Provides helpers for driving rs_issue_t input, reading fu_complete_t
    output, and controlling flush/reset signals.
    """

    def __init__(self, dut: Any) -> None:
        """Initialize interface with DUT handle."""
        self.dut = dut

    @property
    def clock(self) -> Any:
        """Return clock signal."""
        return self.dut.i_clk

    def _init_inputs(self) -> None:
        """Drive all inputs to zero/inactive after reset."""
        self.dut.i_rs_issue.value = 0
        self.dut.i_flush.value = 0
        self.dut.i_flush_en.value = 0
        self.dut.i_flush_tag.value = 0
        self.dut.i_rob_head_tag.value = 0

    async def reset(self, cycles: int = 3) -> None:
        """Reset the DUT for the given number of cycles.

        Drives all inputs low, asserts reset (active-low), waits, then
        deasserts reset and settles on the falling edge.
        """
        self._init_inputs()
        self.dut.i_rst_n.value = 0

        for _ in range(cycles):
            await RisingEdge(self.clock)

        self.dut.i_rst_n.value = 1
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

    async def step(self) -> None:
        """Advance one cycle: rising edge then falling edge."""
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

    def drive_issue(
        self,
        valid: bool,
        rob_tag: int,
        op: int,
        src1_value: int,
        src2_value: int,
        src3_value: int = 0,
        rm: int = 0,
    ) -> None:
        """Pack and drive an rs_issue_t onto i_rs_issue.

        Sources are marked ready since the shim expects operands to be
        available at issue time.
        """
        packed = pack_rs_issue(
            valid=valid,
            rob_tag=rob_tag,
            op=op,
            src1_value=src1_value,
            src2_value=src2_value,
            src3_value=src3_value,
            rm=rm,
        )
        self.dut.i_rs_issue.value = packed

    def clear_issue(self) -> None:
        """Clear i_rs_issue (drive to zero / invalid)."""
        self.dut.i_rs_issue.value = 0

    def read_fu_complete(self) -> dict:
        """Read and unpack the o_fu_complete output."""
        raw = int(self.dut.o_fu_complete.value)
        return unpack_fu_complete(raw)

    def read_busy(self) -> bool:
        """Read o_fu_busy."""
        return bool(int(self.dut.o_fu_busy.value))

    def drive_flush(self) -> None:
        """Assert i_flush (full pipeline flush)."""
        self.dut.i_flush.value = 1

    def clear_flush(self) -> None:
        """Deassert i_flush."""
        self.dut.i_flush.value = 0

    def drive_partial_flush(self, flush_tag: int, head_tag: int) -> None:
        """Assert i_flush_en with tag and ROB head for age comparison."""
        self.dut.i_flush_en.value = 1
        self.dut.i_flush_tag.value = flush_tag & MASK_TAG
        self.dut.i_rob_head_tag.value = head_tag & MASK_TAG

    def clear_partial_flush(self) -> None:
        """Deassert i_flush_en and clear tag signals."""
        self.dut.i_flush_en.value = 0
        self.dut.i_flush_tag.value = 0
        self.dut.i_rob_head_tag.value = 0
