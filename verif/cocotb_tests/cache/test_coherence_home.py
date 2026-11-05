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

"""Exercise the home with independent hart and memory responders."""

from typing import Any

import cocotb
from cocotb.triggers import Timer

from cocotb_tests.cache.test_coherence_endpoints import pack

# The first fill TID, coherence_pkg::fill_base(1): one per completion slot
# (11 per hart, 8 DMA credits and 4 prefetch identities) comes first.
FILL_TID_BASE = 23
PREFETCH = 9
GRANT_ACK = 4


def unpack(value: int, widths: tuple[int, ...]) -> tuple[int, ...]:
    """Decode fields in their declared order."""
    fields = []
    for width in reversed(widths):
        fields.append(value & ((1 << width) - 1))
        value >>= width
    assert value == 0
    return tuple(reversed(fields))


class Home:
    """Drive a private cache and memory with independently delayed replies."""

    def __init__(self, dut: Any) -> None:
        """Track data ownership and every external handshake."""
        self.dut = dut
        self.p = len(dut.i_d) - 312
        self.line = len(dut.i_mem_resp_data) // 8
        self.cycle = 0
        self.memory: dict[int, int] = {}
        self.private: dict[int, tuple[int, int]] = {}
        self.frozen: dict[int, tuple[int, int]] = {}
        self.accepted_puts: set[int] = set()
        self.probes: list[tuple[int, int, int, int]] = []
        self.transactions: list[tuple[int, int, int]] = []
        self.acks: list[tuple[int, ...]] = []
        self.read_delay = 3
        self.write_delay = 40
        self.probe_delay = 2
        self.reservation = False
        self.errors: set[int] = set()
        self.probe_errors: set[int] = set()
        self.responses: list[tuple[int, int, int, int, int, bool]] = []
        self.replies: list[tuple[int, int]] = []
        self.arrivals: list[tuple[int, str, int]] = []
        self.write_fills = 0
        self.allocations: list[tuple[int, int]] = []
        # Grants for source 3, which the bench takes when they are presented,
        # as the prefetcher does.
        self.prefetch_grants: list[tuple[int, ...]] = []

    def get(self, name: str) -> int:
        """Read a signal."""
        return int(getattr(self.dut, name).value)

    async def set(self, **values: int) -> None:
        """Set inputs before sampling handshakes."""
        for name, value in values.items():
            getattr(self.dut, name).value = value
        await Timer(1, unit="ns")

    def initial(self, address: int) -> int:
        """Give each byte a deterministic address-dependent value."""
        return int.from_bytes(
            bytes(((address >> 5) + i * 17) & 255 for i in range(self.line)), "little"
        )

    def expected(self, address: int) -> int:
        """Read the memory model's addressed sector."""
        base = address & -self.line
        data = self.memory.get(base, self.initial(base))
        return (data >> (8 * (address - base))) & ((1 << 256) - 1)

    async def reset(self) -> None:
        """Reset all ownership and wait for tag initialization."""
        self.accepted_puts.clear()
        for signal in self.dut:
            if signal._name.startswith("i_"):
                signal.value = 0
        await self.set(i_rst=1)
        await self.tick(2)
        await self.set(i_rst=0, i_p_ready=1, i_wa_ready=1, i_mem_req_ready=1)
        await self.tick(20)

    async def tick(self, count: int = 1) -> None:
        """Advance clocks while independently servicing probes and memory."""
        for _ in range(count):
            next_put = None
            drop_put = False
            memory = next((r for r in self.responses if r[0] <= self.cycle), None)
            reply = (
                self.replies[0]
                if self.replies and self.replies[0][0] <= self.cycle
                else None
            )
            await self.set(
                i_clk=0,
                i_mem_resp_valid=int(memory is not None),
                i_mem_resp_id=memory[1] if memory else 0,
                i_mem_resp_data=memory[2] if memory else 0,
                i_mem_resp_error=memory[3] if memory else 0,
                i_r_valid=int(reply is not None),
                i_r=reply[1] if reply else 0,
            )
            if memory:
                self.responses.remove(memory)
                if memory[5] and not memory[3]:
                    self.memory[memory[4]] = memory[2]
            if self.get("array_data_valid"):
                token = self.get("array_data_token")
                engines = len(self.dut.engine_idle)
                tid = (
                    (self.get("engine_tid") >> (6 * token)) & 63
                    if token < engines
                    else FILL_TID_BASE + token - engines
                )
                self.arrivals.append((self.cycle, "data", tid))
            if self.get("array_response") and self.get("decision_fill"):
                self.allocations.append(
                    (self.get("array_query"), self.get("array_way"))
                )
            if reply and self.get("o_r_ready"):
                tid = unpack(
                    reply[1], (2, 6, 1, 1, self.p, 2, 1, 1, 256, 1, 1, 1, 1, 1)
                )[1]
                self.arrivals.append((self.cycle, "reply", tid))
                self.replies.pop(0)
            if self.get("o_p_valid") and self.get("i_p_ready"):
                op, tid, epoch, address, requester, reason, q, offset, size = unpack(
                    self.get("o_p"), (2, 6, 1, self.p, 2, 2, 9, 5, 3)
                )
                self.probes.append((op, address, reason, tid))
                state, data = self.private.get(address, (0, 0))
                slot = next(
                    (s for s, item in self.frozen.items() if item[0] == address), None
                )
                absorbed = slot is not None and op != 2
                if absorbed:
                    assert slot not in self.accepted_puts, (
                        "probe crossed an accepted Put"
                    )
                dirty = (state == 3 or absorbed) and op != 2
                if absorbed:
                    assert slot is not None
                    data = self.frozen[slot][1]
                if op != 2:
                    self.private[address] = (
                        0 if op == 1 else (2 if state else 0),
                        data,
                    )
                resulting_state = self.private.get(address, (0, 0))[0]
                response = pack(
                    (2, 2 if op == 2 else int(dirty)),
                    (6, tid),
                    (1, epoch),
                    (1, 0),
                    (self.p, address),
                    (2, resulting_state),
                    (1, 0),
                    (1, int(dirty)),
                    (256, data if dirty else 0),
                    (1, int(absorbed)),
                    (1, slot or 0),
                    (1, epoch),
                    (1, int(self.reservation)),
                    (1, int(address in self.probe_errors)),
                )
                self.replies.append((self.cycle + self.probe_delay, response))
            if self.get("o_wa_valid") and self.get("i_wa_ready"):
                ack = unpack(self.get("o_wa"), (1, 1, 1, self.p, 1, 6, 1))
                self.acks.append(ack)
                if ack[1] in self.frozen:
                    assert self.frozen[ack[1]][0] == ack[3]
                    del self.frozen[ack[1]]
                self.accepted_puts.discard(ack[1])
                if ack[4]:
                    if self.frozen:
                        slot, (address, data) = next(iter(self.frozen.items()))
                        next_put = pack(
                            (1, 0),
                            (1, slot),
                            (1, 0),
                            (self.p, address),
                            (256, data),
                            (1, 0),
                        )
                    else:
                        drop_put = True
            if self.get("i_w_valid") and self.get("o_w_ready"):
                packet = unpack(self.get("i_w"), (1, 1, 1, self.p, 256, 1))
                self.accepted_puts.add(packet[1])
                drop_put = True
            if self.get("o_mem_req_valid") and self.get("i_mem_req_ready"):
                address = self.get("o_mem_req_addr")
                write = bool(self.get("o_mem_req_write"))
                data = (
                    self.get("o_mem_req_data")
                    if write
                    else self.memory.get(address, self.initial(address))
                )
                delay = self.write_delay if write else self.read_delay
                self.transactions.append((self.cycle, int(write), address))
                self.responses.append(
                    (
                        self.cycle + delay,
                        self.get("o_mem_req_id"),
                        data,
                        int(address in self.errors),
                        address,
                        write,
                    )
                )
            grant = unpack(self.get("o_g"), (3, 9, 6, self.p, 256, 1))
            prefetch_grant = bool(self.get("o_g_valid")) and grant[1] >> 7 == 3
            held_ready = self.get("i_g_ready")
            if prefetch_grant:
                self.prefetch_grants.append(grant)
                await self.set(i_g_ready=1)
            await self.set(i_clk=1)
            await self.set(i_clk=0)
            if prefetch_grant:
                await self.set(i_g_ready=held_ready)
            if not self.get("i_rst"):
                self.write_fills += (self.get("o_write_perf_events") >> 7) & 1
            if next_put is not None:
                await self.set(i_w_valid=1, i_w=next_put)
            elif drop_put:
                await self.set(i_w_valid=0)
            self.cycle += 1

    def demand(
        self,
        op: int,
        address: int,
        data: int = 0,
        mask: int = 0,
        slot: int = 0,
        non_alloc: int = 0,
    ) -> tuple[int, int]:
        """Encode hart or agent requests with disjoint source identities."""
        if op in (7, 8):
            q = pack((2, 2), (2, 3), (4, (9 + slot) % 16), (1, 0))
        elif op == PREFETCH:
            q = pack((2, 3), (2, 3), (4, slot), (1, 0))
        elif op in (5, 6):
            q = pack((2, 0), (2, op - 4), (4, slot), (1, 0))
        else:
            q = slot << 1
        return q, pack(
            (4, op),
            (9, q),
            (self.p, address),
            (5, 0),
            (3, 5 if op in (7, 8, PREFETCH) else 3),
            (32, mask),
            (1, 0),
            (1, non_alloc),
            (1, 0),
            (256, data),
        )

    async def wait(self, signal: str, limit: int = 2000) -> None:
        """Fail a stalled protocol with its visible state."""
        for _ in range(limit):
            if self.get(signal):
                return
            await self.tick()
        raise AssertionError(
            f"{signal} timed out at {self.cycle}; fatal={self.get('o_fatal')}"
        )

    async def submit(
        self,
        op: int,
        address: int,
        data: int = 0,
        mask: int = 0,
        slot: int = 0,
        non_alloc: int = 0,
    ) -> None:
        """Admit a request without waiting for grant service."""
        _, request = self.demand(op, address, data, mask, slot, non_alloc)
        await self.set(i_d_valid=1, i_d=request)
        await self.wait("o_d_ready")
        await self.tick()
        await self.set(i_d_valid=0)

    async def start(
        self,
        op: int,
        address: int,
        data: int = 0,
        mask: int = 0,
        slot: int = 0,
        non_alloc: int = 0,
    ) -> tuple[int, ...]:
        """Accept one request and leave its grant held at the home."""
        await self.submit(op, address, data, mask, slot, non_alloc)
        await self.wait("o_g_valid")
        return unpack(self.get("o_g"), (3, 9, 6, self.p, 256, 1))

    async def take_grant(self) -> tuple[int, ...]:
        """Consume one grant while keeping its completion outstanding.

        Grants for source 3 are taken by tick() and never returned here.
        """
        for _ in range(2000):
            grant = unpack(self.get("o_g"), (3, 9, 6, self.p, 256, 1))
            if self.get("o_g_valid") and grant[1] >> 7 != 3:
                break
            await self.tick()
        else:
            raise AssertionError(f"o_g_valid timed out at {self.cycle}")
        await self.set(i_g_ready=1)
        await self.tick()
        await self.set(i_g_ready=0)
        return grant

    async def finish(
        self,
        grant: tuple[int, ...],
        written: bool = False,
        delay: int = 0,
        completion_delay: int = 0,
        release_delay: int = 0,
    ) -> None:
        """Grant, completion and release each permit independent backpressure."""
        payload = self.get("o_g")
        for _ in range(delay):
            await self.tick()
            assert self.get("o_g_valid") and self.get("o_g") == payload
        await self.set(i_g_ready=1)
        await self.tick()
        await self.set(i_g_ready=0)
        await self.complete(grant, written, completion_delay, release_delay)

    async def complete(
        self,
        grant: tuple[int, ...],
        written: bool = False,
        completion_delay: int = 0,
        release_delay: int = 0,
    ) -> None:
        """Complete an accepted grant and return its exact identity."""
        for _ in range(completion_delay):
            await self.tick()
            assert not self.get("o_d_ready")
        await self.set(
            i_c_valid=1,
            i_c=pack(
                (9, grant[1]),
                (6, grant[2]),
                (self.p, grant[3]),
                (2, 2 if grant[5] else 0),
                (1, int(written)),
            ),
        )
        await self.wait("o_c_ready")
        await self.tick()
        await self.set(i_c_valid=0)
        await self.wait("o_u_valid")
        release = self.get("o_u")
        for _ in range(release_delay):
            await self.tick()
            assert self.get("o_u_valid") and self.get("o_u") == release
            assert not self.get("o_d_ready")
        await self.set(i_u_ready=1)
        await self.tick()
        await self.set(i_u_ready=0)

    async def prefetch_grant(self, address: int, slot: int = 0) -> tuple[int, ...]:
        """Wait for the grant of an admitted Prefetch, taken when presented."""
        q = self.demand(PREFETCH, address, slot=slot)[0]
        for _ in range(2000):
            grant = next(
                (g for g in self.prefetch_grants if g[1] == q and g[3] == address), None
            )
            if grant is not None:
                self.prefetch_grants.remove(grant)
                assert grant[0] == GRANT_ACK and grant[4] == 0 and grant[5] == 0
                return grant
            await self.tick()
        raise AssertionError(f"prefetch grant for {address:#x} timed out")

    async def prefetch(
        self, address: int, slot: int = 0, finish: bool = True
    ) -> tuple[int, ...]:
        """Admit a Prefetch and, unless asked not to, complete and release it."""
        await self.submit(PREFETCH, address, slot=slot)
        grant = await self.prefetch_grant(address, slot)
        if finish:
            await self.complete(grant)
        return grant

    async def fills_live(self, count: int) -> None:
        """Wait until a number of fills are live."""
        for _ in range(500):
            if int(self.dut.fill_live_q.value).bit_count() == count:
                return
            await self.tick()
        raise AssertionError(f"{count} fills did not become live")

    def reads_of(self, address: int) -> int:
        """Count the memory reads of the line holding an address."""
        line = address & -self.line
        return len([t for t in self.transactions if not t[1] and t[2] == line])

    async def read(self, address: int, op: int = 0, non_alloc: int = 0) -> int:
        """Complete a read request."""
        grant = await self.start(op, address, non_alloc=non_alloc)
        assert grant[5] == 0
        await self.finish(grant)
        return grant[4]


@cocotb.test()
async def streaming_residency_and_dirty_hits(dut: Any) -> None:
    """Streaming misses preserve three ways and hits merge dirty private bytes."""
    for non_alloc in (0, 1):
        b = Home(dut)
        await b.reset()
        base = 0x80000000
        stride = 4 * b.line
        for index in range(4):
            address = base + index * stride
            assert await b.read(address) == b.expected(address)
        protected = [address for address, way in b.allocations if way != 0]
        assert len(protected) == 3
        initial_fills = len(b.allocations)
        start = b.cycle
        for index in range(8, 16):
            address = base + index * stride
            assert await b.read(address, 7, non_alloc) == b.expected(address)
        stream_cycles = b.cycle - start
        stream_fills = b.allocations[initial_fills:]
        assert len(stream_fills) == 8
        if non_alloc:
            assert all(way == 0 for _, way in stream_fills)
        before = len(b.allocations)
        start = b.cycle
        for address in protected:
            assert await b.read(address) == b.expected(address)
        misses = len(b.allocations) - before
        dut._log.info(
            "streaming policy=%d dma_cycles=%d hot_read_cycles=%d hot_refills=%d",
            non_alloc,
            stream_cycles,
            b.cycle - start,
            misses,
        )
        assert misses == (0 if non_alloc else 3)
        if not non_alloc:
            continue
        address = protected[0]
        dirty = int.from_bytes(bytes(range(32)), "little")
        b.private[address] = (3, dirty)
        assert await b.read(address, 7, 1) == dirty
        assert b.private[address][0] == 2
        dirty = int.from_bytes(bytes(range(32, 64)), "little")
        b.private[address] = (3, dirty)
        mask = 0x80000181
        grant = await b.start(8, address, (1 << 256) - 1, mask, non_alloc=1)
        assert not grant[5]
        await b.finish(grant)
        expected = bytearray(dirty.to_bytes(32, "little"))
        for index in range(32):
            if mask & (1 << index):
                expected[index] = 255
        assert await b.read(address) == int.from_bytes(expected, "little")
        assert b.private[address][0] == 0
        assert len(b.allocations) == before
        address = base + 32 * stride
        expected = bytearray(b.expected(address).to_bytes(32, "little"))
        for index in range(32):
            if mask & (1 << index):
                expected[index] = 255
        grant = await b.start(8, address, (1 << 256) - 1, mask, non_alloc=1)
        assert not grant[5]
        await b.finish(grant)
        assert b.allocations[before:] == [(address & -b.line, 0)]
        assert await b.read(address) == int.from_bytes(expected, "little")
        for hot in protected[1:]:
            assert await b.read(hot) == b.expected(hot)
        assert len(b.allocations) == before + 1


@cocotb.test()
async def streaming_waits_for_its_pinned_way(dut: Any) -> None:
    """Keep one set waiting for its streaming way while another completes."""
    b = Home(dut)
    await b.reset()
    base = 0x80000000
    await b.submit(7, base, non_alloc=1)
    held = await b.take_grant()
    assert b.allocations == [(base, 0)]
    await b.submit(7, base + 4 * b.line, slot=1, non_alloc=1)
    await b.tick(100)
    assert not b.get("o_g_valid") and b.allocations == [(base, 0)]
    await b.submit(7, base + b.line, slot=2, non_alloc=1)
    unrelated = await b.take_grant()
    assert unrelated[3] == base + b.line and not unrelated[5]
    await b.complete(unrelated)
    await b.complete(held)
    waiting = await b.take_grant()
    assert waiting[3] == base + 4 * b.line and not waiting[5]
    await b.complete(waiting)
    assert all(way == 0 for _, way in b.allocations)


@cocotb.test()
async def streaming_waits_for_way_zero_beside_a_prefetch_fill(dut: Any) -> None:
    """Check streaming stalls beside a prefetch while way zero is pinned."""
    b = Home(dut)
    await b.reset()
    base = 0x80000000
    stride = 4 * b.line
    await b.submit(7, base, non_alloc=1)
    held = await b.take_grant()
    assert held[4] == b.expected(base) and not held[5]
    assert b.allocations == [(base, 0)]

    b.read_delay = 800
    prefetched = base + stride
    await b.prefetch(prefetched)
    await b.fills_live(1)
    assert b.reads_of(prefetched) == 1
    assert b.allocations[-1][0] == prefetched and b.allocations[-1][1] != 0

    waiting_address = base + 2 * stride
    await b.submit(7, waiting_address, slot=1, non_alloc=1)
    await b.tick(40)
    assert not b.get("o_g_valid") and b.reads_of(waiting_address) == 0
    assert int(dut.fill_live_q.value).bit_count() == 1

    b.read_delay = 3
    unrelated_address = base + b.line
    await b.submit(7, unrelated_address, slot=2, non_alloc=1)
    unrelated = await b.take_grant()
    assert unrelated[3] == unrelated_address and not unrelated[5]
    assert unrelated[4] == b.expected(unrelated_address)
    await b.complete(unrelated)
    assert b.reads_of(waiting_address) == 0

    await b.complete(held)
    waiting = await b.take_grant()
    assert waiting[3] == waiting_address and not waiting[5]
    assert waiting[4] == b.expected(waiting_address)
    await b.complete(waiting)
    assert int(dut.fill_live_q.value).bit_count() == 1
    assert all(way == 0 for address, way in b.allocations if address != prefetched)

    await b.tick(820)
    assert not int(dut.fill_live_q.value)
    before = len(b.allocations)
    assert await b.read(prefetched, 7, non_alloc=1) == b.expected(prefetched)
    assert b.reads_of(prefetched) == 1 and len(b.allocations) == before
    assert not b.get("o_fatal")


@cocotb.test()
async def dirty_data_and_dma_masks(dut: Any) -> None:
    """Dirty private bytes reach the L2 before DMA reads or masked writes."""
    b = Home(dut)
    await b.reset()
    address = 0x80000000
    grant = await b.start(1, address)
    assert grant[0] == 2 and grant[4] == b.expected(address)
    dirty = int.from_bytes(bytes(range(32)), "little")
    b.private[address] = (3, dirty)
    await b.finish(grant, written=True, delay=9, completion_delay=11, release_delay=13)
    assert await b.read(address, 7) == dirty
    assert b.private[address][0] == 2
    assert await b.read(address, 7) == dirty
    payload = (1 << 256) - 1
    mask = 0x80000181
    grant = await b.start(8, address, payload, mask)
    assert grant[0] == 4
    await b.finish(grant)
    expected = bytearray(dirty.to_bytes(32, "little"))
    for index in range(32):
        if mask & (1 << index):
            expected[index] = 255
    assert await b.read(address) == int.from_bytes(expected, "little")
    assert b.private[address][0] == 0
    assert await b.read(address, 7) == int.from_bytes(expected, "little")


@cocotb.test()
async def dma_read_fill_and_dirty_residency(dut: Any) -> None:
    """Read fills and dirty recalls survive clean reads and later eviction."""
    b = Home(dut)
    await b.reset()
    address = 0x80000000
    initial = b.expected(address)
    assert await b.read(address, 7) == initial
    assert await b.read(address, 7) == initial
    dirty = int.from_bytes(
        bytes((index * 29 + 3) & 255 for index in range(32)), "little"
    )
    b.private[address] = (3, dirty)
    assert await b.read(address, 7) == dirty
    assert b.private[address][0] == 2
    assert await b.read(address, 7) == dirty
    for index in range(1, 9):
        await b.read(address + index * 4096, 7)
    await b.tick(b.write_delay + 2)
    assert b.expected(address) == dirty
    assert await b.read(address, 7) == dirty


@cocotb.test()
async def masked_dma_writes_preserve_dirty_and_sibling_bytes(dut: Any) -> None:
    """Masked writes preserve private dirty bytes and the other shared sector."""
    b = Home(dut)
    await b.reset()
    base = 0x80000000
    expected = {}
    for sector in range(2):
        address = base + 32 * sector
        expected[address] = b.expected(address)
        assert await b.read(address, 7) == expected[address]
    for dirty in (False, True):
        for sector in range(2):
            address = base + 32 * sector
            if dirty:
                grant = await b.start(1, address)
                expected[address] = int.from_bytes(
                    bytes((17 * index + sector + 41) & 255 for index in range(32)),
                    "little",
                )
                b.private[address] = (3, expected[address])
                await b.finish(grant, written=True)
            for mask in (1, 0x80000000, 0xA5A55A5A, 0xFFFFFFFF):
                payload = int.from_bytes(
                    bytes((index * 13 + mask) & 255 for index in range(32)), "little"
                )
                grant = await b.start(8, address, payload, mask)
                assert grant[0] == 4 and grant[4] == 0
                await b.finish(grant, delay=3, completion_delay=2, release_delay=3)
                merged = bytearray(expected[address].to_bytes(32, "little"))
                for index in range(32):
                    if mask & (1 << index):
                        merged[index] = (payload >> (8 * index)) & 255
                expected[address] = int.from_bytes(merged, "little")
                for target, value in expected.items():
                    assert await b.read(target, 7) == value
    for row in sorted({address & -b.line for address in expected}):
        for index in range(1, 9):
            await b.read(row + index * 4096, 7)
    await b.tick(b.write_delay + 2)
    for target, value in expected.items():
        assert b.expected(target) == value
        assert await b.read(target, 7) == value


@cocotb.test()
async def recall_all_sectors_and_keep_victim_lock(dut: Any) -> None:
    """Check all-sector recall and refetch ordering through B."""
    b = Home(dut)
    await b.reset()
    addresses = [0x80000000 + n * b.line * 4 for n in range(9)]
    for index, address in enumerate(addresses[:4]):
        grant = await b.start(1, address)
        b.private[address] = (3, 0xBEEF0000 + index)
        if b.line == 64:
            b.private[address + 32] = (2, b.expected(address + 32))
        await b.finish(grant, written=True)
    b.write_delay = 150
    for address in addresses[4:]:
        await b.read(address)
    recalled = {a for _, a, reason, _ in b.probes if reason == 2}
    for address in addresses[:4]:
        assert address in recalled
        if b.line == 64:
            assert address + 32 in recalled
    for index, address in enumerate(addresses[:4]):
        assert await b.read(address, 7) == 0xBEEF0000 + index
    for index, (_, write, address) in enumerate(b.transactions):
        if write:
            start = b.transactions[index][0]
            later_reads = [
                cycle
                for cycle, w, a in b.transactions[index + 1 :]
                if not w and a == address
            ]
            assert not later_reads or later_reads[0] >= start + b.write_delay


@cocotb.test()
async def absorbed_put_cancellation_and_sc_entitlement(dut: Any) -> None:
    """Absorbed data stays owned through cancellation and SC checks precede self reads."""
    b = Home(dut)
    await b.reset()
    address = 0x80000000
    await b.read(address)
    await b.read(address + 32)
    b.frozen[0] = (address + 32, 0xFEED0001)
    b.frozen[1] = (address, 0x9876543210)
    _, request = b.demand(7, address)
    await b.set(i_d_valid=1, i_d=request)
    await b.wait("o_d_ready")
    await b.tick()
    await b.set(
        i_d_valid=0,
        i_w_valid=1,
        i_w=pack((1, 0), (1, 1), (1, 0), (b.p, address), (256, 0x9876543210), (1, 0)),
        i_wa_ready=0,
    )
    await b.wait("o_wa_valid")
    ack = b.get("o_wa")
    for _ in range(10):
        await b.tick()
        assert b.get("o_wa_valid") and b.get("o_wa") == ack
        assert not b.get("o_w_ready") and not b.get("o_g_valid")
    await b.set(i_wa_ready=1)
    await b.tick()
    await b.wait("o_g_valid")
    grant = unpack(b.get("o_g"), (3, 9, 6, b.p, 256, 1))
    assert grant[4] == 0x9876543210
    # The other PutM drains while this grant waits for its requester.
    for _ in range(100):
        if any(ack[1] == 0 and not ack[4] for ack in b.acks):
            break
        await b.tick()
    assert any(ack[1] == 0 and ack[3] == address + 32 and not ack[4] for ack in b.acks)
    assert b.get("o_g_valid")
    await b.finish(grant)
    assert await b.read(address + 32, 7) == 0xFEED0001
    count = len(b.probes)
    grant = await b.start(4, address)
    assert grant[0] == 5
    assert [p[0] for p in b.probes[count:]] == [2]
    await b.finish(grant)
    b.reservation = True
    b.private[address] = (3, 0x11223344)
    count = len(b.probes)
    grant = await b.start(4, address)
    assert grant[0] == 2 and grant[4] == 0x11223344
    assert [p[0] for p in b.probes[count:]] == [2, 0]
    await b.finish(grant, written=True)


@cocotb.test()
async def failed_fill_does_not_reveal_detached_victim(dut: Any) -> None:
    """Check victim invalidation after a failed read fill."""
    b = Home(dut)
    await b.reset()
    for index in range(4):
        address = 0x80000000 + index * b.line * 4
        grant = await b.start(1, address)
        b.private[address] = (3, 0xCAFE0000 + index)
        await b.finish(grant, written=True)
    failed = 0x80000000 + 4 * b.line * 4
    b.errors.add(failed)
    grant = await b.start(0, failed)
    assert grant[5] == 1
    await b.finish(grant)
    for index in range(4):
        address = 0x80000000 + index * b.line * 4
        assert await b.read(address, 7) == 0xCAFE0000 + index


@cocotb.test()
async def clean_probe_error_disposes_identity(dut: Any) -> None:
    """Check clean-error disposal without permission installation."""
    b = Home(dut)
    await b.reset()
    address = 0x80000000
    await b.read(address)
    b.probe_errors.add(address)
    grant = await b.start(7, address)
    assert grant[5] and not b.get("o_fatal")
    await b.finish(grant)
    b.probe_errors.clear()
    assert await b.read(address, 7) == b.expected(address)


@cocotb.test()
async def completion_pins_retry_without_blocking_unrelated_work(dut: Any) -> None:
    """All pinned ways prevent replacement while another set makes progress."""
    b = Home(dut)
    await b.reset()
    base = 0x80000000
    stride = b.line * 4
    grants = []

    async def admit(slot: int, address: int) -> None:
        _, request = b.demand(0, address, slot=slot)
        await b.set(i_d_valid=1, i_d=request)
        await b.wait("o_d_ready")
        await b.tick()
        await b.set(i_d_valid=0)

    async def take_grant(slot: int) -> tuple[int, ...]:
        await b.wait("o_g_valid")
        grant = unpack(b.get("o_g"), (3, 9, 6, b.p, 256, 1))
        assert grant[1] == slot << 1 and not grant[5]
        await b.set(i_g_ready=1)
        await b.tick()
        await b.set(i_g_ready=0)
        return grant

    async def done(grant: tuple[int, ...], release_delay: int = 0) -> None:
        await b.set(
            i_c_valid=1,
            i_c=pack((9, grant[1]), (6, grant[2]), (b.p, grant[3]), (2, 0), (1, 0)),
        )
        await b.wait("o_c_ready")
        await b.tick()
        await b.set(i_c_valid=0)
        await b.wait("o_u_valid")
        assert unpack(b.get("o_u"), (9, 6, b.p)) == grant[1:4]
        for _ in range(release_delay):
            await b.tick()
            assert not b.get("o_g_valid")
        await b.set(i_u_ready=1)
        await b.tick()
        await b.set(i_u_ready=0)

    for slot in range(4):
        await admit(slot, base + slot * stride)
        grants.append(await take_grant(slot))
    transaction_count = len(b.transactions)
    await admit(4, base + 4 * stride)
    await b.tick(100)
    assert len(b.transactions) == transaction_count and not b.get("o_g_valid")
    await admit(5, base + b.line)
    unrelated = await take_grant(5)
    await done(unrelated)
    await done(grants[0], release_delay=20)
    fifth = await take_grant(4)
    assert fifth[4] == b.expected(base + 4 * stride)
    await done(fifth)
    for grant in grants[1:]:
        await done(grant)


@cocotb.test()
async def missing_put_destination_preserves_dirty_ownership(dut: Any) -> None:
    """Check fatal handling and dirty retention for a nonresident PutM."""
    b = Home(dut)
    await b.reset()
    address = 0x80000000
    payload = pack((1, 0), (1, 0), (1, 0), (b.p, address), (256, 0xDEADBEEF), (1, 0))
    await b.set(i_w_valid=1, i_w=payload)
    await b.wait("o_w_ready")
    await b.tick()
    await b.wait("o_fatal")
    assert b.get("o_fatal_addr") == address
    for _ in range(10):
        await b.tick()
        assert not b.get("o_wa_valid") and not b.get("o_w_ready")
        assert int(dut.put_q[0].value) == payload


@cocotb.test()
async def full_result_pool_keeps_both_put_slots_moving(dut: Any) -> None:
    """Drain two dirty PutM identities while all eight result images wait for G."""
    b = Home(dut)
    await b.reset()
    base = 0x80000000
    puts = [(base + 0x1000, 0x123456), (base + 0x2000, 0x987654)]
    for address, data in puts:
        grant = await b.start(1, address)
        b.private[address] = (3, data)
        await b.finish(grant, written=True)
    for slot, (address, data) in enumerate(puts):
        b.frozen[slot] = (address, data)
        del b.private[address]
    for slot in range(8):
        await b.submit(0, base + 32 * slot, slot=slot)
    for _ in range(2000):
        if int(dut.completions.result_valid_q.value).bit_count() == 8:
            break
        await b.tick()
    else:
        raise AssertionError("eight result images did not fill")
    assert b.get("o_g_valid")
    held = b.get("o_g")
    await b.set(i_wa_ready=0)
    for slot, (address, data) in enumerate(puts):
        await b.set(
            i_w_valid=1,
            i_w=pack((1, 0), (1, slot), (1, 0), (b.p, address), (256, data), (1, 0)),
        )
        await b.wait("o_w_ready")
        await b.tick()
    assert b.accepted_puts == {0, 1}
    await b.wait("o_wa_valid")
    held_ack = b.get("o_wa")
    for _ in range(20):
        await b.tick()
        assert b.get("o_wa_valid") and b.get("o_wa") == held_ack
        assert b.get("o_g_valid") and b.get("o_g") == held
    await b.set(i_wa_ready=1)
    for slot, (address, data) in enumerate(puts):
        for _ in range(100):
            if any(
                ack[1] == slot and ack[3] == address and not ack[4] for ack in b.acks
            ):
                break
            await b.tick()
        else:
            raise AssertionError("PutM did not drain behind full G storage")
        assert b.get("o_g_valid") and b.get("o_g") == held
        assert int(dut.completions.result_valid_q.value).bit_count() == 8
    returned = set()
    for _ in range(8):
        grant = await b.take_grant()
        returned.add(grant[3])
        assert grant[4] == b.expected(grant[3])
        await b.complete(grant)
    assert returned == {base + 32 * slot for slot in range(8)}
    for address, data in puts:
        assert await b.read(address, 7) == data


@cocotb.test()
async def sibling_completion_pins_share_a_way_until_both_releases(dut: Any) -> None:
    """Keep a shared physical way excluded after only one sector releases it."""
    b = Home(dut)
    if b.line != 64:
        return
    await b.reset()
    base = 0x80000000
    await b.submit(0, base, slot=0)
    lower = await b.take_grant()
    await b.submit(0, base + 32, slot=1)
    upper = await b.take_grant()
    await b.complete(lower)
    for index in range(1, 9):
        grant = await b.start(0, base + index * b.line * 4, slot=2)
        await b.finish(grant)
    assert not any(
        addr in (base, base + 32) and reason == 2 for _, addr, reason, _ in b.probes
    )
    await b.complete(upper)
    for index in range(9, 17):
        grant = await b.start(0, base + index * b.line * 4, slot=2)
        await b.finish(grant)
    assert any(addr == base and reason == 2 for _, addr, reason, _ in b.probes)


@cocotb.test()
async def fatal_and_reset_with_held_results_and_dirty_victim(dut: Any) -> None:
    """Preserve held ownership at fatal stop and reset the home ownership records."""
    b = Home(dut)
    await b.reset()
    base = 0x80000000
    for index in range(4):
        address = base + index * b.line * 4
        grant = await b.start(1, address)
        b.private[address] = (3, 0xDEAD0000 + index)
        await b.finish(grant, written=True)
    b.write_delay = 50000
    await b.submit(0, base + 4 * b.line * 4, slot=0)
    first = await b.take_grant()
    await b.set(
        i_c_valid=1,
        i_c=pack((9, first[1]), (6, first[2]), (b.p, first[3]), (2, 0), (1, 0)),
    )
    await b.wait("o_c_ready")
    await b.tick()
    await b.set(i_c_valid=0)
    await b.wait("o_u_valid")
    await b.submit(0, base + b.line, slot=1)
    await b.wait("o_g_valid")
    assert any(response[5] for response in b.responses)
    held_grant, release = b.get("o_g"), b.get("o_u")
    victims = int(dut.wb_valid_q.value)
    assert victims
    await b.set(i_fatal_stop=1)
    for _ in range(12):
        await b.tick()
        assert b.get("o_g_valid") and b.get("o_g") == held_grant
        assert b.get("o_u_valid") and b.get("o_u") == release
        assert int(dut.wb_valid_q.value) == victims
        assert not b.get("o_d_ready") and not b.get("o_w_ready")
    b.responses.clear()
    b.replies.clear()
    b.private.clear()
    b.frozen.clear()
    await b.reset()
    assert not b.get("o_g_valid") and not b.get("o_u_valid")
    assert not int(dut.wb_valid_q.value)
    assert await b.read(base + b.line) == b.expected(base + b.line)


@cocotb.test()
async def parked_fills_release_engines_and_reenter_under_miss_pressure(
    dut: Any,
) -> None:
    """Parked fills on every fill and retries on every engine keep hits served."""
    b = Home(dut)
    await b.reset()
    base = 0x80000000
    first = await b.start(0, base)
    await b.finish(first)
    b.read_delay = 1200
    fills, engines = len(dut.fill_live_q), len(dut.engine_idle)
    addresses = [base + (index + 1) * b.line for index in range(fills + engines)]
    for index, address in enumerate(addresses):
        await b.submit(0 if index < 8 else 7, address, slot=index % 8)
    retried = set()
    for _ in range(500):
        if b.get("retry_valid") and not b.get("retry_park"):
            retried.add(b.get("decision_tid"))
        await b.tick()
        if len(retried) == engines:
            break
    assert len(retried) == engines
    assert int(dut.completions.parked_q.value).bit_count() == fills
    assert len([t for t in b.transactions if not t[1]]) == fills + 1
    assert not b.get("o_g_valid")
    await b.submit(5, base)
    resident = await b.take_grant()
    assert resident[3] == base and resident[4] == b.expected(base)
    await b.complete(resident)
    received = set()
    for _ in addresses:
        grant = await b.take_grant()
        assert grant[3] in addresses and grant[3] not in received
        assert grant[4] == b.expected(grant[3]) and not grant[5]
        received.add(grant[3])
        await b.complete(grant)
    assert received == set(addresses)


@cocotb.test()
async def ready_reader_samples_after_older_unseated_writer(dut: Any) -> None:
    """Reenter a seated reader after the earlier writer releases its sector."""
    b = Home(dut)
    await b.reset()
    base = 0x80000000
    b.read_delay = 150
    await b.submit(0, base, slot=0)
    await b.tick(25)
    await b.submit(1, base, slot=1)
    await b.submit(5, base)
    await b.tick(15)
    assert any(int(seats.value).bit_count() == 2 for seats in dut.fill_seats_q)
    reader = await b.take_grant()
    assert reader[0] == 0 and reader[4] == b.expected(base)
    await b.complete(reader)
    writer = await b.take_grant()
    assert writer[0] == 2
    changed = int.from_bytes(
        bytes((index * 29 + 7) & 255 for index in range(32)), "little"
    )
    b.private[base] = (3, changed)
    await b.tick(20)
    assert not b.get("o_g_valid")
    await b.complete(writer, written=True)
    successor = await b.take_grant()
    assert successor[0] == 3 and successor[4] == changed
    await b.complete(successor)


@cocotb.test()
async def dirty_reply_overrides_each_baseline_arrival_order(dut: Any) -> None:
    """Dirty bytes win before, after and on the resident data-response edge."""
    observed = set()
    for delay in range(12):
        b = Home(dut)
        await b.reset()
        address = 0x80000000 + (32 if b.line == 64 else 0)
        warm = await b.start(0, address)
        await b.finish(warm)
        changed = int.from_bytes(
            bytes((index * 31 + delay) & 255 for index in range(32)), "little"
        )
        b.private[address] = (3, changed)
        b.probe_delay = delay
        b.arrivals.clear()
        grant = await b.start(7, address)
        assert grant[4] == changed and not grant[5]
        events = {kind: cycle for cycle, kind, tid in b.arrivals if tid == grant[2]}
        assert "data" in events and "reply" in events
        observed.add(
            (events["reply"] > events["data"]) - (events["reply"] < events["data"])
        )
        await b.finish(grant)
    assert observed == {-1, 0, 1}


@cocotb.test()
async def dirty_probe_error_preserves_accepted_image(dut: Any) -> None:
    """Fatal handling owns returned dirty bytes while the baseline read drains."""
    b = Home(dut)
    await b.reset()
    address = 0x80000000
    warm = await b.start(0, address)
    await b.finish(warm)
    changed = int.from_bytes(
        bytes((index * 13 + 9) & 255 for index in range(32)), "little"
    )
    b.private[address] = (3, changed)
    b.probe_errors.add(address)
    b.probe_delay = 0
    await b.submit(7, address)
    await b.wait("o_fatal")
    assert b.get("o_fatal_addr") == address
    owners = b.get("engine_fatal")
    assert owners.bit_count() == 1
    engine = owners.bit_length() - 1
    for _ in range(20):
        assert (b.get("engine_image") >> (256 * engine)) & ((1 << 256) - 1) == changed
        assert not b.get("o_g_valid")
        await b.tick()


@cocotb.test()
async def held_probe_survives_another_engine_fatal(dut: Any) -> None:
    """Hold a captured probe through another engine's local fatal transition."""
    for accept in (False, True):
        b = Home(dut)
        await b.reset()
        failed = 0x80000000
        held = failed + b.line
        for address in (failed, held):
            grant = await b.start(0, address)
            await b.finish(grant)
        b.private[failed] = (3, b.expected(failed) ^ 0x1234)
        b.probe_errors.add(failed)
        b.probe_delay = 1000
        before = len(b.probes)
        await b.submit(7, failed, slot=0)
        for _ in range(200):
            if len(b.probes) > before:
                break
            await b.tick()
        else:
            raise AssertionError("the failing probe was not accepted")
        assert b.probes[-1][1] == failed
        await b.set(i_p_ready=0)
        await b.submit(7, held, slot=1)
        await b.wait("o_p_valid")
        payload = b.get("o_p")
        assert unpack(payload, (2, 6, 1, b.p, 2, 2, 9, 5, 3))[3] == held
        assert len(b.replies) == 1
        b.replies[0] = (b.cycle, b.replies[0][1])
        await b.tick()
        assert b.get("engine_fatal") and not b.get("o_fatal")
        assert b.get("o_p_valid") and b.get("o_p") == payload
        assert not b.replies
        await b.set(i_p_ready=int(accept))
        before = len(b.probes)
        await b.tick()
        assert len(b.probes) == before + int(accept)
        assert b.get("o_fatal") and not b.get("o_p_valid")
        await b.tick(3)
        assert not b.get("o_p_valid")


@cocotb.test()
async def returned_fills_install_during_same_set_retries(dut: Any) -> None:
    """Install returned fills while misses repeatedly contest the same set."""
    b = Home(dut)
    await b.reset()
    base = 0x80000000
    stride = 4 * b.line
    b.read_delay = 500
    addresses = [base + i * stride for i in range(4)]
    for i, address in enumerate(addresses):
        await b.submit(7, address, slot=i)
    await b.tick(150)
    assert len(b.transactions) == 4
    extras = [base + i * stride for i in range(4, 7)]
    for op, address in zip((0, 5, 6), extras, strict=True):
        await b.submit(op, address)
    grants = set()
    for _ in addresses + extras:
        grant = await b.take_grant()
        assert grant[3] not in grants and grant[4] == b.expected(grant[3])
        grants.add(grant[3])
        await b.complete(grant)
    assert grants == set(addresses + extras)


@cocotb.test()
async def victim_claim_and_ordinary_put_are_exclusive(dut: Any) -> None:
    """Resolve a victim claim against a Put on either sector of that block."""
    for sector in range(len(dut.i_mem_resp_data) // 256):
        b = Home(dut)
        await b.reset()
        base = 0x80000000
        for i in range(4):
            await b.read(base + i * 4 * b.line)
        target = base + 16 * b.line
        await b.submit(0, target)
        for _ in range(100):
            if int(dut.array.phase_q.value) == 4:
                break
            await b.tick()
        else:
            raise AssertionError("no pre-claim victim decision")
        way = int(dut.array.selected.value)
        entry = int(dut.array.tags_q[way].value)
        low_bits = (b.line.bit_length() - 1) + len(dut.array.set_q)
        address = ((entry & ((1 << (b.p - low_bits)) - 1)) << low_bits) + 32 * sector
        changed = (1 << 255) | 0x13579
        b.frozen[0] = (address, changed)
        await b.set(
            i_w_valid=1,
            i_w=pack((1, 0), (1, 0), (1, 0), (b.p, address), (256, changed), (1, 0)),
        )
        # Capture the W key before the array's claim edge.
        await b.tick()
        assert b.get("array_response") and b.get("put_selected_q")
        assert not (b.get("decision_fill") and b.get("o_w_ready"))
        grant = await b.take_grant()
        assert grant[3] == target and not grant[5]
        await b.complete(grant)
        for _ in range(200):
            if not b.frozen:
                break
            await b.tick()
        assert not b.frozen
        assert await b.read(address) == changed


@cocotb.test()
async def failed_fills_release_resources_before_ordered_error_waiters(dut: Any) -> None:
    """Release failed fills while younger error completions await older writers."""
    b = Home(dut)
    await b.reset()
    addresses = [0x80000000 + i * b.line for i in range(4)]
    b.read_delay = 300
    b.errors.update(addresses)
    for i, address in enumerate(addresses):
        await b.submit(0, address, slot=2 * i)
        await b.tick(25)
        await b.submit(8, address, data=0x7654321 + i, mask=0xF, slot=i)
        await b.submit(0, address, slot=2 * i + 1)
    await b.tick(100)
    assert sum(int(seats.value).bit_count() for seats in dut.fill_seats_q) == 8
    b.errors.clear()
    received: set[int] = set()
    for _ in range(12):
        grant = await b.take_grant()
        assert grant[1] not in received
        received.add(grant[1])
        if grant[0] == 4:
            assert not grant[5]
        else:
            assert grant[5]
        await b.complete(grant)
    for i, address in enumerate(addresses):
        assert await b.read(address) & 0xFFFFFFFF == 0x7654321 + i


@cocotb.test()
async def dirty_victim_error_preserves_accepted_image(dut: Any) -> None:
    """Keep a failed dirty recall's bytes while the victim baseline drains."""
    b = Home(dut)
    await b.reset()
    base = 0x80000000
    changed = (1 << 255) | 0x2468ABCD
    for i in range(4):
        address = base + i * 4 * b.line
        await b.read(address)
        b.private[address] = (3, changed)
        b.probe_errors.add(address)
    b.probe_delay = 0
    await b.submit(0, base + 16 * b.line)
    await b.wait("o_fatal")
    victim = b.get("o_fatal_addr")
    slot = next(
        i
        for i, addr in enumerate(dut.wb_addr_q)
        if b.get("wb_valid_q") & (1 << i) and int(addr.value) == victim
    )
    for _ in range(24):
        assert int(dut.wb_data_q[slot].value) & ((1 << 256) - 1) == changed
        assert not b.get("o_g_valid")
        await b.tick()


@cocotb.test()
async def retried_dma_write_counts_its_fill_allocation(dut: Any) -> None:
    """Count a write fill after read misses occupy every fill control."""
    b = Home(dut)
    await b.reset()
    base = 0x80000000
    b.read_delay = 500
    fills = len(dut.fill_live_q)
    for slot in range(fills - 1):
        await b.submit(7, base + slot * b.line, slot=slot)
    await b.submit(0, base + (fills - 1) * b.line)
    for _ in range(150):
        if len(b.transactions) == fills:
            break
        await b.tick()
    assert len(b.transactions) == fills
    address = base + fills * b.line
    await b.submit(8, address, 0xAABBCCDD, 15, slot=fills - 1)
    await b.tick(100)
    assert len(b.transactions) == fills and b.write_fills == 0
    seen = set()
    for _ in range(fills + 1):
        grant = await b.take_grant()
        assert not grant[5] and grant[3] not in seen
        seen.add(grant[3])
        await b.complete(grant)
    assert b.write_fills == 1
    expected = (b.expected(address) & ~0xFFFFFFFF) | 0xAABBCCDD
    assert await b.read(address, 7) == expected


@cocotb.test()
async def fill_response_crosses_captured_victim_invalidation(dut: Any) -> None:
    """Hold a tag-only invalidation payload across the memory response."""
    b = Home(dut)
    await b.reset()
    base = 0x80000000
    stride = 4 * b.line
    for index in range(4):
        grant = await b.start(0, base + index * stride)
        await b.finish(grant)
    b.read_delay = 10000
    address = base + 4 * stride
    await b.submit(0, address)
    for _ in range(200):
        if (
            any(int(phase.value) == 3 for phase in dut.fill_phase_q)
            and not int(dut.update_arbiter.selected_q.value)
            and b.responses
        ):
            break
        await b.tick()
    else:
        raise AssertionError("victim invalidation capture was not reached")
    response = next(r for r in b.responses if not r[5] and r[4] == address)
    b.responses.remove(response)
    b.responses.append((b.cycle, *response[1:]))
    await b.tick()
    assert int(dut.update_arbiter.selected_q.value)
    grant = await b.take_grant()
    assert not grant[5] and grant[4] == b.expected(address)
    await b.complete(grant)


@cocotb.test()
async def concurrent_sibling_updates_survive_replacement(dut: Any) -> None:
    """Merge both dirty sectors while their independent completion pins overlap."""
    b = Home(dut)
    if b.line != 64:
        return
    await b.reset()
    base = 0x80000000
    changed = [
        int.from_bytes(bytes((i * 19 + sector * 61) & 255 for i in range(32)), "little")
        for sector in range(2)
    ]
    for sector in range(2):
        grant = await b.start(1, base + sector * 32)
        b.private[base + sector * 32] = (3, changed[sector])
        await b.finish(grant, written=True)
    b.probe_delay = 9
    masks = (0x0000FFFF, 0xFF0000FF)
    values = (int.from_bytes(bytes(range(32)), "little"), (1 << 256) - 1)
    for sector in range(2):
        await b.submit(
            8, base + sector * 32, values[sector], masks[sector], slot=sector
        )
        for byte in range(32):
            if masks[sector] & (1 << byte):
                changed[sector] &= ~(255 << (byte * 8))
                changed[sector] |= ((values[sector] >> (byte * 8)) & 255) << (byte * 8)
    grants = [await b.take_grant(), await b.take_grant()]
    assert {g[3] for g in grants} == {base, base + 32}
    assert not any(g[5] for g in grants)
    assert int(dut.completions.pin_valid_q.value).bit_count() == 2
    await b.complete(grants[1])
    await b.tick(20)
    await b.complete(grants[0])
    for index in range(1, 13):
        grant = await b.start(0, base + index * b.line * 4)
        await b.finish(grant)
    await b.tick(b.write_delay + 10)
    assert b.memory[base] == changed[0] | (changed[1] << 256)


@cocotb.test()
async def sibling_misses_reuse_invalidated_clean_victim(dut: Any) -> None:
    """Drain concurrent siblings after a failed clean replacement leaves an invalid tag."""
    b = Home(dut)
    if b.line != 64:
        return
    await b.reset()
    base = 0x80000000
    for index in range(4):
        address = base + index * b.line * 4
        assert await b.read(address, 7) == b.expected(address)
    failed = base + 4 * b.line * 4
    b.errors.add(failed)
    before = len(b.probes)
    grant = await b.start(7, failed)
    assert grant[5]
    await b.finish(grant)
    recalled = [p[1] for p in b.probes[before:] if p[2] == 2]
    assert len(recalled) == 2
    victim = recalled[0] & -b.line
    assert set(recalled) == {victim, victim + 32}
    b.errors.clear()
    transactions = len(b.transactions)
    await b.submit(7, victim, slot=0)
    await b.submit(7, victim + 32, slot=1)
    grants = [await b.take_grant(), await b.take_grant()]
    assert {g[3] for g in grants} == {victim, victim + 32}
    assert not any(g[5] for g in grants)
    for response in grants:
        assert response[4] == b.expected(response[3])
        await b.complete(response)
    assert any(t[1] == 0 and t[2] == victim for t in b.transactions[transactions:])
    assert not b.get("o_fatal")


@cocotb.test()
async def prefetch_fills_absent_lines_and_leaves_resident_ones(dut: Any) -> None:
    """Fill an absent line for a Prefetch with no seat and leave a resident one."""
    b = Home(dut)
    await b.reset()
    address = 0x80000040
    await b.prefetch(address)
    assert b.reads_of(address) == 1
    await b.tick(b.read_delay + 20)
    assert not int(dut.fill_live_q.value)
    # The installed line serves a demand read and a second Prefetch without
    # another memory read, probe or pin.
    assert await b.read(address) == b.expected(address)
    await b.prefetch(address)
    await b.prefetch(address + 32, slot=1)
    assert b.reads_of(address) == 1
    assert not b.probes
    assert not int(dut.completions.pin_valid_q.value)


@cocotb.test()
async def demand_read_takes_a_seat_on_a_prefetch_fill(dut: Any) -> None:
    """Seat a read that meets a Prefetch's fill until its install."""
    b = Home(dut)
    await b.reset()
    b.read_delay = 200
    address = 0x80000000
    await b.prefetch(address)
    grant = await b.start(0, address, slot=1)
    assert grant[4] == b.expected(address) and grant[5] == 0
    await b.finish(grant)
    assert b.reads_of(address) == 1


@cocotb.test()
async def prefetch_leaves_reserved_fills_and_the_last_way(dut: Any) -> None:
    """Allocate Prefetch fills only above the fill reserve and with two ways."""
    b = Home(dut)
    await b.reset()
    b.read_delay = 400
    fills = len(dut.fill_live_q)
    reserve = fills // 4
    sets = 4
    stride = sets * b.line
    base = 0x80000000
    # Demand misses leave reserve + 1 fills free, spread over the sets.
    demands = [
        base + (index % sets) * b.line + (index // sets + 1) * 4096
        for index in range(fills - reserve - 1)
    ]
    for index, address in enumerate(demands):
        await b.submit(0, address, slot=index)
    await b.fills_live(len(demands))
    # One more fill would leave reserve free: allowed.
    allowed = base + 3 * b.line + 64 * 4096
    await b.prefetch(allowed, slot=0)
    assert b.reads_of(allowed) == 1
    # Now only reserve fills are free: the next Prefetch does nothing.
    dropped = base + 2 * b.line + 65 * 4096
    await b.prefetch(dropped, slot=1)
    assert b.reads_of(dropped) == 0
    for _ in demands:
        grant = await b.take_grant()
        await b.complete(grant)
    await b.tick(b.read_delay + 20)
    # Three fills in flight in one set leave one way: a Prefetch of that set
    # does nothing, and a demand miss still takes the last way.
    same_set = [base + 128 * 4096 + index * stride * 16 for index in range(4)]
    for index, address in enumerate(same_set[:3]):
        await b.submit(0, address, slot=index)
    await b.fills_live(3)
    await b.prefetch(base + 200 * 4096, slot=2)
    assert b.reads_of(base + 200 * 4096) == 0
    await b.submit(0, same_set[3], slot=3)
    await b.fills_live(4)
    await b.tick(5)
    assert b.reads_of(same_set[3]) == 1
    for _ in same_set:
        grant = await b.take_grant()
        await b.complete(grant)


@cocotb.test()
async def prefetch_error_frees_its_fill_and_wakes_joined_readers(dut: Any) -> None:
    """Free a failed Prefetch fill and report the error to a joined read."""
    b = Home(dut)
    await b.reset()
    address = 0x80000000
    b.errors.add(address)
    await b.prefetch(address)
    await b.tick(b.read_delay + 20)
    assert not int(dut.fill_live_q.value)
    b.errors.clear()
    assert await b.read(address) == b.expected(address)
    assert b.reads_of(address) == 2
    other = 0x80001000
    b.errors.add(other)
    b.read_delay = 200
    await b.prefetch(other)
    grant = await b.start(0, other, slot=2)
    assert grant[5] == 1
    await b.finish(grant)
    b.errors.clear()
    b.read_delay = 3
    assert await b.read(other) == b.expected(other)


@cocotb.test()
async def prefetches_beside_dma_writes_and_reads_change_no_bytes(dut: Any) -> None:
    """Prefetches beside DMA writes and reads change no bytes."""
    b = Home(dut)
    await b.reset()
    address = 0x80002000
    low = (1 << 128) - 1
    data = int.from_bytes(bytes(range(100, 132)), "little")
    # A DMA write accepted after a Prefetch of its sector does not wait for
    # it, but waits for any fill the Prefetch started.
    await b.submit(PREFETCH, address, slot=0)
    await b.submit(8, address, data, 0xFFFF, slot=0)
    await b.complete(await b.prefetch_grant(address, 0))
    write = await b.take_grant()
    assert write[0] == GRANT_ACK
    await b.complete(write)
    expected = (b.expected(address) & ~low) | (data & low)
    # A Prefetch accepted after a DMA write of its sector, in the other
    # sector of the line, and beside a DMA read.
    second = address + 32
    await b.submit(8, second, data, 0xFFFF, slot=1)
    await b.submit(PREFETCH, second, slot=1)
    write = await b.take_grant()
    assert write[0] == GRANT_ACK
    await b.complete(write)
    await b.complete(await b.prefetch_grant(second, 1))
    expected_second = (b.expected(second) & ~low) | (data & low)
    await b.prefetch(address, slot=2)
    assert await b.read(address, 7) == expected
    await b.prefetch(address, slot=3)
    assert await b.read(address) == expected
    assert await b.read(second) == expected_second
    assert b.reads_of(address) == 1


@cocotb.test()
async def put_proceeds_beside_live_prefetches_of_its_sector(dut: Any) -> None:
    """Live Prefetch slots of a sector never make its PutM wait."""
    b = Home(dut)
    await b.reset()
    address = 0x80003000
    data = 0x5A5A_1234
    grant = await b.start(1, address)
    b.private[address] = (3, data)
    await b.finish(grant, written=True)
    b.frozen[0] = (address, data)
    del b.private[address]
    held = []
    for slot in range(4):
        await b.submit(PREFETCH, address, slot=slot)
        held.append(await b.prefetch_grant(address, slot))
    await b.set(
        i_w_valid=1,
        i_w=pack((1, 0), (1, 0), (1, 0), (b.p, address), (256, data), (1, 0)),
    )
    await b.wait("o_w_ready")
    await b.tick()
    assert 0 in b.accepted_puts
    for _ in range(100):
        if 0 not in b.frozen:
            break
        await b.tick()
    else:
        raise AssertionError("the PutM was not acknowledged")
    for grant in held:
        await b.complete(grant)
    assert await b.read(address) == data


@cocotb.test()
async def demand_replaces_a_line_held_by_resident_prefetches(dut: Any) -> None:
    """Prefetches of every resident way of a set pin none of them."""
    b = Home(dut)
    await b.reset()
    sets = 4
    base = 0x80000000
    lines = [base + index * sets * b.line for index in range(5)]
    for address in lines[:4]:
        assert await b.read(address) == b.expected(address)
    held = []
    for slot, address in enumerate(lines[:4]):
        await b.submit(PREFETCH, address, slot=slot)
        held.append(await b.prefetch_grant(address, slot))
    assert b.reads_of(lines[4]) == 0
    assert await b.read(lines[4]) == b.expected(lines[4])
    for grant in held:
        await b.complete(grant)
    assert b.reads_of(lines[4]) == 1


@cocotb.test()
async def prefetch_leaves_the_last_write_back_slot(dut: Any) -> None:
    """Keep a Prefetch with a valid victim off the last write-back slot."""
    b = Home(dut)
    await b.reset()
    b.write_delay = 50000
    sets = 4
    base = 0x80000000
    lines = [base + index * sets * b.line for index in range(7)]
    # Every way of the set holds a line the L2 has dirty, so each victim
    # needs a write-back, and the first one stays outstanding.
    for address in lines[:4]:
        grant = await b.start(8, address, 0x1234, 0xF)
        await b.finish(grant)
    assert await b.read(lines[4]) == b.expected(lines[4])
    assert int(dut.wb_valid_q.value).bit_count() == 1
    await b.prefetch(lines[5])
    await b.tick(5)
    assert b.reads_of(lines[5]) == 0
    assert await b.read(lines[6]) == b.expected(lines[6])
    assert int(dut.wb_valid_q.value).bit_count() == 2
