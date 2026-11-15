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

"""Full-line stores through the L1D and the home (see the cache README).

Each test drives scalar stores the way the store queue launches them: on the
cycle after the readiness they use, at the store queue's cadence, with
i_write_more set while another committed store follows. A 64-byte block that
the stores cover completely acquires with GetMZero and installs without a
memory read; a partial block fills as before. Every test checks every byte's
final value through the L1D and through the agent port.
"""

import random
from collections import Counter
from typing import Any

import cocotb

from cocotb_tests.cache.test_coherence_cbo_zero import BLOCK, ZeroCluster, line_pattern
from cocotb_tests.cache.test_coherence_home import unpack

MASK64 = (1 << 64) - 1


def dword(seed: int, offset: int) -> int:
    """Return a nonzero store value for a block offset."""
    return (
        0x0123456789ABCDEF ^ (seed * 0x9E3779B97F4A7C15) ^ (offset * 0x0101)
    ) & MASK64


class FullCluster(ZeroCluster):
    """Drive store streams and track the expected memory image."""

    def __init__(self, dut: Any) -> None:
        """Track each dword's expected value beside the cbo.zero counters."""
        super().__init__(dut)
        self.expect: dict[int, int] = {}
        self.dones = 0
        self.pushes = 0
        # (cycle, endpoint, opcode, address, mask) of each accepted request.
        self.requests: list[tuple[int, int, int, int, int]] = []

    async def tick(self, count: int = 1) -> None:
        """Advance, counting write completions."""
        for _ in range(count):
            if self.get("o_write_done"):
                self.dones += 1
            if not self.get("i_rst"):
                accepted = int(self.dut.hart_d_valid.value) & int(
                    self.dut.hart_d_ready.value
                )
                for ep in range(len(self.dut.hart_d_valid)):
                    if accepted >> ep & 1:
                        width = self.p + 312
                        bits = (int(self.dut.hart_d.value) >> (width * ep)) & (
                            (1 << width) - 1
                        )
                        fields = unpack(bits, (4, 9, self.p, 5, 3, 32, 1, 1, 1, 256))
                        self.requests.append(
                            (self.cycle, ep, fields[0], fields[2], fields[5])
                        )
            await super().tick()

    def preload(self, block: int, seed: int) -> None:
        """Fill the block's memory lines and record the old dwords."""
        super().preload(block, seed)
        for offset in range(0, BLOCK, 8):
            address = block + offset
            line = address & -self.line
            self.expect[address] = (
                self.memory[line] >> (8 * (address - line))
            ) & MASK64

    async def stream(
        self,
        stores: list[tuple[int, int, int]],
        gap: int = 3,
        more: bool = True,
        more_last: bool = False,
        gaps: list[int] | None = None,
    ) -> None:
        """Launch scalar stores as the store queue does.

        A store writes on the cycle after a cycle with readiness, at least gap
        cycles (gaps[index] when given) after the previous store, with
        i_write_more set when another store of the list follows and more is
        set. more_last also sets it on the last store, as when the store queue
        flushes the uncommitted stores that the hint counted.
        """
        index = 0
        ready_prev = 0
        since = gaps[0] if gaps else gap

        def claim(nxt: int) -> int:
            """Return the store queue's claim that store nxt combines into store nxt - 1."""
            return int(
                more
                and 0 < nxt < len(stores)
                and stores[nxt][0] & -32 == stores[nxt - 1][0] & -32
            )

        while index < len(stores):
            write = ready_prev and since >= (gaps[index] if gaps else gap)
            if write:
                address, value, mask = stores[index]
                await self.set(
                    i_address=address,
                    i_write_data=value,
                    i_write_mask=mask,
                    i_write_atomic=0,
                    i_write_sc=0,
                    i_write_zero=0,
                    i_write_more=int(more and (index + 1 < len(stores) or more_last)),
                    i_next_same=claim(index + 1),
                    i_write_tag=7,
                )
            else:
                await self.set(i_write_mask=0, i_write_more=0, i_next_same=claim(index))
            ready_now = self.get("o_store_ready")
            await self.tick()
            if write:
                for byte in range(8):
                    if mask >> byte & 1:
                        base = address & -8
                        old = self.expect.get(base, 0)
                        shift = 8 * byte
                        new_byte = (value >> shift) & 0xFF
                        self.expect[base] = (old & ~(0xFF << shift)) | (
                            new_byte << shift
                        )
                self.pushes += 1
                index += 1
                since = 1
            else:
                since += 1
            ready_prev = ready_now
        await self.set(i_write_mask=0, i_write_more=0, i_next_same=0)

    async def drain(self) -> None:
        """Wait until every store record installs and every store completed."""
        await self.wait("o_pending_store", 0, limit=4000)
        await self.tick(4)
        assert self.dones == self.pushes, f"{self.dones} dones for {self.pushes} stores"

    async def check(self, block: int) -> None:
        """Compare every dword of a block, through the L1D and the agent."""
        expect = {
            offset: self.expect.get(block + offset, 0) for offset in range(0, BLOCK, 8)
        }
        await self.check_block(block, expect)


def block_stores(
    block: int, seed: int, offsets: range | list[int] = range(0, BLOCK, 8)
) -> list[tuple[int, int, int]]:
    """Return dword stores of a block at the given offsets."""
    return [(block + offset, dword(seed, offset), 0xFF) for offset in offsets]


@cocotb.test()
async def full_blocks_read_no_memory(dut: Any) -> None:
    """Fully written blocks install without a memory read, at both cadences."""
    b = FullCluster(dut)
    await b.reset()
    blocks = [0x80010000 + 0x400 * n for n in range(6)]
    for n, block in enumerate(blocks):
        b.preload(block, 0x10 + n)
    for n, block in enumerate(blocks[:3]):
        await b.stream(block_stores(block, n), gap=3)
    await b.stream(
        [
            s
            for n, block in enumerate(blocks[3:])
            for s in block_stores(block, 0x40 + n)
        ],
        gap=1,
    )
    await b.drain()
    for block in blocks:
        assert b.reads_of(block) == 0, f"{block:#x} read {b.reads_of(block)} times"
    if b.line == 64:
        assert b.twin_installs >= len(blocks)
    for block in blocks:
        await b.check(block)


@cocotb.test()
async def without_hint_blocks_fill(dut: Any) -> None:
    """Without i_write_more the head seals early; the blocks fill and stay correct."""
    b = FullCluster(dut)
    await b.reset()
    block = 0x80020000
    b.preload(block, 3)
    await b.stream(block_stores(block, 7), gap=3, more=False)
    await b.drain()
    assert b.reads_of(block) > 0
    await b.check(block)


@cocotb.test()
async def partial_and_reversed_blocks_fill(dut: Any) -> None:
    """Partial blocks and an upper-first block keep their unwritten bytes."""
    b = FullCluster(dut)
    await b.reset()
    partial = [0x80030000 + 0x400 * n for n in range(3)]
    reversed_block = 0x80031000
    byte_block = 0x80032000
    for n, block in enumerate(partial + [reversed_block, byte_block]):
        b.preload(block, 0x60 + n)
    # 48 bytes; a full lower sector only; the upper sector only.
    await b.stream(block_stores(partial[0], 1, range(0, 48, 8)))
    await b.stream(block_stores(partial[1], 2, range(0, 32, 8)))
    await b.stream(block_stores(partial[2], 3, range(32, 64, 8)))
    await b.stream(block_stores(reversed_block, 4, list(range(56, -8, -8))))
    # Every byte but one, with byte stores in the last dword.
    stores = block_stores(byte_block, 5, range(0, 56, 8))
    stores += [
        (byte_block + 56 + i, (dword(5, 56 + i) << (8 * i)) & MASK64, 1 << i)
        for i in range(7)
    ]
    await b.stream(stores, gap=1)
    await b.drain()
    # With 64-byte lines every partial block fills; with 32-byte lines only
    # the lines with an unwritten byte do.
    filled = partial + [byte_block] if b.line == 64 else [partial[0], byte_block]
    for block in filled:
        assert b.reads_of(block) > 0, f"{block:#x}"
    for block in partial + [reversed_block, byte_block]:
        await b.check(block)


@cocotb.test()
async def loads_between_stores(dut: Any) -> None:
    """Check that loads of a block between its stores see program order."""
    b = FullCluster(dut)
    await b.reset()
    for n in range(4):
        block = 0x80040000 + 0x400 * n
        b.preload(block, 0x80 + n)
        stores = block_stores(block, 0x90 + n)
        split = 1 + 2 * n
        await b.stream(stores[:split])
        # A written dword reads its store; an unwritten one its old value.
        for offset in (0, 8 * split, 56):
            got = await b.read(block + offset)
            assert got == b.expect[block + offset], f"{block + offset:#x}: {got:#x}"
        await b.stream(stores[split:])
        await b.drain()
        await b.check(block)


@cocotb.test()
async def dma_meets_the_block(dut: Any) -> None:
    """DMA reads and writes of the block during and after its full-line stores.

    A DMA write ordered after the block's GetMZero merges over the stores'
    bytes; one ordered before it is overwritten by them. Without a memory read
    the block was acquired without a fill, so a DMA write to it must come after
    the stores, and its bytes must survive.
    """
    b = FullCluster(dut)
    await b.reset()
    nofill = 0
    for delay in range(0, 60, 4):
        block = 0x80050000 + 0x400 * delay
        b.preload(block, 0xA0 + delay)
        written = line_pattern(32, 0x5A + delay)
        stores = block_stores(block, 0xB0 + delay)
        if delay % 8 == 0:
            # A read of the upper sector between the stores of the two
            # sectors: the old bytes. It fills the line in the home, so this
            # block reads memory.
            await b.stream(stores[:4])
            data = await b.dma(block + 32)
            assert data & MASK64 == b.expect[block + 32], f"delay {delay}: {data:#x}"
            await b.stream(stores[4:])
        else:
            await b.stream(stores)
        await b.tick(delay)
        await b.dma(block + 32, written)
        await b.drain()
        upper = await b.read(block + 32)
        kept = upper == written & MASK64
        assert kept or upper == b.expect[block + 32], f"delay {delay}: {upper:#x}"
        reads = b.reads_of(block)
        if reads == 0:
            nofill += 1
            assert kept, f"delay {delay}: the stores were performed after the DMA write"
        if kept:
            for word in range(4):
                b.expect[block + 32 + 8 * word] = (written >> (64 * word)) & MASK64
        await b.check(block)
    assert nofill > 0


@cocotb.test()
async def stale_and_dirty_copies(dut: Any) -> None:
    """Check that a Shared copy upgrades through GetMZero and a Modified block takes hits."""
    b = FullCluster(dut)
    await b.reset()
    shared = 0x80060000
    dirty = 0x80061000
    b.preload(shared, 0xC1)
    b.preload(dirty, 0xC2)
    assert await b.read(shared) == b.expect[shared]
    assert await b.read(shared + 40) == b.expect[shared + 40]
    await b.stream([(dirty + 8, 0x55, 0xFF), (dirty + 40, 0x66, 0xFF)], more=False)
    await b.drain()
    await b.stream(block_stores(shared, 0xD1) + block_stores(dirty, 0xD2), gap=1)
    await b.drain()
    await b.check(shared)
    await b.check(dirty)


@cocotb.test()
async def streams_through_evictions(dut: Any) -> None:
    """Long copy-like streams over many blocks evict dirty blocks and refill."""
    b = FullCluster(dut)
    await b.reset()
    blocks = [0x80070000 + 0x40 * n for n in range(48)]
    for n, block in enumerate(blocks):
        b.preload(block, 0xE0 + n)
    for start in range(0, len(blocks), 8):
        stores: list[tuple[int, int, int]] = []
        for n, block in enumerate(blocks[start : start + 8]):
            offsets = range(0, BLOCK, 8) if (start + n) % 5 else range(0, 40, 8)
            stores += block_stores(block, 0xF0 + start + n, offsets)
        await b.stream(stores, gap=1 + start % 3)
    await b.drain()
    for block in blocks:
        await b.check(block)


@cocotb.test()
async def stream_cycles_with_and_without_hint(dut: Any) -> None:
    """Report cycles for a memset-like stream with and without i_write_more."""
    b = FullCluster(dut)
    await b.reset()
    # A large home clears its tags one set per cycle after reset.
    await b.tick(2500)
    b.read_delay = 60
    results = []
    for more in (False, True):
        for gap in (3, 1):
            base = 0x80100000 + (0x10000 if more else 0) + (0x8000 if gap == 1 else 0)
            blocks = [base + 0x40 * n for n in range(32)]
            stores = [s for n, blk in enumerate(blocks) for s in block_stores(blk, n)]
            start = b.cycle
            twins = b.twin_installs
            reads = len(b.memory_reads)
            await b.stream(stores, gap=gap, more=more)
            await b.drain()
            results.append(
                f"more={int(more)} gap={gap} cycles={b.cycle - start} "
                f"twins={b.twin_installs - twins} reads={len(b.memory_reads) - reads}"
            )
    # Word stores: sixteen per block.
    for gap in (3, 1):
        base = 0x80140000 + (0x8000 if gap == 1 else 0)
        blocks = [base + 0x40 * n for n in range(32)]
        stores = [
            (
                blk + 4 * i,
                (dword(n, 4 * i) << (32 * (i % 2))) & MASK64,
                0xF << (4 * (i % 2)),
            )
            for n, blk in enumerate(blocks)
            for i in range(16)
        ]
        start = b.cycle
        twins = b.twin_installs
        reads = len(b.memory_reads)
        await b.stream(stores, gap=gap, more=True)
        await b.drain()
        results.append(
            f"words gap={gap} cycles={b.cycle - start} "
            f"twins={b.twin_installs - twins} reads={len(b.memory_reads) - reads}"
        )
        for blk in blocks[:2]:
            await b.check(blk)
    for line in results:
        dut._log.info("FULL_LINE_PERF %s", line)


class HoldCluster(FullCluster):
    """Count the L1D's gather, pair and claim states before each edge."""

    def __init__(self, dut: Any) -> None:
        """Start every count at zero."""
        super().__init__(dut)
        self.seen: Counter[str] = Counter()

    def terms(self) -> dict[str, int]:
        """Return the hold and claim terms of this cycle, before its edge."""
        l1d = self.dut.hart
        count = int(l1d.store_count.value)
        head = int(l1d.store_head_index.value)
        grow = int(l1d.gather_grow.value)
        wait = int(l1d.gather_pair_wait.value)
        push = int(l1d.store_push.value)
        youngest = (head + count - 1) % 4
        lower = (head + count - 2) % 4
        # A look-ahead candidate (never the head) held by the gather window
        # or by a pair wait.
        look_held = (
            int(l1d.gather_open.value) and count >= 2 and grow >> youngest & 1
        ) or (int(l1d.pair_open.value) and count >= 3 and wait >> lower & 1)
        return {
            "hold_head": int(l1d.gather_hold_head.value),
            "hold_next": int(l1d.gather_hold_next.value),
            "pair_wait": int(wait != 0 and int(l1d.pair_open.value)),
            "look_held": int(bool(look_held)),
            "claim_gap": int(int(l1d.merge_claim.value) and not push),
            "merge_four": int(push and count == 4),
            "claim_three": int(l1d.store_buffer.claim_ready.value),
            "pair_acquire": int(l1d.store_acquire.value)
            & int(l1d.pair_acquire_q.value),
        }

    async def tick(self, count: int = 1) -> None:
        """Advance, counting the terms on every cycle out of reset."""
        for _ in range(count):
            if not self.get("i_rst"):
                self.seen.update(self.terms())
            await super().tick()


def mixed_block_stores(
    rng: random.Random, block: int, seed: int, kind: int
) -> list[tuple[int, int, int]]:
    """Return the stores of one block as memset, memcpy or a partial copy issue them.

    Kinds: 0 dwords over the block; 1 words over the block; 2 the first one to
    seven dwords; 3 an unaligned copy (bytes up to a dword boundary, dwords,
    then bytes) that leaves bytes at both ends; 4 dwords upper sector first.
    """
    if kind == 0:
        return block_stores(block, seed)
    if kind == 1:
        return [
            (
                block + o,
                (dword(seed, o) << (32 * (o >> 2 & 1))) & MASK64,
                0xF << (o & 4),
            )
            for o in range(0, BLOCK, 4)
        ]
    if kind == 2:
        return block_stores(block, seed, range(0, 8 * rng.randrange(1, 8), 8))
    if kind == 3:
        start = rng.randrange(1, 8)
        end = BLOCK - rng.randrange(1, 8)
        stores = []
        offset = start
        while offset < end:
            if offset % 8 == 0 and offset + 8 <= end:
                stores.append((block + offset, dword(seed, offset), 0xFF))
                offset += 8
            else:
                lane = offset % 8
                value = (dword(seed, offset) << (8 * lane)) & MASK64
                stores.append((block + offset, value, 1 << lane))
                offset += 1
        return stores
    return block_stores(block, seed, list(range(32, 64, 8)) + list(range(0, 32, 8)))


@cocotb.test()
async def irregular_streams_and_claims(dut: Any) -> None:
    """Check copy- and memset-like streams with irregular gaps and partial last lines.

    The gaps leave the store queue's claim standing over cycles without a
    write, and the records fill to four, so claimed writes combine into the
    youngest record. Every byte is checked through the L1D and the agent.
    """
    b = HoldCluster(dut)
    await b.reset()
    rng = random.Random(0x5EED)
    blocks = [0x80200000 + 0x40 * n for n in range(60)]
    stores: list[tuple[int, int, int]] = []
    for n, block in enumerate(blocks):
        b.preload(block, 0x300 + n)
        stores += mixed_block_stores(rng, block, 0x500 + n, rng.randrange(5))
    gaps = [rng.choice((1, 1, 1, 2, 2, 3, 4, 5, 7)) for _ in stores]
    for start in range(0, len(stores), 97):
        await b.stream(stores[start : start + 97], gaps=gaps[start : start + 97])
    await b.drain()
    # Counted before the checks, whose reads refill blocks the small home evicted.
    nofill = sum(1 for block in blocks if b.reads_of(block) == 0)
    for block in blocks:
        await b.check(block)
    dut._log.info(
        "FULL_LINE_IRREGULAR nofill=%d/%d %s", nofill, len(blocks), dict(b.seen)
    )
    required = ["claim_gap", "hold_head"]
    # With 64-byte home lines the records also fill to four and full pairs
    # acquire; with 32-byte lines each full sector acquires on its own.
    if b.line == 64:
        required += ["merge_four", "claim_three", "pair_acquire"]
        assert nofill > 0
    for term in required:
        assert b.seen[term], f"irregular streams missed {term}: {dict(b.seen)}"


@cocotb.test()
async def flushed_hint_closes_the_window(dut: Any) -> None:
    """Check that a hint whose stores never come holds a record only for its window.

    The store queue counts uncommitted stores in its hint; a flush removes
    them, so the hinted write is the last. The record seals once the window
    closes and installs; the block's remaining stores come later, unhinted.
    """
    b = HoldCluster(dut)
    await b.reset()
    cases = ((3, 0), (4, 1), (6, 2), (4, 5), (7, 9), (5, 30))
    for n, (count, idle) in enumerate(cases):
        block = 0x80300000 + 0x400 * n
        b.preload(block, 0x400 + n)
        await b.stream(
            block_stores(block, n, range(0, 8 * count, 8)), gap=1, more_last=True
        )
        await b.tick(idle)
        await b.stream(
            block_stores(block, 0x40 + n, range(8 * count, BLOCK, 8)),
            gap=5,
            more=False,
        )
        await b.drain()
        await b.check(block)
    assert b.seen["hold_head"], f"no gather hold: {dict(b.seen)}"


def reset_scenarios(base: int) -> dict[str, list[tuple[int, int, int]]]:
    """Return store prefixes that leave a gathering head, a pair hold and a held look-ahead."""
    return {
        "gather": block_stores(base, 1, range(0, 24, 8)),
        "pair": block_stores(base, 2, range(0, 48, 8)),
        "lookahead": block_stores(base, 3, range(0, 16, 8))
        + block_stores(base + 0x400, 4, range(0, 48, 8)),
    }


@cocotb.test()
async def reset_during_holds(dut: Any) -> None:
    """Check a reset with a gathering head, a pair hold and a held look-ahead candidate.

    Each prefix ends with the hint set, and the reset comes zero to two cycles
    later, inside the window. After the reset a full block installs without
    a memory read and every byte of it is right; the RTL assertions hold.
    """
    at_reset: Counter[str] = Counter()
    for n, name in enumerate(("gather", "pair", "lookahead")):
        for delay in range(3):
            b = HoldCluster(dut)
            await b.reset()
            base = 0x80400000 + 0x2000 * (3 * n + delay)
            b.preload(base, 0x600 + n)
            b.preload(base + 0x400, 0x610 + n)
            await b.stream(reset_scenarios(base)[name], gap=1, more_last=True)
            await b.tick(delay)
            terms = b.terms()
            at_reset.update({f"{name}:{k}": v for k, v in terms.items()})
            fresh = HoldCluster(dut)
            await fresh.reset()
            # The interrupted stream's last done may pulse on the reset's
            # first cycle; count only the new stream's.
            fresh.dones = 0
            block = base + 0x1000
            fresh.preload(block, 0x620 + n)
            await fresh.stream(block_stores(block, 0x630 + 3 * n + delay), gap=1)
            await fresh.drain()
            reads = fresh.reads_of(block)
            assert reads == 0, f"{name} {delay}: {reads} reads after the reset"
            await fresh.check(block)
    dut._log.info("FULL_LINE_RESET %s", dict(at_reset))
    # Pair waits exist only with 64-byte home lines.
    wanted = ["gather:hold_head"]
    if len(dut.i_mem_resp_data) == 512:
        wanted += ["pair:pair_wait", "lookahead:look_held"]
    for term in wanted:
        assert at_reset[term], f"no reset with {term}: {dict(at_reset)}"
