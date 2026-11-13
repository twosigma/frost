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

"""Check vec_fma bit for bit against Berkeley SoftFloat.

The reference is Spike's build of SoftFloat in the frost image
(/usr/local/lib/libsoftfloat.so), called through ctypes: f16/f32/f64 mulAdd,
mul and add with softfloat_roundingMode set to the operation's rounding mode
and softfloat_exceptionFlags read afterwards (the same bit order as fflags).
Operands mix random values with zeros, infinities, quiet and signaling NaNs,
subnormals, the largest finite values and addends close to minus the product,
so cancellation, subnormal results, overflow and every rounding mode are
reached. Runs at the format the build sets (EXP and FRAC).
"""

import ctypes
import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

LATENCY = 14
LIB = ctypes.CDLL("/usr/local/lib/libsoftfloat.so")
ROUNDING = ctypes.c_uint8.in_dll(LIB, "softfloat_roundingMode")
FLAGS = ctypes.c_uint8.in_dll(LIB, "softfloat_exceptionFlags")
TININESS = ctypes.c_uint8.in_dll(LIB, "softfloat_detectTininess")


def functions(width: int) -> tuple[Any, Any, Any]:
    """Return SoftFloat's mulAdd, mul and add for a format width."""
    ctype = {16: ctypes.c_uint16, 32: ctypes.c_uint32, 64: ctypes.c_uint64}[width]
    name = {16: "f16", 32: "f32", 64: "f64"}[width]
    mul_add = getattr(LIB, f"{name}_mulAdd")
    mul = getattr(LIB, f"{name}_mul")
    add = getattr(LIB, f"{name}_add")
    for f in (mul_add, mul, add):
        f.restype = ctype
    mul_add.argtypes = [ctype, ctype, ctype]
    mul.argtypes = [ctype, ctype]
    add.argtypes = [ctype, ctype]
    return mul_add, mul, add


def reference(
    fns: tuple[Any, Any, Any],
    width: int,
    op: int,
    neg_prod: int,
    neg_add: int,
    rm: int,
    a: int,
    b: int,
    c: int,
) -> tuple[int, int]:
    """Return (result, flags) as SoftFloat computes them."""
    mul_add, mul, add = fns
    sign = 1 << (width - 1)
    TININESS.value = 1  # after rounding, as RISC-V specifies
    ROUNDING.value = rm
    FLAGS.value = 0
    if op == 0:
        r = mul_add(a ^ (sign if neg_prod else 0), b, c ^ (sign if neg_add else 0))
    elif op == 1:
        r = mul(a ^ (sign if neg_prod else 0), b)
    else:
        r = add(a, c ^ (sign if neg_add else 0))
    return int(r), int(FLAGS.value)


def special(rng: random.Random, exp: int, frac: int) -> int:
    """Return a random value, often a special or boundary one."""
    w = 1 + exp + frac
    emax = (1 << exp) - 1
    s = rng.getrandbits(1) << (w - 1)
    pick = rng.random()
    if pick < 0.05:
        return s  # zero
    if pick < 0.08:
        return s | (emax << frac)  # infinity
    if pick < 0.10:
        return (
            s | (emax << frac) | (1 << (frac - 1)) | rng.getrandbits(frac - 1)
        )  # quiet NaN
    if pick < 0.12:
        return s | (emax << frac) | (rng.getrandbits(frac - 1) | 1)  # signaling NaN
    if pick < 0.25:
        return s | rng.getrandbits(frac)  # subnormal
    if pick < 0.30:
        return s | ((emax - 1) << frac) | rng.getrandbits(frac)  # largest binade
    if pick < 0.40:
        return (
            s | (rng.randrange(1, 4) << frac) | rng.getrandbits(frac)
        )  # smallest binades
    return s | (rng.randrange(1, emax) << frac) | rng.getrandbits(frac)


@cocotb.test()
async def test_vec_fma_softfloat(dut: Any) -> None:
    """Random operations against SoftFloat, back to back."""
    width = len(dut.i_a)
    frac = {16: 10, 32: 23, 64: 52}[width]
    exp = width - 1 - frac
    fns = functions(width)
    rng = random.Random(2036 + width)
    Clock(dut.i_clk, 2, unit="ns").start()
    for sig in (
        "i_valid",
        "i_op",
        "i_neg_prod",
        "i_neg_add",
        "i_rm",
        "i_a",
        "i_b",
        "i_c",
    ):
        getattr(dut, sig).value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0

    count = 60000
    pending: dict[int, tuple[int, int, int, int, int, int, int, int, int, int]] = {}
    checked = 0
    mismatches = []
    for cycle in range(count + LATENCY + 1):
        if cycle < count:
            op = rng.choice([0, 0, 0, 1, 2])
            neg_prod, neg_add, rm = (
                rng.getrandbits(1),
                rng.getrandbits(1),
                rng.randrange(5),
            )
            a, b, c = (special(rng, exp, frac) for _ in range(3))
            if op == 0 and rng.random() < 0.2:
                # An addend near minus the product: heavy cancellation.
                p, _ = reference(fns, width, 1, neg_prod, 0, 0, a, b, 0)
                c = p ^ ((1 << (width - 1)) if not neg_add else 0) ^ rng.getrandbits(3)
            dut.i_valid.value = 1
            dut.i_op.value = op
            dut.i_neg_prod.value = neg_prod
            dut.i_neg_add.value = neg_add
            dut.i_rm.value = rm
            dut.i_a.value = a
            dut.i_b.value = b
            dut.i_c.value = c
            r, f = reference(fns, width, op, neg_prod, neg_add, rm, a, b, c)
            pending[cycle] = (op, neg_prod, neg_add, rm, a, b, c, r, f, 0)
        else:
            dut.i_valid.value = 0
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        origin = cycle - LATENCY
        if origin in pending:
            op, neg_prod, neg_add, rm, a, b, c, r, f, _ = pending.pop(origin)
            assert int(dut.o_valid.value) == 1
            got_r, got_f = int(dut.o_result.value), int(dut.o_flags.value)
            if got_r != r or got_f != f:
                mismatches.append(
                    f"op={op} np={neg_prod} na={neg_add} rm={rm} a={a:#x} b={b:#x} c={c:#x}: "
                    f"{got_r:#x}/{got_f:#04x} want {r:#x}/{f:#04x}"
                )
            checked += 1
        await FallingEdge(dut.i_clk)
    for m in mismatches[:20]:
        dut._log.error(m)
    assert not mismatches, (
        f"{len(mismatches)} of {checked} operations disagreed with SoftFloat"
    )
    dut._log.info(f"{checked} FP{width} operations matched SoftFloat")
