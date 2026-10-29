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

"""DDR reset distribution with a stopped SoC clock."""

import os
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.handle import Immediate
from cocotb.triggers import RisingEdge, Timer

from cocotb_tests.test_real_program import generate_divided_clock


@cocotb.test()
async def ddr_reset_release(dut: Any) -> None:
    """Reset asserts without a clock and restarts release after each pulse."""
    for signal in dut:
        if signal._name.startswith("i_"):
            signal.value = Immediate(0)
    await Timer(1, unit="ps")
    dut.i_rst_n.value = 0
    dut.i_ddr_axi_rst_n.value = 0
    soc_clock = Clock(dut.i_clk, 3, unit="ns").start()
    Clock(dut.i_cpu_clk, 7, unit="ns").start()
    async_cpu = bool(os.environ.get("FROST_CPU_PERIOD_PS"))
    core_clock = dut.i_cpu_clk if async_cpu else dut.i_clk
    cocotb.start_soon(generate_divided_clock(dut, core_clock=core_clock))
    await Timer(300, unit="ns")
    platform = dut.cpu_and_memory_subsystem
    soc = platform.soc
    assert int(platform.cpu.i_rst.value)
    if not async_cpu:
        dut.i_rst_n.value = 1
        await Timer(150, unit="ns")
        assert not int(soc.rst_core.value)
        assert int(platform.cpu.i_rst.value)
    soc_clock.cancel()
    dut.i_clk.value = 0
    await Timer(1, unit="ns")

    for release_edges in (2, 3, 4, 5, 5):
        dut.i_ddr_axi_rst_n.value = 0
        await Timer(1, unit="ns")
        assert int(dut.ddr_axi_reset.value)
        assert int(platform.cpu.i_axi_rst.value)
        assert int(platform.cpu.i_rst.value)
        assert not int(dut.o_ddr_axi_awvalid.value)
        assert not int(dut.o_ddr_axi_wvalid.value)
        assert not int(dut.o_ddr_axi_arvalid.value)
        dut.i_ddr_axi_rst_n.value = 1
        await Timer(35, unit="ns")
        assert int(dut.ddr_axi_reset.value)
        for edge in range(1, release_edges + 1):
            dut.i_clk.value = 1
            await Timer(1, unit="ns")
            assert int(dut.ddr_axi_reset.value) == int(edge < 4)
            if not async_cpu:
                assert int(platform.cpu.i_rst.value) == int(edge < 5)
            dut.i_clk.value = 0
            await Timer(2, unit="ns")

    Clock(dut.i_clk, 3, unit="ns").start()
    await Timer(200, unit="ns")
    assert not int(platform.cpu.i_axi_rst.value)
    assert int(platform.cpu.i_rst.value) == int(async_cpu)
    dut.i_rst_n.value = 1
    await Timer(300, unit="ns")
    assert not int(platform.cpu.i_rst.value)
    if not async_cpu:
        saw_core_assertion = False
        saw_core_release = False
        for request_n in (0, 1):
            dut.i_rst_n.value = request_n
            for _ in range(32):
                core_reset_before = int(soc.rst_core.value)
                await RisingEdge(dut.i_clk)
                await Timer(1, unit="ps")
                core_reset_after = int(soc.rst_core.value)
                saw_core_assertion |= core_reset_before == 0 and core_reset_after == 1
                saw_core_release |= core_reset_before == 1 and core_reset_after == 0
                expected_reset = core_reset_before or core_reset_after
                assert int(platform.cpu.i_rst.value) == expected_reset
            assert int(soc.rst_core.value) == int(not request_n)
            assert int(platform.cpu.i_rst.value) == int(not request_n)
        assert saw_core_assertion and saw_core_release
    for name in ("req_toggle_q", "ack_toggle_q", "req_seen_q", "ack_seen_q"):
        assert int(getattr(soc.u_dtm, name).value) == 0, name
    assert not int(soc.u_dtm.o_dmi_req_valid.value)
    assert not int(soc.u_debug_module.dmi_req_pending_q.value)
