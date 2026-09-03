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
pending, a delayed tag response racing a same-index fill install, a read
racing an MSHR slot re-manned for another line, fence.i with pending misses,
and random mixed traffic with same-line sequences checked against a reference
model in acceptance order.
"""

import random
from typing import Any

import cocotb
from cocotb.triggers import FallingEdge, ReadOnly

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
RESP_TIMEOUT_CYCLES = 5_000


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
        assert data == model.read_line(
            PIPE_BASE + line * LINE_BYTES
        ), f"line {line} mismatch"
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
    assert (
        hit_cycle < miss_cycle
    ), f"hit ({hit_cycle}) did not pass the miss ({miss_cycle})"
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
    assert (
        ack1 - start < MEM_LATENCY
    ), f"write miss ack waited for the fill ({ack1 - start})"
    assert (
        ack2 - start < MEM_LATENCY
    ), f"merged write ack waited for the fill ({ack2 - start})"
    assert got == model.read_line(
        addr
    ), "read did not see both merged writes over the fill"
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


@cocotb.test()
async def test_l2_fill_tag_install_races_resident_lookup(dut: Any) -> None:
    """A tag lookup spanning a same-index fill install retries and then hits.

    Three simultaneous reads of one cold line reach the shared level in a
    deterministic order: the walker bypasses the L1s and allocates the line,
    one cached-side request takes the MSHR's single waiter, and the other must
    remain resident until the fill installs its tag.  With a multi-cycle L2
    tag RAM, that last request can have an old tag response in flight across
    the MSHR tag write.  It must discard/re-read that response, not allocate a
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
    # starting all three now makes their upstream requests simultaneous.
    tasks = [cocotb.start_soon(_read(port)) for port in ("up", "iup", "wup")]
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
