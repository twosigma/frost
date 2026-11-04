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

"""Exercise store resource pressure through the production home."""

from typing import Any

import cocotb

from cocotb_tests.cache.test_coherence_cluster import Cluster


@cocotb.test()
async def frozen_victims_release_and_probe_progress(dut: Any) -> None:
    """Drain ordered stores and a load with both victim slots occupied."""
    b = Cluster(dut)
    await b.reset()
    a = 0x80000000
    for offset, value in ((0, 0x11), (64, 0x22)):
        await b.store(a + offset, value)
        await b.wait("o_pending_store", 0)
    await b.tick(20)
    await b.set(i_hold_wa=1, i_hold_release=1)
    await b.store(a + 128, 0x33)
    await b.store(a + 192, 0x44)
    for _ in range(500):
        if int(dut.hart.wb_live.value) == 3 and not b.get("o_pending_store"):
            break
        await b.tick()
    else:
        raise AssertionError("both dirty victim slots did not become occupied")
    assert b.get("o_live_stores").bit_count() == 2
    await b.store(a + 256, 0x55)
    await b.store(a + 320, 0x66)
    await b.set(
        i_address=a + 384,
        i_read_valid=1,
        i_read_kind=0,
        i_read_id=0,
        i_read_size=3,
        i_read_ready=0,
    )
    await b.tick()
    await b.set(i_read_valid=0)
    await b.tick(80)
    assert not b.get("o_read_valid") and b.get("o_pending_store")
    assert int(dut.hart.wb_live.value) == 3
    await b.set(i_hold_release=0)
    await b.tick(20)
    assert await b.dma(a + 128) & ((1 << 64) - 1) == 0x33
    assert int(dut.hart.wb_live.value) == 3
    await b.set(i_hold_wa=0)
    await b.wait("o_read_valid")
    assert not b.get("o_read_error") and b.get("o_read_data") == 0
    await b.set(i_read_ready=1)
    await b.tick()
    await b.set(i_read_ready=0)
    await b.wait("o_pending_store", 0)
    assert await b.dma(a + 256) & ((1 << 64) - 1) == 0x55
    assert await b.dma(a + 320) & ((1 << 64) - 1) == 0x66
    assert await b.dma(a) & ((1 << 64) - 1) == 0x11
    assert await b.dma(a + 64) & ((1 << 64) - 1) == 0x22
