#!/usr/bin/env python3
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

"""Pair a 32-bit-word verilog-hex image into 64-bit-dword rows.

The data memory BRAM is one MemDataBits(=64)-wide byte-enabled RAM
(hw/rtl/README.md, "Data-tier bus contract"), so its ``$readmemh`` init
file needs one 64-bit token per dword row. Every other consumer of the
software image (imem with its per-word predecode sideband, the JTAG
loaders, sw.txt) keeps the 32-bit-word ``sw.mem`` format, so this script
derives the dword file rather than changing the objcopy flow.

Input is objcopy ``-O verilog --verilog-data-width 4`` output: ``@ADDR``
records in word units followed by 8-hex-digit little-endian word tokens.
Output is the same format at dword granularity (``@ADDR`` in dword units,
16-hex-digit tokens, low word in bits [31:0]).

Halves are merged through a sparse map so adjacent sections that share a
dword row compose correctly. A half never written by the input is zero,
matching both Verilator's 2-state zero-init and hardware BRAM defaults.
"""

import sys
from pathlib import Path


def convert(text: str) -> str:
    """Convert 32-bit-word verilog-hex text to 64-bit-dword rows."""
    rows: dict[int, list[int]] = {}
    word_addr = 0
    for token in text.split():
        if token.startswith("@"):
            word_addr = int(token[1:], 16)
            continue
        value = int(token, 16)
        row = rows.setdefault(word_addr // 2, [0, 0])
        row[word_addr % 2] = value
        word_addr += 1

    out: list[str] = []
    prev_row = None
    for row_addr in sorted(rows):
        if prev_row is None or row_addr != prev_row + 1:
            out.append(f"@{row_addr:08X}")
        lo, hi = rows[row_addr]
        out.append(f"{(hi << 32) | lo:016X}")
        prev_row = row_addr
    return "\n".join(out) + "\n" if out else ""


def main() -> int:
    """CLI entry point: make_dword_mem.py <sw.mem> <sw64.mem>."""
    if len(sys.argv) != 3:
        print(
            "usage: make_dword_mem.py <input word .mem> <output dword .mem>",
            file=sys.stderr,
        )
        return 2
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    dst.write_text(convert(src.read_text()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
