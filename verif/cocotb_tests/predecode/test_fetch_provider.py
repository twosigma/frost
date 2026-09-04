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

"""Unit tests for the high-address fetch_provider (fetch buffer, fills).

The bench plays both of the provider's neighbours: the core, which drives i_pc
like pc_controller would and consumes valid windows, and the L1I line port
slave, which accepts fill requests and returns patterned lines. The tests cover
low addresses staying out of the provider, DDR fills with the sequential walk
across a line boundary (straddle plus next-line prefetch), ask retargeting when
a redirect lands while unserved or immediately after an accepted window,
back-to-back publish throughput, and the invalidate-discard of an in-flight
fill. The RTL also carries a simulation-only cycle-by-cycle oracle for the
folded registered readiness/tag-match state.
"""

import importlib.util
from pathlib import Path
from types import ModuleType
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

CLOCK_PERIOD_NS = 10
LINE_BYTES = 32
DDR_BASE = 0x8000_0000
TIMEOUT = 2_000


def _load_generator() -> ModuleType:
    """Import the offline predecode generator as the sideband golden model."""
    path = (
        Path(__file__).resolve().parents[3]
        / "sw"
        / "common"
        / "generate_imem_predecode_init.py"
    )
    spec = importlib.util.spec_from_file_location("generate_imem_predecode_init", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_GENERATOR = _load_generator()


def _word_at(addr: int) -> int:
    """Return a deterministic 32-bit pattern for any word address."""
    return (addr * 0x01000193 + 0x5BD1E995) & 0xFFFF_FFFF


def _line_at(line_addr: int) -> int:
    """Build the 256-bit line whose byte address is line_addr."""
    value = 0
    for w in range(LINE_BYTES // 4):
        value |= _word_at(line_addr + 4 * w) << (32 * w)
    return value


def _drive_pc(dut: Any, pc: int) -> None:
    """Drive the fetch ask: the VA and, translation off, its identical PA pair."""
    dut.i_pc.value = pc
    dut.i_pa0.value = pc & 0xFFFF_FFFF
    dut.i_pa1.value = (pc + 4) & 0xFFFF_FFFF


def _clear_inputs(dut: Any) -> None:
    _drive_pc(dut, 0)
    # Physical side of the ask (Phase 3 M5): resolved, clean, contiguous.
    dut.i_pa_valid.value = 1
    dut.i_fault0.value = 0
    dut.i_fault0_page.value = 0
    dut.i_fault1.value = 0
    dut.i_fault1_page.value = 0
    dut.i_line_after_ok.value = 1
    dut.i_retarget.value = 0
    dut.i_fetch_replay_consume.value = 0
    dut.i_pipeline_stall.value = 0
    dut.i_l1i_miss_outstanding.value = 0
    dut.i_line_req_ready.value = 0
    dut.i_line_resp_valid.value = 0
    dut.i_line_resp_id.value = 0
    dut.i_line_resp_rdata.value = 0
    dut.i_invalidate.value = 0


async def _setup(dut: Any) -> None:
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await FallingEdge(dut.i_clk)


async def _line_slave(
    dut: Any,
    latency: int,
    log: list[int],
    *,
    reorder: bool = False,
    accept_gap: int = 0,
    inflight: list[tuple[int, int]] | None = None,
) -> None:
    """Serve patterned lines on the line port with several requests in flight.

    Every request is accepted (after ``accept_gap`` idle cycles) and answered
    ``latency`` cycles later, tagged with its id. With ``reorder`` the slave
    answers the most recent request first whenever two are pending, so the
    provider's id routing is exercised. ``inflight`` (if given) mirrors the
    slave's pending (id, addr) list for the tests to inspect.
    """
    pending: list[tuple[int, int, int]] = []  # (due_cycle, id, addr)
    cycle = 0
    gap = 0
    while True:
        await FallingEdge(dut.i_clk)
        cycle += 1
        # Response side first (the provider sees it this cycle).
        dut.i_line_resp_valid.value = 0
        due = [e for e in pending if e[0] <= cycle]
        if due:
            entry = due[-1] if reorder else due[0]
            pending.remove(entry)
            dut.i_line_resp_valid.value = 1
            dut.i_line_resp_id.value = entry[1]
            dut.i_line_resp_rdata.value = _line_at(entry[2])
        # Request side: accept one per cycle unless in an accept gap.
        dut.i_line_req_ready.value = 0
        if gap > 0:
            gap -= 1
        elif int(dut.o_line_req_valid.value) == 1:
            addr = int(dut.o_line_req_addr.value)
            rid = int(dut.o_line_req_id.value)
            log.append(addr)
            pending.append((cycle + latency, rid, addr))
            dut.i_line_req_ready.value = 1
            gap = accept_gap
        if inflight is not None:
            inflight[:] = [(e[1], e[2]) for e in pending]


async def _wait_valid(dut: Any) -> None:
    for _ in range(TIMEOUT):
        await FallingEdge(dut.i_clk)
        if int(dut.o_instr_valid.value) == 1:
            return
    raise AssertionError("o_instr_valid never asserted")


async def _wait_window(dut: Any, addr: int) -> None:
    """Wait until the valid window for addr is presented, then verify it.

    Used for initial alignment after a pc jump. Per the contract, valid
    cycles for the previous owed ask (the post-reset ask 0, or the stale
    post-redirect window) may pass first. The core squashes those with its
    holdoff; the bench skips them.
    """
    base = addr & ~0x3
    want0 = _word_at(base)
    want1 = _word_at(base + 4)
    want = (want1 << 32) | want0
    for _ in range(TIMEOUT):
        await FallingEdge(dut.i_clk)
        if int(dut.o_instr_valid.value) == 1 and int(dut.o_instr.value) == want:
            _check_window(dut, addr)
            return
    raise AssertionError(f"window for 0x{addr:08x} never presented")


def _check_window(dut: Any, addr: int) -> None:
    """Assert the presented window is the two words at addr (word-aligned)."""
    base = addr & ~0x3
    want0 = _word_at(base)
    want1 = _word_at(base + 4)
    got = int(dut.o_instr.value)
    assert got == ((want1 << 32) | want0), (
        f"window @0x{addr:08x}: got 0x{got:016x} "
        f"want 0x{((want1 << 32) | want0):016x}"
    )
    sb = int(dut.o_instr_sideband.value)
    width = _GENERATOR.SIDEBAND_WIDTH
    want_sb = (_GENERATOR.make_sideband(want1) << width) | _GENERATOR.make_sideband(
        want0
    )
    hex_digits = (2 * width + 3) // 4
    assert sb == want_sb, (
        f"sideband @0x{addr:08x}: got 0x{sb:0{hex_digits}x} "
        f"want 0x{want_sb:0{hex_digits}x}"
    )
    bank_sel = (base >> 2) & 1
    assert int(dut.o_instr_bank_sel_r.value) == bank_sel

    # The provider's IF timing replicas carry the same sideband subsets in
    # stable physical {odd,even} order.  Exercise both capture-edge orderings
    # as the walk alternates word parity.
    sb0 = _GENERATOR.make_sideband(want0)
    sb1 = _GENERATOR.make_sideband(want1)
    metadata0 = _GENERATOR.make_pc_metadata_replica(want0, sb0)
    metadata1 = _GENERATOR.make_pc_metadata_replica(want1, sb1)
    pairability0 = (((sb0 >> _GENERATOR.SB_PAIRABLE_NATIVE_LO) & 1) << 1) | (
        (sb0 >> _GENERATOR.SB_EVEN_LOCAL_PAIR_VALID) & 1
    )
    pairability1 = (((sb1 >> _GENERATOR.SB_PAIRABLE_NATIVE_LO) & 1) << 1) | (
        (sb1 >> _GENERATOR.SB_EVEN_LOCAL_PAIR_VALID) & 1
    )
    slot2_start0 = (sb0 >> _GENERATOR.SB_SLOT2_START_VALID_LO) & 1
    slot2_start1 = (sb1 >> _GENERATOR.SB_SLOT2_START_VALID_LO) & 1
    if bank_sel:
        want_metadata = (metadata0 << 4) | metadata1
        want_pairability = (pairability0 << 2) | pairability1
        want_slot2_start = (slot2_start0 << 1) | slot2_start1
    else:
        want_metadata = (metadata1 << 4) | metadata0
        want_pairability = (pairability1 << 2) | pairability0
        want_slot2_start = (slot2_start1 << 1) | slot2_start0
    assert int(dut.o_pc_metadata_by_parity.value) == want_metadata
    assert int(dut.o_pc_pairability_by_parity.value) == want_pairability
    assert int(dut.o_slot2_start_valid_lo_by_parity.value) == want_slot2_start

    served_word = (addr >> 2) & 0x3FFF_FFFF
    assert int(dut.o_served_word.value) == served_word
    assert int(dut.o_served_last_word.value) == ((served_word + 1) & 0x3FFF_FFFF)
    assert int(dut.o_served_prev_word.value) == ((served_word - 1) & 0x3FFF_FFFF)
    assert int(dut.o_served_prev_word_valid.value) == int(served_word != 0)


@cocotb.test()
async def test_low_addresses_stay_idle(dut: Any) -> None:
    """Low BRAM fetches are handled outside this provider."""
    await _setup(dut)
    reqs: list[int] = []
    cocotb.start_soon(_line_slave(dut, latency=2, log=reqs))

    for pc in (0x100, 0x104, 0x108, 0x10C, 0x200):
        _drive_pc(dut, pc)
        await FallingEdge(dut.i_clk)
        assert int(dut.o_instr_valid.value) == 0
        assert int(dut.o_line_req_valid.value) == 0

    assert reqs == []


@cocotb.test()
async def test_ddr_fill_walk_and_straddle(dut: Any) -> None:
    """DDR quadrant: fill, sequential walk, line straddle, prefetch."""
    await _setup(dut)
    reqs: list[int] = []
    cocotb.start_soon(_line_slave(dut, latency=6, log=reqs))

    await FallingEdge(dut.i_clk)
    _drive_pc(dut, DDR_BASE)
    await _wait_window(dut, DDR_BASE)
    # The straddle rule requires word DDR_BASE+4 too (same line here), and
    # the prefetch should already be chasing the next line.
    assert reqs[0] == DDR_BASE

    # Walk the whole first line; the boundary window (offset 0x1C) needs the
    # prefetched second line and must stay valid once it arrives.
    pc = DDR_BASE
    for _ in range(7):
        pc += 4
        _drive_pc(dut, pc)
        await _wait_valid(dut)
        _check_window(dut, pc)
    assert DDR_BASE + 32 in reqs  # next-line prefetch happened

    # Continue into the second line and the third (prefetch keeps ahead).
    for _ in range(8):
        pc += 4
        _drive_pc(dut, pc)
        await _wait_valid(dut)
        _check_window(dut, pc)
    assert DDR_BASE + 64 in reqs


@cocotb.test()
async def test_ready_windows_publish_back_to_back(dut: Any) -> None:
    """Folding the next-ask match into readiness adds no delivery bubble."""
    await _setup(dut)
    reqs: list[int] = []
    cocotb.start_soon(_line_slave(dut, latency=2, log=reqs))

    await FallingEdge(dut.i_clk)
    _drive_pc(dut, DDR_BASE)
    await _wait_window(dut, DDR_BASE)

    # All of these windows live in the already-resident first line.  A valid
    # cycle selects the live PC as fetch_addr and ask_d on the same edge, so the
    # next window must publish immediately on the following cycle.
    for offset in (4, 8, 12, 16):
        _drive_pc(dut, DDR_BASE + offset)
        await FallingEdge(dut.i_clk)
        assert int(dut.o_instr_valid.value) == 1, f"delivery bubble at +0x{offset:x}"
        _check_window(dut, DDR_BASE + offset)


@cocotb.test()
async def test_redirect_while_unserved_retargets(dut: Any) -> None:
    """A redirect during a miss abandons the old ask for the new target."""
    await _setup(dut)
    reqs: list[int] = []
    cocotb.start_soon(_line_slave(dut, latency=20, log=reqs))

    await FallingEdge(dut.i_clk)
    _drive_pc(dut, DDR_BASE)  # miss; fill takes 20+ cycles
    for _ in range(5):
        await FallingEdge(dut.i_clk)
    for _ in range(3):
        await FallingEdge(dut.i_clk)
        assert int(dut.o_instr_valid.value) == 0

    # Redirect while unserved: the core moves the PC once (then holds).
    target = DDR_BASE + 0x1000
    _drive_pc(dut, target)
    await _wait_window(dut, target)
    assert DDR_BASE in reqs and target in reqs


@cocotb.test()
async def test_explicit_redirect_after_accepted_window_retargets(dut: Any) -> None:
    """An architectural pulse overrides accepted-PC movement classification."""
    await _setup(dut)
    reqs: list[int] = []
    cocotb.start_soon(_line_slave(dut, latency=3, log=reqs))

    await FallingEdge(dut.i_clk)
    _drive_pc(dut, DDR_BASE)
    await _wait_window(dut, DDR_BASE)

    # The accepted window points fetch at a cold address whose translation has
    # not resolved. This becomes the normal next owed ask and sets
    # accepted_prev_q, but cannot launch memory traffic.
    old_ask = DDR_BASE + 0x1000
    _drive_pc(dut, old_ask)
    dut.i_pa_valid.value = 0
    await FallingEdge(dut.i_clk)
    assert int(dut.accepted_prev_q.value) == 1
    assert int(dut.ask_q.value) == old_ask
    assert int(dut.o_instr_valid.value) == 0

    # A recovery now lands immediately after that accepted cycle. Movement by
    # itself is classified as flow here, so the narrow architectural pulse has
    # to override it and replace the unresolved ask at the next edge.
    target = DDR_BASE + 0x2000
    _drive_pc(dut, target)
    dut.i_pa_valid.value = 1
    await Timer(1, unit="ns")
    assert int(dut.retarget_now.value) == 0
    dut.i_retarget.value = 1
    await Timer(1, unit="ns")
    assert int(dut.retarget_now.value) == 1
    await FallingEdge(dut.i_clk)
    assert int(dut.ask_q.value) == target
    dut.i_retarget.value = 0

    await _wait_window(dut, target)
    assert old_ask not in reqs
    assert target in reqs


@cocotb.test()
async def test_accepted_leading_prediction_keeps_branch_ask_until_served(
    dut: Any,
) -> None:
    """Accepted-PC movement without a retarget pulse preserves the owed ask."""
    await _setup(dut)
    reqs: list[int] = []
    cocotb.start_soon(_line_slave(dut, latency=12, log=reqs))

    await FallingEdge(dut.i_clk)
    _drive_pc(dut, DDR_BASE)
    await _wait_window(dut, DDR_BASE)

    # The accepted resident window advances the owed ask to a cold branch PC.
    branch_pc = DDR_BASE + 0x1000
    target = DDR_BASE + 0x2000
    _drive_pc(dut, branch_pc)
    await FallingEdge(dut.i_clk)
    assert int(dut.accepted_prev_q.value) == 1
    assert int(dut.ask_q.value) == branch_pc
    assert not dut.o_instr_valid.value

    # Model a leading slot-1 prediction: fetch moves to the target immediately,
    # but IF supplies no cached-provider retarget pulse. The accepted-predecessor
    # classifier must keep the branch response owed.
    _drive_pc(dut, target)
    await Timer(1, unit="ns")
    assert not dut.i_retarget.value
    assert not dut.retarget_now.value

    branch_served = False
    for _ in range(TIMEOUT):
        await FallingEdge(dut.i_clk)
        if dut.o_instr_valid.value:
            _check_window(dut, branch_pc)
            branch_served = True
            break
        assert int(dut.ask_q.value) == branch_pc
    assert branch_served, "the retained branch ask never produced its window"

    # Only after that owed response is presented may the ask advance to the
    # target that has remained on the live PC input.
    await FallingEdge(dut.i_clk)
    assert int(dut.ask_q.value) == target
    assert branch_pc in reqs


@cocotb.test()
async def test_invalidate_discards_inflight_fill(dut: Any) -> None:
    """i_invalidate mid-fill: the completing line must not validate a slot."""
    await _setup(dut)
    reqs: list[int] = []
    cocotb.start_soon(_line_slave(dut, latency=12, log=reqs))

    await FallingEdge(dut.i_clk)
    _drive_pc(dut, DDR_BASE)
    # Let the fill launch, then invalidate mid-flight.
    for _ in range(4):
        await FallingEdge(dut.i_clk)
    assert len(reqs) >= 1
    dut.i_invalidate.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_invalidate.value = 0

    # The discarded fill completes; valid may only come from a fresh fill of
    # the line, so a second request for DDR_BASE must be observed by the time
    # the window turns valid.
    await _wait_valid(dut)
    _check_window(dut, DDR_BASE)
    assert reqs.count(DDR_BASE) >= 2, f"expected a refill of the line, reqs={reqs}"


@cocotb.test()
async def test_cold_redirect_keeps_two_fills_in_flight(dut: Any) -> None:
    """A cold window's line and the following line fill concurrently."""
    await _setup(dut)
    reqs: list[int] = []
    inflight: list[tuple[int, int]] = []
    cocotb.start_soon(_line_slave(dut, latency=10, log=reqs, inflight=inflight))

    await FallingEdge(dut.i_clk)
    _drive_pc(dut, DDR_BASE)
    # Both requests go out well before the first response can land.
    for _ in range(6):
        await FallingEdge(dut.i_clk)
    assert reqs[:2] == [DDR_BASE, DDR_BASE + 32], f"requests: {[hex(r) for r in reqs]}"
    assert len(inflight) == 2, f"expected two fills in flight, slave holds {inflight}"
    ids = {rid for rid, _ in inflight}
    assert ids == {0, 1}, f"fill ids must be the slot numbers: {ids}"

    await _wait_window(dut, DDR_BASE)
    # The straddling boundary window needs the second line, which is already
    # resident: it publishes with no further request.
    n_reqs = len(reqs)
    _drive_pc(dut, DDR_BASE + 0x1C)
    await _wait_valid(dut)
    _check_window(dut, DDR_BASE + 0x1C)
    assert len(reqs) == n_reqs, "straddle window re-requested a resident line"


@cocotb.test()
async def test_out_of_order_fill_responses(dut: Any) -> None:
    """The following line may land before the window's own line."""
    await _setup(dut)
    reqs: list[int] = []
    cocotb.start_soon(_line_slave(dut, latency=8, log=reqs, reorder=True))

    await FallingEdge(dut.i_clk)
    _drive_pc(dut, DDR_BASE)
    await _wait_window(dut, DDR_BASE)
    assert reqs[:2] == [DDR_BASE, DDR_BASE + 32]

    # Walk across the boundary and through the second line; every window is
    # correct even though the lines arrived reversed.
    pc = DDR_BASE
    for _ in range(12):
        pc += 4
        _drive_pc(dut, pc)
        await _wait_valid(dut)
        _check_window(dut, pc)


@cocotb.test()
async def test_invalidate_discards_two_inflight_fills(dut: Any) -> None:
    """i_invalidate with both fills in flight: neither completing line validates."""
    await _setup(dut)
    reqs: list[int] = []
    inflight: list[tuple[int, int]] = []
    cocotb.start_soon(_line_slave(dut, latency=12, log=reqs, inflight=inflight))

    await FallingEdge(dut.i_clk)
    _drive_pc(dut, DDR_BASE)
    for _ in range(6):
        await FallingEdge(dut.i_clk)
    assert len(inflight) == 2
    dut.i_invalidate.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_invalidate.value = 0

    # Both lines must be fetched again before the window can publish.
    await _wait_valid(dut)
    _check_window(dut, DDR_BASE)
    assert reqs.count(DDR_BASE) >= 2 and reqs.count(DDR_BASE + 32) >= 2, f"reqs={reqs}"


@cocotb.test()
async def test_retarget_with_two_inflight_fills(dut: Any) -> None:
    """A redirect while both fills are in flight lands on the new target."""
    await _setup(dut)
    reqs: list[int] = []
    inflight: list[tuple[int, int]] = []
    cocotb.start_soon(_line_slave(dut, latency=16, log=reqs, inflight=inflight))

    await FallingEdge(dut.i_clk)
    _drive_pc(dut, DDR_BASE)
    for _ in range(6):
        await FallingEdge(dut.i_clk)
    assert len(inflight) == 2

    target = DDR_BASE + 0x2000
    _drive_pc(dut, target)
    await _wait_window(dut, target)
    assert target in reqs and target + 32 in reqs, f"reqs={reqs}"
    # The abandoned fills completed into their slots (no abort) and were
    # replaced; the walk from the target is correct.
    pc = target
    for _ in range(9):
        pc += 4
        _drive_pc(dut, pc)
        await _wait_valid(dut)
        _check_window(dut, pc)


async def _walk_lines(dut: Any, start: int, lines: int) -> None:
    """Walk word by word through ``lines`` lines from ``start``, checking each."""
    pc = start
    await _wait_window(dut, pc)
    for _ in range(lines * 8 - 1):
        pc += 4
        _drive_pc(dut, pc)
        await _wait_valid(dut)
        _check_window(dut, pc)


@cocotb.test()
async def test_victim_store_serves_reentered_lines(dut: Any) -> None:
    """A loop body that fits the slots plus the store re-enters with no L1I request.

    Six lines plus the next-line prefetch occupy the two slots and the
    six-entry store exactly; the second pass must be served entirely from
    them.
    """
    await _setup(dut)
    reqs: list[int] = []
    cocotb.start_soon(_line_slave(dut, latency=6, log=reqs))

    await FallingEdge(dut.i_clk)
    # First pass over six lines: every line is fetched once (plus the
    # prefetch of the seventh).
    _drive_pc(dut, DDR_BASE)
    await _walk_lines(dut, DDR_BASE, 6)
    first_pass = len(reqs)
    assert reqs.count(DDR_BASE) == 1

    # Jump back to the start: the line is in the victim store, so the window
    # must come back without a single new line request, and the whole second
    # pass must be served from the slots and the store.
    _drive_pc(dut, DDR_BASE)
    await _walk_lines(dut, DDR_BASE, 6)
    assert (
        len(reqs) == first_pass
    ), f"re-entry refetched lines: {[hex(r) for r in reqs[first_pass:]]}"

    # The re-entry is quick: a third jump back publishes within a few cycles.
    _drive_pc(dut, DDR_BASE)
    for cycles in range(1, 8):
        await FallingEdge(dut.i_clk)
        if int(dut.o_instr_valid.value) == 1 and int(dut.o_served_word.value) == (
            DDR_BASE >> 2
        ):
            break
    else:
        raise AssertionError("re-entered window not published within 7 cycles")
    _check_window(dut, DDR_BASE)
    assert len(reqs) == first_pass


@cocotb.test()
async def test_victim_store_evicts_beyond_capacity(dut: Any) -> None:
    """A loop body larger than the slots plus the store refetches its oldest line."""
    await _setup(dut)
    reqs: list[int] = []
    cocotb.start_soon(_line_slave(dut, latency=6, log=reqs))

    await FallingEdge(dut.i_clk)
    _drive_pc(dut, DDR_BASE)
    await _walk_lines(dut, DDR_BASE, 12)
    assert reqs.count(DDR_BASE) == 1
    _drive_pc(dut, DDR_BASE)
    await _wait_window(dut, DDR_BASE)
    assert reqs.count(DDR_BASE) == 2, f"the first line should have been evicted: {reqs}"


@cocotb.test()
async def test_invalidate_drops_the_victim_store(dut: Any) -> None:
    """fence.i (i_invalidate) must not let a stored line be copied back."""
    await _setup(dut)
    reqs: list[int] = []
    cocotb.start_soon(_line_slave(dut, latency=6, log=reqs))

    await FallingEdge(dut.i_clk)
    _drive_pc(dut, DDR_BASE)
    await _walk_lines(dut, DDR_BASE, 4)
    dut.i_invalidate.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_invalidate.value = 0
    before = reqs.count(DDR_BASE)
    _drive_pc(dut, DDR_BASE)
    await _wait_window(dut, DDR_BASE)
    assert (
        reqs.count(DDR_BASE) == before + 1
    ), f"stale line served after invalidate: {reqs}"


@cocotb.test()
async def test_perf_miss_stall_qualifies_frontend_progress(dut: Any) -> None:
    """Only a confirmed L1I miss that blocks publication counts as a stall."""
    await _setup(dut)

    _drive_pc(dut, DDR_BASE)
    for _ in range(3):
        await FallingEdge(dut.i_clk)
    assert int(dut.o_instr_valid.value) == 0

    # The cache's source-registered outstanding level is registered once more
    # at this seam; with no window available it becomes a stall event.
    dut.i_l1i_miss_outstanding.value = 1
    await FallingEdge(dut.i_clk)
    assert int(dut.o_perf_miss_stall.value) == 1

    # A backend pipeline stall is the competing cause. The live qualifier
    # suppresses the onset immediately; pipeline_stall_q also suppresses the
    # provider's registered tail after the live stall drops.
    dut.i_pipeline_stall.value = 1
    await FallingEdge(dut.i_clk)
    assert int(dut.o_perf_miss_stall.value) == 0
    await FallingEdge(dut.i_clk)
    assert int(dut.o_perf_miss_stall.value) == 0

    dut.i_pipeline_stall.value = 0
    await FallingEdge(dut.i_clk)
    assert int(dut.o_perf_miss_stall.value) == 0
    await FallingEdge(dut.i_clk)
    assert int(dut.o_perf_miss_stall.value) == 1

    # A redirect to low BRAM makes progress outside this provider even while
    # the old high-tier miss completes in the background.
    _drive_pc(dut, 0)
    await FallingEdge(dut.i_clk)
    assert int(dut.o_perf_miss_stall.value) == 0

    _drive_pc(dut, DDR_BASE)
    await FallingEdge(dut.i_clk)
    assert int(dut.o_perf_miss_stall.value) == 1

    dut.i_l1i_miss_outstanding.value = 0
    await FallingEdge(dut.i_clk)
    assert int(dut.o_perf_miss_stall.value) == 0
