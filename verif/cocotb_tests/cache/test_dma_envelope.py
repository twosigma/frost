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

"""DMA-port service envelope measurement (frost_cache_test_harness).

Not a pass/fail bench: it streams tagged line requests through the coherent
DMA port with a chosen number in flight and reports, per scenario and depth,
the cycles per line, the mean and maximum request latency, and the average
residence of a request in each sequencer phase (ADMIT, PROBE, PROBE_WAIT,
INVAL, ISSUE, RESP). The registry builds it once per candidate lock count
(`dma_envelope_lock<N>`, -GNUM_DMA_LOCK), once more for three locks at the
full-system DDR model latency (`dma_envelope_lock3_mem30`), and once with the
production 2 MiB L2 (`dma_envelope_lock3_big_l2`); each build measures every
scenario its geometry supports at every producer depth. Scenarios: full-line
writes to absent lines, to lines clean or dirty in the L1D, and to lines the
L2 holds but the L1D does not (`write_l2_only`, only with an L2 more than
twice the L1D, which keeps the lines in the L2 while aliasing reads evict
them from the L1D); partial-strobe writes to absent lines (a fetch from
memory at the L2); reads of absent lines and of lines dirty in the L1D;
writes under a data-side miss flood; and a stream four times the L2
(`write_beyond_l2`, only with the harness's 4 KiB L2).

The bench plays the load queue with a one-cycle admit and invalidation delay.
Results also land in
`results/dma_envelope_lock<N>_mem<latency>_l2_<KiB>k.json`, which records the
geometry and the memory latency.
"""

import json
import os
from typing import Any

import cocotb
from cocotb.triggers import FallingEdge

from cocotb_tests.cache.test_frost_cache import (
    BASE_ADDR,
    LINE_BYTES,
    RESP_TIMEOUT_CYCLES,
    _line_transaction,
    _perf_field,
    _setup,
)
from cocotb_tests.cache.test_frost_cache_concurrency import _fire
from cocotb_tests.cache.test_frost_cache_dma import FULL, LoadQueueStub, _pattern

STREAM_LINES = 64
BIG_LINES = 512
DEPTHS = (1, 2, 3, 4, 6, 8)
PHASES = ("FREE", "ADMIT", "PROBE", "PROBE_WAIT", "INVAL", "ISSUE", "RESP")
# Everything stays inside the harness's memory model. At the registry's
# 128 KiB L1D, the flood's aliasing lines occupy the bottom 2 MiB (16 tags of
# one L1D index), the 64-line streams take 4 KiB regions above that,
# write_l2_only's aliasing reads land EVICT_ALIAS_L1S L1D sizes (256 KiB)
# above its stream, past every stream region, and the 512-line streams take
# 16 KiB regions above those.
FLOOD_REGION = BASE_ADDR
SMALL_BASE = BASE_ADDR + 0x200000
SMALL_STRIDE = 0x1000
EVICT_ALIAS_L1S = 2
BIG_BASE = BASE_ADDR + 0x300000
BIG_STRIDE = 0x4000


class _PhaseSampler:
    """Accumulate, per cycle, the sequencer entries in each phase and L2 hits."""

    def __init__(self, dut: Any) -> None:
        self._dut = dut
        self._seq = dut.cache_hierarchy.dma_sequencer
        self.num_lock = int(self._seq.NUM_LOCK.value)
        self.counts = [0] * len(PHASES)
        self.l2_hits = 0
        self.l2_misses = 0
        self.active = False
        self._task = cocotb.start_soon(self._run())

    async def _run(self) -> None:
        while True:
            await FallingEdge(self._seq.i_clk)
            if not self.active:
                continue
            for k in range(self.num_lock):
                state = int(self._seq.state_q[k].value)
                self.counts[state] += 1
            self.l2_hits += _perf_field(self._dut, "l2", "hit")
            self.l2_misses += _perf_field(self._dut, "l2", "miss")

    def reset(self) -> None:
        """Clear the accumulated counts."""
        self.counts = [0] * len(PHASES)
        self.l2_hits = 0
        self.l2_misses = 0

    def stop(self) -> None:
        """Stop sampling."""
        self._task.cancel()


class _DmaStream:
    """Issue DMA requests keeping up to `depth` in flight; record timings."""

    def __init__(self, dut: Any, depth: int) -> None:
        self._dut = dut
        self.depth = depth
        self.cycle = 0
        self.outstanding: dict[int, int] = {}  # id -> issue cycle
        self.latencies: list[int] = []
        self.first_fire = -1
        self.last_resp = -1
        self._free = list(range(8))
        self._task = cocotb.start_soon(self._collect())

    async def _collect(self) -> None:
        dut = self._dut
        while True:
            await FallingEdge(dut.i_clk)
            self.cycle += 1
            if int(dut.o_dma_resp_valid.value) == 1:
                rid = int(dut.o_dma_resp_id.value)
                assert rid in self.outstanding, f"response for id {rid} not outstanding"
                self.latencies.append(self.cycle - self.outstanding.pop(rid))
                self.last_resp = self.cycle
                self._free.append(rid)

    async def run(self, requests: list[tuple[bool, int, int, int]]) -> None:
        """Issue (write, addr, wdata, wstrb) requests and wait for every response."""
        dut = self._dut
        for write, addr, wdata, wstrb in requests:
            for _ in range(RESP_TIMEOUT_CYCLES):
                if len(self.outstanding) < self.depth and self._free:
                    break
                await FallingEdge(dut.i_clk)
            else:
                raise AssertionError("DMA stream stalled waiting for a free slot")
            rid = self._free.pop(0)
            self.outstanding[rid] = self.cycle + 1  # fires at the next rising edge
            await _fire(
                dut, "dma", write=write, addr=addr, req_id=rid, wdata=wdata, wstrb=wstrb
            )
            if self.first_fire < 0:
                self.first_fire = self.cycle
        for _ in range(RESP_TIMEOUT_CYCLES):
            if not self.outstanding:
                break
            await FallingEdge(dut.i_clk)
        else:
            raise AssertionError("DMA stream never drained")

    def stop(self) -> None:
        """Stop collecting responses."""
        self._task.cancel()


def _l1_alias(dut: Any) -> int:
    """Return the L1D size: +size is the same index with another tag."""
    return int(dut.L1_CACHE_BYTES.value)


def _l2_holds_l1_evictions(dut: Any) -> bool:
    """Report whether write_l2_only's aliasing reads leave its lines in the L2.

    The reads sit EVICT_ALIAS_L1S L1D sizes above the lines: the same L1D
    index, and another L2 index only while that offset is below the L2 size.
    """
    return int(dut.L2_CACHE_BYTES.value) > EVICT_ALIAS_L1S * _l1_alias(dut)


def _stream_beyond_l2(dut: Any) -> bool:
    """Report whether the 512-line stream is at least four times the L2."""
    return BIG_LINES * LINE_BYTES >= 4 * int(dut.L2_CACHE_BYTES.value)


async def _cpu_touch(dut: Any, addrs: list[int], *, write: bool) -> None:
    """Make the data side read or write each line (resident clean or dirty)."""
    for i, addr in enumerate(addrs):
        if write:
            await _line_transaction(
                dut, write=True, addr=addr, wdata=_pattern(200 + i), wstrb=FULL
            )
        else:
            await _line_transaction(dut, write=False, addr=addr)


async def _evict_l1d(dut: Any, addrs: list[int]) -> None:
    """Push the given lines out of the direct-mapped L1D with aliasing reads."""
    alias = EVICT_ALIAS_L1S * _l1_alias(dut)
    for addr in addrs:
        await _line_transaction(dut, write=False, addr=addr + alias)


def _region(index: int) -> int:
    return SMALL_BASE + index * SMALL_STRIDE


def _write_stream(base: int, wstrb: int = FULL) -> list[tuple[bool, int, int, int]]:
    return [
        (True, base + i * LINE_BYTES, _pattern(i), wstrb) for i in range(STREAM_LINES)
    ]


def _read_stream(base: int) -> list[tuple[bool, int, int, int]]:
    return [(False, base + i * LINE_BYTES, 0, 0) for i in range(STREAM_LINES)]


async def _measure(
    dut: Any,
    sampler: _PhaseSampler,
    name: str,
    depth: int,
    requests: list[tuple[bool, int, int, int]],
    results: dict[str, Any],
) -> int:
    """Run one stream at one depth, log/record its numbers, return its L2 hits."""
    stream = _DmaStream(dut, depth)
    sampler.reset()
    sampler.active = True
    await stream.run(requests)
    sampler.active = False
    stream.stop()
    n = len(requests)
    total = stream.last_resp - stream.first_fire + 1
    per_line = total / n
    mean_lat = sum(stream.latencies) / n
    max_lat = max(stream.latencies)
    phases = {PHASES[i]: round(sampler.counts[i] / n, 2) for i in range(1, len(PHASES))}
    dut._log.info(
        "ENVELOPE %-16s depth=%d  cycles/line=%6.2f  lat mean=%6.1f max=%4d  "
        "L2 hit=%d miss=%d  %s",
        name,
        depth,
        per_line,
        mean_lat,
        max_lat,
        sampler.l2_hits,
        sampler.l2_misses,
        " ".join(f"{k}={v}" for k, v in phases.items()),
    )
    results.setdefault(name, {})[str(depth)] = {
        "cycles_per_line": round(per_line, 3),
        "latency_mean": round(mean_lat, 2),
        "latency_max": max_lat,
        "l2_hits": sampler.l2_hits,
        "l2_misses": sampler.l2_misses,
        "phase_residence": phases,
    }
    return sampler.l2_hits


async def _flood(dut: Any, stop: list[bool]) -> None:
    """Data-side miss stream: thrash one index with many tags, dirty victims."""
    n = 0
    alias = _l1_alias(dut)
    while not stop[0]:
        addr = FLOOD_REGION + (n % 16) * alias
        await _line_transaction(
            dut, write=True, addr=addr, wdata=_pattern(n), wstrb=FULL
        )
        n += 1


@cocotb.test()
async def test_dma_envelope(dut: Any) -> None:
    """Measure DMA-port cycles per line across scenarios and producer depths."""
    await _setup(dut)
    lq = LoadQueueStub(dut, admit_delay=1, inval_delay=1)
    sampler = _PhaseSampler(dut)
    num_lock = sampler.num_lock
    mem_latency = int(dut.MEM_LATENCY.value)
    l1_bytes = _l1_alias(dut)
    l2_bytes = int(dut.L2_CACHE_BYTES.value)
    l2_only = _l2_holds_l1_evictions(dut)
    beyond_l2 = _stream_beyond_l2(dut)
    dut._log.info(
        "ENVELOPE NUM_DMA_LOCK=%d MEM_LATENCY=%d L1D=%d L2=%d stream=%d lines",
        num_lock,
        mem_latency,
        l1_bytes,
        l2_bytes,
        STREAM_LINES,
    )
    skipped = [
        name
        for name, runs in (("write_l2_only", l2_only), ("write_beyond_l2", beyond_l2))
        if not runs
    ]
    if skipped:
        dut._log.info("ENVELOPE geometry skips %s", ", ".join(skipped))
    results: dict[str, Any] = {
        "num_dma_lock": num_lock,
        "mem_latency": mem_latency,
        "l1_cache_bytes": l1_bytes,
        "l2_cache_bytes": l2_bytes,
        "stream_lines": STREAM_LINES,
        "skipped_scenarios": skipped,
    }
    region = 0

    for depth in DEPTHS:
        # 1. Full-line writes to lines no cache holds.
        base = _region(region)
        region += 1
        await _measure(
            dut, sampler, "write_absent", depth, _write_stream(base), results
        )

        # 2. Lines clean in the L1D (read by the data side first).
        base = _region(region)
        region += 1
        addrs = [base + i * LINE_BYTES for i in range(STREAM_LINES)]
        await _cpu_touch(dut, addrs, write=False)
        await _measure(
            dut, sampler, "write_clean_l1d", depth, _write_stream(base), results
        )

        # 3. Lines dirty in the L1D (written by the data side first).
        base = _region(region)
        region += 1
        addrs = [base + i * LINE_BYTES for i in range(STREAM_LINES)]
        await _cpu_touch(dut, addrs, write=True)
        await _measure(
            dut, sampler, "write_dirty_l1d", depth, _write_stream(base), results
        )

        # 4. Lines the L2 holds but the L1D does not: read, then evicted from
        # the L1D by aliasing reads that keep them in a large enough L2.
        base = _region(region)
        region += 1
        if l2_only:
            addrs = [base + i * LINE_BYTES for i in range(STREAM_LINES)]
            await _cpu_touch(dut, addrs, write=False)
            await _evict_l1d(dut, addrs)
            hits = await _measure(
                dut, sampler, "write_l2_only", depth, _write_stream(base), results
            )
            assert hits == STREAM_LINES, (
                f"write_l2_only: {hits} of {STREAM_LINES} DMA writes hit in the L2"
            )

        # 5. Partial-strobe writes to absent lines: the L2 fetches the line.
        base = _region(region)
        region += 1
        await _measure(
            dut,
            sampler,
            "write_partial_abs",
            depth,
            _write_stream(base, wstrb=FULL & ~0x3),
            results,
        )

        # 6. Reads of absent lines and of lines dirty in the L1D (the TX path).
        base = _region(region)
        region += 1
        await _measure(dut, sampler, "read_absent", depth, _read_stream(base), results)
        base = _region(region)
        region += 1
        addrs = [base + i * LINE_BYTES for i in range(STREAM_LINES)]
        await _cpu_touch(dut, addrs, write=True)
        await _measure(
            dut, sampler, "read_dirty_l1d", depth, _read_stream(base), results
        )

        # 7. Full-line writes to absent lines under a data-side miss flood.
        base = _region(region)
        region += 1
        stop = [False]
        flood_task = cocotb.start_soon(_flood(dut, stop))
        for _ in range(40):
            await FallingEdge(dut.i_clk)
        await _measure(
            dut, sampler, "write_under_flood", depth, _write_stream(base), results
        )
        stop[0] = True
        await flood_task

        # 8. A stream four times the harness L2 (4 KiB = 128 lines).
        if beyond_l2:
            base = BIG_BASE + DEPTHS.index(depth) * BIG_STRIDE
            big = [
                (True, base + i * LINE_BYTES, _pattern(i), FULL)
                for i in range(BIG_LINES)
            ]
            await _measure(dut, sampler, "write_beyond_l2", depth, big, results)

    sampler.stop()
    lq.stop()
    out_dir = os.path.join(os.getcwd(), "results")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(
        out_dir,
        f"dma_envelope_lock{num_lock}_mem{mem_latency}_l2_{l2_bytes // 1024}k.json",
    )
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(results, handle, indent=2)
    dut._log.info("ENVELOPE results written to %s", path)
