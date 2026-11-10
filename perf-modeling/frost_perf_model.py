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
    default 6-bit-ID, 512-bit (64B) AXI4 master fabric (``cpu_memory_fabric.sv``).
  - ``SocTopModel`` (``soc_top.sv``): replaceable SoC interconnect and memory
    subsystem consisting of ``soc_axi_slave.sv`` (physical address decode to
    local BRAM/MMIO vs. the default 5-bit-ID whole-line DDR port) and a default single-channel
    512-bit AXI4 DDR endpoint modelled after ``axi_behavioral_memory.sv``.
    ``InterleavedDdrController`` supplies configurable physical channels.

Another project can swap ``SocTopModel`` (or ``DdrController``) while keeping
``CpuTopModel`` unchanged.  All non-RTL-calibrated latencies remain explicit in
``ModelConfig`` / ``SocConfig`` / ``DdrConfig``.

Grounding snapshot: twosigma/frost main @ 410aa8f3e866fffb078fc8f7fd3672866d83d131
(2026-10-22); the coherent L1D, the store drain, the home's prefetch agent,
and MEM_RS and LQ release follow ade0de67. The independent L1D hit path
follows 4d2a20a3 (2026-11-10).  See ``rtl_audit`` for exact
source locations and the boundary between source-proven configuration and
modelling assumptions.

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

from memory_workloads import KERNELS, build_kernel


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
    """FROST DDR endpoint configuration in *core-clock* cycles.

    Defaults match the single 512-bit (64-byte) AXI4 DDR port on ``soc_top.sv`` and its
    simulation-default ``axi_behavioral_memory.sv`` endpoint (5-bit AXI IDs,
    independent read/write slot pools of ``NUM_SLOTS = max(L2MaxSlots, 8)``,
    configurable fixed latency, optional LFSR latency jitter, and optional
    cross-ID out-of-order completion).
    """

    line_bytes: int = 64
    id_bits: int = 5  # riscv_pkg::DdrAxiIdBits (o_ddr_axi_arid / o_ddr_axi_awid)
    num_slots: int = 8  # queue slots per direction; behavioral DDR applies a floor
    latency_cycles: int = 80  # DDR_MODEL_LATENCY default in soc_top.sv / frost.sv
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

    ``soc_axi_slave`` decodes the CPU's physical-address AXI4 master
    with the ID widths in ``ModelConfig``:
      - Cached DDR aperture ``[ddr_base, ddr_base + ddr_bytes)`` forwards whole
        64-byte lines with IDs in ``axi_id_bits`` to the single DDR AXI port
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
    l1d_bimodal_insert: bool = True
    l2_bimodal_insert: bool = False
    l1_line_bytes: int = 32
    l2_line_bytes: int = 64
    l1i_mshrs: int = 2
    l1d_mshrs: int = 8
    l1d_id_bits: int = 4
    l1d_wb_slots: int = 2
    l2_mshrs: int = 4
    l2_id_bits: int = 5
    l2_wb_slots: int = 2
    l2_waiters: int = 2
    l2_prefetch: bool = True
    l2_prefetch_distance: int = 8  # L2_PREFETCH_DISTANCE, in 64-byte lines
    l2_prefetch_inflight: int = 3  # L2_PREFETCH_INFLIGHT data identities
    l2_prefetch_streams: int = 4  # coherence_prefetch_agent STREAMS
    prefetch_page_bytes: int = 4096  # look-ahead and prefetch stay in one page
    # Coherent L1D (coherence_l1d.sv): l1d_mshrs is its request-endpoint
    # count. Endpoint 0 serves stores; the others serve load misses, and the
    # highest l1d_lookahead_slots of them may carry stream look-ahead GetS.
    l1d_lookahead_slots: int = 2  # PrefetchCount for eight endpoints
    l1d_lookahead_sectors: int = 8  # look-ahead window past the demand frontier
    l1d_store_records: int = 4  # ordered 32-byte store records
    l1d_store_lookahead: bool = True  # one load endpoint lent to a younger store
    l1d_read_slots: int = 8  # CPU read slots, including reads waiting on a fill
    l1d_hit_path: bool = True  # coherence_array HIT_PORT beside the controller
    store_drain_cycles: int = 3  # SQ launch interval for cached stores
    coherence_release_cycles: int = 4  # installation or GrantAck to U
    # Pipeline / cache timing abstraction.
    l1_tag_cycles: int = 1  # coherence_array TAG_READ_LATENCY
    l1_data_cycles: int = 2  # coherence_array DATA_READ_LATENCY
    l1_write_cycles: int = 1  # coherence_array DATA_WRITE_LATENCY
    # RTL load microkernels at 4d2a20a3: MEM_RS launch to L1D arrival,
    # ready slot to read response, and read response to registered CDB.
    l1d_request_cycles: int = 1
    l1d_response_cycles: int = 2
    l1d_return_cycles: int = 2
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
    axi_id_pool_size: int = 32
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
            if (
                size <= 0
                or line <= 0
                or ways <= 0
                or ways & (ways - 1)
                or size % (line * ways)
            ):
                raise ValueError(f"invalid {label} geometry")
        if self.l2_line_bytes % self.l1_line_bytes:
            raise ValueError("L2 line must contain an integral number of L1 lines")
        for label, misses, writes, bits in (
            ("L1D", self.l1d_mshrs, self.l1d_wb_slots, self.l1d_id_bits),
            ("L2", self.l2_mshrs, self.l2_wb_slots, self.l2_id_bits),
        ):
            if (
                bits < 2
                or min(misses, writes) < 1
                or max(misses, writes) > 1 << (bits - 1)
            ):
                raise ValueError(f"{label} slots must fit its {{type,slot}} ID width")
        if self.axi_data_bytes != self.l2_line_bytes:
            raise ValueError("the modeled AXI beat is exactly one L2 line")
        if self.cpu_axi_id_bits < max(6, self.axi_id_bits + 1):
            raise ValueError(
                "cpu_memory_fabric requires at least 6 AXI ID bits at the cpu_top boundary"
            )
        if self.axi_id_bits < self.l2_id_bits or self.ddr.id_bits != self.axi_id_bits:
            raise ValueError("DDR AXI IDs must carry each L2 ID without truncation")
        if not 1 <= self.axi_id_pool_size <= 1 << self.axi_id_bits:
            raise ValueError("AXI ID pool must fit the AXI width")
        if self.ddr.line_bytes != self.axi_data_bytes:
            raise ValueError("DDR line_bytes must match the L2/AXI beat width")
        if (
            self.ddr.num_slots <= 0
            or self.ddr.latency_cycles < 0
            or self.ddr.latency_jitter < 0
        ):
            raise ValueError("invalid DDR slot or latency configuration")
        if (
            self.l1d_lookahead_slots < 0
            or self.l1d_lookahead_sectors < 1
            or self.l1d_store_records < 1
            or self.l1d_read_slots < 1
            or self.store_drain_cycles < 1
            or self.l1_write_cycles < 1
            or self.coherence_release_cycles < 0
            or min(
                self.l1d_request_cycles,
                self.l1d_response_cycles,
                self.l1d_return_cycles,
            )
            < 0
            or self.l2_prefetch_streams < 1
            or self.l2_prefetch_inflight < 1
            or self.l2_prefetch_distance < 1
        ):
            raise ValueError("invalid look-ahead, store record, or prefetch setting")
        page_sectors = self.prefetch_page_bytes // self.l1_line_bytes
        if (
            self.prefetch_page_bytes % self.l2_line_bytes
            or self.l1d_lookahead_sectors >= page_sectors
            or self.l2_prefetch_distance
            >= self.prefetch_page_bytes // self.l2_line_bytes
        ):
            raise ValueError("look-ahead and prefetch distances must fit in a page")

    @property
    def l1d_lookahead_endpoints(self) -> int:
        """Return the endpoints that may carry stream look-ahead.

        coherence_l1d.sv keeps at least one load endpoint demand-only, so
        three endpoints allow one and fewer allow none.
        """
        return min(self.l1d_lookahead_slots, max(0, self.l1d_mshrs - 2))


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
    prefetched: bool = False


@dataclass
class MissStatus:
    """One MSHR: the missing line, the way it reserves, and its requests.

    A miss that evicts a dirty line writes it back first, or beside the
    fill when the cache buffers its victims.
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
    wb_sent: bool = False
    granted: bool = False
    fill_ok: bool = True
    replacement_touched: bool = False


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
        request_observer: Callable[[int], None] | None = None,
        buffered_writeback: bool = False,
    ) -> None:
        """Create an empty cache with the given geometry, miss resources, and latencies.

        id_bits is the width of the {type, slot} IDs of its requests to the
        lower level. request_observer, when given, receives the line address
        of each accepted request from the L1D, hit or miss, as the home's
        prefetch agent sees hart GetS and GetM. With buffered_writeback, a
        dirty victim's writeback goes out beside the fill and holds its
        writeback slot until acknowledged, as the coherent L1D's frozen PutM
        slots and the home's detached victims do; otherwise the fill waits
        for the writeback.
        """
        self.name = name
        if ways < 1 or ways & (ways - 1):
            raise ValueError("cache ways must be a power of two")
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
        self.request_observer = request_observer
        self.buffered_writeback = buffered_writeback
        self.sets: dict[int, list[CacheLine]] = {}
        self.mshrs: dict[int, MissStatus] = {}
        self._used_mshr_slots: set[int] = set()
        self._used_wb_slots: set[int] = set()
        self._wb_lines: dict[int, int] = {}  # writeback slot -> line in flight
        self._last_accept_cycle = -1
        self._last_response_cycle = -1
        self.plru: dict[int, int] = {}
        self._insert_lfsr = 0xACE1
        self._insert_cycle = 0
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
        available = {
            index for index, line in enumerate(lines) if line.reserved_by is None
        }
        if not available:
            return None
        state = self.plru.get(set_index, 0)
        node, low, half = 1, 0, self.ways // 2
        while half:
            left = any(low <= way < low + half for way in available)
            right = any(low + half <= way < low + 2 * half for way in available)
            go_right = ((state >> (node - 1)) & 1) if left and right else int(right)
            node = 2 * node + go_right
            low += half * go_right
            half //= 2
        return node - self.ways

    def _touch(self, set_index: int, way: int, allocation: bool = False) -> None:
        if allocation and self.bimodal_insert:
            while self._insert_cycle < self.loop.cycle:
                feedback = (
                    (self._insert_lfsr >> 15)
                    ^ (self._insert_lfsr >> 13)
                    ^ (self._insert_lfsr >> 12)
                    ^ (self._insert_lfsr >> 10)
                ) & 1
                self._insert_lfsr = ((self._insert_lfsr << 1) & 0xFFFF) | feedback
                self._insert_cycle += 1
            if self._insert_lfsr & 31:
                self.stats["bimodal_untouched_allocations"] += 1
                return
        state = self.plru.get(set_index, 0)
        node = way + self.ways
        while node > 1:
            bit = node // 2 - 1
            state = (state & ~(1 << bit)) | (int(node % 2 == 0) << bit)
            node //= 2
        self.plru[set_index] = state
        if allocation:
            self.stats["mru_allocations"] += 1

    def submit(self, request: Request) -> bool:
        """Accept at most one tag lookup per modeled cache cycle."""
        accepted = self._submit(request)
        if accepted and self.request_observer is not None and request.source == "l1d":
            self.request_observer(request.address // self.line_bytes)
        return accepted

    def _submit(self, request: Request) -> bool:
        if self._last_accept_cycle == self.loop.cycle:
            self.stats["input_backpressure"] += 1
            return False
        line_address, set_index, tag = self._set_and_tag(request.address)
        hit_way = self._find(set_index, tag)
        if hit_way is not None:
            self._last_accept_cycle = self.loop.cycle
            line = self._ways(set_index)[hit_way]
            self._touch(set_index, hit_way)
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
        slot = next(s for s in range(self.mshr_count) if s not in self._used_mshr_slots)
        return (
            self._allocate_miss(request, line_address, set_index, victim_way, slot)
            is not None
        )

    def _allocate_miss(
        self,
        request: Request,
        line_address: int,
        set_index: int,
        victim_way: int,
        slot: int,
    ) -> MissStatus | None:
        """Reserve victim_way and miss slot for line_address and start the miss.

        Return None, with nothing reserved, when a dirty victim finds no
        writeback slot.
        """
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
                return None
        self._used_mshr_slots.add(slot)
        self._last_accept_cycle = self.loop.cycle
        victim.reserved_by = slot
        victim.valid = False
        status = MissStatus(
            slot=slot,
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
        touches = self.stats["mru_allocations"]
        self._touch(set_index, victim_way, allocation=True)
        status.replacement_touched = self.stats["mru_allocations"] != touches
        self.stats["misses"] += 1
        if needs_wb:
            self.stats["dirty_evictions"] += 1
        self.loop.after(self.tag_cycles, lambda status=status: self._begin_miss(status))
        return status

    def prefetch_lookup(self, line_address: int, reserve: int) -> bool:
        """Serve one Prefetch request at the home (``coherence_home.sv``).

        The request takes the lookup port; return False when the port is
        busy this cycle. A resident line keeps its data and updates
        replacement state as any hit does. An absent line starts a fill
        only while more than reserve miss slots are free, two ways of its
        set are available and, for a valid victim, every writeback slot is
        free. Otherwise, or when a fill of the line is in flight, the
        prefetch completes having done nothing; it never waits or retries.
        """
        if self._last_accept_cycle == self.loop.cycle:
            self.stats["prefetch_port_backpressure"] += 1
            return False
        self._last_accept_cycle = self.loop.cycle
        set_index, tag = line_address % self.sets_count, line_address // self.sets_count
        hit_way = self._find(set_index, tag)
        if hit_way is not None:
            self._touch(set_index, hit_way)
            self.stats["prefetch_resident"] += 1
            return True
        if line_address in self.mshrs:
            self.stats["prefetch_in_flight"] += 1
            return True
        lines = self._ways(set_index)
        available = sum(line.reserved_by is None for line in lines)
        victim_way = self._victim(set_index)
        free_wb = self.wb_slots - len(self._used_wb_slots)
        if (
            self.mshr_count - len(self.mshrs) <= reserve
            or available < 2
            or victim_way is None
            or (lines[victim_way].valid and free_wb < min(2, self.wb_slots))
        ):
            self.stats["prefetch_declined"] += 1
            return True
        request = Request(
            address=line_address * self.line_bytes,
            is_write=False,
            source="prefetch",
            request_id=("prefetch", line_address),
            complete=lambda _ok: None,
            bytes_size=self.line_bytes,
        )
        slot = next(s for s in range(self.mshr_count) if s not in self._used_mshr_slots)
        if self._allocate_miss(request, line_address, set_index, victim_way, slot):
            self.stats["prefetch_fills"] += 1
        return True

    def _begin_miss(self, status: MissStatus) -> None:
        if self.mshrs.get(status.line_address) is not status:
            return
        if status.waiting_for_wb and not status.wb_sent:
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
            status.wb_sent = True
            self._wb_lines[status.wb_slot] = evicted_line_address
            if not self.buffered_writeback:
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
        if (
            not self.buffered_writeback
            and self.mshrs.get(status.line_address) is not status
        ):
            return
        status.waiting_for_wb = False
        assert status.wb_slot is not None
        self._used_wb_slots.remove(status.wb_slot)
        self._wb_lines.pop(status.wb_slot, None)
        self.stats["writebacks_completed"] += 1
        if not self.buffered_writeback:
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
        line.prefetched = status.primary.source == "prefetch"
        responses = [status.primary] + status.waiters
        del self.mshrs[status.line_address]
        self._used_mshr_slots.remove(status.slot)
        for response in responses:
            self._respond(response, ok)

    def _respond(self, request: Request, ok: bool = True) -> None:
        response_cycle = max(
            self.loop.cycle + self.response_cycles, self._last_response_cycle + 1
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
    axi_id: int = -1
    bytes_size: int = 64

    def __post_init__(self) -> None:
        """Take the AXI ID from the transaction ID when none is given."""
        if self.axi_id == -1:
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
        self._pump_cycle: int | None = None
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
        next_cycle = self._next_ready_cycle()
        if next_cycle is None:
            return
        target = max(self.loop.cycle + 1, next_cycle)
        if self._pump_cycle is not None and self._pump_cycle <= target:
            return
        self._pump_cycle = target

        def pump_if_current() -> None:
            if self._pump_cycle == target:
                self._pump()

        self.loop.at(target, pump_if_current)

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
        self._pump_cycle = None
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
    single AXI4 boundary with configured ID width and routes them by physical address:
      - Cached DDR aperture ``[ddr_base, ddr_base + ddr_bytes)``: validates the
        configured DDR ID width and 64-byte line size, subtracts
        ``ddr_base``, models ``soc_axi_slave``'s write-address register stage
        (``aw_valid_q``) and combinational read pass-through, and submits to the
        selected ``DdrController``.
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

        Without an explicit controller, ddr.controller selects the behavioral
        or interleaved endpoint.
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

        A DDR transaction with an ID outside the configured width or a
        transfer size other than one line completes with an error. An
        address outside DDR, BRAM, and MMIO completes with a decode error.
        """
        addr = transaction.address
        if self._is_ddr_address(addr):
            if (
                not 0 <= transaction.axi_id < 1 << self.config.axi_id_bits
                or transaction.bytes_size != self.config.axi_data_bytes
            ):
                self.stats["ddr_protocol_reject"] += 1
                self.loop.after(1, lambda: transaction.complete(False))
                return True
            ddr_offset = addr - self.soc_config.ddr_base
            ddr_tx = dataclasses.replace(
                transaction,
                address=ddr_offset,
                axi_id=transaction.axi_id,
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
        id_pool_size: int | None = None,
    ) -> None:
        """Send line requests to soc, accepting one read and one write per cycle."""
        self.loop = loop
        self.soc = soc
        self.axi_data_bytes = axi_data_bytes
        self.axi_id_bits = axi_id_bits
        self.id_pool_size = (1 << axi_id_bits) if id_pool_size is None else id_pool_size
        if not 1 <= self.id_pool_size <= 1 << axi_id_bits:
            raise ValueError("AXI ID pool must fit the AXI width")
        self.inflight: dict[int, TransactionId] = {}
        self._accounted_cycle = loop.cycle
        self._read_accept_cycle = -1
        self._write_accept_cycle = -1
        self.stats: Counter = Counter()

    def _account(self) -> None:
        self.stats["inflight_cycles"] += (
            self.loop.cycle - self._accounted_cycle
        ) * len(self.inflight)
        self._accounted_cycle = self.loop.cycle

    def _complete(self, axi_id: int, request: Request, ok: bool) -> None:
        if self.inflight.get(axi_id) != request.request_id:
            raise RuntimeError("AXI response has no matching owner")
        self._account()
        del self.inflight[axi_id]
        self.stats["responses"] += 1
        request.complete(ok)

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
        if axi_id in self.inflight:
            self.stats["duplicate_id_backpressure"] += 1
            return False
        if len(self.inflight) >= self.id_pool_size:
            self.stats["id_pool_backpressure"] += 1
            return False
        self._account()
        self.inflight[axi_id] = request.request_id
        accepted = self.soc.submit_axi(
            AxiTransaction(
                address=request.address,
                is_write=request.is_write,
                transaction_id=request.request_id,
                complete=lambda ok: self._complete(axi_id, request, ok),
                source=request.source,
                axi_id=axi_id,
                bytes_size=self.axi_data_bytes,
            )
        )
        if accepted:
            self.stats["max_inflight"] = max(
                self.stats["max_inflight"], len(self.inflight)
            )
            if request.is_write:
                self._write_accept_cycle = self.loop.cycle
                self.stats["write_beats"] += 1
            else:
                self._read_accept_cycle = self.loop.cycle
                self.stats["read_beats"] += 1
        else:
            del self.inflight[axi_id]
            self.stats["controller_backpressure"] += 1
        return accepted


@dataclass
class PrefetchStream:
    """One entry of ``l2_stream_prefetcher.sv``'s stream table."""

    line: int
    confirmed: bool = False
    ahead: int = 0


class StreamPrefetcher:
    """The home's data prefetcher (``coherence_prefetch_agent.sv``).

    The ``l2_stream_prefetcher.sv`` table holds l2_prefetch_streams entries,
    each the last training line of a stream and how many lines after it
    have been requested. Training comes from every accepted hart GetS and
    GetM at the home, L2 hits included, one cycle later. A line after an
    entry's confirms and advances it; an entry's own line leaves it
    unchanged; any other line replaces an entry in rotation. The lowest
    confirmed entry with fewer than l2_prefetch_distance lines requested
    requests the next line, never past its page. A request loads only
    while more than l2_mshrs // 4 home fills are free (PREFETCH_RESERVE)
    and one of l2_prefetch_inflight identities is free. The home answers
    each Prefetch with GrantAck after one lookup; the identity returns at
    U, coherence_release_cycles later, while any fill goes on without it.
    A line that a live identity already holds is dropped.
    """

    def __init__(self, loop: EventLoop, l2: CacheLevel, config: ModelConfig) -> None:
        """Prefetch into l2 with the configuration's table, distance and identities."""
        self.loop = loop
        self.l2 = l2
        self.config = config
        self.reserve = config.l2_mshrs // 4
        self.page_lines = config.prefetch_page_bytes // config.l2_line_bytes
        self.streams: list[PrefetchStream | None] = [None] * config.l2_prefetch_streams
        self.victim = 0
        self.live: dict[int, int] = {}  # identity -> line
        self.pending: tuple[int, int] | None = None  # registered (identity, line)
        self._scheduled = False
        self.stats: Counter = Counter()

    def observe(self, line: int) -> None:
        """Train on an accepted hart data request for line, a cycle later."""
        if self.config.l2_prefetch:
            self.loop.after(1, lambda line=line: self._train(line))

    def _train(self, line: int) -> None:
        self.stats["observations"] += 1
        for entry in self.streams:
            if entry is not None and line == entry.line + 1:
                entry.line, entry.confirmed = line, True
                entry.ahead = max(0, entry.ahead - 1)
                self._schedule()
                return
        if any(entry is not None and entry.line == line for entry in self.streams):
            return
        self.streams[self.victim] = PrefetchStream(line)
        self.victim = (self.victim + 1) % len(self.streams)
        self.stats["streams_allocated"] += 1

    def _schedule(self) -> None:
        if not self._scheduled:
            self._scheduled = True
            self.loop.after(1, self._pump)

    def _candidate(self) -> PrefetchStream | None:
        for entry in self.streams:
            if (
                entry is not None
                and entry.confirmed
                and entry.ahead < self.config.l2_prefetch_distance
                and entry.line % self.page_lines + entry.ahead + 1 < self.page_lines
            ):
                return entry
        return None

    def _pump(self) -> None:
        self._scheduled = False
        if self.pending is None:
            entry = self._candidate()
            free = [
                ident
                for ident in range(self.config.l2_prefetch_inflight)
                if ident not in self.live
            ]
            room = self.l2.mshr_count - len(self.l2.mshrs) > self.reserve
            if entry is not None and free and room:
                line = entry.line + entry.ahead + 1
                entry.ahead += 1
                if line in self.live.values():
                    self.stats["dropped_live"] += 1
                else:
                    self.live[free[0]] = line
                    self.pending = (free[0], line)
            elif entry is not None:
                self.stats["identity_stall" if room else "room_stall"] += 1
        if self.pending is not None:
            ident, line = self.pending
            if self.l2.prefetch_lookup(line, self.reserve):
                self.pending = None
                self.stats["issued"] += 1
                self.loop.after(
                    self.l2.tag_cycles + self.config.coherence_release_cycles,
                    lambda ident=ident: self._release(ident),
                )
        if self.pending is not None or self._candidate() is not None:
            self._schedule()

    def _release(self, ident: int) -> None:
        del self.live[ident]
        self.stats["completed"] += 1
        self._schedule()


class ReadStream:
    """``coherence_read_stream.sv``: one ascending stream of 32-byte sectors.

    Three adjacent demand misses confirm the stream. Before confirmation an
    adjacent miss advances the seed and an adjacent hit leaves it
    unchanged; a confirmed stream advances on demand hits and misses of the
    next sector; a nonadjacent miss replaces it. The cursor stays within
    distance sectors of the demand frontier and within its page.
    """

    def __init__(self, distance: int, page_bytes: int, sector_bytes: int) -> None:
        """Start unseeded with the given window, page and sector sizes."""
        self.distance = distance
        self.page_bytes = page_bytes
        self.sector_bytes = sector_bytes
        self.page_sectors = page_bytes // sector_bytes
        self.seeded = self.pair_seen = self.confirmed = False
        self.page = self.frontier = self.cursor = 0

    def demand(self, address: int, miss: bool) -> bool:
        """Note a demand's first lookup; return True when it replaces the stream."""
        page = address // self.page_bytes
        sector = address % self.page_bytes // self.sector_bytes
        same = self.seeded and page == self.page and sector == self.frontier
        adjacent = self.seeded and page == self.page and sector == self.frontier + 1
        if miss and not same and not adjacent:
            self.seeded, self.pair_seen, self.confirmed = True, False, False
            self.page, self.frontier, self.cursor = page, sector, sector + 1
            return True
        if adjacent and (self.confirmed or miss):
            if not self.confirmed or self.cursor <= sector:
                self.cursor = sector + 1
            self.confirmed = self.confirmed or self.pair_seen
            self.pair_seen = True
            self.frontier = sector
        return False

    def in_window(self, address: int) -> bool:
        """Return True while address lies ahead of the frontier in the window."""
        sector = address % self.page_bytes // self.sector_bytes
        return (
            self.confirmed
            and address // self.page_bytes == self.page
            and self.frontier < sector <= self.frontier + self.distance
        )

    def consume(self) -> int | None:
        """Return the cursor's sector address and advance it, if it is valid."""
        address = self.page * self.page_bytes + self.cursor * self.sector_bytes
        if self.cursor >= self.page_sectors or not self.in_window(address):
            return None
        self.cursor += 1
        return address


@dataclass
class StoreRecord:
    """One of the coherent L1D's ordered 32-byte store records."""

    line_address: int
    contributors: int = 1
    sealed: bool = False
    status: MissStatus | None = None  # its GetM, once acquired
    checked: bool = False  # a look-ahead lookup found it Modified
    writing: bool = False  # a head hit is updating the array


@dataclass
class L1dRead:
    """A CPU read slot and its single offer to the L1D's hit port."""

    request: Request
    arrival: int
    path_taken: bool = False
    path_hit: bool = False


class CoherentL1d(CacheLevel):
    """The coherent L1D (``coherence_l1d.sv``) behind the load and store queues.

    One controller serves one operation at a time, in its Idle priority:
    a grant's installation, the head store, a load, a store look-ahead, and
    stream look-ahead last. Each operation holds the controller for its
    phases (Idle, Lookup, the array's tag and data reads, then Acquire, or
    Update and its array write). The optional hit path reads a tag copy and
    all ways' data independently, completing a hit's slot four cycles after
    arrival. A controller selection while that path holds the read costs a
    tags-only shadow lookup; only a miss on both paths acquires an endpoint.
    A refused offer, or a read released by a fill, uses the controller's
    l1_tag_cycles + l1_data_cycles + 3 cycle hit path.

    l1d_mshrs request endpoints carry acquisitions. Endpoint 0 carries the
    head store's GetM; endpoints 1 and up carry load misses, the lowest free
    one for each demand. Stream look-ahead GetS uses the highest
    l1d_lookahead_endpoints of them, and one may be lent to a younger
    store's GetM. A demand grant answers its load before installation;
    loads that attached to an endpoint look up again after it installs.
    Each endpoint stays live through U, coherence_release_cycles after
    installation. Committed stores enter l1d_store_records ordered sector
    records; only the youngest unsealed record combines, and every record
    installs at the head. A dirty victim's writeback leaves beside the fill.
    """

    def __init__(
        self, loop: EventLoop, lower: SubmissionPort, config: ModelConfig
    ) -> None:
        """Create the L1D from the configuration's geometry and endpoint settings."""
        super().__init__(
            "l1d",
            loop,
            lower,
            config.l1d_bytes,
            config.l1_line_bytes,
            config.l1d_ways,
            config.l1d_mshrs,
            config.l1d_wb_slots,
            config.l1d_read_slots,
            config.l1_tag_cycles,
            config.l1_data_cycles,
            config.cache_fill_cycles,
            config.l1d_response_cycles,
            config.l1d_id_bits,
            bimodal_insert=config.l1d_bimodal_insert,
            buffered_writeback=True,
        )
        self.release_cycles = config.coherence_release_cycles
        self.hit_path = config.l1d_hit_path
        self.read_slots = config.l1d_read_slots
        self.reads: dict[Any, L1dRead] = {}
        self.pending_reads: deque[L1dRead] = deque()
        self._last_read_arrival = -1
        self._array_claim_cycle = -1
        self._array_plru_cycles: set[int] = set()
        self._array_update: tuple[int, int, int] | None = None
        self._hit_reports: deque[int] = deque()
        self._new_hit_report: int | None = None
        self._demand_report_cycle = -1
        # Controller occupancy: Idle, Lookup, the array's tag read, and the
        # reply cycle; a hit adds the data read, an acquisition its Acquire
        # cycle, and an update its Update, array write and UpdateWait.
        self.lookup_cycles = config.l1_tag_cycles + 3
        self.update_cycles = self.lookup_cycles + config.l1_write_cycles + 2
        endpoints = range(config.l1d_mshrs)
        self.load_endpoints = list(endpoints[1:] if config.l1d_mshrs > 1 else endpoints)
        self.lookahead_endpoints = list(
            endpoints[config.l1d_mshrs - config.l1d_lookahead_endpoints :]
            if config.l1d_lookahead_endpoints
            else []
        )
        self.store_lookahead = config.l1d_store_lookahead and config.l1d_mshrs >= 3
        self.record_limit = config.l1d_store_records
        self.records: deque[StoreRecord] = deque()
        self.stream = ReadStream(
            config.l1d_lookahead_sectors,
            config.prefetch_page_bytes,
            config.l1_line_bytes,
        )
        self.hint: int | None = None
        self.borrowed: int | None = None  # the endpoint lent to a younger store
        self.busy_until = 0
        self.grants: list[MissStatus] = []
        self.replays: deque[Request] = deque()
        self.read_turn = False  # a read waits for its turn between other work
        self._looked_up: set[Any] = set()
        self._waiting_for_endpoint: set[Any] = set()

    # Controller and ownership.
    def _idle(self) -> bool:
        return self.loop.cycle >= self.busy_until

    def _occupy(
        self,
        cycles: int,
        shadow: bool = False,
        write_set: int | None = None,
        touch: bool = False,
        insert_touch: bool = False,
    ) -> None:
        self.busy_until = self.loop.cycle + cycles
        self._last_accept_cycle = self.loop.cycle
        self.stats["controller_busy_cycles"] += cycles
        # coherence_array: a normal lookup claims the data-bank read address
        # in Tags. A shadow reads tags only. A same-set update also refuses
        # the hit port, keeping its tag and data snapshot on one edge.
        if not shadow:
            self._array_claim_cycle = self.loop.cycle + self.lookup_cycles - 2
        self._array_plru_cycles = {
            cycle for cycle in self._array_plru_cycles if cycle >= self.loop.cycle
        }
        if touch:
            self._array_plru_cycles.add(self.loop.cycle + self.lookup_cycles - 1)
        if write_set is not None:
            update_cycle = self.busy_until - self.update_cycles + self.lookup_cycles
            self._array_update = (
                update_cycle,
                update_cycle + 1,
                write_set,
            )
            if insert_touch:
                self._array_plru_cycles.add(update_cycle)

    def _free(self, candidates: Iterable[int]) -> list[int]:
        return [ep for ep in candidates if ep not in self._used_mshr_slots]

    def _record_holds(self, line_address: int) -> bool:
        return any(record.line_address == line_address for record in self.records)

    def _wb_holds(self, line_address: int) -> bool:
        return line_address in self._wb_lines.values()

    def _path_blocked(self, line_address: int) -> bool:
        # The RTL's hit-port holder comparisons use address[5+:18].
        sector = line_address & ((1 << 18) - 1)
        holders = [record.line_address for record in self.records]
        holders.extend(self._wb_lines.values())
        return any(holder & ((1 << 18) - 1) == sector for holder in holders)

    def _touch_controller(self, set_index: int, way: int) -> None:
        if self.hit_path:
            self.loop.after(self.lookup_cycles - 1, lambda: self._touch(set_index, way))
        else:
            self._touch(set_index, way)

    def step(self) -> None:
        """Start a grant's installation or a store operation, ahead of loads.

        A grant or store yields one turn to a waiting load after each store
        operation and after a demand installation with attached loads.
        """
        if not self._idle() or self.read_turn:
            return
        if not self._start_grant():
            self._start_store()

    def step_after_loads(self) -> None:
        """Use an idle controller after this cycle's loads: deferred work, then hints."""
        self._train_path_hits()
        if not self._idle():
            return
        self.read_turn = False
        if self._start_grant() or self._start_store() or self._start_store_lookahead():
            return
        self._start_hint()

    def submit(self, request: Request) -> bool:
        """Capture a read slot, or use the old controller-only configuration.

        New loads get one hit-port offer in the following cycle. The
        controller independently selects pending reads; it owns every miss
        and any read whose hit-port offer was refused.
        """
        if request.is_write:
            raise ValueError("stores enter the coherent L1D through push_store")
        if self.hit_path:
            if (
                len(self.reads) >= self.read_slots
                or self._last_read_arrival == self.loop.cycle
            ):
                self.stats["input_backpressure"] += 1
                return False
            self._last_read_arrival = self.loop.cycle
            complete = request.complete

            def finish(ok: bool) -> None:
                del self.reads[request.request_id]
                complete(ok)

            captured = dataclasses.replace(request, complete=finish)
            read = L1dRead(captured, self.loop.cycle)
            self.reads[request.request_id] = read
            self.pending_reads.append(read)
            self.loop.after(1, lambda: self._offer_path(read))
            return True
        if not self._idle():
            self.stats["input_backpressure"] += 1
            return False
        if not self._eligible(request):
            return False
        first = request.request_id not in self._looked_up
        self._looked_up.add(request.request_id)
        return self._read(request, first)

    def service_replays(self) -> None:
        """Look up again, ahead of new loads, a load released by an installation."""
        if not self._idle():
            return
        if self.replays:
            request = self.replays[0]
            if self._eligible(request):
                self.replays.popleft()
                if not self._read(request, False):
                    self.replays.appendleft(request)
        if not self._idle():
            return
        for read in list(self.pending_reads):
            request = read.request
            age = self.loop.cycle - read.arrival
            if age < 1 or not self._eligible(request):
                continue
            # Stage 4 is excluded from selection. A stage-3 hit can still
            # be selected; its first Lookup cycle in stage 4 is a shadow.
            if read.path_hit:
                if age >= 4:
                    continue
                self._occupy(self.lookup_cycles, shadow=True)
                self.stats["shadow_lookups"] += 1
                self.stats["shadow_skips"] += 1
                self.pending_reads.remove(read)
                self.read_turn = False
                return
            shadow = read.path_taken and age == 1
            first = request.request_id not in self._looked_up
            self._looked_up.add(request.request_id)
            if self._read(request, first, shadow=shadow):
                self.pending_reads.remove(read)
            return

    def _offer_path(self, read: L1dRead) -> None:
        """Sample tags and all data ways on the stage-1 acceptance edge."""
        request = read.request
        line_address, set_index, tag = self._set_and_tag(request.address)
        self.stats["hit_path_offers"] += 1
        update = self._array_update
        if (
            self._path_blocked(line_address)
            or self.loop.cycle == self._array_claim_cycle
            or (
                update is not None
                and update[0] <= self.loop.cycle < update[1]
                and update[2] == set_index
            )
        ):
            self.stats["hit_path_refused"] += 1
            return
        read.path_taken = True
        self.stats["hit_path_takes"] += 1
        # The tag copy sees an installed line at the update edge, even
        # while its way remains reserved until the controller finishes.
        hit_way = next(
            (
                way
                for way, line in enumerate(self._ways(set_index))
                if line.valid and line.tag == tag
            ),
            None,
        )
        if hit_way is None:
            return
        read.path_hit = True
        # Preserve the stage-1 image even if the controller replaces it
        # before the answer. The stream report is from stage 3.
        self.loop.after(2, lambda: self._path_hit(read, set_index, hit_way))
        self.loop.after(3, lambda: self._answer_path(read))

    def _path_hit(self, read: L1dRead, set_index: int, way: int) -> None:
        if self.loop.cycle in self._array_plru_cycles:
            self.stats["hit_path_touch_drops"] += 1
        else:
            self._touch(set_index, way)
        line = self._ways(set_index)[way]
        if line.prefetched:
            self.stats["useful_lookaheads"] += 1
        line.prefetched = False
        self._new_hit_report = read.request.address // self.line_bytes

    def _answer_path(self, read: L1dRead) -> None:
        if read in self.pending_reads:
            self.pending_reads.remove(read)
        self.stats["hits"] += 1
        self.stats["hit_path_hits"] += 1
        self._respond(read.request)

    def _train_path_hits(self) -> None:
        # Two entries on coherence_read_stream's second input. Controller
        # reports win, duplicate tail sectors collapse, and overflow drops
        # a hit rather than delaying a load's answer.
        sector = self._new_hit_report
        duplicate = bool(self._hit_reports) and self._hit_reports[-1] == sector
        if self._hit_reports and self._demand_report_cycle != self.loop.cycle:
            address = self._hit_reports.popleft() * self.line_bytes
            self.stream.demand(address, False)
            self.stats["hit_path_stream_reports"] += 1
        self._new_hit_report = None
        if sector is None or not self.lookahead_endpoints or duplicate:
            return
        if len(self._hit_reports) == 2:
            self.stats["hit_path_stream_drops"] += 1
        else:
            self._hit_reports.append(sector)

    def _report_demand(self, address: int, miss: bool) -> None:
        self._demand_report_cycle = self.loop.cycle
        if self.stream.demand(address, miss):
            self.hint = None

    def _eligible(self, request: Request) -> bool:
        line_address = request.address // self.line_bytes
        if self._record_holds(line_address) or self._wb_holds(line_address):
            # A read of a buffered store's or a frozen victim's sector waits.
            self.stats["store_record_wait"] += 1
            return False
        # A miss that found no endpoint waits for one before it looks again.
        return request.request_id not in self._waiting_for_endpoint or bool(
            self._free(self.load_endpoints)
        )

    def _read(self, request: Request, first: bool, shadow: bool = False) -> bool:
        line_address, set_index, tag = self._set_and_tag(request.address)
        hit_way = self._find(set_index, tag)
        if shadow:
            self.stats["shadow_lookups"] += 1
        if first and not (shadow and hit_way is not None):
            if self.hit_path:
                self.loop.after(
                    self.lookup_cycles
                    + (self.data_cycles if hit_way is not None else 0)
                    - 1,
                    lambda: self._report_demand(request.address, hit_way is None),
                )
            else:
                self._report_demand(request.address, hit_way is None)
        self.read_turn = False
        if hit_way is not None:
            if shadow:
                # A fill can make only the shadow's tags hit. It has no
                # data; leave the read pending for a normal lookup later.
                self._occupy(self.lookup_cycles, shadow=True)
                self.stats["shadow_skips"] += 1
                self._looked_up.discard(request.request_id)
                return False
            self._occupy(self.lookup_cycles + self.data_cycles, touch=True)
            line = self._ways(set_index)[hit_way]
            self._touch_controller(set_index, hit_way)
            if line.prefetched:
                self.stats["useful_lookaheads"] += 1
            line.prefetched = False
            self.stats["hits"] += 1
            self.loop.after(
                self.lookup_cycles + self.data_cycles, lambda: self._respond(request)
            )
            return self._accepted(request)
        active = self.mshrs.get(line_address)
        if active is not None:
            self._occupy(self.lookup_cycles, shadow=shadow)
            active.waiters.append(request)
            self.stats["mshr_merges"] += 1
            if active.primary.source == "l1d_lookahead":
                self.stats["lookahead_attached"] += 1
            return self._accepted(request)
        free = self._free(self.load_endpoints)
        victim_way = self._victim(set_index)
        if not free or victim_way is None:
            # The miss's lookup finds no endpoint; it retries when one frees.
            self._occupy(self.lookup_cycles, shadow=shadow)
            self._waiting_for_endpoint.add(request.request_id)
            self.stats["mshr_backpressure"] += 1
            return False
        status = self._allocate_miss(
            request, line_address, set_index, victim_way, free[0]
        )
        if status is None:
            self._occupy(self.lookup_cycles, shadow=shadow)
            self._waiting_for_endpoint.add(request.request_id)
            return False
        self._occupy(self.lookup_cycles + 1, shadow=shadow)
        return self._accepted(request)

    def _accepted(self, request: Request) -> bool:
        self._looked_up.discard(request.request_id)
        self._waiting_for_endpoint.discard(request.request_id)
        return True

    # Grants.
    def _fill_done(self, status: MissStatus, ok: bool) -> None:
        if self.mshrs.get(status.line_address) is not status:
            return
        status.granted = True
        status.fill_ok = ok
        if status.primary.source == "store_lookahead" and (
            not self.records or self.records[0].status is not status
        ):
            # A younger store's grant waits in its endpoint until the head.
            return
        self.grants.append(status)

    def _start_grant(self) -> bool:
        if not self.grants:
            return False
        # Endpoint 0's grant goes first, then the lowest-numbered load grant.
        status = min(self.grants, key=lambda item: item.slot)
        self.grants.remove(status)
        victim_dirty = status.wb_slot is not None
        cycles = self.update_cycles + (self.data_cycles + 1 if victim_dirty else 0)
        self._occupy(
            cycles,
            write_set=status.set_index,
            touch=self._ways(status.set_index)[status.way_index].valid,
            insert_touch=(
                status.replacement_touched
                or status.primary.source == "l1d"
                or bool(status.waiters)
            ),
        )
        if self.hit_path:
            if self._ways(status.set_index)[status.way_index].valid:
                self._touch_controller(status.set_index, status.way_index)
            self.loop.after(
                cycles - self.update_cycles + self.lookup_cycles,
                lambda: self._publish_grant(status),
            )
        if status.primary.source == "l1d":
            # The demand grant answers its load in its Lookup cycle.
            self.loop.after(
                2,
                lambda request=status.primary, ok=status.fill_ok: self._respond(
                    request, ok
                ),
            )
        self.loop.after(cycles - 1, lambda: self._install(status))
        self.stats["installations"] += 1
        return True

    def _install(self, status: MissStatus) -> None:
        if self.mshrs.get(status.line_address) is not status:
            return
        if not self.hit_path:
            self._publish_grant(status)
        line = self._ways(status.set_index)[status.way_index]
        line.reserved_by = None
        del self.mshrs[status.line_address]
        self.loop.after(
            self.release_cycles,
            lambda slot=status.slot, source=status.primary.source: self._release(
                slot, source
            ),
        )
        if status.primary.source in {"store", "store_lookahead"}:
            self._pop_store()
        if not status.fill_ok:
            for request in status.waiters:
                self._respond(request, False)
        elif status.waiters:
            # Attached loads look up again; one takes a turn before more grants.
            self.replays.extend(status.waiters)
            self.read_turn = True

    def _publish_grant(self, status: MissStatus) -> None:
        """Write the tag/data image before ending the controller's update wait."""
        _, _, tag = self._set_and_tag(status.line_address * self.line_bytes)
        line = self._ways(status.set_index)[status.way_index]
        line.tag = tag
        line.valid = status.fill_ok
        line.dirty = status.write_intent
        line.prefetched = status.primary.source == "l1d_lookahead"

    def _release(self, slot: int, source: str) -> None:
        """End an endpoint's acquisition at U."""
        self._used_mshr_slots.remove(slot)
        if source == "store_lookahead":
            self.borrowed = None

    # Stream look-ahead.
    def _start_hint(self) -> None:
        if not self.lookahead_endpoints:
            return
        if self.hint is None:
            self.hint = self.stream.consume()
        if self.hint is None:
            return
        if not self.stream.in_window(self.hint):
            self.hint = None
            return
        line_address, set_index, tag = self._set_and_tag(self.hint)
        if (
            line_address in self.mshrs
            or self._record_holds(line_address)
            or self._wb_holds(line_address)
        ):
            self.stats["lookahead_conflicts"] += 1
            self.hint = None
            return
        free = self._free(self.lookahead_endpoints)
        if not free:
            return
        self.hint = None
        if self._find(set_index, tag) is not None:
            # A resident hint needs no acquisition and keeps the line's age.
            self._occupy(self.lookup_cycles)
            self.stats["lookahead_resident"] += 1
            return
        victim_way = self._victim(set_index)
        if victim_way is None:
            return
        request = Request(
            address=line_address * self.line_bytes,
            is_write=False,
            source="l1d_lookahead",
            request_id=("lookahead", line_address),
            complete=lambda _ok: None,
            bytes_size=self.line_bytes,
        )
        if self._allocate_miss(request, line_address, set_index, victim_way, free[-1]):
            self._occupy(self.lookup_cycles + 1)
            self.stats["lookahead_issued"] += 1

    # Store records.
    def store_ready(self) -> bool:
        """Return True when a record is free for the next committed store.

        The credit does not compare addresses, so a store that would
        combine also needs a free record (coherence_store_buffer.sv).
        """
        return len(self.records) < self.record_limit

    def push_store(self, address: int) -> None:
        """Buffer a committed store, combining it with the youngest unsealed record."""
        line_address = address // self.line_bytes
        youngest = self.records[-1] if self.records else None
        if (
            youngest is not None
            and not youngest.sealed
            and youngest.line_address == line_address
        ):
            youngest.contributors += 1
            # A record seals at 32 contributors (coherence_store_buffer.sv).
            youngest.sealed = youngest.contributors >= 32
            self.stats["stores_combined"] += 1
            return
        if len(self.records) >= self.record_limit:
            raise RuntimeError("store record pushed without credit")
        self.records.append(StoreRecord(line_address))
        self.stats["store_records"] += 1

    def _start_store(self) -> bool:
        if not self.records or self.records[0].writing:
            return False
        head = self.records[0]
        if head.status is not None:
            if head.status.granted and head.status not in self.grants:
                # A lent endpoint's grant installs once its record is the head.
                self.grants.append(head.status)
                return self._start_grant()
            return False
        line_address, set_index, tag = self._set_and_tag(
            head.line_address * self.line_bytes
        )
        if line_address in self.mshrs or 0 in self._used_mshr_slots:
            return False
        head.sealed = True
        self.read_turn = True
        hit_way = self._find(set_index, tag)
        if hit_way is not None and self._ways(set_index)[hit_way].dirty:
            self._occupy(self.update_cycles, write_set=set_index, touch=True)
            self._touch_controller(set_index, hit_way)
            head.writing = True
            self.stats["store_hits"] += 1
            self.loop.after(self.update_cycles - 1, self._pop_store)
            return True
        self._acquire_store(head, 0, "store")
        return True

    def _start_store_lookahead(self) -> bool:
        if (
            not self.store_lookahead
            or len(self.records) < 2
            or self.borrowed is not None
        ):
            return False
        free = self._free(self.load_endpoints)
        if not free:
            return False
        records = list(self.records)
        head_row = records[0].line_address * self.line_bytes // 64
        candidates = []
        for age, record in enumerate(records):
            if age == 0 or record.status is not None or record.checked:
                continue
            if any(
                other.line_address == record.line_address for other in records[:age]
            ):
                continue
            if record.line_address in self.mshrs or self._wb_holds(record.line_address):
                continue
            candidates.append(record)
        if not candidates:
            return False
        # Look-ahead prefers another home row over the head's sibling sector.
        other_row = [
            record
            for record in candidates
            if record.line_address * self.line_bytes // 64 != head_row
        ]
        record = (other_row or candidates)[0]
        line_address, set_index, tag = self._set_and_tag(
            record.line_address * self.line_bytes
        )
        self.read_turn = True
        hit_way = self._find(set_index, tag)
        if hit_way is not None and self._ways(set_index)[hit_way].dirty:
            self._occupy(self.lookup_cycles, touch=True)
            if self.hit_path:
                self._touch_controller(set_index, hit_way)
            record.checked = True
            return True
        self._acquire_store(record, free[0], "store_lookahead")
        return True

    def _acquire_store(self, record: StoreRecord, endpoint: int, source: str) -> None:
        line_address, set_index, tag = self._set_and_tag(
            record.line_address * self.line_bytes
        )
        request = Request(
            address=line_address * self.line_bytes,
            is_write=True,
            source=source,
            request_id=(source, line_address),
            complete=lambda _ok: None,
            bytes_size=self.line_bytes,
        )
        hit_way = self._find(set_index, tag)
        self._occupy(self.lookup_cycles + 1, touch=hit_way is not None)
        if hit_way is not None:
            # A Shared copy needs permission; it stays in its way.
            if self.hit_path:
                self._touch_controller(set_index, hit_way)
            line = self._ways(set_index)[hit_way]
            line.reserved_by = endpoint
            self._used_mshr_slots.add(endpoint)
            status = MissStatus(
                slot=endpoint,
                line_address=line_address,
                set_index=set_index,
                way_index=hit_way,
                primary=request,
                write_intent=True,
            )
            self.mshrs[line_address] = status
            self.stats["store_upgrades"] += 1
            self.loop.after(
                self.tag_cycles, lambda status=status: self._begin_miss(status)
            )
        else:
            victim_way = self._victim(set_index)
            if victim_way is None:
                return
            allocated = self._allocate_miss(
                request, line_address, set_index, victim_way, endpoint
            )
            if allocated is None:
                return
            status = allocated
        record.status = status
        if source == "store":
            self.stats["store_acquisitions"] += 1
        else:
            self.borrowed = endpoint
            self.stats["store_lookaheads"] += 1

    def _pop_store(self) -> None:
        self.records.popleft()
        self.stats["store_records_installed"] += 1

    def occupancy(self) -> dict[str, int]:
        """Return the live endpoints, writeback slots, and store records."""
        return {
            "mshrs": len(self._used_mshr_slots),
            "writeback_slots": len(self._used_wb_slots),
            "store_records": len(self.records),
        }


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
        """Build the L1I, coherent L1D, sector adapter, prefetcher, L2, and AXI bridge.

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
        self.axi = AxiBridge(
            loop,
            self.soc,
            config.axi_data_bytes,
            config.axi_id_bits,
            config.axi_id_pool_size,
        )
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
            config.l2_id_bits,
            bimodal_insert=config.l2_bimodal_insert,
            buffered_writeback=True,
        )
        self.adapter = LineSizeAdapter(
            self.l2, config.l1_line_bytes, config.l2_line_bytes
        )
        self.prefetcher = StreamPrefetcher(loop, self.l2, config)
        self.l2.request_observer = self.prefetcher.observe
        self.l1d = CoherentL1d(loop, self.adapter, config)
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
        self.axi._account()
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
    rs_issued: bool = False  # left MEM_RS for the LQ or SQ
    fault: bool = False


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
        self._load_ready_cycles: dict[int, int] = {}
        self._early_ready_ids: set[int] = set()
        self._registered_cdb_count = 0
        self.l0_cache: dict[int, int] = {}
        self.fetch_state: dict[int, str] = {}
        self.next_dispatch = 0
        self.retired = 0
        self.int_rs_in_use = 0
        self.mem_rs_in_use = 0
        self.lq_in_use = 0
        self.sq_in_use = 0
        self.committed_stores: deque[RobEntry] = deque()
        self.next_store_launch = 0
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
        for dep in deps:
            if dep not in self.completed_ids:
                return False
            if (
                entry.op.kind in {"load", "store"}
                and self._load_ready_cycles.get(dep, 0) > self.loop.cycle
                and dep not in self._early_ready_ids
            ):
                return False
        return True

    def _complete_later(self, entry: RobEntry, delay: int) -> None:
        self.loop.after(delay, lambda entry=entry: self.completions.append(entry))

    def _issue(self) -> None:
        alu_issued = 0
        mem_issued = 0
        mem_rs_issued = 0

        # Disambiguate stores in O(N): the first unresolved store in ROB order
        # bounds all younger loads that could conflict.
        first_unresolved_store_id = None
        for r in self.rob:
            if r.op.kind == "store" and not self._deps_ready(r):
                first_unresolved_store_id = r.op.op_id
                break

        for entry in list(self.rob):
            if entry.issued or entry.done:
                continue
            op = entry.op
            if op.kind in {"load", "store"} and not entry.rs_issued:
                # MEM_RS issues one operation per cycle and frees its entry
                # at issue (reservation_station.sv); the LQ or SQ holds it on.
                if mem_rs_issued or not self._deps_ready(entry):
                    continue
                entry.rs_issued = True
                mem_rs_issued += 1
                self.mem_rs_in_use -= 1
                if op.kind == "store":
                    # An ordinary store marks its ROB entry done directly.
                    entry.issued = True
                    self.loop.after(1, lambda entry=entry: self._store_ready(entry))
                    continue
            elif not self._deps_ready(entry):
                continue
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
                    self.loop.after(1, lambda entry=entry: self._load_result(entry))
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
                    else:
                        entry.fault = True
                        self.stats["memory_faults"] += 1
                    self._load_result(entry)

                if self._is_local_bram(addr):
                    # Low BRAM is outside the cached tier: the load takes the
                    # SoC's local port and never reaches the L1D.
                    local_read = AxiTransaction(
                        address=addr,
                        is_write=False,
                        transaction_id=TransactionId("uncached", "fill", 0, 6),
                        complete=on_load_complete,
                        source="uncached",
                        axi_id=32,
                        bytes_size=8,
                    )
                    if not self.soc.submit_axi(local_read):
                        self.stats["load_local_backpressure"] += 1
                        continue
                    entry.issued = True
                    mem_issued += 1
                    self.stats["loads_issued"] += 1
                    self.stats["local_loads"] += 1
                    continue

                request = Request(
                    address=addr,
                    is_write=False,
                    source="l1d",
                    request_id=op.op_id,
                    complete=lambda ok, done=on_load_complete: self.loop.after(
                        self.config.l1d_return_cycles, lambda: done(ok)
                    ),
                    bytes_size=8,
                )
                if self.config.l1d_request_cycles:
                    self.loop.after(
                        self.config.l1d_request_cycles,
                        lambda request=request: self._submit_cached_load(request),
                    )
                elif not self.memory.l1d.submit(request):
                    self.stats["load_cache_backpressure"] += 1
                    continue
                entry.issued = True
                mem_issued += 1
                self.stats["loads_issued"] += 1

    def _submit_cached_load(self, request: Request) -> None:
        """Send a launched load after its LQ/router stage, retrying on no credit."""
        if not self.memory.l1d.submit(request):
            self.stats["load_cache_backpressure"] += 1
            self.loop.after(1, lambda: self._submit_cached_load(request))

    def _load_result(self, entry: RobEntry) -> None:
        """Free a load's LQ entry as its result enters the CDB stage.

        load_queue.sv frees the entry when cdb_stage captures the result,
        before the broadcast and long before retirement.
        """
        self.lq_in_use -= 1
        self.completions.append(entry)

    def _drain_cdb(self) -> None:
        early_lane_available = self._registered_cdb_count < self.config.cdb_width
        self._registered_cdb_count = 0
        self._early_ready_ids.clear()
        if not self.completions:
            return
        self.completions.sort(
            key=lambda e: (0 if e.op.kind == "load" else 1, e.op.op_id)
        )
        admitted = self.completions[: self.config.cdb_width]
        self._registered_cdb_count = len(admitted)
        self.completions = self.completions[self.config.cdb_width :]
        if self.completions:
            self.stats["cdb_contention"] += len(self.completions)
        for entry in admitted:
            entry.done = True
            self.completed_ids.add(entry.op.op_id)
            if entry.op.kind == "load":
                self._load_ready_cycles[entry.op.op_id] = self.loop.cycle + 1
                if (
                    self.config.early_load_wakeup
                    and early_lane_available
                    and not entry.fault
                ):
                    self._early_ready_ids.add(entry.op.op_id)
                    early_lane_available = False
                    self.stats["early_load_tokens"] += 1
            if entry.op.kind in {"alu", "branch"}:
                self.int_rs_in_use -= 1
                if entry.op.kind == "branch" and entry.op.mispredict:
                    self.frontend_blocked_until = max(
                        self.frontend_blocked_until,
                        self.loop.cycle + self.config.branch_recovery_cycles,
                    )
                    self.stats["branch_mispredicts"] += 1
            self.stats["completed"] += 1

    def _store_ready(self, entry: RobEntry) -> None:
        """Record an issued store's address and data in its SQ entry."""
        entry.done = True
        self.completed_ids.add(entry.op.op_id)
        self.stats["completed"] += 1

    def _drain_stores(self) -> None:
        """Launch the oldest committed store into the L1D's store records.

        A cached store launches when no other write is in flight
        (``store_queue.sv``); the L1D acknowledges it a cycle after capture,
        which frees its SQ entry. The launch updates a resident L0 dword.
        """
        if not self.committed_stores or self.loop.cycle < self.next_store_launch:
            return
        address = self.committed_stores[0].op.data_address or 0
        if self._is_local_bram(address):
            self._drain_local_store(address)
            return
        l1d = self.memory.l1d
        if not l1d.store_ready():
            self.stats["store_drain_backpressure"] += 1
            return
        self.committed_stores.popleft()
        l1d.push_store(address)
        self.next_store_launch = self.loop.cycle + self.config.store_drain_cycles
        self.loop.after(1, self._store_acknowledged)
        self.stats["stores_drained"] += 1
        if self.config.l0_cache_depth > 0:
            dword = address >> 3
            l0_idx = dword % self.config.l0_cache_depth
            if self.l0_cache.get(l0_idx) == dword:
                self.stats["l0_store_updates"] += 1

    def _is_local_bram(self, address: int) -> bool:
        """Return whether address lies in the low-BRAM aperture."""
        soc = self.config.soc
        return soc.bram_base <= address < soc.bram_base + soc.bram_bytes

    def _drain_local_store(self, address: int) -> None:
        """Write the oldest committed store to low BRAM through the local port.

        The write frees its SQ entry when the port answers, and a resident
        L0 dword takes the new value.
        """
        write = AxiTransaction(
            address=address,
            is_write=True,
            transaction_id=TransactionId("uncached", "writeback", 0, 6),
            complete=lambda _ok: self._store_acknowledged(),
            source="uncached",
            axi_id=32,
            bytes_size=8,
        )
        if not self.soc.submit_axi(write):
            self.stats["store_drain_backpressure"] += 1
            return
        self.committed_stores.popleft()
        self.next_store_launch = self.loop.cycle + self.config.store_drain_cycles
        self.stats["stores_drained"] += 1
        self.stats["local_stores"] += 1
        if self.config.l0_cache_depth > 0:
            dword = address >> 3
            if self.l0_cache.get(dword % self.config.l0_cache_depth) == dword:
                self.stats["l0_store_updates"] += 1

    def _store_acknowledged(self) -> None:
        self.sq_in_use -= 1

    def _retire(self) -> None:
        retired = 0
        while retired < self.config.retire_width and self.rob:
            entry = self.rob[0]
            if not entry.done:
                self.stats["retire_head_not_ready"] += 1
                break
            self.rob.popleft()
            self.retired += 1
            retired += 1
            self.stats["retired"] += 1
            if entry.op.kind == "store":
                # A committed store keeps its SQ entry until it drains.
                self.committed_stores.append(entry)

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
        if self.sq_in_use >= self.config.store_queue_entries:
            self.stats["sq_full_cycles"] += 1
        records = len(self.memory.l1d.records)
        if records > self.max_occupancy["store_records"]:
            self.max_occupancy["store_records"] = records

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
            self._drain_stores()
            # The L1D controller takes a grant or the head store, then a load,
            # then deferred work, a lent store endpoint, and look-ahead last.
            self.memory.l1d.step()
            self.memory.l1d.service_replays()
            self._issue()
            self.memory.l1d.step_after_loads()
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


def workload_coremark(seed: int, operations: int = 3600) -> list[MicroOp]:
    """Model CoreMark kernel micro-ops: list traversal, matrix ops, state machine & CRC.

    Its data starts cold in DDR. L0 misses use the coherent L1D's hit path
    or controller, and the length sets how far the cold start
    weighs against the loops' steady state. The CI check compares the BRAM
    tier's ``coremark_bram`` instead.
    """
    return _coremark_ops(operations, 0x8000_0000, 0x1_0000)


def workload_coremark_bram(seed: int, operations: int = 1200) -> list[MicroOp]:
    """Model the CoreMark kernels in the BRAM tier, as CI's capture runs them.

    Its data lies in low BRAM, whose loads and stores take the SoC's local
    port and never reach the coherent L1D, so the length needs no tuning for
    a cold start.
    """
    return _coremark_ops(operations, 0x0000_0000, 0x8000)


def _coremark_ops(operations: int, region: int, stride: int) -> list[MicroOp]:
    """Return the CoreMark micro-ops with its arrays stride bytes apart in region."""
    b = ProgramBuilder()
    code_base = region + 0x2000
    data_base = region + stride
    matrix_base = region + 2 * stride
    list_base = region + 3 * stride
    crc_table_base = region + 4 * stride

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

# Workloads outside the sweeps: the CI check's BRAM-tier stand-in for the capture.
STANDIN_WORKLOADS: dict[str, Callable[[int], list[MicroOp]]] = {
    "coremark_bram": workload_coremark_bram,
}


def _named_workloads() -> dict[str, Callable[[int], list[MicroOp]]]:
    """Return the sweep workloads and the stand-ins by name."""
    return {**WORKLOADS, **STANDIN_WORKLOADS}


def run_workload(config: ModelConfig, workload_name: str, seed: int) -> dict[str, Any]:
    """Run a named workload on config and return the result.

    The result also names the workload, its seed, and its micro-op count.
    The CoreMark workload starts with every fetch line ready.
    """
    if workload_name not in _named_workloads():
        raise KeyError(workload_name)
    program = _named_workloads()[workload_name](seed)
    pipeline = FrostPipeline(config, program)
    if workload_name.startswith("coremark"):
        for op in program:
            line = pipeline._fetch_line(op.fetch_address)
            pipeline.fetch_state[line] = "ready"
    result = pipeline.run()
    result["workload"] = workload_name
    result["seed"] = seed
    result["micro_ops"] = len(program)
    return result


def run_memory_kernel(
    config: ModelConfig,
    kernel: str,
    scale_shift: int = 4,
    mlp_lines: int = 512,
    passes: int = 1,
) -> dict[str, Any]:
    """Run a DDR loop body with cold data, warm fetches, and explicit dependencies.

    Repeated passes share cache contents. The MLP bodies assume their ring
    is prepared and evicted. DDR bench reads assume zeroed backing memory.
    Setup, eviction, profiling, UART, and data verification are outside the
    modeled region.
    """
    if passes < 1:
        raise ValueError("passes must be positive")
    builder = ProgramBuilder()
    for _ in range(passes):
        build_kernel(builder, kernel, scale_shift, mlp_lines)
    pipeline = FrostPipeline(config, builder.ops)
    for op in builder.ops:
        pipeline.fetch_state[pipeline._fetch_line(op.fetch_address)] = "ready"
    result = pipeline.run(max_cycles=20_000_000)
    result["workload"] = kernel
    result["workload_parameters"] = {
        "scale_shift": scale_shift,
        "mlp_lines": mlp_lines,
        "passes": passes,
        "initial_data_cache": "cold",
        "instruction_fetch": "warm",
        "backing_data": "prepared_ring" if kernel.startswith("ddr_mlp_") else "zero",
    }
    result["micro_ops"] = len(builder.ops)
    return result


def load_config(path: Path | None) -> ModelConfig:
    """Read model settings from a JSON object, with defaults for omitted fields."""
    if path is None:
        return ModelConfig()
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("configuration must be a JSON object")
    name = data.pop("name", "experiment")
    return with_config(ModelConfig(), name, **data)


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
    """Read instruction records with addresses and backward dependencies.

    JSONL records contain kind, fetch_address or pc, data_address, and
    depends_on. Optional op_id values must be consecutive from zero.
    CSV and TSV columns are pc, kind, data_address, depends_on, mispredict;
    semicolons separate dependency IDs. Calibration events are rejected
    because they do not describe an architectural instruction stream.
    """
    if max_ops is not None and max_ops < 1:
        raise ValueError("max_ops must be positive")
    ops: list[MicroOp] = []
    text = path.read_text(encoding="utf-8")
    is_jsonl = path.suffix.lower() == ".jsonl" or text.lstrip().startswith("{")

    def integer(value: Any) -> int:
        if isinstance(value, bool) or not isinstance(value, (int, str)):
            raise ValueError("instruction IDs and addresses must be integers")
        return int(value, 0) if isinstance(value, str) else value

    for line_number, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        if is_jsonl:
            record = json.loads(line)
            if not isinstance(record, dict):
                raise ValueError(f"line {line_number}: expected an instruction object")
            if "event" in record:
                raise ValueError(
                    "calibration events cannot be replayed as instructions; "
                    "supply instruction addresses and dependencies"
                )
            op_id = len(ops)
            if integer(record.get("op_id", op_id)) != op_id:
                raise ValueError("instruction IDs must be consecutive from zero")
            kind = str(record["kind"]).lower()
            pc = record.get("fetch_address", record.get("pc"))
            if pc is None:
                raise ValueError("instruction record has no fetch address")
            data = record.get("data_address", record.get("addr"))
            dependencies = record.get("depends_on", [])
            if not isinstance(dependencies, list):
                raise ValueError("depends_on must be an array of instruction IDs")
            deps = tuple(integer(dep) for dep in dependencies)
            mispredict = record.get("mispredict", False)
            if not isinstance(mispredict, bool):
                raise ValueError("mispredict must be a boolean")
        else:
            if line.startswith("#"):
                continue
            parts = [part.strip() for part in line.replace("\t", ",").split(",")]
            if parts[0].lower() == "pc":
                continue
            if len(parts) < 2:
                raise ValueError(f"line {line_number}: expected pc and kind")
            op_id = len(ops)
            pc, kind = parts[0], parts[1].lower()
            data = (
                parts[2]
                if len(parts) > 2 and parts[2] not in {"", "null", "None"}
                else None
            )
            deps = (
                tuple(integer(dep) for dep in parts[3].split(";"))
                if len(parts) > 3 and parts[3] not in {"", "()"}
                else ()
            )
            if len(parts) > 4 and parts[4].lower() not in {
                "0",
                "1",
                "false",
                "true",
                "",
            }:
                raise ValueError("mispredict must be 0, 1, false, or true")
            mispredict = len(parts) > 4 and parts[4].lower() in {"1", "true"}
        if kind not in {"alu", "branch", "load", "store"}:
            raise ValueError(f"unsupported instruction kind: {kind}")
        if any(dep < 0 or dep >= op_id for dep in deps):
            raise ValueError("dependencies must name earlier instructions")
        if kind in {"load", "store"} and data is None:
            raise ValueError("memory instructions require data_address")
        fetch_address = integer(pc)
        data_address = None if data is None else integer(data)
        if fetch_address < 0 or (data_address is not None and data_address < 0):
            raise ValueError("instruction addresses must be nonnegative")
        ops.append(MicroOp(op_id, kind, fetch_address, data_address, deps, mispredict))
        if max_ops is not None and len(ops) >= max_ops:
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
        if workload_name not in _named_workloads():
            raise KeyError(
                f"Unknown workload: {workload_name}. Available: {sorted(_named_workloads())}"
            )
        program = _named_workloads()[workload_name](seed)

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
                "fact": "soc_axi_slave routes physical DDR addresses [0x8000_0000, +DdrCapacityBytes) to a single 5-bit-ID, 512-bit DDR AXI port (backed in simulation by axi_behavioral_memory with latency=80, NUM_SLOTS=max(L2MaxSlots,8), optional LFSR jitter and reorder) and routes low BRAM/MMIO to a single local port.",
                "source": "hw/rtl/soc_top/soc_axi_slave.sv:130-238; hw/rtl/soc_top/soc_top.sv:35-39, 396-399, 1396-1430; hw/rtl/lib/cache/axi_behavioral_memory.sv:18-67",
            },
            {
                "fact": "Load Queue direct-mapped L0 Data Cache (NormalLqL0Depth = 512 dword entries) provides 1-cycle fast-path bypass for cached hits; EARLY_LOAD_WAKEUP enables 1-cycle dependent scheduling.",
                "source": "hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/lq_l0_cache.sv:18-47; hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv:1926-1928; hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv:43, 2806-2817",
            },
            {
                "fact": "At ade0de67, cpu_top passes L1D_NUM_MSHR=8 request endpoints, L2_NUM_MSHR=8 home fills, L2_PREFETCH=1, L2_PREFETCH_DISTANCE=8 and L2_PREFETCH_INFLIGHT=3; the model's default keeps four L2 miss slots, and a board configuration states eight.",
                "source": "hw/rtl/cpu_top/cpu_top.sv:41-47 (ade0de67)",
            },
            {
                "fact": "MEM_RS frees an entry when it issues, and the LQ frees an entry when cdb_stage captures its result; an ordinary store marks its ROB entry done at issue, commits, and keeps its SQ entry until the L1D acknowledges its launch.",
                "source": "hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/reservation_station.sv:2830-2833, 2882-2902; hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv:3218-3221; hw/rtl/cpu_and_mem/cpu/tomasulo/README.md:21-27; hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/README.md:77-117 (ade0de67)",
            },
            {
                "fact": "Cached stores launch from the SQ one at a time: a launch waits for the previous write's done and the L1D's record credit, and the L1D acknowledges a captured store on the next cycle.",
                "source": "hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/store_queue.sv:913-924, 964-976; hw/rtl/lib/cache/coherence_store_buffer.sv:59-75 (ade0de67)",
            },
            {
                "fact": "The coherent L1D buffers committed stores in four ordered 32-byte records; only the youngest unsealed record combines, a record seals at 32 contributors or when the head is selected, and every record installs at the head. Endpoint 0 carries the head's GetM and at most one load endpoint is lent to a younger record's GetM.",
                "source": "hw/rtl/lib/cache/coherence_store_buffer.sv:17-117; hw/rtl/lib/cache/coherence_l1d.sv:803-811, 1733-1761, 2202-2210 (ade0de67)",
            },
            {
                "fact": "One L1D controller serves one operation at a time in Idle priority order (probe, grant, SC, atomic write, head store, lookahead store, read, maintenance, stream hint). A lookup passes Idle, Lookup, the array's tag read (1 cycle) and its reply; a hit adds the 2-cycle data read, an acquisition its Acquire cycle, and an installation or store update its Update, 1-cycle array write and UpdateWait.",
                "source": "hw/rtl/lib/cache/coherence_l1d.sv:2143-2518; hw/rtl/lib/cache/coherence_array.sv:26-28, 186-194, 378-431 (ade0de67)",
            },
            {
                "fact": "The L1D offers a new load to a tag-copy/all-way-data hit port in the following cycle and completes a hit slot four cycles after arrival. The controller keeps misses and stores; a selected read held by the hit path gets a tags-only shadow with no replacement touch or duplicate answer. The hit port refuses data-bank claims, same-set writes, probe service and blocked sectors. Hit reports train the stream detector through two entries, yielding to controller reports and dropping overflow.",
                "source": "hw/rtl/lib/cache/coherence_l1d.sv:1990-2097; hw/rtl/lib/cache/coherence_array.sv:296-361; hw/rtl/lib/cache/README.md:511-525 (4d2a20a3)",
            },
            {
                "fact": "Load misses take the lowest free load endpoint; a miss on a sector that a live endpoint holds attaches and looks up again after the installation; a demand grant answers its load in its Lookup cycle; each endpoint stays live through U.",
                "source": "hw/rtl/lib/cache/coherence_l1d.sv:1218-1231, 1297-1315, 2233-2238, 2339-2351; hw/rtl/lib/cache/README.md:316, 350-355, 369-372 (ade0de67)",
            },
            {
                "fact": "Stream look-ahead: three adjacent demand sector misses confirm a stream; the cursor stays within eight sectors past the frontier and within a 4 KiB page; hints use the highest PrefetchCount load endpoints (2 with four or more endpoints, 1 with three), demand may use every load endpoint, and a hint is the controller's lowest-priority selection.",
                "source": "hw/rtl/lib/cache/coherence_read_stream.sv:17-82; hw/rtl/lib/cache/coherence_l1d.sv:550-553, 611-638, 692-713, 2227-2231, 2304-2309 (ade0de67)",
            },
            {
                "fact": "The home's prefetch agent trains a four-stream table on accepted hart GetS and GetM, L2 hits included; it confirms on two consecutive lines, requests up to eight lines ahead within the page, loads a request only while more than FILLS/4 fills are free, holds each of three identities from D through U, and the home fills only with two available ways and, for a valid victim, two free writeback slots.",
                "source": "hw/rtl/lib/cache/coherence_prefetch_agent.sv:1-36, 80-115; hw/rtl/lib/cache/l2_stream_prefetcher.sv:17-41, 186-249; hw/rtl/lib/cache/coherence_home.sv:28-32, 785-802, 949-958 (ade0de67)",
            },
        ],
        "implemented_features": [
            "Explicit CpuTopModel + SocTopModel separation across the 6-bit-ID, 512-bit AXI4 boundary so downstream projects can replace SocTopModel or DdrController independently.",
            "Two-wide dispatch/retire, bounded ROB/RS/LQ/SQ with MEM_RS release at issue and LQ release at the result, out-of-order load/ALU completion, two-lane CDB contention, and committed stores draining from the SQ into the L1D's store records.",
            "Load Queue L0 Data Cache (256 dword entries) with 1-cycle CDB fast-path bypass and fill from L1D memory responses.",
            "Coherent L1D with an independent four-cycle hit path, tags-only controller shadows, two-entry hit stream training, request endpoints held through U, attached loads that look up again after installation, stream look-ahead on the highest endpoints, four ordered store records with one lent endpoint, and buffered victim writebacks.",
            "Separate L1I and L1D caches; 32-byte to 64-byte sector adapter; L2 with the home's stream prefetch agent; fill ownership; coalescing; writeback slots; write intent; cache-line dirty state.",
            "Explicit cache lower transaction IDs ({type, slot}), 64-byte single-beat AXI transfers, soc_axi_slave physical address decode (DDR vs. local BRAM/MMIO), and a single-channel 512-bit AXI DDR model matching axi_behavioral_memory.sv.",
            "Deterministic workload generators, sweep driver, self-tests, and machine-readable bottleneck counters.",
        ],
        "assumptions_not_claimed_as_rtl_calibration": [
            "Cache stage timing, insertion-LFSR phase, and pipeline stage latencies are abstractions that require cycle-by-cycle calibration.",
            "The L1D controller's priority omits probes, atomics, maintenance and the credited read turn's exact edges; the SQ launch interval, the C-to-U interval (coherence_release_cycles), and the L2 home's lookup and fill timing are abstractions, and the home's instruction prefetch table and DMA pause are not modeled.",
            "The default DDR endpoint models FROST's single-channel axi_behavioral_memory.sv (LATENCY=80, NUM_SLOTS=max(L2MaxSlots,8)); board DDR4 MIG refresh and bank/row timing require hardware or VIP trace calibration.",
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
    soc = SocTopModel(ModelConfig(ddr=DdrConfig(latency_cycles=30)), soc_loop)
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
- `soc_top`: `soc_axi_slave.sv` decodes physical DDR addresses (`0x8000_0000..`) to a single 5-bit-ID, 512-bit DDR AXI port (connected in simulation to `axi_behavioral_memory.sv` with `LATENCY=80`, `NUM_SLOTS=max(L2MaxSlots, 8)`) and routes low BRAM/MMIO accesses to a single local port.

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

The cache stage latencies, insertion-LFSR phase, workload instruction mixes, and branch rates are explicit modelling assumptions. Treat sweep results as comparative sensitivity directions until calibrated against Verilator RTL traces.
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
    run.add_argument("--workload", choices=sorted(_named_workloads()), required=True)
    run.add_argument("--seed", type=int, default=11)
    run.add_argument("--out", type=Path, required=True)
    run.add_argument("--config-file", type=Path)
    memory_run = sub.add_parser("memory-run", help="Run a DDR benchmark loop body")
    memory_run.add_argument("--kernel", choices=KERNELS, required=True)
    memory_run.add_argument("--scale-shift", type=int, default=4)
    memory_run.add_argument("--mlp-lines", type=int, default=512)
    memory_run.add_argument("--passes", type=int, default=1)
    memory_run.add_argument("--config-file", type=Path)
    memory_run.add_argument("--out", type=Path, required=True)
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
        choices=sorted(get_design_variants()),
        help="Design variant configuration to use (default: baseline)",
    )
    replay.add_argument("--out", type=Path, help="Optional output JSON path")
    explore = sub.add_parser(
        "explore",
        help="Explore design variants and generate optimization suggestions for FROST",
    )
    explore.add_argument(
        "--workload",
        choices=sorted(_named_workloads()),
        help="Built-in workload to evaluate",
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
        dump_json(
            args.out,
            run_workload(load_config(args.config_file), args.workload, args.seed),
        )
        return 0
    if args.command == "memory-run":
        dump_json(
            args.out,
            run_memory_kernel(
                load_config(args.config_file),
                args.kernel,
                args.scale_shift,
                args.mlp_lines,
                args.passes,
            ),
        )
        return 0
    if args.command == "report":
        sweep = json.loads(args.sweep.read_text(encoding="utf-8"))
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(report_markdown(sweep), encoding="utf-8")
        return 0
    if args.command == "replay":
        variants = get_design_variants()
        config = variants[args.config]
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
