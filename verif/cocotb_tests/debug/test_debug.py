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
"""RISC-V debug module directed test (Phase 3 M3).

A cocotb debugger (cocotb_tests.debug.jtag_dtm) drives frost's JTAG pins
while `debug_target` runs, and walks the debug spec's contract end to end:
DTM identification and the sticky-busy protocol, dmactive, the hartsel WARL
probe OpenOCD performs, halt with dcsr.cause/prv, abstract GPR access in both
sizes, progbuf-based CSR and memory access across the BRAM / MMIO / DDR
tiers, abstractauto, a progbuf exception, software breakpoints planted in
BRAM code (a 32-bit ebreak and a halfword c.ebreak — both only work because
the Debug-Mode store mirror lands them in the instruction copy), single
stepping over 32-bit / RVC instructions, a ret, and an ecall (dpc must land
on the trap handler), a halt in U-mode with the privilege round-trip through
dcsr.prv, the program observing the debugger's memory writes (its PASS
banner is gated on them), a halt out of a wfi loop, and ndmreset with
havereset/ackhavereset.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

from cocotb_tests.debug.jtag_dtm import (
    CMDERR_EXCEPTION,
    CMDERR_NOT_SUPPORTED,
    CSR_DPC,
    CSR_DSCRATCH0,
    CSR_MISA,
    CSR_MTVEC,
    DCSR_CAUSE_EBREAK,
    DCSR_CAUSE_HALTREQ,
    DCSR_CAUSE_MASK,
    DCSR_CAUSE_SHIFT,
    DCSR_CAUSE_STEP,
    DCSR_EBREAKM,
    DCSR_EBREAKS,
    DCSR_EBREAKU,
    DCSR_PRV_MASK,
    DM_ABSTRACTAUTO,
    DM_DATA0,
    DM_DATA1,
    DM_DMCONTROL,
    DM_HARTINFO,
    DM_SBCS,
    DMCONTROL_DMACTIVE,
    DMCONTROL_HARTSELHI_MASK,
    DMCONTROL_HARTSELLO_MASK,
    DMCONTROL_HASEL,
    DMSTATUS_ALLHALTED,
    DMSTATUS_ALLHAVERESET,
    DMSTATUS_ALLRESUMEACK,
    DMSTATUS_ALLRUNNING,
    DMSTATUS_ALLUNAVAIL,
    DMSTATUS_AUTHENTICATED,
    DMSTATUS_IMPEBREAK,
    FROST_IDCODE,
    INSN_C_EBREAK,
    INSN_EBREAK,
    DebugModule,
    Dtm,
    JtagDriver,
    addi,
    load,
)
from cocotb_tests.test_real_program import (
    CLK_PERIOD_NS,
    UartMonitor,
    generate_divided_clock,
)

RESET_CYCLES = 10
BANNER_START = "debug_target: start"
BANNER_PHASE_U = "debug_target: phase U"
BANNER_PASS = "debug_target: <<PASS>>"
MTIME_LO_ADDR = 0x4000_0010
# Scratch far from either arrangement's image (the ddr build places the
# whole program at 0x8000_0000+, so a near-image scratch would corrupt it).
DDR_SCRATCH_ADDR = 0x8010_0000


def _read_symbols() -> dict[str, int]:
    """Symbol table of the running program (tests/sw.mem -> <app>/sw.mem)."""
    sw_mem = Path("sw.mem")
    elf = (
        sw_mem.resolve().with_name("sw.elf")
        if sw_mem.is_symlink()
        else Path("../sw/apps/debug_target/sw.elf")
    )
    prefix = os.environ.get("RISCV_PREFIX", "riscv-none-elf-")
    out = subprocess.run(
        [f"{prefix}nm", str(elf)], check=True, capture_output=True, text=True
    ).stdout
    symbols: dict[str, int] = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3:
            symbols[parts[2]] = int(parts[0], 16)
    return symbols


async def _wait_text(
    monitor: UartMonitor, dut: Any, text: str, max_cycles: int = 400000
) -> None:
    for _ in range(max_cycles // 200):
        if monitor.contains(text):
            return
        await ClockCycles(dut.i_clk, 200)
    raise AssertionError(
        f"timeout waiting for UART text {text!r}; got {monitor.get_output()!r}"
    )


async def _reset(dut: Any) -> None:
    dut.i_instr_mem_en.value = 0
    dut.i_rst_n.value = 0
    dut.i_uart_rx.value = 1
    dut.i_external_interrupt.value = 0
    await Timer(2 * CLK_PERIOD_NS, unit="ns")
    for _ in range(RESET_CYCLES):
        await RisingEdge(dut.i_clk)
    dut.i_rst_n.value = 1


def _cause(dcsr: int) -> int:
    return (dcsr & DCSR_CAUSE_MASK) >> DCSR_CAUSE_SHIFT


@cocotb.test()
async def test_debug(dut: Any) -> None:
    """Bit-bang a full debugger session against the frost toplevel."""
    cocotb.start_soon(Clock(dut.i_clk, CLK_PERIOD_NS, unit="ns").start())
    cocotb.start_soon(generate_divided_clock(dut))
    log = cocotb.log
    syms = _read_symbols()
    for name in (
        "counter",
        "flag",
        "ecall_count",
        "table",
        "bp_target",
        "bp_target_rvc",
        "u_loop",
        "u_ecall_site",
        "u_loop_end",
        "trap_entry",
        "trap_dispatch",
    ):
        if name not in syms:
            raise AssertionError(f"symbol {name} missing from debug_target")
    log.info(
        "symbols: "
        + ", ".join(
            f"{k}={syms[k]:#x}"
            for k in ("counter", "flag", "bp_target", "u_loop", "trap_entry")
        )
    )

    jtag = JtagDriver(dut, half_period=4)
    await _reset(dut)
    monitor = UartMonitor(dut)
    await monitor.start()

    # ---- DTM identification ------------------------------------------------
    await jtag.reset()
    dtm = Dtm(jtag, idle_cycles=0)
    dtm.trace = os.environ.get("FROST_DMI_TRACE") == "1"
    idcode = await dtm.idcode()
    assert idcode == FROST_IDCODE, f"IDCODE {idcode:#x}"
    dtmcs = await dtm.dtmcs_read()
    assert dtmcs & 0xF == 1, f"dtmcs version {dtmcs:#x}"
    assert (dtmcs >> 4) & 0x3F == 7, f"dtmcs abits {dtmcs:#x}"
    log.info(f"dtmcs={dtmcs:#x} idle hint={(dtmcs >> 12) & 7}")

    # ---- Debug module activation and OpenOCD's examine probes ---------------
    dm = DebugModule(dtm, log)
    await dm.activate()
    await dtm.write(
        DM_DMCONTROL,
        DMCONTROL_DMACTIVE
        | DMCONTROL_HASEL
        | DMCONTROL_HARTSELLO_MASK
        | DMCONTROL_HARTSELHI_MASK,
    )
    dmcontrol = await dtm.read(DM_DMCONTROL)
    assert dmcontrol & DMCONTROL_DMACTIVE
    assert (
        dmcontrol
        & (DMCONTROL_HASEL | DMCONTROL_HARTSELLO_MASK | DMCONTROL_HARTSELHI_MASK)
        == 0
    ), f"hartsel/hasel must be WARL 0: dmcontrol={dmcontrol:#x}"
    await dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE)
    hartinfo = await dtm.read(DM_HARTINFO)
    assert (
        hartinfo & 0xFFF == 0x7B4 and (hartinfo >> 16) & 1 == 0
    ), f"hartinfo {hartinfo:#x}"
    assert (await dtm.read(DM_SBCS)) == 0
    cs = await dm.abstractcs()
    assert (cs >> 24) & 0x1F == 8 and cs & 0xF == 2, f"abstractcs {cs:#x}"
    status = await dm.dmstatus()
    assert (
        status & 0xF == 2
        and status & DMSTATUS_AUTHENTICATED
        and status & DMSTATUS_IMPEBREAK
    ), f"dmstatus {status:#x}"
    if status & DMSTATUS_ALLHAVERESET:
        await dm.ack_havereset()
        assert not (await dm.dmstatus()) & DMSTATUS_ALLHAVERESET

    await _wait_text(monitor, dut, BANNER_START)
    status = await dm.dmstatus()
    assert (
        status & DMSTATUS_ALLRUNNING and not status & DMSTATUS_ALLHALTED
    ), f"dmstatus {status:#x}"

    # ---- Halt in M-mode ------------------------------------------------------
    await dm.halt()
    dcsr = await dm.read_dcsr()
    assert _cause(dcsr) == DCSR_CAUSE_HALTREQ, f"dcsr {dcsr:#x}"
    assert dcsr & DCSR_PRV_MASK == 3, f"dcsr.prv {dcsr:#x}"
    assert (dcsr >> 28) == 4, f"xdebugver {dcsr:#x}"
    dpc = await dm.read_dpc()
    log.info(f"halted: dcsr={dcsr:#x} dpc={dpc:#x}")
    counter_at_halt = await dm.read_mem(syms["counter"], 8)
    await ClockCycles(dut.i_clk, 200)
    assert (
        await dm.read_mem(syms["counter"], 8)
    ) == counter_at_halt, "counter moved while halted"

    # ---- GPRs: both sizes, x0, unsupported forms ------------------------------
    assert (await dm.read_gpr(0)) == 0
    saved_t0 = await dm.read_gpr(5)
    await dm.write_gpr(5, 0x1122334455667788)
    assert (await dm.read_gpr(5)) == 0x1122334455667788
    assert (await dm.read_gpr(5, size=32)) == 0x55667788
    await dm.command(
        dm.access_register(0x1000 + 5, write=True, size=32), expect=CMDERR_NOT_SUPPORTED
    )
    await dm.clear_cmderr()
    await dm.command(
        dm.access_register(0x1000 + 5, write=False, size=128),
        expect=CMDERR_NOT_SUPPORTED,
    )
    await dm.clear_cmderr()
    await dm.command(
        dm.access_register(0x0300, write=False, size=64), expect=CMDERR_NOT_SUPPORTED
    )
    await dm.clear_cmderr()
    await dm.write_gpr(5, saved_t0)
    all_gprs = [await dm.read_gpr(i) for i in range(32)]
    log.info("gprs: " + " ".join(f"{v:x}" for v in all_gprs))

    # ---- CSRs through the program buffer -------------------------------------
    misa = await dm.read_csr(CSR_MISA)
    assert misa == 0x8000_0000_0014_112F, f"misa {misa:#x}"
    assert (await dm.read_csr(CSR_MTVEC)) == syms["trap_entry"]
    await dm.write_csr(CSR_DSCRATCH0, 0xDEADBEEFCAFEF00D)
    assert (await dm.read_csr(CSR_DSCRATCH0)) == 0xDEADBEEFCAFEF00D
    assert (await dm.read_csr(CSR_DPC)) == dpc

    # ---- Memory: BRAM data, MMIO, DDR, sizes -------------------------------
    table = syms["table"]
    assert (await dm.read_mem(table, 8)) == 0x1000000000000001
    assert (await dm.read_mem(table + 8, 4)) == 0x00000002
    assert (await dm.read_mem(table + 8, 2)) == 0x0002
    assert (await dm.read_mem(table + 8, 1)) == 0x02
    await dm.write_mem(table + 16, 8, 0xA5A5A5A5A5A5A5A5)
    assert (await dm.read_mem(table + 16, 8)) == 0xA5A5A5A5A5A5A5A5
    await dm.write_mem(table + 16, 2, 0x1234)
    assert (await dm.read_mem(table + 16, 8)) == 0xA5A5A5A5A5A51234
    await dm.write_mem(table + 16, 1, 0x99)
    assert (await dm.read_mem(table + 16, 8)) == 0xA5A5A5A5A5A51299
    mtime_a = await dm.read_mem(MTIME_LO_ADDR, 4)
    mtime_b = await dm.read_mem(MTIME_LO_ADDR, 4)
    assert mtime_b > mtime_a, f"mtime did not advance: {mtime_a} {mtime_b}"
    await dm.write_mem(DDR_SCRATCH_ADDR, 8, 0x0123456789ABCDEF)
    await dm.write_mem(DDR_SCRATCH_ADDR + 8, 4, 0xFEEDFACE)
    assert (await dm.read_mem(DDR_SCRATCH_ADDR, 8)) == 0x0123456789ABCDEF
    assert (await dm.read_mem(DDR_SCRATCH_ADDR + 8, 4)) == 0xFEEDFACE

    # ---- A progbuf exception: unmapped address -> cmderr 3 -------------------
    await dm.read_mem(0xDEAD_0000_0000, 8, expect=CMDERR_EXCEPTION)
    assert (await dm.cmderr()) == 0
    # The hart is still parked and usable afterwards.
    assert (await dm.read_gpr(0)) == 0

    # ---- abstractauto: OpenOCD's block read loop -----------------------------
    saved_s0 = await dm.read_gpr(dm.S0)
    saved_s1 = await dm.read_gpr(dm.S1)
    await dm.write_gpr(dm.S0, table)
    # OpenOCD's shape: prime s1 with the first element (progbuf only), then a
    # transfer+postexec command moves it out while the program loads the next;
    # with autoexecdata set, every data0 read re-runs that command.
    await dm.exec_progbuf([load(dm.S1, dm.S0, 8), addi(dm.S0, dm.S0, 8)])
    await dm.command(
        dm.access_register(0x1000 + dm.S1, write=False, size=64, postexec=True)
    )
    await dtm.write(DM_ABSTRACTAUTO, 1)
    words = []
    for _ in range(4):
        # OpenOCD's order for 64-bit block reads: data1 first (no autoexec),
        # then data0 -- whose read re-runs the command for the next element.
        hi = await dtm.read(DM_DATA1)
        lo = await dtm.read(DM_DATA0)
        await dm.wait_command()
        words.append(lo | (hi << 32))
    await dtm.write(DM_ABSTRACTAUTO, 0)
    await dm.wait_command()
    assert words[:3] == [
        0x1000000000000001,
        0x1000000000000002,
        0xA5A5A5A5A5A51299,
    ], f"autoexec block read: {[hex(w) for w in words]}"
    await dm.write_gpr(dm.S1, saved_s1)
    await dm.write_gpr(dm.S0, saved_s0)

    # ---- Software breakpoint in BRAM code (32-bit ebreak via the mirror) ----
    bp = syms["bp_target"]
    original = await dm.read_mem(bp, 4)
    await dm.write_mem(bp, 4, INSN_EBREAK)
    await dm.set_step(False, ebreak_bits=DCSR_EBREAKM | DCSR_EBREAKS | DCSR_EBREAKU)
    await dm.resume()
    await dm.wait_status(DMSTATUS_ALLHALTED)
    dcsr = await dm.read_dcsr()
    dpc = await dm.read_dpc()
    assert (
        _cause(dcsr) == DCSR_CAUSE_EBREAK and dpc == bp
    ), f"breakpoint: dcsr={dcsr:#x} dpc={dpc:#x}"
    await dm.write_mem(bp, 4, original)
    assert (await dm.read_mem(bp, 4)) == original

    # ---- Single steps: 32-bit, RVC, RVC, ret ---------------------------------
    await dm.set_step(True)
    ra = await dm.read_gpr(1)
    for expected in (bp + 4, bp + 6, bp + 8, ra):
        dpc = await dm.step()
        dcsr = await dm.read_dcsr()
        assert (
            dpc == expected and _cause(dcsr) == DCSR_CAUSE_STEP
        ), f"step: dpc={dpc:#x} expected {expected:#x} dcsr={dcsr:#x}"
    await dm.set_step(False)

    # ---- Halfword c.ebreak breakpoint ----------------------------------------
    rvc = syms["bp_target_rvc"]
    original_half = await dm.read_mem(rvc, 2)
    await dm.write_mem(rvc, 2, INSN_C_EBREAK)
    await dm.resume()
    await dm.wait_status(DMSTATUS_ALLHALTED)
    dcsr = await dm.read_dcsr()
    dpc = await dm.read_dpc()
    assert (
        _cause(dcsr) == DCSR_CAUSE_EBREAK and dpc == rvc
    ), f"c.ebreak: dcsr={dcsr:#x} dpc={dpc:#x}"
    await dm.write_mem(rvc, 2, original_half)
    assert (await dm.read_mem(rvc, 2)) == original_half

    # ---- Phase U: the program observes the debugger's flag write -------------
    await dm.write_mem(syms["flag"], 8, 1)
    await dm.resume()
    await _wait_text(monitor, dut, BANNER_PHASE_U)
    # A halt lands either in the U loop or in its M-mode ecall handler; retry
    # until it lands in U (the loop ecalls only every 64th iteration).
    for _attempt in range(8):
        await ClockCycles(dut.i_clk, 2000)
        await dm.halt()
        dcsr = await dm.read_dcsr()
        dpc = await dm.read_dpc()
        in_loop = syms["u_loop"] <= dpc < syms["u_loop_end"]
        # The M-mode handler is the asm trap_entry plus the C trap_dispatch it
        # calls; the two are not adjacent in the ddr arrangement, so cover both
        # symbol windows (a halt landing anywhere in that path is legitimate
        # and simply retried below).
        in_handler = (syms["trap_entry"] <= dpc < syms["trap_entry"] + 0x100) or (
            syms["trap_dispatch"] <= dpc < syms["trap_dispatch"] + 0x200
        )
        prv = dcsr & DCSR_PRV_MASK
        assert (prv == 0 and in_loop) or (
            prv == 3 and in_handler
        ), f"U-phase halt: dcsr={dcsr:#x} dpc={dpc:#x}"
        if prv == 0:
            break
        await dm.resume()
    else:
        raise AssertionError("never halted in U-mode")
    log.info(f"U-mode halt: dcsr={dcsr:#x} dpc={dpc:#x}")
    ecalls_before = await dm.read_mem(syms["ecall_count"], 8)
    # Step over an ecall from U: the hart must halt at the trap handler, in M.
    await dm.write_dpc(syms["u_ecall_site"])
    await dm.set_step(True)
    dpc = await dm.step()
    dcsr = await dm.read_dcsr()
    assert (
        dpc == syms["trap_entry"]
        and _cause(dcsr) == DCSR_CAUSE_STEP
        and dcsr & DCSR_PRV_MASK == 3
    ), f"step over ecall: dpc={dpc:#x} dcsr={dcsr:#x}"
    await dm.set_step(False)
    await dm.resume()
    await ClockCycles(dut.i_clk, 2000)
    await dm.halt()
    assert (await dm.read_mem(syms["ecall_count"], 8)) > ecalls_before
    # The privilege round-trips: resume lands back in U (the handler mrets).
    dcsr = await dm.read_dcsr()
    assert dcsr & DCSR_PRV_MASK in (0, 3), f"dcsr {dcsr:#x}"

    # ---- PASS gate: flag = 2, then a halt out of the wfi loop ----------------
    await dm.write_mem(syms["flag"], 8, 2)
    await dm.resume()
    await _wait_text(monitor, dut, BANNER_PASS)
    await ClockCycles(dut.i_clk, 500)
    await dm.halt()
    dcsr = await dm.read_dcsr()
    assert (
        _cause(dcsr) == DCSR_CAUSE_HALTREQ and dcsr & DCSR_PRV_MASK == 3
    ), f"wfi halt dcsr={dcsr:#x}"
    log.info(f"halted out of wfi at dpc={await dm.read_dpc():#x}")
    await dm.resume()

    # ---- ndmreset / havereset ------------------------------------------------
    monitor.clear()
    await dm.ndmreset(True)
    await ClockCycles(dut.i_clk, 50)
    status = await dm.dmstatus()
    assert status & DMSTATUS_ALLUNAVAIL, f"dmstatus during ndmreset {status:#x}"
    await dm.ndmreset(False)
    await _wait_text(monitor, dut, BANNER_START)
    status = await dm.dmstatus()
    assert (
        status & DMSTATUS_ALLHAVERESET and status & DMSTATUS_ALLRUNNING
    ), f"after ndmreset {status:#x}"
    await dm.ack_havereset()
    assert not (await dm.dmstatus()) & DMSTATUS_ALLHAVERESET
    await dm.halt()
    assert (await dm.read_csr(CSR_MTVEC)) == syms["trap_entry"]
    await dm.resume()
    assert (await dm.dmstatus()) & DMSTATUS_ALLRESUMEACK

    log.info(
        f"DTM sticky-busy retries exercised: {dtm.busy_retries}, final idle={dtm.idle_cycles}"
    )
    assert (
        dtm.busy_retries > 0
    ), "expected the sticky-busy protocol to be exercised at idle=0"
    assert "<<FAIL>>" not in monitor.get_output()
