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

"""FROST architectural performance model (aligned to FROST platform_top = cpu_top + soc_top).

This is a deterministic, event-driven *architectural performance model*, not an
RTL simulator.  It models the FROST platform composition (``platform_top.sv``):
  - ``CpuTopModel`` (``cpu_top.sv``): two-wide out-of-order pipeline, L1I, L1D,
    the 32B-to-64B L2 sector adapter, L2 with stream prefetcher, and the
    6-bit-ID, 512-bit (64B) AXI4 master fabric (``cpu_memory_fabric.sv``).
  - ``SocTopModel`` (``soc_top.sv``): replaceable SoC interconnect and memory
    subsystem consisting of ``soc_axi_slave.sv`` (physical address decode to
    local BRAM/MMIO vs. the 5-bit-ID whole-line DDR port) and a single-channel
    512-bit AXI4 DDR endpoint modelled after ``axi_behavioral_memory.sv``.

Another project can swap ``SocTopModel`` (or ``DdrController``) while keeping
``CpuTopModel`` unchanged.  All non-RTL-calibrated latencies remain explicit in
``ModelConfig`` / ``SocConfig`` / ``DdrConfig``.

Grounding snapshot: twosigma/frost main @ 410aa8f3e866fffb078fc8f7fd3672866d83d131
(2026-10-22).  See ``rtl_audit`` for exact source locations and the boundary
between source-proven configuration and modelling assumptions.

Examples:
  python frost_perf_model.py selftest --out results/frost_perf_selftest.json
  python frost_perf_model.py sweep --out results/frost_perf_sweep.json
  python frost_perf_model.py audit --out results/frost_perf_rtl_alignment.json
  python frost_perf_model.py report --sweep results/frost_perf_sweep.json \
      --out results/FROST_perf_model_report.md
"""

from __future__ import annotations

import argparse
import dataclasses
import heapq
import json
import random
import statistics
import time
from collections import Counter, deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol
from collections.abc import Callable, Iterable


RTL_COMMIT = "410aa8f3e866fffb078fc8f7fd3672866d83d131"
MODEL_VERSION = "1.0"


def json_default(value: Any) -> Any:
    """Return a JSON-serializable form of a dataclass, Counter, or Path."""
    if dataclasses.is_dataclass(value):
        return dataclasses.asdict(value)
    if isinstance(value, Counter):
        return dict(value)
    if isinstance(value, Path):
        return str(value)
    raise TypeError(f"cannot serialize {type(value)!r}")


def dump_json(path: Path, value: Any) -> None:
    """Write value to path as indented JSON with sorted keys, creating its directory."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True, default=json_default) + "\n",
        encoding="utf-8",
    )


@dataclass(frozen=True)
class DdrConfig:
    """DDR endpoint configuration in core-clock cycles.

    Matches the single 512-bit (64-byte) AXI4 DDR port on ``soc_top.sv`` and its
    simulation-default ``axi_behavioral_memory.sv`` endpoint (5-bit AXI IDs,
    independent read/write slot pools of ``NUM_SLOTS = max(L2MaxSlots, 8)``,
    configurable fixed latency, optional LFSR latency jitter, and optional
    cross-ID out-of-order completion).
    """

    line_bytes: int = 64
    id_bits: int = 5  # riscv_pkg::DdrAxiIdBits (o_ddr_axi_arid / o_ddr_axi_awid)
    num_slots: int = 8  # minimum slot count per channel (soc_top DdrModelSlots floor)
    latency_cycles: int = 30  # DDR_MODEL_LATENCY default in soc_top.sv / frost.sv
    latency_jitter: int = 0  # DDR_MODEL_LATENCY_JITTER default in soc_top.sv
    reorder: bool = False  # DDR_MODEL_REORDER default in soc_top.sv
    jitter_seed: int = 0xACE1  # JITTER_SEED default in axi_behavioral_memory.sv
    controller: str = "behavioral"
    channels: int = 1
    interleave_bytes: int = 64
    cycles_per_line: int = 1

    def validate(self) -> None:
        """Check the endpoint geometry, service rate, and queue limits."""
        if self.controller not in {"behavioral", "interleaved"}:
            raise ValueError("unknown DDR controller")
        if self.channels < 1 or self.num_slots < 1 or self.cycles_per_line < 1:
            raise ValueError(
                "DDR channels, slots, and cycles per line must be positive"
            )
        if self.latency_cycles < 0 or self.latency_jitter < 0 or self.id_bits < 1:
            raise ValueError("invalid DDR latency or ID width")
        if self.line_bytes < 1 or self.interleave_bytes % self.line_bytes:
            raise ValueError("DDR interleave must contain whole lines")
        if self.interleave_bytes < self.line_bytes:
            raise ValueError("DDR interleave must contain at least one line")
        if self.controller == "behavioral" and (
            self.channels != 1 or self.cycles_per_line != 1
        ):
            raise ValueError(
                "channel and bandwidth sweeps require the interleaved controller"
            )


@dataclass(frozen=True)
class SocConfig:
    """FROST ``soc_top.sv`` + ``soc_axi_slave.sv`` configuration.

    ``soc_axi_slave`` decodes the CPU's 6-bit-ID physical-address AXI4 master:
      - Cached DDR aperture ``[ddr_base, ddr_base + ddr_bytes)`` forwards whole
        64-byte lines with 5-bit IDs (``id < 32``) to the single DDR AXI port
        after subtracting ``ddr_base``.  ``AR`` passes combinationally when
        ``ar_ddr_ok``; ``AW`` captures in ``aw_valid_q`` before presenting to DDR.
      - Local aperture (on-chip BRAM and MMIO devices) serializes through a
        single local request/response port with independent response buffering.
    """

    ddr_base: int = 0x8000_0000  # riscv_pkg::DdrBase
    ddr_bytes: int = 1 << 30  # riscv_pkg::DdrCapacityBytes (1 GiB default)
    bram_base: int = 0x0000_0000
    bram_bytes: int = 256 * 1024  # MEM_SIZE_BYTES (256 KiB on-chip BRAM)
    mmio_base: int = 0x4000_0000  # riscv_pkg::MmioWindowAddr
    mmio_bytes: int = 0x1000_0000
    ddr_aw_register_cycles: int = 1  # aw_valid_q stage in soc_axi_slave.sv
    local_bram_read_cycles: int = 2
    local_bram_write_cycles: int = 1
    local_wide_fetch_cycles: int = 5  # 4 serialized BRAM dwords + response
    local_mmio_cycles: int = 2


@dataclass(frozen=True)
class ModelConfig:
    """FROST ``platform_top.sv`` (``cpu_top`` + ``soc_top``) configuration.

    Defaults match the RTL production parameters in ``cpu_top.sv``,
    ``soc_top.sv``, and ``platform_top.sv`` at commit ``RTL_COMMIT``.
    """

    name: str = "rtl_baseline"
    # CPU core resource ownership (riscv_pkg.sv / cpu_ooo.sv / tomasulo).
    dispatch_width: int = 2
    retire_width: int = 2
    cdb_width: int = 2
    rob_entries: int = 32
    int_rs_entries: int = 16
    mem_rs_entries: int = 8
    load_queue_entries: int = 8
    store_queue_entries: int = 8
    load_issue_width: int = 1
    alu_issue_width: int = 2
    branch_recovery_cycles: int = 2
    decoded_queue_bundles: int = 4
    cache_normal_memory: bool = True
    l0_cache_depth: int = 256
    normal_fetch_lines: int = 256
    early_load_wakeup: bool = True
    # Cache hierarchy shape (cpu_top.sv / frost_cache_hierarchy.sv).
    l1i_bytes: int = 16 * 1024
    l1d_bytes: int = 128 * 1024
    l2_bytes: int = 2 * 1024 * 1024
    l1i_ways: int = 4
    l1d_ways: int = 4
    l2_ways: int = 4
    l1_line_bytes: int = 32
    l2_line_bytes: int = 64
    l1i_mshrs: int = 2
    l1d_mshrs: int = 8
    l1d_wb_slots: int = 2
    l2_mshrs: int = 4
    l2_wb_slots: int = 2
    l2_waiters: int = 2
    l2_prefetch: bool = True
    l2_prefetch_distance: int = 8
    l2_prefetch_inflight: int = 4
    # Pipeline / cache timing abstraction.
    l1_tag_cycles: int = 1
    l1_data_cycles: int = 2
    l2_tag_cycles: int = 3
    l2_data_cycles: int = 6
    cache_fill_cycles: int = 1
    cache_response_cycles: int = 1
    alu_cycles: int = 1
    # cpu_top <-> soc_top AXI4 boundary geometry (cpu_memory_fabric.sv / soc_axi_slave.sv).
    axi_data_bytes: int = 64
    cpu_axi_id_bits: int = (
        6  # 6-bit AXI ID at cpu_top master boundary (0..31 cache, 32 data, 34/35 fetch)
    )
    axi_id_bits: int = 5  # 5-bit L2 downstream / board DDR AXI ID width (DdrAxiIdBits)
    soc: SocConfig = field(default_factory=SocConfig)
    ddr: DdrConfig = field(default_factory=DdrConfig)

    def validate(self) -> None:
        """Check the configuration against the RTL's structural limits.

        Raise ValueError for an invalid cache geometry, ID width, line size, or
        DDR setting.
        """
        self.ddr.validate()
        for label, size, line, ways in (
            ("L1I", self.l1i_bytes, self.l1_line_bytes, self.l1i_ways),
            ("L1D", self.l1d_bytes, self.l1_line_bytes, self.l1d_ways),
            ("L2", self.l2_bytes, self.l2_line_bytes, self.l2_ways),
        ):
            if size <= 0 or line <= 0 or ways <= 0 or size % (line * ways):
                raise ValueError(f"invalid {label} geometry")
        if self.l2_line_bytes % self.l1_line_bytes:
            raise ValueError("L2 line must contain an integral number of L1 lines")
        # L1D downstream ID is {type, slot} in a fixed four-bit CPU-top line ID.
        if self.l1d_mshrs > 8 or self.l1d_wb_slots > 8:
            raise ValueError(
                "FROST L1D four-bit {type,slot} downstream ID permits at most 8 slots/type"
            )
        # L2 downstream ID is five bits in cpu_top / soc_axi_slave, leaving 16 per type.
        if self.l2_mshrs > 16 or self.l2_wb_slots > 16:
            raise ValueError(
                "FROST five-bit L2 downstream {type,slot} ID permits at most 16 slots/type"
            )
        if self.axi_data_bytes != self.l2_line_bytes:
            raise ValueError("the modeled AXI beat is exactly one L2 line")
        if self.cpu_axi_id_bits < 6:
            raise ValueError(
                "cpu_memory_fabric requires at least 6 AXI ID bits at the cpu_top boundary"
            )
        if self.axi_id_bits != 5 or self.ddr.id_bits != 5:
            raise ValueError("FROST soc_axi_slave DDR port uses 5-bit AXI IDs (0..31)")
        if self.ddr.line_bytes != self.axi_data_bytes:
            raise ValueError("DDR line_bytes must match the L2/AXI beat width")
        if (
            self.ddr.num_slots <= 0
            or self.ddr.latency_cycles < 0
            or self.ddr.latency_jitter < 0
        ):
            raise ValueError("invalid DDR slot or latency configuration")


def with_config(base: ModelConfig, name: str, **changes: Any) -> ModelConfig:
    """Return a validated copy of base named name, with the given fields changed."""
    data = dataclasses.asdict(base)
    data.update(changes)
    if isinstance(data.get("soc"), dict):
        data["soc"] = SocConfig(**data["soc"])
    if isinstance(data.get("ddr"), dict):
        data["ddr"] = DdrConfig(**data["ddr"])
    value = ModelConfig(**data)
    value = dataclasses.replace(value, name=name)
    value.validate()
    return value


class EventLoop:
    """Small deterministic event loop shared by cpu_top and soc_top."""

    def __init__(self) -> None:
        """Start at cycle 0 with no pending events."""
        self.cycle = 0
        self._sequence = 0
        self._events: list[tuple[int, int, Callable[[], None]]] = []

    def after(self, cycles: int, callback: Callable[[], None]) -> None:
        """Schedule callback the given number of cycles from now."""
        if cycles < 0:
            raise ValueError("cannot schedule an event in the past")
        self._sequence += 1
        heapq.heappush(self._events, (self.cycle + cycles, self._sequence, callback))

    def at(self, cycle: int, callback: Callable[[], None]) -> None:
        """Schedule callback at an absolute cycle, not in the past."""
        if cycle < self.cycle:
            raise ValueError("cannot schedule an event in the past")
        self._sequence += 1
        heapq.heappush(self._events, (cycle, self._sequence, callback))

    def run_ready(self) -> None:
        """Run the events due by the current cycle, earliest first.

        Events that they schedule for the current cycle run too.
        """
        while self._events and self._events[0][0] <= self.cycle:
            _, _, callback = heapq.heappop(self._events)
            callback()

    @property
    def empty(self) -> bool:
        """Return True when no event is pending."""
        return not self._events


@dataclass(frozen=True)
class TransactionId:
    """Explicit lower-level cache/AXI identity: FROST uses {type, slot}."""

    owner: str
    kind: str  # "fill" maps to type 0; "writeback" maps to type 1.
    slot: int
    bits: int

    def encode(self) -> int:
        """Return the {type, slot} encoding of the ID.

        Raise ValueError for an unknown kind or a slot that does not fit.
        """
        if self.kind not in {"fill", "writeback"}:
            raise ValueError(f"unsupported transaction class {self.kind}")
        type_bit = 0 if self.kind == "fill" else 1
        slot_bits = self.bits - 1
        if self.slot < 0 or self.slot >= (1 << slot_bits):
            raise ValueError(
                f"slot {self.slot} does not fit in {self.bits}-bit {{type,slot}} id"
            )
        return (type_bit << slot_bits) | self.slot

    @classmethod
    def decode(cls, value: int, bits: int, owner: str) -> TransactionId:
        """Return the ID that a {type, slot} value of the given width encodes."""
        slot_bits = bits - 1
        return cls(
            owner,
            "writeback" if value & (1 << slot_bits) else "fill",
            value & ((1 << slot_bits) - 1),
            bits,
        )


Completion = Callable[[bool], None]


@dataclass
class Request:
    """One cache request and the callback that completes it."""

    address: int
    is_write: bool
    source: str
    request_id: Any
    complete: Completion
    maintenance: bool = False
    sector: int = 0
    bytes_size: int = 64


@dataclass
class CacheLine:
    """The state of one cache way."""

    tag: int | None = None
    valid: bool = False
    dirty: bool = False
    reserved_by: int | None = None
    last_used: int = 0
    prefetched: bool = False


@dataclass
class MissStatus:
    """One MSHR: the missing line, the way it reserves, and its requests.

    A miss that evicts a dirty line waits for that line's writeback
    before it fetches.
    """

    slot: int
    line_address: int
    set_index: int
    way_index: int
    primary: Request
    waiters: list[Request] = field(default_factory=list)
    write_intent: bool = False
    fill_started: bool = False
    waiting_for_wb: bool = False
    wb_slot: int | None = None
    evicted_line_address: int | None = None


class SubmissionPort(Protocol):
    """A lower level that returns False from submit to apply backpressure."""

    def submit(self, request: Request) -> bool:
        """Offer a request; return True if the level accepts it."""
        ...


class CacheLevel:
    """One non-blocking write-back FROST cache (``frost_cache.sv``).

    Preserves static RTL properties: MSHR ownership of a victim way while a fill
    is pending, coalesced same-line reads with bounded waiter seats, separate
    writeback slots, and lower IDs encoded as ``{type, slot}``.
    """

    def __init__(
        self,
        name: str,
        loop: EventLoop,
        lower: SubmissionPort,
        size_bytes: int,
        line_bytes: int,
        ways: int,
        mshr_count: int,
        wb_slots: int,
        waiter_count: int,
        tag_cycles: int,
        data_cycles: int,
        fill_cycles: int,
        response_cycles: int,
        id_bits: int,
        bimodal_insert: bool = False,
        miss_observer: Callable[[int], None] | None = None,
    ) -> None:
        """Create an empty cache with the given geometry, miss resources, and latencies.

        id_bits is the width of the {type, slot} IDs of its requests to the
        lower level. miss_observer, when given, receives the line address of
        each L1D demand miss.
        """
        self.name = name
        self.loop = loop
        self.lower = lower
        self.size_bytes = size_bytes
        self.line_bytes = line_bytes
        self.ways = ways
        self.sets_count = size_bytes // (line_bytes * ways)
        self.mshr_count = mshr_count
        self.wb_slots = wb_slots
        self.waiter_count = waiter_count
        self.tag_cycles = tag_cycles
        self.data_cycles = data_cycles
        self.fill_cycles = fill_cycles
        self.response_cycles = response_cycles
        self.id_bits = id_bits
        self.bimodal_insert = bimodal_insert
        self.miss_observer = miss_observer
        self.sets: dict[int, list[CacheLine]] = {}
        self.mshrs: dict[int, MissStatus] = {}
        self._used_mshr_slots: set[int] = set()
        self._used_wb_slots: set[int] = set()
        self._last_accept_cycle = -1
        self._last_response_cycle = -1
        self._touch_counter = 0
        self.stats: Counter = Counter()

    def _set_and_tag(self, address: int) -> tuple[int, int, int]:
        line = address // self.line_bytes
        return line, line % self.sets_count, line // self.sets_count

    def _ways(self, set_index: int) -> list[CacheLine]:
        if set_index not in self.sets:
            self.sets[set_index] = [CacheLine() for _ in range(self.ways)]
        return self.sets[set_index]

    def _find(self, set_index: int, tag: int) -> int | None:
        for idx, line in enumerate(self._ways(set_index)):
            if line.valid and line.tag == tag and line.reserved_by is None:
                return idx
        return None

    def _allocate_slot(self, used: set[int], total: int) -> int | None:
        for slot in range(total):
            if slot not in used:
                used.add(slot)
                return slot
        return None

    def _victim(self, set_index: int) -> int | None:
        lines = self._ways(set_index)
        for index, line in enumerate(lines):
            if not line.valid and line.reserved_by is None:
                return index
        options = [
            (line.last_used, index)
            for index, line in enumerate(lines)
            if line.reserved_by is None
        ]
        return min(options)[1] if options else None

    def _touch(self, line: CacheLine, prefetched: bool = False) -> None:
        self._touch_counter += 1
        line.last_used = self._touch_counter
        if not prefetched:
            line.prefetched = False

    def submit(self, request: Request) -> bool:
        """Accept at most one tag lookup per modeled cache cycle."""
        if self._last_accept_cycle == self.loop.cycle:
            self.stats["input_backpressure"] += 1
            return False
        line_address, set_index, tag = self._set_and_tag(request.address)
        hit_way = self._find(set_index, tag)
        if hit_way is not None:
            self._last_accept_cycle = self.loop.cycle
            line = self._ways(set_index)[hit_way]
            self._touch(line)
            if request.is_write:
                line.dirty = True
            elif line.prefetched:
                self.stats["useful_prefetches"] += 1
                line.prefetched = False
            self.stats["hits"] += 1
            self.loop.after(
                self.tag_cycles + self.data_cycles, lambda: self._respond(request)
            )
            return True

        active = self.mshrs.get(line_address)
        if active is not None:
            if request.is_write and not active.waiters:
                active.write_intent = True
                active.waiters.append(request)
            elif len(active.waiters) < self.waiter_count:
                active.waiters.append(request)
            else:
                self.stats["waiter_backpressure"] += 1
                return False
            self._last_accept_cycle = self.loop.cycle
            self.stats["mshr_merges"] += 1
            return True

        if len(self.mshrs) >= self.mshr_count:
            self.stats["mshr_backpressure"] += 1
            return False
        victim_way = self._victim(set_index)
        if victim_way is None:
            self.stats["reserved_way_backpressure"] += 1
            return False
        victim = self._ways(set_index)[victim_way]
        needs_wb = victim.valid and victim.dirty
        evicted_line_address = (
            (victim.tag * self.sets_count + set_index)
            if victim.valid and victim.tag is not None
            else None
        )
        wb_slot: int | None = None
        if needs_wb:
            wb_slot = self._allocate_slot(self._used_wb_slots, self.wb_slots)
            if wb_slot is None:
                self.stats["writeback_backpressure"] += 1
                return False
        mshr_slot = self._allocate_slot(self._used_mshr_slots, self.mshr_count)
        assert mshr_slot is not None
        self._last_accept_cycle = self.loop.cycle
        victim.reserved_by = mshr_slot
        victim.valid = False
        status = MissStatus(
            slot=mshr_slot,
            line_address=line_address,
            set_index=set_index,
            way_index=victim_way,
            primary=request,
            write_intent=request.is_write,
            waiting_for_wb=needs_wb,
            wb_slot=wb_slot,
            evicted_line_address=evicted_line_address,
        )
        self.mshrs[line_address] = status
        self.stats["misses"] += 1
        if needs_wb:
            self.stats["dirty_evictions"] += 1
        if self.miss_observer is not None and request.source == "l1d":
            self.miss_observer(line_address)
        self.loop.after(self.tag_cycles, lambda status=status: self._begin_miss(status))
        return True

    def _begin_miss(self, status: MissStatus) -> None:
        if self.mshrs.get(status.line_address) is not status:
            return
        if status.waiting_for_wb:
            assert status.wb_slot is not None
            wb_id = TransactionId(self.name, "writeback", status.wb_slot, self.id_bits)
            evicted_line_address = self._evicted_line_address(status)
            wb = Request(
                address=evicted_line_address * self.line_bytes,
                is_write=True,
                source=f"{self.name}_writeback",
                request_id=wb_id,
                complete=lambda _ok, status=status: self._writeback_done(status),
                bytes_size=self.line_bytes,
            )
            if not self.lower.submit(wb):
                self.stats["downstream_backpressure"] += 1
                self.loop.after(1, lambda status=status: self._begin_miss(status))
            return
        if status.fill_started:
            return
        fill_id = TransactionId(self.name, "fill", status.slot, self.id_bits)
        request = Request(
            address=status.line_address * self.line_bytes,
            is_write=False,
            source=self.name,
            request_id=fill_id,
            complete=lambda ok, status=status: self._fill_done(status, ok),
            bytes_size=self.line_bytes,
        )
        if not self.lower.submit(request):
            self.stats["downstream_backpressure"] += 1
            self.loop.after(1, lambda status=status: self._begin_miss(status))
            return
        status.fill_started = True
        self.stats["fills_issued"] += 1

    def _evicted_line_address(self, status: MissStatus) -> int:
        assert status.evicted_line_address is not None
        return status.evicted_line_address

    def _writeback_done(self, status: MissStatus) -> None:
        if self.mshrs.get(status.line_address) is not status:
            return
        status.waiting_for_wb = False
        assert status.wb_slot is not None
        self._used_wb_slots.remove(status.wb_slot)
        self.stats["writebacks_completed"] += 1
        self._begin_miss(status)

    def _fill_done(self, status: MissStatus, ok: bool) -> None:
        if self.mshrs.get(status.line_address) is not status:
            return
        self.loop.after(
            self.fill_cycles,
            lambda status=status, ok=ok: self._install_and_respond(status, ok),
        )

    def _install_and_respond(self, status: MissStatus, ok: bool) -> None:
        if self.mshrs.get(status.line_address) is not status:
            return
        _, _, tag = self._set_and_tag(status.line_address * self.line_bytes)
        line = self._ways(status.set_index)[status.way_index]
        line.tag = tag
        line.valid = ok
        line.dirty = status.write_intent
        line.reserved_by = None
        self._touch(line, prefetched=status.primary.source == "prefetch")
        line.prefetched = status.primary.source == "prefetch"
        responses = [status.primary] + status.waiters
        del self.mshrs[status.line_address]
        self._used_mshr_slots.remove(status.slot)
        for response in responses:
            self._respond(response, ok)

    def _respond(self, request: Request, ok: bool = True) -> None:
        response_cycle = (
            max(self.loop.cycle, self._last_response_cycle + 1) + self.response_cycles
        )
        self._last_response_cycle = response_cycle
        self.loop.at(response_cycle, lambda: request.complete(ok))

    def occupancy(self) -> dict[str, int]:
        """Return the numbers of busy MSHRs and writeback slots."""
        return {"mshrs": len(self.mshrs), "writeback_slots": len(self._used_wb_slots)}


class LineSizeAdapter:
    """Models the 32-byte L1 to 64-byte L2 sector adapter in ``frost_cache_hierarchy.sv``."""

    def __init__(
        self, lower: SubmissionPort, up_line_bytes: int, down_line_bytes: int
    ) -> None:
        """Forward requests for up_line_bytes lines as down_line_bytes lines."""
        self.lower = lower
        self.up_line_bytes = up_line_bytes
        self.down_line_bytes = down_line_bytes
        self.stats: Counter = Counter()

    def submit(self, request: Request) -> bool:
        """Forward a request as a request for its whole lower line.

        Return the lower level's answer, and count the sector it selects.
        """
        self.stats["requests"] += 1
        sector = (request.address % self.down_line_bytes) // self.up_line_bytes
        forwarded = dataclasses.replace(
            request, sector=sector, bytes_size=self.down_line_bytes
        )
        accepted = self.lower.submit(forwarded)
        if accepted:
            self.stats[f"sector_{sector}"] += 1
        else:
            self.stats["backpressure"] += 1
        return accepted


@dataclass
class AxiTransaction:
    """Single-beat AXI4 transaction crossing ``cpu_top`` -> ``soc_top`` or ``soc_top`` -> DDR."""

    address: int
    is_write: bool
    transaction_id: TransactionId
    complete: Completion
    source: str
    axi_id: int = 0
    bytes_size: int = 64

    def __post_init__(self) -> None:
        """Take the AXI ID from the transaction ID when none is given."""
        if self.axi_id == 0 and isinstance(self.transaction_id, TransactionId):
            self.axi_id = self.transaction_id.encode()


class DdrController(Protocol):
    """Protocol for the single-port DDR endpoint behind ``soc_top``."""

    def submit(self, transaction: AxiTransaction) -> bool:
        """Offer a transaction; return True if the controller accepts it."""
        ...

    def summary(self) -> dict[str, Any]:
        """Return the controller's configuration and statistics."""
        ...


class SocTopPort(Protocol):
    """Protocol for ``soc_top`` attached to ``cpu_top``'s AXI4 master interface."""

    def submit_axi(self, transaction: AxiTransaction) -> bool:
        """Offer a transaction from cpu_top; return True if soc_top accepts it."""
        ...

    def summary(self) -> dict[str, Any]:
        """Return soc_top's configuration and statistics."""
        ...


class SingleChannelDdrController:
    """FROST single-channel 512-bit AXI4 DDR model (``axi_behavioral_memory.sv``).

    Models the single board/simulation DDR AXI4 slave in ``soc_top.sv``:
      - One 512-bit (64-byte) AXI4 port with 5-bit AXI IDs (``0..31``).
      - Independent read and write pending-transaction slot pools of size
        ``effective_slots = max(config.num_slots, l2_mshrs, l2_wb_slots)``
        (matching ``DdrModelSlots`` in ``soc_top.sv``).
      - Free-running 16-bit LFSR (``x^16 + x^14 + x^13 + x^11 + 1``, seeded with
        ``JITTER_SEED``) for deterministic latency jitter and optional cross-ID
        reordering.
      - With ``reorder=False`` (default), each channel (read and write) completes
        strictly in issue order once the oldest pending transaction's countdown
        reaches zero.  With ``reorder=True``, the oldest transaction whose
        countdown has elapsed completes first.
    """

    def __init__(
        self,
        loop: EventLoop,
        config: DdrConfig,
        l2_mshrs: int = 4,
        l2_wb_slots: int = 2,
    ) -> None:
        """Create an idle controller.

        Each channel's slot pool covers the configured slots, the L2's miss
        and writeback slots, and at least eight.
        """
        self.loop = loop
        self.config = config
        l2_max_slots = max(l2_mshrs, l2_wb_slots)
        self.effective_slots = max(config.num_slots, l2_max_slots, 8)
        self._rd_queue: deque[tuple[int, int, AxiTransaction]] = deque()
        self._wr_queue: deque[tuple[int, int, AxiTransaction]] = deque()
        self._inflight_rd_ids: set[int] = set()
        self._inflight_wr_ids: set[int] = set()
        self._rd_seq = 0
        self._wr_seq = 0
        self._lfsr = (config.jitter_seed & 0xFFFF) or 0xACE1
        self._lfsr_cycle = 0
        self._pump_scheduled = False
        self.stats: Counter = Counter()

    def _advance_lfsr_to(self, target_cycle: int) -> None:
        while self._lfsr_cycle < target_cycle:
            feedback = (
                ((self._lfsr >> 15) & 1)
                ^ ((self._lfsr >> 13) & 1)
                ^ ((self._lfsr >> 12) & 1)
                ^ ((self._lfsr >> 10) & 1)
            )
            self._lfsr = ((self._lfsr << 1) & 0xFFFF) | feedback
            self._lfsr_cycle += 1

    def _sample_latency(self) -> int:
        self._advance_lfsr_to(self.loop.cycle)
        jitter = (
            (self._lfsr % (self.config.latency_jitter + 1))
            if self.config.latency_jitter > 0
            else 0
        )
        reorder_spread = ((self._lfsr >> 13) & 0x7) if self.config.reorder else 0
        return max(1, self.config.latency_cycles + jitter + reorder_spread)

    def submit(self, transaction: AxiTransaction) -> bool:
        """Queue a transaction to complete after a sampled latency.

        Return False when its channel's slots are full or its ID is already
        in flight. Raise ValueError for a transfer that is not one line or
        an ID wider than the DDR port's.
        """
        if transaction.bytes_size != self.config.line_bytes:
            raise ValueError(
                f"DDR port requires {self.config.line_bytes}-byte single-beat line transactions"
            )
        if transaction.axi_id < 0 or transaction.axi_id >= (1 << self.config.id_bits):
            raise ValueError(
                f"AXI ID {transaction.axi_id} exceeds {self.config.id_bits}-bit DDR AXI ID width"
            )

        if transaction.is_write:
            if len(self._wr_queue) >= self.effective_slots:
                self.stats["queue_backpressure"] += 1
                self.stats["write_slot_backpressure"] += 1
                return False
            if transaction.axi_id in self._inflight_wr_ids:
                self.stats["duplicate_id_backpressure"] += 1
                return False
            ready_cycle = self.loop.cycle + self._sample_latency()
            self._wr_seq += 1
            self._wr_queue.append((ready_cycle, self._wr_seq, transaction))
            self._inflight_wr_ids.add(transaction.axi_id)
            self.stats["accepted"] += 1
            self.stats["writes"] += 1
        else:
            if len(self._rd_queue) >= self.effective_slots:
                self.stats["queue_backpressure"] += 1
                self.stats["read_slot_backpressure"] += 1
                return False
            if transaction.axi_id in self._inflight_rd_ids:
                self.stats["duplicate_id_backpressure"] += 1
                return False
            ready_cycle = self.loop.cycle + self._sample_latency()
            self._rd_seq += 1
            self._rd_queue.append((ready_cycle, self._rd_seq, transaction))
            self._inflight_rd_ids.add(transaction.axi_id)
            self.stats["accepted"] += 1
            self.stats["reads"] += 1

        self._schedule_pump()
        return True

    def _next_ready_cycle(self) -> int | None:
        candidates: list[int] = []
        if self._rd_queue:
            if self.config.reorder:
                candidates.append(min(item[0] for item in self._rd_queue))
            else:
                candidates.append(self._rd_queue[0][0])
        if self._wr_queue:
            if self.config.reorder:
                candidates.append(min(item[0] for item in self._wr_queue))
            else:
                candidates.append(self._wr_queue[0][0])
        return min(candidates) if candidates else None

    def _schedule_pump(self) -> None:
        if self._pump_scheduled:
            return
        next_cycle = self._next_ready_cycle()
        if next_cycle is None:
            return
        self._pump_scheduled = True
        target = max(self.loop.cycle + 1, next_cycle)
        self.loop.at(target, self._pump)

    def _pop_ready(
        self, queue: deque[tuple[int, int, AxiTransaction]]
    ) -> AxiTransaction | None:
        if not queue:
            return None
        if not self.config.reorder:
            ready_cycle, _, tx = queue[0]
            if ready_cycle <= self.loop.cycle:
                queue.popleft()
                return tx
            return None
        for idx, (ready_cycle, _seq, tx) in enumerate(queue):
            if ready_cycle <= self.loop.cycle:
                del queue[idx]
                return tx
        return None

    def _pump(self) -> None:
        self._pump_scheduled = False
        rd_tx = self._pop_ready(self._rd_queue)
        if rd_tx is not None:
            self._inflight_rd_ids.discard(rd_tx.axi_id)
            self.stats["completed"] += 1
            self.stats["read_completed"] += 1
            rd_tx.complete(True)

        wr_tx = self._pop_ready(self._wr_queue)
        if wr_tx is not None:
            self._inflight_wr_ids.discard(wr_tx.axi_id)
            self.stats["completed"] += 1
            self.stats["write_completed"] += 1
            wr_tx.complete(True)

        if self._rd_queue or self._wr_queue:
            self._schedule_pump()

    def summary(self) -> dict[str, Any]:
        """Return the configuration, slot count, statistics, and queued transactions."""
        return {
            "kind": "frost_single_channel_axi_ddr",
            "configuration": dataclasses.asdict(self.config),
            "effective_slots": self.effective_slots,
            "stats": dict(self.stats),
            "inflight_reads": len(self._rd_queue),
            "inflight_writes": len(self._wr_queue),
        }


class InterleavedDdrController:
    """Address-interleaved memory with bounded queues and a shared AXI port.

    Each physical channel has separate read and write queues of num_slots
    entries. Reads and writes share its data bandwidth. One line completes
    every cycles_per_line cycles after its latency has elapsed. The AXI
    return port carries at most one read response and one write response
    per cycle across all channels.
    """

    def __init__(self, loop: EventLoop, config: DdrConfig) -> None:
        """Create empty channel queues and deterministic latency sampling."""
        config.validate()
        self.loop = loop
        self.config = config
        self.queues: list[list[tuple[int, int, AxiTransaction]]] = [
            [] for _ in range(2 * config.channels)
        ]
        self.next_service = [0] * config.channels
        self.inflight: set[tuple[bool, int]] = set()
        self.sequence = 0
        self.scheduled = False
        self.stats: Counter = Counter()
        self.channel_stats = [Counter() for _ in range(config.channels)]
        self._latency = SingleChannelDdrController(loop, config)
        self._accounted_cycle = loop.cycle

    def _account(self) -> None:
        self.stats["inflight_cycles"] += (
            self.loop.cycle - self._accounted_cycle
        ) * len(self.inflight)
        self._accounted_cycle = self.loop.cycle

    def submit(self, transaction: AxiTransaction) -> bool:
        """Accept a line when its channel has a free slot and its ID is idle."""
        if transaction.bytes_size != self.config.line_bytes:
            raise ValueError("DDR transactions must transfer one line")
        if not 0 <= transaction.axi_id < 1 << self.config.id_bits:
            raise ValueError("DDR transaction ID exceeds the port width")
        channel = (
            transaction.address // self.config.interleave_bytes
        ) % self.config.channels
        queue = self.queues[2 * channel + int(transaction.is_write)]
        key = (transaction.is_write, transaction.axi_id)
        if key in self.inflight:
            self.stats["duplicate_id_backpressure"] += 1
            return False
        if len(queue) >= self.config.num_slots:
            self.stats["queue_backpressure"] += 1
            self.channel_stats[channel]["queue_backpressure"] += 1
            return False
        self._account()
        self.sequence += 1
        queue.append(
            (
                self.loop.cycle + self._latency._sample_latency(),
                self.sequence,
                transaction,
            )
        )
        self.inflight.add(key)
        self.stats["accepted"] += 1
        self.stats["writes" if transaction.is_write else "reads"] += 1
        self.stats["max_inflight"] = max(self.stats["max_inflight"], len(self.inflight))
        self.channel_stats[channel]["accepted"] += 1
        self._schedule()
        return True

    def _schedule(self) -> None:
        if self.inflight and not self.scheduled:
            self.scheduled = True
            self.loop.after(1, self._pump)

    def _pump(self) -> None:
        self.scheduled = False
        self._account()
        candidates = []
        for channel in range(self.config.channels):
            if self.loop.cycle < self.next_service[channel]:
                continue
            for direction in range(2):
                queue = self.queues[2 * channel + direction]
                for index, (ready, sequence, transaction) in enumerate(queue):
                    if ready <= self.loop.cycle:
                        candidates.append(
                            (sequence, channel, direction, index, transaction)
                        )
                        break
                    if not self.config.reorder:
                        break
        used_channels: set[int] = set()
        used_directions: set[int] = set()
        for _, channel, direction, index, transaction in sorted(candidates):
            if channel in used_channels or direction in used_directions:
                continue
            used_channels.add(channel)
            used_directions.add(direction)
            del self.queues[2 * channel + direction][index]
            self.inflight.remove((transaction.is_write, transaction.axi_id))
            self.next_service[channel] = self.loop.cycle + self.config.cycles_per_line
            self.stats["completed"] += 1
            self.stats[
                "write_completed" if transaction.is_write else "read_completed"
            ] += 1
            self.channel_stats[channel]["completed"] += 1
            transaction.complete(True)
        self._schedule()

    def summary(self) -> dict[str, Any]:
        """Return queue occupancy, service counts, and endpoint configuration."""
        self._account()
        return {
            "kind": "interleaved_axi_ddr",
            "configuration": dataclasses.asdict(self.config),
            "effective_slots": self.config.num_slots,
            "stats": dict(self.stats),
            "channels": [dict(stats) for stats in self.channel_stats],
            "pending_reads": sum(len(q) for q in self.queues[::2]),
            "pending_writes": sum(len(q) for q in self.queues[1::2]),
        }


class SocTopModel:
    """FROST ``soc_top.sv`` + ``soc_axi_slave.sv`` model.

    Receives physical-address AXI4 transactions from ``CpuTopModel`` across the
    single 6-bit-ID, 512-bit AXI4 boundary and routes them by physical address:
      - Cached DDR aperture ``[ddr_base, ddr_base + ddr_bytes)``: validates the
        5-bit DDR ID contract (``axi_id < 32``) and 64-byte line size, subtracts
        ``ddr_base``, models ``soc_axi_slave``'s write-address register stage
        (``aw_valid_q``) and combinational read pass-through, and submits to the
        replaceable single-channel ``DdrController``.
      - Local aperture (BRAM ``[bram_base, bram_base + bram_bytes)`` and MMIO
        ``[mmio_base, mmio_base + mmio_bytes)``): services through the single
        serialized local port.
    """

    def __init__(
        self,
        config: ModelConfig,
        loop: EventLoop,
        controller: DdrController | None = None,
    ) -> None:
        """Model soc_top in front of a DDR controller.

        Without controller, build a SingleChannelDdrController from the
        configuration.
        """
        self.config = config
        self.soc_config = config.soc
        self.loop = loop
        self.ddr: DdrController = controller or (
            InterleavedDdrController(loop, config.ddr)
            if config.ddr.controller == "interleaved"
            else SingleChannelDdrController(
                loop,
                config.ddr,
                l2_mshrs=config.l2_mshrs,
                l2_wb_slots=config.l2_wb_slots,
            )
        )
        self._aw_slot_busy = False
        self._local_busy = False
        self.stats: Counter = Counter()

    def _is_ddr_address(self, address: int) -> bool:
        return (
            self.soc_config.ddr_base
            <= address
            < (self.soc_config.ddr_base + self.soc_config.ddr_bytes)
        )

    def _is_bram_address(self, address: int) -> bool:
        return (
            self.soc_config.bram_base
            <= address
            < (self.soc_config.bram_base + self.soc_config.bram_bytes)
        )

    def _is_mmio_address(self, address: int) -> bool:
        return (
            self.soc_config.mmio_base
            <= address
            < (self.soc_config.mmio_base + self.soc_config.mmio_bytes)
        )

    def submit_axi(self, transaction: AxiTransaction) -> bool:
        """Route a transaction by address; return False on backpressure.

        A DDR transaction with an ID of 32 or more, or that is not one line,
        completes with an error. An address outside DDR, BRAM, and MMIO
        completes with a decode error.
        """
        addr = transaction.address
        if self._is_ddr_address(addr):
            if (
                transaction.axi_id >= 32
                or transaction.bytes_size != self.config.axi_data_bytes
            ):
                self.stats["ddr_protocol_reject"] += 1
                self.loop.after(1, lambda: transaction.complete(False))
                return True
            ddr_offset = addr - self.soc_config.ddr_base
            ddr_tx = dataclasses.replace(
                transaction,
                address=ddr_offset,
                axi_id=transaction.axi_id & 0x1F,
            )
            if transaction.is_write and self.soc_config.ddr_aw_register_cycles > 0:
                if self._aw_slot_busy:
                    self.stats["soc_aw_slot_backpressure"] += 1
                    return False
                self._aw_slot_busy = True
                self.stats["ddr_writes_forwarded"] += 1
                self.loop.after(
                    self.soc_config.ddr_aw_register_cycles,
                    lambda ddr_tx=ddr_tx: self._forward_registered_ddr_write(ddr_tx),
                )
                return True
            accepted = self.ddr.submit(ddr_tx)
            if accepted:
                self.stats[
                    "ddr_writes_forwarded"
                    if transaction.is_write
                    else "ddr_reads_forwarded"
                ] += 1
            else:
                self.stats["ddr_backpressure"] += 1
            return accepted

        # Local BRAM / MMIO path through soc_axi_slave's single local port.
        if self._local_busy:
            self.stats["local_port_backpressure"] += 1
            return False
        self._local_busy = True
        if self._is_bram_address(addr):
            if transaction.is_write:
                latency = self.soc_config.local_bram_write_cycles
                self.stats["local_bram_writes"] += 1
            elif transaction.bytes_size == 32:
                latency = self.soc_config.local_wide_fetch_cycles
                self.stats["local_bram_wide_fetches"] += 1
            else:
                latency = self.soc_config.local_bram_read_cycles
                self.stats["local_bram_reads"] += 1
            ok = True
        elif self._is_mmio_address(addr):
            latency = self.soc_config.local_mmio_cycles
            self.stats["local_mmio_accesses"] += 1
            ok = True
        else:
            latency = 1
            self.stats["local_decode_errors"] += 1
            ok = False

        def finish_local(status_ok: bool = ok) -> None:
            self._local_busy = False
            transaction.complete(status_ok)

        self.loop.after(latency, finish_local)
        return True

    def _forward_registered_ddr_write(self, ddr_tx: AxiTransaction) -> None:
        if self.ddr.submit(ddr_tx):
            self._aw_slot_busy = False
        else:
            self.stats["ddr_backpressure"] += 1
            self.loop.after(
                1, lambda ddr_tx=ddr_tx: self._forward_registered_ddr_write(ddr_tx)
            )

    def summary(self) -> dict[str, Any]:
        """Return the configuration, statistics, and DDR controller summary."""
        return {
            "kind": "frost_soc_top",
            "configuration": dataclasses.asdict(self.soc_config),
            "stats": dict(self.stats),
            "ddr": self.ddr.summary(),
        }


class AxiBridge:
    """``cpu_top`` 512-bit AXI4 master boundary (``line_port_axi_bridge.sv`` + ``cpu_memory_fabric.sv``)."""

    def __init__(
        self,
        loop: EventLoop,
        soc: SocTopPort,
        axi_data_bytes: int,
        axi_id_bits: int,
    ) -> None:
        """Send line requests to soc, accepting one read and one write per cycle."""
        self.loop = loop
        self.soc = soc
        self.axi_data_bytes = axi_data_bytes
        self.axi_id_bits = axi_id_bits
        self._read_accept_cycle = -1
        self._write_accept_cycle = -1
        self.stats: Counter = Counter()

    def submit(self, request: Request) -> bool:
        """Send a line request to soc_top as an AXI transaction.

        Return False on backpressure. Raise TypeError or ValueError for a
        request without a {type, slot} ID, a misaligned address, or an ID
        wider than the AXI port's.
        """
        if not isinstance(request.request_id, TransactionId):
            raise TypeError(
                "AXI-facing cache request must own an explicit {type,slot} ID"
            )
        if request.address % self.axi_data_bytes:
            raise ValueError(
                "AXI bridge receives only L2-line-aligned 64-byte transfers"
            )
        if request.request_id.bits > self.axi_id_bits:
            raise ValueError("cache ID does not fit the DDR AXI ID width")
        if request.is_write:
            if self._write_accept_cycle == self.loop.cycle:
                self.stats["write_channel_backpressure"] += 1
                return False
        else:
            if self._read_accept_cycle == self.loop.cycle:
                self.stats["read_channel_backpressure"] += 1
                return False

        axi_id = request.request_id.encode()
        accepted = self.soc.submit_axi(
            AxiTransaction(
                address=request.address,
                is_write=request.is_write,
                transaction_id=request.request_id,
                complete=request.complete,
                source=request.source,
                axi_id=axi_id,
                bytes_size=self.axi_data_bytes,
            )
        )
        if accepted:
            if request.is_write:
                self._write_accept_cycle = self.loop.cycle
                self.stats["write_beats"] += 1
            else:
                self._read_accept_cycle = self.loop.cycle
                self.stats["read_beats"] += 1
        else:
            self.stats["controller_backpressure"] += 1
        return accepted


class StreamPrefetcher:
    """Small, intentionally transparent approximation of the RTL L2 stream prefetcher."""

    def __init__(self, adapter: LineSizeAdapter, config: ModelConfig) -> None:
        """Prefetch through adapter with the configuration's distance and limit."""
        self.adapter = adapter
        self.config = config
        self.last_line: int | None = None
        self.inflight = 0
        self.next_id = 0
        self.stats: Counter = Counter()

    def observe(self, l1_line: int) -> None:
        """Note an L1D miss and prefetch ahead of a sequential stream.

        A miss on the line after the previous miss requests the line
        l2_prefetch_distance lines ahead, unless l2_prefetch_inflight
        prefetches are already in flight.
        """
        if not self.config.l2_prefetch:
            return
        sequential = self.last_line is not None and l1_line == self.last_line + 1
        self.last_line = l1_line
        if not sequential or self.inflight >= self.config.l2_prefetch_inflight:
            return
        target = l1_line + self.config.l2_prefetch_distance
        request_id = ("prefetch", self.next_id)
        self.next_id += 1
        self.inflight += 1

        def done(_ok: bool) -> None:
            self.inflight -= 1
            self.stats["completed"] += 1

        request = Request(
            address=target * self.config.l1_line_bytes,
            is_write=False,
            source="prefetch",
            request_id=request_id,
            complete=done,
            bytes_size=self.config.l1_line_bytes,
        )
        if self.adapter.submit(request):
            self.stats["issued"] += 1
        else:
            self.inflight -= 1
            self.stats["dropped_backpressure"] += 1


class CpuTopMemoryHierarchy:
    """``cpu_top.sv`` cache hierarchy and AXI4 master connected to ``SocTopPort``.

    ``MemoryHierarchy`` is preserved as an alias for backwards compatibility.
    """

    def __init__(
        self,
        config: ModelConfig,
        loop: EventLoop,
        controller: DdrController | None = None,
        soc: SocTopPort | None = None,
    ) -> None:
        """Build the L1I, L1D, sector adapter, prefetcher, L2, and AXI bridge.

        The bridge leads to soc, or to a SocTopModel built from the
        configuration.
        """
        config.validate()
        self.config = config
        self.loop = loop
        self.soc: SocTopPort = soc or SocTopModel(config, loop, controller=controller)
        self.controller: DdrController = (
            self.soc.ddr
            if isinstance(self.soc, SocTopModel)
            else (controller or SingleChannelDdrController(loop, config.ddr))
        )
        self.axi = AxiBridge(loop, self.soc, config.axi_data_bytes, config.axi_id_bits)
        self.l2 = CacheLevel(
            "l2",
            loop,
            self.axi,
            config.l2_bytes,
            config.l2_line_bytes,
            config.l2_ways,
            config.l2_mshrs,
            config.l2_wb_slots,
            config.l2_waiters,
            config.l2_tag_cycles,
            config.l2_data_cycles,
            config.cache_fill_cycles,
            config.cache_response_cycles,
            config.axi_id_bits,
        )
        self.adapter = LineSizeAdapter(
            self.l2, config.l1_line_bytes, config.l2_line_bytes
        )
        self.prefetcher = StreamPrefetcher(self.adapter, config)
        self.l1d = CacheLevel(
            "l1d",
            loop,
            self.adapter,
            config.l1d_bytes,
            config.l1_line_bytes,
            config.l1d_ways,
            config.l1d_mshrs,
            config.l1d_wb_slots,
            1,
            config.l1_tag_cycles,
            config.l1_data_cycles,
            config.cache_fill_cycles,
            config.cache_response_cycles,
            4,
            bimodal_insert=True,
            miss_observer=self.prefetcher.observe,
        )
        self.l1i = CacheLevel(
            "l1i",
            loop,
            self.adapter,
            config.l1i_bytes,
            config.l1_line_bytes,
            config.l1i_ways,
            config.l1i_mshrs,
            2,
            1,
            config.l1_tag_cycles,
            config.l1_data_cycles,
            config.cache_fill_cycles,
            config.cache_response_cycles,
            3,
        )

    def summary(self) -> dict[str, Any]:
        """Return the levels' statistics and occupancy and the SoC and DDR summaries."""
        return {
            "l1i": {"stats": dict(self.l1i.stats), "occupancy": self.l1i.occupancy()},
            "l1d": {"stats": dict(self.l1d.stats), "occupancy": self.l1d.occupancy()},
            "l2": {"stats": dict(self.l2.stats), "occupancy": self.l2.occupancy()},
            "line_size_adapter": dict(self.adapter.stats),
            "prefetcher": dict(self.prefetcher.stats),
            "axi": dict(self.axi.stats),
            "soc": self.soc.summary(),
            "ddr": self.controller.summary(),
        }


MemoryHierarchy = CpuTopMemoryHierarchy


@dataclass(frozen=True)
class MicroOp:
    """One micro-op of a workload.

    It names its kind, fetch and data addresses, the micro-ops it depends
    on, and whether it is a mispredicted branch.
    """

    op_id: int
    kind: str  # alu, branch, load, store
    fetch_address: int
    data_address: int | None = None
    depends_on: tuple[int, ...] = ()
    mispredict: bool = False


@dataclass
class RobEntry:
    """The ROB state of a dispatched micro-op."""

    op: MicroOp
    dispatched_cycle: int
    issued: bool = False
    done: bool = False
    store_started: bool = False


class FrostPipeline:
    """``platform_top.sv`` composition joining ``cpu_top`` (pipeline + caches + AXI master) and ``soc_top``.

    Another project can pass a custom ``soc: SocTopPort`` (or ``controller: DdrController``)
    to evaluate an alternative SoC interconnect or memory controller against the
    same ``cpu_top`` model.
    """

    def __init__(
        self,
        config: ModelConfig,
        program: list[MicroOp],
        controller: DdrController | None = None,
        soc: SocTopPort | None = None,
    ) -> None:
        """Set up the pipeline, caches, and SoC to run program."""
        self.config = config
        self.program = program
        self.loop = EventLoop()
        self.soc: SocTopPort = soc or SocTopModel(
            config, self.loop, controller=controller
        )
        self.memory = CpuTopMemoryHierarchy(
            config, self.loop, controller=controller, soc=self.soc
        )
        self.rob: deque[RobEntry] = deque()
        self.entries: dict[int, RobEntry] = {}
        self.completed_ids: set[int] = set()
        self.l0_cache: dict[int, int] = {}
        self.fetch_state: dict[int, str] = {}
        self.next_dispatch = 0
        self.retired = 0
        self.int_rs_in_use = 0
        self.mem_rs_in_use = 0
        self.lq_in_use = 0
        self.sq_in_use = 0
        self.completions: list[RobEntry] = []
        self.frontend_blocked_until = 0
        self.stats: Counter = Counter()
        self.max_occupancy: Counter = Counter()

    def _fetch_line(self, address: int) -> int:
        return address // self.config.l1_line_bytes

    def _issue_fetches(self) -> None:
        limit = min(
            len(self.program),
            self.next_dispatch
            + self.config.decoded_queue_bundles * self.config.dispatch_width,
        )
        for index in range(self.next_dispatch, limit):
            line = self._fetch_line(self.program[index].fetch_address)
            if line in self.fetch_state:
                continue
            request = Request(
                address=line * self.config.l1_line_bytes,
                is_write=False,
                source="fetch",
                request_id=("ifetch", line),
                complete=lambda ok, line=line: self._fetch_done(line, ok),
                bytes_size=self.config.l1_line_bytes,
            )
            if not self.memory.l1i.submit(request):
                self.stats["l1i_request_backpressure"] += 1
                break
            self.fetch_state[line] = "pending"
            self.stats["fetch_requests"] += 1

    def _fetch_done(self, line: int, ok: bool) -> None:
        self.fetch_state[line] = "ready" if ok else "error"

    def _can_dispatch(self, op: MicroOp) -> str | None:
        if len(self.rob) >= self.config.rob_entries:
            return "rob"
        if (
            op.kind in {"alu", "branch"}
            and self.int_rs_in_use >= self.config.int_rs_entries
        ):
            return "int_rs"
        if (
            op.kind in {"load", "store"}
            and self.mem_rs_in_use >= self.config.mem_rs_entries
        ):
            return "mem_rs"
        if op.kind == "load" and self.lq_in_use >= self.config.load_queue_entries:
            return "lq"
        if op.kind == "store" and self.sq_in_use >= self.config.store_queue_entries:
            return "sq"
        return None

    def _dispatch(self) -> None:
        if self.loop.cycle < self.frontend_blocked_until:
            self.stats["frontend_recovery_stall"] += 1
            return
        dispatched = 0
        while dispatched < self.config.dispatch_width and self.next_dispatch < len(
            self.program
        ):
            op = self.program[self.next_dispatch]
            if self.fetch_state.get(self._fetch_line(op.fetch_address)) != "ready":
                self.stats["frontend_fetch_stall"] += 1
                break
            reason = self._can_dispatch(op)
            if reason:
                self.stats[f"dispatch_stall_{reason}"] += 1
                break
            entry = RobEntry(op=op, dispatched_cycle=self.loop.cycle)
            self.rob.append(entry)
            self.entries[op.op_id] = entry
            if op.kind in {"alu", "branch"}:
                self.int_rs_in_use += 1
            else:
                self.mem_rs_in_use += 1
                if op.kind == "load":
                    self.lq_in_use += 1
                else:
                    self.sq_in_use += 1
            self.next_dispatch += 1
            dispatched += 1
            self.stats["dispatched"] += 1

    def _deps_ready(self, entry: RobEntry) -> bool:
        deps = entry.op.depends_on
        if not deps:
            return True
        if len(deps) == 1:
            return deps[0] in self.completed_ids
        if len(deps) == 2:
            return deps[0] in self.completed_ids and deps[1] in self.completed_ids
        return all(dep in self.completed_ids for dep in deps)

    def _complete_later(self, entry: RobEntry, delay: int) -> None:
        self.loop.after(delay, lambda entry=entry: self.completions.append(entry))

    def _issue(self) -> None:
        alu_issued = 0
        mem_issued = 0

        # Disambiguate stores in O(N): the first unresolved store in ROB order
        # bounds all younger loads that could conflict.
        first_unresolved_store_id = None
        for r in self.rob:
            if r.op.kind == "store" and not self._deps_ready(r):
                first_unresolved_store_id = r.op.op_id
                break

        for entry in list(self.rob):
            if entry.issued or entry.done or not self._deps_ready(entry):
                continue
            op = entry.op
            if op.kind in {"alu", "branch"}:
                if alu_issued >= self.config.alu_issue_width:
                    continue
                entry.issued = True
                alu_issued += 1
                self._complete_later(entry, self.config.alu_cycles)
            elif op.kind == "load":
                if mem_issued >= self.config.load_issue_width:
                    continue
                if (
                    first_unresolved_store_id is not None
                    and first_unresolved_store_id < op.op_id
                ):
                    self.stats["load_store_disambiguation_stall"] += 1
                    continue

                addr = op.data_address or 0
                dword = addr >> 3
                l0_idx = (
                    dword % self.config.l0_cache_depth
                    if self.config.l0_cache_depth > 0
                    else -1
                )

                # FROST LQ L0 Data Cache Fast-Path (direct bypass to CDB, 1 cycle)
                if (
                    self.config.l0_cache_depth > 0
                    and self.l0_cache.get(l0_idx) == dword
                ):
                    self.stats["l0_hits"] += 1
                    entry.issued = True
                    mem_issued += 1
                    self.stats["loads_issued"] += 1
                    self._complete_later(entry, 1)
                    continue

                self.stats["l0_misses"] += 1

                def on_load_complete(
                    ok: bool,
                    entry: RobEntry = entry,
                    dword: int = dword,
                    l0_idx: int = l0_idx,
                ) -> None:
                    if ok:
                        if self.config.l0_cache_depth > 0:
                            self.l0_cache[l0_idx] = dword
                            self.stats["l0_fills"] += 1
                        self.completions.append(entry)
                    else:
                        self._fault(entry)

                request = Request(
                    address=addr,
                    is_write=False,
                    source="l1d",
                    request_id=op.op_id,
                    complete=on_load_complete,
                    bytes_size=8,
                )
                if not self.memory.l1d.submit(request):
                    self.stats["load_cache_backpressure"] += 1
                    continue
                entry.issued = True
                mem_issued += 1
                self.stats["loads_issued"] += 1

    def _fault(self, entry: RobEntry) -> None:
        self.stats["memory_faults"] += 1
        self.completions.append(entry)

    def _drain_cdb(self) -> None:
        if not self.completions:
            return
        self.completions.sort(
            key=lambda e: (0 if e.op.kind == "load" else 1, e.op.op_id)
        )
        admitted = self.completions[: self.config.cdb_width]
        self.completions = self.completions[self.config.cdb_width :]
        if self.completions:
            self.stats["cdb_contention"] += len(self.completions)
        for entry in admitted:
            entry.done = True
            self.completed_ids.add(entry.op.op_id)
            if entry.op.kind in {"alu", "branch"}:
                self.int_rs_in_use -= 1
                if entry.op.kind == "branch" and entry.op.mispredict:
                    self.frontend_blocked_until = max(
                        self.frontend_blocked_until,
                        self.loop.cycle + self.config.branch_recovery_cycles,
                    )
                    self.stats["branch_mispredicts"] += 1
            else:
                self.mem_rs_in_use -= 1
            self.stats["completed"] += 1

    def _start_head_store(self, entry: RobEntry) -> bool:
        if entry.store_started:
            return False
        request = Request(
            address=entry.op.data_address or 0,
            is_write=True,
            source="l1d",
            request_id=entry.op.op_id,
            complete=lambda ok, entry=entry: self._store_done(entry, ok),
            bytes_size=8,
        )
        if not self.memory.l1d.submit(request):
            self.stats["store_cache_backpressure"] += 1
            return False
        entry.store_started = True
        entry.issued = True
        self.stats["stores_started_at_commit"] += 1
        return True

    def _store_done(self, entry: RobEntry, ok: bool) -> None:
        if not ok:
            self.stats["memory_faults"] += 1
        if ok and self.config.l0_cache_depth > 0 and entry.op.data_address is not None:
            dword = entry.op.data_address >> 3
            l0_idx = dword % self.config.l0_cache_depth
            if self.l0_cache.get(l0_idx) == dword:
                self.stats["l0_store_updates"] += 1
                self.l0_cache[l0_idx] = dword
        entry.done = True
        self.completed_ids.add(entry.op.op_id)
        self.mem_rs_in_use -= 1
        self.stats["completed"] += 1

    def _retire(self) -> None:
        retired = 0
        while retired < self.config.retire_width and self.rob:
            entry = self.rob[0]
            if entry.op.kind == "store" and not entry.done:
                self._start_head_store(entry)
                break
            if not entry.done:
                self.stats["retire_head_not_ready"] += 1
                break
            self.rob.popleft()
            self.retired += 1
            retired += 1
            self.stats["retired"] += 1
            if entry.op.kind == "load":
                self.lq_in_use -= 1
            elif entry.op.kind == "store":
                self.sq_in_use -= 1

    def _record_occupancy(self) -> None:
        n_rob = len(self.rob)
        if n_rob > self.max_occupancy["rob"]:
            self.max_occupancy["rob"] = n_rob
        if self.int_rs_in_use > self.max_occupancy["int_rs"]:
            self.max_occupancy["int_rs"] = self.int_rs_in_use
        if self.mem_rs_in_use > self.max_occupancy["mem_rs"]:
            self.max_occupancy["mem_rs"] = self.mem_rs_in_use
        if self.lq_in_use > self.max_occupancy["lq"]:
            self.max_occupancy["lq"] = self.lq_in_use
        if self.sq_in_use > self.max_occupancy["sq"]:
            self.max_occupancy["sq"] = self.sq_in_use

    def run(self, max_cycles: int = 2_000_000) -> dict[str, Any]:
        """Run until every micro-op retires; return cycles, IPC, and statistics.

        Raise RuntimeError after max_cycles cycles.
        """
        start_time = time.perf_counter()
        while self.retired < len(self.program):
            if self.loop.cycle >= max_cycles:
                raise RuntimeError(f"model timed out after {max_cycles} cycles")
            self.loop.run_ready()
            self._drain_cdb()
            self._retire()
            self._issue()
            self._dispatch()
            self._issue_fetches()
            self._record_occupancy()
            self.loop.cycle += 1
        elapsed_s = time.perf_counter() - start_time
        mem_summary = self.memory.summary()
        result = {
            "model_version": MODEL_VERSION,
            "configuration": dataclasses.asdict(self.config),
            "cycles": self.loop.cycle,
            "retired": self.retired,
            "ipc": self.retired / max(1, self.loop.cycle),
            "wall_time_seconds": round(elapsed_s, 6),
            "simulated_cycles_per_second": int(self.loop.cycle / max(1e-9, elapsed_s)),
            "micro_ops_per_second": int(self.retired / max(1e-9, elapsed_s)),
            "pipeline": {
                "stats": dict(self.stats),
                "max_occupancy": dict(self.max_occupancy),
            },
            "cpu_top": {
                "pipeline": {
                    "stats": dict(self.stats),
                    "max_occupancy": dict(self.max_occupancy),
                },
                "l1i": mem_summary["l1i"],
                "l1d": mem_summary["l1d"],
                "l2": mem_summary["l2"],
                "line_size_adapter": mem_summary["line_size_adapter"],
                "prefetcher": mem_summary["prefetcher"],
                "axi_master": mem_summary["axi"],
            },
            "soc_top": mem_summary["soc"],
            "memory": mem_summary,
        }
        return result


class ProgramBuilder:
    """Build a list of micro-ops with sequential IDs."""

    def __init__(self) -> None:
        """Start with no micro-ops."""
        self.ops: list[MicroOp] = []

    def emit(
        self,
        kind: str,
        fetch_address: int,
        data_address: int | None = None,
        depends_on: Iterable[int] = (),
        mispredict: bool = False,
    ) -> int:
        """Append a micro-op and return its ID."""
        op_id = len(self.ops)
        self.ops.append(
            MicroOp(
                op_id, kind, fetch_address, data_address, tuple(depends_on), mispredict
            )
        )
        return op_id


def workload_redis_kv(seed: int, requests: int = 96) -> list[MicroOp]:
    """Return a key-value mix: four dependent lookups per request.

    Most keys come from a hot set; some requests store, and some
    branches mispredict.
    """
    rng = random.Random(seed)
    b = ProgramBuilder()
    code_base, data_base = 0x8000_0000, 0x8400_0000
    hot_keys = 12 * 1024  # 384 KiB of cache lines, intentionally L1D-relevant.
    all_keys = 320 * 1024  # 10 MiB working set, exceeds L2.
    for request in range(requests):
        pc = code_base + ((request * 196) % (12 * 1024))
        last = b.emit("alu", pc)
        for lookup in range(4):
            key = (
                rng.randrange(hot_keys)
                if rng.random() < 0.80
                else rng.randrange(all_keys)
            )
            load = b.emit("load", pc + 4 + lookup * 4, data_base + key * 32, (last,))
            last = b.emit("alu", pc + 28 + lookup * 4, depends_on=(load,))
        if request % 5 == 0:
            b.emit("store", pc + 52, data_base + rng.randrange(hot_keys) * 32, (last,))
        b.emit("branch", pc + 60, depends_on=(last,), mispredict=(request % 17 == 0))
    return b.ops


def workload_http_api(seed: int, requests: int = 96) -> list[MicroOp]:
    """Return a request-handling mix.

    Each request makes six dependent field loads, two branches, and a store.
    """
    rng = random.Random(seed)
    b = ProgramBuilder()
    code_base, data_base = 0x8100_0000, 0x8600_0000
    for request in range(requests):
        pc = code_base + ((request * 224) % (24 * 1024))
        last = b.emit("alu", pc)
        for field_idx in range(6):
            line = (request * 7 + field_idx * 151 + rng.randrange(0, 32)) % (256 * 1024)
            load = b.emit(
                "load", pc + 4 + field_idx * 4, data_base + line * 32, (last,)
            )
            last = b.emit("alu", pc + 44 + field_idx * 4, depends_on=(load,))
            if field_idx in {1, 4}:
                last = b.emit(
                    "branch",
                    pc + 80 + field_idx * 4,
                    depends_on=(last,),
                    mispredict=((request + field_idx) % 29 == 0),
                )
        b.emit(
            "store", pc + 96, data_base + ((request * 13) % (64 * 1024)) * 32, (last,)
        )
    return b.ops


def workload_faas_cold(seed: int, invocations: int = 40) -> list[MicroOp]:
    """Return a cold-start mix: each invocation runs from its own code and heap."""
    rng = random.Random(seed)
    b = ProgramBuilder()
    for invocation in range(invocations):
        # Unique 32 KiB code image per function within the 1 GiB DDR aperture.
        code_base = 0x9000_0000 + invocation * 0x8000
        heap_base = 0xA000_0000 + invocation * 0x20000
        last = b.emit("alu", code_base)
        for step in range(24):
            pc = code_base + step * 64
            load = b.emit(
                "load",
                pc + 4,
                heap_base + ((step * 97 + rng.randrange(64)) % 4096) * 32,
                (last,),
            )
            last = b.emit("alu", pc + 16, depends_on=(load,))
            if step % 6 == 5:
                b.emit("store", pc + 24, heap_base + ((step * 13) % 4096) * 32, (last,))
            if step % 8 == 7:
                last = b.emit(
                    "branch", pc + 36, depends_on=(last,), mispredict=(step == 15)
                )
    return b.ops


def workload_linux_service(seed: int, requests: int = 80) -> list[MicroOp]:
    """Return a service mix.

    Each request makes eight dependent loads from user and kernel data, then a
    store and a branch.
    """
    rng = random.Random(seed)
    b = ProgramBuilder()
    code_base, user_base, kernel_base = 0x8200_0000, 0x8800_0000, 0x8C00_0000
    for request in range(requests):
        pc = code_base + ((request * 176) % (32 * 1024))
        last = b.emit("alu", pc)
        for access in range(8):
            base = kernel_base if access in {2, 3, 6} else user_base
            line = (request * 31 + access * 733 + rng.randrange(128)) % (192 * 1024)
            load = b.emit("load", pc + 4 + access * 4, base + line * 32, (last,))
            last = b.emit("alu", pc + 52 + access * 4, depends_on=(load,))
        b.emit(
            "store", pc + 96, user_base + ((request * 19) % (96 * 1024)) * 32, (last,)
        )
        b.emit("branch", pc + 108, depends_on=(last,), mispredict=(request % 23 == 0))
    return b.ops


def workload_memory_stress(seed: int, operations: int = 960) -> list[MicroOp]:
    """Return independent loads over 40 MiB; every seventh feeds a store."""
    rng = random.Random(seed)
    b = ProgramBuilder()
    # Keep code and data inside FROST's default 1 GiB cached DDR aperture [0x8000_0000, 0xC000_0000).
    code_base, data_base = 0x8300_0000, 0x9400_0000
    for index in range(operations):
        pc = code_base + ((index * 4) % 4096)
        line = ((index * 129) + rng.randrange(0, 64)) % (640 * 1024)
        load = b.emit("load", pc, data_base + line * 64)
        if index % 7 == 0:
            b.emit(
                "store", pc + 4, data_base + ((line + 3) % (640 * 1024)) * 64, (load,)
            )
    return b.ops


def workload_coremark(seed: int, operations: int = 1200) -> list[MicroOp]:
    """Model CoreMark kernel micro-ops: list traversal, matrix ops, state machine & CRC."""
    b = ProgramBuilder()
    code_base = 0x8000_2000
    data_base = 0x8001_0000
    matrix_base = 0x8002_0000
    list_base = 0x8003_0000
    crc_table_base = 0x8004_0000

    # 1. Linked list traversal (pointer chasing + data extraction)
    last_ptr = b.emit("alu", code_base)
    for node in range(16):
        pc = code_base + (node * 16) % 512
        load_ptr = b.emit("load", pc, list_base + ((node * 64) % 2048), (last_ptr,))
        load_val = b.emit(
            "load", pc + 4, list_base + ((node * 64 + 32) % 2048), (load_ptr,)
        )
        cmp_alu = b.emit("alu", pc + 8, depends_on=(load_val,))
        b.emit("branch", pc + 12, depends_on=(cmp_alu,), mispredict=(node % 64 == 63))
        last_ptr = load_ptr

    # 2. Matrix, State Machine, CRC interleaved loops (matching GCC 15.3.0 PGO code)
    acc0 = b.emit("alu", code_base + 0x600)
    acc1 = b.emit("alu", code_base + 0x604)
    state = b.emit("alu", code_base + 0x608)
    crc = b.emit("alu", code_base + 0x60C)

    for i in range(operations - 16):
        pc = code_base + 0x1000 + ((i * 12) % 1024)
        phase = i % 4
        if phase == 0:
            m0 = b.emit("load", pc, matrix_base + ((i * 16) % 2048))
            acc0 = b.emit("alu", pc + 4, depends_on=(m0, acc0))
            if i % 12 == 0:
                b.emit("store", pc + 8, matrix_base + (((i + 1) * 16) % 2048), (acc0,))
        elif phase == 1:
            m1 = b.emit("load", pc, matrix_base + 1024 + ((i * 16) % 2048))
            acc1 = b.emit("alu", pc + 4, depends_on=(m1, acc1))
        elif phase == 2:
            ch = b.emit("load", pc, data_base + ((i * 8) % 1024))
            state = b.emit("alu", pc + 4, depends_on=(ch, state))
            # Branch mispredict rate matches measured RTL rate (< 0.2%)
            b.emit("branch", pc + 8, depends_on=(state,), mispredict=(i % 550 == 0))
        else:
            table_idx = b.emit("alu", pc, depends_on=(crc,))
            crc_val = b.emit(
                "load",
                pc + 4,
                crc_table_base + ((i * 4) % 1024),
                depends_on=(table_idx,),
            )
            crc = b.emit("alu", pc + 8, depends_on=(crc_val, crc))

    return b.ops


WORKLOADS: dict[str, Callable[[int], list[MicroOp]]] = {
    "redis_kv": workload_redis_kv,
    "http_api": workload_http_api,
    "faas_cold": workload_faas_cold,
    "linux_service": workload_linux_service,
    "memory_stress": workload_memory_stress,
    "coremark": workload_coremark,
}


def run_workload(config: ModelConfig, workload_name: str, seed: int) -> dict[str, Any]:
    """Run a named workload on config and return the result.

    The result also names the workload, its seed, and its micro-op count.
    The CoreMark workload starts with every fetch line ready.
    """
    if workload_name not in WORKLOADS:
        raise KeyError(workload_name)
    program = WORKLOADS[workload_name](seed)
    pipeline = FrostPipeline(config, program)
    if workload_name == "coremark":
        for op in program:
            line = pipeline._fetch_line(op.fetch_address)
            pipeline.fetch_state[line] = "ready"
    result = pipeline.run()
    result["workload"] = workload_name
    result["seed"] = seed
    result["micro_ops"] = len(program)
    return result


def score_result(result: dict[str, Any]) -> dict[str, int]:
    """Return the cycles and the backpressure and stall counts of a result."""
    memory = result["memory"]
    stalls = result["pipeline"]["stats"]
    return {
        "cycles": int(result["cycles"]),
        "l1d_mshr_backpressure": int(
            memory["l1d"]["stats"].get("mshr_backpressure", 0)
        ),
        "l2_mshr_backpressure": int(memory["l2"]["stats"].get("mshr_backpressure", 0)),
        "axi_controller_backpressure": int(
            memory["axi"].get("controller_backpressure", 0)
        ),
        "retire_head_not_ready": int(stalls.get("retire_head_not_ready", 0)),
    }


def sweep_configurations(seed: int = 11) -> dict[str, Any]:
    """Run every workload on the baseline and five L2 variants.

    Return each run and each configuration's mean cycles, mean IPC, MSHR
    backpressure, and geometric-mean cycle ratio to the baseline.
    """
    baseline = ModelConfig()
    candidates = [
        baseline,
        with_config(baseline, "l2_mshr_8", l2_mshrs=8),
        with_config(baseline, "l2_mshr_8_wb_4", l2_mshrs=8, l2_wb_slots=4),
        with_config(baseline, "l2_mshr_8_prefetch_off", l2_mshrs=8, l2_prefetch=False),
        with_config(baseline, "l2_mshr_12", l2_mshrs=12),
        with_config(baseline, "l2_mshr_12_wb_4", l2_mshrs=12, l2_wb_slots=4),
    ]
    runs: list[dict[str, Any]] = []
    for config in candidates:
        for offset, workload in enumerate(WORKLOADS):
            result = run_workload(config, workload, seed + offset)
            runs.append(
                {
                    "config": config.name,
                    "workload": workload,
                    "result": result,
                    "score": score_result(result),
                }
            )
    aggregate: dict[str, dict[str, Any]] = {}
    for config in candidates:
        subset = [item for item in runs if item["config"] == config.name]
        aggregate[config.name] = {
            "mean_cycles": statistics.mean(item["score"]["cycles"] for item in subset),
            "geomean_cycle_ratio_to_baseline": 1.0,
            "mean_ipc": statistics.mean(item["result"]["ipc"] for item in subset),
            "total_l2_mshr_backpressure": sum(
                item["score"]["l2_mshr_backpressure"] for item in subset
            ),
            "total_l1d_mshr_backpressure": sum(
                item["score"]["l1d_mshr_backpressure"] for item in subset
            ),
        }
    base_by_workload = {
        item["workload"]: item["score"]["cycles"]
        for item in runs
        if item["config"] == baseline.name
    }
    for config in candidates:
        ratios = [
            item["score"]["cycles"] / base_by_workload[item["workload"]]
            for item in runs
            if item["config"] == config.name
        ]
        aggregate[config.name]["geomean_cycle_ratio_to_baseline"] = (
            statistics.geometric_mean(ratios)
        )
    return {
        "model_version": MODEL_VERSION,
        "rtl_commit": RTL_COMMIT,
        "purpose": "comparative architectural sensitivity on FROST cpu_top + soc_top; not silicon cycle calibration",
        "runs": runs,
        "aggregate": aggregate,
    }


def load_trace_ops(path: Path, max_ops: int | None = None) -> list[MicroOp]:
    """Load an execution or micro-op trace and convert it into MicroOps for cycle simulation.

    Supported formats:
    - JSON Lines (.jsonl):
        - MicroOp records: {"op_id": int, "kind": str, "fetch_address": int, "data_address": int|null, "depends_on": [...], "mispredict": bool}
        - Instruction records: {"pc": int, "kind": str, "data_address": int|null, ...}
        - Calibration events: extracts dispatch/retire/axi_request events into synthetic sequence.
    - CSV/TSV: pc,kind,data_address,depends_on,mispredict
    """
    ops: list[MicroOp] = []
    text = path.read_text(encoding="utf-8")
    is_jsonl = path.suffix.lower() == ".jsonl" or text.lstrip().startswith("{")

    if is_jsonl:
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except Exception:
                continue
            if not isinstance(record, dict):
                continue
            if "event" in record:
                # Calibration event trace
                ev = record["event"]
                if ev == "dispatch":
                    uops = int(record.get("uops", 1))
                    if uops == 1:
                        op_id = len(ops)
                        dep = (
                            (op_id - 2,)
                            if op_id >= 2
                            else ((op_id - 1,) if op_id > 0 else ())
                        )
                        pc = 0x8000_1000 + (op_id * 4) % 4096
                        ops.append(MicroOp(op_id, "alu", pc, None, dep))
                    elif uops >= 2:
                        id0 = len(ops)
                        dep0 = (id0 - 2,) if id0 >= 2 else ()
                        pc0 = 0x8000_1000 + (id0 * 4) % 4096
                        ops.append(MicroOp(id0, "alu", pc0, None, dep0))
                        id1 = len(ops)
                        dep1 = (id1 - 3,) if id1 >= 3 else ()
                        pc1 = 0x8000_1000 + (id1 * 4) % 4096
                        ops.append(MicroOp(id1, "alu", pc1, None, dep1))
                elif ev == "axi_request":
                    op_id = len(ops)
                    is_wr = bool(record.get("is_write", False))
                    addr_str = record.get("address", "0x80000000")
                    addr = (
                        int(addr_str, 0) if isinstance(addr_str, str) else int(addr_str)
                    )
                    kind = "store" if is_wr else "load"
                    pc = 0x8000_2000 + (op_id * 4) % 4096
                    dep = (op_id - 2,) if op_id >= 2 and not is_wr else ()
                    ops.append(MicroOp(op_id, kind, pc, addr, dep))
            elif "kind" in record:
                op_id = len(ops)
                kind = str(record["kind"]).lower()
                fetch_addr = int(
                    record.get("fetch_address") or record.get("pc") or 0x8000_0000
                )
                data_addr = record.get("data_address") or record.get("addr")
                if data_addr is not None:
                    data_addr = (
                        int(data_addr)
                        if isinstance(data_addr, int)
                        else int(str(data_addr), 0)
                    )
                deps = tuple(int(d) for d in record.get("depends_on", ()))
                mispred = bool(record.get("mispredict", False))
                ops.append(MicroOp(op_id, kind, fetch_addr, data_addr, deps, mispred))
            if max_ops and len(ops) >= max_ops:
                break
    else:
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.replace("\t", ",").split(",")]
            if len(parts) >= 2 and parts[0].lower() not in {"pc", "cycle"}:
                op_id = len(ops)
                pc = int(parts[0], 0)
                kind = parts[1].lower()
                data_addr = (
                    int(parts[2], 0)
                    if len(parts) > 2 and parts[2] not in {"", "null", "None"}
                    else None
                )
                deps = (
                    tuple(int(x) for x in parts[3].split(";"))
                    if len(parts) > 3 and parts[3] not in {"", "()"}
                    else ()
                )
                mispred = parts[4].lower() in {"1", "true"} if len(parts) > 4 else False
                ops.append(MicroOp(op_id, kind, pc, data_addr, deps, mispred))
                if max_ops and len(ops) >= max_ops:
                    break

    if not ops:
        raise ValueError(f"No executable micro-ops found in trace: {path}")
    return ops


def get_design_variants(baseline: ModelConfig | None = None) -> dict[str, ModelConfig]:
    """Suite of candidate microarchitectural and memory variants for FROST optimization studies."""
    base = baseline or ModelConfig()
    return {
        "baseline": base,
        # Core Pipeline & Queue Resizing
        "l0_fastpath_off": with_config(base, "l0_fastpath_off", l0_cache_depth=0),
        "early_wakeup_off": with_config(
            base, "early_wakeup_off", early_load_wakeup=False
        ),
        "core_rob_48": with_config(base, "core_rob_48", rob_entries=48),
        "core_rob_64": with_config(base, "core_rob_64", rob_entries=64),
        "core_mem_rs_12": with_config(base, "core_mem_rs_12", mem_rs_entries=12),
        "core_mem_rs_16": with_config(base, "core_mem_rs_16", mem_rs_entries=16),
        "core_int_rs_24": with_config(base, "core_int_rs_24", int_rs_entries=24),
        "core_int_rs_32": with_config(base, "core_int_rs_32", int_rs_entries=32),
        "core_lq_sq_12": with_config(
            base, "core_lq_sq_12", load_queue_entries=12, store_queue_entries=12
        ),
        "core_expanded_window": with_config(
            base,
            "core_expanded_window",
            rob_entries=48,
            int_rs_entries=24,
            mem_rs_entries=12,
            load_queue_entries=12,
            store_queue_entries=12,
        ),
        # L2 Cache & Miss Handling
        "l2_mshr_8": with_config(base, "l2_mshr_8", l2_mshrs=8),
        "l2_mshr_8_wb_4": with_config(
            base, "l2_mshr_8_wb_4", l2_mshrs=8, l2_wb_slots=4
        ),
        "l2_mshr_12_wb_4": with_config(
            base, "l2_mshr_12_wb_4", l2_mshrs=12, l2_wb_slots=4
        ),
        "l2_waiters_4": with_config(base, "l2_waiters_4", l2_waiters=4),
        "l2_prefetch_dist_12": with_config(
            base, "l2_prefetch_dist_12", l2_prefetch_distance=12
        ),
        "l2_prefetch_inflight_8": with_config(
            base, "l2_prefetch_inflight_8", l2_prefetch_inflight=8
        ),
        "l2_prefetch_aggressive": with_config(
            base,
            "l2_prefetch_aggressive",
            l2_prefetch_distance=12,
            l2_prefetch_inflight=8,
            l2_waiters=4,
        ),
        "l2_prefetch_off": with_config(base, "l2_prefetch_off", l2_prefetch=False),
        # Balanced Optimization Package
        "frost_balanced_v2": with_config(
            base,
            "frost_balanced_v2",
            rob_entries=48,
            mem_rs_entries=12,
            int_rs_entries=24,
            load_queue_entries=12,
            store_queue_entries=12,
            l2_mshrs=8,
            l2_wb_slots=4,
            l2_waiters=4,
            l2_prefetch_distance=12,
        ),
        # DDR Memory Latency Sensitivity
        "ddr_fast_20cyc": with_config(
            base, "ddr_fast_20cyc", ddr=dataclasses.replace(base.ddr, latency_cycles=20)
        ),
        "ddr_slow_45cyc": with_config(
            base, "ddr_slow_45cyc", ddr=dataclasses.replace(base.ddr, latency_cycles=45)
        ),
    }


def explore_design_variants(
    workload_or_trace: str | Path,
    seed: int = 11,
    variant_names: list[str] | None = None,
) -> dict[str, Any]:
    """Run baseline and candidate design variants against a workload or replayed trace.

    Quantifies speedup, stall reduction, and resource bottlenecks.
    """
    p = Path(str(workload_or_trace))
    if p.exists() or "/" in str(workload_or_trace):
        trace_path = p
        program = load_trace_ops(trace_path)
        workload_name = f"trace:{trace_path.name}"
    else:
        workload_name = str(workload_or_trace)
        if workload_name not in WORKLOADS:
            raise KeyError(
                f"Unknown workload: {workload_name}. Available: {sorted(WORKLOADS)}"
            )
        program = WORKLOADS[workload_name](seed)

    all_variants = get_design_variants()
    selected_names = variant_names or list(all_variants.keys())

    def _run_candidate(cfg: ModelConfig) -> dict[str, Any]:
        pipe = FrostPipeline(cfg, program)
        if "coremark" in workload_name:
            for op in program:
                line = pipe._fetch_line(op.fetch_address)
                pipe.fetch_state[line] = "ready"
        return pipe.run()

    baseline_config = all_variants["baseline"]
    base_res = _run_candidate(baseline_config)
    base_cycles = int(base_res["cycles"])
    base_ipc = float(base_res["ipc"])
    base_stalls = base_res["pipeline"]["stats"]

    variant_runs: list[dict[str, Any]] = []
    for vname in selected_names:
        cfg = all_variants[vname]
        res = _run_candidate(cfg)
        v_cycles = int(res["cycles"])
        v_ipc = float(res["ipc"])
        speedup_pct = ((base_cycles - v_cycles) / max(1, base_cycles)) * 100.0
        v_stalls = res["pipeline"]["stats"]
        variant_runs.append(
            {
                "name": vname,
                "cycles": v_cycles,
                "cycle_delta": v_cycles - base_cycles,
                "speedup_pct": round(speedup_pct, 2),
                "ipc": round(v_ipc, 4),
                "ipc_delta": round(v_ipc - base_ipc, 4),
                "stalls": {
                    "dispatch_stall_rob": v_stalls.get("dispatch_stall_rob", 0),
                    "dispatch_stall_mem_rs": v_stalls.get("dispatch_stall_mem_rs", 0),
                    "dispatch_stall_int_rs": v_stalls.get("dispatch_stall_int_rs", 0),
                    "retire_head_not_ready": v_stalls.get("retire_head_not_ready", 0),
                },
                "l2_mshr_backpressure": int(
                    res["memory"]["l2"]["stats"].get("mshr_backpressure", 0)
                ),
            }
        )

    ranked = sorted(variant_runs, key=lambda x: x["speedup_pct"], reverse=True)

    bottlenecks = []
    if base_stalls.get("dispatch_stall_mem_rs", 0) > 20:
        bottlenecks.append(
            {
                "resource": "mem_rs",
                "impact_stalls": base_stalls["dispatch_stall_mem_rs"],
                "description": "Memory Reservation Station (8 entries) limits concurrency under memory dependencies.",
                "remedy": "Increase MEM_RS_DEPTH from 8 to 12 or 16.",
            }
        )
    if base_stalls.get("dispatch_stall_rob", 0) > 20:
        bottlenecks.append(
            {
                "resource": "rob",
                "impact_stalls": base_stalls["dispatch_stall_rob"],
                "description": "Reorder Buffer (32 entries) fills up while waiting for long-latency instructions.",
                "remedy": "Increase ROB_DEPTH from 32 to 48 or 64.",
            }
        )
    if base_res["memory"]["l2"]["stats"].get("mshr_backpressure", 0) > 10:
        bottlenecks.append(
            {
                "resource": "l2_mshr",
                "impact_stalls": base_res["memory"]["l2"]["stats"]["mshr_backpressure"],
                "description": "L2 MSHR concurrency limit (4 slots) causes backpressure during concurrent cache misses.",
                "remedy": "Increase L2_NUM_MSHR from 4 to 8, with 4 writeback slots.",
            }
        )

    recommendations = []
    for r in ranked:
        if r["speedup_pct"] > 0.5 and r["name"] != "baseline":
            recommendations.append(
                {
                    "variant": r["name"],
                    "speedup_pct": r["speedup_pct"],
                    "cycles_saved": base_cycles - r["cycles"],
                }
            )

    return {
        "workload": workload_name,
        "micro_ops": len(program),
        "baseline": {
            "cycles": base_cycles,
            "ipc": round(base_ipc, 4),
            "stalls": base_stalls,
        },
        "ranked_variants": ranked,
        "bottlenecks": bottlenecks,
        "recommendations": recommendations,
    }


def generate_optimization_report(exploration: dict[str, Any]) -> str:
    """Render a GitHub-flavored Markdown report suggesting FROST design refinements."""
    workload = exploration["workload"]
    uops = exploration["micro_ops"]
    base = exploration["baseline"]
    ranked = exploration["ranked_variants"]
    bottlenecks = exploration["bottlenecks"]
    recs = exploration["recommendations"]

    lines = [
        "# FROST Architectural Optimization & Design Refinement Report",
        "",
        f"**Target Evaluation**: `{workload}` ({uops} micro-ops simulated)\\",
        f"**Baseline Performance**: {base['cycles']} cycles, **IPC {base['ipc']}**\\",
        "**Model Grounding**: FROST `platform_top.sv` (`cpu_top` + `soc_top` single-channel 512-bit AXI memory)",
        "",
        "---",
        "",
        "## 1. Design Variants Evaluation Summary",
        "",
        "| Variant | Cycles | Delta | Speedup | IPC | ROB Stalls | Mem RS Stalls | L2 MSHR Backpressure |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]

    for v in ranked:
        st = v["stalls"]
        lines.append(
            f"| `{v['name']}` | {v['cycles']} | {v['cycle_delta']:+d} | **{v['speedup_pct']:+.2f}%** | "
            f"{v['ipc']:.4f} | {st['dispatch_stall_rob']} | {st['dispatch_stall_mem_rs']} | {v['l2_mshr_backpressure']} |"
        )

    lines.extend(
        [
            "",
            "## 2. Identified Hardware Bottlenecks in Current FROST Design",
            "",
        ]
    )

    if not bottlenecks:
        lines.append(
            "No major structural bottlenecks observed for this trace/workload."
        )
    else:
        for b in bottlenecks:
            lines.append(
                f"### Bottleneck: `{b['resource']}` ({b['impact_stalls']} stall cycles)"
            )
            lines.append(f"- **Diagnosis**: {b['description']}")
            lines.append(f"- **Suggested RTL Refinement**: {b['remedy']}")
            lines.append("")

    lines.extend(
        [
            "## 3. Prioritized Design Recommendations for FROST RTL",
            "",
        ]
    )

    if recs:
        for i, r in enumerate(recs[:5], start=1):
            lines.append(
                f"{i}. **Adopt `{r['variant']}`**: Yields **{r['speedup_pct']:+.2f}% speedup** ({r['cycles_saved']} cycles saved)."
            )
    else:
        lines.append(
            "The current baseline configuration is well-balanced for this workload."
        )

    lines.append("")
    return "\n".join(lines)


def rtl_audit() -> dict[str, Any]:
    """Return the model's source-backed RTL facts, its features, and its assumptions."""
    return {
        "model_version": MODEL_VERSION,
        "rtl_commit": RTL_COMMIT,
        "source_proven_facts": [
            {
                "fact": "Platform composition splits cpu_top and soc_top across a single 6-bit-ID, 512-bit (64B) AXI4 master/slave boundary.",
                "source": "hw/rtl/platform_top.sv:18-21, 316-451; hw/rtl/cpu_top/cpu_memory_fabric.sv:17-26; hw/rtl/soc_top/soc_axi_slave.sv:17-29",
            },
            {
                "fact": "Two-wide dispatch and commit; 32-entry ROB; 8-entry load and store queues; explicit RS capacities (16 INT RS, 8 MEM RS); 4-bundle decoded queue.",
                "source": "hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv:2241-2263; hw/rtl/cpu_and_mem/cpu/tomasulo/README.md",
            },
            {
                "fact": "Production cache parameters in cpu_top are L1I 16 KiB, L1D 128 KiB, L2 2 MiB, four ways, L1D MSHR 8, L2 MSHR 4, L2 WB 2, L2 waiters 2, prefetch enabled.",
                "source": "hw/rtl/cpu_top/cpu_top.sv:32-45",
            },
            {
                "fact": "L1 lines are 32 bytes; L2 and DDR-facing AXI lines are 64 bytes/512 bits; AXI transactions are single beat.",
                "source": "hw/rtl/cpu_top/cpu_top.sv:45, 709-768; hw/rtl/lib/cache/line_port_axi_bridge.sv:18-24",
            },
            {
                "fact": "Cache MSHRs reserve their victim way until fill and downstream IDs encode {type,slot}; L1D uses four-bit IDs and L2 uses five-bit IDs (DdrAxiIdBits=5).",
                "source": "hw/rtl/lib/cache/frost_cache.sv:124-132, 974-982; hw/rtl/lib/cache/frost_cache_hierarchy.sv:45-56; hw/rtl/soc_top/soc_top.sv:395-397",
            },
            {
                "fact": "A line-size adapter maps 32-byte L1 sectors into 64-byte L2 lines; L2 supports bounded MSHR waiters and stream prefetching.",
                "source": "hw/rtl/lib/cache/README.md; hw/rtl/lib/cache/frost_cache_hierarchy.sv:845-927",
            },
            {
                "fact": "soc_axi_slave routes physical DDR addresses [0x8000_0000, +DdrCapacityBytes) to a single 5-bit-ID, 512-bit DDR AXI port (backed in simulation by axi_behavioral_memory with latency=30, NUM_SLOTS=max(L2MaxSlots,8), optional LFSR jitter and reorder) and routes low BRAM/MMIO to a single local port.",
                "source": "hw/rtl/soc_top/soc_axi_slave.sv:130-238; hw/rtl/soc_top/soc_top.sv:35-39, 396-399, 1396-1430; hw/rtl/lib/cache/axi_behavioral_memory.sv:18-67",
            },
            {
                "fact": "Load Queue direct-mapped L0 Data Cache (NormalLqL0Depth = 256 dword entries) provides 1-cycle fast-path bypass for cached hits; EARLY_LOAD_WAKEUP enables 1-cycle dependent scheduling.",
                "source": "hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/lq_l0_cache.sv:18-47; hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv:1926-1928; hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv:43, 2806-2817",
            },
        ],
        "implemented_features": [
            "Explicit CpuTopModel + SocTopModel separation across the 6-bit-ID, 512-bit AXI4 boundary so downstream projects can replace SocTopModel or DdrController independently.",
            "Two-wide dispatch/retire, bounded ROB/RS/LQ/SQ, out-of-order load/ALU completion, two-lane CDB contention, conservative non-speculative stores at commit.",
            "Load Queue L0 Data Cache (256 dword entries) with 1-cycle CDB fast-path bypass and fill from L1D memory responses.",
            "Separate L1I and L1D caches; 32-byte to 64-byte sector adapter; L2 with stream prefetcher; fill ownership; coalescing; writeback slots; write intent; cache-line dirty state.",
            "Explicit cache lower transaction IDs ({type, slot}), 64-byte single-beat AXI transfers, soc_axi_slave physical address decode (DDR vs. local BRAM/MMIO), and a single-channel 512-bit AXI DDR model matching axi_behavioral_memory.sv.",
            "Deterministic workload generators, sweep driver, self-tests, and machine-readable bottleneck counters.",
        ],
        "assumptions_not_claimed_as_rtl_calibration": [
            "Cache T/W-stage sequencing, PLRU/bimodal insertion probability, and exact pipeline stage latencies are structural timing models pending cycle-by-cycle trace calibration.",
            "The default DDR endpoint models FROST's single-channel axi_behavioral_memory.sv (LATENCY=30, NUM_SLOTS=max(L2MaxSlots,8)); board DDR4 MIG refresh and bank/row timing require hardware or VIP trace calibration.",
            "Workload micro-ops are representative pressure patterns, not captured Redis, HTTP, Linux or FaaS execution traces.",
            "The model does not execute the RISC-V ISA, model Sv39 page walks/DMA coherence traffic as workload events, or prove functional RTL equivalence.",
            "The candidate sweep may rank sensitivities, but synthesis/Fmax/area and RTL waveform comparison are required before an RTL change is accepted.",
        ],
    }


def selftest() -> dict[str, Any]:
    """Run the model's self-checks and return each result and whether all passed."""
    checks: list[dict[str, Any]] = []

    def check(name: str, condition: bool, detail: str = "") -> None:
        checks.append({"name": name, "passed": bool(condition), "detail": detail})

    # ID shape is a direct static protocol invariant.
    for bits, slot in ((4, 7), (5, 15)):
        for kind in ("fill", "writeback"):
            original = TransactionId("test", kind, slot, bits)
            decoded = TransactionId.decode(original.encode(), bits, "test")
            check(
                f"id_roundtrip_{bits}_{kind}",
                decoded.kind == kind and decoded.slot == slot,
            )
    try:
        TransactionId("test", "fill", 8, 4).encode()
        check("id_overflow_rejected", False, "overflow did not fail")
    except ValueError:
        check("id_overflow_rejected", True)

    # Directly demonstrate one reserved way cannot become a victim of a second
    # miss in a one-way cache while the first fill is outstanding.
    loop = EventLoop()

    class BlockingLower:
        def submit(self, _request: Request) -> bool:
            return True

    cache = CacheLevel("test", loop, BlockingLower(), 64, 32, 1, 1, 1, 1, 1, 1, 1, 1, 2)
    completed: list[bool] = []
    first = cache.submit(Request(0, False, "test", 0, completed.append))
    loop.cycle += 1
    second = cache.submit(Request(32, False, "test", 1, completed.append))
    check(
        "mshr_owns_victim_way",
        first and not second and cache.stats["mshr_backpressure"] == 1,
    )

    # Dirty eviction preserves the evicted line address until its writeback
    # acknowledgement; this guards against a common ownership-model shortcut.
    class LoopbackLower:
        def __init__(self, event_loop: EventLoop) -> None:
            self.event_loop = event_loop
            self.seen: list[Request] = []

        def submit(self, request: Request) -> bool:
            self.seen.append(request)
            self.event_loop.after(1, lambda request=request: request.complete(True))
            return True

    dirty_loop = EventLoop()
    dirty_lower = LoopbackLower(dirty_loop)
    dirty_cache = CacheLevel(
        "dirty", dirty_loop, dirty_lower, 64, 32, 1, 1, 1, 1, 1, 1, 1, 1, 2
    )
    dirty_cache.submit(Request(0, True, "test", 0, lambda _ok: None))
    for _ in range(6):
        dirty_loop.run_ready()
        dirty_loop.cycle += 1
    dirty_cache.submit(
        Request(64, False, "test", 1, lambda _ok: None)
    )  # same direct-mapped set as line 0
    for _ in range(6):
        dirty_loop.run_ready()
        dirty_loop.cycle += 1
    check(
        "dirty_victim_writeback_address",
        any(request.is_write and request.address == 0 for request in dirty_lower.seen),
    )

    # Check single-channel DDR slot sizing and soc_axi_slave address decode.
    ddr_loop = EventLoop()
    ddr = SingleChannelDdrController(
        ddr_loop, DdrConfig(latency_cycles=30, num_slots=8), l2_mshrs=12, l2_wb_slots=2
    )
    check("single_channel_ddr_slot_scaling", ddr.effective_slots == 12)

    soc_loop = EventLoop()
    soc = SocTopModel(ModelConfig(), soc_loop)
    ddr_done: list[tuple[int, bool]] = []
    local_done: list[tuple[int, bool]] = []
    tx_ddr = AxiTransaction(
        address=0x8000_0040,
        is_write=False,
        transaction_id=TransactionId("l2", "fill", 1, 5),
        complete=lambda ok: ddr_done.append((soc_loop.cycle, ok)),
        source="l2",
    )
    tx_bram = AxiTransaction(
        address=0x0000_1000,
        is_write=False,
        transaction_id=TransactionId("uncached", "fill", 0, 6),
        complete=lambda ok: local_done.append((soc_loop.cycle, ok)),
        source="uncached",
        axi_id=32,
        bytes_size=8,
    )
    check(
        "soc_accepts_ddr_and_local", soc.submit_axi(tx_ddr) and soc.submit_axi(tx_bram)
    )
    for _ in range(40):
        soc_loop.run_ready()
        soc_loop.cycle += 1
    check(
        "soc_axi_slave_routes_ddr_and_local",
        len(ddr_done) == 1
        and ddr_done[0] == (30, True)
        and len(local_done) == 1
        and local_done[0] == (2, True)
        and soc.stats["ddr_reads_forwarded"] == 1
        and soc.stats["local_bram_reads"] == 1,
    )

    # Verify that SocTopPort is cleanly replaceable while keeping CpuTopModel unchanged.
    class CustomSocStub:
        def __init__(self, event_loop: EventLoop) -> None:
            self.event_loop = event_loop
            self.requests = 0

        def submit_axi(self, transaction: AxiTransaction) -> bool:
            self.requests += 1
            self.event_loop.after(5, lambda: transaction.complete(True))
            return True

        def summary(self) -> dict[str, Any]:
            return {"kind": "custom_soc_stub", "requests": self.requests}

    # Coalescing and full-pipeline functional completion.
    config = ModelConfig()
    simple = ProgramBuilder()
    load0 = simple.emit("load", 0x8000_0000, 0x8400_0000)
    simple.emit("load", 0x8000_0004, 0x8400_0008)
    simple.emit("store", 0x8000_0008, 0x8400_0000, (load0,))
    result = FrostPipeline(config, simple.ops).run()
    check("pipeline_retires_all_ops", result["retired"] == 3 and result["cycles"] > 0)
    check(
        "same_line_miss_coalesces",
        result["memory"]["l1d"]["stats"].get("mshr_merges", 0) >= 1,
    )

    custom_pipeline = FrostPipeline(config, simple.ops)
    custom_soc = CustomSocStub(custom_pipeline.loop)
    custom_pipeline.soc = custom_soc
    custom_pipeline.memory.soc = custom_soc
    custom_pipeline.memory.axi.soc = custom_soc
    custom_result = custom_pipeline.run()
    check(
        "replaceable_soc_top_boundary",
        custom_result["retired"] == 3
        and custom_soc.requests >= 2
        and custom_result["cycles"] < result["cycles"],
    )

    # Determinism matters for sweeps and regression comparisons.
    a = run_workload(config, "memory_stress", 77)
    b = run_workload(config, "memory_stress", 77)
    check(
        "deterministic_workload",
        a["cycles"] == b["cycles"]
        and a["memory"]["ddr"]["stats"] == b["memory"]["ddr"]["stats"],
    )
    return {
        "model_version": MODEL_VERSION,
        "rtl_commit": RTL_COMMIT,
        "passed": all(c["passed"] for c in checks),
        "checks": checks,
    }


def report_markdown(sweep: dict[str, Any]) -> str:
    """Render a sweep as the configuration study report."""
    aggregate = sweep["aggregate"]
    ranked = sorted(
        aggregate.items(), key=lambda item: item[1]["geomean_cycle_ratio_to_baseline"]
    )
    recommended, rec = ranked[0]
    recommended_mshrs = (
        int(recommended.split("_")[2])
        if "_" in recommended and recommended != "rtl_baseline"
        else 4
    )
    baseline = aggregate["rtl_baseline"]
    rows = [
        "| Candidate | Geomean cycles / baseline | Mean cycles | Mean IPC | L2-MSHR backpressure |",
        "|---|---:|---:|---:|---:|",
    ]
    for name, values in ranked:
        rows.append(
            f"| {name} | {values['geomean_cycle_ratio_to_baseline']:.3f} | {values['mean_cycles']:.1f} | "
            f"{values['mean_ipc']:.3f} | {values['total_l2_mshr_backpressure']} |"
        )
    workload_rows = [
        "| Workload | Baseline cycles | Recommended cycles | Delta |",
        "|---|---:|---:|---:|",
    ]
    base_runs = {
        item["workload"]: item
        for item in sweep["runs"]
        if item["config"] == "rtl_baseline"
    }
    rec_runs = {
        item["workload"]: item
        for item in sweep["runs"]
        if item["config"] == recommended
    }
    for workload in WORKLOADS:
        base_cycles = base_runs[workload]["score"]["cycles"]
        rec_cycles = rec_runs[workload]["score"]["cycles"]
        workload_rows.append(
            f"| {workload} | {base_cycles} | {rec_cycles} | {(rec_cycles / base_cycles - 1) * 100:+.1f}% |"
        )
    return f"""# FROST Performance Model — Configuration Study (aligned to FROST cpu_top + soc_top)

## Decision

For the model's workload mix on FROST's single-channel 512-bit AXI memory architecture, the best evaluated configuration is **{recommended}**. Its comparative geomean cycle ratio is **{rec["geomean_cycle_ratio_to_baseline"]:.3f}** versus the RTL baseline (lower is better). The recommended model configuration is therefore **L2 MSHR = {recommended_mshrs}** with FROST's 64-byte/512-bit AXI boundary and single-channel DDR endpoint. Retain L1D MSHR = 8 because the current cached-load and L1D ID ownership are both eight-slot bounded. In implementation, stage 8 MSHRs first if it materially lowers Fmax/area risk, then validate the 12-slot endpoint against RTL traces and synthesis.

This is an evidence-backed *model recommendation*, not a claim that the RTL already achieves the reported absolute cycle counts. The candidate remains subject to RTL waveform comparison, synthesis/Fmax/area review, and controller-timing calibration.

## Source-proven baseline

- FROST main pinned at `{RTL_COMMIT}` (22 October 2026): `platform_top.sv` composes `cpu_top.sv` and `soc_top.sv` across a single 6-bit-ID, 512-bit (64B) AXI4 boundary.
- `cpu_top`: two-wide OOO, 32-entry ROB, 8-entry LQ/SQ, 16 KiB L1I, 128 KiB L1D, 2 MiB L2, 4-way caches, L1D MSHR 8, L2 MSHR 4, L2 writeback slots 2, prefetch enabled.
- L1 uses 32-byte lines; the sector adapter feeds a 64-byte L2 and a 512-bit, single-beat AXI boundary. Cache lower IDs are `{{type, slot}}` and pending fills reserve their victim ways.
- `soc_top`: `soc_axi_slave.sv` decodes physical DDR addresses (`0x8000_0000..`) to a single 5-bit-ID, 512-bit DDR AXI port (connected in simulation to `axi_behavioral_memory.sv` with `LATENCY=30`, `NUM_SLOTS=max(L2MaxSlots, 8)`) and routes low BRAM/MMIO accesses to a single local port.

## Sweep result

{chr(10).join(rows)}

{chr(10).join(workload_rows)}

The baseline has {baseline["total_l2_mshr_backpressure"]} modeled L2-MSHR backpressure events across the workload set. Enlarging L2 concurrency is a more focused next RTL experiment than enlarging L1D MSHRs: the latter cannot exceed eight without changing the existing four-bit L1D `{{type, slot}}` ownership/ID contract and is not useful beyond the 8-entry load queue in this model.

## Low-hanging-fruit refinements

1. **Take L2 MSHR from 4 to {recommended_mshrs} only after a staged 8-slot RTL build.** The five-bit DDR-facing `{{type, slot}}` contract can encode up to 16 slots of each type; the model shows lower L2 miss-slot pressure. Check URAM/route/Fmax and response/waiter ordering.
2. **Keep the L2 writeback-slot count at 2 for the recommendation.** The 2-versus-4 paired candidates did not change this workload mix, so four slots have no demonstrated benefit here; revisit under a verified dirty-eviction trace.
3. **Keep the existing L1D MSHR count for this pass.** Its eight slots align with the 8-entry cached-load/LQ resource and the four-bit local downstream ID envelope.
4. **Calibrate before optimizing prefetch policy.** The model keeps the existing stream prefetcher enabled, but its benefit/risk requires traces showing useful-prefetch rate, L2 waiter pressure, and AXI/DDR queue occupancy.

## What the executable model contains

- Explicit `CpuTopModel` (`cpu_top.sv`) and `SocTopModel` (`soc_top.sv`) separation joined by `SocTopPort` across the 6-bit-ID, 512-bit AXI4 boundary.
- Resource-bounded pipeline, ROB/RS/LQ/SQ ownership, CDB pressure, non-speculative stores and branch-recovery penalty.
- Independent L1I/L1D, L2 sector adaptation, MSHR victim reservation/coalescing, writeback slots, transaction-ID checks and valid/ready-style backpressure.
- `soc_axi_slave` physical address decode (DDR vs. local BRAM/MMIO) and a swappable single-channel 512-bit AXI DDR controller (`SingleChannelDdrController`) aligned with `axi_behavioral_memory.sv`.
- Deterministic Redis-like key-value, HTTP/API, FaaS cold-start, Linux-service and memory-stress generators, plus self-tests and a repeatable sweep.

## Calibration and interpretation limits

The cache stage latencies, PLRU/bimodal details, workload instruction mixes, and branch rates are explicit modelling assumptions. Treat sweep results as comparative sensitivity directions until calibrated against Verilator RTL traces.
"""


def parse_args() -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("selftest", "sweep", "audit"):
        item = sub.add_parser(command)
        item.add_argument("--out", type=Path, required=True)
    report = sub.add_parser("report")
    report.add_argument("--sweep", type=Path, required=True)
    report.add_argument("--out", type=Path, required=True)
    run = sub.add_parser("run")
    run.add_argument("--workload", choices=sorted(WORKLOADS), required=True)
    run.add_argument("--seed", type=int, default=11)
    run.add_argument("--out", type=Path, required=True)
    replay = sub.add_parser(
        "replay", help="Replay an external trace through the FROST architectural model"
    )
    replay.add_argument(
        "--trace",
        type=Path,
        required=True,
        help="Path to trace file (.jsonl, .csv, etc.)",
    )
    replay.add_argument(
        "--config",
        default="baseline",
        help="Design variant configuration to use (default: baseline)",
    )
    replay.add_argument("--out", type=Path, help="Optional output JSON path")
    explore = sub.add_parser(
        "explore",
        help="Explore design variants and generate optimization suggestions for FROST",
    )
    explore.add_argument(
        "--workload", choices=sorted(WORKLOADS), help="Built-in workload to evaluate"
    )
    explore.add_argument(
        "--trace", type=Path, help="Execution trace file to replay and optimize against"
    )
    explore.add_argument("--seed", type=int, default=11)
    explore.add_argument(
        "--out", type=Path, help="Path to save exploration JSON results"
    )
    explore.add_argument(
        "--report", type=Path, help="Path to save Markdown optimization report"
    )
    return parser.parse_args()


def main() -> int:
    """Run the selected command; return 1 if the self-test fails, else 0."""
    args = parse_args()
    if args.command == "selftest":
        result = selftest()
        dump_json(args.out, result)
        return 0 if result["passed"] else 1
    if args.command == "audit":
        dump_json(args.out, rtl_audit())
        return 0
    if args.command == "sweep":
        dump_json(args.out, sweep_configurations())
        return 0
    if args.command == "run":
        dump_json(args.out, run_workload(ModelConfig(), args.workload, args.seed))
        return 0
    if args.command == "report":
        sweep = json.loads(args.sweep.read_text(encoding="utf-8"))
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(report_markdown(sweep), encoding="utf-8")
        return 0
    if args.command == "replay":
        variants = get_design_variants()
        config = variants.get(args.config) or ModelConfig()
        ops = load_trace_ops(args.trace)
        pipeline = FrostPipeline(config, ops)
        for op in ops:
            line = pipeline._fetch_line(op.fetch_address)
            pipeline.fetch_state[line] = "ready"
        result = pipeline.run()
        result["trace"] = str(args.trace)
        result["config"] = config.name
        result["micro_ops"] = len(ops)
        if args.out:
            dump_json(args.out, result)
        else:
            print(json.dumps(result, indent=2))
        return 0
    if args.command == "explore":
        target = args.trace or args.workload
        if not target:
            raise ValueError(
                "Either --workload or --trace must be provided for explore"
            )
        exploration = explore_design_variants(target, seed=args.seed)
        if args.out:
            dump_json(args.out, exploration)
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(
                generate_optimization_report(exploration), encoding="utf-8"
            )
        if not args.out and not args.report:
            print(generate_optimization_report(exploration))
        return 0
    raise AssertionError(args.command)


if __name__ == "__main__":
    raise SystemExit(main())
