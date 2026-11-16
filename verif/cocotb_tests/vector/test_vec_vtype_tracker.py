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

"""Configuration allocation, delayed ROB indication, CSR reload and recovery."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

from ..tomasulo.fu_shims.fp_shim_interface import _parse_instr_op_enum


@cocotb.test()
async def configuration_handoff(dut: Any) -> None:
    """Never expose the previous vtype between vsetvl dispatch and retirement."""
    ops = _parse_instr_op_enum()
    Clock(dut.i_clk, 10, unit="ns").start()
    dut.i_rst.value = 1
    dut.i_alloc.value = 0
    dut.i_alloc_op.value = ops["ADDI"]
    dut.i_alloc_imm.value = 0
    dut.i_ckpt_save.value = 0
    dut.i_ckpt_id.value = 0
    dut.i_restore.value = 0
    dut.i_restore_id.value = 0
    dut.i_flush_all.value = 0
    dut.i_vcfg_in_flight.value = 0
    dut.i_arch_vtype.value = 0x100
    dut.i_arch_vstart_nonzero.value = 0
    dut.i_arch_reload.value = 0
    for _ in range(2):
        await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    for _ in range(5):
        await FallingEdge(dut.i_clk)
    assert int(dut.o_valid.value) and int(dut.o_vtype.value) == 0x100
    for previous, following in ((0x100, 0x18), (0x18, 0x11), (0x11, 0x18)):
        assert int(dut.o_vtype.value) == previous
        dut.i_alloc.value = 1
        dut.i_alloc_op.value = ops["VSETVL"]
        await FallingEdge(dut.i_clk)
        dut.i_alloc.value = 0
        assert not int(dut.o_valid.value)
        # The ROB in-flight output lags allocation by one cycle.
        await FallingEdge(dut.i_clk)
        assert not int(dut.o_valid.value), "reloaded stale CSR before ROB flag arrived"
        dut.i_vcfg_in_flight.value = 1
        for _ in range(3):
            await FallingEdge(dut.i_clk)
            assert not int(dut.o_valid.value)
        dut.i_vcfg_in_flight.value = 0
        await FallingEdge(dut.i_clk)
        assert not int(dut.o_valid.value)
        dut.i_arch_vtype.value = following
        for _ in range(4):
            await FallingEdge(dut.i_clk)
        assert int(dut.o_valid.value) and int(dut.o_vtype.value) == following

    dut.i_arch_vstart_nonzero.value = 1
    dut.i_arch_reload.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_arch_reload.value = 0
    assert not int(dut.o_valid.value)
    await FallingEdge(dut.i_clk)
    assert int(dut.o_valid.value) and int(dut.o_vstart_nonzero.value)
    dut.i_ckpt_save.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_ckpt_save.value = 0
    dut.i_alloc.value = 1
    dut.i_alloc_op.value = ops["VARITH"]
    await FallingEdge(dut.i_clk)
    dut.i_alloc.value = 0
    assert not int(dut.o_vstart_nonzero.value)
    dut.i_restore.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_restore.value = 0
    assert int(dut.o_valid.value) and int(dut.o_vstart_nonzero.value)
