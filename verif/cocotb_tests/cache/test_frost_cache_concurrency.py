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

"""Concurrency tests for the non-blocking frost_cache hierarchy.

Same harness as test_frost_cache (frost_cache_test_harness), but the driver
keeps several tagged transactions in flight per port and collects responses
by id in whatever order the cache completes them. Checked: pipelined hits
(one per cycle), hit-under-miss, miss-under-miss overlap at every level,
early acknowledgement of write misses with merging into the pending fill,
the read waiter, index conflicts, a fill of a line whose writeback is still
pending, the downstream pick's progress bounds under a bench-paced downstream
(a writeback against a fill stream that would otherwise starve it, and one
writeback slot against a dirty-victim stream recycling the other), a delayed
tag response racing a same-index fill install, a read racing an MSHR slot
re-manned for another line, fence.i with pending misses, and random mixed
traffic with same-line sequences checked against a reference model in
acceptance order.
"""

import random
from typing import Any

import cocotb
from cocotb.triggers import FallingEdge, Lock, ReadOnly

from cocotb_tests.cache.test_frost_cache import (
    BASE_ADDR,
    LINE_BYTES,
    UP_ID_BITS,
    ReferenceModel,
    _fence_sync,
    _line_int,
    _monitor_perf_events,
    _new_perf_counts,
    _setup,
)

FULL = (1 << LINE_BYTES) - 1
NUM_IDS = 1 << UP_ID_BITS
MEM_LATENCY = 12  # harness default
L1_LINES = 1024 // LINE_BYTES  # harness L1 = 1 KiB
L2_BYTES = 4096  # harness L2

# Disjoint per-test regions (the behavioral DDR persists across in-run resets).
PIPE_BASE = BASE_ADDR + 0x400000
HUM_BASE = BASE_ADDR + 0x440000
MUM_BASE = BASE_ADDR + 0x480000
MERGE_BASE = BASE_ADDR + 0x4C0000
WAITER_BASE = BASE_ADDR + 0x500000
CONFLICT_BASE = BASE_ADDR + 0x540000
STALE_BASE = BASE_ADDR + 0x680000
WBFILL_BASE = BASE_ADDR + 0x580000
FENCE_BASE = BASE_ADDR + 0x5C0000
RANDOM_BASE = BASE_ADDR + 0x600000
TAG_INSTALL_BASE = BASE_ADDR + 0x640000
STARVE_BASE = BASE_ADDR + 0x6C0000
RESP_TIMEOUT_CYCLES = 5_000

# frost_cache.sv WbStarveLimit: the loads of the downstream request register
# a pending writeback may lose to fills before the next load is a
# writeback's. A writeback that becomes pending while the register holds a
# fill therefore fires after at most WB_STARVE_LIMIT + 1 fill acceptances.
WB_STARVE_LIMIT = 3
# The writeback slots take turns (the pick rotates from the slot after the
# last one loaded), so a pending slot is loaded within NUM_WB writeback loads:
# NUM_WB * (WB_STARVE_LIMIT + 1) loads of the register. NUM_WB is 2.
WB_SLOT_TURN_BOUND = 2 * (WB_STARVE_LIMIT + 1)
WB_FREE = 0  # wb_state_e ordinals: FREE, FILLING, PEND, SENT
WB_PEND = 2
# Acceptances are spaced so that the fill accepted at one completes, responds,
# and its reader re-issues into a re-allocated miss slot before the next, and
# so that a writeback's acknowledgement (one memory latency) frees its slot
# well before the next acceptance.
STARVE_GRANT_SPACING = 64
# The bench gives up on a writeback after this many acceptances. The cache's
# own tripwire (32 lost loads) is below it, so a pick that starves the
# writeback stops the run there first.
STARVE_GIVE_UP_FILLS = 48


class _Ids:
    """Per-port id allocator: ids cycle so consecutive requests never share one."""

    def __init__(self) -> None:
        self._next = {"up": 0, "iup": 0, "wup": 0}
        self._modulus = {"up": NUM_IDS, "iup": NUM_IDS, "wup": NUM_IDS // 2}

    def take(self, port: str) -> int:
        value = self._next[port]
        self._next[port] = (value + 1) % self._modulus[port]
        return value


_ids = _Ids()


async def _fire(
    dut: Any,
    port: str,
    *,
    write: bool,
    addr: int,
    req_id: int,
    wdata: int = 0,
    wstrb: int = 0,
) -> None:
    """Present one request and return in the cycle after it fired."""
    req_valid = getattr(dut, f"i_{port}_req_valid")
    req_ready = getattr(dut, f"o_{port}_req_ready")
    await FallingEdge(dut.i_clk)
    req_valid.value = 1
    getattr(dut, f"i_{port}_req_write").value = 1 if write else 0
    getattr(dut, f"i_{port}_req_addr").value = addr
    getattr(dut, f"i_{port}_req_wdata").value = wdata
    getattr(dut, f"i_{port}_req_wstrb").value = wstrb
    getattr(dut, f"i_{port}_req_id").value = req_id
    for _ in range(RESP_TIMEOUT_CYCLES):
        await ReadOnly()
        if int(req_ready.value) == 1:
            break
        await FallingEdge(dut.i_clk)
    else:
        raise AssertionError(f"{port}: request never accepted (addr=0x{addr:08x})")
    await FallingEdge(dut.i_clk)
    req_valid.value = 0


class _Collector:
    """Background monitor gathering every response on a port keyed by id."""

    def __init__(self, dut: Any, port: str) -> None:
        self._dut = dut
        self._port = port
        self.pending: dict[int, list[tuple[int, int]]] = {}  # id -> [(cycle, data)]
        self.cycle = 0
        self._task = cocotb.start_soon(self._run())

    async def _run(self) -> None:
        resp_valid = getattr(self._dut, f"o_{self._port}_resp_valid")
        resp_id = getattr(self._dut, f"o_{self._port}_resp_id")
        resp_rdata = getattr(self._dut, f"o_{self._port}_resp_rdata")
        while True:
            await FallingEdge(self._dut.i_clk)
            self.cycle += 1
            if int(resp_valid.value) == 1:
                rid = int(resp_id.value)
                self.pending.setdefault(rid, []).append(
                    (self.cycle, int(resp_rdata.value))
                )

    async def wait_for(self, req_id: int) -> tuple[int, int]:
        """Block until a response with req_id arrives; return (cycle, data)."""
        for _ in range(RESP_TIMEOUT_CYCLES):
            if self.pending.get(req_id):
                return self.pending[req_id].pop(0)
            await FallingEdge(self._dut.i_clk)
        raise AssertionError(f"{self._port}: no response for id {req_id}")

    def stop(self) -> None:
        self._task.cancel()


async def _transaction(
    dut: Any,
    port: str,
    col: _Collector,
    *,
    write: bool,
    addr: int,
    wdata: int = 0,
    wstrb: int = 0,
) -> int:
    """One tagged transaction to completion; returns the read data."""
    req_id = _ids.take(port)
    await _fire(
        dut, port, write=write, addr=addr, req_id=req_id, wdata=wdata, wstrb=wstrb
    )
    _, data = await col.wait_for(req_id)
    return data


async def _settle(dut: Any, cycles: int = 80) -> None:
    for _ in range(cycles):
        await FallingEdge(dut.i_clk)


async def _evict_with_reads(
    dut: Any, col: _Collector, base: int, lines: int = 256
) -> None:
    """Read aliasing lines so every level forgets the test's lines.

    The harness caches are tiny, so `lines` reads push everything out with
    clean victims.
    """
    for line in range(lines):
        await _transaction(dut, "up", col, write=False, addr=base + line * LINE_BYTES)
    await _settle(dut)


@cocotb.test()
async def test_pipelined_hits(dut: Any) -> None:
    """Back-to-back read hits complete one per cycle, not one per hit latency."""
    await _setup(dut)
    col = _Collector(dut, "up")
    model = ReferenceModel()
    n = 8
    for line in range(n):
        addr = PIPE_BASE + line * LINE_BYTES
        wdata = _line_int(bytes([(0x50 + line + b) & 0xFF for b in range(32)]))
        model.write_line(addr, wdata, FULL)
        await _transaction(
            dut, "up", col, write=True, addr=addr, wdata=wdata, wstrb=FULL
        )
    # Warm: read each once so every line is an L1D hit, then wait for quiet.
    for line in range(n):
        await _transaction(
            dut, "up", col, write=False, addr=PIPE_BASE + line * LINE_BYTES
        )
    await _settle(dut)

    ids = []
    start = col.cycle
    for line in range(n):
        req_id = _ids.take("up")
        ids.append((req_id, line))
        await _fire(
            dut, "up", write=False, addr=PIPE_BASE + line * LINE_BYTES, req_id=req_id
        )
    last = 0
    for req_id, line in ids:
        cycle, data = await col.wait_for(req_id)
        assert data == model.read_line(PIPE_BASE + line * LINE_BYTES), (
            f"line {line} mismatch"
        )
        last = max(last, cycle)
    elapsed = last - start
    dut._log.info(f"{n} pipelined hits completed in {elapsed} cycles")
    # Blocking: >= n * 5 cycles. Pipelined: n + latency + a few.
    assert elapsed <= n + 12, f"hits did not pipeline: {elapsed} cycles for {n}"
    col.stop()


@cocotb.test()
async def test_hit_under_miss(dut: Any) -> None:
    """A hit issued behind a miss completes before the miss."""
    await _setup(dut)
    col = _Collector(dut, "up")
    model = ReferenceModel()
    hit_addr = HUM_BASE + 3 * LINE_BYTES
    miss_addr = HUM_BASE + 0x20000 + 7 * LINE_BYTES
    hit_data = _line_int(bytes([0x11 + b for b in range(32)]))
    miss_data = _line_int(bytes([0x77 + b for b in range(32)]))
    for addr, data in ((hit_addr, hit_data), (miss_addr, miss_data)):
        model.write_line(addr, data, FULL)
        await _transaction(
            dut, "up", col, write=True, addr=addr, wdata=data, wstrb=FULL
        )
    # Evict everything, then bring only hit_addr back.
    await _evict_with_reads(dut, col, HUM_BASE + 0x40000)
    await _transaction(dut, "up", col, write=False, addr=hit_addr)
    await _settle(dut)

    miss_id, hit_id = _ids.take("up"), _ids.take("up")
    await _fire(dut, "up", write=False, addr=miss_addr, req_id=miss_id)
    await _fire(dut, "up", write=False, addr=hit_addr, req_id=hit_id)
    hit_cycle, hit_got = await col.wait_for(hit_id)
    miss_cycle, miss_got = await col.wait_for(miss_id)
    assert hit_got == hit_data and miss_got == miss_data
    assert hit_cycle < miss_cycle, (
        f"hit ({hit_cycle}) did not pass the miss ({miss_cycle})"
    )
    col.stop()


@cocotb.test()
async def test_miss_under_miss(dut: Any) -> None:
    """Two demand misses overlap: the second completes within one memory latency of the first."""
    await _setup(dut)
    col = _Collector(dut, "up")
    model = ReferenceModel()
    # Distinct indices at every level (same-index misses serialize by design).
    addrs = [MUM_BASE + 0x20000 * k + (5 + 3 * k) * LINE_BYTES for k in range(3)]
    for k, addr in enumerate(addrs):
        data = _line_int(bytes([(0x30 * (k + 1) + b) & 0xFF for b in range(32)]))
        model.write_line(addr, data, FULL)
        await _transaction(
            dut, "up", col, write=True, addr=addr, wdata=data, wstrb=FULL
        )
    await _evict_with_reads(dut, col, MUM_BASE + 0x80000)

    ids = [_ids.take("up") for _ in addrs]
    for req_id, addr in zip(ids, addrs):
        await _fire(dut, "up", write=False, addr=addr, req_id=req_id)
    cycles = []
    for req_id, addr in zip(ids, addrs):
        cycle, got = await col.wait_for(req_id)
        assert got == model.read_line(addr), f"mismatch @0x{addr:08x}"
        cycles.append(cycle)
    spread = max(cycles) - min(cycles)
    dut._log.info(f"three overlapped misses: responses within {spread} cycles")
    assert spread < MEM_LATENCY, f"misses serialized: spread {spread}"
    col.stop()


@cocotb.test()
async def test_write_miss_early_ack_and_merge(dut: Any) -> None:
    """A write miss is acknowledged before its fill lands; later writes merge into it."""
    await _setup(dut)
    col = _Collector(dut, "up")
    model = ReferenceModel()
    addr = MERGE_BASE + 11 * LINE_BYTES
    seed = _line_int(bytes([(0xA0 + b) & 0xFF for b in range(32)]))
    model.write_line(addr, seed, FULL)
    await _transaction(dut, "up", col, write=True, addr=addr, wdata=seed, wstrb=FULL)
    await _evict_with_reads(dut, col, MERGE_BASE + 0x40000)

    w1 = _line_int(bytes([0x11] * 32))
    w2 = _line_int(bytes([0x22] * 32))
    model.write_line(addr, w1, 0x0000_00FF)
    model.write_line(addr, w2, 0x00FF_0000)
    id1, id2, id3 = (_ids.take("up") for _ in range(3))
    start = col.cycle
    await _fire(
        dut, "up", write=True, addr=addr, req_id=id1, wdata=w1, wstrb=0x0000_00FF
    )
    await _fire(
        dut, "up", write=True, addr=addr, req_id=id2, wdata=w2, wstrb=0x00FF_0000
    )
    await _fire(dut, "up", write=False, addr=addr, req_id=id3)
    ack1, _ = await col.wait_for(id1)
    ack2, _ = await col.wait_for(id2)
    read_cycle, got = await col.wait_for(id3)
    assert ack1 - start < MEM_LATENCY, (
        f"write miss ack waited for the fill ({ack1 - start})"
    )
    assert ack2 - start < MEM_LATENCY, (
        f"merged write ack waited for the fill ({ack2 - start})"
    )
    assert got == model.read_line(addr), (
        "read did not see both merged writes over the fill"
    )
    assert read_cycle >= ack2
    col.stop()


@cocotb.test()
async def test_read_waiter(dut: Any) -> None:
    """Secondary reads of a line under fill complete with the fill's data."""
    await _setup(dut)
    col = _Collector(dut, "up")
    model = ReferenceModel()
    addr = WAITER_BASE + 2 * LINE_BYTES
    data = _line_int(bytes([(0xC3 + b) & 0xFF for b in range(32)]))
    model.write_line(addr, data, FULL)
    await _transaction(dut, "up", col, write=True, addr=addr, wdata=data, wstrb=FULL)
    await _evict_with_reads(dut, col, WAITER_BASE + 0x40000)

    ids = [_ids.take("up") for _ in range(3)]
    for req_id in ids:
        await _fire(dut, "up", write=False, addr=addr, req_id=req_id)
    for req_id in ids:
        _, got = await col.wait_for(req_id)
        assert got == data, f"id {req_id}: 0x{got:064x}"
    col.stop()


@cocotb.test()
async def test_index_conflict(dut: Any) -> None:
    """Requests to an index in transition wait and then complete correctly."""
    await _setup(dut)
    col = _Collector(dut, "up")
    model = ReferenceModel()
    x = CONFLICT_BASE + 6 * LINE_BYTES
    y = x + 1024  # same L1D index, different tag
    z = x + 2048
    for k, addr in enumerate((x, y, z)):
        data = _line_int(bytes([(0x60 + 0x20 * k + b) & 0xFF for b in range(32)]))
        model.write_line(addr, data, FULL)
        await _transaction(
            dut, "up", col, write=True, addr=addr, wdata=data, wstrb=FULL
        )
    await _evict_with_reads(dut, col, CONFLICT_BASE + 0x40000)

    ids = [_ids.take("up") for _ in range(3)]
    for req_id, addr in zip(ids, (x, y, z)):
        await _fire(dut, "up", write=False, addr=addr, req_id=req_id)
    for req_id, addr in zip(ids, (x, y, z)):
        _, got = await col.wait_for(req_id)
        assert got == model.read_line(addr), f"mismatch @0x{addr:08x}"
    # And a write into the conflict, followed by a read of the evicted line.
    w = _line_int(bytes([0x5A] * 32))
    model.write_line(y, w, 0xF0F0_F0F0)
    ida, idb, idc = (_ids.take("up") for _ in range(3))
    await _fire(dut, "up", write=False, addr=x, req_id=ida)
    await _fire(dut, "up", write=True, addr=y, req_id=idb, wdata=w, wstrb=0xF0F0_F0F0)
    await _fire(dut, "up", write=False, addr=y, req_id=idc)
    _, gx = await col.wait_for(ida)
    await col.wait_for(idb)
    _, gy = await col.wait_for(idc)
    assert gx == model.read_line(x) and gy == model.read_line(y)
    col.stop()


@cocotb.test()
async def test_fill_waits_for_pending_writeback(dut: Any) -> None:
    """A fill of a line whose writeback is still in flight returns the written-back data."""
    await _setup(dut)
    col = _Collector(dut, "up")
    model = ReferenceModel()
    x = WBFILL_BASE + 4 * LINE_BYTES
    alias = x + 1024
    seed = _line_int(bytes([(0x9A + b) & 0xFF for b in range(32)]))
    model.write_line(x, seed, FULL)
    await _transaction(dut, "up", col, write=True, addr=x, wdata=seed, wstrb=FULL)
    await _settle(dut)
    # Now: x dirty in L1D. Evict it with a write to its alias (x's writeback
    # goes to a slot), and immediately re-read x: its fill must not overtake
    # the writeback.
    w = _line_int(bytes([0x33] * 32))
    model.write_line(alias, w, FULL)
    ida, idb = _ids.take("up"), _ids.take("up")
    await _fire(dut, "up", write=True, addr=alias, req_id=ida, wdata=w, wstrb=FULL)
    await _fire(dut, "up", write=False, addr=x, req_id=idb)
    await col.wait_for(ida)
    _, got = await col.wait_for(idb)
    assert got == seed, f"fill overtook the writeback: 0x{got:064x}"
    # The alias is dirty in L1D now; read it back too.
    assert await _transaction(dut, "up", col, write=False, addr=alias) == w
    col.stop()


def _bottom_cache(dut: Any) -> Any:
    """Return the cache whose downstream port is the bridge: the L2, else the L1D."""
    if int(dut.o_has_l2.value) != 0:
        return dut.cache_hierarchy.gen_l2.l2_cache
    return dut.cache_hierarchy.l1_cache


class _WritebackPendingMonitor:
    """Record, per writeback slot of one cache, the first cycle it is WB_PEND."""

    def __init__(self, dut: Any, cache: Any) -> None:
        self._dut = dut
        self._cache = cache
        self.cycle = 0
        self.num_wb = int(cache.NUM_WB.value)
        self.pend_cycle: list[int | None] = [None] * self.num_wb
        self._task = cocotb.start_soon(self._run())

    async def _run(self) -> None:
        while True:
            await FallingEdge(self._dut.i_clk)
            self.cycle += 1
            for j in range(self.num_wb):
                if (
                    self.pend_cycle[j] is None
                    and int(self._cache.wb_state_q[j].value) == WB_PEND
                ):
                    self.pend_cycle[j] = self.cycle

    def any_pending(self) -> bool:
        return any(cycle is not None for cycle in self.pend_cycle)

    def all_pending(self) -> bool:
        return all(cycle is not None for cycle in self.pend_cycle)

    def stop(self) -> None:
        self._task.cancel()


class _FreshLines:
    """Lines never touched before, on L1 indices no reader holds in flight.

    Each line is a new tag on its index, so every read misses at every level
    with a clean victim; in-flight lines take distinct L1 indices, and with
    them distinct L2 indices, so none waits on another's miss slot. `skip`
    holds the indices the test uses for its own lines.
    """

    def __init__(self, base: int, skip: frozenset[int]) -> None:
        self._base = base
        self._skip = skip
        self._tag = [0] * L1_LINES
        self.in_flight: set[int] = set()

    def take(self) -> tuple[int, int | None]:
        """Return (addr, index) of a fresh line and mark its index in flight."""
        for index in range(L1_LINES):
            if index not in self._skip and index not in self.in_flight:
                break
        else:
            raise AssertionError("every L1 index is in flight")
        addr = self._base + self._tag[index] * 1024 + index * LINE_BYTES
        self._tag[index] += 1
        self.in_flight.add(index)
        return addr, index

    def release(self, index: int | None) -> None:
        if index is not None:
            self.in_flight.discard(index)


class _LinesThen:
    """Serve the caller's lines in order, then (if given) fresh ones."""

    def __init__(self, first: list[int], then: _FreshLines | None) -> None:
        self._first = list(first)
        self._then = then

    def take(self) -> tuple[int, int | None]:
        if self._first:
            return self._first.pop(0), None
        if self._then is None:
            raise AssertionError("the reader's lines are exhausted")
        return self._then.take()

    def release(self, index: int | None) -> None:
        if self._then is not None:
            self._then.release(index)


async def _stream_reader(
    dut: Any,
    col: _Collector,
    model: ReferenceModel,
    lines: _FreshLines | _LinesThen,
    port_lock: Lock,
    ids: tuple[int, int],
    stop: list[bool],
) -> None:
    """Keep one read miss in flight, re-issuing as each fill returns.

    Readers alternate between two ids of their own, so ids never repeat
    among in-flight requests however unevenly the fills complete.
    """
    issued = 0
    while not stop[0]:
        addr, index = lines.take()
        req_id = ids[issued % 2]
        issued += 1
        async with port_lock:
            await _fire(dut, "up", write=False, addr=addr, req_id=req_id)
        _, got = await col.wait_for(req_id)
        lines.release(index)
        assert got == model.read_line(addr), f"stream read mismatch @0x{addr:08x}"


async def _dirty_victim_reader(
    dut: Any,
    col: _Collector,
    model: ReferenceModel,
    cache: Any,
    aliases: list[int],
    port_lock: Lock,
    ids: tuple[int, int],
    stop: list[bool],
) -> None:
    """Read the aliases of dirty lines, one whenever a writeback slot is free.

    A dirty-victim miss that finds no free slot parks in the decision stage
    and holds every request behind it, which would dry up the fill stream
    the test needs; gated on a free slot, each miss allocates at once and
    takes slot 0 the moment its acknowledgement frees it. Two ids let a read
    whose fill the pick keeps waiting stay in flight while the next issues.
    """
    num_wb = int(cache.NUM_WB.value)
    pending: list[tuple[int, int]] = []  # (id, addr)
    issued = 0
    for addr in aliases:
        for _ in range(RESP_TIMEOUT_CYCLES):
            while pending and col.pending.get(pending[0][0]):
                req_id, done = pending.pop(0)
                _, got = await col.wait_for(req_id)
                assert got == model.read_line(done), f"dirty-victim read @0x{done:08x}"
            if stop[0] or (
                len(pending) < 2
                and any(
                    int(cache.wb_state_q[j].value) == WB_FREE for j in range(num_wb)
                )
            ):
                break
            await FallingEdge(dut.i_clk)
        else:
            raise AssertionError("no writeback slot freed for the next dirty victim")
        if stop[0]:
            break
        req_id = ids[issued % 2]
        issued += 1
        async with port_lock:
            await _fire(dut, "up", write=False, addr=addr, req_id=req_id)
        pending.append((req_id, addr))
        await _settle(
            dut, 24
        )  # the miss takes its slot before the slots are judged again
    for req_id, done in pending:
        _, got = await col.wait_for(req_id)
        assert got == model.read_line(done), f"dirty-victim read @0x{done:08x}"


async def _release_downstream_once(dut: Any) -> tuple[bool, bool, int]:
    """Let the bridge accept for one cycle; report (fired, write, addr)."""
    await FallingEdge(dut.i_clk)
    dut.i_down_hold.value = 0
    await ReadOnly()
    fired = (
        int(dut.stack_down_req_valid.value) == 1
        and int(dut.stack_down_req_ready.value) == 1
    )
    write = int(dut.stack_down_req_write.value) == 1
    addr = int(dut.stack_down_req_addr.value)
    await FallingEdge(dut.i_clk)
    dut.i_down_hold.value = 1
    return fired, write, addr


@cocotb.test()
async def test_writeback_wins_within_bound_under_fill_stream(dut: Any) -> None:
    """A writeback that fills keep beating is loaded within the pick's bound.

    The downstream request register takes a pending fill ahead of a pending
    writeback. Under a level below that accepts slowly, fills that complete
    and re-allocate between its acceptances keep a fill pending at every load
    of the register, and a writeback would sit in its slot for as long as the
    stream lasts, with the store, install, probe or fill waiting for its
    acknowledgement (frost_cache.sv) waiting behind it. The cache bounds the
    loss: after WbStarveLimit loads to fills, the next load is a writeback's.
    The bench builds the stream at the cache whose downstream is the bridge
    (the L2 in the X3 shape, the L1D otherwise): it holds the bridge through
    the harness's i_down_hold, releasing one acceptance every
    STARVE_GRANT_SPACING cycles, while four readers keep a miss of a fresh
    line in flight on every miss slot, each re-issuing as soon as its fill
    returns. The first read aliases a line dirty at that cache (pushed down
    from the L1D first in the X3 shape), so its fill evicts the line into a
    writeback slot behind the fill the register holds. The writeback must
    lose at least one acceptance, so the contention the bound exists for was
    reached, and must fire within WB_STARVE_LIMIT + 1 fill acceptances of
    becoming pending. Without the bound, the cache's tripwire stops the run
    once the writeback has lost 32 loads; the bench's STARVE_GIVE_UP_FILLS is
    the backstop. The lines then read back through the drained hierarchy.
    """
    await _setup(dut)
    col = _Collector(dut, "up")
    model = ReferenceModel()
    cache = _bottom_cache(dut)
    has_l2 = int(dut.o_has_l2.value) != 0

    a = STARVE_BASE + 7 * LINE_BYTES
    v0 = _line_int(bytes([(0xA5 + b) & 0xFF for b in range(32)]))
    model.write_line(a, v0, FULL)
    await _transaction(dut, "up", col, write=True, addr=a, wdata=v0, wstrb=FULL)
    if has_l2:
        # Push the dirty line into the L2 with a read of its L1 alias, and let
        # the L1D's writeback and its acknowledgement drain.
        await _transaction(dut, "up", col, write=False, addr=a + 1024)
        evictor = a + 4096  # same L2 index, new tag
    else:
        evictor = a + 1024  # same L1 index, new tag
    await _settle(dut)

    await FallingEdge(dut.i_clk)
    dut.i_down_hold.value = 1
    mon = _WritebackPendingMonitor(dut, cache)
    fresh = _FreshLines(STARVE_BASE + 0x10000, skip=frozenset({7}))
    port_lock = Lock()
    stop = [False]
    readers = [
        cocotb.start_soon(
            _stream_reader(
                dut,
                col,
                model,
                _LinesThen([evictor], fresh) if r == 0 else fresh,
                port_lock,
                (r, r + 4),
                stop,
            )
        )
        for r in range(4)
    ]

    # The evicting fill leaves the line in a writeback slot behind the fill
    # the register already holds; the stream then fills the miss slots.
    for _ in range(RESP_TIMEOUT_CYCLES):
        await FallingEdge(dut.i_clk)
        if mon.any_pending():
            break
    else:
        raise AssertionError("the evicting fill never left a writeback pending")
    await _settle(dut, STARVE_GRANT_SPACING)

    fills_before_wb = 0
    wb_fired = False
    while fills_before_wb < STARVE_GIVE_UP_FILLS:
        fired, write, addr = await _release_downstream_once(dut)
        assert fired, "a released acceptance found no request presented"
        if write:
            assert addr == a, f"unexpected write fired downstream @0x{addr:08x}"
            wb_fired = True
            break
        fills_before_wb += 1
        await _settle(dut, STARVE_GRANT_SPACING)
    stop[0] = True
    await FallingEdge(dut.i_clk)
    dut.i_down_hold.value = 0
    dut._log.info(
        f"writeback fired after {fills_before_wb} fill acceptances (has_l2={has_l2})"
    )
    assert wb_fired, f"writeback still pending after {fills_before_wb} fill acceptances"
    assert fills_before_wb >= 1, "the writeback never lost an acceptance to a fill"
    assert fills_before_wb <= WB_STARVE_LIMIT + 1, (
        f"writeback fired only after {fills_before_wb} fill acceptances; "
        f"the bound is {WB_STARVE_LIMIT + 1}"
    )
    for reader in readers:
        await reader
    mon.stop()
    await _settle(dut)

    assert await _transaction(dut, "up", col, write=False, addr=a) == v0
    assert await _transaction(dut, "up", col, write=False, addr=evictor) == 0
    col.stop()


@cocotb.test()
async def test_writeback_slots_take_turns_under_dirty_victim_stream(dut: Any) -> None:
    """A slot whose neighbour is recycled between writeback loads still gets its turn.

    The fill bound alone says some writeback loads within four loads of the
    register, not which: picked lowest-index-first, slot 1 would lose every
    writeback load to a slot 0 that the level below acknowledges, and a
    parked dirty-victim miss re-mans, before the next one. The pick therefore
    rotates from the slot after the last one loaded, so a pending slot is
    loaded within NUM_WB writeback loads, WB_SLOT_TURN_BOUND loads in all.
    The bench builds the recycling at the cache whose downstream is the
    bridge (the L2 in the X3 shape, the L1D otherwise): it dirties a run of
    lines there, holds the bridge, and reads their aliases one at a time,
    each as a slot frees, so the first two fill both slots and every later
    one takes slot 0 the moment its acknowledgement (one memory latency)
    frees it, without parking in that cache's decision stage where it would
    hold up the fills behind it; two readers of fresh lines keep fills
    pending so that writeback loads are three loads apart, time enough for
    the recycling. Slot 1's line must lose at least one writeback load to slot 0,
    so the contention the rotation exists for was reached, and must fire
    within WB_SLOT_TURN_BOUND + 1 acceptances of the first release. Without
    the rotation, the cache's tripwire stops the run once slot 1 has lost 32
    loads; STARVE_GIVE_UP_FILLS is the backstop. Every line then reads back
    through the drained hierarchy.
    """
    await _setup(dut)
    col = _Collector(dut, "up")
    model = ReferenceModel()
    cache = _bottom_cache(dut)
    has_l2 = int(dut.o_has_l2.value) != 0

    base = STARVE_BASE + 0x20000
    n_dirty = 16
    dirty = [base + i * LINE_BYTES for i in range(n_dirty)]  # L1 indices 0..15
    for i, d in enumerate(dirty):
        v = _line_int(bytes([(0x30 + 9 * i + b) & 0xFF for b in range(32)]))
        model.write_line(d, v, FULL)
        await _transaction(dut, "up", col, write=True, addr=d, wdata=v, wstrb=FULL)
        if has_l2:
            # Push the dirty line into the L2 with a read of its L1 alias.
            await _transaction(dut, "up", col, write=False, addr=d + 1024)
    await _settle(dut)
    # Same index as its line at the bottom cache (and at the L1D), new tag.
    aliases = [d + 4096 for d in dirty]

    await FallingEdge(dut.i_clk)
    dut.i_down_hold.value = 1
    mon = _WritebackPendingMonitor(dut, cache)
    assert mon.num_wb == 2, "WB_SLOT_TURN_BOUND assumes two writeback slots"
    port_lock = Lock()
    stop = [False]
    dirty_reader = cocotb.start_soon(
        _dirty_victim_reader(dut, col, model, cache, aliases, port_lock, (2, 6), stop)
    )
    for _ in range(RESP_TIMEOUT_CYCLES):
        await FallingEdge(dut.i_clk)
        if mon.all_pending():
            break
    else:
        raise AssertionError("the two evictions never left both slots pending")
    # Both slots hold a writeback and the register holds the first fill;
    # the fresh reads now keep a fill pending at every load.
    fresh = _FreshLines(base + 0x10000, skip=frozenset(range(n_dirty)))
    clean_readers = [
        cocotb.start_soon(
            _stream_reader(dut, col, model, fresh, port_lock, (r, r + 4), stop)
        )
        for r in range(2)
    ]
    await _settle(dut, STARVE_GRANT_SPACING)

    target = dirty[1]  # the second eviction's line: slot 1
    fires = 0
    other_wb_fires = 0
    target_fired = False
    while fires < STARVE_GIVE_UP_FILLS:
        fired, write, addr = await _release_downstream_once(dut)
        assert fired, "a released acceptance found no request presented"
        fires += 1
        if write and addr == target:
            target_fired = True
            break
        if write:
            other_wb_fires += 1
        await _settle(dut, STARVE_GRANT_SPACING)
    stop[0] = True
    await FallingEdge(dut.i_clk)
    dut.i_down_hold.value = 0
    dut._log.info(
        f"slot 1's writeback fired as acceptance {fires} after {other_wb_fires} "
        f"other writebacks (has_l2={has_l2})"
    )
    assert target_fired, f"slot 1's writeback still pending after {fires} acceptances"
    assert other_wb_fires >= 1, "slot 1 never lost a writeback load to slot 0"
    assert fires <= WB_SLOT_TURN_BOUND + 1, (
        f"slot 1's writeback fired only as acceptance {fires}; "
        f"the bound is {WB_SLOT_TURN_BOUND + 1}"
    )
    await dirty_reader
    for reader in clean_readers:
        await reader
    mon.stop()
    await _settle(dut)

    for d in dirty:
        assert await _transaction(
            dut, "up", col, write=False, addr=d
        ) == model.read_line(d)
    col.stop()


@cocotb.test()
async def test_l2_fill_tag_install_races_resident_lookup(dut: Any) -> None:
    """A tag lookup spanning a same-index fill install retries and then hits.

    Three reads of one cold line reach the shared level in a deterministic
    order: the walker, launched two cycles ahead because its read first
    probes the L1D (a miss there), allocates the line, one cached-side
    request takes the MSHR's single waiter, and the other must remain
    resident until the fill installs its tag.  With a multi-cycle L2 tag RAM,
    that last request can have an old tag response in flight across the MSHR
    tag write.  It must discard/re-read that response, not allocate a
    duplicate miss from the stale tag contents.

    The exact L2 observer partition pins the intended path independently of
    response latency: alloc + waiter are misses, and the resident retry is a
    hit.  The functional data checks also run in the L1-only configuration.
    """
    await _setup(dut)
    cols = {port: _Collector(dut, port) for port in ("up", "iup", "wup")}

    addr = TAG_INSTALL_BASE + 13 * LINE_BYTES
    data = _line_int(bytes([(0x39 + 5 * b) & 0xFF for b in range(LINE_BYTES)]))
    await _transaction(
        dut, "up", cols["up"], write=True, addr=addr, wdata=data, wstrb=FULL
    )

    # Publish the dirty L1D line, then read its exact L2 alias.  The alias is
    # also an L1D alias, so this one transaction evicts addr from both cached
    # levels and writes its distinctive data all the way to backing memory.
    await _fence_sync(dut)
    assert (
        await _transaction(dut, "up", cols["up"], write=False, addr=addr + L2_BYTES)
        == 0
    )
    await _settle(dut)

    counts = _new_perf_counts()
    stop = [False]
    monitor = cocotb.start_soon(_monitor_perf_events(dut, counts, stop))

    async def _read(port: str) -> tuple[int, int]:
        req_id = _ids.take(port)
        await _fire(dut, port, write=False, addr=addr, req_id=req_id)
        return await cols[port].wait_for(req_id)

    # Each _fire waits for its first falling edge before asserting valid, so
    # tasks started together make simultaneous upstream requests. The walker
    # goes first by two cycles: its probe then decides (a miss, the line is
    # cold everywhere) before the data-side read enters the L1D, so it does
    # not wait behind that read's fill, and all three meet at the shared
    # level in the order walker, L1I, L1D.
    walker = cocotb.start_soon(_read("wup"))
    for _ in range(2):
        await FallingEdge(dut.i_clk)
    tasks = [cocotb.start_soon(_read(port)) for port in ("up", "iup")] + [walker]
    for port, task in zip(("up", "iup", "wup"), tasks):
        _, got = await task
        assert got == data, f"{port} read mismatch: got 0x{got:064x}"

    # Cover the observers' source-register lag before freezing the totals.
    await _settle(dut, 8)
    stop[0] = True
    await FallingEdge(dut.i_clk)
    await monitor

    if int(dut.o_has_l2.value) != 0:
        assert counts["l2"]["access"] == 3
        assert counts["l2"]["miss"] == 2
        assert counts["l2"]["hit"] == 1
        assert counts["l2"]["writeback"] == 0
        assert counts["l2"]["hit"] + counts["l2"]["miss"] == counts["l2"]["access"]

    for col in cols.values():
        col.stop()


@cocotb.test()
async def test_stale_match_recycled_slot(dut: Any) -> None:
    """Reads racing re-manned MSHR slots keep their own lines' data.

    The A-stage comparators are captured before the T decision, and the
    captured match of a request that waits behind others once went stale
    when its slot retired and was re-manned for a different line: the read
    then attached as the new occupant's waiter and was served the other
    line's data. The organic trigger was a demand-paged kernel's page compare
    reading the neighbouring line's beat; p_secondary_targets_own_line pins
    that case in-system, and this traffic exercises it as well.

    Each round leaves slot 3 retired with its line register naming X (prime
    X through slot 3, evict X through slot 0), holds slots 0-2 busy with
    cold misses, re-mans slot 3 to Y, and fires the read of X k cycles
    behind Y, sweeping the offset. Every response must carry its own line's
    data through the recycling storm.
    """
    await _setup(dut)
    col = _Collector(dut, "up")
    model = ReferenceModel()
    alias = L1_LINES * LINE_BYTES  # same L1 index, next tag

    for k in range(14):
        base = STALE_BASE + k * 0x10000
        x = base  # index 0 of this region
        data = _line_int(bytes([(0xA0 + k + b * 3) & 0xFF for b in range(32)]))
        model.write_line(x, data, FULL)
        await _transaction(dut, "up", col, write=True, addr=x, wdata=data, wstrb=FULL)
        # Retire X out of the L1 so the slot-3 dance below misses on it.
        await _transaction(dut, "up", col, write=False, addr=x + alias)
        # Slots 0-2 busy on cold lines, then X misses into slot 3: its line
        # register now names X.
        hold = [_ids.take("up") for _ in range(3)]
        for n, req_id in enumerate(hold):
            await _fire(
                dut, "up", write=False, addr=base + (1 + n) * LINE_BYTES, req_id=req_id
            )
        await _transaction(dut, "up", col, write=False, addr=x)
        for req_id in hold:
            await col.wait_for(req_id)
        # Evict X again (slot 0 re-mans, slot 3 keeps naming X) and settle.
        await _transaction(dut, "up", col, write=False, addr=x + 2 * alias)
        await _settle(dut, 20)

        # The race: slots 0-2 busy again, Y re-mans slot 3, and the read of X
        # chases it k cycles behind.
        busy = [_ids.take("up") for _ in range(3)]
        for n, req_id in enumerate(busy):
            await _fire(
                dut, "up", write=False, addr=base + (4 + n) * LINE_BYTES, req_id=req_id
            )
        y_id = _ids.take("up")
        await _fire(dut, "up", write=False, addr=base + 7 * LINE_BYTES, req_id=y_id)
        for _ in range(k):
            await FallingEdge(dut.i_clk)
        x_id = _ids.take("up")
        await _fire(dut, "up", write=False, addr=x, req_id=x_id)
        for req_id in busy:
            await col.wait_for(req_id)
        await col.wait_for(y_id)
        _, got = await col.wait_for(x_id)
        assert got == data, f"k={k}: X returned 0x{got:064x}, expected 0x{data:064x}"
    col.stop()


@cocotb.test()
async def test_fence_with_pending_misses(dut: Any) -> None:
    """fence.i drains early-acknowledged write misses before the L1I can refetch."""
    await _setup(dut)
    col = _Collector(dut, "up")
    icol = _Collector(dut, "iup")
    model = ReferenceModel()
    lines = [FENCE_BASE + k * LINE_BYTES for k in range(4)]
    ids = []
    for k, addr in enumerate(lines):
        data = _line_int(bytes([(0x70 + k + b) & 0xFF for b in range(32)]))
        model.write_line(addr, data, 0x0F0F_0F0F)
        req_id = _ids.take("up")
        ids.append(req_id)
        await _fire(
            dut,
            "up",
            write=True,
            addr=addr,
            req_id=req_id,
            wdata=data,
            wstrb=0x0F0F_0F0F,
        )
    for req_id in ids:
        await col.wait_for(req_id)
    # The fills are still landing; the sync must wait for them and then push
    # every dirty line down.
    await _fence_sync(dut)
    for addr in lines:
        got = await _transaction(dut, "iup", icol, write=False, addr=addr)
        assert got == model.read_line(addr), f"iup stale @0x{addr:08x}"
    col.stop()
    icol.stop()


@cocotb.test()
async def test_random_outstanding_traffic(dut: Any) -> None:
    """Random bursts with several transactions in flight per port, same-line sequences included.

    Reads are checked against the model's state at the moment the read was
    issued (acceptance order per line), so a merge or waiter that exposed a
    later write, or a lost write, shows up as a mismatch.
    """
    await _setup(dut)
    rng = random.Random(random.getrandbits(32))
    cols = {"up": _Collector(dut, "up"), "iup": _Collector(dut, "iup")}
    dmodel = ReferenceModel()
    window_lines = 64  # 2 KiB: thrashes the 1 KiB L1D and lands in/out of L2
    bursts = 80

    async def _d_master() -> None:
        local = random.Random(rng.getrandbits(32))
        for _ in range(bursts):
            burst = local.randrange(1, NUM_IDS + 1)
            issued: list[tuple[int, int | None, int]] = []
            for _ in range(burst):
                line = local.randrange(window_lines)
                addr = RANDOM_BASE + line * LINE_BYTES
                req_id = _ids.take("up")
                if local.random() < 0.45:
                    wdata = local.getrandbits(256)
                    style = local.random()
                    wstrb = FULL if style < 0.4 else (local.getrandbits(32) or 1)
                    dmodel.write_line(addr, wdata, wstrb)
                    await _fire(
                        dut,
                        "up",
                        write=True,
                        addr=addr,
                        req_id=req_id,
                        wdata=wdata,
                        wstrb=wstrb,
                    )
                    issued.append((req_id, None, 0))
                else:
                    expected = dmodel.read_line(addr)
                    await _fire(dut, "up", write=False, addr=addr, req_id=req_id)
                    issued.append((req_id, addr, expected))
            for req_id, read_addr, expected in issued:
                _, got = await cols["up"].wait_for(req_id)
                if read_addr is not None:
                    assert got == expected, (
                        f"D read id {req_id} @0x{read_addr:08x}: "
                        f"got 0x{got:064x} expected 0x{expected:064x}"
                    )
            for _ in range(local.randrange(3)):
                await FallingEdge(dut.i_clk)

    async def _i_master() -> None:
        # The I side reads a region the D side never writes after the warm-up
        # below, so its values are stable.
        local = random.Random(rng.getrandbits(32))
        for _ in range(bursts):
            burst = local.randrange(1, NUM_IDS + 1)
            issued_i: list[tuple[int, int]] = []
            for _ in range(burst):
                line = local.randrange(16)
                addr = RANDOM_BASE + 0x20000 + line * LINE_BYTES
                req_id = _ids.take("iup")
                await _fire(dut, "iup", write=False, addr=addr, req_id=req_id)
                issued_i.append((req_id, addr))
            for req_id, addr in issued_i:
                _, got = await cols["iup"].wait_for(req_id)
                expected = imodel.read_line(addr)
                assert got == expected, f"I read @0x{addr:08x}: got 0x{got:064x}"

    # Warm the I region through the D port and push it down to the shared
    # level so the I side sees it.
    imodel = ReferenceModel()
    for line in range(16):
        addr = RANDOM_BASE + 0x20000 + line * LINE_BYTES
        data = _line_int(bytes([(line * 13 + b) & 0xFF for b in range(32)]))
        imodel.write_line(addr, data, FULL)
        await _transaction(
            dut, "up", cols["up"], write=True, addr=addr, wdata=data, wstrb=FULL
        )
    await _fence_sync(dut)

    tasks = [cocotb.start_soon(_d_master()), cocotb.start_soon(_i_master())]
    for task in tasks:
        await task
    # Final sweep of the D window.
    for line in range(window_lines):
        addr = RANDOM_BASE + line * LINE_BYTES
        got = await _transaction(dut, "up", cols["up"], write=False, addr=addr)
        assert got == dmodel.read_line(addr), f"final sweep mismatch @0x{addr:08x}"
    for col in cols.values():
        col.stop()
