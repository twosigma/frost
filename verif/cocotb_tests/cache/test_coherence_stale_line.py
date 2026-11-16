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

"""Slab-like node reuse through the L1D and the home.

A small pool of 256-byte nodes is zeroed, copied into and read back in
random order, as the kernel's maple tree reuses slab objects: memset (full
64-byte lines), memcpy from another node (loads interleaved with full-line
stores), cbo.zero blocks (clear_page), partial stores and loads that run
ahead of older stores. The nodes map onto every L1D and home set, so lines
written in one state are evicted and reused in another. The driver keeps the
store queue's rules: stores leave in program order after every older load has
returned, at the store queue's cadence and hints; a load reaches the L1D only
after every older store to its dword completed. Each load checks the value
program order gives it; at the end every byte is read through the L1D and
the agent port.

Background agent traffic runs beside the program: DMA reads of any node, DMA
writes of DMA-only nodes in the same sets, and L2 prefetches. Odd seeds also
hold grants, put acknowledgements and releases for random bursts.

Environment: STALE_SEEDS, STALE_SEED0 and STALE_OPS size the run; STALE_DELAY
randomizes memory latency (and so reorders responses); STALE_AGENT is the
agent's per-cycle start probability (0 turns it off); STALE_POOL sets the node
count; STALE_L1D names the L1D size for the default pool. STALE_WATCH (a hex
block address) logs that block's channel traffic, and STALE_LO/STALE_HI a
cycle window of L1D store-buffer state.
"""

import os
import random
from collections import deque
from typing import Any

import cocotb

from cocotb_tests.cache.test_coherence_cbo_zero import BLOCK, ZeroCluster
from cocotb_tests.cache.test_coherence_endpoints import pack
from cocotb_tests.cache.test_coherence_home import unpack

NODE = 256
MASK64 = (1 << 64) - 1


class FullCluster(ZeroCluster):
    """Drive store streams and track the expected memory image."""

    def __init__(self, dut: Any) -> None:
        """Track each dword's expected value beside the cbo.zero counters."""
        super().__init__(dut)
        self.expect: dict[int, int] = {}
        self.dones = 0
        self.pushes = 0
        # (cycle, endpoint, opcode, address, mask) of each accepted request.
        self.requests: list[tuple[int, int, int, int, int]] = []
        self.agent_grants: list[tuple[Any, ...]] = []

    async def tick(self, count: int = 1) -> None:
        """Advance, counting write completions."""
        for _ in range(count):
            if self.get("o_write_done"):
                self.dones += 1
            if not self.get("i_rst"):
                if self.get("o_agent_g_valid"):
                    self.agent_grants.append(
                        unpack(self.get("o_agent_g"), (3, 9, 6, self.p, 256, 1))
                    )
                accepted = int(self.dut.hart_d_valid.value) & int(
                    self.dut.hart_d_ready.value
                )
                for ep in range(len(self.dut.hart_d_valid)):
                    if accepted >> ep & 1:
                        width = self.p + 312
                        bits = (int(self.dut.hart_d.value) >> (width * ep)) & (
                            (1 << width) - 1
                        )
                        fields = unpack(bits, (4, 9, self.p, 5, 3, 32, 1, 1, 1, 256))
                        self.requests.append(
                            (self.cycle, ep, fields[0], fields[2], fields[5])
                        )
            await super().tick()

    def preload(self, block: int, seed: int) -> None:
        """Fill the block's memory lines and record the old dwords."""
        super().preload(block, seed)
        for offset in range(0, BLOCK, 8):
            address = block + offset
            line = address & -self.line
            self.expect[address] = (
                self.memory[line] >> (8 * (address - line))
            ) & MASK64

    async def drain(self) -> None:
        """Wait until every store record installs and every store completed."""
        await self.wait("o_pending_store", 0, limit=4000)
        await self.tick(4)
        assert self.dones == self.pushes, f"{self.dones} dones for {self.pushes} stores"


class NodeCluster(FullCluster):
    """Drive interleaved loads and stores against a golden dword image."""

    def __init__(self, dut: Any, rng: random.Random) -> None:
        """Start an empty program."""
        super().__init__(dut)
        self.rng = rng
        self.model: dict[int, int] = {}
        # Program items in order: [kind, address, value, mask, state].
        self.program: deque[list[Any]] = deque()
        self.loads_checked = 0
        self.failures: list[str] = []
        # Issue loads in program order (a stream that a load loop trains).
        self.in_order_loads = False
        # Hold the home's grants to the L1D for this many cycles of the next
        # program, so its acquisitions stay outstanding while lookups run.
        self.hold_grant_cycles = 0
        # Background agent traffic: DMA reads of any node, DMA writes of the
        # DMA-only nodes, and L2 prefetches, one request at a time.
        self.agent_on = False
        self.agent_rate = 0.0
        self.agent_targets: list[int] = []
        self.dma_nodes: list[int] = []
        self.dma_model: dict[int, int] = {}
        self.agent_state = 0
        self.agent_op: tuple[int, int, int] = (0, 0, 0)
        self.agent_grant: tuple[Any, ...] = ()
        self.agent_ops = 0

    def get_opt(self, name: str) -> int:
        """Read a signal the harness may not have (0 when it is absent)."""
        return self.get(name) if hasattr(self.dut, name) else 0

    async def set(self, **values: int) -> None:
        """Set inputs, leaving out store-queue hints a harness does not have."""
        await super().set(**{k: v for k, v in values.items() if hasattr(self.dut, k)})

    async def agent_step(self) -> None:
        """Advance the background agent request by one cycle's inputs."""
        rng = self.rng
        p = self.p
        state = self.agent_state
        if state == 0:
            if not self.agent_on or rng.random() >= self.agent_rate:
                return
            kind = rng.choice((0, 0, 1, 1, 2))
            if kind == 1:
                sector = rng.choice(self.dma_nodes) + 32 * rng.randrange(NODE // 32)
            else:
                sector = rng.choice(self.agent_targets) + 32 * rng.randrange(NODE // 32)
            data = rng.getrandbits(256)
            self.agent_op = (kind, sector, data)
            src = 3 if kind == 2 else 2
            q = pack((2, src), (2, 3), (4, 13 if src == 2 else 1), (1, 0))
            opcode = (7, 8, 9)[kind]
            request = pack(
                (4, opcode),
                (9, q),
                (p, sector),
                (5, 0),
                (3, 5),
                (32, 0xFFFFFFFF if kind == 1 else 0),
                (1, 0),
                (1, 0),
                (1, 0),
                (256, data if kind == 1 else 0),
            )
            await self.set(i_agent_valid=1, i_agent_d=request)
            self.agent_state = 2 if self.get("o_agent_ready") else 1
        elif state == 1:
            if self.get("o_agent_ready"):
                # Accepted on the edge of the cycle that saw ready.
                self.agent_state = 2
        elif state == 2:
            await self.set(i_agent_valid=0)
            if self.get("o_agent_g_valid"):
                self.agent_grant = unpack(self.get("o_agent_g"), (3, 9, 6, p, 256, 1))
                await self.set(i_agent_g_ready=int(self.agent_op[0] != 2))
                self.agent_state = 3
        elif state == 3:
            await self.set(i_agent_g_ready=0)
            kind, sector, data = self.agent_op
            grant = self.agent_grant
            if kind == 1:
                for word in range(4):
                    self.dma_model[sector + 8 * word] = (data >> (64 * word)) & MASK64
            elif kind == 0 and sector & -NODE in self.dma_nodes:
                for word in range(4):
                    got = (grant[4] >> (64 * word)) & MASK64
                    want = self.dma_model.get(sector + 8 * word, 0)
                    if got != want:
                        self.failures.append(
                            f"cycle {self.cycle}: DMA read {sector + 8 * word:#x} got "
                            f"{got:#x} want {want:#x}"
                        )
            q = grant[1]
            await self.set(
                i_agent_c_valid=1,
                i_agent_c=pack((9, q), (6, grant[2]), (p, sector), (2, 0), (1, 0)),
            )
            self.agent_state = 5 if self.get("o_agent_c_ready") else 4
        elif state == 4:
            if self.get("o_agent_c_ready"):
                self.agent_state = 5
        elif state == 5:
            await self.set(i_agent_c_valid=0)
            if self.get("o_agent_u_valid"):
                await self.set(i_agent_u_ready=1)
                self.agent_state = 6
        elif state == 6:
            await self.set(i_agent_u_ready=0)
            self.agent_ops += 1
            self.agent_state = 0

    async def agent_quiesce(self) -> None:
        """Finish the background request in flight and stop new ones."""
        self.agent_on = False
        for _ in range(3000):
            if self.agent_state == 0:
                return
            await self.tick()
        raise AssertionError(f"agent stuck in state {self.agent_state}")

    async def tick(self, count: int = 1) -> None:
        """Advance, tracing the watched block's channel traffic when asked."""
        watch = os.environ.get("STALE_WATCH")
        for _ in range(count):
            if not self.get("i_rst") and (self.agent_on or self.agent_state):
                await self.agent_step()
            if watch and not self.get("i_rst"):
                self.trace(int(watch, 16))
            await super().tick()

    def trace(self, block: int) -> None:
        """Log every message of this cycle that names the watched block."""
        d = self.dut
        p = self.p
        log = d._log.info

        def mine(address: int) -> bool:
            return address & -64 == block

        if int(d.g_valid.value) and int(d.g_ready.value):
            g = unpack(int(d.grant.value), (3, 9, 6, p, 256, 1))
            if mine(g[3]):
                log(
                    "TR %d G op=%d q=%#x addr=%#x data=%#x",
                    self.cycle,
                    g[0],
                    g[1],
                    g[3],
                    g[4],
                )
        if int(d.w_valid.value) and int(d.w_ready.value):
            w = unpack(int(d.put.value), (1, 1, 1, p, 256, 1))
            if mine(w[3]):
                log("TR %d W put=%d addr=%#x data=%#x", self.cycle, w[1], w[3], w[4])
        if int(d.p_valid.value) and int(d.p_ready.value):
            pr = unpack(int(d.probe.value), (2, 6, 1, p, 2, 2, 9, 5, 3))
            if mine(pr[3]):
                log("TR %d P op=%d addr=%#x", self.cycle, pr[0], pr[3])
        if int(d.r_valid.value) and int(d.r_ready.value):
            r = unpack(int(d.reply.value), (2, 6, 1, 1, p, 2, 1, 1, 256, 1, 1, 1, 1, 1))
            if mine(r[4]):
                log(
                    "TR %d R op=%d addr=%#x state=%d dv=%d data=%#x",
                    self.cycle,
                    r[0],
                    r[4],
                    r[5],
                    r[7],
                    r[8],
                )
        if int(d.u_valid.value) and int(d.u_ready.value):
            u = unpack(int(d.release_message.value), (9, 6, p))
            if mine(u[2]):
                log("TR %d U q=%#x addr=%#x", self.cycle, u[0], u[2])
        if self.get("o_mem_req_valid") and self.get("i_mem_req_ready"):
            address = self.get("o_mem_req_addr")
            if mine(address):
                log(
                    "TR %d MEM write=%d addr=%#x data=%#x",
                    self.cycle,
                    self.get("o_mem_req_write"),
                    address,
                    self.get("o_mem_req_data"),
                )
        accepted = int(d.hart_d_valid.value) & int(d.hart_d_ready.value)
        for ep in range(len(d.hart_d_valid)):
            if accepted >> ep & 1:
                width = p + 312
                bits = (int(d.hart_d.value) >> (width * ep)) & ((1 << width) - 1)
                f = unpack(bits, (4, 9, p, 5, 3, 32, 1, 1, 1, 256))
                if mine(f[2]):
                    log(
                        "TR %d D ep=%d op=%d addr=%#x mask=%#x",
                        self.cycle,
                        ep,
                        f[0],
                        f[2],
                        f[5],
                    )
        if (
            self.get("i_write_mask")
            and mine(self.get("i_address"))
            and self.get("o_store_ready") >= 0
        ):
            log(
                "TR %d push addr=%#x data=%#x mask=%#x zero=%d more=%d same=%d",
                self.cycle,
                self.get("i_address"),
                self.get("i_write_data"),
                self.get("i_write_mask"),
                self.get("i_write_zero"),
                self.get_opt("i_write_more"),
                self.get_opt("i_next_same"),
            )
        if self.get("i_read_valid") and mine(self.get("i_address")):
            log(
                "TR %d load addr=%#x id=%d",
                self.cycle,
                self.get("i_address"),
                self.get("i_read_id"),
            )
        lo, hi = (
            int(os.environ.get("STALE_LO", "0")),
            int(os.environ.get("STALE_HI", "0")),
        )
        if lo <= self.cycle <= hi:
            h = d.hart
            log(
                "TR %d state done=%d twin_alloc=%d twin_pending=%d count=%d head=%d valid=%#x addr=%s"
                " zero=%#x twin=%#x block_valid=%#x block_addr=%s phase=%d op=%d",
                self.cycle,
                self.get("o_write_done"),
                int(h.store_twin_alloc.value),
                int(h.store_twin_pending.value),
                int(h.store_count.value),
                int(h.store_head_index.value),
                int(h.store_valid.value),
                [
                    hex(int(h.store_addr.value) >> (p * i) & ((1 << p) - 1))
                    for i in range(4)
                ],
                int(h.store_zero.value),
                int(h.store_twin.value),
                self.get("o_block_valid"),
                [
                    hex(self.get("o_block_addr") >> (p * i) & ((1 << p) - 1))
                    for i in range(4)
                ],
                int(h.phase_q.value),
                int(h.operation_q.value),
            )

    def word(self, address: int) -> int:
        """Return the golden dword at an aligned address."""
        return self.model.get(address, 0)

    def put(self, address: int, value: int, mask: int) -> None:
        """Apply a store to the golden image."""
        base = address & -8
        old = self.word(base)
        for byte in range(8):
            if mask >> byte & 1:
                shift = 8 * byte
                old = (old & ~(0xFF << shift)) | (value & (0xFF << shift))
        self.model[base] = old

    def st(self, address: int, value: int, mask: int = 0xFF) -> None:
        """Append a scalar store; value is lane-aligned in the dword."""
        self.program.append(["st", address, value & MASK64, mask, 0])
        self.put(address, value, mask)

    def zero(self, block: int) -> None:
        """Append a cbo.zero of a 64-byte block."""
        self.program.append(["zero", block & -64, 0, 0xFF, 0])
        for offset in range(0, 64, 8):
            self.model[(block & -64) + offset] = 0

    def ld(self, address: int, after_stores: bool = False) -> None:
        """Append a dword load expecting the program-order value.

        With after_stores, the load also waits for every older store's done,
        as a load behind a full store queue does.
        """
        self.program.append(
            ["ld", address & -8, self.word(address & -8), 0xFF, int(after_stores)]
        )

    def preload_node(self, node: int, seed: int) -> None:
        """Fill a node's memory lines and the golden image."""
        for block in range(node, node + NODE, 64):
            self.preload(block, seed + block)
        for offset in range(0, NODE, 8):
            address = node + offset
            line = address & -self.line
            self.model[address] = (self.memory[line] >> (8 * (address - line))) & MASK64

    async def run_program(self, hold: bool = False) -> None:
        """Issue the program with out-of-order loads and in-order stores."""
        rng = self.rng
        items = list(self.program)
        self.program.clear()
        n = len(items)
        store_idx = [i for i, it in enumerate(items) if it[0] != "ld"]
        # For each load, the index (into store_idx) of the last older store
        # that writes its dword or whose block a zero covers.
        last_store_for: dict[int, int] = {}
        seen_store = -1
        last_writer: dict[int, int] = {}
        for i, it in enumerate(items):
            if it[0] == "ld":
                last_store_for[i] = seen_store if it[4] else last_writer.get(it[1], -1)
            else:
                seen_store += 1
                if it[0] == "zero":
                    for offset in range(0, 64, 8):
                        last_writer[it[1] + offset] = seen_store
                else:
                    last_writer[it[1] & -8] = seen_store
        # Loads still to issue, in program order, and the program index of
        # each store.
        pending_loads = [i for i, it in enumerate(items) if it[0] == "ld"]
        load_done = [False] * n
        free_ids = list(range(8))
        rng.shuffle(free_ids)
        inflight: dict[int, int] = {}
        next_store = 0
        pushed = 0
        # Dones arrive in push order; a previous program's last dones may
        # still be on their way.
        done_base = self.pushes
        ready_prev = 0
        since = 9
        gap = rng.choice((1, 1, 2, 3))
        last_sector = -1
        last_plain = False
        hold_left = 0
        hold_kind = 0
        stall = 0

        def store_committable(k: int) -> bool:
            """Every load older than store k has returned."""
            pos = store_idx[k]
            for li in pending_loads:
                if li < pos:
                    return False
                break
            return all(load_done[li] for li in inflight.values() if li < pos)

        def next_claim(k: int, sector: int, plain: bool) -> int:
            if not plain or k >= len(store_idx):
                return 0
            it = items[store_idx[k]]
            return int(
                it[0] == "st" and (it[1] & -32) == sector and store_committable(k)
            )

        while next_store < len(store_idx) or pending_loads or inflight:
            stall += 1
            assert stall < 20000, f"no progress at cycle {self.cycle}"
            if self.hold_grant_cycles:
                self.hold_grant_cycles -= 1
                await self.set(i_hold_grant=int(self.hold_grant_cycles > 0))
            if os.environ.get("STALE_DELAY") and rng.random() < 0.3:
                self.read_delay = rng.randrange(3, 60)
            if hold:
                if hold_left == 0 and rng.random() < 0.02:
                    hold_left = rng.randrange(1, 30)
                    hold_kind = rng.randrange(1, 8)
                if hold_left:
                    hold_left -= 1
                await self.set(
                    i_hold_grant=int(bool(hold_left and hold_kind & 1)),
                    i_hold_wa=int(bool(hold_left and hold_kind & 2)),
                    i_hold_release=int(bool(hold_left and hold_kind & 4)),
                )
            completed = self.dones - done_base
            write = False
            if (
                next_store < len(store_idx)
                and ready_prev
                and since >= gap
                and store_committable(next_store)
            ):
                write = rng.random() < 0.85
            issue = None
            if not write and free_ids and pending_loads:
                # The oldest loads whose stores have completed may issue, out of
                # order among themselves.
                for li in pending_loads[: 1 if self.in_order_loads else 6]:
                    need = last_store_for[li]
                    if (
                        need < completed
                        and need < pushed
                        and (self.in_order_loads or rng.random() < 0.7)
                    ):
                        issue = li
                        break
            if write:
                it = items[store_idx[next_store]]
                kind, address, value, mask = it[0], it[1], it[2], it[3]
                plain = kind == "st"
                more = int(plain and next_store + 1 < len(store_idx))
                await self.set(
                    i_address=address,
                    i_write_data=value,
                    i_write_mask=mask,
                    i_write_atomic=0,
                    i_write_sc=0,
                    i_write_zero=int(kind == "zero"),
                    i_write_more=more,
                    i_next_same=next_claim(next_store + 1, address & -32, plain),
                    i_write_tag=7,
                    i_read_valid=0,
                )
                last_sector, last_plain = address & -32, plain
            else:
                await self.set(
                    i_write_mask=0,
                    i_write_zero=0,
                    i_write_more=0,
                    i_next_same=next_claim(next_store, last_sector, last_plain),
                )
                if issue is not None:
                    slot = free_ids.pop()
                    inflight[slot] = issue
                    pending_loads.remove(issue)
                    await self.set(
                        i_address=items[issue][1],
                        i_read_id=slot,
                        i_read_kind=0,
                        i_read_size=3,
                        i_read_tag=1,
                        i_read_valid=1,
                    )
                else:
                    await self.set(i_read_valid=0)
            response = None
            ready = int(rng.random() < 0.8)
            await self.set(i_read_ready=ready)
            if self.get("o_read_valid") and ready:
                response = (self.get("o_read_id"), self.get("o_read_data"))
            ready_now = self.get("o_store_ready")
            await self.tick()
            await self.set(i_read_valid=0)
            if write:
                pushed += 1
                next_store += 1
                since = 1
                gap = rng.choice((1, 1, 1, 2, 3, 3, 5))
                stall = 0
            else:
                since += 1
            if issue is not None:
                stall = 0
            if response is not None:
                slot, data = response
                assert slot in inflight, f"response for idle slot {slot}"
                li = inflight.pop(slot)
                free_ids.append(slot)
                load_done[li] = True
                self.loads_checked += 1
                want = items[li][2]
                if data != want:
                    msg = (
                        f"cycle {self.cycle}: load {items[li][1]:#x} got {data:#x} "
                        f"want {want:#x}"
                    )
                    self.dut._log.error("STALE %s", msg)
                    self.failures.append(msg)
                    assert len(self.failures) < 4, "\n".join(self.failures)
                stall = 0
            ready_prev = ready_now
        await self.set(
            i_write_mask=0,
            i_write_more=0,
            i_next_same=0,
            i_read_ready=0,
            i_hold_grant=0,
            i_hold_wa=0,
            i_hold_release=0,
        )
        self.pushes += pushed


def value(rng: random.Random) -> int:
    """Return a random nonzero dword."""
    return rng.getrandbits(64) | 1


@cocotb.test()
async def zero_twin_beside_stream(dut: Any) -> None:
    """Check a cbo.zero twin whose sector the stream prefetches during its look-ahead GetMZero.

    A store to a cold line holds the head. A cbo.zero of a block in another
    page follows, so its lower record (the tail) acquires the block with a
    look-ahead GetMZero while its twin, the upper record, is two records
    behind the head. Loads that ascend through the block's page then train the
    stream, whose window reaches the twin's sector. A store to the twin's sector
    follows the loads; every dword of the block is checked afterwards. Without
    the record terms in the prefetch conflicts, the stream sends a GetS for the
    twin's sector, the home grants it after the GetMZero's U, and its GrantS
    replaces the store (and the zeros, when the block was resident in the L2).
    """
    trials = int(os.environ.get("STALE_TRIALS", "40"))
    rng = random.Random(int(os.environ.get("STALE_SEED0", "1")))
    c = NodeCluster(dut, rng)
    c.in_order_loads = True
    await c.reset()
    c.dma_nodes = []
    blocks = []
    for trial in range(trials):
        page = 0x80900000 + 0x2000 * trial
        head = 0x80F00000 + 0x40 * trial
        block = page + 0x40 * rng.randrange(2, 5)
        c.preload_node(page, 0x8100 + trial)
        c.preload_node(page + NODE, 0x8200 + trial)
        c.preload_node(head & -NODE, 0x8300 + trial)
        c.read_delay = rng.choice((90, 150, 250))
        # Warm the page (and sometimes the block) into the L2 and evict it from
        # the L1D, so the ascending loads miss the L1D but hit the L2 quickly
        # while the head store's memory read holds the cbo.zero behind it.
        for offset in range(0, block - page, 32):
            c.ld(page + offset)
        if rng.random() < 0.5:
            # The block resident in the L2: its GetMZero then hits.
            for offset in range(0, 64, 32):
                c.ld(block + offset)
        evict = 0x80E00000 + 0x4000 * (trial % 4)
        for offset in range(0, 2048, 32):
            c.ld(evict + offset)
        await c.run_program(hold=False)
        c.st(head, value(rng))
        c.zero(block)
        # The ascending loads wait for the cbo.zero's done, as loads behind it
        # in the store queue do, so the twin's record already exists.
        for offset in range(0, block - page, 8):
            c.ld(page + offset, after_stores=offset == 0)
        c.st(block + 0x28, value(rng))
        for offset in range(0, 64, 8):
            c.ld(block + offset)
        blocks.append(block)
        c.hold_grant_cycles = rng.choice((0, 0, 60))
        await c.run_program(hold=False)
    await c.drain()
    for block in blocks:
        for offset in range(0, 64, 8):
            got = await c.read(block + offset)
            want = c.word(block + offset)
            if got != want:
                c.failures.append(f"final {block + offset:#x}: {got:#x} != {want:#x}")
    upper = sum(
        1 for a in c.speculative_requests if any(b + 32 <= a < b + 64 for b in blocks)
    )
    dut._log.info(
        "ZERO_TWIN trials=%d prefetches=%d into_twins=%d failures=%d",
        trials,
        len(c.speculative_requests),
        upper,
        len(c.failures),
    )
    assert not c.failures, "\n".join(c.failures[:8])


@cocotb.test()
async def zero_push_during_prefetch_lookup(dut: Any) -> None:
    """Refuse a stream prefetch whose block receives a cbo.zero before array_valid.

    Three ascending demand misses confirm a stream. On the cycle before the tag
    array replies to the stream prefetcher's LookupWait for the upper sector of
    a 64-byte block, a cbo.zero of that block pushes: on the array_valid cycle
    lookup_conflict_q is still low so the controller steps to Acquire while
    lookup_conflict latches the pending twin and the twin allocates its record.
    Acquire drops the prefetch under !prefetch_acquire_ok without sending a
    speculative GetS.
    """
    c = FullCluster(dut)
    await c.reset()
    page = 0x80940000
    block = page + 0x80
    for offset in range(0, 0x100, 64):
        c.preload(page + offset, 0x9100 + offset)
    await c.read(page + 0x00)
    await c.read(page + 0x20)
    await c.set(
        i_address=page + 0x40,
        i_read_id=0,
        i_read_kind=0,
        i_read_size=3,
        i_read_valid=1,
        i_read_ready=1,
    )
    await c.tick()
    await c.set(i_read_valid=0)
    pushed = False
    for _ in range(200):
        if (
            int(dut.hart.phase_q.value) == 2
            and int(dut.hart.array.phase_q.value) == 3
            and int(dut.hart.array.count_q.value) == 1
            and int(dut.hart.operation_q.value) == 7
            and int(dut.hart.lookup_addr_q.value) == block + 32
        ):
            assert c.get("o_store_ready") == 1
            await c.set(
                i_address=block,
                i_write_data=0,
                i_write_mask=0xFF,
                i_write_zero=1,
                i_write_tag=5,
            )
            c.pushes += 1
            await c.tick()
            await c.set(i_write_mask=0, i_write_zero=0)
            assert int(dut.hart.phase_q.value) == 2
            assert int(dut.hart.array_valid.value) == 1
            assert int(dut.hart.store_twin_pending.value) == 1
            await c.tick()
            assert int(dut.hart.phase_q.value) == 3
            assert int(dut.hart.operation_q.value) == 7
            assert int(dut.hart.prefetch_acquire_ok.value) == 0
            assert int(dut.hart.acquire_ready.value) == 1
            pushed = True
            break
        await c.tick()
    assert pushed, "stream prefetch never entered LookupWait for block + 32"
    for _ in range(200):
        if int(dut.hart.rd_valid_q.value) == 0 and not c.get("o_read_valid"):
            break
        await c.tick()
    assert int(dut.hart.rd_valid_q.value) == 0 and not c.get("o_read_valid")
    await c.set(i_read_ready=0)
    await c.drain()
    await c.check_block(block)
    assert block + 32 not in c.speculative_requests


@cocotb.test()
async def zero_pending_twin_lookahead_beside_stream(dut: Any) -> None:
    """Keep look-ahead GetMZero and stream prefetches off a waiting cbo.zero twin.

    When an older cbo.zero's upper twin holds the store-buffer head on endpoint
    0, two same-home-set scalar stores sit behind it, and a younger cbo.zero
    fills the fourth record, 2'(slot + 1) wraps to the head twin. Neither
    LookaheadOp nor an ascending load stream trained in that window may acquire
    the younger block before its own upper twin allocates.
    """
    c = FullCluster(dut)
    await c.reset()
    page = 0x80960000
    block = page + 0x80
    head_block = 0x80F01040
    s1_addr = head_block + 0x4000
    s2_addr = head_block + 0x8000
    for offset in range(0, 0x140, 64):
        c.preload(page + offset, 0xA100 + offset)
    c.preload(head_block, 0xA200)
    c.preload(s1_addr, 0xA300)
    c.preload(s2_addr, 0xA400)

    # Warm the three preceding stream sectors into the 64 KiB L2 and evict them
    # from the 1 KiB L1D, leaving block itself cold in DDR with nonzero bytes.
    for addr in (page + 0x60, page + 0x40, page + 0x20):
        await c.read(addr)
    for way in range(8):
        for s in (0, 2, 1, 3):
            await c.read(0x80E00000 + way * 0x100 + s * 32)
    await c.drain()

    # Put head_block + 0 Modified in L1D set 2, then fill all four ways of L1D
    # set 3 with dirty lines and occupy both L1D writeback slots under i_hold_wa:
    # cbo.zero(head_block) pops its lower record immediately while its upper twin
    # stalls at store_head_index in L1D set 3. Source-3 L2 prefetches then evict
    # head_block from the 4-way home so releasing i_hold_wa sends the head twin's
    # GetM(head_block + 32) to DDR on endpoint 0 for 600 cycles.
    await c.store(head_block, 0xCAFE)
    c.pushes += 1
    await c.drain()
    await c.set(i_hold_wa=1)
    for way in range(6):
        if int(dut.hart.wb_live.value) == 3:
            break
        c.preload(0x80E20040 + way * 0x200, 0xA600 + way)
        await c.store(0x80E20060 + way * 0x200, 0x3000 + way)
        c.pushes += 1
        for _ in range(120):
            if int(dut.hart.store_count.value) == 0:
                break
            await c.tick()
        assert int(dut.hart.store_count.value) == 0
    assert int(dut.hart.wb_live.value) == 3

    assert c.get("o_store_ready") == 1
    await c.set(
        i_address=head_block,
        i_write_data=0,
        i_write_mask=0xFF,
        i_write_zero=1,
        i_write_tag=5,
    )
    c.pushes += 1
    await c.tick()
    await c.set(i_write_mask=0, i_write_zero=0)

    for _ in range(80):
        if (
            int(dut.hart.store_count.value) == 1
            and int(dut.hart.store_twin_pending.value) == 0
        ):
            break
        await c.tick()
    head_idx = int(dut.hart.store_head_index.value)
    assert int(dut.hart.store_count.value) == 1
    assert (int(dut.hart.store_twin.value) >> head_idx) & 1 == 1

    for way in range(1, 8):
        evict_addr = head_block + way * 0x4000
        c.preload(evict_addr, 0xA700 + way)
        agent_q = pack((2, 3), (2, 3), (4, 1), (1, 0))
        agent_req = pack(
            (4, 9),
            (9, agent_q),
            (c.p, evict_addr),
            (5, 0),
            (3, 5),
            (32, 0),
            (1, 0),
            (1, 0),
            (1, 0),
            (256, 0),
        )
        await c.set(i_agent_valid=1, i_agent_d=agent_req)
        await c.wait("o_agent_ready")
        await c.tick()
        await c.set(i_agent_valid=0)
        await c.wait("o_agent_g_valid")
        ag = unpack(c.get("o_agent_g"), (3, 9, 6, c.p, 256, 1))
        await c.tick()
        await c.set(
            i_agent_c_valid=1,
            i_agent_c=pack((9, ag[1]), (6, ag[2]), (c.p, evict_addr), (2, 0), (1, 0)),
        )
        await c.wait("o_agent_c_ready")
        await c.tick()
        await c.set(i_agent_c_valid=0)
        await c.wait("o_agent_u_valid")
        await c.set(i_agent_u_ready=1)
        await c.tick()
        await c.set(i_agent_u_ready=0)

    reads_before = c.reads_of(head_block)
    c.read_delay = 600
    await c.set(i_hold_wa=0)
    for _ in range(120):
        if (int(dut.hart.live.value) & 1) and c.reads_of(head_block) > reads_before:
            break
        await c.tick()
    c.read_delay = 7
    assert c.reads_of(head_block) == reads_before + 1
    assert int(dut.hart.store_count.value) == 1
    assert (int(dut.hart.store_twin.value) >> head_idx) & 1 == 1

    # Give L1D set 3 a clean way for page + 0x60, then launch a 220-cycle L2
    # prefetch fill on block so LookaheadOp's GetMZero(block) parks behind that
    # fill while the stream trains on L2-resident page + 0x20, +0x40, +0x60.
    c.preload(0x80E40040, 0xA500)
    await c.read(0x80E40060)

    for addr, val in ((s1_addr, 0x1111), (s2_addr, 0x2222)):
        assert c.get("o_store_ready") == 1
        await c.set(
            i_address=addr,
            i_write_data=val,
            i_write_mask=0xFF,
            i_write_zero=0,
            i_write_tag=7,
        )
        c.pushes += 1
        await c.tick()
        await c.set(i_write_mask=0)

    grants_before = len(c.agent_grants)
    c.read_delay = 220
    pf_q = pack((2, 3), (2, 3), (4, 1), (1, 0))
    pf_req = pack(
        (4, 9),
        (9, pf_q),
        (c.p, block),
        (5, 0),
        (3, 5),
        (32, 0),
        (1, 0),
        (1, 0),
        (1, 0),
        (256, 0),
    )
    await c.set(i_agent_valid=1, i_agent_d=pf_req)
    await c.wait("o_agent_ready")
    await c.tick()
    await c.set(i_agent_valid=0)
    for _ in range(200):
        if c.reads_of(block) > 0:
            break
        await c.tick()
    assert c.reads_of(block) == 1
    c.read_delay = 7

    assert c.get("o_store_ready") == 1
    req_before = len(c.requests)
    await c.set(
        i_address=block,
        i_write_data=0,
        i_write_mask=0xFF,
        i_write_zero=1,
        i_write_tag=5,
    )
    c.pushes += 1
    await c.tick()
    await c.set(i_write_mask=0, i_write_zero=0)

    assert int(dut.hart.store_count.value) == 4
    assert int(dut.hart.store_twin_pending.value) == 1
    assert int(dut.hart.store_twin_addr.value) == block + 32
    for _ in range(80):
        assert not any(
            addr in (block, block + 32) for _, _, _, addr, _ in c.requests[req_before:]
        ), "younger cbo.zero acquired while its own twin still waited"
        await c.tick()
    assert int(dut.hart.store_twin_pending.value) == 1

    # Train and confirm an ascending stream on page + 0x20, +0x40, +0x60 while
    # store_twin_pending still holds the upper sector of block.
    for addr in (page + 0x20, page + 0x40, page + 0x60):
        await c.read(addr)
    for _ in range(60):
        if len(c.agent_grants) > grants_before or block + 32 in c.speculative_requests:
            break
        await c.tick()
    assert int(dut.hart.store_twin_pending.value) == 1
    assert not any(
        addr in (block, block + 32) for _, _, _, addr, _ in c.requests[req_before:]
    )

    # Complete the source-3 L2 prefetch of block, then drain all four records
    # once endpoint 0's head twin completes.
    for _ in range(1200):
        if len(c.agent_grants) > grants_before:
            break
        await c.tick()
    assert len(c.agent_grants) > grants_before
    pf_g = c.agent_grants[-1]
    await c.set(
        i_agent_c_valid=1,
        i_agent_c=pack((9, pf_g[1]), (6, pf_g[2]), (c.p, block), (2, 0), (1, 0)),
    )
    await c.wait("o_agent_c_ready")
    await c.tick()
    await c.set(i_agent_c_valid=0)
    await c.wait("o_agent_u_valid")
    await c.set(i_agent_u_ready=1)
    await c.tick()
    await c.set(i_agent_u_ready=0)

    for _ in range(700):
        if (
            int(dut.hart.store_count.value) == 0
            and int(dut.hart.store_twin_pending.value) == 0
        ):
            break
        await c.tick()

    await c.drain()
    await c.check_block(block)
    assert block + 32 not in c.speculative_requests


@cocotb.test()
async def dropped_load_retry_during_pending_twin(dut: Any) -> None:
    """Keep a dropped wrong-path load retry from overwriting a cbo.zero twin.

    A load to block + 32 launched on a mispredicted branch path while all load
    endpoints are busy records rd_miss_q in the L1D without owning an endpoint,
    and remains in rd_valid_q after the load queue marks its slot cs_drop. When
    the architectural path fills the store buffer behind an older head twin and
    pushes cbo.zero(block), store_count == 4 and store_twin_pending == 1 before
    the dropped load retries its lookup. LookaheadOp must hold off GetMZero
    until the block's own twin allocates, so the retry's GetS(block + 32)
    completes ahead of cbo.zero(block) rather than overwriting Modified zeros.
    """
    c = FullCluster(dut)
    await c.reset()
    block = 0x80960080
    head_block = 0x80F01040
    s1_addr = head_block + 0x4000
    s2_addr = head_block + 0x8000
    c.preload(block, 0xA180)
    c.preload(head_block, 0xA200)
    c.preload(s1_addr, 0xA300)
    c.preload(s2_addr, 0xA400)

    # Warm block Clean in the 64 KiB L2 with nonzero data, then evict it from
    # the 1 KiB L1D using lines in disjoint L2 sets.
    await c.read(block)
    old_upper = await c.read(block + 32)
    assert old_upper != 0
    for way in range(4):
        for s in range(8):
            await c.read(0x80E00200 + way * 0x400 + s * 32)
    await c.drain()

    # Park an older cbo.zero's upper twin at store_head_index on endpoint 0
    # waiting on a 600-cycle DDR read.
    await c.store(head_block, 0xCAFE)
    c.pushes += 1
    await c.drain()
    await c.set(i_hold_wa=1)
    for way in range(6):
        if int(dut.hart.wb_live.value) == 3:
            break
        c.preload(0x80E20240 + way * 0x400, 0xA600 + way)
        await c.store(0x80E20260 + way * 0x400, 0x3000 + way)
        c.pushes += 1
        for _ in range(120):
            if int(dut.hart.store_count.value) == 0:
                break
            await c.tick()
        assert int(dut.hart.store_count.value) == 0
    assert int(dut.hart.wb_live.value) == 3

    assert c.get("o_store_ready") == 1
    await c.set(
        i_address=head_block,
        i_write_data=0,
        i_write_mask=0xFF,
        i_write_zero=1,
        i_write_tag=5,
    )
    c.pushes += 1
    await c.tick()
    await c.set(i_write_mask=0, i_write_zero=0)

    for _ in range(80):
        if (
            int(dut.hart.store_count.value) == 1
            and int(dut.hart.store_twin_pending.value) == 0
        ):
            break
        await c.tick()
    head_idx = int(dut.hart.store_head_index.value)
    assert int(dut.hart.store_count.value) == 1
    assert (int(dut.hart.store_twin.value) >> head_idx) & 1 == 1

    for way in range(1, 8):
        evict_addr = head_block + way * 0x4000
        c.preload(evict_addr, 0xA700 + way)
        agent_q = pack((2, 3), (2, 3), (4, 1), (1, 0))
        agent_req = pack(
            (4, 9),
            (9, agent_q),
            (c.p, evict_addr),
            (5, 0),
            (3, 5),
            (32, 0),
            (1, 0),
            (1, 0),
            (1, 0),
            (256, 0),
        )
        await c.set(i_agent_valid=1, i_agent_d=agent_req)
        await c.wait("o_agent_ready")
        await c.tick()
        await c.set(i_agent_valid=0)
        await c.wait("o_agent_g_valid")
        ag = unpack(c.get("o_agent_g"), (3, 9, 6, c.p, 256, 1))
        await c.tick()
        await c.set(
            i_agent_c_valid=1,
            i_agent_c=pack((9, ag[1]), (6, ag[2]), (c.p, evict_addr), (2, 0), (1, 0)),
        )
        await c.wait("o_agent_c_ready")
        await c.tick()
        await c.set(i_agent_c_valid=0)
        await c.wait("o_agent_u_valid")
        await c.set(i_agent_u_ready=1)
        await c.tick()
        await c.set(i_agent_u_ready=0)

    reads_before = c.reads_of(head_block)
    c.read_delay = 600
    await c.set(i_hold_wa=0)
    for _ in range(120):
        if (
            (int(dut.hart.live.value) & 1)
            and c.reads_of(head_block) > reads_before
            and int(dut.hart.wb_live.value) == 0
        ):
            break
        await c.tick()
    c.read_delay = 7
    assert c.reads_of(head_block) == reads_before + 1
    assert int(dut.hart.wb_live.value) == 0
    assert int(dut.hart.store_count.value) == 1
    assert (int(dut.hart.store_twin.value) >> head_idx) & 1 == 1

    # Restore clean ways in L1D set 3 after the writeback setup.
    for way in range(4):
        await c.read(0x80E00200 + way * 0x400 + 3 * 32)

    # Occupy all seven load endpoints (ep 1..7): five 600-cycle DDR misses and
    # two 120-cycle DDR misses, with i_read_ready draining flushed responses.
    await c.set(i_read_ready=1)
    for slot in range(7):
        c.read_delay = 600 if slot < 5 else 120
        miss_addr = 0x80B00200 + slot * 0x400 + slot * 32
        c.preload(miss_addr & -64, 0xB100 + slot)
        await c.set(
            i_address=miss_addr,
            i_read_id=slot,
            i_read_kind=0,
            i_read_size=3,
            i_read_valid=1,
        )
        await c.tick()
        await c.set(i_read_valid=0)
        await c.tick(5)
    c.read_delay = 7
    for _ in range(40):
        if int(dut.hart.live.value) == 0xFF and int(dut.hart.load_ep_free.value) == 0:
            break
        await c.tick()
    assert int(dut.hart.live.value) == 0xFF
    assert int(dut.hart.load_ep_free.value) == 0

    # Launch the wrong-path load to block + 32 on slot 7: it misses L1D with no
    # free load endpoint, recording rd_miss_q[7] = 1 with rd_owned[7] = 0.
    await c.set(
        i_address=block + 32,
        i_read_id=7,
        i_read_kind=0,
        i_read_size=3,
        i_read_valid=1,
    )
    await c.tick()
    await c.set(i_read_valid=0)
    for _ in range(25):
        if (int(dut.hart.rd_miss_q.value) >> 7) & 1:
            break
        await c.tick()
    assert (int(dut.hart.rd_valid_q.value) >> 7) & 1 == 1
    assert (int(dut.hart.rd_miss_q.value) >> 7) & 1 == 1
    assert (int(dut.hart.rd_owned.value) >> 7) & 1 == 0

    # After the branch flushes slot 7 into cs_drop in the load queue, the
    # architectural path commits two same-home-set stores and cbo.zero(block),
    # filling store_count == 4 with store_twin_pending == 1.
    req_before = len(c.requests)
    for addr, val in ((s1_addr, 0x1111), (s2_addr, 0x2222)):
        assert c.get("o_store_ready") == 1
        await c.set(
            i_address=addr,
            i_write_data=val,
            i_write_mask=0xFF,
            i_write_zero=0,
            i_write_tag=7,
        )
        c.pushes += 1
        await c.tick()
        await c.set(i_write_mask=0)
    assert c.get("o_store_ready") == 1
    await c.set(
        i_address=block,
        i_write_data=0,
        i_write_mask=0xFF,
        i_write_zero=1,
        i_write_tag=5,
    )
    c.pushes += 1
    await c.tick()
    await c.set(i_write_mask=0, i_write_zero=0)
    assert int(dut.hart.store_count.value) == 4
    assert int(dut.hart.store_twin_pending.value) == 1
    assert int(dut.hart.store_twin_addr.value) == block + 32

    saw_gets_while_pending = False
    seen_idx = req_before
    for _ in range(1000):
        while seen_idx < len(c.requests):
            _, _, op, addr, _ = c.requests[seen_idx]
            seen_idx += 1
            pending_now = int(dut.hart.store_twin_pending.value)
            assert not (op in (1, 10) and addr == block and pending_now), (
                "cbo.zero acquired before its own twin allocated"
            )
            if op == 0 and addr == block + 32 and pending_now:
                saw_gets_while_pending = True
        if (
            int(dut.hart.store_count.value) == 0
            and int(dut.hart.store_twin_pending.value) == 0
            and int(dut.hart.rd_valid_q.value) == 0
            and int(dut.hart.live.value) == 0
        ):
            break
        await c.tick()
    assert saw_gets_while_pending, "dropped load never retried GetS during pending twin"
    await c.set(i_read_ready=0)
    await c.drain()
    await c.check_block(block)
