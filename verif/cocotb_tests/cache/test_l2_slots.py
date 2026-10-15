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
readers. Each reader's lines take one L2 index of their own, so a miss waits
only for a free miss slot, not for another reader's line. The bench reports
cycles per line, the mean number of busy L2 miss slots (the integral of the
L2's miss_outstanding event), and the L2's slot-full and conflict stalls, in
``results/l2_slots_mshr<N>_wb<M>_mem<latency>.json``. No limit is asserted
beyond every read returning its data.
"""

import json
import os
from typing import Any

import cocotb
from cocotb.triggers import FallingEdge, Lock

from cocotb_tests.cache.test_frost_cache import (
    BASE_ADDR,
    ReferenceModel,
    _monitor_perf_events,
    _new_perf_counts,
    _setup,
)
from cocotb_tests.cache.test_frost_cache_concurrency import _Collector, _fire
from cocotb_tests.cache.test_frost_cache_dma import LoadQueueStub

SLOTS_BASE = BASE_ADDR + 0xE00000
L2_BYTES = 4096  # harness L2: a reader's next line keeps its L2 index
LINES_PER_READER = 48
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


def _line(reader: int, n: int) -> int:
    """Return reader's n-th line: L2 index 2 * reader, a new tag each time."""
    return SLOTS_BASE + n * L2_BYTES + reader * 128


async def _reader(
    dut: Any,
    k: int,
    port: str,
    ids: tuple[int, int],
    col: _Collector,
    lock: Lock,
    done: list[int],
) -> None:
    model = ReferenceModel()
    for n in range(LINES_PER_READER):
        req_id = ids[n % 2]
        addr = _line(k, n)
        async with lock:
            await _fire(dut, port, write=False, addr=addr, req_id=req_id)
        _, got = await col.wait_for(req_id)
        assert got == model.read_line(addr), f"{port} read @0x{addr:08x}"
    done.append(k)


@cocotb.test()
async def test_l2_slot_parallelism(dut: Any) -> None:
    """Measure cycles per line and miss-slot use with every port missing."""
    await _setup(dut)
    lq = LoadQueueStub(dut)
    l2 = dut.cache_hierarchy.l2_cache
    num_mshr = int(l2.NUM_MSHR.value)
    num_wb = int(l2.NUM_WB.value)
    mem_latency = int(dut.MEM_LATENCY.value)
    counts = _new_perf_counts()
    stop = [False]
    cocotb.start_soon(_monitor_perf_events(dut, counts, stop))
    ports = ("up", "iup", "wup", "dma")
    cols = {port: _Collector(dut, port) for port in ports}
    locks = {port: Lock() for port in ports}
    done: list[int] = []

    start = cols["up"].cycle
    readers = [
        cocotb.start_soon(_reader(dut, k, port, ids, cols[port], locks[port], done))
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
