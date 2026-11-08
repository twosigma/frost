#    Copyright (c) 2026 John Goodacre.
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

"""Line-scope cbo.zero through the L1D and the home (see the cache README).

Each test drives the L1D's cbo.zero write, one operation for a 64-byte block,
beside CPU loads, stores and agent DMA, and checks every byte's final value
and that a zero fill reads no memory.
"""

from typing import Any

import cocotb

from cocotb_tests.cache.test_coherence_cluster import Cluster

BLOCK = 64
PATTERN = 0x1122334455667788


def line_pattern(line_bytes: int, seed: int) -> int:
    """Return a nonzero line image of 64-bit words seeded by seed."""
    value = 0
    for word in range(line_bytes // 8):
        value |= ((PATTERN ^ (seed * 0x0101010101010101 + word)) & ((1 << 64) - 1)) << (
            64 * word
        )
    return value


class ZeroCluster(Cluster):
    """Drive the cluster with cbo.zero writes and count twin installations."""

    def __init__(self, dut: Any) -> None:
        """Count the L1D's twin installations under a GrantMZero."""
        super().__init__(dut)
        self.twin_installs = 0
        self.twin_owed = 0

    async def tick(self, count: int = 1) -> None:
        """Advance, counting each GrantMZero whose twin the L1D then owes."""
        for _ in range(count):
            await super().tick()
            owed = int(self.dut.hart.twin_fill_q.value)
            if owed and not self.twin_owed:
                self.twin_installs += 1
            self.twin_owed = owed

    def preload(self, block: int, seed: int) -> None:
        """Fill the memory lines of a block with a nonzero pattern."""
        for line in range(block, block + BLOCK, self.line):
            self.memory[line] = line_pattern(self.line, seed + line)

    async def cbo_zero(self, address: int) -> None:
        """Issue the store queue's cached cbo.zero write and wait for its done.

        Like the store queue, the write follows the cycle whose readiness it
        uses: a zero write lowers readiness on its own cycle.
        """
        await self.wait("o_store_ready")
        await self.tick()
        await self.set(
            i_address=address & -BLOCK,
            i_write_data=0,
            i_write_mask=255,
            i_write_atomic=0,
            i_write_sc=0,
            i_write_zero=1,
            i_write_tag=5,
        )
        await self.tick()
        await self.set(i_write_mask=0, i_write_zero=0)
        await self.wait("o_write_done")
        await self.tick()

    async def store(
        self, address: int, value: int, mask: int = 255, atomic: bool = False
    ) -> None:
        """Present a scalar store on the cycle after the readiness it uses."""
        assert not atomic
        await self.wait("o_store_ready")
        await self.tick()
        await self.set(
            i_address=address,
            i_write_data=value,
            i_write_mask=mask,
            i_write_atomic=0,
            i_write_sc=0,
            i_write_zero=0,
            i_write_tag=7,
        )
        await self.tick()
        await self.set(i_write_mask=0)
        await self.wait("o_write_done")
        await self.tick()

    def reads_of(self, block: int) -> int:
        """Count memory reads of a block's lines."""
        return sum(1 for a in self.memory_reads if block <= a < block + BLOCK)

    async def check_block(
        self, block: int, expect: dict[int, int] | None = None
    ) -> None:
        """Read every dword of a block through the L1D and the agent."""
        expect = expect or {}
        for offset in range(0, BLOCK, 8):
            want = expect.get(offset, 0)
            got = await self.read(block + offset)
            assert got == want, f"{block + offset:#x}: {got:#x} != {want:#x}"
        for sector in (0, 32):
            data = await self.dma(block + sector)
            for word in range(4):
                want = expect.get(sector + 8 * word, 0)
                got = (data >> (64 * word)) & ((1 << 64) - 1)
                assert got == want, f"DMA {block + sector + 8 * word:#x}: {got:#x}"


@cocotb.test()
async def cbo_zero_fill_reads_no_memory(dut: Any) -> None:
    """Install a block the home lacks as zeros without a memory read."""
    b = ZeroCluster(dut)
    await b.reset()
    block = 0x80000400
    b.preload(block, 1)
    await b.cbo_zero(block)
    await b.wait("o_pending_store", 0)
    assert b.reads_of(block) == 0
    assert b.twin_installs == (1 if b.line == 64 else 0)
    await b.check_block(block)
    assert b.reads_of(block) == 0


@cocotb.test()
async def cbo_zero_dma_write_in_window(dut: Any) -> None:
    """Race a DMA write to the upper sector against a cbo.zero at every delay.

    The write reaches the home before the block's GetMZero, during it, or after
    it. A write that reaches the home first misses and reads the block from
    memory. Without that read the block was zero-filled before the write, so
    the write's bytes must survive: zeros installed again after the zero fill
    would leave 0, D, 0.
    """
    b = ZeroCluster(dut)
    await b.reset()
    zero_filled = 0
    for delay in range(0, 48, 3):
        block = 0x80004000 + 0x200 * delay
        b.preload(block, 0x40 + delay)
        written = line_pattern(32, 0x5A + delay)
        await b.cbo_zero(block)
        await b.tick(delay)
        await b.dma(block + 32, written)
        await b.wait("o_pending_store", 0)
        upper = await b.read(block + 32)
        kept = upper == written & ((1 << 64) - 1)
        assert kept or upper == 0, f"delay {delay}: {upper:#x}"
        if b.reads_of(block) == 0:
            zero_filled += 1
            assert kept, f"delay {delay}: the upper zeros were performed twice"
        expect = (
            {32 + 8 * w: (written >> (64 * w)) & ((1 << 64) - 1) for w in range(4)}
            if kept
            else {}
        )
        await b.check_block(block, expect)
    assert zero_filled > 0


@cocotb.test()
async def cbo_zero_dma_read_during_install(dut: Any) -> None:
    """Read the upper sector by DMA during the operation: old data or zeros.

    A read that returns zeros follows the block's zeros; one that returns the
    old data precedes them, and its line came from memory. The block then
    reads as zeros.
    """
    b = ZeroCluster(dut)
    await b.reset()
    for delay in range(0, 48, 3):
        block = 0x80008000 + 0x200 * delay
        b.preload(block, 0x80 + delay)
        upper = block + 32
        old = (b.memory[upper & -b.line] >> (8 * (upper & (b.line - 1)))) & (
            (1 << 256) - 1
        )
        await b.cbo_zero(block)
        await b.tick(delay)
        data = await b.dma(upper)
        assert data in (0, old), f"delay {delay}: {data:#x}"
        if data == old:
            assert b.reads_of(block) != 0
        await b.wait("o_pending_store", 0)
        await b.check_block(block)


@cocotb.test()
async def cbo_zero_upgrades_stale_shared_copy(dut: Any) -> None:
    """Upgrade a Shared copy that outlived the home's line to the twin's zeros."""
    b = ZeroCluster(dut)
    await b.reset()
    block = 0x80000C00
    b.preload(block, 4)
    upper = block + 32
    stale = (b.memory[upper & -b.line] >> (8 * (upper & (b.line - 1)))) & (
        (1 << 64) - 1
    )
    assert await b.read(upper) == stale
    # Lines one home way apart replace the block in the home, a set of four
    # ways, while the L1D keeps its clean copy of the upper sector.
    sets = 512 // (b.line * 4)
    for k in range(1, 6):
        await b.read(block + k * b.line * sets)
    await b.tick(40)
    reads = b.reads_of(block)
    await b.cbo_zero(block)
    await b.wait("o_pending_store", 0)
    await b.check_block(block)
    assert b.reads_of(block) == reads


@cocotb.test()
async def cbo_zero_dirty_resident_block(dut: Any) -> None:
    """Zero a block held dirty in both sectors through Modified hits."""
    b = ZeroCluster(dut)
    await b.reset()
    block = 0x80001000
    b.preload(block, 5)
    await b.store(block + 8, 0xAAAA)
    await b.store(block + 40, 0xBBBB)
    await b.wait("o_pending_store", 0)
    await b.cbo_zero(block)
    await b.wait("o_pending_store", 0)
    assert b.twin_installs == 0
    await b.check_block(block)


@cocotb.test()
async def cbo_zero_stores_and_loads_in_program_order(dut: Any) -> None:
    """Zero blocks back to back with stores before and after and loads behind."""
    b = ZeroCluster(dut)
    await b.reset()
    blocks = [0x80001400 + BLOCK * k for k in range(4)]
    for k, block in enumerate(blocks):
        b.preload(block, 6 + k)
    await b.store(blocks[0] + 16, 0x1111)
    await b.cbo_zero(blocks[0])
    await b.cbo_zero(blocks[1])
    await b.store(blocks[0] + 48, 0x2222)
    await b.cbo_zero(blocks[2])
    await b.store(blocks[2] + 8, 0x3333)
    await b.cbo_zero(blocks[3])
    await b.cbo_zero(blocks[3])
    assert await b.read(blocks[0] + 48) == 0x2222
    assert await b.read(blocks[0] + 16) == 0
    await b.wait("o_pending_store", 0)
    await b.check_block(blocks[0], {48: 0x2222})
    await b.check_block(blocks[1])
    await b.check_block(blocks[2], {8: 0x3333})
    await b.check_block(blocks[3])
    # The first block's store misses before its cbo.zero; the others start
    # with a cbo.zero and read no memory.
    for block in blocks[1:]:
        assert b.reads_of(block) == 0, f"{block:#x} read memory"


@cocotb.test()
async def cbo_zero_with_dma_traffic_on_both_sectors(dut: Any) -> None:
    """Land DMA writes beside a run of blocks in an order consistent with each.

    Each DMA write races a cbo.zero of its block; afterwards each written
    sector holds either all of its write or all zeros, consistently for the L1D
    and the agent.
    """
    b = ZeroCluster(dut)
    await b.reset()
    blocks = [0x80002000 + BLOCK * k for k in range(6)]
    for k, block in enumerate(blocks):
        b.preload(block, 20 + k)
    written = {}
    for k, block in enumerate(blocks):
        sector = block + (32 if k % 2 else 0)
        data = line_pattern(32, 0x30 + k)
        written[block] = (sector - block, data)
        await b.cbo_zero(block)
        await b.dma(sector, data)
    await b.wait("o_pending_store", 0)
    for block in blocks:
        offset, data = written[block]
        first = await b.read(block + offset)
        whole = first == (data & ((1 << 64) - 1))
        assert whole or first == 0, f"{block + offset:#x}: {first:#x}"
        expect = (
            {offset + 8 * w: (data >> (64 * w)) & ((1 << 64) - 1) for w in range(4)}
            if whole
            else {}
        )
        await b.check_block(block, expect)
