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

Verifies FMUL_S, FMADD_S, and FMSUB_S operations through the shim,
including NaN-boxing of single-precision results, busy back-pressure,
and flush behavior.
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
F32_MAX_FINITE = 0x7F7F_FFFF
F32_POS_INF = 0x7F80_0000

# NaN-boxed 64-bit representations for driving src values
SRC_1_0 = NAN_BOX | F32_1_0
SRC_2_0 = NAN_BOX | F32_2_0
SRC_3_0 = NAN_BOX | F32_3_0
SRC_MAX_FINITE = NAN_BOX | F32_MAX_FINITE

# Expected NaN-boxed 64-bit results
RES_5_0 = NAN_BOX | F32_5_0
RES_6_0 = NAN_BOX | F32_6_0
RES_7_0 = NAN_BOX | F32_7_0
RES_POS_INF = NAN_BOX | F32_POS_INF

FP_FLAGS_OF_NX = 0x05

# Maximum cycles to wait for completion (FMUL 11 cycles, FMA 16 cycles)
MAX_LATENCY = 20


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
async def setup(dut: Any) -> FpMulShimInterface:
    """Start clock, reset DUT, and return the interface."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    iface = FpMulShimInterface(dut)
    await iface.reset()
    return iface


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


async def issue_aligned_fma_fmul_pair(
    dut: Any,
    iface: FpMulShimInterface,
    *,
    fma_tag: int,
    mult_tag: int,
    mult_src1: int = SRC_2_0,
    mult_src2: int = SRC_3_0,
) -> None:
    """Issue an FMA five cycles before an FMUL so both complete together."""
    iface.drive_issue(
        valid=True,
        rob_tag=fma_tag,
        op=OP_FMADD_S,
        src1_value=SRC_2_0,
        src2_value=SRC_3_0,
        src3_value=SRC_1_0,
    )
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)

    iface.drive_issue(valid=False, rob_tag=0, op=0, src1_value=0, src2_value=0)
    # Four idle issue edges put the FMUL issue edge five cycles after the FMA.
    for _ in range(4):
        await RisingEdge(dut.i_clk)
        await FallingEdge(dut.i_clk)

    iface.drive_issue(
        valid=True,
        rob_tag=mult_tag,
        op=OP_FMUL_S,
        src1_value=mult_src1,
        src2_value=mult_src2,
    )
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    iface.drive_issue(valid=False, rob_tag=0, op=0, src1_value=0, src2_value=0)


async def wait_for_simultaneous_subunit_completions(dut: Any) -> None:
    """Stop in the cycle before simultaneous FMUL/FMA results enter the FIFO."""
    for _ in range(MAX_LATENCY):
        await RisingEdge(dut.i_clk)
        await FallingEdge(dut.i_clk)
        if int(dut.mult_completion_valid.value) and int(dut.fma_completion_valid.value):
            return
    raise AssertionError("FMUL and FMA did not complete simultaneously")


def assert_completion(
    result: dict, *, tag: int, value: int, fp_flags: int, context: str
) -> None:
    """Check every payload field stored by the result FIFO."""
    assert result["valid"], f"{context}: expected a valid completion"
    assert result["tag"] == tag, f"{context}: expected tag={tag}, got {result['tag']}"
    assert (
        result["value"] == value
    ), f"{context}: expected value 0x{value:016X}, got 0x{result['value']:016X}"
    assert result["fp_flags"] == fp_flags, (
        f"{context}: expected fp_flags=0x{fp_flags:02X}, "
        f"got 0x{result['fp_flags']:02X}"
    )


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

    # Wait for completion
    result = await wait_for_complete(dut, iface)
    assert result["valid"], "Expected valid completion"

    # After completion, busy should still be low.
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

    # Clear issue and assert flush
    iface.drive_issue(valid=False, rob_tag=0, op=0, src1_value=0, src2_value=0)
    iface.drive_flush()

    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)

    iface.clear_flush()

    # Wait enough cycles for the operation to have completed (if not flushed)
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
# Test 8: Simultaneous FMUL/FMA completions survive FIFO backpressure
# ============================================================================
@cocotb.test()
async def test_simultaneous_fmul_fma_completion_backpressure(dut: Any) -> None:
    """Hold a two-result push, then drain all payload fields in FIFO order."""
    iface = await setup(dut)
    iface.drive_accepted(False)

    await issue_aligned_fma_fmul_pair(
        dut,
        iface,
        fma_tag=22,
        mult_tag=21,
        mult_src1=SRC_MAX_FINITE,
        mult_src2=SRC_2_0,
    )
    await wait_for_simultaneous_subunit_completions(dut)

    # Both writes enter the FIFO on this edge.  FMUL has the lower write slot
    # and FMA follows it when the subunits complete on the same cycle.
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    assert int(dut.fifo_count.value) == 2, "expected a two-result FIFO push"

    mult_result = iface.read_fu_complete()
    assert_completion(
        mult_result,
        tag=21,
        value=RES_POS_INF,
        fp_flags=FP_FLAGS_OF_NX,
        context="held FMUL",
    )

    # Backpressure must hold the complete payload, not just valid/tag.
    for _ in range(3):
        await RisingEdge(dut.i_clk)
        await FallingEdge(dut.i_clk)
        assert (
            iface.read_fu_complete() == mult_result
        ), "FMUL payload changed while i_mul_accepted was low"

    iface.drive_accepted(True)
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    assert_completion(
        iface.read_fu_complete(),
        tag=22,
        value=RES_7_0,
        fp_flags=0,
        context="drained FMA",
    )

    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    assert not iface.read_fu_complete()["valid"], "FIFO did not drain both results"


# ============================================================================
# Test 9: Same-edge partial flush compacts a surviving FMA result
# ============================================================================
@cocotb.test()
async def test_partial_flush_simultaneous_completion_compacts_fma(dut: Any) -> None:
    """Kill the FMUL as both subunits complete and keep the FMA at the head."""
    iface = await setup(dut)
    iface.drive_accepted(False)

    # With ROB head 0 and flush tag 10, tag 12 is younger and must be killed;
    # tag 8 is older and must survive.  The pair is timed to complete together.
    await issue_aligned_fma_fmul_pair(
        dut,
        iface,
        fma_tag=8,
        mult_tag=12,
    )
    await wait_for_simultaneous_subunit_completions(dut)

    # Assert the partial flush in the completion cycle.  Because the FMUL is
    # filtered, the FMA must use fifo_wr_ptr itself rather than leave slot zero
    # empty by offsetting from the raw FMUL pop.
    iface.drive_partial_flush(flush_tag=10, head_tag=0)
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    iface.clear_partial_flush()

    assert (
        int(dut.fifo_count.value) == 1
    ), "same-edge partial flush should enqueue only the surviving FMA"
    assert_completion(
        iface.read_fu_complete(),
        tag=8,
        value=RES_7_0,
        fp_flags=0,
        context="compacted FMA",
    )

    iface.drive_accepted(True)
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    assert not iface.read_fu_complete()["valid"], "flushed FMUL result reappeared"

    for _ in range(3):
        await RisingEdge(dut.i_clk)
        await FallingEdge(dut.i_clk)
        assert not iface.read_fu_complete()[
            "valid"
        ], "unexpected completion after draining the surviving FMA"
