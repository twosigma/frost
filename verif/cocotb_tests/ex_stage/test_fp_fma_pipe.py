# Copyright (c) 2026 John Goodacre.

"""Compare fp_fma_pipe with Berkeley SoftFloat, one operation per cycle.

The harness computes each reference at launch through DPI-C and compares the
pipeline's result and flags FpPipeDepth cycles later, which also checks the
latency. Directed vectors stream back to back through the injection port;
the random generator covers the operand classes of the fp_engine harness.
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
ROUNDING_MODES = (0, 1, 2, 3, 4)
MASK64 = (1 << 64) - 1

_INSTR_OPS = _parse_instr_op_enum()

PIPE_OPS = ("FADD", "FSUB", "FMUL", "FMADD", "FMSUB", "FNMADD", "FNMSUB")


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
    0x0000_0000,
    0x8000_0000,
    0x0000_0001,
    0x8000_0001,
    0x007F_FFFF,
    0x0040_0000,
    0x0080_0000,
    0x8080_0000,
    0x0080_0001,
    0x00FF_FFFF,
    0x7F7F_FFFF,
    0xFF7F_FFFF,
    0x7F7F_FFFE,
    0x7F00_0000,
    sp(1.0),
    sp(-1.0),
    sp(1.5),
    sp(3.0),
    sp(0.5),
    0x3F80_0001,
    0x3FFF_FFFF,
    0x3F7F_FFFF,
    0x3400_0000,
    0x1F80_0000,  # 2^-64: products reach the subnormal range
    0x2000_0001,
    0x7F80_0000,
    0xFF80_0000,
    0x7FC0_0000,
    0x7F80_0001,
    0xFFC0_0001,
]

DP_CORNERS = [
    0x0000_0000_0000_0000,
    0x8000_0000_0000_0000,
    0x0000_0000_0000_0001,
    0x8000_0000_0000_0001,
    0x000F_FFFF_FFFF_FFFF,
    0x0008_0000_0000_0000,
    0x0010_0000_0000_0000,
    0x8010_0000_0000_0000,
    0x0010_0000_0000_0001,
    0x001F_FFFF_FFFF_FFFF,
    0x7FEF_FFFF_FFFF_FFFF,
    0xFFEF_FFFF_FFFF_FFFF,
    0x7FEF_FFFF_FFFF_FFFE,
    0x7FE0_0000_0000_0000,
    dp(1.0),
    dp(-1.0),
    dp(1.5),
    dp(3.0),
    dp(0.5),
    0x3FF0_0000_0000_0001,
    0x3FFF_FFFF_FFFF_FFFF,
    0x3FEF_FFFF_FFFF_FFFF,
    0x3CB0_0000_0000_0000,
    0x1FF0_0000_0000_0000,  # 2^-512
    0x2000_0000_0000_0001,
    0x7FF0_0000_0000_0000,
    0xFFF0_0000_0000_0000,
    0x7FF8_0000_0000_0000,
    0x7FF0_0000_0000_0001,
    0xFFF8_0000_0000_0001,
]


def op_value(name: str) -> int:
    """Return the instr_op_e ordinal of *name*."""
    return _INSTR_OPS[name]


async def setup(dut: Any, seed: int = 0x0123_4567_89AB_CDEF) -> None:
    """Start the clock and release reset with *seed* in the generator."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    dut.i_gen_enable.value = 0
    dut.i_seed.value = seed & MASK64
    dut.i_bubble.value = 0
    dut.i_ext_valid.value = 0
    dut.i_ext_op.value = 0
    dut.i_ext_rm.value = 0
    dut.i_ext_a.value = 0
    dut.i_ext_b.value = 0
    dut.i_ext_c.value = 0
    dut.i_rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst_n.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)


def _failure_text(dut: Any) -> str:
    """Return the harness's first mismatch as readable text."""
    if not int(dut.o_fail_valid.value):
        return "no mismatch latched"
    names = {v: k for k, v in _INSTR_OPS.items()}
    return (
        f"op={names.get(int(dut.o_fail_op.value), '?')} rm={int(dut.o_fail_rm.value)} "
        f"a=0x{int(dut.o_fail_a.value):016X} b=0x{int(dut.o_fail_b.value):016X} "
        f"c=0x{int(dut.o_fail_c.value):016X} "
        f"pipe=0x{int(dut.o_fail_dut.value):016X}/0x{int(dut.o_fail_dut_flags.value):02X} "
        f"reference=0x{int(dut.o_fail_ref.value):016X}/0x{int(dut.o_fail_ref_flags.value):02X}"
    )


async def stream(dut: Any, vectors: list[tuple[str, int, int, int, int]]) -> None:
    """Inject *vectors* (op, rm, a, b, c) back to back, then drain."""
    for op, rm, a, b, c in vectors:
        dut.i_ext_op.value = op_value(op)
        dut.i_ext_rm.value = rm
        dut.i_ext_a.value = a & MASK64
        dut.i_ext_b.value = b & MASK64
        dut.i_ext_c.value = c & MASK64
        dut.i_ext_valid.value = 1
        await RisingEdge(dut.i_clk)
    dut.i_ext_valid.value = 0
    await ClockCycles(dut.i_clk, 12)


def check(dut: Any, expected: int | None = None) -> None:
    """Fail on any mismatch or latency error the harness counted."""
    vectors = int(dut.o_vectors.value)
    mismatches = int(dut.o_mismatches.value)
    latency = int(dut.o_latency_errors.value)
    assert mismatches == 0, (
        f"{mismatches} of {vectors} vectors disagreed with SoftFloat; first: {_failure_text(dut)}"
    )
    assert latency == 0, f"{latency} cycles with o_valid out of step with the reference"
    assert expected is None or vectors == expected, (
        f"expected {expected}, counted {vectors}"
    )


def _corner_vectors() -> list[tuple[str, int, int, int, int]]:
    vecs = []
    for rm in ROUNDING_MODES:
        for suffix, corners in (("S", [box(v) for v in SP_CORNERS]), ("D", DP_CORNERS)):
            n = len(corners)
            for i, a in enumerate(corners):
                for j, b in enumerate(corners):
                    for op in ("FADD", "FSUB", "FMUL"):
                        vecs.append((f"{op}_{suffix}", rm, a, b, 0))
                    for k, fma in enumerate(PIPE_OPS[3:]):
                        c = corners[(i * 7 + j * 3 + k * 11) % n]
                        vecs.append((f"{fma}_{suffix}", rm, a, b, c))
    return vecs


@cocotb.test()
async def test_directed_corners(dut: Any) -> None:
    """Every corner pair for add, subtract and multiply, FMA with rotating addends."""
    await setup(dut)
    vecs = _corner_vectors()
    await stream(dut, vecs)
    check(dut, len(vecs))
    dut._log.info("corner vectors: %d", len(vecs))


def _fma_triples() -> list[tuple[str, int, int, int, int]]:
    """Every corner triple for FMADD at RNE and RDN (zero signs, inf*0, NaNs)."""
    vecs = []
    for rm in (0, 2):
        for suffix, corners in (
            ("S", [box(v) for v in SP_CORNERS[::2]]),
            ("D", DP_CORNERS[::2]),
        ):
            for a in corners:
                for b in corners:
                    for c in corners:
                        vecs.append((f"FMADD_{suffix}", rm, a, b, c))
    return vecs


@cocotb.test()
async def test_fma_triples(dut: Any) -> None:
    """FMADD over corner triples: signed zeros, infinities, NaNs, inf*0 + qNaN."""
    await setup(dut)
    vecs = _fma_triples()
    await stream(dut, vecs)
    check(dut, len(vecs))
    dut._log.info("triples: %d", len(vecs))


def _border_vectors(rng: random.Random) -> list[tuple[str, int, int, int, int]]:
    """Products and sums at the subnormal border, overflow border and ties."""
    vecs = []
    for _ in range(4000):
        rm = rng.choice(ROUNDING_MODES)
        # Double: product exponent near emin (tininess after rounding), and
        # near emax (overflow per mode).
        ea = rng.randint(1, 2046)
        eb = rng.choice(
            [
                1023 + (-1022 - (ea - 1023)) + rng.randint(-3, 3),
                2046 - ea + 1023 + rng.randint(-2, 2),
            ]
        )
        eb = min(max(eb, 1), 2046)
        fa = rng.getrandbits(52) | rng.choice([0, (1 << 52) - 1])
        fb = rng.choice(
            [rng.getrandbits(52), (1 << 52) - 1, 0, rng.getrandbits(52) | 1]
        )
        a = (rng.getrandbits(1) << 63) | (ea << 52) | (fa & ((1 << 52) - 1))
        b = (rng.getrandbits(1) << 63) | (eb << 52) | fb
        c = rng.choice([0, 0x8000_0000_0000_0000, rng.getrandbits(52), a ^ (1 << 63)])
        vecs.append((rng.choice(["FMUL_D", "FMADD_D", "FNMSUB_D"]), rm, a, b, c))
        # Single.
        ea = rng.randint(1, 254)
        eb = rng.choice(
            [
                127 + (-126 - (ea - 127)) + rng.randint(-3, 3),
                254 - ea + 127 + rng.randint(-2, 2),
            ]
        )
        eb = min(max(eb, 1), 254)
        fa = rng.getrandbits(23) | rng.choice([0, (1 << 23) - 1])
        fb = rng.choice(
            [rng.getrandbits(23), (1 << 23) - 1, 0, rng.getrandbits(23) | 1]
        )
        a = box((rng.getrandbits(1) << 31) | (ea << 23) | (fa & ((1 << 23) - 1)))
        b = box((rng.getrandbits(1) << 31) | (eb << 23) | fb)
        c = rng.choice(
            [box(0), box(0x8000_0000), box(rng.getrandbits(23)), a ^ (1 << 31)]
        )
        vecs.append((rng.choice(["FMUL_S", "FMADD_S", "FNMSUB_S"]), rm, a, b, c))
    # Cancellation: a + (-a') with a' differing in the low bits, subnormal sums.
    for _ in range(4000):
        rm = rng.choice(ROUNDING_MODES)
        e = rng.choice([1, 2, 3, rng.randint(1, 2046), 2046])
        f = rng.getrandbits(52)
        a = (e << 52) | f
        b = (
            (rng.getrandbits(1) << 63)
            | ((e + rng.randint(-1, 1)) % 2047 << 52)
            | (f ^ rng.getrandbits(rng.randint(1, 52)))
        )
        vecs.append((rng.choice(["FSUB_D", "FADD_D"]), rm, a, b, 0))
        e = rng.choice([1, 2, 3, rng.randint(1, 254), 254])
        f = rng.getrandbits(23)
        a = box((e << 23) | f)
        b = box(
            (rng.getrandbits(1) << 31)
            | (((e + rng.randint(-1, 1)) % 255) << 23)
            | (f ^ rng.getrandbits(rng.randint(1, 23)))
        )
        vecs.append((rng.choice(["FSUB_S", "FADD_S"]), rm, a, b, 0))
    return vecs


@cocotb.test()
async def test_borders(dut: Any) -> None:
    """Tininess after rounding, overflow per mode, cancellation to subnormals and zero."""
    await setup(dut)
    vecs = _border_vectors(random.Random(0x5EED_F0FA))
    await stream(dut, vecs)
    check(dut, len(vecs))
    dut._log.info("border vectors: %d", len(vecs))


@cocotb.test()
async def test_nan_boxing(dut: Any) -> None:
    """An improperly boxed single operand reads as the canonical NaN."""
    await setup(dut)
    vecs = []
    for raw in (0x0000_0000_3F80_0000, 0x7FFF_FFFF_3F80_0000, 0xFFFF_FFFE_7F80_0001):
        for op in ("FADD_S", "FSUB_S", "FMUL_S", "FMADD_S", "FNMSUB_S"):
            vecs.append((op, 0, raw, box(sp(2.0)), box(sp(1.0))))
            vecs.append((op, 0, box(sp(2.0)), raw, box(sp(1.0))))
            vecs.append((op, 0, box(sp(2.0)), box(sp(1.0)), raw))
    await stream(dut, vecs)
    check(dut, len(vecs))


async def _random_run(dut: Any, seed: int, bubbles: bool) -> None:
    await setup(dut, seed)
    target = int(dut.o_vector_target.value)
    dut.i_gen_enable.value = 1
    rng = random.Random(seed)
    await RisingEdge(dut.i_clk)
    cycles = 1
    while not int(dut.o_done.value):
        if bubbles:
            dut.i_bubble.value = int(rng.random() < 0.2)
        await RisingEdge(dut.i_clk)
        cycles += 1
        assert cycles < target * 3 + 1000, "random run did not finish"
    dut.i_bubble.value = 0
    await ClockCycles(dut.i_clk, 2)
    check(dut, target)
    dut._log.info("random vectors: %d (seed 0x%X), %d cycles", target, seed, cycles)


@cocotb.test()
async def test_random(dut: Any) -> None:
    """The harness generator, back to back."""
    seed = int(os.environ.get("FROST_FP_PIPE_SEED", "0x20261117"), 0)
    await _random_run(dut, seed, bubbles=False)


@cocotb.test()
async def test_random_bubbles(dut: Any) -> None:
    """The harness generator with idle cycles between operations."""
    seed = int(os.environ.get("FROST_FP_PIPE_SEED", "0x20261117"), 0) ^ 0x0BAD_F00D
    await _random_run(dut, seed, bubbles=True)
