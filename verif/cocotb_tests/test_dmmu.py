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

"""Data-MMU checks through its issue, walker, and registered result ports.

The reference resolves Sv39 leaves and the architectural fault priorities in
Python. Protocol checks pin the two-cycle latency, one-result-per-cycle hit
throughput, miss skid, and recovery behavior without inspecting internal RTL.
"""

from dataclasses import dataclass, replace
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


NONE, MISALIGN, PAGE, ACCESS = range(4)
VPN_MASK = (1 << 27) - 1
XLEN_MASK = (1 << 64) - 1


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
    fault: int = NONE

    def packed(self) -> int:
        """Encode the public riscv_pkg::ptw_resp_t seam."""
        fields = (
            (self.fault, 2),
            (self.vpn, 27),
            (self.ppn, 44),
            (self.level, 2),
            (self.r, 1),
            (self.w, 1),
            (self.x, 1),
            (self.u, 1),
            (self.d, 1),
        )
        value = 0
        for field, width in fields:
            value = (value << width) | field
        return value


@dataclass(frozen=True)
class Op:
    """One issued memory operation and its permission controls."""

    va: int = 0x0040_0120
    tag: int = 3
    size: int = 3
    needs_sq: int = 0
    store: int = 0
    is_sc: int = 0
    data: int = 0xFEDC_BA98_7654_3210
    amo_rs2: int = 0x1234_5678_9ABC_DEF0
    priv_u: int = 0
    sum_: int = 0
    mxr: int = 0
    trap_misaligned: int = 1


def _expected(op: Op, leaf: Leaf) -> tuple[int, int, int]:
    """Return architectural address, fault, and MMIO classification."""
    va = op.va & XLEN_MASK
    if op.trap_misaligned and va % (1 << op.size):
        return va, MISALIGN, 0
    canonical = va < (1 << 38) or va >= (1 << 64) - (1 << 38)
    if not canonical:
        return va, PAGE, 0
    if leaf.fault:
        return va, leaf.fault, 0
    priv_ok = bool(op.priv_u or op.sum_) if leaf.u else not op.priv_u
    access_ok = (
        bool(leaf.w and leaf.d) if op.store else bool(leaf.r or (op.mxr and leaf.x))
    )
    if not priv_ok or not access_ok:
        return va, PAGE, 0
    offset_bits = 12 + 9 * leaf.level
    pa = ((leaf.ppn << 12) & ~((1 << offset_bits) - 1)) | (
        va & ((1 << offset_bits) - 1)
    )
    mapped = pa < 0x40000 or 0x4000_0000 <= pa < 0xC000_0000
    if not mapped:
        return va, ACCESS, 0
    return pa, NONE, int(0x4000_0000 <= pa < 0x8000_0000)


async def _cycle(dut: Any) -> None:
    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")


async def _setup(dut: Any) -> None:
    Clock(dut.i_clk, 10, unit="ns").start()
    for name in (
        "i_rst_n",
        "i_sum",
        "i_mxr",
        "i_eff_priv_u",
        "i_tlb_invalidate",
        "i_flush_all",
        "i_flush_en",
        "i_flush_tag",
        "i_head_tag",
        "i_iss_valid",
        "i_iss_rob_tag",
        "i_iss_va",
        "i_iss_size",
        "i_iss_needs_sq",
        "i_iss_store_perms",
        "i_iss_is_sc",
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
    await _cycle(dut)
    dut.i_flush_all.value = 0
    dut.i_tlb_invalidate.value = 0


def _response(dut: Any, leaf: Leaf) -> None:
    dut.i_walk_resp_valid.value = 1
    dut.i_walk_resp.value = leaf.packed()


async def _install(dut: Any, leaf: Leaf) -> None:
    _response(dut, leaf)
    await _cycle(dut)
    dut.i_walk_resp_valid.value = 0


def _issue(dut: Any, op: Op) -> None:
    dut.i_iss_valid.value = 1
    dut.i_iss_va.value = op.va
    dut.i_iss_rob_tag.value = op.tag
    dut.i_iss_size.value = op.size
    dut.i_iss_needs_sq.value = op.needs_sq
    dut.i_iss_store_perms.value = op.store
    dut.i_iss_is_sc.value = op.is_sc
    dut.i_iss_store_data.value = op.data
    dut.i_iss_amo_rs2.value = op.amo_rs2
    dut.i_eff_priv_u.value = op.priv_u
    dut.i_sum.value = op.sum_
    dut.i_mxr.value = op.mxr
    dut.i_trap_misaligned.value = op.trap_misaligned


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
        "o_iss_out_store_data": op.data,
        "o_iss_out_amo_rs2": op.amo_rs2,
        "o_iss_out_lq_capture_valid": 1 - op.needs_sq,
        "o_iss_out_sq_capture_valid": op.needs_sq,
    }
    for name, expected in outputs.items():
        actual = int(getattr(dut, name).value)
        assert (
            actual == expected
        ), f"{name}: got 0x{actual:x}, expected 0x{expected:x}; {op=}, {leaf=}"


@cocotb.test()
async def test_hit_and_walk_resolution_matrix(dut: Any) -> None:
    """Both sources preserve fault priority, full fault VA, PA, and MMIO."""
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
    ]
    for via_walk in (False, True):
        for op, leaf in cases:
            leaf = replace(leaf, vpn=(op.va >> 12) & VPN_MASK)
            await _clear(dut)
            if not via_walk:
                await _install(dut, leaf)
            _issue(dut, op)
            await _cycle(dut)
            assert not int(
                dut.o_iss_out_valid.value
            ), "result arrived before second edge"
            assert int(dut.o_pre_rob_tag.value) == op.tag
            assert int(dut.o_pre_needs_lq.value) == 1 - op.needs_sq
            dut.i_iss_valid.value = 0
            if via_walk:
                _response(dut, leaf)
            await Timer(1, unit="ns")
            assert not int(
                dut.o_walk_req_valid.value
            ), "locally resolved op asked walker"
            await _cycle(dut)
            _check(dut, op, leaf)
            dut.i_walk_resp_valid.value = 0
            await _cycle(dut)
            assert not int(dut.o_iss_out_valid.value), "resolution duplicated"


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
            _issue(dut, op)
            await _cycle(dut)
            dut.i_iss_valid.value = 0
            _response(dut, Leaf(vpn=hit.vpn, ppn=0x40000, fault=response_fault))
            await _cycle(dut)
            _check(dut, op, hit)


@cocotb.test()
async def test_hit_stream_has_no_bubbles(dut: Any) -> None:
    """Mixed load/store/SC/AMO payloads retain two-edge latency at full rate."""
    await _setup(dut)
    leaf = Leaf(vpn=0x400)
    await _install(dut, leaf)
    previous: Op | None = None
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
        if previous is None:
            assert not int(dut.o_iss_out_valid.value)
        else:
            _check(dut, previous, leaf)
        previous = op
    dut.i_iss_valid.value = 0
    await _cycle(dut)
    assert previous is not None
    _check(dut, previous, leaf)
    await _cycle(dut)
    assert not int(dut.o_iss_out_valid.value)


@cocotb.test()
async def test_miss_skid_and_response_matching(dut: Any) -> None:
    """A miss waits for its VPN once; its skid successor follows without a bubble."""
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
        for _ in range(3):
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
                assert not int(
                    dut.o_iss_out_valid.value
                ), "squashed op escaped recovery"
                assert not int(dut.o_walk_req_valid.value), "phantom issue asked walker"
            dut.i_walk_resp_valid.value = 0
            _issue(dut, correct)
            await _cycle(dut)
            dut.i_iss_valid.value = 0
            await _cycle(dut)
            _check(dut, correct, leaf)
