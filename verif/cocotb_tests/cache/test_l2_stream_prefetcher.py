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

"""Test l2_stream_prefetcher: stream confirmation, distance, pages, and the read cap."""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

CLOCK_PERIOD_NS = 10
L1_LINE = 32
L2_LINE = 64
PAGE = 4096
DISTANCE = 8  # the module's default


class PrefetchBench:
    """Feeds L1D misses, answers the prefetcher's reads, and records them."""

    def __init__(self, dut: Any, ready_pct: int = 100, resp_delay: int = 3) -> None:
        """Bind the bench to the DUT, with the port's readiness and response delay."""
        self.dut = dut
        self.rng = random.Random(7)
        self.ready_pct = ready_pct
        self.resp_delay = resp_delay
        self.edge = 0
        self.reads: list[int] = []  # L2 line addresses, in issue order
        self.pending: list[tuple[int, int]] = []  # (due edge, id)
        self.max_outstanding = 0

    async def start(self) -> None:
        """Start the clock and reset."""
        dut = self.dut
        Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
        dut.i_miss_valid.value = 0
        dut.i_miss_addr.value = 0
        dut.i_req_ready.value = 0
        dut.i_resp_valid.value = 0
        dut.i_resp_id.value = 0
        dut.i_rst.value = 1
        for _ in range(3):
            await RisingEdge(dut.i_clk)
        await FallingEdge(dut.i_clk)
        dut.i_rst.value = 0

    async def cycle(self, miss: int | None = None) -> None:
        """One cycle, with an optional L1D miss address."""
        dut = self.dut
        dut.i_miss_valid.value = int(miss is not None)
        dut.i_miss_addr.value = miss if miss is not None else 0
        ready = self.rng.randrange(100) < self.ready_pct
        dut.i_req_ready.value = int(ready)
        fire = ready and int(dut.o_req_valid.value)
        if fire:
            addr = int(dut.o_req_addr.value)
            rid = int(dut.o_req_id.value)
            assert addr % L2_LINE == 0, f"unaligned prefetch {addr:#x}"
            assert all(rid != pending_id for _, pending_id in self.pending), rid
            self.reads.append(addr)
            self.pending.append((self.edge + 1 + self.resp_delay, rid))
        due = [p for p in self.pending if p[0] <= self.edge + 1]
        resp = due[0] if due else None
        dut.i_resp_valid.value = int(resp is not None)
        dut.i_resp_id.value = resp[1] if resp else 0
        if resp:
            self.pending.remove(resp)
        await RisingEdge(dut.i_clk)
        self.edge += 1
        self.max_outstanding = max(self.max_outstanding, len(self.pending))
        await FallingEdge(dut.i_clk)

    async def idle(self, cycles: int) -> None:
        """Run cycles with no miss."""
        for _ in range(cycles):
            await self.cycle()


@cocotb.test()
async def test_stream_is_confirmed_then_read_ahead(dut: Any) -> None:
    """Misses on consecutive L2 lines start reads up to DISTANCE lines ahead."""
    bench = PrefetchBench(dut)
    await bench.start()
    base = 0x8010_0000
    await bench.cycle(base)  # allocates
    await bench.idle(4)
    assert not bench.reads, f"read before confirmation: {[hex(a) for a in bench.reads]}"
    await bench.cycle(base + L2_LINE)  # confirms
    await bench.idle(20)
    expected = [base + L2_LINE * k for k in range(2, 2 + DISTANCE)]
    assert bench.reads == expected, [hex(a) for a in bench.reads]
    # The stream advances one line: one more read, still DISTANCE ahead.
    await bench.cycle(base + 2 * L2_LINE)
    await bench.idle(20)
    assert bench.reads == expected + [base + L2_LINE * (2 + DISTANCE)], [
        hex(a) for a in bench.reads
    ]


@cocotb.test()
async def test_second_half_of_a_line_leaves_the_stream(dut: Any) -> None:
    """The other 32-byte half of the stream's last line neither confirms nor resets."""
    bench = PrefetchBench(dut)
    await bench.start()
    base = 0x8020_0000
    for addr in (base, base + L1_LINE, base + L2_LINE, base + L2_LINE + L1_LINE):
        await bench.cycle(addr)
    await bench.idle(20)
    assert bench.reads == [base + L2_LINE * k for k in range(2, 2 + DISTANCE)], [
        hex(a) for a in bench.reads
    ]


@cocotb.test()
async def test_reads_stop_at_the_page(dut: Any) -> None:
    """No read leaves the page of the stream's last miss."""
    bench = PrefetchBench(dut)
    await bench.start()
    page = 0x8030_0000
    last = page + PAGE - L2_LINE  # the page's last line
    await bench.cycle(last - 2 * L2_LINE)
    await bench.cycle(last - L2_LINE)
    await bench.idle(20)
    assert bench.reads == [last], [hex(a) for a in bench.reads]
    await bench.cycle(last)
    await bench.idle(20)
    assert bench.reads == [last], "read past the page"


@cocotb.test()
async def test_outstanding_reads_are_capped(dut: Any) -> None:
    """Two streams wait at the request cap and resume as response IDs return."""
    bench = PrefetchBench(dut, resp_delay=200)
    await bench.start()
    base = 0x8040_0000
    for stream in (base, base + 0x10000):
        await bench.cycle(stream)
        await bench.cycle(stream + L2_LINE)
    await bench.idle(80)
    limit = int(dut.MAX_INFLIGHT.value)
    assert len(bench.reads) == len(bench.pending) == limit
    bench.resp_delay = 3
    await bench.idle(300)
    assert bench.max_outstanding == limit, bench.max_outstanding
    assert len(bench.reads) == 2 * DISTANCE, [hex(a) for a in bench.reads]
    assert not bench.pending


@cocotb.test()
async def test_random_misses_read_nothing(dut: Any) -> None:
    """Misses on unrelated lines never confirm a stream."""
    bench = PrefetchBench(dut, ready_pct=70)
    await bench.start()
    rng = random.Random(3)
    seen: set[int] = set()
    for _ in range(400):
        line = 0x8000_0000 + rng.randrange(1 << 16) * L2_LINE * 3
        if any(abs(line - other) == L2_LINE for other in seen):
            continue
        seen.add(line)
        await bench.cycle(line)
    await bench.idle(20)
    assert not bench.reads, [hex(a) for a in bench.reads[:8]]


@cocotb.test()
async def test_four_interleaved_streams(dut: Any) -> None:
    """Four streams missing in turn are all followed."""
    bench = PrefetchBench(dut, ready_pct=80)
    await bench.start()
    bases = [0x8050_0000 + n * 0x10_0000 for n in range(4)]
    for step in range(6):
        for base in bases:
            await bench.cycle(base + step * L2_LINE)
    await bench.idle(60)
    for base in bases:
        ahead = [a for a in bench.reads if base <= a < base + PAGE]
        assert ahead, f"no reads for the stream at {base:#x}"
        assert max(ahead) == base + (5 + DISTANCE) * L2_LINE, [hex(a) for a in ahead]
    assert len(bench.reads) == len(set(bench.reads)), "a line was read twice"
