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

The shim runs one operation at a time on the iterative divide/sqrt unit: 36
cycles at single precision, 65 at double, plus one cycle into the result
register. These tests cover the arithmetic hand-off, the exact completion
cycle, the credit gate (busy while the unit is occupied or a result is
waiting), and the full and partial flush cases at every point an operation can
sit: launching, iterating, and held as a result.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from .fp_div_shim_interface import (
    FpDivShimInterface,
    CLOCK_PERIOD_NS,
    OP_FDIV_S,
    OP_FDIV_D,
    OP_FSQRT_S,
    OP_FSQRT_D,
)

# IEEE 754 single-precision constants (NaN-boxed in 64-bit)
NAN_BOX = 0xFFFF_FFFF_0000_0000
SP_1_0 = NAN_BOX | 0x3F80_0000  # 1.0f
SP_2_0 = NAN_BOX | 0x4000_0000  # 2.0f
SP_3_0 = NAN_BOX | 0x4040_0000  # 3.0f
SP_4_0 = NAN_BOX | 0x4080_0000  # 4.0f
SP_6_0 = NAN_BOX | 0x40C0_0000  # 6.0f
SP_9_0 = NAN_BOX | 0x4110_0000  # 9.0f
SP_ZERO = NAN_BOX | 0x0000_0000  # +0.0f

# IEEE 754 double-precision constants
DP_1_0 = 0x3FF0_0000_0000_0000  # 1.0
DP_2_0 = 0x4000_0000_0000_0000  # 2.0
DP_3_0 = 0x4008_0000_0000_0000  # 3.0
DP_6_0 = 0x4018_0000_0000_0000  # 6.0
DP_9_0 = 0x4022_0000_0000_0000  # 9.0
DP_16_0 = 0x4030_0000_0000_0000  # 16.0
DP_25_0 = 0x4039_0000_0000_0000  # 25.0
DP_NEG_1_0 = 0xBFF0_0000_0000_0000  # -1.0
DP_MIN_SUBNORMAL = 0x0000_0000_0000_0001  # 2^-1074

# Expected results
EXPECTED_3_0_SP = 0xFFFF_FFFF_4040_0000  # 6.0 / 2.0 = 3.0 (SP, NaN-boxed)
EXPECTED_2_0_SP = 0xFFFF_FFFF_4000_0000  # sqrt(4.0) = 2.0 (SP, NaN-boxed)
EXPECTED_3_0_SP_SQRT = 0xFFFF_FFFF_4040_0000  # sqrt(9.0) = 3.0 (SP, NaN-boxed)
EXPECTED_INF_SP = 0xFFFF_FFFF_7F80_0000  # 1.0 / 0.0 = +inf (SP, NaN-boxed)
EXPECTED_THIRD_RNE_SP = 0xFFFF_FFFF_3EAA_AAAB  # 1.0f / 3.0f, round to nearest
EXPECTED_THIRD_RTZ_SP = 0xFFFF_FFFF_3EAA_AAAA  # 1.0f / 3.0f, round toward zero
EXPECTED_3_0_DP = 0x4008_0000_0000_0000  # 6.0 / 2.0 = 3.0 (DP)
EXPECTED_4_0_DP = 0x4010_0000_0000_0000  # sqrt(16.0) = 4.0 (DP)
EXPECTED_5_0_DP = 0x4014_0000_0000_0000  # sqrt(25.0) = 5.0 (DP)
EXPECTED_QNAN_DP = 0x7FF8_0000_0000_0000
EXPECTED_SQRT_MIN_SUBNORMAL_DP = 0x1E60_0000_0000_0000  # 2^-537

FP_FLAG_NV = 0x10
FP_FLAG_DZ = 0x08
FP_FLAG_NX = 0x01

# Unit latency plus the shim's result register: the first cycle after issue on
# which o_fu_complete can be valid.
SP_VISIBLE_CYCLES = 36
DP_VISIBLE_CYCLES = 65

MAX_LATENCY = 80  # DP takes 65 cycles, allow margin

RM_RNE = 0
RM_RTZ = 1


async def setup(dut: Any) -> FpDivShimInterface:
    """Start clock, reset DUT, and return interface."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    iface = FpDivShimInterface(dut)
    await iface.reset()
    return iface


async def issue(
    iface: FpDivShimInterface,
    rob_tag: int,
    op: int,
    src1_value: int,
    src2_value: int = 0,
    rm: int = RM_RNE,
) -> None:
    """Drive one issue for a single cycle. The shim must not be busy.

    Driving from the falling edge keeps the busy read clear of the edge the
    shim samples on.
    """
    await FallingEdge(iface.clock)
    assert not iface.read_busy(), "issue driven while the shim is busy"
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=op,
        src1_value=src1_value,
        src2_value=src2_value,
        rm=rm,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()


async def wait_until_idle(
    iface: FpDivShimInterface, max_cycles: int = MAX_LATENCY * 2
) -> None:
    """Wait for o_fu_busy to fall."""
    for _ in range(max_cycles):
        if not iface.read_busy():
            return
        await RisingEdge(iface.clock)
    raise AssertionError(f"shim stayed busy for {max_cycles} cycles")


async def wait_for_completion(
    iface: FpDivShimInterface, max_cycles: int = MAX_LATENCY
) -> dict:
    """Poll o_fu_complete.valid, drive i_div_accepted to pop, return result."""
    for _ in range(max_cycles):
        await RisingEdge(iface.clock)
        result = iface.read_fu_complete()
        if result["valid"]:
            iface.drive_div_accepted()
            await RisingEdge(iface.clock)
            iface.clear_div_accepted()
            return result
    raise AssertionError(
        f"FU did not produce a valid result within {max_cycles} cycles"
    )


async def run_one(
    iface: FpDivShimInterface,
    rob_tag: int,
    op: int,
    src1_value: int,
    src2_value: int = 0,
    rm: int = RM_RNE,
) -> dict:
    """Issue one operation and return its completion."""
    await issue(iface, rob_tag, op, src1_value, src2_value, rm)
    return await wait_for_completion(iface)


async def expect_completion_at_cycle(
    iface: FpDivShimInterface,
    expected_cycle: int,
    expected_tag: int,
    expected_value: int,
    expected_flags: int = 0,
) -> None:
    """Require the first shim-visible completion on one exact post-issue cycle."""
    result = {}
    for cycle in range(1, expected_cycle + 1):
        await RisingEdge(iface.clock)
        await ReadOnly()
        result = iface.read_fu_complete()
        if cycle < expected_cycle:
            assert not result["valid"], (
                f"Completion appeared at cycle {cycle}, expected cycle "
                f"{expected_cycle}"
            )

    assert result["valid"], f"No completion at expected cycle {expected_cycle}"
    assert (
        result["tag"] == expected_tag
    ), f"Tag mismatch: expected {expected_tag}, got {result['tag']}"
    assert result["value"] == expected_value, (
        f"Value mismatch: expected 0x{expected_value:016X}, "
        f"got 0x{result['value']:016X}"
    )
    assert result["fp_flags"] == expected_flags, (
        f"Flags mismatch: expected 0x{expected_flags:02X}, "
        f"got 0x{result['fp_flags']:02X}"
    )

    await FallingEdge(iface.clock)
    iface.drive_div_accepted()
    await RisingEdge(iface.clock)
    iface.clear_div_accepted()


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
# Test 2: FDIV_S basic: 6.0 / 2.0 = 3.0
# ============================================================================
@cocotb.test()
async def test_fdiv_s_basic(dut: Any) -> None:
    """FDIV_S: 6.0 / 2.0 = 3.0 (NaN-boxed single-precision result)."""
    iface = await setup(dut)

    result = await run_one(iface, 1, OP_FDIV_S, SP_6_0, SP_2_0)
    assert result["tag"] == 1, f"Tag mismatch: expected 1, got {result['tag']}"
    assert result["value"] == EXPECTED_3_0_SP, (
        f"Value mismatch: expected 0x{EXPECTED_3_0_SP:016X}, "
        f"got 0x{result['value']:016X}"
    )
    assert result["fp_flags"] == 0, f"Unexpected flags 0x{result['fp_flags']:02X}"


# ============================================================================
# Test 3: FSQRT_S basic: sqrt(4.0) = 2.0
# ============================================================================
@cocotb.test()
async def test_fsqrt_s_basic(dut: Any) -> None:
    """FSQRT_S: sqrt(4.0) = 2.0 (NaN-boxed single-precision result)."""
    iface = await setup(dut)

    result = await run_one(iface, 5, OP_FSQRT_S, SP_4_0)
    assert result["tag"] == 5, f"Tag mismatch: expected 5, got {result['tag']}"
    assert result["value"] == EXPECTED_2_0_SP, (
        f"Value mismatch: expected 0x{EXPECTED_2_0_SP:016X}, "
        f"got 0x{result['value']:016X}"
    )


# ============================================================================
# Test 4: Double-precision divide and square root
# ============================================================================
@cocotb.test()
async def test_double_precision_ops(dut: Any) -> None:
    """FDIV_D and FSQRT_D deliver unboxed 64-bit results."""
    iface = await setup(dut)

    result = await run_one(iface, 7, OP_FDIV_D, DP_6_0, DP_2_0)
    assert result["tag"] == 7
    assert (
        result["value"] == EXPECTED_3_0_DP
    ), f"FDIV_D: expected 0x{EXPECTED_3_0_DP:016X}, got 0x{result['value']:016X}"

    result = await run_one(iface, 8, OP_FSQRT_D, DP_16_0)
    assert result["tag"] == 8
    assert (
        result["value"] == EXPECTED_4_0_DP
    ), f"FSQRT_D: expected 0x{EXPECTED_4_0_DP:016X}, got 0x{result['value']:016X}"

    result = await run_one(iface, 9, OP_FSQRT_D, DP_25_0)
    assert result["tag"] == 9
    assert result["value"] == EXPECTED_5_0_DP

    result = await run_one(iface, 10, OP_FSQRT_D, DP_MIN_SUBNORMAL)
    assert result["tag"] == 10
    assert result["value"] == EXPECTED_SQRT_MIN_SUBNORMAL_DP


# ============================================================================
# Test 5: Busy covers the whole occupancy, and only that
# ============================================================================
@cocotb.test()
async def test_busy_tracks_occupancy(dut: Any) -> None:
    """Busy rises with the operation, stays up over the held result, then falls."""
    iface = await setup(dut)

    await issue(iface, 2, OP_FDIV_S, SP_6_0, SP_2_0)

    # Busy stays up for the whole run and through the held result. Reads take
    # the read-only phase so they see the state the edge just produced.
    for cycle in range(SP_VISIBLE_CYCLES):
        await ReadOnly()
        assert iface.read_busy(), f"busy dropped at cycle {cycle}"
        assert not iface.read_fu_complete()[
            "valid"
        ], f"completion appeared at cycle {cycle}, expected {SP_VISIBLE_CYCLES}"
        await RisingEdge(iface.clock)

    await ReadOnly()
    result = iface.read_fu_complete()
    assert result["valid"], "expected the completion to be presented"
    assert iface.read_busy(), "busy must stay set while a result waits"

    # Hold the result: the shim keeps presenting it until it is accepted.
    for _ in range(5):
        await RisingEdge(iface.clock)
        await ReadOnly()
        held = iface.read_fu_complete()
        assert held["valid"], "result must be held until accepted"
        assert held["tag"] == 2
        assert held["value"] == EXPECTED_3_0_SP
        assert iface.read_busy(), "busy must stay set while a result waits"

    await FallingEdge(iface.clock)
    iface.drive_div_accepted()
    await RisingEdge(iface.clock)
    iface.clear_div_accepted()
    await FallingEdge(iface.clock)
    assert not iface.read_busy(), "busy must clear once the result is accepted"
    assert not iface.read_fu_complete()["valid"], "result must not be re-presented"


# ============================================================================
# Test 6: Serialized back-to-back issue
# ============================================================================
@cocotb.test()
async def test_serialized_back_to_back(dut: Any) -> None:
    """Four FDIV_S operations, each issued as soon as the shim frees up."""
    iface = await setup(dut)

    tags = [10, 11, 12, 13]
    collected = []
    for tag in tags:
        await wait_until_idle(iface)
        result = await run_one(iface, tag, OP_FDIV_S, SP_6_0, SP_2_0)
        collected.append(result["tag"])
        assert result["value"] == EXPECTED_3_0_SP

    assert collected == tags, f"Expected tags {tags}, got {collected}"


# ============================================================================
# Test 7: The unit pairs each completion with its own tag
# ============================================================================
@cocotb.test()
async def test_unit_completion_pairs_with_tag(dut: Any) -> None:
    """Distinct operations keep result, flags and tag together."""
    iface = await setup(dut)

    operations = [
        (20, OP_FDIV_S, SP_6_0, SP_2_0, EXPECTED_3_0_SP, 0),
        (21, OP_FSQRT_S, SP_9_0, 0, EXPECTED_3_0_SP_SQRT, 0),
        (22, OP_FDIV_S, SP_1_0, SP_ZERO, EXPECTED_INF_SP, FP_FLAG_DZ),
        (23, OP_FSQRT_D, DP_NEG_1_0, 0, EXPECTED_QNAN_DP, FP_FLAG_NV),
        (24, OP_FDIV_D, DP_6_0, DP_2_0, EXPECTED_3_0_DP, 0),
    ]

    for tag, op, src1, src2, value, flags in operations:
        await wait_until_idle(iface)
        result = await run_one(iface, tag, op, src1, src2)
        assert result["tag"] == tag, f"expected tag {tag}, got {result['tag']}"
        assert (
            result["value"] == value
        ), f"tag {tag}: expected 0x{value:016X}, got 0x{result['value']:016X}"
        assert result["fp_flags"] == flags, (
            f"tag {tag}: expected flags 0x{flags:02X}, "
            f"got 0x{result['fp_flags']:02X}"
        )


# ============================================================================
# Test 8: Interleaved divide and square root
# ============================================================================
@cocotb.test()
async def test_interleaved_div_sqrt(dut: Any) -> None:
    """Alternating FDIV_S and FSQRT_S both complete with their own values."""
    iface = await setup(dut)

    ops = [
        (28, OP_FDIV_S, SP_6_0, SP_2_0, EXPECTED_3_0_SP),
        (29, OP_FSQRT_S, SP_4_0, 0, EXPECTED_2_0_SP),
        (30, OP_FDIV_S, SP_6_0, SP_2_0, EXPECTED_3_0_SP),
        (31, OP_FSQRT_S, SP_9_0, 0, EXPECTED_3_0_SP_SQRT),
    ]

    for tag, op, src1, src2, expected in ops:
        await wait_until_idle(iface)
        result = await run_one(iface, tag, op, src1, src2)
        assert result["tag"] == tag
        assert (
            result["value"] == expected
        ), f"tag {tag}: expected 0x{expected:016X}, got 0x{result['value']:016X}"


# ============================================================================
# Test 9: Completions land on the exact cycle, single and double precision
# ============================================================================
@cocotb.test()
async def test_exact_latency(dut: Any) -> None:
    """Single precision completes at cycle 36, double at cycle 65."""
    iface = await setup(dut)

    await issue(iface, 24, OP_FSQRT_S, SP_4_0)
    await expect_completion_at_cycle(
        iface,
        expected_cycle=SP_VISIBLE_CYCLES,
        expected_tag=24,
        expected_value=EXPECTED_2_0_SP,
    )

    await wait_until_idle(iface)
    await issue(iface, 25, OP_FSQRT_D, DP_9_0)
    await expect_completion_at_cycle(
        iface,
        expected_cycle=DP_VISIBLE_CYCLES,
        expected_tag=25,
        expected_value=EXPECTED_3_0_DP,
    )

    await wait_until_idle(iface)
    await issue(iface, 26, OP_FDIV_S, SP_6_0, SP_2_0)
    await expect_completion_at_cycle(
        iface,
        expected_cycle=SP_VISIBLE_CYCLES,
        expected_tag=26,
        expected_value=EXPECTED_3_0_SP,
    )

    await wait_until_idle(iface)
    await issue(iface, 27, OP_FDIV_D, DP_6_0, DP_2_0)
    await expect_completion_at_cycle(
        iface,
        expected_cycle=DP_VISIBLE_CYCLES,
        expected_tag=27,
        expected_value=EXPECTED_3_0_DP,
    )


# ============================================================================
# Test 10: The issue's rounding mode reaches the unit
# ============================================================================
@cocotb.test()
async def test_rounding_mode_passthrough(dut: Any) -> None:
    """1.0f / 3.0f rounds differently under RNE and RTZ."""
    iface = await setup(dut)

    result = await run_one(iface, 14, OP_FDIV_S, SP_1_0, SP_3_0, rm=RM_RNE)
    assert result["value"] == EXPECTED_THIRD_RNE_SP, (
        f"RNE: expected 0x{EXPECTED_THIRD_RNE_SP:016X}, "
        f"got 0x{result['value']:016X}"
    )
    assert result["fp_flags"] == FP_FLAG_NX

    await wait_until_idle(iface)
    result = await run_one(iface, 15, OP_FDIV_S, SP_1_0, SP_3_0, rm=RM_RTZ)
    assert result["value"] == EXPECTED_THIRD_RTZ_SP, (
        f"RTZ: expected 0x{EXPECTED_THIRD_RTZ_SP:016X}, "
        f"got 0x{result['value']:016X}"
    )
    assert result["fp_flags"] == FP_FLAG_NX


# ============================================================================
# Test 11: Full flush during the iteration
# ============================================================================
@cocotb.test()
async def test_flush_clears_inflight(dut: Any) -> None:
    """A full flush mid-operation frees the unit and suppresses the result."""
    iface = await setup(dut)

    await issue(iface, 3, OP_FDIV_S, SP_6_0, SP_2_0)

    for _ in range(3):
        await RisingEdge(iface.clock)

    iface.drive_flush()
    await RisingEdge(iface.clock)
    iface.clear_flush()

    await FallingEdge(iface.clock)
    assert not iface.read_busy(), "the killed operation must free the unit"

    for _ in range(MAX_LATENCY):
        await RisingEdge(iface.clock)
        result = iface.read_fu_complete()
        assert not result["valid"], "Expected no valid output after flush"

    # The shim still works afterwards.
    result = await run_one(iface, 4, OP_FDIV_S, SP_6_0, SP_2_0)
    assert result["tag"] == 4
    assert result["value"] == EXPECTED_3_0_SP


# ============================================================================
# Test 12: Full flush on the issue cycle
# ============================================================================
@cocotb.test()
async def test_flush_on_issue_cycle(dut: Any) -> None:
    """An operation flushed on its own issue cycle never starts."""
    iface = await setup(dut)

    iface.drive_flush()
    iface.drive_issue(
        valid=True,
        rob_tag=6,
        op=OP_FDIV_S,
        src1_value=SP_6_0,
        src2_value=SP_2_0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()
    iface.clear_flush()

    await FallingEdge(iface.clock)
    assert not iface.read_busy(), "a flushed issue must not occupy the unit"

    for _ in range(MAX_LATENCY):
        await RisingEdge(iface.clock)
        assert not iface.read_fu_complete()["valid"], "flushed issue produced a result"


# ============================================================================
# Test 13: Partial flush kills a younger in-flight operation
# ============================================================================
@cocotb.test()
async def test_partial_flush_inflight_younger(dut: Any) -> None:
    """A partial flush younger than the in-flight tag drops the operation."""
    iface = await setup(dut)

    # head=0, flush boundary tag 3: tag 8 is younger and must die.
    await issue(iface, 8, OP_FDIV_D, DP_6_0, DP_2_0)

    for _ in range(5):
        await RisingEdge(iface.clock)

    iface.drive_partial_flush(flush_tag=3, head_tag=0)
    await RisingEdge(iface.clock)
    iface.clear_partial_flush()

    await FallingEdge(iface.clock)
    assert not iface.read_busy(), "the killed operation must free the unit"

    for _ in range(MAX_LATENCY):
        await RisingEdge(iface.clock)
        assert not iface.read_fu_complete()["valid"], "flushed tag 8 completed"


# ============================================================================
# Test 14: Partial flush spares an older in-flight operation
# ============================================================================
@cocotb.test()
async def test_partial_flush_inflight_older(dut: Any) -> None:
    """An in-flight tag older than the flush boundary keeps running."""
    iface = await setup(dut)

    # head=0, flush boundary tag 5: tag 2 is older and must survive.
    await issue(iface, 2, OP_FDIV_S, SP_6_0, SP_2_0)

    for _ in range(5):
        await RisingEdge(iface.clock)

    iface.drive_partial_flush(flush_tag=5, head_tag=0)
    await RisingEdge(iface.clock)
    iface.clear_partial_flush()

    result = await wait_for_completion(iface)
    assert result["tag"] == 2, f"expected tag 2 to survive, got {result['tag']}"
    assert result["value"] == EXPECTED_3_0_SP


# ============================================================================
# Test 15: Partial flush of a held result
# ============================================================================
@cocotb.test()
async def test_partial_flush_held_result(dut: Any) -> None:
    """A held result younger than the boundary is suppressed and drained."""
    iface = await setup(dut)

    # Older tag: survives the flush and is still presented.
    await issue(iface, 2, OP_FDIV_S, SP_6_0, SP_2_0)
    for _ in range(MAX_LATENCY):
        await RisingEdge(iface.clock)
        if iface.read_fu_complete()["valid"]:
            break

    iface.drive_partial_flush(flush_tag=3, head_tag=0)
    await RisingEdge(iface.clock)
    await ReadOnly()
    result = iface.read_fu_complete()
    assert result["valid"], "tag 2 is older than the boundary and must survive"
    assert result["tag"] == 2
    await FallingEdge(iface.clock)
    iface.clear_partial_flush()

    iface.drive_div_accepted()
    await RisingEdge(iface.clock)
    iface.clear_div_accepted()
    await wait_until_idle(iface)

    # Younger tag: suppressed on the flush cycle and dropped.
    await issue(iface, 8, OP_FDIV_S, SP_6_0, SP_2_0)
    for _ in range(MAX_LATENCY):
        await RisingEdge(iface.clock)
        if iface.read_fu_complete()["valid"]:
            break

    iface.drive_partial_flush(flush_tag=3, head_tag=0)
    await RisingEdge(iface.clock)
    await ReadOnly()
    assert not iface.read_fu_complete()[
        "valid"
    ], "a younger held result must be suppressed on the flush cycle"
    await FallingEdge(iface.clock)
    iface.clear_partial_flush()

    for _ in range(5):
        await RisingEdge(iface.clock)
        assert not iface.read_fu_complete()["valid"], "flushed result was presented"
    assert not iface.read_busy(), "the drained result must free the credit"


# ============================================================================
# Test 16: Full flush of a held result
# ============================================================================
@cocotb.test()
async def test_full_flush_held_result(dut: Any) -> None:
    """A full flush clears a result waiting for the adapter."""
    iface = await setup(dut)

    await issue(iface, 12, OP_FSQRT_S, SP_4_0)
    for _ in range(MAX_LATENCY):
        await RisingEdge(iface.clock)
        if iface.read_fu_complete()["valid"]:
            break

    iface.drive_flush()
    await RisingEdge(iface.clock)
    iface.clear_flush()

    for _ in range(5):
        await RisingEdge(iface.clock)
        assert not iface.read_fu_complete()["valid"], "result survived a full flush"
    assert not iface.read_busy(), "busy must clear after a full flush"


# ============================================================================
# Test 17: The credit gate refuses nothing once the result is taken
# ============================================================================
@cocotb.test()
async def test_credit_recovers_after_accept(dut: Any) -> None:
    """After acceptance the shim takes the next operation immediately."""
    iface = await setup(dut)

    await issue(iface, 16, OP_FDIV_S, SP_6_0, SP_2_0)
    result = await wait_for_completion(iface)
    assert result["tag"] == 16

    # i_div_accepted was driven on the cycle before this one, so the credit is
    # back and the next operation can be issued at once.
    await FallingEdge(iface.clock)
    assert not iface.read_busy(), "credit must be back the cycle after acceptance"
    result = await run_one(iface, 17, OP_FSQRT_S, SP_4_0)
    assert result["tag"] == 17
    assert result["value"] == EXPECTED_2_0_SP


# ============================================================================
# Test 18: The unit's completion pulse is one cycle ahead of the shim's
# ============================================================================
@cocotb.test()
async def test_unit_pulse_precedes_result(dut: Any) -> None:
    """The unit pulses o_valid once; the shim presents it the next cycle."""
    iface = await setup(dut)

    await issue(iface, 19, OP_FSQRT_S, SP_4_0)

    pulses = 0
    seen_at = -1
    for cycle in range(1, MAX_LATENCY):
        await RisingEdge(iface.clock)
        await ReadOnly()
        if int(dut.u_div_sqrt.o_valid.value):
            pulses += 1
            seen_at = cycle
            assert (
                int(dut.u_div_sqrt.o_result.value) & 0xFFFF_FFFF
            ) == EXPECTED_2_0_SP & 0xFFFF_FFFF
        if iface.read_fu_complete()["valid"]:
            break

    assert pulses == 1, f"expected exactly one unit completion pulse, saw {pulses}"
    assert (
        seen_at == SP_VISIBLE_CYCLES - 1
    ), f"unit pulsed at cycle {seen_at}, expected {SP_VISIBLE_CYCLES - 1}"


# ============================================================================
# Test 19: Special-case values and flags
# ============================================================================
@cocotb.test()
async def test_special_values_and_flags(dut: Any) -> None:
    """Divide by zero, sqrt of a negative, and an inexact divide set flags."""
    iface = await setup(dut)

    result = await run_one(iface, 21, OP_FDIV_S, SP_1_0, SP_ZERO)
    assert result["value"] == EXPECTED_INF_SP
    assert result["fp_flags"] == FP_FLAG_DZ

    await wait_until_idle(iface)
    result = await run_one(iface, 22, OP_FSQRT_D, DP_NEG_1_0)
    assert result["value"] == EXPECTED_QNAN_DP
    assert result["fp_flags"] == FP_FLAG_NV

    await wait_until_idle(iface)
    result = await run_one(iface, 23, OP_FDIV_D, DP_1_0, DP_3_0)
    assert result["fp_flags"] == FP_FLAG_NX
    assert result["value"] == 0x3FD5_5555_5555_5555


# ============================================================================
# Test 20: Full flush on the unit's completion cycle
# ============================================================================
@cocotb.test()
async def test_full_flush_on_completion_cycle(dut: Any) -> None:
    """A full flush landing on the capture cycle drops the completion."""
    iface = await setup(dut)

    await issue(iface, 13, OP_FDIV_S, SP_6_0, SP_2_0)

    # The unit pulses o_valid one cycle before the shim would present it.
    for _ in range(SP_VISIBLE_CYCLES - 1):
        await RisingEdge(iface.clock)
    await ReadOnly()
    assert int(
        dut.u_div_sqrt.o_valid.value
    ), "expected the unit to complete on this cycle"

    await FallingEdge(iface.clock)
    iface.drive_flush()
    await RisingEdge(iface.clock)
    iface.clear_flush()

    await FallingEdge(iface.clock)
    assert not iface.read_fu_complete()["valid"], "captured a flushed completion"
    assert not iface.read_busy(), "the flushed completion must free the credit"

    for _ in range(5):
        await RisingEdge(iface.clock)
        assert not iface.read_fu_complete()["valid"], "flushed completion appeared"


# ============================================================================
# Test 21: Partial flush on the unit's completion cycle
# ============================================================================
@cocotb.test()
async def test_partial_flush_on_completion_cycle(dut: Any) -> None:
    """A partial flush covering the tag on the capture cycle drops it."""
    iface = await setup(dut)

    await issue(iface, 9, OP_FDIV_S, SP_6_0, SP_2_0)

    for _ in range(SP_VISIBLE_CYCLES - 1):
        await RisingEdge(iface.clock)
    await ReadOnly()
    assert int(
        dut.u_div_sqrt.o_valid.value
    ), "expected the unit to complete on this cycle"

    await FallingEdge(iface.clock)
    iface.drive_partial_flush(flush_tag=4, head_tag=0)
    await RisingEdge(iface.clock)
    iface.clear_partial_flush()

    await FallingEdge(iface.clock)
    assert not iface.read_fu_complete()["valid"], "captured a flushed completion"
    assert not iface.read_busy(), "the flushed completion must free the credit"

    for _ in range(5):
        await RisingEdge(iface.clock)
        assert not iface.read_fu_complete()["valid"], "flushed completion appeared"


# ============================================================================
# Test 22: Consecutive partial flushes around a capture
# ============================================================================
@cocotb.test()
async def test_partial_flushes_around_capture(dut: Any) -> None:
    """A flush that spares the tag on the capture cycle, then one that kills it."""
    iface = await setup(dut)

    await issue(iface, 4, OP_FDIV_S, SP_6_0, SP_2_0)

    for _ in range(SP_VISIBLE_CYCLES - 1):
        await RisingEdge(iface.clock)

    # Capture cycle: boundary tag 9 is younger than tag 4, so tag 4 survives.
    await FallingEdge(iface.clock)
    iface.drive_partial_flush(flush_tag=9, head_tag=0)
    await RisingEdge(iface.clock)
    await ReadOnly()
    assert iface.read_fu_complete()["valid"], "tag 4 should have been captured"
    assert iface.read_fu_complete()["tag"] == 4

    # Next cycle: boundary tag 1 is older than tag 4, so the held result dies.
    await FallingEdge(iface.clock)
    iface.drive_partial_flush(flush_tag=1, head_tag=0)
    await RisingEdge(iface.clock)
    await ReadOnly()
    assert not iface.read_fu_complete()[
        "valid"
    ], "the held result must be suppressed on the flush cycle"

    await FallingEdge(iface.clock)
    iface.clear_partial_flush()
    for _ in range(5):
        await RisingEdge(iface.clock)
        assert not iface.read_fu_complete()["valid"], "flushed result was presented"
    assert not iface.read_busy(), "the drained result must free the credit"
