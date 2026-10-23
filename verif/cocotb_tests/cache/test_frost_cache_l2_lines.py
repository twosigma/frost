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

"""64-byte L2 lines under 32-byte upstream lines.

The harness runs with L2_LINE_BYTES=64: each L2 line holds two upstream
lines, its lower and upper halves, and the line-size adapter in front of the
L2 places each upstream request in its half. An AXI monitor records every
transfer below the bridge, so a test can count the fills and writebacks of a
line and check that every transfer is one 64-byte beat and every writeback a
whole line. Memory contents are set and checked directly in the behavioral
DDR, for lines no cache holds. The L2's write-cost events are checked against
those transfers and against the L2's tag-stage decisions on a line's writes.
"""

from collections.abc import Iterable
from typing import Any

import cocotb
from cocotb.triggers import FallingEdge, ReadOnly

from cocotb_tests.cache.test_frost_cache import (
    BASE_ADDR,
    LINE_BYTES,
    ReferenceModel,
    _copy_perf_counts,
    _monitor_perf_events,
    _new_perf_counts,
    _perf_field,
    _port_transaction,
    cache_geometry,
    evict_l1d,
    evict_l2,
    fresh_aliases,
    l2_line_bytes,
    make_l1d_next_victim,
    make_l2_next_victim,
)
from cocotb_tests.cache.test_frost_cache import _setup as _setup_any
from cocotb_tests.cache.test_frost_cache_concurrency import (
    _Collector,
    _fire,
    _release_downstream_once,
    _settle,
)
from cocotb_tests.cache.test_frost_cache_dma import LoadQueueStub, _pattern

FULL = (1 << LINE_BYTES) - 1
L2_LINE_BYTES = 64
WORDS_PER_L2_LINE = L2_LINE_BYTES // 4
AXI_SIZE_L2_LINE = 6  # log2(64)

# Per-test 256 KiB regions above the other cache benches' ranges, inside the
# harness's 16 MiB memory model. Each test uses lines no earlier test touched.
SHARE_BASE = BASE_ADDR + 0xB00000
MERGE_BASE = BASE_ADDR + 0xB40000
COMBINE_BASE = BASE_ADDR + 0xB80000
SECTOR_BASE = BASE_ADDR + 0xBC0000
ORDER_BASE = BASE_ADDR + 0xC00000
OOO_BASE = BASE_ADDR + 0xC40000
FENCE_BASE = BASE_ADDR + 0xC80000
REFILL_BASE = BASE_ADDR + 0xCC0000
RESET_BASE = BASE_ADDR + 0xD00000
SLOTS_BASE = BASE_ADDR + 0xD40000
WRITE_FILL_BASE = BASE_ADDR + 0xE40000
WRITE_WAIT_BASE = BASE_ADDR + 0xE80000


async def _setup(dut: Any) -> None:
    """Reset the harness and check it was built with 64-byte L2 lines."""
    await _setup_any(dut)
    assert l2_line_bytes(dut) == L2_LINE_BYTES, (
        "build the harness with L2_LINE_BYTES=64"
    )


def _half(addr: int) -> tuple[int, int]:
    """Return the two upstream-line addresses of addr's L2 line (lower, upper)."""
    line = addr & ~(L2_LINE_BYTES - 1)
    return line, line + LINE_BYTES


def _ddr_get_line(dut: Any, addr: int) -> int:
    """Read addr's L2 line from the behavioral DDR's word array."""
    word = ((addr & ~(L2_LINE_BYTES - 1)) - BASE_ADDR) // 4
    value = 0
    for w in range(WORDS_PER_L2_LINE):
        value |= int(dut.main_memory.memory[word + w].value) << (32 * w)
    return value


def _ddr_put_line(dut: Any, model: ReferenceModel, addr: int, value: int) -> None:
    """Set addr's L2 line in the behavioral DDR and in the model.

    Only for lines no cache holds: the caches do not see the change.
    """
    word = ((addr & ~(L2_LINE_BYTES - 1)) - BASE_ADDR) // 4
    for w in range(WORDS_PER_L2_LINE):
        dut.main_memory.memory[word + w].value = (value >> (32 * w)) & 0xFFFFFFFF
    lo, hi = _half(addr)
    model.write_line(lo, value & ((1 << (8 * LINE_BYTES)) - 1), FULL)
    model.write_line(hi, value >> (8 * LINE_BYTES), FULL)


def _two_halves(seed: int) -> tuple[int, int, int]:
    """Return (lower, upper, whole) data for an L2 line with distinct halves."""
    lo = _pattern(seed)
    hi = _pattern(seed + 101)
    return lo, hi, lo | (hi << (8 * LINE_BYTES))


class AxiMonitor:
    """Record every AXI transfer below the bridge and check its shape.

    Every AR and AW must be one beat (AxLEN 0) of a whole L2 line (AxSIZE 6,
    INCR, aligned); every W must be the last beat with all 64 strobes set,
    since the L2 writes back only whole lines.
    """

    def __init__(self, dut: Any) -> None:
        """Start monitoring at the next falling edge."""
        self._dut = dut
        self.cycle = 0
        self.reads: list[tuple[int, int, int]] = []  # (cycle, id, region offset)
        self.writes: list[tuple[int, int, int]] = []  # (cycle, id, region offset)
        self.write_data: list[tuple[int, int]] = []  # (cycle, data)
        self.read_done: list[tuple[int, int]] = []  # (cycle, id)
        self.write_done: list[tuple[int, int]] = []  # (cycle, id)
        self.outstanding_reads: dict[int, int] = {}  # id -> region offset
        self.max_outstanding_reads = 0
        self.out_of_order_reads = 0
        self._read_order: list[int] = []  # ids in AR order
        self.violations: list[str] = []
        self._task = cocotb.start_soon(self._run())

    def _check(self, ok: bool, what: str) -> None:
        if not ok:
            self.violations.append(f"cycle {self.cycle}: {what}")

    async def _run(self) -> None:
        dut = self._dut
        while True:
            await FallingEdge(dut.i_clk)
            self.cycle += 1
            await ReadOnly()
            if int(dut.axi_arvalid.value) and int(dut.axi_arready.value):
                rid = int(dut.axi_arid.value)
                addr = int(dut.axi_araddr.value)
                self._check(int(dut.axi_arlen.value) == 0, "multi-beat read")
                self._check(int(dut.axi_arsize.value) == AXI_SIZE_L2_LINE, "read size")
                self._check(addr % L2_LINE_BYTES == 0, f"unaligned read 0x{addr:x}")
                self.reads.append((self.cycle, rid, addr))
                self.outstanding_reads[rid] = addr
                self._read_order.append(rid)
                self.max_outstanding_reads = max(
                    self.max_outstanding_reads, len(self.outstanding_reads)
                )
            if int(dut.axi_awvalid.value) and int(dut.axi_awready.value):
                addr = int(dut.axi_awaddr.value)
                self._check(int(dut.axi_awlen.value) == 0, "multi-beat write")
                self._check(int(dut.axi_awsize.value) == AXI_SIZE_L2_LINE, "write size")
                self._check(addr % L2_LINE_BYTES == 0, f"unaligned write 0x{addr:x}")
                self.writes.append((self.cycle, int(dut.axi_awid.value), addr))
            if int(dut.axi_wvalid.value) and int(dut.axi_wready.value):
                self._check(int(dut.axi_wlast.value) == 1, "write beat without WLAST")
                strb = int(dut.axi_wstrb.value)
                self._check(
                    strb == (1 << L2_LINE_BYTES) - 1, f"partial writeback 0x{strb:x}"
                )
                self.write_data.append((self.cycle, int(dut.axi_wdata.value)))
            if int(dut.axi_rvalid.value) and int(dut.axi_rready.value):
                rid = int(dut.axi_rid.value)
                if self._read_order and self._read_order[0] != rid:
                    self.out_of_order_reads += 1
                if rid in self._read_order:
                    self._read_order.remove(rid)
                self.outstanding_reads.pop(rid, None)
                self.read_done.append((self.cycle, rid))
            if int(dut.axi_bvalid.value) and int(dut.axi_bready.value):
                self.write_done.append((self.cycle, int(dut.axi_bid.value)))

    def reads_of(self, addr: int, since: int = 0) -> list[int]:
        """Return the cycles of the reads of addr's L2 line after cycle since."""
        offset = (addr & ~(L2_LINE_BYTES - 1)) - BASE_ADDR
        return [c for c, _, a in self.reads if a == offset and c > since]

    def writes_of(self, addr: int, since: int = 0) -> list[int]:
        """Return the cycles of the writebacks of addr's L2 line after cycle since."""
        offset = (addr & ~(L2_LINE_BYTES - 1)) - BASE_ADDR
        return [c for c, _, a in self.writes if a == offset and c > since]

    def assert_clean(self) -> None:
        """Fail on any malformed transfer seen so far."""
        assert not self.violations, "; ".join(self.violations[:8])

    def stop(self) -> None:
        """Stop monitoring."""
        self._task.cancel()


def _l2(dut: Any) -> Any:
    return dut.cache_hierarchy.cluster_cache.l2_cache


def _l2_slots_for(dut: Any, addr: int) -> list[tuple[int, int]]:
    """Return (slot, waiter seats taken) for every busy L2 miss slot on addr's line."""
    l2 = _l2(dut)
    line = addr >> 6
    out = []
    for i in range(int(l2.NUM_MSHR.value)):
        if int(l2.mshr_state_q[i].value) != 0 and int(l2.mshr_line_q[i].value) == line:
            out.append((i, bin(int(l2.mshr_waiter_valid_q[i].value)).count("1")))
    return out


async def _hold(dut: Any, value: int) -> None:
    await FallingEdge(dut.i_clk)
    dut.i_down_hold.value = value


async def _evict_from_l1d(dut: Any, addrs: Iterable[int]) -> None:
    """Push each line out of the L1D, writing a dirty copy back to the L2.

    The reads (evict_l1d) stay out of the line's L2 set.
    """
    for addr in addrs:
        await evict_l1d(dut, addr)


async def _evict_from_l2(dut: Any, addrs: Iterable[int]) -> None:
    """Push each line out of the L2 with walker reads, which skip the L1s.

    The walker's probes find nothing in the L1D at the new lines (evict_l2),
    so each read reaches the L2 at once.
    """
    for addr in addrs:
        await evict_l2(dut, addr & ~(L2_LINE_BYTES - 1))


async def _next_miss_evicts_from_l1d(dut: Any, addr: int) -> int:
    """Return a new line whose read misses in addr's L1D set and evicts addr.

    Reads new lines of the set until addr is its next victim; the returned
    line is in the same L1D set and in another L2 set than addr.
    """
    geom = cache_geometry(dut)
    await make_l1d_next_victim(dut, addr)
    keep = geom.l2_set(addr)
    return fresh_aliases(
        addr, geom.l1d_way_bytes, 1, avoid=lambda a: geom.l2_set(a) == keep
    )[0]


async def _read(dut: Any, port: str, addr: int) -> int:
    return await _port_transaction(dut, port, write=False, addr=addr)


async def _check(dut: Any, model: ReferenceModel, port: str, addr: int) -> None:
    got = await _read(dut, port, addr)
    want = model.read_line(addr)
    assert got == want, (
        f"{port} read @0x{addr:08x}: got 0x{got:064x} expected 0x{want:064x}"
    )


def _perf_delta(
    counts: dict[str, dict[str, int]], before: dict[str, dict[str, int]]
) -> dict[str, dict[str, int]]:
    """Return the event totals accumulated since the copy `before`."""
    return {
        bundle: {
            field: total - before[bundle][field] for field, total in fields.items()
        }
        for bundle, fields in counts.items()
    }


class WriteDecisions:
    """Time the L2 tag stage's decisions on the writes to one L2 line.

    The tag stage takes one request at a time, so a write that waits holds it
    from its first decision until the decision that completes it, and every
    request behind it waits too. A completing decision merges the write into
    its line's miss slot, hits, or allocates a slot. The line's AXI read data
    beats are timed on the same cycle count.
    """

    def __init__(self, dut: Any, addr: int) -> None:
        """Start watching addr's L2 line at the next falling edge."""
        self._dut = dut
        self._line = addr >> 6
        self._offset = (addr & ~(L2_LINE_BYTES - 1)) - BASE_ADDR
        self.cycle = 0
        # (cycle, completed, what a completing decision does: merge, hit, alloc)
        self.decisions: list[tuple[int, bool, str]] = []
        self.read_done: list[int] = []  # cycles of the line's read data beats
        self._read_ids: set[int] = set()
        self._task = cocotb.start_soon(self._run())

    async def _run(self) -> None:
        dut = self._dut
        l2 = _l2(dut)
        while True:
            await FallingEdge(dut.i_clk)
            self.cycle += 1
            await ReadOnly()
            if (
                int(l2.decide.value)
                and int(l2.t_write_q.value)
                and int(l2.t_addr_q.value) >> 6 == self._line
            ):
                if int(l2.same_line.value):
                    outcome = "merge"
                elif int(l2.hit.value):
                    outcome = "hit"
                else:
                    outcome = "alloc"
                completed = bool(int(l2.t_done.value))
                self.decisions.append((self.cycle, completed, outcome))
            if int(dut.axi_arvalid.value) and int(dut.axi_arready.value):
                if int(dut.axi_araddr.value) == self._offset:
                    self._read_ids.add(int(dut.axi_arid.value))
            if int(dut.axi_rvalid.value) and int(dut.axi_rready.value):
                rid = int(dut.axi_rid.value)
                if rid in self._read_ids:
                    self._read_ids.discard(rid)
                    self.read_done.append(self.cycle)

    def requests(self) -> list[tuple[int, int, str]]:
        """Return (first decision, completing decision, outcome) of each write."""
        out = []
        first = None
        for cycle, completed, outcome in self.decisions:
            first = cycle if first is None else first
            if completed:
                out.append((first, cycle, outcome))
                first = None
        assert first is None, "a write's decisions never completed"
        return out

    def outcomes(self) -> list[str]:
        """Return what each write's completing decision did, in order."""
        return [outcome for _, _, outcome in self.requests()]

    def waits(self) -> list[tuple[int, int]]:
        """Return the requests that held the tag stage past their first decision."""
        return [(first, done) for first, done, _ in self.requests() if done > first]

    def stop(self) -> None:
        """Stop watching."""
        self._task.cancel()


@cocotb.test()
async def test_halves_share_one_fill_and_a_reader_past_the_seats_waits(
    dut: Any,
) -> None:
    """Reads of both halves of a missing line share one fill; extra readers wait.

    The L1D reads the lower half and the L1I the upper half while the bridge
    is held: the first read takes the L2 miss slot and the second a waiter
    seat. With two seats (L2_NUM_WAITERS=2) a walker read of the upper half
    takes the other. The next requester, the walker with one seat or a DMA
    read of the upper half with two, finds the seats taken and waits in the
    L2's decision stage (an L2 conflict stall) until the fill installs, then
    hits. One AXI read serves them all. (The walker and the DMA read the
    upper half because a probe of the lower half would wait for the L1D's own
    fill before reaching the L2.)
    """
    await _setup(dut)
    mon = AxiMonitor(dut)
    model = ReferenceModel()
    counts = _new_perf_counts()
    stop = [False]
    cocotb.start_soon(_monitor_perf_events(dut, counts, stop))
    lo, hi, whole = _two_halves(1)
    a, b = _half(SHARE_BASE + 5 * L2_LINE_BYTES)
    _ddr_put_line(dut, model, a, whole)
    seats = int(_l2(dut).NUM_WAITERS.value)
    assert seats in (1, 2), f"the test covers one or two waiter seats, not {seats}"

    # (port, address, id): the primary, one reader per seat, then the waiter.
    readers = [("up", a, 1), ("iup", b, 2), ("wup", b, 1), ("dma", b, 1)][: seats + 2]
    cols = {port: _Collector(dut, port) for port, _, _ in readers}
    await _hold(dut, 1)
    for port, addr, req_id in readers[:-1]:
        await _fire(dut, port, write=False, addr=addr, req_id=req_id)
    await _settle(dut, 40)
    assert _l2_slots_for(dut, a) == [(0, seats)], (
        f"expected one L2 miss slot with all {seats} waiter seats taken: "
        f"{_l2_slots_for(dut, a)}"
    )
    stalls_before = counts["l2"]["conflict_stall"]
    last_port, last_addr, last_id = readers[-1]
    await _fire(dut, last_port, write=False, addr=last_addr, req_id=last_id)
    await _settle(dut, 40)
    assert counts["l2"]["conflict_stall"] > stalls_before, "the last read never waited"
    assert not cols[last_port].pending, "the last read returned before the fill"
    await _hold(dut, 0)

    for port, addr, req_id in readers:
        got = (await cols[port].wait_for(req_id))[1]
        assert got == (lo if addr == a else hi), f"{port} read the wrong data"
    assert len(mon.reads_of(a)) == 1, f"line read {len(mon.reads_of(a))} times"
    await _settle(dut)
    # The request that waited is a read, so no write-cost event counts it.
    assert set(counts["l2_write"].values()) == {0}, counts["l2_write"]
    stop[0] = True
    mon.assert_clean()
    for col in cols.values():
        col.stop()
    mon.stop()


@cocotb.test()
async def test_dirty_writeback_missing_in_l2_fills_then_merges(dut: Any) -> None:
    """A dirty 32-byte writeback whose line the L2 lacks fills, then merges.

    In turn for each half: the L1D holds that half dirty while the L2 has
    lost the line. The writeback reads the 64-byte line from DDR, merges the
    32 written bytes into their half, and installs the line dirty; the other
    half keeps its DDR bytes. The line's eviction is then one 512-bit write
    of the merged line.
    """
    await _setup(dut)
    mon = AxiMonitor(dut)
    model = ReferenceModel()
    for k in range(2):
        _, _, whole = _two_halves(2 + k)
        a, b = _half(MERGE_BASE + (3 + 4 * k) * L2_LINE_BYTES)
        dirty, other = (a, b) if k == 0 else (b, a)
        _ddr_put_line(dut, model, a, whole)
        new = _pattern(7 + k)

        # A whole-line store allocates in the L1D without a fill; the walker
        # reads of new lines of its L2 set make sure the L2 lacks the line.
        model.write_line(dirty, new, FULL)
        await _port_transaction(
            dut, "up", write=True, addr=dirty, wdata=new, wstrb=FULL
        )
        await _evict_from_l2(dut, [a])
        mark = mon.cycle
        await _evict_from_l1d(dut, [dirty])  # the writeback misses the L2
        await _settle(dut)
        assert len(mon.reads_of(a, since=mark)) == 1, (
            "the writeback did not fetch its line"
        )
        assert not mon.writes_of(a, since=mark), "the merged line left the L2 early"

        await _check(dut, model, "iup", other)  # the fill's other half
        await _check(dut, model, "wup", dirty)  # the merged half
        mark = mon.cycle
        await _evict_from_l2(dut, [a])
        await _settle(dut)
        assert len(mon.writes_of(a, since=mark)) == 1, "the eviction was not one write"
        expected = model.read_line(a) | (model.read_line(b) << (8 * LINE_BYTES))
        assert mon.write_data[-1][1] == expected, "the eviction wrote the wrong line"
        assert _ddr_get_line(dut, a) == expected
    mon.assert_clean()
    mon.stop()


@cocotb.test()
async def test_writeback_waits_behind_the_lines_read_fill(dut: Any) -> None:
    """A 32-byte writeback that arrives while its line's read fill is out waits.

    With the bridge held, an L1I read of one half allocates the L2's miss
    slot for the line, a read slot that no write may merge into. The L1D then
    writes back its dirty copy of the other half. The writeback waits in the
    L2's decision stage until the fill installs, then hits and merges: the
    L1I gets the DDR bytes, and the line's eviction carries both the DDR half
    and the written half, after a single fill.
    """
    await _setup(dut)
    mon = AxiMonitor(dut)
    model = ReferenceModel()
    counts = _new_perf_counts()
    stop = [False]
    cocotb.start_soon(_monitor_perf_events(dut, counts, stop))
    for k in range(2):
        _, _, whole = _two_halves(20 + k)
        a, b = _half(MERGE_BASE + 0x2000 + (3 + 4 * k) * L2_LINE_BYTES)
        read_half, dirty = (a, b) if k == 0 else (b, a)
        _ddr_put_line(dut, model, a, whole)
        new = _pattern(30 + k)
        model.write_line(dirty, new, FULL)
        await _port_transaction(
            dut, "up", write=True, addr=dirty, wdata=new, wstrb=FULL
        )
        await _evict_from_l2(dut, [a])  # the L2 lacks the line
        evictor = await _next_miss_evicts_from_l1d(dut, dirty)
        mark = mon.cycle

        iup, up = _Collector(dut, "iup"), _Collector(dut, "up")
        await _hold(dut, 1)
        await _fire(dut, "iup", write=False, addr=read_half, req_id=1)
        await _settle(dut, 30)
        stalls_before = counts["l2"]["conflict_stall"]
        await _fire(dut, "up", write=False, addr=evictor, req_id=1)
        await _settle(dut, 40)
        assert counts["l2"]["conflict_stall"] > stalls_before, (
            "the writeback never waited"
        )
        await _hold(dut, 0)
        assert (await iup.wait_for(1))[1] == model.read_line(read_half)
        await up.wait_for(1)
        iup.stop()
        up.stop()
        await _settle(dut)
        assert len(mon.reads_of(a, since=mark)) == 1, "the line was fetched twice"
        mark = mon.cycle
        await _evict_from_l2(dut, [a])
        await _settle(dut)
        expected = model.read_line(a) | (model.read_line(b) << (8 * LINE_BYTES))
        assert len(mon.writes_of(a, since=mark)) == 1
        assert mon.write_data[-1][1] == expected, "the writeback did not merge"
    stop[0] = True
    mon.assert_clean()
    mon.stop()


@cocotb.test()
async def test_both_halves_written_back_separately_combine(dut: Any) -> None:
    """Writebacks of both halves combine in one L2 line and leave as one write.

    First with the line resident: each half's writeback hits at a different
    time. Then with the line absent and the bridge held: the first writeback
    allocates the miss slot and the second merges into it, so one fill
    serves both. Either way the eviction is a single whole-line write.
    """
    await _setup(dut)
    mon = AxiMonitor(dut)
    model = ReferenceModel()
    for k, held in enumerate((False, True)):
        _, _, whole = _two_halves(10 + k)
        a, b = _half(COMBINE_BASE + (2 + 4 * k) * L2_LINE_BYTES)
        _ddr_put_line(dut, model, a, whole)
        new_lo, new_hi = _pattern(20 + k), _pattern(30 + k)
        if not held:
            await _read(dut, "wup", a)  # the line becomes resident in the L2
        # Whole-line stores allocate in the L1D without a fill.
        model.write_line(a, new_lo, FULL)
        model.write_line(b, new_hi, FULL)
        await _port_transaction(dut, "up", write=True, addr=a, wdata=new_lo, wstrb=FULL)
        await _port_transaction(dut, "up", write=True, addr=b, wdata=new_hi, wstrb=FULL)
        await _settle(dut)  # the stores are acknowledged before their fills
        if held:
            await _evict_from_l2(dut, [a])  # the L2 lacks the line
            evict_a = await _next_miss_evicts_from_l1d(dut, a)
            evict_b = await _next_miss_evicts_from_l1d(dut, b)
        mark = mon.cycle
        if held:
            await _hold(dut, 1)
            col = _Collector(dut, "up")
            await _fire(dut, "up", write=False, addr=evict_a, req_id=1)
            await _fire(dut, "up", write=False, addr=evict_b, req_id=2)
            await _settle(dut, 60)
            slots = _l2_slots_for(dut, a)
            assert len(slots) == 1, f"the two writebacks took {slots} miss slots"
            await _hold(dut, 0)
            await col.wait_for(1)
            await col.wait_for(2)
            col.stop()
            assert len(mon.reads_of(a, since=mark)) == 1, "the halves took two fills"
        else:
            await _evict_from_l1d(dut, [a])
            await _settle(dut, 200)
            await _evict_from_l1d(dut, [b])
            assert not mon.reads_of(a, since=mark), "a resident line was fetched"
        await _settle(dut)
        assert not mon.writes_of(a, since=mark), "a half left the L2 on its own"
        await _evict_from_l2(dut, [a])
        await _settle(dut)
        assert len(mon.writes_of(a, since=mark)) == 1, "the line left as several writes"
        expected = new_lo | (new_hi << (8 * LINE_BYTES))
        assert mon.write_data[-1][1] == expected, "the halves did not combine"
        assert _ddr_get_line(dut, a) == expected
    mon.assert_clean()
    mon.stop()


@cocotb.test()
async def test_dma_writes_change_only_their_half(dut: Any) -> None:
    """DMA writes, whole and four-byte like NIC status words, keep the other half.

    The other half is in turn dirty in the L1D, pending in an L1I fill,
    pending in a writeback, and holding the line's waiter seat. Each case
    ends with the L1D writing its copies back (the L1I does not snoop the
    L1D), every port reading both halves, and the line spilled to DDR.
    Where the DMA write waits behind the other half's fill, the coherence
    sequencer has still released its L1D probe slot, because the L2 has
    accepted the write; an L1D read of the DMA's half then reaches the L2
    behind the write and returns its data.
    """
    await _setup(dut)
    lq = LoadQueueStub(dut)
    mon = AxiMonitor(dut)
    model = ReferenceModel()
    strobes = (FULL, 0xF << (LINE_BYTES - 4), 0xF)
    for case in range(4):
        for s, strobe in enumerate(strobes):
            seed = 40 + 3 * case + s
            _, _, whole = _two_halves(seed)
            # Cases 8 KiB apart and lines in each case's first KiB: no case
            # touches another's lines, and eviction reads use lines of their
            # own (evict_l1d, evict_l2).
            line = SECTOR_BASE + case * 0x2000 + 2 * s * L2_LINE_BYTES
            a, b = _half(line)
            # The DMA writes the upper half in odd rounds, the lower in even.
            dma_addr, other = (b, a) if s % 2 else (a, b)
            _ddr_put_line(dut, model, a, whole)
            data = _pattern(seed + 200)
            if case == 0:
                # The other half is dirty in the L1D.
                mine = _pattern(seed + 300)
                model.write_line(other, mine, FULL)
                await _port_transaction(
                    dut, "up", write=True, addr=other, wdata=mine, wstrb=FULL
                )
                model.write_line(dma_addr, data, strobe)
                await _port_transaction(
                    dut, "dma", write=True, addr=dma_addr, wdata=data, wstrb=strobe
                )
            elif case == 1:
                # The other half's L1I fill is pending: the DMA write waits in
                # the L2 behind the read miss slot, and an L1D read of the DMA's
                # half, issued once the write is accepted, sees the write.
                iup, up, dma = (
                    _Collector(dut, "iup"),
                    _Collector(dut, "up"),
                    _Collector(dut, "dma"),
                )
                await _hold(dut, 1)
                await _fire(dut, "iup", write=False, addr=other, req_id=1)
                await _settle(dut, 30)
                releases = len(lq.releases)
                model.write_line(dma_addr, data, strobe)
                await _fire(
                    dut,
                    "dma",
                    write=True,
                    addr=dma_addr,
                    req_id=1,
                    wdata=data,
                    wstrb=strobe,
                )
                for _ in range(400):
                    await FallingEdge(dut.i_clk)
                    if len(lq.releases) > releases:
                        break
                else:
                    raise AssertionError("the DMA write was never accepted by the L2")
                assert int(dut.i_down_hold.value) == 1
                await _fire(dut, "up", write=False, addr=dma_addr, req_id=1)
                await _settle(dut, 30)
                await _hold(dut, 0)
                assert (await iup.wait_for(1))[1] == model.read_line(other)
                await dma.wait_for(1)
                got = (await up.wait_for(1))[1]
                assert got == model.read_line(dma_addr), (
                    "the L1D read missed the DMA write"
                )
                for col in (iup, up, dma):
                    col.stop()
            elif case == 2:
                # The other half's writeback is in flight to an L2 that lacks
                # the line: the DMA write merges into the same miss slot.
                mine = _pattern(seed + 300)
                model.write_line(other, mine, FULL)
                await _port_transaction(
                    dut, "up", write=True, addr=other, wdata=mine, wstrb=FULL
                )
                await _evict_from_l2(dut, [line])
                evictor = await _next_miss_evicts_from_l1d(dut, other)
                up, dma = _Collector(dut, "up"), _Collector(dut, "dma")
                await _hold(dut, 1)
                await _fire(dut, "up", write=False, addr=evictor, req_id=1)
                await _settle(dut, 30)
                model.write_line(dma_addr, data, strobe)
                await _fire(
                    dut,
                    "dma",
                    write=True,
                    addr=dma_addr,
                    req_id=1,
                    wdata=data,
                    wstrb=strobe,
                )
                await _settle(dut, 60)
                assert len(_l2_slots_for(dut, line)) == 1, "the DMA write did not merge"
                await _hold(dut, 0)
                await up.wait_for(1)
                await dma.wait_for(1)
                up.stop()
                dma.stop()
            else:
                # The L1D reads the DMA's half and the L1I the other half: the
                # waiter seat is taken. The DMA probe waits for the L1D's fill,
                # then the write hits.
                up, iup, dma = (
                    _Collector(dut, "up"),
                    _Collector(dut, "iup"),
                    _Collector(dut, "dma"),
                )
                await _hold(dut, 1)
                await _fire(dut, "up", write=False, addr=dma_addr, req_id=1)
                await _fire(dut, "iup", write=False, addr=other, req_id=1)
                await _settle(dut, 30)
                before = model.read_line(dma_addr)
                model.write_line(dma_addr, data, strobe)
                await _fire(
                    dut,
                    "dma",
                    write=True,
                    addr=dma_addr,
                    req_id=1,
                    wdata=data,
                    wstrb=strobe,
                )
                await _settle(dut, 30)
                await _hold(dut, 0)
                assert (await up.wait_for(1))[1] == before
                assert (await iup.wait_for(1))[1] == model.read_line(other)
                await dma.wait_for(1)
                for col in (up, iup, dma):
                    col.stop()
            await _evict_from_l1d(dut, [a, b])
            for port in ("up", "iup", "wup", "dma"):
                await _check(dut, model, port, a)
                await _check(dut, model, port, b)
            await _evict_from_l2(dut, [line])
            await _settle(dut)
            expected = model.read_line(a) | (model.read_line(b) << (8 * LINE_BYTES))
            assert _ddr_get_line(dut, a) == expected, (
                f"case {case} strobe {s}: DDR line"
            )
    mon.assert_clean()
    mon.stop()
    lq.stop()


@cocotb.test()
async def test_l2_orders_both_halves_in_acceptance_order(dut: Any) -> None:
    """A read between two DMA writes of one line sees the first, not the second.

    With the line missing and the bridge held, a DMA write allocates the
    write miss slot, a walker read of the same half takes the waiter seat,
    and a second DMA write of that half cannot merge past the waiter, so it
    waits. The read returns the first write's data. The second round reads
    the other half between writes of it: the read returns the DDR bytes,
    then the second write lands.
    """
    await _setup(dut)
    lq = LoadQueueStub(dut)
    mon = AxiMonitor(dut)
    model = ReferenceModel()
    for k in range(2):
        _, _, whole = _two_halves(60 + k)
        a, b = _half(ORDER_BASE + (2 + 4 * k) * L2_LINE_BYTES)
        _ddr_put_line(dut, model, a, whole)
        first, second = _pattern(70 + k), _pattern(80 + k)
        read_addr = a if k == 0 else b
        later = a if k == 0 else b
        dma, wup = _Collector(dut, "dma"), _Collector(dut, "wup")
        await _hold(dut, 1)
        await _fire(dut, "dma", write=True, addr=a, req_id=1, wdata=first, wstrb=FULL)
        model.write_line(a, first, FULL)
        expected_read = model.read_line(read_addr)
        await _settle(dut, 40)
        await _fire(dut, "wup", write=False, addr=read_addr, req_id=1)
        await _settle(dut, 40)
        await _fire(
            dut, "dma", write=True, addr=later, req_id=2, wdata=second, wstrb=FULL
        )
        model.write_line(later, second, FULL)
        await _settle(dut, 40)
        await _hold(dut, 0)
        assert (await wup.wait_for(1))[1] == expected_read, "the read saw a later write"
        await dma.wait_for(1)
        await dma.wait_for(2)
        for col in (dma, wup):
            col.stop()
        for port in ("wup", "dma", "iup"):
            await _check(dut, model, port, a)
            await _check(dut, model, port, b)
    mon.assert_clean()
    mon.stop()
    lq.stop()


@cocotb.test()
async def test_outstanding_misses_across_both_halves(dut: Any) -> None:
    """Many misses on both halves of many lines are in flight at the AXI port.

    Every port issues misses while the bridge is held, then the bridge is
    released. The AXI side must see several reads outstanding at once and,
    when the memory model reorders (MEM_REORDER=1), responses out of request
    order. Every response carries its own id and its own half.
    """
    await _setup(dut)
    lq = LoadQueueStub(dut)
    mon = AxiMonitor(dut)
    model = ReferenceModel()
    lines = [OOO_BASE + (3 + 2 * i) * L2_LINE_BYTES for i in range(10)]
    for i, line in enumerate(lines):
        _ddr_put_line(dut, model, line, _two_halves(90 + i)[2])
    cols = {port: _Collector(dut, port) for port in ("up", "iup", "wup", "dma")}
    plan = [
        ("up", 0, lines[0]),
        ("up", 1, lines[1] + LINE_BYTES),
        ("up", 2, lines[2]),
        ("up", 3, lines[3] + LINE_BYTES),
        ("iup", 0, lines[0] + LINE_BYTES),  # the other half of an L1D miss
        ("iup", 1, lines[4]),
        ("wup", 0, lines[5] + LINE_BYTES),
        ("dma", 0, lines[6]),
        ("dma", 1, lines[7] + LINE_BYTES),
        ("dma", 2, lines[8]),
    ]
    await _hold(dut, 1)
    for port, req_id, addr in plan:
        await _fire(dut, port, write=False, addr=addr, req_id=req_id)
    await _settle(dut, 60)
    await _hold(dut, 0)
    for port, req_id, addr in plan:
        got = (await cols[port].wait_for(req_id))[1]
        assert got == model.read_line(addr), f"{port} id {req_id} @0x{addr:08x}"
    num_mshr = int(_l2(dut).NUM_MSHR.value)
    assert mon.max_outstanding_reads >= min(num_mshr, 4), (
        f"at most {mon.max_outstanding_reads} reads were outstanding"
    )
    if int(dut.MEM_REORDER.value):
        assert mon.out_of_order_reads > 0, "no read completed out of order"
    for col in cols.values():
        col.stop()
    mon.assert_clean()
    mon.stop()
    lq.stop()


@cocotb.test()
async def test_fence_writes_back_into_lines_the_l2_lacks(dut: Any) -> None:
    """fence.i completes while its writebacks' L2 fills are still pending.

    The L1D holds dirty halves of lines the L2 has lost, and the L1I holds
    their old contents. With the bridge held, the writeback-all's writes miss
    the L2 and wait for fills, but the L2 acknowledges each once it has
    ordered it, so fence.i completes. Instruction fetches issued right after
    the fence see the new bytes: each waits on its line's write miss slot.
    """
    await _setup(dut)
    mon = AxiMonitor(dut)
    model = ReferenceModel()
    targets = []
    for k in range(2):
        _, _, whole = _two_halves(110 + k)
        a, b = _half(FENCE_BASE + (2 + 4 * k) * L2_LINE_BYTES)
        _ddr_put_line(dut, model, a, whole)
        target = a if k == 0 else b
        await _check(dut, model, "iup", target)  # the L1I keeps the old copy
        new = _pattern(120 + k)
        model.write_line(target, new, FULL)
        await _port_transaction(
            dut, "up", write=True, addr=target, wdata=new, wstrb=FULL
        )
        targets.append(target)
    await _evict_from_l2(dut, targets)  # the L1I's reads left clean copies

    await _hold(dut, 1)
    await FallingEdge(dut.i_clk)
    dut.i_fence_sync.value = 1
    for _ in range(5000):
        await FallingEdge(dut.i_clk)
        if int(dut.o_fence_done.value):
            break
    else:
        raise AssertionError("fence.i waited for the L2's fills")
    dut.i_fence_sync.value = 0
    assert int(dut.i_down_hold.value) == 1
    iup = _Collector(dut, "iup")
    for req_id, target in enumerate(targets):
        await _fire(dut, "iup", write=False, addr=target, req_id=req_id)
    await _settle(dut, 40)
    await _hold(dut, 0)
    for req_id, target in enumerate(targets):
        got = (await iup.wait_for(req_id))[1]
        assert got == model.read_line(target), f"stale fetch @0x{target:08x}"
    iup.stop()
    mon.assert_clean()
    mon.stop()


@cocotb.test()
async def test_refill_waits_for_the_lines_writeback(dut: Any) -> None:
    """A line evicted dirty is fetched again only after its writeback lands.

    With the bridge held, a read of a new line of its L2 set evicts a dirty
    L2 line into a writeback slot, and a read of the line's other half then
    misses. That
    miss must not read DDR until the writeback has been acknowledged, and
    the line must not be written back twice.
    """
    await _setup(dut)
    mon = AxiMonitor(dut)
    model = ReferenceModel()
    _, _, whole = _two_halves(130)
    a, b = _half(REFILL_BASE + 3 * L2_LINE_BYTES)
    _ddr_put_line(dut, model, a, whole)
    new = _pattern(131)
    model.write_line(a, new, FULL)
    await _port_transaction(dut, "up", write=True, addr=a, wdata=new, wstrb=FULL)
    await _evict_from_l1d(dut, [a])  # the L2 now holds the line dirty
    # Read new lines of its L2 set until the set's next miss would evict it.
    await make_l2_next_victim(dut, a)
    evictor = fresh_aliases(a, cache_geometry(dut).l2_way_bytes, 1)[0]
    mark = mon.cycle
    wup, iup = _Collector(dut, "wup"), _Collector(dut, "iup")
    await _hold(dut, 1)
    # The new line's read evicts the dirty line into a writeback slot. Its
    # own fill leaves first; once it has installed, the read of the other half
    # misses with the writeback still pending downstream.
    await _fire(dut, "wup", write=False, addr=evictor, req_id=1)
    await _settle(dut, 40)
    fired, write, _ = await _release_downstream_once(dut)
    assert fired and not write, "the evicting read's fill did not leave first"
    await _settle(dut, 60)
    await _fire(dut, "iup", write=False, addr=b, req_id=1)
    await _settle(dut, 40)
    l2 = _l2(dut)
    slots = _l2_slots_for(dut, a)
    assert len(slots) == 1, f"the other half's miss took {slots}"
    assert int(l2.mshr_wb_wait_q[slots[0][0]].value) != 0, (
        "the miss does not wait for the line's writeback"
    )
    await _hold(dut, 0)
    await wup.wait_for(1)
    assert (await iup.wait_for(1))[1] == model.read_line(b)
    writes = mon.writes_of(a, since=mark)
    reads = mon.reads_of(a, since=mark)
    assert len(writes) == 1 and len(reads) == 1, f"writes {writes}, reads {reads}"
    write_ids = [i for c, i, _ in mon.writes if c == writes[0]]
    acks = [c for c, i in mon.write_done if i == write_ids[0] and c > writes[0]]
    assert acks and reads[0] > acks[0], (
        f"the line was read in cycle {reads[0]} before its writeback landed"
    )
    await _check(dut, model, "wup", a)
    wup.stop()
    iup.stop()
    mon.assert_clean()
    mon.stop()


@cocotb.test()
async def test_reset_with_misses_in_flight(dut: Any) -> None:
    """A reset with fills in flight leaves every line reading its DDR contents.

    The reset sweeps the L2's tags, and the bench's memory model resets with
    the CPU, so fills and writes in flight are dropped. Afterwards both
    halves of every line read their DDR bytes from every port.
    """
    await _setup(dut)
    model = ReferenceModel()
    lines = [RESET_BASE + (2 + 2 * i) * L2_LINE_BYTES for i in range(4)]
    for i, line in enumerate(lines):
        _ddr_put_line(dut, model, line, _two_halves(140 + i)[2])
    await _hold(dut, 1)
    for i, line in enumerate(lines):
        await _fire(dut, "up", write=False, addr=line + (i % 2) * LINE_BYTES, req_id=i)
    await _fire(dut, "iup", write=False, addr=lines[0] + LINE_BYTES, req_id=0)
    await _settle(dut, 30)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 1
    dut.i_down_hold.value = 0
    dut.i_up_req_valid.value = 0
    dut.i_iup_req_valid.value = 0
    await _settle(dut, 4)
    dut.i_rst.value = 0
    for _ in range(200_000):
        await FallingEdge(dut.i_clk)
        if not int(_l2(dut).o_maint_busy.value) and int(dut.o_up_req_ready.value):
            break
    else:
        raise AssertionError("the caches never left the reset sweep")
    mon = AxiMonitor(dut)
    for line in lines:
        for half in _half(line):
            for port in ("up", "iup", "wup"):
                await _check(dut, model, port, half)
    mon.assert_clean()
    mon.stop()


@cocotb.test()
async def test_many_misses_reach_the_high_miss_slots(dut: Any) -> None:
    """Every port's misses together fill the L2's miss slots.

    L1D misses with dirty victims, L1I and walker reads, and DMA writes to
    lines the L2 lacks, all while the bridge is held, take as many L2 miss
    slots as the configuration has (up to what the ports can issue), so the
    highest slots and their ids are exercised. Everything reads back after
    the release.
    """
    await _setup(dut)
    lq = LoadQueueStub(dut)
    mon = AxiMonitor(dut)
    model = ReferenceModel()
    l2 = _l2(dut)
    num_mshr = int(l2.NUM_MSHR.value)
    # Dirty L1D lines in odd L2 sets and distinct L1D sets, and the other
    # ports' lines in even L2 sets, so no two of them share an L2 line.
    dirty = [
        SLOTS_BASE + (1 + 2 * i) * L2_LINE_BYTES + (i // 2) * LINE_BYTES
        for i in range(4)
    ]
    others = [SLOTS_BASE + (8 + 2 * i) * L2_LINE_BYTES for i in range(6)]
    lines = dirty + others
    for i, line in enumerate(lines):
        _ddr_put_line(dut, model, line, _two_halves(150 + i)[2])
    for i, line in enumerate(dirty):
        data = _pattern(170 + i)
        model.write_line(line, data, FULL)
        await _port_transaction(
            dut, "up", write=True, addr=line, wdata=data, wstrb=FULL
        )
    await _evict_from_l2(dut, dirty)  # the L2 lacks the dirty halves' lines
    # A read of a new line of each dirty line's L1D set will evict it.
    evictors = [await _next_miss_evicts_from_l1d(dut, line) for line in dirty]

    cols = {port: _Collector(dut, port) for port in ("up", "iup", "wup", "dma")}
    peak = [0]

    async def watch() -> None:
        while True:
            await FallingEdge(dut.i_clk)
            busy = sum(int(l2.mshr_state_q[i].value) != 0 for i in range(num_mshr))
            peak[0] = max(peak[0], busy)

    watcher = cocotb.start_soon(watch())
    await _hold(dut, 1)
    for i, evictor in enumerate(evictors):
        await _fire(dut, "up", write=False, addr=evictor, req_id=i)
    await _fire(dut, "iup", write=False, addr=others[0], req_id=0)
    await _fire(dut, "iup", write=False, addr=others[1] + LINE_BYTES, req_id=1)
    await _fire(dut, "wup", write=False, addr=others[2], req_id=0)
    for i in range(3):
        data = _pattern(180 + i)
        model.write_line(others[3 + i], data, FULL)
        await _fire(
            dut, "dma", write=True, addr=others[3 + i], req_id=i, wdata=data, wstrb=FULL
        )
    await _settle(dut, 200)
    await _hold(dut, 0)
    for i in range(4):
        await cols["up"].wait_for(i)
    await cols["iup"].wait_for(0)
    await cols["iup"].wait_for(1)
    await cols["wup"].wait_for(0)
    for i in range(3):
        await cols["dma"].wait_for(i)
    watcher.cancel()
    dut._log.info(f"peak L2 miss slots in use: {peak[0]} of {num_mshr}")
    assert peak[0] >= min(num_mshr, 12), f"only {peak[0]} miss slots were ever busy"
    for line in lines:
        for half in _half(line):
            await _check(dut, model, "wup", half)
    for col in cols.values():
        col.stop()
    mon.assert_clean()
    mon.stop()
    lq.stop()


@cocotb.test()
async def test_write_fill_counts_the_writes_that_fetch_their_line(dut: Any) -> None:
    """The write-fill event counts each 32-byte write that fetches its L2 line.

    An L1D writeback of a half whose line the L2 lacks allocates a miss slot
    that fetches the line, and counts once, for either half. The same
    writeback to a resident line hits and does not count. With the bridge
    held, the writebacks of both halves of a missing line share one fetch, as
    do a DMA write of a four-byte status word in one half and of the whole
    other half, the way the NIC writes a frame: the write that allocates
    counts and the one that merges into its slot does not. A DMA write to a
    second missing line meanwhile holds a second slot, and with write fills
    holding every busy slot, their slot-cycles equal the miss slots'. A read
    miss fetches but is not a write and does not count. The tag stage's
    decisions on each line and its fetches at the AXI port are checked too.
    """
    await _setup(dut)
    lq = LoadQueueStub(dut)
    mon = AxiMonitor(dut)
    model = ReferenceModel()
    counts = _new_perf_counts()
    stop = [False]
    cocotb.start_soon(_monitor_perf_events(dut, counts, stop))

    # A writeback of either half to a line the L2 lacks: one fetch, counted.
    for k in range(2):
        _, _, whole = _two_halves(200 + k)
        a, b = _half(WRITE_FILL_BASE + (3 + 4 * k) * L2_LINE_BYTES)
        dirty = a if k == 0 else b
        _ddr_put_line(dut, model, a, whole)
        new = _pattern(210 + k)
        model.write_line(dirty, new, FULL)
        # A whole-line store allocates in the L1D without reaching the L2.
        await _port_transaction(
            dut, "up", write=True, addr=dirty, wdata=new, wstrb=FULL
        )
        mark = mon.cycle
        watch = WriteDecisions(dut, a)
        before = _copy_perf_counts(counts)
        await _evict_from_l1d(dut, [dirty])
        await _settle(dut)
        watch.stop()
        d = _perf_delta(counts, before)
        assert len(mon.reads_of(a, since=mark)) == 1, "the writeback did not fetch"
        assert watch.outcomes() == ["alloc"] and not watch.waits(), watch.decisions
        assert d["l2_write"]["write_fill"] == 1, d
        assert d["l2_write"]["write_fill_outstanding"] > 0, d
        assert d["l2_write"]["write_read_wait"] == 0, d
        await _check(dut, model, "wup", dirty)

    # The same writeback to a line the L2 holds hits: no fetch, not counted.
    _, _, whole = _two_halves(220)
    a, b = _half(WRITE_FILL_BASE + 0x1000 + 3 * L2_LINE_BYTES)
    _ddr_put_line(dut, model, a, whole)
    await _read(dut, "wup", a)  # the line becomes resident in the L2
    new = _pattern(221)
    model.write_line(b, new, FULL)
    await _port_transaction(dut, "up", write=True, addr=b, wdata=new, wstrb=FULL)
    mark = mon.cycle
    watch = WriteDecisions(dut, a)
    before = _copy_perf_counts(counts)
    await _evict_from_l1d(dut, [b])
    await _settle(dut)
    watch.stop()
    d = _perf_delta(counts, before)
    assert not mon.reads_of(a, since=mark), "a resident line was fetched"
    assert watch.outcomes() == ["hit"] and not watch.waits(), watch.decisions
    assert set(d["l2_write"].values()) == {0}, d
    await _check(dut, model, "wup", b)

    # Writebacks of both halves of a missing line, the bridge held: the
    # second merges into the first's miss slot, and one fetch serves both.
    _, _, whole = _two_halves(230)
    a, b = _half(WRITE_FILL_BASE + 0x2000 + 2 * L2_LINE_BYTES)
    _ddr_put_line(dut, model, a, whole)
    new_lo, new_hi = _pattern(231), _pattern(232)
    model.write_line(a, new_lo, FULL)
    model.write_line(b, new_hi, FULL)
    await _port_transaction(dut, "up", write=True, addr=a, wdata=new_lo, wstrb=FULL)
    await _port_transaction(dut, "up", write=True, addr=b, wdata=new_hi, wstrb=FULL)
    await _settle(dut)  # the stores are acknowledged before they install
    evict_a = await _next_miss_evicts_from_l1d(dut, a)
    evict_b = await _next_miss_evicts_from_l1d(dut, b)
    mark = mon.cycle
    watch = WriteDecisions(dut, a)
    before = _copy_perf_counts(counts)
    col = _Collector(dut, "up")
    await _hold(dut, 1)
    await _fire(dut, "up", write=False, addr=evict_a, req_id=1)
    await _fire(dut, "up", write=False, addr=evict_b, req_id=2)
    await _settle(dut, 60)
    await _hold(dut, 0)
    await col.wait_for(1)
    await col.wait_for(2)
    col.stop()
    await _settle(dut)
    watch.stop()
    d = _perf_delta(counts, before)
    assert len(mon.reads_of(a, since=mark)) == 1, "the halves took two fetches"
    assert watch.outcomes() == ["alloc", "merge"], watch.decisions
    assert not watch.waits(), watch.decisions
    assert d["l2_write"]["write_fill"] == 1, d
    await _check(dut, model, "wup", a)
    await _check(dut, model, "wup", b)

    # The bridge held, a DMA status word in the lower half and a whole upper
    # half of one missing line share a fetch, and a DMA write to a second
    # missing line takes a second slot. Only write fills hold miss slots.
    _, _, whole = _two_halves(240)
    a, b = _half(WRITE_FILL_BASE + 0x3000 + 2 * L2_LINE_BYTES)
    _ddr_put_line(dut, model, a, whole)
    c = WRITE_FILL_BASE + 0x3000 + 6 * L2_LINE_BYTES
    _ddr_put_line(dut, model, c, _two_halves(243)[2])
    status, frame, other = _pattern(241), _pattern(242), _pattern(244)
    mark = mon.cycle
    watch_a, watch_c = WriteDecisions(dut, a), WriteDecisions(dut, c)
    before = _copy_perf_counts(counts)
    dma = _Collector(dut, "dma")
    await _hold(dut, 1)
    for req_id, addr, data, strobe in (
        (1, a, status, 0xF),
        (2, b, frame, FULL),
        (3, c, other, FULL),
    ):
        model.write_line(addr, data, strobe)
        await _fire(
            dut, "dma", write=True, addr=addr, req_id=req_id, wdata=data, wstrb=strobe
        )
    await _settle(dut, 60)
    busy = len(_l2_slots_for(dut, a)) + len(_l2_slots_for(dut, c))
    assert busy == 2, f"{busy} miss slots for the two lines"
    assert _perf_field(dut, "l2_write", "write_fill_outstanding") == 2
    await _hold(dut, 0)
    for req_id in (1, 2, 3):
        await dma.wait_for(req_id)
    dma.stop()
    await _settle(dut)
    watch_a.stop()
    watch_c.stop()
    d = _perf_delta(counts, before)
    assert len(mon.reads_of(a, since=mark)) == 1, "line a was fetched twice"
    assert len(mon.reads_of(c, since=mark)) == 1, "line c was not fetched once"
    assert watch_a.outcomes() == ["alloc", "merge"], watch_a.decisions
    assert watch_c.outcomes() == ["alloc"], watch_c.decisions
    assert d["l2"]["miss"] == 3, d
    assert d["l2_write"]["write_fill"] == 2, d
    # Both slots are write fills, so the slot-cycle sums agree.
    assert d["l2_write"]["write_fill_outstanding"] == d["l2"]["miss_outstanding"], d
    assert d["l2_write"]["write_read_wait"] == 0, d
    for addr in (a, b, c):
        await _check(dut, model, "wup", addr)

    # A read miss fetches its line but is no write.
    e = WRITE_FILL_BASE + 0x4000 + 3 * L2_LINE_BYTES
    mark = mon.cycle
    before = _copy_perf_counts(counts)
    await _read(dut, "wup", e)
    await _settle(dut)
    d = _perf_delta(counts, before)
    assert len(mon.reads_of(e, since=mark)) == 1
    assert d["l2"]["miss"] == 1 and d["l2"]["miss_outstanding"] > 0, d
    assert set(d["l2_write"].values()) == {0}, d

    stop[0] = True
    mon.assert_clean()
    mon.stop()
    lq.stop()


@cocotb.test()
async def test_write_read_wait_counts_writes_held_behind_a_read(dut: Any) -> None:
    """The write-read wait events count writes that wait for a read of their line.

    With the bridge held, an L1I read of one half takes the line's miss slot,
    and the L1D's writeback of the other half, or of the same half, waits
    until that fill installs, then hits. Then a DMA write takes a missing
    line's slot, a walker read of either half waits on it, and a second DMA
    write of that half waits for the read. Each waiting write counts once,
    and the cycles it holds the L2 equal the cycles from its first tag-stage
    decision to the one that completes it, which comes after the line's
    fill. A write that waited for a read fetches nothing itself. A DMA write
    that merges into a write's miss slot with no read on it does not wait.
    """
    await _setup(dut)
    lq = LoadQueueStub(dut)
    mon = AxiMonitor(dut)
    model = ReferenceModel()
    counts = _new_perf_counts()
    stop = [False]
    cocotb.start_soon(_monitor_perf_events(dut, counts, stop))

    def check_one_wait(watch: WriteDecisions, d: dict[str, dict[str, int]]) -> None:
        waits = watch.waits()
        assert len(waits) == 1, f"writes that held the tag stage: {waits}"
        first, done = waits[0]
        assert watch.read_done and first < watch.read_done[0] < done, (
            f"the write waited from cycle {first} to {done}, the line's fill "
            f"arrived in {watch.read_done}"
        )
        assert d["l2_write"]["write_read_wait"] == 1, d
        assert d["l2_write"]["write_read_waiting"] == done - first, (d, waits)
        assert d["l2"]["conflict_stall"] > 0, d
        dut._log.info(
            f"a write held the L2 for {done - first} cycles, from its first "
            f"decision to the one after its line's fill"
        )

    # An L1D writeback while an L1I read of the line is fetching it: of the
    # other half, then, in the third round, of the same half, where the read
    # returns the line from before the writeback.
    for k, (read_lower, dirty_lower) in enumerate(
        ((True, False), (False, True), (True, True))
    ):
        _, _, whole = _two_halves(300 + k)
        a, b = _half(WRITE_WAIT_BASE + (3 + 4 * k) * L2_LINE_BYTES)
        read_half = a if read_lower else b
        dirty = a if dirty_lower else b
        _ddr_put_line(dut, model, a, whole)
        expected_read = model.read_line(read_half)
        new = _pattern(310 + k)
        model.write_line(dirty, new, FULL)
        await _port_transaction(
            dut, "up", write=True, addr=dirty, wdata=new, wstrb=FULL
        )
        await _settle(dut)  # the store is acknowledged before it installs
        evictor = await _next_miss_evicts_from_l1d(dut, dirty)
        watch = WriteDecisions(dut, a)
        before = _copy_perf_counts(counts)
        iup, up = _Collector(dut, "iup"), _Collector(dut, "up")
        await _hold(dut, 1)
        await _fire(dut, "iup", write=False, addr=read_half, req_id=1)
        await _settle(dut, 30)
        await _fire(dut, "up", write=False, addr=evictor, req_id=1)
        await _settle(dut, 40)
        await _hold(dut, 0)
        assert (await iup.wait_for(1))[1] == expected_read
        await up.wait_for(1)
        iup.stop()
        up.stop()
        await _settle(dut)
        watch.stop()
        d = _perf_delta(counts, before)
        check_one_wait(watch, d)
        assert watch.outcomes() == ["hit"], watch.decisions
        assert d["l2_write"]["write_fill"] == 0, d
        await _check(dut, model, "wup", dirty)

    # A second DMA write of a half held behind a walker read waiting on the
    # first DMA write's miss slot: the same half, then the other half.
    for k in range(2):
        _, _, whole = _two_halves(320 + k)
        a, b = _half(WRITE_WAIT_BASE + 0x2000 + (2 + 4 * k) * L2_LINE_BYTES)
        _ddr_put_line(dut, model, a, whole)
        first_data, second_data = _pattern(330 + k), _pattern(340 + k)
        later = a if k == 0 else b
        watch = WriteDecisions(dut, a)
        before = _copy_perf_counts(counts)
        dma, wup = _Collector(dut, "dma"), _Collector(dut, "wup")
        await _hold(dut, 1)
        await _fire(
            dut, "dma", write=True, addr=a, req_id=1, wdata=first_data, wstrb=FULL
        )
        model.write_line(a, first_data, FULL)
        expected_read = model.read_line(later)
        await _settle(dut, 40)
        await _fire(dut, "wup", write=False, addr=later, req_id=1)
        await _settle(dut, 40)
        await _fire(
            dut, "dma", write=True, addr=later, req_id=2, wdata=second_data, wstrb=FULL
        )
        model.write_line(later, second_data, FULL)
        await _settle(dut, 40)
        await _hold(dut, 0)
        assert (await wup.wait_for(1))[1] == expected_read
        await dma.wait_for(1)
        await dma.wait_for(2)
        dma.stop()
        wup.stop()
        await _settle(dut)
        watch.stop()
        d = _perf_delta(counts, before)
        check_one_wait(watch, d)
        assert watch.outcomes() == ["alloc", "hit"], watch.decisions
        assert d["l2_write"]["write_fill"] == 1, d
        await _check(dut, model, "wup", a)
        await _check(dut, model, "wup", b)

    # A second DMA write of the other half merges into the first's miss slot,
    # which no read waits on: no write holds the tag stage.
    _, _, whole = _two_halves(350)
    a, b = _half(WRITE_WAIT_BASE + 0x4000 + 2 * L2_LINE_BYTES)
    _ddr_put_line(dut, model, a, whole)
    watch = WriteDecisions(dut, a)
    before = _copy_perf_counts(counts)
    dma = _Collector(dut, "dma")
    await _hold(dut, 1)
    for req_id, addr in ((1, a), (2, b)):
        data = _pattern(351 + req_id)
        model.write_line(addr, data, FULL)
        await _fire(
            dut, "dma", write=True, addr=addr, req_id=req_id, wdata=data, wstrb=FULL
        )
    await _settle(dut, 60)
    await _hold(dut, 0)
    await dma.wait_for(1)
    await dma.wait_for(2)
    dma.stop()
    await _settle(dut)
    watch.stop()
    d = _perf_delta(counts, before)
    assert watch.outcomes() == ["alloc", "merge"], watch.decisions
    assert not watch.waits(), watch.decisions
    assert d["l2_write"]["write_read_wait"] == 0, d
    assert d["l2_write"]["write_read_waiting"] == 0, d
    assert d["l2_write"]["write_fill"] == 1, d
    await _check(dut, model, "wup", a)
    await _check(dut, model, "wup", b)

    stop[0] = True
    mon.assert_clean()
    mon.stop()
    lq.stop()
