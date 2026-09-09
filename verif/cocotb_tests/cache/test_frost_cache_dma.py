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

"""DMA coherence tests for the frost_cache hierarchy (frost_cache_test_harness).

Same harness as test_frost_cache, driving its fourth upstream port (dma) and
playing the load queue on the DMA sequencer's admit / inval / release
handshake. Checked: a DMA write becomes visible to the data side whether the
line was absent, clean or dirty in the L1D (partial DMA strobes preserve the
CPU's dirty neighbouring bytes); a DMA read returns the CPU's dirty data and
leaves the line valid and clean; a probe to a line whose fill is in flight
waits for the fill; a data-side miss issued while the sequencer holds the
line (long load-queue invalidation) is served with the post-write line rather
than resurrecting the pre-write one; same-line DMA requests serialize; the
load-queue handshake fires admit, inval and release once per DMA write and
never for a DMA read; a DMA write concurrent with fence.i's writeback-all; a
DMA request under a data-side miss flood still completes; concurrent DMA and
data-side traffic on disjoint lines stays exact; and a data-side reader of
lines a DMA agent is writing only ever sees values in coherence order (the
sequence it observes per line never goes backwards).
"""

import random
from typing import Any

import cocotb
from cocotb.triggers import FallingEdge, ReadOnly, Timer

from cocotb_tests.cache.test_frost_cache import (
    BASE_ADDR,
    LINE_BYTES,
    RESP_TIMEOUT_CYCLES,
    ReferenceModel,
    _check_read,
    _fence_sync,
    _line_int,
    _line_transaction,
    _port_transaction,
    _settle,
    _setup,
)
from cocotb_tests.cache.test_frost_cache_concurrency import _Collector, _fire

FULL = (1 << LINE_BYTES) - 1
# Per-test disjoint regions (the behavioral DDR persists across in-run resets).
ABSENT_BASE = BASE_ADDR + 0x700000
CLEAN_BASE = BASE_ADDR + 0x740000
DIRTY_BASE = BASE_ADDR + 0x780000
READ_BASE = BASE_ADDR + 0x7C0000
TRANSIT_BASE = BASE_ADDR + 0x800000
LOCK_BASE = BASE_ADDR + 0x840000
SERIAL_BASE = BASE_ADDR + 0x880000
FENCE_BASE = BASE_ADDR + 0x8C0000
FLOOD_BASE = BASE_ADDR + 0x900000
DISJOINT_BASE = BASE_ADDR + 0x940000
ORDER_BASE = BASE_ADDR + 0x980000
RANDOM_BASE = BASE_ADDR + 0x9C0000

L1_ALIAS = 1024  # harness L1 = 1 KiB: +1024 is the same index, another tag
MEM_LATENCY = 12  # harness default


class LoadQueueStub:
    """Plays the load queue on the sequencer's handshake.

    Admits every line (after admit_delay cycles), completes every
    invalidation (after inval_delay cycles), and records the events so a test
    can check the sequence per slot: admit, inval, release, in that order,
    exactly once per DMA write and never for a DMA read.
    """

    def __init__(self, dut: Any, *, admit_delay: int = 0, inval_delay: int = 0) -> None:
        """Start the stub; it drives i_coh_admit_ready and i_coh_inval_done."""
        self._dut = dut
        self.admit_delay = admit_delay
        self.inval_delay = inval_delay
        self.admits: list[tuple[int, int]] = []  # (slot, line-aligned address)
        self.invals: list[int] = []  # slot
        self.releases: list[int] = []  # slot
        self.open_slots: dict[int, int] = {}  # slot -> address, admitted not released
        self._task = cocotb.start_soon(self._run())

    async def _run(self) -> None:
        dut = self._dut
        dut.i_coh_admit_ready.value = 0
        dut.i_coh_inval_done.value = 0
        admit_wait = 0
        inval_wait = 0
        while True:
            await FallingEdge(dut.i_clk)
            # Both handshakes fire at the rising edge after ready/done is
            # raised; drop the strobe again so a following request of another
            # slot re-qualifies.
            dut.i_coh_admit_ready.value = 0
            dut.i_coh_inval_done.value = 0
            if int(dut.o_coh_release_valid.value) == 1:
                slot = int(dut.o_coh_release_slot.value)
                assert slot in self.open_slots, f"release of slot {slot} never admitted"
                assert slot in self.invals, f"release of slot {slot} before its inval"
                del self.open_slots[slot]
                self.releases.append(slot)
            await ReadOnly()
            admit_valid = int(dut.o_coh_admit_valid.value) == 1
            inval_valid = int(dut.o_coh_inval_valid.value) == 1
            admit_slot = int(dut.o_coh_admit_slot.value)
            admit_addr = int(dut.o_coh_admit_addr.value)
            inval_slot = int(dut.o_coh_inval_slot.value)
            await Timer(1, unit="ns")
            if admit_valid:
                if admit_wait >= self.admit_delay:
                    assert (
                        admit_slot not in self.open_slots
                    ), f"slot {admit_slot} admitted twice"
                    self.open_slots[admit_slot] = admit_addr
                    self.admits.append((admit_slot, admit_addr))
                    dut.i_coh_admit_ready.value = 1
                    admit_wait = 0
                else:
                    admit_wait += 1
            else:
                admit_wait = 0
            if inval_valid:
                if inval_wait >= self.inval_delay:
                    assert (
                        inval_slot in self.open_slots
                    ), f"inval of slot {inval_slot} never admitted"
                    self.invals.append(inval_slot)
                    dut.i_coh_inval_done.value = 1
                    inval_wait = 0
                else:
                    inval_wait += 1
            else:
                inval_wait = 0

    def stop(self) -> None:
        """Stop driving the handshake."""
        self._task.cancel()


async def _dma(
    dut: Any, *, write: bool, addr: int, wdata: int = 0, wstrb: int = 0
) -> int:
    """One DMA-port transaction to completion (see _port_transaction)."""
    return await _port_transaction(
        dut, "dma", write=write, addr=addr, wdata=wdata, wstrb=wstrb
    )


def _pattern(seed: int) -> int:
    return _line_int(bytes([(seed * 37 + b * 11) & 0xFF for b in range(LINE_BYTES)]))


async def _cpu_write(
    dut: Any, model: ReferenceModel, addr: int, wdata: int, wstrb: int
) -> None:
    model.write_line(addr, wdata, wstrb)
    await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=wstrb)


async def _dma_write(
    dut: Any, model: ReferenceModel, addr: int, wdata: int, wstrb: int
) -> None:
    model.write_line(addr, wdata, wstrb)
    await _dma(dut, write=True, addr=addr, wdata=wdata, wstrb=wstrb)


async def _check_dma_read(dut: Any, model: ReferenceModel, addr: int) -> None:
    got = await _dma(dut, write=False, addr=addr)
    expected = model.read_line(addr)
    assert (
        got == expected
    ), f"DMA read mismatch @0x{addr:08x}: got 0x{got:064x} expected 0x{expected:064x}"


def _l1d_tag_state(dut: Any, addr: int) -> tuple[bool, bool]:
    """Return (valid, dirty) of addr's L1D tag entry from the harness's tag RAM."""
    l1 = dut.cache_hierarchy.l1_cache
    index_bits = int(l1.IndexBits.value)
    tag_bits = int(l1.TagBits.value)
    index = (addr >> 5) & ((1 << index_bits) - 1)
    entry = int(l1.gen_tag_block.tag_array.ram[index].value)
    tag = entry & ((1 << tag_bits) - 1)
    dirty = (entry >> tag_bits) & 1
    valid = (entry >> (tag_bits + 1)) & 1
    expected_tag = addr >> (5 + index_bits)
    return (bool(valid) and tag == expected_tag, bool(valid) and bool(dirty))


@cocotb.test()
async def test_dma_write_to_absent_line(dut: Any) -> None:
    """A DMA write to a line the L1D does not hold is visible to a CPU read."""
    await _setup(dut)
    lq = LoadQueueStub(dut)
    model = ReferenceModel()
    addr = ABSENT_BASE + 3 * LINE_BYTES
    await _dma_write(dut, model, addr, _pattern(1), FULL)
    await _check_read(dut, model, addr)
    # A partial DMA write over the now-resident line: the CPU's copy is
    # invalidated and the merged line comes back from the shared level.
    await _dma_write(dut, model, addr, _pattern(2), 0x0000_FF00)
    await _check_read(dut, model, addr)
    assert (
        lq.admits
        and len(lq.admits) == 2
        and len(lq.invals) == 2
        and len(lq.releases) == 2
    )
    lq.stop()


@cocotb.test()
async def test_dma_write_invalidates_clean_copy(dut: Any) -> None:
    """A clean L1D copy is invalidated by the probe; the re-read fetches new data."""
    await _setup(dut)
    lq = LoadQueueStub(dut)
    model = ReferenceModel()
    addr = CLEAN_BASE + 7 * LINE_BYTES
    await _cpu_write(dut, model, addr, _pattern(3), FULL)
    await _fence_sync(dut)  # writeback-all leaves the line valid and clean
    assert _l1d_tag_state(dut, addr) == (True, False)
    await _dma_write(dut, model, addr, _pattern(4), FULL)
    assert _l1d_tag_state(dut, addr)[0] is False, "probe left a stale clean copy"
    await _check_read(dut, model, addr)
    lq.stop()


@cocotb.test()
async def test_dma_write_merges_with_dirty_copy(dut: Any) -> None:
    """A partial DMA write to a dirty L1D line keeps the CPU's other bytes.

    The probe writes the dirty line back and invalidates it, so the DMA
    strobes merge at the shared level; the CPU then re-reads the union.
    """
    await _setup(dut)
    lq = LoadQueueStub(dut)
    model = ReferenceModel()
    addr = DIRTY_BASE + 11 * LINE_BYTES
    await _cpu_write(dut, model, addr, _pattern(5), 0x00FF_00FF)
    await _settle(dut)  # a partial write miss is acknowledged before its fill installs
    assert _l1d_tag_state(dut, addr) == (True, True)
    await _dma_write(dut, model, addr, _pattern(6), 0x0F00_0F00)
    assert _l1d_tag_state(dut, addr)[0] is False
    await _check_read(dut, model, addr)
    await _check_dma_read(dut, model, addr)
    # Dirty again, then a whole-line DMA write, then both readers.
    await _cpu_write(dut, model, addr, _pattern(7), 0xF000_0000)
    await _dma_write(dut, model, addr, _pattern(8), FULL)
    await _check_dma_read(dut, model, addr)
    await _check_read(dut, model, addr)
    lq.stop()


@cocotb.test()
async def test_dma_read_sees_dirty_cpu_data(dut: Any) -> None:
    """A DMA read of a dirty line gets the CPU's data; the copy stays valid, clean."""
    await _setup(dut)
    lq = LoadQueueStub(dut)
    model = ReferenceModel()
    addr = READ_BASE + 5 * LINE_BYTES
    await _cpu_write(dut, model, addr, _pattern(9), FULL)
    await _cpu_write(dut, model, addr, _pattern(10), 0x0000_00F0)
    assert _l1d_tag_state(dut, addr) == (True, True)
    await _check_dma_read(dut, model, addr)
    assert _l1d_tag_state(dut, addr) == (
        True,
        False,
    ), "PROBE_CLEAN must leave a clean copy"
    await _check_read(dut, model, addr)  # still a hit
    await _check_dma_read(dut, model, addr)  # clean hit: no writeback needed
    assert (
        lq.admits == [] and lq.invals == [] and lq.releases == []
    ), "a DMA read must not touch the load-queue handshake"
    lq.stop()


@cocotb.test()
async def test_probe_waits_for_fill_in_flight(dut: Any) -> None:
    """A DMA write to a line whose CPU fill is in flight orders after the fill.

    The CPU read was accepted first, so it returns the pre-write line; the
    probe waits for the fill to install, then invalidates it; the next CPU
    read returns the post-write line.
    """
    await _setup(dut)
    lq = LoadQueueStub(dut)
    model = ReferenceModel()
    addr = TRANSIT_BASE + 2 * LINE_BYTES
    old = _pattern(11)
    await _dma_write(dut, model, addr, old, FULL)
    await _fence_sync(dut)
    # Evict the line from the L1D through an alias so the next read misses.
    await _cpu_write(dut, model, addr + L1_ALIAS, _pattern(12), FULL)
    await _settle(dut)
    read_task = cocotb.start_soon(_line_transaction(dut, write=False, addr=addr))
    for _ in range(2):
        await FallingEdge(dut.i_clk)
    new = _pattern(13)
    write_task = cocotb.start_soon(
        _dma(dut, write=True, addr=addr, wdata=new, wstrb=FULL)
    )
    first = await read_task
    await write_task
    model.write_line(addr, new, FULL)
    assert first == old, "a read accepted before the DMA write must see the old line"
    await _check_read(dut, model, addr)
    lq.stop()


@cocotb.test()
async def test_lock_serves_post_write_line_to_racing_miss(dut: Any) -> None:
    """The resurrection race: a miss issued during the lock waits for the write.

    The load queue is slow to complete the invalidation, so the window
    between the L1D invalidation and the write's acceptance is long. A CPU
    read issued inside it misses (the probe invalidated the copy) and its
    fill is withheld by the L1D until the sequencer releases the probe after
    the DMA write has been ordered, so it returns the post-write line, and
    the L1D ends up holding that line rather than the pre-write one.
    """
    await _setup(dut)
    lq = LoadQueueStub(dut, inval_delay=60)
    model = ReferenceModel()
    addr = LOCK_BASE + 9 * LINE_BYTES
    old = _pattern(14)
    await _cpu_write(dut, model, addr, old, FULL)
    await _fence_sync(dut)  # resident, clean
    new = _pattern(15)
    write_task = cocotb.start_soon(
        _dma(dut, write=True, addr=addr, wdata=new, wstrb=FULL)
    )
    # Wait until the probe has invalidated the copy, then issue the racing read.
    for _ in range(RESP_TIMEOUT_CYCLES):
        await FallingEdge(dut.i_clk)
        if _l1d_tag_state(dut, addr)[0] is False:
            break
    else:
        raise AssertionError("probe never invalidated the resident copy")
    blocked_seen = False
    read_task = cocotb.start_soon(_line_transaction(dut, write=False, addr=addr))
    for _ in range(RESP_TIMEOUT_CYCLES):
        await FallingEdge(dut.i_clk)
        if int(dut.cache_hierarchy.l1_cache.mshr_fill_held.value) != 0:
            blocked_seen = True
        if read_task.done():
            break
    data = read_task.result()
    await write_task
    model.write_line(addr, new, FULL)
    assert blocked_seen, "the racing fill was never held by the lock"
    assert data == new, "a fill held by the lock must return the post-write line"
    assert _l1d_tag_state(dut, addr) == (True, False)
    await _check_read(dut, model, addr)
    lq.stop()


@cocotb.test()
async def test_same_line_dma_requests_serialize(dut: Any) -> None:
    """Back-to-back DMA writes to one line take effect in acceptance order.

    The requests are fired without waiting for responses (each with its own
    id); the sequencer accepts a same-line request only once the previous one
    has retired, so the merged line is the writes applied in issue order.
    """
    await _setup(dut)
    lq = LoadQueueStub(dut, admit_delay=3, inval_delay=5)
    model = ReferenceModel()
    col = _Collector(dut, "dma")
    addr = SERIAL_BASE + 4 * LINE_BYTES
    for i in range(6):
        wdata = _pattern(20 + i)
        wstrb = FULL if i % 3 == 0 else (0xFF << (8 * (i % 4)))
        model.write_line(addr, wdata, wstrb)
        await _fire(
            dut, "dma", write=True, addr=addr, req_id=i, wdata=wdata, wstrb=wstrb
        )
    for i in range(6):
        await col.wait_for(i)
    col.stop()
    await _check_dma_read(dut, model, addr)
    await _check_read(dut, model, addr)
    assert len(lq.releases) == 6
    lq.stop()


@cocotb.test()
async def test_dma_write_during_fence_writeback_all(dut: Any) -> None:
    """A DMA write racing fence.i's writeback-all completes with correct data."""
    await _setup(dut)
    lq = LoadQueueStub(dut)
    model = ReferenceModel()
    lines = [FENCE_BASE + i * LINE_BYTES for i in range(12)]
    for i, addr in enumerate(lines):
        await _cpu_write(dut, model, addr, _pattern(40 + i), FULL)
    target = lines[5]
    fence_task = cocotb.start_soon(_fence_sync(dut))
    new = _pattern(60)
    write_task = cocotb.start_soon(
        _dma(dut, write=True, addr=target, wdata=new, wstrb=0x00FF_FF00)
    )
    await fence_task
    await write_task
    model.write_line(target, new, 0x00FF_FF00)
    for addr in lines:
        await _check_read(dut, model, addr)
    await _check_dma_read(dut, model, target)
    lq.stop()


@cocotb.test()
async def test_dma_completes_under_cpu_miss_flood(dut: Any) -> None:
    """A DMA request under a data-side miss stream completes within a bound."""
    await _setup(dut)
    lq = LoadQueueStub(dut)
    model = ReferenceModel()
    stop = [False]

    async def flood() -> None:
        # Thrash one index with many tags: every access is a miss with a
        # dirty victim, the busiest the L1D's downstream port gets.
        n = 0
        while not stop[0]:
            addr = FLOOD_BASE + (n % 16) * L1_ALIAS
            await _line_transaction(
                dut, write=True, addr=addr, wdata=_pattern(n), wstrb=FULL
            )
            n += 1

    flood_task = cocotb.start_soon(flood())
    for _ in range(40):
        await FallingEdge(dut.i_clk)
    target = FLOOD_BASE + 0x8000
    start = 0
    for _ in range(8):
        wdata = _pattern(80 + start)
        model.write_line(target, wdata, FULL)
        await _dma(dut, write=True, addr=target, wdata=wdata, wstrb=FULL)
        await _check_dma_read(dut, model, target)
        start += 1
    stop[0] = True
    await flood_task
    await _check_read(dut, model, target)
    lq.stop()


@cocotb.test()
async def test_concurrent_disjoint_traffic(dut: Any) -> None:
    """CPU and DMA traffic on disjoint line sets, each exact against its model."""
    await _setup(dut)
    lq = LoadQueueStub(dut, admit_delay=1, inval_delay=2)
    rng = random.Random(0xD3A1)

    async def cpu_side(base: int, seed: int, count: int) -> None:
        model = ReferenceModel()
        r = random.Random(seed)
        for _ in range(count):
            addr = base + r.randrange(64) * LINE_BYTES
            if r.random() < 0.6:
                wdata = r.getrandbits(256)
                wstrb = FULL if r.random() < 0.5 else (0xF << (4 * r.randrange(8)))
                await _cpu_write(dut, model, addr, wdata, wstrb)
            else:
                await _check_read(dut, model, addr)

    async def dma_side(base: int, seed: int, count: int) -> None:
        model = ReferenceModel()
        r = random.Random(seed)
        for _ in range(count):
            addr = base + r.randrange(64) * LINE_BYTES
            if r.random() < 0.6:
                wdata = r.getrandbits(256)
                wstrb = FULL if r.random() < 0.5 else r.getrandbits(32) or 1
                await _dma_write(dut, model, addr, wdata, wstrb)
            else:
                await _check_dma_read(dut, model, addr)

    tasks = [
        cocotb.start_soon(cpu_side(DISJOINT_BASE, rng.getrandbits(32), 150)),
        cocotb.start_soon(dma_side(DISJOINT_BASE + 0x10000, rng.getrandbits(32), 150)),
    ]
    for task in tasks:
        await task
    lq.stop()


@cocotb.test()
async def test_cpu_reads_dma_writes_in_coherence_order(dut: Any) -> None:
    """A CPU reader of DMA-written lines never sees a value go backwards.

    The DMA side writes an increasing sequence number into each line; the CPU
    side reads the lines concurrently, in any interleaving. Per line the
    sequence the CPU observes must be non-decreasing and never exceed the
    latest write the DMA side has issued.
    """
    await _setup(dut)
    lq = LoadQueueStub(dut, inval_delay=3)
    lines = [ORDER_BASE + i * LINE_BYTES for i in range(4)]
    issued = {addr: 0 for addr in lines}
    done = [False]

    async def dma_writer() -> None:
        r = random.Random(0xC0FFEE)
        for n in range(1, 61):
            addr = lines[r.randrange(len(lines))]
            issued[addr] = n
            await _dma(dut, write=True, addr=addr, wdata=n, wstrb=FULL)
        done[0] = True

    async def cpu_reader() -> None:
        r = random.Random(0xBEEF)
        last = {addr: 0 for addr in lines}
        while not done[0]:
            addr = lines[r.randrange(len(lines))]
            before = issued[addr]
            seen = await _line_transaction(dut, write=False, addr=addr) & 0xFFFF_FFFF
            assert (
                seen >= last[addr]
            ), f"line 0x{addr:08x}: saw sequence {seen} after {last[addr]}"
            assert (
                seen <= issued[addr]
            ), f"line 0x{addr:08x}: saw sequence {seen} before it was issued"
            # A value that was never written to this line is impossible: the
            # writer's own model is the sequence of values issued to addr.
            del before
            last[addr] = seen

    writer = cocotb.start_soon(dma_writer())
    reader = cocotb.start_soon(cpu_reader())
    await writer
    await reader
    lq.stop()


@cocotb.test()
async def test_random_mixed_traffic_vs_model(dut: Any) -> None:
    """Sequential random CPU / DMA / walker / instruction traffic vs the model."""
    await _setup(dut)
    lq = LoadQueueStub(dut, admit_delay=1, inval_delay=1)
    model = ReferenceModel()
    rng = random.Random(random.getrandbits(32))
    for _ in range(900):
        addr = RANDOM_BASE + rng.randrange(256) * LINE_BYTES
        pick = rng.random()
        if pick < 0.3:
            wdata = rng.getrandbits(256)
            wstrb = FULL if rng.random() < 0.4 else (0xF << (4 * rng.randrange(8)))
            await _cpu_write(dut, model, addr, wdata, wstrb)
        elif pick < 0.5:
            await _check_read(dut, model, addr)
        elif pick < 0.75:
            wdata = rng.getrandbits(256)
            wstrb = FULL if rng.random() < 0.4 else (rng.getrandbits(32) or 1)
            await _dma_write(dut, model, addr, wdata, wstrb)
        elif pick < 0.9:
            await _check_dma_read(dut, model, addr)
        else:
            # Walker reads go through the shared level: they see CPU data
            # only after a writeback, which fence.i forces.
            await _fence_sync(dut)
            got = await _port_transaction(dut, "wup", write=False, addr=addr)
            assert got == model.read_line(addr), f"walker read mismatch @0x{addr:08x}"
    lq.stop()
