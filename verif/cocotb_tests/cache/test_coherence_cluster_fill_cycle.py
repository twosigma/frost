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

"""Check progress with a younger store grant and a seated DMA reader."""

from collections.abc import Callable
from typing import Any

import cocotb

from cocotb_tests.cache.test_coherence_cluster_stress import (
    BASE,
    ClusterStress,
    DmaRequest,
)


class FillCycle(ClusterStress):
    """Gate memory read responses and the release channel independently."""

    def __init__(self, dut: Any) -> None:
        """Start with both channels unheld and no DMA request."""
        super().__init__(dut, 0)
        self.hold_reads = False
        self.hold_release = False
        self.dma: DmaRequest | None = None
        self.read_addresses: set[int] = set()

    async def drive_environment(self) -> None:
        """Deliver ready memory responses unless a read is held."""
        response = next(
            (
                response
                for response in self.responses
                if response[0] <= self.cycle
                and (response[1] & 16 or not self.hold_reads)
            ),
            None,
        )
        if response is not None:
            self.responses.remove(response)
            if response[1] & 16:
                self.complete_memory_write(response)
        self.cut_age = self.cut_age + 1 if self.get("o_cut_inval_valid") else 0
        if self.get("o_mem_req_valid") and not self.get("o_mem_req_write"):
            self.read_addresses.add(self.get("o_mem_req_addr"))
        await self.set(
            i_mem_resp_valid=int(response is not None),
            i_mem_resp_id=response[1] if response else 0,
            i_mem_resp_data=response[2] if response else 0,
            i_cut_admit_ready=1,
            i_cut_inval_done=int(self.cut_age >= 3),
            i_hold_release=int(self.hold_release),
        )

    async def step(self, count: int = 1) -> None:
        """Advance the cluster and its one active DMA request."""
        for _ in range(count):
            await self.drive_environment()
            self.dma = await self.step_dma(self.dma, finished=True)
            await self.edge()

    async def store(self, address: int, data: int) -> None:
        """Present an eight-byte store on the cycle after its credit."""
        await self.wait_for(lambda: self.get("o_store_ready"), "store credit")
        await self.step()
        await self.drive_environment()
        await self.set(i_address=address, i_write_data=data, i_write_mask=0xFF)
        self.record_store(address, data, 0xFF)
        await self.edge()
        await self.set(i_write_mask=0)

    async def wait_for(self, condition: Callable[[], int | bool], name: str) -> None:
        """Require the named event before its cycle budget expires."""
        for _ in range(2000):
            if condition():
                return
            await self.step()
        self.fail(f"timed out waiting for {name}")

    def read(self, sector: int) -> None:
        """Start a DMA read that checks the sector's final data."""
        assert self.dma is None
        self.dma = DmaRequest(sector, final=True)


@cocotb.test()
async def seated_reader_holds_fill_behind_younger_store(dut: Any) -> None:
    """Drain the head store while a reader holds the younger store's fill."""
    b = FillCycle(dut)
    await b.reset()
    resident, head, younger = BASE + 128, BASE, BASE + 64
    b.hold_release = True
    await b.store(resident, 0x11)
    await b.wait_for(lambda: not b.get("o_pending_store"), "resident store install")
    assert b.get("o_live_stores") == 1

    # The held release keeps endpoint 0 busy while the younger store takes
    # a fill through a borrowed endpoint. The reader then joins that fill.
    b.hold_reads = True
    await b.store(head, 0x22)
    await b.step(20)
    await b.store(younger, 0x33)
    await b.wait_for(lambda: younger in b.read_addresses, "younger store's memory read")
    assert head not in b.read_addresses
    mask = int(dut.home.fill_live_q.value)
    assert mask.bit_count() == 1
    fill = mask.bit_length() - 1
    seats = dut.home.fill_seat_count_q[fill]
    assert int(seats.value) == 1
    b.read(younger)
    await b.wait_for(
        lambda: int(seats.value) == 2, "DMA reader seated beside the younger store"
    )
    b.hold_reads = False
    await b.wait_for(lambda: b.hget("ep_grant_valid") & ~1, "held younger grant")
    assert b.dma is not None and b.dma.phase == 1
    assert int(dut.home.fill_live_q.value) == mask
    dut._log.info("cycle %d: younger store grant held, fill %#x", b.cycle, mask)

    # The head takes a second fill while the younger grant and reader wait.
    b.hold_release = False
    await b.wait_for(lambda: head in b.read_addresses, "head store's memory read")
    assert int(dut.home.fill_live_q.value).bit_count() == 2
    assert b.dma is not None and b.dma.phase == 1
    await b.wait_for(lambda: not b.get("o_pending_store"), "both stores drained")
    await b.wait_for(lambda: b.dma is None, "seated DMA read complete")
    assert b.installed == b.acks == b.pushed == 3
    dut._log.info("cycle %d: stores and seated reader drained", b.cycle)

    for sector in (resident, head):
        b.read(sector)
        await b.wait_for(lambda: b.dma is None, "final DMA read complete")
