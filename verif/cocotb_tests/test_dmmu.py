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

"""Data-MMU checks through its issue, walker, early-store, and registered result ports.

The reference resolves Sv39 leaves, the PMA map (the device windows take loads
and stores but no atomics), and the architectural fault priorities in Python.
Protocol checks cover one-cycle resident DTLB hits, the two-stage fallback,
one-result-per-cycle hit throughput, LQ look-ahead, miss skid, and recovery
without inspecting internal RTL.
"""

from dataclasses import dataclass, replace
import os
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_tests.cpu_structs import PTW_RESP_FIELDS, TLB_FLUSH_FIELDS
from utils.packed_structs import assert_port_width, pack_struct


NONE, MISALIGN, PAGE, ACCESS = range(4)
VPN_MASK = (1 << 27) - 1
XLEN_MASK = (1 << 64) - 1
FLUSH_ALL = pack_struct(TLB_FLUSH_FIELDS, {"en": 1})
DDR_CAPACITY_LOG2_BYTES = int(os.environ.get("FROST_DDR_CAPACITY_LOG2_BYTES", "30"))
DDR_LIMIT = 0x8000_0000 + (1 << DDR_CAPACITY_LOG2_BYTES)
# riscv_pkg "Svpbmt": the uncached alias of DDR sets one bit above it.
ALIAS_BIT = 30 if DDR_CAPACITY_LOG2_BYTES <= 30 else DDR_CAPACITY_LOG2_BYTES
ALIAS_OFFSET = 1 << ALIAS_BIT
ALIAS_COVER_LIMIT = (
    DDR_LIMIT if DDR_CAPACITY_LOG2_BYTES <= 30 else 1 << DDR_CAPACITY_LOG2_BYTES
)


@dataclass(frozen=True)
class Leaf:
    """Walk response payload, including refused walks."""

    vpn: int
    ppn: int = 0x80000
    level: int = 0
    r: int = 1
    w: int = 1
    x: int = 0
    u: int = 0
    d: int = 1
    g: int = 0
    fault: int = NONE
    pbmt: int = 0  # Svpbmt field: 0 PMA, 1 NC, 2 IO

    def packed(self) -> int:
        """Pack the leaf as a riscv_pkg::ptw_resp_t."""
        return pack_struct(
            PTW_RESP_FIELDS,
            {
                "pbmt": self.pbmt,
                "fault_kind": self.fault,
                "vpn": self.vpn,
                "ppn": self.ppn,
                "level": self.level,
                "perm_r": self.r,
                "perm_w": self.w,
                "perm_x": self.x,
                "perm_u": self.u,
                "perm_d": self.d,
                "perm_g": self.g,
            },
        )


@dataclass(frozen=True)
class Op:
    """One issued memory operation and its permission controls."""

    va: int = 0x0040_0120
    tag: int = 3
    size: int = 3
    needs_sq: int = 0
    store: int = 0
    is_sc: int = 0
    is_cmo: int = 0
    atomic: int = 0
    data: int = 0xFEDC_BA98_7654_3210
    amo_rs2: int = 0x1234_5678_9ABC_DEF0
    priv_u: int = 0
    sum_: int = 0
    mxr: int = 0
    trap_misaligned: int = 1
    offset: int = 0


def _alias_ok(pa: int) -> bool:
    """Return whether a PA is in the Svpbmt uncached alias of DDR."""
    real = pa & ~ALIAS_OFFSET
    return bool(pa & ALIAS_OFFSET) and 0x8000_0000 <= real < ALIAS_COVER_LIMIT


def _device_ok(pa: int) -> bool:
    """Return whether a PA is in the MMIO, APLIC, or IMSIC device windows."""
    return (
        0x4000_0000 <= pa < 0x4003_1000
        or 0x4400_0000 <= pa < 0x4440_0000
        or 0x4800_0000 <= pa < 0x4820_0000
    )


def _expected(op: Op, leaf: Leaf) -> tuple[int, int, int]:
    """Return architectural address, fault, and MMIO classification."""
    va = op.va & XLEN_MASK
    if op.trap_misaligned and va % (1 << op.size):
        return va, MISALIGN, 0
    canonical = va < (1 << 38) or va >= (1 << 64) - (1 << 38)
    if not canonical:
        return va, PAGE, 0
    if leaf.fault and not (leaf.fault == ACCESS and leaf.pbmt):
        return va, leaf.fault, 0
    priv_ok = bool(op.priv_u or op.sum_) if leaf.u else not op.priv_u
    access_ok = (
        bool(leaf.w and leaf.d) if op.store else bool(leaf.r or (op.mxr and leaf.x))
    )
    if not priv_ok or not access_ok:
        return va, PAGE, 0
    if leaf.fault:
        return va, leaf.fault, 0
    offset_bits = 12 + 9 * leaf.level
    pa = ((leaf.ppn << 12) & ~((1 << offset_bits) - 1)) | (
        va & ((1 << offset_bits) - 1)
    )
    memory = pa < 0x40000 or 0x8000_0000 <= pa < DDR_LIMIT
    # Svpbmt: NC or IO over low BRAM, or over the uncached alias of DDR the
    # walker gives NC and IO leaves, is a device page without atomics. The
    # alias is outside the PMA map, so a PMA leaf there is an access fault.
    device = _device_ok(pa) or (leaf.pbmt != 0 and (memory or _alias_ok(pa)))
    mapped = (memory and not leaf.pbmt) or (not op.atomic and device)
    if not mapped:
        return va, ACCESS, 0
    return pa, NONE, int(device)


async def _cycle(dut: Any) -> None:
    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")


async def _setup(dut: Any) -> None:
    assert_port_width(dut.i_walk_resp, PTW_RESP_FIELDS)
    assert_port_width(dut.i_tlb_flush, TLB_FLUSH_FIELDS)
    Clock(dut.i_clk, 10, unit="ns").start()
    for name in (
        "i_rst_n",
        "i_sum",
        "i_mxr",
        "i_eff_priv_u",
        "i_tlb_invalidate",
        "i_tlb_flush",
        "i_asid",
        "i_flush_all",
        "i_flush_en",
        "i_flush_tag",
        "i_head_tag",
        "i_iss_valid",
        "i_iss_rob_tag",
        "i_iss_base",
        "i_iss_offset",
        "i_iss_size",
        "i_iss_needs_sq",
        "i_iss_store_perms",
        "i_iss_is_sc",
        "i_iss_is_cmo",
        "i_iss_atomic",
        "i_iss_store_data",
        "i_iss_amo_rs2",
        "i_early_valid",
        "i_early_va",
        "i_early2_valid",
        "i_early2_va",
        "i_walk_resp_valid",
        "i_walk_resp",
    ):
        getattr(dut, name).value = 0
    dut.i_active.value = 1
    dut.i_trap_misaligned.value = 1
    dut.i_walk_req_ready.value = 1
    await _cycle(dut)
    await _cycle(dut)
    dut.i_rst_n.value = 1


async def _clear(dut: Any) -> None:
    dut.i_iss_valid.value = 0
    dut.i_walk_resp_valid.value = 0
    dut.i_flush_all.value = 1
    dut.i_tlb_invalidate.value = 1
    dut.i_tlb_flush.value = FLUSH_ALL
    await _cycle(dut)
    dut.i_flush_all.value = 0
    dut.i_tlb_invalidate.value = 0
    dut.i_tlb_flush.value = 0


def _response(dut: Any, leaf: Leaf) -> None:
    dut.i_walk_resp_valid.value = 1
    dut.i_walk_resp.value = leaf.packed()


async def _install(dut: Any, leaf: Leaf) -> None:
    _response(dut, leaf)
    await _cycle(dut)
    dut.i_walk_resp_valid.value = 0


def _drive_address(dut: Any, op: Op) -> None:
    dut.i_iss_base.value = (op.va - op.offset) & XLEN_MASK
    dut.i_iss_offset.value = op.offset & XLEN_MASK


def _issue(dut: Any, op: Op) -> None:
    dut.i_iss_valid.value = 1
    _drive_address(dut, op)
    dut.i_iss_rob_tag.value = op.tag
    dut.i_iss_size.value = op.size
    dut.i_iss_needs_sq.value = op.needs_sq
    dut.i_iss_store_perms.value = op.store
    dut.i_iss_is_sc.value = op.is_sc
    dut.i_iss_is_cmo.value = op.is_cmo
    dut.i_iss_atomic.value = op.atomic
    dut.i_iss_store_data.value = op.data
    dut.i_iss_amo_rs2.value = op.amo_rs2
    dut.i_eff_priv_u.value = op.priv_u
    dut.i_sum.value = op.sum_
    dut.i_mxr.value = op.mxr
    dut.i_trap_misaligned.value = op.trap_misaligned


def _present_payload(dut: Any, op: Op) -> None:
    """Drive op's issue payload with valid low, as a held MEM_RS may present."""
    dut.i_iss_valid.value = 0
    _drive_address(dut, op)
    dut.i_iss_rob_tag.value = op.tag
    dut.i_iss_size.value = op.size
    dut.i_iss_needs_sq.value = op.needs_sq
    dut.i_iss_store_perms.value = op.store
    dut.i_iss_is_sc.value = op.is_sc
    dut.i_iss_is_cmo.value = op.is_cmo
    dut.i_iss_atomic.value = op.atomic
    dut.i_iss_store_data.value = op.data
    dut.i_iss_amo_rs2.value = op.amo_rs2


def _check(dut: Any, op: Op, leaf: Leaf) -> None:
    expected_addr, expected_fault, expected_mmio = _expected(op, leaf)
    outputs = {
        "o_iss_out_valid": 1,
        "o_iss_out_rob_tag": op.tag,
        "o_iss_out_addr": expected_addr,
        "o_iss_out_fault": expected_fault,
        "o_iss_out_is_mmio": expected_mmio,
        "o_iss_out_needs_sq": op.needs_sq,
        "o_iss_out_is_sc": op.is_sc,
        "o_iss_out_is_cmo": op.is_cmo,
        "o_iss_out_store_data": op.data,
        "o_iss_out_amo_rs2": op.amo_rs2,
        "o_iss_out_lq_capture_valid": 1 - op.needs_sq,
        "o_iss_out_sq_capture_valid": op.needs_sq,
    }
    for name, expected in outputs.items():
        actual = int(getattr(dut, name).value)
        assert actual == expected, (
            f"{name}: got 0x{actual:x}, expected 0x{expected:x}; {op=}, {leaf=}"
        )


@cocotb.test()
async def test_hit_and_walk_resolution_matrix(dut: Any) -> None:
    """DTLB hits and walk responses match the reference fault, address, and MMIO.

    The reference applies the architectural fault priority, and a faulting op
    must return its full VA (for xtval) in place of the PA. The device cases
    cover each window edge, atomics (LR, AMO, SC) onto the windows, and 2 MiB
    and 1 GiB leaves whose VA offset lands inside or outside a window.
    """
    await _setup(dut)
    base_op = Op()
    base_leaf = Leaf(vpn=base_op.va >> 12)
    cases = [
        (base_op, base_leaf),
        (replace(base_op, needs_sq=1, store=1, is_sc=1), base_leaf),
        (base_op, replace(base_leaf, ppn=0x40000)),
        (base_op, replace(base_leaf, ppn=0x3F)),
        (base_op, replace(base_leaf, ppn=0x40)),
        (base_op, replace(base_leaf, ppn=0xC0000)),
        (base_op, replace(base_leaf, ppn=(1 << 20) | 0x80000)),
        (base_op, replace(base_leaf, ppn=(DDR_LIMIT - 0x1000) >> 12)),
        (base_op, replace(base_leaf, ppn=DDR_LIMIT >> 12)),
        (base_op, replace(base_leaf, ppn=0xC0000, r=0)),
        (replace(base_op, store=1), replace(base_leaf, d=0)),
        (replace(base_op, store=1), replace(base_leaf, w=0)),
        (base_op, replace(base_leaf, r=0, x=1)),
        (replace(base_op, mxr=1), replace(base_leaf, r=0, x=1)),
        (base_op, replace(base_leaf, u=1)),
        (replace(base_op, sum_=1), replace(base_leaf, u=1)),
        (replace(base_op, priv_u=1), replace(base_leaf, u=1)),
        (replace(base_op, priv_u=1, sum_=1), base_leaf),
        (replace(base_op, va=(1 << 39) | 0x123), replace(base_leaf, r=0)),
        (replace(base_op, va=(1 << 39) | 0x120), base_leaf),
        (replace(base_op, va=0xFFFF_FFC0_0040_0120), replace(base_leaf, r=0)),
        (replace(base_op, va=0xFFFF_FFC0_0040_0120), base_leaf),
        (replace(base_op, va=base_op.va + 1, trap_misaligned=0), base_leaf),
        (replace(base_op, va=0x0123_4568), replace(base_leaf, level=1, ppn=0x80200)),
        (replace(base_op, va=0x1234_5678), replace(base_leaf, level=2)),
        # Device windows: loads and stores only, whole pages.
        (base_op, replace(base_leaf, ppn=0x3FFFF)),
        (base_op, replace(base_leaf, ppn=0x40030)),
        (base_op, replace(base_leaf, ppn=0x40031)),
        (base_op, replace(base_leaf, ppn=0x43FFF)),
        (base_op, replace(base_leaf, ppn=0x44000)),
        (base_op, replace(base_leaf, ppn=0x443FF)),
        (base_op, replace(base_leaf, ppn=0x44400)),
        (base_op, replace(base_leaf, ppn=0x47FFF)),
        (base_op, replace(base_leaf, ppn=0x48000)),
        (base_op, replace(base_leaf, ppn=0x480FF)),
        (base_op, replace(base_leaf, ppn=0x48100)),
        (base_op, replace(base_leaf, ppn=0x481FF)),
        (base_op, replace(base_leaf, ppn=0x48200)),
        (replace(base_op, needs_sq=1, store=1), replace(base_leaf, ppn=0x48000)),
        (replace(base_op, needs_sq=1, store=1), replace(base_leaf, ppn=0x481FF)),
        (replace(base_op, needs_sq=1, store=1), replace(base_leaf, ppn=0x7FFFF)),
        # At the same unmapped PA, denied writes take a page fault and a
        # misaligned VA traps before either the permission or the PMA check.
        (replace(base_op, needs_sq=1, store=1), replace(base_leaf, ppn=0x40031, w=0)),
        (
            replace(base_op, needs_sq=1, store=1, va=base_op.va + 1),
            replace(base_leaf, ppn=0x40031, w=0),
        ),
        (replace(base_op, atomic=1), replace(base_leaf, ppn=0x40000)),
        (replace(base_op, store=1, atomic=1), replace(base_leaf, ppn=0x44000)),
        (replace(base_op, atomic=1), replace(base_leaf, ppn=0x48000)),
        (replace(base_op, store=1, atomic=1), replace(base_leaf, ppn=0x48100)),
        (
            replace(base_op, needs_sq=1, store=1, is_sc=1, atomic=1),
            replace(base_leaf, ppn=0x481FF),
        ),
        (
            replace(base_op, needs_sq=1, store=1, is_sc=1, atomic=1),
            replace(base_leaf, ppn=0x40030),
        ),
        (replace(base_op, store=1, atomic=1), base_leaf),
        # Superpages over the device quadrant: the VA offset picks the page.
        (replace(base_op, va=0x0120_0010), replace(base_leaf, level=1, ppn=0x40000)),
        (replace(base_op, va=0x0123_1000), replace(base_leaf, level=1, ppn=0x40000)),
        (replace(base_op, va=0x0121_0000), replace(base_leaf, level=1, ppn=0x44200)),
        (replace(base_op, va=0x0120_0008), replace(base_leaf, level=1, ppn=0x48000)),
        (replace(base_op, va=0x013F_F008), replace(base_leaf, level=1, ppn=0x48000)),
        (replace(base_op, va=0x0120_0008), replace(base_leaf, level=1, ppn=0x48200)),
        (replace(base_op, va=0xC400_0008), replace(base_leaf, level=2, ppn=0x40000)),
        (replace(base_op, va=0xC440_0000), replace(base_leaf, level=2, ppn=0x40000)),
        (replace(base_op, va=0xC800_0008), replace(base_leaf, level=2, ppn=0x40000)),
        (replace(base_op, va=0xC81F_FFF8), replace(base_leaf, level=2, ppn=0x40000)),
        (replace(base_op, va=0xC820_0000), replace(base_leaf, level=2, ppn=0x40000)),
        (
            replace(base_op, va=0xC000_0018, store=1, atomic=1),
            replace(base_leaf, level=2, ppn=0x40000),
        ),
        # Zicbom: SQ-resident with load permissions (D and W ignored, R or X
        # with MXR needed), echoed for the wrapper; device windows resolve.
        (replace(base_op, needs_sq=1, is_cmo=1, size=0), base_leaf),
        (replace(base_op, needs_sq=1, is_cmo=1, size=0), replace(base_leaf, w=0, d=0)),
        (replace(base_op, needs_sq=1, is_cmo=1, size=0), replace(base_leaf, r=0, x=1)),
        (
            replace(base_op, needs_sq=1, is_cmo=1, size=0, mxr=1),
            replace(base_leaf, r=0, x=1),
        ),
        (replace(base_op, needs_sq=1, is_cmo=1, size=0), replace(base_leaf, u=1)),
        (
            replace(base_op, needs_sq=1, is_cmo=1, size=0),
            replace(base_leaf, ppn=0x40000),
        ),
        (
            replace(base_op, needs_sq=1, is_cmo=1, size=0),
            replace(base_leaf, ppn=0x44000),
        ),
        (
            replace(base_op, needs_sq=1, is_cmo=1, size=0),
            replace(base_leaf, ppn=DDR_LIMIT >> 12),
        ),
    ]
    for path in ("direct", "lookup", "walk"):
        for op, leaf in cases:
            leaf = replace(leaf, vpn=(op.va >> 12) & VPN_MASK)
            await _clear(dut)
            if path != "walk":
                await _install(dut, leaf)
            # Keep a resident hit in S1 to exercise its resolution as well.
            dut.i_tlb_invalidate.value = int(path == "lookup")
            _issue(dut, op)
            await _cycle(dut)
            dut.i_tlb_invalidate.value = 0
            if int(dut.o_iss_out_valid.value):
                assert path == "direct" and _expected(op, leaf)[1] == NONE
                _check(dut, op, leaf)
                dut.i_iss_valid.value = 0
                await _cycle(dut)
                assert not int(dut.o_iss_out_valid.value)
                continue
            assert int(dut.o_pre_rob_tag.value) == op.tag
            assert int(dut.o_pre_needs_lq.value) == 1 - op.needs_sq
            dut.i_iss_valid.value = 0
            if path == "walk":
                _response(dut, leaf)
            await Timer(1, unit="ns")
            assert not int(dut.o_walk_req_valid.value), (
                "locally resolved op asked walker"
            )
            await _cycle(dut)
            _check(dut, op, leaf)
            dut.i_walk_resp_valid.value = 0
            await _cycle(dut)
            assert not int(dut.o_iss_out_valid.value), "resolution duplicated"


@cocotb.test()
async def test_pbmt_pages_take_the_mmio_path(dut: Any) -> None:
    """Svpbmt: NC and IO leaves resolve as MMIO, refuse atomics, keep their PA.

    The walker gives an NC or IO leaf over DDR the alias PPN; the DMMU must
    classify it MMIO (loads at the ROB head, no L0, stores after B), refuse
    AMO, LR and SC with an access fault, and return the alias PA, from a walk
    response and from a resident DTLB entry. An NC leaf over
    low BRAM keeps its BRAM PA and is MMIO by its field. Superpages and Zicbom
    ops on them resolve the same way.
    """
    await _setup(dut)
    base_op = Op()
    leaf = Leaf(vpn=base_op.va >> 12)
    alias_ppn = 0x8_0123 | (ALIAS_OFFSET >> 12)
    nc = replace(leaf, ppn=alias_ppn, pbmt=1)
    io = replace(leaf, ppn=alias_ppn, pbmt=2)
    bram = replace(leaf, ppn=0x10, pbmt=1)
    device = replace(leaf, ppn=0x40000, pbmt=2)
    mega = replace(leaf, level=1, ppn=0x80200 | (ALIAS_OFFSET >> 12), pbmt=2)
    giga = replace(leaf, level=2, ppn=0x80000 | (ALIAS_OFFSET >> 12), pbmt=1)
    load, store = base_op, replace(base_op, needs_sq=1, store=1)
    amo = replace(base_op, store=1, atomic=1)
    lr = replace(base_op, atomic=1)
    sc = replace(base_op, needs_sq=1, store=1, is_sc=1, atomic=1)
    cmo = replace(base_op, needs_sq=1, size=0)
    cases = []
    for page in (nc, io, bram, device):
        for op in (load, store, amo, lr, sc, cmo):
            cases.append((op, page))
    # A PMA leaf over the alias window is outside the map.
    for op in (load, store, cmo):
        cases.append((op, replace(nc, pbmt=0)))
    for op in (load, store, amo):
        cases.append((replace(op, va=0x0123_4568), mega))
        cases.append((replace(op, va=0x1234_5678), giga))
    for via_walk in (False, True):
        for op, page in cases:
            page = replace(page, vpn=(op.va >> 12) & VPN_MASK)
            _, fault, mmio = _expected(op, page)
            if page.pbmt == 0:
                assert fault == ACCESS, (op, page)
            elif not op.atomic:
                assert fault == NONE and mmio == 1, (op, page)
            else:
                assert fault == ACCESS, (op, page)
            await _clear(dut)
            if not via_walk:
                await _install(dut, page)
            _issue(dut, op)
            await _cycle(dut)
            dut.i_iss_valid.value = 0
            if via_walk:
                _response(dut, page)
            if not int(dut.o_iss_out_valid.value):
                await _cycle(dut)
            _check(dut, op, page)
            dut.i_walk_resp_valid.value = 0
            await _cycle(dut)
    # Consecutive loads of a resident NC page bypass S1 and resolve as MMIO.
    for page in (nc, bram):
        page = replace(page, vpn=(load.va >> 12) & VPN_MASK)
        await _clear(dut)
        await _install(dut, page)
        for i in range(4):
            op = replace(load, va=load.va + 8 * i, tag=4 + i)
            _issue(dut, op)
            await _cycle(dut)
            dut.i_iss_valid.value = 0
            _check(dut, op, page)
            await _cycle(dut)


@cocotb.test()
async def test_no_alias_refusal_checks_live_page_permissions(dut: Any) -> None:
    """A no-alias leaf keeps page faults ahead of its physical-access refusal."""
    await _setup(dut)
    load = Op()
    store = replace(load, needs_sq=1, store=1)
    for pbmt in (1, 2):
        leaf = Leaf(vpn=load.va >> 12, pbmt=pbmt, fault=ACCESS)
        cases = (
            (load, leaf),
            (store, leaf),
            (load, replace(leaf, u=1)),
            (store, replace(leaf, u=1)),
            (replace(load, sum_=1), replace(leaf, u=1)),
            (replace(load, priv_u=1), leaf),
            (store, replace(leaf, w=0)),
            (store, replace(leaf, d=0)),
            (load, replace(leaf, r=0, x=1)),
            (replace(load, mxr=1), replace(leaf, r=0, x=1)),
        )
        for op, response in cases:
            await _clear(dut)
            _issue(dut, op)
            await _cycle(dut)
            dut.i_iss_valid.value = 0
            _response(dut, response)
            await _cycle(dut)
            _check(dut, op, response)
            dut.i_walk_resp_valid.value = 0
            await _cycle(dut)


@cocotb.test()
async def test_tlb_hit_wins_over_matching_walk_response(dut: Any) -> None:
    """A matching walk never overrides an existing hit's address or fault."""
    await _setup(dut)
    op = Op()
    for hit_denied in (False, True):
        hit = Leaf(vpn=op.va >> 12, r=int(not hit_denied))
        for response_fault in (NONE, PAGE, ACCESS):
            await _clear(dut)
            await _install(dut, hit)
            dut.i_tlb_invalidate.value = 1  # Exercise S1 hit versus walk arbitration.
            _issue(dut, op)
            await _cycle(dut)
            dut.i_tlb_invalidate.value = 0
            dut.i_iss_valid.value = 0
            _response(dut, Leaf(vpn=hit.vpn, ppn=0x40000, fault=response_fault))
            await _cycle(dut)
            _check(dut, op, hit)


@cocotb.test()
async def test_hit_stream_has_no_bubbles(dut: Any) -> None:
    """Mixed load/store/SC/AMO payloads resolve on consecutive issue edges."""
    await _setup(dut)
    leaf = Leaf(vpn=0x400)
    await _install(dut, leaf)
    for index in range(40):
        op = Op(
            va=0x400000 + index * 8,
            tag=index % 32,
            needs_sq=index % 2,
            store=int(index % 4 != 0),
            is_sc=int(index % 4 == 3),
            data=index * 0x12345678,
            amo_rs2=index * 0x87654321,
        )
        _issue(dut, op)
        await _cycle(dut)
        assert not int(dut.o_stall.value), "hit stream filled the skid"
        assert not int(dut.o_walk_req_valid.value), "hit stream asked walker"
        _check(dut, op, leaf)
    dut.i_iss_valid.value = 0
    await _cycle(dut)
    assert not int(dut.o_iss_out_valid.value)


@cocotb.test()
async def test_miss_skid_and_response_matching(dut: Any) -> None:
    """A miss waits for its VPN once; its skid successor follows without a bubble.

    While the skid is full the issue port carries other ops' payloads with
    valid low, and the held op keeps its own.
    """
    await _setup(dut)
    first, second = Op(), Op(va=0x500120, tag=4, needs_sq=1, store=1)
    second_leaf = Leaf(vpn=second.va >> 12, ppn=0x40000)
    for fault in (NONE, PAGE, ACCESS):
        await _clear(dut)
        await _install(dut, second_leaf)
        _issue(dut, first)
        await _cycle(dut)
        assert int(dut.o_walk_req_valid.value)
        assert int(dut.o_walk_vpn.value) == first.va >> 12
        _issue(dut, second)
        await _cycle(dut)
        dut.i_iss_valid.value = 0
        assert int(dut.o_stall.value), "second op did not occupy the skid"
        _response(dut, Leaf(vpn=0x777, fault=PAGE))
        for step in range(3):
            _present_payload(
                dut,
                Op(
                    va=0x0060_0000 + (step << 12) + 8 * step,
                    tag=9 + step,
                    size=step,
                    needs_sq=1 - second.needs_sq,
                    store=1 - second.store,
                    data=~second.data & XLEN_MASK,
                    amo_rs2=~second.amo_rs2 & XLEN_MASK,
                ),
            )
            await _cycle(dut)
            assert not int(dut.o_iss_out_valid.value), "unrelated VPN resolved held op"
            assert not int(dut.o_walk_req_valid.value), "accepted request repeated"
            assert int(dut.o_stall.value)
        first_leaf = Leaf(vpn=first.va >> 12, fault=fault)
        _response(dut, first_leaf)
        await _cycle(dut)
        _check(dut, first, first_leaf)
        assert not int(dut.o_stall.value)
        assert int(dut.o_pre_rob_tag.value) == second.tag
        dut.i_walk_resp_valid.value = 0
        await _cycle(dut)
        _check(dut, second, second_leaf)
        await _cycle(dut)
        assert not int(dut.o_iss_out_valid.value)


@cocotb.test()
async def test_flush_drops_phantom_issue_and_tag_reuse(dut: Any) -> None:
    """Younger issues in the flush cycle never fault a later reuse of their tag."""
    await _setup(dut)
    correct = Op(tag=5)
    leaf = Leaf(vpn=correct.va >> 12)
    for full_flush in (False, True):
        for held_miss in (False, True):
            await _clear(dut)
            await _install(dut, leaf)
            if held_miss:
                _issue(dut, Op(va=0x20, tag=4))
                await _cycle(dut)
                assert int(dut.o_walk_req_valid.value)
            dut.i_flush_tag.value = 2
            dut.i_flush_en.value = int(not full_flush)
            dut.i_flush_all.value = int(full_flush)
            _issue(dut, Op(va=0x88, tag=correct.tag))
            await _cycle(dut)
            dut.i_flush_en.value = 0
            dut.i_flush_all.value = 0
            dut.i_iss_valid.value = 0
            _response(dut, Leaf(vpn=0, fault=PAGE))
            for _ in range(3):
                await _cycle(dut)
                assert not int(dut.o_iss_out_valid.value), (
                    "squashed op escaped recovery"
                )
                assert not int(dut.o_walk_req_valid.value), "phantom issue asked walker"
            dut.i_walk_resp_valid.value = 0
            _issue(dut, correct)
            await _cycle(dut)
            dut.i_iss_valid.value = 0
            _check(dut, correct, leaf)


@cocotb.test()
async def test_early_port_needs_store_permission_and_a_data_page(dut: Any) -> None:
    """The early store port returns a PA only for a writable hit on a data page.

    Anything else drops the prefill: a page outside the map, a device-quadrant
    page outside the device windows, or a leaf without W or without D.
    """
    await _setup(dut)
    va = 0x0040_0128
    # (ppn, w, d, expected_ok)
    cases = [
        (0x80000, 1, 1, True),
        (0x40000, 1, 1, True),
        (0x443FF, 1, 1, True),
        (0x48000, 1, 1, True),
        (0x481FF, 1, 1, True),
        (0x40031, 1, 1, False),
        (0x47FFF, 1, 1, False),
        (0x48200, 1, 1, False),
        (0x7FFFF, 1, 1, False),
        (0xC0000, 1, 1, DDR_LIMIT > 0xC000_0000),
        (0x80000, 1, 0, False),
        (0x80000, 0, 1, False),
        (0x48000, 1, 0, False),
        (0x48100, 0, 1, False),
    ]
    for ppn, w, d, expected_ok in cases:
        await _clear(dut)
        await _install(dut, Leaf(vpn=va >> 12, ppn=ppn, w=w, d=d))
        dut.i_early_valid.value = 1
        dut.i_early_va.value = va
        await _cycle(dut)
        dut.i_early_valid.value = 0
        await _cycle(dut)
        pa = (ppn << 12) | (va & 0xFFF)
        assert int(dut.o_early_ok.value) == int(expected_ok), f"{ppn=:#x} {w=} {d=}"
        if expected_ok:
            assert int(dut.o_early_pa.value) == pa
            assert int(dut.o_early_is_mmio.value) == int(_device_ok(pa))


@cocotb.test()
async def test_walk_response_on_flush_and_reused_tag(dut: Any) -> None:
    """Recovery cancels a resolving operation without losing a later tag reuse."""
    await _setup(dut)
    old = Op(tag=5)
    replacement = Op(tag=5, va=0x00600120, needs_sq=1, store=1)
    leaf = Leaf(vpn=replacement.va >> 12, ppn=0x80012)
    for full in (False, True):
        for fault in (NONE, PAGE, ACCESS):
            await _clear(dut)
            _issue(dut, old)
            await _cycle(dut)
            dut.i_iss_valid.value = 0
            await _cycle(dut)
            dut.i_flush_tag.value = 2
            dut.i_flush_en.value = int(not full)
            dut.i_flush_all.value = int(full)
            _response(dut, Leaf(vpn=old.va >> 12, fault=fault))
            await _cycle(dut)
            assert not int(dut.o_iss_out_valid.value)
            dut.i_flush_en.value = 0
            dut.i_flush_all.value = 0
            dut.i_walk_resp_valid.value = 0
            for _ in range(3):
                await _cycle(dut)
                assert not int(dut.o_iss_out_valid.value)
            _issue(dut, replacement)
            await _cycle(dut)
            dut.i_iss_valid.value = 0
            _response(dut, leaf)
            await _cycle(dut)
            _check(dut, replacement, leaf)
            dut.i_walk_resp_valid.value = 0
            await _cycle(dut)
            assert not int(dut.o_iss_out_valid.value), "replacement completed twice"


@cocotb.test()
async def test_killed_walk_fault_does_not_resolve_replacement(dut: Any) -> None:
    """A walk outlives partial recovery while a different VPN occupies S1."""
    await _setup(dut)
    for fault in (PAGE, ACCESS):
        await _clear(dut)
        old = Op(tag=6)
        current = Op(tag=6, va=0x00800120)
        leaf = Leaf(vpn=current.va >> 12, ppn=0x80020)
        _issue(dut, old)
        await _cycle(dut)
        dut.i_iss_valid.value = 0
        await _cycle(dut)
        dut.i_flush_en.value = 1
        dut.i_flush_tag.value = 2
        await _cycle(dut)
        dut.i_flush_en.value = 0
        _issue(dut, current)
        await _cycle(dut)
        dut.i_iss_valid.value = 0
        _response(dut, Leaf(vpn=old.va >> 12, fault=fault))
        await _cycle(dut)
        assert not int(dut.o_iss_out_valid.value), "stale walk faulted the reused tag"
        dut.i_walk_resp_valid.value = 0
        for _ in range(3):
            await _cycle(dut)
            assert not int(dut.o_iss_out_valid.value)
        _response(dut, leaf)
        await _cycle(dut)
        _check(dut, current, leaf)


@cocotb.test()
async def test_superpage_hit_over_matching_walk_fault(dut: Any) -> None:
    """A superpage hit keeps its PA and store permissions when a stale fault arrives."""
    await _setup(dut)
    op = Op(needs_sq=1, store=1)
    for level in (1, 2):
        for fault in (PAGE, ACCESS):
            await _clear(dut)
            hit = Leaf(vpn=op.va >> 12, ppn=0x80000, level=level)
            await _install(dut, hit)
            dut.i_tlb_invalidate.value = 1  # Exercise S1 hit versus walk arbitration.
            _issue(dut, op)
            await _cycle(dut)
            dut.i_tlb_invalidate.value = 0
            dut.i_iss_valid.value = 0
            _response(dut, Leaf(vpn=op.va >> 12, fault=fault))
            await _cycle(dut)
            _check(dut, op, hit)
            dut.i_walk_resp_valid.value = 0
            await _cycle(dut)
            assert not int(dut.o_iss_out_valid.value)


@cocotb.test()
async def test_every_resident_entry_bypasses_and_replacement_takes_effect(
    dut: Any,
) -> None:
    """All slots grant on the first edge, including carries and borrows into each VPN field."""
    await _setup(dut)
    leaves = [Leaf(vpn=(i << 18) | (i << 9) | i, ppn=0x80000 + i) for i in range(16)]
    for leaf in leaves:
        await _install(dut, leaf)
    for offset in (1, -1, 0x1FFF, -(1 << 22), (1 << 30) + 1):
        for index in (15, *range(15)):
            leaf = leaves[index]
            op = Op(
                va=leaf.vpn << 12,
                tag=index,
                offset=offset,
                store=index % 2,
                needs_sq=index % 2,
            )
            _issue(dut, op)
            await _paired_cycle(dut)
            _check(dut, op, leaf)
    # Slot zero is replaced as its old mapping is issued. S1 must see the new fill.
    incoming = replace(leaves[0], ppn=0x81000)
    _response(dut, incoming)
    op = Op(va=0, tag=5, offset=1)
    _issue(dut, op)
    await _paired_cycle(dut)
    assert not int(dut.o_iss_out_valid.value)
    dut.i_walk_resp_valid.value = 0
    dut.i_iss_valid.value = 0
    await _paired_cycle(dut)
    _check(dut, op, incoming)


@cocotb.test()
async def test_uniform_user_superpage_bypasses_across_subpages(dut: Any) -> None:
    """A user hit anywhere in a uniform leaf supplies that access's low PPN bits."""
    await _setup(dut)
    for level in (1, 2):
        await _clear(dut)
        dut.i_eff_priv_u.value = 1
        leaf = Leaf(vpn=(1 << 26) | 0x42101, ppn=0x80000, level=level, u=1)
        await _install(dut, leaf)
        mask = (1 << (9 * level)) - 1
        for subpage in (0, 1, mask):
            vpn = (leaf.vpn & ~mask) | subpage
            va = (XLEN_MASK ^ ((1 << 39) - 1)) | (vpn << 12) | 0x80
            op = Op(va=va, priv_u=1, offset=-0x280)
            _issue(dut, op)
            await _paired_cycle(dut)
            _check(dut, op, leaf)
        dut.i_iss_valid.value = 0


@cocotb.test()
async def test_mixed_or_denied_winner_precedes_clean_overlap(dut: Any) -> None:
    """The lowest matching slot owns the access even when only the other slot is clean."""
    await _setup(dut)
    op = Op(va=0x400010)
    for first in (Leaf(vpn=0x400, ppn=0, level=1), Leaf(vpn=0x400, r=0)):
        await _clear(dut)
        await _install(dut, first)
        await _install(dut, Leaf(vpn=0x400))
        _issue(dut, op)
        await _paired_cycle(dut)
        assert not int(dut.o_iss_out_valid.value)
        dut.i_iss_valid.value = 0
        await _paired_cycle(dut)
        _check(dut, op, first)


@cocotb.test()
async def test_entry_bypass_permission_mismatch_fault_precision(dut: Any) -> None:
    """Store to read-only page does not bypass, preserving exact page fault."""
    await _setup(dut)
    # Read-only leaf (w=0)
    leaf = Leaf(vpn=0x400, ppn=0x80000, w=0)
    await _install(dut, leaf)

    op0 = Op(va=0x400010, tag=1, store=0)
    _issue(dut, op0)
    await _cycle(dut)
    dut.i_iss_valid.value = 0
    _check(dut, op0, leaf)

    # Store to same page must not bypass and must fault
    op1 = Op(va=0x400028, tag=2, needs_sq=1, store=1)
    _issue(dut, op1)
    await _cycle(dut)
    assert not int(dut.o_iss_out_valid.value), "Permission mismatch must not bypass"
    dut.i_iss_valid.value = 0
    await _cycle(dut)
    _check(dut, op1, leaf)
    assert int(dut.o_iss_out_fault.value) == PAGE


@cocotb.test()
async def test_entry_bypass_misaligned_trap_precision(dut: Any) -> None:
    """Misaligned access does not bypass, preserving exact misaligned fault."""
    await _setup(dut)
    leaf = Leaf(vpn=0x400, ppn=0x80000)
    await _install(dut, leaf)

    op0 = Op(va=0x400010, tag=1)
    _issue(dut, op0)
    await _cycle(dut)
    dut.i_iss_valid.value = 0
    _check(dut, op0, leaf)

    # Misaligned op (double at byte offset 1)
    op1 = Op(va=0x400011, tag=2, size=3, trap_misaligned=1)
    _issue(dut, op1)
    await _cycle(dut)
    assert not int(dut.o_iss_out_valid.value), "Misaligned access must not bypass"
    dut.i_iss_valid.value = 0
    await _cycle(dut)
    _check(dut, op1, leaf)
    assert int(dut.o_iss_out_fault.value) == MISALIGN


async def _paired_cycle(dut: Any) -> None:
    """Check the LQ look-ahead against the next registered capture pulse."""
    await Timer(1, unit="ns")
    pre_tag = int(dut.o_pre_rob_tag.value)
    pre_valid = int(dut.o_pre_needs_lq.value)
    await _cycle(dut)
    if int(dut.o_iss_out_lq_capture_valid.value):
        assert pre_valid
        assert int(dut.o_iss_out_rob_tag.value) == pre_tag


async def _install_and_check(dut: Any, leaf: Leaf, op: Op) -> None:
    """Fill under the requested context and check the first direct result."""
    dut.i_eff_priv_u.value = op.priv_u
    dut.i_sum.value = op.sum_
    dut.i_mxr.value = op.mxr
    await _install(dut, leaf)
    _issue(dut, op)
    await _paired_cycle(dut)
    dut.i_iss_valid.value = 0
    _check(dut, op, leaf)
    assert int(dut.o_iss_out_fault.value) == NONE


@cocotb.test()
async def test_entry_bypass_partial_flush_resolution(dut: Any) -> None:
    """A killed S1 hit releases S2. A simultaneous refill sends the older op through S1."""
    await _setup(dut)
    leaf_a = Leaf(vpn=0x400, ppn=0x80000)
    leaf_b = Leaf(vpn=0x500, ppn=0x81000)
    for resident_b in (True, False):
        await _clear(dut)
        if resident_b:
            await _install(dut, leaf_b)
        await _install_and_check(dut, leaf_a, Op(va=0x400010, tag=1))
        dut.i_tlb_invalidate.value = int(resident_b)  # Leave the younger hit in S1.
        _issue(dut, Op(va=0x500010, tag=5))
        await _paired_cycle(dut)
        dut.i_tlb_invalidate.value = 0
        assert not int(dut.o_iss_out_valid.value)
        if not resident_b:
            _response(dut, leaf_b)
        dut.i_flush_en.value = 1
        dut.i_flush_tag.value = 2
        dut.i_head_tag.value = 0
        older = Op(va=0x400028, tag=1, data=0x123, amo_rs2=0x456)
        _issue(dut, older)
        await _paired_cycle(dut)
        dut.i_iss_valid.value = 0
        dut.i_walk_resp_valid.value = 0
        if not resident_b:
            assert not int(dut.o_iss_out_valid.value)  # Concurrent fill.
            await _paired_cycle(dut)
        _check(dut, older, leaf_a)
        dut.i_flush_en.value = 0
        await _paired_cycle(dut)
        assert not int(dut.o_iss_out_valid.value)


@cocotb.test()
async def test_entry_bypass_routing_and_lookahead(dut: Any) -> None:
    """Consecutive load, store, SC, LR and AMO hits preserve tags and payloads."""
    await _setup(dut)
    leaf = Leaf(vpn=0x400, ppn=0x80000)
    await _install_and_check(dut, leaf, Op(va=0x400010, tag=1))
    operations = (
        Op(va=0x400028, tag=2),
        Op(va=0x400030, tag=3, needs_sq=1, store=1, data=0x123456),
        Op(va=0x400038, tag=4, needs_sq=1, store=1, atomic=1, is_sc=1, data=0xABC),
        Op(va=0x400040, tag=5, atomic=1),
        Op(va=0x400048, tag=6, store=1, atomic=1, amo_rs2=0xFEDCBA),
    )
    for op in operations:
        _issue(dut, op)
        await Timer(1, unit="ns")
        assert int(dut.o_pre_rob_tag.value) == op.tag
        assert int(dut.o_pre_needs_lq.value) == 1 - op.needs_sq
        await _paired_cycle(dut)
        _check(dut, op, leaf)
    dut.i_iss_valid.value = 0
    await _paired_cycle(dut)
    assert not int(dut.o_iss_out_valid.value)


@cocotb.test()
async def test_entry_bypass_warm_permissions_and_addresses(dut: Any) -> None:
    """Resident entry checks preserve faults, physical pages and routing."""
    await _setup(dut)
    base_leaf = Leaf(vpn=0x400, ppn=0x80000)
    prime = Op(va=0x400010, tag=1)
    access = Op(va=0x400028, tag=2)
    cases = (
        (replace(base_leaf, u=1), replace(prime, priv_u=1), access, False),
        (replace(base_leaf, u=1), replace(prime, sum_=1), access, False),
        (replace(base_leaf, r=0, x=1), replace(prime, mxr=1), access, False),
        (replace(base_leaf, d=0), prime, replace(access, store=1, needs_sq=1), False),
        (base_leaf, prime, replace(access, priv_u=1), False),
        (replace(base_leaf, ppn=0x40000), prime, replace(access, atomic=1), False),
        (base_leaf, prime, replace(access, va=access.va | (1 << 39)), False),
        (base_leaf, prime, replace(access, va=0x400029), False),
        (
            replace(base_leaf, u=1),
            replace(prime, priv_u=1),
            replace(access, sum_=1),
            False,
        ),
        (replace(base_leaf, level=1), prime, access, True),
        (replace(base_leaf, level=2), prime, access, True),
        (replace(base_leaf, ppn=(DDR_LIMIT - 4096) >> 12), prime, access, True),
    )
    for leaf, first, second, bypass in cases:
        await _clear(dut)
        await _install_and_check(dut, leaf, first)
        _issue(dut, second)
        await _paired_cycle(dut)
        if not bypass:
            assert not int(dut.o_iss_out_valid.value)
            dut.i_iss_valid.value = 0
            await _paired_cycle(dut)
        _check(dut, second, leaf)
        dut.i_iss_valid.value = 0
        await _paired_cycle(dut)


@cocotb.test()
async def test_entry_bypass_lifetime_and_remap(dut: Any) -> None:
    """Recovery and disable preserve resident translations. Reset and remap use the new fill."""
    await _setup(dut)
    original = Leaf(vpn=0x400, ppn=0x80000)
    for event in ("reset", "flush", "disable", "remap"):
        await _clear(dut)
        await _install_and_check(dut, original, Op(va=0x400010, tag=1))
        signal = {
            "reset": "i_rst_n",
            "flush": "i_flush_all",
            "disable": "i_active",
            "remap": "i_tlb_invalidate",
        }[event]
        active_value = int(event in ("flush", "remap"))
        getattr(dut, signal).value = active_value
        # A real invalidate comes with its flush command.
        dut.i_tlb_flush.value = FLUSH_ALL if event == "remap" else 0
        await _paired_cycle(dut)
        getattr(dut, signal).value = 1 - active_value
        dut.i_tlb_flush.value = 0
        leaf = replace(original, ppn=0x81000) if event == "remap" else original
        if event in ("reset", "remap"):
            await _install(dut, leaf)
        op = Op(va=0x400028, tag=2)
        _issue(dut, op)
        await _paired_cycle(dut)
        dut.i_iss_valid.value = 0
        _check(dut, op, leaf)


@cocotb.test()
async def test_entry_bypass_backpressure_and_issue_kill(dut: Any) -> None:
    """A warm hit waits behind S1/S0, and flushed issues produce no packet."""
    await _setup(dut)
    leaf_a = Leaf(vpn=0x400, ppn=0x80000)
    leaf_b = Leaf(vpn=0x500, ppn=0x81000)
    await _install_and_check(dut, leaf_a, Op(va=0x400010, tag=1))
    first = Op(va=0x500010, tag=3)
    second = Op(va=0x400028, tag=4)
    _issue(dut, first)
    await _paired_cycle(dut)
    assert int(dut.o_walk_req_valid.value)
    _issue(dut, second)
    await _paired_cycle(dut)
    assert int(dut.o_stall.value)
    assert not int(dut.o_iss_out_valid.value)
    dut.i_iss_valid.value = 0
    await _paired_cycle(dut)
    assert int(dut.o_stall.value)
    assert not int(dut.o_iss_out_valid.value)
    _response(dut, leaf_b)
    await _paired_cycle(dut)
    _check(dut, first, leaf_b)
    dut.i_walk_resp_valid.value = 0
    await _paired_cycle(dut)
    _check(dut, second, leaf_a)
    dut.i_flush_en.value = 1
    dut.i_flush_tag.value = 2
    dut.i_head_tag.value = 0
    _issue(dut, Op(va=0x400030, tag=5))
    await _paired_cycle(dut)
    assert not int(dut.o_iss_out_valid.value)
    dut.i_flush_en.value = 0
    surviving = Op(va=0x400038, tag=1)
    _issue(dut, surviving)
    await _paired_cycle(dut)
    _check(dut, surviving, leaf_a)
    dut.i_flush_all.value = 1
    _issue(dut, Op(va=0x400040, tag=8))
    await _paired_cycle(dut)
    assert not int(dut.o_iss_out_valid.value)
    dut.i_flush_all.value = 0
    dut.i_iss_valid.value = 0
    await _paired_cycle(dut)
    assert not int(dut.o_iss_out_valid.value)


def _flush_cmd(vpn: int | None = None, asid: int | None = None) -> int:
    """Pack a riscv_pkg::tlb_flush_t that clears entries by page and/or ASID."""
    return pack_struct(
        TLB_FLUSH_FIELDS,
        {
            "en": 1,
            "use_va": vpn is not None,
            "vpn": vpn or 0,
            "use_asid": asid is not None,
            "asid": asid or 0,
        },
    )


async def _translation_changed(dut: Any, flush: int = 0) -> None:
    """Pulse the translation-changed input with an optional flush command."""
    dut.i_tlb_invalidate.value = 1
    dut.i_tlb_flush.value = flush
    await _cycle(dut)
    dut.i_tlb_invalidate.value = 0
    dut.i_tlb_flush.value = 0


async def _switch_asid(dut: Any, asid: int) -> None:
    """Change satp.ASID the way the CSR file does: new value plus a changed pulse."""
    dut.i_asid.value = asid
    await _translation_changed(dut)


async def _probe(dut: Any, asid: int, leaf: Leaf) -> bool:
    """Look the leaf's page up under asid; return True for a TLB hit.

    A miss is answered with the same leaf, which installs it again.
    """
    await _switch_asid(dut, asid)
    op = Op(va=(leaf.vpn << 12) | 0x20, tag=1)
    _issue(dut, op)
    await _cycle(dut)
    miss = bool(int(dut.o_walk_req_valid.value))
    dut.i_iss_valid.value = 0
    if miss:
        _response(dut, leaf)
        await _cycle(dut)
    _check(dut, op, leaf)
    dut.i_walk_resp_valid.value = 0
    await _cycle(dut)
    return not miss


@cocotb.test()
async def test_asid_isolation_and_global_entries(dut: Any) -> None:
    """Same page under two ASIDs keeps two entries; a global entry serves all."""
    await _setup(dut)
    await _clear(dut)
    leaf_a = Leaf(vpn=0x400, ppn=0x80000)
    leaf_b = Leaf(vpn=0x400, ppn=0x81000)
    leaf_g = Leaf(vpn=0x600, ppn=0x83000, g=1)
    for asid, leaf in ((1, leaf_a), (2, leaf_b), (1, leaf_g)):
        await _switch_asid(dut, asid)
        await _install(dut, leaf)
    assert await _probe(dut, 1, leaf_a)
    assert await _probe(dut, 2, leaf_b)
    assert await _probe(dut, 1, leaf_a)
    # The global entry hits under an ASID that never installed it.
    assert await _probe(dut, 3, leaf_g)
    assert await _probe(dut, 0x1FF, leaf_g)
    # A non-global entry never answers for another ASID.
    assert not await _probe(dut, 3, leaf_a)
    assert not await _probe(dut, 4, leaf_b)


@cocotb.test()
async def test_sfence_forms_follow_the_privileged_spec(dut: Any) -> None:
    """Flush by page, by ASID, by both, and everything; global entries are spared by ASID."""
    await _setup(dut)
    leaf_a = Leaf(vpn=0x400, ppn=0x80000)
    leaf_b = Leaf(vpn=0x400, ppn=0x81000)
    leaf_c = Leaf(vpn=0x500, ppn=0x82000)
    leaf_g = Leaf(vpn=0x600, ppn=0x83000, g=1)
    entries = ((1, "A", leaf_a), (2, "B", leaf_b), (1, "C", leaf_c), (1, "G", leaf_g))
    # (flush, names that survive)
    cases = {
        "none": (None, "ABCG"),
        "asid1": (_flush_cmd(asid=1), "BG"),
        "page400": (_flush_cmd(vpn=0x400), "CG"),
        "page600": (_flush_cmd(vpn=0x600), "ABC"),
        "page400_asid1": (_flush_cmd(vpn=0x400, asid=1), "BCG"),
        "page600_asid1": (_flush_cmd(vpn=0x600, asid=1), "ABCG"),
        "all": (_flush_cmd(), ""),
    }
    for name, (flush, survivors) in cases.items():
        await _clear(dut)
        for asid, _, leaf in entries:
            await _switch_asid(dut, asid)
            await _install(dut, leaf)
        if flush is not None:
            await _translation_changed(dut, flush)
        for asid, label, leaf in entries:
            hit = await _probe(dut, asid, leaf)
            assert hit == (label in survivors), f"{name}: entry {label} hit={hit}"


@cocotb.test()
async def test_asid_wrap_and_reuse_after_flush(dut: Any) -> None:
    """ASIDs 0 and 511 stay separate; a reused ASID sees nothing after its flush."""
    await _setup(dut)
    await _clear(dut)
    leaf_lo = Leaf(vpn=0x400, ppn=0x80000)
    leaf_hi = Leaf(vpn=0x400, ppn=0x81000)
    leaf_new = Leaf(vpn=0x400, ppn=0x82000)
    for asid, leaf in ((0, leaf_lo), (0x1FF, leaf_hi)):
        await _switch_asid(dut, asid)
        await _install(dut, leaf)
    assert await _probe(dut, 0, leaf_lo)
    assert await _probe(dut, 0x1FF, leaf_hi)
    # The OS recycles ASID 0x1FF: it flushes that ASID, then maps a new page.
    await _translation_changed(dut, _flush_cmd(asid=0x1FF))
    assert not await _probe(dut, 0x1FF, leaf_hi)
    await _translation_changed(dut, _flush_cmd(asid=0x1FF))
    await _switch_asid(dut, 0x1FF)
    await _install(dut, leaf_new)
    assert await _probe(dut, 0x1FF, leaf_new)
    assert await _probe(dut, 0, leaf_lo)


@cocotb.test()
async def test_asid_follows_the_pulse_by_one_cycle(dut: Any) -> None:
    """The old address space never answers once the delayed ASID arrives.

    In the core the CSR file's translation-changed pulse comes in the cycle
    after the satp write, and the DMMU's ASID (the registered translation
    state) changes one cycle after the pulse. An access issued with the pulse
    looks the DTLB up in the first cycle under the new ASID and must miss; the
    pulse prevents a direct hit on the old address space.
    """
    await _setup(dut)
    await _clear(dut)
    leaf_old = Leaf(vpn=0x400, ppn=0x80000)
    leaf_new = Leaf(vpn=0x400, ppn=0x81000)
    await _switch_asid(dut, 1)
    # Install under ASID 1 and check the direct result.
    await _install_and_check(dut, leaf_old, Op(va=0x400010, tag=1))
    # The pulse, with the old ASID still applied, and an access issued beside
    # it. In the next cycle the access looks the DTLB up under the new ASID.
    op = Op(va=0x400028, tag=2)
    dut.i_tlb_invalidate.value = 1
    _issue(dut, op)
    await _cycle(dut)
    dut.i_tlb_invalidate.value = 0
    dut.i_iss_valid.value = 0
    dut.i_asid.value = 2
    await Timer(1, unit="ns")
    assert not int(dut.o_iss_out_valid.value), (
        "the issue bypass answered under the old ASID"
    )
    assert int(dut.o_walk_req_valid.value), "an ASID 1 entry answered under ASID 2"
    _response(dut, leaf_new)
    await _cycle(dut)
    _check(dut, op, leaf_new)
    dut.i_walk_resp_valid.value = 0
    await _cycle(dut)
    # Each address space keeps its own entry.
    assert await _probe(dut, 2, leaf_new)
    assert await _probe(dut, 1, leaf_old)


@cocotb.test()
async def test_materialized_range_selective_fences(dut: Any) -> None:
    """Adjacent level-0 responses retain independent ASID and global invalidation."""
    await _setup(dut)
    entries = [(1, Leaf(vpn=0x400 + i, ppn=0x80000 + i)) for i in range(8)]
    entries += [(2, Leaf(vpn=0x400 + i, ppn=0x81000 + i)) for i in range(4)]
    entries += [(1, Leaf(vpn=0x408, ppn=0x82008, g=1))]
    entries += [(1, Leaf(vpn=0x500 + i, ppn=0x83000 + i)) for i in range(3)]
    for vpn, asid in ((0x402, None), (0x402, 1), (0x408, 1), (0x500, None)):
        await _clear(dut)
        for owner, leaf in entries:
            await _switch_asid(dut, owner)
            await _install(dut, leaf)
        await _translation_changed(dut, _flush_cmd(vpn=vpn, asid=asid))

        def survives(item: tuple[int, Leaf]) -> bool:
            owner, leaf = item
            return leaf.vpn != vpn or (
                asid is not None and (owner != asid or bool(leaf.g))
            )

        hits = 0
        # Probe survivors before refilling misses can evict one of them.
        for owner, leaf in sorted(entries, key=survives, reverse=True):
            hit = await _probe(dut, owner, leaf)
            assert hit == survives((owner, leaf)), (vpn, asid, owner, leaf, hit)
            hits += hit
        dut._log.info(
            "DTLB survivors vpn=%#x asid=%s: %d/%d", vpn, asid, hits, len(entries)
        )
