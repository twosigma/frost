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

"""Exercise connected S/M endpoints with CPU-side and memory peers."""

from typing import Any

import cocotb
from cocotb.triggers import Timer

from cocotb_tests.cache.test_coherence_endpoints import pack
from cocotb_tests.cache.test_coherence_home import unpack


class Cluster:
    """Supply memory responses and a staged local invalidation handshake."""

    def __init__(self, dut: Any) -> None:
        """Record interface widths and independent transport queues."""
        self.dut = dut
        self.p = len(dut.i_address)
        self.line = len(dut.i_mem_resp_data) // 8
        self.cycle = 0
        self.memory: dict[int, int] = {}
        self.responses: list[tuple[int, int, int, int]] = []
        self.cut_age = 0
        self.cut_admit_age = 0
        self.cut_admit_delay = 0
        self.cut_inval_delay = 3
        self.cut_lookup_overlap = 0
        self.cuts: list[int] = []
        self.sc_writes: list[int] = []
        self.reply_states: list[int] = []
        self.perf: dict[str, list[int]] = {
            "l1d": [0] * 8,
            "l2": [0] * 8,
            "l2_write": [0] * 4,
        }

    def get(self, name: str) -> int:
        """Read an interface signal."""
        return int(getattr(self.dut, name).value)

    async def set(self, **values: int) -> None:
        """Set inputs and settle combinational logic."""
        for name, value in values.items():
            getattr(self.dut, name).value = value
        await Timer(1, unit="ns")

    async def tick(self, count: int = 1) -> None:
        """Advance one clock without waiting on a demand-side resource."""
        for _ in range(count):
            response = next((r for r in self.responses if r[0] <= self.cycle), None)
            self.cut_age = self.cut_age + 1 if self.get("o_cut_inval_valid") else 0
            self.cut_admit_age = (
                self.cut_admit_age + 1 if self.get("o_cut_admit_valid") else 0
            )
            await self.set(
                i_clk=0,
                i_mem_resp_valid=int(response is not None),
                i_mem_resp_id=response[1] if response else 0,
                i_mem_resp_data=response[2] if response else 0,
                i_cut_admit_ready=int(self.cut_admit_age >= self.cut_admit_delay),
                i_cut_inval_done=int(self.cut_age >= self.cut_inval_delay),
            )
            if response:
                self.responses.remove(response)
                if response[1] & 16:
                    self.memory[response[3]] = response[2]
            if self.cut_age == self.cut_inval_delay:
                address = self.get("o_cut_address")
                self.cuts.append(address)
                if self.get("i_reservation_addr") & -32 == address:
                    await self.set(i_reservation_valid=0)
            if self.get("o_cut_hold"):
                assert not int(self.dut.r_valid.value)
                if int(self.dut.hart.phase_q.value) == 8:
                    self.cut_lookup_overlap += 1
            if int(self.dut.r_valid.value) and int(self.dut.r_ready.value):
                reply = unpack(
                    int(self.dut.reply.value),
                    (2, 6, 1, 1, self.p, 2, 1, 1, 256, 1, 1, 1, 1, 1),
                )
                self.reply_states.append(reply[5])
            if self.get("o_mem_req_valid") and self.get("i_mem_req_ready"):
                address = self.get("o_mem_req_addr")
                write = self.get("o_mem_req_write")
                data = (
                    self.get("o_mem_req_data") if write else self.memory.get(address, 0)
                )
                self.responses.append(
                    (
                        self.cycle + (31 if write else 7),
                        self.get("o_mem_req_id"),
                        data,
                        address,
                    )
                )
            await self.set(i_clk=1)
            await self.set(i_clk=0)
            self.cycle += 1
            if not self.get("i_rst"):
                for name in self.perf:
                    widths = (
                        (1, 5, 1, 1) if name == "l2_write" else (1, 1, 1, 1, 5, 1, 1, 1)
                    )
                    events = unpack(self.get(f"o_{name}_perf"), widths)
                    self.perf[name] = [
                        a + b for a, b in zip(self.perf[name], events, strict=True)
                    ]
            if self.get("o_sc_write_done"):
                self.sc_writes.append(self.get("o_sc_write_tag"))
            assert not self.get("o_fatal"), f"fatal at {self.get('o_fatal_addr'):x}"

    async def reset(self) -> None:
        """Reset the cluster and let both tag arrays initialize."""
        for signal in self.dut:
            if signal._name.startswith("i_"):
                signal.value = 0
        await self.set(i_rst=1)
        await self.tick(2)
        await self.set(i_rst=0, i_mem_req_ready=1, i_atomic_protected=1)
        await self.tick(30)

    async def wait(self, signal: str, value: int = 1, limit: int = 2000) -> None:
        """Bound every protocol wait."""
        for _ in range(limit):
            if self.get(signal) == value:
                return
            await self.tick()
        raise AssertionError(f"{signal} != {value} at cycle {self.cycle}")

    async def read(self, address: int, kind: int = 0, slot: int = 0) -> int:
        """Launch and consume a CPU read without merging its identity."""
        await self.set(
            i_address=address,
            i_read_id=slot,
            i_read_kind=kind,
            i_read_size=3,
            i_read_valid=1,
        )
        await self.tick()
        await self.set(i_read_valid=0)
        await self.wait("o_read_valid")
        assert self.get("o_read_id") == slot and not self.get("o_read_error")
        value = self.get("o_read_data")
        await self.set(i_read_ready=1)
        await self.tick()
        await self.set(i_read_ready=0)
        return value

    async def store(
        self, address: int, value: int, mask: int = 255, atomic: bool = False
    ) -> None:
        """Keep SQ ownership until the cache's completion pulse."""
        if not atomic:
            await self.wait("o_store_ready")
        await self.set(
            i_address=address,
            i_write_data=value,
            i_write_mask=mask,
            i_write_atomic=int(atomic),
            i_write_sc=int(atomic),
            i_write_tag=7,
        )
        await self.tick()
        await self.set(i_write_mask=0)
        await self.wait("o_write_done")
        await self.tick()

    async def dma(
        self, address: int, data: int | None = None, mask: int = 0xFFFFFFFF
    ) -> int:
        """Execute an opaque-ID agent request through completion and release."""
        q = pack((2, 2), (2, 3), (4, 13), (1, 0))
        request = pack(
            (4, 7 if data is None else 8),
            (9, q),
            (self.p, address),
            (5, 0),
            (3, 5),
            (32, 0 if data is None else mask),
            (1, 0),
            (1, 0),
            (1, 0),
            (256, data or 0),
        )
        await self.set(i_agent_valid=1, i_agent_d=request)
        await self.wait("o_agent_ready")
        await self.tick()
        await self.set(i_agent_valid=0)
        await self.wait("o_agent_g_valid")
        grant = unpack(self.get("o_agent_g"), (3, 9, 6, self.p, 256, 1))
        assert grant[1] == q and not grant[5]
        await self.set(i_agent_g_ready=1)
        await self.tick()
        await self.set(
            i_agent_g_ready=0,
            i_agent_c_valid=1,
            i_agent_c=pack((9, q), (6, grant[2]), (self.p, address), (2, 0), (1, 0)),
        )
        await self.wait("o_agent_c_ready")
        await self.tick()
        await self.set(i_agent_c_valid=0)
        await self.wait("o_agent_u_valid")
        await self.set(i_agent_u_ready=1)
        await self.tick()
        await self.set(i_agent_u_ready=0)
        return grant[4]


@cocotb.test()
async def yielding_store_and_dma(dut: Any) -> None:
    """Check unrelated local reads while a store waits for GrantM."""
    b = Cluster(dut)
    await b.reset()
    a, other = 0x80000000, 0x80000040
    assert await b.read(a) == 0
    await b.store(other, 0x12345678)
    await b.wait("o_pending_store", 0)
    await b.set(i_hold_grant=1)
    await b.store(a, 0xDEADBEEF)
    assert b.get("o_pending_store")
    assert await b.read(other) == 0x12345678
    assert b.get("o_pending_store")
    await b.set(i_hold_grant=0)
    await b.wait("o_pending_store", 0)
    assert await b.dma(a) & ((1 << 64) - 1) == 0xDEADBEEF
    assert b.reply_states[-1] == 2
    await b.dma(a, 0xA5, 1)
    assert b.reply_states[-1] == 0
    assert a in b.cuts
    assert await b.read(a) == 0xDEADBEA5


@cocotb.test()
async def cut_and_snapshot_overlap(dut: Any) -> None:
    """Snapshot data while admission and replay marking are backpressured."""
    b = Cluster(dut)
    await b.reset()
    a = 0x80000000
    await b.store(a, 0xFEDCBA9876543210)
    await b.wait("o_pending_store", 0)
    b.cut_admit_delay = 24
    b.cut_inval_delay = 19
    await b.set(i_reservation_valid=1, i_reservation_addr=a, i_reservation_size=3)
    await b.dma(a, 0xA5, 1)
    assert b.cut_lookup_overlap >= 20
    assert b.cuts == [a] and not b.get("i_reservation_valid")
    assert await b.read(a) == 0xFEDCBA98765432A5
    before = b.cut_lookup_overlap
    await b.dma(a + 32, 0x1234, 3)
    assert b.cut_lookup_overlap > before
    assert await b.read(a + 32) == 0x1234


@cocotb.test()
async def inclusion_and_maintenance(dut: Any) -> None:
    """Dirty private sectors survive L2 replacement and maintenance PutM."""
    b = Cluster(dut)
    await b.reset()
    addresses = [0x80000000 + 128 * index for index in range(7)]
    for index, address in enumerate(addresses):
        await b.store(address, 0xCAFE0000 + index)
        await b.wait("o_pending_store", 0)
    for index, address in enumerate(addresses):
        assert await b.read(address) == 0xCAFE0000 + index
        assert await b.dma(address) & ((1 << 64) - 1) == 0xCAFE0000 + index
    await b.store(addresses[0], 0x11223344)
    await b.wait("o_pending_store", 0)
    await b.set(i_maint_valid=1)
    await b.wait("o_maint_done")
    await b.set(i_maint_valid=0)
    assert await b.dma(addresses[0]) & ((1 << 64) - 1) == 0x11223344


@cocotb.test()
async def sc_self_probe_and_exact_write(dut: Any) -> None:
    """Check selected SC ownership through its self probe and tagged write."""
    b = Cluster(dut)
    await b.reset()
    address = 0x80000000
    await b.store(address, 91)
    await b.wait("o_pending_store", 0)
    assert await b.read(address, kind=1) == 91
    await b.set(
        i_reservation_valid=1,
        i_reservation_addr=address,
        i_reservation_size=3,
        i_sc_address=address,
        i_sc_size=3,
        i_sc_tag=7,
        i_sc_valid=1,
    )
    await b.wait("o_sc_ready")
    await b.tick()
    await b.set(i_sc_valid=0)
    await b.wait("o_sc_result_valid")
    assert b.get("o_sc_success") and not b.get("o_sc_error")
    assert b.get("i_reservation_valid")
    for _ in range(20):
        assert b.get("o_sc_write_pending")
        assert b.get("o_atomic_live") and b.sc_writes == []
        await b.tick()
    await b.set(i_sc_result_ready=1)
    await b.tick()
    await b.set(i_sc_result_ready=0, i_sc_commit=1)
    await b.tick()
    await b.set(i_sc_commit=0)
    await b.tick(20)
    assert b.get("o_sc_write_pending") and b.get("o_block_valid") & 2
    await b.store(address, 92, atomic=True)
    await b.wait("o_sc_write_pending", 0)
    assert b.sc_writes == [7]
    assert await b.dma(address) & ((1 << 64) - 1) == 92
    await b.dma(address, 100, 255)
    assert not b.get("i_reservation_valid")
    await b.set(i_sc_valid=1)
    await b.wait("o_sc_ready")
    await b.tick()
    await b.set(i_sc_valid=0)
    await b.wait("o_sc_result_valid")
    assert not b.get("o_sc_success") and not b.get("o_sc_error")


@cocotb.test()
async def amo_holds_home_until_exact_write(dut: Any) -> None:
    """Check AMO publication before a queued DMA read."""
    b = Cluster(dut)
    await b.reset()
    address = 0x80000000
    await b.store(address, 17)
    await b.wait("o_pending_store", 0)
    await b.set(i_read_tag=11)
    assert await b.read(address, kind=2) == 17
    assert b.get("o_atomic_live")
    q = pack((2, 2), (2, 3), (4, 9), (1, 0))
    await b.set(
        i_agent_valid=1,
        i_agent_d=pack(
            (4, 7),
            (9, q),
            (b.p, address),
            (5, 0),
            (3, 5),
            (32, 0),
            (1, 0),
            (1, 0),
            (1, 0),
            (256, 0),
        ),
    )
    await b.tick(20)
    assert not b.get("o_agent_ready") and not b.get("o_agent_g_valid")
    await b.set(
        i_write_atomic=1,
        i_write_sc=0,
        i_write_tag=11,
        i_address=address,
        i_write_mask=255,
        i_write_data=18,
    )
    await b.tick()
    await b.set(i_write_mask=0)
    await b.wait("o_write_done")
    assert not b.get("o_sc_write_done")
    await b.wait("o_agent_ready")
    await b.tick()
    await b.set(i_agent_valid=0)
    await b.wait("o_agent_g_valid")
    grant = unpack(b.get("o_agent_g"), (3, 9, 6, b.p, 256, 1))
    assert grant[4] & ((1 << 64) - 1) == 18


@cocotb.test()
async def full_read_queue_yields_to_probe_and_responses_rotate(dut: Any) -> None:
    """Check dirty shared/invalidation replies with all CPU read IDs occupied."""
    for write in (False, True):
        b = Cluster(dut)
        await b.reset()
        address = 0x80000000
        await b.store(address, 0x1234)
        await b.wait("o_pending_store", 0)
        for slot in range(8):
            await b.set(
                i_read_valid=1,
                i_read_id=slot,
                i_read_kind=0,
                i_read_size=3,
                i_address=address,
            )
            await b.tick()
        await b.set(i_read_valid=0)
        await b.tick(150)
        assert b.get("o_read_valid")
        if write:
            await b.dma(address, 0xCD, mask=1)
            assert address in b.cuts
        else:
            assert await b.dma(address) & ((1 << 64) - 1) == 0x1234
        seen = []
        for _ in range(8):
            await b.wait("o_read_valid")
            seen.append(b.get("o_read_id"))
            assert b.get("o_read_data") == 0x1234
            await b.set(i_read_ready=1)
            await b.tick()
            await b.set(i_read_ready=0)
            if seen[-1] < 2:
                await b.set(i_read_valid=1, i_read_id=seen[-1])
                await b.tick()
                await b.set(i_read_valid=0)
            await b.tick(17)
        assert sorted(seen) == list(range(8))
        if write:
            assert await b.dma(address) & ((1 << 64) - 1) == 0x12CD


@cocotb.test()
async def maintenance_yields_with_unprotected_amo_and_read_traffic(dut: Any) -> None:
    """Line maintenance completes beside a waiting AMO and continued read hits."""
    b = Cluster(dut)
    await b.reset()
    address, other = 0x80000000, 0x80000040
    await b.store(address, 73)
    await b.wait("o_pending_store", 0)
    assert await b.read(other) == 0
    await b.set(
        i_atomic_protected=0,
        i_read_valid=1,
        i_read_id=7,
        i_read_kind=2,
        i_address=other,
    )
    await b.tick()
    await b.set(
        i_read_valid=0, i_maint_valid=1, i_maint_line=1, i_maint_address=address
    )
    outstanding = False
    returned = 0
    for _ in range(400):
        if b.get("o_maint_done"):
            break
        if b.get("o_read_valid"):
            assert b.get("o_read_id") == 0
            await b.set(i_read_ready=1)
            await b.tick()
            await b.set(i_read_ready=0)
            outstanding = False
            returned += 1
        if not outstanding:
            await b.set(i_read_valid=1, i_read_id=0, i_read_kind=0, i_address=other)
            await b.tick()
            await b.set(i_read_valid=0)
            outstanding = True
        await b.tick()
    else:
        raise AssertionError("maintenance starved under read traffic")
    assert returned > 0
    await b.set(i_maint_valid=0)
    assert not b.get("o_atomic_live")
    assert await b.dma(address) & ((1 << 64) - 1) == 73


@cocotb.test()
async def sc_permissions_sizes_and_repeated_progress(dut: Any) -> None:
    """Check SC from I/S/M, exact reservation matching, and repeated writes."""
    for initial in (0, 2, 3):
        b = Cluster(dut)
        await b.reset()
        address = 0x80000000
        b.memory[address] = 91
        if initial == 2:
            assert await b.read(address, kind=1) == 91
        elif initial == 3:
            await b.store(address, 91)
            await b.wait("o_pending_store", 0)
        for iteration in range(3):
            await b.set(
                i_reservation_valid=1,
                i_reservation_addr=address,
                i_reservation_size=3,
                i_sc_address=address,
                i_sc_size=3,
                i_sc_tag=7,
                i_sc_valid=1,
            )
            await b.wait("o_sc_ready")
            await b.tick()
            await b.set(i_sc_valid=0)
            await b.wait("o_sc_result_valid")
            assert b.get("o_sc_success") and not b.get("o_sc_error")
            await b.set(i_sc_result_ready=1, i_sc_commit=1)
            await b.tick()
            await b.set(i_sc_result_ready=0, i_sc_commit=0)
            await b.store(address, 92 + iteration, atomic=True)
            await b.wait("o_atomic_live", 0)
            assert b.sc_writes == [7] * (iteration + 1)
        assert await b.dma(address) & ((1 << 64) - 1) == 94
        for reserved_address, reserved_size in ((address, 2), (address + 8, 3)):
            await b.set(
                i_reservation_valid=1,
                i_reservation_addr=reserved_address,
                i_reservation_size=reserved_size,
                i_sc_valid=1,
            )
            await b.wait("o_sc_ready")
            await b.tick()
            await b.set(i_sc_valid=0)
            await b.wait("o_sc_result_valid")
            assert not b.get("o_sc_success") and not b.get("o_sc_error")
            assert b.sc_writes == [7] * 3
            await b.set(i_sc_result_ready=1)
            await b.tick()
            await b.set(i_sc_result_ready=0)
            await b.wait("o_atomic_live", 0)


@cocotb.test()
async def registered_store_survives_maintenance_entry(dut: Any) -> None:
    """Check a registered SQ write after its launch credit meets a line clean."""
    b = Cluster(dut)
    await b.reset()
    address = 0x80000000
    await b.store(address, 55)
    await b.wait("o_pending_store", 0)
    await b.wait("o_store_ready")
    await b.tick()
    await b.set(
        i_maint_valid=1,
        i_maint_line=1,
        i_maint_address=address,
        i_address=address,
        i_write_data=99,
        i_write_mask=255,
        i_write_atomic=0,
    )
    assert not b.get("o_store_ready")
    await b.tick()
    await b.set(i_write_mask=0)
    await b.wait("o_write_done")
    await b.wait("o_pending_store", 0)
    await b.wait("o_maint_done")
    await b.set(i_maint_valid=0)
    await b.tick()
    assert await b.dma(address) & ((1 << 64) - 1) == 99


@cocotb.test()
async def test_demand_counters_exclude_probe_and_maintenance(dut: Any) -> None:
    """Count one demand decision across retries and private dirty probes."""
    cluster = Cluster(dut)
    await cluster.reset()
    assert await cluster.read(0x8000) == 0
    await cluster.tick(10)
    assert cluster.perf["l1d"][:3] == [1, 0, 1]
    assert cluster.perf["l2"][:3] == [1, 0, 1]
    assert cluster.perf["l1d"][4] > 0 and cluster.perf["l2"][4] > 0
    assert await cluster.read(0x8000) == 0
    await cluster.tick(10)
    assert cluster.perf["l1d"][:3] == [2, 1, 1]
    assert cluster.perf["l2"][:3] == [1, 0, 1]
    await cluster.store(0x8000, 0x12345678)
    await cluster.wait("o_pending_store", 0)
    await cluster.tick(10)
    assert cluster.perf["l1d"][:3] == [3, 1, 2]
    assert cluster.perf["l2"][:3] == [2, 1, 1]
    before = cluster.perf["l1d"][:4]
    assert (await cluster.dma(0x8000)) & ((1 << 64) - 1) == 0x12345678
    await cluster.tick(10)
    assert cluster.perf["l1d"][:4] == before
    assert cluster.perf["l2"][:3] == [3, 2, 1]
    await cluster.dma(0xA000, data=0xABCDEF, mask=255)
    await cluster.tick(10)
    assert cluster.perf["l2_write"][0] == 1
    assert cluster.perf["l2_write"][1] > 0
    assert cluster.perf["l1d"][:4] == before
    await cluster.store(0x8000, 0x98765432)
    await cluster.wait("o_pending_store", 0)
    await cluster.tick(10)
    before_l1d = cluster.perf["l1d"][:4]
    before_l2 = cluster.perf["l2"][:4]
    await cluster.set(i_maint_valid=1, i_maint_line=0)
    await cluster.wait("o_maint_done")
    await cluster.set(i_maint_valid=0)
    await cluster.tick(10)
    assert cluster.perf["l1d"][:4] == before_l1d
    assert cluster.perf["l2"][:4] == before_l2
