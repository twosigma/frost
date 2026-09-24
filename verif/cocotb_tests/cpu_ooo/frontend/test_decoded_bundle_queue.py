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

"""Randomized decoded_bundle_queue test with a held producer (ID) and an independent consumer."""

import random
from collections import deque
from typing import Any

import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def test_ownership_order_and_flush(dut: Any) -> None:
    """Compare the queue with a FIFO model under random stalls, pops, resets, and flushes.

    The run must cover a full queue, a bypass, a flush of live entries, an
    accepted bundle held in ID, and a same-cycle push and pop on a non-empty
    queue.
    """
    rng = random.Random(0xDEC0DE)
    depth = len(dut.live_q)
    queued: deque[tuple[int, bool]] = deque()
    consumed = False
    packet = 1
    valid = True
    indirect = False
    counts = {"full": 0, "bypass": 0, "flush_live": 0, "held": 0, "replace": 0}
    dut.i_clk.value = 0
    for cycle in range(4000):
        reset = cycle == 0 or cycle == 1800
        flush = cycle in (35, 40, 400, 1801) or rng.random() < 0.015
        full = len(queued) == depth
        # Long producer/consumer stalls deliberately fill, drain, and wrap.
        advance = not full and (cycle % 100 < 75)
        candidate = bool(queued) or (valid and not consumed)
        pop = candidate and cycle % 100 >= 15 and rng.random() < 0.8
        if reset or flush:
            pop = False
        dut.i_rst.value = reset
        dut.i_flush.value = flush
        dut.i_advance.value = advance
        dut.i_valid.value = valid
        dut.i_packet.value = packet
        shadow_mask = (1 << len(dut.i_shadow)) - 1
        dut.i_shadow.value = packet & shadow_mask
        dut.i_shadow_next.value = (
            packet + 1 if advance or reset or flush else packet
        ) & shadow_mask
        dut.i_indirect.value = indirect
        dut.i_pop.value = pop
        await Timer(5, unit="ns")
        if not reset:
            assert int(dut.o_full.value) == full, f"full at cycle {cycle}"
            assert int(dut.o_valid.value) == candidate, f"valid at cycle {cycle}"
            if candidate:
                expected = queued[0][0] if queued else packet
                assert int(dut.o_packet.value) == expected, f"packet at cycle {cycle}"
                if cycle > 0:
                    assert int(dut.o_shadow.value) == expected & shadow_mask, (
                        f"shadow at cycle {cycle}"
                    )
            assert bool(dut.o_indirect_pending.value) == any(item[1] for item in queued)
        if reset or flush:
            counts["flush_live"] += bool(queued)
            queued.clear()
            consumed = False
        else:
            accepted = valid and not consumed and not full
            counts["full"] += full
            counts["held"] += consumed and not advance
            counts["replace"] += bool(queued) and accepted and pop
            counts["bypass"] += not queued and accepted and pop
            if accepted:
                queued.append((packet, indirect))
            if pop:
                queued.popleft()
            consumed = False if advance else consumed or accepted
        dut.i_clk.value = 1
        await Timer(5, unit="ns")
        dut.i_clk.value = 0
        if advance or reset or flush:
            packet += 1
            valid = rng.random() < 0.9
            indirect = rng.random() < 0.2
    assert all(counts.values()), counts
