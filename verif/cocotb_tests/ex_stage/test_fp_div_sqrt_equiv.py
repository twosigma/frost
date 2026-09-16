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

"""Equivalence of fp_div_sqrt_iter with the fp_divider and fp_sqrt pipelines.

The harness runs both sides on the same operand and compares result and flags
bit for bit. This module drives the directed corner list through the harness's
injection port, then hands over to its internal random generator and checks the
counters.
"""

import os
import struct
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

CLOCK_PERIOD_NS = 10

# Cycles a single operation needs at most (65 for double precision) plus the
# harness's launch and compare cycles.
VECTOR_CYCLES = 80

# A killed vector runs the operation twice: up to the clamped kill delay, the
# drain until the reference retires, then the whole replay.
KILL_VECTOR_CYCLES = 220

# The random sweep's vector count comes from the harness parameter. The test
# polls in blocks and gives up after this many cycles per vector on average.
SWEEP_CYCLE_MARGIN = 4


def sp(value: float) -> int:
    """Return the single-precision bit pattern of *value*."""
    return int(struct.unpack("<I", struct.pack("<f", value))[0])


def dp(value: float) -> int:
    """Return the double-precision bit pattern of *value*."""
    return int(struct.unpack("<Q", struct.pack("<d", value))[0])


# Single-precision corner operands
SP_OPERANDS = {
    "zero": 0x0000_0000,
    "neg_zero": 0x8000_0000,
    "min_subnormal": 0x0000_0001,
    "max_subnormal": 0x007F_FFFF,
    "mid_subnormal": 0x0040_0000,
    "min_normal": 0x0080_0000,
    "max_normal": 0x7F7F_FFFF,
    "one": sp(1.0),
    "two": sp(2.0),
    "three": sp(3.0),
    "four": sp(4.0),
    "six": sp(6.0),
    "neg_one": sp(-1.0),
    "half_ulp_tie": 0x3F80_0001,
    "all_frac_ones": 0x3FFF_FFFF,
    "inf": 0x7F80_0000,
    "neg_inf": 0xFF80_0000,
    "qnan": 0x7FC0_0000,
    "snan": 0x7F80_0001,
    "neg_snan": 0xFF80_0001,
}

# Double-precision corner operands
DP_OPERANDS = {
    "zero": 0x0000_0000_0000_0000,
    "neg_zero": 0x8000_0000_0000_0000,
    "min_subnormal": 0x0000_0000_0000_0001,
    "max_subnormal": 0x000F_FFFF_FFFF_FFFF,
    "mid_subnormal": 0x0008_0000_0000_0000,
    "min_normal": 0x0010_0000_0000_0000,
    "max_normal": 0x7FEF_FFFF_FFFF_FFFF,
    "one": dp(1.0),
    "two": dp(2.0),
    "three": dp(3.0),
    "four": dp(4.0),
    "six": dp(6.0),
    "nine": dp(9.0),
    "neg_one": dp(-1.0),
    "half_ulp_tie": 0x3FF0_0000_0000_0001,
    "all_frac_ones": 0x3FFF_FFFF_FFFF_FFFF,
    "inf": 0x7FF0_0000_0000_0000,
    "neg_inf": 0xFFF0_0000_0000_0000,
    "qnan": 0x7FF8_0000_0000_0000,
    "snan": 0x7FF0_0000_0000_0001,
    "neg_snan": 0xFFF0_0000_0000_0001,
}

# Operand pairs the divide corner list walks, by name.
DIV_PAIRS = [
    ("six", "two"),
    ("one", "three"),
    ("one", "zero"),
    ("neg_one", "zero"),
    ("zero", "zero"),
    ("zero", "one"),
    ("neg_zero", "one"),
    ("one", "neg_zero"),
    ("inf", "inf"),
    ("inf", "two"),
    ("two", "inf"),
    ("neg_inf", "two"),
    ("qnan", "one"),
    ("one", "qnan"),
    ("snan", "one"),
    ("one", "snan"),
    ("neg_snan", "snan"),
    ("max_normal", "min_subnormal"),
    ("min_subnormal", "max_normal"),
    ("max_normal", "min_normal"),
    ("min_normal", "max_normal"),
    ("min_subnormal", "two"),
    ("two", "min_subnormal"),
    ("max_subnormal", "min_subnormal"),
    ("min_subnormal", "max_subnormal"),
    ("mid_subnormal", "three"),
    ("all_frac_ones", "three"),
    ("half_ulp_tie", "two"),
    ("one", "half_ulp_tie"),
    ("three", "all_frac_ones"),
    ("max_normal", "max_normal"),
    ("min_subnormal", "min_subnormal"),
    ("one", "one"),
]

# Operands the square-root corner list walks, by name.
SQRT_OPERANDS = [
    "zero",
    "neg_zero",
    "one",
    "two",
    "three",
    "four",
    "six",
    "neg_one",
    "neg_inf",
    "inf",
    "qnan",
    "snan",
    "neg_snan",
    "min_subnormal",
    "max_subnormal",
    "mid_subnormal",
    "min_normal",
    "max_normal",
    "half_ulp_tie",
    "all_frac_ones",
]

ROUNDING_MODES = [0, 1, 2, 3, 4, 5, 6, 7]


def _init_inputs(dut: Any) -> None:
    """Drive every harness input to a safe default."""
    dut.i_gen_enable.value = 0
    dut.i_seed.value = 0x0123_4567_89AB_CDEF
    dut.i_ext_valid.value = 0
    dut.i_ext_is_sqrt.value = 0
    dut.i_ext_is_double.value = 0
    dut.i_ext_a.value = 0
    dut.i_ext_b.value = 0
    dut.i_ext_rm.value = 0
    dut.i_kill_enable.value = 0
    dut.i_kill_delay.value = 0


async def setup(dut: Any, seed: int = 0x0123_4567_89AB_CDEF) -> None:
    """Start the clock and release reset with *seed* loaded into the generator."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    _init_inputs(dut)
    dut.i_seed.value = seed & ((1 << 64) - 1)
    dut.i_rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst_n.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)


def _failure_text(dut: Any) -> str:
    """Return the harness's latched first mismatch as readable text."""
    if not int(dut.o_fail_valid.value):
        return "no mismatch latched"
    kind = "sqrt" if int(dut.o_fail_is_sqrt.value) else "div"
    width = "d" if int(dut.o_fail_is_double.value) else "s"
    return (
        f"{kind}.{width} rm={int(dut.o_fail_rm.value)} "
        f"a=0x{int(dut.o_fail_a.value):016X} b=0x{int(dut.o_fail_b.value):016X} "
        f"unit=0x{int(dut.o_fail_dut.value):016X}/"
        f"0x{int(dut.o_fail_dut_flags.value):02X} "
        f"reference=0x{int(dut.o_fail_ref.value):016X}/"
        f"0x{int(dut.o_fail_ref_flags.value):02X}"
    )


async def _inject(
    dut: Any,
    is_sqrt: bool,
    is_double: bool,
    operand_a: int,
    operand_b: int,
    rm: int,
    cycles: int = VECTOR_CYCLES,
) -> None:
    """Run one directed vector through the harness and wait for its compare."""
    start_count = int(dut.o_vectors.value)

    dut.i_ext_is_sqrt.value = 1 if is_sqrt else 0
    dut.i_ext_is_double.value = 1 if is_double else 0
    dut.i_ext_a.value = operand_a
    dut.i_ext_b.value = operand_b
    dut.i_ext_rm.value = rm
    dut.i_ext_valid.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_ext_valid.value = 0

    for _ in range(cycles):
        await RisingEdge(dut.i_clk)
        if int(dut.o_vectors.value) != start_count:
            return
    raise AssertionError(
        f"vector did not complete in {cycles} cycles: "
        f"sqrt={is_sqrt} double={is_double} a=0x{operand_a:016X} b=0x{operand_b:016X}"
    )


def _check_counters(dut: Any, expected_vectors: int | None = None) -> None:
    """Fail on any mismatch, latency skew or timeout the harness recorded."""
    mismatches = int(dut.o_mismatches.value)
    skews = int(dut.o_skews.value)
    timeouts = int(dut.o_timeouts.value)
    vectors = int(dut.o_vectors.value)

    assert mismatches == 0, (
        f"{mismatches} of {vectors} vectors disagreed with the reference; "
        f"first: {_failure_text(dut)}"
    )
    assert timeouts == 0, f"{timeouts} of {vectors} vectors never completed"
    leaks = int(dut.o_kill_leaks.value)
    stuck = int(dut.o_kill_stuck.value)
    assert leaks == 0, f"{leaks} killed operations still produced a completion"
    assert stuck == 0, f"{stuck} killed operations left the unit busy"
    assert skews == 0, (
        f"{skews} of {vectors} vectors completed on different cycles; the "
        "iterative unit must keep the reference's 36/65-cycle latency"
    )
    assert (
        expected_vectors is None or vectors == expected_vectors
    ), f"expected {expected_vectors} vectors, harness counted {vectors}"


# ============================================================================
# Test 1: directed divide corners
# ============================================================================
@cocotb.test()
async def test_directed_divide(dut: Any) -> None:
    """Every divide corner pair, both precisions, every rounding mode."""
    await setup(dut)

    count = 0
    for rm in ROUNDING_MODES:
        for name_a, name_b in DIV_PAIRS:
            await _inject(
                dut, False, False, SP_OPERANDS[name_a], SP_OPERANDS[name_b], rm
            )
            count += 1
            await _inject(
                dut, False, True, DP_OPERANDS[name_a], DP_OPERANDS[name_b], rm
            )
            count += 1

    _check_counters(dut, count)
    dut._log.info("directed divide vectors: %d", count)


# ============================================================================
# Test 2: directed square-root corners
# ============================================================================
@cocotb.test()
async def test_directed_sqrt(dut: Any) -> None:
    """Every square-root corner operand, both precisions, every rounding mode."""
    await setup(dut)

    count = 0
    for rm in ROUNDING_MODES:
        for name in SQRT_OPERANDS:
            await _inject(dut, True, False, SP_OPERANDS[name], 0, rm)
            count += 1
            await _inject(dut, True, True, DP_OPERANDS[name], 0, rm)
            count += 1

    _check_counters(dut, count)
    dut._log.info("directed sqrt vectors: %d", count)


# ============================================================================
# Test 3: exhaustive small-mantissa divides
# ============================================================================
@cocotb.test()
async def test_mantissa_sweep(dut: Any) -> None:
    """Sweep the low mantissa bits of both operands to walk rounding boundaries."""
    await setup(dut)

    count = 0
    for rm in (0, 1, 2, 3, 4):
        for step_a in range(8):
            for step_b in range(8):
                operand_a = SP_OPERANDS["one"] | step_a
                operand_b = SP_OPERANDS["one"] | (step_b << 1)
                await _inject(dut, False, False, operand_a, operand_b, rm)
                count += 1
        for step_a in range(8):
            operand_a = DP_OPERANDS["two"] | step_a
            await _inject(dut, True, True, operand_a, 0, rm)
            count += 1

    _check_counters(dut, count)
    dut._log.info("mantissa sweep vectors: %d", count)


# ============================================================================
# Test 4: randomized sweep driven by the harness generator
# ============================================================================
@cocotb.test()
async def test_random_sweep(dut: Any) -> None:
    """Run the harness's random generator to its vector target."""
    seed = int(os.environ.get("FROST_FP_EQUIV_SEED", "0x20260915"), 0)
    await setup(dut, seed=seed)

    target = int(dut.o_vector_target.value)
    dut.i_gen_enable.value = 1

    budget = target * VECTOR_CYCLES * SWEEP_CYCLE_MARGIN + 10000
    elapsed = 0
    block = 5000
    while elapsed < budget:
        await ClockCycles(dut.i_clk, block)
        elapsed += block
        if int(dut.o_done.value) or int(dut.o_mismatches.value):
            break

    dut.i_gen_enable.value = 0
    await RisingEdge(dut.i_clk)

    _check_counters(dut, target)
    dut._log.info("random sweep vectors: %d (seed 0x%X)", target, seed)


# ============================================================================
# Test 5: the kill path
# ============================================================================
@cocotb.test()
async def test_kill_leaves_no_residue(dut: Any) -> None:
    """Killing an operation mid-flight drops it and leaves the next one exact."""
    await setup(dut)

    dut.i_kill_enable.value = 1

    # Every state of the sequence gets a kill: unpack, init, setup, the first
    # and last iteration steps, and each of the rounding/output stages. The
    # harness clamps a delay past the last cycle before completion, so the
    # large values land on the final states of each precision.
    delays = [1, 2, 3, 4, 5, 17, 33, 34, 35, 40, 50, 62, 63, 64, 90]
    count = 0
    for delay in delays:
        dut.i_kill_delay.value = delay
        for rm in (0, 1, 4):
            await _inject(
                dut,
                False,
                False,
                SP_OPERANDS["all_frac_ones"],
                SP_OPERANDS["three"],
                rm,
                cycles=KILL_VECTOR_CYCLES,
            )
            count += 1
            await _inject(
                dut,
                False,
                True,
                DP_OPERANDS["one"],
                DP_OPERANDS["three"],
                rm,
                cycles=KILL_VECTOR_CYCLES,
            )
            count += 1
            await _inject(
                dut,
                True,
                True,
                DP_OPERANDS["max_subnormal"],
                0,
                rm,
                cycles=KILL_VECTOR_CYCLES,
            )
            count += 1

    dut.i_kill_enable.value = 0
    await RisingEdge(dut.i_clk)

    kills = int(dut.o_kills.value)
    assert kills == count, f"expected {count} kills, harness counted {kills}"
    _check_counters(dut, count)

    # The replays after the kills must still agree with the reference, and a
    # plain vector after the mode is switched off must too.
    await _inject(dut, True, False, SP_OPERANDS["two"], 0, 0)
    _check_counters(dut, count + 1)
    dut._log.info("killed vectors: %d", kills)
