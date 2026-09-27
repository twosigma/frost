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

"""Unit tests for the int_muldiv_shim module.

Covers MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU and the word forms,
divide by zero, signed overflow, result acceptance, busy signalling, and full
and partial flushes. Full-width MUL takes 6 cycles and MULW 3 on the word
multiplier. The divider takes one operation at a time and holds its result
until accepted: 64 cycles for DIV and REM, 32 for the word forms. Tests present
a divide only while o_div_busy is low, as MUL_RS's divide gate does.
Mixed-width tests exercise the MUL path's shared completion slots, backpressure,
and flushes at every position. FROST_TEST_SHORT_WORD_OPS=0 selects the
expectations for a DUT built with SHORT_WORD_OPS=0, which runs MULW through the
full-width multiplier.
"""

import os
import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from config import XLEN

from .fp_shim_interface import _parse_instr_op_enum
from .int_muldiv_shim_interface import IntMulDivShimInterface
from models import alu_model

CLOCK_PERIOD_NS = 10

MAX_LATENCY = 80
# Latencies count clock edges from the issue edge to the first cycle the
# result is valid at the shim output.
DIV_LATENCY = XLEN
WORD_DIV_LATENCY = XLEN // 2
SHORT_WORD_OPS = os.environ.get("FROST_TEST_SHORT_WORD_OPS", "1") == "1"
WORD_MUL_LATENCY = 3 if SHORT_WORD_OPS else 6
WORD_LATENCIES = (
    ("MULW", WORD_MUL_LATENCY),
    ("DIVW", WORD_DIV_LATENCY),
    ("REMUW", WORD_DIV_LATENCY),
)

# ---------------------------------------------------------------------------
# Parse instr_op_e from riscv_pkg.sv so op values track the RTL source.
# ---------------------------------------------------------------------------
_INSTR_OPS = _parse_instr_op_enum()


def _op(name: str) -> int:
    """Look up an instr_op_e value by name, raising KeyError on mismatch."""
    return _INSTR_OPS[name]


# ---------------------------------------------------------------------------
# Common helpers
# ---------------------------------------------------------------------------
async def setup(dut: Any) -> IntMulDivShimInterface:
    """Start clock, reset DUT, and return the interface."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    iface = IntMulDivShimInterface(dut)
    await iface.reset()
    return iface


async def wait_for_mul_complete(
    iface: IntMulDivShimInterface, max_cycles: int = MAX_LATENCY
) -> dict:
    """Wait until o_mul_fu_complete.valid is asserted, return the result.

    After capturing a valid result, drives i_mul_accepted for one cycle
    to pop the FIFO entry.

    Raises AssertionError if valid is not seen within max_cycles.
    """
    for _ in range(max_cycles):
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
        result = iface.read_mul_fu_complete()
        if result["valid"]:
            iface.drive_mul_accepted()
            await RisingEdge(iface.clock)
            iface.clear_mul_accepted()
            await FallingEdge(iface.clock)
            return result
    raise AssertionError(
        f"mul_fu_complete.valid not asserted within {max_cycles} cycles"
    )


async def wait_for_div_complete(
    iface: IntMulDivShimInterface, max_cycles: int = MAX_LATENCY
) -> dict:
    """Wait until o_div_fu_complete.valid is asserted, return the result.

    After capturing a valid result, drives i_div_accepted for one cycle
    to take it from the divider.

    Raises AssertionError if valid is not seen within max_cycles.
    """
    for _ in range(max_cycles):
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
        result = iface.read_div_fu_complete()
        if result["valid"]:
            iface.drive_div_accepted()
            await RisingEdge(iface.clock)
            iface.clear_div_accepted()
            await FallingEdge(iface.clock)
            return result
    raise AssertionError(
        f"div_fu_complete.valid not asserted within {max_cycles} cycles"
    )


# ============================================================================
# Test 1: After reset, outputs are idle
# ============================================================================
@cocotb.test()
async def test_reset_state(dut: Any) -> None:
    """After reset: both outputs valid=0, o_fu_busy=0."""
    iface = await setup(dut)

    mul_result = iface.read_mul_fu_complete()
    div_result = iface.read_div_fu_complete()
    assert mul_result["valid"] is False, "mul valid should be 0 after reset"
    assert div_result["valid"] is False, "div valid should be 0 after reset"
    assert iface.read_busy() is False, "busy should be 0 after reset"


# ============================================================================
# Test 2: MUL basic (7 * 6 = 42, low 64 bits)
# ============================================================================
@cocotb.test()
async def test_mul_basic(dut: Any) -> None:
    """MUL: 7 * 6 = 42 (low 64 bits of product)."""
    iface = await setup(dut)

    rob_tag = 1
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("MUL"),
        src1_value=7,
        src2_value=6,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_mul_complete(iface)
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    assert result["value"] == 42, f"Expected 42, got {result['value']}"
    assert result["exception"] is False, "unexpected exception"


# ============================================================================
# Test 3: MULH basic (signed * signed, high 64 bits)
# ============================================================================
@cocotb.test()
async def test_mulh_basic(dut: Any) -> None:
    """MULH: INT64_MIN * INT64_MAX has high half 0xC000000000000000."""
    iface = await setup(dut)

    rob_tag = 2
    src1 = 0x8000_0000_0000_0000  # INT64_MIN
    src2 = 0x7FFF_FFFF_FFFF_FFFF  # INT64_MAX
    expected_high = 0xC000_0000_0000_0000

    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("MULH"),
        src1_value=src1,
        src2_value=src2,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_mul_complete(iface)
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    assert result["value"] == expected_high, (
        f"Expected 0x{expected_high:016X}, got 0x{result['value']:016X}"
    )


# ============================================================================
# Test 4: MULHSU basic (signed * unsigned, high 64 bits)
# ============================================================================
@cocotb.test()
async def test_mulhsu_basic(dut: Any) -> None:
    """MULHSU: INT64_MIN times a large unsigned value has a mixed high half."""
    iface = await setup(dut)

    rob_tag = 3
    src1 = 0x8000_0000_0000_0000  # INT64_MIN
    src2 = 0xFEDC_BA98_7654_3210
    expected_high = 0x8091_A2B3_C4D5_E6F8

    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("MULHSU"),
        src1_value=src1,
        src2_value=src2,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_mul_complete(iface)
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    assert result["value"] == expected_high, (
        f"Expected 0x{expected_high:016X}, got 0x{result['value']:016X}"
    )


# ============================================================================
# Test 5: MULHU basic (unsigned * unsigned, high 64 bits)
# ============================================================================
@cocotb.test()
async def test_mulhu_basic(dut: Any) -> None:
    """MULHU: UINT64_MAX squared has high half 0xFFFFFFFFFFFFFFFE."""
    iface = await setup(dut)

    rob_tag = 4
    src1 = 0xFFFF_FFFF_FFFF_FFFF
    src2 = 0xFFFF_FFFF_FFFF_FFFF
    expected_high = 0xFFFF_FFFF_FFFF_FFFE

    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("MULHU"),
        src1_value=src1,
        src2_value=src2,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_mul_complete(iface)
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    assert result["value"] == expected_high, (
        f"Expected 0x{expected_high:016X}, got 0x{result['value']:016X}"
    )


# ============================================================================
# Test 6: DIV basic (42 / 7 = 6)
# ============================================================================
@cocotb.test()
async def test_div_basic(dut: Any) -> None:
    """DIV: 42 / 7 = 6 (signed divide)."""
    iface = await setup(dut)

    rob_tag = 5
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("DIV"),
        src1_value=42,
        src2_value=7,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_div_complete(iface)
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    assert result["value"] == 6, f"Expected 6, got {result['value']}"
    assert result["exception"] is False, "unexpected exception"


# ============================================================================
# Test 7: DIVU basic (unsigned divide)
# ============================================================================
@cocotb.test()
async def test_divu_basic(dut: Any) -> None:
    """DIVU: UINT64_MAX - 1 divided by 2 equals INT64_MAX."""
    iface = await setup(dut)

    rob_tag = 6
    src1 = 0xFFFF_FFFF_FFFF_FFFE
    src2 = 2
    expected = alu_model.divu(src1, src2)

    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("DIVU"),
        src1_value=src1,
        src2_value=src2,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_div_complete(iface)
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    assert result["value"] == expected, (
        f"Expected 0x{expected:016X}, got 0x{result['value']:016X}"
    )


# ============================================================================
# Test 8: REM with a negative dividend (-43 % 7 = -1)
# ============================================================================
@cocotb.test()
async def test_rem_basic(dut: Any) -> None:
    """REM: -43 % 7 = -1, with the remainder following the dividend sign."""
    iface = await setup(dut)

    rob_tag = 7
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("REM"),
        src1_value=0xFFFF_FFFF_FFFF_FFD5,
        src2_value=7,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_div_complete(iface)
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    expected = 0xFFFF_FFFF_FFFF_FFFF
    assert result["value"] == expected, (
        f"Expected 0x{expected:016X}, got 0x{result['value']:016X}"
    )
    assert result["exception"] is False, "unexpected exception"


# ============================================================================
# Test 9: Single MUL does not assert busy (credit-based)
# ============================================================================
@cocotb.test()
async def test_single_mul_not_busy(dut: Any) -> None:
    """After issuing one MUL, o_fu_busy=0 (FIFO has room for more)."""
    iface = await setup(dut)

    assert not iface.read_busy(), "busy should be 0 before issue"

    iface.drive_issue(
        valid=True,
        rob_tag=8,
        op=_op("MUL"),
        src1_value=7,
        src2_value=6,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()
    await FallingEdge(iface.clock)

    # Busy is credit/backpressure based; one in-flight MUL still leaves space.
    assert not iface.read_busy(), "busy should be 0 with one MUL in-flight"

    result = await wait_for_mul_complete(iface)
    assert result["valid"], "Expected valid completion"

    # Busy stays low the cycle after completion as well.
    await iface.step()
    assert not iface.read_busy(), "busy should still be 0 after MUL completion"


# ============================================================================
# Test 10: A DIV raises o_div_busy until its result is taken, never o_fu_busy
# ============================================================================
@cocotb.test()
async def test_single_div_busy(dut: Any) -> None:
    """o_div_busy is high from the DIV's issue until its result is taken.

    o_fu_busy, the multiplier's back-pressure, stays low throughout.
    """
    iface = await setup(dut)

    assert not iface.read_busy() and not iface.read_div_busy()

    iface.drive_issue(
        valid=True,
        rob_tag=9,
        op=_op("DIV"),
        src1_value=42,
        src2_value=7,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()
    await FallingEdge(iface.clock)

    for _ in range(DIV_LATENCY):
        assert iface.read_div_busy(), "o_div_busy should be high while dividing"
        assert not iface.read_busy(), "a DIV must not raise o_fu_busy"
        assert not iface.read_div_fu_complete()["valid"]
        await iface.step()

    result = iface.read_div_fu_complete()
    assert result["valid"] and result["value"] == 6, result
    assert iface.read_div_busy(), "o_div_busy should stay high while the result waits"
    iface.drive_div_accepted()
    await iface.step()
    iface.clear_div_accepted()
    assert not iface.read_div_busy(), "o_div_busy should drop once the result is taken"
    assert not iface.read_div_fu_complete()["valid"]


# ============================================================================
# Test 11: Flush clears in-flight MUL
# ============================================================================
@cocotb.test()
async def test_flush_clears_mul(dut: Any) -> None:
    """Full flush during MUL in-flight: result suppressed (valid=0)."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=10,
        op=_op("MUL"),
        src1_value=7,
        src2_value=6,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    iface.drive_flush()
    await RisingEdge(iface.clock)
    iface.clear_flush()
    await FallingEdge(iface.clock)

    for _ in range(MAX_LATENCY):
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
        result = iface.read_mul_fu_complete()
        assert result["valid"] is False, "MUL result should be suppressed after flush"


# ============================================================================
# Test 12: Flush clears in-flight DIV
# ============================================================================
@cocotb.test()
async def test_flush_clears_div(dut: Any) -> None:
    """Full flush during DIV in-flight: result suppressed (valid=0)."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=11,
        op=_op("DIV"),
        src1_value=42,
        src2_value=7,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    # Flush while the divider is mid-operation rather than on the issue cycle.
    for _ in range(3):
        await RisingEdge(iface.clock)

    iface.drive_flush()
    await RisingEdge(iface.clock)
    iface.clear_flush()
    await FallingEdge(iface.clock)

    for _ in range(MAX_LATENCY):
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
        result = iface.read_div_fu_complete()
        assert result["valid"] is False, "DIV result should be suppressed after flush"


# ============================================================================
# Test 13: REMU basic (unsigned remainder)
# ============================================================================
@cocotb.test()
async def test_remu_basic(dut: Any) -> None:
    """REMU: 43 % 7 = 1 (unsigned remainder)."""
    iface = await setup(dut)

    rob_tag = 12
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("REMU"),
        src1_value=43,
        src2_value=7,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_div_complete(iface)
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    assert result["value"] == 1, f"Expected 1, got {result['value']}"


# ============================================================================
# Test 14: DIV by zero -> quotient = all ones
# ============================================================================
@cocotb.test()
async def test_div_by_zero(dut: Any) -> None:
    """DIV: x / 0 = -1 (all 64 bits set) per RISC-V spec."""
    iface = await setup(dut)

    rob_tag = 13
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("DIV"),
        src1_value=42,
        src2_value=0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_div_complete(iface)
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    assert result["value"] == alu_model.div(42, 0), (
        f"DIV by zero should return all ones, got 0x{result['value']:016X}"
    )


# ============================================================================
# Test 15: DIVU by zero -> quotient = all ones
# ============================================================================
@cocotb.test()
async def test_divu_by_zero(dut: Any) -> None:
    """DIVU: x / 0 returns all 64 bits set per RISC-V spec."""
    iface = await setup(dut)

    rob_tag = 14
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("DIVU"),
        src1_value=100,
        src2_value=0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_div_complete(iface)
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    assert result["value"] == alu_model.divu(100, 0), (
        f"DIVU by zero should return all ones, got 0x{result['value']:016X}"
    )


# ============================================================================
# Test 16: REM by zero -> remainder = dividend
# ============================================================================
@cocotb.test()
async def test_rem_by_zero(dut: Any) -> None:
    """REM: x % 0 = x per RISC-V spec."""
    iface = await setup(dut)

    rob_tag = 15
    dividend = 123
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("REM"),
        src1_value=dividend,
        src2_value=0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_div_complete(iface)
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    assert result["value"] == dividend, (
        f"REM by zero should return dividend ({dividend}), got {result['value']}"
    )


# ============================================================================
# Test 16b: REM by zero with a negative dividend -> remainder = dividend
# (sign must be preserved; a divider that returns |dividend| is wrong)
# ============================================================================
@cocotb.test()
async def test_rem_by_zero_negative_dividend(dut: Any) -> None:
    """REM: (-x) % 0 = -x per RISC-V spec (sign preserved)."""
    iface = await setup(dut)

    rob_tag = 14
    dividend = 0xAAAA_AAAA_AAAA_AAAA  # Negative because RV64 sign bit is set
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("REM"),
        src1_value=dividend,
        src2_value=0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_div_complete(iface)
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    assert result["value"] == dividend, (
        f"REM by zero should return 0x{dividend:016X}, got 0x{result['value']:016X}"
    )


# ============================================================================
# Test 17: Signed DIV with a negative dividend truncates toward zero
# ============================================================================
@cocotb.test()
async def test_div_negative_dividend(dut: Any) -> None:
    """DIV: -100 / 7 = -14, truncating toward zero."""
    iface = await setup(dut)

    rob_tag = 16
    dividend = 0xFFFF_FFFF_FFFF_FF9C  # -100
    divisor = 7

    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("DIV"),
        src1_value=dividend,
        src2_value=divisor,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_div_complete(iface)
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    expected = 0xFFFF_FFFF_FFFF_FFF2  # -14
    assert result["value"] == expected, (
        f"Expected 0x{expected:016X}, got 0x{result['value']:016X}"
    )


# ============================================================================
# Test 18: REM signed overflow (INT64_MIN % -1 = 0)
# ============================================================================
@cocotb.test()
async def test_rem_signed_overflow(dut: Any) -> None:
    """REM: INT64_MIN % -1 = 0 in the signed overflow case."""
    iface = await setup(dut)

    rob_tag = 17
    min_int = 0x8000_0000_0000_0000
    neg_one = 0xFFFF_FFFF_FFFF_FFFF

    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("REM"),
        src1_value=min_int,
        src2_value=neg_one,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_div_complete(iface)
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    assert result["value"] == 0, (
        f"REM overflow should return 0, got 0x{result['value']:016X}"
    )


# ============================================================================
# Test 19: Partial flush suppresses younger in-flight MUL
# ============================================================================
@cocotb.test()
async def test_partial_flush_suppresses_younger(dut: Any) -> None:
    """A partial flush suppresses an in-flight MUL younger than the flush tag."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=10,
        op=_op("MUL"),
        src1_value=7,
        src2_value=6,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    # Partial flush: flush_tag=5, head=0 -> tag 10 is younger than 5, gets flushed
    iface.drive_partial_flush(flush_tag=5, head_tag=0)
    await RisingEdge(iface.clock)
    iface.clear_partial_flush()
    await FallingEdge(iface.clock)

    for _ in range(MAX_LATENCY):
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
        result = iface.read_mul_fu_complete()
        assert result["valid"] is False, (
            "MUL result should be suppressed after partial flush of younger tag"
        )


# ============================================================================
# Test 20: Partial flush keeps older in-flight MUL
# ============================================================================
@cocotb.test()
async def test_partial_flush_keeps_older(dut: Any) -> None:
    """A partial flush keeps an in-flight MUL older than the flush tag."""
    iface = await setup(dut)

    rob_tag = 3
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("MUL"),
        src1_value=7,
        src2_value=6,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    # Partial flush: flush_tag=10, head=0 -> tag 3 is older than 10, not flushed
    iface.drive_partial_flush(flush_tag=10, head_tag=0)
    await RisingEdge(iface.clock)
    iface.clear_partial_flush()

    result = await wait_for_mul_complete(iface)
    assert result["valid"], "MUL result should NOT be suppressed (tag is older)"
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    assert result["value"] == 42, f"Expected 42, got {result['value']}"


# ============================================================================
# Test 21: Partial flush suppresses younger in-flight DIV
# ============================================================================
@cocotb.test()
async def test_partial_flush_suppresses_younger_div(dut: Any) -> None:
    """A partial flush suppresses an in-flight DIV younger than the flush tag."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=10,
        op=_op("DIV"),
        src1_value=42,
        src2_value=7,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    # Partial flush: flush_tag=5, head=0 -> tag 10 is younger than 5, gets flushed
    iface.drive_partial_flush(flush_tag=5, head_tag=0)
    await RisingEdge(iface.clock)
    iface.clear_partial_flush()
    await FallingEdge(iface.clock)

    for _ in range(MAX_LATENCY):
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
        result = iface.read_div_fu_complete()
        assert result["valid"] is False, (
            "DIV result should be suppressed after partial flush of younger tag"
        )


# ============================================================================
# Test 22: Partial flush keeps older in-flight DIV
# ============================================================================
@cocotb.test()
async def test_partial_flush_keeps_older_div(dut: Any) -> None:
    """A partial flush keeps an in-flight DIV older than the flush tag."""
    iface = await setup(dut)

    rob_tag = 3
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("DIV"),
        src1_value=42,
        src2_value=7,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    # Partial flush: flush_tag=10, head=0 -> tag 3 is older than 10, not flushed
    iface.drive_partial_flush(flush_tag=10, head_tag=0)
    await RisingEdge(iface.clock)
    iface.clear_partial_flush()

    result = await wait_for_div_complete(iface)
    assert result["valid"], "DIV result should NOT be suppressed (tag is older)"
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    assert result["value"] == 6, f"Expected 6, got {result['value']}"


# ============================================================================
# Test 23: Back-to-back MUL results advance through the accepted handshake
# ============================================================================
@cocotb.test()
async def test_back_to_back_mul_acceptance(dut: Any) -> None:
    """Accepting the first of two queued MULs exposes the second result."""
    iface = await setup(dut)

    test_cases = [
        {"rob_tag": 1, "lhs": 6, "rhs": 7, "expected": 42},
        {"rob_tag": 2, "lhs": 8, "rhs": 9, "expected": 72},
    ]
    for tc in test_cases:
        iface.drive_issue(
            valid=True,
            rob_tag=tc["rob_tag"],
            op=_op("MUL"),
            src1_value=tc["lhs"],
            src2_value=tc["rhs"],
        )
        await RisingEdge(iface.clock)
    iface.clear_issue()

    for tc in test_cases:
        result = await wait_for_mul_complete(iface)
        assert result["tag"] == tc["rob_tag"], (
            f"tag mismatch: got {result['tag']}, expected {tc['rob_tag']}"
        )
        assert result["value"] == tc["expected"], (
            f"value mismatch: got {result['value']}, expected {tc['expected']}"
        )


# ============================================================================
# Test 24: Back-to-back DIVs (each issued as soon as the divider is free)
# ============================================================================
@cocotb.test()
async def test_back_to_back_div(dut: Any) -> None:
    """Each DIV issues in the first cycle o_div_busy is low; all four results are right.

    The result is taken in its first valid cycle, so the divider is free again
    on the next cycle.
    """
    iface = await setup(dut)

    # (rob_tag, op, dividend, divisor, expected)
    test_cases = [
        (1, "DIV", 100, 10, 10),
        (2, "DIVUW", 200, 10, 20),
        (3, "REM", 305, 10, 5),
        (4, "DIVU", 400, 10, 40),
    ]

    for rob_tag, op, dividend, divisor, expected in test_cases:
        assert not iface.read_div_busy()
        iface.drive_issue(
            valid=True,
            rob_tag=rob_tag,
            op=_op(op),
            src1_value=dividend,
            src2_value=divisor,
        )
        await iface.step()
        iface.clear_issue()
        latency = WORD_DIV_LATENCY if op.endswith("W") else DIV_LATENCY
        for _ in range(latency):
            assert not iface.read_div_fu_complete()["valid"]
            await iface.step()
        result = iface.read_div_fu_complete()
        assert result["valid"], f"tag {rob_tag}: no result at its latency"
        assert result["tag"] == rob_tag, (
            f"tag mismatch: got {result['tag']}, expected {rob_tag}"
        )
        assert result["value"] == expected, (
            f"Expected {expected}, got {result['value']} for tag {rob_tag}"
        )
        iface.drive_div_accepted()
        await iface.step()
        iface.clear_div_accepted()


# ============================================================================
# Test 25: MUL during in-flight DIV (both complete correctly)
# ============================================================================
@cocotb.test()
async def test_mul_during_inflight_div(dut: Any) -> None:
    """Issue DIV then MUL on the next cycle; both complete correctly."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=1,
        op=_op("DIV"),
        src1_value=42,
        src2_value=7,
    )
    await RisingEdge(iface.clock)

    iface.drive_issue(
        valid=True,
        rob_tag=2,
        op=_op("MUL"),
        src1_value=7,
        src2_value=6,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    # MUL should complete first (MulPipeDepth is 6 at XLEN=64).
    mul_result = await wait_for_mul_complete(iface)
    assert mul_result["tag"] == 2, f"MUL tag mismatch: got {mul_result['tag']}"
    assert mul_result["value"] == 42, f"MUL expected 42, got {mul_result['value']}"

    # DIV completes later (64 cycles at XLEN=64).
    div_result = await wait_for_div_complete(iface)
    assert div_result["tag"] == 1, f"DIV tag mismatch: got {div_result['tag']}"
    assert div_result["value"] == 6, f"DIV expected 6, got {div_result['value']}"


# ============================================================================
# Test 26: A full flush frees the divider for the next DIV
# ============================================================================
@cocotb.test()
async def test_flush_frees_divider(dut: Any) -> None:
    """A full flush mid-divide frees the divider on the next cycle.

    A DIV reusing the flushed tag then completes with its own result only.
    """
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=3,
        op=_op("DIV"),
        src1_value=30,
        src2_value=3,
    )
    await iface.step()
    iface.clear_issue()
    for _ in range(10):
        await iface.step()

    iface.drive_flush()
    await iface.step()
    iface.clear_flush()
    assert not iface.read_div_busy(), "the flush should free the divider"

    iface.drive_issue(
        valid=True,
        rob_tag=3,
        op=_op("DIVU"),
        src1_value=90,
        src2_value=9,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()
    result = await wait_for_div_complete(iface)
    assert (result["tag"], result["value"]) == (3, 10), result
    for _ in range(MAX_LATENCY):
        await iface.step()
        assert not iface.read_div_fu_complete()["valid"], "a flushed DIV completed"


# ============================================================================
# Test 27: Partial flush age compare across ROB-tag wraparound
# ============================================================================
@cocotb.test()
async def test_partial_flush_mixed_ages(dut: Any) -> None:
    """A partial flush kills a running DIV only if it is younger than the flush tag.

    Ages are measured from the ROB head, including across tag wraparound.
    """
    iface = await setup(dut)

    # (tag, head, flush_tag, survives)
    cases = [(2, 0, 5, True), (8, 0, 5, False), (1, 30, 3, True), (31, 30, 30, False)]
    for tag, head, flush_tag, survives in cases:
        iface.drive_issue(
            valid=True,
            rob_tag=tag,
            op=_op("DIV"),
            src1_value=100,
            src2_value=10,
        )
        await iface.step()
        iface.clear_issue()
        for _ in range(5):
            await iface.step()
        iface.drive_partial_flush(flush_tag=flush_tag, head_tag=head)
        await iface.step()
        iface.clear_partial_flush()
        assert iface.read_div_busy() == survives, (tag, head, flush_tag)
        if survives:
            result = await wait_for_div_complete(iface)
            assert (result["tag"], result["value"]) == (tag, 10), result
        for _ in range(MAX_LATENCY):
            await iface.step()
            assert not iface.read_div_fu_complete()["valid"], (tag, "completed twice")


# ============================================================================
# Test 28: A held DIV result blocks only divides, never multiplies
# ============================================================================
@cocotb.test()
async def test_held_div_result_does_not_block_mul(dut: Any) -> None:
    """An untaken DIV result stays valid and stable while MULs issue and complete."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=4,
        op=_op("REMU"),
        src1_value=47,
        src2_value=10,
    )
    await iface.step()
    iface.clear_issue()
    for _ in range(DIV_LATENCY):
        await iface.step()
    held = iface.read_div_fu_complete()
    assert held["valid"] and (held["tag"], held["value"]) == (4, 7), held

    # MULs keep issuing, as fast as their credits allow, while the result waits.
    received = []
    issued = 0
    for _ in range(48):
        assert iface.read_div_fu_complete() == held, "the held result changed"
        assert iface.read_div_busy()
        result = iface.read_mul_fu_complete()
        if result["valid"]:
            received.append(result["tag"])
            assert result["value"] == 3 * result["tag"], result
            iface.drive_mul_accepted()
        else:
            iface.clear_mul_accepted()
        if issued < 12 and not iface.read_busy():
            iface.drive_issue(True, 10 + issued, _op("MUL"), 10 + issued, 3)
            issued += 1
        else:
            iface.clear_issue()
        await iface.step()
    iface.clear_mul_accepted()
    assert received == list(range(10, 22)), received

    iface.drive_div_accepted()
    await iface.step()
    iface.clear_div_accepted()
    assert not iface.read_div_busy()


# ============================================================================
# Test 29: Partial flush on the divider's last step
# ============================================================================
@cocotb.test()
async def test_partial_flush_at_completion(dut: Any) -> None:
    """A partial flush on the edge that would end a younger DIV's last step drops it."""
    iface = await setup(dut)

    # Issue a DIV with a younger tag (tag=10, head=0)
    iface.drive_issue(
        valid=True,
        rob_tag=10,
        op=_op("DIV"),
        src1_value=42,
        src2_value=7,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    # These edges run all steps but the last.
    for _ in range(DIV_LATENCY - 1):
        await RisingEdge(iface.clock)

    # The partial flush is sampled on the edge that would make the result valid.
    # flush_tag=5, head=0  =>  tag 10 is younger, should be squashed.
    iface.drive_partial_flush(flush_tag=5, head_tag=0)
    await RisingEdge(iface.clock)
    iface.clear_partial_flush()
    await FallingEdge(iface.clock)
    assert not iface.read_div_busy()

    for _ in range(MAX_LATENCY):
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
        result = iface.read_div_fu_complete()
        assert result["valid"] is False, (
            "DIV result should be suppressed when partial flush "
            "coincides with divider completion"
        )


# ============================================================================
# Test 30: Partial flush of a held DIV result
# ============================================================================
@cocotb.test()
async def test_partial_flush_held_result(dut: Any) -> None:
    """A partial flush drops a younger held result from the next cycle on.

    On the flush cycle itself the adapter's own partial-flush check drops the result.
    """
    iface = await setup(dut)

    # Issue a DIV with tag=10 (younger than flush_tag=5 when head=0)
    iface.drive_issue(
        valid=True,
        rob_tag=10,
        op=_op("DIV"),
        src1_value=42,
        src2_value=7,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = None
    for _ in range(MAX_LATENCY):
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
        result = iface.read_div_fu_complete()
        if result["valid"]:
            break

    assert result is not None and result["valid"], (
        "DIV result should appear before flush"
    )

    # Do not take it (no i_div_accepted); the divider holds the result.
    # Partial-flush with flush_tag=5, head=0 => tag 10 is younger.
    iface.drive_partial_flush(flush_tag=5, head_tag=0)
    await RisingEdge(iface.clock)
    iface.clear_partial_flush()
    await FallingEdge(iface.clock)

    result = iface.read_div_fu_complete()
    assert result["valid"] is False, (
        "held result should be dropped after partial flush of younger tag"
    )
    assert not iface.read_div_busy(), "the flush should free the divider"

    for _ in range(5):
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
        result = iface.read_div_fu_complete()
        assert result["valid"] is False, "Flushed result should stay dropped"


# ============================================================================
# RV64 vectors: word forms and 64-bit corner cases.
# ============================================================================
async def _check_muldiv_op(
    dut: Any, op_name: str, src1: int, src2: int, expected: int, is_div: bool
) -> None:
    """Drive one op and wait for its completion on the multiplier or divider port."""
    iface = await setup(dut)
    iface.drive_issue(
        valid=True, rob_tag=9, op=_op(op_name), src1_value=src1, src2_value=src2
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()
    if is_div:
        result = await wait_for_div_complete(iface)
    else:
        result = await wait_for_mul_complete(iface)
    assert result["value"] == expected, (
        f"{op_name}: expected 0x{expected:X}, got 0x{result['value']:X}"
    )


@cocotb.test()
async def test_rv64_mulw_wrap(dut: Any) -> None:
    """MULW wraps at 32 bits and sign-extends (high operand bits ignored)."""
    a, b = 0xFFFF_FFFF_0001_0000, 0x0001_0001
    await _check_muldiv_op(dut, "MULW", a, b, alu_model.mulw(a, b), is_div=False)


@cocotb.test()
async def test_rv64_mul_full64(dut: Any) -> None:
    """64-bit MUL carries across bit 32."""
    a, b = 0x1_0000_0001, 0x1_0000_0001
    await _check_muldiv_op(dut, "MUL", a, b, alu_model.mul(a, b), is_div=False)


@cocotb.test()
async def test_rv64_mulh_64(dut: Any) -> None:
    """MULH returns the high 64 bits of the 128-bit signed product."""
    a = 0x7FFF_FFFF_FFFF_FFFF
    b = 0x7FFF_FFFF_FFFF_FFFF
    await _check_muldiv_op(dut, "MULH", a, b, alu_model.mulh(a, b), is_div=False)


@cocotb.test()
async def test_rv64_divw_overflow(dut: Any) -> None:
    """DIVW INT32_MIN / -1 returns sext32(INT32_MIN)."""
    a, b = 0x8000_0000, 0xFFFF_FFFF
    await _check_muldiv_op(dut, "DIVW", a, b, alu_model.divw(a, b), is_div=True)


@cocotb.test()
async def test_rv64_divuw_by_zero(dut: Any) -> None:
    """DIVUW by zero returns all-ones (sext32 of 2^32-1)."""
    await _check_muldiv_op(dut, "DIVUW", 5, 0, alu_model.divuw(5, 0), is_div=True)


@cocotb.test()
async def test_rv64_remw_negative(dut: Any) -> None:
    """REMW follows the dividend sign at word width."""
    a, b = 0xFFFF_FFF9, 5  # -7 rem 5 = -2
    await _check_muldiv_op(dut, "REMW", a, b, alu_model.remw(a, b), is_div=True)


@cocotb.test()
async def test_rv64_remuw_high_ignored(dut: Any) -> None:
    """REMUW ignores the operands' high words."""
    a, b = 0xDEAD_BEEF_0000_0007, 0x5555_5555_0000_0003
    await _check_muldiv_op(dut, "REMUW", a, b, alu_model.remuw(a, b), is_div=True)


@cocotb.test()
async def test_rv64_div64_overflow(dut: Any) -> None:
    """64-bit DIV INT64_MIN / -1 overflow case."""
    a = 0x8000_0000_0000_0000
    b = 0xFFFF_FFFF_FFFF_FFFF
    await _check_muldiv_op(dut, "DIV", a, b, alu_model.div(a, b), is_div=True)


@cocotb.test()
async def test_word_latency_and_hold(dut: Any) -> None:
    """Word results arrive at the selected latency and stay stable until accepted."""
    iface = await setup(dut)
    for name, latency in WORD_LATENCIES:
        await iface.reset()
        a, b = 0x1234_5678_8000_0003, 0xDEAD_BEEF_FFFF_FFFE
        expected = getattr(alu_model, name.lower())(a, b)
        read = (
            iface.read_mul_fu_complete if name == "MULW" else iface.read_div_fu_complete
        )
        iface.drive_issue(True, 7, _op(name), a, b)
        await iface.step()
        iface.clear_issue()
        assert not read()["valid"]
        for elapsed in range(1, latency + 1):
            await iface.step()
            result = read()
            assert result["valid"] == (elapsed == latency), (name, elapsed, result)
        assert (result["tag"], result["value"]) == (7, expected)
        for _ in range(8):
            await iface.step()
            assert read() == result
        if name == "MULW":
            iface.drive_mul_accepted()
        else:
            iface.drive_div_accepted()
        await iface.step()
        assert not read()["valid"]


@cocotb.test()
async def test_word_completion_slot_collision(dut: Any) -> None:
    """A MULW waits only when it shares a full-width multiply's completion cycle."""
    iface = await setup(dut)
    for full, word, gap in (("MULH", "MULW", 3),):
        await iface.reset()
        a, b = 0xFFFF_FFFF_8000_0005, 0x1234_5678_0000_0003
        read = iface.read_mul_fu_complete
        iface.drive_issue(True, 1, _op(full), a, b)
        await iface.step()
        iface.clear_issue()
        for _ in range(gap - 1):
            await iface.step()
        # The RS holds its registered opcode even when ready masks valid.
        iface.drive_issue(False, 2, _op(word), a, b)
        await Timer(1, unit="ns")
        assert iface.read_busy() == SHORT_WORD_OPS, (
            full,
            word,
            "wrong collision stall",
        )
        await iface.step()
        assert not iface.read_busy(), (full, word, "collision did not clear")
        iface.drive_issue(True, 2, _op(word), a, b)
        await iface.step()
        iface.clear_issue()
        received = []
        for _ in range(MAX_LATENCY):
            result = read()
            if result["valid"]:
                name = full if result["tag"] == 1 else word
                assert result["value"] == getattr(alu_model, name.lower())(a, b)
                received.append(result["tag"])
                iface.drive_mul_accepted()
            else:
                iface.clear_mul_accepted()
            await iface.step()
        assert received == [1, 2], (full, word, received)


@cocotb.test()
async def test_mixed_word_full_random_backpressure(dut: Any) -> None:
    """Random mixed-width ops match the model under random back-pressure.

    Each op completes exactly once, on its own port, with the model's value.
    Until every op has issued, each presented result is accepted with probability 1/4.
    A divide issues only while o_div_busy is low, as MUL_RS's divide gate ensures.
    """
    iface = await setup(dut)
    rng = random.Random(0x6432)
    names = (
        "MUL",
        "MULH",
        "MULHSU",
        "MULHU",
        "MULW",
        "DIV",
        "DIVU",
        "REM",
        "REMU",
        "DIVW",
        "DIVUW",
        "REMW",
        "REMUW",
    )
    corners = (0, 1, 0xFFFF_FFFF, 0x8000_0000, (1 << 64) - 1, 1 << 63)
    for _batch in range(24):
        expected: dict[int, tuple[bool, int]] = {}
        pending = []
        for tag in range(16):
            name = rng.choice(names)
            a, b = (
                rng.choice(corners) if rng.randrange(3) == 0 else rng.getrandbits(64)
                for _ in range(2)
            )
            pending.append((tag, name, a, b))
        for cycle in range(4000):
            iface.clear_mul_accepted()
            iface.clear_div_accepted()
            for is_mul, read, accept in (
                (True, iface.read_mul_fu_complete, iface.drive_mul_accepted),
                (False, iface.read_div_fu_complete, iface.drive_div_accepted),
            ):
                result = read()
                if result["valid"]:
                    tag = result["tag"]
                    assert tag in expected, ("duplicate or unissued", result)
                    assert (is_mul, result["value"]) == expected[tag], (tag, result)
                    if rng.randrange(4) == 0 or not pending:
                        del expected[tag]
                        accept()
            iface.clear_issue()
            if pending:
                tag, name, a, b = pending[0]
                iface.drive_issue(False, tag, _op(name), a, b)
                await Timer(1, unit="ns")
                is_div = name.startswith(("DIV", "REM"))
                if not iface.read_busy() and not (is_div and iface.read_div_busy()):
                    expected[tag] = (
                        name.startswith("MUL"),
                        getattr(alu_model, name.lower())(a, b),
                    )
                    iface.drive_issue(True, tag, _op(name), a, b)
                    pending.pop(0)
            await iface.step()
            if not expected and not pending:
                break
        else:
            raise AssertionError(("lost completion", pending, expected, cycle))
        iface.clear_mul_accepted()
        iface.clear_div_accepted()
        for _ in range(MAX_LATENCY):
            await iface.step()
            assert not iface.read_mul_fu_complete()["valid"]
            assert not iface.read_div_fu_complete()["valid"]


@cocotb.test()
async def test_word_flush_every_pipeline_position(dut: Any) -> None:
    """Kill a word operation on its issue cycle, in flight, as it completes, or held."""
    iface = await setup(dut)
    for name, latency in WORD_LATENCIES:
        for full_flush in (False, True):
            for flush_delay in range(latency + 3):
                await iface.reset()
                iface.drive_issue(True, 10, _op(name), 0xDEAD_BEEF_8000_0000, 3)
                if flush_delay:
                    await iface.step()
                    iface.clear_issue()
                    for _ in range(flush_delay - 1):
                        await iface.step()
                if full_flush:
                    iface.drive_flush()
                else:
                    iface.drive_partial_flush(flush_tag=5, head_tag=0)
                await iface.step()
                iface.clear_issue()
                iface.clear_flush()
                iface.clear_partial_flush()
                for _ in range(MAX_LATENCY):
                    assert not iface.read_mul_fu_complete()["valid"]
                    assert not iface.read_div_fu_complete()["valid"]
                    await iface.step()
                assert not iface.read_busy() and not iface.read_div_busy()
