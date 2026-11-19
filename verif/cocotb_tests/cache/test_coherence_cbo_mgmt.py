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

"""Zicbom cbo.clean, cbo.flush and cbo.inval through the L1D and the home.

Each test drives the hart's Zicbom requester (coherence_cmo_agent) as the
store queue does, after the older stores have installed, and checks the
behavioral memory as a non-coherent agent would see it: after a clean or a
flush the memory holds the latest coherent bytes of the block, after an
invalidate the memory is unchanged and the next load returns its bytes, and
after a clean no later eviction rewrites the block.
"""

from typing import Any

import cocotb

from cocotb_tests.cache.test_coherence_cluster import Cluster

BLOCK = 64
INVAL, CLEAN, FLUSH = 0, 1, 2
KIND_NAME = {INVAL: "inval", CLEAN: "clean", FLUSH: "flush"}
MASK64 = (1 << 64) - 1


def word(seed: int, index: int) -> int:
    """Return a distinct 64-bit word for a seed and a dword index."""
    return ((seed * 0x9E3779B97F4A7C15) ^ (index * 0x0101010101010101) ^ 0xA5) & MASK64


class CmoCluster(Cluster):
    """Drive the Zicbom requester and record memory writes."""

    def __init__(self, dut: Any) -> None:
        """Record each memory write's line address and data."""
        super().__init__(dut)
        self.memory_writes: list[tuple[int, int, int]] = []
        self.cmo_dones = 0

    async def tick(self, count: int = 1) -> None:
        """Advance, recording writes accepted by memory."""
        for _ in range(count):
            if (
                self.get("o_mem_req_valid")
                and self.get("i_mem_req_ready")
                and self.get("o_mem_req_write")
            ):
                self.memory_writes.append(
                    (self.cycle, self.get("o_mem_req_addr"), self.get("o_mem_req_data"))
                )
            self.cmo_dones += self.get("o_cmo_done")
            await super().tick()

    async def cmo_launch(self, kind: int, address: int) -> int:
        """Hand one block to the requester; return the done count to wait for."""
        await self.wait("o_pending_store", 0)
        await self.set(i_cmo_valid=1, i_cmo_kind=kind, i_cmo_addr=address)
        await self.wait("o_cmo_ready")
        await self.tick()
        await self.set(i_cmo_valid=0)
        return self.cmo_dones + 1

    async def cmo_wait(self, count: int) -> None:
        """Wait for the requester's done pulse, which may come during a DMA."""
        for _ in range(4000):
            if self.cmo_dones >= count:
                return
            await self.tick()
        raise AssertionError(f"no CMO done at cycle {self.cycle}")

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
            i_write_tag=7,
        )
        await self.tick()
        await self.set(i_write_mask=0)
        await self.wait("o_write_done")
        await self.tick()

    def reads_of(self, block: int) -> int:
        """Count memory reads of a block's lines."""
        return sum(1 for a in self.memory_reads if block <= a < block + BLOCK)

    def writes_of(self, block: int) -> int:
        """Count memory writes to a block's lines."""
        return sum(1 for w in self.memory_writes if block <= w[1] < block + BLOCK)

    def memory_dword(self, address: int) -> int:
        """Read a dword of the behavioral memory (a non-coherent view)."""
        line = address & -self.line
        return (self.memory.get(line, 0) >> (8 * (address - line))) & MASK64

    def preload(self, block: int, seed: int) -> None:
        """Fill a block's memory lines with words of a seed."""
        for line in range(block, block + BLOCK, self.line):
            value = 0
            for d in range(self.line // 8):
                value |= word(seed, (line - block) // 8 + d) << (64 * d)
            self.memory[line] = value

    async def cmo(self, kind: int, address: int) -> None:
        """Present one block to the requester as the store queue does.

        The store queue launches a CMO only after the older stores have
        installed in the L1D, then waits for the requester's done.
        """
        await self.cmo_wait(await self.cmo_launch(kind, address))

    async def fill_block(self, block: int, seed: int, dwords: range = range(8)) -> None:
        """Store words of a seed to some dwords of a block."""
        for d in dwords:
            await self.store(block + 8 * d, word(seed, d))

    async def expect_block(self, block: int, values: list[int]) -> None:
        """Read every dword of a block through the L1D."""
        for d, want in enumerate(values):
            got = await self.read(block + 8 * d)
            assert got == want, f"{block + 8 * d:#x}: {got:#x} != {want:#x}"

    def expect_memory(self, block: int, values: list[int]) -> None:
        """Compare the behavioral memory's view of a block."""
        for d, want in enumerate(values):
            got = self.memory_dword(block + 8 * d)
            assert got == want, f"memory {block + 8 * d:#x}: {got:#x} != {want:#x}"


async def start(dut: Any) -> CmoCluster:
    """Reset a cluster for a test."""
    c = CmoCluster(dut)
    await c.reset()
    return c


@cocotb.test()
async def cmo_dirty_l1d_block(dut: Any) -> None:
    """Clean and flush write an L1D-Modified block to memory; inval drops it."""
    c = await start(dut)
    for n, kind in enumerate((CLEAN, FLUSH, INVAL)):
        block = 0x80001000 + 0x400 * n
        c.preload(block, 0x10 + n)
        old = [word(0x10 + n, d) for d in range(8)]
        new = [word(0x20 + n, d) for d in range(8)]
        await c.fill_block(block, 0x20 + n)
        writes = c.writes_of(block)
        await c.cmo(kind, block + 0x13)
        if kind == INVAL:
            assert c.writes_of(block) == writes, "inval wrote memory"
            c.expect_memory(block, old)
            await c.expect_block(block, old)
        else:
            assert c.writes_of(block) > writes, f"{KIND_NAME[kind]} wrote nothing"
            c.expect_memory(block, new)
            await c.expect_block(block, new)
        # The block's memory stays as the CMO left it.
        c.expect_memory(block, old if kind == INVAL else new)


@cocotb.test()
async def cmo_half_dirty(dut: Any) -> None:
    """Only one sector of the block dirty: the whole block's latest bytes land."""
    c = await start(dut)
    for n, (kind, upper) in enumerate(
        [(CLEAN, 0), (CLEAN, 1), (FLUSH, 0), (FLUSH, 1), (INVAL, 0), (INVAL, 1)]
    ):
        block = 0x80002000 + 0x400 * n
        c.preload(block, 0x30 + n)
        old = [word(0x30 + n, d) for d in range(8)]
        dirty = range(4, 8) if upper else range(4)
        await c.fill_block(block, 0x40 + n, dirty)
        new = [word(0x40 + n, d) if d in dirty else old[d] for d in range(8)]
        await c.cmo(kind, block)
        want = old if kind == INVAL else new
        c.expect_memory(block, want)
        await c.expect_block(block, want)


@cocotb.test()
async def cmo_l2_dirty_only(dut: Any) -> None:
    """Check that a DMA write leaves the line dirty in the L2 alone."""
    c = await start(dut)
    for n, kind in enumerate((CLEAN, FLUSH, INVAL)):
        block = 0x80003000 + 0x400 * n
        c.preload(block, 0x50 + n)
        old = [word(0x50 + n, d) for d in range(8)]
        sector = 0
        for d in range(4):
            sector |= word(0x60 + n, d) << (64 * d)
        await c.dma(block + 32, sector)
        new = old[:4] + [word(0x60 + n, d) for d in range(4)]
        await c.cmo(kind, block)
        want = old if kind == INVAL else new
        c.expect_memory(block, want)
        await c.expect_block(block, want)


@cocotb.test()
async def cmo_clean_and_absent_blocks(dut: Any) -> None:
    """Clean resident or absent blocks need no memory write."""
    c = await start(dut)
    for n, kind in enumerate((CLEAN, FLUSH, INVAL)):
        absent = 0x80004000 + 0x400 * n
        c.preload(absent, 0x70 + n)
        await c.cmo(kind, absent)
        assert c.writes_of(absent) == 0 and c.reads_of(absent) == 0
        resident = absent + 0x200
        c.preload(resident, 0x78 + n)
        values = [word(0x78 + n, d) for d in range(8)]
        await c.expect_block(resident, values)
        reads = c.reads_of(resident)
        await c.cmo(kind, resident)
        assert c.writes_of(resident) == 0
        await c.expect_block(resident, values)
        if kind != CLEAN:
            # The flushed or invalidated line comes back from memory.
            assert c.reads_of(resident) > reads


@cocotb.test()
async def cmo_clean_then_no_rewrite(dut: Any) -> None:
    """After a clean no eviction rewrites the block until a later store.

    A non-coherent agent writes the block's memory after the clean; evicting
    every line of the home's sets must leave that write in place. An inval
    then exposes it to loads.
    """
    c = await start(dut)
    block = 0x80005000
    c.preload(block, 0x80)
    await c.fill_block(block, 0x81)
    await c.cmo(CLEAN, block)
    c.expect_memory(block, [word(0x81, d) for d in range(8)])
    c.preload(block, 0x82)
    agent = [word(0x82, d) for d in range(8)]
    # Fill and dirty more lines than the home has ways in every set.
    home_bytes = 512
    for k in range(1, 9):
        other = block + k * home_bytes
        await c.store(other, k)
        await c.store(other + 32, k)
    for k in range(1, 9):
        await c.read(block + k * home_bytes + 8)
    c.expect_memory(block, agent)
    await c.cmo(INVAL, block)
    await c.expect_block(block, agent)


@cocotb.test()
async def cmo_program_order(dut: Any) -> None:
    """Run stores, CMOs and loads of one block in program order."""
    c = await start(dut)
    block = 0x80006000
    c.preload(block, 0x90)
    await c.store(block, 0x1111)
    await c.cmo(FLUSH, block)
    assert await c.read(block) == 0x1111
    await c.store(block + 40, 0x2222)
    await c.cmo(CLEAN, block + 40)
    assert c.memory_dword(block) == 0x1111 and c.memory_dword(block + 40) == 0x2222
    await c.store(block + 8, 0x3333)
    await c.cmo(CLEAN, block)
    await c.store(block + 8, 0x4444)
    assert await c.read(block + 8) == 0x4444
    assert c.memory_dword(block + 8) == 0x3333
    await c.cmo(FLUSH, block)
    assert c.memory_dword(block + 8) == 0x4444
    # Back-to-back blocks.
    for k in range(6):
        await c.store(block + 0x100 + 64 * k, k + 7)
    for k in range(6):
        await c.cmo((CLEAN, FLUSH)[k % 2], block + 0x100 + 64 * k)
    for k in range(6):
        assert c.memory_dword(block + 0x100 + 64 * k) == k + 7
        assert await c.read(block + 0x100 + 64 * k) == k + 7


@cocotb.test()
async def cmo_dma_race(dut: Any) -> None:
    """DMA reads and writes of the block at every delay around a flush.

    The coherent value after both is the DMA's (the home orders them), and a
    DMA read sees the CPU's stores.
    """
    c = await start(dut)
    for delay in range(0, 60, 4):
        block = 0x80008000 + 0x200 * delay
        c.preload(block, delay)
        await c.fill_block(block, 0x100 + delay)
        sector = 0
        for d in range(4):
            sector |= word(0x200 + delay, d) << (64 * d)
        done = await c.cmo_launch(FLUSH, block)
        await c.tick(delay)
        await c.dma(block + 32, sector)
        await c.cmo_wait(done)
        await c.tick(2)
        want = [word(0x100 + delay, d) for d in range(4)] + [
            word(0x200 + delay, d) for d in range(4)
        ]
        await c.expect_block(block, want)
        data = await c.dma(block)
        for d in range(4):
            assert (data >> (64 * d)) & MASK64 == want[d]
        await c.cmo(FLUSH, block)
        c.expect_memory(block, want)


@cocotb.test()
async def cmo_frozen_putm(dut: Any) -> None:
    """Clean a block whose dirty sector the L1D is writing back as a PutM.

    Stores to more sectors of one L1D set than it has ways evict a dirty
    sector; a clean of that block right behind the stores reaches the home
    while the PutM is in flight or absorbed.
    """
    c = await start(dut)
    l1d_set_stride = 1024 // 4
    base = 0x8000C000
    for k in range(6):
        await c.store(base + k * l1d_set_stride, 0x500 + k)
    for k in range(6):
        await c.cmo(CLEAN, base + k * l1d_set_stride)
        assert c.memory_dword(base + k * l1d_set_stride) == 0x500 + k
    for k in range(6):
        assert await c.read(base + k * l1d_set_stride) == 0x500 + k
