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

"""RV64C/Zcb/Zcmop expansion oracle from the ratified instruction tables.

The C, Zc and Zimop chapters of the 20260120 unprivileged specification
define these encodings. Immediate maps list input bits in increasing output
bit order; -1 denotes a zero bit. This model does not import predecode code.
An absent expansion means a reserved encoding; its expanded bits are unspecified.
"""


def _bits(c: int, mapping: tuple[int, ...], signed: bool = False) -> int:
    value = sum(((c >> src) & 1) << dst for dst, src in enumerate(mapping) if src >= 0)
    if signed and value & (1 << (len(mapping) - 1)):
        value -= 1 << len(mapping)
    return value


def _i(op: int, rd: int, rs: int, imm: int, f: int = 0) -> int:
    return op | rd << 7 | f << 12 | rs << 15 | (imm & 4095) << 20


def _r(op: int, rd: int, rs: int, rt: int, f: int = 0, top: int = 0) -> int:
    return _i(op, rd, rs, (top << 5) | rt, f)


def _s(op: int, rs: int, rt: int, imm: int, f: int) -> int:
    return op | (imm & 31) << 7 | f << 12 | rs << 15 | rt << 20 | (imm >> 5) << 25


def expand(c: int) -> int | None:
    """Return the canonical 32-bit equivalent, or None for a reserved parcel."""
    q, f = c & 3, c >> 13
    rd, rt = (c >> 7) & 31, (c >> 2) & 31
    rp, tp = 8 + ((c >> 7) & 7), 8 + ((c >> 2) & 7)
    ci = _bits(c, (2, 3, 4, 5, 6, 12), True)
    if q == 3:
        return c
    if q == 0:
        if f == 0:
            imm = _bits(c, (-1, -1, 6, 5, 11, 12, 7, 8, 9, 10))
            return _i(0x13, tp, 2, imm) if imm else None
        if f in (1, 2, 3, 5, 6, 7):
            double = f != 2 and f != 6
            imm = (
                _bits(c, (-1, -1, -1, 10, 11, 12, 5, 6))
                if double
                else _bits(c, (-1, -1, 6, 10, 11, 12, 5))
            )
            op = 0x07 if f in (1, 5) else 0x03
            if f < 4:
                return _i(op, tp, rp, imm, 3 if double else 2)
            return _s(op | 0x20, rp, tp, imm, 3 if double else 2)
        # Zcb's five memory forms use funct6 and, for halfwords, bit 6.
        form = c & 0xFC00
        byte_offset = _bits(c, (6, 5))
        half_offset = _bits(c, (-1, 5))
        if form == 0x8000:
            return _i(3, tp, rp, byte_offset, 4)
        if form == 0x8400:
            return _i(3, tp, rp, half_offset, 1 if c & 64 else 5)
        if form == 0x8800:
            return _s(0x23, rp, tp, byte_offset, 0)
        if form == 0x8C00 and not c & 64:
            return _s(0x23, rp, tp, half_offset, 1)
        return None
    if q == 1:
        if f == 0:
            return _i(0x13, rd, rd, ci)
        if f == 1:
            return _i(0x1B, rd, rd, ci) if rd else None
        if f == 2:
            return _i(0x13, rd, 0, ci)
        if f == 3:
            if rd == 2:
                imm = _bits(c, (-1, -1, -1, -1, 6, 2, 5, 3, 4, 12), True)
                return _i(0x13, 2, 2, imm) if imm else None
            if ci:
                return ((ci & 0xFFFFF) << 12) | rd << 7 | 0x37
            return 0x13 if rd in range(1, 16, 2) else None
        if f == 4:
            sub = (c >> 10) & 3
            if sub < 2:
                shamt = _bits(c, (2, 3, 4, 5, 6, 12))
                return _i(0x13, rp, rp, shamt | (sub << 10), 5)
            if sub == 2:
                return _i(0x13, rp, rp, ci, 7)
            op = (c >> 5) & 3
            if not c & 0x1000:
                return _r(0x33, rp, rp, tp, (0, 4, 6, 7)[op], 32 if op == 0 else 0)
            if op < 2:
                return _r(0x3B, rp, rp, tp, 0, 32 if op == 0 else 0)
            if op == 2:
                return _r(0x33, rp, rp, tp, 0, 1)
            # Fixed equivalent opcodes leave only rd and rs1 variable.
            unary = (
                0x0FF07013,
                0x60401013,
                0x0800403B,
                0x60501013,
                0x0800003B,
                0xFFF04013,
            )
            selector = (c >> 2) & 7
            return unary[selector] | rp << 7 | rp << 15 if selector < 6 else None
        if f == 5:
            imm = _bits(c, (-1, 3, 4, 5, 11, 2, 7, 6, 9, 10, 8, 12), True) & 0x1FFFFF
            return (
                0x6F
                | ((imm >> 12) & 255) << 12
                | ((imm >> 11) & 1) << 20
                | ((imm >> 1) & 1023) << 21
                | (imm >> 20) << 31
            )
        imm = _bits(c, (-1, 3, 4, 10, 11, 2, 5, 6, 12), True) & 8191
        return (
            0x63
            | ((imm >> 11) & 1) << 7
            | ((imm >> 1) & 15) << 8
            | (f - 6) << 12
            | rp << 15
            | ((imm >> 5) & 63) << 25
            | (imm >> 12) << 31
        )
    if f == 0:
        return _i(0x13, rd, rd, _bits(c, (2, 3, 4, 5, 6, 12)), 1)
    if f in (1, 2, 3):
        double = f != 2
        imm = (
            _bits(c, (-1, -1, -1, 5, 6, 12, 2, 3, 4))
            if double
            else _bits(c, (-1, -1, 4, 5, 6, 12, 2, 3))
        )
        return (
            _i(7 if f == 1 else 3, rd, 2, imm, 3 if double else 2)
            if rd or f == 1
            else None
        )
    if f == 4:
        if not c & 0x1000:
            if rt:
                return _r(0x33, rd, 0, rt)
            return _i(0x67, 0, rd, 0) if rd else None
        if rt:
            return _r(0x33, rd, rd, rt)
        return _i(0x67, 1, rd, 0) if rd else 0x00100073
    double = f != 6
    imm = (
        _bits(c, (-1, -1, -1, 10, 11, 12, 7, 8, 9))
        if double
        else _bits(c, (-1, -1, 9, 10, 11, 12, 7, 8))
    )
    return _s(0x27 if f == 5 else 0x23, 2, rt, imm, 3 if double else 2)
