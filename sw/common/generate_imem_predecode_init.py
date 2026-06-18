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

"""Generate Vivado-friendly init files for imem_predecode.sv.

The runtime instruction memory is split into even/odd banks, and its predecode
sideband is stored in separate memories.  Simulation can derive those memories
inside SystemVerilog from sw.mem, but Vivado is much more reliable when each
synthesized memory is initialized directly with a file.
"""

from __future__ import annotations

import argparse
from pathlib import Path

OPC_MISC_MEM = 0b0001111
OPC_CSR = 0b1110011
OPC_AMO = 0b0101111
OPC_FMADD = 0b1000011
OPC_FMSUB = 0b1000111
OPC_FNMSUB = 0b1001011
OPC_FNMADD = 0b1001111
OPC_OP_FP = 0b1010011
SIDEBAND_WIDTH = 12


def parse_verilog_hex(path: Path) -> dict[int, int]:
    """Parse an objcopy --verilog-data-width 4 file as word-addressed data."""
    words: dict[int, int] = {}
    address = 0

    for raw_line in path.read_text().splitlines():
        line = raw_line.split("//", 1)[0].strip()
        if not line:
            continue

        for token in line.split():
            if token.startswith("@"):
                address = int(token[1:], 16)
                continue

            words[address] = int(token, 16) & 0xFFFF_FFFF
            address += 1

    return words


def compressed_control(parcel: int) -> bool:
    """Return whether a compressed parcel is control-flow-like."""
    funct3 = (parcel >> 13) & 0x7
    funct4 = (parcel >> 12) & 0xF
    rs1 = (parcel >> 7) & 0x1F
    rs2 = (parcel >> 2) & 0x1F
    op = parcel & 0x3

    return (op == 0b01 and funct3 in {0b001, 0b101, 0b110, 0b111}) or (
        op == 0b10 and rs2 == 0 and rs1 != 0 and funct4 in {0b1000, 0b1001}
    )


def native_serialize(opcode: int) -> bool:
    """Return whether a native instruction opcode must serialize dispatch."""
    return opcode in {OPC_CSR, OPC_MISC_MEM, OPC_AMO}


def native_fp_compute(opcode: int) -> bool:
    """Return whether a native instruction opcode uses an FP compute unit."""
    return opcode in {OPC_OP_FP, OPC_FMADD, OPC_FMSUB, OPC_FNMSUB, OPC_FNMADD}


def make_sideband(word: int) -> int:
    """Return predecode sideband bits for one instruction-memory word."""
    sideband = 0
    lo = word & 0xFFFF
    hi = (word >> 16) & 0xFFFF
    opcode_lo = word & 0x7F
    opcode_hi = (word >> 16) & 0x7F

    if (lo & 0x3) != 0b11:
        sideband |= 1 << 0
    if (hi & 0x3) != 0b11:
        sideband |= 1 << 1
    if compressed_control(lo):
        sideband |= 1 << 2
    if compressed_control(hi):
        sideband |= 1 << 3
    if native_serialize(opcode_lo):
        sideband |= 1 << 4
    if native_serialize(opcode_hi):
        sideband |= 1 << 5
    if native_fp_compute(opcode_lo):
        sideband |= 1 << 6
    if native_fp_compute(opcode_hi):
        sideband |= 1 << 7
    if (sideband & (1 << 0)) and not (sideband & (1 << 2)):
        sideband |= 1 << 8
    if (sideband & (1 << 1)) and not (sideband & (1 << 3)):
        sideband |= 1 << 9
    if (sideband & (1 << 0)) or not (sideband & ((1 << 4) | (1 << 6))):
        sideband |= 1 << 10
    if (sideband & (1 << 1)) or not (sideband & ((1 << 5) | (1 << 7))):
        sideband |= 1 << 11

    return sideband


def write_word_file(path: Path, values: list[int], width_hex_digits: int) -> None:
    """Write one fixed-width hexadecimal value per line."""
    with path.open("w") as output:
        for value in values:
            output.write(f"{value:0{width_hex_digits}X}\n")


def split_words(words: dict[int, int], depth_words: int) -> tuple[list[int], list[int]]:
    """Split full word-addressed memory contents into even and odd banks."""
    if depth_words <= 0 or depth_words % 2 != 0:
        raise ValueError("--depth-words must be a positive even integer")

    highest_word = max(words, default=-1)
    if highest_word >= depth_words:
        raise ValueError(
            f"input word address 0x{highest_word:X} exceeds depth 0x{depth_words:X}"
        )

    even_words = [0] * (depth_words // 2)
    odd_words = [0] * (depth_words // 2)

    for address, word in words.items():
        if address & 1:
            odd_words[address >> 1] = word
        else:
            even_words[address >> 1] = word

    return even_words, odd_words


def main() -> int:
    """Run the command-line init-file generator."""
    parser = argparse.ArgumentParser(
        description="Generate split instruction-memory init files"
    )
    parser.add_argument("sw_mem", type=Path)
    parser.add_argument("--depth-words", type=int, default=32768)
    parser.add_argument("--even-data", type=Path, required=True)
    parser.add_argument("--odd-data", type=Path, required=True)
    parser.add_argument("--even-sideband", type=Path, required=True)
    parser.add_argument("--odd-sideband", type=Path, required=True)
    args = parser.parse_args()

    words = parse_verilog_hex(args.sw_mem)
    even_words, odd_words = split_words(words, args.depth_words)

    write_word_file(args.even_data, even_words, 8)
    write_word_file(args.odd_data, odd_words, 8)
    sideband_hex_digits = (SIDEBAND_WIDTH + 3) // 4
    write_word_file(
        args.even_sideband,
        [make_sideband(word) for word in even_words],
        sideband_hex_digits,
    )
    write_word_file(
        args.odd_sideband,
        [make_sideband(word) for word in odd_words],
        sideband_hex_digits,
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
