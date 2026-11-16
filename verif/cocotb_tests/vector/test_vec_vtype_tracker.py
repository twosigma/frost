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


async def reset_tracker(dut: Any) -> None:
    """Reset the tracker and wait for its initial architectural reload."""
    Clock(dut.i_clk, 10, unit="ns").start()
    dut.i_rst.value = 1
    dut.i_alloc.value = 0
    dut.i_alloc_op.value = _parse_instr_op_enum()["ADDI"]
    dut.i_alloc_imm.value = 0
    dut.i_ckpt_save.value = 0
    dut.i_ckpt_id.value = 0
    dut.i_restore.value = 0
    dut.i_restore_id.value = 0
    dut.i_flush_all.value = 0
    dut.i_vcfg_in_flight.value = 0
    dut.i_arch_vtype.value = 0x100
    for _ in range(2):
        await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    for _ in range(5):
        await FallingEdge(dut.i_clk)
    assert int(dut.o_valid.value) and int(dut.o_vtype.value) == 0x100


@cocotb.test()
async def configuration_handoff(dut: Any) -> None:
    """Never expose the previous vtype between vsetvl dispatch and retirement."""
    ops = _parse_instr_op_enum()
    await reset_tracker(dut)
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


@cocotb.test()
async def immediate_and_recovery(dut: Any) -> None:
    """Immediate forms and recovery retain the configuration of surviving code."""
    ops = _parse_instr_op_enum()
    await reset_tracker(dut)

    async def cycles(count: int) -> None:
        for _ in range(count):
            await FallingEdge(dut.i_clk)

    async def allocate(name: str, immediate: int = 0) -> None:
        dut.i_alloc.value = 1
        dut.i_alloc_op.value = ops[name]
        dut.i_alloc_imm.value = immediate
        await cycles(1)
        dut.i_alloc.value = 0

    for name, immediate, expected in (
        ("VSETVLI", 0x10, 0x10),
        ("VSETIVLI", 0xC01, 0x01),
        ("VSETVLI", 0x100, 0x100),
    ):
        await allocate(name, immediate)
        assert int(dut.o_valid.value)
        assert int(dut.o_vtype.value) == expected
        dut.i_vcfg_in_flight.value = 1
        await cycles(2)
        dut.i_arch_vtype.value = expected
        dut.i_vcfg_in_flight.value = 0
        await cycles(5)
        assert int(dut.o_valid.value) and int(dut.o_vtype.value) == expected

    # A full flush removes an allocated register-form configuration. The
    # old architectural state returns after the pipeline indication drains.
    dut.i_arch_vtype.value = 0x10
    await allocate("VSETVL")
    dut.i_vcfg_in_flight.value = 1
    dut.i_flush_all.value = 1
    await cycles(1)
    dut.i_flush_all.value = 0
    await cycles(2)
    assert not int(dut.o_valid.value)
    dut.i_vcfg_in_flight.value = 0
    await cycles(5)
    assert int(dut.o_valid.value) and int(dut.o_vtype.value) == 0x10

    # A flush after the configuration commits squashes only younger work.
    # Its retiring architectural write arrives after the ROB flag drops.
    await allocate("VSETVL")
    dut.i_vcfg_in_flight.value = 1
    await cycles(3)
    dut.i_vcfg_in_flight.value = 0
    dut.i_flush_all.value = 1
    await cycles(1)
    dut.i_flush_all.value = 0
    dut.i_arch_vtype.value = 0x18
    await cycles(5)
    assert int(dut.o_valid.value) and int(dut.o_vtype.value) == 0x18

    # Restore a known checkpoint after a wrong-path immediate change.
    dut.i_ckpt_save.value = 1
    dut.i_ckpt_id.value = 0
    await cycles(1)
    dut.i_ckpt_save.value = 0
    await allocate("VSETIVLI", 0xC00)
    assert int(dut.o_vtype.value) == 0
    dut.i_restore.value = 1
    dut.i_restore_id.value = 0
    await cycles(1)
    dut.i_restore.value = 0
    assert int(dut.o_valid.value) and int(dut.o_vtype.value) == 0x18
    await cycles(5)

    # A checkpoint one cycle behind unresolved vsetvl must save unknown,
    # even though the registered ROB in-flight indication has not arrived.
    await allocate("VSETVL")
    dut.i_ckpt_save.value = 1
    dut.i_ckpt_id.value = 1
    await cycles(1)
    dut.i_ckpt_save.value = 0
    dut.i_vcfg_in_flight.value = 1
    await allocate("VSETVLI", 0x08)
    dut.i_restore.value = 1
    dut.i_restore_id.value = 1
    await cycles(1)
    dut.i_restore.value = 0
    assert not int(dut.o_valid.value), "restored a stale configuration behind vsetvl"
    dut.i_vcfg_in_flight.value = 0
    await cycles(1)
    dut.i_arch_vtype.value = 0x00
    await cycles(4)
    assert int(dut.o_valid.value) and int(dut.o_vtype.value) == 0
