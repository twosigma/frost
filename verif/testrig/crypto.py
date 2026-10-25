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

"""Scalar cryptography traces with aliases, dependencies, and integer traffic."""

import random
from pathlib import Path

# OP encodings: funct7, funct3.
OPERATIONS = {"clmul": (0x05, 1), "clmulh": (0x05, 3), "clmulr": (0x05, 2)}


def write_tests(directory: Path, count: int, seed: int, length: int) -> list[Path]:
    """Write reproducible QuickCheckVEngine traces with full-width operands."""
    rng = random.Random(seed)
    directory.mkdir(parents=True, exist_ok=True)
    paths = []
    for index in range(count):
        lines = [f"# Scalar cryptography test {index}, seed {seed}", ".noshrink"]
        corners = [0, 1, 1 << 63, (1 << 64) - 1, 0xAAAAAAAAAAAAAAAA, 0x5555555555555555]
        for register in range(1, 16):
            value = (
                corners[register - 1]
                if register <= len(corners)
                else rng.getrandbits(64)
            )
            # Eight unsigned bytes avoid assembler-dependent constant expansion.
            lines.append(
                f".4byte {((value >> 56) << 20) | (register << 7) | 0x13:#010x}"
            )
            for shift in range(48, -1, -8):
                lines.append(
                    f".4byte {(8 << 20) | (register << 15) | (1 << 12) | (register << 7) | 0x13:#010x}"
                )
                lines.append(
                    f".4byte {(((value >> shift) & 255) << 20) | (register << 15) | (register << 7) | 0x13:#010x}"
                )
        lines.append(".shrink")
        names = tuple(OPERATIONS)
        for position in range(length):
            rd, rs1, rs2 = (rng.randrange(16) for _ in range(3))
            name = names[position % len(names)]
            funct7, funct3 = OPERATIONS[name]
            if position % 7 == 0:
                funct7, funct3 = rng.choice(((1, 0), (1, 1), (1, 5), (0, 4)))
                name = "integer traffic"
            word = (
                (funct7 << 25)
                | (rs2 << 20)
                | (rs1 << 15)
                | (funct3 << 12)
                | (rd << 7)
                | 0x33
            )
            lines.append(f".4byte {word:#010x} # {name} x{rd}, x{rs1}, x{rs2}")
            if position % 17 == 0:
                # TestRIG places the next stream instruction at the branch target.
                lines.extend(
                    (".4byte 0x00000463 # beq x0,x0,+8", f".4byte {word:#010x}")
                )
            if position % 31 == 0:
                lines.append(".4byte 0x00000073 # ecall")
        path = directory / f"crypto_{seed}_{index:04d}.S"
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        paths.append(path)
    return paths
