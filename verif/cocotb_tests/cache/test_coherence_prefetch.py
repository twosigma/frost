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
from cocotb_tests.cache.test_coherence_home import FILL_TID_BASE, Home, unpack

# The harness's data identities (PREFETCH_INFLIGHT) and the instruction
# table's identity after them.
DATA_IDS = 3
IF_ID = 3
READ_ONCE_IF = 5


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
        """Track prefetch protocol lifetimes and the fills they start."""
        super().__init__(HomeSignals(dut))
        self.fills = len(dut.home.fill_live_q)
        self.pf: list[tuple[int, str, tuple[int, ...]]] = []
        self.live: dict[int, tuple[int, str]] = {}
        self.returned: dict[int, int] = {}
        self.installed: dict[int, int] = {}
        self.max_live = 0
        self.max_fills = 0
        self.drops = 0
        self.dirty_prefetch_recalls: list[int] = []

    def get(self, name: str) -> int:
        """Expose home internals used by the shared memory responder."""
        signal = getattr(self.dut, name, None)
        if signal is None:
            signal = getattr(self.dut.home, name)
        return int(signal.value)

    def fill_address(self, slot: int) -> int:
        """Read a fill slot's line address."""
        return (self.get("fill_addr_q") >> (slot * self.p)) & ((1 << self.p) - 1)

    def lines(self, kind: str) -> list[int]:
        """Prefetched line addresses in the order of one protocol step."""
        return [f[2] if kind in "DCU" else f[3] for _, k, f in self.pf if k == kind]

    async def set(self, **values: int) -> None:
        """Sample protocol transfers immediately before each rising edge."""
        if values.get("i_clk") == 1 and not self.get("i_rst"):
            engines = len(self.dut.engine_idle)
            if self.get("array_updated"):
                slot = self.get("array_updated_token") - engines
                if (
                    0 <= slot < self.fills
                    and int(self.dut.home.fill_phase_q[slot].value) == 7
                ):
                    self.installed[self.fill_address(slot)] = self.cycle
            if self.get("i_r_valid") and self.get("o_r_ready"):
                reply = unpack(
                    self.get("i_r"), (2, 6, 1, 1, self.p, 2, 1, 1, 256, 1, 1, 1, 1, 1)
                )
                slot = reply[1] - FILL_TID_BASE
                if (
                    0 <= slot < self.fills
                    and reply[7]
                    and (self.get("fill_prefetch_q") >> slot) & 1
                ):
                    self.dirty_prefetch_recalls.append(reply[4])
            if self.get("i_mem_resp_valid"):
                rid = self.get("i_mem_resp_id")
                if rid < self.fills:
                    self.returned[self.fill_address(rid)] = self.cycle
            generate = getattr(self.dut.top, "gen_prefetch", None)
            if generate is not None:
                self.drops += int(generate.agent.data_drop.value) + int(
                    generate.agent.if_drop.value
                )
            if self.get("pf_d_valid") and self.get("d_ready") & 2:
                fields = unpack(
                    self.get("pf_d"), (4, 9, self.p, 5, 3, 32, 1, 1, 1, 256)
                )
                op, q, address = fields[:3]
                assert op == 9 and q >> 5 == 15
                assert address % self.line == 0 and fields[7] == 0
                assert q not in self.live, "identity reused before U"
                assert all(a != address for a, _ in self.live.values()), (
                    "two live identities hold one line"
                )
                self.live[q] = (address, "D")
                self.pf.append((self.cycle, "D", (q, 0, address)))
            if self.get("home_g_valid"):
                fields = unpack(self.get("home_g"), (3, 9, 6, self.p, 256, 1))
                if fields[1] >> 5 == 15:
                    q, address = fields[1], fields[3]
                    assert self.live[q] == (address, "D")
                    assert fields[0] == 4 and fields[4] == 0
                    # The home takes a source-3 G when it presents it.
                    assert self.get("home_g_ready")
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
        """Make two lines resident, then train on them as a stream."""
        for address in (base, base + self.line):
            assert await self.read(address) == self.expected(address)
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

    async def drain(self, count: int = 8) -> None:
        """Finish the prediction window's releases and every fill."""
        await self.until(lambda: len(self.lines("U")) >= count)
        await self.until(lambda: not self.live)
        await self.until(lambda: self.get("fill_live_q") == 0)
        assert not self.get("o_fatal")


@cocotb.test()
async def identities_and_held_completion(dut: Any) -> None:
    """Hold data identities at C and U without reuse, then check their fills."""
    b = PrefetchHome(dut)
    await b.reset()
    base = 0x80000000
    await b.set(i_hold_pf_c=1, i_hold_pf_u=1)
    await b.prime(base)
    await b.until(
        lambda: (
            len(b.live) == DATA_IDS
            and all(phase == "G" for _, phase in b.live.values())
        )
    )
    assert {(q >> 1) & 15 for q in b.live} == set(range(DATA_IDS))
    await b.tick(250)
    assert len(b.live) == DATA_IDS
    assert all(phase == "G" for _, phase in b.live.values())
    await b.set(i_hold_pf_c=0)
    await b.until(lambda: all(phase == "C" for _, phase in b.live.values()))
    await b.tick(20)
    assert len(b.live) == DATA_IDS
    await b.set(i_hold_pf_u=0)
    await b.drain()
    predicted = [base + index * b.line for index in range(2, 10)]
    assert b.lines("D") == predicted
    assert b.max_live == DATA_IDS
    # The home grants each Prefetch at its lookup, before the fill's memory
    # response, so the fill goes on whether or not its identity is live.
    # Every fill installs after that response, and later demands read the
    # line without memory traffic.
    grants = {f[3]: cycle for cycle, k, f in b.pf if k == "G"}
    for address in predicted:
        assert grants[address] < b.returned[address]
        assert b.installed[address] >= b.returned[address]
        assert b.reads_of(address) == 1
        assert await b.read(address) == b.expected(address)
        assert b.reads_of(address) == 1


@cocotb.test()
async def errors_reset_and_fatal_stop(dut: Any) -> None:
    """Install nothing for a failed fill; reset and stop with prefetches held."""
    b = PrefetchHome(dut)
    await b.reset()
    base = 0x80002000
    failed = base + 2 * b.line
    b.errors.add(failed)
    await b.prime(base, 70)
    await b.drain()
    # The home answers the prefetch at its lookup; the fill's error frees the
    # fill without an install, and the identity completes with Consumed.
    assert all(f[3] == 0 for _, k, f in b.pf if k == "C")
    prefetched = set(b.lines("D"))
    assert failed in prefetched and failed in b.returned
    assert failed not in b.installed and set(b.installed) & prefetched
    for hold in ("i_hold_pf_c", "i_hold_pf_u"):
        b = PrefetchHome(dut)
        await b.reset()
        await b.set(**{hold: 1})
        await b.prime(base, 50)
        await b.until(lambda: len(b.live) == DATA_IDS)
        await b.tick(100)
        await b.set(i_fatal_stop=1)
        accepted = len(b.lines("D"))
        await b.set(i_train_enable=1)
        await b.tick(20)
        assert len(b.lines("D")) == accepted
        b = PrefetchHome(dut)
        await b.reset()
        await b.tick(100)
        assert not b.live and not b.pf and b.get("fill_live_q") == 0
        assert await b.read(base) == b.expected(base)


@cocotb.test()
async def demands_join_prefetch_fills(dut: Any) -> None:
    """Join a demand to a pending prefetch fill beside an unrelated demand."""
    b = PrefetchHome(dut)
    await b.reset()
    base = 0x80004000
    await b.prime(base, 150)
    await b.until(lambda: b.get("fill_live_q").bit_count() >= DATA_IDS)
    joined = base + 2 * b.line
    addresses = (joined, base + 0x1000)
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
    assert b.reads_of(joined) == 1
    dut._log.info(
        "PREFETCH demand_pair_cycles=%d max_fills=%d", b.cycle - start, b.max_fills
    )


@cocotb.test()
async def dirty_victim_put_and_streaming_dma(dut: Any) -> None:
    """Prefetch recalls keep PutM bytes and marked DMA uses only way zero."""
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
    await b.until(lambda: len(b.live) == DATA_IDS)
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
async def put_passes_live_prefetches_of_its_line(dut: Any) -> None:
    """Accept a waiting PutM while prefetches of its line stay live."""
    b = PrefetchHome(dut)
    await b.reset()
    base = 0x80018000
    for address in (base, base + b.line):
        assert await b.read(address) == b.expected(address)
    # The hart holds the next three lines Modified.
    targets = [base + index * b.line for index in range(2, 2 + DATA_IDS)]
    for index, address in enumerate(targets):
        grant = await b.start(1, address, slot=index)
        await b.finish(grant, written=True)
        b.private[address] = (3, (index + 1) * 0x1111)
    # Each prefetch of them hits and waits at C, keeping its identity live.
    await b.set(i_hold_pf_c=1, i_train_enable=1)
    for address in (base, base + b.line):
        assert await b.read(address) == b.expected(address)
    await b.set(i_train_enable=0)
    await b.until(
        lambda: (
            sorted(a for a, _ in b.live.values()) == targets
            and all(phase == "G" for _, phase in b.live.values())
        )
    )
    for slot, address in enumerate(targets[:2]):
        data = b.private.pop(address)[1]
        b.frozen[slot] = (address, data)
        await b.set(
            i_w_valid=1,
            i_w=pack((1, 0), (1, slot), (1, 0), (b.p, address), (256, data), (1, 0)),
        )
        await b.until(lambda: slot in b.accepted_puts or slot not in b.frozen, 200)
        await b.until(lambda: slot not in b.frozen, 200)
    assert sorted(a for a, _ in b.live.values()) == targets
    await b.set(i_hold_pf_c=0)
    await b.until(lambda: not b.live)
    for index, address in enumerate(targets[:2]):
        assert (await b.read(address, 7)) & 0xFFFF == (index + 1) * 0x1111


@cocotb.test()
async def dma_response_before_delayed_completion(dut: Any) -> None:
    """Read responses allow admission during held DMA C/U; writes wait for U."""
    for write in (False, True):
        for hold in ("C", "U"):
            b = PrefetchHome(dut)
            await b.reset()
            base = 0x80010000
            address = base + 0x1000
            for resident in (address, base, base + b.line):
                assert await b.read(resident) == b.expected(resident)
            b.read_delay = 100
            await b.submit(8 if write else 7, address, 0x1234, 0xFF, non_alloc=1)
            grant = await b.take_grant()
            assert grant[3] == address and not grant[5]
            assert not b.get("dma_response_q")
            await b.tick()
            assert b.get("dma_response_q") == int(not write)
            await b.tick()
            assert not b.get("dma_response_q")
            assert b.get("dma_pause")
            if hold == "U":
                await b.set(
                    i_c_valid=1,
                    i_c=pack(
                        (9, grant[1]),
                        (6, grant[2]),
                        (b.p, address),
                        (2, 0),
                        (1, int(write)),
                    ),
                )
                await b.wait("o_c_ready")
                await b.tick()
                await b.set(i_c_valid=0)
                await b.wait("o_u_valid")
            training_grants = []
            await b.set(i_train_enable=1)
            for slot in range(2):
                await b.submit(0, base + slot * b.line, slot=slot)
                training_grants.append(await b.take_grant())
            await b.set(i_train_enable=0)
            await b.tick(20)
            accepted = len(b.lines("D"))
            if write:
                assert b.get("dma_pause")
                assert accepted == 0
                await b.tick(150)
                assert b.get("dma_pause")
                assert len(b.lines("D")) == accepted
            else:
                assert not b.get("dma_pause")
                await b.until(lambda: bool(b.lines("D")))
                assert not b.get("dma_pause")
            if hold == "C":
                assert not b.get("o_u_valid")
                await b.complete(grant, written=write)
            else:
                assert b.get("o_u_valid")
                assert unpack(b.get("o_u"), (9, 6, b.p)) == (
                    grant[1],
                    grant[2],
                    address,
                )
                await b.set(i_u_ready=1)
                await b.tick()
                await b.set(i_u_ready=0)
            assert b.get("dma_response_q") == int(write)
            for training_grant in training_grants:
                await b.complete(training_grant)
            await b.until(lambda: not b.get("dma_pause"))
            await b.drain()


@cocotb.test()
async def full_completion_queue_progress(dut: Any) -> None:
    """Drain full hart and DMA slots, results and PutM with prefetches held."""
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
    b.read_delay = 10000
    b.write_delay = 10000
    # Prefetch identities wait at C, so their completion slots stay live.
    await b.set(i_hold_pf_c=1, i_train_enable=1)
    for address in (stream, stream + b.line):
        assert await b.read(address) == b.expected(address)
    await b.set(i_train_enable=0)
    await b.until(lambda: len(b.live) == DATA_IDS)
    requests = (
        [(0, s) for s in range(8)]
        + [(5, 0), (5, 1), (6, 0)]
        + [(7, s) for s in range(8)]
    )
    # The line in each way: resident, clean and returned lines hit.
    ways = {(address // b.line % 4, way): address for address, way in b.allocations}
    resident = sorted(
        address
        for address in ways.values()
        if address in b.returned and b.private.get(address, (0, 0))[0] != 3
    )[:8]
    addresses = resident + [
        base + 0x4000 + index * b.line for index in range(len(requests) - len(resident))
    ]
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
    live = int(dut.home.completions.live.value).bit_count()
    assert live == len(requests) + DATA_IDS
    assert int(dut.home.completions.result_valid_q.value).bit_count() == 8
    assert b.get("put_busy_q").bit_count() == 2
    dut._log.info(
        "PREFETCH full queues: completions=%d results=8 fills=%d writebacks=%d puts=2",
        live,
        b.get("fill_live_q").bit_count(),
        b.get("wb_valid_q").bit_count(),
    )
    b.responses = [(b.cycle + 20, *response[1:]) for response in b.responses]
    b.read_delay = 20
    b.write_delay = 40
    await b.set(i_hold_pf_c=0, i_wa_ready=1)
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


@cocotb.test()
async def instruction_and_data_streams_share_no_line(dut: Any) -> None:
    """Train instruction refills on their own table and identity.

    No line is requested twice while an identity holds it.
    """
    b = PrefetchHome(dut)
    await b.reset()
    base = 0x80014000
    for address in (base, base + b.line):
        assert await b.read(address) == b.expected(address)
    # Both tables train on the same two lines while prefetches wait at C.
    await b.set(i_hold_pf_c=1, i_train_enable=1)
    for address in (base, base + b.line):
        assert await b.read(address) == b.expected(address)
    await b.until(lambda: len(b.live) == DATA_IDS)
    for address in (base, base + b.line):
        assert await b.read(address, READ_ONCE_IF) == b.expected(address)
    await b.set(i_train_enable=0)
    # The instruction table drops the lines the data identities hold and
    # takes its own identity for the next line.
    await b.until(lambda: len(b.live) == DATA_IDS + 1)
    held = {q: address for q, (address, _) in b.live.items()}
    instruction_q = pack((2, 3), (2, 3), (4, IF_ID), (1, 0))
    assert held[instruction_q] == base + (2 + DATA_IDS) * b.line
    assert b.drops >= DATA_IDS
    assert len(set(held.values())) == len(held)
    await b.set(i_hold_pf_c=0)
    await b.drain()
