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

"""Count the full-line store events of a program, from the store queue to the L1D.

The watch samples the production store queue and L1D of a frost build on
every CPU cycle. It counts the store queue's hints as the L1D receives them
(i_write_more with a write, the next-same claim with and without a write and
a claim that ends without one), overlapped cached plain writes, the store
buffer's claimed credit at three and four records, the L1D's gather and pair
holds, full-pair acquisitions at the head and by look-ahead, data-twin
installs, and store-queue flushes (full or partial) while a gather or pair
window is open.

The home holds a block from its GetMZero until the L1D's Done, which follows
the data twin's install, so a DMA access to the block in that window waits at
the home. The watch counts DMA requests that the home's DMA ingress accepts for
a block whose pair acquisition is in flight (from the acquisition to the data
twin's install), probes that reach the L1D for such a block (possible only for
a copy the L1D held before), probes during an owed twin, and probes of a block
within 64 cycles after its data twin installed: the snoops that waited.
A program that names the events it must reach fails without them.
"""

from collections import Counter
from typing import Any

from cocotb.triggers import FallingEdge

# coherence_l1d operation_t: StoreOp 1, LookaheadOp 8, TwinOp 9.
STORE_OP = 1
LOOKAHEAD_OP = 8
TWIN_OP = 9
PROBE_INVALIDATE = 1
# The events that full_line_test exists to reach.
FULL_LINE_TEST_EVENTS = (
    "write_more",
    "claim_gap",
    "claim_write",
    "claim_three",
    "merge_four",
    "sq_overlap",
    "hold_head",
    "hold_next",
    "pair_head",
    "pair_lookahead",
    "data_twin",
    "squash_in_window",
    "dma_in_window",
    "probe_after_window",
)
# Cycles after a data twin's install in which a probe of its block counts as
# one that waited for the window.
AFTER_WINDOW = 64


def _bits(value: int, low: int, width: int) -> int:
    return (value >> low) & ((1 << width) - 1)


class FullLineWatch:
    """Count full-line events across the store queue and the L1D."""

    def __init__(self, dut: Any, required: tuple[str, ...] = ()) -> None:
        """Locate the production store queue, L1D and its store buffer."""
        hart = dut.cpu_and_memory_subsystem.cpu.hart
        self.clk = hart.i_clk
        self.rst = hart.i_rst
        self.l1d = hart.gen_coherent_tier.hart_cache.l1d
        self.buffer = self.l1d.store_buffer
        self.sq = hart.cpu_inst.u_tomasulo.u_sq
        self.addr_bits = len(self.l1d.i_address)
        memory = dut.cpu_and_memory_subsystem.cpu.cluster_memory
        self.ingress = memory.gen_coherent_tier.gen_dma_ingress.ingress
        self.required = required
        self.hits: Counter[str] = Counter()
        self.runs: list[dict[str, int]] = []
        self._reset_state()

    def _reset_state(self) -> None:
        self.prev_claim = 0
        self.prev_push = 0
        # 64-byte blocks of pairs acquired and not yet installed by their twin.
        self.pending: set[int] = set()
        # Cycle of each block's last data twin install.
        self.installed: dict[int, int] = {}
        self.cycle = 0

    def _record_block(self, index: int) -> int:
        value = int(self.l1d.store_addr.value)
        return _bits(value, index * self.addr_bits, self.addr_bits) >> 6

    async def run(self) -> None:
        """Sample every CPU cycle; a reset starts the next run's counts."""
        while True:
            await FallingEdge(self.clk)
            if int(self.rst.value):
                if self.hits:
                    self.runs.append(dict(self.hits))
                    self.hits.clear()
                self._reset_state()
                continue
            self.sample()

    def sample(self) -> None:
        """Count this cycle's events."""
        l1d, sq, hits = self.l1d, self.sq, self.hits
        self.cycle += 1
        push = int(l1d.store_push.value)
        claim = int(l1d.merge_claim.value)
        count = int(l1d.store_count.value)
        if push:
            hits["writes"] += 1
            hits["write_more"] += int(l1d.i_write_more.value)
            hits["merge_four"] += int(count == 4)
        if claim:
            hits["claim_write" if push else "claim_gap"] += 1
        if self.prev_claim and not self.prev_push and not claim and not push:
            hits["claim_drop"] += 1
        self.prev_claim, self.prev_push = claim, push
        hits["claim_three"] += int(self.buffer.claim_ready.value)
        if (
            int(sq.o_mem_write_en.value)
            and int(sq.o_mem_write_is_cached.value)
            and int(sq.write_inflight_cnt.value) != 0
            and int(sq.write_inflight_cached.value)
        ):
            hits["sq_overlap"] += 1
        hits["hold_head"] += int(l1d.gather_hold_head.value)
        hits["hold_next"] += int(l1d.gather_hold_next.value)
        window = int(l1d.gather_open.value) or int(l1d.pair_open.value)
        if window and int(sq.i_flush_all.value):
            hits["flush_all_in_window"] += 1
        if window and int(sq.i_flush_en.value):
            hits["flush_partial_in_window"] += 1
        if window and (int(sq.i_flush_all.value) or int(sq.i_flush_en.value)):
            hits["squash_in_window"] += 1
        operation = int(l1d.operation_q.value)
        if int(l1d.store_acquire.value) and int(l1d.pair_acquire_q.value):
            hits["pair_lookahead" if operation == LOOKAHEAD_OP else "pair_head"] += 1
            self.pending.add(self._record_block(int(l1d.store_selected_q.value)))
        if int(l1d.store_pop.value) and operation == TWIN_OP:
            head = int(l1d.store_head_index.value)
            if not (int(l1d.store_zero.value) >> head & 1):
                hits["data_twin"] += 1
                block = self._record_block(head)
                self.pending.discard(block)
                self.installed[block] = self.cycle
        ingress = self.ingress
        if int(ingress.i_req_valid.value) and int(ingress.o_req_ready.value):
            block = int(ingress.i_req_addr.value) >> 6
            kind = "write" if int(ingress.i_req_write.value) else "read"
            if block in self.pending:
                hits["dma_in_window"] += 1
                hits[f"dma_{kind}_in_window"] += 1
        if int(l1d.i_p_valid.value) and int(l1d.o_p_ready.value):
            probe = int(l1d.i_p.value)
            width = len(l1d.i_p)
            block = _bits(probe, 21, self.addr_bits) >> 6
            opcode = _bits(probe, width - 2, 2)
            if int(l1d.twin_fill_q.value):
                hits["probe_twin_owed"] += 1
            kind = "inval" if opcode == PROBE_INVALIDATE else "read"
            if block in self.pending:
                hits["probe_pair_window"] += 1
            done = self.installed.get(block)
            if done is not None and self.cycle - done <= AFTER_WINDOW:
                hits["probe_after_window"] += 1
                hits[f"probe_{kind}_after_window"] += 1

    def verify(self, log: Any) -> None:
        """Log the run's counts and require the named events."""
        counts = dict(self.hits)
        log.info(f"FULL_LINE_WATCH {sorted(counts.items())}")
        missing = [event for event in self.required if not counts.get(event)]
        assert not missing, f"full-line events missed {missing}: {counts}"
