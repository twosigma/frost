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

"""The second-level TLB in front of the page-table walker.

A model walker answers the array's misses from a table of page mappings. The
tests check that a repeat request hits without reaching the walker, that
entries separate by ASID and global bit, that superpage, faulting and discarded
walks are not stored, that every SFENCE.VMA form (page, ASID, both, all)
removes exactly what the privileged spec names, that a request waits out a
flush, and that 512 resident pages all hit. A random run compares every hit
against the entries a reference model says may still be present.
"""

from __future__ import annotations

import random
from dataclasses import dataclass
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

SETS = 128
WAYS = 4
NONE, PAGE = 0, 2
ASID_MASK = 0x1FF


@dataclass(frozen=True)
class Entry:
    """One mapping the walker can return."""

    ppn: int
    r: int = 1
    w: int = 1
    x: int = 0
    u: int = 0
    d: int = 1
    g: int = 0
    level: int = 0
    fault: int = NONE


def pack_resp(vpn: int, e: Entry) -> int:
    """Pack a riscv_pkg::ptw_resp_t."""
    fields = (
        (e.fault, 2),
        (vpn, 27),
        (e.ppn, 44),
        (e.level, 2),
        (e.r, 1),
        (e.w, 1),
        (e.x, 1),
        (e.u, 1),
        (e.d, 1),
        (e.g, 1),
    )
    value = 0
    for field, width in fields:
        value = (value << width) | field
    return value


def unpack_resp(resp: int) -> tuple[int, Entry]:
    """Split a riscv_pkg::ptw_resp_t into (vpn, Entry)."""
    g = resp & 1
    d = (resp >> 1) & 1
    u = (resp >> 2) & 1
    x = (resp >> 3) & 1
    w = (resp >> 4) & 1
    r = (resp >> 5) & 1
    level = (resp >> 6) & 3
    ppn = (resp >> 8) & ((1 << 44) - 1)
    vpn = (resp >> 52) & ((1 << 27) - 1)
    fault = (resp >> 79) & 3
    return vpn, Entry(ppn, r, w, x, u, d, g, level, fault)


def flush_cmd(vpn: int | None = None, asid: int | None = None) -> int:
    """Pack a riscv_pkg::tlb_flush_t: {en, use_va, vpn, use_asid, asid}."""
    return (
        (1 << 38)
        | (int(vpn is not None) << 37)
        | (((vpn or 0) & ((1 << 27) - 1)) << 10)
        | (int(asid is not None) << 9)
        | ((asid or 0) & ASID_MASK)
    )


class Bench:
    """Clocked driver with a model walker behind the array."""

    def __init__(self, dut: Any, latency: int = 6) -> None:
        """Start the clock and the model walker."""
        self.dut = dut
        self.latency = latency
        self.table: dict[tuple[int | None, int], Entry] = {}
        self.walks: list[tuple[int, int]] = []  # (asid, vpn) of each accepted walk
        self.asid = 0
        self._pending: tuple[int, int, int] | None = None  # (vpn, asid, countdown)
        self._prev_ptw_valid = 0
        self._prev_ptw_vpn = 0
        # Raise the discard in the very cycle the walker answers.
        self.discard_on_resp = False
        self._discarding = False
        self.dut.i_clk.value = 0
        Clock(dut.i_clk, 10, unit="ns").start()

    async def reset(self) -> None:
        """Reset and drive every input idle."""
        d = self.dut
        d.i_rst.value = 1
        d.i_asid.value = 0
        d.i_flush.value = 0
        d.i_discard.value = 0
        d.i_req_valid.value = 0
        d.i_req_vpn.value = 0
        d.i_ptw_req_ready.value = 1
        d.i_ptw_resp_valid.value = 0
        d.i_ptw_resp.value = 0
        for _ in range(3):
            await self.tick()
        d.i_rst.value = 0
        await self.tick()

    def set_asid(self, asid: int) -> None:
        """Change the ASID that lookups and fills use."""
        self.asid = asid & ASID_MASK
        self.dut.i_asid.value = self.asid

    def lookup_table(self, asid: int, vpn: int) -> Entry:
        """Return what the walker finds for vpn under asid."""
        return self.table.get(
            (asid, vpn), self.table.get((None, vpn), Entry(0, fault=PAGE))
        )

    async def tick(self) -> None:
        """Advance one clock; run the model walker."""
        d = self.dut
        # A walk accepted at the edge that is about to pass.
        fires = self._prev_ptw_valid and int(d.i_ptw_req_ready.value)
        await RisingEdge(d.i_clk)
        await Timer(1, unit="ns")
        d.i_ptw_resp_valid.value = 0
        if self._discarding:
            d.i_discard.value = 0
            self._discarding = False
        if fires and self._pending is None:
            self._pending = (self._prev_ptw_vpn, self.asid, self.latency)
            self.walks.append((self.asid, self._prev_ptw_vpn))
        if self._pending is not None:
            vpn, asid, count = self._pending
            if count <= 1:
                e = self.lookup_table(asid, vpn)
                d.i_ptw_resp_valid.value = 1
                d.i_ptw_resp.value = pack_resp(vpn, e)
                self._pending = None
                if self.discard_on_resp:
                    d.i_discard.value = 1
                    self._discarding = True
            else:
                self._pending = (vpn, asid, count - 1)
        # Not ready while the model walker is busy.
        d.i_ptw_req_ready.value = int(self._pending is None)
        # Let the combinational outputs follow the new inputs before sampling.
        await Timer(1, unit="ns")
        self._prev_ptw_valid = int(d.o_ptw_req_valid.value)
        self._prev_ptw_vpn = int(d.o_ptw_req_vpn.value)

    async def request(self, vpn: int, timeout: int = 400) -> tuple[Entry, int, bool]:
        """Request vpn; return (response entry, cycles from fire to response, walked)."""
        d = self.dut
        d.i_req_valid.value = 1
        d.i_req_vpn.value = vpn
        walks_before = len(self.walks)
        for _ in range(timeout):
            fire = int(d.o_req_ready.value)
            await self.tick()
            if fire:
                break
        else:
            raise AssertionError(f"request for 0x{vpn:x} never fired")
        d.i_req_valid.value = 0
        d.i_req_vpn.value = 0
        for cycles in range(1, timeout):
            if int(d.o_resp_valid.value):
                got_vpn, entry = unpack_resp(int(d.o_resp.value))
                assert got_vpn == vpn, f"response vpn 0x{got_vpn:x} != 0x{vpn:x}"
                await self.tick()
                return entry, cycles, len(self.walks) > walks_before
            await self.tick()
        raise AssertionError(
            f"no response for 0x{vpn:x}: state={int(d.state_q.value)} "
            f"ptw_valid={int(d.o_ptw_req_valid.value)} ready={int(d.i_ptw_req_ready.value)} "
            f"pending={self._pending}"
        )

    async def flush(self, cmd: int, cycles: int = 1) -> None:
        """Hold a flush command (and the translation-changed discard) for cycles."""
        self.dut.i_flush.value = cmd
        self.dut.i_discard.value = 1
        for _ in range(cycles):
            await self.tick()
        self.dut.i_flush.value = 0
        self.dut.i_discard.value = 0
        # Let a scanning flush finish before the next request is offered.
        for _ in range(SETS * 2 + 8):
            await self.tick()

    async def hits(self, vpn: int) -> bool:
        """Return whether vpn answers without a walk."""
        entry, _, walked = await self.request(vpn)
        assert entry.fault == NONE
        return not walked


def clean(ppn: int, **kw: int) -> Entry:
    """Return a clean 4 KiB mapping."""
    return Entry(ppn, **kw)


@cocotb.test()
async def repeat_request_hits_after_two_cycles(dut: Any) -> None:
    """Check that a fill answers the repeat request without the walker, in two cycles."""
    b = Bench(dut)
    await b.reset()
    b.set_asid(1)
    b.table[(1, 0x1234)] = clean(0x80123, r=1, w=1, x=0, u=1, d=0)
    entry, miss_cycles, walked = await b.request(0x1234)
    assert walked and entry == b.table[(1, 0x1234)]
    entry, hit_cycles, walked = await b.request(0x1234)
    assert not walked and entry == b.table[(1, 0x1234)], entry
    assert hit_cycles <= 3, hit_cycles
    assert hit_cycles < miss_cycles
    dut._log.info(
        "L2 hit latency %d cycles, miss through model walker %d",
        hit_cycles,
        miss_cycles,
    )


@cocotb.test()
async def asid_isolation_and_global_entries(dut: Any) -> None:
    """One VPN under two ASIDs keeps two entries; a global entry serves every ASID."""
    b = Bench(dut)
    await b.reset()
    b.table[(1, 0x400)] = clean(0x80001)
    b.table[(2, 0x400)] = clean(0x80002)
    b.table[(None, 0x500)] = clean(0x80005, g=1)
    for asid in (1, 2):
        b.set_asid(asid)
        entry, _, walked = await b.request(0x400)
        assert walked and entry.ppn == 0x80000 + asid
    for asid in (1, 2):
        b.set_asid(asid)
        entry, _, walked = await b.request(0x400)
        assert not walked and entry.ppn == 0x80000 + asid
    b.set_asid(1)
    entry, _, walked = await b.request(0x500)
    assert walked and entry.g == 1
    for asid in (2, 3, ASID_MASK, 0):
        b.set_asid(asid)
        entry, _, walked = await b.request(0x500)
        assert not walked and entry.g == 1, asid
    # A fresh ASID misses on the non-global page.
    b.set_asid(7)
    b.table[(7, 0x400)] = clean(0x80007)
    entry, _, walked = await b.request(0x400)
    assert walked and entry.ppn == 0x80007


@cocotb.test()
async def superpage_fault_and_discarded_walks_are_not_stored(dut: Any) -> None:
    """Only clean 4 KiB translations fill the array."""
    b = Bench(dut)
    await b.reset()
    b.set_asid(1)
    b.table[(1, 0x600)] = Entry(0x80200, level=1)
    b.table[(1, 0x601)] = Entry(0, fault=PAGE)
    b.table[(1, 0x602)] = clean(0x80602)
    for vpn in (0x600, 0x601):
        for _ in range(2):
            _, _, walked = await b.request(vpn)
            assert walked, hex(vpn)
    # A discard in the very cycle the walker answers drops the fill.
    b.discard_on_resp = True
    dut.i_req_valid.value = 1
    dut.i_req_vpn.value = 0x602
    await b.tick()
    dut.i_req_valid.value = 0
    for _ in range(b.latency + 8):
        await b.tick()
        assert not int(dut.o_resp_valid.value), "a discarded response passed through"
    b.discard_on_resp = False
    _, _, walked = await b.request(0x602)
    assert walked, "a response met by a discard filled the array"
    await b.flush(flush_cmd())
    # A walk discarded while the walker works is dropped and does not fill.
    dut.i_req_valid.value = 1
    dut.i_req_vpn.value = 0x602
    await b.tick()
    dut.i_req_valid.value = 0
    for _ in range(3):
        await b.tick()
    dut.i_discard.value = 1
    await b.tick()
    dut.i_discard.value = 0
    for _ in range(b.latency + 8):
        await b.tick()
        assert not int(dut.o_resp_valid.value), "a discarded walk answered"
    _, _, walked = await b.request(0x602)
    assert walked, "a discarded walk filled the array"


@cocotb.test()
async def every_sfence_form_removes_what_the_spec_names(dut: Any) -> None:
    """Flush by page, ASID, both, and everything."""
    b = Bench(dut)
    await b.reset()
    pages = {
        "A": (1, 0x400, clean(0x80001)),
        "B": (2, 0x400, clean(0x80002)),
        "C": (1, 0x500, clean(0x80005)),
        "G": (1, 0x600, clean(0x80006, g=1)),
    }
    cases = {
        "none": (None, "ABCG"),
        "asid1": (flush_cmd(asid=1), "BG"),
        "page400": (flush_cmd(vpn=0x400), "CG"),
        "page600": (flush_cmd(vpn=0x600), "ABC"),
        "page400_asid1": (flush_cmd(vpn=0x400, asid=1), "BCG"),
        "page600_asid1": (flush_cmd(vpn=0x600, asid=1), "ABCG"),
        "all": (flush_cmd(), ""),
    }
    for name, (cmd, survivors) in cases.items():
        await b.flush(flush_cmd())
        b.table.clear()
        for asid, vpn, e in pages.values():
            b.table[(asid, vpn) if not e.g else (None, vpn)] = e
        for asid, vpn, _ in pages.values():
            b.set_asid(asid)
            await b.request(vpn)
        if cmd is not None:
            await b.flush(cmd, cycles=3)
        for label, (asid, vpn, e) in pages.items():
            b.set_asid(asid)
            hit = await b.hits(vpn)
            assert hit == (label in survivors), f"{name}: {label} hit={hit}"


@cocotb.test()
async def request_waits_for_a_scanning_flush(dut: Any) -> None:
    """During an ASID scan no request fires, so no stale entry can answer."""
    b = Bench(dut)
    await b.reset()
    b.set_asid(1)
    for vpn in range(SETS):
        b.table[(1, vpn)] = clean(0x80000 + vpn)
        await b.request(vpn)
    dut.i_flush.value = flush_cmd(asid=1)
    dut.i_discard.value = 1
    await b.tick()
    dut.i_flush.value = 0
    dut.i_discard.value = 0
    dut.i_req_valid.value = 1
    dut.i_req_vpn.value = 0x7F
    waited = 0
    while not int(dut.o_req_ready.value):
        await b.tick()
        waited += 1
        assert waited < 4 * SETS, "scan never finished"
    assert waited >= SETS - 2, f"request fired after {waited} cycles, mid-scan"
    dut.i_req_valid.value = 0
    await b.tick()
    # Every entry of the flushed ASID is gone.
    for vpn in (0, 1, 0x40, 0x20):
        assert not await b.hits(vpn), hex(vpn)


@cocotb.test()
async def five_hundred_twelve_pages_stay_resident(dut: Any) -> None:
    """512 sequential pages fill every way of every set and all hit; page 513 evicts one."""
    b = Bench(dut, latency=2)
    await b.reset()
    b.set_asid(3)
    for vpn in range(SETS * WAYS):
        b.table[(3, 0x10000 + vpn)] = clean(0x80000 + vpn)
        _, _, walked = await b.request(0x10000 + vpn)
        assert walked
    resident = 0
    for vpn in range(SETS * WAYS):
        entry, _, walked = await b.request(0x10000 + vpn)
        assert entry.ppn == 0x80000 + vpn
        resident += int(not walked)
    assert resident == SETS * WAYS, resident
    b.table[(3, 0x10000 + SETS * WAYS)] = clean(0x90000)
    await b.request(0x10000 + SETS * WAYS)
    # Pages outside set 0 are untouched; set 0 holds the new page and only
    # three of its four old pages, so at least one old page now misses.
    for vpn in range(SETS * WAYS):
        if vpn % SETS:
            assert await b.hits(0x10000 + vpn), hex(vpn)
    assert await b.hits(0x10000 + SETS * WAYS)
    old_hits = [await b.hits(0x10000 + k * SETS) for k in range(WAYS)]
    assert not all(old_hits), old_hits


@cocotb.test()
async def random_requests_and_flushes_match_a_reference(dut: Any) -> None:
    """Every hit returns an entry the model says may still be present."""
    b = Bench(dut, latency=3)
    await b.reset()
    rng = random.Random(7)
    asids = [0, 1, 2, 3, ASID_MASK]
    pool = [(s << 7) | rng.randrange(SETS) for s in range(6)] + [5, 6, 7, 133]
    present: dict[tuple[int, int], Entry] = {}  # (asid filled under, vpn) -> entry
    serial = 0x80000
    hits = walks = 0

    def candidates(asid: int, vpn: int) -> list[Entry]:
        return [e for (a, v), e in present.items() if v == vpn and (a == asid or e.g)]

    for _ in range(1500):
        action = rng.random()
        if action < 0.72:
            asid = rng.choice(asids)
            vpn = rng.choice(pool)
            b.set_asid(asid)
            if (asid, vpn) not in b.table and (None, vpn) not in b.table:
                serial += 1
                b.table[(asid, vpn)] = clean(serial, g=0)
            cand = candidates(asid, vpn)
            entry, _, walked = await b.request(vpn)
            if walked:
                walks += 1
                if entry.fault == NONE and entry.level == 0:
                    present[(asid, vpn)] = entry
            else:
                hits += 1
                assert entry in cand, (asid, vpn, entry, cand)
        elif action < 0.80:
            vpn = rng.choice(pool)
            asid = rng.choice(asids)
            serial += 1
            if rng.random() < 0.3:
                b.table[(None, vpn)] = clean(serial, g=1)
            else:
                b.table[(asid, vpn)] = clean(serial)
        else:
            kind = rng.choice(("page", "asid", "both", "all"))
            vpn = rng.choice(pool)
            asid = rng.choice(asids)
            cmd = {
                "page": flush_cmd(vpn=vpn),
                "asid": flush_cmd(asid=asid),
                "both": flush_cmd(vpn=vpn, asid=asid),
                "all": flush_cmd(),
            }[kind]
            await b.flush(cmd, cycles=rng.choice((1, 3)))
            for key in list(present):
                a, v = key
                e = present[key]
                kill = (
                    kind == "all"
                    or (kind == "page" and v == vpn)
                    or (kind == "asid" and a == asid and not e.g)
                    or (kind == "both" and v == vpn and a == asid and not e.g)
                )
                if kill:
                    del present[key]
    dut._log.info("random run: %d hits, %d walks", hits, walks)
    assert hits > 100
