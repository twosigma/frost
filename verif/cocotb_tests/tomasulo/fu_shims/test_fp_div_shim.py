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

Tests FDIV_S, FSQRT_S operations, busy signalling, flush behaviour,
and pipelined back-to-back issue with FIFO-based result output.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from .fp_div_shim_interface import (
    FpDivShimInterface,
    CLOCK_PERIOD_NS,
    OP_FDIV_S,
    OP_FDIV_D,
    OP_FSQRT_S,
)

# IEEE 754 single-precision constants (NaN-boxed in 64-bit)
NAN_BOX = 0xFFFF_FFFF_0000_0000
SP_2_0 = NAN_BOX | 0x4000_0000  # 2.0f
SP_3_0 = NAN_BOX | 0x4040_0000  # 3.0f
SP_4_0 = NAN_BOX | 0x4080_0000  # 4.0f
SP_6_0 = NAN_BOX | 0x40C0_0000  # 6.0f
SP_9_0 = NAN_BOX | 0x4110_0000  # 9.0f

# IEEE 754 double-precision constants
DP_2_0 = 0x4000_0000_0000_0000  # 2.0
DP_6_0 = 0x4018_0000_0000_0000  # 6.0
DP_4_0 = 0x4010_0000_0000_0000  # 4.0

# Expected NaN-boxed results
EXPECTED_3_0 = 0xFFFF_FFFF_4040_0000  # 6.0 / 2.0 = 3.0
EXPECTED_2_0 = 0xFFFF_FFFF_4000_0000  # sqrt(4.0) = 2.0
EXPECTED_3_0_SP = 0xFFFF_FFFF_4040_0000  # 6.0 / 2.0 = 3.0 (SP, NaN-boxed)
EXPECTED_2_0_SP = 0xFFFF_FFFF_4000_0000  # sqrt(4.0) = 2.0 (SP, NaN-boxed)
EXPECTED_3_0_DP = 0x4008_0000_0000_0000  # 6.0 / 2.0 = 3.0 (DP)
EXPECTED_2_0_DP = 0x4000_0000_0000_0000  # sqrt(4.0) = 2.0 (DP)

MAX_LATENCY = 80  # DP pipeline is 65 stages, allow margin


async def setup(dut: Any) -> FpDivShimInterface:
    """Start clock, reset DUT, and return interface."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    iface = FpDivShimInterface(dut)
    await iface.reset()
    return iface


async def wait_for_completion(
    iface: FpDivShimInterface, max_cycles: int = MAX_LATENCY
) -> dict:
    """Poll o_fu_complete.valid, drive i_div_accepted to pop, return result.

    Raises AssertionError if the operation does not complete in time.
    """
    for _ in range(max_cycles):
        await RisingEdge(iface.clock)
        result = iface.read_fu_complete()
        if result["valid"]:
            # Drive accepted for one cycle to pop the FIFO entry
            iface.drive_div_accepted()
            await RisingEdge(iface.clock)
            iface.clear_div_accepted()
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
    """Fire FDIV_S, verify busy=0 (pipelined) while single op in-flight."""
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

    # Pipelined: single op should not assert busy (credit < FifoDepth)
    await RisingEdge(iface.clock)
    assert not iface.read_busy(), "Expected busy=0 with single in-flight op (pipelined)"

    # Wait for completion and accept
    result = await wait_for_completion(iface)
    assert result["valid"], "Expected valid completion"


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


# ============================================================================
# Test 6: Back-to-back FDIV_S — issue 4 consecutive ops, all complete
# ============================================================================
@cocotb.test()
async def test_fdiv_s_back_to_back(dut: Any) -> None:
    """Issue 4 back-to-back FDIV_S, verify all 4 complete with correct tags."""
    iface = await setup(dut)

    tags = [10, 11, 12, 13]
    # Issue 4 consecutive FDIV_S ops
    for tag in tags:
        iface.drive_issue(
            valid=True,
            rob_tag=tag,
            op=OP_FDIV_S,
            src1_value=SP_6_0,
            src2_value=SP_2_0,
        )
        await RisingEdge(iface.clock)
    iface.clear_issue()

    # Collect all 4 results
    collected_tags = []
    for _ in range(MAX_LATENCY + 10):
        await RisingEdge(iface.clock)
        result = iface.read_fu_complete()
        if result["valid"]:
            collected_tags.append(result["tag"])
            assert (
                result["value"] == EXPECTED_3_0
            ), f"Value mismatch: expected 0x{EXPECTED_3_0:016X}, got 0x{result['value']:016X}"
            iface.drive_div_accepted()
            await RisingEdge(iface.clock)
            iface.clear_div_accepted()
        if len(collected_tags) == len(tags):
            break

    assert collected_tags == tags, f"Expected tags {tags}, got {collected_tags}"


# ============================================================================
# Test 7: Interleaved FDIV_S/FSQRT_S — alternating div/sqrt complete correctly
# ============================================================================
@cocotb.test()
async def test_interleaved_div_sqrt(dut: Any) -> None:
    """Issue alternating FDIV_S and FSQRT_S, verify all complete."""
    iface = await setup(dut)

    ops = [
        (20, OP_FDIV_S, SP_6_0, SP_2_0, EXPECTED_3_0_SP),
        (21, OP_FSQRT_S, SP_4_0, 0, EXPECTED_2_0_SP),
    ]

    for tag, op, s1, s2, _exp in ops:
        iface.drive_issue(valid=True, rob_tag=tag, op=op, src1_value=s1, src2_value=s2)
        await RisingEdge(iface.clock)
    iface.clear_issue()

    collected = {}
    for _ in range(MAX_LATENCY + 10):
        await RisingEdge(iface.clock)
        result = iface.read_fu_complete()
        if result["valid"]:
            collected[result["tag"]] = result["value"]
            iface.drive_div_accepted()
            await RisingEdge(iface.clock)
            iface.clear_div_accepted()
        if len(collected) == len(ops):
            break

    for tag, _op, _s1, _s2, expected in ops:
        assert tag in collected, f"Tag {tag} not found in results"
        assert (
            collected[tag] == expected
        ), f"Tag {tag}: expected 0x{expected:016X}, got 0x{collected[tag]:016X}"


# ============================================================================
# Test 8: Full flush with multiple in-flight — all suppressed
# ============================================================================
@cocotb.test()
async def test_flush_multiple_inflight(dut: Any) -> None:
    """Issue 3 ops, flush, verify all suppressed."""
    iface = await setup(dut)

    for tag in [30, 31, 32]:
        iface.drive_issue(
            valid=True,
            rob_tag=tag,
            op=OP_FDIV_S,
            src1_value=SP_6_0,
            src2_value=SP_2_0,
        )
        await RisingEdge(iface.clock)
    iface.clear_issue()

    # Flush after 5 cycles
    for _ in range(5):
        await RisingEdge(iface.clock)
    iface.drive_flush()
    await RisingEdge(iface.clock)
    iface.clear_flush()

    # Verify no valid output
    for _ in range(MAX_LATENCY):
        await RisingEdge(iface.clock)
        result = iface.read_fu_complete()
        assert not result["valid"], "Expected no valid output after flush"


# ============================================================================
# Test 9: FIFO backpressure — issue 4 ops without accepting, busy asserts
# ============================================================================
@cocotb.test()
async def test_fifo_backpressure(dut: Any) -> None:
    """Issue 4 FDIV_S ops without accepting results, verify busy asserts."""
    iface = await setup(dut)

    # Issue 4 ops (saturates credits)
    for tag in [40, 41, 42, 43]:
        iface.drive_issue(
            valid=True,
            rob_tag=tag,
            op=OP_FDIV_S,
            src1_value=SP_6_0,
            src2_value=SP_2_0,
        )
        await RisingEdge(iface.clock)
    iface.clear_issue()

    # After 4 in-flight, busy should be asserted
    await RisingEdge(iface.clock)
    assert iface.read_busy(), "Expected busy=1 with 4 in-flight ops"

    # Accept results as they come
    accepted = 0
    for _ in range(MAX_LATENCY + 10):
        await RisingEdge(iface.clock)
        result = iface.read_fu_complete()
        if result["valid"]:
            iface.drive_div_accepted()
            await RisingEdge(iface.clock)
            iface.clear_div_accepted()
            accepted += 1
        if accepted == 4:
            break

    assert accepted == 4, f"Expected 4 results, got {accepted}"

    # After all drained, busy should be 0
    await RisingEdge(iface.clock)
    assert not iface.read_busy(), "Expected busy=0 after all results accepted"


# ============================================================================
# Test 10: Cross-precision simultaneous completion
# ============================================================================
@cocotb.test()
async def test_cross_precision_collision(dut: Any) -> None:
    """Issue FDIV_D then FDIV_S 29 cycles later so both complete same cycle.

    SP pipeline = 36 stages, DP pipeline = 65 stages. Offset = 29.
    Both sub-units' hold registers fill on the same cycle; the arbiter
    can only drain one per cycle. Verifies no result is lost.
    """
    iface = await setup(dut)

    # Issue FDIV_D (65-cycle pipeline)
    iface.drive_issue(
        valid=True,
        rob_tag=14,
        op=OP_FDIV_D,
        src1_value=DP_6_0,
        src2_value=DP_2_0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    # Wait 28 cycles so next issue is 29 cycles after the DP issue
    for _ in range(28):
        await RisingEdge(iface.clock)

    # Issue FDIV_S (36-cycle pipeline, completes same cycle as FDIV_D)
    iface.drive_issue(
        valid=True,
        rob_tag=15,
        op=OP_FDIV_S,
        src1_value=SP_6_0,
        src2_value=SP_2_0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    # Collect both results
    collected = {}
    for _ in range(MAX_LATENCY + 10):
        await RisingEdge(iface.clock)
        result = iface.read_fu_complete()
        if result["valid"]:
            collected[result["tag"]] = result["value"]
            iface.drive_div_accepted()
            await RisingEdge(iface.clock)
            iface.clear_div_accepted()
        if len(collected) == 2:
            break

    assert 14 in collected, "FDIV_D result (tag 14) not found"
    assert 15 in collected, "FDIV_S result (tag 15) not found"
    assert (
        collected[14] == EXPECTED_3_0_DP
    ), f"FDIV_D value mismatch: expected 0x{EXPECTED_3_0_DP:016X}, got 0x{collected[14]:016X}"
    assert (
        collected[15] == EXPECTED_3_0_SP
    ), f"FDIV_S value mismatch: expected 0x{EXPECTED_3_0_SP:016X}, got 0x{collected[15]:016X}"


# ============================================================================
# Test 11: Hold overwrite stress — back-to-back DP + simultaneous SP
# ============================================================================
@cocotb.test()
async def test_hold_overwrite_stress(dut: Any) -> None:
    """Issue 2 FDIV_D + 1 FDIV_S timed so FDIV_D completes twice in a row.

    FDIV_S hold also contends.
    FDIV_D#1 @ T, FDIV_D#2 @ T+1, FDIV_S @ T+29.
    T+65: FDIV_D#1 + FDIV_S complete simultaneously (hold collision).
    T+66: FDIV_D#2 completes; if DP hold wasn't drained, old code overwrites.
    With 2-deep hold, all three results must survive.
    """
    iface = await setup(dut)

    # Issue FDIV_D#1
    iface.drive_issue(
        valid=True,
        rob_tag=16,
        op=OP_FDIV_D,
        src1_value=DP_6_0,
        src2_value=DP_2_0,
    )
    await RisingEdge(iface.clock)

    # Issue FDIV_D#2 (1 cycle later)
    iface.drive_issue(
        valid=True,
        rob_tag=17,
        op=OP_FDIV_D,
        src1_value=DP_6_0,
        src2_value=DP_2_0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    # Wait until 29 cycles after FDIV_D#1 issue, then issue FDIV_S
    for _ in range(27):
        await RisingEdge(iface.clock)

    iface.drive_issue(
        valid=True,
        rob_tag=18,
        op=OP_FDIV_S,
        src1_value=SP_6_0,
        src2_value=SP_2_0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    # Collect all 3 results
    collected = {}
    for _ in range(MAX_LATENCY + 20):
        await RisingEdge(iface.clock)
        result = iface.read_fu_complete()
        if result["valid"]:
            collected[result["tag"]] = result["value"]
            iface.drive_div_accepted()
            await RisingEdge(iface.clock)
            iface.clear_div_accepted()
        if len(collected) == 3:
            break

    assert 16 in collected, "FDIV_D#1 (tag 16) lost — possible hold overwrite"
    assert 17 in collected, "FDIV_D#2 (tag 17) lost — possible hold overwrite"
    assert 18 in collected, "FDIV_S (tag 18) lost"
    assert collected[16] == EXPECTED_3_0_DP
    assert collected[17] == EXPECTED_3_0_DP
    assert collected[18] == EXPECTED_3_0_SP


# ============================================================================
# Test 12: Partial flush suppresses younger FIFO/hold entry
# ============================================================================
@cocotb.test()
async def test_partial_flush_fifo_entry(dut: Any) -> None:
    """Issue 2 FDIV_S ops (tags 2 and 4), let both complete into FIFO.

    Then partial-flush everything younger than tag 3 (head=0).
    Tag 2 (older) should survive; tag 4 (younger) should be suppressed.
    """
    iface = await setup(dut)

    # Issue two FDIV_S back-to-back
    iface.drive_issue(
        valid=True,
        rob_tag=2,
        op=OP_FDIV_S,
        src1_value=SP_6_0,
        src2_value=SP_2_0,
    )
    await RisingEdge(iface.clock)
    iface.drive_issue(
        valid=True,
        rob_tag=4,
        op=OP_FDIV_S,
        src1_value=SP_6_0,
        src2_value=SP_2_0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    # Wait for first result to appear in FIFO, then wait a few more cycles
    # so the second op also completes (1 cycle later) and the arbiter pushes
    # it into the FIFO.  Don't accept anything — both must sit in FIFO.
    for _ in range(MAX_LATENCY + 10):
        await RisingEdge(iface.clock)
        result = iface.read_fu_complete()
        if result["valid"]:
            break
    # The second FDIV_S completes 1 cycle after the first.  Give 3 extra
    # cycles for it to transit hold → arbiter → FIFO.
    for _ in range(3):
        await RisingEdge(iface.clock)

    # Partial flush: flush everything younger than tag 3, head=0
    # tag 2: age=2, flush_age=3 → NOT younger → survives
    # tag 4: age=4, flush_age=3 → younger → flushed
    iface.drive_partial_flush(flush_tag=3, head_tag=0)
    await RisingEdge(iface.clock)
    iface.clear_partial_flush()

    # Accept first result (tag 2) — should be valid
    result = iface.read_fu_complete()
    assert result["valid"], "Expected tag 2 result to survive partial flush"
    assert result["tag"] == 2, f"Expected tag 2, got {result['tag']}"
    iface.drive_div_accepted()
    await RisingEdge(iface.clock)
    iface.clear_div_accepted()

    # After accepting tag 2, tag 4 should NOT appear (flushed/auto-drained)
    for _ in range(5):
        await RisingEdge(iface.clock)
        result = iface.read_fu_complete()
        assert not result[
            "valid"
        ], f"Expected tag 4 to be suppressed, but got valid tag {result['tag']}"
