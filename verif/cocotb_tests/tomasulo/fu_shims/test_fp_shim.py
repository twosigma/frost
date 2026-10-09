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

"""FP shim tests that drive fp_engine without an RS or CDB adapter.

The engine runs one operation at a time and pulses its result for one cycle.
Random arithmetic expectations use exact fractions rounded to double;
square root uses math.sqrt.
"""

import math
import random
import struct
from fractions import Fraction
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from .fp_shim_interface import FpShimInterface, _parse_instr_op_enum, nan_box_f32

CLOCK_PERIOD_NS = 10

_OPS = _parse_instr_op_enum()

RM_RNE = 0
RM_RTZ = 1
RM_RDN = 2
RM_RUP = 3
RM_RMM = 4

FLAG_NV = 0x10
FLAG_NX = 0x01

# Longest engine operation, with margin (the slowest, a double-precision FMA
# on subnormal operands, takes 139 cycles).
MAX_LATENCY = 200

DP_1_0 = 0x3FF0_0000_0000_0000
DP_3_0 = 0x4008_0000_0000_0000
DP_7_0 = 0x401C_0000_0000_0000
DP_2_POW_M60 = 0x3C30_0000_0000_0000  # 2^-60
DP_NEG_3_5 = 0xC00C_0000_0000_0000

SP_1_0 = 0x3F80_0000
SP_1_5 = 0x3FC0_0000
SP_2_5 = 0x4020_0000
SP_3_0 = 0x4040_0000
SP_3_75 = 0x4070_0000
SP_THIRD_RNE = 0x3EAA_AAAB
SP_THIRD_RTZ = 0x3EAA_AAAA
SP_CANONICAL_NAN = 0x7FC0_0000


def dp_bits(x: float) -> int:
    """Return the IEEE 754 double-precision encoding of x."""
    return int(struct.unpack("<Q", struct.pack("<d", x))[0])


def dp_value(bits: int) -> float:
    """Return the double whose encoding is bits."""
    return float(struct.unpack("<d", struct.pack("<Q", bits))[0])


def random_normal_dp(rng: random.Random, exp_range: int = 30) -> int:
    """Return a random normal double with an unbiased exponent in +/-exp_range."""
    sign = rng.getrandbits(1)
    exponent = rng.randint(-exp_range, exp_range) + 1023
    fraction = rng.getrandbits(52)
    return (sign << 63) | (exponent << 52) | fraction


def rne_reference(op: str, a: int, b: int, c: int) -> tuple[int, int]:
    """Round-to-nearest-even result and flags for a double op on normal operands.

    The operands stay far from the overflow and underflow thresholds, so the
    only flag an operation can raise is NX, set when the rounded result
    differs from the exact one.
    """
    fa, fb, fc = Fraction(dp_value(a)), Fraction(dp_value(b)), Fraction(dp_value(c))
    if op == "FSQRT_D":
        result = math.sqrt(dp_value(a))
        exact = Fraction(result) * Fraction(result) == fa
        return dp_bits(result), (0 if exact else FLAG_NX)
    exact_value = {
        "FADD_D": fa + fb,
        "FSUB_D": fa - fb,
        "FMUL_D": fa * fb,
        "FDIV_D": fa / fb,
        "FMADD_D": fa * fb + fc,
        "FMSUB_D": fa * fb - fc,
        "FNMSUB_D": -(fa * fb) + fc,
        "FNMADD_D": -(fa * fb) - fc,
    }[op]
    # Fraction -> float is correctly rounded, ties to even.
    result = float(exact_value)
    return dp_bits(result), (0 if Fraction(result) == exact_value else FLAG_NX)


async def setup(dut: Any) -> FpShimInterface:
    """Start the clock, reset the DUT, and return the interface."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    iface = FpShimInterface(dut)
    await iface.reset()
    return iface


def drive(
    iface: FpShimInterface,
    tag: int,
    op: str,
    a: int,
    b: int = 0,
    c: int = 0,
    rm: int = RM_RNE,
) -> None:
    """Drive a valid issue for the op named op (call on a falling edge)."""
    iface.drive_issue(
        valid=True,
        rob_tag=tag,
        op=_OPS[op],
        src1_value=a,
        src2_value=b,
        src3_value=c,
        rm=rm,
    )


async def issue(
    iface: FpShimInterface,
    tag: int,
    op: str,
    a: int,
    b: int = 0,
    c: int = 0,
    rm: int = RM_RNE,
) -> None:
    """Present one issue for one cycle, from a falling edge, while not busy."""
    assert not iface.read_busy(), "issue driven while the shim is busy"
    drive(iface, tag, op, a, b, c, rm)
    await RisingEdge(iface.clock)
    await FallingEdge(iface.clock)
    iface.clear_issue()


async def run_to_result(iface: FpShimInterface) -> tuple[int, dict]:
    """Wait for the result after an issue; check the busy window on the way.

    Called on the falling edge after the issue's rising edge. Returns the
    number of falling edges up to and including the result cycle, and the
    result. Busy must stay high through the result cycle and drop right after
    it, and the result must be valid for exactly one cycle.
    """
    for cycle in range(1, MAX_LATENCY + 1):
        assert iface.read_busy(), f"busy dropped before the result (cycle {cycle})"
        result = iface.read_fu_complete()
        if result["valid"]:
            await RisingEdge(iface.clock)
            await FallingEdge(iface.clock)
            assert not iface.read_busy(), "busy stayed high after the result cycle"
            assert not iface.read_fu_complete()["valid"], "result valid for two cycles"
            return cycle, result
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
    raise AssertionError(f"no result within {MAX_LATENCY} cycles")


async def expect_no_result(iface: FpShimInterface, cycles: int = MAX_LATENCY) -> None:
    """Check that the shim stays idle and silent for the given cycles."""
    for _ in range(cycles):
        assert not iface.read_busy(), "shim busy with no operation in flight"
        assert not iface.read_fu_complete()["valid"], "result from a flushed operation"
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)


async def check_op(
    iface: FpShimInterface,
    tag: int,
    op: str,
    a: int,
    b: int,
    c: int,
    rm: int,
    expected: int,
    expected_flags: int,
) -> int:
    """Issue one operation, check its result, and return its latency."""
    await issue(iface, tag, op, a, b, c, rm)
    latency, result = await run_to_result(iface)
    assert result["tag"] == tag, f"{op}: tag {result['tag']} != {tag}"
    assert result["value"] == expected, (
        f"{op} rm={rm}: result {result['value']:#018x} != {expected:#018x}"
    )
    assert result["fp_flags"] == expected_flags, (
        f"{op} rm={rm}: flags {result['fp_flags']:#04x} != {expected_flags:#04x}"
    )
    assert not result["exception"], f"{op}: unexpected exception"
    return latency


@cocotb.test()
async def test_double_ops_through_shim(dut: Any) -> None:
    """Check operand, opcode, and tag routing with distinct random sources."""
    iface = await setup(dut)
    rng = random.Random(0x5EED_F9)
    ops = [
        "FADD_D",
        "FSUB_D",
        "FMUL_D",
        "FDIV_D",
        "FSQRT_D",
        "FMADD_D",
        "FMSUB_D",
        "FNMSUB_D",
        "FNMADD_D",
    ]
    tag = 0
    for _ in range(40):
        for op in ops:
            a = random_normal_dp(rng)
            if op == "FSQRT_D":
                a &= (1 << 63) - 1
            b = random_normal_dp(rng)
            c = random_normal_dp(rng)
            expected, flags = rne_reference(op, a, b, c)
            await check_op(iface, tag, op, a, b, c, RM_RNE, expected, flags)
            tag = (tag + 7) % 32


@cocotb.test()
async def test_rounding_mode_reaches_engine(dut: Any) -> None:
    """Check inexact results for each static rounding mode."""
    iface = await setup(dut)
    up = DP_1_0 + 1  # 1 + 2^-52
    neg_one = DP_1_0 | (1 << 63)
    neg_small = DP_2_POW_M60 | (1 << 63)
    cases = [
        (DP_1_0, DP_2_POW_M60, RM_RNE, DP_1_0),
        (DP_1_0, DP_2_POW_M60, RM_RTZ, DP_1_0),
        (DP_1_0, DP_2_POW_M60, RM_RDN, DP_1_0),
        (DP_1_0, DP_2_POW_M60, RM_RUP, up),
        (DP_1_0, DP_2_POW_M60, RM_RMM, DP_1_0),
        (neg_one, neg_small, RM_RDN, up | (1 << 63)),
        (neg_one, neg_small, RM_RUP, neg_one),
    ]
    for tag, (a, b, rm, expected) in enumerate(cases):
        await check_op(iface, tag, "FADD_D", a, b, 0, rm, expected, FLAG_NX)

    one_s, three_s = nan_box_f32(SP_1_0), nan_box_f32(SP_3_0)
    await check_op(
        iface,
        9,
        "FDIV_S",
        one_s,
        three_s,
        0,
        RM_RNE,
        nan_box_f32(SP_THIRD_RNE),
        FLAG_NX,
    )
    await check_op(
        iface,
        10,
        "FDIV_S",
        one_s,
        three_s,
        0,
        RM_RTZ,
        nan_box_f32(SP_THIRD_RTZ),
        FLAG_NX,
    )


@cocotb.test()
async def test_single_precision_and_integer_results(dut: Any) -> None:
    """NaN-boxed single results, unboxed inputs, and an integer result."""
    iface = await setup(dut)
    await check_op(
        iface,
        1,
        "FMUL_S",
        nan_box_f32(SP_1_5),
        nan_box_f32(SP_2_5),
        0,
        RM_RNE,
        nan_box_f32(SP_3_75),
        0,
    )
    # A single-precision operand that is not NaN-boxed reads as the canonical
    # NaN; adding a quiet NaN raises no flag.
    await check_op(
        iface,
        2,
        "FADD_S",
        SP_1_5,
        nan_box_f32(SP_1_0),
        0,
        RM_RNE,
        nan_box_f32(SP_CANONICAL_NAN),
        0,
    )
    # FCVT.W.D rounds -3.5 to even (-4) and sign-extends the 32-bit result.
    await check_op(
        iface, 3, "FCVT_W_D", DP_NEG_3_5, 0, 0, RM_RNE, 0xFFFF_FFFF_FFFF_FFFC, FLAG_NX
    )
    # Invalid: square root of a negative number.
    await check_op(
        iface,
        4,
        "FSQRT_D",
        DP_3_0 | (1 << 63),
        0,
        0,
        RM_RNE,
        0x7FF8_0000_0000_0000,
        FLAG_NV,
    )


@cocotb.test()
async def test_back_to_back_issue(dut: Any) -> None:
    """A new operation issued on the first idle cycle after a result."""
    iface = await setup(dut)
    first, _ = rne_reference("FDIV_D", DP_1_0, DP_3_0, 0)
    second, _ = rne_reference("FMUL_D", DP_3_0, DP_7_0, 0)
    await issue(iface, 5, "FDIV_D", DP_1_0, DP_3_0)
    _, result = await run_to_result(iface)
    assert (result["tag"], result["value"]) == (5, first)
    # run_to_result returns on the first idle cycle's falling edge.
    await issue(iface, 6, "FMUL_D", DP_3_0, DP_7_0)
    _, result = await run_to_result(iface)
    assert (result["tag"], result["value"]) == (6, second)


@cocotb.test()
async def test_full_flush_at_every_cycle(dut: Any) -> None:
    """Flush a divide before its result cycle, then reuse its tag.

    The engine must be idle on the next cycle and never return the killed
    result. The replacement operation must complete with its own result.
    """
    iface = await setup(dut)
    expected, flags = rne_reference("FDIV_D", DP_1_0, DP_3_0, 0)
    latency = await check_op(
        iface, 12, "FDIV_D", DP_1_0, DP_3_0, 0, RM_RNE, expected, flags
    )
    replay, replay_flags = rne_reference("FSUB_D", DP_7_0, DP_3_0, 0)

    for flush_cycle in range(1, latency):
        await issue(iface, 12, "FDIV_D", DP_1_0, DP_3_0)
        for _ in range(flush_cycle - 1):
            assert not iface.read_fu_complete()["valid"]
            await RisingEdge(iface.clock)
            await FallingEdge(iface.clock)
        assert iface.read_busy()
        iface.drive_flush()
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
        iface.clear_flush()
        await expect_no_result(iface, latency + 4)
        await check_op(
            iface, 12, "FSUB_D", DP_7_0, DP_3_0, 0, RM_RNE, replay, replay_flags
        )


@cocotb.test()
async def test_partial_flush(dut: Any) -> None:
    """A partial flush kills a younger operation and spares an older one.

    Ages are measured from the ROB head, including across tag wraparound.
    """
    iface = await setup(dut)
    expected, flags = rne_reference("FDIV_D", DP_7_0, DP_3_0, 0)
    # (operation tag, flush tag, head, killed)
    cases = [
        (3, 5, 0, False),  # older than the flush point
        (5, 5, 0, False),  # the flush point itself survives
        (6, 5, 0, True),  # younger
        (1, 31, 30, True),  # younger across wraparound (ages 3 and 1)
        (31, 1, 30, False),  # older across wraparound (ages 1 and 3)
    ]
    for tag, flush_tag, head, killed in cases:
        await issue(iface, tag, "FDIV_D", DP_7_0, DP_3_0)
        for _ in range(10):
            await RisingEdge(iface.clock)
            await FallingEdge(iface.clock)
        iface.drive_partial_flush(flush_tag, head)
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
        iface.clear_partial_flush()
        if killed:
            await expect_no_result(iface)
        else:
            _, result = await run_to_result(iface)
            assert (result["tag"], result["value"], result["fp_flags"]) == (
                tag,
                expected,
                flags,
            ), f"tag {tag} flush tag {flush_tag} head {head}"


@cocotb.test()
async def test_issue_on_flush_cycle(dut: Any) -> None:
    """An issue that its own cycle's flush covers never starts the engine."""
    iface = await setup(dut)
    expected, flags = rne_reference("FMUL_D", DP_3_0, DP_7_0, 0)

    # Full flush.
    drive(iface, 4, "FMUL_D", DP_3_0, DP_7_0)
    iface.drive_flush()
    await RisingEdge(iface.clock)
    await FallingEdge(iface.clock)
    iface.clear_issue()
    iface.clear_flush()
    await expect_no_result(iface, 40)

    # Partial flush covering the issue (tag 9 is younger than flush tag 8).
    drive(iface, 9, "FMUL_D", DP_3_0, DP_7_0)
    iface.drive_partial_flush(8, 0)
    await RisingEdge(iface.clock)
    await FallingEdge(iface.clock)
    iface.clear_issue()
    iface.clear_partial_flush()
    await expect_no_result(iface, 40)

    # Partial flush that does not cover the issue: it starts and completes.
    drive(iface, 7, "FMUL_D", DP_3_0, DP_7_0)
    iface.drive_partial_flush(8, 0)
    await RisingEdge(iface.clock)
    await FallingEdge(iface.clock)
    iface.clear_issue()
    iface.clear_partial_flush()
    _, result = await run_to_result(iface)
    assert (result["tag"], result["value"], result["fp_flags"]) == (7, expected, flags)


@cocotb.test()
async def test_flush_on_result_cycle(dut: Any) -> None:
    """A result-cycle flush leaves the result visible until the next edge.

    The CDB arbiter suppresses broadcasts on a full flush; the adapter filters
    partial flushes. The engine returns to idle on the next cycle.
    """
    iface = await setup(dut)
    expected, flags = rne_reference("FDIV_D", DP_1_0, DP_7_0, 0)
    latency = await check_op(
        iface, 2, "FDIV_D", DP_1_0, DP_7_0, 0, RM_RNE, expected, flags
    )

    await issue(iface, 2, "FDIV_D", DP_1_0, DP_7_0)
    for _ in range(latency - 1):
        assert not iface.read_fu_complete()["valid"]
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
    result = iface.read_fu_complete()
    assert result["valid"] and result["tag"] == 2 and result["value"] == expected
    iface.drive_flush()
    await RisingEdge(iface.clock)
    await FallingEdge(iface.clock)
    iface.clear_flush()
    await expect_no_result(iface, 20)
