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

"""Random cache-block, prefetch, Zawrs, device-drain, and Sstvala tests.

Each test exercises Zicbom (cbo.clean, cbo.flush, cbo.inval), Zicbop
(prefetch.i, prefetch.r, prefetch.w), Zicboz (cbo.zero privilege gates and
fault paths), Zawrs (wrs.sto and wrs.nto), WFI, device-window loads and stores
interleaved with cached DDR and low-BRAM stores, and Sstvala fault values
across M, S, and U modes under both Bare and Sv39 translation.

The reference model shapes the generated instruction sequences.
1. Sail 0.16's RVFI-DII write recorder asserts a maximum write width of 16
   bytes (core/rvfi_dii.sail:214), so a retiring 64-byte cbo.zero aborts the
   reference model. cbo.zero is therefore emitted on privilege-gated and
   translation/PMA fault paths, where both implementations trap and compare
   xtval, xepc, and xcause; retiring 64-byte zeroing is covered by the cocotb
   Zicboz benches.
2. Sail 0.16's non-nop wait instructions enter Step_Waiting in RVFI-DII mode,
   reporting pc_wdata = 0 and consuming the following instruction packet, so
   wfi_is_nop and nto.is_nop are both true. Sail's nop forms skip mstatus.TW
   in S-mode (while keeping WFI illegal in U-mode), whereas FROST raises
   illegal-instruction on both WFI and wrs.nto below M when mstatus.TW is set.
   These tests therefore exercise WFI and wrs.nto across M (with TW clear),
   S (with TW clear), and U (with TW clear and set on U-mode WFI, plus wrs.sto
   in S-mode with TW set and wrs.sto/wrs.nto inside active LR/SC reservation
   windows), while zawrs_test and sstvala_test cover S-mode TW=1 traps on
   wrs.nto and WFI.
3. The reference model retains stores across cache invalidation. A clean before
   a leading invalidate makes the following load deterministic on dirty DDR.
"""

import random
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from testrig.mmu import (
    CSRS as MMU_CSRS,
    ECALL,
    EBREAK,
    FENCE,
    Instruction,
    MRET,
    MSTATUS_MPP_S,
    MSTATUS_MXR,
    MSTATUS_SUM,
    PRIV_M,
    PRIV_S,
    PRIV_U,
    PTE_A,
    PTE_D,
    PTE_G,
    PTE_R,
    PTE_U,
    PTE_V,
    PTE_W,
    PTE_X,
    RESULTS,
    Strand,
    StrandCheck,
    TMP_A,
    TMP_B,
    _i_type,
    _r_type,
    alu_imm,
    csrr,
    csrw,
    load,
    load_u64,
    make_pte,
    make_satp,
    render,
    sfence_vma,
    store,
)

# Physical addresses.
CODE_ENTRY = 0x8000_0100
MTVEC_BASE = 0x8004_0000
STVEC_BASE = 0x8008_0000

ROOT_PT = 0x8010_0000
L1_PT = 0x8010_1000
L0_PT = 0x8010_2000
L1_SYS = 0x8010_3000

PA_DDR_BUF = 0x8030_0000
PA_BRAM_BUF = 0x0002_0000
PA_MMIO = 0x4000_0200
PA_APLIC = 0x4400_1000
PA_IMSIC = 0x4800_1000
PA_DEVICE_HOLE = 0x4003_1000
PA_UNMAPPED_LOW = 0x2000_0000
PA_UNMAPPED_HIGH = 0xC000_0000

# Sv39 virtual addresses in L0_PT (VPN[2]=0, VPN[1]=1, index 0x100 + slot).
VA_RW_DDR = 0x0030_0000  # slot 256: R=1, W=1, D=1
VA_RO_CLEAN = 0x0030_1000  # slot 257: R=1, W=0, D=0 (Zicbom ok, cbo.zero faults 15)
VA_EXEC_ONLY = 0x0030_2000  # slot 258: X=1, R=0 (Zicbom needs MXR=1)
VA_USER_RWX = 0x0030_3000  # slot 259: U=1, R=1, W=1, X=1, D=1
VA_UNACCESSED = 0x0030_4000  # slot 260: A=0 (StorePageFault 15 on CMO)
VA_INVALID = 0x0030_5000  # slot 261: V=0 (StorePageFault 15 on CMO)
VA_MMIO_MAP = 0x0030_6000  # slot 262: MMIO page (Zicbom ok, cbo.zero faults 7)
VA_UNMAPPED_MAP = 0x0030_7000  # slot 263: unmapped PA (StoreAccessFault 7 on CMO)
VA_CLEAN_RW = 0x0030_8000  # slot 264: R=1, W=1, D=0 (Zicbom ok, cbo.zero faults 15)

# envcfg bits.
ENVCFG_FIOM = 1 << 0
ENVCFG_CBIE_FLUSH = 1 << 4
ENVCFG_CBIE_RESV = 2 << 4
ENVCFG_CBIE_INVAL = 3 << 4
ENVCFG_CBCFE = 1 << 6
ENVCFG_CBZE = 1 << 7

MSTATUS_TW = 1 << 21

CSRS = dict(MMU_CSRS) | {"menvcfg": 0x30A, "senvcfg": 0x10A}

CBO_OPS = {
    "cbo.inval": 0x000,
    "cbo.clean": 0x001,
    "cbo.flush": 0x002,
    "cbo.zero": 0x004,
}
PREFETCH_OPS = {"prefetch.i": 0, "prefetch.r": 1, "prefetch.w": 3}

WFI = Instruction(0x10500073, "wfi")
FENCE_I = Instruction(0x0000100F, "fence.i")
WRS_NTO = Instruction(0x00D00073, "wrs.nto")
WRS_STO = Instruction(0x01D00073, "wrs.sto")
C_EBREAK = Instruction(0x00009002, "c.ebreak")
C_UNIMP = Instruction(0x00000000, "c.unimp")

STRAND_KINDS = (
    "setup",
    "bare_cmo_device",
    "translated_cmo_retire",
    "translated_cmo_gate_trap",
    "translated_cmo_mem_trap",
    "bare_cmo_fault",
    "wrs_and_wfi",
    "illegal_insn_tval",
    "ebreak_tval",
    "bare_access_misalign",
)

MIN_FULL_SAMPLE = 6

ZAWRS_FAULT_KINDS = (
    "bare_cbo_fault",
    "wrs_tw0",
    "wrs_reservation",
    "wfi_tw1",
    "illegal_bits",
    "ebreak_tval",
    "bare_access_and_misalign",
)


def cbo(name: str, rs1: int) -> Instruction:
    """Encode a Zicbom or Zicboz instruction."""
    return Instruction(
        (CBO_OPS[name] << 20) | (rs1 << 15) | (0x2 << 12) | 0x0F,
        f"{name} 0(x{rs1})",
    )


def prefetch(name: str, rs1: int, offset: int = 0) -> Instruction:
    """Encode a Zicbop prefetch hint (offset must be a multiple of 32)."""
    assert (offset & 0x1F) == 0 and -2048 <= offset < 2048
    imm = (offset & 0xFE0) | PREFETCH_OPS[name]
    return Instruction(_i_type(0x13, 0b110, 0, rs1, imm), f"{name} {offset}(x{rs1})")


def csrr_ext(rd: int, name: str) -> Instruction:
    """Encode CSRRS rd, csr, x0 including envcfg CSRs."""
    return Instruction(_i_type(0x73, 2, rd, 0, CSRS[name]), f"csrr x{rd}, {name}")


def csrw_ext(name: str, rs1: int) -> Instruction:
    """Encode CSRRW x0, csr, rs1 including envcfg CSRs."""
    return Instruction(_i_type(0x73, 1, 0, rs1, CSRS[name]), f"csrw {name}, x{rs1}")


def lr_d(rd: int, rs1: int) -> Instruction:
    """Encode LR.D rd, (rs1)."""
    return Instruction(_r_type(0x2F, 3, 0x02 << 2, rd, rs1, 0), f"lr.d x{rd}, (x{rs1})")


def sc_d(rd: int, rs2: int, rs1: int) -> Instruction:
    """Encode SC.D rd, rs2, (rs1)."""
    return Instruction(
        _r_type(0x2F, 3, 0x03 << 2, rd, rs1, rs2), f"sc.d x{rd}, x{rs2}, (x{rs1})"
    )


def raw_illegal_32(word: int) -> Instruction:
    """Wrap an illegal 32-bit encoding for Sstvala checks."""
    assert (word & 0x3) == 0x3
    return Instruction(word, f".insn {word:#010x}")


@dataclass(frozen=True)
class EnvCfgState:
    """Decoded enable fields of menvcfg or senvcfg."""

    cbie: int  # 0, 1, or 3 after WARL legalization of 2 -> 0
    cbcfe: bool
    cbze: bool
    fiom: bool

    def encode(self, write_reserved_cbie: bool = False) -> int:
        """Pack the enable state into a raw menvcfg or senvcfg CSR word."""
        raw_cbie = 2 if write_reserved_cbie else self.cbie
        return (
            (ENVCFG_FIOM if self.fiom else 0)
            | (raw_cbie << 4)
            | (ENVCFG_CBCFE if self.cbcfe else 0)
            | (ENVCFG_CBZE if self.cbze else 0)
        )


class Generator:
    """Generate reproducible CMO, prefetch, Zawrs, device, and Sstvala tests."""

    def __init__(self, rng: random.Random) -> None:
        """Initialize the generator with a random source."""
        self.rng = rng
        self.asid = 5
        self._translated_deck: list[str] = []
        self._fault_deck: list[str] = []

    def _draw(self, deck: list[Any], items: Sequence[Any]) -> Any:
        if not deck:
            deck.extend(items)
            self.rng.shuffle(deck)
        return deck.pop()

    def _res(self) -> int:
        return self.rng.choice(RESULTS)

    def _write_pte(self, table_pa: int, index: int, pte: int) -> list[Instruction]:
        addr = table_pa + 8 * index
        base = addr & ~0x7FF
        off = addr - base
        return (
            load_u64(TMP_A, base)
            + load_u64(TMP_B, pte)
            + [store("sd", TMP_B, TMP_A, off)]
        )

    def _read_trap_csrs(self, to_s: bool) -> list[Instruction]:
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
        assert (medeleg_mask & (1 << 9)) == 0
        mpp = MSTATUS_MPP_S if priv == "S" else 0
        return (
            load_u64(TMP_A, satp_val)
            + [csrw("satp", TMP_A)]
            + load_u64(TMP_A, medeleg_mask)
            + [csrw("medeleg", TMP_A)]
            + load_u64(TMP_A, mpp | mstatus_extra)
            + [csrw("mstatus", TMP_A)]
            + load_u64(TMP_A, entry_va)
            + [csrw("mepc", TMP_A), MRET]
        )

    def _return_from_s_to_m(self) -> list[Instruction]:
        return [ECALL] + self._read_trap_csrs(to_s=False)

    def _random_envcfg(self) -> tuple[EnvCfgState, int]:
        rng = self.rng
        raw_cbie = rng.choice((0, 1, 2, 3))
        legal_cbie = 0 if raw_cbie == 2 else raw_cbie
        state = EnvCfgState(
            cbie=legal_cbie,
            cbcfe=rng.random() < 0.65,
            cbze=rng.random() < 0.5,
            fiom=rng.random() < 0.5,
        )
        return state, state.encode(write_reserved_cbie=(raw_cbie == 2))

    def _setup_strand(self) -> Strand:
        """Build an Sv39 hierarchy for translated CMO and fault checks."""
        rng = self.rng
        self.asid = rng.randrange(1, 0x200)
        insns: list[Instruction] = []
        insns += load_u64(TMP_A, MTVEC_BASE) + [csrw("mtvec", TMP_A)]
        insns += load_u64(TMP_A, STVEC_BASE) + [csrw("stvec", TMP_A)]

        rwx_g = PTE_V | PTE_R | PTE_W | PTE_X | PTE_G | PTE_A | PTE_D
        rw = PTE_V | PTE_R | PTE_W | PTE_A | PTE_D
        insns += self._write_pte(L1_SYS, 0, make_pte(0x8000_0000, rwx_g))
        insns += self._write_pte(ROOT_PT, 2, make_pte(L1_SYS, PTE_V))
        insns += self._write_pte(ROOT_PT, 0, make_pte(L1_PT, PTE_V))
        insns += self._write_pte(L1_PT, 1, make_pte(L0_PT, PTE_V))

        entries = [
            (0x100, make_pte(PA_DDR_BUF, rw)),
            (0x101, make_pte(PA_DDR_BUF + 0x1000, PTE_V | PTE_R | PTE_A)),
            (0x102, make_pte(PA_DDR_BUF + 0x2000, PTE_V | PTE_X | PTE_A | PTE_D)),
            (
                0x103,
                make_pte(
                    PA_DDR_BUF + 0x3000,
                    PTE_V | PTE_R | PTE_W | PTE_X | PTE_U | PTE_A | PTE_D,
                ),
            ),
            (0x104, make_pte(PA_DDR_BUF + 0x4000, PTE_V | PTE_R | PTE_W | PTE_D)),
            # 0x105 stays zero (V=0).
            (0x106, make_pte(PA_MMIO + 0x1000, rw)),
            (0x107, make_pte(PA_UNMAPPED_LOW, rw)),
            (0x108, make_pte(PA_DDR_BUF + 0x5000, PTE_V | PTE_R | PTE_W | PTE_A)),
        ]
        for slot, pte in entries:
            insns += self._write_pte(L0_PT, slot, pte)
        insns.append(sfence_vma(0, 0))
        return Strand(
            True,
            insns,
            StrandCheck(kind="setup", priv=PRIV_M, target_index=len(insns) - 1),
        )

    def _bare_cmo_and_device_strand(self) -> Strand:
        """Interleave Bare stores, Zicbom, Zicbop, device RAM accesses, and WFI."""
        rng = self.rng
        insns: list[Instruction] = [alu_imm("addi", TMP_A, 0, 0), csrw("satp", TMP_A)]
        extra_retire: list[int] = []

        # Exercise menvcfg/senvcfg WARL legalization (including CBIE=10 -> 00).
        _, raw_m = self._random_envcfg()
        _, raw_s = self._random_envcfg()
        insns += load_u64(TMP_A, raw_m) + [
            csrw_ext("menvcfg", TMP_A),
            csrr_ext(self._res(), "menvcfg"),
        ]
        insns += load_u64(TMP_A, raw_s) + [
            csrw_ext("senvcfg", TMP_A),
            csrr_ext(self._res(), "senvcfg"),
        ]

        # Cached DDR and low BRAM: store -> unaligned Zicbom -> Zicbop -> load,
        # including back-to-back Zicbom ops on the same 64-byte block.
        for region_pa, cached in (
            (PA_DDR_BUF + 64 * rng.randrange(8), True),
            (PA_BRAM_BUF + 64 * rng.randrange(8), False),
        ):
            unaligned = region_pa + rng.randrange(1, 64)
            insns += load_u64(TMP_A, region_pa)
            insns += load_u64(TMP_B, rng.getrandbits(64))
            insns.append(store("sd", TMP_B, TMP_A, 8 * rng.randrange(8)))
            insns += load_u64(TMP_A, unaligned)
            ops = rng.sample(("cbo.clean", "cbo.flush", "cbo.inval"), 2)
            if cached and ops[0] == "cbo.inval":
                ops.insert(0, "cbo.clean")
            for op in ops:
                extra_retire.append(len(insns))
                insns.append(cbo(op, TMP_A))
            pref_off = 32 * rng.randrange(-8, 9)
            extra_retire.append(len(insns))
            insns.append(prefetch(rng.choice(list(PREFETCH_OPS)), TMP_A, pref_off))
            insns += load_u64(TMP_A, region_pa)
            insns.append(load("ld", self._res(), TMP_A, 8 * rng.randrange(8)))

        # Interleave mapped device accesses with cached DDR stores, Zicbom, FENCE and WFI.
        dev_pa = rng.choice((PA_MMIO, PA_APLIC, PA_IMSIC)) + 8 * rng.randrange(16)
        insns += load_u64(TMP_A, PA_DDR_BUF + 0x200)
        insns += load_u64(TMP_B, 0xCAFE_BABE_0000_0000 | rng.randrange(1 << 16))
        insns.append(store("sd", TMP_B, TMP_A, 0))
        insns += load_u64(TMP_A, dev_pa)
        insns.append(store("sd", TMP_B, TMP_A, 0))
        extra_retire.append(len(insns))
        insns.append(cbo(rng.choice(("cbo.clean", "cbo.flush", "cbo.inval")), TMP_A))
        extra_retire.append(len(insns))
        insns.append(load("ld", self._res(), TMP_A, 0))
        wfi_idx = len(insns) + 1
        extra_retire.extend((wfi_idx, wfi_idx + 1))
        insns += [FENCE, WFI, WRS_STO, WRS_NTO]
        nto_idx = len(insns) - 1
        if rng.random() < 0.25:
            insns.append(FENCE_I)

        return Strand(
            True,
            insns,
            StrandCheck(
                kind="bare_cmo_device",
                priv=PRIV_M,
                target_index=nto_idx,
                extra_retire_indices=tuple(extra_retire),
            ),
        )

    def _translated_cmo_strand(self) -> Strand:
        """Exercise Zicbom, Zicboz gates/faults, and Zicbop in S and U under Sv39."""
        rng = self.rng
        goal = self._draw(
            self._translated_deck, ("retire", "gate_trap", "mem_trap", "random")
        )
        m_cfg, raw_m = self._random_envcfg()
        s_cfg, raw_s = self._random_envcfg()
        priv = "U" if rng.random() < 0.35 else "S"
        priv_code = PRIV_U if priv == "U" else PRIV_S
        delegate = rng.random() < 0.5
        medeleg = 0xB1FF if delegate else 0
        handler_priv = PRIV_S if delegate else PRIV_M
        sum_bit = MSTATUS_SUM if (priv == "S" and rng.random() < 0.5) else 0
        mxr_bit = MSTATUS_MXR if rng.random() < 0.5 else 0

        if goal == "retire":
            op = rng.choice(("cbo.clean", "cbo.flush", "cbo.inval"))
            if op == "cbo.inval":
                m_cfg = EnvCfgState(
                    cbie=rng.choice((1, 3)),
                    cbcfe=m_cfg.cbcfe,
                    cbze=m_cfg.cbze,
                    fiom=m_cfg.fiom,
                )
                s_cfg = EnvCfgState(
                    cbie=rng.choice((1, 3)),
                    cbcfe=s_cfg.cbcfe,
                    cbze=s_cfg.cbze,
                    fiom=s_cfg.fiom,
                )
            else:
                m_cfg = EnvCfgState(
                    cbie=m_cfg.cbie, cbcfe=True, cbze=m_cfg.cbze, fiom=m_cfg.fiom
                )
                s_cfg = EnvCfgState(
                    cbie=s_cfg.cbie, cbcfe=True, cbze=s_cfg.cbze, fiom=s_cfg.fiom
                )
            raw_m = m_cfg.encode()
            raw_s = s_cfg.encode()
        elif goal == "gate_trap":
            op = rng.choice(("cbo.clean", "cbo.flush", "cbo.inval", "cbo.zero"))
            disable_m = priv == "S" or rng.random() < 0.5
            if op == "cbo.zero":
                if disable_m:
                    m_cfg = EnvCfgState(m_cfg.cbie, m_cfg.cbcfe, False, m_cfg.fiom)
                    raw_m = m_cfg.encode()
                else:
                    s_cfg = EnvCfgState(s_cfg.cbie, s_cfg.cbcfe, False, s_cfg.fiom)
                    raw_s = s_cfg.encode()
            elif op == "cbo.inval":
                use_resv = rng.random() < 0.5
                if disable_m:
                    m_cfg = EnvCfgState(0, m_cfg.cbcfe, m_cfg.cbze, m_cfg.fiom)
                    raw_m = m_cfg.encode(write_reserved_cbie=use_resv)
                else:
                    s_cfg = EnvCfgState(0, s_cfg.cbcfe, s_cfg.cbze, s_cfg.fiom)
                    raw_s = s_cfg.encode(write_reserved_cbie=use_resv)
            else:
                if disable_m:
                    m_cfg = EnvCfgState(m_cfg.cbie, False, m_cfg.cbze, m_cfg.fiom)
                    raw_m = m_cfg.encode()
                else:
                    s_cfg = EnvCfgState(s_cfg.cbie, False, s_cfg.cbze, s_cfg.fiom)
                    raw_s = s_cfg.encode()
        elif goal == "mem_trap":
            op = rng.choice(("cbo.clean", "cbo.flush", "cbo.inval", "cbo.zero"))
            m_cfg = EnvCfgState(rng.choice((1, 3)), True, True, m_cfg.fiom)
            s_cfg = EnvCfgState(rng.choice((1, 3)), True, True, s_cfg.fiom)
            raw_m = m_cfg.encode()
            raw_s = s_cfg.encode()
        else:
            op = rng.choice(("cbo.clean", "cbo.flush", "cbo.inval", "cbo.zero"))

        insns: list[Instruction] = []
        insns += load_u64(TMP_A, raw_m) + [csrw_ext("menvcfg", TMP_A)]
        insns += load_u64(TMP_A, raw_s) + [csrw_ext("senvcfg", TMP_A)]

        satp_val = make_satp(self.asid, ROOT_PT)
        entry_va = VA_USER_RWX if priv == "U" else CODE_ENTRY
        insns += self._enter_mode(
            priv,
            entry_va,
            satp_val,
            mstatus_extra=sum_bit | mxr_bit,
            medeleg_mask=medeleg,
        )

        # Pick target VA; for cbo.zero, pick only targets where cbo.zero traps
        # (either gated by CBZE=0 or faulting on permissions / PMA) so Sail 0.16
        # never hits its 16-byte rvfi_write assertion.
        if op == "cbo.zero":
            gate_ok = m_cfg.cbze and (s_cfg.cbze if priv == "U" else True)
            if not gate_ok:
                base_va = rng.choice((VA_USER_RWX, VA_RW_DDR, VA_INVALID, VA_RO_CLEAN))
            elif priv == "U":
                base_va = rng.choice(
                    (VA_RW_DDR, VA_RO_CLEAN, VA_CLEAN_RW, VA_INVALID, VA_MMIO_MAP)
                )
            else:
                choices = [
                    VA_RO_CLEAN,
                    VA_CLEAN_RW,
                    VA_UNACCESSED,
                    VA_INVALID,
                    VA_MMIO_MAP,
                    VA_UNMAPPED_MAP,
                ]
                if not sum_bit:
                    choices.append(VA_USER_RWX)
                base_va = rng.choice(choices)
            will_trap = True
        else:
            if op == "cbo.inval":
                gate_ok = (m_cfg.cbie != 0) and (
                    s_cfg.cbie != 0 if priv == "U" else True
                )
            else:
                gate_ok = m_cfg.cbcfe and (s_cfg.cbcfe if priv == "U" else True)

            if goal == "retire":
                if priv == "U":
                    base_va = VA_USER_RWX
                else:
                    valid_choices = [VA_RW_DDR, VA_RO_CLEAN, VA_CLEAN_RW, VA_MMIO_MAP]
                    if mxr_bit:
                        valid_choices.append(VA_EXEC_ONLY)
                    if sum_bit:
                        valid_choices.append(VA_USER_RWX)
                    base_va = rng.choice(valid_choices)
            elif goal == "mem_trap":
                if priv == "U":
                    base_va = rng.choice(
                        (
                            VA_RW_DDR,
                            VA_RO_CLEAN,
                            VA_EXEC_ONLY,
                            VA_UNACCESSED,
                            VA_INVALID,
                            VA_UNMAPPED_MAP,
                        )
                    )
                else:
                    fault_choices = [VA_UNACCESSED, VA_INVALID, VA_UNMAPPED_MAP]
                    if not mxr_bit:
                        fault_choices.append(VA_EXEC_ONLY)
                    if not sum_bit:
                        fault_choices.append(VA_USER_RWX)
                    base_va = rng.choice(fault_choices)
            else:
                base_va = rng.choice(
                    (
                        VA_RW_DDR,
                        VA_RO_CLEAN,
                        VA_CLEAN_RW,
                        VA_EXEC_ONLY,
                        VA_USER_RWX,
                        VA_UNACCESSED,
                        VA_INVALID,
                        VA_MMIO_MAP,
                        VA_UNMAPPED_MAP,
                    )
                )

            if not gate_ok:
                will_trap = True
            elif priv == "U":
                will_trap = base_va != VA_USER_RWX
            else:
                if base_va in (VA_RW_DDR, VA_RO_CLEAN, VA_CLEAN_RW, VA_MMIO_MAP):
                    will_trap = False
                elif base_va == VA_EXEC_ONLY:
                    will_trap = not bool(mxr_bit)
                elif base_va == VA_USER_RWX:
                    will_trap = not bool(sum_bit)
                else:
                    will_trap = True

        # Unaligned byte offset inside the 64-byte block tests that xtval = rs1.
        target_va = base_va + rng.randrange(1, 64)
        insns += load_u64(TMP_A, target_va)
        # Prefetch hints never trap, even on V=0, A=0, or unmapped pages.
        prefetch_idx = len(insns)
        insns.append(
            prefetch(rng.choice(list(PREFETCH_OPS)), TMP_A, 32 * rng.randrange(-4, 5))
        )
        cbo_inst = cbo(op, TMP_A)
        cbo_idx = len(insns)
        insns.append(cbo_inst)

        if will_trap:
            tval_idx = len(insns)
            cause_idx = len(insns) + 2
            insns += self._read_trap_csrs(to_s=delegate)
            if delegate:
                insns += self._return_from_s_to_m()
            if not gate_ok:
                strand_kind = "translated_cmo_gate_trap"
                expected_cause = 2
                expected_tval = cbo_inst.word
            else:
                strand_kind = "translated_cmo_mem_trap"
                if priv == "S" and (
                    base_va == VA_UNMAPPED_MAP
                    or (op == "cbo.zero" and base_va == VA_MMIO_MAP)
                ):
                    expected_cause = 7
                else:
                    expected_cause = 15
                expected_tval = target_va
            check = StrandCheck(
                kind=strand_kind,
                priv=priv_code,
                target_index=cbo_idx,
                will_trap=True,
                expected_cause=expected_cause,
                cause_index=cause_idx,
                tval_index=tval_idx,
                expected_tval=expected_tval,
                handler_priv=handler_priv,
                extra_retire_indices=(prefetch_idx,),
            )
        else:
            # No trap: return cleanly from S or U back to M-mode.
            if priv == "U":
                insns.append(ECALL)
                insns += self._read_trap_csrs(to_s=delegate)
                if delegate:
                    insns += self._return_from_s_to_m()
            else:
                insns += self._return_from_s_to_m()
            check = StrandCheck(
                kind="translated_cmo_retire",
                priv=priv_code,
                target_index=cbo_idx,
                extra_retire_indices=(prefetch_idx,),
            )

        return Strand(True, insns, check)

    def _zawrs_and_sstvala_fault_strand(self) -> Strand:
        """Check Zawrs, WFI under TW, and Sstvala values on Bare/illegal faults."""
        rng = self.rng
        kind = self._draw(self._fault_deck, ZAWRS_FAULT_KINDS)
        delegate = rng.random() < 0.5
        medeleg = 0xB1FF if delegate else 0
        handler_priv = PRIV_S if delegate else PRIV_M

        if kind == "bare_cbo_fault":
            # M-mode Bare CMO fault on unmapped PA or cbo.zero on MMIO/quadrant:
            # StoreAccessFault (7) with full unaligned PA in mtval.
            op = rng.choice(("cbo.clean", "cbo.flush", "cbo.inval", "cbo.zero"))
            if op == "cbo.zero":
                pa = rng.choice(
                    (PA_MMIO, PA_APLIC, PA_IMSIC, PA_DEVICE_HOLE, PA_UNMAPPED_LOW)
                )
            else:
                pa = rng.choice((PA_DEVICE_HOLE, PA_UNMAPPED_LOW, PA_UNMAPPED_HIGH))
            pa += rng.randrange(1, 64)
            insns = [alu_imm("addi", TMP_A, 0, 0), csrw("satp", TMP_A)]
            insns += load_u64(TMP_A, pa)
            cbo_idx = len(insns)
            insns.append(cbo(op, TMP_A))
            tval_idx = len(insns)
            cause_idx = len(insns) + 2
            insns += self._read_trap_csrs(to_s=False)
            return Strand(
                True,
                insns,
                StrandCheck(
                    kind="bare_cmo_fault",
                    priv=PRIV_M,
                    target_index=cbo_idx,
                    will_trap=True,
                    expected_cause=7,
                    cause_index=cause_idx,
                    tval_index=tval_idx,
                    expected_tval=pa,
                    handler_priv=PRIV_M,
                ),
            )

        if kind == "wrs_tw0":
            priv = "U" if rng.random() < 0.4 else "S"
            entry = VA_USER_RWX if priv == "U" else CODE_ENTRY
            insns = self._enter_mode(
                priv, entry, make_satp(self.asid, ROOT_PT), medeleg_mask=medeleg
            )
            sto_idx = len(insns)
            if priv == "S":
                # In S-mode with TW=0, wrs.sto, wrs.nto, and wfi all retire;
                # ecall returns to M-mode because medeleg bit 9 is clear.
                insns += [WRS_STO, WRS_NTO, WFI]
                wfi_idx = len(insns) - 1
                insns += self._return_from_s_to_m()
                return Strand(
                    True,
                    insns,
                    StrandCheck(
                        kind="wrs_and_wfi",
                        priv=PRIV_S,
                        target_index=wfi_idx,
                        extra_retire_indices=(sto_idx, sto_idx + 1),
                    ),
                )
            # In U-mode with TW=0, wrs.sto and wrs.nto retire, while wfi
            # traps with illegal instruction.
            insns += [WRS_STO, WRS_NTO, WFI]
            wfi_idx = len(insns) - 1
            tval_idx = len(insns)
            cause_idx = len(insns) + 2
            insns += self._read_trap_csrs(to_s=delegate)
            if delegate:
                insns += self._return_from_s_to_m()
            return Strand(
                True,
                insns,
                StrandCheck(
                    kind="wrs_and_wfi",
                    priv=PRIV_U,
                    target_index=wfi_idx,
                    will_trap=True,
                    expected_cause=2,
                    cause_index=cause_idx,
                    tval_index=tval_idx,
                    expected_tval=WFI.word,
                    handler_priv=handler_priv,
                    extra_retire_indices=(sto_idx, sto_idx + 1),
                ),
            )

        if kind == "wrs_reservation":
            # Set an LR reservation on cached DDR, execute wrs.sto and wrs.nto
            # inside the window, and verify the following SC succeeds.
            if rng.random() < 0.5:
                insns = [alu_imm("addi", TMP_A, 0, 0), csrw("satp", TMP_A)]
                insns += load_u64(TMP_A, MSTATUS_TW) + [csrw("mstatus", TMP_A)]
                insns += load_u64(TMP_A, PA_DDR_BUF + 0x40)
                lr_idx = len(insns)
                insns += [
                    lr_d(self._res(), TMP_A),
                    WRS_STO,
                    WRS_NTO,
                    sc_d(self._res(), TMP_A, TMP_A),
                    alu_imm("addi", TMP_A, 0, 0),
                    csrw("mstatus", TMP_A),
                ]
                sc_idx = lr_idx + 3
                priv_code = PRIV_M
            else:
                insns = self._enter_mode(
                    "S",
                    CODE_ENTRY,
                    make_satp(self.asid, ROOT_PT),
                    medeleg_mask=medeleg,
                )
                insns += load_u64(TMP_A, VA_RW_DDR + 0x40)
                lr_idx = len(insns)
                insns += [
                    lr_d(self._res(), TMP_A),
                    WRS_STO,
                    WRS_NTO,
                    sc_d(self._res(), TMP_A, TMP_A),
                ]
                sc_idx = lr_idx + 3
                insns += self._return_from_s_to_m()
                priv_code = PRIV_S
            return Strand(
                True,
                insns,
                StrandCheck(
                    kind="wrs_and_wfi",
                    priv=priv_code,
                    target_index=sc_idx,
                    extra_retire_indices=(lr_idx, lr_idx + 1, lr_idx + 2),
                    expected_rd_zero_index=sc_idx,
                ),
            )

        if kind == "wfi_tw1":
            priv = "U" if rng.random() < 0.6 else "S"
            entry = VA_USER_RWX if priv == "U" else CODE_ENTRY
            insns = self._enter_mode(
                priv,
                entry,
                make_satp(self.asid, ROOT_PT),
                mstatus_extra=MSTATUS_TW,
                medeleg_mask=medeleg,
            )
            sto_idx = len(insns)
            if priv == "S":
                # wrs.sto never traps on mstatus.TW, even in S-mode with TW=1;
                # S-mode WFI with TW=1 is omitted because wfi_is_nop skips TW
                # in Sail.
                insns += [WRS_STO]
                insns += self._return_from_s_to_m()
                check = StrandCheck(
                    kind="wrs_and_wfi",
                    priv=PRIV_S,
                    target_index=sto_idx,
                )
            else:
                # U-mode WFI traps even with wfi_is_nop = true; wrs.sto retires.
                insns += [WRS_STO, WFI]
                wfi_idx = len(insns) - 1
                tval_idx = len(insns)
                cause_idx = len(insns) + 2
                insns += self._read_trap_csrs(to_s=delegate)
                if delegate:
                    insns += self._return_from_s_to_m()
                check = StrandCheck(
                    kind="wrs_and_wfi",
                    priv=PRIV_U,
                    target_index=wfi_idx,
                    will_trap=True,
                    expected_cause=2,
                    cause_index=cause_idx,
                    tval_index=tval_idx,
                    expected_tval=WFI.word,
                    handler_priv=handler_priv,
                    extra_retire_indices=(sto_idx,),
                )
            insns += [alu_imm("addi", TMP_A, 0, 0), csrw("mstatus", TMP_A)]
            return Strand(True, insns, check)

        if kind == "illegal_bits":
            # Sstvala: illegal 32-bit and 16-bit encodings write instruction bits
            # to mtval/stval (zero-extended for 16-bit parcels).
            bad = rng.choice(
                (
                    raw_illegal_32(0x0034A00F),  # unassigned CBO funct12=0x003
                    raw_illegal_32(0x0054A00F),  # unassigned CBO funct12=0x005
                    raw_illegal_32(0xFFFFFFFF),
                    C_UNIMP,
                )
            )
            insns = self._enter_mode(
                "S", CODE_ENTRY, make_satp(self.asid, ROOT_PT), medeleg_mask=medeleg
            )
            bad_idx = len(insns)
            insns.append(bad)
            tval_idx = len(insns)
            cause_idx = len(insns) + 2
            insns += self._read_trap_csrs(to_s=delegate)
            if delegate:
                insns += self._return_from_s_to_m()
            return Strand(
                True,
                insns,
                StrandCheck(
                    kind="illegal_insn_tval",
                    priv=PRIV_S,
                    target_index=bad_idx,
                    will_trap=True,
                    expected_cause=2,
                    cause_index=cause_idx,
                    tval_index=tval_idx,
                    expected_tval=bad.word,
                    handler_priv=handler_priv,
                ),
            )

        if kind == "ebreak_tval":
            insns = self._enter_mode(
                "S", CODE_ENTRY, make_satp(self.asid, ROOT_PT), medeleg_mask=medeleg
            )
            ebreak_idx = len(insns)
            insns.append(EBREAK if rng.random() < 0.5 else C_EBREAK)
            tval_idx = len(insns)
            cause_idx = len(insns) + 2
            insns += self._read_trap_csrs(to_s=delegate)
            if delegate:
                insns += self._return_from_s_to_m()
            return Strand(
                True,
                insns,
                StrandCheck(
                    kind="ebreak_tval",
                    priv=PRIV_S,
                    target_index=ebreak_idx,
                    will_trap=True,
                    expected_cause=3,
                    cause_index=cause_idx,
                    tval_index=tval_idx,
                    handler_priv=handler_priv,
                ),
            )

        # Bare misaligned vs unmapped access fault priority and mtval checks.
        insns = [alu_imm("addi", TMP_A, 0, 0), csrw("satp", TMP_A)]
        addr = rng.choice(
            (
                PA_BRAM_BUF + 3,  # low BRAM misaligned -> 4/6
                PA_MMIO + 5,  # device misaligned -> 4/6
                PA_UNMAPPED_LOW + 3,  # unmapped misaligned -> access fault 5/7 first
                PA_DEVICE_HOLE + 8,  # unmapped device page -> access fault 5/7
            )
        )
        insns += load_u64(TMP_A, addr)
        is_load = rng.random() < 0.5
        mem_idx = len(insns)
        if is_load:
            insns.append(load("ld", self._res(), TMP_A, 0))
        else:
            insns.append(store("sd", TMP_A, TMP_A, 0))
        if addr in (PA_UNMAPPED_LOW + 3, PA_DEVICE_HOLE + 8):
            expected_cause = 5 if is_load else 7
        else:
            expected_cause = 4 if is_load else 6
        tval_idx = len(insns)
        cause_idx = len(insns) + 2
        insns += self._read_trap_csrs(to_s=False)
        return Strand(
            True,
            insns,
            StrandCheck(
                kind="bare_access_misalign",
                priv=PRIV_M,
                target_index=mem_idx,
                will_trap=True,
                expected_cause=expected_cause,
                cause_index=cause_idx,
                tval_index=tval_idx,
                expected_tval=addr,
                handler_priv=PRIV_M,
            ),
        )

    def test(self, length: int) -> list[Strand]:
        """Generate one CMO/prefetch/Sstvala test of at least `length` instructions."""
        rng = self.rng
        strands = [
            self._setup_strand(),
            self._bare_cmo_and_device_strand(),
            self._translated_cmo_strand(),
            self._translated_cmo_strand(),
            self._zawrs_and_sstvala_fault_strand(),
            self._zawrs_and_sstvala_fault_strand(),
        ]
        count = sum(len(s.instructions) for s in strands)
        while count < length:
            roll = rng.random()
            if roll < 0.30:
                strand = self._bare_cmo_and_device_strand()
            elif roll < 0.70:
                strand = self._translated_cmo_strand()
            else:
                strand = self._zawrs_and_sstvala_fault_strand()
            strands.append(strand)
            count += len(strand.instructions)
        return strands


def write_tests_with_strands(
    directory: Path,
    count: int,
    seed: int,
    length: int = 300,
) -> tuple[list[Path], list[list[Strand]]]:
    """Write `count` CMO tests into `directory` and return paths and strands."""
    rng = random.Random(seed)
    generator = Generator(rng)
    directory.mkdir(parents=True, exist_ok=True)
    paths: list[Path] = []
    all_strands: list[list[Strand]] = []
    for index in range(count):
        header = [
            f"CMO and Sstvala test {index} from seed {seed} (verif/testrig/cmo.py)"
        ]
        path = directory / f"cmo_{seed}_{index:04d}.S"
        strands = generator.test(length)
        path.write_text(render(strands, header), encoding="utf-8")
        paths.append(path)
        all_strands.append(strands)
    return paths, all_strands


def write_tests(
    directory: Path,
    count: int,
    seed: int,
    length: int = 300,
) -> list[Path]:
    """Write `count` CMO tests from `seed` into `directory`; return their paths."""
    paths, _ = write_tests_with_strands(directory, count, seed, length)
    return paths
