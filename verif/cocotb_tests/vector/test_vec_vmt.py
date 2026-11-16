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

"""Check vec_vmt against a model of the vector memory table's lifecycle.

Vector memory instructions are allocated in program order (ROB tags are the
low bits of a sequence number), commit oldest first, are flushed (all
unretired ones, or those younger than a flush point), complete only after
they retire, and get their range once. Flush removals remain live for one
extra cycle; they cannot retire or release a retired entry's ordering hold.
Every cycle the bench compares the
table's view, its allocation index and full flag, the generations and the
registered "no live retired entry" term with the model.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

VMT = 4


@cocotb.test()
async def test_vec_vmt_random(dut: Any) -> None:
    """Random lifecycle traffic against the model."""
    rng = random.Random(77)
    tagw = len(dut.i_alloc_tag)
    ntag = 1 << tagw
    seg_w = len(dut.i_range_seg0)
    ent_w = len(dut.o_view) // VMT
    Clock(dut.i_clk, 2, unit="ns").start()
    for sig in (
        "i_alloc_valid",
        "i_alloc_tag",
        "i_commit_valid",
        "i_commit_tag",
        "i_flush_all",
        "i_flush_en",
        "i_flush_tag",
        "i_head_tag",
        "i_range_valid",
        "i_range_idx",
        "i_range_seg0",
        "i_range_seg1",
        "i_done_valid",
        "i_done_idx",
    ):
        getattr(dut, sig).value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0

    ent: list[Any] = [None] * VMT
    gen = [0] * VMT
    seq = 0
    head = 0  # sequence number of the oldest unretired instruction
    stats = {"alloc": 0, "commit": 0, "flush": 0, "done": 0, "quiet0": 0}
    pending: set[int] = set()
    for cycle in range(8000):
        # Expected outputs from the registered model state.
        free = [t for t in range(VMT) if ent[t] is None]
        exp_full = not free
        exp_idx = free[0] if free else 0
        exp_quiet = not any(e is not None and e["ret"] for e in ent)
        await ReadOnly()
        view = int(dut.o_view.value)
        for t in range(VMT):
            w = (view >> (ent_w * t)) & ((1 << ent_w) - 1)
            live, ret = (w >> (ent_w - 1)) & 1, (w >> (ent_w - 2)) & 1
            tag = (w >> (2 * seg_w + 1)) & (ntag - 1)
            known = (w >> (2 * seg_w)) & 1
            e = ent[t]
            assert live == (e is not None), f"cycle {cycle} entry {t} live"
            if e is not None:
                assert ret == e["ret"] and tag == e["seq"] % ntag, (
                    f"cycle {cycle} entry {t}"
                )
                assert known == e["known"], f"cycle {cycle} entry {t} known"
                if e["known"]:
                    assert w & ((1 << (2 * seg_w)) - 1) == e["segs"], (
                        f"cycle {cycle} entry {t} segs"
                    )
            assert ((int(dut.o_gen.value) >> (2 * t)) & 3) == gen[t] % 4, (
                f"cycle {cycle} gen {t}"
            )
        assert int(dut.o_full.value) == exp_full, f"cycle {cycle} full"
        if not exp_full:
            assert int(dut.o_alloc_idx.value) == exp_idx, f"cycle {cycle} alloc idx"
        assert int(dut.o_quiet_q.value) == exp_quiet, f"cycle {cycle} quiet"
        stats["quiet0"] += not exp_quiet
        await FallingEdge(dut.i_clk)

        # Inputs for the next edge.
        unret = sorted(
            (e["seq"], t)
            for t, e in enumerate(ent)
            if e is not None and not e["ret"] and t not in pending
        )
        alloc = not exp_full and rng.random() < 0.4
        commit = bool(unret) and rng.random() < 0.3
        flush_all = rng.random() < 0.02
        flush_en = not flush_all and len(unret) > 1 and rng.random() < 0.05
        flush_point = unret[rng.randrange(len(unret) - 1)][0] if flush_en else 0
        alloc = alloc and not flush_all
        done_cand = [t for t, e in enumerate(ent) if e is not None and e["ret"]]
        done = bool(done_cand) and rng.random() < 0.25
        done_idx = rng.choice(done_cand) if done else 0
        rng_cand = [t for t, e in enumerate(ent) if e is not None and not e["known"]]
        rng_w = bool(rng_cand) and rng.random() < 0.3
        rng_idx = rng.choice(rng_cand) if rng_w else 0
        s0, s1 = rng.getrandbits(seg_w), rng.getrandbits(seg_w)
        dut.i_alloc_valid.value = int(alloc)
        dut.i_alloc_tag.value = seq % ntag
        dut.i_commit_valid.value = int(commit)
        dut.i_commit_tag.value = unret[0][0] % ntag if commit else 0
        dut.i_flush_all.value = int(flush_all)
        dut.i_flush_en.value = int(flush_en)
        dut.i_flush_tag.value = flush_point % ntag
        dut.i_head_tag.value = head % ntag
        dut.i_done_valid.value = int(done)
        dut.i_done_idx.value = done_idx
        dut.i_range_valid.value = int(rng_w)
        dut.i_range_idx.value = rng_idx
        dut.i_range_seg0.value = s0
        dut.i_range_seg1.value = s1
        await RisingEdge(dut.i_clk)

        # Apply last cycle's removals; the pre-edge free index cannot name
        # one of these entries, even when a tag is reused after a flush.
        for t in pending:
            ent[t] = None
        pending = set()
        # Model update for that edge.
        if commit:
            ent[unret[0][1]]["ret"] = True
            stats["commit"] += 1
        for t, e in enumerate(ent):
            if (
                e is not None
                and not e["ret"]
                and (flush_all or (flush_en and e["seq"] > flush_point))
            ):
                pending.add(t)
                stats["flush"] += 1
        if done:
            ent[done_idx] = None
            stats["done"] += 1
        if rng_w and ent[rng_idx] is not None:
            ent[rng_idx]["known"] = True
            ent[rng_idx]["segs"] = (s1 << seg_w) | s0
        if alloc and not flush_all:
            ent[exp_idx] = {"seq": seq, "ret": False, "known": False, "segs": 0}
            gen[exp_idx] += 1
            seq += 1
            stats["alloc"] += 1
        unret_seqs = [
            e["seq"]
            for t, e in enumerate(ent)
            if e is not None and not e["ret"] and t not in pending
        ]
        head = min(unret_seqs) if unret_seqs else seq
    dut._log.info(f"model matched: {stats}")
    assert min(stats.values()) > 50, "traffic too thin"


@cocotb.test()
async def test_flush_retirement_and_reuse(dut: Any) -> None:
    """Flush cleanup cannot release retired work or kill a reused entry."""
    Clock(dut.i_clk, 10, unit="ns").start()
    ent_w = len(dut.o_view) // VMT

    def live() -> int:
        view = int(dut.o_view.value)
        return sum(((view >> (ent_w * t + ent_w - 1)) & 1) << t for t in range(VMT))

    async def tick(**values: int) -> None:
        await FallingEdge(dut.i_clk)
        for name, value in values.items():
            getattr(dut, name).value = value
        await RisingEdge(dut.i_clk)
        await ReadOnly()

    await tick(
        **{
            name: 0
            for name in (
                "i_alloc_valid",
                "i_alloc_tag",
                "i_commit_valid",
                "i_commit_tag",
                "i_flush_all",
                "i_flush_en",
                "i_flush_tag",
                "i_head_tag",
                "i_range_valid",
                "i_range_idx",
                "i_range_seg0",
                "i_range_seg1",
                "i_done_valid",
                "i_done_idx",
            )
        },
        i_rst=1,
    )
    await tick(i_rst=0)
    for tag in (4, 5, 6):
        await tick(i_alloc_valid=1, i_alloc_tag=tag, i_head_tag=4)
    assert live() == 7
    # Retirement wins on the flush edge, and quiet falls on that same edge.
    await tick(i_alloc_valid=0, i_commit_valid=1, i_commit_tag=4, i_flush_all=1)
    assert live() == 7, "flush cleanup must wait for its local register"
    assert int(dut.o_quiet_q.value) == 0
    # The first recovery allocation uses the pre-edge free index, not a
    # pending removal. The head can move without changing the sampled mask.
    await tick(
        i_flush_all=0, i_commit_valid=0, i_head_tag=20, i_alloc_valid=1, i_alloc_tag=20
    )
    assert live() == 9 and int(dut.o_quiet_q.value) == 0
    await tick(i_alloc_tag=21)
    assert live() == 11, "a pending flush must not kill a reused index"
    await tick(i_alloc_valid=0, i_flush_en=1, i_flush_tag=20)
    assert live() == 11
    await tick(i_flush_en=0, i_head_tag=21)
    assert live() == 9
    # Full flushes on consecutive cycles remove only unretired work; the
    # live retired entry keeps quiet low until its completion edge.
    await tick(i_flush_all=1)
    await tick(i_flush_all=1)
    assert live() == 1 and int(dut.o_quiet_q.value) == 0
    await tick(i_flush_all=0, i_done_valid=1, i_done_idx=0)
    assert live() == 0 and int(dut.o_quiet_q.value) == 1
    await tick(i_done_valid=0, i_alloc_valid=1, i_alloc_tag=21)
    await tick(i_alloc_valid=0)
    assert live() == 1
    # Neither a trap's nor an interrupt's full flush creates a quiet pulse
    # before retired memory completes; an unretired entry never affects it.
    await tick(i_flush_all=1)
    assert live() == 1 and int(dut.o_quiet_q.value) == 1
    await tick(i_flush_all=0)
    assert live() == 0 and int(dut.o_quiet_q.value) == 1
    await Timer(1, unit="ns")
