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

"""Observe accepted-store ownership through CPU drain consumers."""

from collections import Counter
from typing import Any

from cocotb.triggers import FallingEdge


class StoreBurstWatch:
    """Require actual buffered overlap and check its externally visible holds."""

    def __init__(self, dut: Any) -> None:
        """Locate the production drain and store ownership signals."""
        self.hart = dut.cpu_and_memory_subsystem.cpu.hart
        self.cpu = self.hart.cpu_inst
        self.cache = self.hart.gen_coherent_tier.hart_cache.l1d
        self.sq = self.cpu.u_tomasulo.u_sq
        self.rob = self.cpu.u_tomasulo.u_rob
        self.hits: Counter[str] = Counter()

    async def run(self) -> None:
        """Sample every CPU cycle across both reset-separated program runs."""
        while True:
            await FallingEdge(self.hart.i_clk)
            if int(self.hart.i_rst.value):
                self.hits.clear()
                continue
            pending = int(self.cache.o_pending_store.value)
            if int(self.cache.tail_q.value):
                self.hits["two"] += 1
                assert int(self.cache.o_block_valid.value).bit_count() == int(
                    self.cache.store_count.value
                )
            if pending:
                assert not int(self.sq.o_committed_empty.value)
                assert not int(self.cache.o_atomic_live.value)
                if int(self.cpu.trap_pending.value):
                    self.hits["trap"] += 1
                if int(self.rob.head_f_is_fence_i.value):
                    self.hits["fence"] += 1
            if int(self.cache.store_pop.value):
                self.hits["install"] += 1
            if int(self.cache.o_sc_write_done.value):
                self.hits["sc"] += 1
            if int(self.cache.atomic_done_q.value) and not int(
                self.cache.atomic_sc_q.value
            ):
                self.hits["amo"] += 1

    def verify(self) -> None:
        """Reject a passing program that missed the intended overlap windows."""
        for event in ("two", "trap", "fence", "install", "sc", "amo"):
            assert self.hits[event], f"store burst missed {event}: {self.hits}"
