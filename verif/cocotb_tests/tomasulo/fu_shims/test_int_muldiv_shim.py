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

Tests MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU operations,
divide-by-zero, signed overflow, busy signalling, and full/partial
flush behavior.  MUL has ~4-cycle latency, DIV has ~17-cycle latency,
so tests poll for completion.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from .fp_add_shim_interface import _parse_instr_op_enum
from .int_muldiv_shim_interface import IntMulDivShimInterface

CLOCK_PERIOD_NS = 10

MASK32 = 0xFFFF_FFFF

# Maximum cycles to wait for completion
MAX_LATENCY = 50

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
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    iface = IntMulDivShimInterface(dut)
    await iface.reset()
    return iface


async def wait_for_mul_complete(
    iface: IntMulDivShimInterface, max_cycles: int = MAX_LATENCY
) -> dict:
    """Wait until o_mul_fu_complete.valid is asserted, return the result.

    Raises AssertionError if valid is not seen within max_cycles.
    """
    for _ in range(max_cycles):
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
        result = iface.read_mul_fu_complete()
        if result["valid"]:
            return result
    raise AssertionError(
        f"mul_fu_complete.valid not asserted within {max_cycles} cycles"
    )


async def wait_for_div_complete(
    iface: IntMulDivShimInterface, max_cycles: int = MAX_LATENCY
) -> dict:
    """Wait until o_div_fu_complete.valid is asserted, return the result.

    Raises AssertionError if valid is not seen within max_cycles.
    """
    for _ in range(max_cycles):
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
        result = iface.read_div_fu_complete()
        if result["valid"]:
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
# Test 2: MUL basic (7 * 6 = 42, low 32 bits)
# ============================================================================
@cocotb.test()
async def test_mul_basic(dut: Any) -> None:
    """MUL: 7 * 6 = 42 (low 32 bits of product)."""
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
# Test 3: MULH basic (signed * signed, high 32 bits)
# ============================================================================
@cocotb.test()
async def test_mulh_basic(dut: Any) -> None:
    """MULH: 0x7FFFFFFF * 0x7FFFFFFF, high 32 bits = 0x3FFFFFFF."""
    iface = await setup(dut)

    rob_tag = 2
    src1 = 0x7FFF_FFFF  # 2147483647
    src2 = 0x7FFF_FFFF  # 2147483647
    # Product = 2147483647^2 = 0x3FFFFFFF_00000001
    expected_high = 0x3FFF_FFFF

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
    ), f"Expected 0x{expected_high:08X}, got 0x{result['value']:016X}"


# ============================================================================
# Test 4: MULHSU basic (signed * unsigned, high 32 bits)
# ============================================================================
@cocotb.test()
async def test_mulhsu_basic(dut: Any) -> None:
    """MULHSU: (-1) * 2 unsigned, high 32 bits = 0xFFFFFFFF."""
    iface = await setup(dut)

    rob_tag = 3
    src1 = 0xFFFF_FFFF  # -1 as signed 32-bit
    src2 = 0x0000_0002  # 2 as unsigned
    # Signed(-1) * Unsigned(2) = -2, 64-bit = 0xFFFFFFFF_FFFFFFFE
    expected_high = 0xFFFF_FFFF

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
    ), f"Expected 0x{expected_high:08X}, got 0x{result['value']:016X}"


# ============================================================================
# Test 5: MULHU basic (unsigned * unsigned, high 32 bits)
# ============================================================================
@cocotb.test()
async def test_mulhu_basic(dut: Any) -> None:
    """MULHU: 0xFFFFFFFF * 0xFFFFFFFF, high 32 bits = 0xFFFFFFFE."""
    iface = await setup(dut)

    rob_tag = 4
    src1 = 0xFFFF_FFFF
    src2 = 0xFFFF_FFFF
    # (2^32-1)^2 = 0xFFFFFFFE_00000001
    expected_high = 0xFFFF_FFFE

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
    ), f"Expected 0x{expected_high:08X}, got 0x{result['value']:016X}"


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
    """DIVU: 0xFFFFFFFE / 2 = 0x7FFFFFFF (unsigned divide)."""
    iface = await setup(dut)

    rob_tag = 6
    src1 = 0xFFFF_FFFE  # 4294967294 unsigned
    src2 = 2
    expected = 0x7FFF_FFFF  # 2147483647

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
    ), f"Expected 0x{expected:08X}, got 0x{result['value']:016X}"


# ============================================================================
# Test 8: REM basic (43 % 7 = 1)
# ============================================================================
@cocotb.test()
async def test_rem_basic(dut: Any) -> None:
    """REM: 43 % 7 = 1 (signed remainder)."""
    iface = await setup(dut)

    rob_tag = 7
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("REM"),
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
    assert result["exception"] is False, "unexpected exception"


# ============================================================================
# Test 9: Busy during MUL
# ============================================================================
@cocotb.test()
async def test_busy_during_mul(dut: Any) -> None:
    """After issuing MUL, o_fu_busy=1 while in-flight, 0 after completion."""
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

    # Multiplier is in-flight, busy should be asserted
    assert iface.read_busy(), "busy should be 1 while MUL is in-flight"

    # Wait for completion
    result = await wait_for_mul_complete(iface)
    assert result["valid"], "Expected valid completion"

    # After completion cycle, busy should drop on the next cycle
    await iface.step()
    assert not iface.read_busy(), "busy should be 0 after MUL completion"


# ============================================================================
# Test 10: Busy during DIV
# ============================================================================
@cocotb.test()
async def test_busy_during_div(dut: Any) -> None:
    """After issuing DIV, o_fu_busy=1 while in-flight, 0 after completion."""
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

    # Divider is in-flight, busy should be asserted
    assert iface.read_busy(), "busy should be 1 while DIV is in-flight"

    # Wait for completion
    result = await wait_for_div_complete(iface)
    assert result["valid"], "Expected valid completion"

    # After completion cycle, busy should drop on the next cycle
    await iface.step()
    assert not iface.read_busy(), "busy should be 0 after DIV completion"


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

    # Assert full flush
    iface.drive_flush()
    await RisingEdge(iface.clock)
    iface.clear_flush()
    await FallingEdge(iface.clock)

    # Wait for the multiplier to finish; result should be suppressed
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

    # Let it run a few cycles
    for _ in range(3):
        await RisingEdge(iface.clock)

    # Assert full flush
    iface.drive_flush()
    await RisingEdge(iface.clock)
    iface.clear_flush()
    await FallingEdge(iface.clock)

    # Wait for the divider to finish; result should be suppressed
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
# Test 14: DIV by zero -> quotient = 0xFFFFFFFF
# ============================================================================
@cocotb.test()
async def test_div_by_zero(dut: Any) -> None:
    """DIV: x / 0 = -1 (0xFFFFFFFF) per RISC-V spec."""
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
    assert (
        result["value"] == MASK32
    ), f"DIV by zero should return 0xFFFFFFFF, got 0x{result['value']:08X}"


# ============================================================================
# Test 15: DIVU by zero -> quotient = 0xFFFFFFFF
# ============================================================================
@cocotb.test()
async def test_divu_by_zero(dut: Any) -> None:
    """DIVU: x / 0 = 0xFFFFFFFF per RISC-V spec."""
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
    assert (
        result["value"] == MASK32
    ), f"DIVU by zero should return 0xFFFFFFFF, got 0x{result['value']:08X}"


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
# Test 17: DIV signed overflow (-2^31 / -1 = -2^31)
# ============================================================================
@cocotb.test()
async def test_div_signed_overflow(dut: Any) -> None:
    """DIV: 0x80000000 / 0xFFFFFFFF = 0x80000000 (signed overflow)."""
    iface = await setup(dut)

    rob_tag = 16
    min_int = 0x8000_0000  # -2^31 in signed 32-bit
    neg_one = 0xFFFF_FFFF  # -1 in signed 32-bit

    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("DIV"),
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
        result["value"] == min_int
    ), f"DIV overflow should return 0x80000000, got 0x{result['value']:08X}"


# ============================================================================
# Test 18: REM signed overflow (-2^31 % -1 = 0)
# ============================================================================
@cocotb.test()
async def test_rem_signed_overflow(dut: Any) -> None:
    """REM: 0x80000000 % 0xFFFFFFFF = 0 (signed overflow)."""
    iface = await setup(dut)

    rob_tag = 17
    min_int = 0x8000_0000
    neg_one = 0xFFFF_FFFF

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
    ), f"REM overflow should return 0, got 0x{result['value']:08X}"


# ============================================================================
# Test 19: Partial flush suppresses younger in-flight MUL
# ============================================================================
@cocotb.test()
async def test_partial_flush_suppresses_younger(dut: Any) -> None:
    """Partial flush with flush_tag younger than in-flight op suppresses result."""
    iface = await setup(dut)

    # Issue MUL with rob_tag=10
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

    # Wait for multiplier to finish; result should be suppressed
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

    # Issue MUL with rob_tag=3
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

    # Result should still appear
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

    # Issue DIV with rob_tag=10
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

    # Wait for divider to finish; result should be suppressed
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

    # Issue DIV with rob_tag=3
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

    # Result should still appear
    result = await wait_for_div_complete(iface)
    assert result["valid"], "DIV result should NOT be suppressed (tag is older)"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert result["value"] == 6, f"Expected 6, got {result['value']}"
