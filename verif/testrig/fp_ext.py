#    Copyright (c) 2026 John Goodacre.
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

"""Zfhmin and Zfa traces: directed and random operands compared with Sail.

TestRIG does not report FP destinations, so every FP result is moved to an
integer register with FMV.X.D (all 64 bits, NaN boxing included), and fflags is
read and cleared after every operation. FSH results appear as store records.
"""

import random
import struct
from pathlib import Path

BASE_REG = 9  # x9: data buffer in cached DDR
TMP, RES, FLG, TMP2 = 10, 11, 12, 13

# OP-FP funct7 and rs2 of the operations.
FMV_X_D, FMV_D_X, FMV_W_X, FMV_H_X, FMV_X_H = 0x71, 0x79, 0x78, 0x7A, 0x72
CONVERSIONS = {
    "fcvt.h.s": (0x22, 0),
    "fcvt.h.d": (0x22, 1),
    "fcvt.s.h": (0x20, 2),
    "fcvt.d.h": (0x21, 2),
}
ROUNDS = {
    "fround.s": (0x20, 4),
    "froundnx.s": (0x20, 5),
    "fround.d": (0x21, 4),
    "froundnx.d": (0x21, 5),
}
MINMAX = {
    "fminm.s": (0x14, 2),
    "fmaxm.s": (0x14, 3),
    "fminm.d": (0x15, 2),
    "fmaxm.d": (0x15, 3),
}
COMPARES = {
    "fleq.s": (0x50, 4),
    "fltq.s": (0x50, 5),
    "fleq.d": (0x51, 4),
    "fltq.d": (0x51, 5),
}


def op_fp(funct7: int, rs2: int, rs1: int, funct3: int, rd: int) -> int:
    """Encode an OP-FP instruction."""
    return (
        (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x53
    )


def i_type(opcode: int, funct3: int, rd: int, rs1: int, imm: int) -> int:
    """Encode an I-type instruction."""
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def s_type(opcode: int, funct3: int, rs1: int, rs2: int, imm: int) -> int:
    """Encode an S-type instruction."""
    imm &= 0xFFF
    return (
        ((imm >> 5) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (funct3 << 12)
        | ((imm & 31) << 7)
        | opcode
    )


class Trace:
    """Collect instruction words with comments."""

    def __init__(self) -> None:
        """Start an empty trace."""
        self.lines: list[str] = []

    def emit(self, word: int, text: str) -> None:
        """Append one instruction word."""
        self.lines.append(f".4byte {word:#010x} # {text}")

    def li(self, rd: int, value: int) -> None:
        """Load a 64-bit constant: ADDI, LUI+ADDIW, or a byte-wise build."""
        value &= (1 << 64) - 1
        signed = value - (1 << 64) if value >> 63 else value
        if -2048 <= signed < 2048:
            self.emit(i_type(0x13, 0, rd, 0, signed), f"li x{rd}, {signed}")
            return
        if -(1 << 31) <= signed < (1 << 31):
            low = ((signed + 0x800) & 0xFFF) - 0x800
            high = ((signed - low) >> 12) & 0xFFFFF
            self.emit((high << 12) | (rd << 7) | 0x37, f"lui x{rd}, {high:#x}")
            self.emit(i_type(0x1B, 0, rd, rd, low), f"addiw x{rd}, x{rd}, {low}")
            return
        self.emit(i_type(0x13, 0, rd, 0, value >> 56), f"li x{rd}, {value >> 56}")
        for shift in range(48, -1, -8):
            self.emit(i_type(0x13, 1, rd, rd, 8), f"slli x{rd}, x{rd}, 8")
            byte = (value >> shift) & 255
            self.emit(i_type(0x13, 6, rd, rd, byte), f"ori x{rd}, x{rd}, {byte}")

    def fmv_to_fp(self, funct7: int, fd: int, rs1: int, name: str) -> None:
        """Move an integer register into an FP register."""
        self.emit(op_fp(funct7, 0, rs1, 0, fd), f"{name} f{fd}, x{rs1}")

    def observe(self, fs: int) -> None:
        """Move all 64 bits of an FP register out, then read and clear fflags."""
        self.emit(op_fp(FMV_X_D, 0, fs, 0, RES), f"fmv.x.d x{RES}, f{fs}")
        self.flags()

    def flags(self) -> None:
        """Read and clear fflags."""
        self.emit(i_type(0x73, 1, FLG, 0, 0x001), f"csrrw x{FLG}, fflags, x0")

    def frm(self, value: int) -> None:
        """Write frm."""
        self.emit(i_type(0x73, 5, 0, value, 0x002), f"csrwi frm, {value}")


def _sext32(value: int) -> int:
    """Sign-extend 32 bits, so the constant loads in two instructions."""
    value &= 0xFFFF_FFFF
    return value - (1 << 32) if value >> 31 else value


def _sp(value: float) -> int:
    return int(struct.unpack("<I", struct.pack("<f", value))[0])


def _dp(value: float) -> int:
    return int(struct.unpack("<Q", struct.pack("<d", value))[0])


HALF_CORNERS = [
    0x0000, 0x8000, 0x0001, 0x8001, 0x03FF, 0x0200, 0x0400, 0x7BFF, 0xFBFF,
    0x3C00, 0xBC00, 0x7C00, 0xFC00, 0x7E00, 0x7C01, 0x7D55, 0xFE01, 0x3555,
]  # fmt: skip
SINGLE_CORNERS = [
    _sp(65504.0), _sp(65520.0), _sp(65519.0), _sp(65536.0), _sp(2.0**-14),
    _sp(2.0**-24), _sp(2.0**-25), _sp(3 * 2.0**-25), _sp(2.0**-26), _sp(1.0 + 2.0**-11),
    _sp(1.0 + 3 * 2.0**-11), 0x0000_0001, 0x7F7F_FFFF, 0x7F80_0000, 0xFF80_0000,
    0x7FC0_0000, 0x7F80_0001, 0x8000_0000, 0, _sp(-2.5), _sp(0.5), _sp(8388607.5),
]  # fmt: skip
DOUBLE_CORNERS = [
    _dp(65504.0), _dp(65520.0), _dp(65519.999), _dp(2.0**-24), _dp(2.0**-25),
    _dp(2.0**-25) + 1, _dp(2.0**-14) - 1, 0x0000_0000_0000_0001, 0x7FEF_FFFF_FFFF_FFFF,
    0x7FF0_0000_0000_0000, 0xFFF0_0000_0000_0000, 0x7FF8_0000_0000_0000,
    0x7FF0_0000_0000_0001, 0x8000_0000_0000_0000, 0, _dp(-2.5), _dp(0.5),
    _dp(4503599627370495.5), _dp(2147483647.75), _dp(-2147483648.5), _dp(2.0**31),
    _dp(2.0**83 + 2.0**31), _dp(2.0**84), _dp(-(2.0**70 + 2.0**20)),
]  # fmt: skip


def _near_half_single(rng: random.Random) -> int:
    exponent = 127 + rng.randint(-28, 19)
    fraction = rng.getrandbits(23)
    if rng.random() < 0.3:  # tie or near tie at the half guard bit (fraction bit 12)
        fraction = (fraction & ~0x1FFF) | 0x1000 | rng.choice((0, 1, 0xFFF))
    return (rng.getrandbits(1) << 31) | (exponent << 23) | fraction


def _near_half_double(rng: random.Random) -> int:
    exponent = 1023 + rng.randint(-28, 19)
    fraction = rng.getrandbits(52)
    if rng.random() < 0.3:  # guard bit is fraction bit 41
        fraction = (
            (fraction & ~((1 << 42) - 1))
            | (1 << 41)
            | rng.choice((0, 1, (1 << 41) - 1))
        )
    return (rng.getrandbits(1) << 63) | (exponent << 52) | fraction


def _single(rng: random.Random) -> int:
    pick = rng.random()
    if pick < 0.25:
        return rng.choice(SINGLE_CORNERS)
    if pick < 0.65:
        return _near_half_single(rng)
    return rng.getrandbits(32)


def _double(rng: random.Random) -> int:
    pick = rng.random()
    if pick < 0.25:
        return rng.choice(DOUBLE_CORNERS)
    if pick < 0.6:
        return _near_half_double(rng)
    if pick < 0.8:  # integer range: FROUND and FCVTMOD
        exponent = 1023 + rng.randint(-2, 90)
        return (rng.getrandbits(1) << 63) | (exponent << 52) | rng.getrandbits(52)
    return rng.getrandbits(64)


def _half(rng: random.Random) -> int:
    return rng.choice(HALF_CORNERS) if rng.random() < 0.3 else rng.getrandbits(16)


def _fp_source(trace: Trace, rng: random.Random, fd: int, precision: str) -> None:
    """Place a random operand of *precision* in fd, sometimes improperly boxed."""
    if precision != "d" and rng.random() < 0.08:
        trace.li(TMP, rng.getrandbits(64) & ~(1 << 63 if rng.random() < 0.5 else 0))
        trace.fmv_to_fp(FMV_D_X, fd, TMP, "fmv.d.x")
        return
    if precision == "h":
        trace.li(TMP, _sext32(_half(rng) | (rng.getrandbits(16) << 16)))
        trace.fmv_to_fp(FMV_H_X, fd, TMP, "fmv.h.x")
    elif precision == "s":
        trace.li(TMP, _sext32(_single(rng)))
        trace.fmv_to_fp(FMV_W_X, fd, TMP, "fmv.w.x")
    else:
        trace.li(TMP, _double(rng))
        trace.fmv_to_fp(FMV_D_X, fd, TMP, "fmv.d.x")


def _rounding(trace: Trace, rng: random.Random) -> int:
    """Return a static rounding mode, or DYN with frm set to a legal mode."""
    if rng.random() < 0.2:
        trace.frm(rng.randrange(5))
        return 7
    return rng.randrange(5)


def _one(trace: Trace, rng: random.Random) -> None:
    kind = rng.randrange(13)
    if kind <= 3:
        name = rng.choice(tuple(CONVERSIONS))
        funct7, rs2 = CONVERSIONS[name]
        _fp_source(trace, rng, 1, {0: "s", 1: "d", 2: "h"}[rs2])
        rm = _rounding(trace, rng)
        trace.emit(op_fp(funct7, rs2, 1, rm, 2), f"{name} f2, f1, rm={rm}")
        trace.observe(2)
    elif kind == 4:
        _fp_source(trace, rng, 1, rng.choice("hsd"))
        trace.emit(op_fp(FMV_X_H, 0, 1, 0, RES), f"fmv.x.h x{RES}, f1")
        trace.li(TMP, rng.getrandbits(64))
        trace.fmv_to_fp(FMV_H_X, 2, TMP, "fmv.h.x")
        trace.observe(2)
    elif kind == 5:
        # FLH / FSH at an aligned offset; an odd offset traps (misaligned).
        offset = 2 * rng.randrange(64)
        trace.li(TMP, _half(rng))
        trace.emit(
            s_type(0x23, 1, BASE_REG, TMP, offset), f"sh x{TMP}, {offset}(x{BASE_REG})"
        )
        trace.emit(
            i_type(0x07, 1, 3, BASE_REG, offset), f"flh f3, {offset}(x{BASE_REG})"
        )
        trace.observe(3)
        _fp_source(trace, rng, 4, rng.choice("hsd"))
        store = 2 * rng.randrange(64)
        trace.emit(s_type(0x27, 1, BASE_REG, 4, store), f"fsh f4, {store}(x{BASE_REG})")
        trace.emit(
            i_type(0x03, 5, RES, BASE_REG, store), f"lhu x{RES}, {store}(x{BASE_REG})"
        )
        if rng.random() < 0.05:
            trace.emit(i_type(0x07, 1, 3, BASE_REG, offset + 1), "flh f3, odd offset")
    elif kind == 6:
        index = rng.randrange(32)
        funct7 = rng.choice((FMV_W_X, FMV_D_X))
        trace.emit(
            op_fp(funct7, 1, index, 0, 5),
            f"fli.{'s' if funct7 == FMV_W_X else 'd'} f5, {index}",
        )
        trace.observe(5)
    elif kind == 7:
        name = rng.choice(tuple(MINMAX))
        funct7, funct3 = MINMAX[name]
        _fp_source(trace, rng, 1, name[-1])
        if rng.random() < 0.3:
            trace.emit(op_fp(0x10 | (funct7 & 1), 1, 1, 0, 2), "fsgnj f2, f1, f1")
        else:
            _fp_source(trace, rng, 2, name[-1])
        trace.emit(op_fp(funct7, 2, 1, funct3, 6), f"{name} f6, f1, f2")
        trace.observe(6)
    elif kind == 8:
        name = rng.choice(tuple(COMPARES))
        funct7, funct3 = COMPARES[name]
        _fp_source(trace, rng, 1, name[-1])
        _fp_source(trace, rng, 2, name[-1])
        trace.emit(op_fp(funct7, 2, 1, funct3, RES), f"{name} x{RES}, f1, f2")
        trace.flags()
    elif kind in (9, 10):
        name = rng.choice(tuple(ROUNDS))
        funct7, rs2 = ROUNDS[name]
        _fp_source(trace, rng, 1, name[-1])
        rm = _rounding(trace, rng)
        trace.emit(op_fp(funct7, rs2, 1, rm, 7), f"{name} f7, f1, rm={rm}")
        trace.observe(7)
    elif kind == 11:
        _fp_source(trace, rng, 1, "d")
        trace.emit(op_fp(0x61, 8, 1, 1, RES), f"fcvtmod.w.d x{RES}, f1, rtz")
        trace.flags()
    else:
        # Reserved rounding modes: static 5 or 6, DYN with frm 5..7, and
        # FCVTMOD.W.D with an rm other than RTZ, all illegal.
        choice = rng.randrange(3)
        if choice == 0:
            funct7, rs2 = rng.choice(
                tuple(CONVERSIONS.values()) + tuple(ROUNDS.values())
            )
            trace.emit(
                op_fp(funct7, rs2, 1, rng.choice((5, 6)), 2), "reserved static rm"
            )
        elif choice == 1:
            trace.frm(rng.choice((5, 6, 7)))
            funct7, rs2 = rng.choice(
                tuple(CONVERSIONS.values()) + tuple(ROUNDS.values())
            )
            trace.emit(op_fp(funct7, rs2, 1, 7, 2), "DYN with reserved frm")
            trace.frm(0)
        else:
            trace.emit(
                op_fp(0x61, 8, 1, rng.choice((0, 2, 3, 4, 7)), RES),
                "fcvtmod.w.d rm != rtz",
            )


def write_tests(directory: Path, count: int, seed: int, length: int) -> list[Path]:
    """Write reproducible Zfhmin/Zfa traces of about *length* instructions."""
    rng = random.Random(seed)
    directory.mkdir(parents=True, exist_ok=True)
    paths = []
    for index in range(count):
        trace = Trace()
        trace.lines += [f"# Zfhmin/Zfa test {index}, seed {seed}", ".noshrink"]
        # mstatus.FS = Dirty, and x9 = 0x8000_1000 in cached DDR.
        trace.emit((0x6 << 12) | (5 << 7) | 0x37, "lui x5, 0x6")
        trace.emit(i_type(0x73, 2, 0, 5, 0x300), "csrrs x0, mstatus, x5")
        trace.emit(
            (0x80001 << 12) | (BASE_REG << 7) | 0x37, f"lui x{BASE_REG}, 0x80001"
        )
        trace.emit(
            (32 << 20) | (BASE_REG << 15) | (1 << 12) | (BASE_REG << 7) | 0x13,
            "slli x9, x9, 32",
        )
        trace.emit(
            (32 << 20) | (BASE_REG << 15) | (5 << 12) | (BASE_REG << 7) | 0x13,
            "srli x9, x9, 32",
        )
        trace.lines.append(".shrink")
        while len(trace.lines) < length:
            _one(trace, rng)
        path = directory / f"fp_ext_{seed}_{index:04d}.S"
        path.write_text("\n".join(trace.lines) + "\n", encoding="utf-8")
        paths.append(path)
    return paths
