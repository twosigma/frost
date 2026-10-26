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
            if reply and self.get("o_r_ready"):
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
            await self.set(i_clk=1)
            await self.set(i_clk=0)
            if next_put is not None:
                await self.set(i_w_valid=1, i_w=next_put)
            elif drop_put:
                await self.set(i_w_valid=0)
            self.cycle += 1

    def demand(
        self, op: int, address: int, data: int = 0, mask: int = 0
    ) -> tuple[int, int]:
        """Encode hart or agent requests with disjoint source identities."""
        q = pack((2, 2), (2, 3), (4, 9), (1, 0)) if op in (7, 8) else 0
        return q, pack(
            (4, op),
            (9, q),
            (self.p, address),
            (5, 0),
            (3, 5 if op in (7, 8) else 3),
            (32, mask),
            (1, 0),
            (1, 0),
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

    async def start(
        self, op: int, address: int, data: int = 0, mask: int = 0
    ) -> tuple[int, ...]:
        """Accept one request and leave its grant held at the home."""
        _, request = self.demand(op, address, data, mask)
        await self.set(i_d_valid=1, i_d=request)
        await self.wait("o_d_ready")
        await self.tick()
        await self.set(i_d_valid=0)
        await self.wait("o_g_valid")
        return unpack(self.get("o_g"), (3, 9, 6, self.p, 256, 1))

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
        for _ in range(completion_delay):
            await self.tick()
            assert not self.get("o_d_ready") and not self.get("o_w_ready")
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
            assert not self.get("o_d_ready") and not self.get("o_w_ready")
        await self.set(i_u_ready=1)
        await self.tick()
        await self.set(i_u_ready=0)

    async def read(self, address: int, op: int = 0) -> int:
        """Complete a read request."""
        grant = await self.start(op, address)
        assert grant[5] == 0
        await self.finish(grant)
        return grant[4]


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
    assert b.get("i_w_valid")
    assert unpack(b.get("i_w"), (1, 1, 1, b.p, 256, 1))[1] == 0
    await b.finish(grant)
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
