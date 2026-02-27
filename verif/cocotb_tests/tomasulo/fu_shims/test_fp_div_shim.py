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

"""Unit tests for the FP Divide/Sqrt Shim.

Tests FDIV_S, FSQRT_S operations, busy signalling, and flush behaviour.
The div/sqrt unit has long latency (~32 cycles), so tests poll for up to
50 cycles waiting for completion.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from .fp_div_shim_interface import (
    FpDivShimInterface,
    CLOCK_PERIOD_NS,
    OP_FDIV_S,
    OP_FSQRT_S,
)

# IEEE 754 single-precision constants (NaN-boxed in 64-bit)
NAN_BOX = 0xFFFF_FFFF_0000_0000
SP_2_0 = NAN_BOX | 0x4000_0000  # 2.0f
SP_3_0 = NAN_BOX | 0x4040_0000  # 3.0f
SP_4_0 = NAN_BOX | 0x4080_0000  # 4.0f
SP_6_0 = NAN_BOX | 0x40C0_0000  # 6.0f

# Expected NaN-boxed results
EXPECTED_3_0 = 0xFFFF_FFFF_4040_0000  # 6.0 / 2.0 = 3.0
EXPECTED_2_0 = 0xFFFF_FFFF_4000_0000  # sqrt(4.0) = 2.0

MAX_LATENCY = 50


async def setup(dut: Any) -> FpDivShimInterface:
    """Start clock, reset DUT, and return interface."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    iface = FpDivShimInterface(dut)
    await iface.reset()
    return iface


async def wait_for_completion(
    iface: FpDivShimInterface, max_cycles: int = MAX_LATENCY
) -> dict:
    """Poll o_fu_complete.valid for up to *max_cycles*, return the result dict.

    Raises AssertionError if the operation does not complete in time.
    """
    for _ in range(max_cycles):
        await RisingEdge(iface.clock)
        result = iface.read_fu_complete()
        if result["valid"]:
            return result
    raise AssertionError(
        f"FU did not produce a valid result within {max_cycles} cycles"
    )


# ============================================================================
# Test 1: After reset, valid=0 and busy=0
# ============================================================================
@cocotb.test()
async def test_reset_state(dut: Any) -> None:
    """After reset: o_fu_complete.valid=0, o_fu_busy=0."""
    iface = await setup(dut)

    result = iface.read_fu_complete()
    assert not result["valid"], "valid should be 0 after reset"
    assert not iface.read_busy(), "busy should be 0 after reset"


# ============================================================================
# Test 2: FDIV_S basic — 6.0 / 2.0 = 3.0
# ============================================================================
@cocotb.test()
async def test_fdiv_s_basic(dut: Any) -> None:
    """FDIV_S: 6.0 / 2.0 = 3.0 (NaN-boxed single-precision result)."""
    iface = await setup(dut)

    rob_tag = 1
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=OP_FDIV_S,
        src1_value=SP_6_0,
        src2_value=SP_2_0,
    )

    # Deassert issue after one cycle so the shim only fires once
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_completion(iface)
    assert result["valid"], "Expected valid completion"
    assert (
        result["tag"] == rob_tag
    ), f"Tag mismatch: expected {rob_tag}, got {result['tag']}"
    assert (
        result["value"] == EXPECTED_3_0
    ), f"Value mismatch: expected 0x{EXPECTED_3_0:016X}, got 0x{result['value']:016X}"


# ============================================================================
# Test 3: FSQRT_S basic — sqrt(4.0) = 2.0
# ============================================================================
@cocotb.test()
async def test_fsqrt_s_basic(dut: Any) -> None:
    """FSQRT_S: sqrt(4.0) = 2.0 (NaN-boxed single-precision result)."""
    iface = await setup(dut)

    rob_tag = 5
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=OP_FSQRT_S,
        src1_value=SP_4_0,
        src2_value=0,
    )

    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_completion(iface)
    assert result["valid"], "Expected valid completion"
    assert (
        result["tag"] == rob_tag
    ), f"Tag mismatch: expected {rob_tag}, got {result['tag']}"
    assert (
        result["value"] == EXPECTED_2_0
    ), f"Value mismatch: expected 0x{EXPECTED_2_0:016X}, got 0x{result['value']:016X}"


# ============================================================================
# Test 4: Busy during operation — busy=1 while in-flight, 0 after completion
# ============================================================================
@cocotb.test()
async def test_busy_during_operation(dut: Any) -> None:
    """Fire FDIV_S, verify busy=1 while in-flight, busy=0 after completion."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=2,
        op=OP_FDIV_S,
        src1_value=SP_6_0,
        src2_value=SP_2_0,
    )

    await RisingEdge(iface.clock)
    iface.clear_issue()

    # After fire, busy should be asserted
    await RisingEdge(iface.clock)
    assert iface.read_busy(), "Expected busy=1 while operation is in-flight"

    # Wait for completion
    result = await wait_for_completion(iface)
    assert result["valid"], "Expected valid completion"

    # After the completing cycle, busy should drop
    await RisingEdge(iface.clock)
    assert not iface.read_busy(), "Expected busy=0 after operation completed"


# ============================================================================
# Test 5: Flush clears in-flight — no valid output after full flush
# ============================================================================
@cocotb.test()
async def test_flush_clears_inflight(dut: Any) -> None:
    """Fire FDIV_S, assert i_flush after a few cycles, verify no valid output."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=3,
        op=OP_FDIV_S,
        src1_value=SP_6_0,
        src2_value=SP_2_0,
    )

    await RisingEdge(iface.clock)
    iface.clear_issue()

    # Let the operation run for a few cycles
    for _ in range(3):
        await RisingEdge(iface.clock)

    # Assert full flush
    iface.drive_flush()
    await RisingEdge(iface.clock)
    iface.clear_flush()

    # Wait for the remaining latency; the result should be suppressed
    for _ in range(MAX_LATENCY):
        await RisingEdge(iface.clock)
        result = iface.read_fu_complete()
        assert not result[
            "valid"
        ], "Expected no valid output after flush, but got valid=1"
