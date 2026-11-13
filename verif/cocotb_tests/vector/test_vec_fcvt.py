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

"""Check the vector conversion blocks bit for bit against Berkeley SoftFloat.

The reference is Spike's build of SoftFloat in the frost image
(/usr/local/lib/libsoftfloat.so), called through ctypes: fN_to_iM and
fN_to_uiM (with exact set, so inexact results raise NX) for vec_f2i, i32,
ui32, i64 and ui64_to_fN for vec_i2f (narrower integers extended first,
which is exact), and fN_to_fM for vec_f2f, with softfloat_roundingMode set
to the operation's rounding mode (5 is round to odd) and
softfloat_exceptionFlags read afterwards. Operands mix random values with
zeros, infinities, NaNs, subnormals and values near the edges of the
destination's range. The block and its widths come from the build.
"""

import ctypes
import random
from typing import Any
from collections.abc import Callable

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

LIB = ctypes.CDLL("/usr/local/lib/libsoftfloat.so")
ROUNDING = ctypes.c_uint8.in_dll(LIB, "softfloat_roundingMode")
FLAGS = ctypes.c_uint8.in_dll(LIB, "softfloat_exceptionFlags")
TININESS = ctypes.c_uint8.in_dll(LIB, "softfloat_detectTininess")
FRAC = {16: 10, 32: 23, 64: 52}
FTYPE = {16: ctypes.c_uint16, 32: ctypes.c_uint32, 64: ctypes.c_uint64}
# SoftFloat's int_fastN_t on 64-bit Linux.
ITYPE = {
    (8, True): ctypes.c_int8,
    (8, False): ctypes.c_uint8,
    (16, True): ctypes.c_long,
    (16, False): ctypes.c_ulong,
    (32, True): ctypes.c_long,
    (32, False): ctypes.c_ulong,
    (64, True): ctypes.c_int64,
    (64, False): ctypes.c_uint64,
}
LATENCY = {"vec_f2i": 5, "vec_i2f": 7, "vec_f2f": 8}


def fp_value(
    rng: random.Random, width: int, near: tuple[int, int] | None = None
) -> int:
    """Return a random value of a format, often special, or with an unbiased exponent in near."""
    frac = FRAC[width]
    exp = width - 1 - frac
    emax = (1 << exp) - 1
    bias = emax >> 1
    s = rng.getrandbits(1) << (width - 1)
    pick = rng.random()
    if pick < 0.04:
        return s
    if pick < 0.07:
        return s | (emax << frac)
    if pick < 0.09:
        return s | (emax << frac) | (1 << (frac - 1)) | rng.getrandbits(frac - 1)
    if pick < 0.11:
        return s | (emax << frac) | (rng.getrandbits(frac - 1) | 1)
    if pick < 0.18:
        return s | rng.getrandbits(frac)
    if near is not None and pick < 0.75:
        e = min(max(rng.randint(*near) + bias, 1), emax - 1)
        return s | (e << frac) | rng.getrandbits(frac)
    return s | (rng.randrange(1, emax) << frac) | rng.getrandbits(frac)


def setup(dut: Any) -> tuple[Callable[[], tuple[dict[str, int], int, int]], int]:
    """Return a generator of (inputs, result, flags) for the block, and its latency."""
    name = dut._name
    rng = random.Random(2038 + len(dut.i_a) * 7 + len(dut.o_result))
    TININESS.value = 1
    if name == "vec_f2i":
        fw, iw = len(dut.i_a), len(dut.o_result)
        fns = {}
        for signed in (True, False):
            f = getattr(LIB, f"f{fw}_to_{'i' if signed else 'ui'}{iw}")
            f.restype = ITYPE[(iw, signed)]
            f.argtypes = [FTYPE[fw], ctypes.c_uint8, ctypes.c_bool]
            fns[signed] = f

        def gen_f2i() -> tuple[dict[str, int], int, int]:
            signed = bool(rng.getrandbits(1))
            rm = rng.randrange(5)
            a = fp_value(rng, fw, (-3, iw + 1))
            ROUNDING.value = rm
            FLAGS.value = 0
            r = int(fns[signed](a, rm, True)) & ((1 << iw) - 1)
            return {"i_signed": int(signed), "i_rm": rm, "i_a": a}, r, int(FLAGS.value)

        return gen_f2i, LATENCY[name]
    if name == "vec_i2f":
        iw, fw = len(dut.i_a), len(dut.o_result)
        rw = 32 if iw <= 32 else 64
        fns = {}
        for signed in (True, False):
            f = getattr(LIB, f"{'i' if signed else 'ui'}{rw}_to_f{fw}")
            f.restype = FTYPE[fw]
            f.argtypes = [
                ITYPE[(64, signed)]
                if rw == 64
                else (ctypes.c_int32 if signed else ctypes.c_uint32)
            ]
            fns[signed] = f

        def gen_i2f() -> tuple[dict[str, int], int, int]:
            signed = bool(rng.getrandbits(1))
            rm = rng.randrange(5)
            bits = rng.randint(0, iw)
            a = rng.getrandbits(bits) if bits else 0
            if rng.random() < 0.3:
                a = ((1 << iw) - 1) ^ rng.getrandbits(
                    min(bits, iw)
                )  # near -1 or the top
            a &= (1 << iw) - 1
            value = a - (1 << iw) if signed and a >> (iw - 1) else a
            ROUNDING.value = rm
            FLAGS.value = 0
            r = int(fns[signed](value))
            return {"i_signed": int(signed), "i_rm": rm, "i_a": a}, r, int(FLAGS.value)

        return gen_i2f, LATENCY[name]
    sw, dw = len(dut.i_a), len(dut.o_result)
    f = getattr(LIB, f"f{sw}_to_f{dw}")
    f.restype = FTYPE[dw]
    f.argtypes = [FTYPE[sw]]
    dbias = (1 << (dw - 2 - FRAC[dw])) - 1
    rms = 6 if dw < sw else 5

    def gen_f2f() -> tuple[dict[str, int], int, int]:
        rm = rng.randrange(rms)
        edge = rng.choice(
            [(1 - dbias - FRAC[dw] - 3, 1 - dbias + 1), (dbias - 2, dbias + 1)]
        )
        a = fp_value(rng, sw, edge)
        ROUNDING.value = rm
        FLAGS.value = 0
        r = int(f(a))
        return {"i_rm": rm, "i_a": a}, r, int(FLAGS.value)

    return gen_f2f, LATENCY[name]


@cocotb.test()
async def test_vec_fcvt_softfloat(dut: Any) -> None:
    """Random conversions against SoftFloat, back to back."""
    gen, latency = setup(dut)
    ports = [p for p in ("i_signed", "i_rm", "i_a") if hasattr(dut, p)]
    Clock(dut.i_clk, 2, unit="ns").start()
    dut.i_valid.value = 0
    for p in ports:
        getattr(dut, p).value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0

    count = 40000
    pending: dict[int, tuple[dict[str, int], int, int]] = {}
    mismatches = []
    checked = 0
    for cycle in range(count + latency + 1):
        if cycle < count:
            inputs, r, f = gen()
            dut.i_valid.value = 1
            for p, value in inputs.items():
                getattr(dut, p).value = value
            pending[cycle] = (inputs, r, f)
        else:
            dut.i_valid.value = 0
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        origin = cycle - latency
        if origin in pending:
            inputs, r, f = pending.pop(origin)
            assert int(dut.o_valid.value) == 1
            got_r, got_f = int(dut.o_result.value), int(dut.o_flags.value)
            if got_r != r or got_f != f:
                shown = " ".join(f"{k}={v:#x}" for k, v in inputs.items())
                mismatches.append(
                    f"{shown}: {got_r:#x}/{got_f:#04x} want {r:#x}/{f:#04x}"
                )
            checked += 1
        await FallingEdge(dut.i_clk)
    for m in mismatches[:20]:
        dut._log.error(m)
    assert not mismatches, (
        f"{len(mismatches)} of {checked} conversions disagreed with SoftFloat"
    )
    dut._log.info(f"{checked} conversions matched SoftFloat")
