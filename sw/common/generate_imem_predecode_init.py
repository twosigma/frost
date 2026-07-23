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
sideband and narrow timing replicas are stored in separate memories. The
dedicated one-bit Slot2StartValidLo images keep that PC-critical field out of
the sideband BRAM without overfilling the existing seven-lane RAM64M8-shaped
replica. Simulation can derive those memories inside SystemVerilog from sw.mem,
but Vivado is much more reliable when each synthesized memory is initialized
directly with a file.
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
OPC_BRANCH = 0b1100011
OPC_JAL = 0b1101111
OPC_JALR = 0b1100111
SIDEBAND_WIDTH = 12
FAST_REPLICA_WIDTH = 7
SB_IS_COMPRESSED_LO = 0
SB_IS_COMPRESSED_HI = 1
SB_EVEN_LOCAL_PAIR_VALID = 2
SB_PAIRABLE_NATIVE_LO = 3
SB_NATIVE_SERIALIZE_LO = 4
SB_NATIVE_SERIALIZE_HI = 5
SB_PAIRABLE_COMPRESSED_HI = 6
SB_PAIRABLE_NATIVE_HI = 7
SB_ALLOWS_SLOT2_AFTER_LO = 8
SB_ALLOWS_SLOT2_AFTER_HI = 9
SB_SLOT2_START_VALID_LO = 10
SB_SLOT2_START_VALID_HI = 11


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


def native_control(opcode: int) -> bool:
    """Return whether a native instruction opcode is control flow."""
    return opcode in {OPC_BRANCH, OPC_JAL, OPC_JALR}


def make_sideband(word: int) -> int:
    """Return predecode sideband bits for one instruction-memory word."""
    sideband = 0
    lo = word & 0xFFFF
    hi = (word >> 16) & 0xFFFF
    opcode_lo = word & 0x7F
    opcode_hi = (word >> 16) & 0x7F

    compressed_lo = (lo & 0x3) != 0b11
    compressed_hi = (hi & 0x3) != 0b11
    compressed_control_lo = compressed_control(lo)
    compressed_control_hi = compressed_control(hi)
    native_serialize_lo = native_serialize(opcode_lo)
    native_serialize_hi = native_serialize(opcode_hi)
    native_fp_compute_lo = native_fp_compute(opcode_lo)
    native_fp_compute_hi = native_fp_compute(opcode_hi)

    allows_slot2_after_lo = (compressed_lo and not compressed_control_lo) or (
        not compressed_lo and not native_control(opcode_lo) and not native_serialize_lo
    )
    allows_slot2_after_hi = (compressed_hi and not compressed_control_hi) or (
        not compressed_hi and not native_control(opcode_hi) and not native_serialize_hi
    )
    slot2_start_valid_lo = compressed_lo or not (
        native_serialize_lo or native_fp_compute_lo
    )
    slot2_start_valid_hi = compressed_hi or not (
        native_serialize_hi or native_fp_compute_hi
    )

    if compressed_lo:
        sideband |= 1 << SB_IS_COMPRESSED_LO
    if compressed_hi:
        sideband |= 1 << SB_IS_COMPRESSED_HI
    if native_serialize_lo:
        sideband |= 1 << SB_NATIVE_SERIALIZE_LO
    if native_serialize_hi:
        sideband |= 1 << SB_NATIVE_SERIALIZE_HI
    # AllowsSlot2After: compressed non-control, or native non-control
    # non-serialize (mirrors riscv_pkg::imem_make_sideband).
    if allows_slot2_after_lo:
        sideband |= 1 << SB_ALLOWS_SLOT2_AFTER_LO
    if allows_slot2_after_hi:
        sideband |= 1 << SB_ALLOWS_SLOT2_AFTER_HI
    if slot2_start_valid_lo:
        sideband |= 1 << SB_SLOT2_START_VALID_LO
    if slot2_start_valid_hi:
        sideband |= 1 << SB_SLOT2_START_VALID_HI

    # Word-local PC/bundle predicates.  The RVC-at-low shape can include its
    # same-word slot-2 class; the other three bits collapse the slot-1
    # size/allows conjunction before the fetch-time cross-word join.
    if compressed_lo and allows_slot2_after_lo and slot2_start_valid_hi:
        sideband |= 1 << SB_EVEN_LOCAL_PAIR_VALID
    if not compressed_lo and allows_slot2_after_lo:
        sideband |= 1 << SB_PAIRABLE_NATIVE_LO
    if compressed_hi and allows_slot2_after_hi:
        sideband |= 1 << SB_PAIRABLE_COMPRESSED_HI
    if not compressed_hi and allows_slot2_after_hi:
        sideband |= 1 << SB_PAIRABLE_NATIVE_HI

    return sideband


def make_fast_replica(word: int, sideband: int | None = None) -> int:
    """Return the seven-bit low-BRAM timing replica for one instruction word."""
    if sideband is None:
        sideband = make_sideband(word)
    return (
        (((sideband >> SB_ALLOWS_SLOT2_AFTER_HI) & 1) << 6)
        | (((word >> 28) & 0b11) << 4)
        | (((word >> 31) & 1) << 3)
        | (int(((word >> 23) & 0x1F) == 2) << 2)
        | (sideband & 0b11)
    )


def make_slot2_start_valid_lo_replica(word: int, sideband: int | None = None) -> int:
    """Return the one-bit low-word slot-2-start-valid timing replica."""
    if sideband is None:
        sideband = make_sideband(word)
    return (sideband >> SB_SLOT2_START_VALID_LO) & 1


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
    parser.add_argument("--even-compressed", type=Path, required=True)
    parser.add_argument("--odd-compressed", type=Path, required=True)
    parser.add_argument("--even-slot2-start-valid-lo", type=Path, required=True)
    parser.add_argument("--odd-slot2-start-valid-lo", type=Path, required=True)
    args = parser.parse_args()

    words = parse_verilog_hex(args.sw_mem)
    even_words, odd_words = split_words(words, args.depth_words)

    write_word_file(args.even_data, even_words, 8)
    write_word_file(args.odd_data, odd_words, 8)
    sideband_hex_digits = (SIDEBAND_WIDTH + 3) // 4
    fast_replica_hex_digits = (FAST_REPLICA_WIDTH + 3) // 4
    even_sideband = [make_sideband(word) for word in even_words]
    odd_sideband = [make_sideband(word) for word in odd_words]
    write_word_file(args.even_sideband, even_sideband, sideband_hex_digits)
    write_word_file(args.odd_sideband, odd_sideband, sideband_hex_digits)
    # The legacy *_compressed.mem images are the narrow LUTRAM replicas used
    # by the X3 frontend:
    # {allows-slot2-after-hi, word[29:28], word[31], word[27:23] == x2,
    #  compressed-hi, compressed-lo}.
    write_word_file(
        args.even_compressed,
        [
            make_fast_replica(word, sideband)
            for word, sideband in zip(even_words, even_sideband, strict=True)
        ],
        fast_replica_hex_digits,
    )
    write_word_file(
        args.odd_compressed,
        [
            make_fast_replica(word, sideband)
            for word, sideband in zip(odd_words, odd_sideband, strict=True)
        ],
        fast_replica_hex_digits,
    )
    write_word_file(
        args.even_slot2_start_valid_lo,
        [
            make_slot2_start_valid_lo_replica(word, sideband)
            for word, sideband in zip(even_words, even_sideband, strict=True)
        ],
        1,
    )
    write_word_file(
        args.odd_slot2_start_valid_lo,
        [
            make_slot2_start_valid_lo_replica(word, sideband)
            for word, sideband in zip(odd_words, odd_sideband, strict=True)
        ],
        1,
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
