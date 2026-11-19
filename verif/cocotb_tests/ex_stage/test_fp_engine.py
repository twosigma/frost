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

"""Compare fp_engine values and flags bit for bit with Berkeley SoftFloat.

The harness computes references through DPI-C. Drive directed vectors
through its injection port, run its random generator, and kill operations
in flight.
"""

import os
import random
import struct
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

from ..tomasulo.fu_shims.fp_shim_interface import _parse_instr_op_enum

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


def box16(bits16: int) -> int:
    """NaN-box a half-precision pattern into a 64-bit register value."""
    return 0xFFFF_FFFF_FFFF_0000 | (bits16 & 0xFFFF)


def hp(value: float) -> int:
    """Return the half-precision bit pattern of *value*."""
    return int(struct.unpack("<H", struct.pack("<e", value))[0])


HP_CORNERS = [
    0x0000,  # +0
    0x8000,  # -0
    0x0001,  # smallest subnormal
    0x8001,
    0x03FF,  # largest subnormal
    0x0200,
    0x0400,  # smallest normal
    0x0401,
    0x7BFF,  # largest normal (65504)
    0xFBFF,
    0x3C00,  # 1.0
    0xBC00,  # -1.0
    0x3C01,  # 1 + ulp
    0x3BFF,  # 1 - ulp/2
    0x7C00,  # +inf
    0xFC00,  # -inf
    0x7E00,  # canonical NaN
    0x7C01,  # signalling NaN
    0x7D55,  # signalling NaN with payload
    0xFE01,  # negative quiet NaN with payload
    0x5555,
    0xAAAA,
]


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
# Special and boundary operands
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
# Zfhmin: half-precision conversions and moves
# ============================================================================
def _half_boundary_singles() -> list[int]:
    """Single-precision patterns at the half range limits and rounding ties."""
    values = []
    # Around the largest half (65504), the overflow threshold (65520) and the
    # next binade; around the smallest normal, the subnormal steps and half
    # the smallest subnormal (2^-25), the underflow-to-zero tie.
    for centre in (
        65504.0, 65520.0, 65536.0, 2.0**-14, 2.0**-15, 2.0**-24, 2.0**-25,
        3 * 2.0**-25, 2.0**-26, 1.0, 1.0 + 2.0**-11, 1.0 + 3 * 2.0**-11,
        2.0**-14 - 2.0**-25, 2.0**-14 - 2.0**-26, 1.5 * 2.0**-24,
    ):  # fmt: skip
        bits = sp(centre)
        for k in (-2, -1, 0, 1, 2):
            values.append(bits + k)
            values.append((bits + k) | 0x8000_0000)
    return values


@cocotb.test()
async def test_half_precision(dut: Any) -> None:
    """FCVT.{S,D}.H, FCVT.H.{S,D}, FMV.X.H and FMV.H.X against SoftFloat."""
    await setup(dut)
    inj = Injector(dut)

    # Every half pattern widens exactly to single and double.
    for h in range(1 << 16):
        await inj.run("FCVT_S_H", 0, box16(h))
        if h % 7 == 0:
            await inj.run("FCVT_D_H", 4, box16(h))
    for h in HP_CORNERS:
        for rm in ROUNDING_MODES:
            await inj.run("FCVT_D_H", rm, box16(h))
        await inj.run("FMV_X_H", 0, box16(h))
        await inj.run("FMV_H_X", 0, h | 0x1234_5678_9ABC_0000)

    # Narrowing in every rounding mode: the half range limits, ties and the
    # single and double corners.
    singles = _half_boundary_singles() + SP_CORNERS
    for h in HP_CORNERS:
        singles.append(sp(struct.unpack("<e", struct.pack("<H", h))[0]))
    for rm in ROUNDING_MODES:
        for s in singles:
            await inj.run("FCVT_H_S", rm, box(s))
            fs = struct.unpack("<f", struct.pack("<I", s & 0xFFFF_FFFF))[0]
            await inj.run("FCVT_H_D", rm, dp(fs))
        for d in DP_CORNERS:
            await inj.run("FCVT_H_D", rm, d)
            # Double-only bits below the single precision: sticky for half.
            if ((d >> 52) & 0x7FF) != 0x7FF:
                await inj.run("FCVT_H_D", rm, d | 1)

    # NaN boxing: an improperly boxed half reads as the canonical NaN (no NV);
    # FMV.X.H moves the raw low half; FMV.H.X boxes; an improperly boxed single
    # source of FCVT.H.S is the canonical NaN.
    for raw in (
        0x0000_0000_0000_3C00,
        0xFFFF_FFFF_FFFE_3C00,
        0x7FFF_FFFF_FFFF_3C00,
        0xFFFF_FFFF_0000_7C01,
        0xFFFF_0000_FFFF_3C00,
    ):
        for op in ("FCVT_S_H", "FCVT_D_H", "FMV_X_H", "FMV_H_X", "FCVT_H_S"):
            await inj.run(op, 0, raw)

    _check_counters(dut, inj.count)
    dut._log.info("half-precision vectors: %d", inj.count)


# ============================================================================
# Zfa: FLI, FMINM/FMAXM, FLEQ/FLTQ, FROUND/FROUNDNX, FCVTMOD.W.D
# ============================================================================
ROUNDING_VALUES = [
    0.0, 0.25, 0.5, 0.75, 1.0, 1.5, 2.5, 3.5, -0.5, -1.5, -2.5, -0.25, 7.49,
    1e-300, -1e-300, 1e-40, 123456.5, -123456.5, 4503599627370495.5,
    4503599627370496.0, 9007199254740993.0, 8388607.5, 8388608.0, 16777215.0,
    2147483647.0, 2147483647.75, 2147483648.0, -2147483648.0, -2147483648.5,
    -2147483649.0, 4294967296.0 + 7.25, 2.0**63, 2.0**64 + 2.0**12,
    2.0**83 + 2.0**31, 2.0**83, 2.0**84, 2.0**100, -(2.0**70 + 2.0**20),
]  # fmt: skip


@cocotb.test()
async def test_zfa(dut: Any) -> None:
    """Zfa operations against SoftFloat (FCVTMOD.W.D against the Sail algorithm)."""
    await setup(dut)
    inj = Injector(dut)

    for index in range(32):
        await inj.run("FLI_S", 0, index)
        await inj.run("FLI_D", 0, index | 0xABCD_EF00)

    sp_ops = [box(v) for v in SP_CORNERS]
    for suffix, corners in (("S", sp_ops), ("D", DP_CORNERS)):
        for a in corners:
            for b in corners:
                for op in ("FMINM", "FMAXM", "FLEQ", "FLTQ"):
                    await inj.run(f"{op}_{suffix}", 0, a, b)
        for rm in ROUNDING_MODES:
            for a in corners:
                await inj.run(f"FROUND_{suffix}", rm, a)
                await inj.run(f"FROUNDNX_{suffix}", rm, a)
    for rm in ROUNDING_MODES:
        for value in ROUNDING_VALUES:
            for k in (-1, 0, 1):
                await inj.run("FROUND_D", rm, dp(value) + k)
                await inj.run("FROUNDNX_D", rm, dp(value) + k)
                await inj.run("FROUND_S", rm, box(sp(value) + k))
                await inj.run("FROUNDNX_S", rm, box(sp(value) + k))
    for value in ROUNDING_VALUES:
        for sign in (0, 1 << 63):
            for k in (-1, 0, 1):
                await inj.run("FCVTMOD_W_D", 1, (dp(value) ^ sign) + k)
    for a in DP_CORNERS:
        await inj.run("FCVTMOD_W_D", 1, a)
    for exponent in range(1023 - 2, 1023 + 90):
        await inj.run("FCVTMOD_W_D", 1, (exponent << 52) | 0x000F_EDCB_A987_6543)
        await inj.run("FCVTMOD_W_D", 1, (1 << 63) | (exponent << 52) | 0x8_0000_0001)

    # Improperly boxed single operands read as the canonical NaN.
    for raw in (0x0000_0000_3F80_0000, 0x7FFF_FFFF_3F80_0000):
        for op in ("FMINM_S", "FMAXM_S", "FLEQ_S", "FLTQ_S"):
            await inj.run(op, 0, raw, box(sp(2.0)))
            await inj.run(op, 0, box(sp(2.0)), raw)
        await inj.run("FROUND_S", 0, raw)
        await inj.run("FROUNDNX_S", 0, raw)

    _check_counters(dut, inj.count)
    dut._log.info("Zfa vectors: %d", inj.count)


# ============================================================================
# Cancellation in add and fused multiply-add
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
# Multiply and divide: rounding boundaries, exact quotients, range limits
# ============================================================================
def _sig_patterns(rng: random.Random, bits: int) -> list[int]:
    """Significands (hidden bit included) with dense high, low and all-ones patterns."""
    top = 1 << (bits - 1)
    ones = (1 << bits) - 1
    pats = [top, top | 1, ones, ones - 1, top | (top >> 1), top | (ones >> 2)]
    pats += [top | rng.getrandbits(bits - 1) for _ in range(10)]
    return pats


@cocotb.test()
async def test_mul_div_boundaries(dut: Any) -> None:
    """FMUL, FMA and FDIV near ties, with exact quotients, and across the range limits."""
    await setup(dut)
    inj = Injector(dut)
    rng = random.Random(0x5EED_0019)

    for rm in ROUNDING_MODES:
        for suffix, frac_bits, ebias, emax in (
            ("D", 52, 1023, 2046),
            ("S", 23, 127, 254),
        ):

            def pack(sign: int, exp_field: int, sig: int, fb: int = frac_bits) -> int:
                value = (
                    (sign << (fb + 1 + (11 if fb == 52 else 8) - 1))
                    | (exp_field << fb)
                    | (sig & ((1 << fb) - 1))
                )
                return value if fb == 52 else box(value)

            sigs = _sig_patterns(rng, frac_bits + 1)
            for sa in sigs[:8]:
                for sb in sigs[8:]:
                    sign_a, sign_b = rng.getrandbits(1), rng.getrandbits(1)
                    # Exponents: mid range, product and quotient overflow and
                    # underflow, and results in the subnormal range.
                    for ea, eb in (
                        (ebias, ebias),
                        (ebias + 3, ebias - 7),
                        (emax - 1, ebias + 2),
                        (3, ebias - 3),
                        (ebias - frac_bits // 2, 1 + frac_bits // 3),
                        (emax, 1),
                        (1, emax),
                    ):
                        a = pack(sign_a, ea, sa)
                        b = pack(sign_b, eb, sb)
                        await inj.run(f"FMUL_{suffix}", rm, a, b)
                        await inj.run(f"FDIV_{suffix}", rm, a, b)
                        await inj.run(f"FDIV_{suffix}", rm, b, a)
                        c = pack(
                            rng.getrandbits(1),
                            max(1, min(emax, ea + eb - ebias)),
                            sb ^ sa,
                        )
                        await inj.run(f"FMADD_{suffix}", rm, a, b, c)
                        await inj.run(f"FNMSUB_{suffix}", rm, a, b, c)
                    # Subnormal operands.
                    sub = pack(sign_a, 0, sa >> rng.randint(1, frac_bits))
                    await inj.run(
                        f"FMUL_{suffix}", rm, sub, pack(sign_b, ebias + 5, sb)
                    )
                    await inj.run(
                        f"FDIV_{suffix}", rm, sub, pack(sign_b, ebias - 5, sb)
                    )
                    await inj.run(f"FDIV_{suffix}", rm, pack(sign_b, ebias, sb), sub)
            # Exact quotients (remainder zero) and one unit either side of them.
            half = (frac_bits + 1) // 2
            for _ in range(24):
                qs = (1 << (half - 1)) | rng.getrandbits(half - 1)
                bs = (1 << (half - 1)) | rng.getrandbits(half - 1)
                prod = qs * bs
                shift = frac_bits + 1 - prod.bit_length()
                for k in (-1, 0, 1):
                    a = pack(0, ebias + 4, (prod << shift) + k)
                    b = pack(0, ebias - 2, bs << (frac_bits + 1 - half))
                    await inj.run(f"FDIV_{suffix}", rm, a, b)

    _check_counters(dut, inj.count)
    dut._log.info("multiply and divide boundary vectors: %d", inj.count)


# ============================================================================
# Engine latency per operation
# ============================================================================
# Upper bounds on engine cycles (ST_DEC1 to ST_DONE inclusive) for normal
# operands, so a latency regression fails here.
LATENCY_LIMITS = {
    "FSGNJ_D": 2,
    "FADD_D": 16,
    "FMUL_S": 11,
    "FMUL_D": 11,
    "FMADD_S": 18,
    "FMADD_D": 18,
    "FDIV_S": 28,
    "FDIV_D": 42,
    "FSQRT_S": 62,
    "FSQRT_D": 84,
}


@cocotb.test()
async def test_latency_table(dut: Any) -> None:
    """Report engine cycles per operation and hold them under LATENCY_LIMITS."""
    await setup(dut)

    async def harness_cycles(op: str, a: int, b: int = 0, c: int = 0) -> int:
        start = int(dut.o_vectors.value)
        dut.i_ext_op.value = op_value(op)
        dut.i_ext_rm.value = 0
        dut.i_ext_a.value = a & MASK64
        dut.i_ext_b.value = b & MASK64
        dut.i_ext_c.value = c & MASK64
        dut.i_ext_valid.value = 1
        await RisingEdge(dut.i_clk)
        dut.i_ext_valid.value = 0
        cycles = 1
        while int(dut.o_vectors.value) == start:
            await RisingEdge(dut.i_clk)
            cycles += 1
            assert cycles < VECTOR_CYCLES, f"{op} did not complete"
        await ClockCycles(dut.i_clk, 2)
        return cycles

    operands = {
        "S": (box(sp(1.375)), box(sp(3.0625)), box(sp(-0.75))),
        "D": (dp(1.375), dp(3.0625), dp(-0.75)),
    }
    # FSGNJ takes 2 engine cycles: the harness overhead is the rest.
    da, db, _ = operands["D"]
    overhead = await harness_cycles("FSGNJ_D", da, db) - 2
    rows = []
    for op in LATENCY_LIMITS:
        a, b, c = operands[op[-1]]
        engine = await harness_cycles(op, a, b, c) - overhead
        rows.append(f"{op} {engine}")
        assert engine <= LATENCY_LIMITS[op], (
            f"{op}: {engine} cycles > {LATENCY_LIMITS[op]}"
        )
    _check_counters(dut)
    dut._log.info("engine cycles: %s", ", ".join(rows))


# ============================================================================
# Conversions at integer limits
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
# Randomized sweep driven by the harness
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
# Kill behavior
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
        ("FCVT_H_D", dp(65519.0), 0, 0),
        ("FCVT_H_S", box(0x3380_0001), 0, 0),
        ("FCVT_S_H", box16(0x0001), 0, 0),
        ("FROUNDNX_D", dp(-2.5), 0, 0),
        ("FCVTMOD_W_D", dp(2.0**70 + 2.0**40), 0, 0),
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
