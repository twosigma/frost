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

"""Negative probes for selective signal visibility and RTL assertions on frost.

Each cocotb test in this module is expected to fail when invoked on a
selective-visibility ``TOPLEVEL=frost`` build:

- ``unlisted_signal_probe`` reads an internal ``soc_top`` net omitted from
  ``hw/sim/frost_cocotb_visibility.vlt`` so the run fails with an
  ``AttributeError`` naming the visibility configuration and override knob.
- ``deliberate_assertion_violation`` completes reset, asserts the post-reset
  ``nic_engine.sim_assertion_probe`` control with
  ``+frost_startup_assertion_control=nic_reset``, and clocks the SoC so the
  ``nic_engine`` reset invariant assertion fires.
"""

from typing import Any

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from cocotb_tests.test_real_program import (
    CLK_PERIOD_NS,
    RESET_CYCLES,
    _nic_engine,
    generate_divided_clock,
    hold_nic_without_mac_clocks,
    prepare_program_start,
    start_clocks,
    start_cpu_clock,
    takes_last_edge,
    wait_for_power_on_reset,
)


@cocotb.test()
async def unlisted_signal_probe(dut: Any) -> None:
    """Touch an unlisted internal signal; fails under selective visibility."""
    _ = int(dut.cpu_and_memory_subsystem.soc.prog_port_imem_we.value)


@cocotb.test()
@takes_last_edge
async def deliberate_assertion_violation(dut: Any) -> None:
    """Trip nic_engine's post-reset assertion control under selective visibility."""
    await prepare_program_start(dut)
    start_clocks((dut.i_clk,), CLK_PERIOD_NS * 1000)
    start_cpu_clock(dut)
    cocotb.start_soon(generate_divided_clock(dut))
    soc = dut.cpu_and_memory_subsystem.soc
    hold_nic_without_mac_clocks(dut, (soc.nic_access_q,))

    dut.i_instr_mem_en.value = 0
    dut.i_rst_n.value = 0
    dut.i_uart_rx.value = 1
    dut.i_external_interrupt.value = 0
    for _ in range(RESET_CYCLES):
        await RisingEdge(dut.i_clk)
    await wait_for_power_on_reset(dut)

    dut.i_rst_n.value = 1
    await ClockCycles(dut.i_clk, 8)
    _nic_engine(soc.gen_cached_tier.nic).sim_assertion_probe.value = 1
    await ClockCycles(dut.i_clk, 32)
