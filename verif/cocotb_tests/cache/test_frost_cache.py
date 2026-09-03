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

"""Unit tests for the frost_cache hierarchy (frost_cache_test_harness DUT).

The harness wires the same backside topology the CPU integration uses:
frost_cache_hierarchy (L1s + walker port, optional L2) ->
line_port_axi_bridge -> axi_behavioral_memory. The bench drives raw tagged
line-port transactions on all three upstream ports (up = D-side, iup =
I-side, wup = page-table walker) and checks every read against a
byte-granular reference model and every response id against the request that
carried it. The harness defaults make the caches tiny (L1 1 KiB / L2 4 KiB)
so evictions and thrash are constantly exercised; the registry runs the same
tests in both board shapes via -GHAS_L2={0,1} and with the memory model
completing ids out of order via -GMEM_REORDER=1.
"""

import itertools

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

CLOCK_PERIOD_NS = 10
LINE_BYTES = 32
BASE_ADDR = 0x8000_0000

# Address window for the randomized tests: 1024 lines = 32 KiB, comfortably
# larger than L1 (1 KiB) and L2 (4 KiB) so both levels evict constantly.
WINDOW_LINES = 1024

# Each test gets a disjoint 256 KiB region: the behavioral DDR persists across
# the in-run resets between cocotb tests (like real DDR), so a fresh
# zero-default reference model is only valid in untouched address space.
SMOKE_BASE = BASE_ADDR + 0x00000
PARTIAL_BASE = BASE_ADDR + 0x40000
EVICT_BASE = BASE_ADDR + 0x80000
STROBE_BASE = BASE_ADDR + 0xC0000
THRASH_BASE = BASE_ADDR + 0x100000
RANDOM_BASE = BASE_ADDR + 0x140000
IFETCH_BASE = BASE_ADDR + 0x180000
ISTALE_BASE = BASE_ADDR + 0x1C0000
MIXED_BASE = BASE_ADDR + 0x200000
FENCE_BASE = BASE_ADDR + 0x240000
FENCE2_BASE = BASE_ADDR + 0x280000
PERF_BASE = BASE_ADDR + 0x2C0000
OVERLAP_BASE = BASE_ADDR + 0x300000
WALK_BASE = BASE_ADDR + 0x340000
WALK2_BASE = BASE_ADDR + 0x380000
WALK3_BASE = BASE_ADDR + 0x3C0000

RESP_TIMEOUT_CYCLES = 20_000
# Harness default MEM_LATENCY; the overlap test bounds response spread by it.
MEM_LATENCY_CYCLES = 12
SWEEP_TIMEOUT_CYCLES = 200_000

# The harness's up/iup ports carry UP_ID_BITS=3 ids and the walker port
# UP_ID_BITS-1 (its slot under the id tree's 2-bit prefix); each port's
# driver cycles through its id space so consecutive transactions never
# share one.
UP_ID_BITS = 3
_port_ids = {
    "up": itertools.cycle(range(1 << UP_ID_BITS)),
    "iup": itertools.cycle(range(1 << UP_ID_BITS)),
    "wup": itertools.cycle(range(1 << (UP_ID_BITS - 1))),
}

# Packed cache_instance_perf_events_t layout, MSB first: access, hit, miss,
# writeback (1 bit each), the MissOutstandingBits-wide outstanding count, then
# hit_under_miss, slot_full_stall, conflict_stall (1 bit each).
PERF_FIELDS = (
    "access",
    "hit",
    "miss",
    "writeback",
    "miss_outstanding",
    "hit_under_miss",
    "slot_full_stall",
    "conflict_stall",
)
PERF_FIELD_WIDTHS = {
    "access": 1,
    "hit": 1,
    "miss": 1,
    "writeback": 1,
    "miss_outstanding": 4,
    "hit_under_miss": 1,
    "slot_full_stall": 1,
    "conflict_stall": 1,
}
PERF_INSTANCE_WIDTH = sum(PERF_FIELD_WIDTHS.values())
PERF_INSTANCE_SHIFTS = {
    "l1i": 2 * PERF_INSTANCE_WIDTH,
    "l1d": PERF_INSTANCE_WIDTH,
    "l2": 0,
}


def _clear_inputs(dut: Any) -> None:
    dut.i_up_req_valid.value = 0
    dut.i_up_req_write.value = 0
    dut.i_up_req_addr.value = 0
    dut.i_up_req_wdata.value = 0
    dut.i_up_req_wstrb.value = 0
    dut.i_up_req_id.value = 0
    dut.i_iup_req_valid.value = 0
    dut.i_iup_req_write.value = 0
    dut.i_iup_req_addr.value = 0
    dut.i_iup_req_wdata.value = 0
    dut.i_iup_req_wstrb.value = 0
    dut.i_iup_req_id.value = 0
    dut.i_wup_req_valid.value = 0
    dut.i_wup_req_write.value = 0
    dut.i_wup_req_addr.value = 0
    dut.i_wup_req_wdata.value = 0
    dut.i_wup_req_wstrb.value = 0
    dut.i_wup_req_id.value = 0
    dut.i_fence_sync.value = 0


async def _setup(dut: Any) -> None:
    """Start the clock, reset, and wait out the tag-invalidate sweep."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    dut.i_rst.value = 1
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    for _ in range(SWEEP_TIMEOUT_CYCLES):
        await FallingEdge(dut.i_clk)
        if (
            int(dut.o_up_req_ready.value) == 1
            and int(dut.o_iup_req_ready.value) == 1
            and int(dut.o_wup_req_ready.value) == 1
        ):
            return
    raise AssertionError("cache never became ready after reset (sweep stuck?)")


async def _port_transaction(
    dut: Any, port: str, *, write: bool, addr: int, wdata: int = 0, wstrb: int = 0
) -> int:
    """Run one tagged line transaction on one of the three upstream ports.

    Ports: "up" = D-side, "iup" = I-side, "wup" = page-table walker.

    Returns the 256-bit read data (0 for writes). Inputs are driven at
    falling edges so they are stable across the rising edge that samples
    them; ready / resp_valid are likewise sampled mid-cycle at falling edges.
    The request carries the port's next id and the response must echo it.
    """
    req_valid = getattr(dut, f"i_{port}_req_valid")
    req_ready = getattr(dut, f"o_{port}_req_ready")
    resp_valid = getattr(dut, f"o_{port}_resp_valid")
    resp_rdata = getattr(dut, f"o_{port}_resp_rdata")
    resp_id = getattr(dut, f"o_{port}_resp_id")
    req_id = next(_port_ids[port])

    await FallingEdge(dut.i_clk)
    req_valid.value = 1
    getattr(dut, f"i_{port}_req_write").value = 1 if write else 0
    getattr(dut, f"i_{port}_req_addr").value = addr
    getattr(dut, f"i_{port}_req_wdata").value = wdata
    getattr(dut, f"i_{port}_req_wstrb").value = wstrb
    getattr(dut, f"i_{port}_req_id").value = req_id
    # Let the deposit propagate before the first ready sample. The walker
    # port's ready is request-dependent: the comb arbiter tree presents the
    # winning payload to the bridge, whose ready depends on the presented
    # request, so raising valid can itself raise ready mid-cycle. Sampling
    # the pre-deposit value would miss the fire at the next rising edge and
    # leave valid high, which is a same-id double request.
    await Timer(1, unit="ns")

    # Hold valid until a cycle where ready is high: that rising edge fires.
    for cycle in range(RESP_TIMEOUT_CYCLES):
        if int(req_ready.value) == 1:
            break
        await FallingEdge(dut.i_clk)
    else:
        raise AssertionError(f"{port} request never accepted (addr=0x{addr:08x})")

    await FallingEdge(dut.i_clk)  # now in the cycle after the fire
    req_valid.value = 0

    for cycle in range(RESP_TIMEOUT_CYCLES):
        if int(resp_valid.value) == 1:
            got_id = int(resp_id.value)
            assert (
                got_id == req_id
            ), f"{port} response id {got_id} != request id {req_id} (addr=0x{addr:08x})"
            return int(resp_rdata.value)
        await FallingEdge(dut.i_clk)
    raise AssertionError(f"no {port} response (addr=0x{addr:08x}, write={write})")


async def _line_transaction(
    dut: Any, *, write: bool, addr: int, wdata: int = 0, wstrb: int = 0
) -> int:
    """Run one D-side line transaction (see _port_transaction)."""
    return await _port_transaction(
        dut, "up", write=write, addr=addr, wdata=wdata, wstrb=wstrb
    )


class ReferenceModel:
    """Byte-granular reference: backing memory defaults to zero."""

    def __init__(self) -> None:
        """Start with an empty (all-zero) backing store."""
        self._bytes: dict[int, int] = {}

    def write_line(self, addr: int, wdata: int, wstrb: int) -> None:
        """Apply a strobed 32-byte line write at addr."""
        for b in range(LINE_BYTES):
            if (wstrb >> b) & 1:
                self._bytes[addr + b] = (wdata >> (8 * b)) & 0xFF

    def read_line(self, addr: int) -> int:
        """Return the 32-byte line at addr as a little-endian integer."""
        value = 0
        for b in range(LINE_BYTES):
            value |= self._bytes.get(addr + b, 0) << (8 * b)
        return value


def _line_int(data: bytes) -> int:
    return int.from_bytes(data, "little")


def _new_perf_counts() -> dict[str, dict[str, int]]:
    """Create zeroed per-instance event/cycle totals."""
    return {
        level: {field: 0 for field in PERF_FIELDS} for level in PERF_INSTANCE_SHIFTS
    }


def _sample_perf_events(dut: Any, counts: dict[str, dict[str, int]]) -> None:
    """Accumulate one cycle of the packed hierarchy event bundle.

    Pulse fields add 0/1; the outstanding-miss count adds its value, so the
    total is the miss-cycle integral the aggregator's *_MISS_CYCLES_SUM keeps.
    """
    raw = int(dut.o_perf_events.value)
    for level, instance_shift in PERF_INSTANCE_SHIFTS.items():
        field_shift = PERF_INSTANCE_WIDTH
        for field in PERF_FIELDS:
            width = PERF_FIELD_WIDTHS[field]
            field_shift -= width
            counts[level][field] += (raw >> (instance_shift + field_shift)) & (
                (1 << width) - 1
            )


async def _monitor_perf_events(
    dut: Any, counts: dict[str, dict[str, int]], stop: list[bool]
) -> None:
    """Sample registered cache events once per cycle until requested to stop."""
    while True:
        await FallingEdge(dut.i_clk)
        if stop[0]:
            return
        _sample_perf_events(dut, counts)


def _copy_perf_counts(
    counts: dict[str, dict[str, int]],
) -> dict[str, dict[str, int]]:
    """Take a value copy of monitor totals."""
    return {level: dict(values) for level, values in counts.items()}


async def _check_read(dut: Any, model: ReferenceModel, addr: int) -> None:
    got = await _line_transaction(dut, write=False, addr=addr)
    expected = model.read_line(addr)
    assert (
        got == expected
    ), f"read mismatch @0x{addr:08x}: got 0x{got:064x} expected 0x{expected:064x}"


@cocotb.test()
async def test_smoke_write_read(dut: Any) -> None:
    """Whole-line write then read back (allocate-without-fetch + read hit)."""
    await _setup(dut)
    model = ReferenceModel()
    addr = SMOKE_BASE + 0x40
    wdata = _line_int(bytes(range(32)))
    model.write_line(addr, wdata, (1 << LINE_BYTES) - 1)
    await _line_transaction(
        dut, write=True, addr=addr, wdata=wdata, wstrb=(1 << LINE_BYTES) - 1
    )
    await _check_read(dut, model, addr)


@cocotb.test()
async def test_partial_write_merges_on_miss(dut: Any) -> None:
    """A sparse-strobe write miss must fetch and merge (unwritten bytes = 0)."""
    await _setup(dut)
    model = ReferenceModel()
    addr = PARTIAL_BASE + 5 * LINE_BYTES
    wdata = _line_int(bytes([0xAB] * 32))
    wstrb = 0x0000_F00F  # bytes 0-3 and 12-15
    model.write_line(addr, wdata, wstrb)
    await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=wstrb)
    await _check_read(dut, model, addr)


@cocotb.test()
async def test_dirty_eviction_roundtrip(dut: Any) -> None:
    """Two lines aliasing the same L1 index: dirty victim must survive."""
    await _setup(dut)
    model = ReferenceModel()
    full = (1 << LINE_BYTES) - 1
    # 1 KiB L1 = 32 lines; stride by L1 size to alias index 3 with many tags.
    addrs = [EVICT_BASE + 3 * LINE_BYTES + tag * 1024 for tag in range(12)]
    for i, addr in enumerate(addrs):
        wdata = _line_int(bytes([(i * 7 + b) & 0xFF for b in range(32)]))
        model.write_line(addr, wdata, full)
        await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=full)
    for addr in addrs:
        await _check_read(dut, model, addr)


@cocotb.test()
async def test_word_strobe_writes(dut: Any) -> None:
    """4-byte strobe groups in every lane (the adapter's store pattern)."""
    await _setup(dut)
    model = ReferenceModel()
    addr = STROBE_BASE + 64 * LINE_BYTES
    for lane in range(8):
        word = 0x1111_0000 * 0 + (0xC0DE_0000 | lane)
        wdata = word << (32 * lane)
        wstrb = 0xF << (4 * lane)
        model.write_line(addr, wdata, wstrb)
        await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=wstrb)
    await _check_read(dut, model, addr)


@cocotb.test()
async def test_random_traffic_vs_model(dut: Any) -> None:
    """Randomized reads/writes over a window far larger than both caches."""
    await _setup(dut)
    model = ReferenceModel()
    rng = random.Random(random.getrandbits(32))
    full = (1 << LINE_BYTES) - 1

    for _ in range(1200):
        line = rng.randrange(WINDOW_LINES)
        addr = RANDOM_BASE + line * LINE_BYTES
        if rng.random() < 0.55:
            wdata = rng.getrandbits(256)
            style = rng.random()
            if style < 0.4:
                wstrb = full  # whole line (eviction-shaped)
            elif style < 0.8:
                wstrb = 0xF << (4 * rng.randrange(8))  # one word (CPU store shape)
            else:
                wstrb = rng.getrandbits(32)  # arbitrary sparse bytes
                if wstrb == 0:
                    wstrb = 1
            model.write_line(addr, wdata, wstrb)
            await _line_transaction(
                dut, write=True, addr=addr, wdata=wdata, wstrb=wstrb
            )
        else:
            await _check_read(dut, model, addr)

    # Final sweep: every line the model knows about must read back exactly.
    for line in range(0, WINDOW_LINES, 7):
        await _check_read(dut, model, RANDOM_BASE + line * LINE_BYTES)


@cocotb.test()
async def test_thrash_same_index(dut: Any) -> None:
    """Alternating tags on one index: continuous evict/fill at both levels."""
    await _setup(dut)
    model = ReferenceModel()
    full = (1 << LINE_BYTES) - 1
    index_addr = THRASH_BASE + 9 * LINE_BYTES
    tags = [index_addr + t * 1024 for t in range(6)]
    for rep in range(8):
        for t, addr in enumerate(tags):
            wdata = _line_int(bytes([(rep * 31 + t * 5 + b) & 0xFF for b in range(32)]))
            model.write_line(addr, wdata, full)
            await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=full)
        for addr in tags:
            await _check_read(dut, model, addr)


async def _settle(dut: Any, cycles: int = 80) -> None:
    """Let deferred work (writeback slots, fills) drain through the hierarchy."""
    for _ in range(cycles):
        await FallingEdge(dut.i_clk)


async def _force_l1d_writeback(dut: Any, model: ReferenceModel, addr: int) -> None:
    """Evict addr's L1 line so its dirty data reaches the shared level.

    A write to an aliasing tag (same index) forces the writeback that makes
    the data visible to L1I fills. The write is acknowledged before the
    writeback slot drains, so wait for it to reach the shared level.
    """
    alias = addr + 1024  # L1 is 1 KiB in the harness: same index, new tag
    full = (1 << LINE_BYTES) - 1
    wdata = _line_int(bytes([0xE5] * 32))
    model.write_line(alias, wdata, full)
    await _line_transaction(dut, write=True, addr=alias, wdata=wdata, wstrb=full)
    await _settle(dut)


@cocotb.test()
async def test_iport_reads_written_back_data(dut: Any) -> None:
    """The I-side reads D-side data once it reaches the shared level."""
    await _setup(dut)
    model = ReferenceModel()
    full = (1 << LINE_BYTES) - 1
    addr = IFETCH_BASE + 5 * LINE_BYTES
    wdata = _line_int(bytes([(0x42 + b) & 0xFF for b in range(32)]))
    model.write_line(addr, wdata, full)
    await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=full)
    await _force_l1d_writeback(dut, model, addr)

    got = await _port_transaction(dut, "iup", write=False, addr=addr)
    assert got == model.read_line(addr), f"iup read mismatch @0x{addr:08x}"

    # Second read returns identical data (now an L1I hit).
    got2 = await _port_transaction(dut, "iup", write=False, addr=addr)
    assert got2 == got


@cocotb.test()
async def test_iport_does_not_snoop_l1d_dirty(dut: Any) -> None:
    """v1 semantics: L1D-dirty data is invisible to the I-side.

    The I-side fills from the shared level below the arbiter; fence.i exists
    to force dirty data down before refetching.
    """
    await _setup(dut)
    addr = ISTALE_BASE + 9 * LINE_BYTES
    full = (1 << LINE_BYTES) - 1
    wdata = _line_int(bytes([0xAA] * 32))
    await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=full)

    # The line is dirty in L1D and has never been written back: the I-side
    # fill comes from the shared level, which still holds zeros.
    got = await _port_transaction(dut, "iup", write=False, addr=addr)
    assert got == 0, f"iup unexpectedly observed dirty L1D data @0x{addr:08x}"


@cocotb.test()
async def test_mixed_id_traffic(dut: Any) -> None:
    """Concurrent D-side write/read traffic and I-side reads stay isolated."""
    await _setup(dut)
    model = ReferenceModel()
    full = (1 << LINE_BYTES) - 1
    rng = random.Random(random.getrandbits(32))

    # Phase 1: D-side writes the I-region with known patterns, then thrashes
    # an aliasing region twice the L1 size so every I-region line is written
    # back to the shared level.
    icode_lines = 16
    for line in range(icode_lines):
        addr = MIXED_BASE + line * LINE_BYTES
        wdata = _line_int(bytes([(line * 11 + b) & 0xFF for b in range(32)]))
        model.write_line(addr, wdata, full)
        await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=full)
    for line in range(64):  # 2 KiB worth of aliases (L1 = 1 KiB)
        addr = MIXED_BASE + 0x10000 + line * LINE_BYTES
        wdata = _line_int(bytes([(0x77 + line + b) & 0xFF for b in range(32)]))
        model.write_line(addr, wdata, full)
        await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=full)

    # Phase 2: hammer both ports concurrently.
    async def _d_master() -> None:
        for _ in range(120):
            line = rng.randrange(64)
            addr = MIXED_BASE + 0x10000 + line * LINE_BYTES
            if rng.random() < 0.5:
                wdata = rng.getrandbits(256)
                model.write_line(addr, wdata, full)
                await _line_transaction(
                    dut, write=True, addr=addr, wdata=wdata, wstrb=full
                )
            else:
                got = await _line_transaction(dut, write=False, addr=addr)
                assert got == model.read_line(addr)

    async def _i_master() -> None:
        for _ in range(120):
            line = rng.randrange(icode_lines)
            addr = MIXED_BASE + line * LINE_BYTES
            got = await _port_transaction(dut, "iup", write=False, addr=addr)
            assert got == model.read_line(addr), f"iup mismatch @0x{addr:08x}"

    tasks = [cocotb.start_soon(_d_master()), cocotb.start_soon(_i_master())]
    for task in tasks:
        await task


@cocotb.test()
async def test_ports_overlap_below_arbiter(dut: Any) -> None:
    """Simultaneous D and I misses both fire downstream without a grant lock.

    One request from each L1 reaches the tagged arbiter, which lets both reach
    the bridge back to back. In the L1-only shape the two DDR reads therefore
    overlap and the responses land within one memory latency of each other;
    the L2 shape spaces their launches through its serialized tag front-end,
    so there only the data and id routing are checked.
    """
    await _setup(dut)
    model = ReferenceModel()
    full = (1 << LINE_BYTES) - 1
    d_addr = OVERLAP_BASE + 3 * LINE_BYTES
    i_addr = OVERLAP_BASE + 9 * LINE_BYTES
    d_data = _line_int(bytes([0xD0 + b for b in range(32)]))
    i_data = _line_int(bytes([0x10 + b for b in range(32)]))
    for addr, data in ((d_addr, d_data), (i_addr, i_data)):
        model.write_line(addr, data, full)
        await _line_transaction(dut, write=True, addr=addr, wdata=data, wstrb=full)
    # Push both lines out of every cache level with reads of aliasing lines
    # (the harness caches are tiny: 256 lines overflow L1D and L2 alike), so
    # the demand misses below find clean victims and go straight to their
    # fills. A dirty victim would serialize a writeback ahead of the fill.
    for line in range(256):
        addr = OVERLAP_BASE + 0x10000 + line * LINE_BYTES
        got = await _line_transaction(dut, write=False, addr=addr)
        assert got == model.read_line(addr)

    done_cycle: dict[str, int] = {}
    cycle = [0]

    async def _count_cycles() -> None:
        while True:
            await FallingEdge(dut.i_clk)
            cycle[0] += 1

    counter = cocotb.start_soon(_count_cycles())

    async def _read(port: str, addr: int, expected: int) -> None:
        got = await _port_transaction(dut, port, write=False, addr=addr)
        done_cycle[port] = cycle[0]
        assert got == expected, f"{port} read mismatch @0x{addr:08x}"

    tasks = [
        cocotb.start_soon(_read("up", d_addr, model.read_line(d_addr))),
        cocotb.start_soon(_read("iup", i_addr, model.read_line(i_addr))),
    ]
    for task in tasks:
        await task
    counter.cancel()

    spread = abs(done_cycle["up"] - done_cycle["iup"])
    dut._log.info(
        f"overlap test: responses {spread} cycles apart (has_l2={int(dut.o_has_l2.value)})"
    )
    if int(dut.o_has_l2.value) == 0:
        # Both fills were in flight at once: the second response cannot trail
        # the first by a whole memory round trip.
        assert (
            spread < MEM_LATENCY_CYCLES
        ), f"misses did not overlap: {spread} cycles apart"


@cocotb.test()
async def test_walker_port_reads_shared_level(dut: Any) -> None:
    """The walker port reads what the shared level holds, uncached.

    A line written back from the L1D is visible to a walk; a repeat read
    returns the same data (there is no cache in front of the walker port,
    so both reads go downstream and both must route their responses home by
    id alone).
    """
    await _setup(dut)
    model = ReferenceModel()
    full = (1 << LINE_BYTES) - 1
    addr = WALK_BASE + 5 * LINE_BYTES
    wdata = _line_int(bytes([(0x9A + b) & 0xFF for b in range(32)]))
    model.write_line(addr, wdata, full)
    await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=full)
    await _force_l1d_writeback(dut, model, addr)

    got = await _port_transaction(dut, "wup", write=False, addr=addr)
    assert got == model.read_line(addr), f"wup read mismatch @0x{addr:08x}"
    got2 = await _port_transaction(dut, "wup", write=False, addr=addr)
    assert got2 == got


@cocotb.test()
async def test_three_ports_overlap_below_arbiters(dut: Any) -> None:
    """Simultaneous D, I, and walker misses all fire downstream together.

    The arbiter tree has no grant lock at either level, so three tagged
    reads (one per master) can be in flight below it at once. In the
    L1-only shape the three DDR reads overlap and the responses land within
    one memory latency of each other; the L2 shape spaces their launches
    through its serialized tag front-end, so there only the data and id
    routing are checked.
    """
    await _setup(dut)
    model = ReferenceModel()
    full = (1 << LINE_BYTES) - 1
    d_addr = WALK2_BASE + 3 * LINE_BYTES
    i_addr = WALK2_BASE + 9 * LINE_BYTES
    w_addr = WALK2_BASE + 15 * LINE_BYTES
    for addr, seed in ((d_addr, 0xD0), (i_addr, 0x10), (w_addr, 0xA0)):
        data = _line_int(bytes([(seed + b) & 0xFF for b in range(32)]))
        model.write_line(addr, data, full)
        await _line_transaction(dut, write=True, addr=addr, wdata=data, wstrb=full)
    # Push the lines out of every cache level with reads of aliasing lines
    # (see test_ports_overlap_below_arbiter for the clean-victim rationale).
    for line in range(256):
        addr = WALK2_BASE + 0x10000 + line * LINE_BYTES
        got = await _line_transaction(dut, write=False, addr=addr)
        assert got == model.read_line(addr)

    done_cycle: dict[str, int] = {}
    cycle = [0]

    async def _count_cycles() -> None:
        while True:
            await FallingEdge(dut.i_clk)
            cycle[0] += 1

    counter = cocotb.start_soon(_count_cycles())

    async def _read(port: str, addr: int, expected: int) -> None:
        got = await _port_transaction(dut, port, write=False, addr=addr)
        done_cycle[port] = cycle[0]
        assert got == expected, f"{port} read mismatch @0x{addr:08x}"

    tasks = [
        cocotb.start_soon(_read("up", d_addr, model.read_line(d_addr))),
        cocotb.start_soon(_read("iup", i_addr, model.read_line(i_addr))),
        cocotb.start_soon(_read("wup", w_addr, model.read_line(w_addr))),
    ]
    for task in tasks:
        await task
    counter.cancel()

    spread = max(done_cycle.values()) - min(done_cycle.values())
    dut._log.info(
        f"3-port overlap: responses {spread} cycles apart (has_l2={int(dut.o_has_l2.value)})"
    )
    if int(dut.o_has_l2.value) == 0:
        assert (
            spread < MEM_LATENCY_CYCLES
        ), f"misses did not overlap: {spread} cycles apart"


@cocotb.test()
async def test_walker_mixed_id_traffic(dut: Any) -> None:
    """All three masters hammer concurrently; ids route every response home."""
    await _setup(dut)
    model = ReferenceModel()
    full = (1 << LINE_BYTES) - 1
    rng = random.Random(random.getrandbits(32))

    # Stable region for the read-only masters, written back to the shared
    # level by thrashing aliases (as in test_mixed_id_traffic).
    walk_lines = 16
    for line in range(walk_lines):
        addr = WALK3_BASE + line * LINE_BYTES
        wdata = _line_int(bytes([(line * 7 + b) & 0xFF for b in range(32)]))
        model.write_line(addr, wdata, full)
        await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=full)
    for line in range(64):
        addr = WALK3_BASE + 0x10000 + line * LINE_BYTES
        wdata = _line_int(bytes([(0x55 + line + b) & 0xFF for b in range(32)]))
        model.write_line(addr, wdata, full)
        await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=full)

    async def _d_master() -> None:
        for _ in range(100):
            line = rng.randrange(64)
            addr = WALK3_BASE + 0x10000 + line * LINE_BYTES
            if rng.random() < 0.5:
                wdata = rng.getrandbits(256)
                model.write_line(addr, wdata, full)
                await _line_transaction(
                    dut, write=True, addr=addr, wdata=wdata, wstrb=full
                )
            else:
                got = await _line_transaction(dut, write=False, addr=addr)
                assert got == model.read_line(addr)

    async def _ro_master(port: str) -> None:
        for _ in range(100):
            line = rng.randrange(walk_lines)
            addr = WALK3_BASE + line * LINE_BYTES
            got = await _port_transaction(dut, port, write=False, addr=addr)
            assert got == model.read_line(addr), f"{port} mismatch @0x{addr:08x}"

    tasks = [
        cocotb.start_soon(_d_master()),
        cocotb.start_soon(_ro_master("iup")),
        cocotb.start_soon(_ro_master("wup")),
    ]
    for task in tasks:
        await task


async def _fence_sync(dut: Any) -> None:
    """Run one fence.i cache-sync handshake (hold sync until done rises)."""
    await FallingEdge(dut.i_clk)
    dut.i_fence_sync.value = 1
    for _ in range(SWEEP_TIMEOUT_CYCLES):
        await FallingEdge(dut.i_clk)
        if int(dut.o_fence_done.value) == 1:
            break
    else:
        raise AssertionError("fence sync never completed")
    dut.i_fence_sync.value = 0
    await FallingEdge(dut.i_clk)


@cocotb.test()
async def test_fence_sync_publishes_dirty_lines(dut: Any) -> None:
    """Fence sync alone (no manual eviction) makes L1D-dirty data fetchable.

    This is the property fence.i is built on: writeback-all pushes every
    dirty line to the level the I-side fills from, while the lines stay
    valid and clean on the D-side.
    """
    await _setup(dut)
    model = ReferenceModel()
    full = (1 << LINE_BYTES) - 1

    addrs = [FENCE_BASE + line * LINE_BYTES for line in (0, 3, 17)]
    for i, addr in enumerate(addrs):
        wdata = _line_int(bytes([(0x30 + 13 * i + b) & 0xFF for b in range(32)]))
        model.write_line(addr, wdata, full)
        await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=full)

    await _fence_sync(dut)

    for addr in addrs:
        got = await _port_transaction(dut, "iup", write=False, addr=addr)
        assert got == model.read_line(addr), f"iup stale after fence @0x{addr:08x}"

    # The lines stayed valid and clean on the D-side: reads still match, and
    # a re-dirtying write round-trips as usual.
    for addr in addrs:
        await _check_read(dut, model, addr)
    rewrite = _line_int(bytes([0x5C] * 32))
    model.write_line(addrs[0], rewrite, full)
    await _line_transaction(dut, write=True, addr=addrs[0], wdata=rewrite, wstrb=full)
    await _check_read(dut, model, addrs[0])


@cocotb.test()
async def test_fence_sync_invalidates_stale_l1i(dut: Any) -> None:
    """A line already cached in the L1I is refetched fresh after a fence."""
    await _setup(dut)
    model = ReferenceModel()
    full = (1 << LINE_BYTES) - 1
    addr = FENCE2_BASE + 7 * LINE_BYTES

    # Prime the L1I with the line's pre-write contents (zeros).
    got = await _port_transaction(dut, "iup", write=False, addr=addr)
    assert got == 0

    # D-side writes new "code"; without a fence the L1I would keep hitting
    # on the stale line.
    wdata = _line_int(bytes([(0xC0 + b) & 0xFF for b in range(32)]))
    model.write_line(addr, wdata, full)
    await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=full)

    await _fence_sync(dut)

    got = await _port_transaction(dut, "iup", write=False, addr=addr)
    assert got == model.read_line(addr), "L1I served stale data after fence"


@cocotb.test()
async def test_fence_sync_publishes_dirty_lines_to_walker(dut: Any) -> None:
    """The sfence.vma coherence property, at the fabric level.

    A page-table store dirty in the L1D is invisible to a walk, because the
    walker reads through the shared level, below the L1D. sfence.vma runs
    that fence sync with the TLBs held invalid, so the walk after it sees
    the store.
    """
    await _setup(dut)
    model = ReferenceModel()
    full = (1 << LINE_BYTES) - 1
    addr = WALK_BASE + 0x20000 + 11 * LINE_BYTES

    wdata = _line_int(bytes([(0xE0 + b) & 0xFF for b in range(32)]))
    model.write_line(addr, wdata, full)
    await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=full)

    # Dirty in L1D, never written back: the walk sees the shared level's
    # zeros. This is the stale-PTE hazard sfence.vma's writeback-all exists for.
    got = await _port_transaction(dut, "wup", write=False, addr=addr)
    assert got == 0, f"wup unexpectedly observed dirty L1D data @0x{addr:08x}"

    await _fence_sync(dut)

    got = await _port_transaction(dut, "wup", write=False, addr=addr)
    assert got == model.read_line(addr), f"wup stale after fence @0x{addr:08x}"


@cocotb.test()
async def test_fence_sync_idle_cache(dut: Any) -> None:
    """A fence with nothing dirty completes and disturbs nothing."""
    await _setup(dut)
    await _fence_sync(dut)
    await _fence_sync(dut)  # back-to-back syncs from idle
    got = await _port_transaction(dut, "iup", write=False, addr=FENCE2_BASE)
    assert got == 0


@cocotb.test()
async def test_perf_events_partition_known_traffic_and_exclude_maintenance(
    dut: Any,
) -> None:
    """Known hit/miss/eviction traffic partitions exactly; fence traffic is excluded."""
    await _setup(dut)
    counts = _new_perf_counts()
    stop = [False]
    monitor = cocotb.start_soon(_monitor_perf_events(dut, counts, stop))

    # One cold + one warm read on each L1 gives a deterministic 2 = 1 hit +
    # 1 miss partition. Keep the addresses on distinct L1 indices.
    d_addr = PERF_BASE + 1 * LINE_BYTES
    i_addr = PERF_BASE + 2 * LINE_BYTES
    assert await _line_transaction(dut, write=False, addr=d_addr) == 0
    assert await _line_transaction(dut, write=False, addr=d_addr) == 0
    assert await _port_transaction(dut, "iup", write=False, addr=i_addr) == 0
    assert await _port_transaction(dut, "iup", write=False, addr=i_addr) == 0

    # Four whole-line writes alias in L1D. The first two evicted lines land in
    # distinct L2 indices; the third aliases the first in L2, so evicting it
    # from L1D produces a positive, ordinary-traffic L2 writeback. The fourth
    # remains dirty in L1D for the maintenance-exclusion check below.
    full = (1 << LINE_BYTES) - 1
    dirty_addr = PERF_BASE + 7 * LINE_BYTES
    dirty_l1_alias = dirty_addr + 1024  # harness L1D is 1 KiB
    dirty_l2_alias = dirty_addr + 4096  # harness L2 is 4 KiB
    dirty_l2_alias_2 = dirty_addr + 8192
    await _line_transaction(
        dut,
        write=True,
        addr=dirty_addr,
        wdata=_line_int(bytes([0x4A] * LINE_BYTES)),
        wstrb=full,
    )
    await _line_transaction(
        dut,
        write=True,
        addr=dirty_l1_alias,
        wdata=_line_int(bytes([0xB7] * LINE_BYTES)),
        wstrb=full,
    )
    await _line_transaction(
        dut,
        write=True,
        addr=dirty_l2_alias,
        wdata=_line_int(bytes([0x6D] * LINE_BYTES)),
        wstrb=full,
    )
    await _line_transaction(
        dut,
        write=True,
        addr=dirty_l2_alias_2,
        wdata=_line_int(bytes([0x93] * LINE_BYTES)),
        wstrb=full,
    )

    await _settle(dut)
    await Timer(1, unit="ns")

    assert counts["l1i"]["access"] == 2
    assert counts["l1i"]["hit"] == 1
    assert counts["l1i"]["miss"] == 1
    assert counts["l1i"]["writeback"] == 0

    assert counts["l1d"]["access"] == 6
    assert counts["l1d"]["hit"] == 1
    assert counts["l1d"]["miss"] == 5
    assert counts["l1d"]["writeback"] == 3
    assert counts["l1d"]["miss_outstanding"] > 0

    assert counts["l1i"]["hit"] + counts["l1i"]["miss"] == counts["l1i"]["access"]
    assert counts["l1d"]["hit"] + counts["l1d"]["miss"] == counts["l1d"]["access"]

    if int(dut.o_has_l2.value) != 0:
        # Cold D/I reads + three ordinary dirty L1D victims written to L2.
        assert counts["l2"]["access"] == 5
        assert counts["l2"]["hit"] == 0
        assert counts["l2"]["miss"] == 5
        assert counts["l2"]["writeback"] == 1
        assert counts["l2"]["miss_outstanding"] > 0
        assert counts["l2"]["hit"] + counts["l2"]["miss"] == counts["l2"]["access"]
    else:
        assert counts["l2"] == {field: 0 for field in PERF_FIELDS}

    before_fence = _copy_perf_counts(counts)
    await _fence_sync(dut)
    await _settle(dut)
    await Timer(1, unit="ns")

    # dirty_l2_alias_2 is written through L1D and collides with
    # dirty_l2_alias in L2, inducing another L2 victim writeback. Neither the
    # walk nor that lower-level work is ordinary traffic, so no event or
    # miss-occupancy total may move.
    assert counts == before_fence

    stop[0] = True
    await FallingEdge(dut.i_clk)
    await monitor
