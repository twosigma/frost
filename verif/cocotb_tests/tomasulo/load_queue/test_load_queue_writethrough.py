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

"""Delayed Normal reads must not overwrite a newer committed-store cache update."""

from typing import Any
import cocotb
from cocotb.triggers import Timer
from .test_load_queue import (
    setup,
    alloc_and_addr,
    wait_for_fu_complete,
    accept_fu_complete,
)
from .test_load_queue_axi_errors import launch
from .lq_model import MEM_SIZE_WORD


@cocotb.test()
async def older_read_never_refills_after_overlapping_store(dut: Any) -> None:
    """Test both prior and simultaneous invalidation against an older reply."""
    for simultaneous in (False, True):
        interface, model = await setup(dut)
        dut.i_cache_store_strb.value = 0
        dut.i_l0_hit_allowed.value = 0
        await launch(interface, 1, 0x5000)
        interface.drive_mem_bus_busy(True)
        interface.drive_cache_invalidate(0x5000)
        dut.i_cache_store_data.value = 0x12345678
        dut.i_cache_store_strb.value = 255
        if not simultaneous:
            await interface.step()
            interface.clear_cache_invalidate()
            dut.i_cache_store_strb.value = 0
            for _ in range(8):
                await interface.step()
        interface.drive_mem_response(0x654321)
        await Timer(1, unit="ns")
        assert not int(dut.o_l0_fill.value)
        await interface.step()
        interface.clear_mem_response()
        interface.clear_cache_invalidate()
        dut.i_cache_store_strb.value = 0
        interface.drive_mem_bus_busy(False)
        result = await wait_for_fu_complete(interface, max_cycles=12)
        assert result.valid and result.tag == 1 and result.value == 0x654321
        await accept_fu_complete(interface)
        await alloc_and_addr(interface, model, 2, 0x5000, size=MEM_SIZE_WORD)
        interface.drive_sq_all_older_known(True)
        interface.drive_sq_forward(match=False, can_forward=False)
        for _ in range(16):
            assert not interface.read_mem_request()["en"]
            result = interface.read_fu_complete()
            if result.valid:
                break
            await interface.step()
        assert result.valid and result.tag == 2 and result.value == 0x12345678
        await accept_fu_complete(interface)


@cocotb.test()
async def unrelated_store_does_not_discard_valid_read_fill(dut: Any) -> None:
    """Track invalidations by address instead of dropping every busy-period fill."""
    interface, _ = await setup(dut)
    dut.i_cache_store_strb.value = 0
    await launch(interface, 1, 0x5000)
    interface.drive_cache_invalidate(0x5010)
    await interface.step()
    interface.clear_cache_invalidate()
    interface.drive_mem_response(0x11122334)
    await Timer(1, unit="ns")
    assert int(dut.o_l0_fill.value)
    await interface.step()
    interface.clear_mem_response()
    result = await wait_for_fu_complete(interface, max_cycles=12)
    assert result.valid and result.value == 0x11122334


@cocotb.test()
async def l0_hit_and_older_uncached_reply_keep_both_results(dut: Any) -> None:
    """Keep both results when an older Normal read completes alongside a hit."""
    interface, model = await setup(dut)
    dut.i_l0_hit_allowed.value = 0
    interface.drive_cache_invalidate(0x5000)
    dut.i_cache_store_data.value = 0x11223344
    dut.i_cache_store_strb.value = 255
    await interface.step()
    interface.clear_cache_invalidate()
    dut.i_cache_store_strb.value = 0
    await launch(interface, 1, 0x6008)
    interface.drive_mem_bus_busy(True)
    await alloc_and_addr(interface, model, 2, 0x5000, size=MEM_SIZE_WORD)
    interface.drive_sq_all_older_known(True)
    interface.drive_sq_forward(match=False, can_forward=False)
    for _ in range(6):
        await interface.step()
        assert not interface.read_fu_complete().valid
    dut.i_l0_hit_allowed.value = 1
    # Permission also enables the two-cycle SQ probe. Wait until the hit
    # is ready, then return the older read on that exact result-write edge.
    for _ in range(6):
        await Timer(1, unit="ns")
        if int(dut.o_l0_hit.value):
            break
        await interface.step()
    assert int(dut.o_l0_hit.value)
    interface.drive_mem_response(0x55667788)
    await Timer(1, unit="ns")
    assert not interface.read_mem_request()["en"]
    await interface.step()
    interface.clear_mem_response()
    seen = {}
    for _ in range(24):
        result = interface.read_fu_complete()
        if result.valid:
            assert result.tag not in seen and not result.exception
            seen[result.tag] = result.value
            interface.drive_result_accepted(True)
        else:
            interface.clear_result_accepted()
        await interface.step()
    interface.clear_result_accepted()
    assert seen == {1: 0x55667788, 2: 0x11223344}
