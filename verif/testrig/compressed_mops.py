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

"""Random Zcb, Zcmop, Zimop and Zihintntl traces with full-width operands.

x8 and x9 (rs1' 000 and 001) hold cached-DDR addresses and are the only
bases of the Zcb loads and stores, which no instruction overwrites. The
other registers in x1..x15 start with a corner or random 64-bit value;
x16..x31 retain the TestRIG preamble values until written. A few reserved
neighbours of these encodings trap between the cases.
"""

import random
from pathlib import Path


def _i(imm: int, rs1: int, funct3: int, rd: int, opcode: int) -> int:
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def _r(funct7: int, rs2: int, rs1: int, funct3: int, rd: int, opcode: int) -> int:
    return (
        (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode
    )


def _mop_r(n: int, rd: int, rs1: int) -> int:
    funct12 = (
        (1 << 11) | ((n >> 4) & 1) << 10 | ((n >> 2) & 3) << 6 | 0b0111 << 2 | (n & 3)
    )
    return _i(funct12, rs1, 4, rd, 0x73)


def _mop_rr(n: int, rd: int, rs1: int, rs2: int) -> int:
    funct7 = (1 << 6) | ((n >> 2) & 1) << 5 | (n & 3) << 1 | 1
    return _r(funct7, rs2, rs1, 4, rd, 0x73)


# Reserved neighbours: c.sh with bit 6, quadrant 0 funct3=100 bit 12, Zcb
# unary selectors 110/111, c.lui x4/x16, 0, hlv.b, a MOP.R near miss.
RESERVED = (0x8CC4, 0x9FFC, 0x9C79, 0x9C7D, 0x6201, 0x6801, 0x6005C573, 0x91C5C573)

# Data registers for rd' (x10-x15) and any compressed source (x8-x15).
DATA_PRIME = range(2, 8)
ANY_PRIME = range(8)
# Full registers a MOP or integer op may write: not x0, x8 or x9.
WRITABLE = [r for r in range(1, 32) if r not in (8, 9)]


def _case(rng: random.Random) -> tuple[int, str]:
    kind = rng.randrange(12)
    if kind == 0:  # c.lbu
        base, rd, uimm = rng.randrange(2), rng.choice(DATA_PRIME), rng.randrange(4)
        return 0x8000 | base << 7 | (uimm & 1) << 6 | (
            uimm >> 1
        ) << 5 | rd << 2, "c.lbu"
    if kind == 1:  # c.lhu / c.lh
        base, rd, signed = rng.randrange(2), rng.choice(DATA_PRIME), rng.randrange(2)
        return 0x8400 | base << 7 | signed << 6 | rng.randrange(
            2
        ) << 5 | rd << 2, "c.lh(u)"
    if kind == 2:  # c.sb
        base, rs2, uimm = rng.randrange(2), rng.choice(ANY_PRIME), rng.randrange(4)
        return 0x8800 | base << 7 | (uimm & 1) << 6 | (
            uimm >> 1
        ) << 5 | rs2 << 2, "c.sb"
    if kind == 3:  # c.sh
        base, rs2 = rng.randrange(2), rng.choice(ANY_PRIME)
        return 0x8C00 | base << 7 | rng.randrange(2) << 5 | rs2 << 2, "c.sh"
    if kind in (4, 5):  # unary forms
        sel = rng.randrange(6)
        return 0x9C61 | rng.choice(DATA_PRIME) << 7 | sel << 2, f"c.unary.{sel}"
    if kind == 6:  # c.mul
        return 0x9C41 | rng.choice(DATA_PRIME) << 7 | rng.choice(
            ANY_PRIME
        ) << 2, "c.mul"
    if kind == 7:  # c.mop.n
        n = rng.randrange(1, 16, 2)
        return 0x6001 | n << 7, f"c.mop.{n}"
    if kind == 8:  # mop.r.n / mop.rr.n
        rd = rng.choice(WRITABLE + [0])
        if rng.randrange(2):
            n = rng.randrange(32)
            return _mop_r(n, rd, rng.randrange(32)), f"mop.r.{n}"
        n = rng.randrange(8)
        return _mop_rr(n, rd, rng.randrange(32), rng.randrange(32)), f"mop.rr.{n}"
    if kind == 9:  # ntl.* / c.ntl.*
        rs2 = rng.randrange(2, 6)
        if rng.randrange(2):
            return _r(0, rs2, 0, 0, 0, 0x33), "ntl"
        return 0x9002 | rs2 << 2, "c.ntl"
    if kind == 10:  # integer traffic: add / xor / sub
        funct7, funct3 = rng.choice(((0, 0), (0, 4), (0x20, 0)))
        return (
            _r(
                funct7,
                rng.randrange(32),
                rng.randrange(32),
                funct3,
                rng.choice(WRITABLE),
                0x33,
            ),
            "integer traffic",
        )
    return rng.choice(RESERVED), "reserved"


def write_tests(directory: Path, count: int, seed: int, length: int) -> list[Path]:
    """Write reproducible QuickCheckVEngine traces of the new encodings."""
    rng = random.Random(seed)
    directory.mkdir(parents=True, exist_ok=True)
    paths = []
    corners = [
        0,
        1,
        1 << 63,
        (1 << 64) - 1,
        0xAAAAAAAAAAAAAAAA,
        0x5555555555555555,
        0x80,
        0xFF80,
    ]
    for index in range(count):
        lines = [f"# Zcb/Zcmop/Zimop/Zihintntl test {index}, seed {seed}", ".noshrink"]
        for register in range(1, 16):
            value = (
                corners[register - 1]
                if register <= len(corners)
                else rng.getrandbits(64)
            )
            # Eight unsigned bytes avoid assembler-dependent constant expansion.
            lines.append(f".4byte {_i(value >> 56, 0, 0, register, 0x13):#010x}")
            for shift in range(48, -1, -8):
                lines.append(f".4byte {_i(8, register, 1, register, 0x13):#010x}")
                lines.append(
                    f".4byte {_i((value >> shift) & 255, register, 0, register, 0x13):#010x}"
                )
        for base in (8, 9):  # 0x8000_0000 + 8-aligned offset below 2 KiB
            lines.append(f".4byte {_i(1, 0, 0, base, 0x13):#010x}")
            lines.append(f".4byte {_i(31, base, 1, base, 0x13):#010x}")
            lines.append(
                f".4byte {_i(rng.randrange(0, 2040, 8), base, 0, base, 0x13):#010x}"
            )
        lines.append(".shrink")
        for _ in range(length):
            word, name = _case(rng)
            lines.append(f".4byte {word:#010x} # {name}")
        path = directory / f"compressed_mops_{index:03d}.S"
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        paths.append(path)
    return paths
