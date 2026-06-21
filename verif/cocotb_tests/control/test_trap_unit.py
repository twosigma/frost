"""Unit tests for trap_unit interrupt/MRET arbitration."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


MSTATUS_MIE = 1 << 3
MIE_MTIE = 1 << 7
INTERRUPT_MTIP = 0b010
PRIV_U = 0
PRIV_M = 3


def _drive_defaults(dut: Any) -> None:
    dut.i_pipeline_stall.value = 0
    dut.i_sq_committed_empty.value = 1
    dut.i_mstatus.value = 0
    dut.i_mie.value = 0
    dut.i_mtvec.value = 0x1000
    dut.i_mepc.value = 0x2000
    dut.i_mstatus_mie_direct.value = 0
    dut.i_priv.value = PRIV_M
    dut.i_interrupts.value = 0
    dut.i_exception_valid.value = 0
    dut.i_exception_cause.value = 0
    dut.i_exception_tval.value = 0
    dut.i_exception_pc.value = 0x3000
    dut.i_interrupt_pc.value = 0x4000
    dut.i_mret_start.value = 0
    dut.i_wfi_start.value = 0


async def _reset(dut: Any) -> None:
    _drive_defaults(dut)
    dut.i_rst.value = 1
    await RisingEdge(dut.i_clk)
    await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await RisingEdge(dut.i_clk)


@cocotb.test()
async def test_mret_defers_registered_timer_interrupt(dut: Any) -> None:
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    await _reset(dut)

    dut.i_mstatus.value = MSTATUS_MIE
    dut.i_mstatus_mie_direct.value = 1
    dut.i_mie.value = MIE_MTIE
    dut.i_interrupts.value = INTERRUPT_MTIP

    # Latch a timer interrupt while the trap unit is stalled. This creates the
    # exact bad state from hardware: interrupt_pending is already registered
    # when MRET reaches the trap unit.
    dut.i_pipeline_stall.value = 1
    await RisingEdge(dut.i_clk)

    dut.i_pipeline_stall.value = 0
    dut.i_mret_start.value = 1
    await Timer(1, unit="ns")

    assert int(dut.o_trap_taken.value) == 0
    assert int(dut.o_mret_taken.value) == 1
    assert int(dut.o_trap_target.value) == 0x2000

    await RisingEdge(dut.i_clk)
    dut.i_mret_start.value = 0
    dut.i_priv.value = PRIV_U
    dut.i_mstatus_mie_direct.value = 0
    await Timer(1, unit="ns")
    assert int(dut.o_trap_taken.value) == 0

    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")
    assert int(dut.o_trap_taken.value) == 0


@cocotb.test()
async def test_timer_interrupt_still_traps_without_mret(dut: Any) -> None:
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    await _reset(dut)

    dut.i_mstatus.value = MSTATUS_MIE
    dut.i_mstatus_mie_direct.value = 1
    dut.i_mie.value = MIE_MTIE
    dut.i_interrupts.value = INTERRUPT_MTIP

    dut.i_pipeline_stall.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_pipeline_stall.value = 0
    await Timer(1, unit="ns")

    assert int(dut.o_trap_taken.value) == 1
    assert int(dut.o_mret_taken.value) == 0
    assert int(dut.o_trap_cause.value) == 0x80000007
    assert int(dut.o_trap_target.value) == 0x1000


@cocotb.test()
async def test_registered_interrupt_requires_current_mie(dut: Any) -> None:
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    await _reset(dut)

    dut.i_mstatus.value = MSTATUS_MIE
    dut.i_mstatus_mie_direct.value = 1
    dut.i_mie.value = MIE_MTIE
    dut.i_interrupts.value = INTERRUPT_MTIP

    # Latch a pending timer interrupt, then model the Linux return path clearing
    # mstatus.MIE before that registered pending bit reaches take_trap.
    dut.i_pipeline_stall.value = 1
    await RisingEdge(dut.i_clk)

    dut.i_pipeline_stall.value = 0
    dut.i_mstatus.value = 0
    dut.i_mstatus_mie_direct.value = 0
    await Timer(1, unit="ns")
    assert int(dut.o_trap_taken.value) == 0

    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")
    assert int(dut.o_trap_taken.value) == 0

    # Once MIE is restored, the still-asserted timer interrupt is sampled again
    # and should trap on the registered path.
    dut.i_mstatus.value = MSTATUS_MIE
    dut.i_mstatus_mie_direct.value = 1
    await Timer(1, unit="ns")
    assert int(dut.o_trap_taken.value) == 0

    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")
    assert int(dut.o_trap_taken.value) == 1
    assert int(dut.o_trap_cause.value) == 0x80000007
