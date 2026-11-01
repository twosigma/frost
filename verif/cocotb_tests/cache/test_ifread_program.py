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

"""Check coherent reader events while executing dirty and translated DDR code."""

from collections import Counter
from typing import Any

import cocotb
from cocotb.triggers import FallingEdge

from cocotb_tests import test_real_program as program
from cocotb_tests.cache.test_coherence_home import unpack


class ReaderMonitor:
    """Separate the line-response debt from D/G/C/U ownership."""

    def __init__(self, dut: Any) -> None:
        """Resolve the real cache, walker and fetch interfaces."""
        self.hart = dut.cpu_and_memory_subsystem.cpu.hart
        self.cache = self.hart.gen_coherent_tier.hart_cache
        self.walker = self.hart.cpu_inst.u_ptw
        self.counts: Counter[str] = Counter()

    @staticmethod
    def get(obj: Any, name: str) -> int:
        """Sample one integer signal."""
        return int(getattr(obj, name).value)

    async def run(self) -> None:
        """Check response capture, release ownership and required overlaps."""
        c, w = self.cache, self.walker
        live: dict[int, dict[str, int]] = {}
        debt: dict[int, int] = {}
        expected: tuple[int, int, int, int] | None = None
        killed: set[int] = set()
        walk_debt = False
        discarded = False
        reset_seen = False

        def v(name: str) -> int:
            return self.get(c, name)

        while True:
            await FallingEdge(c.i_clk)
            if v("i_rst"):
                reset_seen = True
                live.clear()
                debt.clear()
                killed.clear()
                expected = None
                walk_debt = False
                discarded = False
                continue
            if not reset_seen:
                continue
            if self.get(w, "i_req_valid") and self.get(w, "o_req_ready"):
                discarded = False
            if self.get(w, "i_discard"):
                discarded = True
            if discarded:
                assert not self.get(w, "o_resp_valid")
            if expected is not None:
                q, ident, data, error = expected
                if q == 0x40:
                    assert v("o_walk_resp_valid")
                    assert v("o_walk_resp_data") == data
                    assert v("o_walk_resp_error") == error
                else:
                    assert v("if_resp_valid") and v("if_resp_id") == ident
                    assert v("if_resp_data") == data and v("if_resp_error") == error
            else:
                assert not v("if_resp_valid") and not v("o_walk_resp_valid")
            expected = None
            if self.get(self.hart.cached_fetch, "i_retarget"):
                killed.update(debt)
            if v("if_resp_valid"):
                if v("if_resp_id") in killed:
                    self.counts["killed_fetch_response"] += 1
                    killed.remove(v("if_resp_id"))
                assert v("if_resp_id") in debt
                del debt[v("if_resp_id")]
            if v("o_walk_resp_valid"):
                assert walk_debt
                walk_debt = False
                if discarded:
                    self.counts["discarded_walk_response"] += 1
                    assert not self.get(w, "o_resp_valid")
            if v("if_req_valid") and v("if_req_ready"):
                ident = v("if_req_id")
                assert ident not in debt
                debt[ident] = v("if_req_addr")
                q = 0x20 if v("if_slot_valid") & 1 else 0x22
                assert q not in live
                live[q] = dict(
                    ident=ident, addr=v("if_req_addr"), granted=0, complete=0
                )
                if len(debt) == 2:
                    self.counts["two_refills"] += 1
            if v("i_walk_req_valid") and v("o_walk_req_ready"):
                assert not walk_debt and 0x40 not in live
                walk_debt = True
                live[0x40] = dict(
                    ident=v("i_walk_req_id"),
                    addr=v("i_walk_req_addr"),
                    granted=0,
                    complete=0,
                )
            if self.get(w, "i_discard") and walk_debt:
                discarded = True
                self.counts["walk_discard"] += 1
            if v("i_fence_sync") and debt:
                self.counts["old_fill_at_fence"] += 1
            if v("i_g_valid") and v("o_g_ready"):
                g = unpack(v("i_g"), (3, 9, 6, 32, 256, 1))
                if g[1] in (0x20, 0x22, 0x40):
                    r = live[g[1]]
                    assert not r["granted"] and r["addr"] == g[3]
                    r.update(granted=1, tid=g[2], error=g[5])
                    expected = (g[1], r["ident"], g[4], g[5])
                    self.counts["early_grant"] += 1
            if v("o_c_valid") and v("i_c_ready"):
                complete = unpack(v("o_c"), (9, 6, 32, 2, 1))
                if complete[0] in live:
                    r = live[complete[0]]
                    assert r["granted"] and not r["complete"]
                    assert (complete[1], complete[2]) == (r["tid"], r["addr"])
                    assert complete[3] == (2 if r["error"] else 0)
                    r["complete"] = 1
            if v("i_u_valid") and v("o_u_ready"):
                release = unpack(v("i_u"), (9, 6, 32))
                if release[0] in (0x20, 0x22, 0x40):
                    r = live.pop(release[0])
                    assert r["complete"]
                    assert (release[1], release[2]) == (r["tid"], r["addr"])
                    self.counts["reader_release"] += 1
            if v("o_r_valid") and v("i_r_ready"):
                reply = unpack(v("o_r"), (2, 6, 1, 1, 32, 2, 1, 1, 256, 1, 1, 1, 1, 1))
                if reply[7] and any(
                    r["addr"] == reply[4] for q, r in live.items() if q != 0x40
                ):
                    self.counts["dirty_if"] += 1


@cocotb.test()
async def instruction_readers(dut: Any) -> None:
    """Require real DDR overlap, dirty grants, fence drain and walk discard."""
    monitor = ReaderMonitor(dut)
    task = cocotb.start_soon(monitor.run())
    try:
        await program.test_real_program.func(dut)
        for event in (
            "two_refills",
            "dirty_if",
            "old_fill_at_fence",
            "killed_fetch_response",
            "walk_discard",
            "discarded_walk_response",
        ):
            assert monitor.counts[event], (
                f"missing reader event: {event}; {monitor.counts}"
            )
        cocotb.log.info("Reader events: %s", dict(monitor.counts))
    finally:
        task.cancel()
