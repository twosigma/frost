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

"""Committed FP instruction semantics, register geometry and active-only flags."""

import ctypes
import os
import random
from functools import cache
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from .test_vec_engine import Model, signed
from .test_vec_fcvt import FLAGS, FTYPE, LIB, ROUNDING, TININESS, fp_value

SPECS: list[tuple[str, int, int, int | None]] = []
for name, f6 in {
    "add": 0x00,
    "sub": 0x02,
    "min": 0x04,
    "max": 0x06,
    "sgnj": 0x08,
    "sgnjn": 0x09,
    "sgnjx": 0x0A,
    "eq": 0x18,
    "le": 0x19,
    "lt": 0x1B,
    "ne": 0x1C,
    "div": 0x20,
    "mul": 0x24,
    "madd": 0x28,
    "nmadd": 0x29,
    "msub": 0x2A,
    "nmsub": 0x2B,
    "macc": 0x2C,
    "nmacc": 0x2D,
    "msac": 0x2E,
    "nmsac": 0x2F,
    "wadd": 0x30,
    "wsub": 0x32,
    "wadd_w": 0x34,
    "wsub_w": 0x36,
    "wmul": 0x38,
    "wmacc": 0x3C,
    "wnmacc": 0x3D,
    "wmsac": 0x3E,
    "wnmsac": 0x3F,
}.items():
    for f3 in (1, 5):
        SPECS.append((name, f6, f3, None))
for name, f6 in {
    "slide1up": 0x0E,
    "slide1down": 0x0F,
    "mv_s_f": 0x10,
    "merge": 0x17,
    "gt": 0x1D,
    "ge": 0x1F,
    "rdiv": 0x21,
    "rsub": 0x27,
}.items():
    SPECS.append((name, f6, 5, None))
for name, code in {"sqrt": 0, "rsqrt7": 4, "rec7": 5, "class": 16}.items():
    SPECS.append((name, 0x13, 1, code))
for name, f6 in {
    "redusum": 1,
    "redosum": 3,
    "redmin": 5,
    "redmax": 7,
    "wredusum": 0x31,
    "wredosum": 0x33,
}.items():
    SPECS.append((name, f6, 1, None))
for code in (
    0,
    1,
    2,
    3,
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    14,
    15,
    16,
    17,
    18,
    19,
    20,
    21,
    22,
    23,
):
    SPECS.append((f"cvt{code}", 0x12, 1, code))
SPECS.append(("mv_v_f", 0x17, 5, None))


@cache
def fn(name: str, result: Any, args: tuple[Any, ...]) -> Any:
    """Bind one reference operation's exact C ABI."""
    f = getattr(LIB, name)
    f.restype = result
    f.argtypes = list(args)
    return f


def fp_call(width: int, name: str, *values: int) -> int:
    """Evaluate one SoftFloat operation without clearing accumulated flags."""
    out = (
        ctypes.c_bool
        if name in {"eq", "lt", "le"}
        else ctypes.c_uint16
        if name == "classify"
        else FTYPE[width]
    )
    return int(fn(f"f{width}_{name}", out, (FTYPE[width],) * len(values))(*values))


def convert(value: int, sw: int, dw: int, kind: str, sign: bool, rm: int) -> int:
    """Use SoftFloat for all FP/integer widths, including eight-bit integers."""
    ROUNDING.value = rm
    if kind == "ff":
        return int(fn(f"f{sw}_to_f{dw}", FTYPE[dw], (FTYPE[sw],))(value))
    if kind == "fi":
        itype: Any = ctypes.c_int64 if sign else ctypes.c_uint64
        return int(
            fn(
                f"f{sw}_to_{'i' if sign else 'ui'}{dw}",
                itype,
                (FTYPE[sw], ctypes.c_uint8, ctypes.c_bool),
            )(value, rm, True)
        ) & ((1 << dw) - 1)
    n = max(32, sw)
    itype = (
        (ctypes.c_int32 if sign else ctypes.c_uint32)
        if n == 32
        else (ctypes.c_int64 if sign else ctypes.c_uint64)
    )
    v = signed(value, sw) if sign else value
    return int(fn(f"{'i' if sign else 'ui'}{n}_to_f{dw}", FTYPE[dw], (itype,))(v))


def geometry(name: str, sew: int) -> tuple[int, int, bool, bool]:
    """Return source/destination widths, widening, and reduction."""
    cvt = int(name[3:]) if name.startswith("cvt") else -1
    wide = name.startswith("w") or 8 <= cvt < 16
    aw = sew * (2 if cvt >= 16 or name.endswith("_w") else 1)
    dw = sew * (2 if wide else 1)
    return aw, dw, wide, "red" in name


def allowed(name: str, sew: int) -> bool:
    """Only FP formats and EEWs present in the implemented profile."""
    aw, dw, _, _ = geometry(name, sew)
    if max(aw, dw) > 64:
        return False
    if name.startswith("cvt"):
        code = int(name[3:]) & 7
        return (aw >= 16 if code in (0, 1, 4, 5, 6, 7) else True) and (
            dw >= 16 if code in (2, 3, 4, 5) else True
        )
    return sew >= 16


def unbox(value: int, sew: int) -> int:
    """FP scalar inputs use the scalar NaN-boxing rule."""
    if sew < 64 and value >> sew != (1 << (64 - sew)) - 1:
        return 0x7E00 if sew == 16 else 0x7FC00000
    return value & ((1 << sew) - 1)


def element(name: str, sew: int, a: int, b: int, c: int, rm: int) -> tuple[int, int]:
    """Independent element operation using the architectural formula."""
    aw, dw, wide, _ = geometry(name, sew)
    ROUNDING.value = rm
    TININESS.value = 1
    FLAGS.value = 0
    if name.startswith("cvt"):
        code = int(name[3:])
        sub = code & 7
        kind = "ff" if sub in (4, 5) else "if" if sub in (2, 3) else "fi"
        r = convert(
            a,
            aw,
            dw,
            kind,
            bool(sub & 1),
            5 if code == 21 else 1 if sub in (6, 7) else rm,
        )
        return r, int(FLAGS.value)
    if wide:
        if aw != dw:
            a = convert(a, aw, dw, "ff", False, 0)
        if "red" not in name:
            b = convert(b, sew, dw, "ff", False, 0)
        ROUNDING.value = rm
        name = name[1:]
        if name.endswith("_w"):
            name = name[:-2]
    sign = 1 << (dw - 1)
    if name in {"add", "sub", "rsub", "redusum", "redosum"}:
        if name == "rsub":
            a, b = b, a
        r = fp_call(dw, "add", a, b ^ (sign if name in {"sub", "rsub"} else 0))
    elif name in {"mul", "div", "rdiv"}:
        if name == "rdiv":
            a, b = b, a
        r = fp_call(dw, "mul" if name == "mul" else "div", a, b)
    elif name in {"min", "max", "redmin", "redmax"}:
        r = fp_call(dw, "min" if "min" in name else "max", a, b)
    elif name in {"eq", "ne", "lt", "le", "gt", "ge"}:
        if name in {"gt", "ge"}:
            a, b = b, a
        r = fp_call(
            dw,
            "eq" if name in {"eq", "ne"} else "lt" if name in {"lt", "gt"} else "le",
            a,
            b,
        )
        if name == "ne":
            r ^= 1
    elif name in {"sgnj", "sgnjn", "sgnjx"}:
        r = (a & ~sign) | (
            (b ^ (sign if name == "sgnjn" else a if name == "sgnjx" else 0)) & sign
        )
    elif name in {"sqrt", "rec7", "rsqrt7", "class"}:
        r = fp_call(
            dw,
            {
                "sqrt": "sqrt",
                "rec7": "recip7",
                "rsqrt7": "rsqrte7",
                "class": "classify",
            }[name],
            a,
        )
    else:
        if name in {"madd", "nmadd", "msub", "nmsub"}:
            a, c = c, a
        np = name.startswith("n")
        na = name in {"nmadd", "msub", "nmacc", "msac"}
        r = fp_call(dw, "mulAdd", a ^ (sign if np else 0), b, c ^ (sign if na else 0))
    return r, int(FLAGS.value)


def execute(
    model: Model,
    name: str,
    sew: int,
    vl: int,
    vm: int,
    vd: int,
    vs2: int,
    vs1: int,
    scalar: int,
    scalar_form: bool,
    rm: int,
    start: int = 0,
) -> int:
    """Apply one operation to a complete register image."""
    old = Model(model.vlen)
    old.regs = model.regs.copy()
    aw, dw, _, red = geometry(name, sew)
    acc = old.elem(vs1, 0, dw)
    flags = 0
    if name == "mv_s_f":
        vl, start = (1, 0) if start < vl else (0, 0)
    for i in range(start, vl):
        active = bool(
            vm or ((old.regs[0] >> i) & 1) or name in {"merge", "mv_v_f", "mv_s_f"}
        )
        if not active:
            continue
        a = old.elem(vs2, i, aw)
        b = (
            unbox(scalar, sew)
            if scalar_form
            else old.elem(vs1, 0 if red else i, dw if red else sew)
        )
        if name in {"mv_s_f", "mv_v_f"}:
            value = b
        elif name == "merge":
            value = b if (old.regs[0] >> i) & 1 else a
        elif name == "slide1up":
            value = b if i == 0 else old.elem(vs2, i - 1, sew)
        elif name == "slide1down":
            value = b if i + 1 == vl else old.elem(vs2, i + 1, sew)
        else:
            c = old.elem(vd, 0 if red else i, dw)
            value, f = element(name, sew, a, acc if red else b, c, rm)
            flags |= f
        if red:
            acc = value
        elif name in {"eq", "ne", "lt", "le", "gt", "ge"}:
            model.regs[vd] = (model.regs[vd] & ~(1 << i)) | ((value & 1) << i)
        else:
            model.set_elem(vd, i, dw, value & ((1 << dw) - 1))
    if red and vl > 0:
        model.set_elem(vd, 0, dw, acc & ((1 << dw) - 1))
    return flags


@cocotb.test()
async def floating_point_families(dut: Any) -> None:
    """Every instruction form, width, rounding mode, mask, tail and flag result."""
    vlen = len(dut.o_wdata)
    model = Model(vlen)
    memory = [0] * 32

    async def memory_port() -> None:
        while True:
            await FallingEdge(dut.i_clk)
            addresses = int(dut.o_raddr.value)
            reads = sum(
                memory[(addresses >> (5 * k)) & 31] << (vlen * k) for k in range(4)
            )
            we = int(dut.o_we.value)
            addr = int(dut.o_waddr.value)
            data = int(dut.o_wdata.value)
            enable = int(dut.o_wbe.value)
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            if we:
                for byte in range(vlen // 8):
                    if enable >> byte & 1:
                        mask = 255 << (8 * byte)
                        memory[addr] = (memory[addr] & ~mask) | (data & mask)
            dut.i_rdata.value = reads

    Clock(dut.i_clk, 10, unit="ns").start()
    dut.i_rst.value = 1
    dut.i_valid.value = 0
    dut.i_insn.value = 0
    dut.i_sew.value = 1
    dut.i_vl.value = 0
    dut.i_vstart.value = 0
    dut.i_scalar.value = 0
    dut.i_frm.value = 0
    dut.i_rdata.value = 0
    cocotb.start_soon(memory_port())
    for _ in range(3):
        await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    rng = random.Random(9027 + vlen)
    cases = [
        (spec, w, rm)
        for spec in SPECS
        for w in (8, 16, 32, 64)
        for rm in range(5)
        if allowed(spec[0], w)
    ]
    rng.shuffle(cases)
    for n, ((name, f6, f3, code), sew, rm) in enumerate(cases):
        aw, dw, _, red = geometry(name, sew)
        lm = rng.choice((1, 2, 4) if max(aw, dw) > sew else (1, 2, 4, 8))
        vlmax = vlen // sew * lm
        vl = rng.choice((0, 1, vlmax, rng.randrange(vlmax + 1)))
        vm = rng.randrange(2)
        vd, vs2, vs1 = (5, 8, 3) if red else (16, 8, 24)
        if name in {"mv_s_f", "mv_v_f"}:
            vs2 = 0
            vm = 1
        if name == "merge":
            vm = 0
        if name in {"add", "macc", "slide1down"} and rng.randrange(2):
            vd = vs2
        for r in range(32):
            fw = max(16, sew)
            value = sum(fp_value(rng, fw) << (k * fw) for k in range(vlen // fw))
            memory[r] = model.regs[r] = value
        scalar = fp_value(rng, max(16, sew))
        if sew < 64 and rng.randrange(3):
            scalar |= ((1 << (64 - sew)) - 1) << sew
        start = rng.choice((0, 1, vl, vl + 1)) if name == "mv_s_f" else 0
        expected_flags = execute(
            model, name, sew, vl, vm, vd, vs2, vs1, scalar, f3 == 5, rm, start
        )
        if os.environ.get("FROST_VECTOR_NEGATIVE_CONTROL") == "1" and n == 0:
            model.regs[vd] ^= 1
        field = vs1 if code is None else code
        dut.i_insn.value = (
            f6 << 26 | vm << 25 | vs2 << 20 | field << 15 | f3 << 12 | vd << 7 | 0x57
        )
        dut.i_sew.value = sew.bit_length() - 4
        dut.i_vl.value = vl
        dut.i_vstart.value = start
        dut.i_scalar.value = scalar
        dut.i_frm.value = rm
        dut.i_valid.value = 1
        await FallingEdge(dut.i_clk)
        dut.i_valid.value = 0
        got_flags = 0
        pulses = 0
        for _ in range(100000):
            if int(dut.o_flags_valid.value):
                got_flags |= int(dut.o_flags.value)
                pulses += 1
            if int(dut.o_idle.value):
                break
            await FallingEdge(dut.i_clk)
        else:
            raise AssertionError(f"timeout {name}")
        context = f"{name} f3={f3} sew={sew} vl={vl} vm={vm} rm={rm}"
        assert got_flags == expected_flags, (
            f"{context}: flags {got_flags:#x} != {expected_flags:#x}"
        )
        # The flags of all active elements leave in one pulse, after the
        # last element and before the engine reports idle; an instruction
        # that raises no flag sends no pulse.
        assert pulses == (1 if expected_flags else 0), (
            f"{context}: {pulses} flag pulses"
        )
        for r in range(32):
            assert memory[r] == model.regs[r], (
                f"{context}: v{r} {memory[r]:#x} != {model.regs[r]:#x}"
            )
    dut._log.info("%d FP instruction/width/rounding cases matched", len(cases))
