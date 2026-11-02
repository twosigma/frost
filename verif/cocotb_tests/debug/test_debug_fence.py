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

"""Check a BRAM patch within one Debug-Mode program-buffer command."""

import os
from typing import Any

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge

from cocotb_tests.debug.jtag_dtm import (
    INSN_FENCE_I,
    DebugModule,
    Dtm,
    JtagDriver,
    addi,
    store,
)
from cocotb_tests.debug.test_debug import _reset
from cocotb_tests.test_real_program import (
    CLK_PERIOD_NS,
    cpu_clock,
    generate_divided_clock,
    start_clocks,
    start_cpu_clock,
    takes_last_edge,
)


@cocotb.test()
@takes_last_edge
async def test_debug_fence(dut: Any) -> None:
    """A fence drains both mirror words and invalidates a warm Normal fetch."""
    start_clocks((dut.i_clk,), CLK_PERIOD_NS * 1000)
    start_cpu_clock(dut)
    cocotb.start_soon(generate_divided_clock(dut))
    await _reset(dut)
    jtag = JtagDriver(dut, half_period=4)
    await jtag.reset()
    dm = DebugModule(Dtm(jtag, idle_cycles=1), cocotb.log)
    await dm.activate()
    await dm.halt()
    patch = 0x1E000
    await dm.write_mem(patch, 8, addi(5, 0, 1) | (addi(5, 5, 2) << 32))
    await dm.write_mem(patch + 8, 4, 0x00008067)  # ret
    await dm.write_gpr(dm.S0, patch)
    await dm.write_gpr(dm.S1, addi(5, 0, 17) | (addi(5, 5, 23) << 32))
    hart = dut.cpu_and_memory_subsystem.cpu.hart
    soc = dut.cpu_and_memory_subsystem.soc
    asynchronous = bool(os.environ.get("FROST_CPU_PERIOD_PS"))

    async def hold_mirror() -> None:
        for _ in range(200000):
            await RisingEdge(dut.i_clk)
            await ReadOnly()
            if (
                int(soc.dbg_bram_store.value)
                and int(soc.dbg_bram_store_addr.value) == patch
            ):
                break
        else:
            raise AssertionError("program-buffer patch store did not arrive")
        await FallingEdge(dut.i_clk)
        dut.i_instr_mem_we.value = 0
        dut.i_instr_mem_en.value = 1
        waited = False
        for _ in range(96):
            await RisingEdge(dut.i_clk)
            await ReadOnly()
            assert not int(hart.fence_i_sync_done.value), (
                "fence passed an outstanding mirror"
            )
            if asynchronous:
                # The store holds B before the serializer can request a fence.
                assert not int(soc.local_resp_valid.value), (
                    "store response passed an outstanding mirror"
                )
                waited |= not int(soc.debug_store_done.value)
            else:
                waited |= bool(int(hart.fence_i_sync_req.value))
        await FallingEdge(dut.i_clk)
        dut.i_instr_mem_en.value = 0
        assert waited, "store drain or fence did not wait for the stalled mirror"
        for _ in range(10000):
            await RisingEdge(cpu_clock(dut))
            await ReadOnly()
            if int(hart.fence_i_sync_done.value):
                assert int(soc.slice_all_done.value) and not int(
                    soc.slice_req_valid.value
                )
                return
        raise AssertionError("fence did not complete after mirror release")

    observer = cocotb.start_soon(hold_mirror())
    call_patch = (dm.S0 << 15) | (1 << 7) | 0x67  # jalr ra, 0(s0)
    # The first call warms fetch after GO. The second executes both patched words.
    await dm.exec_progbuf(
        [call_patch, store(dm.S1, dm.S0, 8), INSN_FENCE_I, call_patch]
    )
    await observer
    assert (await dm.read_gpr(5)) == 40, "stale instruction word survived FENCE.I"
    await ClockCycles(dut.i_clk, 10)
