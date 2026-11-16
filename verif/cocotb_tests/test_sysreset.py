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

"""Load SYSRESET over retained markers and exercise both reset widths."""

from typing import Any

import cocotb
from cocotb.handle import Immediate
from cocotb.triggers import ClockCycles, FallingEdge, Timer

from cocotb_tests.test_real_program import (
    CLK_PERIOD_NS,
    UartMonitor,
    generate_divided_clock,
    hold_nic_without_mac_clocks,
    load_program_images,
    prepare_program_start,
    run_until_complete,
    start_clocks,
    start_cpu_clock,
    takes_last_edge,
    wait_for_power_on_reset,
)


@cocotb.test()
@takes_last_edge
async def test_sysreset(dut: Any) -> None:
    """Reload over each interrupted phase and require the complete program."""
    await prepare_program_start(dut)
    start_clocks((dut.i_clk,), CLK_PERIOD_NS * 1000)
    start_cpu_clock(dut)
    cocotb.start_soon(generate_divided_clock(dut))
    soc = dut.cpu_and_memory_subsystem.soc
    hold_nic_without_mac_clocks(dut, (soc.nic_access_q,))
    dut.i_uart_rx.value = 1
    dut.i_external_interrupt.value = 0
    uart = UartMonitor(dut)
    await uart.start()
    memory = soc.data_memory

    # Retain the same DUT and memories across all three loads. Each value is
    # a possible marker left by an interrupted earlier invocation.
    for run, stale in enumerate((0x5E5E0001, 0x5E5E0002, 0x5E5E0003), start=1):
        dut.i_rst_n.value = 0
        await ClockCycles(dut.i_clk, 20)
        await wait_for_power_on_reset(dut)
        await FallingEdge(dut.i_clk)
        memory.memory[0x30000 // 8].value = Immediate(stale)
        memory.sim_load_image.value = 0
        await Timer(1, unit="ps")
        load_program_images(dut)
        await Timer(1, unit="ps")
        assert int(memory.memory[0x30000 // 8].value) & 0xFFFFFFFF == 0
        uart.clear()
        dut.i_rst_n.value = 1
        await run_until_complete(
            dut, uart, "<<PASS>>", None, True, 500000, run, "sysreset_test"
        )
        assert "no reset from invalid writes" in uart.get_output()
        assert "word and halfword resets completed" in uart.get_output()
        await Timer(1, unit="ps")
        cocotb.log.info("Reload over stale marker %#x completed", stale)
    uart.stop()
