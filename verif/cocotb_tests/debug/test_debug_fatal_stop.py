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

"""Drive the debug module through JTAG across a real fatal memory-error stop.

memerr_test ends in a cached writeback error that stops the hart. The test
checks what a debugger sees and can do, with and without the misaligned-access
engine (the registry entry sets MISALIGNED_HW):

- A hart already halted in Debug Mode when the stop arrives. The debugger
  itself writes the faulting line and evicts it with program-buffer accesses.
  dmstatus turns to unavailable, an abstract command ends with cmderr 4 and
  busy clear, and resumereq changes nothing.
- A running hart. haltreq does not enter Debug Mode and dmstatus reads
  unavailable. A command gets cmderr 4. haltreq left set halts the hart as
  soon as ndmreset has cleared the stop.
- After ndmreset the hart is available again: it halts and a register access
  works.
"""

from typing import Any

import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import ClockCycles, FallingEdge

from cocotb_tests.debug.jtag_dtm import (
    CMDERR_HALT_RESUME,
    DM_COMMAND,
    DM_DMCONTROL,
    DMCONTROL_DMACTIVE,
    DMCONTROL_HALTREQ,
    DMCONTROL_NDMRESET,
    DMCONTROL_RESUMEREQ,
    DMSTATUS_ALLHALTED,
    DMSTATUS_ALLHAVERESET,
    DMSTATUS_ALLRESUMEACK,
    DMSTATUS_ALLRUNNING,
    DMSTATUS_ALLUNAVAIL,
    GPR_REGNO_BASE,
    DebugError,
    DebugModule,
    Dtm,
    JtagDriver,
    load,
    store,
)
from cocotb_tests.debug.test_debug import _reset
from cocotb_tests.test_real_program import (
    CLK_PERIOD_NS,
    EccReportDriver,
    UartMonitor,
    cpu_clock,
    generate_divided_clock,
    start_clocks,
    start_cpu_clock,
    takes_last_edge,
)

BANNER_FATAL = "<<EXPECT_FATAL>>"
# The last check before the banner: the hart is still a few thousand cycles
# from the store and evictions that end in the stop.
LAST_CHECK = "[PASS] other-claims"
# memerr_test's faulting line and the stride that evicts it from the L2 set.
WRITE_ERROR_LINE = 0x82000000
L2_SET_STRIDE = 2 << 20
EVICT_LINES = 8
DMSTATUS_ANYUNAVAIL = 1 << 12
DMSTATUS_ANYRUNNING = 1 << 10
DMSTATUS_ANYHALTED = 1 << 8
S0, S1, T0 = 8, 9, 5


def lui(rd: int, imm20: int) -> int:
    """Encode ``lui rd, imm20``."""
    return (imm20 << 12) | (rd << 7) | 0x37


def add(rd: int, rs1: int, rs2: int) -> int:
    """Encode ``add rd, rs1, rs2``."""
    return (rs2 << 20) | (rs1 << 15) | (rd << 7) | 0x33


def _unavailable(status: int) -> bool:
    """Return whether dmstatus reads unavailable with no running or halted bit."""
    return status & (
        DMSTATUS_ALLUNAVAIL | DMSTATUS_ANYUNAVAIL
    ) == DMSTATUS_ALLUNAVAIL | DMSTATUS_ANYUNAVAIL and not status & (
        DMSTATUS_ALLRUNNING
        | DMSTATUS_ANYRUNNING
        | DMSTATUS_ALLHALTED
        | DMSTATUS_ANYHALTED
    )


class Bench:
    """The device under test, its debugger and the hart's internal state."""

    def __init__(self, dut: Any, dm: DebugModule, monitor: UartMonitor) -> None:
        """Bind the debugger and locate the hart's registers."""
        self.dut = dut
        self.dm = dm
        self.monitor = monitor
        self.cpu = dut.cpu_and_memory_subsystem.cpu.hart.cpu_inst
        self.csr = self.cpu.csr_file_inst

    def stopped(self) -> bool:
        """Return whether the hart's fatal stop is set."""
        return bool(int(self.cpu.i_fatal_stop.value))

    def in_debug_mode(self) -> bool:
        """Return whether the hart is in Debug Mode."""
        return bool(int(self.cpu.csr_debug_mode.value))

    def instret(self) -> int:
        """Return the retired-instruction count."""
        return int(self.csr.instret_counter.value)

    async def wait_text(self, text: str, count: int, limit: int = 600_000) -> None:
        """Wait until the UART output holds ``text`` at least ``count`` times."""
        for _ in range(limit // 100):
            if self.monitor.get_output().count(text) >= count:
                return
            await ClockCycles(self.dut.i_clk, 100)
        raise AssertionError(f"{text!r} x{count} not seen")

    async def refused_command(self) -> None:
        """Check that an abstract register read ends with cmderr 4 and busy clear."""
        dm = self.dm
        await dm.dtm.write(
            DM_COMMAND,
            dm.access_register(GPR_REGNO_BASE + T0, write=False, size=64),
        )
        err = await dm.wait_command()  # returns only when busy is clear
        assert err == CMDERR_HALT_RESUME, f"cmderr {err}, want {CMDERR_HALT_RESUME}"
        await dm.clear_cmderr()
        assert await dm.cmderr() == 0

    async def command_until_refused(self, limit: int = 150) -> int:
        """Issue register reads until one ends with cmderr 4; return how many."""
        dm = self.dm
        word = dm.access_register(GPR_REGNO_BASE + T0, write=False, size=64)
        for count in range(limit):
            await dm.dtm.write(DM_COMMAND, word)
            err = await dm.wait_command()
            if err == CMDERR_HALT_RESUME:
                await dm.clear_cmderr()
                assert await dm.cmderr() == 0
                return count + 1
            assert err == 0, f"unexpected cmderr {err} before the stop"
        raise AssertionError("no command was refused: the hart did not stop")

    async def stop_on_step_done(self, result: dict[str, Any]) -> None:
        """Raise the stop as a single step completes; record what follows.

        The forced flops stand for the registered stop at the cache. The record
        shows whether the finished step and the stop met, and whether the hart
        then entered Debug Mode.
        """
        edge = FallingEdge(cpu_clock(self.dut))
        bus = self.dut.cpu_and_memory_subsystem.cpu
        while not int(self.cpu.step_done_set.value):
            await edge
        # step_done_q rises at the next edge; the stop is visible in that same
        # cycle, as when the cache raises it one cycle before.
        await edge
        bus.hart_fatal_stop_q.value = Force(1)
        bus.o_fatal_error.value = Force(1)
        met = entered = pending = False
        for _ in range(80):
            await edge
            met |= bool(int(self.cpu.step_done_q.value)) and self.stopped()
            entered |= self.in_debug_mode()
            pending |= bool(int(self.cpu.trap_unit_inst.d_int_pending.value))
        result.update(met=met, entered=entered, pending=pending)

    def release_stop(self) -> None:
        """Release the forced stop flops."""
        bus = self.dut.cpu_and_memory_subsystem.cpu
        bus.hart_fatal_stop_q.value = Release()
        bus.o_fatal_error.value = Release()

    async def hold_unavailable(self, polls: int) -> None:
        """Dmstatus stays exactly unavailable and the hart retires nothing."""
        retired = self.instret()
        for _ in range(polls):
            status = await self.dm.dmstatus()
            assert _unavailable(status), f"dmstatus {status:#x}"
            assert self.stopped()
        assert self.instret() == retired, "the stopped hart retired instructions"

    async def recover(self, haltreq: bool = False) -> None:
        """Ndmreset clears the stop; the hart reports a reset and is available.

        With ``haltreq`` the request stays set across the reset, as a debugger
        that resets and halts writes it.
        """
        dm = self.dm
        level = DMCONTROL_DMACTIVE | (DMCONTROL_HALTREQ if haltreq else 0)
        await dm.dtm.write(DM_DMCONTROL, level | DMCONTROL_NDMRESET)
        await ClockCycles(self.dut.i_clk, 60)
        await dm.dtm.write(DM_DMCONTROL, level)
        for _ in range(400):
            status = await dm.dmstatus()
            if status & DMSTATUS_ALLHAVERESET and not status & DMSTATUS_ALLUNAVAIL:
                break
        else:
            raise AssertionError(f"hart still unavailable after ndmreset: {status:#x}")
        assert not self.stopped()
        await dm.ack_havereset()

    async def prove_available(self) -> None:
        """Check that the hart halts and a register write then read works."""
        dm = self.dm
        await dm.halt()
        assert await dm.is_halted()
        await dm.write_gpr(S0, 0x1234_5678_9ABC_DEF0)
        assert await dm.read_gpr(S0) == 0x1234_5678_9ABC_DEF0


@cocotb.test()
@takes_last_edge
async def test_debug_fatal_stop(dut: Any) -> None:
    """A fatally stopped hart is unavailable to the debugger until reset."""
    start_clocks((dut.i_clk,), CLK_PERIOD_NS * 1000)
    start_cpu_clock(dut)
    cocotb.start_soon(generate_divided_clock(dut))
    log = cocotb.log
    await _reset(dut)
    # memerr_test expects the X3's ECC reader; play it as the real-program bench does.
    cocotb.start_soon(EccReportDriver(dut).run())
    monitor = UartMonitor(dut)
    await monitor.start()
    jtag = JtagDriver(dut, half_period=1)
    await jtag.reset()
    dm = DebugModule(Dtm(jtag, idle_cycles=0), log)
    await dm.activate()
    bench = Bench(dut, dm, monitor)
    engine = int(dut.MISALIGNED_HW.value)
    log.info(f"FATALDBG MISALIGNED_HW={engine}")

    # ---- Halted first, then the stop --------------------------------------
    await bench.wait_text(LAST_CHECK, 1)
    await dm.halt()
    status = await dm.dmstatus()
    assert status & DMSTATUS_ALLHALTED and not status & DMSTATUS_ALLUNAVAIL
    assert bench.in_debug_mode() and not bench.stopped()
    # The stop can arrive between two of the debugger's own commands: the next
    # one is then refused with cmderr 4, which clears busy like any refusal.
    refused = 0
    try:
        await dm.write_gpr(S0, WRITE_ERROR_LINE)
        await dm.write_gpr(S1, 0x5A5A5A5A5A5A5A5A)
        await dm.exec_progbuf([store(S1, S0, 8)])
        # Three runs of three dependent loads, one set stride apart: nine
        # lines that map to the faulting line's L2 set evict it.
        assert L2_SET_STRIDE == 0x200 << 12 and EVICT_LINES <= 9
        evict = [lui(T0, 0x200)]
        for _ in range(3):
            evict += [add(S0, S0, T0), load(S1, S0, 8)]
        for _ in range(3):
            await dm.exec_progbuf(evict)
    except DebugError as err:
        assert f"cmderr {CMDERR_HALT_RESUME}" in str(err), str(err)
        await dm.clear_cmderr()
        refused = 1
    if not refused:
        refused = await bench.command_until_refused()
    log.info(f"FATALDBG halted hart: a command was refused after the stop ({refused})")
    assert bench.stopped() and bench.in_debug_mode(), "the hart was halted at the stop"
    await bench.hold_unavailable(12)
    await dm.dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE | DMCONTROL_RESUMEREQ)
    await dm.dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE)
    await bench.hold_unavailable(12)
    assert not await dm.dmstatus() & DMSTATUS_ALLRESUMEACK
    # Clearing and setting dmactive resets the debug module, not the hart.
    await dm.dtm.write(DM_DMCONTROL, 0)
    await dm.dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE)
    assert bench.stopped()
    await bench.hold_unavailable(12)
    await bench.refused_command()
    await bench.recover()
    await bench.prove_available()
    log.info("FATALDBG halted-hart case passed")

    # ---- Running hart ------------------------------------------------------
    await dm.resume()
    await bench.wait_text(BANNER_FATAL, 1)
    for _ in range(4000):
        status = await dm.dmstatus()
        if status & DMSTATUS_ALLUNAVAIL:
            break
        assert status & DMSTATUS_ALLRUNNING, f"dmstatus {status:#x}"
    else:
        raise AssertionError("the running hart never read as unavailable")
    assert bench.stopped() and not bench.in_debug_mode()
    await bench.hold_unavailable(12)
    # The resume that preceded the stop left the acknowledge set; a new
    # resumereq clears it, starts nothing, and must not read as done.
    await dm.dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE | DMCONTROL_RESUMEREQ)
    await dm.dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE)
    status = await dm.dmstatus()
    assert not status & DMSTATUS_ALLRESUMEACK and _unavailable(status), hex(status)
    await dm.dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE | DMCONTROL_HALTREQ)
    await bench.hold_unavailable(30)
    assert not bench.in_debug_mode(), "haltreq entered Debug Mode after the stop"
    await bench.refused_command()
    # haltreq stays set through the reset: the hart halts as soon as it is back.
    await bench.recover(haltreq=True)
    for _ in range(400):
        if await dm.is_halted():
            break
    else:
        raise AssertionError("the level haltreq did not halt the hart after reset")
    await dm.dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE)
    await dm.write_gpr(S0, 0x0FED_CBA9_8765_4321)
    assert await dm.read_gpr(S0) == 0x0FED_CBA9_8765_4321
    status = await dm.dmstatus()
    assert not _unavailable(status) and status & DMSTATUS_ALLHALTED
    log.info("FATALDBG running-hart case passed")

    # ---- A step, then the stop in the cycle the step completes ----------------
    await dm.set_step(True)
    before = await dm.read_dpc()
    after = await dm.step()
    assert after != before, "a single step did not advance"
    result: dict[str, Any] = {}
    watcher = cocotb.start_soon(bench.stop_on_step_done(result))
    await dm.dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE | DMCONTROL_RESUMEREQ)
    await dm.dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE)
    for _ in range(300):
        if _unavailable(await dm.dmstatus()):
            break
    else:
        raise AssertionError("the stepping hart never read as unavailable")
    await watcher
    log.info(f"FATALDBG step then stop: {result}")
    assert result["met"], "the stop did not meet the finished step"
    if not engine:
        # The gate at the trap unit refuses the step. With the engine built the
        # engine's terminal state shields the entry instead (checked next).
        assert not result["pending"], "a finished step queued a halt after the stop"
    assert not result["entered"], "no further step may complete after the stop"
    bench.release_stop()
    await bench.recover()
    await bench.prove_available()
    log.info("FATALDBG step case passed")
    await ClockCycles(dut.i_clk, 10)
