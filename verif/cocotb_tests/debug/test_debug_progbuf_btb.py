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

"""Check that a rewritten program-buffer word does not follow an old BTB entry.

The program buffer is code at fixed addresses that the debugger rewrites
between commands, with no FENCE.I. A taken BTB entry left by a branch in one
command's buffer must not redirect the instruction that replaces it: that
instruction is not control flow, so nothing would correct the redirect.
"""

from typing import Any

import cocotb
from cocotb.triggers import ClockCycles

from cocotb_tests.debug.jtag_dtm import DebugModule, Dtm, JtagDriver, addi
from cocotb_tests.debug.test_debug import _reset
from cocotb_tests.test_real_program import (
    CLK_PERIOD_NS,
    generate_divided_clock,
    start_clocks,
    start_cpu_clock,
    takes_last_edge,
)

# Runs of the branch program: enough to train the BTB entry taken.
TRAIN_RUNS = 4
SCRATCH = 5  # t0


def beq(rs1: int, rs2: int, offset: int) -> int:
    """Encode ``beq rs1, rs2, offset``."""
    imm = offset & 0x1FFF
    return (
        ((imm >> 12) & 1) << 31
        | ((imm >> 5) & 0x3F) << 25
        | (rs2 << 20)
        | (rs1 << 15)
        | ((imm >> 1) & 0xF) << 8
        | ((imm >> 11) & 1) << 7
        | 0x63
    )


@cocotb.test()
@takes_last_edge
async def test_debug_progbuf_btb(dut: Any) -> None:
    """A taken branch's program-buffer word, rewritten as an addi, runs the addi."""
    start_clocks((dut.i_clk,), CLK_PERIOD_NS * 1000)
    start_cpu_clock(dut)
    cocotb.start_soon(generate_divided_clock(dut))
    await _reset(dut)
    jtag = JtagDriver(dut, half_period=4)
    await jtag.reset()
    dm = DebugModule(Dtm(jtag, idle_cycles=1), cocotb.log)
    await dm.activate()
    await dm.halt()

    # Always-taken beqs at words 1, 3 and 5 skip words 2, 4 and 6: t0 = 8.
    # The program buffer starts in the upper word of an 8-byte fetch window,
    # so these words start windows, and each branch is predicted by the lookup
    # at its own address.
    branch_program = [
        addi(SCRATCH, 0, 0),
        beq(0, 0, 8),
        addi(SCRATCH, SCRATCH, 1),
        beq(0, 0, 8),
        addi(SCRATCH, SCRATCH, 2),
        beq(0, 0, 8),
        addi(SCRATCH, SCRATCH, 4),
        addi(SCRATCH, SCRATCH, 8),
    ]
    for run in range(TRAIN_RUNS):
        await dm.exec_progbuf(branch_program)
        got = await dm.read_gpr(SCRATCH)
        assert got == 8, f"branch program run {run}: t0 = {got}, want 8"

    # The same buffer with each beq rewritten as an addi: t0 = 127. A word
    # that follows its old beq's entry skips the next word, which clears
    # bit 0, 1 or 2 of the sum.
    rewritten_program = list(branch_program)
    rewritten_program[1] = addi(SCRATCH, SCRATCH, 16)
    rewritten_program[3] = addi(SCRATCH, SCRATCH, 32)
    rewritten_program[5] = addi(SCRATCH, SCRATCH, 64)
    await dm.exec_progbuf(rewritten_program)
    got = await dm.read_gpr(SCRATCH)
    assert got == 127, f"rewritten program: t0 = {got}, want 127" + (
        " (an old beq's BTB entry redirected its addi)" if got < 127 else ""
    )
    await ClockCycles(dut.i_clk, 10)
