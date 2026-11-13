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

"""Check vec_fp_misc bit for bit against Berkeley SoftFloat.

The reference is Spike's build of SoftFloat in the frost image
(/usr/local/lib/libsoftfloat.so), called through ctypes: eq, lt and le for the
comparisons, Spike's min and max (the RISC-V minimum and maximum) and
classify, with softfloat_exceptionFlags read afterwards. Sign injection has no
SoftFloat routine and is checked against its bit definition. Operands mix
random values with zeros, infinities, quiet and signaling NaNs, subnormals
and pairs that are equal or differ only in sign. Runs at the format the build
sets (EXP and FRAC).
"""

import ctypes
import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

LATENCY = 1
LIB = ctypes.CDLL("/usr/local/lib/libsoftfloat.so")
FLAGS = ctypes.c_uint8.in_dll(LIB, "softfloat_exceptionFlags")


def softfloat(width: int, name: str, restype: Any, nargs: int) -> Any:
    """Return one SoftFloat routine typed for a format width."""
    ctype = {16: ctypes.c_uint16, 32: ctypes.c_uint32, 64: ctypes.c_uint64}[width]
    f = getattr(LIB, f"f{width}_{name}")
    f.restype = restype if restype is not None else ctype
    f.argtypes = [ctype] * nargs
    return f


def special(rng: random.Random, exp: int, frac: int) -> int:
    """Return a random value, often a special or boundary one."""
    w = 1 + exp + frac
    emax = (1 << exp) - 1
    s = rng.getrandbits(1) << (w - 1)
    pick = rng.random()
    if pick < 0.10:
        return s
    if pick < 0.18:
        return s | (emax << frac)
    if pick < 0.24:
        return s | (emax << frac) | (1 << (frac - 1)) | rng.getrandbits(frac - 1)
    if pick < 0.30:
        return s | (emax << frac) | (rng.getrandbits(frac - 1) | 1)
    if pick < 0.45:
        return s | rng.getrandbits(frac)
    return s | (rng.randrange(1, emax) << frac) | rng.getrandbits(frac)


@cocotb.test()
async def test_vec_fp_misc_softfloat(dut: Any) -> None:
    """Random operations against SoftFloat, back to back."""
    width = len(dut.i_a)
    frac = {16: 10, 32: 23, 64: 52}[width]
    exp = width - 1 - frac
    sign = 1 << (width - 1)
    eq = softfloat(width, "eq", ctypes.c_bool, 2)
    lt = softfloat(width, "lt", ctypes.c_bool, 2)
    le = softfloat(width, "le", ctypes.c_bool, 2)
    fmin = softfloat(width, "min", None, 2)
    fmax = softfloat(width, "max", None, 2)
    classify = softfloat(width, "classify", ctypes.c_uint16, 1)

    def reference(op: int, a: int, b: int) -> tuple[int, int]:
        FLAGS.value = 0
        if op == 0:
            r = int(eq(a, b))
        elif op == 1:
            r = int(lt(a, b))
        elif op == 2:
            r = int(le(a, b))
        elif op == 3:
            r = int(fmin(a, b))
        elif op == 4:
            r = int(fmax(a, b))
        elif op == 5:
            r = (b & sign) | (a & ~sign)
        elif op == 6:
            r = (~b & sign) | (a & ~sign)
        elif op == 7:
            r = a ^ (b & sign)
        else:
            r = int(classify(a))
        return r, int(FLAGS.value)

    rng = random.Random(2037 + width)
    Clock(dut.i_clk, 2, unit="ns").start()
    dut.i_valid.value = 0
    dut.i_op.value = 0
    dut.i_a.value = 0
    dut.i_b.value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0

    count = 40000
    pending: dict[int, tuple[int, int, int, int, int]] = {}
    mismatches = []
    checked = 0
    for cycle in range(count + LATENCY + 1):
        if cycle < count:
            op = rng.randrange(9)
            a = special(rng, exp, frac)
            pick = rng.random()
            if pick < 0.15:
                b = a
            elif pick < 0.25:
                b = a ^ sign
            else:
                b = special(rng, exp, frac)
            dut.i_valid.value = 1
            dut.i_op.value = op
            dut.i_a.value = a
            dut.i_b.value = b
            r, f = reference(op, a, b)
            pending[cycle] = (op, a, b, r, f)
        else:
            dut.i_valid.value = 0
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        origin = cycle - LATENCY
        if origin in pending:
            op, a, b, r, f = pending.pop(origin)
            assert int(dut.o_valid.value) == 1
            got_r, got_f = int(dut.o_result.value), int(dut.o_flags.value)
            if got_r != r or got_f != f:
                mismatches.append(
                    f"op={op} a={a:#x} b={b:#x}: {got_r:#x}/{got_f:#04x} want {r:#x}/{f:#04x}"
                )
            checked += 1
        await FallingEdge(dut.i_clk)
    for m in mismatches[:20]:
        dut._log.error(m)
    assert not mismatches, (
        f"{len(mismatches)} of {checked} operations disagreed with SoftFloat"
    )
    dut._log.info(f"{checked} FP{width} operations matched SoftFloat")
