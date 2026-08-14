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

The runtime instruction memory is split into even/odd banks. Each data bank is
then split into a 28-bit cold block-RAM image and a four-bit frontend-hot image
for architectural word bits ``{15, 10, 7, 6}``. Predecode sideband (including
six RVC source-hot bits) and the dedicated block-RAM timing replicas have their
own images as well, including an independent two-bit compressed-size image per
parity for the IF live PC-advance selector. Simulation can derive those memories
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
OPC_BRANCH = 0b1100011
OPC_JAL = 0b1101111
OPC_JALR = 0b1100111
SIDEBAND_WIDTH = 18
FAST_REPLICA_WIDTH = 7
PC_COMPRESSED_REPLICA_WIDTH = 2
COLD_DATA_WIDTH = 28
FRONTEND_HOT_WIDTH = 4
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
SB_RVC_SOURCE_HOT_LO_LSB = 12
SB_RVC_SOURCE_HOT_HI_LSB = 15


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


# Mirrors riscv_pkg's RV64 predecode functions (RV64C has no C.JAL: the
# q01/funct3=001 slot is C.ADDIW, so it is not control flow).
def compressed_control(parcel: int) -> bool:
    """Return whether a compressed parcel is control-flow-like."""
    funct3 = (parcel >> 13) & 0x7
    funct4 = (parcel >> 12) & 0xF
    rs1 = (parcel >> 7) & 0x1F
    rs2 = (parcel >> 2) & 0x1F
    op = parcel & 0x3

    q01_control = {0b101, 0b110, 0b111}
    return (op == 0b01 and funct3 in q01_control) or (
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


def rvc_source_hot(parcel: int) -> int:
    """Return ``{expanded rs2[1], expanded rs1[2:1]}`` for one RVC parcel.

    Unused instruction-format fields remain literal rather than being
    normalized to zero. This mirrors ``riscv_pkg::imem_rvc_source_hot`` and
    exactly replaces the selected decompressor slices in PD.
    """
    parcel &= 0xFFFF
    quadrant = parcel & 0x3
    funct3 = (parcel >> 13) & 0x7
    rd_full = (parcel >> 7) & 0x1F
    rs2_full = (parcel >> 2) & 0x1F
    rs1_prime = 0x8 | ((parcel >> 7) & 0x7)
    rs2_prime = 0x8 | ((parcel >> 2) & 0x7)
    shamt = rs2_full

    imm_addi4spn = (
        (((parcel >> 7) & 0xF) << 6)
        | (((parcel >> 11) & 0x3) << 4)
        | (((parcel >> 5) & 1) << 3)
        | (((parcel >> 6) & 1) << 2)
    )
    imm_lw_sw = (
        (((parcel >> 5) & 1) << 6)
        | (((parcel >> 10) & 0x7) << 3)
        | (((parcel >> 6) & 1) << 2)
    )
    imm_ld_sd = (((parcel >> 5) & 0x3) << 6) | (((parcel >> 10) & 0x7) << 3)
    imm_ci = (
        (0xFC0 if ((parcel >> 12) & 1) else 0)
        | (((parcel >> 12) & 1) << 5)
        | ((parcel >> 2) & 0x1F)
    )
    imm_addi16sp = (
        (0xE00 if ((parcel >> 12) & 1) else 0)
        | (((parcel >> 3) & 0x3) << 7)
        | (((parcel >> 5) & 1) << 6)
        | (((parcel >> 2) & 1) << 5)
        | (((parcel >> 6) & 1) << 4)
    )
    sign = (parcel >> 12) & 1
    imm_lui = (0xFFFC0 if sign else 0) | (sign << 5) | ((parcel >> 2) & 0x1F)
    imm_j = (
        (sign << 11)
        | (((parcel >> 8) & 1) << 10)
        | (((parcel >> 9) & 0x3) << 8)
        | (((parcel >> 6) & 1) << 7)
        | (((parcel >> 7) & 1) << 6)
        | (((parcel >> 2) & 1) << 5)
        | (((parcel >> 11) & 1) << 4)
        | (((parcel >> 3) & 0x7) << 1)
    )
    imm_lwsp = (
        (((parcel >> 2) & 0x3) << 6)
        | (((parcel >> 12) & 1) << 5)
        | (((parcel >> 4) & 0x7) << 2)
    )
    imm_ldsp = (
        (((parcel >> 2) & 0x7) << 6)
        | (((parcel >> 12) & 1) << 5)
        | (((parcel >> 5) & 0x3) << 3)
    )

    rs1 = 0
    rs2 = 0
    if quadrant == 0b00:
        if funct3 == 0b000:  # C.ADDI4SPN
            rs1, rs2 = 2, imm_addi4spn & 0x1F
        elif funct3 in {0b010, 0b011}:  # C.LW / C.FLW
            rs1, rs2 = rs1_prime, imm_lw_sw & 0x1F
        elif funct3 == 0b001:  # C.FLD
            rs1, rs2 = rs1_prime, imm_ld_sd & 0x1F
        elif funct3 in {0b101, 0b110, 0b111}:  # C.FSD / C.SW / C.FSW
            rs1, rs2 = rs1_prime, rs2_prime
    elif quadrant == 0b01:
        if funct3 == 0b000:  # C.ADDI / C.NOP
            rs1, rs2 = rd_full, imm_ci & 0x1F
        elif funct3 == 0b001:  # C.ADDIW (rd is also rs1)
            rs1, rs2 = rd_full, imm_ci & 0x1F
        elif funct3 == 0b101:  # C.J
            rs1 = 0x1F if (imm_j >> 11) & 1 else 0
            rs2 = (((imm_j >> 1) & 0xF) << 1) | ((imm_j >> 11) & 1)
        elif funct3 == 0b010:  # C.LI
            rs1, rs2 = 0, imm_ci & 0x1F
        elif funct3 == 0b011:
            if rd_full == 2:  # C.ADDI16SP
                rs1, rs2 = 2, imm_addi16sp & 0x1F
            else:  # C.LUI
                rs1, rs2 = (imm_lui >> 3) & 0x1F, (imm_lui >> 8) & 0x1F
        elif funct3 == 0b100:
            subop = (parcel >> 10) & 0x3
            if subop != 0b11:  # C.SRLI / C.SRAI / C.ANDI
                rs1, rs2 = rs1_prime, shamt
            elif not sign or not ((parcel >> 6) & 1):
                # C.SUB family; with bit12=1, C.SUBW/C.ADDW at [6:5]=00/01
                # while [6:5]=10/11 stay reserved (zero expansion/metadata).
                rs1, rs2 = rs1_prime, rs2_prime
        elif funct3 in {0b110, 0b111}:  # C.BEQZ / C.BNEZ
            rs1, rs2 = rs1_prime, 0
    elif quadrant == 0b10:
        if funct3 == 0b000:  # C.SLLI
            rs1, rs2 = rd_full, shamt
        elif funct3 in {0b010, 0b011}:  # C.LWSP / C.FLWSP
            rs1, rs2 = 2, imm_lwsp & 0x1F
        elif funct3 == 0b001:  # C.FLDSP
            rs1, rs2 = 2, imm_ldsp & 0x1F
        elif funct3 == 0b100:
            if not sign:
                if rs2_full == 0:  # C.JR
                    rs1, rs2 = rd_full, 0
                else:  # C.MV
                    rs1, rs2 = 0, rs2_full
            elif rs2_full == 0:
                if rd_full == 0:  # C.EBREAK (literal instruction fields)
                    rs1, rs2 = 0, 1
                else:  # C.JALR
                    rs1, rs2 = rd_full, 0
            else:  # C.ADD
                rs1, rs2 = rd_full, rs2_full
        elif funct3 in {0b101, 0b110, 0b111}:  # C.FSDSP / C.SWSP / C.FSWSP
            rs1, rs2 = 2, rs2_full

    return (((rs2 >> 1) & 1) << 2) | ((rs1 >> 1) & 0x3)


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
    sideband |= rvc_source_hot(lo) << SB_RVC_SOURCE_HOT_LO_LSB
    sideband |= rvc_source_hot(hi) << SB_RVC_SOURCE_HOT_HI_LSB

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


def make_pc_compressed_replica(word: int, sideband: int | None = None) -> int:
    """Return ``{compressed-hi, compressed-lo}`` for the PC-only BRAM copy."""
    if sideband is None:
        sideband = make_sideband(word)
    return sideband & 0b11


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


def pack_frontend_hot(word: int) -> int:
    """Pack ``{word[15], word[10], word[7], word[6]}`` into bits ``[3:0]``."""
    word &= 0xFFFF_FFFF
    return (
        (((word >> 15) & 1) << 3)
        | (((word >> 10) & 1) << 2)
        | (((word >> 7) & 1) << 1)
        | ((word >> 6) & 1)
    )


def pack_cold_data(word: int) -> int:
    """Pack all architectural word bits except ``{15, 10, 7, 6}``."""
    word &= 0xFFFF_FFFF
    return (
        (((word >> 16) & 0xFFFF) << 12)
        | (((word >> 11) & 0xF) << 8)
        | (((word >> 8) & 0x3) << 6)
        | (word & 0x3F)
    )


def join_data_banks(cold: int, frontend_hot: int) -> int:
    """Reconstruct one architectural word from its cold and hot images."""
    cold &= (1 << COLD_DATA_WIDTH) - 1
    frontend_hot &= (1 << FRONTEND_HOT_WIDTH) - 1
    return (
        (((cold >> 12) & 0xFFFF) << 16)
        | (((frontend_hot >> 3) & 1) << 15)
        | (((cold >> 8) & 0xF) << 11)
        | (((frontend_hot >> 2) & 1) << 10)
        | (((cold >> 6) & 0x3) << 8)
        | (((frontend_hot >> 1) & 1) << 7)
        | ((frontend_hot & 1) << 6)
        | (cold & 0x3F)
    )


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
        bank_index = address >> 1
        if address & 1:
            odd_words[bank_index] = word
        else:
            even_words[bank_index] = word
    return even_words, odd_words


def main() -> int:
    """Run the command-line init-file generator."""
    parser = argparse.ArgumentParser(
        description="Generate split instruction-memory init files"
    )
    parser.add_argument("sw_mem", type=Path)
    parser.add_argument("--depth-words", type=int, default=32768)
    parser.add_argument("--even-cold", type=Path, required=True)
    parser.add_argument("--odd-cold", type=Path, required=True)
    parser.add_argument("--even-frontend-hot", type=Path, required=True)
    parser.add_argument("--odd-frontend-hot", type=Path, required=True)
    parser.add_argument("--even-sideband", type=Path, required=True)
    parser.add_argument("--odd-sideband", type=Path, required=True)
    parser.add_argument("--even-compressed", type=Path, required=True)
    parser.add_argument("--odd-compressed", type=Path, required=True)
    parser.add_argument("--even-pc-compressed", type=Path, required=True)
    parser.add_argument("--odd-pc-compressed", type=Path, required=True)
    parser.add_argument("--even-slot2-start-valid-lo", type=Path, required=True)
    parser.add_argument("--odd-slot2-start-valid-lo", type=Path, required=True)
    args = parser.parse_args()

    words = parse_verilog_hex(args.sw_mem)
    even_words, odd_words = split_words(words, args.depth_words)

    cold_hex_digits = (COLD_DATA_WIDTH + 3) // 4
    frontend_hot_hex_digits = (FRONTEND_HOT_WIDTH + 3) // 4
    write_word_file(
        args.even_cold,
        [pack_cold_data(word) for word in even_words],
        cold_hex_digits,
    )
    write_word_file(
        args.odd_cold,
        [pack_cold_data(word) for word in odd_words],
        cold_hex_digits,
    )
    write_word_file(
        args.even_frontend_hot,
        [pack_frontend_hot(word) for word in even_words],
        frontend_hot_hex_digits,
    )
    write_word_file(
        args.odd_frontend_hot,
        [pack_frontend_hot(word) for word in odd_words],
        frontend_hot_hex_digits,
    )
    sideband_hex_digits = (SIDEBAND_WIDTH + 3) // 4
    fast_replica_hex_digits = (FAST_REPLICA_WIDTH + 3) // 4
    pc_compressed_hex_digits = (PC_COMPRESSED_REPLICA_WIDTH + 3) // 4
    even_sideband = [make_sideband(word) for word in even_words]
    odd_sideband = [make_sideband(word) for word in odd_words]
    write_word_file(args.even_sideband, even_sideband, sideband_hex_digits)
    write_word_file(args.odd_sideband, odd_sideband, sideband_hex_digits)
    # The legacy *_compressed.mem images are the narrow block-RAM replicas used
    # by the X3 frontend:
    # {allows-slot2-after-hi, word[29:28], word[31],
    #  word[27:23] == x2, compressed-hi, compressed-lo}.
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
    # Protected two-bit helper banks mirror the two parity banks and feed the
    # IF live PC-size decisions. Keep their images separate from the seven-bit
    # timing banks so the RTL hierarchy preserves independent BRAM launches.
    write_word_file(
        args.even_pc_compressed,
        [
            make_pc_compressed_replica(word, sideband)
            for word, sideband in zip(even_words, even_sideband, strict=True)
        ],
        pc_compressed_hex_digits,
    )
    write_word_file(
        args.odd_pc_compressed,
        [
            make_pc_compressed_replica(word, sideband)
            for word, sideband in zip(odd_words, odd_sideband, strict=True)
        ],
        pc_compressed_hex_digits,
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
