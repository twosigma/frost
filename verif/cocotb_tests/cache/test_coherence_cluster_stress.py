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

"""Check ordered store visibility through the L1D and coherence home."""

import os
import random
from contextlib import ExitStack
from dataclasses import dataclass, replace
from typing import Any, Never, TextIO

import cocotb
from cocotb.triggers import Timer

from cocotb_tests.cache.test_coherence_endpoints import pack
from cocotb_tests.cache.test_coherence_home import unpack

BASE = 0x80000000
SHARED_SECTORS = 8
STALL_CYCLES = 6000
GRANT_OP = 2
AMO_SLOT = 7
TRACE_FIELDS = (
    "phase_q",
    "operation_q",
    "read_owed_q",
    "rd_candidate",
    "store_read_turn_q",
    "read_waiting_q",
    "grant_valid",
    "grant_pick",
    "store_pop",
    "store_head_ready",
    "look_ready",
    "look_priority_q",
    "store_count",
    "store_valid",
    "store_acquired",
    "live",
    "ep_store",
    "selected_grant_store",
    "grant_ep_q",
    "store_continue",
    "rd_pick",
    "load_grant_eligible",
    "wb_live",
    "wb_free",
    "read_fill",
    "active",
    "waiting_store_selections_q",
)


@dataclass(frozen=True)
class Traffic:
    """Select the store count, address range and optional traffic."""

    stores: int = 1200
    cpu_sectors: int = 64
    non_alloc: bool = False
    amo_probability: float = 0.0


@dataclass
class StoreAddress:
    """Track the current and previous locations in the scalar store pattern."""

    sector: int = BASE
    dword: int = 0
    previous: tuple[int, int] | None = None


@dataclass(frozen=True)
class CpuRead:
    """Capture a load's address, program-order store prefix and issue cycle."""

    address: int
    prefix: int
    issued: int


@dataclass
class Amo:
    """Track a CPU atomic operation from queue drain through release."""

    address: int
    tag: int
    start: int
    phase: str = "drain"


@dataclass
class DmaRequest:
    """Carry a DMA operation and its progress through the coherence channels."""

    sector: int
    mask: int = 0
    data: int = 0
    final: bool = False
    non_alloc: int = 0
    phase: int = 0
    wait: int = 0
    issue: int = 0
    tid: int = 0


@dataclass
class DmaWrite:
    """Hold an accepted DMA write's merged sector image and grant cycle."""

    data: int
    granted: int | None = None


@dataclass(frozen=True)
class StressProfile:
    """Define the seeded workload and required coverage counts."""

    seed: int
    traffic: Traffic
    coverage_floors: dict[str, int]


# Seed 1 exercises read-turn scheduling. Direct-mapped seed 11 and wide
# seed 41 exercise simultaneous write-backs under replacement pressure.
PROFILES = {
    "three_endpoints": StressProfile(
        seed=1,
        traffic=Traffic(),
        coverage_floors={
            "dma_stream_reads": 31,
            "dma_same_sector_windows": 6,
            "dma_write_grant_release_reads": 1,
            "combined": 287,
            "held_younger_grant_cycles": 1923,
            "borrowed_installs": 32,
        },
    ),
    "direct_mapped": StressProfile(
        seed=11,
        traffic=Traffic(stores=1500),
        coverage_floors={
            "dma_stream_reads": 48,
            "dma_same_sector_windows": 7,
            "dma_write_grant_release_reads": 1,
            "combined": 336,
            "held_younger_grant_cycles": 1669,
            "borrowed_installs": 58,
            "both_wb_live": 248,
        },
    ),
    "wide": StressProfile(
        seed=41,
        traffic=Traffic(
            stores=1500, cpu_sectors=192, non_alloc=True, amo_probability=0.004
        ),
        coverage_floors={
            "dma_stream_reads": 47,
            "dma_same_sector_windows": 6,
            "dma_write_grant_release_reads": 1,
            "combined": 321,
            "held_younger_grant_cycles": 951,
            "borrowed_installs": 41,
            "both_wb_live": 80,
            "amos": 16,
            "non_alloc_reads": 24,
        },
    ),
}


def sector_of(address: int) -> int:
    """Return the base of the 32-byte coherence sector."""
    return address & ~31


class ClusterStress:
    """Drive CPU, DMA and memory traffic and check every observer's data."""

    def __init__(
        self,
        dut: Any,
        seed: int,
        traffic: Traffic = Traffic(),
        trace: TextIO | None = None,
    ) -> None:
        """Initialize the reference images, event counts and channel drivers."""
        self.dut = dut
        self.rng = random.Random(seed)
        self.seed = seed
        self.traffic = traffic
        self.shared_base = BASE + 32 * traffic.cpu_sectors
        self.p = len(dut.i_address)
        self.line = len(dut.i_mem_resp_data) // 8
        self.cycle = 0
        self.memory: dict[int, int] = {}
        self.responses: list[tuple[int, int, int, int, int]] = []
        self.cut_age = 0
        self.cut_admit_age = 0
        self.cut_admit_delay = 0
        # Scalar store stream in program order, with sector-relative byte offsets.
        self.stores: list[tuple[int, list[tuple[int, int]]]] = []
        self.installed = 0
        self.acks = 0
        self.atomic_store_pending = False
        self.last_install = 0
        self.coverage = {
            k: 0
            for k in (
                "two_store_endpoints",
                "combined",
                "borrowed_installs",
                "lookahead_acquires",
                "held_younger_grant_cycles",
                "probes",
                "full_queue_cycles",
                "both_wb_live",
                "peak_live_writebacks",
                "dma_reads",
                "dma_stream_reads",
                "dma_open_windows",
                "dma_same_sector_windows",
                "dma_write_grant_release_reads",
                "peak_dma_window",
                "cpu_reads",
                "amos",
                "non_alloc_reads",
            )
        }
        self.last_progress = 0
        # DMA owns the upper two doublewords of each shared sector.
        self.dma_writes: dict[int, list[DmaWrite]] = {}
        self.holds = {"i_hold_grant": 0, "i_hold_release": 0, "i_hold_wa": 0}
        self.hold_left = {name: 0 for name in self.holds}
        self.hold_cool = {name: 0 for name in self.holds}
        self.trace = trace

    def get(self, name: str) -> int:
        """Read a cluster port."""
        return int(getattr(self.dut, name).value)

    def hget(self, name: str) -> int:
        """Read an L1D signal."""
        return int(getattr(self.dut.hart, name).value)

    async def set(self, **values: int) -> None:
        """Drive inputs and settle combinational logic."""
        for name, value in values.items():
            getattr(self.dut, name).value = value
        await Timer(1, unit="ns")

    def fail(self, message: str) -> Never:
        """Report the workload seed and cycle with a failure."""
        raise AssertionError(f"seed {self.seed} cycle {self.cycle}: {message}")

    @property
    def pushed(self) -> int:
        """Return the number of scalar writes presented to the cache."""
        return len(self.stores)

    def record_store(self, address: int, data: int, mask: int) -> None:
        """Record the written bytes of one scalar store in program order."""
        writes = [
            ((address & 31) + byte, (data >> (8 * byte)) & 0xFF)
            for byte in range(8)
            if (mask >> byte) & 1
        ]
        self.stores.append((sector_of(address), writes))

    def is_shared(self, sector: int) -> bool:
        """Identify sectors with separate CPU and DMA byte ranges."""
        return self.shared_base <= sector < self.shared_base + 32 * SHARED_SECTORS

    async def reset(self) -> None:
        """Reset the cluster and let both tag arrays initialize."""
        for signal in self.dut:
            if signal._name.startswith("i_"):
                signal.value = 0
        await self.set(i_rst=1)
        for _ in range(2):
            await self.edge()
        await self.set(i_rst=0, i_mem_req_ready=1, i_atomic_protected=1, i_read_ready=1)
        for _ in range(40):
            await self.drive_environment()
            await self.edge()

    async def edge(self) -> None:
        """Account for this cycle's pops, then apply one rising edge."""
        if self.trace is not None:
            values = " ".join(f"{field}={self.hget(field)}" for field in TRACE_FIELDS)
            self.trace.write(f"{self.cycle} seed={self.seed} {values}\n")
        store_pop = self.hget("store_pop")
        if store_pop:
            head = self.hget("store_head_index")
            contributors = (self.hget("store_contributors") >> (6 * head)) & 63
            self.installed += contributors
            self.last_install = self.cycle
            self.last_progress = self.cycle
        if self.get("o_mem_req_valid") and self.get("i_mem_req_ready"):
            address = self.get("o_mem_req_addr")
            write = self.get("o_mem_req_write")
            if write:
                mask = self.get("o_mem_req_mask")
                data = self.get("o_mem_req_data")
                delay = self.rng.randint(4, 90)
            else:
                mask = 0
                data = self.memory.get(address, 0)
                delay = self.rng.randint(3, 70)
            self.responses.append(
                (self.cycle + delay, self.get("o_mem_req_id"), data, address, mask)
            )
        self.acks += self.get("o_write_done")
        cov = self.coverage
        live = self.hget("live")
        ep_store = self.hget("ep_store")
        if (live & ep_store).bit_count() == 2:
            cov["two_store_endpoints"] += 1
        cov["combined"] += self.hget("store_combined")
        if (
            store_pop
            and self.hget("operation_q") == GRANT_OP
            and self.hget("grant_ep_q")
        ):
            cov["borrowed_installs"] += 1
        if self.hget("store_acquire") and self.hget("acq_ep_q"):
            cov["lookahead_acquires"] += 1
        grants = (
            self.hget("ep_grant_valid") & ep_store & ~self.hget("store_grant_head_q")
        )
        if grants:
            cov["held_younger_grant_cycles"] += 1
        if self.hget("probe_capture"):
            cov["probes"] += 1
        if self.hget("store_count") == 4:
            cov["full_queue_cycles"] += 1
        in_reset = self.get("i_rst")
        if not in_reset:
            live_writebacks = self.hget("wb_live").bit_count()
            cov["peak_live_writebacks"] = max(
                cov["peak_live_writebacks"], live_writebacks
            )
            cov["both_wb_live"] += live_writebacks == 2
        await self.set(i_clk=1)
        await self.set(i_clk=0)
        self.cycle += 1
        if self.get("o_fatal"):
            self.fail(f"fatal at {self.get('o_fatal_addr'):#x}")
        if not in_reset:
            if self.hget("atomic_done_q"):
                assert self.atomic_store_pending
                self.installed += 1
                self.atomic_store_pending = False
                self.last_install = self.cycle
                self.last_progress = self.cycle
            valid = self.hget("store_valid")
            contributors = self.hget("store_contributors")
            total = sum(
                (contributors >> (6 * slot)) & 63
                for slot in range(4)
                if (valid >> slot) & 1
            )
            queued = self.pushed - self.installed - int(self.atomic_store_pending)
            if total != queued:
                self.fail(
                    f"record contributors {total} != queued scalars {queued} "
                    f"(pushed {self.pushed}, installed {self.installed}, "
                    f"pending atomic {self.atomic_store_pending})"
                )

    def complete_memory_write(self, response: tuple[int, int, int, int, int]) -> None:
        """Apply a memory response's byte mask to backing storage."""
        _, _, data, address, mask = response
        value = self.memory.get(address, 0)
        for byte in range(self.line):
            if (mask >> byte) & 1:
                bits = 0xFF << (8 * byte)
                value = (value & ~bits) | (data & bits)
        self.memory[address] = value

    async def drive_environment(self) -> None:
        """Memory responses, cut handshakes and random hold windows for this cycle."""
        ready = [r for r in self.responses if r[0] <= self.cycle]
        response = self.rng.choice(ready) if ready else None
        if response:
            self.responses.remove(response)
            if response[1] & 16:
                self.complete_memory_write(response)
        self.cut_age = self.cut_age + 1 if self.get("o_cut_inval_valid") else 0
        if self.get("o_cut_admit_valid"):
            self.cut_admit_age += 1
        else:
            self.cut_admit_age = 0
            self.cut_admit_delay = self.rng.randint(0, 3)
        for name in self.holds:
            if self.hold_left[name]:
                self.hold_left[name] -= 1
                if not self.hold_left[name]:
                    self.holds[name] = 0
                    self.hold_cool[name] = self.rng.randint(20, 200)
            elif self.hold_cool[name]:
                self.hold_cool[name] -= 1
            elif self.rng.random() < 0.01:
                self.holds[name] = 1
                self.hold_left[name] = self.rng.randint(1, 120)
        await self.set(
            i_mem_resp_valid=int(response is not None),
            i_mem_resp_id=response[1] if response else 0,
            i_mem_resp_data=response[2] if response else 0,
            i_cut_admit_ready=int(self.cut_admit_age >= self.cut_admit_delay),
            i_cut_inval_done=int(self.cut_age >= 3),
            **self.holds,
        )

    def cpu_image(self, sector: int, prefix: int) -> dict[int, int]:
        """Apply the specified prefix of the store stream to one sector."""
        image: dict[int, int] = {}
        for index in range(prefix):
            s, writes = self.stores[index]
            if s == sector:
                for byte, value in writes:
                    image[byte] = value
        return image

    def dword_value(self, sector: int, dword: int, prefix: int) -> int:
        """Read a CPU doubleword from a reference store prefix."""
        image = self.cpu_image(sector, prefix)
        value = 0
        for byte in range(8):
            value |= image.get(8 * dword + byte, 0) << (8 * byte)
        return value

    def make_store(self, seq: int, state: StoreAddress) -> tuple[int, int, int]:
        """Choose (address, data, mask) for the next scalar store."""
        r = self.rng.random()
        sector, dword = state.sector, state.dword
        if r < 0.40:
            dword += 1
            if dword > (1 if self.is_shared(sector) else 3):
                dword = 0
                if self.is_shared(sector):
                    sector = self.shared_base + 32 * self.rng.randrange(SHARED_SECTORS)
                else:
                    sector = BASE + 32 * (
                        (((sector - BASE) >> 5) + 1) % self.traffic.cpu_sectors
                    )
        elif r < 0.55:
            pass
        elif r < 0.70:
            if self.rng.random() < 0.2:
                sector = self.shared_base + 32 * self.rng.randrange(SHARED_SECTORS)
            else:
                sector = BASE + 32 * self.rng.randrange(self.traffic.cpu_sectors)
            dword = self.rng.randrange(2 if self.is_shared(sector) else 4)
        elif r < 0.80 and state.previous is not None:
            sector, dword = state.previous
        else:
            dword = self.rng.randrange(2 if self.is_shared(sector) else 4)
        if (sector, dword) != (state.sector, state.dword):
            state.previous = (state.sector, state.dword)
        state.sector, state.dword = sector, dword
        mask = 0xFF if self.rng.random() < 0.8 else self.rng.randint(1, 255)
        data = 0
        for byte in range(8):
            data |= (((seq * 131 + byte * 17) % 251) + 1) << (8 * byte)
        return sector + 8 * dword, data, mask

    async def run(self) -> None:
        """Drive the seeded workload, drain the cluster and read back all sectors."""
        await self.reset()
        state = StoreAddress()
        credit = False
        next_store = None
        reads: dict[int, CpuRead] = {}
        dma = None
        finished_stores = False
        drain_cycles = 0
        amo = None
        last_push = -10
        while True:
            await self.drive_environment()
            # Present this cycle's CPU operation: a credited store or a read.
            store_now = None
            read_now = None
            amo_now = None
            if (
                amo is None
                and self.traffic.amo_probability
                and self.pushed < self.traffic.stores
                and self.rng.random() < self.traffic.amo_probability
            ):
                sector = BASE + 32 * self.rng.randrange(self.traffic.cpu_sectors)
                amo = Amo(
                    sector + 8 * self.rng.randrange(4),
                    self.rng.randrange(128),
                    self.cycle,
                )
            if amo is not None:
                if (
                    amo.phase == "drain"
                    and not reads
                    and not self.get("o_pending_store")
                    and self.cycle - last_push > 1
                ):
                    amo_now = "read"
                    amo.phase = "read"
                elif amo.phase == "granted":
                    amo_now = "write"
                    amo.phase = "done_wait"
                elif amo.phase == "done_wait" and not self.hget("atomic_q"):
                    amo = None
                    self.coverage["amos"] += 1
                if amo is not None and self.cycle - amo.start > STALL_CYCLES:
                    self.fail(f"AMO stalled: {amo}")
            if next_store is None and self.pushed < self.traffic.stores:
                next_store = self.make_store(self.pushed, state)
            if amo is None and credit and next_store is not None:
                address, data, mask = next_store
                if not any(read.address == address for read in reads.values()):
                    store_now = next_store
            if (
                amo is None
                and store_now is None
                and self.pushed < self.traffic.stores
                and len(reads) < 3
                and self.rng.random() < 0.06
            ):
                slot = next(s for s in range(8) if s not in reads)
                if self.rng.random() < 0.15:
                    sector = self.shared_base + 32 * self.rng.randrange(SHARED_SECTORS)
                    dword = self.rng.randrange(4)
                elif self.stores and self.rng.random() < 0.7:
                    sector = self.stores[self.rng.randrange(len(self.stores))][0]
                    dword = self.rng.randrange(2 if self.is_shared(sector) else 4)
                else:
                    sector = BASE + 32 * self.rng.randrange(self.traffic.cpu_sectors)
                    dword = self.rng.randrange(4)
                if not (
                    next_store is not None
                    and credit
                    and (next_store[0] & ~7) == sector + 8 * dword
                ):
                    read_now = (slot, sector + 8 * dword)
            if amo is not None and amo_now == "read":
                await self.set(
                    i_address=amo.address,
                    i_write_mask=0,
                    i_read_valid=1,
                    i_read_id=AMO_SLOT,
                    i_read_kind=2,
                    i_read_size=3,
                    i_read_tag=amo.tag,
                )
            elif amo is not None and amo_now == "write":
                data = 0
                for byte in range(8):
                    data |= (((self.pushed * 131 + byte * 17) % 251) + 1) << (8 * byte)
                await self.set(
                    i_address=amo.address,
                    i_write_data=data,
                    i_write_mask=0xFF,
                    i_write_atomic=1,
                    i_write_sc=0,
                    i_write_tag=amo.tag,
                    i_read_valid=0,
                )
                self.record_store(amo.address, data, 0xFF)
                self.atomic_store_pending = True
                if self.pushed == self.traffic.stores:
                    next_store = None
            elif store_now is not None:
                last_push = self.cycle
                address, data, mask = store_now
                await self.set(
                    i_address=address,
                    i_write_data=data,
                    i_write_mask=mask,
                    i_write_atomic=0,
                    i_write_sc=0,
                    i_write_tag=self.pushed % 128,
                    i_read_valid=0,
                )
                self.record_store(address, data, mask)
                next_store = None
            elif read_now is not None:
                slot, address = read_now
                await self.set(
                    i_address=address,
                    i_write_mask=0,
                    i_read_valid=1,
                    i_read_id=slot,
                    i_read_kind=0,
                    i_read_size=3,
                    i_read_tag=0,
                )
                reads[slot] = CpuRead(address, self.pushed, self.cycle)
            else:
                await self.set(i_write_mask=0, i_read_valid=0, i_write_atomic=0)
            # A credit observed with this cycle's arriving write enables the next one.
            credit = bool(self.get("o_store_ready"))
            # Read responses.
            read_response = None
            if self.get("o_read_valid") and self.get("i_read_ready"):
                slot = self.get("o_read_id")
                value = self.get("o_read_data")
                error = self.get("o_read_error")
                if amo is not None and amo.phase == "read" and slot == AMO_SLOT:
                    sector, dword = sector_of(amo.address), (amo.address >> 3) & 3
                    expected = self.dword_value(sector, dword, self.pushed)
                    if value != expected or error:
                        self.fail(
                            f"AMO read {amo.address:#x} returned {value:#x}, "
                            f"expected {expected:#x}"
                        )
                    amo.phase = "granted"
                    self.last_progress = self.cycle
                elif slot not in reads:
                    self.fail(f"unexpected read response for slot {slot}")
                else:
                    read_response = (reads.pop(slot), value, error)
            # The single DMA agent.
            dma = await self.step_dma(dma, finished_stores)
            # Include DMA acceptances on the response cycle.
            if read_response is not None:
                self.check_read(*read_response)
            # Progress and termination.
            for slot, read in reads.items():
                if self.cycle - read.issued > STALL_CYCLES:
                    self.fail(f"CPU read {read.address:#x} in slot {slot} stalled")
            if (
                self.installed < self.traffic.stores
                and self.cycle - self.last_install > STALL_CYCLES
            ):
                self.fail(
                    f"store installation stalled at {self.installed} of {self.pushed}"
                )
            if self.cycle - self.last_progress > STALL_CYCLES:
                self.fail(
                    f"no progress: pushed {self.pushed} installed {self.installed} "
                    f"reads {sorted(reads)} dma {dma}"
                )
            if (
                self.pushed >= self.traffic.stores
                and not reads
                and next_store is None
                and amo is None
            ):
                finished_stores = True
            if finished_stores and dma is None and not self.get("o_pending_store"):
                drain_cycles += 1
                if drain_cycles > 50:
                    break
            await self.edge()
        await self.set(i_write_mask=0, i_read_valid=0)
        if self.installed != self.pushed:
            self.fail(f"installed {self.installed} != pushed {self.pushed}")
        if self.acks != self.pushed:
            self.fail(f"acknowledgements {self.acks} != pushed {self.pushed}")
        # Final check of every sector through the DMA port.
        for sector in range(BASE, self.shared_base + 32 * SHARED_SECTORS, 32):
            dma = DmaRequest(sector, final=True)
            while dma is not None:
                await self.drive_environment()
                dma = await self.step_dma(dma, True)
                await self.edge()
        await self.check_dma_write_during_release()
        self.dut._log.info(
            f"seed {self.seed}: {self.pushed} stores, {self.cycle} cycles, {self.coverage}"
        )

    async def check_dma_write_during_release(self) -> None:
        """Read a DMA-written word while holding its release after grant."""
        sector = self.shared_base
        address = sector + 16
        history = self.dma_writes.get(sector)
        previous = (history[-1].data >> 128) & 0xFF if history else 0
        dma: DmaRequest | None = DmaRequest(sector, 1 << 16, (previous ^ 0xFF) << 128)
        reads: dict[int, CpuRead] = {}
        issued = 0
        read_count = 3
        for _ in range(STALL_CYCLES):
            await self.drive_environment()
            granted = dma is not None and dma.phase in (2, 3)
            issue = granted and issued < read_count
            await self.set(
                i_hold_release=int(granted and (issue or bool(reads))),
                i_address=address,
                i_read_valid=int(issue),
                i_read_id=issued,
                i_read_kind=0,
                i_read_size=3,
                i_read_tag=0,
            )
            if issue:
                reads[issued] = CpuRead(address, self.pushed, self.cycle)
                issued += 1
            if self.get("o_read_valid") and self.get("i_read_ready"):
                slot = self.get("o_read_id")
                if slot not in reads:
                    self.fail(f"unexpected read response for slot {slot}")
                self.check_read(
                    reads.pop(slot), self.get("o_read_data"), self.get("o_read_error")
                )
            dma = await self.step_dma(dma, True)
            await self.edge()
            if dma is None and issued == read_count and not reads:
                return
        self.fail("hart reads stalled during DMA write release hold")

    async def step_dma(
        self, dma: DmaRequest | None, finished: bool
    ) -> DmaRequest | None:
        """Advance the single DMA agent by one cycle."""
        q = pack((2, 2), (2, 3), (4, 13), (1, 0))
        if dma is None:
            await self.set(
                i_agent_valid=0, i_agent_g_ready=0, i_agent_c_valid=0, i_agent_u_ready=0
            )
            if finished or self.rng.random() > 0.03:
                return None
            if self.rng.random() < 0.6:
                if self.rng.random() < 0.3:
                    sector = BASE + 0x10000 + 32 * self.rng.randrange(256)
                elif self.stores and self.rng.random() < 0.7:
                    sector = self.stores[
                        -1 - self.rng.randrange(min(8, len(self.stores)))
                    ][0]
                else:
                    sector = BASE + 32 * self.rng.randrange(self.traffic.cpu_sectors)
                dma = DmaRequest(sector)
            else:
                sector = self.shared_base + 32 * self.rng.randrange(SHARED_SECTORS)
                mask = 0
                while not mask:
                    mask = self.rng.getrandbits(16) << 16
                data = self.rng.getrandbits(256)
                dma = DmaRequest(sector, mask, data)
            dma.non_alloc = int(self.traffic.non_alloc and self.rng.random() < 0.6)
        dma.wait += 1
        if dma.wait > STALL_CYCLES:
            self.fail(f"DMA stalled: {dma}")
        sector = dma.sector
        write = dma.mask != 0
        if dma.phase == 0:
            request = pack(
                (4, 8 if write else 7),
                (9, q),
                (self.p, sector),
                (5, 0),
                (3, 5),
                (32, dma.mask),
                (1, 0),
                (1, dma.non_alloc),
                (1, 0),
                (256, dma.data),
            )
            await self.set(i_agent_valid=1, i_agent_d=request)
            if self.get("o_agent_ready"):
                dma.phase = 1
                if write:
                    history = self.dma_writes.setdefault(sector, [])
                    previous = history[-1].data if history else 0
                    mask = sum(
                        0xFF << (8 * byte)
                        for byte in range(32)
                        if (dma.mask >> byte) & 1
                    )
                    history.append(DmaWrite((previous & ~mask) | (dma.data & mask)))
                else:
                    dma.issue = self.installed
        elif dma.phase == 1:
            await self.set(i_agent_valid=0)
            if self.get("o_agent_g_valid"):
                grant = unpack(self.get("o_agent_g"), (3, 9, 6, self.p, 256, 1))
                if grant[1] != q or grant[5]:
                    self.fail(f"bad DMA grant {grant}")
                await self.set(i_agent_g_ready=1)
                dma.tid = grant[2]
                dma.phase = 2
                if write:
                    self.dma_writes[sector][-1].granted = self.cycle
                else:
                    self.check_dma_read(dma, grant[4])
        elif dma.phase == 2:
            await self.set(
                i_agent_g_ready=0,
                i_agent_c_valid=1,
                i_agent_c=pack((9, q), (6, dma.tid), (self.p, sector), (2, 0), (1, 0)),
            )
            if self.get("o_agent_c_ready"):
                dma.phase = 3
        elif dma.phase == 3:
            await self.set(i_agent_c_valid=0)
            if self.get("o_agent_u_valid"):
                await self.set(i_agent_u_ready=1)
                dma.phase = 4
        else:
            await self.set(i_agent_u_ready=0)
            self.last_progress = self.cycle
            return None
        # Phases 2 and 3 keep the write live before release. Exclude the
        # cycle of the grant itself so the load must see the write.
        if (
            write
            and dma.phase in (2, 3)
            and self.dma_writes[sector][-1].granted != self.cycle
            and self.get("i_read_valid")
            and sector_of(self.get("i_address")) == sector
        ):
            self.coverage["dma_write_grant_release_reads"] += 1
        return dma

    def check_read(self, read: CpuRead, value: int, error: int) -> None:
        """Check the CPU value against its CPU or DMA write prefixes."""
        address = read.address
        sector, dword = sector_of(address), (address >> 3) & 3
        self.coverage["cpu_reads"] += 1
        if error:
            self.fail(f"read error at {address:#x}")
        if self.is_shared(sector) and dword >= 2:
            # The array update is between acceptance and grant. Start with
            # writes accepted through the response and stop at the latest
            # write granted before issue.
            acceptable = set()
            for write in reversed(self.dma_writes.get(sector, [])):
                acceptable.add((write.data >> (64 * dword)) & ((1 << 64) - 1))
                if write.granted is not None and write.granted < read.issued:
                    break
            else:
                acceptable.add(0)
            if value not in acceptable:
                self.fail(
                    f"read {address:#x} returned {value:#x}, "
                    f"DMA values {[hex(v) for v in sorted(acceptable)]} "
                    f"for issue at {read.issued}"
                )
        else:
            expected = self.dword_value(sector, dword, read.prefix)
            if value != expected:
                self.fail(
                    f"read {address:#x} returned {value:#x}, expected "
                    f"{expected:#x} after {read.prefix} stores"
                )
        self.last_progress = self.cycle

    def check_dma_read(self, dma: DmaRequest, data: int) -> None:
        """Check that the entire observed sector matches an installed prefix."""
        self.coverage["dma_reads"] += 1
        self.coverage["non_alloc_reads"] += dma.non_alloc
        sector = dma.sector
        cpu_bytes = 16 if self.is_shared(sector) else 32
        observed = {b: (data >> (8 * b)) & 0xFF for b in range(cpu_bytes)}
        low, high = (
            (self.pushed, self.pushed) if dma.final else (dma.issue, self.installed)
        )
        if not dma.final:
            cov = self.coverage
            cov["dma_stream_reads"] += 1
            cov["dma_open_windows"] += low < high
            cov["peak_dma_window"] = max(cov["peak_dma_window"], high - low)
            # Coverage scans the full acceptance-to-grant window independently
            # of which installed prefix matches the returned data.
            cov["dma_same_sector_windows"] += any(
                store_sector == sector for store_sector, _ in self.stores[low:high]
            )
        image = self.cpu_image(sector, low)
        matched = None
        for prefix in range(low, high + 1):
            if prefix > low:
                s, writes = self.stores[prefix - 1]
                if s == sector:
                    for byte, value in writes:
                        image[byte] = value
            if all(image.get(b, 0) == observed[b] for b in range(cpu_bytes)):
                matched = prefix
                break
        if matched is None:
            expected = self.cpu_image(sector, high)
            self.fail(
                f"DMA read {sector:#x} saw {data:#066x}; no installed prefix in "
                f"[{low}, {high}] matches; image at {high}: "
                f"{[hex(expected.get(b, 0)) for b in range(cpu_bytes)]}"
            )
        if self.is_shared(sector):
            # The single DMA agent has received every previous write grant.
            history = self.dma_writes.get(sector)
            merged = history[-1].data if history else 0
            for dword in (2, 3):
                value = (data >> (64 * dword)) & ((1 << 64) - 1)
                expected_word = (merged >> (64 * dword)) & ((1 << 64) - 1)
                if value != expected_word:
                    self.fail(
                        f"DMA read {sector:#x} dword {dword} saw {value:#x}, "
                        f"expected {expected_word:#x}"
                    )


@cocotb.test()
async def randomized_ordered_visibility(dut: Any) -> None:
    """Randomize stores, loads, DMA and channel delays through the home."""
    profile_name = os.getenv("FROST_CLUSTER_STRESS_PROFILE", "three_endpoints")
    profile = PROFILES[profile_name]
    seed_list = os.getenv("FROST_CLUSTER_STRESS_SEEDS")
    seeds = (
        tuple(int(seed) for seed in seed_list.split(","))
        if seed_list
        else (profile.seed,)
    )
    stores = int(os.getenv("FROST_CLUSTER_STRESS_STORES", str(profile.traffic.stores)))
    assert stores > 0, "FROST_CLUSTER_STRESS_STORES must be positive"
    traffic = replace(profile.traffic, stores=stores)
    path = os.getenv("FROST_CLUSTER_STRESS_TRACE")
    with ExitStack() as files:
        trace = files.enter_context(open(path, "w", buffering=1)) if path else None
        for seed in seeds:
            bench = ClusterStress(dut, seed, traffic, trace)
            await bench.run()
            missed = [
                f"{event}={bench.coverage[event]} < {minimum}"
                for event, minimum in profile.coverage_floors.items()
                if bench.coverage[event] < minimum
            ]
            if missed:
                bench.fail(
                    f"{profile_name} coverage below minimum: {', '.join(missed)}"
                )
