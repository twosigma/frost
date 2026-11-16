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

"""Differential tests of integer, fixed-point, mask and permutation execution."""

import os
import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

from .test_vec_engine import Model, signed

# Mnemonic, funct6, operand class, unary selector (when present).
SPECS: list[tuple[str, int, int, int | None]] = []
for name, f6 in {
    "adc": 0x10,
    "madc": 0x11,
    "sbc": 0x12,
    "msbc": 0x13,
    "saddu": 0x20,
    "sadd": 0x21,
    "ssubu": 0x22,
    "ssub": 0x23,
    "smul": 0x27,
    "ssrl": 0x2A,
    "ssra": 0x2B,
    "nsrl": 0x2C,
    "nsra": 0x2D,
    "nclipu": 0x2E,
    "nclip": 0x2F,
    "wsll": 0x35,
    "rgather": 0x0C,
}.items():
    for f3 in [0, 4] if name in {"sbc", "msbc", "ssubu", "ssub", "smul"} else [0, 4, 3]:
        SPECS.append((name, f6, f3, None))
for name, f6 in {
    "aaddu": 0x08,
    "aadd": 0x09,
    "asubu": 0x0A,
    "asub": 0x0B,
    "divu": 0x20,
    "div": 0x21,
    "remu": 0x22,
    "rem": 0x23,
    "mulhu": 0x24,
    "mul": 0x25,
    "mulhsu": 0x26,
    "mulh": 0x27,
    "madd": 0x29,
    "nmsub": 0x2B,
    "macc": 0x2D,
    "nmsac": 0x2F,
    "waddu": 0x30,
    "wadd": 0x31,
    "wsubu": 0x32,
    "wsub": 0x33,
    "waddu_w": 0x34,
    "wadd_w": 0x35,
    "wsubu_w": 0x36,
    "wsub_w": 0x37,
    "wmulu": 0x38,
    "wmulsu": 0x3A,
    "wmul": 0x3B,
    "wmaccu": 0x3C,
    "wmacc": 0x3D,
    "wmaccsu": 0x3F,
}.items():
    for f3 in [2, 6]:
        SPECS.append((name, f6, f3, None))
SPECS.append(("wmaccus", 0x3E, 6, None))
for name, f6 in {"slideup": 0x0E, "slidedown": 0x0F}.items():
    for f3 in [3, 4]:
        SPECS.append((name, f6, f3, None))
SPECS += [
    ("slide1up", 0x0E, 6, None),
    ("slide1down", 0x0F, 6, None),
    ("rgatherei16", 0x0E, 0, None),
    ("compress", 0x17, 2, None),
    ("mv_s_x", 0x10, 6, None),
]
for count in [1, 2, 4, 8]:
    SPECS.append((f"mv{count}r", 0x27, 3, count - 1))
for log in [1, 2, 3]:
    for sign in [0, 1]:
        SPECS.append(
            (f"{'s' if sign else 'z'}ext{1 << log}", 0x12, 2, 8 - 2 * log + sign)
        )
for name, code in {"msbf": 1, "msof": 2, "msif": 3, "iota": 16, "id": 17}.items():
    SPECS.append((name, 0x14, 2, code))
for i, name in enumerate(
    ["mandn", "mand", "mor", "mxor", "morn", "mnand", "mnor", "mxnor"]
):
    SPECS.append((name, 0x18 + i, 2, None))
for i, name in enumerate(
    ["redsum", "redand", "redor", "redxor", "redminu", "redmin", "redmaxu", "redmax"]
):
    SPECS.append((name, i, 2, None))
SPECS += [("wredsumu", 0x30, 0, None), ("wredsum", 0x31, 0, None)]


def rounded(value: int, shift: int, rm: int) -> int:
    """Unbounded integer rounding, independent of the implementation widths."""
    quotient, remainder = divmod(value, 1 << shift)
    if not shift:
        return value
    half = 1 << (shift - 1)
    if rm == 0:
        return quotient + (remainder >= half)
    if rm == 1:
        return quotient + (remainder > half or (remainder == half and quotient & 1))
    if rm == 2:
        return quotient
    return quotient | bool(remainder)


def execute(
    model: Model,
    name: str,
    sew: int,
    lm: float,
    vl: int,
    vm: int,
    vd: int,
    vs1: int,
    vs2: int,
    scalar: int,
    scalar_form: bool,
    rm: int,
    start: int = 0,
) -> bool:
    """Apply an instruction from a snapshot, including allowed register overlap."""
    old = Model(model.vlen)
    old.regs = model.regs.copy()
    m = (1 << sew) - 1
    wide = name.startswith("w") and not name.startswith("wred")
    narrowing = name.startswith(("nsr", "nclip"))
    dw = sew * (2 if wide or name.startswith("wred") else 1)
    aw = sew * (2 if narrowing or name.endswith("_w") else 1)
    if name.startswith(("zext", "sext")):
        aw = sew // int(name[4:])
    is_reduction = name.startswith(("red", "wred"))
    mask_names = {
        "mandn",
        "mand",
        "mor",
        "mxor",
        "morn",
        "mnand",
        "mnor",
        "mxnor",
        "msbf",
        "msof",
        "msif",
        "madc",
        "msbc",
    }
    accumulator = old.elem(vs1, 0, dw)
    found = False
    count = 0
    sat = False
    if name.startswith("mv") and name.endswith("r"):
        vl = int(name[2:-1]) * model.vlen // sew
    if name == "mv_s_x":
        vl, start = (1, 0) if start < vl else (0, 0)
    vlmax = int(model.vlen // sew * lm)
    for i in range(start, vl):
        a = old.elem(vs2, i, aw)
        bw = 16 if name == "rgatherei16" else sew
        b = scalar if scalar_form else old.elem(vs1, i, bw)
        b &= (1 << bw) - 1
        sa, sb = signed(a, aw), signed(b, bw)
        c = old.elem(vd, i, dw) if not is_reduction else 0
        mask = (old.regs[0] >> i) & 1
        active = bool(vm or mask)
        if name in {"adc", "madc", "sbc", "msbc", "mv_s_x"} or (
            name.startswith("mv") and name.endswith("r")
        ):
            active = True
        out = i
        result = a
        if name in {"adc", "madc", "sbc", "msbc"}:
            carry = mask if not vm else 0
            total = a - b - carry if name in {"sbc", "msbc"} else a + b + carry
            result = (
                int(total < 0)
                if name == "msbc"
                else int(total > m)
                if name == "madc"
                else total
            )
        elif name in {"saddu", "sadd", "ssubu", "ssub"}:
            sign = name in {"sadd", "ssub"}
            x, y = (sa, sb) if sign else (a, b)
            result = x - y if name.startswith("ssub") else x + y
            lo, hi = (-(1 << (sew - 1)), (1 << (sew - 1)) - 1) if sign else (0, m)
            clipped = min(hi, max(lo, result))
            sat |= active and clipped != result
            result = clipped
        elif name in {"aaddu", "aadd", "asubu", "asub"}:
            x, y = (a, b) if name.endswith("u") else (sa, sb)
            result = rounded(x - y if name.startswith("asub") else x + y, 1, rm)
        elif name == "smul":
            result = rounded(sa * sb, sew - 1, rm)
            clipped = min((1 << (sew - 1)) - 1, max(-(1 << (sew - 1)), result))
            sat |= active and clipped != result
            result = clipped
        elif name in {"ssrl", "ssra", "nsrl", "nsra", "nclipu", "nclip"}:
            x = sa if name in {"ssra", "nsra", "nclip"} else a
            shift = b & (aw - 1)
            result = x >> shift if name.startswith("nsr") else rounded(x, shift, rm)
            if name.startswith("nclip"):
                lo, hi = (
                    (0, m)
                    if name.endswith("u")
                    else (-(1 << (sew - 1)), (1 << (sew - 1)) - 1)
                )
                clipped = min(hi, max(lo, result))
                sat |= active and clipped != result
                result = clipped
        elif name.startswith(("wadd", "wsub")):
            x, y = (a, b) if name.startswith(("waddu", "wsubu")) else (sa, sb)
            result = x - y if name.startswith("wsub") else x + y
        elif name == "wsll":
            result = a << (b & 63)
        elif name.startswith(("zext", "sext")):
            result = sa if name.startswith("s") else a
        elif name in {
            "mul",
            "mulh",
            "mulhu",
            "mulhsu",
            "madd",
            "nmsub",
            "macc",
            "nmsac",
            "wmul",
            "wmulu",
            "wmulsu",
            "wmacc",
            "wmaccu",
            "wmaccsu",
            "wmaccus",
        }:
            x, y = a, b
            if name in {"mulh", "wmul", "wmacc"}:
                x, y = sa, sb
            elif name in {"mulhsu", "wmulsu", "wmaccus"}:
                x = sa
            elif name == "wmaccsu":
                y = sb
            if name in {"madd", "nmsub"}:
                result = a + c * b if name == "madd" else a - c * b
            elif name in {"macc", "nmsac"}:
                result = c + a * b if name == "macc" else c - a * b
            else:
                result = x * y
                if name in {"mulh", "mulhu", "mulhsu"}:
                    result >>= sew
                if name.startswith("wmacc"):
                    result += c
        elif name in {"div", "divu", "rem", "remu"}:
            x, y = (a, b) if name.endswith("u") else (sa, sb)
            if y == 0:
                result = x if name.startswith("rem") else m
            else:
                quotient = abs(x) // abs(y) * (-1 if (x < 0) != (y < 0) else 1)
                result = x - quotient * y if name.startswith("rem") else quotient
        elif name in {"rgather", "rgatherei16"}:
            index = scalar if scalar_form else b
            result = old.elem(vs2, index, sew) if index < vlmax else 0
        elif name in {"slideup", "slidedown", "slide1up", "slide1down"}:
            offset = 1 if "1" in name else scalar
            index = i - offset if name.endswith("up") else i + offset
            if name == "slide1up" and i == 0 or name == "slide1down" and i == vl - 1:
                result = scalar
            elif index < 0:
                active = False
            else:
                result = old.elem(vs2, index, sew) if index < vlmax else 0
        elif name == "mv_s_x":
            result = scalar
        elif name == "compress":
            active = bool((old.regs[vs1] >> i) & 1)
            out = count
            count += active
        elif name in mask_names or name in {"iota", "id"}:
            bit_a, bit_b = (old.regs[vs2] >> i) & 1, (old.regs[vs1] >> i) & 1
            logical = {
                "mandn": bit_a & ~bit_b,
                "mand": bit_a & bit_b,
                "mor": bit_a | bit_b,
                "mxor": bit_a ^ bit_b,
                "morn": bit_a | ~bit_b,
                "mnand": ~(bit_a & bit_b),
                "mnor": ~(bit_a | bit_b),
                "mxnor": ~(bit_a ^ bit_b),
            }
            if name in logical:
                result = logical[name] & 1
            elif name == "id":
                result = i
            elif name == "iota":
                result = count
                count += bool(bit_a and active)
            else:
                first = bool(bit_a and active and not found)
                result = (
                    int(not found and not first)
                    if name == "msbf"
                    else int(not found)
                    if name == "msif"
                    else int(first)
                )
                found |= first
        elif is_reduction:
            if active:
                acc_s = signed(accumulator, dw)
                if name in {"redsum", "wredsumu", "wredsum"}:
                    accumulator += sa if name == "wredsum" else a
                elif name == "redand":
                    accumulator &= a
                elif name == "redor":
                    accumulator |= a
                elif name == "redxor":
                    accumulator ^= a
                elif name == "redminu":
                    accumulator = min(accumulator, a)
                elif name == "redmaxu":
                    accumulator = max(accumulator, a)
                elif name == "redmin":
                    accumulator = min(acc_s, sa)
                elif name == "redmax":
                    accumulator = max(acc_s, sa)
                accumulator &= (1 << dw) - 1
            active = i == vl - 1
            out, result = 0, accumulator
        if active:
            if name in mask_names:
                model.regs[vd] = (model.regs[vd] & ~(1 << out)) | ((result & 1) << out)
            else:
                model.set_elem(vd, out, dw, result & ((1 << dw) - 1))
    return sat


@cocotb.test()
async def integer_families(dut: Any) -> None:
    """All encoded forms, element widths, LMULs, rounding modes and policies."""
    rng = random.Random(0x5A17)
    vlen = len(dut.i_xw_data)
    model = Model(vlen)
    Clock(dut.i_clk, 10, unit="ns").start()
    dut.i_rst.value = 1
    dut.i_valid.value = 0
    dut.i_xw_en.value = 0
    dut.i_xr_addr.value = 0
    for _ in range(3):
        await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    cases = [
        (spec, w, rm, False)
        for spec in SPECS
        for w in [8, 16, 32, 64]
        for rm in range(4)
    ]
    # Legal source/destination overlaps need original source values even as
    # earlier destination elements are written. Include the high-half overlap
    # for widening, low-half for narrowing, and in-place descending slides.
    overlap_names = {
        "wmul",
        "wmacc",
        "wadd",
        "wadd_w",
        "wsub",
        "wsll",
        "nsrl",
        "nclip",
        "zext2",
        "sext2",
        "zext4",
        "sext8",
        "macc",
        "madd",
        "sadd",
        "smul",
        "slidedown",
        "slide1down",
        "redsum",
        "wredsum",
        "mand",
        "madc",
    }
    for spec in SPECS:
        if spec[0] in overlap_names:
            cases.extend(
                (spec, 64 if "ext" in spec[0] else 16, rm, True) for rm in range(4)
            )
    rng.shuffle(cases)
    checked = 0
    for (name, f6, f3, code), sew, rm, overlap in cases:
        width_change = name.startswith(("w", "nsr", "nclip"))
        if width_change and sew == 64:
            continue
        if name.startswith(("zext", "sext")) and sew // int(name[4:]) < 8:
            continue
        lmul_code = rng.choice([0, 1, 2, 3, 5, 6, 7])
        lm = 2 ** (lmul_code if lmul_code < 4 else lmul_code - 8)
        if sew > 64 * lm or width_change and lm > 4:
            lmul_code, lm = 0, 1
        if name == "rgatherei16" and not 0.125 <= lm * 16 / sew <= 8:
            lmul_code, lm = 0, 1
        if name.startswith(("zext", "sext")) and lm / int(name[4:]) < 0.125:
            lmul_code, lm = 0, 1
        vd, vs2, vs1 = 16, 8, 24
        if name.startswith(("red", "wred")):
            vd, vs1 = 5, 3
        if name == "mv_s_x":
            vs2 = 0
        if name == "id":
            vs2 = 0
        whole = name.startswith("mv") and name.endswith("r")
        if overlap:
            lmul_code, lm = 1, 2
            vd, vs2, vs1 = 8, 8, 24
            if (
                name.startswith("w")
                and not name.startswith("wred")
                and not name.endswith("_w")
            ):
                vs2 = 10  # upper two registers of the four-register destination
            if "ext" in name:
                lm = int(name[4:])
                lmul_code = lm.bit_length() - 1
                vs2 = vd + lm - 1
        vm = rng.randrange(2)
        if name in {"adc", "sbc"}:
            vm = 0
        if (
            whole
            or name == "compress"
            or name == "mv_s_x"
            or f3 == 2
            and 0x18 <= f6 <= 0x1F
        ):
            vm = 1
        vlmax = int(vlen // sew * lm)
        vl = rng.choice([0, 1, vlmax, rng.randrange(vlmax + 1)])
        if overlap:
            vl = vlmax
        scalar = rng.getrandbits(64)
        if "slide" in name or name == "rgather":
            scalar = rng.choice([0, 1, 3, vlmax, 2**64 - 1])
        field = vs1 if code is None else code
        if f3 == 3 and not whole:
            field = rng.randrange(32)
            scalar = field
            if name in {"adc", "madc", "saddu", "sadd"} and field & 16:
                scalar -= 32
        for r in range(32):
            # Repeated boundaries exercise saturation and divide exceptions.
            value = rng.choice(
                [
                    rng.getrandbits(vlen),
                    0,
                    (1 << vlen) - 1,
                    sum(1 << (i + sew - 1) for i in range(0, vlen, sew)),
                ]
            )
            model.regs[r] = value
            dut.i_xw_en.value = 1
            dut.i_xw_addr.value = r
            dut.i_xw_data.value = value
            dut.i_xw_be.value = (1 << (vlen // 8)) - 1
            await FallingEdge(dut.i_clk)
        dut.i_xw_en.value = 0
        start = 0
        if whole:
            count = int(name[2:-1]) * vlen // sew
            start = rng.choice([0, 1, count - 1, count, count + 1])
        elif name == "mv_s_x":
            start = rng.choice([0, 1, vl, vl + 1])
        expected_sat = execute(
            model,
            name,
            sew,
            lm,
            vl,
            vm,
            vd,
            vs1,
            vs2,
            scalar,
            f3 in [3, 4, 6],
            rm,
            start,
        )
        if os.environ.get("FROST_VECTOR_NEGATIVE_CONTROL") == "1" and checked == 0:
            model.regs[vd] ^= 1
        insn = f6 << 26 | vm << 25 | vs2 << 20 | field << 15 | f3 << 12 | vd << 7 | 0x57
        dut.i_insn.value = insn
        dut.i_vsew.value = sew.bit_length() - 4
        dut.i_vlmul.value = lmul_code
        dut.i_vl.value = vl
        dut.i_vstart.value = start
        dut.i_rs1.value = scalar & ((1 << 64) - 1)
        dut.i_vxrm.value = rm
        dut.i_valid.value = 1
        await FallingEdge(dut.i_clk)
        dut.i_valid.value = 0
        got_sat = False
        for cycle in range(100000):
            got_sat |= bool(int(dut.o_sat.value))
            assert not int(dut.o_unsupported.value), name
            if int(dut.o_idle.value):
                break
            await FallingEdge(dut.i_clk)
        else:
            raise AssertionError(f"engine timeout {name}")
        ctx = f"{name} scalar={scalar:#x} sew={sew} lmul={lmul_code} vl={vl} vm={vm} rm={rm} f3={f3}"
        assert got_sat == expected_sat, f"{ctx}: saturation {got_sat} != {expected_sat}"
        for r in range(32):
            dut.i_xr_addr.value = r
            await FallingEdge(dut.i_clk)
            got = int(dut.o_xr_data.value)
            if got != model.regs[r]:
                dut._log.error(
                    "a=%x b=%x op=%d sum=%x result=%x",
                    int(dut.u_int_exec.a_q.value),
                    int(dut.u_int_exec.b_q.value),
                    int(dut.u_int_exec.fixed_op.value),
                    int(dut.u_int_exec.u_fixed.rounded3.value),
                    int(dut.u_int_exec.result_q.value),
                )
                raise AssertionError(f"{ctx} v{r}: {got:#x} != {model.regs[r]:#x}")
        checked += 1
    dut._log.info("%d instruction/width/rounding cases matched", checked)
