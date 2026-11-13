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

"""The hart's line client against the L1D and the home.

The line client makes sector reads and masked sector writes under the hart's
own source. A read must see the L1D's dirty data; a write must replace the
bytes it masks, keep the others, and leave the L1D without a stale copy.
Every check compares with a byte-level reference memory.
"""

import random
from typing import Any

import cocotb

from cocotb_tests.cache.test_coherence_cluster import Cluster

SECTOR = 32
BASE = 0x8000_0000


class LineCluster(Cluster):
    """The cluster bench with the line client's request and response ports."""

    def __init__(self, dut: Any) -> None:
        """Track a byte-level reference memory beside the cluster's state."""
        super().__init__(dut)
        self.ref: dict[int, int] = {}

    def ref_byte(self, address: int) -> int:
        """Return the reference byte at address (memory starts zero)."""
        return self.ref.get(address, 0)

    def ref_bytes(self, address: int, count: int) -> int:
        """Return count reference bytes from address, little-endian."""
        return sum(self.ref_byte(address + i) << (8 * i) for i in range(count))

    async def line_request(
        self, address: int, ident: int, data: int | None = None, mask: int = 0
    ) -> None:
        """Present one line-client request until the client takes it."""
        await self.set(
            i_line_req_valid=1,
            i_line_req_write=int(data is not None),
            i_line_req_addr=address,
            i_line_req_data=data or 0,
            i_line_req_mask=mask,
            i_line_req_id=ident,
        )
        await self.wait("o_line_req_ready")
        await self.tick()
        await self.set(i_line_req_valid=0)

    async def line_response(self) -> tuple[int, int, int]:
        """Wait for one response and return (id, data, error)."""
        await self.wait("o_line_resp_valid")
        response = (
            self.get("o_line_resp_id"),
            self.get("o_line_resp_data"),
            self.get("o_line_resp_error"),
        )
        await self.tick()
        return response

    async def line_read(self, address: int, ident: int = 0) -> int:
        """Read one sector through the line client."""
        await self.line_request(address, ident)
        rid, data, error = await self.line_response()
        assert rid == ident and not error
        return data

    async def line_write(
        self, address: int, data: int, mask: int, ident: int = 0
    ) -> None:
        """Write the masked bytes of one sector through the line client."""
        await self.line_request(address, ident, data, mask)
        rid, _, error = await self.line_response()
        assert rid == ident and not error
        for i in range(SECTOR):
            if (mask >> i) & 1:
                self.ref[address + i] = (data >> (8 * i)) & 0xFF

    async def l1d_store(self, address: int, value: int, mask: int) -> None:
        """Store through the L1D, wait for installation, and record the bytes.

        The core uses the line client only once every older store has left
        the L1D's store records (its committed-empty status), so the bench
        waits for the same condition.
        """
        await self.store(address, value, mask)
        await self.wait("o_pending_store", 0)
        for i in range(8):
            if (mask >> i) & 1:
                self.ref[address + i] = (value >> (8 * i)) & 0xFF

    def check_sector(self, address: int, data: int) -> None:
        """Compare a sector read with the reference."""
        expected = self.ref_bytes(address, SECTOR)
        assert data == expected, (hex(address), hex(data), hex(expected))


async def setup(dut: Any) -> LineCluster:
    """Reset the cluster with its line-client inputs idle."""
    cluster = LineCluster(dut)
    await cluster.reset()
    return cluster


@cocotb.test()
async def read_sees_dirty_l1d_data(dut: Any) -> None:
    """Check that a line read returns the bytes the L1D holds Modified."""
    cluster = await setup(dut)
    address = BASE + 0x1000
    await cluster.l1d_store(address + 8, 0x1122_3344_5566_7788, 0xFF)
    await cluster.l1d_store(address + 24, 0xA5, 0x01)
    cluster.check_sector(address, await cluster.line_read(address))


@cocotb.test()
async def write_replaces_masked_bytes_and_cuts_l1d_copy(dut: Any) -> None:
    """Check that a line write merges with dirty L1D data and later reads see it."""
    cluster = await setup(dut)
    address = BASE + 0x2040
    await cluster.l1d_store(address, 0x0102_0304_0506_0708, 0xFF)
    assert await cluster.read(address) == cluster.ref_bytes(address, 8)
    data = int.from_bytes(bytes(range(0x40, 0x60)), "little")
    mask = 0x00F0_0F3C
    await cluster.line_write(address, data, mask)
    for offset in range(0, SECTOR, 8):
        value = await cluster.read(address + offset)
        assert value == cluster.ref_bytes(address + offset, 8), hex(offset)
    cluster.check_sector(address, await cluster.line_read(address, ident=1))


@cocotb.test()
async def two_identities_in_flight(dut: Any) -> None:
    """Keep both identities outstanding at once and check each answer."""
    cluster = await setup(dut)
    first, second = BASE + 0x3000, BASE + 0x3020
    await cluster.l1d_store(second, 0xDEAD_BEEF, 0x0F)
    data = int.from_bytes(bytes(range(0x80, 0xA0)), "little")
    await cluster.line_request(first, 0, data, 0xFFFF_FFFF)
    await cluster.line_request(second, 1)
    seen: dict[int, tuple[int, int]] = {}
    for _ in range(2):
        rid, rdata, error = await cluster.line_response()
        assert not error and rid not in seen
        seen[rid] = (rdata, error)
    assert set(seen) == {0, 1}, seen
    for i in range(SECTOR):
        cluster.ref[first + i] = (data >> (8 * i)) & 0xFF
    cluster.check_sector(second, seen[1][0])
    cluster.check_sector(first, await cluster.line_read(first))


@cocotb.test()
async def random_mix_with_l1d_traffic(dut: Any) -> None:
    """Mix random L1D loads and stores with line reads and writes."""
    cluster = await setup(dut)
    rng = random.Random(11)
    sectors = [BASE + 0x4000 + SECTOR * i for i in range(6)] + [BASE + 0x8000]
    for _ in range(120):
        sector = rng.choice(sectors)
        choice = rng.random()
        if choice < 0.3:
            offset = 8 * rng.randrange(4)
            await cluster.l1d_store(
                sector + offset, rng.getrandbits(64), rng.getrandbits(8)
            )
        elif choice < 0.55:
            offset = 8 * rng.randrange(4)
            value = await cluster.read(sector + offset)
            assert value == cluster.ref_bytes(sector + offset, 8), hex(sector + offset)
        elif choice < 0.75:
            cluster.check_sector(
                sector, await cluster.line_read(sector, rng.randrange(2))
            )
        else:
            await cluster.line_write(
                sector, rng.getrandbits(256), rng.getrandbits(32), rng.randrange(2)
            )
    for sector in sectors:
        cluster.check_sector(sector, await cluster.line_read(sector))


@cocotb.test()
async def line_request_beside_dma(dut: Any) -> None:
    """Run a DMA write while a line read is in flight, on adjacent sectors."""
    cluster = await setup(dut)
    line_sector, dma_sector = BASE + 0x5000, BASE + 0x5020
    await cluster.l1d_store(line_sector, 0x55AA_55AA, 0x0F)
    await cluster.line_request(line_sector, 0)
    data = int.from_bytes(bytes(range(0xC0, 0xE0)), "little")
    await cluster.dma(dma_sector, data)
    for i in range(SECTOR):
        cluster.ref[dma_sector + i] = (data >> (8 * i)) & 0xFF
    rid, rdata, error = await cluster.line_response()
    assert rid == 0 and not error
    cluster.check_sector(line_sector, rdata)
    cluster.check_sector(dma_sector, await cluster.line_read(dma_sector, ident=1))
