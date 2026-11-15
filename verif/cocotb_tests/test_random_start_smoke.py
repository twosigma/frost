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

"""Exercise system startup and a short execution interval with seeded state."""

from typing import Any
import os

import cocotb
from cocotb.handle import Immediate
from cocotb.triggers import ClockCycles, ReadOnly, ReadWrite, RisingEdge

from cocotb_tests.test_real_program import (
    CLK_PERIOD_NS,
    RESET_CYCLES,
    _load_imem_predecode_model,
    generate_divided_clock,
    prepare_program_start,
    start_clocks,
    start_cpu_clock,
    start_nic_mac_clocks,
    wait_for_power_on_reset,
)


def load_startup_loop(dut: Any) -> None:
    """Install the entry self loop after reset; the sweep preloads its banks."""
    platform = dut.cpu_and_memory_subsystem
    soc = platform.soc if hasattr(platform, "soc") else platform
    assert int(soc.rst_core.value), "startup loop load requires system reset"
    if hasattr(platform, "u_rvfi_dii"):
        # An empty injected stream supplies C.NOP instructions.
        return
    memory = soc.instruction_memory
    model = _load_imem_predecode_model()
    word = 0x0000006F  # jal x0, 0
    sideband = model.make_sideband(word)
    packed = {
        "cold": model.pack_cold_data(word),
        "frontend_hot": model.pack_frontend_hot(word),
        "sideband": sideband,
        "compressed": model.make_fast_replica(word, sideband),
    }
    for parity in ("even", "odd"):
        for name, value in packed.items():
            bank = getattr(memory, f"u_{parity}_{name}")
            if hasattr(bank, "ram"):
                bank.ram[0].value = Immediate(value)
            elif hasattr(bank.u_sram, "gen_array"):
                bank.u_sram.gen_array.memory[0].value = Immediate(value)
            else:
                for column_index, column in enumerate(
                    bank.u_sram.gen_macros.gen_row[0].gen_column
                ):
                    array = column.gen_macro.u_macro.mem
                    width = len(array[0])
                    array[0].value = Immediate(
                        (value >> (column_index * width)) & ((1 << width) - 1)
                    )
        for name, bit in model.SCALAR_REPLICA_BITS:
            bank = getattr(memory, f"u_{parity}_{name}_bank").u_ram.ram
            bank[0].value = Immediate((sideband >> bit) & 1)


@cocotb.test()
async def startup_smoke(dut: Any) -> None:
    """Apply the program bench's reset, then run 300 system clock cycles."""
    control = os.environ.get("FROST_STARTUP_ASSERTION_CONTROL")
    withheld = os.environ.get("FROST_STARTUP_WITHHOLD_ASSERTIONS") == "1"
    if control:
        assert control in ("bridge", "nic_reset"), "unknown assertion control"
        assert cocotb.plusargs.get("frost_startup_assertion_control") == control
    if withheld:
        assert control == "bridge"
        assert cocotb.plusargs.get("frost_startup_withhold_assertions") == "1"
    for signal in dut:
        if signal._name.startswith("i_"):
            signal.value = Immediate(0)
    platform = dut.cpu_and_memory_subsystem
    if hasattr(platform, "u_rvfi_dii"):
        harness = platform.u_rvfi_dii
        harness.dii_count.value = Immediate(0)
        harness.event_target.value = Immediate(1024)
        harness.hang_limit.value = Immediate(10000)
    await prepare_program_start(dut)
    dut.i_uart_rx.value = 1
    dut.i_external_interrupt.value = 0
    start_clocks((dut.i_clk,), CLK_PERIOD_NS * 1000)
    start_cpu_clock(dut)
    cocotb.start_soon(
        generate_divided_clock(
            dut, image_loader=load_startup_loop, arm_assertions=not withheld
        )
    )
    start_nic_mac_clocks(dut, edges_without_delay=True)
    for _ in range(RESET_CYCLES):
        await RisingEdge(dut.i_clk)
    await wait_for_power_on_reset(dut)
    dut.i_rst_n.value = 1
    if hasattr(dut, "i_ddr_axi_rst_n"):
        dut.i_ddr_axi_rst_n.value = 1
    if control:
        await ClockCycles(dut.i_clk, 8)
        await ReadWrite()
        soc = platform.soc if hasattr(platform, "soc") else platform
        nic = soc.gen_cached_tier.nic
        target = nic.u_dma_axi if control == "bridge" else nic
        cocotb.log.info("STARTUP_ASSERTION_CONTROL %s", control)
        target.sim_assertion_probe.value = 1
    await ClockCycles(dut.i_clk, 300)
    await ReadOnly()
    if withheld:
        from cocotb_tests.sim_assertions import simulation_assertions_enabled

        assert not simulation_assertions_enabled()
        cocotb.log.info("STARTUP_WITHHELD_ASSERTIONS_PASS")
    cocotb.log.info("STARTUP_SMOKE_PASS")
