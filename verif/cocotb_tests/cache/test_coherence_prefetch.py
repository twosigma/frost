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

"""Check the stream requester against the production coherent home."""

from typing import Any

import cocotb

from cocotb_tests.cache.test_coherence_endpoints import pack
from cocotb_tests.cache.test_coherence_home import Home, unpack


class HomeSignals:
    """Present the harness interface and the home's observation signals."""

    def __init__(self, dut: Any) -> None:
        """Bind both scopes without copying signal values."""
        self.top = dut

    def __getattr__(self, name: str) -> Any:
        """Resolve interface names before home internals."""
        signal = getattr(self.top, name, None)
        return signal if signal is not None else getattr(self.top.home, name)

    def __iter__(self) -> Any:
        """Iterate the top inputs for reset."""
        return iter(self.top)


class PrefetchHome(Home):
    """Observe identities while the home services independent transport peers."""

    def __init__(self, dut: Any) -> None:
        """Track prefetch protocol lifetimes and memory completion cycles."""
        super().__init__(HomeSignals(dut))
        self.pf: list[tuple[int, str, tuple[int, ...]]] = []
        self.live: dict[int, tuple[int, str]] = {}
        self.returned: dict[int, int] = {}
        self.required_fills: set[int] = set()
        self.max_live = 0
        self.max_fills = 0
        self.dirty_prefetch_recalls: list[int] = []

    def get(self, name: str) -> int:
        """Expose home internals used by the shared memory responder."""
        signal = getattr(self.dut, name, None)
        if signal is None:
            signal = getattr(self.dut.home, name)
        return int(signal.value)

    async def set(self, **values: int) -> None:
        """Sample protocol transfers immediately before each rising edge."""
        if values.get("i_clk") == 1 and not self.get("i_rst"):
            if self.get("i_r_valid") and self.get("o_r_ready"):
                reply = unpack(
                    self.get("i_r"), (2, 6, 1, 1, self.p, 2, 1, 1, 256, 1, 1, 1, 1, 1)
                )
                if 19 <= reply[1] < 23 and reply[7]:
                    slot = reply[1] - 19
                    address = (self.get("fill_addr_q") >> (slot * self.p)) & (
                        (1 << self.p) - 1
                    )
                    if any(a == address for a, _ in self.live.values()):
                        self.dirty_prefetch_recalls.append(reply[4])
            if self.get("i_mem_resp_valid"):
                rid = self.get("i_mem_resp_id")
                if rid < 4:
                    address = (self.get("fill_addr_q") >> (rid * self.p)) & (
                        (1 << self.p) - 1
                    )
                    self.returned[address] = self.cycle
            if self.get("pf_d_valid") and self.get("d_ready") & 2:
                fields = unpack(
                    self.get("pf_d"), (4, 9, self.p, 5, 3, 32, 1, 1, 1, 256)
                )
                op, q, address = fields[:3]
                assert op == 9 and q >> 5 == 15
                assert address % self.line == 0 and fields[7] == 0
                assert q not in self.live, "identity reused before U"
                self.live[q] = (address, "D")
                self.pf.append((self.cycle, "D", fields))
            if self.get("home_g_valid"):
                fields = unpack(self.get("home_g"), (3, 9, 6, self.p, 256, 1))
                if fields[1] >> 5 == 15:
                    q, address = fields[1], fields[3]
                    assert self.live[q] == (address, "D")
                    assert fields[0] == 4 and fields[4] == 0
                    reads = [
                        c for c, w, a in self.transactions if not w and a == address
                    ]
                    if reads or address in self.required_fills:
                        assert address in self.returned, (
                            "grant offered before fill response"
                        )
                    for slot in range(4):
                        fill_address = (self.get("fill_addr_q") >> (slot * self.p)) & (
                            (1 << self.p) - 1
                        )
                        if (
                            self.get("fill_live_q") & (1 << slot)
                            and fill_address == address
                        ):
                            assert int(self.dut.home.fill_phase_q[slot].value) == 8, (
                                "grant offered before fill installation"
                            )
                    if self.get("home_g_ready"):
                        self.live[q] = (address, "G")
                        self.pf.append((self.cycle, "G", fields))
            if self.get("pf_c_valid") and self.get("c_ready") & 2:
                fields = unpack(self.get("pf_c"), (9, 6, self.p, 2, 1))
                q, _, address, status, write = fields
                assert self.live[q] == (address, "G")
                assert status in (0, 2) and write == 0
                grant = next(
                    f for _, k, f in reversed(self.pf) if k == "G" and f[1] == q
                )
                assert status == (2 if grant[5] else 0)
                self.live[q] = (address, "C")
                self.pf.append((self.cycle, "C", fields))
            if self.get("home_u_valid") and self.get("home_u_ready"):
                fields = unpack(self.get("home_u"), (9, 6, self.p))
                if fields[0] >> 5 == 15:
                    assert self.live.pop(fields[0]) == (fields[2], "C")
                    self.pf.append((self.cycle, "U", fields))
            self.max_live = max(self.max_live, len(self.live))
            self.max_fills = max(self.max_fills, self.get("fill_live_q").bit_count())
        await super().set(**values)

    async def prime(self, base: int, delay: int = 200) -> None:
        """Train on resident lines so all fill slots can belong to prefetches."""
        for address in (base, base + self.line):
            assert await self.read(address) == self.expected(address)
        self.required_fills.update(base + index * self.line for index in range(2, 10))
        self.read_delay = delay
        await self.set(i_train_enable=1)
        for address in (base, base + self.line):
            assert await self.read(address) == self.expected(address)
        await self.set(i_train_enable=0)

    async def until(self, condition: Any, limit: int = 4000) -> None:
        """Bound waits on tracked transactions and resource occupancy."""
        for _ in range(limit):
            if condition():
                return
            await self.tick()
        raise AssertionError(f"condition timed out at {self.cycle}: {self.live}")

    async def drain(self) -> None:
        """Finish the eight-line prediction window and all releases."""
        await self.until(lambda: len([1 for _, k, _ in self.pf if k == "U"]) == 8)
        assert not self.live
        assert not self.get("o_fatal")


@cocotb.test()
async def four_identities_delayed_completion(dut: Any) -> None:
    """Four fills wait for memory, G, C and U without identity recycling."""
    b = PrefetchHome(dut)
    await b.reset()
    await b.set(i_hold_pf_g=1, i_hold_pf_c=1, i_hold_pf_u=1)
    await b.prime(0x80000000)
    await b.until(lambda: len(b.live) == 4 and b.get("fill_live_q").bit_count() == 4)
    assert {q & 30 for q in b.live} == {0, 2, 4, 6}
    await b.tick(250)
    assert len(b.live) == 4 and all(phase == "D" for _, phase in b.live.values())
    await b.set(i_hold_pf_g=0)
    await b.until(lambda: all(phase == "G" for _, phase in b.live.values()))
    await b.tick(20)
    assert len(b.live) == 4
    await b.set(i_hold_pf_c=0)
    await b.until(lambda: all(phase == "C" for _, phase in b.live.values()))
    await b.tick(20)
    assert len(b.live) == 4
    await b.set(i_hold_pf_u=0)
    await b.drain()
    assert b.max_live == 4 and b.max_fills == 4


@cocotb.test()
async def errors_reset_and_fatal_stop(dut: Any) -> None:
    """Complete errored fills as Error and reset during held G, C and U."""
    b = PrefetchHome(dut)
    await b.reset()
    base = 0x80002000
    b.errors.add(base + 2 * b.line)
    await b.prime(base, 70)
    await b.drain()
    errors = [f for _, k, f in b.pf if k == "C" and f[3] == 2]
    assert len(errors) == 1 and errors[0][2] == base + 2 * b.line
    for hold in ("i_hold_pf_g", "i_hold_pf_c", "i_hold_pf_u"):
        b = PrefetchHome(dut)
        await b.reset()
        await b.set(**{hold: 1})
        await b.prime(base, 50)
        await b.until(lambda: len(b.live) == 4)
        await b.tick(100)
        await b.set(i_fatal_stop=1)
        accepted = len([1 for _, k, _ in b.pf if k == "D"])
        await b.set(i_train_enable=1)
        await b.tick(20)
        assert len([1 for _, k, _ in b.pf if k == "D"]) == accepted
        b = PrefetchHome(dut)
        await b.reset()
        await b.tick(100)
        assert not b.live and not b.pf and b.get("fill_live_q") == 0
        assert await b.read(base) == b.expected(base)


@cocotb.test()
async def demands_behind_full_prefetch_fills(dut: Any) -> None:
    """Same-line and unrelated demand readers progress behind four prefetches."""
    b = PrefetchHome(dut)
    await b.reset()
    base = 0x80004000
    await b.prime(base, 150)
    await b.until(lambda: b.get("fill_live_q").bit_count() == 4)
    addresses = (base + 2 * b.line, base + 0x1000)
    start = b.cycle
    for slot, address in enumerate(addresses):
        await b.submit(0, address, slot=slot)
    seen = set()
    for _ in addresses:
        grant = await b.take_grant()
        assert grant[3] in addresses and not grant[5]
        assert grant[4] == b.expected(grant[3])
        assert grant[3] not in seen
        seen.add(grant[3])
        await b.complete(grant)
    await b.drain()
    assert sum(a == addresses[0] and not w for _, w, a in b.transactions) == 1
    dut._log.info(
        "PREFETCH demand_pair_cycles=%d max_fills=%d", b.cycle - start, b.max_fills
    )


@cocotb.test()
async def dirty_victim_put_and_streaming_dma(dut: Any) -> None:
    """Prefetch recalls preserve PutM bytes and marked DMA uses only way zero."""
    b = PrefetchHome(dut)
    await b.reset()
    base = 0x80008000
    # Four sets contain dirty private sectors before the stream replaces ways.
    for index in range(16):
        address = base + index * b.line
        grant = await b.start(1, address)
        assert not grant[5]
        await b.finish(grant, written=True)
        b.private[address] = (3, (index + 1) * 0x0101010101010101)
    await b.prime(base + 0x1000, 80)
    await b.until(lambda: len(b.live) == 4)
    put_address = base + 15 * b.line
    put_data = b.private.pop(put_address)[1]
    b.frozen[0] = (put_address, put_data)
    await b.set(
        i_w_valid=1,
        i_w=pack((1, 0), (1, 0), (1, 0), (b.p, put_address), (256, put_data), (1, 0)),
    )
    for index in range(4):
        address = base + 0x2000 + index * 4 * b.line
        before = len(b.allocations)
        assert await b.read(address, 7, non_alloc=1) == b.expected(address)
        assert (address, 0) in b.allocations[before:]
        value = (index + 9) * 0x0101010101010101
        grant = await b.start(8, address, value, 0xFF, non_alloc=1)
        assert not grant[5]
        await b.finish(grant, written=True)
        assert (await b.read(address, 7)) & ((1 << 64) - 1) == value
    await b.drain()
    await b.until(lambda: not b.frozen and not b.responses)
    assert any(w for _, w, _ in b.transactions)
    assert b.dirty_prefetch_recalls and b.acks
    assert await b.read(put_address, 7) == put_data
    for index in range(15):
        address = base + index * b.line
        assert (await b.read(address, 7)) & ((1 << 64) - 1) == (
            index + 1
        ) * 0x0101010101010101


@cocotb.test()
async def full_completion_queue_progress(dut: Any) -> None:
    """Drain full completion, result, fill, writeback and PutM storage."""
    b = PrefetchHome(dut)
    await b.reset()
    base = 0x8000C000
    for index in range(16):
        address = base + index * b.line
        dirty = index % 4 < 2
        grant = await b.start(int(dirty), address)
        await b.finish(grant, written=dirty)
        if dirty:
            b.private[address] = (3, (index + 1) * 0x0101010101010101)
    stream = base + 0x1000
    for address in (stream, stream + b.line):
        assert await b.read(address) == b.expected(address)
    await b.until(lambda: not b.responses and b.get("wb_valid_q") == 0)
    b.required_fills.update(stream + index * b.line for index in range(2, 10))
    b.read_delay = 10000
    b.write_delay = 10000
    await b.set(i_hold_pf_g=1, i_train_enable=1)
    for address in (stream, stream + b.line):
        assert await b.read(address) == b.expected(address)
    await b.set(i_train_enable=0)
    await b.until(
        lambda: (
            b.get("fill_live_q").bit_count() == 4
            and b.get("wb_frozen_q").bit_count() == 2
        )
    )
    requests = (
        [(0, s) for s in range(8)]
        + [(5, 0), (5, 1), (6, 0)]
        + [(7, s) for s in range(4)]
    )
    ways = {(address // b.line % 4, way): address for address, way in b.allocations}
    resident = sorted(
        address
        for address in ways.values()
        if address in b.returned and b.private.get(address, (0, 0))[0] != 3
    )
    assert len(resident) == 8, resident
    addresses = resident + [base + 0x4000 + index * b.line for index in range(7)]
    expected = {}
    for (op, slot), address in zip(requests, addresses, strict=True):
        q, _ = b.demand(op, address, slot=slot)
        expected[q] = address
        await b.submit(op, address, slot=slot)
    await b.until(
        lambda: int(dut.home.completions.result_valid_q.value).bit_count() == 8
    )
    await b.set(i_wa_ready=0)
    puts = []
    private_addresses = [a for a, (state, _) in b.private.items() if state == 3]
    assert len(private_addresses) >= 2
    for slot, address in enumerate(private_addresses[:2]):
        data = b.private.pop(address)[1]
        puts.append((address, data))
        b.frozen[slot] = (address, data)
        await b.set(
            i_w_valid=1,
            i_w=pack((1, 0), (1, slot), (1, 0), (b.p, address), (256, data), (1, 0)),
        )
        await b.wait("o_w_ready")
        await b.tick()
    await b.until(lambda: b.get("put_busy_q").bit_count() == 2)
    assert int(dut.home.completions.live.value).bit_count() == 19
    assert int(dut.home.completions.result_valid_q.value).bit_count() == 8
    assert b.get("fill_live_q").bit_count() == 4
    assert b.get("wb_valid_q").bit_count() == 2
    assert b.get("put_busy_q").bit_count() == 2
    dut._log.info(
        "PREFETCH full queues: completions=19 results=8 fills=4 writebacks=2 puts=2"
    )
    b.responses = [(b.cycle + 20, *response[1:]) for response in b.responses]
    b.read_delay = 20
    b.write_delay = 40
    await b.set(i_hold_pf_g=0, i_wa_ready=1)
    for _ in requests:
        grant = await b.take_grant()
        address = expected.pop(grant[1])
        assert grant[3] == address and not grant[5]
        assert grant[4] == b.expected(address)
        await b.complete(grant)
    await b.drain()
    await b.until(lambda: not b.frozen and not b.responses)
    assert not expected and b.acks
    for address, data in puts:
        assert await b.read(address, 7) == data
