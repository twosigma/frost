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

Covers MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU, divide-by-zero,
signed overflow, result acceptance, busy signalling, and full/partial flush
behavior. MUL has the configured ``riscv_pkg::MulPipeDepth`` latency (6 cycles
currently); DIV latency is XLEN/2 + 1 cycles (33 currently), so tests poll for
completion.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from config import XLEN

from .fp_add_shim_interface import _parse_instr_op_enum
from .int_muldiv_shim_interface import IntMulDivShimInterface
from models import alu_model

CLOCK_PERIOD_NS = 10

MAX_LATENCY = 50
DIV_PIPELINE_LATENCY = XLEN // 2 + 1

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
    to pop the FIFO entry.

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
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
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
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert (
        result["value"] == expected_high
    ), f"Expected 0x{expected_high:016X}, got 0x{result['value']:016X}"


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
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert (
        result["value"] == expected_high
    ), f"Expected 0x{expected_high:016X}, got 0x{result['value']:016X}"


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
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert (
        result["value"] == expected_high
    ), f"Expected 0x{expected_high:016X}, got 0x{result['value']:016X}"


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
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
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
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert (
        result["value"] == expected
    ), f"Expected 0x{expected:016X}, got 0x{result['value']:016X}"


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
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    expected = 0xFFFF_FFFF_FFFF_FFFF
    assert (
        result["value"] == expected
    ), f"Expected 0x{expected:016X}, got 0x{result['value']:016X}"
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
# Test 10: Single DIV does not assert busy (pipelined, credit-based)
# ============================================================================
@cocotb.test()
async def test_single_div_not_busy(dut: Any) -> None:
    """After issuing one DIV, o_fu_busy=0 (FIFO has room for more)."""
    iface = await setup(dut)

    assert not iface.read_busy(), "busy should be 0 before issue"

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

    # The divider is pipelined, so one in-flight DIV does not assert busy.
    assert not iface.read_busy(), "busy should be 0 with one DIV in-flight"

    result = await wait_for_div_complete(iface)
    assert result["valid"], "Expected valid completion"
    assert result["value"] == 6, f"Expected 6, got {result['value']}"


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
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
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
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert result["value"] == alu_model.div(
        42, 0
    ), f"DIV by zero should return all ones, got 0x{result['value']:016X}"


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
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert result["value"] == alu_model.divu(
        100, 0
    ), f"DIVU by zero should return all ones, got 0x{result['value']:016X}"


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
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert (
        result["value"] == dividend
    ), f"REM by zero should return dividend ({dividend}), got {result['value']}"


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
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert (
        result["value"] == dividend
    ), f"REM by zero should return 0x{dividend:016X}, got 0x{result['value']:016X}"


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
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    expected = 0xFFFF_FFFF_FFFF_FFF2  # -14
    assert (
        result["value"] == expected
    ), f"Expected 0x{expected:016X}, got 0x{result['value']:016X}"


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
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert (
        result["value"] == 0
    ), f"REM overflow should return 0, got 0x{result['value']:016X}"


# ============================================================================
# Test 19: Partial flush suppresses younger in-flight MUL
# ============================================================================
@cocotb.test()
async def test_partial_flush_suppresses_younger(dut: Any) -> None:
    """Partial flush with flush_tag younger than in-flight op suppresses result."""
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
        assert (
            result["valid"] is False
        ), "MUL result should be suppressed after partial flush of younger tag"


# ============================================================================
# Test 20: Partial flush keeps older in-flight MUL
# ============================================================================
@cocotb.test()
async def test_partial_flush_keeps_older(dut: Any) -> None:
    """Partial flush with flush_tag older than in-flight op keeps result."""
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
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert result["value"] == 42, f"Expected 42, got {result['value']}"


# ============================================================================
# Test 21: Partial flush suppresses younger in-flight DIV
# ============================================================================
@cocotb.test()
async def test_partial_flush_suppresses_younger_div(dut: Any) -> None:
    """Partial flush with flush_tag younger than in-flight DIV suppresses result."""
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
        assert (
            result["valid"] is False
        ), "DIV result should be suppressed after partial flush of younger tag"


# ============================================================================
# Test 22: Partial flush keeps older in-flight DIV
# ============================================================================
@cocotb.test()
async def test_partial_flush_keeps_older_div(dut: Any) -> None:
    """Partial flush with flush_tag older than in-flight DIV keeps result."""
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
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
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
        assert (
            result["tag"] == tc["rob_tag"]
        ), f"tag mismatch: got {result['tag']}, expected {tc['rob_tag']}"
        assert (
            result["value"] == tc["expected"]
        ), f"value mismatch: got {result['value']}, expected {tc['expected']}"


# ============================================================================
# Test 24: Back-to-back DIV issue (4 divides on consecutive cycles)
# ============================================================================
@cocotb.test()
async def test_back_to_back_div(dut: Any) -> None:
    """Issue 4 DIVs on consecutive cycles; all 4 produce correct results."""
    iface = await setup(dut)

    test_cases = [
        {"rob_tag": 1, "dividend": 100, "divisor": 10, "expected": 10},
        {"rob_tag": 2, "dividend": 200, "divisor": 10, "expected": 20},
        {"rob_tag": 3, "dividend": 300, "divisor": 10, "expected": 30},
        {"rob_tag": 4, "dividend": 400, "divisor": 10, "expected": 40},
    ]

    for tc in test_cases:
        iface.drive_issue(
            valid=True,
            rob_tag=tc["rob_tag"],
            op=_op("DIV"),
            src1_value=tc["dividend"],
            src2_value=tc["divisor"],
        )
        await RisingEdge(iface.clock)

    iface.clear_issue()
    await FallingEdge(iface.clock)

    # Collect all 4 results in order
    for tc in test_cases:
        result = await wait_for_div_complete(iface)
        assert (
            result["tag"] == tc["rob_tag"]
        ), f"tag mismatch: got {result['tag']}, expected {tc['rob_tag']}"
        assert (
            result["value"] == tc["expected"]
        ), f"Expected {tc['expected']}, got {result['value']} for tag {tc['rob_tag']}"


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

    # DIV should complete later (33 cycles at XLEN=64).
    div_result = await wait_for_div_complete(iface)
    assert div_result["tag"] == 1, f"DIV tag mismatch: got {div_result['tag']}"
    assert div_result["value"] == 6, f"DIV expected 6, got {div_result['value']}"


# ============================================================================
# Test 26: Full flush with multiple in-flight divides
# ============================================================================
@cocotb.test()
async def test_flush_multiple_inflight_divs(dut: Any) -> None:
    """Issue 3 DIVs, full flush, verify all suppressed."""
    iface = await setup(dut)

    for tag in range(1, 4):
        iface.drive_issue(
            valid=True,
            rob_tag=tag,
            op=_op("DIV"),
            src1_value=tag * 10,
            src2_value=tag,
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
        result = iface.read_div_fu_complete()
        assert (
            result["valid"] is False
        ), "All DIV results should be suppressed after flush"


# ============================================================================
# Test 27: Partial flush with mixed ages
# ============================================================================
@cocotb.test()
async def test_partial_flush_mixed_ages(dut: Any) -> None:
    """Issue divides with varying tags, partial flush hits younger ones only."""
    iface = await setup(dut)

    # Issue 3 DIVs with tags 2, 8, 12 (head=0)
    # Partial flush at tag=5 -> tag 8 and 12 are younger, tag 2 is older
    tags = [2, 8, 12]
    dividends = [100, 200, 300]
    divisors = [10, 10, 10]

    for i in range(3):
        iface.drive_issue(
            valid=True,
            rob_tag=tags[i],
            op=_op("DIV"),
            src1_value=dividends[i],
            src2_value=divisors[i],
        )
        await RisingEdge(iface.clock)

    iface.clear_issue()

    iface.drive_partial_flush(flush_tag=5, head_tag=0)
    await RisingEdge(iface.clock)
    iface.clear_partial_flush()

    # Only tag 2 (100/10=10) should produce a valid result
    result = await wait_for_div_complete(iface)
    assert result["tag"] == 2, f"Expected tag 2, got {result['tag']}"
    assert result["value"] == 10, f"Expected 10, got {result['value']}"

    for _ in range(MAX_LATENCY):
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
        result = iface.read_div_fu_complete()
        assert result["valid"] is False, "Younger DIV results should be suppressed"


# ============================================================================
# Test 28: FIFO backpressure (4 divides without popping -> busy)
# ============================================================================
@cocotb.test()
async def test_fifo_backpressure(dut: Any) -> None:
    """Issue 4 DIVs; once all 4 are in-flight, busy should assert."""
    iface = await setup(dut)

    for tag in range(1, 5):
        iface.drive_issue(
            valid=True,
            rob_tag=tag,
            op=_op("DIV"),
            src1_value=tag * 10,
            src2_value=tag,
        )
        await RisingEdge(iface.clock)

    iface.clear_issue()
    await FallingEdge(iface.clock)

    assert (
        iface.read_busy()
    ), "busy should be 1 with 4 DIVs in-flight (FIFO_DEPTH reached)"

    result = await wait_for_div_complete(iface)
    assert result["valid"], "Expected valid completion"
    await FallingEdge(iface.clock)

    # After popping one, inflight + fifo < FIFO_DEPTH, busy should drop
    assert not iface.read_busy(), "busy should be 0 after popping one result"


# ============================================================================
# Test 29: Partial flush on same cycle as DIV completion suppresses result
# ============================================================================
@cocotb.test()
async def test_partial_flush_at_completion(dut: Any) -> None:
    """Partial flush arriving on the same cycle the divider completes.

    Must suppress the result (not leak it into the FIFO).
    """
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

    # Wait until one cycle before the divider output is expected. One edge was
    # consumed above; the flush edge below is the final latency cycle.
    for _ in range(DIV_PIPELINE_LATENCY - 2):
        await RisingEdge(iface.clock)

    # Assert the partial flush on the same cycle the tail valid goes high.
    # flush_tag=5, head=0  =>  tag 10 is younger, should be squashed.
    iface.drive_partial_flush(flush_tag=5, head_tag=0)
    await RisingEdge(iface.clock)
    iface.clear_partial_flush()
    await FallingEdge(iface.clock)

    for _ in range(MAX_LATENCY):
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
        result = iface.read_div_fu_complete()
        assert result["valid"] is False, (
            "DIV result should be suppressed when partial flush "
            "coincides with divider completion"
        )


# ============================================================================
# Test 30: Partial flush suppresses FIFO head presented to adapter
# ============================================================================
@cocotb.test()
async def test_partial_flush_fifo_head(dut: Any) -> None:
    """Partial flush must suppress a valid FIFO head on the same cycle.

    Prevents the adapter from latching a younger result.
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

    assert (
        result is not None and result["valid"]
    ), "DIV result should appear before flush"

    # Do not pop (no i_div_accepted); the result sits at the FIFO head.
    # Partial-flush with flush_tag=5, head=0 => tag 10 is younger.
    iface.drive_partial_flush(flush_tag=5, head_tag=0)
    await RisingEdge(iface.clock)
    iface.clear_partial_flush()
    await FallingEdge(iface.clock)

    # The FIFO head should now be suppressed (auto-drained as flushed).
    result = iface.read_div_fu_complete()
    assert (
        result["valid"] is False
    ), "FIFO head should be suppressed after partial flush of younger tag"

    for _ in range(5):
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
        result = iface.read_div_fu_complete()
        assert result["valid"] is False, "Flushed FIFO entry should remain suppressed"


# ============================================================================
# RV64 W-form vectors (M3 rung 2).
# ============================================================================
async def _check_muldiv_op(
    dut: Any, op_name: str, src1: int, src2: int, expected: int, is_div: bool
) -> None:
    """Drive one op and wait for its completion via the appropriate FIFO."""
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
    assert (
        result["value"] == expected
    ), f"{op_name}: expected 0x{expected:X}, got 0x{result['value']:X}"


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
