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

"""Random Svinval (sinval.vma, sfence.w.inval, sfence.inval.ir) traces.

Each test builds a valid Sv39 hierarchy in DDR (with distinct S-mode, global,
U-mode, and remappable 4 KiB pages plus an S-mode gigapage over low BRAM trap
vectors) and then mixes:
  - all four (x0 / register) operand forms of sinval.vma under Bare and Sv39,
  - live PTE remaps bracketed by sfence.w.inval ... sinval.vma ... sfence.inval.ir,
  - M/S/U privilege and mstatus.TVM transitions, including U->S and U->M trap
    entries whose very first instruction at stvec/mtvec is sfence.w.inval or
    sfence.inval.ir,
  - back-to-back Zimop (mop.r.n / mop.rr.n) and sinval.vma pairs in each order,
  - reserved SYSTEM funct3=000 neighbours (rd/rs1 != 0, funct7=0001100 with
    rs2=2..31, and hypervisor fences hfence.vvma/gvma and hinval.vvma/gvma),
  - Sstc stimecmp register and immediate CSR accesses across (STCE, TM).
"""

import random
from pathlib import Path

CSR_SSTATUS = 0x100
CSR_STVEC = 0x105
CSR_SEPC = 0x141
CSR_SCAUSE = 0x142
CSR_STVAL = 0x143
CSR_STIMECMP = 0x14D
CSR_SATP = 0x180
CSR_MSTATUS = 0x300
CSR_MEDELEG = 0x302
CSR_MTVEC = 0x305
CSR_MCOUNTEREN = 0x306
CSR_MENVCFG = 0x30A
CSR_MEPC = 0x341
CSR_MCAUSE = 0x342
CSR_MTVAL = 0x343

ECALL = 0x00000073
MRET = 0x30200073
SFENCE_VMA_ALL = 0x12000073
SFENCE_W_INVAL = 0x18000073
SFENCE_INVAL_IR = 0x18100073

# Registers 1..15 hold fixed addresses, masks, and Sv39 satp values; x16..x31
# hold corner/random 64-bit values and receive architectural results.
WRITABLE = list(range(16, 32))


def _i(imm: int, rs1: int, funct3: int, rd: int, opcode: int) -> int:
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def _s(imm: int, rs2: int, rs1: int, funct3: int, opcode: int) -> int:
    imm &= 0xFFF
    return (
        ((imm >> 5) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (funct3 << 12)
        | ((imm & 0x1F) << 7)
        | opcode
    )


def _r(funct7: int, rs2: int, rs1: int, funct3: int, rd: int, opcode: int) -> int:
    return (
        (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode
    )


def sinval_vma(rs1: int, rs2: int, rd: int = 0) -> int:
    """Encode sinval.vma rs1, rs2 (or malformed rd != 0 when testing traps)."""
    return _r(0b0001011, rs2, rs1, 0, rd, 0x73)


def sfence_vma(rs1: int, rs2: int, rd: int = 0) -> int:
    """Encode sfence.vma rs1, rs2."""
    return _r(0b0001001, rs2, rs1, 0, rd, 0x73)


def mop_r(n: int, rd: int, rs1: int) -> int:
    """Encode Zimop mop.r.n rd, rs1."""
    funct12 = (
        (1 << 11)
        | (((n >> 4) & 1) << 10)
        | (((n >> 2) & 3) << 6)
        | (0b0111 << 2)
        | (n & 3)
    )
    return _i(funct12, rs1, 4, rd, 0x73)


def mop_rr(n: int, rd: int, rs1: int, rs2: int) -> int:
    """Encode Zimop mop.rr.n rd, rs1, rs2."""
    funct7 = (1 << 6) | (((n >> 2) & 1) << 5) | ((n & 3) << 1) | 1
    return _r(funct7, rs2, rs1, 4, rd, 0x73)


def _csrrw(rd: int, csr: int, rs1: int) -> int:
    return _i(csr, rs1, 0b001, rd, 0x73)


def _csrrs(rd: int, csr: int, rs1: int) -> int:
    return _i(csr, rs1, 0b010, rd, 0x73)


def _csrrc(rd: int, csr: int, rs1: int) -> int:
    return _i(csr, rs1, 0b011, rd, 0x73)


def _csrrwi(rd: int, csr: int, uimm: int) -> int:
    return _i(csr, uimm & 0x1F, 0b101, rd, 0x73)


def _csrrsi(rd: int, csr: int, uimm: int) -> int:
    return _i(csr, uimm & 0x1F, 0b110, rd, 0x73)


def _csrrci(rd: int, csr: int, uimm: int) -> int:
    return _i(csr, uimm & 0x1F, 0b111, rd, 0x73)


def _li64(rd: int, value: int) -> list[int]:
    """Build an exact 64-bit constant in rd using eight byte shifts."""
    value &= (1 << 64) - 1
    words = [_i((value >> 56) & 0xFF, 0, 0, rd, 0x13)]
    for shift in range(48, -1, -8):
        words.append(_i(8, rd, 1, rd, 0x13))
        words.append(_i((value >> shift) & 0xFF, rd, 0, rd, 0x13))
    return words


def _sd(rs2: int, base: int, offset: int) -> int:
    return _s(offset, rs2, base, 0b011, 0x23)


def _ld(rd: int, base: int, offset: int) -> int:
    return _i(offset, base, 0b011, rd, 0x03)


def _setup_lines(rng: random.Random) -> list[str]:
    """Emit the .noshrink setup building page tables, CSRs, and seed registers."""
    words: list[int] = []

    # Fixed control/address registers x1..x15:
    #   x1  = 0x100 (mtvec / S-mode mepc in low BRAM)
    #   x2  = 0x200 (stvec in low BRAM)
    #   x3  = 0x8002_0000 (U-mode 16 KiB code/data region, U=1 in Sv39)
    #   x4  = 0x1800 (mstatus.MPP mask)
    #   x5  = 0x0800 (mstatus.MPP = S)
    #   x6  = 0x0010_0000 (mstatus.TVM)
    #   x7  = 1 << 63 (menvcfg.STCE)
    #   x8  = 0x8000_0000 (S-mode R/W/X page l0[0])
    #   x9  = 0x8000_1000 (Global S-mode R/W/X page l0[1])
    #   x10 = 0x8000_3000 (Remappable S-mode R/W page l0[3])
    #   x11 = 0x8001_2000 (Level-0 page table VA/PA, mapped at l0[18])
    #   x12 = satp Sv39 ASID 1, root PPN 0x80010
    #   x13 = satp Sv39 ASID 2, root PPN 0x80010
    #   x14 = 1 (ASID 1), x15 = 2 (ASID 2)
    fixed = {
        1: 0x100,
        2: 0x200,
        3: 0x8002_0000,
        4: 0x1800,
        5: 0x0800,
        6: 1 << 20,
        7: 1 << 63,
        8: 0x8000_0000,
        9: 0x8000_1000,
        10: 0x8000_3000,
        11: 0x8001_2000,
        12: (8 << 60) | (1 << 44) | 0x80010,
        13: (8 << 60) | (2 << 44) | 0x80010,
        14: 1,
        15: 2,
    }
    for reg, val in fixed.items():
        words.extend(_li64(reg, val))

    # Build Sv39 tables at PA 0x8001_0000 (root), 0x8001_1000 (l1), 0x8001_2000 (l0)
    # using x16 (table base) and x17 (PTE / data scratch).
    words.extend(_li64(16, 0x8001_0000))
    words.extend(
        _li64(17, 0x0000_00CF)
    )  # root[0]: 1 GiB S-mode R/W/X A/D over low BRAM
    words.append(_sd(17, 16, 0))
    words.extend(_li64(17, (0x80011 << 10) | 0x01))  # root[2] -> l1
    words.append(_sd(17, 16, 16))

    words.extend(_li64(16, 0x8001_1000))
    words.extend(_li64(17, (0x80012 << 10) | 0x01))  # l1[0] -> l0
    words.append(_sd(17, 16, 0))

    ptes = [
        (0, (0x80000 << 10) | 0xCF),  # l0[0]: 0x8000_0000 S-mode R/W/X A/D
        (8, (0x80001 << 10) | 0xEF),  # l0[1]: 0x8000_1000 Global S-mode R/W/X G/A/D
        (24, (0x80003 << 10) | 0xC7),  # l0[3]: 0x8000_3000 S-mode R/W A/D
        (144, (0x80012 << 10) | 0xC7),  # l0[18]: 0x8001_2000 maps l0 table itself
    ] + [(8 * (32 + p), ((0x80020 + p) << 10) | 0xDF) for p in range(4)]
    for offset, pte in ptes:
        words.extend(_li64(17, pte))
        words.append(_sd(17, 11, offset))

    # Populate backing DDR pages with random 64-bit data.
    for pa in (0x8000_0000, 0x8000_1000, 0x8002_0000, 0x8000_3000, 0x8000_4000):
        words.extend(_li64(16, pa))
        words.extend(_li64(17, rng.getrandbits(64)))
        words.append(_sd(17, 16, 0))
        words.extend(_li64(17, rng.getrandbits(64)))
        words.append(_sd(17, 16, 8))

    # Initialize CSRs: mtvec=0x100, stvec=0x200, menvcfg=STCE, mcounteren=TM,
    # stimecmp=UINT64_MAX, satp=Sv39 ASID 1, and flush TLBs.
    words.append(_csrrw(0, CSR_MTVEC, 1))
    words.append(_csrrw(0, CSR_STVEC, 2))
    words.append(_csrrw(0, CSR_MENVCFG, 7))
    words.append(_csrrwi(0, CSR_MCOUNTEREN, 2))
    words.extend(_li64(17, (1 << 64) - 1))
    words.append(_csrrw(0, CSR_STIMECMP, 17))
    words.append(_csrrw(0, CSR_MEDELEG, 0))
    words.append(_csrrw(0, CSR_SATP, 12))
    words.append(SFENCE_VMA_ALL)

    # Seed x16..x31 with corner VAs, ASIDs (including upper bits above ASIDLEN=9),
    # non-canonical addresses, and random 64-bit values.
    corners = [
        0x1FF,
        (0x5A << 16) | 1,
        (0x7FFF << 48) | 0x8000_0000,
        0x0001_8000_0000_0000,
        (1 << 64) - 1,
        0xFFFF_FFC0_0000_0000,
        0x8000_3FF8,
        0,
    ]
    for idx, reg in enumerate(WRITABLE):
        val = corners[idx] if idx < len(corners) else rng.getrandbits(64)
        words.extend(_li64(reg, val))

    return [f".4byte {w:#010x}" for w in words]


def _bad_system_word(rng: random.Random) -> tuple[int, str]:
    """Pick a reserved or hypervisor SYSTEM funct3=000 encoding that must trap."""
    choice = rng.randrange(8)
    rs1 = rng.randrange(32)
    rs2 = rng.randrange(32)
    nz_reg = rng.randrange(1, 32)
    if choice == 0:
        return _r(0b0010001, rs2, rs1, 0, 0, 0x73), "hfence.vvma"
    if choice == 1:
        return _r(0b0110001, rs2, rs1, 0, 0, 0x73), "hfence.gvma"
    if choice == 2:
        return _r(0b0010011, rs2, rs1, 0, 0, 0x73), "hinval.vvma"
    if choice == 3:
        return _r(0b0110011, rs2, rs1, 0, 0, 0x73), "hinval.gvma"
    if choice == 4:
        bad_rs2 = rng.randrange(2, 32)
        return _r(0b0001100, bad_rs2, 0, 0, 0, 0x73), f"funct7=0x0c,rs2={bad_rs2}"
    if choice == 5:
        return sinval_vma(rs1, rs2, rd=nz_reg), "sinval.vma rd!=0"
    if choice == 6:
        if rng.randrange(2):
            return _r(0b0001100, 0, nz_reg, 0, 0, 0x73), "sfence.w.inval rs1!=0"
        return _r(0b0001100, 0, 0, 0, nz_reg, 0x73), "sfence.w.inval rd!=0"
    if rng.randrange(2):
        return _r(0b0001100, 1, nz_reg, 0, 0, 0x73), "sfence.inval.ir rs1!=0"
    return _r(0b0001100, 1, 0, 0, nz_reg, 0x73), "sfence.inval.ir rd!=0"


def _pick_sinval_operands(rng: random.Random) -> tuple[int, int]:
    """Choose one of the four (x0 / register) operand forms for sinval.vma."""
    form = rng.randrange(4)
    va_pool = [8, 9, 10] + WRITABLE
    asid_pool = [14, 15] + WRITABLE
    rs1 = 0 if form in (0, 2) else rng.choice(va_pool)
    rs2 = 0 if form in (0, 1) else rng.choice(asid_pool)
    return rs1, rs2


def write_tests(directory: Path, count: int, seed: int, length: int) -> list[Path]:
    """Write reproducible QuickCheckVEngine traces exercising Svinval."""
    rng = random.Random(seed)
    directory.mkdir(parents=True, exist_ok=True)
    paths: list[Path] = []

    for index in range(count):
        lines = [f"# Svinval test {index}, seed {seed}", ".noshrink"]
        lines.extend(_setup_lines(rng))
        lines.append(".shrink")

        priv = "M"
        tvm = 0
        deleg_illegal = 0
        satp_asid = 1  # 0 = Bare, 1 = ASID 1 (x12), 2 = ASID 2 (x13)
        stce = 1
        tm = 1
        alt_pa = False
        emitted = 0

        def emit(word: int, comment: str) -> None:
            nonlocal emitted
            lines.append(f".4byte {word:#010x} # {comment}")
            emitted += 1

        def take_illegal_trap() -> None:
            nonlocal priv
            if priv != "M" and deleg_illegal:
                priv = "S"
                emit(_csrrs(rng.choice(WRITABLE), CSR_SCAUSE, 0), "csrr scause")
                emit(_csrrs(rng.choice(WRITABLE), CSR_STVAL, 0), "csrr stval")
            else:
                priv = "M"
                emit(_csrrs(rng.choice(WRITABLE), CSR_MCAUSE, 0), "csrr mcause")
                emit(_csrrs(rng.choice(WRITABLE), CSR_MTVAL, 0), "csrr mtval")

        while emitted < length:
            kind = rng.randrange(10)

            # 0, 1: sinval.vma (all 4 operand forms) in current mode / TVM state.
            if kind in (0, 1):
                rs1, rs2 = _pick_sinval_operands(rng)
                emit(
                    sinval_vma(rs1, rs2),
                    f"sinval.vma x{rs1}, x{rs2} ({priv},tvm={tvm})",
                )
                if priv == "U" or (priv == "S" and tvm == 1):
                    take_illegal_trap()
                continue

            # 2: sfence.w.inval and/or sfence.inval.ir in current mode / TVM state.
            if kind == 2:
                word, name = (
                    (SFENCE_W_INVAL, "sfence.w.inval")
                    if rng.randrange(2) == 0
                    else (SFENCE_INVAL_IR, "sfence.inval.ir")
                )
                emit(word, f"{name} ({priv},tvm={tvm})")
                if priv == "U":
                    take_illegal_trap()
                continue

            # 3: Live PTE remap bracketed by sfence.w.inval ... sinval.vma ... sfence.inval.ir.
            if (
                kind == 3
                and satp_asid != 0
                and (priv == "M" or (priv == "S" and tvm == 0))
            ):
                alt_pa = not alt_pa
                pte_ppn = 0x80004 if alt_pa else 0x80003
                scratch = rng.choice(WRITABLE)
                for w in _li64(scratch, (pte_ppn << 10) | 0xC7):
                    emit(w, "li64 pte")
                emit(_sd(scratch, 11, 24), "sd new l0[3] pte")
                emit(SFENCE_W_INVAL, "sfence.w.inval")
                asid_reg = 14 if satp_asid == 1 else 15
                match_rs1 = rng.choice((0, 10))
                match_rs2 = rng.choice((0, asid_reg))
                emit(
                    sinval_vma(match_rs1, match_rs2),
                    f"sinval.vma x{match_rs1}, x{match_rs2} (remap)",
                )
                if rng.randrange(2):
                    extra_rs1, extra_rs2 = _pick_sinval_operands(rng)
                    emit(sinval_vma(extra_rs1, extra_rs2), "sinval.vma extra")
                emit(SFENCE_INVAL_IR, "sfence.inval.ir")
                if priv == "S":
                    emit(_ld(rng.choice(WRITABLE), 10, 0), "ld remapped VA 0x8000_3000")
                continue

            # 4: U->S or U->M trap entry landing directly on sfence.w.inval / sfence.inval.ir.
            if kind == 4:
                if priv != "M":
                    emit(ECALL, "ecall -> M")
                    priv = "M"
                to_s = rng.randrange(2) == 1
                scratch = rng.choice(WRITABLE)
                if to_s:
                    emit(_i(1 << 8, 0, 0, scratch, 0x13), "li medeleg ecall_u")
                    emit(_csrrw(0, CSR_MEDELEG, scratch), "csrw medeleg (ecall_u)")
                else:
                    emit(_csrrw(0, CSR_MEDELEG, 0), "csrw medeleg, 0")
                deleg_illegal = 0
                emit(_csrrc(0, CSR_MSTATUS, 4), "csrc mstatus, MPP")
                emit(_csrrw(0, CSR_MEPC, 3), "csrw mepc, u_va")
                emit(MRET, "mret -> U")
                emit(ECALL, "U ecall -> S/M")
                priv = "S" if to_s else "M"
                first_word, first_name = (
                    (SFENCE_W_INVAL, "sfence.w.inval")
                    if rng.randrange(2) == 0
                    else (SFENCE_INVAL_IR, "sfence.inval.ir")
                )
                emit(first_word, f"first insn after U->{priv} trap: {first_name}")
                continue

            # 5: Privilege / TVM / satp / delegation / Sstc mode switch via M-mode.
            if kind == 5:
                if priv != "M":
                    emit(ECALL, "ecall -> M")
                    priv = "M"
                tvm = rng.randrange(2)
                emit(
                    _csrrs(0, CSR_MSTATUS, 6) if tvm else _csrrc(0, CSR_MSTATUS, 6),
                    f"set TVM={tvm}",
                )
                satp_asid = rng.choice((0, 1, 2))
                satp_reg = 0 if satp_asid == 0 else (12 if satp_asid == 1 else 13)
                emit(_csrrw(0, CSR_SATP, satp_reg), f"csrw satp (asid={satp_asid})")
                deleg_illegal = rng.randrange(2)
                if deleg_illegal:
                    scratch = rng.choice(WRITABLE)
                    emit(_i(1 << 2, 0, 0, scratch, 0x13), "li medeleg illegal")
                    emit(_csrrw(0, CSR_MEDELEG, scratch), "csrw medeleg (illegal)")
                else:
                    emit(_csrrw(0, CSR_MEDELEG, 0), "csrw medeleg, 0")
                stce = rng.randrange(2)
                tm = rng.randrange(2)
                emit(_csrrw(0, CSR_MENVCFG, 7 if stce else 0), f"menvcfg STCE={stce}")
                emit(_csrrwi(0, CSR_MCOUNTEREN, 2 if tm else 0), f"mcounteren TM={tm}")
                target = rng.choice(("M", "S", "S", "U"))
                if target == "S":
                    emit(_csrrc(0, CSR_MSTATUS, 4), "csrc mstatus, MPP")
                    emit(_csrrs(0, CSR_MSTATUS, 5), "csrs mstatus, MPP_S")
                    emit(_csrrw(0, CSR_MEPC, 1), "csrw mepc, 0x100")
                    emit(MRET, "mret -> S")
                    priv = "S"
                elif target == "U":
                    emit(_csrrc(0, CSR_MSTATUS, 4), "csrc mstatus, MPP")
                    emit(_csrrw(0, CSR_MEPC, 3), "csrw mepc, u_va")
                    emit(MRET, "mret -> U")
                    priv = "U"
                continue

            # 6: Back-to-back Zimop (mop.r.n / mop.rr.n) and sinval.vma in each order.
            if kind == 6 and (priv == "M" or (priv == "S" and tvm == 0)):
                rd = rng.choice(WRITABLE)
                mop_word = (
                    mop_r(rng.randrange(32), rd, rng.randrange(32))
                    if rng.randrange(2) == 0
                    else mop_rr(
                        rng.randrange(8), rd, rng.randrange(32), rng.randrange(32)
                    )
                )
                rs1, rs2 = _pick_sinval_operands(rng)
                sinval_word = sinval_vma(rs1, rs2)
                if rng.randrange(2) == 0:
                    emit(mop_word, f"mop -> x{rd}")
                    emit(sinval_word, f"sinval.vma x{rs1}, x{rs2}")
                else:
                    emit(sinval_word, f"sinval.vma x{rs1}, x{rs2}")
                    emit(mop_word, f"mop -> x{rd}")
                continue

            # 7: Reserved / hypervisor SYSTEM funct3=000 encoding (must trap illegal).
            if kind == 7:
                bad_word, bad_name = _bad_system_word(rng)
                emit(bad_word, f"illegal {bad_name} ({priv})")
                take_illegal_trap()
                continue

            # 8: Sstc stimecmp access via register or immediate CSR form.
            if kind == 8:
                rd = rng.choice(WRITABLE)
                form = rng.randrange(5)
                if form == 0:
                    word, desc = _csrrs(rd, CSR_STIMECMP, 0), "csrr stimecmp"
                elif form == 1:
                    word, desc = _csrrsi(rd, CSR_STIMECMP, 0), "csrrsi stimecmp, 0"
                elif form == 2:
                    uimm = rng.randrange(32)
                    word, desc = (
                        _csrrwi(rd, CSR_STIMECMP, uimm),
                        f"csrrwi stimecmp, {uimm}",
                    )
                elif form == 3:
                    uimm = rng.randrange(1, 32)
                    word, desc = (
                        _csrrsi(rd, CSR_STIMECMP, uimm),
                        f"csrrsi stimecmp, {uimm}",
                    )
                else:
                    uimm = rng.randrange(1, 32)
                    word, desc = (
                        _csrrci(rd, CSR_STIMECMP, uimm),
                        f"csrrci stimecmp, {uimm}",
                    )
                emit(word, f"{desc} ({priv},stce={stce},tm={tm})")
                if priv == "U" or (priv == "S" and not (stce and tm)):
                    take_illegal_trap()
                continue

            # 9: Memory load/store traffic interleaved with TLB invalidations.
            rd = rng.choice(WRITABLE)
            base = 3 if priv == "U" else rng.choice((8, 9, 10))
            offset = rng.choice((0, 8))
            if rng.randrange(2) == 0:
                emit(_ld(rd, base, offset), f"ld x{rd}, {offset}(x{base})")
            else:
                src = rng.choice(WRITABLE)
                emit(_sd(src, base, offset), f"sd x{src}, {offset}(x{base})")

        path = directory / f"svinval_{index:03d}.S"
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        paths.append(path)

    return paths
