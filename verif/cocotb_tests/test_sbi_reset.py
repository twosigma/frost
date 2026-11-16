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

"""Follow an S-mode SRST ecall through OpenSBI to reset and boot entry.

The image uses the smoke test's fixed BRAM shim and DDR firmware layout.
A minimal DT and suppressed boot prints shorten setup; the reset driver and
S-mode ecall path use the production OpenSBI configuration.
Returning to the shim does not prove that mutable firmware or an OS image
can be booted again without reloading it.
"""

from typing import Any

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge, with_timeout
from cocotb.utils import get_sim_time

from cocotb_tests.test_real_program import (
    CLK_PERIOD_NS,
    UartMonitor,
    generate_divided_clock,
    hold_nic_without_mac_clocks,
    prepare_program_start,
    start_clocks,
    start_cpu_clock,
    wait_for_power_on_reset,
)


@cocotb.test()
async def test_sbi_reset(dut: Any) -> None:
    """Check the syscon driver, pulse, surviving fabric and first retired PC."""
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
    await ClockCycles(dut.i_clk, 20)
    await wait_for_power_on_reset(dut)
    uart.clear()
    dut.i_rst_n.value = 1

    await with_timeout(RisingEdge(soc.sysreset_q), 60_000_000, "ns")
    started = get_sim_time(unit="ps")
    assert "SBI reset: requesting reboot" in uart.get_output(), uart.get_output()
    assert "<<FAIL>>" not in uart.get_output(), uart.get_output()
    await ClockCycles(dut.i_clk, 8)
    await ReadOnly()
    assert int(soc.o_cpu_rst.value) == 1
    assert int(soc.soc_axi_rst.value) == 0
    assert int(soc.o_cpu_axi_rst.value) == 0
    assert int(soc.debug_cpu_rst.value) == 0
    assert int(soc.debug_soc_rst.value) == 0
    await with_timeout(FallingEdge(soc.sysreset_q), 300, "ns")
    assert get_sim_time(unit="ps") - started == 64 * CLK_PERIOD_NS * 1000

    # This test returns in ReadOnly below; it must not use takes_last_edge,
    # whose final ReadOnly would be an illegal same-phase transition.
    for _ in range(2000):
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        if int(soc.i_debug_commit_valid.value) & 1:
            pc = int(soc.i_debug_commit_pc.value)
            assert pc == 0, f"first post-reset instruction retired at {pc:#x}"
            cocotb.log.info("S-mode SRST completed; first post-reset PC = 0")
            uart.stop()
            return
    raise AssertionError("no instruction retired after SYSRESET")
