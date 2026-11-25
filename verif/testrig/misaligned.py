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

"""Directed misaligned load and store traces for TestRIG (FROST vs Sail).

Generates five deterministic RVFI-DII traces covering hardware misaligned
accesses (Zicclsm, MISALIGNED_HW=1) in cached DDR and address-misaligned or
access-fault traps outside cached DDR:

  01_bare_int_offsets_boundaries.S
    Bare-mode integer loads and stores (lh, lhu, lw, lwu, ld, sh, sw, sd, and
    x0 destination/source) at every misaligned offset across 8-byte dword,
    32-byte sector, 64-byte cache-line, and 4 KiB page boundaries, plus
    aligned store-to-misaligned-load ordering and a branch immediately after a
    misaligned access.
  02_bare_fp_and_compressed.S
    Bare-mode scalar FP (flh, flw, fld, fsh, fsw, fsd) and compressed (c.lh,
    c.lhu, c.sh, c.lw, c.sw, c.ld, c.sd, c.fld, c.fsd, c.lwsp, c.ldsp,
    c.fldsp, c.swsp, c.sdsp, c.fsdsp) misaligned loads and stores at every
    misaligned offset and across 32-byte, 64-byte, and 4 KiB boundaries.
  03_sv39_same_and_cross_page.S
    Sv39 translated misaligned loads and stores across 8-byte, 32-byte,
    64-byte, and 4 KiB page boundaries (including non-adjacent physical frames
    and a 2 MiB superpage) in MPRV S, direct S, and direct U modes, plus Ssnpm
    7-bit pointer masking across a 4 KiB boundary.
  04_sv39_second_page_faults.S
    Sv39 cross-page misaligned loads faulting on the second page (invalid,
    execute-only without MXR, user page without SUM, supervisor page in U mode,
    A=0, reserved W=1/R=0, non-canonical upper VA, and unmapped upper PA),
    covering M-mode and delegated S-mode handlers alongside first-page faults.
  05_region_misaligned_and_access_traps.S
    Misaligned loads and stores in low BRAM and the MMIO, APLIC, and IMSIC
    windows (bare and Sv39, raising causes 4 and 6), misaligned atomics in DDR
    (lr/sc/amo raising causes 4 and 6), and unmapped physical addresses (bare
    and Sv39, raising access faults 5 and 7 ahead of alignment checks).

Cases omitted because Sail 0.16 cannot model FROST's rule:
  - Sv39 cross-page stores faulting on the second page: FROST validates both
    pages before writing and leaves mem_wmask=0; Sail 0.16 commits the lower
    page write before translating the upper page and reports a nonzero
    mem_wmask on the trapping RVFI record.
  - Sv39 cross-page accesses in or into misaligned-trapping regions (low BRAM
    or device windows): Sail 0.16 splits a translated cross-page access at the
    4 KiB page boundary before checking per-region misaligned_exceptions, so
    naturally aligned halves (+0xFFF for 2B, +0xFFE for 4B, +0xFFC for 8B)
    retire on Sail instead of trapping, and an upper-page alignment trap
    reports upper_va instead of the original virtual address.
  - Bare-mode accesses straddling the upper edge of cached DDR into unmapped
    space: FROST writes the upper sector base to xtval; Sail 0.16 writes the
    starting address.
  - Bare-mode accesses straddling the upper edge of low BRAM or a device window
    into unmapped space: FROST checks the lower part first (causes 4/6); Sail
    0.16 checks whole-range region containment first (causes 5/7).
"""

from pathlib import Path

from testrig.mmu import (
    CSRS as MMU_CSRS,
    MRET,
    MSTATUS_MPP_S,
    MSTATUS_MPRV,
    MSTATUS_MXR,
    MSTATUS_SUM,
    PTE_A,
    PTE_D,
    PTE_R,
    PTE_U,
    PTE_V,
    PTE_W,
    PTE_X,
    SRET,
    Instruction,
    _i_type,
    _r_type,
    alu_imm,
    alu_reg,
    load,
    load_u64,
    make_pte,
    make_satp,
    sfence_vma,
    store as _mmu_store,
)

# Register roles kept uniform across traces.
REG_BASE = 8  # x8 (s0, compressed-addressable)
REG_BASE2 = 9  # x9 (s1, compressed-addressable)
REG_RES = 10  # x10 (a0)
REG_RES2 = 11  # x11 (a1)
REG_DATA = 12  # x12 (a2)
REG_DATA2 = 13  # x13 (a3)
REG_TMP = 14  # x14 (a4)
REG_TMP2 = 15  # x15 (a5)
REG_ADDR = 16  # x16
REG_SAVED = 17  # x17
REG_MPRV = 18  # x18
REG_SENTINEL = 19  # x19
REG_CAUSE = 20  # x20
REG_TVAL = 21  # x21
REG_EPC = 22  # x22
REG_CHK = 23  # x23

# Physical layout inside the 1 GiB default DDR aperture (0x8000_0000..0xBFFF_FFFF).
MTVEC_BASE = 0x8004_0000
STVEC_BASE = 0x8008_0000
CODE_S = 0x8001_0000
CODE_U = 0xC002_0000

ROOT_PT = 0x8010_0000
L1_PT = 0x8010_1000
L0_PT = 0x8010_2000
L1_CANON = 0x8010_3000
L0_CANON = 0x8010_4000

PA_BARE_BASE = 0x8020_0000
PA_P0 = 0x8021_0000
PA_P1 = 0x8025_0000  # non-adjacent to PA_P0
PA_P2 = 0x8021_2000
PA_P3 = 0x8026_0000  # non-adjacent to PA_P2
PA_P4 = 0x8021_4000
PA_P5 = 0x8027_0000  # non-adjacent to PA_P4
PA_CANON = 0x8028_0000
PA_MEGA = 0x8040_0000  # 2 MiB aligned

PA_BRAM = 0x0001_0000
PA_MMIO = 0x4000_1000
PA_APLIC = 0x4400_1000
PA_IMSIC = 0x4800_1000
PA_UNMAPPED_LOW = 0x2000_0000
PA_DEVICE_HOLE = 0x4003_1000
PA_UNMAPPED_HIGH = 0xC000_0000
PA_UNMAPPED_WIDE = 0x0001_0000_0000_0000

# Sv39 virtual addresses under ROOT_PT -> L1_PT -> L0_PT (VPN[2]=0, VPN[1]=1).
VA_P0 = 0x0020_0000  # slot 0 -> PA_P0 (RW+U+A+D)
VA_P1 = 0x0020_1000  # slot 1 -> PA_P1 (RW+U+A+D, non-adjacent)
VA_P2 = 0x0020_2000  # slot 2 -> PA_P2 (RW+A+D, S-only)
VA_P3 = 0x0020_3000  # slot 3 -> PA_P3 (RW+A+D, S-only, non-adjacent)
VA_P4 = 0x0020_4000  # slot 4 -> PA_P4 (RW+A+D)
VA_XONLY = 0x0020_5000  # slot 5 -> PA_P5 (X+A+D, R=0)
VA_MEGA = 0x0040_0000  # L1_PT[2] -> 2 MiB leaf PA_MEGA (RW+U+A+D)

# Faulting pairs in trace 04 (L0_PT slots 0..31): valid page followed by fault page.
VA_F_INV_0 = 0x0020_0000  # slot 0 valid -> slot 1 V=0
VA_F_XONLY_0 = 0x0020_2000  # slot 2 valid -> slot 3 X-only (R=0, X=1)
VA_F_USER_0 = 0x0020_4000  # slot 4 valid S-only -> slot 5 U=1 (needs SUM in S)
VA_F_SUP_0 = 0x0020_6000  # slot 6 valid U=1 -> slot 7 S-only (U=0, faults in U)
VA_F_NOACC_0 = 0x0020_8000  # slot 8 valid -> slot 9 A=0
VA_F_RESV_0 = 0x0020_A000  # slot 10 valid -> slot 11 reserved W=1, R=0
VA_F_UNMAP_0 = 0x0020_C000  # slot 12 valid -> slot 13 unmapped PA
VA_F_RO_0 = 0x0020_E000  # slot 14 RO (R=1, W=0, A=1, D=0) for first-page store fault
VA_F_CLEAN_0 = 0x0020_F000  # slot 15 RW+A, D=0 for first-page store fault
# Highest canonical positive page: VPN[2]=255, VPN[1]=511, VPN[0]=511.
# Crossing into 0x0000_0040_0000_0000 produces a non-canonical upper VA.
VA_CANON_TOP = 0x0000_003F_FFFF_F000

# Region-trap Sv39 pages in trace 05.
VA_R_BRAM_0 = 0x0020_0000  # slot 0 -> PA_BRAM
VA_R_BRAM_1 = 0x0020_1000  # slot 1 -> PA_BRAM + 0x1000
VA_R_MMIO = 0x0020_2000  # slot 2 -> PA_MMIO
VA_R_UNMAP = 0x0020_3000  # slot 3 -> PA_UNMAPPED_LOW

MSTATUS_FS_INITIAL = 1 << 13
MSTATUS_MPP_U = 0 << 11
ENVCFG_PMM_7 = 2 << 32  # Ssnpm 7-bit pointer masking (PMM = 2)

CSRS = dict(MMU_CSRS) | {
    "menvcfg": 0x30A,
    "senvcfg": 0x10A,
}

ECALL = Instruction(0x0000_0073, "ecall")

# Distinctive 64-bit seed words with mixed high-bit bytes (tests sign/zero ext).
SEED_WORDS = (
    0xF1E2_D3C4_B5A6_9788,
    0x091A_2B3C_4D5E_6F70,
    0x8192_A3B4_C5D6_E7F8,
    0x1324_3546_5768_798A,
    0x9BAC_BDCE_DFE0_F102,
    0x2536_4758_697A_8B9C,
    0xADBE_CFD0_E1F2_0314,
    0x3748_596A_7B8C_9DAE,
    0xBFC0_D1E2_F304_1526,
    0x495A_6B7C_8D9E_AF01,
    0xC1D2_E3F4_0516_2738,
    0x5B6C_7D8E_9FA0_B1C2,
    0xD3E4_F506_1728_394A,
    0x6D7E_8F90_A1B2_C3D4,
    0xE5F6_0718_293A_4B5C,
    0x7F80_91A2_B3C4_D5E6,
)


def csrw(name: str, rs1: int) -> Instruction:
    """Encode csrw <name>, rs1."""
    return Instruction(_i_type(0x73, 1, 0, rs1, CSRS[name]), f"csrw {name}, x{rs1}")


def csrr(rd: int, name: str) -> Instruction:
    """Encode csrr rd, <name>."""
    return Instruction(_i_type(0x73, 2, rd, 0, CSRS[name]), f"csrr x{rd}, {name}")


def store(op: str, rs1: int, rs2: int, imm: int = 0) -> Instruction:
    """Encode integer store sh/sw/sd with base rs1, source rs2, offset imm."""
    return _mmu_store(op, rs2, rs1, imm)


def fload(op: str, frd: int, rs1: int, imm: int = 0) -> Instruction:
    """Encode scalar FP load flh/flw/fld."""
    f3 = {"flh": 1, "flw": 2, "fld": 3}[op]
    return Instruction(_i_type(0x07, f3, frd, rs1, imm), f"{op} f{frd}, {imm}(x{rs1})")


def fstore(op: str, frs2: int, rs1: int, imm: int = 0) -> Instruction:
    """Encode scalar FP store fsh/fsw/fsd."""
    f3 = {"fsh": 1, "fsw": 2, "fsd": 3}[op]
    word = (
        (((imm >> 5) & 0x7F) << 25)
        | (frs2 << 20)
        | (rs1 << 15)
        | (f3 << 12)
        | ((imm & 0x1F) << 7)
        | 0x27
    )
    return Instruction(word, f"{op} f{frs2}, {imm}(x{rs1})")


def fmv_d_x(fd: int, rs1: int) -> Instruction:
    """Encode fmv.d.x fd, rs1."""
    return Instruction(
        _r_type(0x53, 0, 0x79, fd, rs1, 0),
        f"fmv.d.x f{fd}, x{rs1}",
    )


def fmv_x_d(rd: int, fs1: int) -> Instruction:
    """Encode fmv.x.d rd, fs1."""
    return Instruction(
        _r_type(0x53, 0, 0x71, rd, fs1, 0),
        f"fmv.x.d x{rd}, f{fs1}",
    )


def jal(rd: int, imm: int) -> Instruction:
    """Encode JAL rd, imm (imm must be even and in [-2^20, 2^20 - 2])."""
    assert imm % 2 == 0 and -(1 << 20) <= imm < (1 << 20)
    u = imm & 0x1F_FFFF
    word = (
        (((u >> 20) & 1) << 31)
        | (((u >> 1) & 0x3FF) << 21)
        | (((u >> 11) & 1) << 20)
        | (((u >> 12) & 0xFF) << 12)
        | (rd << 7)
        | 0x6F
    )
    return Instruction(word, f"jal x{rd}, {imm}")


def c_lh(rd: int, rs1: int, uimm: int = 0) -> Instruction:
    """Encode Zcb c.lh rd', uimm(rs1') with uimm in {0, 2}."""
    assert 8 <= rd <= 15 and 8 <= rs1 <= 15 and uimm in (0, 2)
    word = 0x8440 | ((rs1 - 8) << 7) | (((uimm >> 1) & 1) << 5) | ((rd - 8) << 2)
    return Instruction(word, f"c.lh x{rd}, {uimm}(x{rs1})")


def c_lhu(rd: int, rs1: int, uimm: int = 0) -> Instruction:
    """Encode Zcb c.lhu rd', uimm(rs1') with uimm in {0, 2}."""
    assert 8 <= rd <= 15 and 8 <= rs1 <= 15 and uimm in (0, 2)
    word = 0x8400 | ((rs1 - 8) << 7) | (((uimm >> 1) & 1) << 5) | ((rd - 8) << 2)
    return Instruction(word, f"c.lhu x{rd}, {uimm}(x{rs1})")


def c_sh(rs2: int, rs1: int, uimm: int = 0) -> Instruction:
    """Encode Zcb c.sh rs2', uimm(rs1') with uimm in {0, 2}."""
    assert 8 <= rs2 <= 15 and 8 <= rs1 <= 15 and uimm in (0, 2)
    word = 0x8C00 | ((rs1 - 8) << 7) | (((uimm >> 1) & 1) << 5) | ((rs2 - 8) << 2)
    return Instruction(word, f"c.sh x{rs2}, {uimm}(x{rs1})")


def c_lw(rd: int, rs1: int, uimm: int = 0) -> Instruction:
    """Encode RVC c.lw rd', uimm(rs1')."""
    assert 8 <= rd <= 15 and 8 <= rs1 <= 15 and uimm % 4 == 0 and 0 <= uimm <= 124
    word = (
        0x4000
        | (((uimm >> 3) & 7) << 10)
        | ((rs1 - 8) << 7)
        | (((uimm >> 2) & 1) << 6)
        | (((uimm >> 6) & 1) << 5)
        | ((rd - 8) << 2)
    )
    return Instruction(word, f"c.lw x{rd}, {uimm}(x{rs1})")


def c_sw(rs2: int, rs1: int, uimm: int = 0) -> Instruction:
    """Encode RVC c.sw rs2', uimm(rs1')."""
    assert 8 <= rs2 <= 15 and 8 <= rs1 <= 15 and uimm % 4 == 0 and 0 <= uimm <= 124
    word = (
        0xC000
        | (((uimm >> 3) & 7) << 10)
        | ((rs1 - 8) << 7)
        | (((uimm >> 2) & 1) << 6)
        | (((uimm >> 6) & 1) << 5)
        | ((rs2 - 8) << 2)
    )
    return Instruction(word, f"c.sw x{rs2}, {uimm}(x{rs1})")


def c_ld(rd: int, rs1: int, uimm: int = 0) -> Instruction:
    """Encode RVC c.ld rd', uimm(rs1')."""
    assert 8 <= rd <= 15 and 8 <= rs1 <= 15 and uimm % 8 == 0 and 0 <= uimm <= 248
    word = (
        0x6000
        | (((uimm >> 3) & 7) << 10)
        | ((rs1 - 8) << 7)
        | (((uimm >> 6) & 3) << 5)
        | ((rd - 8) << 2)
    )
    return Instruction(word, f"c.ld x{rd}, {uimm}(x{rs1})")


def c_sd(rs2: int, rs1: int, uimm: int = 0) -> Instruction:
    """Encode RVC c.sd rs2', uimm(rs1')."""
    assert 8 <= rs2 <= 15 and 8 <= rs1 <= 15 and uimm % 8 == 0 and 0 <= uimm <= 248
    word = (
        0xE000
        | (((uimm >> 3) & 7) << 10)
        | ((rs1 - 8) << 7)
        | (((uimm >> 6) & 3) << 5)
        | ((rs2 - 8) << 2)
    )
    return Instruction(word, f"c.sd x{rs2}, {uimm}(x{rs1})")


def c_fld(frd: int, rs1: int, uimm: int = 0) -> Instruction:
    """Encode RVC c.fld frd', uimm(rs1')."""
    assert 8 <= frd <= 15 and 8 <= rs1 <= 15 and uimm % 8 == 0 and 0 <= uimm <= 248
    word = (
        0x2000
        | (((uimm >> 3) & 7) << 10)
        | ((rs1 - 8) << 7)
        | (((uimm >> 6) & 3) << 5)
        | ((frd - 8) << 2)
    )
    return Instruction(word, f"c.fld f{frd}, {uimm}(x{rs1})")


def c_fsd(frs2: int, rs1: int, uimm: int = 0) -> Instruction:
    """Encode RVC c.fsd frs2', uimm(rs1')."""
    assert 8 <= frs2 <= 15 and 8 <= rs1 <= 15 and uimm % 8 == 0 and 0 <= uimm <= 248
    word = (
        0xA000
        | (((uimm >> 3) & 7) << 10)
        | ((rs1 - 8) << 7)
        | (((uimm >> 6) & 3) << 5)
        | ((frs2 - 8) << 2)
    )
    return Instruction(word, f"c.fsd f{frs2}, {uimm}(x{rs1})")


def c_lwsp(rd: int, uimm: int = 0) -> Instruction:
    """Encode RVC c.lwsp rd, uimm(x2)."""
    assert 1 <= rd <= 31 and uimm % 4 == 0 and 0 <= uimm <= 252
    word = (
        0x4002
        | (((uimm >> 5) & 1) << 12)
        | (rd << 7)
        | (((uimm >> 2) & 7) << 4)
        | (((uimm >> 6) & 3) << 2)
    )
    return Instruction(word, f"c.lwsp x{rd}, {uimm}(x2)")


def c_ldsp(rd: int, uimm: int = 0) -> Instruction:
    """Encode RVC c.ldsp rd, uimm(x2)."""
    assert 1 <= rd <= 31 and uimm % 8 == 0 and 0 <= uimm <= 504
    word = (
        0x6002
        | (((uimm >> 5) & 1) << 12)
        | (rd << 7)
        | (((uimm >> 3) & 3) << 5)
        | (((uimm >> 6) & 7) << 2)
    )
    return Instruction(word, f"c.ldsp x{rd}, {uimm}(x2)")


def c_fldsp(frd: int, uimm: int = 0) -> Instruction:
    """Encode RVC c.fldsp frd, uimm(x2)."""
    assert 0 <= frd <= 31 and uimm % 8 == 0 and 0 <= uimm <= 504
    word = (
        0x2002
        | (((uimm >> 5) & 1) << 12)
        | (frd << 7)
        | (((uimm >> 3) & 3) << 5)
        | (((uimm >> 6) & 7) << 2)
    )
    return Instruction(word, f"c.fldsp f{frd}, {uimm}(x2)")


def c_swsp(rs2: int, uimm: int = 0) -> Instruction:
    """Encode RVC c.swsp rs2, uimm(x2)."""
    assert 0 <= rs2 <= 31 and uimm % 4 == 0 and 0 <= uimm <= 252
    word = 0xC002 | (((uimm >> 2) & 0xF) << 9) | (((uimm >> 6) & 3) << 7) | (rs2 << 2)
    return Instruction(word, f"c.swsp x{rs2}, {uimm}(x2)")


def c_sdsp(rs2: int, uimm: int = 0) -> Instruction:
    """Encode RVC c.sdsp rs2, uimm(x2)."""
    assert 0 <= rs2 <= 31 and uimm % 8 == 0 and 0 <= uimm <= 504
    word = 0xE002 | (((uimm >> 3) & 7) << 10) | (((uimm >> 6) & 7) << 7) | (rs2 << 2)
    return Instruction(word, f"c.sdsp x{rs2}, {uimm}(x2)")


def c_fsdsp(frs2: int, uimm: int = 0) -> Instruction:
    """Encode RVC c.fsdsp frs2, uimm(x2)."""
    assert 0 <= frs2 <= 31 and uimm % 8 == 0 and 0 <= uimm <= 504
    word = 0xA002 | (((uimm >> 3) & 7) << 10) | (((uimm >> 6) & 7) << 7) | (frs2 << 2)
    return Instruction(word, f"c.fsdsp f{frs2}, {uimm}(x2)")


def lr(op: str, rd: int, rs1: int) -> Instruction:
    """Encode lr.w or lr.d."""
    f3 = 2 if op == "lr.w" else 3
    word = (0x02 << 27) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x2F
    return Instruction(word, f"{op} x{rd}, (x{rs1})")


def sc(op: str, rd: int, rs2: int, rs1: int) -> Instruction:
    """Encode sc.w or sc.d."""
    f3 = 2 if op == "sc.w" else 3
    word = (0x03 << 27) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x2F
    return Instruction(word, f"{op} x{rd}, x{rs2}, (x{rs1})")


def amoadd(op: str, rd: int, rs2: int, rs1: int) -> Instruction:
    """Encode amoadd.w or amoadd.d."""
    f3 = 2 if op == "amoadd.w" else 3
    word = (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x2F
    return Instruction(word, f"{op} x{rd}, x{rs2}, (x{rs1})")


def _seed_region(base_pa: int, dwords: int, *, start_idx: int = 0) -> list[Instruction]:
    """Initialize contiguous 8-byte words starting at base_pa with distinct patterns."""
    insns = load_u64(REG_ADDR, base_pa)
    for i in range(dwords):
        val = SEED_WORDS[(start_idx + i) % len(SEED_WORDS)]
        insns += load_u64(REG_TMP, val)
        insns.append(store("sd", REG_ADDR, REG_TMP, 8 * i))
    return insns


def _readback_dwords(base_pa: int, offsets: tuple[int, ...]) -> list[Instruction]:
    """Read aligned dwords back into REG_RES to verify stored bytes and neighbors."""
    insns = load_u64(REG_ADDR, base_pa)
    for off in offsets:
        insns.append(load("ld", REG_RES, REG_ADDR, off))
    return insns


def _write_pte(table_pa: int, index: int, pte: int) -> list[Instruction]:
    """Store one 64-bit Sv39 PTE into table_pa[index]."""
    insns = load_u64(REG_ADDR, table_pa + 8 * index)
    insns += load_u64(REG_TMP, pte)
    insns.append(store("sd", REG_ADDR, REG_TMP, 0))
    return insns


def _render_trace(header: str, insns: list[Instruction]) -> str:
    """Format one trace as .4byte lines with a header comment."""
    lines = [f"# {line}" if line else "#" for line in header.strip().splitlines()]
    lines.append(".noshrink")
    for inst in insns:
        lines.append(f".4byte 0x{inst.word:08x} # {inst.text}")
    return "\n".join(lines) + "\n"


def _build_bare_int_trace() -> tuple[str, str]:
    """Trace 01: bare-mode integer loads/stores at every offset and boundary."""
    insns: list[Instruction] = []
    insns += load_u64(REG_TMP, MTVEC_BASE)
    insns.append(csrw("mtvec", REG_TMP))

    # Seed 128 bytes at PA_BARE_BASE (covers dword, 32B sector, 64B line) and
    # 32 bytes spanning the 4 KiB boundary at PA_BARE_BASE + 0xFF0..0x1010.
    insns += _seed_region(PA_BARE_BASE, 16, start_idx=0)
    insns += _seed_region(PA_BARE_BASE + 0xFF0, 4, start_idx=5)

    # 1. Within-dword and 8-byte-dword-crossing loads at every misaligned offset.
    insns += load_u64(REG_BASE, PA_BARE_BASE)
    for off in (1, 3, 5, 7):
        insns.append(load("lh", REG_RES, REG_BASE, off))
        insns.append(load("lhu", REG_RES2, REG_BASE, off))
    for off in (1, 2, 3, 5, 6, 7):
        insns.append(load("lw", REG_RES, REG_BASE, off))
        insns.append(load("lwu", REG_RES2, REG_BASE, off))
    for off in range(1, 8):
        insns.append(load("ld", REG_RES, REG_BASE, off))

    # x0 destination loads (must retire without writing x0).
    insns.append(load("lh", 0, REG_BASE, 1))
    insns.append(load("lhu", 0, REG_BASE, 3))
    insns.append(load("lw", 0, REG_BASE, 1))
    insns.append(load("lwu", 0, REG_BASE, 2))
    insns.append(load("ld", 0, REG_BASE, 5))

    # 2. 32-byte sector boundary (+0x20) and 64-byte cache-line boundary (+0x40).
    for boundary in (0x20, 0x40):
        insns.append(load("lh", REG_RES, REG_BASE, boundary - 1))
        insns.append(load("lhu", REG_RES2, REG_BASE, boundary - 1))
        for off in range(boundary - 3, boundary):
            insns.append(load("lw", REG_RES, REG_BASE, off))
            insns.append(load("lwu", REG_RES2, REG_BASE, off))
        for off in range(boundary - 7, boundary):
            insns.append(load("ld", REG_RES, REG_BASE, off))

    # 3. 4 KiB page boundary in bare mode (PA_BARE_BASE + 0x1000).
    insns += load_u64(REG_BASE2, PA_BARE_BASE + 0xFF0)
    insns.append(load("lh", REG_RES, REG_BASE2, 0x0F))
    insns.append(load("lhu", REG_RES2, REG_BASE2, 0x0F))
    for off in (0x0D, 0x0E, 0x0F):
        insns.append(load("lw", REG_RES, REG_BASE2, off))
        insns.append(load("lwu", REG_RES2, REG_BASE2, off))
    for off in range(0x09, 0x10):
        insns.append(load("ld", REG_RES, REG_BASE2, off))

    # 4. Misaligned integer stores at every misaligned offset and every boundary,
    #    with aligned readbacks of both sides after each width/boundary group.
    store_pat = 0xA1B2_C3D4_E5F6_0718
    insns += load_u64(REG_DATA, store_pat)
    insns += load_u64(REG_DATA2, 0x5E4D_3C2B_1A09_F8E7)

    # Every misaligned offset within/across 8-byte dword (sh, sw, sd).
    for i, off in enumerate((1, 3, 5, 7)):
        insns.append(store("sh", REG_BASE, REG_DATA if i % 2 == 0 else REG_DATA2, off))
        insns += _readback_dwords(PA_BARE_BASE, (0, 8))
    for i, off in enumerate((1, 2, 3, 5, 6, 7)):
        insns.append(store("sw", REG_BASE, REG_DATA if i % 2 == 0 else REG_DATA2, off))
        insns += _readback_dwords(PA_BARE_BASE, (0, 8))
    for i, off in enumerate(range(1, 8)):
        insns.append(store("sd", REG_BASE, REG_DATA if i % 2 == 0 else REG_DATA2, off))
        insns += _readback_dwords(PA_BARE_BASE, (0, 8))

    # x0 source stores (must write zeros, not stale register RAM).
    insns.append(store("sh", REG_BASE, 0, 1))
    insns.append(store("sw", REG_BASE, 0, 5))
    insns.append(store("sd", REG_BASE, 0, 3))
    insns += _readback_dwords(PA_BARE_BASE, (0, 8))

    # 32-byte sector boundary (+0x20) and 64-byte line boundary (+0x40) stores.
    for boundary in (0x20, 0x40):
        insns.append(store("sh", REG_BASE, REG_DATA, boundary - 1))
        insns += _readback_dwords(PA_BARE_BASE, (boundary - 8, boundary))
        for off in range(boundary - 3, boundary):
            insns.append(store("sw", REG_BASE, REG_DATA2, off))
            insns += _readback_dwords(PA_BARE_BASE, (boundary - 8, boundary))
        for off in range(boundary - 7, boundary):
            insns.append(store("sd", REG_BASE, REG_DATA, off))
            insns += _readback_dwords(PA_BARE_BASE, (boundary - 8, boundary))

    # 4 KiB page boundary in bare mode stores.
    insns += load_u64(REG_BASE2, PA_BARE_BASE + 0xFF0)
    insns.append(store("sh", REG_BASE2, REG_DATA, 0x0F))
    insns += _readback_dwords(PA_BARE_BASE + 0xFF0, (0x08, 0x10))
    for off in (0x0D, 0x0E, 0x0F):
        insns.append(store("sw", REG_BASE2, REG_DATA2, off))
        insns += _readback_dwords(PA_BARE_BASE + 0xFF0, (0x08, 0x10))
    for off in range(0x09, 0x10):
        insns.append(store("sd", REG_BASE2, REG_DATA, off))
        insns += _readback_dwords(PA_BARE_BASE + 0xFF0, (0x08, 0x10))

    # 5. Ordering: aligned store immediately before misaligned load to overlapping
    #    bytes, dependent ALU after misaligned load, and JAL immediately after
    #    a misaligned load (stresses assist redirect + layout advance).
    insns += load_u64(REG_TMP, 0x1122_3344_5566_7788)
    insns.append(store("sd", REG_BASE, REG_TMP, 0x60))
    insns += load_u64(REG_TMP2, 0x99AA_BBCC_DDEE_FF00)
    insns.append(store("sd", REG_BASE, REG_TMP2, 0x68))
    insns.append(load("ld", REG_RES, REG_BASE, 0x63))
    insns.append(alu_imm("addi", REG_RES2, REG_RES, 17))
    insns.append(load("lw", REG_RES, REG_BASE, 0x65))
    insns.append(jal(REG_SAVED, 8))
    insns.append(alu_imm("addi", REG_RES2, REG_RES, 1))
    insns.append(alu_reg("xor", REG_CHK, REG_RES2, REG_SAVED))

    header = (
        "Bare-mode misaligned integer loads and stores (lh, lhu, lw, lwu, ld, "
        "sh, sw, sd, x0) at every misaligned offset across 8B dword, 32B "
        "sector, 64B cache-line, and 4 KiB page boundaries in cached DDR."
    )
    return "01_bare_int_offsets_boundaries.S", _render_trace(header, insns)


def _build_bare_fp_compressed_trace() -> tuple[str, str]:
    """Trace 02: bare-mode FP and compressed misaligned loads and stores."""
    insns: list[Instruction] = []
    # Enable FP state (mstatus.FS = Initial).
    insns += load_u64(REG_TMP, MSTATUS_FS_INITIAL)
    insns.append(csrw("mstatus", REG_TMP))
    insns += load_u64(REG_TMP, MTVEC_BASE)
    insns.append(csrw("mtvec", REG_TMP))

    # Seed DDR regions across 32B, 64B, and 4 KiB boundaries.
    insns += _seed_region(PA_BARE_BASE, 16, start_idx=2)
    insns += _seed_region(PA_BARE_BASE + 0xFF0, 4, start_idx=7)

    # Load FP source patterns into f8 (fs0) and f9 (fs1) (compressed-addressable).
    insns += load_u64(REG_DATA, 0x3FF1_921F_B544_42D1)
    insns.append(fmv_d_x(8, REG_DATA))
    insns += load_u64(REG_DATA2, 0xC024_8000_7E00_3C01)
    insns.append(fmv_d_x(9, REG_DATA2))

    insns += load_u64(REG_BASE, PA_BARE_BASE)

    # 1. Scalar FP loads (flh, flw, fld) at every misaligned offset + boundaries.
    #    fmv.x.d after each load compares all 64 bits including NaN boxing.
    for off in (1, 3, 7, 0x1F, 0x3F):
        insns.append(fload("flh", 10, REG_BASE, off))
        insns.append(fmv_x_d(REG_RES, 10))
    for off in (1, 2, 3, 5, 6, 7, 0x1D, 0x1E, 0x1F, 0x3D, 0x3E, 0x3F):
        insns.append(fload("flw", 10, REG_BASE, off))
        insns.append(fmv_x_d(REG_RES, 10))
    for off in (
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        0x19,
        0x1A,
        0x1B,
        0x1C,
        0x1D,
        0x1E,
        0x1F,
        0x39,
        0x3A,
        0x3B,
        0x3C,
        0x3D,
        0x3E,
        0x3F,
    ):
        insns.append(fload("fld", 10, REG_BASE, off))
        insns.append(fmv_x_d(REG_RES, 10))

    # FP loads across 4 KiB bare page boundary.
    insns += load_u64(REG_BASE2, PA_BARE_BASE + 0xFF0)
    insns.append(fload("flh", 10, REG_BASE2, 0x0F))
    insns.append(fmv_x_d(REG_RES, 10))
    for off in (0x0D, 0x0E, 0x0F):
        insns.append(fload("flw", 10, REG_BASE2, off))
        insns.append(fmv_x_d(REG_RES, 10))
    for off in range(0x09, 0x10):
        insns.append(fload("fld", 10, REG_BASE2, off))
        insns.append(fmv_x_d(REG_RES, 10))

    # 2. Scalar FP stores (fsh, fsw, fsd) at every misaligned offset + boundaries.
    for off in (1, 7, 0x1F, 0x3F):
        insns.append(fstore("fsh", 8, REG_BASE, off))
        insns += _readback_dwords(PA_BARE_BASE, (off & ~7, (off & ~7) + 8))
    for off in (1, 2, 3, 5, 0x1D, 0x1E, 0x1F, 0x3D, 0x3E, 0x3F):
        insns.append(fstore("fsw", 9, REG_BASE, off))
        insns += _readback_dwords(PA_BARE_BASE, (off & ~7, (off & ~7) + 8))
    for off in (1, 2, 3, 4, 5, 6, 7, 0x19, 0x1D, 0x1F, 0x39, 0x3C, 0x3F):
        insns.append(fstore("fsd", 8, REG_BASE, off))
        insns += _readback_dwords(PA_BARE_BASE, (off & ~7, (off & ~7) + 8))
    insns += load_u64(REG_BASE2, PA_BARE_BASE + 0xFF0)
    insns.append(fstore("fsh", 9, REG_BASE2, 0x0F))
    insns.append(fstore("fsw", 8, REG_BASE2, 0x0E))
    insns.append(fstore("fsd", 9, REG_BASE2, 0x0B))
    insns += _readback_dwords(PA_BARE_BASE + 0xFF0, (0x08, 0x10))

    # 3. Compressed loads and stores (Zcb c.lh/c.lhu/c.sh; RVC c.lw/c.sw/c.ld/
    #    c.sd/c.fld/c.fsd; stack-pointer c.*sp) with PC step +2.
    #    Use misaligned base pointers in x8/x9/x2 to hit every offset and boundary.
    insns += _seed_region(PA_BARE_BASE, 16, start_idx=9)
    insns += _seed_region(PA_BARE_BASE + 0xFF0, 4, start_idx=1)
    insns += load_u64(REG_DATA, 0xDE11_AD22_BE33_EF44)
    insns.append(fmv_d_x(8, REG_DATA))

    # Zcb c.lh, c.lhu, c.sh across dword (+1, +7), 32B (+0x1F), 64B (+0x3F), 4KiB (+0xFFF).
    for addr in (
        PA_BARE_BASE + 1,
        PA_BARE_BASE + 7,
        PA_BARE_BASE + 0x1F,
        PA_BARE_BASE + 0x3F,
        PA_BARE_BASE + 0xFFF,
    ):
        insns += load_u64(REG_BASE, addr)
        insns.append(c_lh(REG_RES, REG_BASE, 0))
        insns.append(c_lhu(REG_RES2, REG_BASE, 0))
        insns.append(c_sh(REG_DATA, REG_BASE, 0))
        insns += _readback_dwords(addr & ~7, (0, 8))
    # Also exercise nonzero uimm=2 on c.lh/c.lhu/c.sh.
    insns += load_u64(REG_BASE, PA_BARE_BASE + 0x1D)
    insns.append(c_lh(REG_RES, REG_BASE, 2))
    insns.append(c_lhu(REG_RES2, REG_BASE, 2))
    insns.append(c_sh(REG_DATA2, REG_BASE, 2))

    # RVC c.lw / c.sw at offsets 1, 2, 3 and across 32B, 64B, 4 KiB boundaries.
    for addr in (
        PA_BARE_BASE + 1,
        PA_BARE_BASE + 2,
        PA_BARE_BASE + 3,
        PA_BARE_BASE + 0x1D,
        PA_BARE_BASE + 0x1E,
        PA_BARE_BASE + 0x1F,
        PA_BARE_BASE + 0x3E,
        PA_BARE_BASE + 0xFFD,
        PA_BARE_BASE + 0xFFF,
    ):
        insns += load_u64(REG_BASE, addr)
        insns.append(c_lw(REG_RES, REG_BASE, 0))
        insns.append(c_sw(REG_DATA, REG_BASE, 0))
        insns += _readback_dwords(addr & ~7, (0, 8))

    # RVC c.ld / c.sd / c.fld / c.fsd at offsets 1..7 and across 32B, 64B, 4 KiB.
    for addr in (
        PA_BARE_BASE + 1,
        PA_BARE_BASE + 2,
        PA_BARE_BASE + 3,
        PA_BARE_BASE + 4,
        PA_BARE_BASE + 5,
        PA_BARE_BASE + 6,
        PA_BARE_BASE + 7,
        PA_BARE_BASE + 0x19,
        PA_BARE_BASE + 0x1F,
        PA_BARE_BASE + 0x3B,
        PA_BARE_BASE + 0x3F,
        PA_BARE_BASE + 0xFF9,
        PA_BARE_BASE + 0xFFF,
    ):
        insns += load_u64(REG_BASE, addr)
        insns.append(c_ld(REG_RES, REG_BASE, 0))
        insns.append(c_fld(10, REG_BASE, 0))
        insns.append(fmv_x_d(REG_RES2, 10))
        insns.append(c_sd(REG_DATA, REG_BASE, 0))
        insns.append(c_fsd(8, REG_BASE, 0))
        insns += _readback_dwords(addr & ~7, (0, 8))

    # Stack-pointer compressed loads/stores with misaligned sp (x2).
    for sp_addr in (
        PA_BARE_BASE + 0x1D,
        PA_BARE_BASE + 0x3B,
        PA_BARE_BASE + 0xFFB,
    ):
        insns += load_u64(2, sp_addr)
        insns.append(c_lwsp(REG_RES, 0))
        insns.append(c_ldsp(REG_RES2, 0))
        insns.append(c_fldsp(10, 0))
        insns.append(fmv_x_d(REG_CHK, 10))
        insns.append(c_swsp(REG_DATA, 0))
        insns.append(c_sdsp(REG_DATA2, 0))
        insns.append(c_fsdsp(9, 0))
        insns += _readback_dwords(sp_addr & ~7, (0, 8))

    header = (
        "Bare-mode misaligned FP (flh, flw, fld, fsh, fsw, fsd) and compressed "
        "(c.lh, c.lhu, c.sh, c.lw, c.sw, c.ld, c.sd, c.fld, c.fsd, c.lwsp, "
        "c.ldsp, c.fldsp, c.swsp, c.sdsp, c.fsdsp) loads and stores across "
        "dword, 32B sector, 64B line, and 4 KiB page boundaries in cached DDR."
    )
    return "02_bare_fp_and_compressed.S", _render_trace(header, insns)


def _build_sv39_same_and_cross_page_trace() -> tuple[str, str]:
    """Trace 03: Sv39 same-page and cross-page misaligned loads and stores."""
    insns: list[Instruction] = []
    insns += load_u64(REG_TMP, MSTATUS_FS_INITIAL)
    insns.append(csrw("mstatus", REG_TMP))
    insns += load_u64(REG_TMP, MTVEC_BASE)
    insns.append(csrw("mtvec", REG_TMP))
    insns += load_u64(REG_TMP, STVEC_BASE)
    insns.append(csrw("stvec", REG_TMP))

    # Build Sv39 page tables in DDR:
    #   ROOT_PT[0] -> L1_PT
    #   ROOT_PT[2] -> 1 GiB identity leaf at 0x8000_0000 (RWX+U+A+D for S/U fetch)
    #   L1_PT[1]   -> L0_PT (VA 0x0020_0000..0x003F_FFFF)
    #   L1_PT[2]   -> 2 MiB leaf PA_MEGA (RW+U+A+D, VA 0x0040_0000..0x005F_FFFF)
    #   L0_PT[0]   -> PA_P0 (RW+U+A+D)
    #   L0_PT[1]   -> PA_P1 (RW+U+A+D, non-adjacent physical frame!)
    #   L0_PT[2]   -> PA_P2 (RW+A+D, S-only)
    #   L0_PT[3]   -> PA_P3 (RW+A+D, S-only, non-adjacent)
    #   L0_PT[4]   -> PA_P4 (RW+A+D)
    #   L0_PT[5]   -> PA_P5 (X+A+D, R=0 for MXR=1 cross-page load)
    u_rw = PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D
    s_rw = PTE_V | PTE_R | PTE_W | PTE_A | PTE_D
    s_x = PTE_V | PTE_X | PTE_A | PTE_D
    s_code_leaf = PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D
    u_code_leaf = PTE_V | PTE_R | PTE_W | PTE_X | PTE_U | PTE_A | PTE_D

    insns += _write_pte(ROOT_PT, 0, make_pte(L1_PT, PTE_V))
    insns += _write_pte(ROOT_PT, 2, make_pte(0x8000_0000, s_code_leaf))
    insns += _write_pte(ROOT_PT, 3, make_pte(0x8000_0000, u_code_leaf))
    insns += _write_pte(L1_PT, 1, make_pte(L0_PT, PTE_V))
    insns += _write_pte(L1_PT, 2, make_pte(PA_MEGA, u_rw))
    insns += _write_pte(L0_PT, 0, make_pte(PA_P0, u_rw))
    insns += _write_pte(L0_PT, 1, make_pte(PA_P1, u_rw))
    insns += _write_pte(L0_PT, 2, make_pte(PA_P2, s_rw))
    insns += _write_pte(L0_PT, 3, make_pte(PA_P3, s_rw))
    insns += _write_pte(L0_PT, 4, make_pte(PA_P4, s_rw))
    insns += _write_pte(L0_PT, 5, make_pte(PA_P5, s_x))

    # Seed backing physical frames (start of frame and end of frame).
    insns += _seed_region(PA_P0, 16, start_idx=0)
    insns += _seed_region(PA_P0 + 0xFF0, 2, start_idx=3)
    insns += _seed_region(PA_P1, 2, start_idx=10)
    insns += _seed_region(PA_P2 + 0xFF0, 2, start_idx=6)
    insns += _seed_region(PA_P3, 2, start_idx=12)
    insns += _seed_region(PA_P4 + 0xFF0, 2, start_idx=4)
    insns += _seed_region(PA_P5, 2, start_idx=14)
    insns += _seed_region(PA_MEGA + 0xFF0, 4, start_idx=8)

    # Load FP data into f8/f9.
    insns += load_u64(REG_DATA, 0xA5B4_C3D2_E1F0_1928)
    insns.append(fmv_d_x(8, REG_DATA))
    insns += load_u64(REG_DATA2, 0x3746_5564_7382_91A0)
    insns.append(fmv_d_x(9, REG_DATA2))

    # Enable Sv39 and MPRV=1, MPP=S, SUM=1, FS=Initial.
    insns += load_u64(REG_TMP, make_satp(1, ROOT_PT))
    insns.append(csrw("satp", REG_TMP))
    insns.append(sfence_vma(0, 0))
    mprv_s_sum = MSTATUS_FS_INITIAL | MSTATUS_MPRV | MSTATUS_MPP_S | MSTATUS_SUM
    insns += load_u64(REG_MPRV, mprv_s_sum)
    insns.append(csrw("mstatus", REG_MPRV))

    # 1. Within-page translated misaligned loads & stores across dword, 32B, 64B.
    insns += load_u64(REG_BASE, VA_P0)
    for off in (1, 0x1F, 0x3F):
        insns.append(load("lh", REG_RES, REG_BASE, off))
        insns.append(load("lhu", REG_RES2, REG_BASE, off))
        insns.append(fload("flh", 10, REG_BASE, off))
        insns.append(fmv_x_d(REG_CHK, 10))
        insns.append(store("sh", REG_BASE, REG_DATA, off))
        insns.append(fstore("fsh", 9, REG_BASE, off))
    for off in (1, 2, 3, 0x1D, 0x1E, 0x1F, 0x3D, 0x3E, 0x3F):
        insns.append(load("lw", REG_RES, REG_BASE, off))
        insns.append(load("lwu", REG_RES2, REG_BASE, off))
        insns.append(fload("flw", 10, REG_BASE, off))
        insns.append(fmv_x_d(REG_CHK, 10))
        insns.append(store("sw", REG_BASE, REG_DATA2, off))
        insns.append(fstore("fsw", 8, REG_BASE, off))
    for off in (1, 2, 3, 4, 5, 6, 7, 0x19, 0x1C, 0x1F, 0x39, 0x3C, 0x3F):
        insns.append(load("ld", REG_RES, REG_BASE, off))
        insns.append(fload("fld", 10, REG_BASE, off))
        insns.append(fmv_x_d(REG_CHK, 10))
        insns.append(store("sd", REG_BASE, REG_DATA, off))
        insns.append(fstore("fsd", 9, REG_BASE, off))
    insns += _readback_dwords(VA_P0, (0, 8, 0x18, 0x20, 0x38, 0x40))

    # 2. Cross-page translated misaligned loads & stores across non-adjacent
    #    physical frames (VA_P0 -> PA_P0, VA_P1 -> PA_P1), every width & split!
    insns += load_u64(REG_BASE2, VA_P0 + 0xFF0)
    # 2-byte cross-page (+0xFFF: 1+1)
    insns.append(load("lh", REG_RES, REG_BASE2, 0x0F))
    insns.append(load("lhu", REG_RES2, REG_BASE2, 0x0F))
    insns.append(fload("flh", 10, REG_BASE2, 0x0F))
    insns.append(fmv_x_d(REG_CHK, 10))
    insns.append(store("sh", REG_BASE2, REG_DATA, 0x0F))
    insns += _readback_dwords(VA_P0 + 0xFF0, (0x08, 0x10))
    insns.append(fstore("fsh", 9, REG_BASE2, 0x0F))
    insns += _readback_dwords(VA_P0 + 0xFF0, (0x08, 0x10))

    # 4-byte cross-page (+0xFFD, +0xFFE, +0xFFF: 3+1, 2+2, 1+3)
    for off in (0x0D, 0x0E, 0x0F):
        insns.append(load("lw", REG_RES, REG_BASE2, off))
        insns.append(load("lwu", REG_RES2, REG_BASE2, off))
        insns.append(fload("flw", 10, REG_BASE2, off))
        insns.append(fmv_x_d(REG_CHK, 10))
        insns.append(store("sw", REG_BASE2, REG_DATA, off))
        insns += _readback_dwords(VA_P0 + 0xFF0, (0x08, 0x10))
        insns.append(fstore("fsw", 9, REG_BASE2, off))
        insns += _readback_dwords(VA_P0 + 0xFF0, (0x08, 0x10))

    # 8-byte cross-page (+0xFF9..+0xFFF: all 7 splits, 7+1 .. 1+7)
    for off in range(0x09, 0x10):
        insns.append(load("ld", REG_RES, REG_BASE2, off))
        insns.append(fload("fld", 10, REG_BASE2, off))
        insns.append(fmv_x_d(REG_CHK, 10))
        insns.append(store("sd", REG_BASE2, REG_DATA, off))
        insns += _readback_dwords(VA_P0 + 0xFF0, (0x08, 0x10))
        insns.append(fstore("fsd", 9, REG_BASE2, off))
        insns += _readback_dwords(VA_P0 + 0xFF0, (0x08, 0x10))

    # Compressed cross-page loads & stores across non-adjacent frames.
    for addr, ops in (
        (VA_P0 + 0xFFF, ("c_lh", "c_lhu", "c_sh")),
        (VA_P0 + 0xFFE, ("c_lw", "c_sw")),
        (VA_P0 + 0xFFB, ("c_ld", "c_sd", "c_fld", "c_fsd")),
    ):
        insns += load_u64(REG_BASE, addr)
        for op in ops:
            if op == "c_lh":
                insns.append(c_lh(REG_RES, REG_BASE, 0))
            elif op == "c_lhu":
                insns.append(c_lhu(REG_RES2, REG_BASE, 0))
            elif op == "c_sh":
                insns.append(c_sh(REG_DATA, REG_BASE, 0))
            elif op == "c_lw":
                insns.append(c_lw(REG_RES, REG_BASE, 0))
            elif op == "c_sw":
                insns.append(c_sw(REG_DATA2, REG_BASE, 0))
            elif op == "c_ld":
                insns.append(c_ld(REG_RES, REG_BASE, 0))
            elif op == "c_sd":
                insns.append(c_sd(REG_DATA, REG_BASE, 0))
            elif op == "c_fld":
                insns.append(c_fld(10, REG_BASE, 0))
                insns.append(fmv_x_d(REG_CHK, 10))
            elif op == "c_fsd":
                insns.append(c_fsd(9, REG_BASE, 0))
        insns += _readback_dwords(VA_P0 + 0xFF0, (0x08, 0x10))

    # Verify raw physical frames directly in bare mode (MPRV=0) to prove both
    # non-adjacent frames received their exact half of the cross-page stores.
    insns += load_u64(REG_TMP, MSTATUS_FS_INITIAL)
    insns.append(csrw("mstatus", REG_TMP))
    insns += _readback_dwords(PA_P0 + 0xFF0, (0x08,))
    insns += _readback_dwords(PA_P1, (0x00,))
    insns.append(csrw("mstatus", REG_MPRV))

    # 3. 2 MiB superpage crossing a 4 KiB boundary (VA_MEGA + 0xFF9..0xFFF).
    insns += load_u64(REG_BASE2, VA_MEGA + 0xFF0)
    insns.append(load("lh", REG_RES, REG_BASE2, 0x0F))
    insns.append(load("lw", REG_RES2, REG_BASE2, 0x0E))
    insns.append(load("ld", REG_RES, REG_BASE2, 0x0B))
    insns.append(store("sh", REG_BASE2, REG_DATA, 0x0F))
    insns.append(store("sw", REG_BASE2, REG_DATA2, 0x0D))
    insns.append(store("sd", REG_BASE2, REG_DATA, 0x0A))
    insns += _readback_dwords(VA_MEGA + 0xFF0, (0x08, 0x10))

    # 4. Cross-page load into X-only page with MXR=1 (VA_P4 + 0xFFC -> VA_XONLY).
    insns += load_u64(REG_TMP, mprv_s_sum | MSTATUS_MXR)
    insns.append(csrw("mstatus", REG_TMP))
    insns += load_u64(REG_BASE2, VA_P4 + 0xFF0)
    insns.append(load("ld", REG_RES, REG_BASE2, 0x0C))
    insns.append(load("lw", REG_RES2, REG_BASE2, 0x0E))

    # 5. Direct S-mode cross-page loads & stores on S-only pages (VA_P2 -> VA_P3).
    insns += load_u64(REG_TMP, MSTATUS_FS_INITIAL | MSTATUS_MPP_S)
    insns.append(csrw("mstatus", REG_TMP))
    insns += load_u64(REG_TMP, CODE_S)
    insns.append(csrw("mepc", REG_TMP))
    insns.append(MRET)
    insns += load_u64(REG_BASE2, VA_P2 + 0xFF0)
    insns.append(load("ld", REG_RES, REG_BASE2, 0x0D))
    insns.append(store("sd", REG_BASE2, REG_DATA2, 0x0D))
    insns += _readback_dwords(VA_P2 + 0xFF0, (0x08, 0x10))
    insns.append(ECALL)  # return to M-mode at MTVEC_BASE
    insns.append(csrr(REG_CAUSE, "mcause"))

    # 6. Direct U-mode cross-page loads & stores on U-pages (VA_P0 -> VA_P1),
    #    first with PMM=0, then with Ssnpm PMM=2 (7-bit pointer masking).
    insns += load_u64(REG_TMP, MSTATUS_FS_INITIAL | MSTATUS_MPP_U)
    insns.append(csrw("mstatus", REG_TMP))
    insns += load_u64(REG_TMP, CODE_U)
    insns.append(csrw("mepc", REG_TMP))
    insns.append(MRET)
    insns += load_u64(REG_BASE2, VA_P0 + 0xFF0)
    insns.append(load("lw", REG_RES, REG_BASE2, 0x0F))
    insns.append(store("sw", REG_BASE2, REG_DATA, 0x0F))
    insns.append(load("ld", REG_RES2, REG_BASE2, 0x0A))
    insns.append(store("sd", REG_BASE2, REG_DATA2, 0x0A))
    insns += _readback_dwords(VA_P0 + 0xFF0, (0x08, 0x10))
    insns.append(ECALL)  # return to M-mode
    insns.append(csrr(REG_CAUSE, "mcause"))

    # Ssnpm PMM=2 (7-bit pointer masking in U-mode via senvcfg.PMM = 2).
    insns += load_u64(REG_TMP, ENVCFG_PMM_7)
    insns.append(csrw("senvcfg", REG_TMP))
    insns += load_u64(REG_TMP, MSTATUS_FS_INITIAL | MSTATUS_MPP_U)
    insns.append(csrw("mstatus", REG_TMP))
    insns += load_u64(REG_TMP, CODE_U + 0x100)
    insns.append(csrw("mepc", REG_TMP))
    insns.append(MRET)
    # Tag top 7 bits with 0x5A << 57; masked VA is VA_P0 + 0xFFC crossing into VA_P1.
    tagged_va = (0x5A << 57) | (VA_P0 + 0xFF0)
    insns += load_u64(REG_BASE2, tagged_va)
    insns.append(load("ld", REG_RES, REG_BASE2, 0x0C))
    insns.append(store("sd", REG_BASE2, REG_DATA, 0x0C))
    insns.append(load("lw", REG_RES2, REG_BASE2, 0x0E))
    insns.append(store("sw", REG_BASE2, REG_DATA2, 0x0E))
    insns.append(ECALL)
    insns.append(csrr(REG_CAUSE, "mcause"))

    header = (
        "Sv39 translated misaligned loads and stores across 8B dword, 32B "
        "sector, 64B cache-line, and 4 KiB page boundaries (non-adjacent "
        "physical frames and a 2 MiB superpage) in MPRV S, direct S, and "
        "direct U modes, including MXR=1 and Ssnpm 7-bit pointer masking."
    )
    return "03_sv39_same_and_cross_page.S", _render_trace(header, insns)


def _build_sv39_second_page_faults_trace() -> tuple[str, str]:
    """Trace 04: Sv39 second-page faults on cross-page loads and first-page faults."""
    insns: list[Instruction] = []
    insns += load_u64(REG_TMP, MSTATUS_FS_INITIAL)
    insns.append(csrw("mstatus", REG_TMP))
    insns += load_u64(REG_TMP, MTVEC_BASE)
    insns.append(csrw("mtvec", REG_TMP))
    insns += load_u64(REG_TMP, STVEC_BASE)
    insns.append(csrw("stvec", REG_TMP))

    s_rw = PTE_V | PTE_R | PTE_W | PTE_A | PTE_D
    u_rw = PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D
    s_x = PTE_V | PTE_X | PTE_A | PTE_D
    s_ro = PTE_V | PTE_R | PTE_A
    s_noacc = PTE_V | PTE_R | PTE_W | PTE_D
    s_clean = PTE_V | PTE_R | PTE_W | PTE_A
    s_resv = PTE_V | PTE_W | PTE_A | PTE_D  # W=1, R=0 reserved
    s_code_leaf = PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D
    u_code_leaf = PTE_V | PTE_R | PTE_W | PTE_X | PTE_U | PTE_A | PTE_D

    insns += _write_pte(ROOT_PT, 0, make_pte(L1_PT, PTE_V))
    insns += _write_pte(ROOT_PT, 2, make_pte(0x8000_0000, s_code_leaf))
    insns += _write_pte(ROOT_PT, 3, make_pte(0x8000_0000, u_code_leaf))
    insns += _write_pte(ROOT_PT, 255, make_pte(L1_CANON, PTE_V))
    insns += _write_pte(L1_CANON, 511, make_pte(L0_CANON, PTE_V))
    insns += _write_pte(L0_CANON, 511, make_pte(PA_CANON, s_rw))

    insns += _write_pte(L1_PT, 1, make_pte(L0_PT, PTE_V))
    # Pair 0: slot 0 valid S-RW -> slot 1 invalid (V=0)
    insns += _write_pte(L0_PT, 0, make_pte(PA_P0, s_rw))
    insns += _write_pte(L0_PT, 1, 0)
    # Pair 1: slot 2 valid S-RW -> slot 3 X-only (R=0, X=1)
    insns += _write_pte(L0_PT, 2, make_pte(PA_P0, s_rw))
    insns += _write_pte(L0_PT, 3, make_pte(PA_P1, s_x))
    # Pair 2: slot 4 valid S-RW -> slot 5 U-RW (faults in S with SUM=0)
    insns += _write_pte(L0_PT, 4, make_pte(PA_P0, s_rw))
    insns += _write_pte(L0_PT, 5, make_pte(PA_P1, u_rw))
    # Pair 3: slot 6 valid U-RW -> slot 7 S-RW (faults in U)
    insns += _write_pte(L0_PT, 6, make_pte(PA_P0, u_rw))
    insns += _write_pte(L0_PT, 7, make_pte(PA_P1, s_rw))
    # Pair 4: slot 8 valid S-RW -> slot 9 A=0 (Svade)
    insns += _write_pte(L0_PT, 8, make_pte(PA_P0, s_rw))
    insns += _write_pte(L0_PT, 9, make_pte(PA_P1, s_noacc))
    # Pair 5: slot 10 valid S-RW -> slot 11 reserved W=1, R=0
    insns += _write_pte(L0_PT, 10, make_pte(PA_P0, s_rw))
    insns += _write_pte(L0_PT, 11, make_pte(PA_P1, s_resv))
    # Pair 6: slot 12 valid S-RW -> slot 13 unmapped physical address
    insns += _write_pte(L0_PT, 12, make_pte(PA_P0, s_rw))
    insns += _write_pte(L0_PT, 13, make_pte(PA_UNMAPPED_LOW, s_rw))
    # First-page fault pages: slot 14 RO, slot 15 D=0
    insns += _write_pte(L0_PT, 14, make_pte(PA_P0, s_ro))
    insns += _write_pte(L0_PT, 15, make_pte(PA_P0, s_clean))

    # Seed valid lower and upper backing frames.
    insns += _seed_region(PA_P0 + 0xFF0, 2, start_idx=1)
    insns += _seed_region(PA_P1, 2, start_idx=9)
    insns += _seed_region(PA_CANON + 0xFF0, 2, start_idx=13)

    # Enable Sv39.
    insns += load_u64(REG_TMP, make_satp(2, ROOT_PT))
    insns.append(csrw("satp", REG_TMP))
    insns.append(sfence_vma(0, 0))

    mprv_s = MSTATUS_FS_INITIAL | MSTATUS_MPRV | MSTATUS_MPP_S
    insns += load_u64(REG_MPRV, mprv_s)
    insns += load_u64(REG_SENTINEL, 0xCAFE_BABE_DEAD_1234)
    insns.append(fmv_d_x(10, REG_SENTINEL))

    def m_fault_check(
        base_va: int, inst: Instruction, *, check_fp: bool = False
    ) -> list[Instruction]:
        # Re-arm MPRV=1/MPP=S (previous M-mode trap set MPP=M), load sentinel,
        # execute faulting instruction, then read mcause/mtval/mepc and sentinel.
        seq: list[Instruction] = []
        seq.append(csrw("mstatus", REG_MPRV))
        seq.append(alu_imm("addi", REG_RES, REG_SENTINEL, 0))
        if check_fp:
            seq.append(fmv_d_x(10, REG_SENTINEL))
        seq += load_u64(REG_BASE, base_va)
        seq.append(inst)
        seq.append(csrr(REG_CAUSE, "mcause"))
        seq.append(csrr(REG_TVAL, "mtval"))
        seq.append(csrr(REG_EPC, "mepc"))
        if check_fp:
            seq.append(fmv_x_d(REG_CHK, 10))
        else:
            seq.append(alu_imm("addi", REG_CHK, REG_RES, 0))
        return seq

    # 1. Second page invalid (V=0): all widths, offsets, FP, and compressed.
    insns += m_fault_check(VA_F_INV_0 + 0xFF0, load("lh", REG_RES, REG_BASE, 0x0F))
    insns += m_fault_check(VA_F_INV_0 + 0xFF0, load("lhu", REG_RES, REG_BASE, 0x0F))
    for off in (0x0D, 0x0E, 0x0F):
        insns += m_fault_check(VA_F_INV_0 + 0xFF0, load("lw", REG_RES, REG_BASE, off))
    for off in range(0x09, 0x10):
        insns += m_fault_check(VA_F_INV_0 + 0xFF0, load("ld", REG_RES, REG_BASE, off))
    insns += m_fault_check(
        VA_F_INV_0 + 0xFF0, fload("flh", 10, REG_BASE, 0x0F), check_fp=True
    )
    insns += m_fault_check(
        VA_F_INV_0 + 0xFF0, fload("flw", 10, REG_BASE, 0x0E), check_fp=True
    )
    insns += m_fault_check(
        VA_F_INV_0 + 0xFF0, fload("fld", 10, REG_BASE, 0x0B), check_fp=True
    )
    insns += m_fault_check(VA_F_INV_0 + 0xFFF, c_lh(REG_RES, REG_BASE, 0))
    insns += m_fault_check(VA_F_INV_0 + 0xFFE, c_lw(REG_RES, REG_BASE, 0))
    insns += m_fault_check(VA_F_INV_0 + 0xFFB, c_ld(REG_RES, REG_BASE, 0))

    # 2. Second page execute-only (MXR=0 -> fault 13, mtval=upper_va; MXR=1 -> retires).
    insns += m_fault_check(VA_F_XONLY_0 + 0xFF0, load("ld", REG_RES, REG_BASE, 0x0C))
    insns += load_u64(REG_TMP, mprv_s | MSTATUS_MXR)
    insns.append(csrw("mstatus", REG_TMP))
    insns += load_u64(REG_BASE, VA_F_XONLY_0 + 0xFF0)
    insns.append(load("ld", REG_RES, REG_BASE, 0x0C))

    # 3. Second page U=1 in S-mode (SUM=0 -> fault 13; SUM=1 -> retires).
    insns += m_fault_check(VA_F_USER_0 + 0xFF0, load("lw", REG_RES, REG_BASE, 0x0E))
    insns += load_u64(REG_TMP, mprv_s | MSTATUS_SUM)
    insns.append(csrw("mstatus", REG_TMP))
    insns += load_u64(REG_BASE, VA_F_USER_0 + 0xFF0)
    insns.append(load("lw", REG_RES, REG_BASE, 0x0E))

    # 4. Second page A=0 (Svade -> fault 13, mtval=upper_va).
    insns += m_fault_check(VA_F_NOACC_0 + 0xFF0, load("lh", REG_RES, REG_BASE, 0x0F))

    # 5. Second page reserved PTE (W=1, R=0 -> fault 13, mtval=upper_va).
    insns += m_fault_check(VA_F_RESV_0 + 0xFF0, load("lw", REG_RES, REG_BASE, 0x0D))

    # 6. Second page non-canonical upper VA (0x3F_FFFF_FFFD -> 0x40_0000_0000 -> fault 13).
    insns += m_fault_check(VA_CANON_TOP + 0xFF0, load("lw", REG_RES, REG_BASE, 0x0D))
    insns += m_fault_check(VA_CANON_TOP + 0xFF0, load("ld", REG_RES, REG_BASE, 0x0B))

    # 7. Second page unmapped physical address -> Load Access Fault (cause 5, mtval=upper_va).
    insns += m_fault_check(VA_F_UNMAP_0 + 0xFF0, load("lh", REG_RES, REG_BASE, 0x0F))
    insns += m_fault_check(VA_F_UNMAP_0 + 0xFF0, load("lw", REG_RES, REG_BASE, 0x0E))
    insns += m_fault_check(VA_F_UNMAP_0 + 0xFF0, load("ld", REG_RES, REG_BASE, 0x0B))

    # 8. First-page faults (both loads and stores) -> mtval is original VA.
    insns += m_fault_check(VA_F_INV_0 + 0x1000, load("ld", REG_RES, REG_BASE, 3))
    insns += m_fault_check(VA_F_INV_0 + 0x1000, store("sd", REG_BASE, REG_SENTINEL, 3))
    insns += m_fault_check(VA_F_RO_0, store("sw", REG_BASE, REG_SENTINEL, 1))
    insns += m_fault_check(VA_F_RO_0 + 0xFF0, store("sd", REG_BASE, REG_SENTINEL, 0x0C))
    insns += m_fault_check(VA_F_CLEAN_0, store("sh", REG_BASE, REG_SENTINEL, 1))
    insns += m_fault_check(VA_F_UNMAP_0 + 0x1000, load("lw", REG_RES, REG_BASE, 1))
    insns += m_fault_check(
        VA_F_UNMAP_0 + 0x1000, store("sd", REG_BASE, REG_SENTINEL, 5)
    )

    # 9. Delegated S-mode traps (medeleg bits 5 and 13):
    #    (a) S-mode cross-page load faulting on invalid second page (cause 13)
    #        and unmapped upper PA (cause 5);
    #    (b) U-mode cross-page load faulting on S-only second page (cause 13).
    insns += load_u64(REG_TMP, (1 << 5) | (1 << 13))
    insns.append(csrw("medeleg", REG_TMP))
    # Enter S-mode.
    insns += load_u64(REG_TMP, MSTATUS_FS_INITIAL | MSTATUS_MPP_S)
    insns.append(csrw("mstatus", REG_TMP))
    insns += load_u64(REG_TMP, CODE_S)
    insns.append(csrw("mepc", REG_TMP))
    insns.append(MRET)
    # In S-mode: fault on invalid second page -> STVEC_BASE.
    insns.append(alu_imm("addi", REG_RES, REG_SENTINEL, 0))
    insns += load_u64(REG_BASE, VA_F_INV_0 + 0xFF0)
    insns.append(load("ld", REG_RES, REG_BASE, 0x0D))
    insns.append(csrr(REG_CAUSE, "scause"))
    insns.append(csrr(REG_TVAL, "stval"))
    insns.append(csrr(REG_EPC, "sepc"))
    insns.append(alu_imm("addi", REG_CHK, REG_RES, 0))
    # In S-mode: fault on unmapped PA second page -> STVEC_BASE (scause=5).
    insns.append(alu_imm("addi", REG_RES, REG_SENTINEL, 0))
    insns += load_u64(REG_BASE, VA_F_UNMAP_0 + 0xFF0)
    insns.append(load("lw", REG_RES, REG_BASE, 0x0E))
    insns.append(csrr(REG_CAUSE, "scause"))
    insns.append(csrr(REG_TVAL, "stval"))
    insns.append(csrr(REG_EPC, "sepc"))
    insns.append(alu_imm("addi", REG_CHK, REG_RES, 0))
    # Drop to U-mode via sret (sstatus.SPP = 0), fault on S-only second page.
    insns += load_u64(REG_TMP, MSTATUS_FS_INITIAL)
    insns.append(csrw("sstatus", REG_TMP))
    insns += load_u64(REG_TMP, CODE_U)
    insns.append(csrw("sepc", REG_TMP))
    insns.append(SRET)
    insns.append(alu_imm("addi", REG_RES, REG_SENTINEL, 0))
    insns += load_u64(REG_BASE, VA_F_SUP_0 + 0xFF0)
    insns.append(load("ld", REG_RES, REG_BASE, 0x0B))
    # Trapped to STVEC_BASE in S-mode.
    insns.append(csrr(REG_CAUSE, "scause"))
    insns.append(csrr(REG_TVAL, "stval"))
    insns.append(csrr(REG_EPC, "sepc"))
    insns.append(csrr(REG_TMP2, "sstatus"))
    insns.append(alu_imm("addi", REG_CHK, REG_RES, 0))
    insns.append(ECALL)  # return to M-mode
    insns.append(csrr(REG_CAUSE, "mcause"))

    header = (
        "Sv39 cross-page misaligned loads faulting on the second page (V=0, "
        "X-only without MXR, U without SUM, S-only in U mode, A=0, reserved "
        "W=1/R=0, non-canonical upper VA, and unmapped upper PA), in M mode "
        "and delegated to S mode, plus first-page load and store faults. "
        "Cross-page stores faulting on the second page are omitted because "
        "Sail 0.16 performs the first-page write before translating the "
        "second page."
    )
    return "04_sv39_second_page_faults.S", _render_trace(header, insns)


def _build_region_traps_trace() -> tuple[str, str]:
    """Trace 05: low BRAM / device misaligned traps, atomics, and unmapped faults."""
    insns: list[Instruction] = []
    insns += load_u64(REG_TMP, MSTATUS_FS_INITIAL)
    insns.append(csrw("mstatus", REG_TMP))
    insns += load_u64(REG_TMP, MTVEC_BASE)
    insns.append(csrw("mtvec", REG_TMP))

    # Seed low BRAM and MMIO/APLIC/IMSIC/DDR words so any erroneous partial
    # store would be visible on readback.
    insns += load_u64(REG_DATA, 0x1357_9BDF_2468_ACE0)
    insns.append(fmv_d_x(8, REG_DATA))
    insns += load_u64(REG_SENTINEL, 0x55AA_33CC_9966_0F1E)
    insns.append(fmv_d_x(10, REG_SENTINEL))
    insns += _seed_region(PA_BRAM, 4, start_idx=0)
    insns += _seed_region(PA_BRAM + 0xFF0, 4, start_idx=4)
    insns += _seed_region(PA_MMIO, 2, start_idx=8)
    insns += _seed_region(PA_APLIC, 2, start_idx=10)
    insns += _seed_region(PA_IMSIC, 2, start_idx=12)
    insns += _seed_region(PA_BARE_BASE, 2, start_idx=14)

    def trap_case(base: int, inst: Instruction) -> list[Instruction]:
        seq: list[Instruction] = []
        seq.append(alu_imm("addi", REG_RES, REG_SENTINEL, 0))
        seq += load_u64(REG_BASE, base)
        seq.append(inst)
        seq.append(csrr(REG_CAUSE, "mcause"))
        seq.append(csrr(REG_TVAL, "mtval"))
        seq.append(csrr(REG_EPC, "mepc"))
        seq.append(alu_imm("addi", REG_CHK, REG_RES, 0))
        return seq

    # 1. Low BRAM misaligned loads and stores -> causes 4 and 6, memory untouched.
    insns += trap_case(PA_BRAM, load("lh", REG_RES, REG_BASE, 1))
    insns += trap_case(PA_BRAM, load("lhu", REG_RES, REG_BASE, 3))
    insns += trap_case(PA_BRAM, load("lw", REG_RES, REG_BASE, 2))
    insns += trap_case(PA_BRAM, load("lwu", REG_RES, REG_BASE, 5))
    insns += trap_case(PA_BRAM, load("ld", REG_RES, REG_BASE, 7))
    insns += trap_case(PA_BRAM, fload("flh", 10, REG_BASE, 1))
    insns += trap_case(PA_BRAM, fload("flw", 10, REG_BASE, 3))
    insns += trap_case(PA_BRAM, fload("fld", 10, REG_BASE, 5))
    insns += trap_case(PA_BRAM, store("sh", REG_BASE, REG_DATA, 1))
    insns += trap_case(PA_BRAM, store("sw", REG_BASE, REG_DATA, 2))
    insns += trap_case(PA_BRAM, store("sd", REG_BASE, REG_DATA, 3))
    insns += trap_case(PA_BRAM, fstore("fsh", 8, REG_BASE, 1))
    insns += trap_case(PA_BRAM, fstore("fsw", 8, REG_BASE, 3))
    insns += trap_case(PA_BRAM, fstore("fsd", 8, REG_BASE, 5))
    # Cross-page inside low BRAM (both halves in BRAM -> cause 4/6).
    insns += trap_case(PA_BRAM + 0xFF0, load("ld", REG_RES, REG_BASE, 0x0C))
    insns += trap_case(PA_BRAM + 0xFF0, store("sd", REG_BASE, REG_DATA, 0x0C))
    insns += _readback_dwords(PA_BRAM, (0, 8))
    insns += _readback_dwords(PA_BRAM + 0xFF0, (0x08, 0x10))

    # 2. MMIO, APLIC, and IMSIC windows -> causes 4 and 6.
    for dev_pa in (PA_MMIO, PA_APLIC, PA_IMSIC):
        insns += trap_case(dev_pa, load("lh", REG_RES, REG_BASE, 1))
        insns += trap_case(dev_pa, load("lw", REG_RES, REG_BASE, 2))
        insns += trap_case(dev_pa, load("ld", REG_RES, REG_BASE, 5))
        insns += trap_case(dev_pa, store("sh", REG_BASE, REG_DATA, 1))
        insns += trap_case(dev_pa, store("sw", REG_BASE, REG_DATA, 3))
        insns += trap_case(dev_pa, store("sd", REG_BASE, REG_DATA, 6))
        insns += _readback_dwords(dev_pa, (0, 8))

    # 3. Misaligned atomics in cached DDR always trap (causes 4/6).
    insns += trap_case(PA_BARE_BASE + 2, lr("lr.w", REG_RES, REG_BASE))
    insns += trap_case(PA_BARE_BASE + 4, lr("lr.d", REG_RES, REG_BASE))
    insns += trap_case(PA_BARE_BASE + 2, sc("sc.w", REG_RES, REG_DATA, REG_BASE))
    insns += trap_case(PA_BARE_BASE + 4, sc("sc.d", REG_RES, REG_DATA, REG_BASE))
    insns += trap_case(
        PA_BARE_BASE + 2, amoadd("amoadd.w", REG_RES, REG_DATA, REG_BASE)
    )
    insns += trap_case(
        PA_BARE_BASE + 4, amoadd("amoadd.d", REG_RES, REG_DATA, REG_BASE)
    )

    # 4. Unmapped physical addresses -> Access Fault (5/7) outranks alignment.
    for bad_pa in (
        PA_UNMAPPED_LOW + 3,
        PA_DEVICE_HOLE + 5,
        PA_UNMAPPED_HIGH + 1,
        PA_UNMAPPED_WIDE + 7,
    ):
        insns += trap_case(bad_pa, load("lh", REG_RES, REG_BASE, 0))
        insns += trap_case(bad_pa, load("ld", REG_RES, REG_BASE, 0))
        insns += trap_case(bad_pa, store("sw", REG_BASE, REG_DATA, 0))
        insns += trap_case(bad_pa, store("sd", REG_BASE, REG_DATA, 0))

    # 5. Sv39 translated accesses to low BRAM, MMIO, and unmapped PA.
    s_rw = PTE_V | PTE_R | PTE_W | PTE_A | PTE_D
    insns += _write_pte(ROOT_PT, 0, make_pte(L1_PT, PTE_V))
    insns += _write_pte(L1_PT, 1, make_pte(L0_PT, PTE_V))
    insns += _write_pte(L0_PT, 0, make_pte(PA_BRAM, s_rw))
    insns += _write_pte(L0_PT, 1, make_pte(PA_BRAM + 0x1000, s_rw))
    insns += _write_pte(L0_PT, 2, make_pte(PA_MMIO, s_rw))
    insns += _write_pte(L0_PT, 3, make_pte(PA_UNMAPPED_LOW, s_rw))
    insns += load_u64(REG_TMP, make_satp(3, ROOT_PT))
    insns.append(csrw("satp", REG_TMP))
    insns.append(sfence_vma(0, 0))
    mprv_s = MSTATUS_FS_INITIAL | MSTATUS_MPRV | MSTATUS_MPP_S
    insns += load_u64(REG_MPRV, mprv_s)

    def mprv_trap_case(va: int, inst: Instruction) -> list[Instruction]:
        seq = [csrw("mstatus", REG_MPRV)]
        seq += trap_case(va, inst)
        return seq

    # Translated low BRAM within page (multiple offsets) -> 4/6.
    # Sv39 cross-page accesses in low BRAM are omitted because Sail 0.16 splits
    # translated cross-page accesses before checking per-region alignment.
    insns += mprv_trap_case(VA_R_BRAM_0, load("lh", REG_RES, REG_BASE, 1))
    insns += mprv_trap_case(VA_R_BRAM_0, store("sh", REG_BASE, REG_DATA, 1))
    insns += mprv_trap_case(VA_R_BRAM_0, load("ld", REG_RES, REG_BASE, 3))
    insns += mprv_trap_case(VA_R_BRAM_0, store("sd", REG_BASE, REG_DATA, 3))
    # Translated MMIO -> 4/6.
    insns += mprv_trap_case(VA_R_MMIO, load("lw", REG_RES, REG_BASE, 1))
    insns += mprv_trap_case(VA_R_MMIO, store("sw", REG_BASE, REG_DATA, 1))
    # Translated unmapped PA -> Access Fault 5/7.
    insns += mprv_trap_case(VA_R_UNMAP, load("ld", REG_RES, REG_BASE, 5))
    insns += mprv_trap_case(VA_R_UNMAP, store("sd", REG_BASE, REG_DATA, 5))

    header = (
        "Misaligned traps outside cached DDR (low BRAM, MMIO, APLIC, IMSIC) "
        "and misaligned DDR atomics (causes 4/6), plus unmapped physical "
        "addresses (causes 5/7), in bare and Sv39 modes. Bare end-of-region "
        "straddles and Sv39 cross-page accesses touching low BRAM or device "
        "windows are omitted due to Sail 0.16 split/xtval/priority rules."
    )
    return "05_region_misaligned_and_access_traps.S", _render_trace(header, insns)


TRACE_BUILDERS = (
    _build_bare_int_trace,
    _build_bare_fp_compressed_trace,
    _build_sv39_same_and_cross_page_trace,
    _build_sv39_second_page_faults_trace,
    _build_region_traps_trace,
)


def write_tests(directory: Path) -> list[Path]:
    """Write the deterministic misaligned load/store trace set into directory."""
    directory.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    for builder in TRACE_BUILDERS:
        filename, content = builder()
        path = directory / filename
        path.write_text(content, encoding="utf-8")
        written.append(path)
    return written
