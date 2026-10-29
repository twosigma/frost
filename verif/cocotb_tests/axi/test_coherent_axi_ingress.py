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

"""Check completion and reset across the connected AXI and coherent ports."""

from typing import Any

import cocotb
from cocotb.triggers import FallingEdge, RisingEdge

from cocotb_tests.axi.axi_models import AxiMaster, INCR, OKAY
from cocotb_tests.axi.coherent_axi_home import CoherentHome
from cocotb_tests.axi.test_axi_coherent_bridge import REGION_BASE, _start, _wait


@cocotb.test()
async def four_credits_and_release_before_b(dut: Any) -> None:
    """Check that B follows every coherent Release of a four-line burst."""
    b = await _start(dut, seed=31, master_ready=0.0)
    assert isinstance(b.ingress, CoherentHome)
    b.ingress.pause = "u"
    beats = 4 * 32 // b.bus
    write = b.write(REGION_BASE + 0x1000, beats - 1, b.max_size, INCR, strobe_bias=1.0)
    aw = b.master._aw_queue.popleft()
    for _ in range(12):
        await RisingEdge(dut.i_clk)
    assert int(dut.i_axi_wvalid.value)
    assert not int(dut.o_axi_bvalid.value)
    b.master._aw_queue.appendleft(aw)
    for _ in range(200):
        await RisingEdge(dut.i_clk)
        assert not int(dut.o_axi_bvalid.value)
        if b.ingress.max_occupied == 4 and b.ingress.phase == "u":
            break
    else:
        raise AssertionError("four ingress credits did not fill")
    for _ in range(20):
        await RisingEdge(dut.i_clk)
        assert not int(dut.o_axi_bvalid.value)
    b.ingress.pause = None
    for _ in range(500):
        await RisingEdge(dut.i_clk)
        if int(dut.o_axi_bvalid.value):
            assert b.ingress.completions == 4
            break
    else:
        raise AssertionError("released burst did not produce B")
    for _ in range(12):
        await RisingEdge(dut.i_clk)
        assert int(dut.o_axi_bvalid.value)
    b.master.ready_bias = 1.0
    await _wait(dut, [write])
    assert write.resp == OKAY
    read = b.read(write.addr, beats - 1, b.max_size, INCR)
    await _wait(dut, [read])
    b.check_read(read)
    b.check_memory()
    b.check_clean()


@cocotb.test()
async def reset_cancels_each_coherent_stage(dut: Any) -> None:
    """Shared reset cancels queued bursts and channel debt before ID reuse."""
    b = await _start(dut, seed=32)
    assert isinstance(b.ingress, CoherentHome)
    for stage in ("d", "g", "c", "u"):
        b.ingress.pause = stage
        b.write(REGION_BASE + 0x2000, 63, b.max_size, INCR)
        b.read(REGION_BASE + 0x4000, 63, b.max_size, INCR)
        for _ in range(500):
            await RisingEdge(dut.i_clk)
            if b.ingress.phase == stage and len(b.ingress.outstanding) == 4:
                break
        else:
            raise AssertionError(f"requests did not reach {stage}")
        await FallingEdge(dut.i_clk)
        dut.i_rst.value = 1
        b.master._task.cancel()
        for _ in range(3):
            await RisingEdge(dut.i_clk)
        await FallingEdge(dut.i_clk)
        b.master = AxiMaster(dut, dut.i_clk, "i_axi_", "o_axi_", b.bus, b.rng, 0.5)
        b.ingress.pause = None
        dut.i_rst.value = 0
        b.ref.clear()
        fresh = b.write(REGION_BASE + 0x6000, 3, b.max_size, INCR, strobe_bias=1.0)
        await _wait(dut, [fresh])
        assert fresh.resp == OKAY
        read = b.read(fresh.addr, 3, b.max_size, INCR)
        await _wait(dut, [read])
        b.check_read(read)
        b.check_clean()


@cocotb.test()
async def independent_results_preserve_axi_burst_order(dut: Any) -> None:
    """Hold four coherent results and reorder line replies inside one AXI burst."""
    b = await _start(dut, seed=33, master_ready=0.0)
    assert isinstance(b.ingress, CoherentHome)
    b.ingress.pause = "c"
    beats = 4 * 32 // b.bus
    write = b.write(REGION_BASE + 0x8000, beats - 1, b.max_size, INCR, strobe_bias=1.0)
    for _ in range(500):
        await RisingEdge(dut.i_clk)
        assert not int(dut.o_axi_bvalid.value)
        if len(b.ingress.grant_order) == 4:
            break
    else:
        raise AssertionError("four grants did not arrive while C was blocked")
    assert b.ingress.max_active == 4 and b.ingress.completions == 0
    assert b.ingress.grant_order != sorted(b.ingress.grant_order)
    for _ in range(20):
        await RisingEdge(dut.i_clk)
        assert not int(dut.o_axi_bvalid.value)
    b.ingress.pause = None
    for _ in range(500):
        await RisingEdge(dut.i_clk)
        if int(dut.o_axi_bvalid.value):
            assert b.ingress.completions == 4 and len(b.ingress.release_order) == 4
            break
    else:
        raise AssertionError("released write did not complete")
    b.master.ready_bias = 0.3
    await _wait(dut, [write])
    assert write.resp == OKAY
    read = b.read(write.addr, beats - 1, b.max_size, INCR)
    await _wait(dut, [read])
    b.check_read(read)
    assert b.ingress.grant_order[4:] != sorted(b.ingress.grant_order[4:])
    b.check_memory()
    b.check_clean()
