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

"""Split a $readmemh word image into per-bank init files for the banked dmem.

The data memory is two half-depth tdp_bram_dc_byte_en instances
(cpu_and_mem.sv's gen_dmem_banks).
Vivado cannot infer a true-dual-port BRAM from an array initialized by
copying out of a staging array, so the synthesis path loads each physical
bank from its own pre-split file (mirroring the imem even/odd splitter).
Bank k receives words [k*bank_depth, (k+1)*bank_depth), rebased to 0.

Input format: verilog hex as emitted by objcopy -O verilog
--verilog-data-width 4 (little-endian 32-bit words; @ headers are in
4-byte-word units — binutils divides the byte address by the data width).
"""

import argparse
import sys
from pathlib import Path


def parse_words(path: Path, depth_words: int) -> list[int]:
    """Parse an objcopy verilog-hex word image into a zero-padded word list."""
    words = [0] * depth_words
    word_index = 0
    for token in path.read_text().split():
        if token.startswith("@"):
            # objcopy -O verilog --verilog-data-width 4 emits @ addresses in
            # 4-byte-word units (binutils divides by the data width).
            word_index = int(token[1:], 16)
            continue
        if word_index >= depth_words:
            raise ValueError(
                f"word address 0x{word_index:X} exceeds depth 0x{depth_words:X}"
            )
        words[word_index] = int(token, 16)
        word_index += 1
    return words


def main() -> int:
    """Split the input image across the requested per-bank output files."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sw_mem", type=Path)
    parser.add_argument("--depth-words", type=int, default=65536)
    parser.add_argument(
        "--bank-output",
        type=Path,
        action="append",
        required=True,
        help="per-bank output file, repeat once per bank in order",
    )
    args = parser.parse_args()

    banks = len(args.bank_output)
    if args.depth_words <= 0 or args.depth_words % banks != 0:
        raise ValueError("--depth-words must be a positive multiple of the bank count")

    words = parse_words(args.sw_mem, args.depth_words)
    bank_depth = args.depth_words // banks
    for bank, out in enumerate(args.bank_output):
        chunk = words[bank * bank_depth : (bank + 1) * bank_depth]
        out.write_text("\n".join(f"{w:08x}" for w in chunk) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
