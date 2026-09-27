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

"""Equivalence of fp_engine with Berkeley SoftFloat for every F and D compute op.

The harness computes the reference for each vector through DPI-C and compares
the engine's value and flags bit for bit. These tests drive directed corners
through its injection port (special operands, cancellation, overflow and
underflow boundaries, conversion limits), run its internal random generator,
and kill operations mid-flight.
"""

import os
import random
import struct
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

from ..tomasulo.fu_shims.fp_add_shim_interface import _parse_instr_op_enum

CLOCK_PERIOD_NS = 10

# Longest engine latency plus the harness's launch and compare cycles.
VECTOR_CYCLES = 400
# A killed vector runs twice.
KILL_VECTOR_CYCLES = 900
# Cycles the random sweep may take per vector, on average.
SWEEP_CYCLES_PER_VECTOR = 200

ROUNDING_MODES = (0, 1, 2, 3, 4)
MASK64 = (1 << 64) - 1


def sp(value: float) -> int:
    """Return the single-precision bit pattern of *value*."""
    return int(struct.unpack("<I", struct.pack("<f", value))[0])


def dp(value: float) -> int:
    """Return the double-precision bit pattern of *value*."""
    return int(struct.unpack("<Q", struct.pack("<d", value))[0])


def box(bits32: int) -> int:
    """NaN-box a single-precision pattern into a 64-bit register value."""
    return 0xFFFF_FFFF_0000_0000 | (bits32 & 0xFFFF_FFFF)


SP_CORNERS = [
    0x0000_0000,  # +0
    0x8000_0000,  # -0
    0x0000_0001,  # smallest subnormal
    0x007F_FFFF,  # largest subnormal
    0x0040_0000,
    0x0080_0000,  # smallest normal
    0x0080_0001,
    0x7F7F_FFFF,  # largest normal
    0x7F7F_FFFE,
    sp(1.0),
    sp(-1.0),
    sp(1.5),
    sp(3.0),
    0x3F80_0001,  # 1 + ulp
    0x3FFF_FFFF,  # 2 - ulp
    0x3400_0000,  # 2^-23
    0x7F80_0000,  # +inf
    0xFF80_0000,  # -inf
    0x7FC0_0000,  # quiet NaN
    0x7F80_0001,  # signalling NaN
    0xFFC0_0001,  # negative quiet NaN with payload
    0x4F00_0000,  # 2^31
    0x5F00_0000,  # 2^63
]

DP_CORNERS = [
    0x0000_0000_0000_0000,
    0x8000_0000_0000_0000,
    0x0000_0000_0000_0001,
    0x000F_FFFF_FFFF_FFFF,
    0x0008_0000_0000_0000,
    0x0010_0000_0000_0000,
    0x0010_0000_0000_0001,
    0x7FEF_FFFF_FFFF_FFFF,
    0x7FEF_FFFF_FFFF_FFFE,
    dp(1.0),
    dp(-1.0),
    dp(1.5),
    dp(3.0),
    0x3FF0_0000_0000_0001,
    0x3FFF_FFFF_FFFF_FFFF,
    0x3CB0_0000_0000_0000,  # 2^-52
    0x7FF0_0000_0000_0000,
    0xFFF0_0000_0000_0000,
    0x7FF8_0000_0000_0000,
    0x7FF0_0000_0000_0001,
    0xFFF8_0000_0000_0001,
    0x41E0_0000_0000_0000,  # 2^31
    0x43E0_0000_0000_0000,  # 2^63
    0x380F_FFFF_E000_0000,  # rounds to the single-precision minimum normal
    0x47EF_FFFF_F000_0000,  # rounds to single-precision overflow
]

INT_CORNERS = [
    0,
    1,
    2,
    3,
    0x7FFF_FFFF,
    0x8000_0000,
    0xFFFF_FFFF,
    0x1_0000_0000,
    0x100_0001,  # 2^24 + 1
    0x100_0003,
    0x20_0000_0000_0001,  # 2^53 + 1
    0x20_0000_0000_0003,
    0x7FFF_FFFF_FFFF_FFFF,
    0x8000_0000_0000_0000,
    0xFFFF_FFFF_FFFF_FFFF,
    0xFFFF_FFFF_8000_0000,
    0x7FFF_FF80_0000_0000,
    0x7FFF_FF40_0000_0000,
]

TWO_SOURCE_OPS = [
    "FADD",
    "FSUB",
    "FMUL",
    "FDIV",
    "FMIN",
    "FMAX",
    "FEQ",
    "FLT",
    "FLE",
    "FSGNJ",
    "FSGNJN",
    "FSGNJX",
]
FMA_OPS = ["FMADD", "FMSUB", "FNMADD", "FNMSUB"]
ONE_SOURCE_OPS = ["FSQRT", "FCLASS"]
FP_TO_INT_OPS = ["FCVT_W", "FCVT_WU", "FCVT_L", "FCVT_LU"]
INT_TO_FP_OPS = ["W", "WU", "L", "LU"]


_INSTR_OPS = _parse_instr_op_enum()


def op_value(name: str) -> int:
    """Return the instr_op_e ordinal of *name*."""
    return _INSTR_OPS[name]


def _init_inputs(dut: Any) -> None:
    """Drive every harness input to a safe default."""
    dut.i_gen_enable.value = 0
    dut.i_seed.value = 0x0123_4567_89AB_CDEF
    dut.i_ext_valid.value = 0
    dut.i_ext_op.value = 0
    dut.i_ext_rm.value = 0
    dut.i_ext_a.value = 0
    dut.i_ext_b.value = 0
    dut.i_ext_c.value = 0
    dut.i_kill_enable.value = 0
    dut.i_kill_delay.value = 0


async def setup(dut: Any, seed: int = 0x0123_4567_89AB_CDEF) -> None:
    """Start the clock and release reset with *seed* loaded into the generator."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    _init_inputs(dut)
    dut.i_seed.value = seed & MASK64
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
    return (
        f"op={int(dut.o_fail_op.value)} rm={int(dut.o_fail_rm.value)} "
        f"a=0x{int(dut.o_fail_a.value):016X} b=0x{int(dut.o_fail_b.value):016X} "
        f"c=0x{int(dut.o_fail_c.value):016X} "
        f"engine=0x{int(dut.o_fail_dut.value):016X}/"
        f"0x{int(dut.o_fail_dut_flags.value):02X} "
        f"reference=0x{int(dut.o_fail_ref.value):016X}/"
        f"0x{int(dut.o_fail_ref_flags.value):02X}"
    )


class Injector:
    """Feed directed vectors through the harness port, back to back."""

    def __init__(self, dut: Any) -> None:
        """Bind to *dut* and start counting injected vectors."""
        self.dut = dut
        self.count = 0

    async def run(
        self,
        op: str,
        rm: int,
        a: int,
        b: int = 0,
        c: int = 0,
        cycles: int = VECTOR_CYCLES,
    ) -> None:
        """Inject one vector and wait until the harness has compared it."""
        dut = self.dut
        start = int(dut.o_vectors.value)
        dut.i_ext_op.value = op_value(op)
        dut.i_ext_rm.value = rm
        dut.i_ext_a.value = a & MASK64
        dut.i_ext_b.value = b & MASK64
        dut.i_ext_c.value = c & MASK64
        dut.i_ext_valid.value = 1
        await RisingEdge(dut.i_clk)
        dut.i_ext_valid.value = 0
        waited = 0
        while int(dut.o_vectors.value) == start:
            await ClockCycles(dut.i_clk, 4)
            waited += 4
            if waited > cycles:
                raise AssertionError(
                    f"{op} rm={rm} a=0x{a:016X} b=0x{b:016X} c=0x{c:016X} did not complete"
                )
        self.count += 1


def _check_counters(dut: Any, expected_vectors: int | None = None) -> None:
    """Fail on any mismatch, timeout or kill problem the harness recorded."""
    mismatches = int(dut.o_mismatches.value)
    timeouts = int(dut.o_timeouts.value)
    vectors = int(dut.o_vectors.value)
    assert mismatches == 0, (
        f"{mismatches} of {vectors} vectors disagreed with SoftFloat; "
        f"first: {_failure_text(dut)}"
    )
    assert timeouts == 0, f"{timeouts} of {vectors} vectors never completed"
    leaks = int(dut.o_kill_leaks.value)
    stuck = int(dut.o_kill_stuck.value)
    assert leaks == 0, f"{leaks} killed operations still produced a completion"
    assert stuck == 0, f"{stuck} killed operations left the engine busy"
    assert expected_vectors is None or vectors == expected_vectors, (
        f"expected {expected_vectors} vectors, harness counted {vectors}"
    )


# ============================================================================
# Test 1: special and boundary operands for every operation
# ============================================================================
@cocotb.test()
async def test_directed_corners(dut: Any) -> None:
    """Every operation on the corner operands at both precisions, every rounding mode."""
    await setup(dut)
    inj = Injector(dut)

    sp_ops = [box(v) for v in SP_CORNERS]
    for rm in ROUNDING_MODES:
        for suffix, corners in (("S", sp_ops), ("D", DP_CORNERS)):
            for i, a in enumerate(corners):
                for op in ONE_SOURCE_OPS:
                    await inj.run(f"{op}_{suffix}", rm, a)
                for op in FP_TO_INT_OPS:
                    await inj.run(f"{op}_{suffix}", rm, a)
                await inj.run("FCVT_D_S" if suffix == "S" else "FCVT_S_D", rm, a)
                for j, b in enumerate(corners):
                    # Every pair for the arithmetic ops; a subset for the rest.
                    ops = TWO_SOURCE_OPS if rm == 0 else TWO_SOURCE_OPS[:4]
                    for op in ops:
                        await inj.run(f"{op}_{suffix}", rm, a, b)
                    fma = FMA_OPS[(i + j) % len(FMA_OPS)]
                    await inj.run(
                        f"{fma}_{suffix}", rm, a, b, corners[(i * 7 + j) % len(corners)]
                    )
        for value in INT_CORNERS:
            for signed_value in (value, (-value) & MASK64):
                for form in INT_TO_FP_OPS:
                    await inj.run(f"FCVT_S_{form}", rm, signed_value)
                    await inj.run(f"FCVT_D_{form}", rm, signed_value)

    # NaN boxing: an improperly boxed single-precision operand reads as the
    # canonical NaN, except that FMV.X.W moves the raw low word.
    for raw in (0x0000_0000_3F80_0000, 0x7FFF_FFFF_3F80_0000, 0xFFFF_FFFE_3F80_0000):
        for op in ("FADD_S", "FMUL_S", "FMIN_S", "FEQ_S", "FSGNJ_S", "FSGNJN_S"):
            await inj.run(op, 0, raw, box(sp(2.0)))
            await inj.run(op, 0, box(sp(2.0)), raw)
        for op in ("FCLASS_S", "FSQRT_S", "FCVT_D_S", "FCVT_W_S", "FMV_X_W", "FMV_W_X"):
            await inj.run(op, 0, raw)
        await inj.run("FMV_D_X", 0, raw)
        await inj.run("FMV_X_D", 0, raw)

    _check_counters(dut, inj.count)
    dut._log.info("directed corner vectors: %d", inj.count)


# ============================================================================
# Test 2: cancellation in add and fused multiply-add
# ============================================================================
@cocotb.test()
async def test_cancellation(dut: Any) -> None:
    """Sums and FMA results that cancel, including an addend one binade above the product."""
    await setup(dut)
    inj = Injector(dut)
    rng = random.Random(0x5EED_0001)

    for _ in range(120):
        a = rng.uniform(0.5, 4.0) * 2.0 ** rng.randint(-60, 60)
        b = rng.uniform(0.5, 4.0) * 2.0 ** rng.randint(-60, 60)
        k = rng.randint(-2, 2)
        rm = rng.choice(ROUNDING_MODES)
        # Double: the addend cancels the rounded product, leaving its rounding
        # error; and a power-of-two addend just above a product below it.
        pd = dp(a * b)
        await inj.run("FMADD_D", rm, dp(a), dp(b), (pd ^ (1 << 63)) + k)
        await inj.run("FMSUB_D", rm, dp(a), dp(b), pd + k)
        near_two = dp(2.0) - 1 - rng.randint(0, 3)
        await inj.run("FMADD_D", rm, near_two, near_two, dp(-4.0) + k)
        await inj.run("FSUB_D", rm, dp(a), dp(a) + k)
        await inj.run("FADD_D", rm, dp(a), (dp(a) ^ (1 << 63)) + k)
        # Single: the product of two singles is exact in double precision, so
        # rounding it to single once gives the rounded single product.
        sa, sb = sp(a), sp(b)
        fa = struct.unpack("<f", struct.pack("<I", sa))[0]
        fb = struct.unpack("<f", struct.pack("<I", sb))[0]
        ps = sp(fa * fb)
        await inj.run("FMADD_S", rm, box(sa), box(sb), box((ps ^ 0x8000_0000) + k))
        await inj.run("FNMSUB_S", rm, box(sa), box(sb), box(ps + k))
        near_two_s = sp(2.0) - 1 - rng.randint(0, 3)
        await inj.run(
            "FMADD_S", rm, box(near_two_s), box(near_two_s), box(sp(-4.0) + k)
        )
        await inj.run("FSUB_S", rm, box(sa), box(sa + k))
        # A tiny subtrahend far below the other operand.
        await inj.run("FSUB_S", rm, box(sa), box(rng.getrandbits(31) & 0x0FFF_FFFF))
        await inj.run("FSUB_D", rm, dp(a), rng.getrandbits(62) & 0x1FFF_FFFF_FFFF_FFFF)

    _check_counters(dut, inj.count)
    dut._log.info("cancellation vectors: %d", inj.count)


# ============================================================================
# Test 3: conversions at the integer limits
# ============================================================================
@cocotb.test()
async def test_conversion_limits(dut: Any) -> None:
    """FCVT to and from integers at every range limit, tie, and rounding mode."""
    await setup(dut)
    inj = Injector(dut)

    values = [
        0.5, 1.5, 2.5, -0.5, -1.5, -2.5, 0.25, -0.75, 3.0, -3.0,
        2147483647.0, 2147483647.5, 2147483648.0, -2147483648.0, -2147483648.5,
        -2147483649.0, 4294967295.0, 4294967295.5, 4294967296.0, -1.0,
        9223372036854775807.0, 9223372036854775808.0, -9223372036854775808.0,
        18446744073709551615.0, 18446744073709551616.0, 1e-30, -1e-30,
    ]  # fmt: skip
    for rm in ROUNDING_MODES:
        for value in values:
            for k in (-1, 0, 1):
                for op in FP_TO_INT_OPS:
                    await inj.run(f"{op}_D", rm, dp(value) + k)
                    await inj.run(f"{op}_S", rm, box(sp(value) + k))
        for value in INT_CORNERS:
            for k in (-1, 0, 1):
                for form in INT_TO_FP_OPS:
                    await inj.run(f"FCVT_S_{form}", rm, value + k)
                    await inj.run(f"FCVT_D_{form}", rm, value + k)

    _check_counters(dut, inj.count)
    dut._log.info("conversion vectors: %d", inj.count)


# ============================================================================
# Test 4: randomized sweep driven by the harness generator
# ============================================================================
@cocotb.test()
async def test_random_sweep(dut: Any) -> None:
    """Run the harness's random generator to its vector target."""
    seed = int(os.environ.get("FROST_FP_EQUIV_SEED", "0x20260926"), 0)
    await setup(dut, seed=seed)

    target = int(dut.o_vector_target.value)
    dut.i_gen_enable.value = 1
    budget = target * SWEEP_CYCLES_PER_VECTOR + 10000
    elapsed = 0
    while elapsed < budget:
        await ClockCycles(dut.i_clk, 5000)
        elapsed += 5000
        if int(dut.o_done.value) or int(dut.o_mismatches.value):
            break
    dut.i_gen_enable.value = 0
    await RisingEdge(dut.i_clk)

    _check_counters(dut, target)
    dut._log.info(
        "random sweep vectors: %d (seed 0x%X, longest latency %d cycles)",
        target,
        seed,
        int(dut.o_max_latency.value),
    )


# ============================================================================
# Test 5: the kill path
# ============================================================================
@cocotb.test()
async def test_kill_leaves_no_residue(dut: Any) -> None:
    """Killing an operation at any cycle drops it and leaves the next one exact."""
    await setup(dut)
    inj = Injector(dut)
    dut.i_kill_enable.value = 1

    vectors = [
        ("FDIV_D", DP_CORNERS[13], DP_CORNERS[12], 0),
        ("FSQRT_S", box(sp(2.0)), 0, 0),
        ("FMADD_D", dp(1.5), dp(3.0), dp(-4.5)),
        ("FMUL_S", box(sp(1.5)), box(0x0000_0003), 0),
        ("FADD_D", DP_CORNERS[2], dp(-1.0), 0),
        ("FCVT_L_D", dp(-12345.75), 0, 0),
        ("FCVT_S_L", 0x0000_0000_0000_0005, 0, 0),
        ("FCVT_S_D", DP_CORNERS[23], 0, 0),
        ("FLT_D", dp(1.0), dp(2.0), 0),
    ]
    for delay in (0, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144):
        dut.i_kill_delay.value = delay
        for op, a, b, c in vectors:
            await inj.run(op, 0, a, b, c, cycles=KILL_VECTOR_CYCLES)

    dut.i_kill_enable.value = 0
    _check_counters(dut, inj.count)
    kills = int(dut.o_kills.value)
    assert kills > 0, "no operation was killed"
    dut._log.info("kill vectors: %d, kills: %d", inj.count, kills)
