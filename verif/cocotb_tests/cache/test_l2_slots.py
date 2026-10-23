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

"""L2 miss-slot parallelism with every port missing at once.

Every upstream port keeps as many reads in flight as it can, each to a line
no cache holds: four L1D readers, two L1I readers, the walker, and three DMA
readers. Each reader's lines take one L2 set of their own, and the L1
readers' lines one L1 set each, so a miss waits only for a free miss slot,
not for another reader's line. The bench reports
cycles per line, the mean number of busy L2 miss slots (the integral of the
L2's miss_outstanding event), the L2's slot-full and conflict stalls, and
for each port its longest wait for one read and the cycle its last reader
finished, in ``results/l2_slots_mshr<N>_wb<M>_mem<latency>.json``. Every
read must return its data, and none may wait more than WAIT_LIMIT cycles.
"""

import json
import os
from typing import Any

import cocotb
from cocotb.triggers import FallingEdge, Lock

from cocotb_tests.cache.test_frost_cache import (
    BASE_ADDR,
    CacheGeometry,
    ReferenceModel,
    _monitor_perf_events,
    _new_perf_counts,
    _setup,
    cache_geometry,
)
from cocotb_tests.cache.test_frost_cache_concurrency import _Collector, _fire
from cocotb_tests.cache.test_frost_cache_dma import LoadQueueStub

SLOTS_BASE = BASE_ADDR + 0xE00000
LINES_PER_READER = 48
# The longest any one read may wait. With four L2 miss slots, a DMA read
# waited 4,277 cycles while the DMA sequencer issued its lowest-numbered
# entry first, which let later reads of other entries overtake it; oldest
# first, the longest wait of any port is 280 cycles.
WAIT_LIMIT = 1000
# (port, local ids it alternates between) for each reader.
READERS = (
    ("up", (0, 4)),
    ("up", (1, 5)),
    ("up", (2, 6)),
    ("up", (3, 7)),
    ("iup", (0, 4)),
    ("iup", (1, 5)),
    ("wup", (0, 1)),
    ("dma", (0, 4)),
    ("dma", (1, 5)),
    ("dma", (2, 6)),
)


def _line(geom: CacheGeometry, reader: int, n: int) -> int:
    """Return reader's n-th line: L2 set `reader`, a new tag each time.

    An L2 way is a multiple of an L1 way, so the reader's lines also share an
    L1 set, a different one for each L1 reader.
    """
    return SLOTS_BASE + n * geom.l2_way_bytes + reader * geom.l2_line


async def _reader(
    dut: Any,
    k: int,
    port: str,
    ids: tuple[int, int],
    col: _Collector,
    lock: Lock,
    clock: _Collector,
    timing: dict[str, dict[str, int]],
) -> None:
    """Read reader k's lines one at a time; track its port's waits in timing.

    A read's wait runs from the cycle it is ready to go, before its port's
    other readers or the port's ready can hold it, to its response.
    """
    model = ReferenceModel()
    geom = cache_geometry(dut)
    port_timing = timing.setdefault(port, {"worst_wait": 0, "finished": 0})
    for n in range(LINES_PER_READER):
        req_id = ids[n % 2]
        addr = _line(geom, k, n)
        asked = clock.cycle
        async with lock:
            await _fire(dut, port, write=False, addr=addr, req_id=req_id)
        _, got = await col.wait_for(req_id)
        port_timing["worst_wait"] = max(port_timing["worst_wait"], clock.cycle - asked)
        assert got == model.read_line(addr), f"{port} read @0x{addr:08x}"
    port_timing["finished"] = max(port_timing["finished"], clock.cycle)


@cocotb.test()
async def test_l2_slot_parallelism(dut: Any) -> None:
    """Measure cycles per line and miss-slot use with every port missing."""
    await _setup(dut)
    geom = cache_geometry(dut)
    assert geom.l2_way_bytes // geom.l2_line >= len(READERS), "a reader without a set"
    lq = LoadQueueStub(dut)
    l2 = dut.cache_hierarchy.cluster_cache.l2_cache
    num_mshr = int(l2.NUM_MSHR.value)
    num_wb = int(l2.NUM_WB.value)
    mem_latency = int(dut.MEM_LATENCY.value)
    counts = _new_perf_counts()
    stop = [False]
    cocotb.start_soon(_monitor_perf_events(dut, counts, stop))
    ports = ("up", "iup", "wup", "dma")
    cols = {port: _Collector(dut, port) for port in ports}
    locks = {port: Lock() for port in ports}
    timing: dict[str, dict[str, int]] = {}

    clock = cols["up"]
    start = clock.cycle
    readers = [
        cocotb.start_soon(
            _reader(dut, k, port, ids, cols[port], locks[port], clock, timing)
        )
        for k, (port, ids) in enumerate(READERS)
    ]
    for reader in readers:
        await reader
    cycles = cols["up"].cycle - start
    stop[0] = True
    await FallingEdge(dut.i_clk)

    lines = LINES_PER_READER * len(READERS)
    results = {
        "l2_num_mshr": num_mshr,
        "l2_num_wb": num_wb,
        "mem_latency": mem_latency,
        "lines": lines,
        "cycles": cycles,
        "cycles_per_line": round(cycles / lines, 3),
        "mean_busy_miss_slots": round(counts["l2"]["miss_outstanding"] / cycles, 3),
        "l2_slot_full_stalls": counts["l2"]["slot_full_stall"],
        "l2_conflict_stalls": counts["l2"]["conflict_stall"],
        "worst_wait_cycles": {port: timing[port]["worst_wait"] for port in ports},
        "finish_cycles": {port: timing[port]["finished"] - start for port in ports},
    }
    dut._log.info("L2 SLOTS %s", " ".join(f"{k}={v}" for k, v in results.items()))
    out_dir = os.path.join(os.getcwd(), "results")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(
        out_dir, f"l2_slots_mshr{num_mshr}_wb{num_wb}_mem{mem_latency}.json"
    )
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(results, handle, indent=2)
    for col in cols.values():
        col.stop()
    lq.stop()
    for port in ports:
        worst = timing[port]["worst_wait"]
        assert worst <= WAIT_LIMIT, f"a {port} read waited {worst} cycles"
