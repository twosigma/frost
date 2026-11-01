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

"""Control G/C/U around the real instruction cache, fetch provider and walker."""

from typing import Any

import cocotb
from cocotb.triggers import Timer

from cocotb_tests.cache.test_coherence_endpoints import pack
from cocotb_tests.cache.test_coherence_home import unpack


class Readers:
    """Track reader responses separately from coherent identity ownership."""

    def __init__(self, dut: Any) -> None:
        """Initialize independent protocol and reader tracking."""
        self.dut = dut
        self.cycle = 0
        self.demands: list[tuple[int, ...]] = []
        self.live: dict[int, dict[str, int]] = {}
        self.responses: list[tuple[int, int, int]] = []
        self.walks: list[int] = []
        self.if_ids: list[int] = []
        self.if_debt: set[int] = set()
        self.early: tuple[int, int] | None = None
        self.expected_word: int | None = None

    def get(self, name: str) -> int:
        """Read a signal after combinational settling."""
        return int(getattr(self.dut, name).value)

    async def step(self, **inputs: int) -> dict[str, int]:
        """Observe all handshakes before the active clock edge."""
        self.dut.i_clk.value = 0
        for name, value in inputs.items():
            getattr(self.dut, "i_" + name).value = value
        await Timer(5, unit="ns")
        names = (
            "req_ready",
            "resp_valid",
            "resp_id",
            "resp_data",
            "resp_error",
            "fence_done",
            "walk_ready",
            "walk_valid",
            "translation",
            "line_valid",
            "line_ready",
            "line_resp",
            "line_error",
            "if_accept",
            "if_id",
            "if_response",
            "if_response_id",
            "d_valid",
            "d",
            "g_ready",
            "c_valid",
            "c",
            "u_ready",
            "instr_valid",
            "instr",
            "served_word",
        )
        s = {n: self.get("o_" + n) for n in names}
        if not self.get("i_rst"):
            if self.expected_word is not None and s["instr_valid"]:
                assert s["served_word"] == self.expected_word
            if self.early is not None:
                q, error = self.early
                if q == 0x40:
                    assert s["line_resp"] and s["line_error"] == error
                else:
                    assert s["if_response"]
            else:
                assert not s["if_response"] and not s["line_resp"]
            self.early = None
            if s["if_response"]:
                assert s["if_response_id"] in self.if_debt
                self.if_debt.remove(s["if_response_id"])
            if s["if_accept"]:
                assert s["if_id"] not in self.if_debt
                self.if_debt.add(s["if_id"])
                self.if_ids.append(s["if_id"])
            if s["d_valid"] and self.get("i_d_ready"):
                d = unpack(s["d"], (4, 9, 32, 5, 3, 32, 1, 1, 1, 256))
                assert d[1] not in self.live, "identity reused before U"
                self.live[d[1]] = dict(
                    addr=d[2], granted=0, completed=0, tid=0, error=0
                )
                self.demands.append(d)
            if self.get("i_g_valid") and s["g_ready"]:
                g = unpack(self.get("i_g"), (3, 9, 6, 32, 256, 1))
                record = self.live[g[1]]
                assert not record["granted"] and record["addr"] == g[3]
                record.update(granted=1, tid=g[2], error=g[5])
                self.early = g[1], g[5]
            if s["c_valid"] and self.get("i_c_ready"):
                c = unpack(s["c"], (9, 6, 32, 2, 1))
                record = self.live[c[0]]
                assert record["granted"] and not record["completed"]
                assert (c[1], c[2]) == (record["tid"], record["addr"])
                assert c[3] == (2 if record["error"] else 0)
                record["completed"] = 1
            if self.get("i_u_valid") and s["u_ready"]:
                u = unpack(self.get("i_u"), (9, 6, 32))
                assert self.live[u[0]]["completed"]
                del self.live[u[0]]
            if s["resp_valid"]:
                self.responses.append((s["resp_id"], s["resp_data"], s["resp_error"]))
            if s["walk_valid"]:
                self.walks.append(s["translation"])
        self.dut.i_clk.value = 1
        await Timer(5, unit="ns")
        self.cycle += 1
        return s

    async def wait(self, predicate: Any, limit: int = 400) -> dict[str, int]:
        """Bound all waits on channels and cache maintenance."""
        for _ in range(limit):
            s = await self.step()
            if predicate(s):
                return s
        raise AssertionError(f"condition timed out at cycle {self.cycle}")

    async def reset(self) -> None:
        """Reset protocol state and initialize the real cache arrays."""
        for signal in self.dut:
            if signal._name.startswith("i_"):
                signal.value = 0
        self.live.clear()
        self.demands.clear()
        self.responses.clear()
        self.walks.clear()
        self.if_ids.clear()
        self.if_debt.clear()
        self.early = None
        self.expected_word = None
        await self.step(rst=1)
        await self.step(rst=0, d_ready=1, c_ready=1, imem_done=1, root=0x80000)
        for _ in range(100):
            await self.step()

    async def request(self, addr: int, ident: int) -> None:
        """Offer one instruction line until the L1I accepts it."""
        self.dut.i_req_valid.value = 1
        self.dut.i_req_addr.value = addr
        self.dut.i_req_id.value = ident
        await self.wait(lambda s: s["req_ready"])
        self.dut.i_req_valid.value = 0

    async def grant(self, q: int, data: int, error: int = 0, gap: bool = True) -> None:
        """Return final data and check the registered early pulse."""
        record = self.live[q]
        tid = (q >> 1) & 63
        g = pack(
            (3, 3), (9, q), (6, tid), (32, record["addr"]), (256, data), (1, error)
        )
        s = await self.step(g_valid=1, g=g)
        assert s["g_ready"]
        if gap:
            await self.step(g_valid=0)

    async def release(self, q: int) -> None:
        """Retire only a completed coherent identity."""
        await self.wait(lambda _: bool(self.live[q]["completed"]))
        record = self.live[q]
        u = pack((9, q), (6, record["tid"]), (32, record["addr"]))
        s = await self.step(u_valid=1, u=u)
        assert s["u_ready"]
        await self.step(u_valid=0)

    async def walk(self, vpn: int = 7) -> None:
        """Start a translation while its previous bridge tail may remain live."""
        s = await self.step(walk_valid=1, vpn=vpn)
        assert s["walk_ready"]
        await self.step(walk_valid=0)


def line(word: int) -> int:
    """Replicate a PTE across the four doublewords of its sector."""
    return sum(word << (64 * n) for n in range(4))


@cocotb.test()
async def two_refills_fence_and_reversed_completion(dut: Any) -> None:
    """Drain two pre-fence fills before invalidation while U remains withheld."""
    b = Readers(dut)
    await b.reset()
    await b.step(c_ready=0)
    await b.request(0x80000000, 3)
    await b.request(0x80000020, 6)
    await b.wait(lambda _: len(b.demands) == 2)
    assert set(b.live) == {0x20, 0x22} and not b.responses
    for q, addr in ((0x24, 0x80000000), (0x40, 0x80000000)):
        g = pack((3, 0), (9, q), (6, 0), (32, addr), (256, 0), (1, 0))
        assert not (await b.step(g_valid=1, g=g))["g_ready"]
    # Readiness matches the waiting q independently of the G address.
    for q in (0x20, 0x22):
        g = pack((3, 0), (9, q), (6, 0), (32, 0x80000080), (256, 0), (1, 0))
        assert (await b.step(g_valid=0, g=g))["g_ready"]
    await b.step(g_valid=0)
    await b.step(fence=1)
    for _ in range(10):
        assert not (await b.step())["fence_done"]
    await b.grant(0x22, line(0x2222), gap=False)
    await b.grant(0x20, line(0x1111))
    await b.wait(lambda s: bool(s["fence_done"]))
    assert sorted(b.responses) == [(3, line(0x1111), 0), (6, line(0x2222), 0)]
    assert all(not r["completed"] for r in b.live.values())
    await b.step(c_ready=1, fence=0)
    await b.release(0x22)
    await b.release(0x20)
    await b.request(0x80000000, 9)
    await b.wait(lambda _: len(b.demands) == 3)
    await b.grant(0x20, line(0x3333))
    await b.wait(lambda _: len(b.responses) == 3)
    assert b.responses[-1] == (9, line(0x3333), 0)
    await b.release(0x20)


@cocotb.test()
async def reused_mshr_error_and_held_identity(dut: Any) -> None:
    """Reuse an answered MSHR in the other slot and hold a third request for U."""
    b = Readers(dut)
    await b.reset()
    await b.request(0x80000000, 0)
    await b.wait(lambda _: len(b.demands) == 1)
    await b.grant(0x20, line(0x1234), error=1)
    await b.wait(lambda _: len(b.responses) == 1)
    assert b.responses[0][2] == 1
    await b.request(0x80000020, 1)
    await b.wait(lambda _: len(b.demands) == 2)
    assert b.if_ids[0] == b.if_ids[1]
    await b.grant(0x22, line(0x5678))
    await b.wait(lambda _: len(b.responses) == 2)
    await b.request(0x80000040, 2)
    for _ in range(15):
        await b.step()
        assert len(b.demands) == 2
    # Wrong TID, address, and identity cannot release a live slot.
    for q, tid, addr in (
        (0x20, 63, 0x80000000),
        (0x20, 16, 0x80000080),
        (0x24, 16, 0x80000000),
    ):
        s = await b.step(u_valid=1, u=pack((9, q), (6, tid), (32, addr)))
        assert not s["u_ready"]
    await b.step(u_valid=0)
    await b.release(0x20)
    await b.wait(lambda _: len(b.demands) == 3)
    await b.grant(0x20, line(0x9ABC))
    await b.wait(lambda _: len(b.responses) == 3)
    await b.release(0x22)
    await b.release(0x20)
    assert len(b.responses) == 3 and not b.live


@cocotb.test()
async def walk_errors_discard_and_retry_with_release_held(dut: Any) -> None:
    """Classify root/interior errors and consume discarded grants exactly once."""
    b = Readers(dut)
    for depth in range(3):
        for discarded in (False, True):
            await b.reset()
            await b.walk()
            for level in range(depth + 1):
                await b.wait(lambda _: 0x40 in b.live)
                g = pack((3, 0), (9, 0x40), (6, 0), (32, 0x80000080), (256, 0), (1, 0))
                assert (await b.step(g_valid=0, g=g))["g_ready"]
                if level == depth:
                    await b.step(discard=int(discarded))
                    await b.grant(0x40, line((0x80000 << 10) | 0xCF), error=1)
                    await b.step(discard=0)
                else:
                    await b.grant(0x40, line(((0x80001 + level) << 10) | 1))
                    await b.release(0x40)
            await b.wait(lambda s: bool(s["walk_ready"]))
            if discarded:
                assert not b.walks
            else:
                assert len(b.walks) == 1 and b.walks[0] >> 78 == 3
                assert (b.walks[0] >> 51) & ((1 << 27) - 1) == 7
            before = len(b.demands)
            await b.walk(vpn=11)
            for _ in range(8):
                s = await b.step()
                assert s["line_valid"] and not s["line_ready"]
                assert len(b.demands) == before
            await b.release(0x40)
            await b.wait(lambda _: len(b.demands) == before + 1)
            await b.grant(0x40, line((0x80000 << 10) | 0xCF))
            await b.wait(lambda s: bool(s["walk_ready"]))
            assert b.walks[-1] >> 78 == 0
            assert (b.walks[-1] >> 51) & ((1 << 27) - 1) == 11
            await b.release(0x40)


@cocotb.test()
async def killed_fetch_and_fatal_tail(dut: Any) -> None:
    """Retarget an accepted fetch and preserve its response-free fatal tail."""
    b = Readers(dut)
    await b.reset()
    await b.step(use_fetch=1, fetch_valid=1, pc=0x80000000)
    await b.wait(lambda _: len(b.demands) == 1)
    await b.step(pc=0x80000080, retarget=1, invalidate=1)
    b.expected_word = 0x80000080 >> 2
    await b.step(retarget=0, invalidate=0)
    await b.grant(0x20, line(0x0010009300100093))
    await b.wait(lambda _: len(b.demands) == 2)
    for _ in range(12):
        s = await b.step()
        assert not s["instr_valid"] or s["served_word"] == 0x80000080 >> 2
    await b.step(fatal_stop=1)
    await b.grant(0x22, line(0x0020009300200093))
    await b.wait(lambda s: bool(s["instr_valid"]))
    assert b.get("o_served_word") == 0x80000080 >> 2
    await b.release(0x22)
    await b.release(0x20)
    for _ in range(10):
        await b.step()
    assert not b.live and len(b.responses) == 2


@cocotb.test()
async def reset_during_each_protocol_phase(dut: Any) -> None:
    """Clear all coherent channels together at Demand, Grant, Complete and Release."""
    b = Readers(dut)
    for phase in range(4):
        await b.reset()
        await b.step(d_ready=int(phase != 0), c_ready=int(phase == 3))
        await b.request(0x80000000, 0)
        if phase == 0:
            await b.wait(lambda s: bool(s["d_valid"]))
        else:
            await b.wait(lambda _: len(b.demands) == 1)
        if phase >= 2:
            await b.grant(0x20, line(0xCF))
        if phase == 3:
            await b.wait(lambda _: bool(b.live[0x20]["completed"]))
        await b.reset()
        assert not b.live and not b.responses and not b.walks
