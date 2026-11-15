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

"""Random Sv39 MMU, ASID, SFENCE.VMA, and Sstvala tests for TestRIG.

Sail walks memory on every translated access and treats SFENCE.VMA as a
privilege check, whereas FROST caches translations across its L1 ITLB, L1 DTLB,
512-entry L2 TLB, 32-entry superpage side array, and upper-level walk cache.
The two agree whenever each non-zero ASID names one page-table hierarchy and
every modification of an already-valid PTE is paired with a matching
SFENCE.VMA, while invalid-to-valid upgrades need no fence under Svvptc.

Each test builds two Sv39 hierarchies in cached DDR with 4 KiB leaves, 2 MiB
megapages, 1 GiB gigapages, global leaves, non-leaf global pointers, upper-half
negative canonical virtual addresses, mapped device pages, and faulting PTEs.
Self-contained `.noshrink` strands exercise ASID-only and root-changing satp
writes, ASIDLEN WARL probes, all four SFENCE.VMA forms, L1-to-L2 TLB spills,
superpage side-array replacement, M/S/U privilege and delegation combinations,
and explicit reads of mtval/stval, mepc/sepc, and mcause/scause after traps.
"""

import hashlib
import random
import struct
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# Physical layout inside the 1 GiB default DDR aperture (0x8000_0000..0xBFFF_FFFF).
CODE_ENTRY = 0x8000_0100
MTVEC_BASE = 0x8004_0000
STVEC_BASE = 0x8008_0000

ROOT_A = 0x8010_0000
ROOT_B = 0x8010_1000
L1_A = 0x8010_2000
L1_B = 0x8010_3000
L0_A = 0x8010_4000
L0_B = 0x8010_5000
L1_GLOBAL_PTR = 0x8010_6000
L1_NEG = 0x8010_7000
L1_SYS = 0x8010_8000
L1_MEGA_THRASH = 0x8010_9000

PA_POOL_A = 0x8020_0000  # 24 x 4 KiB pages for ROOT_A
PA_POOL_B = 0x8024_0000  # 24 x 4 KiB pages for ROOT_B
PA_SPECIAL = 0x8028_0000  # backing pages for permission and mutable slots
PA_MUT_B0 = 0x8029_0000
PA_MUT_B1 = 0x8029_1000
PA_SVVPTC = 0x8029_2000
PA_G_INHERIT = 0x8040_0000  # 2 MiB aligned
PA_NEG_MEGA = 0x8060_0000  # 2 MiB aligned
PA_MUT_MEGA0 = 0x8080_0000  # 2 MiB aligned
PA_MUT_MEGA1 = 0x80A0_0000  # 2 MiB aligned
PA_THRASH_BASE = 0x8100_0000  # 34 x 2 MiB megapages (68 MiB)

PA_MMIO_PAGE = 0x4000_1000
PA_UNMAPPED_LOW = 0x2000_0000
PA_HIGH_PPN = 0x40_0000_0000  # above 38-bit physical address width
PA_BRAM_TABLE = 0x0001_0000  # outside cached DDR: PTW access fault

# Virtual addresses mapped by the two hierarchies.
VA_POOL_BASE = 0x0020_0000  # VPN[2]=0, VPN[1]=1, VPN[0]=0..17
POOL_PAGES = 18
SEEDED_POOL_PAGES = 4

VA_USER_RWX = 0x0022_0000  # L0 index 32
VA_EXEC_ONLY = 0x0022_1000  # L0 index 33
VA_CLEAN_RW = 0x0022_2000  # L0 index 34 (D=0)
VA_UNACCESSED = 0x0022_3000  # L0 index 35 (A=0)
VA_INVALID = 0x0022_4000  # L0 index 36 (V=0)
VA_STRADDLE_OK = 0x0022_5000  # L0 index 37 (RWX, followed by V=0 at 0x0022_6000)
VA_RESERVED_WR = 0x0022_7000  # L0 index 39 (W=1, R=0)
VA_RESERVED_HI = 0x0022_8000  # L0 index 40 (PTE bit 54 set)
VA_MMIO_PAGE = 0x0022_9000  # L0 index 41 (device page)
VA_UNMAPPED_PA = 0x0022_A000  # L0 index 42 (leaf PPN outside map)
VA_HIGH_PPN = 0x0022_B000  # L0 index 43 (leaf PPN above PhysAddrBits)
VA_MUT_DATA = 0x0022_C000  # L0 index 44 (mutable 4 KiB data leaf in L0_B)
VA_MUT_EXEC = 0x0022_D000  # L0 index 45 (mutable 4 KiB exec leaf in L0_B)
VA_SVVPTC = 0x0022_E000  # L0 index 46 (V=0 -> V=1 upgrade without SFENCE.VMA)

VA_MISALIGN_MEGA = 0x0040_0000  # L1_A[2]: misaligned 2 MiB leaf
VA_NONLEAF_DAU = 0x0060_0000  # L1_A[3]: non-leaf with D/A/U set
VA_NONLEAF_BRAM = 0x0080_0000  # L1_A[4]: non-leaf pointing to low BRAM
VA_MUT_MEGA = 0x00A0_0000  # L1_B[5]: mutable 2 MiB leaf

VA_G_INHERIT = 0x4000_0000  # VPN[2]=1: non-leaf G=1, leaf G=0
VA_GIGAPAGE = 0xC030_0000  # VPN[2]=3: 1 GiB leaf (RW in ROOT_A, RO in ROOT_B)
VA_THRASH_BASE = 0x1_0000_0000  # VPN[2]=4: 34 x 2 MiB megapages
VA_NEG_MEGA = 0xFFFF_FFFF_FFE0_0000  # VPN[2]=511, VPN[1]=511: negative canonical

# Sv39 PTE flags.
PTE_V = 1 << 0
PTE_R = 1 << 1
PTE_W = 1 << 2
PTE_X = 1 << 3
PTE_U = 1 << 4
PTE_G = 1 << 5
PTE_A = 1 << 6
PTE_D = 1 << 7
PTE_RESERVED_54 = 1 << 54

SATP_MODE_SV39 = 8 << 60

# mstatus bits.
MSTATUS_MPP_S = 1 << 11
MSTATUS_MPP_M = 3 << 11
MSTATUS_MPRV = 1 << 17
MSTATUS_SUM = 1 << 18
MSTATUS_MXR = 1 << 19
MSTATUS_TVM = 1 << 20
MSTATUS_TSR = 1 << 22
MSTATUS_SPP_S = 1 << 8

PRIV_U = 0
PRIV_S = 1
PRIV_M = 3

CSRS = {
    "sstatus": 0x100,
    "stvec": 0x105,
    "sscratch": 0x140,
    "sepc": 0x141,
    "scause": 0x142,
    "stval": 0x143,
    "satp": 0x180,
    "mstatus": 0x300,
    "medeleg": 0x302,
    "mtvec": 0x305,
    "mscratch": 0x340,
    "mepc": 0x341,
    "mcause": 0x342,
    "mtval": 0x343,
}

ALU_IMM = {
    "addi": (0, None, 0),
    "xori": (4, None, 0),
    "ori": (6, None, 0),
    "andi": (7, None, 0),
    "slli": (1, 0x00, 6),
    "srli": (5, 0x00, 6),
    "addiw": (0, None, 0),
}
ALU_REG = {
    "add": (0, 0x00),
    "sub": (0, 0x20),
    "xor": (4, 0x00),
    "or": (6, 0x00),
    "and": (7, 0x00),
}
LOADS = {"lb": 0, "lh": 1, "lw": 2, "ld": 3, "lbu": 4, "lhu": 5, "lwu": 6}
STORES = {"sb": 0, "sh": 1, "sw": 2, "sd": 3}
AMOS = {"amoadd": 0x00, "amoswap": 0x01, "amoxor": 0x04, "amoor": 0x08}

# Register conventions: x5..x7 scratch for constant loading, x8..x23 results.
TMP_A = 5
TMP_B = 6
TMP_C = 7
RESULTS = tuple(range(8, 24))

SFENCE_FORM_KINDS = (
    "sfence_all",
    "sfence_va",
    "sfence_asid",
    "sfence_va_asid",
)

STRAND_KINDS = (
    "setup",
    "asid_and_l2",
    "sfence_all",
    "sfence_va",
    "sfence_asid",
    "sfence_va_asid",
    "svvptc_upgrade",
    "root_switch",
    "instr_page_fault",
    "noncanonical_fetch",
    "load_page_fault",
    "store_page_fault",
    "load_access_fault",
    "store_access_fault",
    "misaligned_fault",
    "privilege_intercept",
)

MIN_FULL_SAMPLE = 11

FAULT_CASES = (
    "v0_data",
    "straddle_fetch",
    "a0_fault",
    "d0_store",
    "u_sum0",
    "u_sum1_data_and_fetch",
    "u_mode_s_page",
    "u_mode_valid",
    "x_only_mxr",
    "reserved_pte",
    "misaligned_mega",
    "nonleaf_dau",
    "nonleaf_bram_access",
    "leaf_unmapped_pa",
    "leaf_high_ppn",
    "mmio_amo_fault",
    "noncanonical_va",
    "noncanonical_fetch",
    "mapped_misalign",
    "tvm_trap",
    "tsr_trap",
    "mprv_check",
)


@dataclass(frozen=True)
class Instruction:
    """One 32-bit instruction word and its assembly text."""

    word: int
    text: str


@dataclass(frozen=True)
class StrandCheck:
    """Expected RVFI behavior for one generated strand."""

    kind: str
    priv: int
    target_index: int
    will_trap: bool = False
    expected_cause: int | None = None
    cause_index: int | None = None
    tval_index: int | None = None
    expected_tval: int | None = None
    handler_priv: int | None = None
    extra_retire_indices: tuple[int, ...] = ()
    expected_rd_zero_index: int | None = None


@dataclass
class Strand:
    """Instructions that shrinking keeps whole (noshrink) or may cut."""

    noshrink: bool
    instructions: list[Instruction]
    check: StrandCheck | None = None


@dataclass
class ModeBehaviorSummary:
    """Aggregated RVFI verification results across a batch of sequences."""

    mode: str
    catalog: tuple[str, ...]
    sequences: int = 0
    instructions: int = 0
    s_mode_sequences: int = 0
    u_mode_sequences: int = 0
    traps_taken: int = 0
    fault_xtval_reads: int = 0
    sequences_reached: dict[str, int] = field(default_factory=dict)
    strands_emitted: dict[str, int] = field(default_factory=dict)
    strands_reached: dict[str, int] = field(default_factory=dict)
    errors: list[str] = field(default_factory=list)


def trace_digest(words: Sequence[int]) -> str:
    """Return a stable SHA-256 hex digest for an instruction word stream."""
    hasher = hashlib.sha256()
    for word in words:
        hasher.update(struct.pack("<I", word & 0xFFFF_FFFF))
    return hasher.hexdigest()


def verify_strand_rvfi(
    strand: Strand,
    records: Sequence[Any],
    label: str,
) -> tuple[list[str], bool]:
    """Check one strand's RVFI slice against its StrandCheck metadata.

    Returns `(errors, counted_xtval_read)`.
    """
    check = strand.check
    if check is None:
        return [], False
    errors: list[str] = []
    if len(records) != len(strand.instructions):
        return [
            f"{label} ({check.kind}): expected {len(strand.instructions)} "
            f"RVFI records, got {len(records)}"
        ], False

    target = records[check.target_index]
    target_text = strand.instructions[check.target_index].text
    if target.mode != check.priv:
        errors.append(
            f"{label} ({check.kind}): expected privilege {check.priv} at "
            f"index {check.target_index} ({target_text}), got {target.mode}"
        )
    if bool(target.trap) != check.will_trap:
        errors.append(
            f"{label} ({check.kind}): expected trap={int(check.will_trap)} at "
            f"index {check.target_index} ({target_text}), got trap={target.trap}"
        )

    for idx in check.extra_retire_indices:
        rec = records[idx]
        if rec.trap != 0:
            errors.append(
                f"{label} ({check.kind}): expected retirement at index {idx} "
                f"({strand.instructions[idx].text}), got trap=1"
            )

    if check.expected_rd_zero_index is not None:
        sc_rec = records[check.expected_rd_zero_index]
        if sc_rec.trap != 0 or sc_rec.rd_addr == 0 or sc_rec.rd_wdata != 0:
            errors.append(
                f"{label} ({check.kind}): expected successful status 0 in "
                f"x{sc_rec.rd_addr} at index {check.expected_rd_zero_index}, "
                f"got trap={sc_rec.trap} rd_wdata={sc_rec.rd_wdata:#x}"
            )

    xtval_ok = False
    if check.will_trap:
        if check.cause_index is None:
            errors.append(f"{label} ({check.kind}): will_trap set without cause_index")
        else:
            cause_rec = records[check.cause_index]
            if cause_rec.trap != 0 or cause_rec.rd_addr == 0:
                errors.append(
                    f"{label} ({check.kind}): cause CSR read at index "
                    f"{check.cause_index} did not retire (trap={cause_rec.trap})"
                )
            else:
                if (
                    check.handler_priv is not None
                    and cause_rec.mode != check.handler_priv
                ):
                    errors.append(
                        f"{label} ({check.kind}): expected handler privilege "
                        f"{check.handler_priv}, got {cause_rec.mode}"
                    )
                if (
                    check.expected_cause is not None
                    and cause_rec.rd_wdata != check.expected_cause
                ):
                    errors.append(
                        f"{label} ({check.kind}): expected xcause="
                        f"{check.expected_cause}, got {cause_rec.rd_wdata:#x}"
                    )
        if check.tval_index is not None:
            tval_rec = records[check.tval_index]
            if tval_rec.trap != 0 or tval_rec.rd_addr == 0:
                errors.append(
                    f"{label} ({check.kind}): xtval CSR read at index "
                    f"{check.tval_index} did not retire (trap={tval_rec.trap})"
                )
            else:
                xtval_ok = True
                if (
                    check.expected_tval is not None
                    and tval_rec.rd_wdata != check.expected_tval
                ):
                    errors.append(
                        f"{label} ({check.kind}): expected xtval="
                        f"{check.expected_tval:#x}, got {tval_rec.rd_wdata:#x}"
                    )

    return errors, xtval_ok


def verify_mode_rvfi(
    mode: str,
    catalog: tuple[str, ...],
    tests: Sequence[Sequence[Strand]],
    records_by_digest: dict[str, Sequence[Any]],
    *,
    require_all_kinds: bool = True,
) -> ModeBehaviorSummary:
    """Verify every sequence's RVFI records against its strand expectations."""
    summary = ModeBehaviorSummary(
        mode=mode,
        catalog=catalog,
        sequences=len(tests),
        sequences_reached={kind: 0 for kind in catalog},
        strands_emitted={kind: 0 for kind in catalog},
        strands_reached={kind: 0 for kind in catalog},
    )
    for seq_index, strands in enumerate(tests):
        words = [inst.word for strand in strands for inst in strand.instructions]
        digest = trace_digest(words)
        records = records_by_digest.get(digest)
        if records is None:
            summary.errors.append(
                f"{mode} sequence {seq_index}: missing RVFI record stream"
            )
            continue
        if len(records) != len(words):
            summary.errors.append(
                f"{mode} sequence {seq_index}: expected {len(words)} RVFI "
                f"records, got {len(records)}"
            )
            continue

        summary.instructions += len(records)
        if any(r.mode == PRIV_S for r in records):
            summary.s_mode_sequences += 1
        if any(r.mode == PRIV_U for r in records):
            summary.u_mode_sequences += 1
        summary.traps_taken += sum(1 for r in records if r.trap)

        reached_in_seq: set[str] = set()
        offset = 0
        for strand_index, strand in enumerate(strands):
            length = len(strand.instructions)
            sub_records = records[offset : offset + length]
            offset += length
            if strand.check is None:
                continue
            kind = strand.check.kind
            summary.strands_emitted[kind] = summary.strands_emitted.get(kind, 0) + 1
            errs, xtval_ok = verify_strand_rvfi(
                strand,
                sub_records,
                f"{mode}[{seq_index}].strand[{strand_index}]",
            )
            if xtval_ok:
                summary.fault_xtval_reads += 1
            if errs:
                summary.errors.extend(errs)
            else:
                summary.strands_reached[kind] = summary.strands_reached.get(kind, 0) + 1
                reached_in_seq.add(kind)

        for kind in reached_in_seq:
            summary.sequences_reached[kind] = summary.sequences_reached.get(kind, 0) + 1

    for kind in catalog:
        emitted = summary.strands_emitted.get(kind, 0)
        reached = summary.sequences_reached.get(kind, 0)
        if emitted > 0 and reached == 0:
            summary.errors.append(
                f"{mode}: strand kind '{kind}' was emitted {emitted} times "
                f"and reached its expected behavior in 0 sequences"
            )
        elif require_all_kinds and reached == 0:
            summary.errors.append(
                f"{mode}: strand kind '{kind}' never reached its expected "
                f"behavior across {summary.sequences} sequences"
            )

    return summary


def format_behavior_summary(summary: ModeBehaviorSummary) -> str:
    """Format a ModeBehaviorSummary as a human-readable table."""
    total = max(1, summary.sequences)
    s_pct = 100.0 * summary.s_mode_sequences / total
    u_pct = 100.0 * summary.u_mode_sequences / total
    lines = [
        f"RVFI strand behavior summary ({summary.mode}, "
        f"{summary.sequences} sequences, {summary.instructions} instructions):",
        f"  S-mode sequences: {summary.s_mode_sequences}/{summary.sequences} "
        f"({s_pct:.1f}%), U-mode sequences: "
        f"{summary.u_mode_sequences}/{summary.sequences} ({u_pct:.1f}%), "
        f"traps: {summary.traps_taken}, "
        f"fault xtval reads: {summary.fault_xtval_reads}",
        f"  {'Strand kind':<26} {'Sequences':>13} {'Share':>9} {'Strands':>13}",
    ]
    for kind in summary.catalog:
        seq_hit = summary.sequences_reached.get(kind, 0)
        pct = 100.0 * seq_hit / total if summary.sequences else 0.0
        st_hit = summary.strands_reached.get(kind, 0)
        st_emit = summary.strands_emitted.get(kind, 0)
        lines.append(
            f"  {kind:<26} {f'{seq_hit} / {summary.sequences}':>13} "
            f"{pct:>8.1f}% {f'{st_hit} / {st_emit}':>13}"
        )
    return "\n".join(lines)


def _i_type(opcode: int, funct3: int, rd: int, rs1: int, imm: int) -> int:
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def _r_type(opcode: int, funct3: int, funct7: int, rd: int, rs1: int, rs2: int) -> int:
    return (
        (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode
    )


def _s_type(funct3: int, rs1: int, rs2: int, imm: int) -> int:
    return (
        (((imm >> 5) & 0x7F) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (funct3 << 12)
        | ((imm & 0x1F) << 7)
        | 0x23
    )


def lui(rd: int, imm20: int) -> Instruction:
    """Encode LUI."""
    field = imm20 & 0xFFFFF
    return Instruction((field << 12) | (rd << 7) | 0x37, f"lui x{rd}, {field:#x}")


def alu_imm(name: str, rd: int, rs1: int, imm: int) -> Instruction:
    """Encode an OP-IMM or OP-IMM-32 instruction."""
    funct3, funct7, shift_bits = ALU_IMM[name]
    opcode = 0x1B if name.endswith("w") else 0x13
    field = imm if funct7 is None else (funct7 << 5) | (imm & ((1 << shift_bits) - 1))
    return Instruction(
        _i_type(opcode, funct3, rd, rs1, field), f"{name} x{rd}, x{rs1}, {imm}"
    )


def alu_reg(name: str, rd: int, rs1: int, rs2: int) -> Instruction:
    """Encode an OP instruction."""
    funct3, funct7 = ALU_REG[name]
    return Instruction(
        _r_type(0x33, funct3, funct7, rd, rs1, rs2), f"{name} x{rd}, x{rs1}, x{rs2}"
    )


def load(name: str, rd: int, rs1: int, imm: int) -> Instruction:
    """Encode an integer load."""
    return Instruction(
        _i_type(0x03, LOADS[name], rd, rs1, imm), f"{name} x{rd}, {imm}(x{rs1})"
    )


def store(name: str, rs2: int, rs1: int, imm: int) -> Instruction:
    """Encode an integer store."""
    return Instruction(
        _s_type(STORES[name], rs1, rs2, imm), f"{name} x{rs2}, {imm}(x{rs1})"
    )


def amo(name: str, rd: int, rs2: int, rs1: int, width: int = 8) -> Instruction:
    """Encode a 32-bit or 64-bit AMO."""
    funct3 = 3 if width == 8 else 2
    suffix = "d" if width == 8 else "w"
    return Instruction(
        _r_type(0x2F, funct3, AMOS[name] << 2, rd, rs1, rs2),
        f"{name}.{suffix} x{rd}, x{rs2}, (x{rs1})",
    )


def jalr(rd: int, rs1: int, imm: int) -> Instruction:
    """Encode JALR."""
    return Instruction(_i_type(0x67, 0, rd, rs1, imm), f"jalr x{rd}, {imm}(x{rs1})")


def csrr(rd: int, name: str) -> Instruction:
    """Encode CSRRS rd, csr, x0."""
    return Instruction(_i_type(0x73, 2, rd, 0, CSRS[name]), f"csrr x{rd}, {name}")


def csrw(name: str, rs1: int) -> Instruction:
    """Encode CSRRW x0, csr, rs1."""
    return Instruction(_i_type(0x73, 1, 0, rs1, CSRS[name]), f"csrw {name}, x{rs1}")


def csrrw(rd: int, name: str, rs1: int) -> Instruction:
    """Encode CSRRW rd, csr, rs1."""
    return Instruction(
        _i_type(0x73, 1, rd, rs1, CSRS[name]), f"csrrw x{rd}, {name}, x{rs1}"
    )


def sfence_vma(rs1: int = 0, rs2: int = 0) -> Instruction:
    """Encode SFENCE.VMA rs1, rs2."""
    return Instruction(
        (0x09 << 25) | (rs2 << 20) | (rs1 << 15) | 0x73,
        f"sfence.vma x{rs1}, x{rs2}",
    )


MRET = Instruction(0x30200073, "mret")
SRET = Instruction(0x10200073, "sret")
ECALL = Instruction(0x00000073, "ecall")
EBREAK = Instruction(0x00100073, "ebreak")
FENCE = Instruction(0x0FF0000F, "fence")


def _split_s32(u32: int) -> tuple[int, int]:
    """Split a 32-bit value into (imm20, signed_imm12) for LUI + ADDIW."""
    u32 &= 0xFFFF_FFFF
    upper = ((u32 + 0x800) >> 12) & 0xFFFFF
    lower = (u32 & 0xFFF) - (0x1000 if (u32 & 0xFFF) >= 0x800 else 0)
    return upper, lower


def _load_s32(rd: int, u32: int) -> list[Instruction]:
    """Load u32 sign-extended from bit 31 into rd."""
    u32 &= 0xFFFF_FFFF
    signed = u32 - (1 << 32) if (u32 & 0x8000_0000) else u32
    if -2048 <= signed < 2048:
        return [alu_imm("addi", rd, 0, signed)]
    upper, lower = _split_s32(u32)
    seq = [lui(rd, upper)]
    if lower != 0:
        seq.append(alu_imm("addiw", rd, rd, lower))
    return seq


def load_u64(rd: int, value: int, scratch: int = TMP_C) -> list[Instruction]:
    """Load an arbitrary 64-bit integer into rd, using `scratch` when needed."""
    assert rd != 0 and rd != scratch
    value &= (1 << 64) - 1
    signed64 = value - (1 << 64) if (value & (1 << 63)) else value
    if -(1 << 31) <= signed64 < (1 << 31):
        return _load_s32(rd, value & 0xFFFF_FFFF)
    if value < (1 << 32):
        seq = _load_s32(rd, value)
        seq.append(alu_imm("slli", rd, rd, 32))
        seq.append(alu_imm("srli", rd, rd, 32))
        return seq
    hi32 = (value >> 32) & 0xFFFF_FFFF
    lo32 = value & 0xFFFF_FFFF
    seq = _load_s32(rd, hi32)
    seq.append(alu_imm("slli", rd, rd, 32))
    if lo32 == 0:
        return seq
    if lo32 < 0x800:
        seq.append(alu_imm("ori", rd, rd, lo32))
        return seq
    seq += _load_s32(scratch, lo32)
    if lo32 >= 0x8000_0000:
        seq.append(alu_imm("slli", scratch, scratch, 32))
        seq.append(alu_imm("srli", scratch, scratch, 32))
    seq.append(alu_reg("or", rd, rd, scratch))
    return seq


def make_pte(pa: int, flags: int, rsw: int = 0) -> int:
    """Pack an Sv39 PTE from a physical base address and flag mask."""
    ppn = (pa >> 12) & ((1 << 44) - 1)
    return (ppn << 10) | ((rsw & 0x3) << 8) | flags


def make_satp(asid: int, root_pa: int, mode: int = SATP_MODE_SV39) -> int:
    """Pack an RV64 satp value."""
    return mode | ((asid & 0xFFFF) << 44) | ((root_pa >> 12) & ((1 << 44) - 1))


class Generator:
    """Generate reproducible Sv39 MMU and Sstvala tests."""

    def __init__(self, rng: random.Random) -> None:
        """Initialize the generator with a random source and ASID bindings."""
        self.rng = rng
        self.asid_a1 = 1
        self.asid_a2 = 2
        self.asid_b = 3
        self.mut_data_toggle = False
        self.mut_mega_toggle = False
        self.mut_exec_ok = True
        self._mut_kind_deck: list[str] = []
        self._sfence_form_deck: list[int] = []
        self._fault_deck: list[str] = []
        self._access_fault_load_deck: list[bool] = []
        self._noncanonical_op_deck: list[str] = []
        self._root_switch_deck: list[bool] = []

    def _draw(self, deck: list[Any], items: Sequence[Any]) -> Any:
        if not deck:
            deck.extend(items)
            self.rng.shuffle(deck)
        return deck.pop()

    def _res(self) -> int:
        return self.rng.choice(RESULTS)

    def _write_pte(self, table_pa: int, index: int, pte: int) -> list[Instruction]:
        """Store `pte` into `table_pa + 8 * index` using TMP_A and TMP_B."""
        addr = table_pa + 8 * index
        base = addr & ~0x7FF
        off = addr - base
        return (
            load_u64(TMP_A, base)
            + load_u64(TMP_B, pte)
            + [store("sd", TMP_B, TMP_A, off)]
        )

    def _read_trap_csrs(self, to_s: bool) -> list[Instruction]:
        """Read xtval, xepc, and xcause into integer registers so RVFI compares them."""
        r1, r2, r3 = self.rng.sample(RESULTS, 3)
        if to_s:
            return [csrr(r1, "stval"), csrr(r2, "sepc"), csrr(r3, "scause")]
        return [csrr(r1, "mtval"), csrr(r2, "mepc"), csrr(r3, "mcause")]

    def _enter_mode(
        self,
        priv: str,
        entry_va: int,
        satp_val: int,
        *,
        mstatus_extra: int = 0,
        medeleg_mask: int = 0,
    ) -> list[Instruction]:
        """From M-mode, configure satp, medeleg, mstatus, mepc, and mret to S or U."""
        assert (medeleg_mask & (1 << 9)) == 0, "S-mode ecall must return to M-mode"
        mpp = MSTATUS_MPP_S if priv == "S" else 0
        mstatus_val = mpp | mstatus_extra
        return (
            load_u64(TMP_A, satp_val)
            + [csrw("satp", TMP_A)]
            + load_u64(TMP_A, medeleg_mask)
            + [csrw("medeleg", TMP_A)]
            + load_u64(TMP_A, mstatus_val)
            + [csrw("mstatus", TMP_A)]
            + load_u64(TMP_A, entry_va)
            + [csrw("mepc", TMP_A), MRET]
        )

    def _return_from_s_to_m(self) -> list[Instruction]:
        """Return from S-mode to M-mode via ECALL (medeleg bit 9 is always clear)."""
        return [ECALL] + self._read_trap_csrs(to_s=False)

    def _setup_strand(self) -> Strand:
        """Build the two Sv39 hierarchies and seed backing memory."""
        rng = self.rng
        # Pick distinct non-zero 9-bit ASIDs, always covering high bits as well.
        pool = rng.sample(range(1, 0x1FF), 2)
        self.asid_a1 = pool[0]
        self.asid_a2 = pool[1]
        self.asid_b = 0x1FF if rng.random() < 0.5 else rng.randrange(0x100, 0x200)
        if self.asid_b in (self.asid_a1, self.asid_a2):
            self.asid_b = 0x1FF
        self.mut_data_toggle = False
        self.mut_mega_toggle = False
        self.mut_exec_ok = True

        insns: list[Instruction] = []
        insns += load_u64(TMP_A, MTVEC_BASE) + [csrw("mtvec", TMP_A)]
        insns += load_u64(TMP_A, STVEC_BASE) + [csrw("stvec", TMP_A)]

        # System identity megapage (0x8000_0000..0x801F_FFFF, global S-mode RWX).
        rwx_g = PTE_V | PTE_R | PTE_W | PTE_X | PTE_G | PTE_A | PTE_D
        rw_ng = PTE_V | PTE_R | PTE_W | PTE_A | PTE_D
        ro_ng = PTE_V | PTE_R | PTE_A
        insns += self._write_pte(L1_SYS, 0, make_pte(0x8000_0000, rwx_g))
        insns += self._write_pte(ROOT_A, 2, make_pte(L1_SYS, PTE_V))
        insns += self._write_pte(ROOT_B, 2, make_pte(L1_SYS, PTE_V))

        # VPN[2]=0 -> L1_A / L1_B, and VPN[1]=1 -> L0_A / L0_B.
        insns += self._write_pte(ROOT_A, 0, make_pte(L1_A, PTE_V))
        insns += self._write_pte(ROOT_B, 0, make_pte(L1_B, PTE_V))
        insns += self._write_pte(L1_A, 1, make_pte(L0_A, PTE_V))
        insns += self._write_pte(L1_B, 1, make_pte(L0_B, PTE_V))

        # VPN[2]=1 -> non-leaf pointer with G=1, leaf megapage with G=0.
        insns += self._write_pte(ROOT_A, 1, make_pte(L1_GLOBAL_PTR, PTE_V | PTE_G))
        insns += self._write_pte(ROOT_B, 1, make_pte(L1_GLOBAL_PTR, PTE_V | PTE_G))
        insns += self._write_pte(L1_GLOBAL_PTR, 0, make_pte(PA_G_INHERIT, rw_ng))

        # VPN[2]=3 -> 1 GiB gigapages (RW in ROOT_A, read-only in ROOT_B).
        insns += self._write_pte(ROOT_A, 3, make_pte(0x8000_0000, rw_ng))
        insns += self._write_pte(ROOT_B, 3, make_pte(0x8000_0000, ro_ng))

        # VPN[2]=4 -> megapage thrash table for ROOT_A.
        insns += self._write_pte(ROOT_A, 4, make_pte(L1_MEGA_THRASH, PTE_V))

        # VPN[2]=511 -> upper-half negative canonical megapage.
        insns += self._write_pte(ROOT_A, 511, make_pte(L1_NEG, PTE_V))
        insns += self._write_pte(ROOT_B, 511, make_pte(L1_NEG, PTE_V))
        insns += self._write_pte(L1_NEG, 511, make_pte(PA_NEG_MEGA, rw_ng | PTE_G))

        # Populate 24 distinct 4 KiB pages in L0_A and L0_B, plus distinct values
        # at their physical targets so stale-ASID hits show up in load data.
        insns += load_u64(TMP_A, L0_A)
        insns += load_u64(TMP_B, make_pte(PA_POOL_A, rw_ng, rsw=1))
        for i in range(POOL_PAGES):
            insns.append(store("sd", TMP_B, TMP_A, 8 * i))
            if i + 1 < POOL_PAGES:
                insns.append(alu_imm("addi", TMP_B, TMP_B, 1 << 10))

        insns += load_u64(TMP_A, L0_B)
        insns += load_u64(TMP_B, make_pte(PA_POOL_B, rw_ng, rsw=2))
        for i in range(POOL_PAGES):
            insns.append(store("sd", TMP_B, TMP_A, 8 * i))
            if i + 1 < POOL_PAGES:
                insns.append(alu_imm("addi", TMP_B, TMP_B, 1 << 10))

        # Seed distinct marker words in the first SEEDED_POOL_PAGES targets of
        # PA_POOL_A and PA_POOL_B, plus the mutable targets, so stale-ASID hits
        # show up in load data without pre-dirtying every cold pool page.
        insns += load_u64(TMP_A, PA_POOL_A)
        insns += load_u64(TMP_B, 0xA000_0001 ^ rng.randrange(1 << 16))
        for i in range(SEEDED_POOL_PAGES):
            insns.append(store("sd", TMP_B, TMP_A, 0))
            insns.append(alu_imm("addi", TMP_B, TMP_B, 0x11))
            if i + 1 < SEEDED_POOL_PAGES:
                insns += load_u64(TMP_A, PA_POOL_A + (i + 1) * 0x1000)

        insns += load_u64(TMP_A, PA_POOL_B)
        insns += load_u64(TMP_B, 0xB000_0501 ^ rng.randrange(1 << 16))
        for i in range(SEEDED_POOL_PAGES):
            insns.append(store("sd", TMP_B, TMP_A, 0))
            insns.append(alu_imm("addi", TMP_B, TMP_B, 0x23))
            if i + 1 < SEEDED_POOL_PAGES:
                insns += load_u64(TMP_A, PA_POOL_B + (i + 1) * 0x1000)

        for pa, tag in (
            (PA_MUT_B0, 0x1111_2222_3333_4444),
            (PA_MUT_B1, 0x5555_6666_7777_8888),
            (PA_MUT_MEGA0 + 0x13_000, 0xCAFE_0000_0000_0001),
            (PA_MUT_MEGA1 + 0x13_000, 0xBEEF_0000_0000_0002),
            (PA_SVVPTC, 0x7777_8888_9999_AAAA),
        ):
            insns += load_u64(TMP_A, pa) + load_u64(TMP_B, tag)
            insns.append(store("sd", TMP_B, TMP_A, 0))

        # Shared special-permission and fault PTEs in both L0_A and L0_B.
        special_l0 = [
            (
                32,
                make_pte(
                    PA_SPECIAL, PTE_V | PTE_R | PTE_W | PTE_X | PTE_U | PTE_A | PTE_D
                ),
            ),
            (33, make_pte(PA_SPECIAL + 0x1000, PTE_V | PTE_X | PTE_A | PTE_D)),
            (34, make_pte(PA_SPECIAL + 0x2000, PTE_V | PTE_R | PTE_W | PTE_A)),
            (
                35,
                make_pte(PA_SPECIAL + 0x3000, PTE_V | PTE_R | PTE_W | PTE_X | PTE_D),
            ),
            (
                37,
                make_pte(
                    PA_SPECIAL + 0x5000, PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D
                ),
            ),
            (39, make_pte(PA_SPECIAL + 0x6000, PTE_V | PTE_W | PTE_A | PTE_D)),
            (
                40,
                make_pte(PA_SPECIAL + 0x7000, rw_ng | PTE_RESERVED_54),
            ),
            (41, make_pte(PA_MMIO_PAGE, rw_ng | PTE_G)),
            (42, make_pte(PA_UNMAPPED_LOW, rw_ng)),
            (43, make_pte(PA_HIGH_PPN, rw_ng)),
        ]
        for slot, pte in special_l0:
            insns += self._write_pte(L0_A, slot, pte)
            insns += self._write_pte(L0_B, slot, pte)

        # Mutable leaves in ROOT_B.
        insns += self._write_pte(L0_B, 44, make_pte(PA_MUT_B0, rw_ng))
        insns += self._write_pte(
            L0_B,
            45,
            make_pte(PA_SPECIAL + 0x8000, PTE_V | PTE_R | PTE_X | PTE_A | PTE_D),
        )
        insns += self._write_pte(L1_B, 5, make_pte(PA_MUT_MEGA0, rw_ng))

        # Faulting L1 entries in L1_A: misaligned superpage, non-leaf D/A/U,
        # and non-leaf pointing outside cached DDR.
        dau_flag = rng.choice((PTE_D, PTE_A, PTE_U))
        insns += self._write_pte(L1_A, 2, make_pte(PA_POOL_A + 0x1000, rw_ng))
        insns += self._write_pte(L1_A, 3, make_pte(L0_A, PTE_V | dau_flag))
        insns += self._write_pte(L1_A, 4, make_pte(PA_BRAM_TABLE, PTE_V))

        return Strand(
            True,
            insns,
            StrandCheck(kind="setup", priv=PRIV_M, target_index=len(insns) - 1),
        )

    def _asid_and_l2_strand(self) -> Strand:
        """Exercise ASID-only satp writes, WARL probes, and multi-ASID L2 TLB hits."""
        rng = self.rng
        satp_a1 = make_satp(self.asid_a1, ROOT_A)
        insns = self._enter_mode("S", CODE_ENTRY, satp_a1)

        # Probe ASIDLEN=9 WARL with a 16-bit ASID whose low 9 bits match asid_a1,
        # then probe an unsupported satp.MODE value (must leave satp unchanged).
        raw_asid = ((rng.randrange(1, 0x80) << 9) | self.asid_a1) & 0xFFFF
        insns += load_u64(TMP_A, make_satp(raw_asid, ROOT_A))
        insns += [csrw("satp", TMP_A), csrr(self._res(), "satp")]
        bad_mode = rng.choice((1, 2, 5, 7, 9, 10, 15)) << 60
        insns += load_u64(TMP_A, make_satp(0x1234, ROOT_B, mode=bad_mode))
        insns += [csrw("satp", TMP_A), csrr(self._res(), "satp")]

        # Spill the 16-entry L1 DTLB into the 512-entry L2 TLB across 18 pages,
        # touching the seeded marker pages first so they evict from L1 into L2.
        seeded = list(range(SEEDED_POOL_PAGES))
        rng.shuffle(seeded)
        tail = list(range(SEEDED_POOL_PAGES, POOL_PAGES))
        rng.shuffle(tail)
        pages = seeded + tail
        for idx in pages:
            off = 0 if idx < SEEDED_POOL_PAGES else 8 * rng.randrange(8)
            va = VA_POOL_BASE + idx * 0x1000 + off
            insns += load_u64(TMP_A, va) + [load("ld", self._res(), TMP_A, 0)]

        # Also touch negative canonical VA, inherited-global megapage, and gigapage.
        for va in (VA_NEG_MEGA + 0x40, VA_G_INHERIT + 0x80, VA_GIGAPAGE + 0x20):
            insns += load_u64(TMP_A, va)
            if rng.random() < 0.5:
                insns.append(load("ld", self._res(), TMP_A, 0))
            else:
                insns.append(store("sd", self._res(), TMP_A, 0))

        # Pure ASID-only satp write: keep ROOT_A, switch ASID from asid_a1 to asid_a2.
        insns += load_u64(TMP_A, make_satp(self.asid_a2, ROOT_A))
        asid_csrw_idx = len(insns)
        insns += [csrw("satp", TMP_A), csrr(self._res(), "satp")]
        for idx in pages[:4]:
            va = VA_POOL_BASE + idx * 0x1000
            insns += load_u64(TMP_A, va) + [load("ld", self._res(), TMP_A, 0)]

        # Switch to (asid_b, ROOT_B) without SFENCE.VMA; access the same VPNs.
        insns += load_u64(TMP_A, make_satp(self.asid_b, ROOT_B))
        insns += [csrw("satp", TMP_A)]
        for idx in pages[:6]:
            va = VA_POOL_BASE + idx * 0x1000
            insns += load_u64(TMP_A, va) + [load("ld", self._res(), TMP_A, 0)]

        # Switch back to (asid_a1, ROOT_A) via satp and re-read L2-resident pages.
        insns += load_u64(TMP_A, satp_a1) + [csrw("satp", TMP_A)]
        for idx in pages[:6]:
            va = VA_POOL_BASE + idx * 0x1000
            insns += load_u64(TMP_A, va) + [load("ld", self._res(), TMP_A, 0)]
        last_ld_idx = len(insns) - 1

        insns += self._return_from_s_to_m()
        return Strand(
            True,
            insns,
            StrandCheck(
                kind="asid_and_l2",
                priv=PRIV_S,
                target_index=asid_csrw_idx,
                extra_retire_indices=(last_ld_idx,),
            ),
        )

    def _emit_selective_sfence(
        self, form: int, va: int, asid: int
    ) -> list[Instruction]:
        """Emit one of the four SFENCE.VMA forms: 0=(0,0), 1=(va,0), 2=(0,asid), 3=(va,asid)."""
        rng = self.rng
        va_arg = va | rng.randrange(0, 0x1000)
        # Include non-zero upper bits above ASIDLEN=9 half the time; the spec
        # requires implementations to ignore bits above ASIDLEN in rs2.
        asid_arg = asid | (
            (rng.randrange(1, 1 << 20) << 9) if rng.random() < 0.5 else 0
        )
        if form == 0:
            return [sfence_vma(0, 0)]
        if form == 1:
            return load_u64(TMP_A, va_arg) + [sfence_vma(TMP_A, 0)]
        if form == 2:
            return load_u64(TMP_B, asid_arg) + [sfence_vma(0, TMP_B)]
        return (
            load_u64(TMP_A, va_arg)
            + load_u64(TMP_B, asid_arg)
            + [sfence_vma(TMP_A, TMP_B)]
        )

    def _sfence_mutation_strand(self) -> Strand:
        """Mutate a cached 4 KiB, 2 MiB, or executable PTE and flush selectively."""
        rng = self.rng
        kind = self._draw(self._mut_kind_deck, ("data4k", "mega2m", "exec4k", "svvptc"))
        satp_b = make_satp(self.asid_b, ROOT_B)
        rw_ng = PTE_V | PTE_R | PTE_W | PTE_A | PTE_D

        if kind == "svvptc":
            # Invalid-to-valid upgrade needs no SFENCE.VMA under Svvptc: a fault
            # handler installs the leaf and returns via sret or mret (which
            # drains committed stores without invalidating TLBs), and the retry
            # succeeds.
            cleanup_form = rng.randrange(4)
            is_exec = rng.random() < 0.4
            fault_bit = 12 if is_exec else 13
            medeleg = (1 << fault_bit) if rng.random() < 0.5 else 0
            insns = self._enter_mode("S", CODE_ENTRY, satp_b, medeleg_mask=medeleg)
            extra_retire: list[int] = []
            if is_exec:
                insns += load_u64(TMP_A, VA_SVVPTC + 16)
                extra_retire.append(len(insns))
                insns += [
                    jalr(self._res(), TMP_A, 0),
                    alu_imm("addi", self._res(), 0, 1),
                ]
            else:
                insns += load_u64(TMP_A, VA_SVVPTC + 8)
                insns.append(load("ld", self._res(), TMP_A, 0))
            fault_idx = len(insns) - 1
            tval_idx = len(insns)
            cause_idx = len(insns) + 2
            insns += self._read_trap_csrs(to_s=bool(medeleg))
            leaf_flags = (rw_ng | PTE_X) if is_exec else rw_ng
            insns += self._write_pte(L0_B, 46, make_pte(PA_SVVPTC, leaf_flags))
            insns += load_u64(TMP_A, CODE_ENTRY)
            if medeleg:
                insns += [csrw("sepc", TMP_A), SRET]
            else:
                insns += [csrw("mepc", TMP_A), MRET]
            if is_exec:
                insns += load_u64(TMP_A, VA_SVVPTC + 16)
                insns += load_u64(TMP_B, CODE_ENTRY)
                insns += [jalr(self._res(), TMP_A, 0), jalr(self._res(), TMP_B, 0)]
                retry_idx = len(insns) - 1
            else:
                insns += load_u64(TMP_A, VA_SVVPTC)
                insns.append(load("ld", self._res(), TMP_A, 0))
                retry_idx = len(insns) - 1
            extra_retire.append(retry_idx)
            # Restore V=0 and flush so later strands find VA_SVVPTC invalid.
            insns += self._write_pte(L0_B, 46, 0)
            insns += self._emit_selective_sfence(cleanup_form, VA_SVVPTC, self.asid_b)
            extra_retire.append(len(insns) - 1)
            insns += self._return_from_s_to_m()
            return Strand(
                True,
                insns,
                StrandCheck(
                    kind="svvptc_upgrade",
                    priv=PRIV_S,
                    target_index=fault_idx,
                    will_trap=True,
                    expected_cause=fault_bit,
                    cause_index=cause_idx,
                    tval_index=tval_idx,
                    handler_priv=PRIV_S if medeleg else PRIV_M,
                    extra_retire_indices=tuple(extra_retire),
                ),
            )

        form = self._draw(self._sfence_form_deck, (0, 1, 2, 3))
        form_kind = SFENCE_FORM_KINDS[form]

        if kind == "exec4k":
            medeleg = (1 << 12) if rng.random() < 0.5 else 0
            insns = self._enter_mode("S", CODE_ENTRY, satp_b, medeleg_mask=medeleg)
            # Execute at VA_MUT_EXEC when valid, return to CODE_ENTRY, then toggle X.
            if self.mut_exec_ok:
                insns += load_u64(TMP_A, VA_MUT_EXEC + 16)
                insns += load_u64(TMP_B, CODE_ENTRY)
                insns += [jalr(self._res(), TMP_A, 0), jalr(self._res(), TMP_B, 0)]
                next_flags = PTE_V | PTE_R | PTE_A | PTE_D
                self.mut_exec_ok = False
            else:
                next_flags = PTE_V | PTE_R | PTE_X | PTE_A | PTE_D
                self.mut_exec_ok = True
            insns += self._write_pte(
                L0_B, 45, make_pte(PA_SPECIAL + 0x8000, next_flags)
            )
            insns += self._emit_selective_sfence(form, VA_MUT_EXEC, self.asid_b)
            sfence_idx = len(insns) - 1
            insns += load_u64(TMP_A, VA_MUT_EXEC + 32)
            if self.mut_exec_ok:
                insns += load_u64(TMP_B, CODE_ENTRY)
                insns += [jalr(self._res(), TMP_A, 0), jalr(self._res(), TMP_B, 0)]
                exec_ret_idx = len(insns) - 1
                insns += self._return_from_s_to_m()
                return Strand(
                    True,
                    insns,
                    StrandCheck(
                        kind=form_kind,
                        priv=PRIV_S,
                        target_index=sfence_idx,
                        extra_retire_indices=(exec_ret_idx,),
                    ),
                )
            jalr_idx = len(insns)
            insns += [
                jalr(self._res(), TMP_A, 0),
                alu_imm("addi", self._res(), 0, 3),
            ]
            fault_idx = len(insns) - 1
            tval_idx = len(insns)
            cause_idx = len(insns) + 2
            insns += self._read_trap_csrs(to_s=bool(medeleg))
            if medeleg:
                insns += self._return_from_s_to_m()
            return Strand(
                True,
                insns,
                StrandCheck(
                    kind=form_kind,
                    priv=PRIV_S,
                    target_index=fault_idx,
                    will_trap=True,
                    expected_cause=12,
                    cause_index=cause_idx,
                    tval_index=tval_idx,
                    expected_tval=VA_MUT_EXEC + 32,
                    handler_priv=PRIV_S if medeleg else PRIV_M,
                    extra_retire_indices=(sfence_idx, jalr_idx),
                ),
            )

        insns = self._enter_mode("S", CODE_ENTRY, satp_b)
        if kind == "data4k":
            insns += load_u64(TMP_A, VA_MUT_DATA)
            insns.append(load("ld", self._res(), TMP_A, 0))
            # Half the time, spill 18 pool pages so VA_MUT_DATA moves to the L2 TLB
            # before the selective SFENCE.VMA runs.
            if rng.random() < 0.5:
                for idx in range(18):
                    insns += load_u64(TMP_A, VA_POOL_BASE + idx * 0x1000)
                    insns.append(load("ld", self._res(), TMP_A, 0))
            self.mut_data_toggle = not self.mut_data_toggle
            next_pa = PA_MUT_B1 if self.mut_data_toggle else PA_MUT_B0
            insns += self._write_pte(L0_B, 44, make_pte(next_pa, rw_ng))
            insns += self._emit_selective_sfence(form, VA_MUT_DATA, self.asid_b)
            sfence_idx = len(insns) - 1
            insns += load_u64(TMP_A, VA_MUT_DATA)
            insns.append(load("ld", self._res(), TMP_A, 0))
            post_ld_idx = len(insns) - 1
        else:
            # 2 MiB superpage: access and flush at an interior page (VPN[0] != 0).
            va_in_mega = VA_MUT_MEGA + 0x13_000
            insns += load_u64(TMP_A, va_in_mega)
            insns.append(load("ld", self._res(), TMP_A, 0))
            self.mut_mega_toggle = not self.mut_mega_toggle
            next_pa = PA_MUT_MEGA1 if self.mut_mega_toggle else PA_MUT_MEGA0
            insns += self._write_pte(L1_B, 5, make_pte(next_pa, rw_ng))
            flush_va = VA_MUT_MEGA + rng.randrange(512) * 0x1000
            insns += self._emit_selective_sfence(form, flush_va, self.asid_b)
            sfence_idx = len(insns) - 1
            insns += load_u64(TMP_A, va_in_mega)
            insns.append(load("ld", self._res(), TMP_A, 0))
            post_ld_idx = len(insns) - 1

        insns += self._return_from_s_to_m()
        return Strand(
            True,
            insns,
            StrandCheck(
                kind=form_kind,
                priv=PRIV_S,
                target_index=sfence_idx,
                extra_retire_indices=(post_ld_idx,),
            ),
        )

    def _root_switch_and_superpage_strand(self) -> Strand:
        """Test same-ASID root switching and 32-entry superpage side-array wrap."""
        rng = self.rng
        insns = self._enter_mode("S", CODE_ENTRY, make_satp(0, ROOT_A))
        insns += load_u64(TMP_A, VA_POOL_BASE)
        insns.append(load("ld", self._res(), TMP_A, 0))
        # Same ASID (0), second root (ROOT_B): hardware flushes TLBs without SFENCE.VMA.
        insns += load_u64(TMP_A, make_satp(0, ROOT_B))
        root_csrw_idx = len(insns)
        insns.append(csrw("satp", TMP_A))
        insns += load_u64(TMP_A, VA_POOL_BASE)
        insns.append(load("ld", self._res(), TMP_A, 0))
        post_ld_idx = len(insns) - 1
        # Clear ASID 0 with the single-ASID form (rs2 != x0 holding 0) before leaving.
        insns += [alu_imm("addi", TMP_B, 0, 0), sfence_vma(0, TMP_B)]
        sfence0_idx = len(insns) - 1
        extra_retire = [post_ld_idx, sfence0_idx]

        if rng.random() < 0.25:
            # Populate and touch 34 distinct 2 MiB megapages to wrap SP_ENTRIES=32.
            rw_ng = PTE_V | PTE_R | PTE_W | PTE_A | PTE_D
            insns += load_u64(TMP_A, make_satp(self.asid_a1, ROOT_A))
            insns.append(csrw("satp", TMP_A))
            insns += load_u64(TMP_A, L1_MEGA_THRASH)
            insns += load_u64(TMP_B, make_pte(PA_THRASH_BASE, rw_ng))
            for i in range(34):
                insns.append(store("sd", TMP_B, TMP_A, 8 * i))
                insns += load_u64(TMP_C, pte_step := (512 << 10), scratch=self._res())
                insns.append(alu_reg("add", TMP_B, TMP_B, TMP_C))
                _ = pte_step
            insns.append(sfence_vma(0, 0))
            for i in range(34):
                va = VA_THRASH_BASE + i * 0x20_0000 + 0x100
                insns += load_u64(TMP_A, va)
                insns.append(load("ld", self._res(), TMP_A, 0))
            extra_retire.append(len(insns) - 1)

        insns += self._return_from_s_to_m()
        return Strand(
            True,
            insns,
            StrandCheck(
                kind="root_switch",
                priv=PRIV_S,
                target_index=root_csrw_idx,
                extra_retire_indices=tuple(extra_retire),
            ),
        )

    def _fault_strand(self) -> Strand:
        """Trigger one translated fault or permission check and read xtval/xepc/xcause."""
        rng = self.rng
        case = self._draw(self._fault_deck, FAULT_CASES)
        satp_a = make_satp(self.asid_a1, ROOT_A)
        delegate = rng.random() < 0.5
        # Delegable synchronous exception bits (keeping bit 9 clear for S-mode ecall).
        medeleg = 0xB1FF if delegate else 0
        handler_priv = PRIV_S if delegate else PRIV_M

        if case == "mprv_check":
            # M-mode with MPRV=1: instruction fetch stays Bare while data uses Sv39.
            use_u = rng.random() < 0.4
            sum_bit = MSTATUS_SUM if rng.random() < 0.5 else 0
            mxr_bit = MSTATUS_MXR if rng.random() < 0.5 else 0
            mpp = 0 if use_u else MSTATUS_MPP_S
            insns = load_u64(TMP_A, satp_a) + [csrw("satp", TMP_A)]
            insns += load_u64(TMP_A, MSTATUS_MPRV | mpp | sum_bit | mxr_bit)
            insns.append(csrw("mstatus", TMP_A))
            target_va = (
                VA_USER_RWX + 0x18
                if (use_u or sum_bit)
                else (VA_EXEC_ONLY + 0x10 if mxr_bit else VA_INVALID + 0x28)
            )
            insns += load_u64(TMP_A, target_va)
            target_idx = len(insns)
            insns.append(load("ld", self._res(), TMP_A, 0))
            if target_va == VA_INVALID + 0x28:
                tval_idx = len(insns)
                cause_idx = len(insns) + 2
                insns += self._read_trap_csrs(to_s=False)
                check = StrandCheck(
                    kind="load_page_fault",
                    priv=PRIV_M,
                    target_index=target_idx,
                    will_trap=True,
                    expected_cause=13,
                    cause_index=cause_idx,
                    tval_index=tval_idx,
                    expected_tval=target_va,
                    handler_priv=PRIV_M,
                )
            else:
                check = StrandCheck(
                    kind="privilege_intercept",
                    priv=PRIV_M,
                    target_index=target_idx,
                )
            # Clear MPRV so later S/U strands start with MPRV=0.
            insns += [alu_imm("addi", TMP_A, 0, 0), csrw("mstatus", TMP_A)]
            return Strand(True, insns, check)

        if case == "tvm_trap":
            insns = self._enter_mode(
                "S",
                CODE_ENTRY,
                satp_a,
                mstatus_extra=MSTATUS_TVM,
                medeleg_mask=medeleg,
            )
            form = rng.randrange(5)
            if form == 4:
                insns.append(
                    csrr(self._res(), "satp")
                    if rng.random() < 0.5
                    else csrw("satp", TMP_A)
                )
            else:
                insns += self._emit_selective_sfence(form, VA_POOL_BASE, self.asid_a1)
            target_idx = len(insns) - 1
            tval_idx = len(insns)
            cause_idx = len(insns) + 2
            insns += self._read_trap_csrs(to_s=delegate)
            if delegate:
                insns += self._return_from_s_to_m()
            insns += [alu_imm("addi", TMP_A, 0, 0), csrw("mstatus", TMP_A)]
            return Strand(
                True,
                insns,
                StrandCheck(
                    kind="privilege_intercept",
                    priv=PRIV_S,
                    target_index=target_idx,
                    will_trap=True,
                    expected_cause=2,
                    cause_index=cause_idx,
                    tval_index=tval_idx,
                    handler_priv=handler_priv,
                ),
            )

        if case == "tsr_trap":
            insns = self._enter_mode(
                "S",
                CODE_ENTRY,
                satp_a,
                mstatus_extra=MSTATUS_TSR,
                medeleg_mask=medeleg,
            )
            target_idx = len(insns)
            insns.append(SRET)
            tval_idx = len(insns)
            cause_idx = len(insns) + 2
            insns += self._read_trap_csrs(to_s=delegate)
            if delegate:
                insns += self._return_from_s_to_m()
            insns += [alu_imm("addi", TMP_A, 0, 0), csrw("mstatus", TMP_A)]
            return Strand(
                True,
                insns,
                StrandCheck(
                    kind="privilege_intercept",
                    priv=PRIV_S,
                    target_index=target_idx,
                    will_trap=True,
                    expected_cause=2,
                    cause_index=cause_idx,
                    tval_index=tval_idx,
                    handler_priv=handler_priv,
                ),
            )

        if case == "straddle_fetch":
            insns = self._enter_mode("S", CODE_ENTRY, satp_a, medeleg_mask=medeleg)
            insns += load_u64(TMP_A, VA_STRADDLE_OK + 0xFFE)
            if rng.random() < 0.5:
                # 32-bit instruction at page_end - 2 followed by V=0:
                # xepc = 0x0022_5FFE, xcause = 12. Sail 0.16's rvfi_fetch writes
                # PC instead of PC + 2 to xtval here, so check xepc/xcause and
                # clear xtval.
                jalr_idx = len(insns)
                insns += [
                    jalr(self._res(), TMP_A, 0),
                    alu_imm("addi", self._res(), 0, 7),
                    csrr(self._res(), "sepc" if delegate else "mepc"),
                    csrr(self._res(), "scause" if delegate else "mcause"),
                    csrw("stval" if delegate else "mtval", 0),
                ]
                check = StrandCheck(
                    kind="instr_page_fault",
                    priv=PRIV_S,
                    target_index=jalr_idx + 1,
                    will_trap=True,
                    expected_cause=12,
                    cause_index=jalr_idx + 3,
                    tval_index=None,
                    handler_priv=handler_priv,
                    extra_retire_indices=(jalr_idx,),
                )
            else:
                # 16-bit compressed c.li at page_end - 2 retires cleanly on the
                # valid page, then the 32-bit instruction at 0x0022_6000 faults
                # with both xepc and xtval equal to 0x0022_6000.
                jalr_idx = len(insns)
                insns += [
                    jalr(self._res(), TMP_A, 0),
                    Instruction(0x0000441D, "c.li x8, 7"),
                    alu_imm("addi", self._res(), 0, 7),
                ]
                fault_idx = len(insns) - 1
                tval_idx = len(insns)
                cause_idx = len(insns) + 2
                insns += self._read_trap_csrs(to_s=delegate)
                check = StrandCheck(
                    kind="instr_page_fault",
                    priv=PRIV_S,
                    target_index=fault_idx,
                    will_trap=True,
                    expected_cause=12,
                    cause_index=cause_idx,
                    tval_index=tval_idx,
                    expected_tval=VA_STRADDLE_OK + 0x1000,
                    handler_priv=handler_priv,
                    extra_retire_indices=(jalr_idx, jalr_idx + 1),
                )
            if delegate:
                insns += self._return_from_s_to_m()
            return Strand(True, insns, check)

        if case == "u_mode_valid":
            insns = self._enter_mode("U", VA_USER_RWX, satp_a, medeleg_mask=medeleg)
            insns += load_u64(TMP_A, VA_USER_RWX + 0x100)
            sd_idx = len(insns)
            insns += [
                store("sd", TMP_A, TMP_A, 0),
                load("ld", self._res(), TMP_A, 0),
                ECALL,
            ]
            ecall_idx = len(insns) - 1
            tval_idx = len(insns)
            cause_idx = len(insns) + 2
            insns += self._read_trap_csrs(to_s=delegate)
            if delegate:
                # Test SRET back to U-mode, then ebreak back out.
                insns += load_u64(TMP_A, VA_USER_RWX + 0x40) + [csrw("sepc", TMP_A)]
                insns += [SRET, EBREAK]
                insns += self._read_trap_csrs(to_s=True)
                insns += self._return_from_s_to_m()
            return Strand(
                True,
                insns,
                StrandCheck(
                    kind="privilege_intercept",
                    priv=PRIV_U,
                    target_index=ecall_idx,
                    will_trap=True,
                    expected_cause=8,
                    cause_index=cause_idx,
                    tval_index=tval_idx,
                    handler_priv=handler_priv,
                    extra_retire_indices=(sd_idx, sd_idx + 1),
                ),
            )

        if case == "u_mode_s_page":
            insns = self._enter_mode("U", VA_USER_RWX, satp_a, medeleg_mask=medeleg)
            va = VA_POOL_BASE + 8 * rng.randrange(64)
            insns += load_u64(TMP_A, va)
            op = rng.choice(("ld", "sd", "jalr"))
            extra_retire = []
            if op == "ld":
                insns.append(load("ld", self._res(), TMP_A, 0))
                fault_kind = "load_page_fault"
                expected_cause = 13
            elif op == "sd":
                insns.append(store("sd", TMP_A, TMP_A, 0))
                fault_kind = "store_page_fault"
                expected_cause = 15
            else:
                extra_retire.append(len(insns))
                insns += [
                    jalr(self._res(), TMP_A, 0),
                    alu_imm("addi", self._res(), 0, 7),
                ]
                fault_kind = "instr_page_fault"
                expected_cause = 12
            target_idx = len(insns) - 1
            tval_idx = len(insns)
            cause_idx = len(insns) + 2
            insns += self._read_trap_csrs(to_s=delegate)
            if delegate:
                insns += self._return_from_s_to_m()
            return Strand(
                True,
                insns,
                StrandCheck(
                    kind=fault_kind,
                    priv=PRIV_U,
                    target_index=target_idx,
                    will_trap=True,
                    expected_cause=expected_cause,
                    cause_index=cause_idx,
                    tval_index=tval_idx,
                    expected_tval=va,
                    handler_priv=handler_priv,
                    extra_retire_indices=tuple(extra_retire),
                ),
            )

        if case == "u_sum1_data_and_fetch":
            # S-mode with SUM=1: load/store to U=1 page succeeds, fetch faults (12).
            insns = self._enter_mode(
                "S",
                CODE_ENTRY,
                satp_a,
                mstatus_extra=MSTATUS_SUM,
                medeleg_mask=medeleg,
            )
            va = VA_USER_RWX + 0x80
            insns += load_u64(TMP_A, va)
            sd_idx = len(insns)
            insns += [
                store("sd", TMP_A, TMP_A, 0),
                load("ld", self._res(), TMP_A, 0),
                jalr(self._res(), TMP_A, 0),
                alu_imm("addi", self._res(), 0, 7),
            ]
            fault_idx = len(insns) - 1
            tval_idx = len(insns)
            cause_idx = len(insns) + 2
            insns += self._read_trap_csrs(to_s=delegate)
            if delegate:
                insns += self._return_from_s_to_m()
            return Strand(
                True,
                insns,
                StrandCheck(
                    kind="instr_page_fault",
                    priv=PRIV_S,
                    target_index=fault_idx,
                    will_trap=True,
                    expected_cause=12,
                    cause_index=cause_idx,
                    tval_index=tval_idx,
                    expected_tval=va,
                    handler_priv=handler_priv,
                    extra_retire_indices=(sd_idx, sd_idx + 1, sd_idx + 2),
                ),
            )

        if case == "x_only_mxr":
            mxr = rng.random() < 0.5
            insns = self._enter_mode(
                "S",
                CODE_ENTRY,
                satp_a,
                mstatus_extra=MSTATUS_MXR if mxr else 0,
                medeleg_mask=medeleg,
            )
            va = VA_EXEC_ONLY + 0x18
            insns += load_u64(TMP_A, va)
            extra_retire = []
            if mxr:
                # Load succeeds under MXR=1; store still raises store page fault 15.
                extra_retire.append(len(insns))
                insns.append(load("ld", self._res(), TMP_A, 0))
                insns.append(store("sd", TMP_A, TMP_A, 0))
                fault_kind = "store_page_fault"
                expected_cause = 15
            else:
                insns.append(load("ld", self._res(), TMP_A, 0))
                fault_kind = "load_page_fault"
                expected_cause = 13
            target_idx = len(insns) - 1
            tval_idx = len(insns)
            cause_idx = len(insns) + 2
            insns += self._read_trap_csrs(to_s=delegate)
            if delegate:
                insns += self._return_from_s_to_m()
            return Strand(
                True,
                insns,
                StrandCheck(
                    kind=fault_kind,
                    priv=PRIV_S,
                    target_index=target_idx,
                    will_trap=True,
                    expected_cause=expected_cause,
                    cause_index=cause_idx,
                    tval_index=tval_idx,
                    expected_tval=va,
                    handler_priv=handler_priv,
                    extra_retire_indices=tuple(extra_retire),
                ),
            )

        if case == "mmio_amo_fault":
            # Aligned load and store to a mapped MMIO page succeed; AMO faults (7).
            insns = self._enter_mode("S", CODE_ENTRY, satp_a, medeleg_mask=medeleg)
            va = VA_MMIO_PAGE + 0x20
            insns += load_u64(TMP_A, va)
            sd_idx = len(insns)
            insns += [
                store("sd", TMP_A, TMP_A, 0),
                load("ld", self._res(), TMP_A, 0),
                amo("amoadd", self._res(), TMP_A, TMP_A, 8),
            ]
            amo_idx = len(insns) - 1
            tval_idx = len(insns)
            cause_idx = len(insns) + 2
            insns += self._read_trap_csrs(to_s=delegate)
            if delegate:
                insns += self._return_from_s_to_m()
            return Strand(
                True,
                insns,
                StrandCheck(
                    kind="store_access_fault",
                    priv=PRIV_S,
                    target_index=amo_idx,
                    will_trap=True,
                    expected_cause=7,
                    cause_index=cause_idx,
                    tval_index=tval_idx,
                    expected_tval=va,
                    handler_priv=handler_priv,
                    extra_retire_indices=(sd_idx, sd_idx + 1),
                ),
            )

        # Remaining single-fault S-mode cases.
        insns = self._enter_mode(
            "S", CODE_ENTRY, satp_a, mstatus_extra=0, medeleg_mask=medeleg
        )
        aligned_off = 8 * rng.randrange(1, 64)
        extra_retire = []
        if case == "v0_data":
            va = VA_INVALID + aligned_off
            insns += load_u64(TMP_A, va)
            is_load = rng.random() < 0.5
            insns.append(
                load("ld", self._res(), TMP_A, 0)
                if is_load
                else store("sd", TMP_A, TMP_A, 0)
            )
            fault_kind = "load_page_fault" if is_load else "store_page_fault"
            expected_cause = 13 if is_load else 15
        elif case == "a0_fault":
            va = VA_UNACCESSED + aligned_off
            insns += load_u64(TMP_A, va)
            op = rng.choice(("ld", "sd", "jalr"))
            if op == "ld":
                insns.append(load("ld", self._res(), TMP_A, 0))
                fault_kind = "load_page_fault"
                expected_cause = 13
            elif op == "sd":
                insns.append(store("sd", TMP_A, TMP_A, 0))
                fault_kind = "store_page_fault"
                expected_cause = 15
            else:
                extra_retire.append(len(insns))
                insns += [
                    jalr(self._res(), TMP_A, 0),
                    alu_imm("addi", self._res(), 0, 7),
                ]
                fault_kind = "instr_page_fault"
                expected_cause = 12
        elif case == "d0_store":
            va = VA_CLEAN_RW + aligned_off
            insns += load_u64(TMP_A, va)
            # Load first so the D=0 entry is resident in the DTLB, then store/AMO.
            extra_retire.append(len(insns))
            insns.append(load("ld", self._res(), TMP_A, 0))
            insns.append(
                store("sd", TMP_A, TMP_A, 0)
                if rng.random() < 0.6
                else amo("amoswap", self._res(), TMP_A, TMP_A, 8)
            )
            fault_kind = "store_page_fault"
            expected_cause = 15
        elif case == "u_sum0":
            va = VA_USER_RWX + aligned_off
            insns += load_u64(TMP_A, va)
            is_load = rng.random() < 0.5
            insns.append(
                load("ld", self._res(), TMP_A, 0)
                if is_load
                else store("sd", TMP_A, TMP_A, 0)
            )
            fault_kind = "load_page_fault" if is_load else "store_page_fault"
            expected_cause = 13 if is_load else 15
        elif case == "reserved_pte":
            base_va = VA_RESERVED_WR if rng.random() < 0.5 else VA_RESERVED_HI
            va = base_va + aligned_off
            insns += load_u64(TMP_A, va)
            is_load = rng.random() < 0.5
            insns.append(
                load("ld", self._res(), TMP_A, 0)
                if is_load
                else store("sd", TMP_A, TMP_A, 0)
            )
            fault_kind = "load_page_fault" if is_load else "store_page_fault"
            expected_cause = 13 if is_load else 15
        elif case == "misaligned_mega":
            va = VA_MISALIGN_MEGA + aligned_off
            insns += load_u64(TMP_A, va)
            insns.append(load("ld", self._res(), TMP_A, 0))
            fault_kind = "load_page_fault"
            expected_cause = 13
        elif case == "nonleaf_dau":
            va = VA_NONLEAF_DAU + aligned_off
            insns += load_u64(TMP_A, va)
            insns.append(store("sd", TMP_A, TMP_A, 0))
            fault_kind = "store_page_fault"
            expected_cause = 15
        elif case in ("nonleaf_bram_access", "leaf_unmapped_pa", "leaf_high_ppn"):
            base_va = (
                VA_NONLEAF_BRAM
                if case == "nonleaf_bram_access"
                else VA_UNMAPPED_PA
                if case == "leaf_unmapped_pa"
                else VA_HIGH_PPN
            )
            va = base_va + aligned_off
            insns += load_u64(TMP_A, va)
            is_load = self._draw(self._access_fault_load_deck, (True, False))
            insns.append(
                load("ld", self._res(), TMP_A, 0)
                if is_load
                else store("sd", TMP_A, TMP_A, 0)
            )
            fault_kind = "load_access_fault" if is_load else "store_access_fault"
            expected_cause = 5 if is_load else 7
        elif case in ("noncanonical_va", "noncanonical_fetch"):
            va = rng.choice(
                (
                    0x0000_0040_0000_0180,
                    0xFFFF_FFBF_FFFF_F240,
                    0x0123_4567_89AB_C008,
                )
            )
            insns += load_u64(TMP_A, va)
            if case == "noncanonical_fetch":
                extra_retire.append(len(insns))
                insns += [
                    jalr(self._res(), TMP_A, 0),
                    alu_imm("addi", self._res(), 0, 7),
                ]
                fault_kind = "noncanonical_fetch"
                expected_cause = 12
            else:
                op = self._draw(self._noncanonical_op_deck, ("ld", "sd"))
                if op == "ld":
                    insns.append(load("ld", self._res(), TMP_A, 0))
                    fault_kind = "load_page_fault"
                    expected_cause = 13
                else:
                    insns.append(store("sd", TMP_A, TMP_A, 0))
                    fault_kind = "store_page_fault"
                    expected_cause = 15
        else:
            # Mapped misaligned access on a valid Sv39 page: misaligned trap (4/6).
            va = VA_POOL_BASE + rng.choice((1, 2, 3, 5, 6, 7))
            insns += load_u64(TMP_A, va)
            is_load = rng.random() < 0.5
            insns.append(
                load("ld", self._res(), TMP_A, 0)
                if is_load
                else store("sd", TMP_A, TMP_A, 0)
            )
            fault_kind = "misaligned_fault"
            expected_cause = 4 if is_load else 6

        target_idx = len(insns) - 1
        tval_idx = len(insns)
        cause_idx = len(insns) + 2
        insns += self._read_trap_csrs(to_s=delegate)
        if delegate:
            insns += self._return_from_s_to_m()
        return Strand(
            True,
            insns,
            StrandCheck(
                kind=fault_kind,
                priv=PRIV_S,
                target_index=target_idx,
                will_trap=True,
                expected_cause=expected_cause,
                cause_index=cause_idx,
                tval_index=tval_idx,
                expected_tval=va,
                handler_priv=handler_priv,
                extra_retire_indices=tuple(extra_retire),
            ),
        )

    def test(self, length: int) -> list[Strand]:
        """Generate one MMU test of at least `length` instructions."""
        rng = self.rng
        strands = [self._setup_strand()]
        # Guarantee every test hits ASID switches, selective SFENCE.VMA, and faults,
        # and regularly exercises same-ASID root switches and superpage wraparound.
        strands.append(self._asid_and_l2_strand())
        strands.append(self._sfence_mutation_strand())
        if self._draw(self._root_switch_deck, (True, False)):
            strands.append(self._root_switch_and_superpage_strand())
        strands.append(self._fault_strand())
        strands.append(self._fault_strand())
        count = sum(len(s.instructions) for s in strands)
        while count < length:
            roll = rng.random()
            if roll < 0.25:
                strand = self._asid_and_l2_strand()
            elif roll < 0.55:
                strand = self._sfence_mutation_strand()
            elif roll < 0.65:
                strand = self._root_switch_and_superpage_strand()
            else:
                strand = self._fault_strand()
            strands.append(strand)
            count += len(strand.instructions)
        return strands


def render(strands: list[Strand], header: list[str]) -> str:
    """Render a test as a QuickCheckVEngine trace file."""
    lines = [f"# {line}" if line else "#" for line in header]
    for strand in strands:
        lines.append(".noshrink" if strand.noshrink else ".shrink")
        lines += [
            f".4byte {inst.word:#010x} # {inst.text}" for inst in strand.instructions
        ]
    return "\n".join(lines) + "\n"


def write_tests_with_strands(
    directory: Path,
    count: int,
    seed: int,
    length: int = 350,
) -> tuple[list[Path], list[list[Strand]]]:
    """Write `count` MMU tests into `directory` and return paths and strands."""
    rng = random.Random(seed)
    generator = Generator(rng)
    directory.mkdir(parents=True, exist_ok=True)
    paths: list[Path] = []
    all_strands: list[list[Strand]] = []
    for index in range(count):
        header = [f"Sv39 MMU test {index} from seed {seed} (verif/testrig/mmu.py)"]
        path = directory / f"mmu_{seed}_{index:04d}.S"
        strands = generator.test(length)
        path.write_text(render(strands, header), encoding="utf-8")
        paths.append(path)
        all_strands.append(strands)
    return paths, all_strands


def write_tests(
    directory: Path,
    count: int,
    seed: int,
    length: int = 350,
) -> list[Path]:
    """Write `count` MMU tests from `seed` into `directory`; return their paths."""
    paths, _ = write_tests_with_strands(directory, count, seed, length)
    return paths
