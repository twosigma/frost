#    Copyright 2026 John Goodacre
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

"""Same-address load order (CoRR) across an invalidating probe and the L1D hit path.

The real LQ, ROB and coherence port drive the real coherent L1D. An older load A
and a younger load B read one word. B is issued first and reaches the L1D hit
path while the line is resident (old value); an invalidating probe (the DMA
write's ProbeInvalidate) is injected at a swept cycle offset, so its capture
falls before, during and after B's hit-path stages. After the probe reply the
line holds the new value and A is issued, misses and reads the new value. RVWMO
forbids A = new with B = old once both retire, so B must replay (or read new).
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from cocotb_tests.cache.test_coherence_endpoints import pack
from cocotb_tests.tomasulo.tomasulo_wrapper.test_coherent_cut import issue
from cocotb_tests.tomasulo.tomasulo_wrapper.test_coherent_stream_order import (
    StreamInterface,
)
from cocotb_tests.tomasulo.tomasulo_wrapper.test_tomasulo_wrapper import (
    OP_LW,
    RS_MEM,
    make_int_req,
)

SECTOR = 0x80008000
OLD = 0x11111111
NEW = 0x22222222
EXC_MEM_REPLAY = 24


def image(word: int) -> int:
    """Return a 32-byte sector image with the word at every 4-byte offset."""
    return sum(word << (32 * n) for n in range(8))


class OrderInterface(StreamInterface):
    """Record per-cycle hit-path and probe state beside the stream records."""

    def __init__(self, dut: Any) -> None:
        """Initialize the cycle trace."""
        super().__init__(dut)
        self.cycle = 0
        self.trace: list[dict[str, int]] = []
        self.cdb_values: dict[int, list[int]] = {}

    async def step(self) -> None:
        """Sample hit-path stages, probe service and the cut before the edge."""
        await Timer(1, unit="ps")
        c = self.dut.cache
        self.trace.append(
            {
                "cycle": self.cycle,
                "s2": int(c.s2_valid_q.value),
                "s3": int(c.s3_valid_q.value),
                "s4": int(c.s4_valid_q.value),
                "probe": int(c.probe_valid_q.value),
                "capture": int(self.dut.i_probe_valid.value)
                & int(self.dut.o_probe_ready.value),
                "cut": int(c.cut_phase_q.value),
                "reply": int(self.dut.o_reply_valid.value)
                & int(self.dut.i_reply_ready.value),
                "replay": int(self.dut.core.u_rob.rob_replay.value),
            }
        )
        if int(self.dut.i_rst_n.value):
            cdb = self.read_cdb_output()
            if cdb.valid:
                self.cdb_values.setdefault(cdb.tag, []).append(cdb.value)
        self.cycle += 1
        await super().step()


async def serve(b: OrderInterface, served: set[int], word: int) -> None:
    """Complete every new request for the sector with the given word."""
    for index, (_, fields) in enumerate(b.requests):
        if index not in served and fields[2] == SECTOR:
            served.add(index)
            await b.complete(index, image(word))


async def run_offset(dut: Any, offset: int) -> dict[str, Any]:
    """Run one probe offset and return the observed outcome."""
    for signal in dut:
        if signal._name.startswith(("i_cache_", "i_probe_", "i_seed_", "i_reply_")):
            signal.value = 0
    b = OrderInterface(dut)
    await b.reset_dut()
    b.set_fu_ready(RS_MEM, True)
    b.set_commit_hold(True)
    dut.i_coherent_store_ready.value = 1
    dut.i_cache_d_ready.value = 255
    for _ in range(25):
        await b.step()
    served: set[int] = set()
    # Install the sector (old value) through a load of its second dword, so the
    # L0 keeps no copy of the word that A and B read.
    seed = await b.dispatch(make_int_req(pc=0x3000, rd=5))
    await issue(b, seed, OP_LW, SECTOR + 8)
    await b.wait_request(SECTOR)
    await serve(b, served, OLD)
    await b.wait_value(seed, OLD)
    b.set_commit_hold(False)
    for _ in range(10):
        await b.step()
    b.set_commit_hold(True)
    assert any(c["tag"] == seed for c in b.commits)
    older = await b.dispatch(make_int_req(pc=0x4000, rd=8))
    younger = await b.dispatch(make_int_req(pc=0x4004, rd=9))
    await issue(b, younger, OP_LW, SECTOR)
    issue_cycle = b.cycle
    for _ in range(offset):
        await b.step()
    # Invalidating probe (ProbeInvalidate, reason Write) with immediate cut
    # service and reply acceptance.
    dut.i_probe_delay_admit.value = 0
    dut.i_probe_delay_inval.value = 0
    dut.i_reply_ready.value = 1
    dut.i_probe.value = pack(
        (2, 1), (6, 1), (1, 0), (32, SECTOR), (2, 2), (2, 1), (9, 0), (5, 0), (3, 0)
    )
    dut.i_probe_valid.value = 1
    capture_cycle = -1
    for _ in range(100):
        await Timer(1, unit="ps")
        if int(dut.o_probe_ready.value):
            capture_cycle = b.cycle
            await b.step()
            break
        await b.step()
    assert capture_cycle >= 0, "probe was not captured"
    dut.i_probe_valid.value = 0
    reply_cycle = -1
    for _ in range(100):
        await Timer(1, unit="ps")
        if int(dut.o_reply_valid.value):
            reply_cycle = b.cycle
            await b.step()
            break
        await b.step()
    assert reply_cycle >= 0, "probe reply did not arrive"
    dut.i_reply_ready.value = 0
    # The DMA write is ordered at the home after the reply: every later request
    # for the sector reads the new value.
    await issue(b, older, OP_LW, SECTOR)
    for _ in range(200):
        await serve(b, served, NEW)
        if older in b.values and younger in b.values:
            break
        await b.step()
    assert older in b.values and younger in b.values, (b.values, b.requests)
    replay_flag = bool(int(dut.core.u_rob.rob_replay.value) >> younger & 1)
    b.set_commit_hold(False)
    for _ in range(40):
        await b.step()
    b.set_commit_hold(True)
    trap_pending = bool(int(dut.o_trap_pending.value))
    trap_cause = int(dut.o_trap_cause.value)
    committed = [c["tag"] for c in b.commits]
    s4_cycles = [t["cycle"] for t in b.trace if t["s4"] and t["cycle"] >= issue_cycle]
    s2_cycles = [t["cycle"] for t in b.trace if t["s2"] and t["cycle"] >= issue_cycle]
    overlap = [t["cycle"] for t in b.trace if t["s4"] and t["probe"]]
    return {
        "offset": offset,
        "older": older,
        "younger": younger,
        "a_value": b.values[older],
        "b_value": b.values[younger],
        "b_values": b.cdb_values.get(younger, []),
        "trap_pending": trap_pending,
        "trap_cause": trap_cause,
        "b_replay_flag": replay_flag,
        "a_committed": older in committed,
        "b_committed": younger in committed,
        "issue": issue_cycle,
        "capture": capture_cycle,
        "reply": reply_cycle,
        "s2": s2_cycles,
        "s4": s4_cycles,
        "s4_during_probe": overlap,
    }


@cocotb.test()
async def corr_hit_path_across_invalidating_probe(dut: Any) -> None:
    """Sweep the probe capture across B's hit path; no older-new/younger-old retirement."""
    Clock(dut.i_clk, 10, unit="ns").start()
    results = []
    for offset in range(0, 12):
        r = await run_offset(dut, offset)
        results.append(r)
        dut._log.info("CORR %s", r)
        assert r["a_value"] == NEW
        assert r["a_committed"]
        # Each load answers once; a second answer could hide a stale first one.
        assert r["b_values"] == [r["b_value"]], r
        if r["b_value"] == OLD:
            # B observed the line before the invalidation: it must be flagged
            # and must not retire behind A; it waits at the head as a replay.
            assert r["b_replay_flag"], r
            assert not r["b_committed"], r
            assert r["trap_pending"] and r["trap_cause"] == EXC_MEM_REPLAY, r
        if r["b_committed"]:
            assert r["b_value"] == NEW, r
    # The sweep must reach the reviewed case: a hit-path stage-4 answer while
    # the invalidating probe is in service.
    assert any(r["s4_during_probe"] for r in results), results
    assert any(r["b_value"] == OLD for r in results), results
    # The offsets must also bracket B's hit path: a probe captured before B
    # enters it (B misses and reads the new value) and one captured after B's
    # stage-4 answer. A change of hit-path depth that moves the window out of
    # the swept offsets fails one of these.
    assert any(r["b_value"] == NEW and not r["s4"] for r in results), results
    assert any(r["s4"] and r["capture"] > r["s4"][0] for r in results), results
