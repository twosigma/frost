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

"""Observe DDR read traffic in the program's timed pointer walks."""

from typing import Any

import cocotb
from cocotb.triggers import FallingEdge

from cocotb_tests import test_real_program as program


@cocotb.test()
async def capacity_transition(dut: Any) -> None:
    """Require the warmed small ring to fit L2 and the large ring to read DDR."""
    cpu = dut.cpu_and_memory_subsystem.cpu
    core = cpu.hart.cpu_inst
    start, end = program._load_symbol_ranges(["walk"], "l2_capacity_chase")["walk"]
    windows: list[int] = []

    async def monitor() -> None:
        active = False
        reset_seen = False
        reads = 0
        while True:
            await FallingEdge(dut.i_clk)
            if not int(dut.i_rst_n.value):
                active = False
                reset_seen = True
                continue
            if not reset_seen:
                continue
            retired = [
                int(pc.value)
                for valid, pc in (
                    (core.dbg_commit_valid, core.dbg_commit_pc),
                    (core.dbg_commit_2_valid, core.dbg_commit_2_pc),
                )
                if int(valid.value)
            ]
            if any(start <= pc < end for pc in retired) and not active:
                active = True
                reads = 0
            if active and int(cpu.o_axi_arvalid.value) and int(cpu.i_axi_arready.value):
                reads += 1
            if active and retired and not start <= retired[-1] < end:
                windows.append(reads)
                active = False

    task = cocotb.start_soon(monitor())
    try:
        await program.test_real_program.func(dut)
        assert windows and len(windows) % 2 == 0, windows
        for small, large in zip(windows[::2], windows[1::2], strict=True):
            assert small <= 4, f"warmed 8 KiB ring missed a 32 KiB L2: {small} reads"
            assert large >= 256, (
                f"128 KiB ring did not exceed L2 capacity: {large} reads"
            )
        cocotb.log.info("Timed DDR reads, alternating 8/128 KiB: %s", windows)
    finally:
        task.cancel()
