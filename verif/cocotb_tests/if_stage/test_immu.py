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

"""Standalone instruction-MMU tests at the registered selected-PC seam.

The reference helpers below derive Sv39 matching, physical-page composition,
permissions, PMA faults, and fetch-window formation in Python without
inspecting implementation state.  Directed protocol tests separately pin the
visible-key rule: translated payload is usable only after the state is tagged
with the live registered PC, privilege, and address-space mode.
"""

from dataclasses import dataclass
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


CLOCK_PERIOD_NS = 10
XLEN_MASK = (1 << 64) - 1
VPN_MASK = (1 << 27) - 1
PPN_MASK = (1 << 44) - 1

DFAULT_NONE = 0
DFAULT_PAGE = 2
DFAULT_ACCESS = 3


@dataclass(frozen=True)
class Leaf:
    """Independent description of one walked Sv39 leaf."""

    vpn: int
    ppn: int
    level: int = 0
    perm_x: int = 1
    perm_u: int = 0
    perm_r: int = 1
    perm_w: int = 0
    perm_d: int = 1


@dataclass(frozen=True)
class Window:
    """Architecturally visible IMMU fetch-window result."""

    pa0: int
    pa1: int
    fault0: int = 0
    fault0_page: int = 0
    fault1: int = 0
    fault1_page: int = 0
    line_after_ok: int = 1


def _canonical(va: int) -> bool:
    va &= XLEN_MASK
    sign = (va >> 38) & 1
    high = va >> 39
    return high == (0x1FFFFFF if sign else 0)


def _fetch_pma_ok(address: int) -> bool:
    address &= XLEN_MASK
    return address < 0x0004_0000 or 0x8000_0000 <= address < 0xC000_0000


def _next_page_va(va: int) -> int:
    page_number = ((va & XLEN_MASK) >> 12) + 1
    return ((page_number & ((1 << 52) - 1)) << 12) & XLEN_MASK


def _page_cross(va: int) -> bool:
    return ((va >> 2) & 0x3FF) == 0x3FF


def _next_word_low32(va: int) -> int:
    return (((va & 0xFFFF_FFFF) >> 2) + 1 << 2) & 0xFFFF_FFFF


def _bare_window(va: int) -> Window:
    va &= XLEN_MASK
    next_word = _next_word_low32(va)
    fault0 = int(not _fetch_pma_ok(va))
    word1_va = _next_page_va(va) if _page_cross(va) else va
    fault1 = int(not _fetch_pma_ok(word1_va)) if _page_cross(va) else fault0
    return Window(
        pa0=va & 0xFFFF_FFFF,
        pa1=next_word,
        fault0=fault0,
        fault1=fault1,
    )


def _leaf_matches(leaf: Leaf, vpn: int) -> bool:
    vpn &= VPN_MASK
    if leaf.level == 2:
        return (leaf.vpn >> 18) == (vpn >> 18)
    if leaf.level == 1:
        return (leaf.vpn >> 9) == (vpn >> 9)
    return leaf.vpn == vpn


def _materialized_ppn(leaf: Leaf, vpn: int) -> int:
    ppn20 = leaf.ppn & 0xF_FFFF
    if leaf.level == 2:
        return (ppn20 & ~0x3_FFFF) | (vpn & 0x3_FFFF)
    if leaf.level == 1:
        return (ppn20 & ~0x1FF) | (vpn & 0x1FF)
    return ppn20


def _resolve_word(va: int, leaf: Leaf | None, priv_u: int) -> tuple[int, int, int]:
    """Return (PA, fault, is_page_fault) for one instruction word."""
    va &= XLEN_MASK
    vpn = (va >> 12) & VPN_MASK
    if not _canonical(va):
        return va & 0xFFFF_FFFF, 1, 1
    if leaf is None or not _leaf_matches(leaf, vpn):
        raise AssertionError(f"reference has no leaf for VPN 0x{vpn:x}")
    if not leaf.perm_x or leaf.perm_u != priv_u:
        return va & 0xFFFF_FFFF, 1, 1
    ppn20 = _materialized_ppn(leaf, vpn)
    physical_page = ppn20 << 12
    if leaf.ppn >> 20 or not _fetch_pma_ok(physical_page):
        return va & 0xFFFF_FFFF, 1, 0
    return physical_page | (va & 0xFFF), 0, 0


def _translated_window(
    va: int,
    leaf0: Leaf,
    *,
    priv_u: int = 0,
    leaf1: Leaf | None = None,
    fault1_kind: int | None = None,
) -> Window:
    """Resolve the two-word window independently from the RTL."""
    pa0, fault0, page0 = _resolve_word(va, leaf0, priv_u)
    if not _page_cross(va):
        pa1 = (pa0 & 0xFFFF_F000) | (_next_word_low32(va) & 0xFFF)
        fault1, page1 = fault0, page0
    else:
        va1 = _next_page_va(va)
        if fault1_kind is not None:
            pa1 = va1 & 0xFFFF_FFFF
            fault1 = 1
            page1 = int(fault1_kind == DFAULT_PAGE)
        else:
            chosen_leaf = (
                leaf0 if _leaf_matches(leaf0, (va1 >> 12) & VPN_MASK) else leaf1
            )
            pa1, fault1, page1 = _resolve_word(va1, chosen_leaf, priv_u)
    line_after_ok = int(((pa0 >> 5) & 0x7F) != 0x7F or ((pa0 >> 2) & 0x7) == 0x7)
    return Window(pa0, pa1, fault0, page0, fault1, page1, line_after_ok)


def _drive_idle(dut: Any) -> None:
    dut.i_active.value = 0
    dut.i_priv_u.value = 0
    dut.i_tlb_invalidate.value = 0
    dut.i_pc_update_en.value = 0
    dut.i_pc_d.value = 0
    dut.i_walk_req_ready.value = 0
    dut.i_walk_resp_valid.value = 0
    dut.i_walk_resp_fault_kind.value = DFAULT_NONE
    dut.i_walk_resp_vpn.value = 0
    dut.i_walk_resp_ppn.value = 0
    dut.i_walk_resp_level.value = 0
    dut.i_walk_resp_perm_r.value = 0
    dut.i_walk_resp_perm_w.value = 0
    dut.i_walk_resp_perm_x.value = 0
    dut.i_walk_resp_perm_u.value = 0
    dut.i_walk_resp_perm_d.value = 0


async def _settle() -> None:
    await Timer(1, unit="ns")


async def _cycle(dut: Any) -> None:
    await RisingEdge(dut.i_clk)
    await _settle()


async def _setup(dut: Any) -> None:
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    _drive_idle(dut)
    dut.i_rst.value = 1
    await _cycle(dut)
    await _cycle(dut)
    dut.i_rst.value = 0
    await _settle()


async def _move_pc(dut: Any, pc: int) -> None:
    dut.i_pc_d.value = pc & XLEN_MASK
    dut.i_pc_update_en.value = 1
    await _cycle(dut)
    dut.i_pc_update_en.value = 0
    assert int(dut.o_pc.value) == (pc & XLEN_MASK)


def _assert_faults_zero(dut: Any) -> None:
    assert int(dut.o_fault0.value) == 0
    assert int(dut.o_fault0_page.value) == 0
    assert int(dut.o_fault1.value) == 0
    assert int(dut.o_fault1_page.value) == 0


def _assert_invisible(dut: Any) -> None:
    assert int(dut.o_pa_valid.value) == 0
    _assert_faults_zero(dut)


def _assert_window(dut: Any, expected: Window) -> None:
    assert int(dut.o_pa_valid.value) == 1
    assert int(dut.o_pa0.value) == expected.pa0
    assert int(dut.o_pa1.value) == expected.pa1
    assert int(dut.o_fault0.value) == expected.fault0
    assert int(dut.o_fault0_page.value) == expected.fault0_page
    assert int(dut.o_fault1.value) == expected.fault1
    assert int(dut.o_fault1_page.value) == expected.fault1_page
    assert int(dut.o_line_after_ok.value) == expected.line_after_ok


def _drive_response(
    dut: Any,
    *,
    vpn: int,
    fault_kind: int = DFAULT_NONE,
    ppn: int = 0,
    level: int = 0,
    perm_x: int = 1,
    perm_u: int = 0,
    perm_r: int = 1,
    perm_w: int = 0,
    perm_d: int = 1,
) -> None:
    dut.i_walk_resp_fault_kind.value = fault_kind
    dut.i_walk_resp_vpn.value = vpn & VPN_MASK
    dut.i_walk_resp_ppn.value = ppn & PPN_MASK
    dut.i_walk_resp_level.value = level
    dut.i_walk_resp_perm_r.value = perm_r
    dut.i_walk_resp_perm_w.value = perm_w
    dut.i_walk_resp_perm_x.value = perm_x
    dut.i_walk_resp_perm_u.value = perm_u
    dut.i_walk_resp_perm_d.value = perm_d
    dut.i_walk_resp_valid.value = 1


async def _pulse_response(dut: Any, **response: int) -> None:
    _drive_response(dut, **response)
    await _cycle(dut)
    dut.i_walk_resp_valid.value = 0
    await _settle()


async def _wait_for_request(dut: Any, vpn: int, *, max_cycles: int = 6) -> None:
    for _ in range(max_cycles + 1):
        await _settle()
        if int(dut.o_walk_req_valid.value):
            assert int(dut.o_walk_vpn.value) == (vpn & VPN_MASK)
            return
        await _cycle(dut)
    raise AssertionError(f"no walk request for VPN 0x{vpn:x}")


async def _accept_request(dut: Any, vpn: int) -> None:
    await _wait_for_request(dut, vpn)
    dut.i_walk_req_ready.value = 1
    await _cycle(dut)
    dut.i_walk_req_ready.value = 0


async def _return_leaf(dut: Any, leaf: Leaf) -> None:
    """Complete the currently owned walk with ``leaf``."""
    await _pulse_response(
        dut,
        vpn=leaf.vpn,
        ppn=leaf.ppn,
        level=leaf.level,
        perm_x=leaf.perm_x,
        perm_u=leaf.perm_u,
        perm_r=leaf.perm_r,
        perm_w=leaf.perm_w,
        perm_d=leaf.perm_d,
    )


@cocotb.test()
async def test_bare_exact_selected_pc_window(dut: Any) -> None:
    """Bare mode is direct, bubble-free, and exact at every PMA seam."""
    await _setup(dut)

    cases = (
        0,
        0x0000_0002,
        0x0003_FFFC,
        0x7FFF_FFFC,
        0xBFFF_FFFC,
        0x1_0000_1002,
        0xFFFF_FFFF_FFFF_FFFF,
    )
    for pc in cases:
        await _move_pc(dut, pc)
        _assert_window(dut, _bare_window(pc))
        assert int(dut.o_walk_req_valid.value) == 0

        # A held selected PC is still a direct result, not a shadow replay.
        await _cycle(dut)
        _assert_window(dut, _bare_window(pc))


@cocotb.test()
async def test_warm_translation_retags_once_per_pc_movement(dut: Any) -> None:
    """Warm same-page/different-page motion gets one invisible retag cycle."""
    await _setup(dut)
    leaves = (
        Leaf(vpn=0x4, ppn=0x20),
        Leaf(vpn=0x5, ppn=0x21),
        Leaf(vpn=0x6, ppn=0x22),
    )
    pc_a = 0x0000_4040
    pc_a_same_page = 0x0000_4FE2
    pc_b = 0x0000_5040
    pc_c = 0x0000_6040
    await _move_pc(dut, pc_a)
    dut.i_active.value = 1
    await _settle()
    _assert_invisible(dut)
    await _cycle(dut)
    await _accept_request(dut, leaves[0].vpn)
    await _return_leaf(dut, leaves[0])
    _assert_window(dut, _translated_window(pc_a, leaves[0]))

    await _move_pc(dut, pc_a_same_page)
    _assert_invisible(dut)
    await _cycle(dut)
    _assert_window(dut, _translated_window(pc_a_same_page, leaves[0]))
    assert int(dut.o_line_after_ok.value) == 0

    await _move_pc(dut, pc_b)
    _assert_invisible(dut)
    await _cycle(dut)
    await _accept_request(dut, leaves[1].vpn)
    await _return_leaf(dut, leaves[1])
    _assert_window(dut, _translated_window(pc_b, leaves[1]))

    # Loading the same selected value does not invalidate an exact live tag.
    await _move_pc(dut, pc_b)
    _assert_window(dut, _translated_window(pc_b, leaves[1]))

    # Populate C, then return to A so the consecutive movement below is warm
    # at every intermediate and final page.
    await _move_pc(dut, pc_c)
    _assert_invisible(dut)
    await _cycle(dut)
    await _accept_request(dut, leaves[2].vpn)
    await _return_leaf(dut, leaves[2])
    _assert_window(dut, _translated_window(pc_c, leaves[2]))
    await _move_pc(dut, pc_a)
    _assert_invisible(dut)
    await _cycle(dut)
    _assert_window(dut, _translated_window(pc_a, leaves[0]))

    # A -> B -> C on consecutive edges may never publish the intermediate
    # key after the upstream register already names C.
    dut.i_pc_d.value = pc_b
    dut.i_pc_update_en.value = 1
    await _cycle(dut)
    _assert_invisible(dut)
    dut.i_pc_d.value = pc_c
    await _cycle(dut)
    dut.i_pc_update_en.value = 0
    assert int(dut.o_pc.value) == pc_c
    _assert_invisible(dut)
    assert int(dut.o_walk_req_valid.value) == 0
    await _cycle(dut)
    _assert_window(dut, _translated_window(pc_c, leaves[2]))


@cocotb.test()
async def test_mode_privilege_and_invalidate_mask_stale_state(dut: Any) -> None:
    """Mode/privilege/flush changes cannot expose an old tagged payload."""
    await _setup(dut)
    pc = 0x0000_8040
    leaf = Leaf(vpn=pc >> 12, ppn=0x30, perm_u=1)
    await _move_pc(dut, pc)
    dut.i_priv_u.value = 1
    dut.i_active.value = 1
    await _settle()
    _assert_invisible(dut)
    await _cycle(dut)
    await _accept_request(dut, leaf.vpn)
    await _return_leaf(dut, leaf)
    _assert_window(dut, _translated_window(pc, leaf, priv_u=1))

    # Permission state is part of the visible identity.  The S-mode retag
    # resolves as a page fault because this leaf is user-only.
    dut.i_priv_u.value = 0
    await _settle()
    _assert_invisible(dut)
    await _cycle(dut)
    expected_s = _translated_window(pc, leaf, priv_u=0)
    _assert_window(dut, expected_s)
    assert expected_s.fault0_page == 1

    # Bare is direct immediately.  Holding Bare across an edge retires the
    # translated tag, so re-entering translation cannot resurrect it.
    dut.i_active.value = 0
    await _settle()
    _assert_window(dut, _bare_window(pc))
    await _cycle(dut)
    dut.i_active.value = 1
    await _settle()
    _assert_invisible(dut)
    await _cycle(dut)
    _assert_window(dut, expected_s)

    # Invalidate masks the result in its assertion cycle.
    dut.i_tlb_invalidate.value = 1
    await _settle()
    _assert_invisible(dut)
    await _cycle(dut)
    dut.i_tlb_invalidate.value = 0
    await _settle()
    _assert_invisible(dut)

    # Re-establish an accepted owner, then prove invalidate wins over its
    # simultaneous clean response rather than merely ignoring an unowned one.
    await _cycle(dut)
    await _accept_request(dut, leaf.vpn)
    dut.i_tlb_invalidate.value = 1
    _drive_response(dut, vpn=leaf.vpn, ppn=0x31, perm_u=0)
    await _settle()
    _assert_invisible(dut)
    await _cycle(dut)
    dut.i_tlb_invalidate.value = 0
    dut.i_walk_resp_valid.value = 0
    await _settle()
    _assert_invisible(dut)
    await _wait_for_request(dut, leaf.vpn)


@cocotb.test()
async def test_walk_backpressure_and_retarget_edge_races(dut: Any) -> None:
    """PC loads neither suppress a live request nor expose an old response."""
    await _setup(dut)
    pc_a = 0x0001_0040
    pc_b = 0x0001_2040
    pc_c = 0x0001_4040
    vpn_a = pc_a >> 12
    vpn_b = pc_b >> 12
    vpn_c = pc_c >> 12
    leaf_a = Leaf(vpn=vpn_a, ppn=0x31)
    leaf_b = Leaf(vpn=vpn_b, ppn=0x32)
    leaf_c = Leaf(vpn=vpn_c, ppn=0x33)

    # With request backpressure, retargeting before acceptance replaces A;
    # the first transaction the walker accepts must belong to B.
    await _move_pc(dut, pc_a)
    dut.i_active.value = 1
    await _cycle(dut)
    await _wait_for_request(dut, vpn_a)
    await _move_pc(dut, pc_b)
    _assert_invisible(dut)
    await _cycle(dut)
    await _wait_for_request(dut, vpn_b)
    await _accept_request(dut, vpn_b)

    # B's owned response and the upstream B -> A PC load share an edge.  The
    # resolver is allowed to consume/install B, but exact post-edge tag matching
    # must hide every bit of B's result while the registered PC names A.
    dut.i_pc_d.value = pc_a
    dut.i_pc_update_en.value = 1
    _drive_response(dut, vpn=vpn_b, ppn=leaf_b.ppn)
    await _cycle(dut)
    dut.i_pc_update_en.value = 0
    dut.i_walk_resp_valid.value = 0
    assert int(dut.o_pc.value) == pc_a
    _assert_invisible(dut)
    assert int(dut.o_walk_req_valid.value) == 0

    # The response recheck expires while A is captured.  Its miss request must
    # remain asserted even when the harness independently arms an A -> C PC
    # load; accepting that edge records A as the stale owner.
    await _cycle(dut)
    await _wait_for_request(dut, vpn_a)
    dut.i_pc_d.value = pc_c
    dut.i_pc_update_en.value = 1
    dut.i_walk_req_ready.value = 1
    await _settle()
    assert int(dut.o_walk_req_valid.value) == 1
    assert int(dut.o_walk_vpn.value) == vpn_a
    await _cycle(dut)
    dut.i_pc_update_en.value = 0
    dut.i_walk_req_ready.value = 0
    assert int(dut.o_pc.value) == pc_c
    _assert_invisible(dut)
    assert int(dut.o_walk_req_valid.value) == 0

    # C can be captured while A owns the response slot, but cannot issue until
    # A's late result has drained and the mandatory install/recheck cycle ends.
    await _cycle(dut)
    assert int(dut.o_walk_req_valid.value) == 0

    await _return_leaf(dut, leaf_a)
    _assert_invisible(dut)
    assert int(dut.o_walk_req_valid.value) == 0
    await _wait_for_request(dut, vpn_c, max_cycles=3)
    await _accept_request(dut, vpn_c)
    await _return_leaf(dut, leaf_c)
    _assert_window(dut, _translated_window(pc_c, leaf_c))


@cocotb.test()
async def test_translation_faults_and_refusal_memo(dut: Any) -> None:
    """Pin noncanonical, permission, PMA, and memoized walk refusals."""
    await _setup(dut)

    # Non-canonical VAs resolve to an instruction page fault without walking.
    noncanon = 1 << 39
    await _move_pc(dut, noncanon)
    dut.i_active.value = 1
    await _settle()
    _assert_invisible(dut)
    await _cycle(dut)
    _assert_window(
        dut,
        Window(
            pa0=noncanon & 0xFFFF_FFFF,
            pa1=_next_word_low32(noncanon),
            fault0=1,
            fault0_page=1,
            fault1=1,
            fault1_page=1,
            line_after_ok=1,
        ),
    )
    assert int(dut.o_walk_req_valid.value) == 0

    episodes = (
        (0x0001_4040, Leaf(vpn=0x14, ppn=0x50, perm_x=0), 1),
        (0x0001_6040, Leaf(vpn=0x16, ppn=0x51, perm_u=1), 1),
        (0x0001_8040, Leaf(vpn=0x18, ppn=0x40000), 0),
        (0x0001_A040, Leaf(vpn=0x1A, ppn=1 << 20), 0),
    )
    for pc, leaf, page_kind in episodes:
        await _move_pc(dut, pc)
        _assert_invisible(dut)
        await _cycle(dut)
        await _accept_request(dut, leaf.vpn)
        await _return_leaf(dut, leaf)
        expected = _translated_window(pc, leaf)
        _assert_window(dut, expected)
        assert expected.fault0 == 1
        assert expected.fault0_page == page_kind
        assert int(dut.o_walk_req_valid.value) == 0

    # A refused walk is memoized.  Revisiting its VPN resolves from the memo
    # without asking again until an invalidate clears both TLB and memo.
    refused_pc = 0x0001_C040
    other_pc = 0x0001_E040
    refused_vpn = refused_pc >> 12
    other_leaf = Leaf(vpn=other_pc >> 12, ppn=0x34)
    await _move_pc(dut, refused_pc)
    await _cycle(dut)
    await _accept_request(dut, refused_vpn)
    await _pulse_response(dut, vpn=refused_vpn, fault_kind=DFAULT_PAGE)
    expected_refusal = Window(
        pa0=refused_pc,
        pa1=_next_word_low32(refused_pc),
        fault0=1,
        fault0_page=1,
        fault1=1,
        fault1_page=1,
        line_after_ok=1,
    )
    _assert_window(dut, expected_refusal)

    await _move_pc(dut, other_pc)
    await _cycle(dut)
    await _accept_request(dut, other_leaf.vpn)
    await _return_leaf(dut, other_leaf)
    _assert_window(dut, _translated_window(other_pc, other_leaf))
    await _move_pc(dut, refused_pc)
    _assert_invisible(dut)
    await _cycle(dut)
    _assert_window(dut, expected_refusal)
    assert int(dut.o_walk_req_valid.value) == 0

    dut.i_tlb_invalidate.value = 1
    await _cycle(dut)
    dut.i_tlb_invalidate.value = 0
    _assert_invisible(dut)
    await _accept_request(dut, refused_vpn)
    await _pulse_response(dut, vpn=refused_vpn, fault_kind=DFAULT_ACCESS)
    expected_access_refusal = Window(
        pa0=refused_pc,
        pa1=_next_word_low32(refused_pc),
        fault0=1,
        fault1=1,
        line_after_ok=1,
    )
    _assert_window(dut, expected_access_refusal)

    # ACCESS refusals use the same memo path but preserve their distinct
    # non-page classification on a later revisit.
    other_noncanon = (1 << 39) | 0x2000
    await _move_pc(dut, other_noncanon)
    await _cycle(dut)
    await _move_pc(dut, refused_pc)
    await _cycle(dut)
    _assert_window(dut, expected_access_refusal)
    assert int(dut.o_walk_req_valid.value) == 0


@cocotb.test()
async def test_cross_page_resolution_and_exact_successor_vpn(dut: Any) -> None:
    """Resolve unrelated 4K pages, refusals, and superpage crossings."""
    await _setup(dut)
    pc = 0x0020_1FFC
    vpn0 = pc >> 12
    vpn1 = vpn0 + 1
    leaf0 = Leaf(vpn=vpn0, ppn=0x10)
    leaf1 = Leaf(vpn=vpn1, ppn=0x80000)

    await _move_pc(dut, pc)
    dut.i_active.value = 1
    await _cycle(dut)
    await _accept_request(dut, vpn0)
    await _pulse_response(dut, vpn=vpn0, ppn=leaf0.ppn)
    _assert_invisible(dut)
    await _accept_request(dut, vpn1)
    await _pulse_response(dut, vpn=vpn1, ppn=leaf1.ppn)
    _assert_window(dut, _translated_window(pc, leaf0, leaf1=leaf1))

    # A refusal for the exact next page faults word 1 only.
    pc_refuse = 0x0020_3FFC
    vpn_refuse0 = pc_refuse >> 12
    vpn_refuse1 = vpn_refuse0 + 1
    leaf_refuse0 = Leaf(vpn=vpn_refuse0, ppn=0x11)
    dut.i_tlb_invalidate.value = 1
    await _cycle(dut)
    dut.i_tlb_invalidate.value = 0
    await _move_pc(dut, pc_refuse)
    await _cycle(dut)
    await _accept_request(dut, vpn_refuse0)
    await _pulse_response(dut, vpn=vpn_refuse0, ppn=leaf_refuse0.ppn)
    await _accept_request(dut, vpn_refuse1)
    await _pulse_response(dut, vpn=vpn_refuse1, fault_kind=DFAULT_PAGE)
    _assert_window(
        dut,
        _translated_window(
            pc_refuse,
            leaf_refuse0,
            fault1_kind=DFAULT_PAGE,
        ),
    )

    # A 2 MiB interior page crossing derives word 1 from the same leaf and
    # therefore needs no second walk.
    pc_super = 0x0040_1FFC
    vpn_super = pc_super >> 12
    leaf_super = Leaf(vpn=vpn_super, ppn=0x80000, level=1)
    dut.i_tlb_invalidate.value = 1
    await _cycle(dut)
    dut.i_tlb_invalidate.value = 0
    await _move_pc(dut, pc_super)
    await _cycle(dut)
    await _accept_request(dut, vpn_super)
    await _pulse_response(
        dut,
        vpn=vpn_super,
        ppn=leaf_super.ppn,
        level=leaf_super.level,
    )
    _assert_window(dut, _translated_window(pc_super, leaf_super))
    assert int(dut.o_walk_req_valid.value) == 0

    # At the end of that superpage, the exact successor VPN is independent
    # and must be walked rather than derived through the leaf boundary.
    pc_super_end = 0x005F_FFFC
    vpn_super_end = pc_super_end >> 12
    next_leaf = Leaf(vpn=vpn_super_end + 1, ppn=0x12)
    await _move_pc(dut, pc_super_end)
    _assert_invisible(dut)
    await _cycle(dut)
    # The installed level-1 leaf covers word 0, so only the successor asks.
    await _wait_for_request(dut, vpn_super_end + 1)
    await _accept_request(dut, vpn_super_end + 1)
    await _pulse_response(dut, vpn=next_leaf.vpn, ppn=next_leaf.ppn)
    _assert_window(dut, _translated_window(pc_super_end, leaf_super, leaf1=next_leaf))

    # The same derivation rule applies to a 1 GiB interior crossing: the
    # response's aligned PPN supplies the high bits and the VA supplies both
    # lower VPN fields, with no independent successor walk.
    pc_giga = 0x4000_1FFC
    vpn_giga = pc_giga >> 12
    leaf_giga = Leaf(vpn=vpn_giga, ppn=0x80000, level=2)
    dut.i_tlb_invalidate.value = 1
    await _cycle(dut)
    dut.i_tlb_invalidate.value = 0
    await _move_pc(dut, pc_giga)
    await _cycle(dut)
    await _accept_request(dut, vpn_giga)
    await _return_leaf(dut, leaf_giga)
    _assert_window(dut, _translated_window(pc_giga, leaf_giga))
    assert int(dut.o_walk_req_valid.value) == 0
