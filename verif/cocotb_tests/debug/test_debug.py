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
"""Exercise the RISC-V debug module while ``debug_target`` runs.

The cocotb debugger in cocotb_tests.debug.jtag_dtm drives frost's JTAG pins.
The program's PASS banner depends on observing the debugger's memory writes.

The 32-bit ebreak and halfword c.ebreak breakpoints in BRAM require the
Debug-Mode store mirror: it sends debugger stores to the programming port,
the only write path to the instruction copy.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Any

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from cocotb_tests.debug.jtag_dtm import (
    CMDERR_EXCEPTION,
    CMDERR_NOT_SUPPORTED,
    CSR_DPC,
    CSR_DSCRATCH0,
    CSR_MEPC,
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
    store,
)
from cocotb_tests.test_real_program import (
    CLK_PERIOD_NS,
    RESET_CYCLES,
    UartMonitor,
    cpu_clock,
    generate_divided_clock,
    start_clocks,
    start_cpu_clock,
    takes_last_edge,
    wait_for_power_on_reset,
)

BANNER_START = "debug_target: start"
BANNER_PHASE_U = "debug_target: phase U"
BANNER_PASS = "debug_target: <<PASS>>"
MTIME_LO_ADDR = 0x4000_0010
# Scratch address far from the program image in both memory configurations.
# The DDR build places the whole program at 0x8000_0000 and up, so a scratch
# address near the image would corrupt it.
DDR_SCRATCH_ADDR = 0x8010_0000


def _expected_misa() -> int:
    """Return the ISA register value selected by the simulation build."""
    return 0x8000_0000_0014_112F | (
        int(os.environ.get("FROST_EXPECT_MISA_V", "0")) << 21
    )


def _read_symbols() -> dict[str, int]:
    """Return the symbol table of the running program (tests/sw.mem -> <app>/sw.mem)."""
    sw_mem = Path("sw.mem")
    elf = (
        sw_mem.resolve().with_name("sw.elf")
        if sw_mem.is_symlink()
        else Path("../sw/apps/debug_target/sw.elf")
    )
    prefix = os.environ.get("RISCV_PREFIX", "riscv64-linux-")
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
    for _ in range(RESET_CYCLES):
        await RisingEdge(dut.i_clk)
    await wait_for_power_on_reset(dut)
    dut.i_rst_n.value = 1


def _cause(dcsr: int) -> int:
    return (dcsr & DCSR_CAUSE_MASK) >> DCSR_CAUSE_SHIFT


async def _misaligned_steps(dm: DebugModule, patch_addr: int, resume_pc: int) -> None:
    """Step over a misaligned ld and sd to DDR, then try one in Debug Mode."""
    lo, mid, hi = 0x0123456789ABCDEF, 0x8877665544332211, 0xF0E0D0C0B0A09080
    for offset, value in ((0, lo), (8, mid), (16, hi)):
        await dm.write_mem(DDR_SCRATCH_ADDR + offset, 8, value)
    saved_regs = {n: await dm.read_gpr(n) for n in (5, 6, 7)}
    saved_patch = await dm.read_mem(patch_addr, 8)
    saved_dcsr = await dm.read_dcsr()
    stored = 0x1122334455667788
    # ld t1, 1(t0); sd t2, 9(t0), with t0 at the DDR scratch area.
    await dm.write_mem(
        patch_addr, 8, load(6, 5, 8, imm=1) | (store(7, 5, 8, imm=9) << 32)
    )
    await dm.write_gpr(5, DDR_SCRATCH_ADDR)
    await dm.write_gpr(6, 0)
    await dm.write_gpr(7, stored)
    await dm.write_dpc(patch_addr)
    await dm.set_step(True)
    for expected in (patch_addr + 4, patch_addr + 8):
        dpc = await dm.step()
        dcsr = await dm.read_dcsr()
        assert dpc == expected and _cause(dcsr) == DCSR_CAUSE_STEP, (
            f"misaligned step: dpc={dpc:#x} expected {expected:#x} dcsr={dcsr:#x}"
        )
    want = (lo >> 8) | ((mid & 0xFF) << 56)
    got = await dm.read_gpr(6)
    assert got == want, f"misaligned ld: {got:#x} expected {want:#x}"
    want_mid = (mid & 0xFF) | ((stored << 8) & 0xFFFF_FFFF_FFFF_FF00)
    want_hi = (hi & ~0xFF) | (stored >> 56)
    got_mid = await dm.read_mem(DDR_SCRATCH_ADDR + 8, 8)
    got_hi = await dm.read_mem(DDR_SCRATCH_ADDR + 16, 8)
    assert (got_mid, got_hi) == (want_mid, want_hi), (
        f"misaligned sd: {got_mid:#x} {got_hi:#x} expected {want_mid:#x} {want_hi:#x}"
    )
    await dm.write_dcsr(saved_dcsr)
    await dm.write_dpc(resume_pc)
    for n, value in saved_regs.items():
        await dm.write_gpr(n, value)
    await dm.write_mem(patch_addr, 8, saved_patch)
    # Debug Mode: the same misaligned load from the program buffer faults.
    await dm.read_mem(DDR_SCRATCH_ADDR + 1, 8, expect=CMDERR_EXCEPTION)
    assert (await dm.cmderr()) == 0


async def _pointer_mask_steps(dm: DebugModule, patch_addr: int, resume_pc: int) -> None:
    """DRET restores U masking; debug entry uses M, or MPRV with mprven set."""
    saved_csrs = {n: await dm.read_csr(n) for n in (0x300, 0x10A)}
    saved_regs = {n: await dm.read_gpr(n) for n in (5, 6, 7)}
    saved_patch = await dm.read_mem(patch_addr, 8)
    saved_dcsr = await dm.read_dcsr()
    await dm.write_csr(0x300, saved_csrs[0x300] & ~((1 << 17) | (1 << 19)))
    await dm.write_mem(patch_addr, 8, load(6, 5, 8) | (store(7, 5, 8, imm=8) << 32))
    for pmm, pmlen in ((2, 7), (3, 16)):
        tagged = DDR_SCRATCH_ADDR | (0x35 << (64 - pmlen))
        await dm.write_csr(0x10A, pmm << 32)
        await dm.write_mem(DDR_SCRATCH_ADDR, 8, 0x123456789ABCDEF0)
        await dm.write_gpr(5, tagged)
        await dm.write_gpr(7, 0xFEDCBA9876543210)
        await dm.write_dcsr(saved_dcsr & ~DCSR_PRV_MASK)
        await dm.set_step(True)
        await dm.write_dpc(patch_addr)
        assert (await dm.step()) == patch_addr + 4
        assert (await dm.read_gpr(6)) == 0x123456789ABCDEF0
        assert (await dm.read_dcsr()) & DCSR_PRV_MASK == 0
        # Debug entry executes at M privilege without MPRV.
        await dm.read_mem(tagged, 8, expect=CMDERR_EXCEPTION)
        assert (await dm.step()) == patch_addr + 8
        assert (await dm.read_mem(DDR_SCRATCH_ADDR + 8, 8)) == 0xFEDCBA9876543210
        # dcsr.mprven is one, so an explicit debug access can select U.
        await dm.write_csr(
            0x300, (saved_csrs[0x300] & ~((3 << 11) | (1 << 19))) | (1 << 17)
        )
        assert (await dm.read_mem(tagged, 8)) == 0x123456789ABCDEF0
        await dm.write_csr(0x300, saved_csrs[0x300])
    await dm.write_csr(0x10A, saved_csrs[0x10A])
    await dm.write_dcsr(saved_dcsr)
    await dm.write_dpc(resume_pc)
    for n, value in saved_regs.items():
        await dm.write_gpr(n, value)
    await dm.write_mem(patch_addr, 8, saved_patch)


@cocotb.test()
@takes_last_edge
async def test_debug(dut: Any) -> None:
    """Bit-bang a full debugger session against the frost toplevel."""
    start_clocks((dut.i_clk,), CLK_PERIOD_NS * 1000)
    start_cpu_clock(dut)
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
    assert hartinfo & 0xFFF == 0x7B4 and (hartinfo >> 16) & 1 == 0, (
        f"hartinfo {hartinfo:#x}"
    )
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
    assert status & DMSTATUS_ALLRUNNING and not status & DMSTATUS_ALLHALTED, (
        f"dmstatus {status:#x}"
    )

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
    assert (await dm.read_mem(syms["counter"], 8)) == counter_at_halt, (
        "counter moved while halted"
    )

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
    assert misa == _expected_misa(), f"misa {misa:#x}"
    assert (await dm.read_csr(CSR_MTVEC)) == syms["trap_entry"]
    await dm.write_csr(CSR_DSCRATCH0, 0xDEADBEEFCAFEF00D)
    assert (await dm.read_csr(CSR_DSCRATCH0)) == 0xDEADBEEFCAFEF00D
    assert (await dm.read_csr(CSR_DPC)) == dpc

    # A doubleword patch supplies two executable instruction words in BRAM.
    patch_addr = 0x1E000
    saved_patch = await dm.read_mem(patch_addr, 8)
    saved_next = await dm.read_mem(patch_addr + 8, 4)
    saved_dcsr = await dm.read_dcsr()
    await dm.write_mem(patch_addr + 8, 4, INSN_EBREAK)
    await dm.write_mem(patch_addr, 8, addi(5, 0, 17) | (addi(5, 5, 23) << 32))
    await dm.write_gpr(5, 0)
    await dm.write_dpc(patch_addr)
    await dm.set_step(True)
    assert (await dm.step()) == patch_addr + 4
    assert (await dm.read_gpr(5)) == 17, "lower instruction word was not mirrored"
    assert (await dm.step()) == patch_addr + 8
    assert (await dm.read_gpr(5)) == 40, "upper instruction word was not mirrored"
    await dm.write_dcsr(saved_dcsr)
    await dm.write_dpc(dpc)
    await dm.write_gpr(5, saved_t0)
    await dm.write_mem(patch_addr, 8, saved_patch)
    await dm.write_mem(patch_addr + 8, 4, saved_next)

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

    # ---- Misaligned accesses: single steps, and none in Debug Mode -----------
    # With the misaligned-access engine (MISALIGNED_HW, the default), a step
    # over a misaligned load or store to DDR retires it as one instruction and
    # halts at the next. In Debug Mode the access keeps its exception, so a
    # program buffer's misaligned load reports cmderr 3.
    if os.environ.get("MISALIGNED_HW", "1") != "0":
        await _misaligned_steps(dm, patch_addr, dpc)

    await _pointer_mask_steps(dm, patch_addr, dpc)

    # ---- A progbuf exception: unmapped address -> cmderr 3 -------------------
    await dm.read_mem(0xDEAD_0000_0000, 8, expect=CMDERR_EXCEPTION)
    assert (await dm.cmderr()) == 0
    assert (await dm.read_gpr(0)) == 0

    # ---- abstractauto: OpenOCD's block read loop -----------------------------
    saved_s0 = await dm.read_gpr(dm.S0)
    saved_s1 = await dm.read_gpr(dm.S1)
    await dm.write_gpr(dm.S0, table)
    # This mirrors OpenOCD's block read: a progbuf-only run primes s1 with the
    # first element, then a transfer+postexec command moves it out while the
    # program loads the next. With autoexecdata set, every data0 read re-runs
    # that command.
    await dm.exec_progbuf([load(dm.S1, dm.S0, 8), addi(dm.S0, dm.S0, 8)])
    await dm.command(
        dm.access_register(0x1000 + dm.S1, write=False, size=64, postexec=True)
    )
    await dtm.write(DM_ABSTRACTAUTO, 1)
    words = []
    for _ in range(4):
        # OpenOCD's order for 64-bit block reads: data1 first (no autoexec),
        # then data0, whose read re-runs the command for the next element.
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
    assert _cause(dcsr) == DCSR_CAUSE_EBREAK and dpc == bp, (
        f"breakpoint: dcsr={dcsr:#x} dpc={dpc:#x}"
    )
    await dm.write_mem(bp, 4, original)
    assert (await dm.read_mem(bp, 4)) == original

    # ---- Single steps: 32-bit, RVC, RVC, ret ---------------------------------
    await dm.set_step(True)
    ra = await dm.read_gpr(1)
    for expected in (bp + 4, bp + 6, bp + 8, ra):
        dpc = await dm.step()
        dcsr = await dm.read_dcsr()
        assert dpc == expected and _cause(dcsr) == DCSR_CAUSE_STEP, (
            f"step: dpc={dpc:#x} expected {expected:#x} dcsr={dcsr:#x}"
        )

    # ---- Single steps: a div into a wfi --------------------------------------
    # The wfi reaches the ROB head while the step's halt holds it there. It
    # runs as a nop while a step is armed, so the halt must save its own PC,
    # and the next step retires it.
    site = syms["step_wfi_site"]
    resume_pc = await dm.read_dpc()
    saved = {n: await dm.read_gpr(n) for n in (10, 11, 12)}
    await dm.write_gpr(11, 1000)
    await dm.write_gpr(12, 7)
    await dm.write_dpc(site)
    for expected in (site + 4, site + 8):
        dpc = await dm.step()
        dcsr = await dm.read_dcsr()
        assert dpc == expected and _cause(dcsr) == DCSR_CAUSE_STEP, (
            f"step over div/wfi: dpc={dpc:#x} expected {expected:#x} dcsr={dcsr:#x}"
        )
    assert (await dm.read_gpr(10)) == 1000 // 7
    for n, value in saved.items():
        await dm.write_gpr(n, value)
    await dm.write_dpc(resume_pc)
    await dm.set_step(False)

    # ---- Halfword c.ebreak breakpoint ----------------------------------------
    rvc = syms["bp_target_rvc"]
    original_half = await dm.read_mem(rvc, 2)
    await dm.write_mem(rvc, 2, INSN_C_EBREAK)
    await dm.resume()
    await dm.wait_status(DMSTATUS_ALLHALTED)
    dcsr = await dm.read_dcsr()
    dpc = await dm.read_dpc()
    assert _cause(dcsr) == DCSR_CAUSE_EBREAK and dpc == rvc, (
        f"c.ebreak: dcsr={dcsr:#x} dpc={dpc:#x}"
    )
    await dm.write_mem(rvc, 2, original_half)
    assert (await dm.read_mem(rvc, 2)) == original_half

    # ---- Phase U: the program observes the debugger's flag write -------------
    await dm.write_mem(syms["flag"], 8, 1)
    await dm.resume()
    await _wait_text(monitor, dut, BANNER_PHASE_U)
    # Retry halts in the M-mode handler until one lands in the U loop, which
    # ecalls every 64 iterations. Vary the wait by a prime stride to avoid
    # repeatedly sampling the same handler phase.
    for _attempt in range(8):
        await ClockCycles(dut.i_clk, 2000 + 97 * _attempt)
        await dm.halt()
        dcsr = await dm.read_dcsr()
        dpc = await dm.read_dpc()
        in_loop = syms["u_loop"] <= dpc < syms["u_loop_end"]
        # The M-mode handler is the asm trap_entry plus the C trap_dispatch it
        # calls. The two are not adjacent in the DDR build, so cover both
        # symbol windows. A halt anywhere on that path is valid and is retried
        # below.
        in_handler = (syms["trap_entry"] <= dpc < syms["trap_entry"] + 0x100) or (
            syms["trap_dispatch"] <= dpc < syms["trap_dispatch"] + 0x200
        )
        prv = dcsr & DCSR_PRV_MASK
        log.info(f"U-phase halt attempt {_attempt}: dcsr={dcsr:#x} dpc={dpc:#x}")
        assert (prv == 0 and in_loop) or (prv == 3 and in_handler), (
            f"U-phase halt: dcsr={dcsr:#x} dpc={dpc:#x}"
        )
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
    # The handler mrets back to the U loop, so this halt may land in either mode.
    dcsr = await dm.read_dcsr()
    assert dcsr & DCSR_PRV_MASK in (0, 3), f"dcsr {dcsr:#x}"

    # ---- PASS gate: flag = 2, then a halt out of the wfi loop ----------------
    await dm.write_mem(syms["flag"], 8, 2)
    await dm.resume()
    await _wait_text(monitor, dut, BANNER_PASS)
    await ClockCycles(dut.i_clk, 500)
    await dm.halt()
    dcsr = await dm.read_dcsr()
    assert _cause(dcsr) == DCSR_CAUSE_HALTREQ and dcsr & DCSR_PRV_MASK == 3, (
        f"wfi halt dcsr={dcsr:#x}"
    )
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
    assert status & DMSTATUS_ALLHAVERESET and status & DMSTATUS_ALLRUNNING, (
        f"after ndmreset {status:#x}"
    )
    await dm.ack_havereset()
    assert not (await dm.dmstatus()) & DMSTATUS_ALLHAVERESET
    await dm.halt()
    assert (await dm.read_csr(CSR_MTVEC)) == syms["trap_entry"]
    await dm.resume()
    assert (await dm.dmstatus()) & DMSTATUS_ALLRESUMEACK

    log.info(
        f"DTM sticky-busy retries exercised: {dtm.busy_retries}, final idle={dtm.idle_cycles}"
    )
    assert dtm.busy_retries > 0, (
        "expected the sticky-busy protocol to be exercised at idle=0"
    )
    assert "<<FAIL>>" not in monitor.get_output()


@cocotb.test()
@takes_last_edge
async def test_return_stack_after_older_fault(dut: Any) -> None:
    """A delayed load fault discards an indirect call that has already resolved."""
    start_clocks((dut.i_clk,), CLK_PERIOD_NS * 1000)
    start_cpu_clock(dut)
    cocotb.start_soon(generate_divided_clock(dut))
    await _reset(dut)
    jtag = JtagDriver(dut, half_period=4)
    await jtag.reset()
    dm = DebugModule(Dtm(jtag, idle_cycles=1), cocotb.log)
    await dm.activate()
    await dm.halt()

    pc = 0x1E000
    fault_address = 0x0010_0000
    handler = pc + 40
    jump_here = 0x0000_006F  # jal zero, 0

    # Two dependent divisions delay the load; the following call has a ready target.
    def divide(source: int) -> int:
        return (1 << 25) | (21 << 20) | (source << 15) | (5 << 12) | (6 << 7) | 0x33

    words = [
        0x0080_02EF,  # jal t0, +8: leaves pc + 4 at the top of the stack
        jump_here,
        divide(20),
        divide(6),
        load(11, 6, 8),
        (8 << 15) | (1 << 7) | 0x67,  # jalr ra, 0(s0)
        jump_here,
        jump_here,
        addi(7, 7, 1),  # squashed indirect target
        jump_here,
        jump_here,  # trap handler
        jump_here,
    ]
    for n in range(0, len(words), 2):
        await dm.write_mem(pc + n * 4, 8, words[n] | (words[n + 1] << 32), fence=False)
    await dm.fence_i()
    await dm.write_csr(CSR_MTVEC, handler)
    await dm.write_gpr(20, fault_address * 9)
    await dm.write_gpr(21, 3)
    await dm.write_gpr(8, pc + 32)
    await dm.write_gpr(1, 0x987)
    await dm.write_gpr(7, 40)
    await dm.write_dpc(pc)

    cpu = dut.cpu_and_memory_subsystem.cpu.hart.cpu_inst
    front = cpu.if_stage_inst
    clock = cpu_clock(dut)

    async def check_squash() -> None:
        recovery = cpu.early_misprediction_recovery_inst
        early_admitted = None
        before_call = None
        for _ in range(60000):
            await RisingEdge(clock)
            await ReadOnly()
            if (
                int(recovery.i_is_jalr_issue.value)
                and int(recovery.i_branch_target_resolved.value) == pc + 32
            ):
                early_admitted = bool(int(recovery.jalr_admitted.value))
            if (
                int(cpu.early_mispredict_active.value)
                and int(cpu.early_mispredict_pc.value) == pc + 20
            ):
                before_call = (
                    int(cpu.restored_ras_tos.value),
                    int(cpu.restored_ras_valid_count.value),
                    int(cpu.restored_ras_top.value),
                )
            if int(cpu.trap_taken.value) and int(cpu.rob_trap_pc.value) == pc + 16:
                break
        else:
            raise AssertionError("the load did not trap")
        # The trap raises the registered full flush, then the existing RAS input
        # register delivers its restore to the stack on the following edge.
        await ClockCycles(clock, 3)
        await ReadOnly()
        after = (
            int(front.ras_checkpoint_tos.value),
            int(front.ras_checkpoint_valid_count.value),
            int(front.ras_checkpoint_top.value),
        )
        assert early_admitted is not None, "the younger indirect call did not issue"
        assert (before_call is not None) == early_admitted
        assert after[1] and after[2] == pc + 4, after
        if before_call is not None:
            assert after == before_call
        cocotb.log.info(
            "Return stack before the early call %s, after the fault %s",
            before_call,
            after,
        )

    observer = cocotb.start_soon(check_squash())
    await dm.resume()
    await observer
    await dm.halt()
    assert await dm.read_dpc() == handler
    assert await dm.read_csr(CSR_MEPC) == pc + 16
    assert await dm.read_csr(0x342) == 5  # mcause, load access fault
    assert await dm.read_csr(0x343) == fault_address  # mtval
    assert await dm.read_gpr(6) == fault_address
    assert await dm.read_gpr(1) == 0x987
    assert await dm.read_gpr(7) == 40
