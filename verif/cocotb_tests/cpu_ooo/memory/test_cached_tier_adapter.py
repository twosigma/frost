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

"""Test cached_tier_adapter: shared line requests, store ordering, and responses.

A model of the cache hierarchy's line port applies a store when it accepts the
request, snapshots the line when it accepts a read, and answers requests out
of order. A read's beat must be the value of its address when the read was
accepted, or a value a store wrote there while the read was outstanding.
"""

import random
from dataclasses import dataclass, field
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

CLOCK_PERIOD_NS = 10
CACHED_BASE = 0x8000_0000
LINE_BYTES = 32
BEAT_BYTES = 8
BEATS_PER_LINE = LINE_BYTES // BEAT_BYTES
BEAT_MASK = (1 << 64) - 1


@dataclass
class LinePortModel:
    """The cache hierarchy's line port, with a byte memory and versioned beats."""

    rng: random.Random
    ready_pct: int = 80
    max_delay: int = 12
    memory: dict[int, int] = field(default_factory=dict)  # beat address -> value
    # beat address -> [(edge, value)], oldest first
    history: dict[int, list[tuple[int, int]]] = field(default_factory=dict)
    pending: list[dict[str, int]] = field(default_factory=list)
    read_requests: list[tuple[int, int]] = field(default_factory=list)  # (edge, line)
    write_requests: int = 0

    def beat(self, addr: int) -> int:
        """Return the current value of the beat at addr."""
        return self.memory.get(addr & ~(BEAT_BYTES - 1), 0)

    def allowed(self, addr: int, edge_from: int, edge_to: int) -> set[int]:
        """Values a read of addr accepted at edge_from may return by edge_to."""
        key = addr & ~(BEAT_BYTES - 1)
        entries = self.history.get(key, [])
        before = [value for edge, value in entries if edge <= edge_from]
        values = {before[-1] if before else 0}
        values.update(value for edge, value in entries if edge_from < edge <= edge_to)
        return values

    def accept(
        self, edge: int, write: bool, addr: int, wdata: int, wstrb: int, rid: int
    ) -> None:
        """Take a request on this edge."""
        line = addr & ~(LINE_BYTES - 1)
        delay = edge + self.rng.randint(1, self.max_delay)
        if write:
            self.write_requests += 1
            for b in range(BEATS_PER_LINE):
                beat_strb = (wstrb >> (b * BEAT_BYTES)) & 0xFF
                if not beat_strb:
                    continue
                key = line + b * BEAT_BYTES
                old = self.memory.get(key, 0)
                new_bytes = (wdata >> (b * 64)) & BEAT_MASK
                value = old
                for byte in range(BEAT_BYTES):
                    if beat_strb >> byte & 1:
                        value &= ~(0xFF << (8 * byte))
                        value |= new_bytes & (0xFF << (8 * byte))
                self.memory[key] = value
                self.history.setdefault(key, []).append((edge, value))
            self.pending.append({"id": rid, "due": delay, "data": 0})
        else:
            self.read_requests.append((edge, line))
            data = 0
            for b in range(BEATS_PER_LINE):
                data |= self.memory.get(line + b * BEAT_BYTES, 0) << (b * 64)
            self.pending.append({"id": rid, "due": delay, "data": data})

    def pick_response(self, edge: int) -> dict[str, int] | None:
        """Pop one due response, in random order among the due ones."""
        due = [p for p in self.pending if p["due"] <= edge]
        if not due:
            return None
        choice = self.rng.choice(due)
        self.pending.remove(choice)
        return choice


@dataclass
class ReadRecord:
    """One outstanding router read."""

    slot: int
    addr: int
    accept_edge: int


class AdapterBench:
    """Drives the router side, models the line port, and checks every beat."""

    def __init__(self, dut: Any, seed: int) -> None:
        """Bind the bench to the DUT, with its own random stream."""
        self.dut = dut
        self.rng = random.Random(seed)
        self.port = LinePortModel(self.rng)
        self.slots = 1 << len(dut.i_read_id)
        self.edge = 0
        self.outstanding: dict[int, ReadRecord] = {}
        self.store_pending = False
        self.delivered = 0
        self.read_ready_pct = 80
        # Reads that joined a group on the cycle its response arrived.
        self.joined_on_response = 0

    async def start(self, clock: bool = True) -> None:
        """Start the clock (once per test) and reset."""
        dut = self.dut
        if clock:
            Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
        self.idle_router()
        dut.i_line_req_ready.value = 0
        dut.i_line_resp_valid.value = 0
        dut.i_line_resp_id.value = 0
        dut.i_line_resp_rdata.value = 0
        dut.i_read_ready.value = 1
        dut.i_rst.value = 1
        for _ in range(3):
            await RisingEdge(dut.i_clk)
        await FallingEdge(dut.i_clk)
        dut.i_rst.value = 0

    def idle_router(self) -> None:
        """Drive no request on the router side."""
        dut = self.dut
        dut.i_read_req.value = 0
        dut.i_read_id.value = 0
        dut.i_read_no_merge.value = 0
        dut.i_req_addr.value = 0
        dut.i_write_byte_en.value = 0
        dut.i_write_data.value = 0

    def free_slots(self) -> list[int]:
        """Slots the router may launch into."""
        return [s for s in range(self.slots) if s not in self.outstanding]

    async def cycle(
        self,
        read: tuple[int, bool] | None = None,
        write: tuple[int, int, int] | None = None,
    ) -> None:
        """Run one cycle: drive inputs for the next edge, then check its effects.

        read is (addr, no_merge) for a read into the lowest free slot; write is
        (addr, data, byte_en). The caller keeps the router protocol: no read
        while a store is pending or fires.
        """
        dut = self.dut
        self.idle_router()
        if read is not None:
            slot = self.free_slots()[0]
            addr, no_merge = read
            dut.i_read_req.value = 1
            dut.i_read_id.value = slot
            dut.i_read_no_merge.value = int(no_merge)
            dut.i_req_addr.value = addr
        if write is not None:
            addr, data, byte_en = write
            dut.i_req_addr.value = addr
            dut.i_write_data.value = data
            dut.i_write_byte_en.value = byte_en
        # Line port: request handshake and one response.
        req_ready = self.rng.randrange(100) < self.port.ready_pct
        dut.i_line_req_ready.value = int(req_ready)
        req_fire = req_ready and int(dut.o_line_req_valid.value)
        req = None
        if req_fire:
            req = (
                bool(int(dut.o_line_req_write.value)),
                int(dut.o_line_req_addr.value),
                int(dut.o_line_req_wdata.value),
                int(dut.o_line_req_wstrb.value),
                int(dut.o_line_req_id.value),
            )
        resp = self.port.pick_response(self.edge + 1)
        dut.i_line_resp_valid.value = int(resp is not None)
        if resp is not None:
            dut.i_line_resp_id.value = resp["id"]
            dut.i_line_resp_rdata.value = resp["data"]
        # Router read port.
        read_ready = self.rng.randrange(100) < self.read_ready_pct
        dut.i_read_ready.value = int(read_ready)
        out = None
        if read_ready and int(dut.o_read_valid.value):
            out = (int(dut.o_read_id.value), int(dut.o_read_data.value))

        await ReadOnly()
        if read is not None and int(dut.attach_answered.value):
            self.joined_on_response += 1
        await RisingEdge(dut.i_clk)
        self.edge += 1
        if req is not None:
            self.port.accept(self.edge, *req)
        if read is not None:
            self.outstanding[slot] = ReadRecord(slot, read[0], self.edge)
        if write is not None:
            self.store_pending = True
        if out is not None:
            self.check_delivery(*out)
        await FallingEdge(dut.i_clk)
        if int(dut.o_write_done.value):
            self.store_pending = False

    def check_delivery(self, slot: int, data: int) -> None:
        """Check that a delivered beat answers an outstanding read with a fresh value."""
        assert slot in self.outstanding, f"beat for slot {slot}, which has no read"
        record = self.outstanding.pop(slot)
        allowed = self.port.allowed(record.addr, record.accept_edge, self.edge)
        assert data in allowed, (
            f"slot {slot} read {record.addr:#x} at edge {record.accept_edge}: "
            f"got {data:#018x}, allowed {[hex(v) for v in sorted(allowed)]}"
        )
        self.delivered += 1

    async def drain(self, limit: int = 400) -> None:
        """Run idle cycles until every read and the store have completed."""
        for _ in range(limit):
            if (
                not self.outstanding
                and not self.store_pending
                and not self.port.pending
            ):
                if not int(self.dut.o_read_valid.value):
                    return
            await self.cycle()
        raise AssertionError(
            f"adapter did not drain: reads {sorted(self.outstanding)}, store {self.store_pending}"
        )

    async def store(self, addr: int, data: int, byte_en: int = 0xFF) -> None:
        """Fire a store, then idle until its done pulse."""
        await self.cycle(write=(addr, data, byte_en))
        for _ in range(200):
            if not self.store_pending:
                return
            await self.cycle()
        raise AssertionError("store never completed")

    def read_requests_for(self, line: int) -> int:
        """Line read requests the port has taken for line."""
        return sum(1 for _, req_line in self.port.read_requests if req_line == line)


@cocotb.test()
async def test_reads_of_one_line_share_a_request(dut: Any) -> None:
    """Four reads of one line, back to back, send one line request."""
    bench = AdapterBench(dut, seed=1)
    bench.port.ready_pct = 100
    bench.port.max_delay = 20
    await bench.start()
    line = CACHED_BASE + 0x400
    await bench.store(line, 0x1111_2222_3333_4444)
    await bench.store(line + 24, 0x5555_6666_7777_8888)
    for beat in range(4):
        await bench.cycle(read=(line + beat * BEAT_BYTES, False))
    await bench.drain()
    assert bench.read_requests_for(line) == 1, bench.port.read_requests
    assert bench.delivered == 4


@cocotb.test()
async def test_eight_reads_in_flight(dut: Any) -> None:
    """Eight reads of eight lines are all outstanding at once."""
    bench = AdapterBench(dut, seed=2)
    bench.port.ready_pct = 100
    bench.port.max_delay = 40
    await bench.start()
    for n in range(bench.slots):
        await bench.cycle(read=(CACHED_BASE + n * 0x1000, False))
    assert len(bench.outstanding) == bench.slots
    await bench.drain()
    assert len(bench.port.read_requests) == bench.slots
    assert bench.delivered == bench.slots


@cocotb.test()
async def test_store_closes_the_open_request(dut: Any) -> None:
    """A read after a store to its line gets its own request and the stored value."""
    bench = AdapterBench(dut, seed=3)
    bench.port.ready_pct = 100
    await bench.start()
    line = CACHED_BASE + 0x800
    bench.port.max_delay = 60
    await bench.cycle(read=(line, False))  # opens a group; its response is slow
    # Let the group's request reach the port before the store.
    for _ in range(3):
        await bench.cycle()
    bench.port.max_delay = 3
    await bench.store(line + 8, 0xABCD_EF01_2345_6789)
    await bench.cycle(read=(line + 8, False))
    await bench.drain(600)
    assert bench.read_requests_for(line) == 2, bench.port.read_requests
    assert bench.delivered == 2


@cocotb.test()
async def test_no_merge_reads_keep_their_own_request(dut: Any) -> None:
    """An LR or AMO read neither joins nor takes followers."""
    bench = AdapterBench(dut, seed=4)
    bench.port.ready_pct = 100
    bench.port.max_delay = 40
    await bench.start()
    line = CACHED_BASE + 0xC00
    await bench.cycle(read=(line, False))  # a plain group
    await bench.cycle(read=(line + 8, True))  # LR: its own request
    await bench.cycle(read=(line + 16, False))  # joins the plain group
    await bench.drain()
    assert bench.read_requests_for(line) == 2, bench.port.read_requests
    assert bench.delivered == 3

    no_merge_line = CACHED_BASE + 0x1C00
    await bench.cycle(read=(no_merge_line, True))  # AMO read first
    await bench.cycle(read=(no_merge_line + 8, False))  # may not join it
    await bench.drain()
    assert bench.read_requests_for(no_merge_line) == 2, bench.port.read_requests


@cocotb.test()
async def test_random_traffic(dut: Any) -> None:
    """Random reads, LR/AMO reads, and stores over four lines, with backpressure."""
    joined_on_response = 0
    for seed in (11, 12, 13):
        bench = AdapterBench(dut, seed=seed)
        bench.read_ready_pct = 70
        await bench.start(clock=(seed == 11))
        lines = [CACHED_BASE + n * 0x2000 for n in range(4)]
        for _ in range(3000):
            read = write = None
            roll = bench.rng.randrange(100)
            if not bench.store_pending and roll < 8 and not bench.outstanding:
                pass  # leave the port idle so groups drain now and then
            elif not bench.store_pending and roll < 14:
                addr = bench.rng.choice(lines) + bench.rng.randrange(4) * BEAT_BYTES
                write = (
                    addr,
                    bench.rng.getrandbits(64),
                    bench.rng.choice([0xFF, 0x0F, 0xF0, 0x01]),
                )
            elif not bench.store_pending and bench.free_slots() and roll < 70:
                addr = bench.rng.choice(lines) + bench.rng.randrange(4) * BEAT_BYTES
                read = (addr, bench.rng.randrange(100) < 10)
            await bench.cycle(read=read, write=write)
        await bench.drain(1000)
        dut._log.info(
            f"seed {seed}: {bench.delivered} reads, "
            f"{len(bench.port.read_requests)} line reads, {bench.port.write_requests} stores, "
            f"{bench.joined_on_response} joined on the response cycle"
        )
        assert bench.delivered > 500
        joined_on_response += bench.joined_on_response
    assert joined_on_response > 0, "no read joined a group on its response's cycle"
