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

"""Unit tests for trap-unit arbitration and committed-store drain behavior."""

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
    dut.i_amo_at_head.value = 0
    dut.i_device_read_at_head.value = 0
    # Debug Mode seam (Phase 3 M3): idle unless a test drives it.
    dut.i_debug_mode.value = 0
    dut.i_dbg_haltreq.value = 0
    dut.i_dbg_step_req.value = 0
    dut.i_dbg_step_armed.value = 0
    dut.i_dbg_go.value = 0
    dut.i_dbg_go_target.value = 0
    dut.i_dcsr_ebreak.value = 0
    dut.i_dpc.value = 0
    dut.i_dret_start.value = 0


async def _reset(dut: Any) -> None:
    _drive_defaults(dut)
    dut.i_rst.value = 1
    await RisingEdge(dut.i_clk)
    await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await RisingEdge(dut.i_clk)


@cocotb.test()
async def test_mret_defers_registered_timer_interrupt(dut: Any) -> None:
    """Verify that a pending timer interrupt is deferred while MRET is in flight."""
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
    # Once the MRET-recovery inhibit lifts, the machine timer source is still
    # live: it was held across the inhibit rather than force-cleared, so a real
    # timer tick is never lost. It becomes eligible at the first eligible
    # boundary (U-mode here, where a machine interrupt preempts regardless of
    # MIE). The 0x80388bba panic is guarded by cpu_ooo's interrupt_resume_pc
    # seed on mret_taken, not by this latch (718f8cc). The eligible cycle arms
    # the take and raises o_trap_drain_wait (commit hold); the trap is taken
    # one cycle later.
    assert int(dut.o_trap_taken.value) == 0
    assert int(dut.o_trap_drain_wait.value) == 1

    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")
    assert int(dut.o_trap_taken.value) == 1
    # Machine timer interrupt: interrupt bit at XLEN-1 (bit 63), code 7.
    assert int(dut.o_trap_cause.value) == (1 << 63) | 7


@cocotb.test()
async def test_timer_interrupt_still_traps_without_mret(dut: Any) -> None:
    """Verify that a latched timer interrupt traps when no MRET is in flight."""
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

    # First eligible cycle arms the take (and holds commit via
    # o_trap_drain_wait); the trap is taken the following cycle.
    assert int(dut.o_trap_taken.value) == 0
    assert int(dut.o_trap_drain_wait.value) == 1

    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")
    assert int(dut.o_trap_taken.value) == 1
    assert int(dut.o_mret_taken.value) == 0
    # Machine timer interrupt: interrupt bit at XLEN-1 (bit 63), code 7.
    assert int(dut.o_trap_cause.value) == (1 << 63) | 7
    assert int(dut.o_trap_target.value) == 0x1000


@cocotb.test()
async def test_device_read_shield_defers_interrupt_until_released(dut: Any) -> None:
    """A device read at the ROB head defers interrupt take until it clears.

    This is the duplicate-destructive-read guard seen from the trap side. An
    MMIO read is irrevocable at the router's terminal accept, so no interrupt
    may be taken between that accept and the owning load's commit. The shield
    must also stay bounded: while it defers, commit must not be held, or the
    load could never commit and the interrupt would never take.
    """
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    await _reset(dut)

    dut.i_mstatus.value = MSTATUS_MIE
    dut.i_mstatus_mie_direct.value = 1
    dut.i_mie.value = MIE_MTIE
    dut.i_interrupts.value = INTERRUPT_MTIP
    dut.i_device_read_at_head.value = 1

    dut.i_pipeline_stall.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_pipeline_stall.value = 0
    await Timer(1, unit="ns")

    # Arm the take, then hold it off for as long as the device read owns the
    # head. The interrupt is eligible and armed the whole time.
    for _ in range(8):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        assert (
            int(dut.o_trap_taken.value) == 0
        ), "interrupt escaped the device-read shield"
        # Boundedness: the drain is open, so commit must not be held here.
        assert int(dut.o_trap_drain_wait.value) == 0, "shield window held commit"

    # Releasing the shield takes the still-pending interrupt immediately.
    dut.i_device_read_at_head.value = 0
    await Timer(1, unit="ns")
    assert int(dut.o_trap_taken.value) == 1
    assert int(dut.o_trap_cause.value) == (1 << 63) | 7


@cocotb.test()
async def test_device_read_shield_does_not_defer_exceptions(dut: Any) -> None:
    """Exceptions stay ungated by the shield, exactly as with the AMO shield."""
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    await _reset(dut)

    dut.i_device_read_at_head.value = 1
    dut.i_exception_valid.value = 1
    dut.i_exception_cause.value = 2  # illegal instruction
    # exception_pending is registered, so the take lands the following cycle.
    # Unlike an interrupt, it is never deferred by the shield.
    await RisingEdge(dut.i_clk)
    dut.i_exception_valid.value = 0
    await Timer(1, unit="ns")
    assert int(dut.o_trap_taken.value) == 1
    assert int(dut.o_trap_cause.value) == 2


@cocotb.test()
async def test_registered_interrupt_requires_current_mie(dut: Any) -> None:
    """Verify that a held interrupt is only taken when current MIE is asserted."""
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

    # The timer interrupt was held across the MIE-low window, not erased, so it
    # is eligible again on the restore cycle. That is one cycle earlier than the
    # old clear-then-re-latch path, which could lose the tick if MIE never
    # stayed high long enough (the no-MMU boot lost-tick hang). Taking it still
    # requires current MIE (eligible gates on live m_int_globally_enabled), so
    # the test name still holds.
    dut.i_mstatus.value = MSTATUS_MIE
    dut.i_mstatus_mie_direct.value = 1
    await Timer(1, unit="ns")
    # The restore cycle re-arms the take; the held tick is taken the cycle
    # after. It is never lost: the source is held, not erased.
    assert int(dut.o_trap_taken.value) == 0
    assert int(dut.o_trap_drain_wait.value) == 1

    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")
    assert int(dut.o_trap_taken.value) == 1
    # Machine timer interrupt: interrupt bit at XLEN-1 (bit 63), code 7.
    assert int(dut.o_trap_cause.value) == (1 << 63) | 7

    # Cleared on take (trap_taken_prev gates re-entry); does not re-fire next cycle.
    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")
    assert int(dut.o_trap_taken.value) == 0


@cocotb.test()
async def test_exception_waits_for_committed_store_drain(dut: Any) -> None:
    """An early LQ exception cannot enter its trap until stores have drained."""
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    await _reset(dut)

    dut.i_sq_committed_empty.value = 0
    dut.i_exception_valid.value = 1
    dut.i_exception_cause.value = 4
    dut.i_exception_tval.value = 0x4000_0002
    dut.i_exception_pc.value = 0x3000
    await RisingEdge(dut.i_clk)
    dut.i_exception_valid.value = 0
    await Timer(1, unit="ns")

    assert int(dut.o_trap_taken.value) == 0
    assert int(dut.o_trap_drain_wait.value) == 1

    for _ in range(2):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        assert int(dut.o_trap_taken.value) == 0
        assert int(dut.o_trap_drain_wait.value) == 1

    dut.i_sq_committed_empty.value = 1
    await Timer(1, unit="ns")
    assert int(dut.o_trap_taken.value) == 1
    assert int(dut.o_trap_cause.value) == 4
    assert int(dut.o_trap_value.value) == 0x4000_0002
