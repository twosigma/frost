# Copyright (c) 2026 John Goodacre.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""The page-table walker's walk cache against a reference Sv39 walk.

Every response must equal a full walk of the current memory image. Software
may change memory between walks in the two ways the privileged spec and
Svvptc allow without a fence: an invalid PTE becomes valid (leaf or pointer),
and a leaf changes (the walker caches no leaf). Any other change, such as
retargeting a valid pointer, is followed by a discard (SFENCE.VMA or a satp
access). The bench also counts line reads to show that the cache removes the
upper-level reads of repeated walks.
"""

from __future__ import annotations

import random
from typing import Any
from collections.abc import Callable

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

DDR_BASE = 0x8000_0000
DDR_LIMIT = DDR_BASE + (1 << 30)
LINE_BYTES = 32
DFAULT_NONE, DFAULT_PAGE, DFAULT_ACCESS = 0, 2, 3
V, R, W, X, U, A, D = 1, 2, 4, 8, 16, 64, 128
ROOT = 0x8010_0000


def pte(ppn: int, flags: int) -> int:
    """Return an Sv39 PTE."""
    return (ppn << 10) | flags


def unpack(resp: int) -> dict[str, int]:
    """Split a ptw_resp_t: {fault, vpn, ppn, level, r, w, x, u, d}."""
    return {
        "fault": (resp >> 78) & 3,
        "vpn": (resp >> 51) & ((1 << 27) - 1),
        "ppn": (resp >> 7) & ((1 << 44) - 1),
        "level": (resp >> 5) & 3,
        "perms": resp & 0x1F,
    }


class Memory:
    """Sparse dword memory with a reference walk."""

    def __init__(self) -> None:
        """Start with every PTE zero (invalid)."""
        self.words: dict[int, int] = {}

    def read(self, addr: int) -> int:
        """Return the dword at addr."""
        return self.words.get(addr & ~7, 0)

    def write(self, addr: int, value: int) -> None:
        """Store a dword."""
        self.words[addr & ~7] = value

    def line(self, addr: int) -> int:
        """Return the aligned line as the walker's port delivers it."""
        base = addr & ~(LINE_BYTES - 1)
        data = 0
        for i in range(LINE_BYTES // 8):
            data |= self.read(base + 8 * i) << (64 * i)
        return data

    def walk(self, root_ppn: int, vpn: int) -> dict[str, int]:
        """Walk Sv39 page tables with FROST's fault classification."""
        ptr = root_ppn
        for level in (2, 1, 0):
            index = (vpn >> (9 * level)) & 0x1FF
            addr = (ptr << 12) + index * 8
            if not DDR_BASE <= (ptr << 12) < DDR_LIMIT:
                return {"fault": DFAULT_ACCESS, "vpn": vpn}
            e = self.read(addr)
            r, w, x = (e >> 1) & 1, (e >> 2) & 1, (e >> 3) & 1
            leaf = r or x
            if (
                (e >> 54)
                or not e & V
                or (w and not r)
                or (not leaf and e & (U | A | D))
            ):
                return {"fault": DFAULT_PAGE, "vpn": vpn}
            ppn = (e >> 10) & ((1 << 44) - 1)
            if leaf:
                misaligned = ppn & ((1 << (9 * level)) - 1)
                if misaligned or not e & A:
                    return {"fault": DFAULT_PAGE, "vpn": vpn}
                perms = (r << 4) | (w << 3) | (x << 2) | (((e >> 4) & 1) << 1)
                perms |= (e >> 7) & 1
                return {
                    "fault": DFAULT_NONE,
                    "vpn": vpn,
                    "ppn": ppn,
                    "level": level,
                    "perms": perms,
                }
            if level == 0:
                return {"fault": DFAULT_PAGE, "vpn": vpn}
            ptr = ppn
        raise AssertionError("unreachable")


class Bench:
    """Drive walks and answer line reads from the memory image."""

    def __init__(self, dut: Any, seed: int) -> None:
        """Start the clock and the line responder."""
        self.dut = dut
        self.mem = Memory()
        self.rng = random.Random(seed)
        self.reads = 0
        self.discard_now = False
        Clock(dut.i_clk, 10, unit="ns").start()
        cocotb.start_soon(self._responder())

    async def reset(self) -> None:
        """Reset the walker; its cache starts empty."""
        d = self.dut
        d.i_rst.value = 1
        d.i_root_ppn.value = ROOT >> 12
        d.i_req_valid.value = 0
        d.i_req_vpn.value = 0
        d.i_discard.value = 0
        d.i_line_req_ready.value = 0
        d.i_line_resp_valid.value = 0
        d.i_line_resp_error.value = 0
        d.i_line_resp_id.value = 0
        d.i_line_resp_rdata.value = 0
        for _ in range(3):
            await RisingEdge(d.i_clk)
        d.i_rst.value = 0

    async def _responder(self) -> None:
        """Accept reads with random backpressure and answer each a few cycles later.

        Each cycle, just after the clock edge, decide this cycle's inputs: a
        response due now, and ready. A read presented with ready set is
        accepted at the next edge.
        """
        d = self.dut
        pending: list[list[int]] = []  # [cycles left, address]
        while True:
            await RisingEdge(d.i_clk)
            await Timer(1, unit="ns")
            d.i_line_resp_valid.value = 0
            if pending:
                if pending[0][0] == 0:
                    d.i_line_resp_valid.value = 1
                    d.i_line_resp_rdata.value = self.mem.line(pending[0][1])
                    pending.pop(0)
                else:
                    pending[0][0] -= 1
            ready = int(self.rng.random() < 0.6)
            d.i_line_req_ready.value = ready
            if int(d.o_line_req_valid.value) and ready:
                pending.append([self.rng.randint(1, 6), int(d.o_line_req_addr.value)])
                self.reads += 1

    async def discard(self) -> None:
        """Pulse i_discard (SFENCE.VMA or a satp access) for one cycle."""
        d = self.dut
        await RisingEdge(d.i_clk)
        await Timer(2, unit="ns")
        d.i_discard.value = 1
        await RisingEdge(d.i_clk)
        await Timer(1, unit="ns")
        d.i_discard.value = 0

    async def walk(self, vpn: int) -> dict[str, int]:
        """Run one walk to completion and return its response."""
        got = await self.walk_or_discard(vpn)
        assert got is not None
        return got

    async def walk_or_discard(
        self,
        vpn: int,
        discard_after: int | None = None,
        on_discard: Callable[[], None] | None = None,
    ) -> dict[str, int] | None:
        """Run one walk; return its response, or None when discarded.

        on_discard runs as the discard is raised: the page-table store that
        the discarding sfence.vma orders.
        """
        d = self.dut
        await RisingEdge(d.i_clk)
        await Timer(1, unit="ns")
        d.i_req_vpn.value = vpn
        d.i_req_valid.value = 1
        for _ in range(400):
            await Timer(1, unit="ns")
            accepted = int(d.o_req_ready.value)
            await RisingEdge(d.i_clk)
            await Timer(1, unit="ns")
            if accepted:
                break
        else:
            raise AssertionError("walker never ready")
        d.i_req_valid.value = 0
        for cycle in range(400):
            if discard_after is not None and cycle == discard_after:
                d.i_discard.value = 1
                if on_discard is not None:
                    on_discard()
            await Timer(1, unit="ns")
            valid = int(d.o_resp_valid.value)
            resp = int(d.o_resp.value)
            await RisingEdge(d.i_clk)
            await Timer(1, unit="ns")
            d.i_discard.value = 0
            if valid:
                assert discard_after is None or cycle < discard_after
                return unpack(resp)
            if discard_after is not None and cycle >= discard_after:
                if not int(d.o_busy.value):
                    return None
        raise AssertionError(f"walk for VPN 0x{vpn:x} did not finish")

    def check(self, got: dict[str, int], vpn: int) -> None:
        """Compare a response with the reference walk of current memory."""
        want = self.mem.walk(ROOT >> 12, vpn)
        assert got["vpn"] == vpn
        assert got["fault"] == want["fault"], (hex(vpn), got, want)
        if want["fault"] == DFAULT_NONE:
            for key in ("ppn", "level", "perms"):
                assert got[key] == want[key], (hex(vpn), key, got, want)


def table(index: int) -> int:
    """Physical address of the index'th page-table page."""
    return ROOT + 0x1000 * (index + 1)


@cocotb.test()
async def repeated_walks_skip_cached_upper_levels(dut: Any) -> None:
    """Check that a walk under a cached level-1 pointer reads only the leaf."""
    b = Bench(dut, 1)
    await b.reset()
    m = b.mem
    m.write(ROOT + 8 * 1, pte(table(0) >> 12, V))
    m.write(table(0) + 8 * 2, pte(table(1) >> 12, V))
    for i in range(8):
        m.write(table(1) + 8 * i, pte(0x90000 + i, V | R | W | A | D))
    vpn = lambda i: (1 << 18) | (2 << 9) | i  # noqa: E731
    reads = b.reads
    b.check(await b.walk(vpn(0)), vpn(0))
    assert b.reads - reads == 3, "the first walk reads all three levels"
    for i in range(1, 8):
        reads = b.reads
        b.check(await b.walk(vpn(i)), vpn(i))
        assert b.reads - reads == 1, "a cached level-1 pointer leaves one read"
    # Another 2 MiB region under the same root pointer: two reads.
    m.write(table(0) + 8 * 3, pte(table(2) >> 12, V))
    m.write(table(2), pte(0x91000, V | R | A))
    reads = b.reads
    b.check(await b.walk((1 << 18) | (3 << 9)), (1 << 18) | (3 << 9))
    assert b.reads - reads == 2, "a cached root pointer leaves two reads"
    # A discard empties the cache: the next walk reads three levels again.
    await b.discard()
    reads = b.reads
    b.check(await b.walk(vpn(5)), vpn(5))
    assert b.reads - reads == 3, "the walk after a discard used a cached pointer"


@cocotb.test()
async def invalid_pointers_are_never_cached(dut: Any) -> None:
    """Svvptc: an invalid pointer made valid is seen by the next walk."""
    b = Bench(dut, 2)
    await b.reset()
    m = b.mem
    vpn = (4 << 18) | (7 << 9) | 3
    # Root slot invalid: page fault, nothing cached.
    b.check(await b.walk(vpn), vpn)
    m.write(ROOT + 8 * 4, pte(table(3) >> 12, V))
    # Level-1 slot invalid now: page fault after two reads.
    b.check(await b.walk(vpn), vpn)
    m.write(table(3) + 8 * 7, pte(table(4) >> 12, V))
    # Leaf invalid: page fault after three levels, the root pointer cached.
    b.check(await b.walk(vpn), vpn)
    m.write(table(4) + 8 * 3, pte(0x92000, V | R | X | A))
    got = await b.walk(vpn)
    b.check(got, vpn)
    assert got["fault"] == DFAULT_NONE
    # An invalid pointer naming a real table is not cached: once it becomes
    # valid with another table, the next walk uses the new one.
    m.write(ROOT + 8 * 8, pte(table(20) >> 12, 0))
    m.write(table(20), pte(table(22) >> 12, V))
    m.write(table(22), pte(0x9A000, V | R | A))
    m.write(table(21), pte(table(23) >> 12, V))
    m.write(table(23), pte(0x9B000, V | R | W | A | D))
    vpn8 = 8 << 18
    b.check(await b.walk(vpn8), vpn8)
    m.write(ROOT + 8 * 8, pte(table(21) >> 12, V))
    got = await b.walk(vpn8)
    b.check(got, vpn8)
    assert got["ppn"] == 0x9B000
    # Likewise at level 1: an invalid level-1 PTE naming a table.
    m.write(table(21) + 8, pte(table(20) >> 12, 0))
    vpn81 = (8 << 18) | (1 << 9)
    b.check(await b.walk(vpn81), vpn81)
    m.write(table(21) + 8, pte(table(22) >> 12, V))
    got = await b.walk(vpn81)
    b.check(got, vpn81)
    assert got["ppn"] == 0x9A000
    # A malformed pointer (A set) is a page fault and is not cached either.
    m.write(ROOT + 8 * 5, pte(table(5) >> 12, V | A))
    vpn5 = (5 << 18) | 1
    b.check(await b.walk(vpn5), vpn5)
    m.write(ROOT + 8 * 5, pte(table(5) >> 12, V))
    m.write(table(5), pte(table(6) >> 12, V))
    m.write(table(6) + 8, pte(0x93000, V | R | A))
    b.check(await b.walk(vpn5), vpn5)


@cocotb.test()
async def refused_pointer_keeps_full_cache_intact(dut: Any) -> None:
    """Check that a pointer outside DDR, met with every entry valid, replaces nothing."""
    b = Bench(dut, 6)
    await b.reset()
    m = b.mem
    m.write(ROOT + 8 * 3, pte(table(30) >> 12, V))
    # Seventeen 2 MiB regions under one root pointer: the 16 level-1 entries
    # fill and wrap.
    for s in range(17):
        m.write(table(30) + 8 * s, pte(table(31 + s) >> 12, V))
        m.write(table(31 + s), pte(0xA0000 + s, V | R | A))
    vpn = lambda s: (3 << 18) | (s << 9)  # noqa: E731
    for s in range(16):
        b.check(await b.walk(vpn(s)), vpn(s))
    # A level-1 pointer outside cached DDR: an access fault, and the entry
    # the next fill would replace keeps its pointer.
    m.write(table(30) + 8 * 20, pte(0x1000, V))
    got = await b.walk(vpn(20))
    b.check(got, vpn(20))
    assert got["fault"] == DFAULT_ACCESS
    for s in range(16):
        reads = b.reads
        b.check(await b.walk(vpn(s)), vpn(s))
        assert b.reads - reads == 1, f"region {s} lost its cached level-1 pointer"


@cocotb.test()
async def pointer_change_with_discard_is_seen(dut: Any) -> None:
    """Check that a retargeted pointer followed by a discard walks the new table."""
    b = Bench(dut, 3)
    await b.reset()
    m = b.mem
    m.write(ROOT + 8 * 6, pte(table(7) >> 12, V))
    m.write(table(7), pte(table(8) >> 12, V))
    m.write(table(8), pte(0x94000, V | R | A))
    m.write(table(9), pte(0x95000, V | R | W | A | D))
    vpn = 6 << 18
    b.check(await b.walk(vpn), vpn)
    m.write(table(7), pte(table(9) >> 12, V))
    await b.discard()
    got = await b.walk(vpn)
    b.check(got, vpn)
    assert got["ppn"] == 0x95000


@cocotb.test()
async def discarded_walk_fills_nothing(dut: Any) -> None:
    """Check that a walk poisoned mid-way neither answers nor fills the cache."""
    b = Bench(dut, 4)
    await b.reset()
    m = b.mem
    m.write(ROOT + 8 * 7, pte(table(10) >> 12, V))
    m.write(table(10), pte(table(11) >> 12, V))
    m.write(table(11), pte(0x96000, V | R | A))
    m.write(table(12), pte(0x97000, V | R | A))
    vpn = 7 << 18
    for when in range(40):
        # Software retargets the level-1 pointer and runs sfence.vma while
        # the walk is in flight. A pointer the poisoned walk read before the
        # store must not fill the cache; the next walk reads the new table.
        target = table(12 if when % 2 == 0 else 11)

        def retarget(target: int = target) -> None:
            m.write(table(10), pte(target >> 12, V))

        got = await b.walk_or_discard(vpn, discard_after=when, on_discard=retarget)
        if got is None:
            b.check(await b.walk(vpn), vpn)
        await b.discard()


@cocotb.test()
async def random_walks_match_reference(dut: Any) -> None:
    """Random tables, walks and permitted memory changes match the reference."""
    b = Bench(dut, 5)
    await b.reset()
    m = b.mem
    rng = random.Random(55)
    root_slots = [1, 2, 200, 511]
    l1_slots = [0, 1, 9, 300]
    tables = iter(range(13, 200))
    l1_table = {}
    l0_table = {}

    def leaf_flags() -> int:
        return rng.choice(
            (V | R | A, V | R | W | A | D, V | X | A, V | R | X | U | A, V | R)
        )

    def build_slot(r: int, s: int) -> None:
        if r not in l1_table:
            l1_table[r] = table(next(tables))
            m.write(ROOT + 8 * r, pte(l1_table[r] >> 12, V))
        if rng.random() < 0.2:
            # A 2 MiB leaf, aligned or not.
            ppn = 0x80000 + (rng.randrange(4) << 9) + (0 if rng.random() < 0.8 else 1)
            m.write(l1_table[r] + 8 * s, pte(ppn, leaf_flags()))
        else:
            key = (r, s)
            if key not in l0_table:
                l0_table[key] = table(next(tables))
            m.write(l1_table[r] + 8 * s, pte(l0_table[key] >> 12, V))

    def vpn_of(r: int, s: int, i: int) -> int:
        return (r << 18) | (s << 9) | i

    for r in root_slots[:2]:
        for s in l1_slots[:2]:
            build_slot(r, s)
    for step in range(400):
        r, s = rng.choice(root_slots), rng.choice(l1_slots)
        i = rng.randrange(16)
        vpn = vpn_of(r, s, i)
        action = rng.random()
        if action < 0.10:
            # Invalid to valid without a fence (Svvptc): a new subtree or leaf.
            if m.read(ROOT + 8 * r) & V == 0 or (
                r in l1_table and m.read(l1_table[r] + 8 * s) & V == 0
            ):
                build_slot(r, s)
        elif action < 0.25 and (r, s) in l0_table:
            # A leaf changes without a fence: the walker caches no leaf.
            m.write(l0_table[(r, s)] + 8 * i, pte(0x98000 + step, leaf_flags()))
        elif action < 0.30 and r in l1_table:
            # Any pointer change, followed by a discard.
            m.write(l1_table[r] + 8 * s, 0)
            await b.discard()
        elif action < 0.33:
            await b.discard()
        elif action < 0.38:
            got = await b.walk_or_discard(vpn, discard_after=rng.randrange(20))
            if got is not None:
                b.check(got, vpn)
            continue
        b.check(await b.walk(vpn), vpn)
