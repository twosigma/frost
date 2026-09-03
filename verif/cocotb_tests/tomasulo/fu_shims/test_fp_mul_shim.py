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

"""Cocotb tests for the fp_mul_shim module.

Verifies arithmetic and the producer-local payload queues, including ordered
dual completion, synchronous-RAM collision bypass, sustained mixed-producer
drain, wraparound, back-pressure, and partial/full flush behavior.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from .fp_add_shim_interface import _parse_instr_op_enum
from .fp_mul_shim_interface import FpMulShimInterface

CLOCK_PERIOD_NS = 10

# ---------------------------------------------------------------------------
# Parse op codes from RTL source
# ---------------------------------------------------------------------------
_INSTR_OPS = _parse_instr_op_enum()

OP_FMUL_S = _INSTR_OPS["FMUL_S"]
OP_FMADD_S = _INSTR_OPS["FMADD_S"]
OP_FMSUB_S = _INSTR_OPS["FMSUB_S"]

# ---------------------------------------------------------------------------
# IEEE 754 single-precision constants (NaN-boxed in 64-bit)
# ---------------------------------------------------------------------------
NAN_BOX = 0xFFFF_FFFF_0000_0000

F32_1_0 = 0x3F80_0000
F32_2_0 = 0x4000_0000
F32_3_0 = 0x4040_0000
F32_5_0 = 0x40A0_0000
F32_6_0 = 0x40C0_0000
F32_7_0 = 0x40E0_0000
F32_POS_ZERO = 0x0000_0000
F32_POS_INF = 0x7F80_0000
F32_CANONICAL_NAN = 0x7FC0_0000

# NaN-boxed 64-bit representations for driving src values
SRC_1_0 = NAN_BOX | F32_1_0
SRC_2_0 = NAN_BOX | F32_2_0
SRC_3_0 = NAN_BOX | F32_3_0
SRC_POS_ZERO = NAN_BOX | F32_POS_ZERO
SRC_POS_INF = NAN_BOX | F32_POS_INF

# Expected NaN-boxed 64-bit results
RES_5_0 = NAN_BOX | F32_5_0
RES_6_0 = NAN_BOX | F32_6_0
RES_7_0 = NAN_BOX | F32_7_0
RES_CANONICAL_NAN = NAN_BOX | F32_CANONICAL_NAN

FP_FLAG_NV = 0x10

# Native completion latency is 11 cycles for FMUL and 16 cycles for FMA.
MAX_LATENCY = 20
FMA_EXTRA_LATENCY = 5


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
async def setup(dut: Any) -> FpMulShimInterface:
    """Start clock, reset DUT, and return the interface."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    iface = FpMulShimInterface(dut)
    await iface.reset()
    return iface


async def clock_cycle(dut: Any) -> None:
    """Advance one full clock cycle and stop at the falling edge."""
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)


async def issue_once(
    dut: Any,
    iface: FpMulShimInterface,
    *,
    rob_tag: int,
    op: int,
    src1_value: int,
    src2_value: int,
    src3_value: int = 0,
) -> None:
    """Issue one operation for exactly one cycle."""
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=op,
        src1_value=src1_value,
        src2_value=src2_value,
        src3_value=src3_value,
    )
    await clock_cycle(dut)
    iface.drive_issue(valid=False, rob_tag=0, op=0, src1_value=0, src2_value=0)


async def wait_for_fifo_count(dut: Any, expected: int) -> None:
    """Wait until the internal shared ordering-ring count reaches *expected*."""
    for _ in range(MAX_LATENCY + expected + 8):
        if int(dut.fifo_count.value) == expected:
            return
        await clock_cycle(dut)
    raise AssertionError(
        f"fifo_count did not reach {expected}; got {int(dut.fifo_count.value)}"
    )


def assert_completion(result: dict, *, tag: int, value: int, fp_flags: int = 0) -> None:
    """Check all payload fields that the result queues must keep aligned."""
    assert result["valid"], "expected a valid completion"
    assert result["tag"] == tag, f"expected tag {tag}, got {result['tag']}"
    assert (
        result["value"] == value
    ), f"expected value 0x{value:016X}, got 0x{result['value']:016X}"
    assert (
        result["fp_flags"] == fp_flags
    ), f"expected flags 0x{fp_flags:02X}, got 0x{result['fp_flags']:02X}"


async def wait_for_complete(dut: Any, iface: FpMulShimInterface) -> dict:
    """Wait until o_fu_complete.valid is asserted and return the unpacked result.

    Raises an assertion error if valid is not seen within MAX_LATENCY cycles.
    """
    for _ in range(MAX_LATENCY):
        await RisingEdge(dut.i_clk)
        await FallingEdge(dut.i_clk)
        result = iface.read_fu_complete()
        if result["valid"]:
            return result
    raise AssertionError("fu_complete.valid not asserted within MAX_LATENCY cycles")


async def wait_for_completions(
    dut: Any, iface: FpMulShimInterface, count: int
) -> list[dict]:
    """Collect *count* completions within a bounded number of cycles."""
    results: list[dict] = []
    for _ in range(MAX_LATENCY + count + 8):
        await RisingEdge(dut.i_clk)
        await FallingEdge(dut.i_clk)
        result = iface.read_fu_complete()
        if result["valid"]:
            results.append(result)
            if len(results) == count:
                return results
    raise AssertionError(f"only saw {len(results)} of {count} expected completions")


# ============================================================================
# Test 1: After reset, valid=0 and busy=0
# ============================================================================
@cocotb.test()
async def test_reset_state(dut: Any) -> None:
    """After reset, o_fu_complete.valid=0 and o_fu_busy=0."""
    iface = await setup(dut)

    result = iface.read_fu_complete()
    assert result["valid"] == 0, f"Expected valid=0 after reset, got {result['valid']}"
    assert not iface.read_busy(), "Expected busy=0 after reset"


# ============================================================================
# Test 2: FMUL_S basic -- 2.0 * 3.0 = 6.0 (NaN-boxed)
# ============================================================================
@cocotb.test()
async def test_fmul_s_basic(dut: Any) -> None:
    """FMUL_S: 2.0f * 3.0f = 6.0f, result is NaN-boxed."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=1,
        op=OP_FMUL_S,
        src1_value=SRC_2_0,
        src2_value=SRC_3_0,
    )
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)

    # Clear issue after one cycle
    iface.drive_issue(valid=False, rob_tag=0, op=0, src1_value=0, src2_value=0)

    result = await wait_for_complete(dut, iface)

    assert result["valid"], "Expected valid completion"
    assert result["tag"] == 1, f"Expected tag=1, got {result['tag']}"
    assert result["value"] == RES_6_0, (
        f"Expected NaN-boxed 6.0f (0x{RES_6_0:016X}), " f"got 0x{result['value']:016X}"
    )


# ============================================================================
# Test 3: FMADD_S basic -- 2.0 * 3.0 + 1.0 = 7.0
# ============================================================================
@cocotb.test()
async def test_fmadd_s_basic(dut: Any) -> None:
    """FMADD_S: src1=2.0f, src2=3.0f, src3=1.0f -> 2.0*3.0+1.0 = 7.0f."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=2,
        op=OP_FMADD_S,
        src1_value=SRC_2_0,
        src2_value=SRC_3_0,
        src3_value=SRC_1_0,
    )
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)

    iface.drive_issue(valid=False, rob_tag=0, op=0, src1_value=0, src2_value=0)

    result = await wait_for_complete(dut, iface)

    assert result["valid"], "Expected valid completion"
    assert result["tag"] == 2, f"Expected tag=2, got {result['tag']}"
    assert result["value"] == RES_7_0, (
        f"Expected NaN-boxed 7.0f (0x{RES_7_0:016X}), " f"got 0x{result['value']:016X}"
    )


# ============================================================================
# Test 4: FMSUB_S basic -- 2.0 * 3.0 - 1.0 = 5.0
# ============================================================================
@cocotb.test()
async def test_fmsub_s_basic(dut: Any) -> None:
    """FMSUB_S: src1=2.0f, src2=3.0f, src3=1.0f -> 2.0*3.0-1.0 = 5.0f."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=3,
        op=OP_FMSUB_S,
        src1_value=SRC_2_0,
        src2_value=SRC_3_0,
        src3_value=SRC_1_0,
    )
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)

    iface.drive_issue(valid=False, rob_tag=0, op=0, src1_value=0, src2_value=0)

    result = await wait_for_complete(dut, iface)

    assert result["valid"], "Expected valid completion"
    assert result["tag"] == 3, f"Expected tag=3, got {result['tag']}"
    assert result["value"] == RES_5_0, (
        f"Expected NaN-boxed 5.0f (0x{RES_5_0:016X}), " f"got 0x{result['value']:016X}"
    )


# ============================================================================
# Test 5: Single in-flight operation does not backpressure the pipeline
# ============================================================================
@cocotb.test()
async def test_single_operation_does_not_assert_busy(dut: Any) -> None:
    """Fire one FMUL_S; busy should remain low because the pipeline has credits."""
    iface = await setup(dut)

    assert not iface.read_busy(), "busy should be 0 before issue"

    iface.drive_issue(
        valid=True,
        rob_tag=4,
        op=OP_FMUL_S,
        src1_value=SRC_2_0,
        src2_value=SRC_3_0,
    )
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)

    # Clear issue after one cycle
    iface.drive_issue(valid=False, rob_tag=0, op=0, src1_value=0, src2_value=0)

    assert (
        not iface.read_busy()
    ), "busy should remain 0 while pipeline credits are available"

    result = await wait_for_complete(dut, iface)
    assert result["valid"], "Expected valid completion"

    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    assert not iface.read_busy(), "busy should be 0 after completion"


# ============================================================================
# Test 6: Flush clears in-flight operation
# ============================================================================
@cocotb.test()
async def test_flush_clears_inflight(dut: Any) -> None:
    """Fire FMUL_S, assert i_flush, verify no valid output appears."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=5,
        op=OP_FMUL_S,
        src1_value=SRC_2_0,
        src2_value=SRC_3_0,
    )
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)

    iface.drive_issue(valid=False, rob_tag=0, op=0, src1_value=0, src2_value=0)
    iface.drive_flush()

    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)

    iface.clear_flush()

    # Cover the full native latency: an unflushed op would have completed by now
    for _ in range(MAX_LATENCY):
        await RisingEdge(dut.i_clk)
        await FallingEdge(dut.i_clk)
        result = iface.read_fu_complete()
        assert not result["valid"], (
            "Expected no valid output after flush, "
            f"but got valid with tag={result['tag']}"
        )


# ============================================================================
# Test 7: Back-to-back FMUL operations keep distinct tags/results in flight
# ============================================================================
@cocotb.test()
async def test_back_to_back_fmul_s_tags(dut: Any) -> None:
    """Issue four FMUL_S ops on consecutive cycles and check ordered completions."""
    iface = await setup(dut)

    for tag in range(8, 12):
        iface.drive_issue(
            valid=True,
            rob_tag=tag,
            op=OP_FMUL_S,
            src1_value=SRC_2_0,
            src2_value=SRC_3_0,
        )
        await RisingEdge(dut.i_clk)
        await FallingEdge(dut.i_clk)
        assert not iface.read_busy(), "credits should allow back-to-back FMUL issue"

    iface.drive_issue(valid=False, rob_tag=0, op=0, src1_value=0, src2_value=0)

    results = await wait_for_completions(dut, iface, 4)
    tags = [result["tag"] for result in results]
    assert tags == [8, 9, 10, 11], f"unexpected completion tags: {tags}"
    for result in results:
        assert (
            result["value"] == RES_6_0
        ), f"Expected NaN-boxed 6.0f (0x{RES_6_0:016X}), got 0x{result['value']:016X}"


# ============================================================================
# Queue architecture: simultaneous producers into an empty ring
# ============================================================================
@cocotb.test()
async def test_empty_dual_completion_keeps_mult_first(dut: Any) -> None:
    """Simultaneous FMUL/FMA completion uses the bypass and keeps FMUL first."""
    iface = await setup(dut)
    iface.set_accepted(False)

    # The FMA pipe is five cycles longer than FMUL. Offset their issues so both
    # native valid signals reach the empty result ring in the same cycle.
    await issue_once(
        dut,
        iface,
        rob_tag=3,
        op=OP_FMADD_S,
        src1_value=SRC_POS_ZERO,
        src2_value=SRC_POS_INF,
        src3_value=SRC_1_0,
    )
    for _ in range(FMA_EXTRA_LATENCY - 1):
        await clock_cycle(dut)
    await issue_once(
        dut,
        iface,
        rob_tag=4,
        op=OP_FMUL_S,
        src1_value=SRC_2_0,
        src2_value=SRC_3_0,
    )

    saw_dual_completion = False
    for _ in range(MAX_LATENCY):
        if int(dut.mult_completion_valid.value) and int(dut.fma_completion_valid.value):
            saw_dual_completion = True
            assert int(dut.fifo_count.value) == 0
            assert int(dut.fifo_push_count.value) == 2
            break
        await clock_cycle(dut)
    assert saw_dual_completion, "FMUL and FMA completions did not align"

    await clock_cycle(dut)
    assert int(dut.fifo_count.value) == 2
    assert int(dut.head_bypass_valid_q.value) == 1
    assert_completion(iface.read_fu_complete(), tag=4, value=RES_6_0)

    iface.set_accepted(True)
    await clock_cycle(dut)
    assert_completion(
        iface.read_fu_complete(),
        tag=3,
        value=RES_CANONICAL_NAN,
        fp_flags=FP_FLAG_NV,
    )
    await clock_cycle(dut)
    assert not iface.read_fu_complete()["valid"]


# ============================================================================
# Queue architecture: same-producer one-entry pop/refill collision
# ============================================================================
@cocotb.test()
async def test_same_producer_pop_refill_collision(dut: Any) -> None:
    """A count-one FMUL pop/refill returns the new payload, including flags."""
    iface = await setup(dut)

    await issue_once(
        dut,
        iface,
        rob_tag=6,
        op=OP_FMUL_S,
        src1_value=SRC_2_0,
        src2_value=SRC_3_0,
    )
    await issue_once(
        dut,
        iface,
        rob_tag=7,
        op=OP_FMUL_S,
        src1_value=SRC_POS_ZERO,
        src2_value=SRC_POS_INF,
    )

    saw_collision = False
    for _ in range(MAX_LATENCY):
        collision = (
            int(dut.fifo_count.value) == 1
            and int(dut.fifo_pop.value)
            and int(dut.mult_completion_valid.value)
        )
        if collision:
            saw_collision = True
            assert int(dut.mult_payload_read_addr.value) == int(
                dut.mult_payload_wr_ptr.value
            )
            assert_completion(iface.read_fu_complete(), tag=6, value=RES_6_0)
            break
        await clock_cycle(dut)
    assert saw_collision, "did not exercise the FMUL RAM read/write collision"

    await clock_cycle(dut)
    assert int(dut.head_bypass_valid_q.value) == 1
    assert_completion(
        iface.read_fu_complete(),
        tag=7,
        value=RES_CANONICAL_NAN,
        fp_flags=FP_FLAG_NV,
    )
    await clock_cycle(dut)
    assert not iface.read_fu_complete()["valid"]


# ============================================================================
# Queue architecture: output stability under back-pressure
# ============================================================================
@cocotb.test()
async def test_payload_stable_under_backpressure(dut: Any) -> None:
    """A stalled head stays stable while a following payload writes its RAM."""
    iface = await setup(dut)
    iface.set_accepted(False)

    await issue_once(
        dut,
        iface,
        rob_tag=8,
        op=OP_FMUL_S,
        src1_value=SRC_2_0,
        src2_value=SRC_3_0,
    )
    await issue_once(
        dut,
        iface,
        rob_tag=9,
        op=OP_FMUL_S,
        src1_value=SRC_POS_ZERO,
        src2_value=SRC_POS_INF,
    )
    await wait_for_fifo_count(dut, 2)

    stalled_head = iface.read_fu_complete()
    assert_completion(stalled_head, tag=8, value=RES_6_0)
    shared_rd_ptr = int(dut.fifo_rd_ptr.value)
    mult_rd_ptr = int(dut.mult_payload_rd_ptr.value)
    for _ in range(4):
        await clock_cycle(dut)
        assert iface.read_fu_complete() == stalled_head
        assert int(dut.fifo_count.value) == 2
        assert int(dut.fifo_rd_ptr.value) == shared_rd_ptr
        assert int(dut.mult_payload_rd_ptr.value) == mult_rd_ptr

    iface.set_accepted(True)
    assert_completion(iface.read_fu_complete(), tag=8, value=RES_6_0)
    await clock_cycle(dut)
    assert_completion(
        iface.read_fu_complete(),
        tag=9,
        value=RES_CANONICAL_NAN,
        fp_flags=FP_FLAG_NV,
    )
    await clock_cycle(dut)
    assert not iface.read_fu_complete()["valid"]


# ============================================================================
# Queue architecture: alternating producer heads, one accepted per cycle
# ============================================================================
@cocotb.test()
async def test_continuous_alternating_producer_drain(dut: Any) -> None:
    """A preloaded FMUL/FMA-alternating ring drains without bubbles."""
    iface = await setup(dut)
    iface.set_accepted(False)

    expected: list[tuple[int, int, int]] = []
    for index in range(6):
        tag = 10 + index
        if index % 2 == 0:
            await issue_once(
                dut,
                iface,
                rob_tag=tag,
                op=OP_FMUL_S,
                src1_value=SRC_2_0,
                src2_value=SRC_3_0,
            )
            expected.append((tag, RES_6_0, 0))
        else:
            await issue_once(
                dut,
                iface,
                rob_tag=tag,
                op=OP_FMADD_S,
                src1_value=SRC_POS_ZERO,
                src2_value=SRC_POS_INF,
                src3_value=SRC_1_0,
            )
            expected.append((tag, RES_CANONICAL_NAN, FP_FLAG_NV))
        await wait_for_fifo_count(dut, index + 1)

    iface.set_accepted(True)
    for tag, value, fp_flags in expected:
        assert_completion(
            iface.read_fu_complete(), tag=tag, value=value, fp_flags=fp_flags
        )
        await clock_cycle(dut)
    assert not iface.read_fu_complete()["valid"]
    assert int(dut.fifo_count.value) == 0


# ============================================================================
# Queue architecture: shared and producer-local pointer wraparound
# ============================================================================
@cocotb.test()
async def test_fmul_payload_and_ordering_ring_wraparound(dut: Any) -> None:
    """Twenty-four accepted FMULs wrap both 16-entry rings without reordering."""
    iface = await setup(dut)

    issued = 0
    results: list[dict] = []
    while issued < 24:
        if iface.read_busy():
            iface.drive_issue(valid=False, rob_tag=0, op=0, src1_value=0, src2_value=0)
        else:
            issued += 1
            iface.drive_issue(
                valid=True,
                rob_tag=issued,
                op=OP_FMUL_S,
                src1_value=SRC_2_0,
                src2_value=SRC_3_0,
            )
        await clock_cycle(dut)
        result = iface.read_fu_complete()
        if result["valid"]:
            results.append(result)

    iface.drive_issue(valid=False, rob_tag=0, op=0, src1_value=0, src2_value=0)
    for _ in range(MAX_LATENCY + 24):
        if len(results) == 24:
            break
        await clock_cycle(dut)
        result = iface.read_fu_complete()
        if result["valid"]:
            results.append(result)
    assert len(results) == 24, f"only saw {len(results)} of 24 completions"

    for expected_tag, result in enumerate(results, start=1):
        assert_completion(result, tag=expected_tag, value=RES_6_0)

    # The last sampled result is accepted on the following edge.
    await clock_cycle(dut)
    assert int(dut.fifo_rd_ptr.value) == 8
    assert int(dut.fifo_wr_ptr.value) == 8
    assert int(dut.mult_payload_rd_ptr.value) == 8
    assert int(dut.mult_payload_wr_ptr.value) == 8


# ============================================================================
# Queue architecture: partial flush advances the matching local payload FIFO
# ============================================================================
@cocotb.test()
async def test_partial_flush_advances_source_payload_head(dut: Any) -> None:
    """A killed FMUL head pops its payload before the surviving FMA is exposed."""
    iface = await setup(dut)
    iface.set_accepted(False)

    await issue_once(
        dut,
        iface,
        rob_tag=20,
        op=OP_FMUL_S,
        src1_value=SRC_2_0,
        src2_value=SRC_3_0,
    )
    await issue_once(
        dut,
        iface,
        rob_tag=5,
        op=OP_FMADD_S,
        src1_value=SRC_2_0,
        src2_value=SRC_3_0,
        src3_value=SRC_1_0,
    )
    await wait_for_fifo_count(dut, 2)
    assert_completion(iface.read_fu_complete(), tag=20, value=RES_6_0)

    mult_rd_before = int(dut.mult_payload_rd_ptr.value)
    fma_rd_before = int(dut.fma_payload_rd_ptr.value)
    iface.drive_partial_flush(flush_tag=10, head_tag=0)
    await clock_cycle(dut)
    iface.clear_partial_flush()
    await clock_cycle(dut)

    assert int(dut.fifo_count.value) == 1
    assert int(dut.mult_payload_rd_ptr.value) == (mult_rd_before + 1) % 16
    assert int(dut.fma_payload_rd_ptr.value) == fma_rd_before
    assert_completion(iface.read_fu_complete(), tag=5, value=RES_7_0)

    iface.set_accepted(True)
    await clock_cycle(dut)
    assert not iface.read_fu_complete()["valid"]


# ============================================================================
# Queue architecture: full flush resets and safely reuses local RAM pointers
# ============================================================================
@cocotb.test()
async def test_full_flush_reuses_payload_ram_entries(dut: Any) -> None:
    """Post-flush payloads overwrite address zero and never expose stale data."""
    iface = await setup(dut)
    iface.set_accepted(False)

    await issue_once(
        dut,
        iface,
        rob_tag=1,
        op=OP_FMUL_S,
        src1_value=SRC_POS_ZERO,
        src2_value=SRC_POS_INF,
    )
    await issue_once(
        dut,
        iface,
        rob_tag=2,
        op=OP_FMADD_S,
        src1_value=SRC_POS_ZERO,
        src2_value=SRC_POS_INF,
        src3_value=SRC_1_0,
    )
    await wait_for_fifo_count(dut, 2)
    assert int(dut.mult_payload_wr_ptr.value) == 1
    assert int(dut.fma_payload_wr_ptr.value) == 1

    iface.drive_flush()
    await clock_cycle(dut)
    iface.clear_flush()
    assert int(dut.fifo_count.value) == 0
    assert int(dut.mult_payload_rd_ptr.value) == 0
    assert int(dut.mult_payload_wr_ptr.value) == 0
    assert int(dut.fma_payload_rd_ptr.value) == 0
    assert int(dut.fma_payload_wr_ptr.value) == 0
    assert not iface.read_fu_complete()["valid"]

    await issue_once(
        dut,
        iface,
        rob_tag=3,
        op=OP_FMUL_S,
        src1_value=SRC_2_0,
        src2_value=SRC_3_0,
    )
    await issue_once(
        dut,
        iface,
        rob_tag=4,
        op=OP_FMADD_S,
        src1_value=SRC_2_0,
        src2_value=SRC_3_0,
        src3_value=SRC_1_0,
    )
    await wait_for_fifo_count(dut, 2)

    # Wait beyond the one-cycle bypass: this value must now come from the RAM
    # location that contained the pre-flush invalid result.
    for _ in range(3):
        await clock_cycle(dut)
        assert_completion(iface.read_fu_complete(), tag=3, value=RES_6_0)

    iface.set_accepted(True)
    await clock_cycle(dut)
    assert_completion(iface.read_fu_complete(), tag=4, value=RES_7_0)
    await clock_cycle(dut)
    assert not iface.read_fu_complete()["valid"]
