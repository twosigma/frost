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

"""Check both i_rst_n reset paths in the default FROST clock configuration."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge, Timer
from cocotb.utils import get_sim_time

EXPECTED_SYNC_STAGES = 3


async def _first_release_time(reset: Any) -> float:
    await FallingEdge(reset)
    return get_sim_time(unit="ps")


async def _check_release(
    clock: Any, reset_in_n: Any, reset: Any, expected_edges: int
) -> None:
    assert int(reset.value) == 1, f"{reset._path} was not asserted before release"
    release = cocotb.start_soon(_first_release_time(reset))

    edge_times = []
    samples = []
    await RisingEdge(reset_in_n)
    for _ in range(expected_edges + 1):
        await RisingEdge(clock)
        await ReadOnly()
        edge_times.append(get_sim_time(unit="ps"))
        samples.append(int(reset.value))

    released_at = release.result() if release.done() else None
    if released_at is None:
        release.cancel()
    observed_edge = next(
        (edge for edge, time in enumerate(edge_times, start=1) if time == released_at),
        None,
    )
    result = (
        f"{reset._path} on {clock._name}: expected release at rising edge "
        f"{expected_edges}, observed {observed_edge}. Samples {samples}, "
        f"first falling transition at {released_at} ps."
    )
    assert observed_edge == expected_edges, result
    assert samples == [1] * (expected_edges - 1) + [0, 0], result
    cocotb.log.info(result)


@cocotb.test(timeout_time=2000, timeout_unit="ns")
async def test_frost_reset_release(dut: Any) -> None:
    """Check the release edge and levels at the outputs and consumer ports."""
    stages = int(dut.NumResetSyncStages.value)
    assert stages == EXPECTED_SYNC_STAGES, (
        f"NumResetSyncStages is {stages}, expected {EXPECTED_SYNC_STAGES}"
    )
    cocotb.log.info("NumResetSyncStages = %s", stages)
    reset_in_n = dut.i_rst_n
    reset_in_n.value = 0
    dut.i_power_on_rst.value = 1
    dut.i_ddr_axi_rst_n.value = 0
    dut.i_jtag_trst_n.value = 0
    await Timer(1, unit="ns")
    Clock(dut.i_clk, 10, unit="ns").start()
    # Separate the rising edges so a release on the wrong clock is visible.
    await Timer(2, unit="ns")
    Clock(dut.i_clk_div4, 40, unit="ns").start()
    await ClockCycles(dut.i_clk_div4, 5)
    await Timer(1, unit="ns")

    main_resets = (
        dut.reset_synchronized,
        dut.cpu_and_memory_subsystem.i_rst,
        dut.memory_mapped_io_fifo_0.i_rst,
        dut.memory_mapped_io_fifo_1.i_rst,
        dut.uart_transmit_clock_domain_crossing_fifo.i_rst,
        dut.uart_receive_clock_domain_crossing_fifo.o_rst,
    )
    divided_resets = (
        dut.reset_div4_synchronized,
        dut.uart_transmit_clock_domain_crossing_fifo.o_rst,
        dut.uart_receive_clock_domain_crossing_fifo.i_rst,
        dut.uart_transmitter.i_rst,
        dut.uart_receiver.i_rst,
    )
    # The main-clock path includes the registered output after the stages.
    checks = [
        cocotb.start_soon(_check_release(clock, reset_in_n, reset, expected_edges))
        for clock, resets, expected_edges in (
            (dut.i_clk, main_resets, EXPECTED_SYNC_STAGES + 1),
            (dut.i_clk_div4, divided_resets, EXPECTED_SYNC_STAGES),
        )
        for reset in resets
    ]

    # Release shortly before the next divided-clock rise, with main reset held.
    await FallingEdge(dut.i_clk_div4)
    await Timer(12, unit="ns")
    reset_in_n.value = 1
    await RisingEdge(reset_in_n)
    input_release_time = get_sim_time(unit="ps")
    await RisingEdge(dut.i_clk_div4)
    await ReadOnly()
    assert int(dut.reset_synchronized.value) == 1, (
        "The first divided-clock rise must precede main-clock reset release"
    )
    cocotb.log.info(
        "i_rst_n released at %s ps. First divided-clock rise at %s ps "
        "with main-clock reset asserted.",
        input_release_time,
        get_sim_time(unit="ps"),
    )
    for check in checks:
        await check
