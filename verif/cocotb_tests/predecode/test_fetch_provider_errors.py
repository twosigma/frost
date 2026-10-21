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

"""Instruction-bus errors retain VA identity and never become victim hits."""

from typing import Any

import cocotb
from cocotb.triggers import FallingEdge
from cocotb_tests.predecode.test_fetch_provider import (
    DDR_BASE,
    TIMEOUT,
    _drive_pc,
    _line_slave,
    _setup,
    _wait_window,
)


async def wait_fault(dut: Any, pc: int, first: int, second: int) -> None:
    """Check wait fault."""
    for _ in range(TIMEOUT):
        await FallingEdge(dut.i_clk)
        if int(dut.o_instr_valid.value) and int(dut.o_served_word.value) == pc >> 2:
            assert int(dut.o_served_fault0.value) == first
            assert int(dut.o_served_fault1.value) == second
            assert not int(dut.o_served_fault0_page.value)
            assert not int(dut.o_served_fault1_page.value)
            return
    raise AssertionError("fault window never presented")


@cocotb.test()
async def failed_first_line_and_recovery(dut: Any) -> None:
    """Check failed first line and recovery."""
    await _setup(dut)
    pc = DDR_BASE + 0x200
    errors = {pc}
    log: list[int] = []
    cocotb.start_soon(_line_slave(dut, 7, log, errors=errors))
    _drive_pc(dut, pc)
    await wait_fault(dut, pc, 1, 1)
    await FallingEdge(dut.i_clk)
    _drive_pc(dut, pc + 0x100)
    dut.i_retarget.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_retarget.value = 0
    await _wait_window(dut, pc + 0x100)
    errors.clear()
    await FallingEdge(dut.i_clk)
    _drive_pc(dut, pc)
    dut.i_retarget.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_retarget.value = 0
    await _wait_window(dut, pc)
    assert not int(dut.o_served_fault0.value)
    assert log.count(pc) >= 2


@cocotb.test()
async def straddling_second_word_fault(dut: Any) -> None:
    """Check straddling second word fault."""
    await _setup(dut)
    pc = DDR_BASE + 28
    log: list[int] = []
    cocotb.start_soon(_line_slave(dut, 9, log, errors={DDR_BASE + 32}))
    _drive_pc(dut, pc)
    await wait_fault(dut, pc, 0, 1)
