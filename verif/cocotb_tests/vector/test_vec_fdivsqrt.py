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

"""Check vec_fdivsqrt bit for bit against Berkeley SoftFloat.

The reference is Spike's build of SoftFloat in the frost image
(/usr/local/lib/libsoftfloat.so), called through ctypes: fN_div and fN_sqrt
with softfloat_roundingMode set to the operation's rounding mode and
softfloat_exceptionFlags read afterwards. Operands mix random values with
zeros, infinities, quiet and signaling NaNs, subnormals, negative square root
operands and quotients near the overflow and underflow thresholds. The bench
also checks that every operation takes the same number of cycles and that
o_ready stays low while one is in flight. Runs at the format the build sets.
"""

import ctypes
import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

LIB = ctypes.CDLL("/usr/local/lib/libsoftfloat.so")
ROUNDING = ctypes.c_uint8.in_dll(LIB, "softfloat_roundingMode")
FLAGS = ctypes.c_uint8.in_dll(LIB, "softfloat_exceptionFlags")
TININESS = ctypes.c_uint8.in_dll(LIB, "softfloat_detectTininess")


def special(rng: random.Random, exp: int, frac: int) -> int:
    """Return a random value, often a special or boundary one."""
    w = 1 + exp + frac
    emax = (1 << exp) - 1
    s = rng.getrandbits(1) << (w - 1)
    pick = rng.random()
    if pick < 0.05:
        return s
    if pick < 0.08:
        return s | (emax << frac)
    if pick < 0.10:
        return s | (emax << frac) | (1 << (frac - 1)) | rng.getrandbits(frac - 1)
    if pick < 0.12:
        return s | (emax << frac) | (rng.getrandbits(frac - 1) | 1)
    if pick < 0.25:
        return s | rng.getrandbits(frac)
    if pick < 0.35:
        return (
            s | (rng.choice([1, 2, emax - 2, emax - 1]) << frac) | rng.getrandbits(frac)
        )
    return s | (rng.randrange(1, emax) << frac) | rng.getrandbits(frac)


@cocotb.test()
async def test_vec_fdivsqrt_softfloat(dut: Any) -> None:
    """Random divisions and square roots against SoftFloat."""
    width = len(dut.i_a)
    frac = {16: 10, 32: 23, 64: 52}[width]
    exp = width - 1 - frac
    ctype = {16: ctypes.c_uint16, 32: ctypes.c_uint32, 64: ctypes.c_uint64}[width]
    fdiv = getattr(LIB, f"f{width}_div")
    fdiv.restype = ctype
    fdiv.argtypes = [ctype, ctype]
    fsqrt = getattr(LIB, f"f{width}_sqrt")
    fsqrt.restype = ctype
    fsqrt.argtypes = [ctype]
    TININESS.value = 1
    latency = frac + 1 + 10

    rng = random.Random(2039 + width)
    Clock(dut.i_clk, 2, unit="ns").start()
    for sig in ("i_valid", "i_sqrt", "i_rm", "i_a", "i_b"):
        getattr(dut, sig).value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0

    count = 6000
    mismatches = []
    for _ in range(count):
        sqrt = rng.random() < 0.4
        mode = rng.randrange(5)
        a, b = special(rng, exp, frac), special(rng, exp, frac)
        if sqrt and rng.random() < 0.8:
            a &= (1 << (width - 1)) - 1
        ROUNDING.value = mode
        FLAGS.value = 0
        want = int(fsqrt(a)) if sqrt else int(fdiv(a, b))
        want_flags = int(FLAGS.value)
        assert int(dut.o_ready.value) == 1
        dut.i_valid.value = 1
        dut.i_sqrt.value = int(sqrt)
        dut.i_rm.value = mode
        dut.i_a.value = a
        dut.i_b.value = b
        await RisingEdge(dut.i_clk)
        await FallingEdge(dut.i_clk)
        dut.i_valid.value = 0
        cycles = 1
        while True:
            await RisingEdge(dut.i_clk)
            await ReadOnly()
            if int(dut.o_valid.value):
                break
            assert int(dut.o_ready.value) == 0, "ready while an operation is in flight"
            cycles += 1
            assert cycles <= latency, "no result"
        assert cycles == latency, f"latency {cycles}, expected {latency}"
        got, got_flags = int(dut.o_result.value), int(dut.o_flags.value)
        if got != want or got_flags != want_flags:
            op = "sqrt" if sqrt else "div"
            mismatches.append(
                f"{op} mode={mode} a={a:#x} b={b:#x}: {got:#x}/{got_flags:#04x} "
                f"want {want:#x}/{want_flags:#04x}"
            )
        await FallingEdge(dut.i_clk)
    for m in mismatches[:20]:
        dut._log.error(m)
    assert not mismatches, (
        f"{len(mismatches)} of {count} operations disagreed with SoftFloat"
    )
    dut._log.info(
        f"{count} FP{width} operations matched SoftFloat, {latency} cycles each"
    )
