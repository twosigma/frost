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

"""Exercise independent store grants and ordered installation."""

from typing import Any

import cocotb

from cocotb_tests.cache.test_coherence_endpoints import pack
from cocotb_tests.cache.test_coherence_home import unpack
from cocotb_tests.cache.test_coherence_l1d import Private, snapshot, store


class Stream(Private):
    """Record each endpoint's identity independently of reusable queue records."""

    def __init__(self, dut: Any) -> None:
        """Locate the interface and initialize the channel history."""
        super().__init__(dut)
        self.demands: list[tuple[int, tuple[int, ...]]] = []
        self.completions: list[tuple[int, tuple[int, ...]]] = []
        self.installs: list[int] = []
        self.accesses = 0
        self.hits = 0
        self.misses = 0
        self.combined = 0
        self.read_results: list[tuple[int, int]] = []

    async def tick(self, count: int = 1) -> None:
        """Capture accepted channels and head installations before each edge."""
        for _ in range(count):
            if self.get("o_read_valid") and self.get("i_read_ready"):
                self.read_results.append(
                    (self.get("o_read_id"), self.get("o_read_data"))
                )
            events = self.get("o_perf_events")
            combined = (events >> 13) & 1
            self.accesses += ((events >> 11) & 1) + combined
            self.hits += ((events >> 10) & 1) + combined
            self.misses += (events >> 9) & 1
            self.combined += combined
            for ep in range(len(self.dut.o_d_valid)):
                if (self.get("o_d_valid") & self.get("i_d_ready")) & (1 << ep):
                    d = (self.get("o_d") >> (ep * (self.p + 312))) & (
                        (1 << (self.p + 312)) - 1
                    )
                    self.demands.append(
                        (ep, unpack(d, (4, 9, self.p, 5, 3, 32, 1, 1, 1, 256)))
                    )
                if (self.get("o_c_valid") & self.get("i_c_ready")) & (1 << ep):
                    c = (self.get("o_c") >> (ep * (self.p + 18))) & (
                        (1 << (self.p + 18)) - 1
                    )
                    self.completions.append((ep, unpack(c, (9, 6, self.p, 2, 1))))
            if self.get("store_pop"):
                self.installs.append(self.get("pending_addr_q"))
            await super().tick()

    async def reset(self) -> None:
        """Reset records and endpoints, then enable independent D and C service."""
        await super().reset()
        self.demands.clear()
        self.completions.clear()
        self.installs.clear()
        self.read_results.clear()
        self.accesses = self.hits = self.misses = self.combined = 0
        await self.set(i_d_ready=7, i_c_ready=7, i_read_ready=1)

    async def issued(self, address: int) -> tuple[int, tuple]:
        """Wait for a request for the specified sector."""
        for _ in range(200):
            for ep, demand in self.demands:
                if demand[2] == address:
                    return ep, demand
            await self.tick()
        raise AssertionError(f"no acquisition for {address:#x}: {self.demands}")

    async def grant(self, address: int, data: int = 0, error: bool = False) -> None:
        """Return a grant using the captured request identity."""
        _, demand = await self.issued(address)
        await self.set(
            i_g_valid=1,
            i_g=pack(
                (3, 2 if demand[0] == 1 else 1),
                (9, demand[1]),
                (6, 0),
                (self.p, address),
                (256, data),
                (1, error),
            ),
        )
        await self.wait("o_g_ready")
        await self.tick()
        await self.set(i_g_valid=0)

    async def release(self, address: int) -> None:
        """Wait for completion, then return its matching U."""
        _, demand = await self.issued(address)
        for _ in range(200):
            if any(c[0] == demand[1] for _, c in self.completions):
                break
            await self.tick()
        else:
            raise AssertionError(f"no C for {address:#x}")
        await self.set(i_u_valid=1, i_u=pack((9, demand[1]), (6, 0), (self.p, address)))
        await self.wait("o_u_ready")
        await self.tick()
        await self.set(i_u_valid=0)


@cocotb.test()
async def reverse_grants_combine_and_install_in_order(dut: Any) -> None:
    """Hold a younger grant while every accepted byte stays under a sector hold."""
    b = Stream(dut)
    await b.reset()
    a, c = 0x80000000, 0x80000040
    await store(b, a, 0x1234)
    await b.issued(a)
    for offset in range(0, 32, 8):
        await store(b, c + offset, 0x1111111111111111 * (offset // 8 + 1))
    ep_a, _ = await b.issued(a)
    ep_c, _ = await b.issued(c)
    assert ep_a == 0 and ep_c != 0
    assert b.get("store_count") == 2
    assert b.acknowledged == 5
    assert (b.accesses, b.hits, b.misses, b.combined) == (5, 3, 2, 3)
    await b.grant(c)
    await b.tick(20)
    assert b.installs == [] and b.completions == []
    assert b.get("o_block_valid").bit_count() == 2
    await b.grant(a)
    await b.wait("o_pending_store", 0)
    await b.tick(5)
    assert b.installs == [a, c]
    assert [entry[1][2] for entry in b.completions] == [a, c]
    assert b.acknowledged == 5
    # Keep endpoint 0's U delayed across circular record reuse on an M hit.
    await b.release(c)
    for index in range(24):
        await store(b, c + 8 * (index % 4), index + 1)
        await b.wait("o_pending_store", 0)
    assert b.get("live") & 1
    await b.release(a)
    expected = sum((21 + word) << (64 * word) for word in range(4))
    assert await snapshot(b, c) == expected
    assert not b.get("o_fatal")


@cocotb.test()
async def same_sector_and_home_set_keep_older_records_first(dut: Any) -> None:
    """Exclude younger duplicate sectors and conflicting home rows."""
    for younger in (0x80000000, 0x80000080):
        b = Stream(dut)
        await b.reset()
        a, c = 0x80000000, 0x80000040
        await store(b, a, 0xAA, 1)
        await b.issued(a)
        await store(b, c, 0xCC, 1)
        await b.issued(c)
        await store(b, younger + 8, 0xBB, 1)
        await b.tick(12)
        assert len(b.demands) == 2
        await b.grant(c)
        await b.grant(a)
        await b.release(c)
        await b.tick(12)
        if younger == a:
            await b.wait("o_pending_store", 0)
            assert len(b.demands) == 2
            await b.release(a)
            assert await snapshot(b, a) == 0xAA | (0xBB << 64)
        else:
            assert len(b.demands) == 2
            await b.release(a)
            await b.issued(younger)
            await b.grant(younger)
            await b.release(younger)
            assert await snapshot(b, younger) == 0xBB << 64
        assert b.installs == [a, c, younger]
        assert not b.get("o_fatal")


@cocotb.test()
async def queued_bytes_are_excluded_from_probe_replies(dut: Any) -> None:
    """Return installed bytes while a later store waits for permission."""
    b = Stream(dut)
    await b.reset()
    a, c = 0x80000000, 0x80000040
    await store(b, c, 0x1234)
    await b.grant(c)
    await b.release(c)
    assert await snapshot(b, c) == 0x1234
    b.demands.clear()
    b.completions.clear()
    await store(b, a, 0x11)
    await b.issued(a)
    await store(b, c, 0x5678)
    await b.issued(c)
    await b.set(
        i_p_valid=1,
        i_p=pack(
            (2, 0), (6, 3), (1, 0), (b.p, c), (2, 2), (2, 0), (9, 0), (5, 0), (3, 0)
        ),
    )
    await b.wait("o_p_ready")
    await b.tick()
    await b.set(i_p_valid=0)
    await b.wait("o_r_valid")
    reply = unpack(b.get("o_r"), (2, 6, 1, 1, b.p, 2, 1, 1, 256, 1, 1, 1, 1, 1))
    assert reply[0] == 0 and reply[7] == 0
    await b.set(i_r_ready=1)
    await b.tick()
    await b.set(i_r_ready=0)
    await b.grant(c, 0x1234)
    await b.tick(8)
    assert b.installs == [c]
    await b.grant(a)
    await b.release(a)
    await b.release(c)
    assert await snapshot(b, c) == 0x5678


@cocotb.test()
async def borrowed_store_error_has_no_read_or_completion(dut: Any) -> None:
    """Stop a failed committed store without read completion or error disposal."""
    b = Stream(dut)
    await b.reset()
    a, c = 0x80000000, 0x80000040
    await store(b, a, 1)
    await b.issued(a)
    await store(b, c, 2)
    await b.issued(c)
    await b.grant(c, error=True)
    await b.tick(8)
    assert not b.get("o_fatal")
    await b.grant(a)
    await b.wait("o_fatal")
    await b.tick(10)
    assert b.get("o_fatal_addr") == c
    assert not b.get("o_read_valid")
    assert b.installs == [a]
    assert all(entry[1][2] == a for entry in b.completions)


@cocotb.test()
async def lr_hit_and_atomic_drains_include_borrowed_endpoint(dut: Any) -> None:
    """LR hits can finish beside U waits; SC and AMO wait for both releases."""
    for sc in (False, True):
        b = Stream(dut)
        await b.reset()
        a, c = 0x80000000, 0x80000040
        await store(b, a, 0x1234)
        await b.issued(a)
        await store(b, c, 0x5678)
        await b.issued(c)
        await b.grant(a)
        await b.grant(c)
        await b.wait("o_pending_store", 0)
        await b.set(
            i_read_valid=1, i_read_id=0, i_read_kind=1, i_address=a, i_read_ready=0
        )
        await b.tick()
        await b.set(i_read_valid=0)
        await b.wait("o_read_valid")
        assert b.get("o_read_data") == 0x1234 and len(b.demands) == 2
        await b.set(i_read_ready=1)
        await b.tick()
        if sc:
            await b.set(i_atomic_protected=1, i_sc_valid=1, i_sc_address=a, i_sc_size=3)
        else:
            await b.set(
                i_atomic_protected=1,
                i_read_valid=1,
                i_read_id=1,
                i_read_kind=2,
                i_address=a,
            )
            await b.tick()
            await b.set(i_read_valid=0)
        await b.tick(12)
        assert len(b.demands) == 2 and not b.get("o_sc_ready")
        await b.release(a)
        await b.tick(12)
        assert len(b.demands) == 2 and not b.get("o_sc_ready")
        await b.release(c)
        if sc:
            await b.wait("o_sc_ready")
            await b.tick()
            await b.set(i_sc_valid=0)
            assert b.get("o_atomic_live")
        else:
            for _ in range(60):
                if len(b.demands) == 3:
                    break
                await b.tick()
            assert len(b.demands) == 3
            assert b.get("o_atomic_live")
        assert not b.get("o_fatal")


@cocotb.test()
async def queued_predecessor_blocks_duplicate_lookahead(dut: Any) -> None:
    """Keep X2 behind unacquired X1 in H, X1, Y, X2 and preserve X1's bytes."""
    b = Stream(dut)
    await b.reset()
    h, x, y = 0x80000000, 0x80000040, 0x80000020
    await store(b, x, 0)
    await b.grant(x)
    await b.release(x)
    b.demands.clear()
    b.completions.clear()
    b.installs.clear()
    await store(b, h, 0x11, 1)
    await b.issued(h)
    await store(b, x, 0xAA, 1)
    x1 = (b.get("store_head_index") + 1) % 4
    for _ in range(100):
        if b.get("store_checked_q") & (1 << x1):
            break
        await b.tick()
    else:
        raise AssertionError("X1 did not finish its resident lookahead")
    await store(b, y, 0xCC, 1)
    await store(b, x + 8, 0xBB, 1)
    await b.issued(y)
    assert b.get("store_count") == 4
    head = b.get("store_head_index")
    x1, x2 = (head + 1) % 4, (head + 3) % 4
    assert not b.get("store_acquired") & (1 << x1)
    assert b.get("look_blocked") & (1 << x2)
    assert [d[2] for _, d in b.demands] == [h, y]
    assert await snapshot(b, x, invalidate=True) == 0
    await b.grant(y)
    await b.grant(h)
    await b.release(h)
    await b.issued(x)
    # The home image predates both partial stores to X.
    await b.grant(x, 0)
    await b.release(x)
    await b.release(y)
    await b.wait("o_pending_store", 0)
    assert b.installs == [h, x, y, x]
    assert len(b.demands) == 3
    assert await snapshot(b, x) == 0xAA | (0xBB << 64)


@cocotb.test()
async def load_hits_allow_repeated_store_borrowing(dut: Any) -> None:
    """Issue another borrowed GetM while unrelated resident loads keep arriving."""
    b = Stream(dut)
    await b.reset()
    base = 0x80000000
    hot = base + 32
    await store(b, hot, 0xABC)
    await b.grant(hot)
    await b.release(hot)
    for address in (base, base + 64):
        await store(b, address, address)
        await b.issued(address)
    for address in (base, base + 64):
        await b.grant(address)
    for address in (base, base + 64):
        await b.release(address)
    head, tail = base + 256, base + 320
    await store(b, head, 1)
    await b.issued(head)
    active: set[int] = set()
    consumed = 0

    async def hit() -> None:
        nonlocal consumed
        free = next((slot for slot in range(8) if slot not in active), None)
        await b.set(
            i_address=hot,
            i_read_valid=int(free is not None),
            i_read_kind=0,
            i_read_id=free or 0,
            i_read_size=3,
        )
        if free is not None:
            active.add(free)
        await b.tick()
        for slot, value in b.read_results[consumed:]:
            assert slot in active and value == 0xABC
            active.remove(slot)
        consumed = len(b.read_results)

    for _ in range(12):
        await hit()
    await b.set(i_read_valid=0)
    await store(b, tail, 2)
    for slot, value in b.read_results[consumed:]:
        assert slot in active and value == 0xABC
        active.remove(slot)
    consumed = len(b.read_results)
    for _ in range(100):
        await hit()
    assert consumed > 10
    assert any(ep != 0 and demand[2] == tail for ep, demand in b.demands)
    assert sum(demand[0] == 0 for _, demand in b.demands) == 0
    await b.set(i_read_valid=0)
    await b.grant(tail)
    await b.grant(head)
    await b.release(head)
    await b.release(tail)
    await b.wait("o_pending_store", 0)


@cocotb.test()
async def waiting_load_miss_keeps_its_allocation_turn(dut: Any) -> None:
    """Keep a borrowed store behind a known miss while resident hits are served."""
    b = Stream(dut)
    await b.reset()
    base = 0x80000000
    hot, load, miss = base + 160, base + 128, base + 224
    await store(b, hot, 0xABC)
    await b.grant(hot)
    await b.release(hot)
    await b.set(
        i_read_valid=1, i_read_id=0, i_read_kind=0, i_read_size=3, i_address=load
    )
    await b.tick()
    await b.set(i_read_valid=0)
    await b.issued(load)
    for address in (base, base + 64):
        await store(b, address, address)
        await b.issued(address)
    await b.set(i_read_valid=1, i_read_id=7, i_address=miss)
    await b.tick()
    await b.set(i_read_valid=0)
    for _ in range(100):
        if b.get("rd_miss_q") & 128:
            break
        await b.tick()
    assert b.get("rd_miss_q") & 128
    for address in (base + 32, base + 96):
        await store(b, address, address)
    await b.grant(base + 64)
    await b.grant(base)
    for _ in range(100):
        if b.installs[-2:] == [base, base + 64]:
            break
        await b.tick()
    assert b.installs[-2:] == [base, base + 64]
    active: set[int] = set()
    consumed = len(b.read_results)

    async def hit() -> None:
        nonlocal consumed
        free = next((slot for slot in range(1, 7) if slot not in active), None)
        await b.set(
            i_read_valid=int(free is not None), i_read_id=free or 1, i_address=hot
        )
        if free is not None:
            active.add(free)
        await b.tick()
        for slot, value in b.read_results[consumed:]:
            assert slot in active and value == 0xABC
            active.remove(slot)
        consumed = len(b.read_results)

    for _ in range(30):
        await hit()
    await b.set(i_read_valid=0)
    assert consumed > 0
    # Endpoint 0 and the other load keep their identities through this release.
    await b.release(base + 64)
    for _ in range(100):
        await hit()
        following = [d[2] for _, d in b.demands if d[2] in (miss, base + 96)]
        if following:
            assert following[0] == miss
            break
    else:
        raise AssertionError("the waiting load miss received no allocation")
    await b.set(i_read_valid=0)
    for address in (load, miss):
        await b.grant(address)
        await b.release(address)
    await b.release(base)
    for address in (base + 32, base + 96):
        await b.grant(address)
    for address in (base + 32, base + 96):
        await b.release(address)
    await b.wait("o_pending_store", 0)
    await b.wait("live", 0)
    assert not b.get("o_fatal")


@cocotb.test()
async def head_lookup_preserves_lookahead_allocation_turn(dut: Any) -> None:
    """Place a borrowed store between two misses across a head-store lookup."""
    b = Stream(dut)
    await b.reset()
    base = 0x80000000
    resident, first, second = base + 128, base + 224, base + 192
    await b.set(
        i_read_valid=1, i_read_id=0, i_read_kind=0, i_read_size=3, i_address=resident
    )
    await b.tick()
    await b.set(i_read_valid=0)
    await b.issued(resident)
    for address in (base, base + 64):
        await store(b, address, address)
        await b.issued(address)
    for address in (resident, base, base + 64):
        await b.grant(address)
    for _ in range(100):
        if len(b.completions) == 3:
            break
        await b.tick()
    assert len(b.completions) == 3
    for address in (base + 32, base + 96):
        await store(b, address, address)
    for slot, address in ((6, first), (7, second)):
        await b.set(i_read_valid=1, i_read_id=slot, i_address=address)
        await b.tick()
    await b.set(i_read_valid=0)
    for _ in range(100):
        if b.get("rd_miss_q") & 192 == 192 and b.get("pending_miss_q"):
            break
        await b.tick()
    assert b.get("rd_miss_q") & 192 == 192 and b.get("pending_miss_q")
    await b.release(base + 64)
    for _ in range(100):
        if b.get("operation_q") == 0 and b.get("phase_q") == 1:
            break
        await b.tick()
    assert b.get("selected_read_q") == 6
    await b.release(resident)
    for _ in range(100):
        if b.get("ep_request_valid"):
            break
        await b.tick()
    assert b.get("acq_ep_q") == 1 and b.get("selected_read_q") == 6
    _, demand = await b.issued(base)
    await b.set(i_u_valid=1, i_u=pack((9, demand[1]), (6, 0), (b.p, base)))
    assert b.get("o_u_ready")
    await b.tick()
    await b.set(i_u_valid=0)
    for _ in range(100):
        await b.tick()
        following = [d[2] for _, d in b.demands if d[2] in (second, base + 96)]
        if following:
            assert following[0] == base + 96
            break
    else:
        raise AssertionError("lookahead received no allocation after the load")
    await b.grant(base + 96)
    await b.grant(base + 32)
    for address in (base + 32, base + 96):
        await b.release(address)
    await b.grant(first)
    await b.release(first)
    await b.grant(second)
    await b.release(second)
    await b.wait("o_pending_store", 0)
    await b.wait("live", 0)
    assert b.installs == [base, base + 64, base + 32, base + 96]
    assert not b.get("o_fatal")
