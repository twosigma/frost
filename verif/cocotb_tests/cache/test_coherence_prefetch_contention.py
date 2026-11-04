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

"""Measure demand service while prefetch, dirty recalls and DMA share the home."""

import json
from typing import Any

import cocotb

from cocotb_tests.cache.test_coherence_prefetch import PrefetchHome


@cocotb.test()
async def demand_contention(dut: Any) -> None:
    """Report completed demand latency and useful bytes per cycle for each mix."""
    for delay in (30, 200):
        for scenario in ("cold_demand", "competing_streams", "dirty_dma"):
            b = PrefetchHome(dut)
            await b.reset()
            base = 0x80000000
            if scenario == "dirty_dma":
                for index in range(16):
                    address = base + index * b.line
                    grant = await b.start(1, address)
                    await b.finish(grant, written=True)
                    b.private[address] = (3, (index + 1) * 0x0101010101010101)
            base += 0x1000
            await b.prime(base, delay)
            await b.tick(35)
            latencies: list[int] = []
            dma_latencies: list[int] = []
            start = b.cycle
            count = 1 if scenario == "cold_demand" else 32
            await b.set(i_train_enable=int(scenario != "cold_demand"))
            for index in range(count):
                address = (
                    base + 0x4000
                    if scenario == "cold_demand"
                    else base + (index % 2) * 0x2000 + (index // 2 + 2) * b.line
                )
                issued = b.cycle
                await b.submit(0, address)
                expected = {0: address}
                if scenario == "dirty_dma":
                    dma_address = base + 0x6000 + index * b.line
                    q, _ = b.demand(7, dma_address, non_alloc=1)
                    expected[q] = dma_address
                    await b.submit(7, dma_address, non_alloc=1)
                while expected:
                    grant = await b.take_grant()
                    current = expected.pop(grant[1])
                    assert grant[3] == current and not grant[5]
                    assert grant[4] == b.expected(current)
                    elapsed = b.cycle - issued
                    (latencies if grant[1] == 0 else dma_latencies).append(elapsed)
                    await b.complete(grant)
            duration = b.cycle - start
            dut._log.info(
                "CONTENTION %s",
                json.dumps(
                    {
                        "scenario": scenario,
                        "memory_latency": delay,
                        "cycles": duration,
                        "demand_latency": latencies,
                        "dma_latency": dma_latencies,
                        "demand_bytes": 32 * count,
                        "demand_bytes_per_cycle": 32 * count / duration,
                        "prefetch_requests": sum(k == "D" for _, k, _ in b.pf),
                        "memory_reads": sum(not w for _, w, _ in b.transactions),
                        "memory_writes": sum(w for _, w, _ in b.transactions),
                        "max_fills": b.max_fills,
                    }
                ),
            )
            assert not b.get("o_fatal")
