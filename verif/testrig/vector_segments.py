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

"""Seeded deterministic TestRIG generator for all 252 base-V segment memory forms.

Generates five VLEN-portable traces covering every (nf=2..8, EEW=8/16/32/64)
combination across all nine RVV 1.0 segment load/store classes:
  1. 01_segment_unit_stride.S   -- 56 unit-stride segment loads/stores (SEW != EEW),
                                   masked/tails/VL=0/VLMAX, control and illegal traps
  2. 02_segment_strided.S       -- 56 strided segment loads/stores (SEW != EEW),
                                   pos/neg/zero strides, masked/tails/VL=0/VLMAX and traps
  3. 03_segment_indexed_load.S  -- 56 indexed segment loads (unordered + ordered),
                                   cross-width, masked/tails/VL=0/VLMAX and overlap traps
  4. 04_segment_indexed_store.S -- 56 indexed segment stores (unordered + ordered),
                                   cross-width, dup-idx, masked/VL=0/VLMAX and traps
  5. 05_segment_fof.S           -- 28 fault-only-first segment loads, elem-0/1/2 and
                                   mid-segment faults, masked/VL=0/VLMAX, non-FoF vstart
                                   resume and illegal traps

Every trace avoids misa accesses and explicit vstart writes, verifies segment
field order across all fields independent of SEW, and reads back every written
byte of every retiring vector store through immediate scalar loads.
"""

from __future__ import annotations

import hashlib
import random
from pathlib import Path

DEFAULT_SEED = 0x5E60_0013

REG_NAMES = [
    "zero",
    "ra",
    "sp",
    "gp",
    "tp",
    "t0",
    "t1",
    "t2",
    "s0",
    "s1",
    "a0",
    "a1",
    "a2",
    "a3",
    "a4",
    "a5",
    "a6",
    "a7",
    "s2",
    "s3",
    "s4",
    "s5",
    "s6",
    "s7",
    "s8",
    "s9",
    "s10",
    "s11",
    "t3",
    "t4",
    "t5",
    "t6",
]

ZERO, T0, T1, T2, S0, S1, A0, A1, A2, S2, S3, S4, T6 = (
    0,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    18,
    19,
    20,
    31,
)

SEW_CODE = {8: 0, 16: 1, 32: 2, 64: 3}
WIDTH_CODE = {8: 0, 16: 5, 32: 6, 64: 7}
LMUL_CODE = {"m1": 0, "m2": 1, "m4": 2, "m8": 3, "mf8": 5, "mf4": 6, "mf2": 7}
LOAD_F3 = {1: (4, "lbu"), 2: (5, "lhu"), 4: (6, "lwu"), 8: (3, "ld")}
STORE_F3 = {1: (0, "sb"), 2: (1, "sh"), 4: (2, "sw"), 8: (3, "sd")}

# (SEW, LMUL) pairs with SEW != EEW and EMUL = (EEW / SEW) * LMUL == m1
# so every nf in 2..8 is legal and VLMAX >= 2 at VLEN >= 128.
UNIT_XWIDTH_CFG: dict[int, tuple[int, str]] = {
    8: (32, "m4"),
    16: (64, "m4"),
    32: (8, "mf4"),
    64: (16, "mf4"),
}
STRIDED_XWIDTH_CFG: dict[int, tuple[int, str]] = {
    8: (16, "m2"),
    16: (8, "mf2"),
    32: (64, "m2"),
    64: (32, "mf2"),
}

DDR_SRC_BASE = 0x8001_0000
DDR_DST_BASE = 0x8001_0400
DDR_LIMIT = 0xC000_0000

CONTROL_INSN = 0x43D0_2557  # vmv.x.s a0, v29 (appears once across all segment traces)

TRACE_NAMES = (
    "01_segment_unit_stride.S",
    "02_segment_strided.S",
    "03_segment_indexed_load.S",
    "04_segment_indexed_store.S",
    "05_segment_fof.S",
)

SENTINEL_BY_EEW = {
    8: 0x5A,
    16: 0x5A5A,
    32: 0x5A5A_A5A5,
    64: 0x5A5A_A5A5_1234_5678,
}


class _SeededPatterns:
    """Deterministic, seeded source-memory and store-payload tables."""

    def __init__(self, seed: int) -> None:
        rng = random.Random(seed)
        # Shuffled 1..255 gives 255 pairwise-distinct non-zero bytes so swapping
        # any two fields at any nf/EEW always changes the observed element.
        buf = list(range(1, 256))
        rng.shuffle(buf)
        buf.append(((buf[0] ^ 0xA5) | 1) & 0xFF)
        self._src = bytes(buf)

        self._store: dict[tuple[int, int, int], int] = {}
        for eew in (8, 16, 32, 64):
            used: set[int] = {0, SENTINEL_BY_EEW[eew]}
            mask = (1 << eew) - 1
            for field in range(8):
                for lane in range(4):
                    while True:
                        cand = rng.getrandbits(eew) & mask
                        if cand not in used:
                            used.add(cand)
                            self._store[(field, lane, eew)] = cand
                            break

    def src_elem(self, offset: int, nbytes: int) -> int:
        return int.from_bytes(self._src[offset : offset + nbytes], "little")

    def store_elem(self, field: int, lane: int, eew: int) -> int:
        return self._store[(field, lane, eew)]


def _sext64(val: int, bits: int) -> int:
    mask = (1 << bits) - 1
    val &= mask
    if val & (1 << (bits - 1)):
        return (val - (1 << bits)) & 0xFFFF_FFFF_FFFF_FFFF
    return val


def _enc_lui(rd: int, imm20: int) -> int:
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37


def _enc_addi(rd: int, rs1: int, imm12: int) -> int:
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x13


def _enc_slli(rd: int, rs1: int, shamt: int) -> int:
    return ((shamt & 0x3F) << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x13


def _enc_srli(rd: int, rs1: int, shamt: int) -> int:
    return ((shamt & 0x3F) << 20) | (rs1 << 15) | (5 << 12) | (rd << 7) | 0x13


def _enc_ori(rd: int, rs1: int, imm12: int) -> int:
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (6 << 12) | (rd << 7) | 0x13


def _enc_or(rd: int, rs1: int, rs2: int) -> int:
    return (0 << 25) | (rs2 << 20) | (rs1 << 15) | (6 << 12) | (rd << 7) | 0x33


def _enc_load(rd: int, rs1: int, imm12: int, f3: int) -> int:
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x03


def _enc_store(rs2: int, rs1: int, imm12: int, f3: int) -> int:
    imm = imm12 & 0xFFF
    return (
        ((imm >> 5) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (f3 << 12)
        | ((imm & 0x1F) << 7)
        | 0x23
    )


def _enc_csrrs(rd: int, csr: int, rs1: int) -> int:
    return ((csr & 0xFFF) << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x73


def _enc_vsetvli(rd: int, rs1: int, vtypei: int) -> int:
    return ((vtypei & 0x7FF) << 20) | (rs1 << 15) | (7 << 12) | (rd << 7) | 0x57


def _enc_vsetivli(rd: int, uimm: int, vtypei: int) -> int:
    return (
        (0b11 << 30)
        | ((vtypei & 0x3FF) << 20)
        | ((uimm & 0x1F) << 15)
        | (7 << 12)
        | (rd << 7)
        | 0x57
    )


def _enc_opv(f6: int, vm: int, vs2: int, vs1: int, f3: int, vd: int) -> int:
    return (
        (f6 << 26)
        | (vm << 25)
        | (vs2 << 20)
        | ((vs1 & 0x1F) << 15)
        | (f3 << 12)
        | (vd << 7)
        | 0x57
    )


def _enc_vmem(
    is_store: bool,
    nfields: int,
    mop: int,
    vm: int,
    rs2_or_umop: int,
    rs1: int,
    eew: int,
    vd_vs3: int,
) -> int:
    nf_field = nfields - 1
    opcode = 0x27 if is_store else 0x07
    return (
        (nf_field << 29)
        | (mop << 26)
        | (vm << 25)
        | (rs2_or_umop << 20)
        | (rs1 << 15)
        | (WIDTH_CODE[eew] << 12)
        | (vd_vs3 << 7)
        | opcode
    )


def _vtype(sew: int, lmul: str, ta: bool = False, ma: bool = False) -> int:
    return (int(ma) << 7) | (int(ta) << 6) | (SEW_CODE[sew] << 3) | LMUL_CODE[lmul]


class _TraceBuilder:
    def __init__(self, patterns: _SeededPatterns) -> None:
        self.pat = patterns
        self.lines: list[str] = []
        self.insn_count = 0
        self.assert_count = 0
        self.ctrl_order: int | None = None
        self.ctrl_expected: int | None = None

    def comment(self, text: str) -> None:
        self.lines.append(f"# {text}")

    def blank(self) -> None:
        self.lines.append("")

    def emit(
        self,
        word: int,
        asm: str,
        asserts: list[tuple[str, str]] | None = None,
    ) -> int:
        order = self.insn_count
        self.lines.append(f".4byte 0x{word:08x}  # {asm}")
        self.insn_count += 1
        if asserts:
            for cond, msg in asserts:
                self.lines.append(f'.assert {cond} "{msg}"')
                self.assert_count += 1
        return order

    def load_u32(self, rd: int, val: int) -> None:
        val32 = val & 0xFFFF_FFFF
        lo = val32 & 0xFFF
        if lo >= 0x800:
            lo_s = lo - 0x1000
            hi = ((val32 - lo_s) >> 12) & 0xFFFFF
        else:
            lo_s = lo
            hi = (val32 >> 12) & 0xFFFFF
        if hi == 0:
            self.emit(_enc_addi(rd, ZERO, lo_s), f"addi {REG_NAMES[rd]}, zero, {lo_s}")
        else:
            self.emit(_enc_lui(rd, hi), f"lui {REG_NAMES[rd]}, 0x{hi:x}")
            if lo_s != 0:
                self.emit(
                    _enc_addi(rd, rd, lo_s),
                    f"addi {REG_NAMES[rd]}, {REG_NAMES[rd]}, {lo_s}",
                )

    def load_u64(self, rd: int, val: int, tmp: int = T6) -> None:
        val &= 0xFFFF_FFFF_FFFF_FFFF
        if val < 0x8000_0000 or val >= 0xFFFF_FFFF_8000_0000:
            self.load_u32(rd, val & 0xFFFF_FFFF)
            return
        hi32 = (val >> 32) & 0xFFFF_FFFF
        lo32 = val & 0xFFFF_FFFF
        if lo32 == 0:
            self.load_u32(rd, hi32)
            self.emit(
                _enc_slli(rd, rd, 32), f"slli {REG_NAMES[rd]}, {REG_NAMES[rd]}, 32"
            )
            return
        if lo32 <= 0x7FF:
            self.load_u32(rd, hi32)
            self.emit(
                _enc_slli(rd, rd, 32), f"slli {REG_NAMES[rd]}, {REG_NAMES[rd]}, 32"
            )
            self.emit(
                _enc_ori(rd, rd, lo32),
                f"ori {REG_NAMES[rd]}, {REG_NAMES[rd]}, 0x{lo32:x}",
            )
            return
        self.load_u32(rd, hi32)
        self.emit(_enc_slli(rd, rd, 32), f"slli {REG_NAMES[rd]}, {REG_NAMES[rd]}, 32")
        self.load_u32(tmp, lo32)
        if lo32 & 0x8000_0000:
            self.emit(
                _enc_slli(tmp, tmp, 32),
                f"slli {REG_NAMES[tmp]}, {REG_NAMES[tmp]}, 32",
            )
            self.emit(
                _enc_srli(tmp, tmp, 32),
                f"srli {REG_NAMES[tmp]}, {REG_NAMES[tmp]}, 32",
            )
        self.emit(
            _enc_or(rd, rd, tmp),
            f"or {REG_NAMES[rd]}, {REG_NAMES[rd]}, {REG_NAMES[tmp]}",
        )

    def load_addr_shifted(self, rd: int, addr: int) -> None:
        """Load a 32-bit unsigned physical DDR address via lui+slli."""
        assert (addr & 0x1FFF) == 0
        self.emit(
            _enc_lui(rd, (addr >> 13) & 0xFFFFF),
            f"lui {REG_NAMES[rd]}, 0x{(addr >> 13) & 0xFFFFF:x}",
        )
        self.emit(_enc_slli(rd, rd, 1), f"slli {REG_NAMES[rd]}, {REG_NAMES[rd]}, 1")

    def vsetivli(
        self,
        rd: int,
        uimm: int,
        sew: int,
        lmul: str,
        ta: bool = False,
        ma: bool = False,
    ) -> None:
        vt = _vtype(sew, lmul, ta, ma)
        pol = f"{'ta' if ta else 'tu'}, {'ma' if ma else 'mu'}"
        self.emit(
            _enc_vsetivli(rd, uimm, vt),
            f"vsetivli {REG_NAMES[rd]}, {uimm}, e{sew}, {lmul}, {pol}",
        )

    def vsetvli_vlmax(
        self, rd: int, sew: int, lmul: str, ta: bool = False, ma: bool = False
    ) -> None:
        vt = _vtype(sew, lmul, ta, ma)
        pol = f"{'ta' if ta else 'tu'}, {'ma' if ma else 'mu'}"
        self.emit(
            _enc_vsetvli(rd, ZERO, vt),
            f"vsetvli {REG_NAMES[rd]}, zero, e{sew}, {lmul}, {pol}",
        )

    def vmv_v_i(self, vd: int, simm5: int) -> None:
        self.emit(_enc_opv(0x17, 1, 0, simm5 & 0x1F, 3, vd), f"vmv.v.i v{vd}, {simm5}")

    def vmv_v_x(self, vd: int, rs1: int) -> None:
        self.emit(_enc_opv(0x17, 1, 0, rs1, 4, vd), f"vmv.v.x v{vd}, {REG_NAMES[rs1]}")

    def vmv_s_x(self, vd: int, rs1: int) -> None:
        self.emit(_enc_opv(0x10, 1, 0, rs1, 6, vd), f"vmv.s.x v{vd}, {REG_NAMES[rs1]}")

    def load_vec_lanes(self, vd: int, vals: list[int], sew: int, lmul: str) -> None:
        for idx in range(len(vals) - 1, -1, -1):
            v = vals[idx] & ((1 << sew) - 1)
            self.vsetivli(A2, idx + 1, sew, lmul)
            if v <= 15:
                self.vmv_v_i(vd, v)
            elif v >= (1 << sew) - 16:
                self.vmv_v_i(vd, v - (1 << sew))
            else:
                self.load_u64(T1, v)
                self.vmv_v_x(vd, T1)

    def load_mask_u32(self, vd: int, bits: int) -> None:
        self.vsetivli(A2, 1, 32, "m1")
        if bits <= 15:
            self.vmv_v_i(vd, bits)
        else:
            self.load_u32(T1, bits)
            self.vmv_s_x(vd, T1)

    def read_lane(
        self,
        vs: int,
        lane: int,
        sew: int,
        lmul: str,
        expected: int | None,
        desc: str,
        scratch: int = 24,
    ) -> int:
        assert scratch != vs
        asserts: list[tuple[str, str]] | None = None
        if expected is not None:
            exp64 = _sext64(expected, sew)
            asserts = [
                ("rd_addr == 10", f"{desc} writes a0"),
                (f"rd_wdata == 0x{exp64:x}", desc),
            ]
        if lane == 0:
            self.vsetivli(A2, 1, sew, lmul)
            return self.emit(
                _enc_opv(0x10, 1, vs, 0, 2, A0),
                f"vmv.x.s a0, v{vs}",
                asserts,
            )
        self.vsetivli(A2, 1, sew, lmul)
        self.emit(
            _enc_opv(0x0F, 1, vs, lane, 3, scratch),
            f"vslidedown.vi v{scratch}, v{vs}, {lane}",
        )
        return self.emit(
            _enc_opv(0x10, 1, scratch, 0, 2, A0),
            f"vmv.x.s a0, v{scratch}",
            asserts,
        )

    def write_scalar_mem(
        self, base_reg: int, offset: int, nbytes: int, val: int
    ) -> None:
        f3, mnem = STORE_F3[nbytes]
        self.load_u64(T1, val)
        self.emit(
            _enc_store(T1, base_reg, offset, f3),
            f"{mnem} t1, {offset}({REG_NAMES[base_reg]})",
        )

    def read_scalar_mem(
        self,
        base_reg: int,
        offset: int,
        nbytes: int,
        expected: int | None,
        desc: str,
    ) -> None:
        f3, mnem = LOAD_F3[nbytes]
        asserts: list[tuple[str, str]] | None = None
        if expected is not None:
            asserts = [
                ("rd_addr == 10", f"{desc} writes a0"),
                (f"rd_wdata == 0x{expected:x}", desc),
            ]
        self.emit(
            _enc_load(A0, base_reg, offset, f3),
            f"{mnem} a0, {offset}({REG_NAMES[base_reg]})",
            asserts,
        )

    def assert_trap(
        self,
        word: int,
        asm: str,
        desc: str,
        cause: int = 2,
        tval: int | None = None,
    ) -> None:
        exp_tval = word if tval is None else tval
        self.emit(word, asm, [("trap == 1", f"{desc} traps")])
        self.emit(
            _enc_csrrs(A0, 0x342, ZERO),
            "csrr a0, mcause",
            [
                ("rd_addr == 10", f"{desc} mcause writes a0"),
                (f"rd_wdata == 0x{cause:x}", f"{desc} mcause"),
            ],
        )
        self.emit(
            _enc_csrrs(A0, 0x343, ZERO),
            "csrr a0, mtval",
            [
                ("rd_addr == 10", f"{desc} mtval writes a0"),
                (f"rd_wdata == 0x{exp_tval:x}", f"{desc} mtval"),
            ],
        )

    def assert_csr(self, csr: int, name: str, expected: int, desc: str) -> None:
        self.emit(
            _enc_csrrs(A0, csr, ZERO),
            f"csrr a0, {name}",
            [
                ("rd_addr == 10", f"{desc} writes a0"),
                (f"rd_wdata == 0x{expected:x}", desc),
            ],
        )

    def preamble(
        self, *, init_src_bytes: int = 0, init_pre_limit_bytes: int = 0
    ) -> None:
        self.lines.append(".noshrink")
        self.comment("Enable mstatus.VS, zero v0..v31, set cached DDR bases.")
        self.emit(_enc_addi(T0, ZERO, 0x600), "addi t0, zero, 0x600")
        self.emit(_enc_csrrs(ZERO, 0x300, T0), "csrs mstatus, t0")
        self.load_addr_shifted(S0, DDR_SRC_BASE)
        self.emit(_enc_addi(S1, S0, DDR_DST_BASE - DDR_SRC_BASE), "addi s1, s0, 1024")
        self.load_addr_shifted(S2, DDR_LIMIT)
        self.vsetvli_vlmax(T0, 8, "m8")
        for vd in (0, 8, 16, 24):
            self.vmv_v_i(vd, 0)
        if init_src_bytes > 0:
            self.comment(
                f"Populate {init_src_bytes} seeded bytes at s0 (0x{DDR_SRC_BASE:x})."
            )
            for off in range(0, init_src_bytes, 8):
                dw = self.pat.src_elem(off, 8)
                self.load_u64(T1, dw)
                self.emit(_enc_store(T1, S0, off, 3), f"sd t1, {off}(s0)")
        if init_pre_limit_bytes > 0:
            self.emit(
                _enc_addi(S3, S2, -init_pre_limit_bytes),
                f"addi s3, s2, -{init_pre_limit_bytes}",
            )
            self.comment(
                f"Populate {init_pre_limit_bytes} seeded bytes at s3=0x{DDR_LIMIT - init_pre_limit_bytes:x} below DDR limit."
            )
            for off in range(0, init_pre_limit_bytes, 8):
                dw = self.pat.src_elem(off, 8)
                self.load_u64(T1, dw)
                self.emit(_enc_store(T1, S3, off, 3), f"sd t1, {off}(s3)")
        self.blank()


def _preload_store_fields(tb: _TraceBuilder, eew: int) -> None:
    """Load seeded lane-0 and lane-1 values into v8..v15 for the given EEW."""
    for f in range(8):
        tb.load_vec_lanes(
            8 + f,
            [tb.pat.store_elem(f, 0, eew), tb.pat.store_elem(f, 1, eew)],
            eew,
            "m1",
        )


def _build_unit_stride_trace(patterns: _SeededPatterns) -> _TraceBuilder:
    """Trace 1: All 56 unit-stride segment forms (SEW != EEW), masked/tails/VL=0/VLMAX, control and traps."""
    tb = _TraceBuilder(patterns)
    tb.comment(
        "Generated segment unit-stride trace: all 56 vlseg/vsseg encodings (nf=2..8, e8..e64, SEW!=EEW)."
    )
    tb.preamble(init_src_bytes=128)

    # Control readout using vmv.x.s a0, v29 (0x43d02557) — ONLY occurrence across all segment traces.
    tb.comment(
        "Control readout: vlseg2e32.v v28, (s0); field 1 in v29 read via 0x43d02557."
    )
    ctrl_val = tb.pat.src_elem(4, 4)
    tb.vsetivli(A2, 2, 32, "m1")
    tb.emit(
        _enc_vmem(False, 2, 0, 1, 0, S0, 32, 28),
        "vlseg2e32.v v28, (s0)",
        [("trap == 0", "ctrl vlseg2e32.v retires")],
    )
    tb.ctrl_order = tb.read_lane(29, 0, 32, "m1", ctrl_val, "ctrl vlseg2e32 f1 lane 0")
    tb.ctrl_expected = _sext64(ctrl_val, 32)
    tb.read_lane(28, 0, 32, "m1", tb.pat.src_elem(0, 4), "ctrl vlseg2e32 f0 lane 0")
    tb.blank()

    # Sweep all 28 vlseg<nf>e<eew>.v with SEW != EEW (EMUL = (EEW/SEW)*LMUL = m1)
    tb.comment(
        "All 28 unit-stride segment loads with SEW != EEW: verify ALL nf fields at lane 0 + lane 1 endpoints."
    )
    for eew in (8, 16, 32, 64):
        nb = eew // 8
        sew, lmul = UNIT_XWIDTH_CFG[eew]
        for nf in range(2, 9):
            tb.vsetivli(A2, 2, sew, lmul)
            tb.emit(
                _enc_vmem(False, nf, 0, 1, 0, S0, eew, 8),
                f"vlseg{nf}e{eew}.v v8, (s0) [sew=e{sew},{lmul}]",
                [("trap == 0", f"vlseg{nf}e{eew}.v retires")],
            )
            for f in range(nf):
                tb.read_lane(
                    8 + f,
                    0,
                    eew,
                    "m1",
                    tb.pat.src_elem(f * nb, nb),
                    f"vlseg{nf}e{eew} f{f} lane 0",
                )
            seg_bytes = nf * nb
            tb.read_lane(
                8,
                1,
                eew,
                "m1",
                tb.pat.src_elem(seg_bytes, nb),
                f"vlseg{nf}e{eew} f0 lane 1",
            )
            tb.read_lane(
                8 + nf - 1,
                1,
                eew,
                "m1",
                tb.pat.src_elem(seg_bytes + (nf - 1) * nb, nb),
                f"vlseg{nf}e{eew} f{nf - 1} lane 1",
            )
    tb.blank()

    # Multi-reg EMUL=m2 cross-width (SEW=32 m1, vlseg3e64 -> EMUL=m2, vl=3 crosses into upper reg at VLEN 128)
    tb.comment(
        "Cross-width EMUL=m2 vlseg3e64.v (sew=e32, m1, vl=3) and EMUL=mf4 vlseg4e8.v."
    )
    tb.vsetivli(A2, 3, 32, "m1")
    tb.emit(
        _enc_vmem(False, 3, 0, 1, 0, S0, 64, 8),
        "vlseg3e64.v v8, (s0) [sew=e32,m1 -> EMUL=m2]",
        [("trap == 0", "xwidth m2 vlseg3e64.v retires")],
    )
    for f in range(3):
        tb.read_lane(
            8 + 2 * f,
            2,
            64,
            "m2",
            tb.pat.src_elem(2 * 24 + f * 8, 8),
            f"xwidth m2 vlseg3e64 f{f} lane 2",
        )
    tb.vsetivli(A2, 2, 32, "m1")  # eew=8 -> EMUL=mf4
    tb.emit(
        _enc_vmem(False, 4, 0, 1, 0, S0, 8, 8),
        "vlseg4e8.v v8, (s0) [sew=e32,m1 -> EMUL=mf4]",
        [("trap == 0", "xwidth mf4 vlseg4e8.v retires")],
    )
    for f in range(4):
        tb.read_lane(
            8 + f, 1, 8, "m1", tb.pat.src_elem(4 + f, 1), f"xwidth mf4 vlseg4e8 f{f} l1"
        )
    tb.blank()

    # Masked unit-stride loads (tu, mu AND ta, ma), VL == 0, and VLMAX
    tb.comment(
        "Masked vlseg3e16 (tu, mu), masked vlseg2e32 (ta, ma), VL==0 vlseg4e32, VLMAX vlseg2e64."
    )
    for f in range(3):
        tb.load_vec_lanes(8 + f, [0x1111, 0x2222, 0x3333], 16, "m1")
    tb.load_mask_u32(0, 0b01)  # lane 0 active, lane 1 masked-off (mu), lane 2 tail (tu)
    tb.vsetivli(A2, 2, 16, "m1", ta=False, ma=False)
    tb.emit(
        _enc_vmem(False, 3, 0, 0, 0, S0, 16, 8),
        "vlseg3e16.v v8, (s0), v0.t [tu,mu]",
        [("trap == 0", "masked tu,mu vlseg3e16.v retires")],
    )
    for f in range(3):
        tb.read_lane(
            8 + f, 0, 16, "m1", tb.pat.src_elem(f * 2, 2), f"masked vlseg3e16 f{f} l0"
        )
        tb.read_lane(8 + f, 1, 16, "m1", 0x2222, f"masked vlseg3e16 f{f} l1 mu")
        tb.read_lane(8 + f, 2, 16, "m1", 0x3333, f"masked vlseg3e16 f{f} l2 tu")

    for f in range(2):
        tb.load_vec_lanes(8 + f, [0x1111_0001, 0x2222_0002, 0x3333_0003], 32, "m1")
    tb.load_mask_u32(0, 0b01)
    tb.vsetivli(A2, 2, 32, "m1", ta=True, ma=True)
    tb.emit(
        _enc_vmem(False, 2, 0, 0, 0, S0, 32, 8),
        "vlseg2e32.v v8, (s0), v0.t [ta,ma]",
        [("trap == 0", "masked ta,ma vlseg2e32.v retires")],
    )
    for f in range(2):
        tb.read_lane(
            8 + f,
            0,
            32,
            "m1",
            tb.pat.src_elem(f * 4, 4),
            f"masked ta,ma vlseg2e32 f{f} l0",
        )
        tb.read_lane(8 + f, 1, 32, "m1", None, f"masked ta,ma vlseg2e32 f{f} l1 ma")
        tb.read_lane(8 + f, 2, 32, "m1", None, f"masked ta,ma vlseg2e32 f{f} l2 ta")

    # VL == 0 unit-stride load leaves destination sentinel untouched
    tb.vsetivli(A2, 2, 32, "m1")
    tb.load_u32(T1, SENTINEL_BY_EEW[32])
    for f in range(4):
        tb.vmv_v_x(8 + f, T1)
    tb.vsetivli(A2, 0, 32, "m1")
    tb.emit(
        _enc_vmem(False, 4, 0, 1, 0, S0, 32, 8),
        "vlseg4e32.v v8, (s0) [vl==0]",
        [("trap == 0", "vl==0 vlseg4e32.v retires")],
    )
    for f in range(4):
        tb.read_lane(
            8 + f, 0, 32, "m1", SENTINEL_BY_EEW[32], f"vl==0 vlseg4e32 f{f} l0"
        )

    # VLMAX unit-stride load (e64, m1 -> VLMAX = 2/4/8 across VLEN 128/256/512; <= 128 bytes)
    tb.vsetvli_vlmax(T0, 64, "m1")
    tb.emit(
        _enc_vmem(False, 2, 0, 1, 0, S0, 64, 8),
        "vlseg2e64.v v8, (s0) [VLMAX]",
        [("trap == 0", "vlmax vlseg2e64.v retires")],
    )
    for lane in range(2):
        for f in range(2):
            tb.read_lane(
                8 + f,
                lane,
                64,
                "m1",
                tb.pat.src_elem(lane * 16 + f * 8, 8),
                f"vlmax vlseg2e64 f{f} l{lane}",
            )
    tb.blank()

    # Sweep all 28 vsseg<nf>e<eew>.v with SEW != EEW and immediate scalar readback on EVERY written byte
    tb.comment(
        "All 28 unit-stride segment stores with SEW != EEW and immediate scalar readbacks."
    )
    for eew in (8, 16, 32, 64):
        nb = eew // 8
        sew, lmul = UNIT_XWIDTH_CFG[eew]
        _preload_store_fields(tb, eew)
        for nf in range(2, 9):
            tb.vsetivli(A2, 2, sew, lmul)
            tb.emit(
                _enc_vmem(True, nf, 0, 1, 0, S1, eew, 8),
                f"vsseg{nf}e{eew}.v v8, (s1) [sew=e{sew},{lmul}]",
                [("trap == 0", f"vsseg{nf}e{eew}.v retires")],
            )
            for lane in range(2):
                for f in range(nf):
                    off = (lane * nf + f) * nb
                    tb.read_scalar_mem(
                        S1,
                        off,
                        nb,
                        tb.pat.store_elem(f, lane, eew),
                        f"vsseg{nf}e{eew} l{lane} f{f}",
                    )
    tb.blank()

    # Masked vsseg3e16, VL == 0 vsseg4e32, and VLMAX vsseg2e64 stores with immediate scalar readbacks
    tb.comment(
        "Masked vsseg3e16, VL==0 vsseg4e32, and VLMAX vsseg2e64 stores with immediate readbacks."
    )
    _preload_store_fields(tb, 16)
    for off in range(0, 12, 2):
        tb.write_scalar_mem(S1, off, 2, SENTINEL_BY_EEW[16])
    tb.load_mask_u32(0, 0b01)
    tb.vsetivli(A2, 2, 16, "m1")
    tb.emit(
        _enc_vmem(True, 3, 0, 0, 0, S1, 16, 8),
        "vsseg3e16.v v8, (s1), v0.t",
        [("trap == 0", "masked vsseg3e16.v retires")],
    )
    for f in range(3):
        tb.read_scalar_mem(
            S1, f * 2, 2, tb.pat.store_elem(f, 0, 16), f"masked vsseg3e16 l0 f{f}"
        )
    for f in range(3):
        tb.read_scalar_mem(
            S1, 6 + f * 2, 2, SENTINEL_BY_EEW[16], f"masked vsseg3e16 l1 f{f} untouched"
        )

    tb.write_scalar_mem(S1, 0, 4, SENTINEL_BY_EEW[32])
    tb.vsetivli(A2, 0, 32, "m1")
    tb.emit(
        _enc_vmem(True, 4, 0, 1, 0, S1, 32, 8),
        "vsseg4e32.v v8, (s1) [vl==0]",
        [("trap == 0", "vl==0 vsseg4e32.v retires")],
    )
    tb.read_scalar_mem(
        S1, 0, 4, SENTINEL_BY_EEW[32], "vl==0 vsseg4e32 sentinel untouched"
    )

    for off in range(0, 128, 8):
        tb.write_scalar_mem(S1, off, 8, SENTINEL_BY_EEW[64])
    tb.vsetvli_vlmax(T0, 64, "m1")
    tb.load_u64(T1, tb.pat.store_elem(0, 0, 64))
    tb.vmv_v_x(8, T1)
    tb.load_u64(T1, tb.pat.store_elem(1, 0, 64))
    tb.vmv_v_x(9, T1)
    tb.emit(
        _enc_vmem(True, 2, 0, 1, 0, S1, 64, 8),
        "vsseg2e64.v v8, (s1) [VLMAX]",
        [("trap == 0", "vlmax vsseg2e64.v retires")],
    )
    for lane in range(8):
        for f in range(2):
            exp = tb.pat.store_elem(f, 0, 64) if lane < 2 else None
            tb.read_scalar_mem(
                S1, (lane * 2 + f) * 8, 8, exp, f"vlmax vsseg2e64 l{lane} f{f}"
            )
    tb.blank()

    # Illegal traps: nf*EMUL>8 (10, cross-width 10, 12, 16), vd+nf*EMUL>32, masked v0, align, vill
    tb.comment(
        "Unit-stride segment illegal traps: nf*EMUL>8 (10, xwidth 10, 12, 16), wrap, v0, align, vill."
    )
    tb.vsetivli(A2, 2, 32, "m2")
    tb.assert_trap(
        _enc_vmem(False, 5, 0, 1, 0, S0, 32, 8),
        "vlseg5e32.v v8, (s0)",
        "vlseg5e32 m2 nf*EMUL=10>8",
    )
    tb.assert_trap(
        _enc_vmem(True, 5, 0, 1, 0, S1, 32, 8),
        "vsseg5e32.v v8, (s1)",
        "vsseg5e32 m2 nf*EMUL=10>8",
    )
    tb.vsetivli(
        A2, 2, 16, "m1"
    )  # eew=32 -> EMUL=m2, nf=5 -> nf*EMUL=10>8 despite LMUL=m1
    tb.assert_trap(
        _enc_vmem(False, 5, 0, 1, 0, S0, 32, 8),
        "vlseg5e32.v v8, (s0) [sew=e16,m1 -> EMUL=m2]",
        "vlseg5e32 xwidth nf*EMUL=10>8",
    )
    tb.vsetivli(A2, 2, 32, "m4")
    tb.assert_trap(
        _enc_vmem(False, 3, 0, 1, 0, S0, 32, 8),
        "vlseg3e32.v v8, (s0)",
        "vlseg3e32 m4 nf*EMUL=12>8",
    )
    tb.assert_trap(
        _enc_vmem(True, 3, 0, 1, 0, S1, 32, 8),
        "vsseg3e32.v v8, (s1)",
        "vsseg3e32 m4 nf*EMUL=12>8",
    )
    tb.vsetivli(A2, 2, 32, "m2")
    tb.assert_trap(
        _enc_vmem(False, 2, 0, 1, 0, S0, 32, 9),
        "vlseg2e32.v v9, (s0)",
        "vlseg2e32 m2 misaligned vd",
    )
    tb.vsetivli(A2, 2, 32, "m8")
    tb.assert_trap(
        _enc_vmem(False, 2, 0, 1, 0, S0, 32, 8),
        "vlseg2e32.v v8, (s0)",
        "vlseg2e32 m8 nf*EMUL=16>8",
    )
    tb.vsetivli(A2, 2, 32, "m1")
    tb.assert_trap(
        _enc_vmem(False, 5, 0, 1, 0, S0, 32, 28),
        "vlseg5e32.v v28, (s0)",
        "vlseg5e32 m1 vd+nf=33>32",
    )
    tb.assert_trap(
        _enc_vmem(False, 2, 0, 0, 0, S0, 32, 0),
        "vlseg2e32.v v0, (s0), v0.t",
        "vlseg2e32 masked vd==v0",
    )
    tb.emit(
        _enc_vsetivli(A2, 1, 0x020),
        "vsetivli a2, 1, 0x20 (vill=1)",
        [("rd_addr == 12", "vill writes a2"), ("rd_wdata == 0x0", "vill vl=0")],
    )
    tb.assert_trap(
        _enc_vmem(False, 2, 0, 1, 0, S0, 32, 8),
        "vlseg2e32.v v8, (s0)",
        "vlseg2e32 under vill=1",
    )
    return tb


def _build_strided_trace(patterns: _SeededPatterns) -> _TraceBuilder:
    """Trace 2: All 56 strided segment forms (SEW != EEW), neg/zero strides, masked/tails/VL=0/VLMAX and traps."""
    tb = _TraceBuilder(patterns)
    tb.comment(
        "Generated segment strided trace: all 56 vlsseg/vssseg encodings (nf=2..8, e8..e64, SEW!=EEW)."
    )
    tb.preamble(init_src_bytes=256)

    # All 28 vlsseg<nf>e<eew>.v with SEW != EEW and positive stride=72 (> max segment width 64)
    tb.comment(
        "All 28 strided segment loads with SEW != EEW and positive stride=72 (> max segment width 64)."
    )
    tb.emit(_enc_addi(T2, ZERO, 72), "addi t2, zero, 72")
    for eew in (8, 16, 32, 64):
        nb = eew // 8
        sew, lmul = STRIDED_XWIDTH_CFG[eew]
        for nf in range(2, 9):
            tb.vsetivli(A2, 2, sew, lmul)
            tb.emit(
                _enc_vmem(False, nf, 2, 1, T2, S0, eew, 8),
                f"vlsseg{nf}e{eew}.v v8, (s0), t2 [sew=e{sew},{lmul}]",
                [("trap == 0", f"vlsseg{nf}e{eew}.v retires")],
            )
            for f in range(nf):
                tb.read_lane(
                    8 + f,
                    0,
                    eew,
                    "m1",
                    tb.pat.src_elem(f * nb, nb),
                    f"vlsseg{nf}e{eew} f{f} lane 0",
                )
            tb.read_lane(
                8, 1, eew, "m1", tb.pat.src_elem(72, nb), f"vlsseg{nf}e{eew} f0 lane 1"
            )
            tb.read_lane(
                8 + nf - 1,
                1,
                eew,
                "m1",
                tb.pat.src_elem(72 + (nf - 1) * nb, nb),
                f"vlsseg{nf}e{eew} f{nf - 1} lane 1",
            )
    tb.blank()

    # Negative stride, zero stride (x0), masked (tu,mu and ta,ma), VL == 0, and VLMAX
    tb.comment(
        "Negative stride (-32), zero stride (x0), masked (tu,mu + ta,ma), VL==0 and VLMAX strided loads."
    )
    tb.emit(_enc_addi(S4, S0, 64), "addi s4, s0, 64")
    tb.emit(_enc_addi(T2, ZERO, -32), "addi t2, zero, -32")
    tb.vsetivli(A2, 2, 32, "m1")
    tb.emit(
        _enc_vmem(False, 4, 2, 1, T2, S4, 32, 8),
        "vlsseg4e32.v v8, (s4), t2",
        [("trap == 0", "neg-stride vlsseg4e32.v retires")],
    )
    for f in range(4):
        tb.read_lane(
            8 + f, 0, 32, "m1", tb.pat.src_elem(64 + f * 4, 4), f"neg vlsseg4 f{f} l0"
        )
        tb.read_lane(
            8 + f, 1, 32, "m1", tb.pat.src_elem(32 + f * 4, 4), f"neg vlsseg4 f{f} l1"
        )

    tb.vsetivli(A2, 2, 32, "m1")
    tb.emit(
        _enc_vmem(False, 3, 2, 1, ZERO, S0, 32, 8),
        "vlsseg3e32.v v8, (s0), zero",
        [("trap == 0", "zero-stride vlsseg3e32.v retires")],
    )
    for f in range(3):
        tb.read_lane(
            8 + f,
            1,
            32,
            "m1",
            tb.pat.src_elem(f * 4, 4),
            f"zero-stride vlsseg3 f{f} l1",
        )

    tb.emit(_enc_addi(T2, ZERO, 72), "addi t2, zero, 72")
    for f in range(3):
        tb.load_vec_lanes(8 + f, [0x1111_0001, 0x2222_0002, 0x3333_0003], 32, "m1")
    tb.load_mask_u32(0, 0b01)
    tb.vsetivli(A2, 2, 32, "m1", ta=False, ma=False)
    tb.emit(
        _enc_vmem(False, 3, 2, 0, T2, S0, 32, 8),
        "vlsseg3e32.v v8, (s0), t2, v0.t [tu,mu]",
        [("trap == 0", "masked tu,mu vlsseg3e32.v retires")],
    )
    for f in range(3):
        tb.read_lane(
            8 + f, 0, 32, "m1", tb.pat.src_elem(f * 4, 4), f"masked vlsseg3e32 f{f} l0"
        )
        tb.read_lane(8 + f, 1, 32, "m1", 0x2222_0002, f"masked vlsseg3e32 f{f} l1 mu")
        tb.read_lane(8 + f, 2, 32, "m1", 0x3333_0003, f"masked vlsseg3e32 f{f} l2 tu")

    for f in range(2):
        tb.load_vec_lanes(8 + f, [0x1111_0001, 0x2222_0002, 0x3333_0003], 32, "m1")
    tb.load_mask_u32(0, 0b01)
    tb.vsetivli(A2, 2, 32, "m1", ta=True, ma=True)
    tb.emit(
        _enc_vmem(False, 2, 2, 0, T2, S0, 32, 8),
        "vlsseg2e32.v v8, (s0), t2, v0.t [ta,ma]",
        [("trap == 0", "masked ta,ma vlsseg2e32.v retires")],
    )
    for f in range(2):
        tb.read_lane(
            8 + f,
            0,
            32,
            "m1",
            tb.pat.src_elem(f * 4, 4),
            f"masked ta,ma vlsseg2e32 f{f} l0",
        )
        tb.read_lane(8 + f, 1, 32, "m1", None, f"masked ta,ma vlsseg2e32 f{f} l1 ma")
        tb.read_lane(8 + f, 2, 32, "m1", None, f"masked ta,ma vlsseg2e32 f{f} l2 ta")

    tb.vsetivli(A2, 2, 32, "m1")
    tb.load_u32(T1, SENTINEL_BY_EEW[32])
    tb.vmv_v_x(8, T1)
    tb.vmv_v_x(9, T1)
    tb.vsetivli(A2, 0, 32, "m1")
    tb.emit(
        _enc_vmem(False, 2, 2, 1, T2, S0, 32, 8),
        "vlsseg2e32.v v8, (s0), t2 [vl==0]",
        [("trap == 0", "vl==0 vlsseg2e32.v retires")],
    )
    tb.read_lane(8, 0, 32, "m1", SENTINEL_BY_EEW[32], "vl==0 vlsseg2e32 f0 l0")
    tb.read_lane(9, 0, 32, "m1", SENTINEL_BY_EEW[32], "vl==0 vlsseg2e32 f1 l0")

    # VLMAX strided load (e32, mf2 -> VLMAX=2/4/8, stride=16 -> max byte 7*16+8=120 < 256)
    tb.emit(_enc_addi(T2, ZERO, 16), "addi t2, zero, 16")
    tb.vsetvli_vlmax(T0, 32, "mf2")
    tb.emit(
        _enc_vmem(False, 2, 2, 1, T2, S0, 32, 8),
        "vlsseg2e32.v v8, (s0), t2 [VLMAX]",
        [("trap == 0", "vlmax vlsseg2e32.v retires")],
    )
    for lane in range(2):
        for f in range(2):
            tb.read_lane(
                8 + f,
                lane,
                32,
                "m1",
                tb.pat.src_elem(lane * 16 + f * 4, 4),
                f"vlmax vlsseg2e32 f{f} l{lane}",
            )
    tb.blank()

    # All 28 vssseg<nf>e<eew>.v with SEW != EEW, positive stride=72 and immediate scalar readback
    tb.comment(
        "All 28 strided segment stores with SEW != EEW, stride=72 and immediate scalar readbacks."
    )
    tb.emit(_enc_addi(T2, ZERO, 72), "addi t2, zero, 72")
    for eew in (8, 16, 32, 64):
        nb = eew // 8
        sew, lmul = STRIDED_XWIDTH_CFG[eew]
        _preload_store_fields(tb, eew)
        for nf in range(2, 9):
            tb.vsetivli(A2, 2, sew, lmul)
            tb.emit(
                _enc_vmem(True, nf, 2, 1, T2, S1, eew, 8),
                f"vssseg{nf}e{eew}.v v8, (s1), t2 [sew=e{sew},{lmul}]",
                [("trap == 0", f"vssseg{nf}e{eew}.v retires")],
            )
            for lane in range(2):
                for f in range(nf):
                    off = lane * 72 + f * nb
                    tb.read_scalar_mem(
                        S1,
                        off,
                        nb,
                        tb.pat.store_elem(f, lane, eew),
                        f"vssseg{nf}e{eew} l{lane} f{f}",
                    )
    tb.blank()

    # Masked vssseg2e32 and VL == 0 vssseg2e32 stores
    tb.comment(
        "Masked vssseg2e32 and VL==0 vssseg2e32 stores with immediate scalar readbacks."
    )
    _preload_store_fields(tb, 32)
    for off in (0, 4, 72, 76):
        tb.write_scalar_mem(S1, off, 4, SENTINEL_BY_EEW[32])
    tb.load_mask_u32(0, 0b01)
    tb.vsetivli(A2, 2, 32, "m1")
    tb.emit(
        _enc_vmem(True, 2, 2, 0, T2, S1, 32, 8),
        "vssseg2e32.v v8, (s1), t2, v0.t",
        [("trap == 0", "masked vssseg2e32.v retires")],
    )
    tb.read_scalar_mem(S1, 0, 4, tb.pat.store_elem(0, 0, 32), "masked vssseg2e32 l0 f0")
    tb.read_scalar_mem(S1, 4, 4, tb.pat.store_elem(1, 0, 32), "masked vssseg2e32 l0 f1")
    tb.read_scalar_mem(
        S1, 72, 4, SENTINEL_BY_EEW[32], "masked vssseg2e32 l1 f0 untouched"
    )
    tb.read_scalar_mem(
        S1, 76, 4, SENTINEL_BY_EEW[32], "masked vssseg2e32 l1 f1 untouched"
    )

    tb.write_scalar_mem(S1, 0, 4, SENTINEL_BY_EEW[32])
    tb.vsetivli(A2, 0, 32, "m1")
    tb.emit(
        _enc_vmem(True, 2, 2, 1, T2, S1, 32, 8),
        "vssseg2e32.v v8, (s1), t2 [vl==0]",
        [("trap == 0", "vl==0 vssseg2e32.v retires")],
    )
    tb.read_scalar_mem(
        S1, 0, 4, SENTINEL_BY_EEW[32], "vl==0 vssseg2e32 sentinel untouched"
    )
    tb.blank()

    # Strided segment traps
    tb.comment(
        "Strided segment illegal traps: nf*EMUL>8 (10, 12), vd+nf*EMUL>32, masked v0, align, vill."
    )
    tb.vsetivli(A2, 2, 16, "m2")
    tb.assert_trap(
        _enc_vmem(False, 5, 2, 1, T2, S0, 16, 8),
        "vlsseg5e16.v v8, (s0), t2",
        "vlsseg5e16 m2 nf*EMUL=10>8",
    )
    tb.assert_trap(
        _enc_vmem(False, 6, 2, 1, T2, S0, 16, 8),
        "vlsseg6e16.v v8, (s0), t2",
        "vlsseg6e16 m2 nf*EMUL=12>8",
    )
    tb.assert_trap(
        _enc_vmem(True, 6, 2, 1, T2, S1, 16, 8),
        "vssseg6e16.v v8, (s1), t2",
        "vssseg6e16 m2 nf*EMUL=12>8",
    )
    tb.vsetivli(A2, 2, 32, "m1")
    tb.assert_trap(
        _enc_vmem(False, 6, 2, 1, T2, S0, 32, 27),
        "vlsseg6e32.v v27, (s0), t2",
        "vlsseg6e32 m1 vd+nf=33>32",
    )
    tb.assert_trap(
        _enc_vmem(True, 2, 2, 0, T2, S1, 32, 0),
        "vssseg2e32.v v0, (s1), t2, v0.t",
        "vssseg2e32 masked vs3==v0",
    )
    tb.emit(
        _enc_vsetivli(A2, 1, 0x020),
        "vsetivli a2, 1, 0x20 (vill=1)",
        [("rd_addr == 12", "vill writes a2"), ("rd_wdata == 0x0", "vill vl=0")],
    )
    tb.assert_trap(
        _enc_vmem(False, 2, 2, 1, T2, S0, 32, 8),
        "vlsseg2e32.v v8, (s0), t2",
        "vlsseg2e32 under vill=1",
    )
    return tb


def _build_indexed_load_trace(patterns: _SeededPatterns) -> _TraceBuilder:
    """Trace 3: All 56 indexed segment loads + cross-width (all 4 ieew) + masked/VL=0/VLMAX + overlap traps."""
    tb = _TraceBuilder(patterns)
    tb.comment(
        "Generated segment indexed-load trace: all 56 vluxseg/vloxseg encodings (nf=2..8, ei8..ei64)."
    )
    tb.preamble(init_src_bytes=256)

    # Non-monotonic offsets [128, 16]: 128 (0x80) tests unsigned high-bit ei8; disjoint even for nf=8, e64!
    offsets = [128, 16]
    tb.comment(
        "All 56 indexed segment loads (28 vluxseg + 28 vloxseg); offsets=[128, 16] (high-bit ei8)."
    )
    for ieew in (8, 16, 32, 64):
        nb = ieew // 8
        tb.load_vec_lanes(16, offsets, ieew, "m1")
        for mop, prefix in ((1, "vluxseg"), (3, "vloxseg")):
            for nf in range(2, 9):
                tb.vsetivli(A2, 2, ieew, "m1")
                tb.emit(
                    _enc_vmem(False, nf, mop, 1, 16, S0, ieew, 8),
                    f"{prefix}{nf}ei{ieew}.v v8, (s0), v16",
                    [("trap == 0", f"{prefix}{nf}ei{ieew}.v retires")],
                )
                for f in range(nf):
                    tb.read_lane(
                        8 + f,
                        0,
                        ieew,
                        "m1",
                        tb.pat.src_elem(offsets[0] + f * nb, nb),
                        f"{prefix}{nf}ei{ieew} f{f} lane 0",
                    )
                tb.read_lane(
                    8,
                    1,
                    ieew,
                    "m1",
                    tb.pat.src_elem(offsets[1], nb),
                    f"{prefix}{nf}ei{ieew} f0 lane 1",
                )
                tb.read_lane(
                    8 + nf - 1,
                    1,
                    ieew,
                    "m1",
                    tb.pat.src_elem(offsets[1] + (nf - 1) * nb, nb),
                    f"{prefix}{nf}ei{ieew} f{nf - 1} lane 1",
                )
    tb.blank()

    # Cross-width data SEW != index EEW across all 4 index widths + masked (tu,mu and ta,ma) + VL=0 + VLMAX
    tb.comment(
        "Cross-width indexed segment loads (ei8/e32, ei16/e64, masked ei32/e16 tu,mu, masked ei64/e32 ta,ma), VL==0, VLMAX."
    )
    tb.load_vec_lanes(16, [128, 16], 8, "m1")
    tb.vsetivli(A2, 2, 32, "m1")  # index EMUL=mf4, data SEW=32 m1
    tb.emit(
        _enc_vmem(False, 3, 1, 1, 16, S0, 8, 8),
        "vluxseg3ei8.v v8, (s0), v16 [data=e32]",
        [("trap == 0", "cross-width vluxseg3ei8 e32 retires")],
    )
    for f in range(3):
        tb.read_lane(
            8 + f,
            0,
            32,
            "m1",
            tb.pat.src_elem(128 + f * 4, 4),
            f"xwidth ei8/e32 f{f} l0",
        )
        tb.read_lane(
            8 + f,
            1,
            32,
            "m1",
            tb.pat.src_elem(16 + f * 4, 4),
            f"xwidth ei8/e32 f{f} l1",
        )

    tb.load_vec_lanes(16, [128, 16], 16, "m1")
    tb.vsetivli(A2, 2, 64, "m1")  # index EMUL=mf4, data SEW=64 m1
    tb.emit(
        _enc_vmem(False, 2, 3, 1, 16, S0, 16, 8),
        "vloxseg2ei16.v v8, (s0), v16 [data=e64]",
        [("trap == 0", "cross-width vloxseg2ei16 e64 retires")],
    )
    for f in range(2):
        tb.read_lane(
            8 + f,
            0,
            64,
            "m1",
            tb.pat.src_elem(128 + f * 8, 8),
            f"xwidth ei16/e64 f{f} l0",
        )
        tb.read_lane(
            8 + f,
            1,
            64,
            "m1",
            tb.pat.src_elem(16 + f * 8, 8),
            f"xwidth ei16/e64 f{f} l1",
        )

    tb.load_vec_lanes(16, [128, 16], 32, "m2")
    for f in range(3):
        tb.load_vec_lanes(8 + f, [0x4444, 0x5555, 0x6666], 16, "m1")
    tb.load_mask_u32(0, 0b01)
    tb.vsetivli(
        A2, 2, 16, "m1", ta=False, ma=False
    )  # index EMUL=m2, data SEW=16 m1, masked tu,mu
    tb.emit(
        _enc_vmem(False, 3, 3, 0, 16, S0, 32, 8),
        "vloxseg3ei32.v v8, (s0), v16, v0.t [tu,mu]",
        [("trap == 0", "cross-width masked tu,mu vloxseg3ei32 e16 retires")],
    )
    for f in range(3):
        tb.read_lane(
            8 + f,
            0,
            16,
            "m1",
            tb.pat.src_elem(128 + f * 2, 2),
            f"xwidth masked ei32/e16 f{f} l0",
        )
        tb.read_lane(8 + f, 1, 16, "m1", 0x5555, f"xwidth masked ei32/e16 f{f} l1 mu")
        tb.read_lane(8 + f, 2, 16, "m1", 0x6666, f"xwidth masked ei32/e16 f{f} l2 tu")

    tb.load_vec_lanes(16, [128, 16], 64, "m2")
    for f in range(2):
        tb.load_vec_lanes(8 + f, [0x1111_0001, 0x2222_0002, 0x3333_0003], 32, "m1")
    tb.load_mask_u32(0, 0b01)
    tb.vsetivli(
        A2, 2, 32, "m1", ta=True, ma=True
    )  # index EMUL=m2, data SEW=32 m1, masked ta,ma
    tb.emit(
        _enc_vmem(False, 2, 1, 0, 16, S0, 64, 8),
        "vluxseg2ei64.v v8, (s0), v16, v0.t [ta,ma]",
        [("trap == 0", "cross-width masked ta,ma vluxseg2ei64 e32 retires")],
    )
    for f in range(2):
        tb.read_lane(
            8 + f,
            0,
            32,
            "m1",
            tb.pat.src_elem(128 + f * 4, 4),
            f"xwidth ta,ma ei64/e32 f{f} l0",
        )
        tb.read_lane(8 + f, 1, 32, "m1", None, f"xwidth ta,ma ei64/e32 f{f} l1 ma")
        tb.read_lane(8 + f, 2, 32, "m1", None, f"xwidth ta,ma ei64/e32 f{f} l2 ta")

    # VL == 0 and VLMAX indexed segment loads
    tb.vsetivli(A2, 2, 32, "m1")
    tb.load_u32(T1, SENTINEL_BY_EEW[32])
    tb.vmv_v_x(8, T1)
    tb.vmv_v_x(9, T1)
    tb.vsetivli(A2, 0, 32, "m1")
    tb.emit(
        _enc_vmem(False, 2, 1, 1, 16, S0, 32, 8),
        "vluxseg2ei32.v v8, (s0), v16 [vl==0]",
        [("trap == 0", "vl==0 vluxseg2ei32.v retires")],
    )
    tb.read_lane(8, 0, 32, "m1", SENTINEL_BY_EEW[32], "vl==0 vluxseg2ei32 f0 l0")
    tb.read_lane(9, 0, 32, "m1", SENTINEL_BY_EEW[32], "vl==0 vluxseg2ei32 f1 l0")

    tb.vsetvli_vlmax(T0, 32, "mf2")
    tb.vmv_v_i(16, 8)
    tb.emit(
        _enc_vmem(False, 2, 3, 1, 16, S0, 32, 8),
        "vloxseg2ei32.v v8, (s0), v16 [VLMAX]",
        [("trap == 0", "vlmax vloxseg2ei32.v retires")],
    )
    for lane in range(2):
        for f in range(2):
            tb.read_lane(
                8 + f,
                lane,
                32,
                "m1",
                tb.pat.src_elem(8 + f * 4, 4),
                f"vlmax vloxseg2ei32 f{f} l{lane}",
            )
    tb.blank()

    # Indexed segment load traps: nf*EMUL>8 (10, 12), single & multi-reg vd/vs2 overlap, v0, wrap, align, vill
    tb.comment(
        "Indexed segment load illegal traps: nf*EMUL>8, single & multi-reg vd/vs2 overlap, v0, wrap, align, vill."
    )
    tb.vsetivli(A2, 2, 32, "m2")
    tb.assert_trap(
        _enc_vmem(False, 5, 1, 1, 20, S0, 32, 8),
        "vluxseg5ei32.v v8, (s0), v20",
        "vluxseg5ei32 m2 nf*EMUL=10>8",
    )
    tb.vsetivli(A2, 2, 32, "m4")
    tb.assert_trap(
        _enc_vmem(False, 3, 1, 1, 20, S0, 32, 8),
        "vluxseg3ei32.v v8, (s0), v20",
        "vluxseg3ei32 m4 nf*EMUL=12>8",
    )
    tb.vsetivli(A2, 2, 32, "m1")
    tb.assert_trap(
        _enc_vmem(False, 4, 1, 1, 10, S0, 32, 8),
        "vluxseg4ei32.v v8, (s0), v10",
        "vluxseg4ei32 vd[8..11] overlaps vs2=v10",
    )
    tb.assert_trap(
        _enc_vmem(False, 2, 3, 1, 8, S0, 32, 8),
        "vloxseg2ei32.v v8, (s0), v8",
        "vloxseg2ei32 vd==vs2 overlap",
    )
    tb.assert_trap(
        _enc_vmem(False, 3, 1, 1, 10, S0, 32, 8),
        "vluxseg3ei32.v v8, (s0), v10",
        "vluxseg3ei32 vd[8..10] highest reg overlaps vs2=v10",
    )
    tb.vsetivli(
        A2, 2, 16, "m1"
    )  # ei32 -> index EMUL=m2 (vs2=v10..v11); vd=v11..v12 overlaps upper reg v11
    tb.assert_trap(
        _enc_vmem(False, 2, 3, 1, 10, S0, 32, 11),
        "vloxseg2ei32.v v11, (s0), v10",
        "vloxseg2ei32 vd[11..12] overlaps upper vs2[10..11] overlap",
    )
    tb.vsetivli(
        A2, 2, 32, "m2"
    )  # data EMUL=m2 (vd=v8..v11); ei8 -> index EMUL=mf2 (vs2=v11 overlaps upper vd)
    tb.assert_trap(
        _enc_vmem(False, 2, 1, 1, 11, S0, 8, 8),
        "vluxseg2ei8.v v8, (s0), v11",
        "vluxseg2ei8 m2 vd[8..11] overlaps vs2=v11 overlap",
    )
    tb.vsetivli(A2, 2, 32, "m1")
    tb.assert_trap(
        _enc_vmem(False, 2, 1, 0, 16, S0, 32, 0),
        "vluxseg2ei32.v v0, (s0), v16, v0.t",
        "vluxseg2ei32 masked vd==v0",
    )
    tb.assert_trap(
        _enc_vmem(False, 2, 3, 0, 0, S0, 32, 8),
        "vloxseg2ei32.v v8, (s0), v0, v0.t",
        "vloxseg2ei32 masked vs2==v0",
    )
    tb.assert_trap(
        _enc_vmem(False, 5, 1, 1, 16, S0, 32, 28),
        "vluxseg5ei32.v v28, (s0), v16",
        "vluxseg5ei32 vd+nf=33>32",
    )
    tb.vsetivli(A2, 2, 16, "m1")  # ei32 -> index EMUL=m2 -> odd vs2=v17 misaligned
    tb.assert_trap(
        _enc_vmem(False, 2, 1, 1, 17, S0, 32, 8),
        "vluxseg2ei32.v v8, (s0), v17",
        "vluxseg2ei32 index EMUL=m2 misaligned vs2",
    )
    tb.emit(
        _enc_vsetivli(A2, 1, 0x020),
        "vsetivli a2, 1, 0x20 (vill=1)",
        [("rd_addr == 12", "vill writes a2"), ("rd_wdata == 0x0", "vill vl=0")],
    )
    tb.assert_trap(
        _enc_vmem(False, 2, 1, 1, 16, S0, 32, 8),
        "vluxseg2ei32.v v8, (s0), v16",
        "vluxseg2ei32 under vill=1",
    )
    return tb


def _build_indexed_store_trace(patterns: _SeededPatterns) -> _TraceBuilder:
    """Trace 4: All 56 indexed segment stores + cross-width + dup-idx + masked/VL=0/VLMAX + traps."""
    tb = _TraceBuilder(patterns)
    tb.comment(
        "Generated segment indexed-store trace: all 56 vsuxseg/vsoxseg encodings (nf=2..8, ei8..ei64)."
    )
    tb.preamble(init_src_bytes=0)

    offsets = [128, 16]
    tb.comment(
        "All 56 indexed segment stores (28 vsuxseg + 28 vsoxseg) with immediate scalar readbacks."
    )
    for ieew in (8, 16, 32, 64):
        nb = ieew // 8
        _preload_store_fields(tb, ieew)
        tb.load_vec_lanes(16, offsets, ieew, "m1")
        for mop, prefix in ((1, "vsuxseg"), (3, "vsoxseg")):
            for nf in range(2, 9):
                tb.vsetivli(A2, 2, ieew, "m1")
                tb.emit(
                    _enc_vmem(True, nf, mop, 1, 16, S1, ieew, 8),
                    f"{prefix}{nf}ei{ieew}.v v8, (s1), v16",
                    [("trap == 0", f"{prefix}{nf}ei{ieew}.v retires")],
                )
                for lane in range(2):
                    for f in range(nf):
                        off = offsets[lane] + f * nb
                        tb.read_scalar_mem(
                            S1,
                            off,
                            nb,
                            tb.pat.store_elem(f, lane, ieew),
                            f"{prefix}{nf}ei{ieew} l{lane} f{f}",
                        )
    tb.blank()

    # Cross-width indexed segment stores (data SEW != index EEW)
    tb.comment(
        "Cross-width indexed segment stores (vsuxseg2ei8 w/ e32; vsoxseg2ei32 w/ e16)."
    )
    _preload_store_fields(tb, 32)
    tb.load_vec_lanes(16, [128, 16], 8, "m1")
    tb.vsetivli(A2, 2, 32, "m1")
    tb.emit(
        _enc_vmem(True, 2, 1, 1, 16, S1, 8, 8),
        "vsuxseg2ei8.v v8, (s1), v16 [data=e32]",
        [("trap == 0", "xwidth vsuxseg2ei8 e32 retires")],
    )
    for lane in range(2):
        for f in range(2):
            tb.read_scalar_mem(
                S1,
                offsets[lane] + f * 4,
                4,
                tb.pat.store_elem(f, lane, 32),
                f"xwidth vsuxseg2ei8/e32 l{lane} f{f}",
            )

    _preload_store_fields(tb, 16)
    tb.load_vec_lanes(16, [128, 16], 32, "m2")
    tb.vsetivli(A2, 2, 16, "m1")
    tb.emit(
        _enc_vmem(True, 2, 3, 1, 16, S1, 32, 8),
        "vsoxseg2ei32.v v8, (s1), v16 [data=e16]",
        [("trap == 0", "xwidth vsoxseg2ei32 e16 retires")],
    )
    for lane in range(2):
        for f in range(2):
            tb.read_scalar_mem(
                S1,
                offsets[lane] + f * 2,
                2,
                tb.pat.store_elem(f, lane, 16),
                f"xwidth vsoxseg2ei32/e16 l{lane} f{f}",
            )
    tb.blank()

    # Ordered duplicate-index overwrite, masked indexed store, VL == 0, and VLMAX indexed store
    tb.comment(
        "Ordered duplicate-index overwrite, masked vsuxseg2ei32, VL==0 vsuxseg2ei32 and VLMAX vsoxseg2ei32."
    )
    _preload_store_fields(tb, 32)
    tb.load_vec_lanes(16, [0, 0], 32, "m1")
    tb.vsetivli(A2, 2, 32, "m1")
    tb.emit(
        _enc_vmem(True, 3, 3, 1, 16, S1, 32, 8),
        "vsoxseg3ei32.v v8, (s1), v16",
        [("trap == 0", "dup-idx vsoxseg3ei32.v retires")],
    )
    for f in range(3):
        tb.read_scalar_mem(
            S1,
            f * 4,
            4,
            tb.pat.store_elem(f, 1, 32),
            f"dup-idx vsoxseg3ei32 f{f} lane 1 wins",
        )

    tb.load_vec_lanes(16, [128, 16], 32, "m1")
    for off in (128, 132, 16, 20):
        tb.write_scalar_mem(S1, off, 4, SENTINEL_BY_EEW[32])
    tb.load_mask_u32(0, 0b01)
    tb.vsetivli(A2, 2, 32, "m1")
    tb.emit(
        _enc_vmem(True, 2, 1, 0, 16, S1, 32, 8),
        "vsuxseg2ei32.v v8, (s1), v16, v0.t",
        [("trap == 0", "masked vsuxseg2ei32.v retires")],
    )
    tb.read_scalar_mem(
        S1, 128, 4, tb.pat.store_elem(0, 0, 32), "masked vsuxseg2ei32 l0 f0"
    )
    tb.read_scalar_mem(
        S1, 132, 4, tb.pat.store_elem(1, 0, 32), "masked vsuxseg2ei32 l0 f1"
    )
    tb.read_scalar_mem(
        S1, 16, 4, SENTINEL_BY_EEW[32], "masked vsuxseg2ei32 l1 f0 untouched"
    )
    tb.read_scalar_mem(
        S1, 20, 4, SENTINEL_BY_EEW[32], "masked vsuxseg2ei32 l1 f1 untouched"
    )

    tb.write_scalar_mem(S1, 0, 4, SENTINEL_BY_EEW[32])
    tb.vsetivli(A2, 0, 32, "m1")
    tb.emit(
        _enc_vmem(True, 2, 1, 1, 16, S1, 32, 8),
        "vsuxseg2ei32.v v8, (s1), v16 [vl==0]",
        [("trap == 0", "vl==0 vsuxseg2ei32.v retires")],
    )
    tb.read_scalar_mem(
        S1, 0, 4, SENTINEL_BY_EEW[32], "vl==0 vsuxseg2ei32 sentinel untouched"
    )

    tb.vsetvli_vlmax(T0, 32, "mf2")
    tb.vmv_v_i(16, 8)
    tb.load_u32(T1, tb.pat.store_elem(0, 0, 32))
    tb.vmv_v_x(8, T1)
    tb.load_u32(T1, tb.pat.store_elem(1, 0, 32))
    tb.vmv_v_x(9, T1)
    tb.emit(
        _enc_vmem(True, 2, 3, 1, 16, S1, 32, 8),
        "vsoxseg2ei32.v v8, (s1), v16 [VLMAX]",
        [("trap == 0", "vlmax vsoxseg2ei32.v retires")],
    )
    tb.read_scalar_mem(S1, 8, 4, tb.pat.store_elem(0, 0, 32), "vlmax vsoxseg2ei32 f0")
    tb.read_scalar_mem(S1, 12, 4, tb.pat.store_elem(1, 0, 32), "vlmax vsoxseg2ei32 f1")
    tb.blank()

    # Indexed segment store traps
    tb.comment(
        "Indexed segment store illegal traps: nf*EMUL>8 (10, 12), cross-width overlap, masked v0, vill."
    )
    tb.vsetivli(A2, 2, 32, "m2")
    tb.assert_trap(
        _enc_vmem(True, 5, 1, 1, 20, S1, 32, 8),
        "vsuxseg5ei32.v v8, (s1), v20",
        "vsuxseg5ei32 m2 nf*EMUL=10>8",
    )
    tb.vsetivli(A2, 2, 32, "m4")
    tb.assert_trap(
        _enc_vmem(True, 3, 1, 1, 20, S1, 32, 8),
        "vsuxseg3ei32.v v8, (s1), v20",
        "vsuxseg3ei32 m4 nf*EMUL=12>8",
    )
    tb.vsetivli(A2, 2, 32, "m1")
    tb.assert_trap(
        _enc_vmem(True, 2, 1, 1, 9, S1, 8, 8),
        "vsuxseg2ei8.v v8, (s1), v9",
        "vsuxseg2ei8 cross-width vs3[8..9] overlaps vs2=v9",
    )
    tb.assert_trap(
        _enc_vmem(True, 2, 3, 0, 16, S1, 32, 0),
        "vsoxseg2ei32.v v0, (s1), v16, v0.t",
        "vsoxseg2ei32 masked vs3==v0",
    )
    tb.assert_trap(
        _enc_vmem(True, 2, 1, 0, 0, S1, 32, 8),
        "vsuxseg2ei32.v v8, (s1), v0, v0.t",
        "vsuxseg2ei32 masked vs2==v0",
    )
    tb.emit(
        _enc_vsetivli(A2, 1, 0x020),
        "vsetivli a2, 1, 0x20 (vill=1)",
        [("rd_addr == 12", "vill writes a2"), ("rd_wdata == 0x0", "vill vl=0")],
    )
    tb.assert_trap(
        _enc_vmem(True, 2, 3, 1, 16, S1, 32, 8),
        "vsoxseg2ei32.v v8, (s1), v16",
        "vsoxseg2ei32 under vill=1",
    )
    return tb


def _build_fof_trace(patterns: _SeededPatterns) -> _TraceBuilder:
    """Trace 5: All 28 FoF segment loads + elem-0/1/2/mid-seg faults + masked/VL=0/VLMAX + non-FoF vstart + traps."""
    tb = _TraceBuilder(patterns)
    tb.comment(
        "Generated segment fault-only-first trace: all 28 vlseg<2..8>e<8..64>ff.v + vstart + traps."
    )
    tb.preamble(init_src_bytes=64, init_pre_limit_bytes=128)

    # Confirm 0xC0000000 faults on scalar load
    tb.assert_trap(
        _enc_load(A0, S2, 0, 6),
        "lwu a0, 0(s2)",
        "scalar lwu at DDR limit 0xC0000000",
        cause=5,
        tval=DDR_LIMIT,
    )
    tb.blank()

    # Sweep all 28 vlseg<nf>e<eew>ff.v across 0xC0000000:
    # segment 0 lies in [0xC0000000 - seg_bytes, 0xC0000000), segment 1 starts at 0xC0000000
    # -> vl trims 3->1, vstart==0, segment 0 loads all nf fields, segment 1 stays undisturbed.
    tb.comment(
        "All 28 vlseg<nf>e<eew>ff.v trimming vl 3->1 across 0xC0000000 with vstart==0."
    )
    for eew in (8, 16, 32, 64):
        nb = eew // 8
        sent = SENTINEL_BY_EEW[eew]
        for nf in range(2, 9):
            seg_bytes = nf * nb
            pre_off = 128 - seg_bytes
            tb.emit(
                _enc_addi(S4, S2, -seg_bytes),
                f"addi s4, s2, -{seg_bytes}",
            )
            tb.vsetvli_vlmax(T0, eew, "m1")
            tb.load_u64(T1, sent)
            tb.vmv_v_x(8, T1)
            tb.vmv_v_x(8 + nf - 1, T1)
            tb.vsetivli(A2, 3, eew, "m1")
            tb.emit(
                _enc_vmem(False, nf, 0, 1, 0x10, S4, eew, 8),
                f"vlseg{nf}e{eew}ff.v v8, (s4)",
                [("trap == 0", f"vlseg{nf}e{eew}ff.v retires with trim")],
            )
            tb.assert_csr(0xC20, "vl", 1, f"vlseg{nf}e{eew}ff trimmed vl==1")
            tb.assert_csr(0x008, "vstart", 0, f"vlseg{nf}e{eew}ff vstart==0")
            for f in range(nf):
                tb.read_lane(
                    8 + f,
                    0,
                    eew,
                    "m1",
                    tb.pat.src_elem(pre_off + f * nb, nb),
                    f"vlseg{nf}e{eew}ff f{f} lane 0",
                )
            tb.read_lane(
                8, 1, eew, "m1", sent, f"vlseg{nf}e{eew}ff f0 lane 1 undisturbed"
            )
            tb.read_lane(
                8 + nf - 1,
                1,
                eew,
                "m1",
                sent,
                f"vlseg{nf}e{eew}ff f{nf - 1} lane 1 undisturbed",
            )
    tb.blank()

    # Later-element trim at element 2 (vl 4 -> 2): vlseg3e32ff.v at s2 - 24
    # seg 0 = [-24..-12), seg 1 = [-12..0), seg 2 = [0..12) faults -> vl==2, vstart==0.
    tb.comment(
        "Later-element FoF trim at element 2: vlseg3e32ff.v at s2-24 trims vl 4->2."
    )
    tb.emit(_enc_addi(S4, S2, -24), "addi s4, s2, -24")
    tb.vsetvli_vlmax(T0, 32, "m1")
    tb.load_u32(T1, SENTINEL_BY_EEW[32])
    for f in range(3):
        tb.vmv_v_x(8 + f, T1)
    tb.vsetivli(A2, 4, 32, "m1")
    tb.emit(
        _enc_vmem(False, 3, 0, 1, 0x10, S4, 32, 8),
        "vlseg3e32ff.v v8, (s4)",
        [("trap == 0", "elem2 vlseg3e32ff.v retires with trim")],
    )
    tb.assert_csr(0xC20, "vl", 2, "elem2 vlseg3e32ff trimmed vl==2")
    tb.assert_csr(0x008, "vstart", 0, "elem2 vlseg3e32ff vstart==0")
    for lane in range(2):
        for f in range(3):
            tb.read_lane(
                8 + f,
                lane,
                32,
                "m1",
                tb.pat.src_elem(128 - 24 + lane * 12 + f * 4, 4),
                f"elem2 vlseg3e32ff f{f} l{lane}",
            )
    for f in range(3):
        tb.read_lane(
            8 + f,
            2,
            32,
            "m1",
            SENTINEL_BY_EEW[32],
            f"elem2 vlseg3e32ff f{f} l2 undisturbed",
        )

    # Cross-width SEW != EEW FoF (vlseg3e16ff under SEW=32 m2 -> EMUL=m1; vlseg2e64ff under SEW=32 m1 -> EMUL=m2)
    tb.comment(
        "Cross-width SEW != EEW FoF: vlseg3e16ff (sew=e32,m2) and vlseg2e64ff (sew=e32,m1)."
    )
    tb.emit(_enc_addi(S4, S2, -6), "addi s4, s2, -6")
    tb.vsetivli(A2, 3, 32, "m2")
    tb.emit(
        _enc_vmem(False, 3, 0, 1, 0x10, S4, 16, 8),
        "vlseg3e16ff.v v8, (s4) [sew=e32,m2]",
        [("trap == 0", "xwidth vlseg3e16ff.v retires")],
    )
    tb.assert_csr(0xC20, "vl", 1, "xwidth vlseg3e16ff trimmed vl==1")
    for f in range(3):
        tb.read_lane(
            8 + f,
            0,
            16,
            "m1",
            tb.pat.src_elem(128 - 6 + f * 2, 2),
            f"xwidth vlseg3e16ff f{f} l0",
        )

    tb.emit(_enc_addi(S4, S2, -16), "addi s4, s2, -16")
    tb.vsetivli(A2, 3, 32, "m1")
    tb.emit(
        _enc_vmem(False, 2, 0, 1, 0x10, S4, 64, 8),
        "vlseg2e64ff.v v8, (s4) [sew=e32,m1 -> EMUL=m2]",
        [("trap == 0", "xwidth vlseg2e64ff.v retires")],
    )
    tb.assert_csr(0xC20, "vl", 1, "xwidth vlseg2e64ff trimmed vl==1")
    tb.read_lane(
        8, 0, 64, "m2", tb.pat.src_elem(128 - 16, 8), "xwidth vlseg2e64ff f0 l0"
    )
    tb.read_lane(
        10, 0, 64, "m2", tb.pat.src_elem(128 - 8, 8), "xwidth vlseg2e64ff f1 l0"
    )

    # Mid-segment straddling fault on segment 1: vlseg4e32ff.v at s2 - 24
    # seg 0 = [-24..-8) valid, seg 1 = [-8..+8) straddles 0xC0000000 -> vl trims to 1, vstart==0.
    # RVV 1.0 allows pre-fault fields (f0, f1) of the faulting segment to be written or preserved;
    # assert seg 0 (f0..f3), vl==1, vstart==0, and faulting/post-fault fields (f2..f3) of seg 1.
    tb.comment(
        "Mid-segment straddling fault on element 1: vlseg4e32ff.v at 0xC0000000-24 trims vl=1."
    )
    tb.emit(_enc_addi(S4, S2, -24), "addi s4, s2, -24")
    tb.vsetvli_vlmax(T0, 32, "m1")
    tb.load_u32(T1, SENTINEL_BY_EEW[32])
    for f in range(4):
        tb.vmv_v_x(8 + f, T1)
    tb.vsetivli(A2, 3, 32, "m1")
    tb.emit(
        _enc_vmem(False, 4, 0, 1, 0x10, S4, 32, 8),
        "vlseg4e32ff.v v8, (s4)",
        [("trap == 0", "mid-seg straddling vlseg4e32ff.v retires")],
    )
    tb.assert_csr(0xC20, "vl", 1, "mid-seg vlseg4e32ff trimmed vl==1")
    tb.assert_csr(0x008, "vstart", 0, "mid-seg vlseg4e32ff vstart==0")
    for f in range(4):
        tb.read_lane(
            8 + f, 0, 32, "m1", tb.pat.src_elem(128 - 24 + f * 4, 4), f"mid-seg f{f} l0"
        )
    for f in (2, 3):
        tb.read_lane(
            8 + f,
            1,
            32,
            "m1",
            SENTINEL_BY_EEW[32],
            f"mid-seg f{f} l1 post-fault undisturbed",
        )

    # Masked-off faulting element 1 (tu, mu) preserves vl == 2, inactive lane 1 and tail lane 2
    tb.comment(
        "Masked FoF: masked-off faulting elem 1 (tu,mu) preserves vl==2; active masked (ta,ma) trims vl==1."
    )
    tb.emit(_enc_addi(S4, S2, -8), "addi s4, s2, -8")
    for f in range(2):
        tb.load_vec_lanes(8 + f, [0x1111_0001, 0x2222_0002, 0x3333_0003], 32, "m1")
    tb.load_mask_u32(0, 0b01)  # lane 0 active, faulting lane 1 masked off, lane 2 tail
    tb.vsetivli(A2, 2, 32, "m1", ta=False, ma=False)
    tb.emit(
        _enc_vmem(False, 2, 0, 0, 0x10, S4, 32, 8),
        "vlseg2e32ff.v v8, (s4), v0.t [tu,mu]",
        [("trap == 0", "masked-off faulting vlseg2e32ff.v retires")],
    )
    tb.assert_csr(0xC20, "vl", 2, "masked-off vlseg2e32ff preserves vl==2")
    tb.assert_csr(0x008, "vstart", 0, "masked-off vlseg2e32ff vstart==0")
    for f in range(2):
        tb.read_lane(
            8 + f,
            0,
            32,
            "m1",
            tb.pat.src_elem(128 - 8 + f * 4, 4),
            f"masked fof f{f} l0",
        )
        tb.read_lane(8 + f, 1, 32, "m1", 0x2222_0002, f"masked fof f{f} l1 mu")
        tb.read_lane(8 + f, 2, 32, "m1", 0x3333_0003, f"masked fof f{f} l2 tu")

    tb.load_mask_u32(
        0, 0b11
    )  # lanes 0 and 1 active -> elem 1 faults -> trims vl==1 under ta,ma
    tb.vsetivli(A2, 3, 32, "m1", ta=True, ma=True)
    tb.emit(
        _enc_vmem(False, 2, 0, 0, 0x10, S4, 32, 8),
        "vlseg2e32ff.v v8, (s4), v0.t [ta,ma]",
        [("trap == 0", "masked ta,ma vlseg2e32ff.v retires with trim")],
    )
    tb.assert_csr(0xC20, "vl", 1, "masked ta,ma vlseg2e32ff trimmed vl==1")
    tb.assert_csr(0x008, "vstart", 0, "masked ta,ma vlseg2e32ff vstart==0")

    # VL == 0 FoF at faulting DDR_LIMIT must retire without trapping, and VLMAX FoF trims to 1
    tb.comment(
        "VL==0 FoF at 0xC0000000 does not trap; VLMAX FoF at s2-8 trims VLMAX->1."
    )
    tb.vsetivli(A2, 2, 32, "m1")
    tb.load_u32(T1, SENTINEL_BY_EEW[32])
    tb.vmv_v_x(8, T1)
    tb.vmv_v_x(9, T1)
    tb.vsetivli(A2, 0, 32, "m1")
    tb.emit(
        _enc_vmem(False, 2, 0, 1, 0x10, S2, 32, 8),
        "vlseg2e32ff.v v8, (s2) [vl==0]",
        [("trap == 0", "vl==0 vlseg2e32ff.v at 0xC0000000 retires")],
    )
    tb.assert_csr(0xC20, "vl", 0, "vl==0 vlseg2e32ff vl==0")
    tb.assert_csr(0x008, "vstart", 0, "vl==0 vlseg2e32ff vstart==0")
    tb.read_lane(
        8, 0, 32, "m1", SENTINEL_BY_EEW[32], "vl==0 vlseg2e32ff f0 undisturbed"
    )

    tb.emit(_enc_addi(S4, S2, -8), "addi s4, s2, -8")
    tb.vsetvli_vlmax(T0, 32, "mf2")  # VLMAX = 2/4/8 >= 2 across VLEN 128/256/512
    tb.emit(
        _enc_vmem(False, 2, 0, 1, 0x10, S4, 32, 8),
        "vlseg2e32ff.v v8, (s4) [VLMAX]",
        [("trap == 0", "vlmax vlseg2e32ff.v retires with trim")],
    )
    tb.assert_csr(0xC20, "vl", 1, "vlmax vlseg2e32ff trimmed vl==1")
    tb.assert_csr(0x008, "vstart", 0, "vlmax vlseg2e32ff vstart==0")

    # Element-0 full fault on vlseg3e32ff.v at 0xC0000000 traps with mcause=5, mtval=0xC0000000, vl unchanged
    tb.comment(
        "Element-0 full fault and element-0 mid-segment straddling fault trap with vl unchanged and vstart==0."
    )
    tb.vsetvli_vlmax(T0, 32, "m1")
    tb.load_u32(T1, SENTINEL_BY_EEW[32])
    for f in range(3):
        tb.vmv_v_x(8 + f, T1)
    tb.vsetivli(A2, 3, 32, "m1")
    tb.assert_trap(
        _enc_vmem(False, 3, 0, 1, 0x10, S2, 32, 8),
        "vlseg3e32ff.v v8, (s2)",
        "elem0 vlseg3e32ff access fault",
        cause=5,
        tval=DDR_LIMIT,
    )
    tb.assert_csr(0xC20, "vl", 3, "elem0 vlseg3e32ff vl unchanged==3")
    tb.assert_csr(0x008, "vstart", 0, "elem0 vlseg3e32ff vstart==0")
    for f in range(3):
        tb.read_lane(
            8 + f,
            0,
            32,
            "m1",
            SENTINEL_BY_EEW[32],
            f"elem0 fault vlseg3e32ff f{f} undisturbed",
        )

    # Element-0 mid-segment straddling fault: vlseg4e32ff.v at s2 - 8 (f0, f1 valid; f2 hits 0xC0000000 -> MUST trap!)
    tb.emit(_enc_addi(S4, S2, -8), "addi s4, s2, -8")
    tb.vsetivli(A2, 3, 32, "m1")
    tb.assert_trap(
        _enc_vmem(False, 4, 0, 1, 0x10, S4, 32, 8),
        "vlseg4e32ff.v v8, (s4)",
        "elem0 mid-seg vlseg4e32ff access fault",
        cause=5,
        tval=DDR_LIMIT,
    )
    tb.assert_csr(0xC20, "vl", 3, "elem0 mid-seg vlseg4e32ff vl unchanged==3")
    tb.assert_csr(0x008, "vstart", 0, "elem0 mid-seg vlseg4e32ff vstart==0")

    # Non-FoF segment fault on element 1 reports vstart==1 and resumes cleanly from vstart==1
    tb.comment(
        "Non-FoF vlseg2e32.v fault on element 1 traps with vstart==1, then resumes from s0."
    )
    tb.emit(_enc_addi(S4, S2, -8), "addi s4, s2, -8")
    tb.vsetvli_vlmax(T0, 32, "m1")
    tb.load_u32(T1, SENTINEL_BY_EEW[32])
    tb.vmv_v_x(8, T1)
    tb.vmv_v_x(9, T1)
    tb.vsetivli(A2, 2, 32, "m1")
    tb.assert_trap(
        _enc_vmem(False, 2, 0, 1, 0, S4, 32, 8),
        "vlseg2e32.v v8, (s4)",
        "non-FoF vlseg2e32 elem1 access fault",
        cause=5,
        tval=DDR_LIMIT,
    )
    tb.assert_csr(0x008, "vstart", 1, "non-FoF vlseg2e32 fault vstart==1")
    tb.emit(
        _enc_vmem(False, 2, 0, 1, 0, S0, 32, 8),
        "vlseg2e32.v v8, (s0)",
        [("trap == 0", "non-FoF vlseg2e32 resume from vstart==1 retires")],
    )
    tb.assert_csr(0x008, "vstart", 0, "non-FoF vlseg2e32 resume clears vstart==0")
    tb.read_lane(
        8, 0, 32, "m1", tb.pat.src_elem(120, 4), "vlseg2e32 pre-fault f0 l0 preserved"
    )
    tb.read_lane(
        9, 0, 32, "m1", tb.pat.src_elem(124, 4), "vlseg2e32 pre-fault f1 l0 preserved"
    )
    tb.read_lane(
        8, 1, 32, "m1", tb.pat.src_elem(8, 4), "vlseg2e32 resumed f0 l1 from s0"
    )
    tb.read_lane(
        9, 1, 32, "m1", tb.pat.src_elem(12, 4), "vlseg2e32 resumed f1 l1 from s0"
    )
    tb.blank()

    # Non-FoF strided segment load/store fault on segment 1 -> vstart==1 -> resume.
    tb.comment(
        "Non-FoF vlsseg2e32/vssseg2e32 and vluxseg2e32/vsoxseg2e32 fault on seg 1 -> vstart==1 -> resume, plus FoF resume at vstart==1."
    )
    tb.emit(_enc_addi(S4, S2, -16), "addi s4, s2, -16")
    tb.emit(_enc_addi(T0, ZERO, 16), "addi t0, zero, 16")
    tb.vsetvli_vlmax(T2, 32, "m1")
    tb.load_u32(T1, SENTINEL_BY_EEW[32])
    tb.vmv_v_x(8, T1)
    tb.vmv_v_x(9, T1)
    tb.vsetivli(A2, 2, 32, "m1")
    tb.assert_trap(
        _enc_vmem(False, 2, 2, 1, T0, S4, 32, 8),
        "vlsseg2e32.v v8, (s4), t0",
        "non-FoF vlsseg2e32 elem1 access fault",
        cause=5,
        tval=DDR_LIMIT,
    )
    tb.assert_csr(0x008, "vstart", 1, "vlsseg2e32 fault vstart==1")
    tb.emit(
        _enc_vmem(False, 2, 2, 1, T0, S0, 32, 8),
        "vlsseg2e32.v v8, (s0), t0",
        [("trap == 0", "vlsseg2e32 resume from vstart==1 retires")],
    )
    tb.assert_csr(0x008, "vstart", 0, "vlsseg2e32 resume clears vstart==0")
    tb.read_lane(
        8, 0, 32, "m1", tb.pat.src_elem(112, 4), "vlsseg2e32 prestart f0 l0 preserved"
    )
    tb.read_lane(
        9, 0, 32, "m1", tb.pat.src_elem(116, 4), "vlsseg2e32 prestart f1 l0 preserved"
    )
    tb.read_lane(
        8, 1, 32, "m1", tb.pat.src_elem(16, 4), "vlsseg2e32 resumed f0 l1 from s0"
    )
    tb.read_lane(
        9, 1, 32, "m1", tb.pat.src_elem(20, 4), "vlsseg2e32 resumed f1 l1 from s0"
    )

    # Indexed segment load fault on seg 1 -> vstart==1 -> resume (before stores overwrite s4).
    tb.load_vec_lanes(16, [0, 16], 32, "m1")
    tb.vsetvli_vlmax(T2, 32, "m1")
    tb.load_u32(T1, SENTINEL_BY_EEW[32])
    tb.vmv_v_x(8, T1)
    tb.vmv_v_x(9, T1)
    tb.vsetivli(A2, 2, 32, "m1")
    tb.assert_trap(
        _enc_vmem(False, 2, 1, 1, 16, S4, 32, 8),
        "vluxseg2e32.v v8, (s4), v16",
        "non-FoF vluxseg2e32 elem1 access fault",
        cause=5,
        tval=DDR_LIMIT,
    )
    tb.assert_csr(0x008, "vstart", 1, "vluxseg2e32 fault vstart==1")
    tb.emit(
        _enc_vmem(False, 2, 1, 1, 16, S0, 32, 8),
        "vluxseg2e32.v v8, (s0), v16",
        [("trap == 0", "vluxseg2e32 resume from vstart==1 retires")],
    )
    tb.assert_csr(0x008, "vstart", 0, "vluxseg2e32 resume clears vstart==0")
    tb.read_lane(
        8, 0, 32, "m1", tb.pat.src_elem(112, 4), "vluxseg2e32 prestart f0 l0 preserved"
    )
    tb.read_lane(
        9, 0, 32, "m1", tb.pat.src_elem(116, 4), "vluxseg2e32 prestart f1 l0 preserved"
    )
    tb.read_lane(
        8, 1, 32, "m1", tb.pat.src_elem(16, 4), "vluxseg2e32 resumed f0 l1 from s0"
    )
    tb.read_lane(
        9, 1, 32, "m1", tb.pat.src_elem(20, 4), "vluxseg2e32 resumed f1 l1 from s0"
    )

    # Strided segment store resumed from vstart==1 (established by a faulting
    # segment load) preserves seg 0 sentinel and writes seg 1.
    _preload_store_fields(tb, 32)
    for off in (0, 4, 16, 20):
        tb.write_scalar_mem(S1, off, 4, SENTINEL_BY_EEW[32])
    tb.vsetivli(A2, 2, 32, "m1")
    tb.assert_trap(
        _enc_vmem(False, 2, 2, 1, T0, S4, 32, 12),
        "vlsseg2e32.v v12, (s4), t0",
        "setup vstart==1 before vssseg2e32 resume",
        cause=5,
        tval=DDR_LIMIT,
    )
    tb.assert_csr(0x008, "vstart", 1, "vssseg2e32 setup vstart==1")
    tb.emit(
        _enc_vmem(True, 2, 2, 1, T0, S1, 32, 8),
        "vssseg2e32.v v8, (s1), t0",
        [("trap == 0", "vssseg2e32 resume from vstart==1 retires")],
    )
    tb.read_scalar_mem(
        S1, 0, 4, SENTINEL_BY_EEW[32], "vssseg2e32 prestart seg0 f0 undisturbed"
    )
    tb.read_scalar_mem(
        S1, 4, 4, SENTINEL_BY_EEW[32], "vssseg2e32 prestart seg0 f1 undisturbed"
    )
    tb.read_scalar_mem(
        S1, 16, 4, tb.pat.store_elem(0, 1, 32), "vssseg2e32 resumed seg1 f0"
    )
    tb.read_scalar_mem(
        S1, 20, 4, tb.pat.store_elem(1, 1, 32), "vssseg2e32 resumed seg1 f1"
    )
    tb.assert_csr(0x008, "vstart", 0, "vssseg2e32 resume clears vstart==0")

    _preload_store_fields(tb, 32)
    for off in (0, 4, 16, 20):
        tb.write_scalar_mem(S1, off, 4, SENTINEL_BY_EEW[32])
    tb.vsetivli(A2, 2, 32, "m1")
    tb.assert_trap(
        _enc_vmem(False, 2, 1, 1, 16, S4, 32, 12),
        "vluxseg2e32.v v12, (s4), v16",
        "setup vstart==1 before vsoxseg2e32 resume",
        cause=5,
        tval=DDR_LIMIT,
    )
    tb.assert_csr(0x008, "vstart", 1, "vsoxseg2e32 setup vstart==1")
    tb.emit(
        _enc_vmem(True, 2, 3, 1, 16, S1, 32, 8),
        "vsoxseg2e32.v v8, (s1), v16",
        [("trap == 0", "vsoxseg2e32 resume from vstart==1 retires")],
    )
    tb.read_scalar_mem(
        S1, 0, 4, SENTINEL_BY_EEW[32], "vsoxseg2e32 prestart seg0 f0 undisturbed"
    )
    tb.read_scalar_mem(
        S1, 4, 4, SENTINEL_BY_EEW[32], "vsoxseg2e32 prestart seg0 f1 undisturbed"
    )
    tb.read_scalar_mem(
        S1, 16, 4, tb.pat.store_elem(0, 1, 32), "vsoxseg2e32 resumed seg1 f0"
    )
    tb.read_scalar_mem(
        S1, 20, 4, tb.pat.store_elem(1, 1, 32), "vsoxseg2e32 resumed seg1 f1"
    )
    tb.assert_csr(0x008, "vstart", 0, "vsoxseg2e32 resume clears vstart==0")

    # FoF segment load entered with vstart==1 faulting immediately on seg 1 trims vl==1 without trapping.
    tb.emit(_enc_addi(S4, S2, -8), "addi s4, s2, -8")
    tb.vsetvli_vlmax(T2, 32, "m1")
    tb.load_u32(T1, SENTINEL_BY_EEW[32])
    tb.vmv_v_x(8, T1)
    tb.vmv_v_x(9, T1)
    tb.vsetivli(A2, 2, 32, "m1")
    tb.assert_trap(
        _enc_vmem(False, 2, 0, 1, 0, S4, 32, 8),
        "vlseg2e32.v v8, (s4)",
        "setup vstart==1 for FoF resume",
        cause=5,
        tval=DDR_LIMIT,
    )
    tb.assert_csr(0x008, "vstart", 1, "setup vstart==1 before vlseg2e32ff")
    tb.emit(
        _enc_vmem(False, 2, 0, 1, 0x10, S4, 32, 8),
        "vlseg2e32ff.v v8, (s4)",
        [
            (
                "trap == 0",
                "vlseg2e32ff at vstart==1 faults on seg 1 and trims without trap",
            )
        ],
    )
    tb.assert_csr(0xC20, "vl", 1, "vlseg2e32ff at vstart==1 trims vl==1")
    tb.assert_csr(0x008, "vstart", 0, "vlseg2e32ff at vstart==1 clears vstart==0")
    tb.read_lane(
        8, 0, 32, "m1", tb.pat.src_elem(120, 4), "vlseg2e32ff prestart f0 l0 preserved"
    )
    tb.read_lane(
        9, 0, 32, "m1", tb.pat.src_elem(124, 4), "vlseg2e32ff prestart f1 l0 preserved"
    )
    tb.read_lane(
        8, 1, 32, "m1", SENTINEL_BY_EEW[32], "vlseg2e32ff faulting f0 l1 undisturbed"
    )
    tb.read_lane(
        9, 1, 32, "m1", SENTINEL_BY_EEW[32], "vlseg2e32ff faulting f1 l1 undisturbed"
    )
    tb.blank()

    # FoF segment illegal traps: nf*EMUL>8 (10, 12), vd+nf*EMUL>32, masked vd==v0, align, vill
    tb.comment(
        "FoF segment illegal traps: nf*EMUL>8 (10, 12), vd+nf*EMUL>32, masked v0, align, vill."
    )
    tb.vsetivli(A2, 2, 32, "m4")
    tb.assert_trap(
        _enc_vmem(False, 3, 0, 1, 0x10, S0, 32, 8),
        "vlseg3e32ff.v v8, (s0)",
        "vlseg3e32ff m4 nf*EMUL=12>8",
    )
    tb.vsetivli(A2, 2, 32, "m2")
    tb.assert_trap(
        _enc_vmem(False, 5, 0, 1, 0x10, S0, 32, 8),
        "vlseg5e32ff.v v8, (s0)",
        "vlseg5e32ff m2 nf*EMUL=10>8",
    )
    tb.assert_trap(
        _enc_vmem(False, 2, 0, 1, 0x10, S0, 32, 9),
        "vlseg2e32ff.v v9, (s0)",
        "vlseg2e32ff m2 misaligned vd",
    )
    tb.vsetivli(A2, 2, 32, "m1")
    tb.assert_trap(
        _enc_vmem(False, 5, 0, 1, 0x10, S0, 32, 28),
        "vlseg5e32ff.v v28, (s0)",
        "vlseg5e32ff m1 vd+nf=33>32",
    )
    tb.assert_trap(
        _enc_vmem(False, 2, 0, 0, 0x10, S0, 32, 0),
        "vlseg2e32ff.v v0, (s0), v0.t",
        "vlseg2e32ff masked vd==v0",
    )
    tb.emit(
        _enc_vsetivli(A2, 1, 0x020),
        "vsetivli a2, 1, 0x20 (vill=1)",
        [("rd_addr == 12", "vill writes a2"), ("rd_wdata == 0x0", "vill vl=0")],
    )
    tb.assert_trap(
        _enc_vmem(False, 2, 0, 1, 0x10, S0, 32, 8),
        "vlseg2e32ff.v v8, (s0)",
        "vlseg2e32ff under vill=1",
    )
    return tb


_BUILDERS = (
    ("01_segment_unit_stride.S", _build_unit_stride_trace),
    ("02_segment_strided.S", _build_strided_trace),
    ("03_segment_indexed_load.S", _build_indexed_load_trace),
    ("04_segment_indexed_store.S", _build_indexed_store_trace),
    ("05_segment_fof.S", _build_fof_trace),
)


def write_traces(directory: Path, *, seed: int = DEFAULT_SEED) -> list[Path]:
    """Write all five seeded deterministic segment traces into `directory`."""
    directory.mkdir(parents=True, exist_ok=True)
    patterns = _SeededPatterns(seed)
    paths: list[Path] = []
    for name, builder_fn in _BUILDERS:
        tb = builder_fn(patterns)
        path = directory / name
        path.write_text("\n".join(tb.lines) + "\n", encoding="utf-8")
        paths.append(path)
    return paths


def trace_digests(*, seed: int = DEFAULT_SEED) -> dict[str, str]:
    """Return {filename: sha256_hex} for all five generated segment traces."""
    patterns = _SeededPatterns(seed)
    digests: dict[str, str] = {}
    for name, builder_fn in _BUILDERS:
        tb = builder_fn(patterns)
        raw = ("\n".join(tb.lines) + "\n").encode("utf-8")
        digests[name] = hashlib.sha256(raw).hexdigest()
    return digests


def trace_stats(
    *, seed: int = DEFAULT_SEED
) -> dict[str, tuple[int, int, int | None, int | None]]:
    """Return {filename: (insn_count, assert_count, ctrl_order, ctrl_expected)}."""
    patterns = _SeededPatterns(seed)
    stats: dict[str, tuple[int, int, int | None, int | None]] = {}
    for name, builder_fn in _BUILDERS:
        tb = builder_fn(patterns)
        stats[name] = (
            tb.insn_count,
            tb.assert_count,
            tb.ctrl_order,
            tb.ctrl_expected,
        )
    return stats
