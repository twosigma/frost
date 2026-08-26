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
"""JTAG / DTM / Debug Module driver for the frost toplevel (Phase 3 M3).

Bit-bangs frost's ``i_jtag_*`` pins from cocotb (the generic 5-bit-IR TAP),
speaks the RISC-V Debug Spec 0.13.2 DTM protocol (dtmcs / dmi with the
sticky-busy rule and dmireset retries, the way OpenOCD does), and wraps the
debug module's register-level protocol into the operations a debugger
performs: halt / resume / step, abstract GPR access, program-buffer
execution, and the progbuf-based CSR and memory access OpenOCD falls back
to when the module advertises no abstract CSR access and no system bus.
"""

from __future__ import annotations

from typing import Any

import cocotb
from cocotb.triggers import ClockCycles

# --------------------------------------------------------------------------
# DTM / DM constants (Debug Spec 0.13.2)
# --------------------------------------------------------------------------
IR_IDCODE = 0x01
IR_DTMCS = 0x10
IR_DMI = 0x11
IR_BYPASS = 0x1F

DTMCS_DMIRESET = 1 << 16
DTMCS_DMIHARDRESET = 1 << 17

DMI_OP_NOP = 0
DMI_OP_READ = 1
DMI_OP_WRITE = 2
DMI_STATUS_OK = 0
DMI_STATUS_FAILED = 2
DMI_STATUS_BUSY = 3

DM_DATA0 = 0x04
DM_DATA1 = 0x05
DM_DMCONTROL = 0x10
DM_DMSTATUS = 0x11
DM_HARTINFO = 0x12
DM_ABSTRACTCS = 0x16
DM_COMMAND = 0x17
DM_ABSTRACTAUTO = 0x18
DM_PROGBUF0 = 0x20
DM_SBCS = 0x38
DM_HALTSUM0 = 0x40

DMCONTROL_HALTREQ = 1 << 31
DMCONTROL_RESUMEREQ = 1 << 30
DMCONTROL_ACKHAVERESET = 1 << 28
DMCONTROL_HASEL = 1 << 26
DMCONTROL_HARTSELLO_MASK = 0x3FF << 16
DMCONTROL_HARTSELHI_MASK = 0x3FF << 6
DMCONTROL_NDMRESET = 1 << 1
DMCONTROL_DMACTIVE = 1 << 0

DMSTATUS_IMPEBREAK = 1 << 22
DMSTATUS_ALLHAVERESET = 1 << 19
DMSTATUS_ALLRESUMEACK = 1 << 17
DMSTATUS_ALLNONEXISTENT = 1 << 15
DMSTATUS_ALLUNAVAIL = 1 << 13
DMSTATUS_ALLRUNNING = 1 << 11
DMSTATUS_ALLHALTED = 1 << 9
DMSTATUS_AUTHENTICATED = 1 << 7

ABSTRACTCS_BUSY = 1 << 12
ABSTRACTCS_CMDERR_SHIFT = 8
ABSTRACTCS_CMDERR_MASK = 0x7 << 8

CMDERR_NONE = 0
CMDERR_BUSY = 1
CMDERR_NOT_SUPPORTED = 2
CMDERR_EXCEPTION = 3
CMDERR_HALT_RESUME = 4
CMDERR_OTHER = 7

# dcsr
DCSR_EBREAKM = 1 << 15
DCSR_EBREAKS = 1 << 13
DCSR_EBREAKU = 1 << 12
DCSR_STEP = 1 << 2
DCSR_CAUSE_SHIFT = 6
DCSR_CAUSE_MASK = 0x7 << 6
DCSR_PRV_MASK = 0x3
DCSR_CAUSE_EBREAK = 1
DCSR_CAUSE_HALTREQ = 3
DCSR_CAUSE_STEP = 4

CSR_DCSR = 0x7B0
CSR_DPC = 0x7B1
CSR_DSCRATCH0 = 0x7B2
CSR_DSCRATCH1 = 0x7B3
CSR_DDATA = 0x7B4
CSR_MISA = 0x301
CSR_MSTATUS = 0x300
CSR_MEPC = 0x341
CSR_MTVEC = 0x305

GPR_REGNO_BASE = 0x1000

FROST_IDCODE = 0x1F057001

# --------------------------------------------------------------------------
# Instruction encoders (the handful the progbuf paths need)
# --------------------------------------------------------------------------
INSN_EBREAK = 0x00100073
INSN_NOP = 0x00000013
INSN_FENCE_I = 0x0000100F
INSN_FENCE = 0x0FF0000F
INSN_C_EBREAK = 0x9002


def csrr(rd: int, csr: int) -> int:
    """Csrrs rd, csr, x0."""
    return (csr << 20) | (0 << 15) | (2 << 12) | (rd << 7) | 0x73


def csrw(csr: int, rs1: int) -> int:
    """Csrrw x0, csr, rs1."""
    return (csr << 20) | (rs1 << 15) | (1 << 12) | (0 << 7) | 0x73


def load(rd: int, rs1: int, size: int, imm: int = 0, unsigned: bool = False) -> int:
    """lb/lh/lw/ld (or lbu/lhu/lwu) rd, imm(rs1)."""
    funct3 = {1: 0, 2: 1, 4: 2, 8: 3}[size] | (4 if unsigned and size < 8 else 0)
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x03


def store(rs2: int, rs1: int, size: int, imm: int = 0) -> int:
    """sb/sh/sw/sd rs2, imm(rs1)."""
    funct3 = {1: 0, 2: 1, 4: 2, 8: 3}[size]
    imm &= 0xFFF
    return (
        ((imm >> 5) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (funct3 << 12)
        | ((imm & 0x1F) << 7)
        | 0x23
    )


def addi(rd: int, rs1: int, imm: int) -> int:
    """Addi rd, rs1, imm."""
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x13


# --------------------------------------------------------------------------
# JTAG bit-bang
# --------------------------------------------------------------------------
class JtagDriver:
    """Drive a JTAG TAP through frost's i_jtag_* pins.

    ``half_period`` is the number of core clock cycles per TCK half period;
    the DTM's request/response handshake crosses TCK<->core through two-flop
    synchronizers, so a slow TCK keeps the busy path deterministic while a
    fast one exercises it.
    """

    def __init__(self, dut: Any, half_period: int = 4) -> None:
        """Bind the JTAG pins and drive them to their idle levels."""
        self.dut = dut
        self.clk = dut.i_clk
        self.half_period = half_period
        self.tck = dut.i_jtag_tck
        self.tms = dut.i_jtag_tms
        self.tdi = dut.i_jtag_tdi
        self.tdo = dut.o_jtag_tdo
        self.trst_n = dut.i_jtag_trst_n
        self.tck.value = 0
        self.tms.value = 0
        self.tdi.value = 0
        self.trst_n.value = 1

    async def clock(self, tms: int, tdi: int) -> int:
        """One TCK cycle; returns TDO as sampled before the rising edge."""
        self.tms.value = tms
        self.tdi.value = tdi
        await ClockCycles(self.clk, self.half_period)
        tdo = int(self.tdo.value)
        self.tck.value = 1
        await ClockCycles(self.clk, self.half_period)
        self.tck.value = 0
        return tdo

    async def idle(self, cycles: int) -> None:
        """Stay in Run-Test/Idle for ``cycles`` TCK cycles."""
        for _ in range(cycles):
            await self.clock(0, 0)

    async def reset(self) -> None:
        """Test-Logic-Reset via five TMS=1 clocks, then Run-Test/Idle."""
        for _ in range(5):
            await self.clock(1, 0)
        await self.clock(0, 0)

    async def scan_ir(self, ir: int, width: int = 5) -> int:
        """From RTI: shift ``ir`` LSB-first, return the captured IR value."""
        await self.clock(1, 0)  # Select-DR
        await self.clock(1, 0)  # Select-IR
        await self.clock(0, 0)  # Capture-IR
        await self.clock(0, 0)  # Shift-IR
        captured = 0
        for i in range(width):
            last = i == width - 1
            bit = await self.clock(1 if last else 0, (ir >> i) & 1)
            captured |= bit << i
        await self.clock(1, 0)  # Update-IR
        await self.clock(0, 0)  # RTI
        return captured

    async def scan_dr(self, value: int, width: int, idle_cycles: int = 0) -> int:
        """From RTI: shift ``value`` LSB-first through the selected DR."""
        await self.clock(1, 0)  # Select-DR
        await self.clock(0, 0)  # Capture-DR
        await self.clock(0, 0)  # Shift-DR
        captured = 0
        for i in range(width):
            last = i == width - 1
            bit = await self.clock(1 if last else 0, (value >> i) & 1)
            captured |= bit << i
        await self.clock(1, 0)  # Update-DR
        await self.clock(0, 0)  # RTI
        await self.idle(idle_cycles)
        return captured


# --------------------------------------------------------------------------
# DTM: dtmcs / dmi with OpenOCD-style busy handling
# --------------------------------------------------------------------------
class DtmError(Exception):
    """A DMI operation failed or exhausted its busy retries."""

    pass


class Dtm:
    """The DTM's dtmcs/dmi protocol over a JtagDriver (sticky-busy aware)."""

    def __init__(self, jtag: JtagDriver, abits: int = 7, idle_cycles: int = 0) -> None:
        """Wrap ``jtag``; ``abits``/``idle_cycles`` mirror dtmcs's fields."""
        self.jtag = jtag
        self.abits = abits
        self.idle_cycles = idle_cycles
        self.busy_retries = 0  # statistics: how often the sticky-busy path ran
        self.trace = False  # log every DMI scan
        self._ir: int | None = None

    async def select_ir(self, ir: int) -> None:
        """Scan the IR only when it differs from the cached selection."""
        if self._ir != ir:
            await self.jtag.scan_ir(ir)
            self._ir = ir

    async def idcode(self) -> int:
        """Read the TAP IDCODE register."""
        await self.select_ir(IR_IDCODE)
        return await self.jtag.scan_dr(0, 32)

    async def dtmcs_read(self) -> int:
        """Read dtmcs."""
        await self.select_ir(IR_DTMCS)
        return await self.jtag.scan_dr(0, 32)

    async def dtmcs_write(self, value: int) -> int:
        """Write dtmcs (dmireset / dmihardreset live here)."""
        await self.select_ir(IR_DTMCS)
        return await self.jtag.scan_dr(value, 32)

    async def dmi_scan(self, op: int, addr: int, data: int) -> tuple[int, int, int]:
        """One dmi scan; returns (status, data, addr) as captured."""
        await self.select_ir(IR_DMI)
        width = self.abits + 34
        value = (
            ((addr & ((1 << self.abits) - 1)) << 34)
            | ((data & 0xFFFFFFFF) << 2)
            | (op & 3)
        )
        captured = await self.jtag.scan_dr(value, width, self.idle_cycles)
        return captured & 3, (captured >> 2) & 0xFFFFFFFF, captured >> 34

    async def _dmi_op(self, op: int, addr: int, data: int) -> int:
        """Issue one DMI operation the way OpenOCD's dmi_op_timeout does.

        The operation scan may itself capture a busy status from the previous
        request; a follow-up nop scan reads the result. Busy is sticky: clear
        it with dmireset, add idle cycles, and retry.
        """
        for _attempt in range(64):
            status, sdata, saddr = await self.dmi_scan(op, addr, data)
            if self.trace:
                cocotb.log.info(
                    f"dmi op={op} addr={addr:#x} data={data:#x} -> status={status} cap_data={sdata:#x} cap_addr={saddr:#x}"
                )
            if status == DMI_STATUS_BUSY:
                self.busy_retries += 1
                await self.dtmcs_write(DTMCS_DMIRESET)
                self.idle_cycles += 1
                continue
            if status != DMI_STATUS_OK:
                raise DtmError(f"dmi op {op} addr {addr:#x}: status {status}")
            break
        else:
            raise DtmError("dmi: too many busy retries issuing the operation")
        for _attempt in range(64):
            status, rdata, saddr = await self.dmi_scan(DMI_OP_NOP, addr, 0)
            if self.trace:
                cocotb.log.info(
                    f"dmi nop addr={addr:#x} -> status={status} data={rdata:#x} cap_addr={saddr:#x}"
                )
            if status == DMI_STATUS_BUSY:
                self.busy_retries += 1
                await self.dtmcs_write(DTMCS_DMIRESET)
                self.idle_cycles += 1
                continue
            if status != DMI_STATUS_OK:
                raise DtmError(f"dmi result addr {addr:#x}: status {status}")
            return rdata
        raise DtmError("dmi: too many busy retries reading the result")

    async def read(self, addr: int) -> int:
        """Read one debug-module register through DMI."""
        return await self._dmi_op(DMI_OP_READ, addr, 0)

    async def write(self, addr: int, data: int) -> None:
        """Write one debug-module register through DMI."""
        await self._dmi_op(DMI_OP_WRITE, addr, data)


# --------------------------------------------------------------------------
# Debug module operations
# --------------------------------------------------------------------------
class DebugError(Exception):
    """The debug module refused or timed out on an operation."""

    pass


class DebugModule:
    """Debugger-level operations over the DTM (single hart)."""

    S0 = 8
    S1 = 9

    def __init__(self, dtm: Dtm, log: Any = None) -> None:
        """Operate the debug module reached through ``dtm``."""
        self.dtm = dtm
        self.log = log or cocotb.log

    # ---- module control ---------------------------------------------------
    async def activate(self) -> None:
        """Pulse dmactive low then high and verify it sticks."""
        await self.dtm.write(DM_DMCONTROL, 0)
        await self.dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE)
        dmcontrol = await self.dtm.read(DM_DMCONTROL)
        if not dmcontrol & DMCONTROL_DMACTIVE:
            raise DebugError(f"dmactive did not set: dmcontrol={dmcontrol:#x}")

    async def dmstatus(self) -> int:
        """Read dmstatus."""
        return await self.dtm.read(DM_DMSTATUS)

    async def is_halted(self) -> bool:
        """Return whether dmstatus reports the hart halted."""
        return bool((await self.dmstatus()) & DMSTATUS_ALLHALTED)

    async def wait_status(self, mask: int, timeout: int = 200) -> int:
        """Poll dmstatus until ``mask`` is set; return that dmstatus."""
        for _ in range(timeout):
            status = await self.dmstatus()
            if status & mask:
                return status
        raise DebugError(f"timeout waiting for dmstatus mask {mask:#x}")

    async def halt(self) -> None:
        """Haltreq until allhalted, then drop the request."""
        await self.dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE | DMCONTROL_HALTREQ)
        await self.wait_status(DMSTATUS_ALLHALTED)
        await self.dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE)

    async def resume(self, wait_halted: bool = False) -> int:
        """resumereq; returns the dmstatus once resumeack is seen.

        With ``wait_halted`` (a single step) the poll also waits for the
        hart to have halted again.
        """
        await self.dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE | DMCONTROL_RESUMEREQ)
        for _ in range(400):
            status = await self.dmstatus()
            if status & DMSTATUS_ALLRESUMEACK and (
                not wait_halted or status & DMSTATUS_ALLHALTED
            ):
                await self.dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE)
                return status
        raise DebugError("timeout waiting for resumeack")

    async def ndmreset(self, assert_reset: bool) -> None:
        """Drive dmcontrol.ndmreset to the requested level."""
        value = DMCONTROL_DMACTIVE | (DMCONTROL_NDMRESET if assert_reset else 0)
        await self.dtm.write(DM_DMCONTROL, value)

    async def ack_havereset(self) -> None:
        """Clear the havereset sticky bits."""
        await self.dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE | DMCONTROL_ACKHAVERESET)

    # ---- abstract commands -----------------------------------------------
    async def abstractcs(self) -> int:
        """Read abstractcs."""
        return await self.dtm.read(DM_ABSTRACTCS)

    async def cmderr(self) -> int:
        """Return abstractcs.cmderr."""
        return (
            (await self.abstractcs()) & ABSTRACTCS_CMDERR_MASK
        ) >> ABSTRACTCS_CMDERR_SHIFT

    async def clear_cmderr(self) -> None:
        """Clear abstractcs.cmderr (W1C)."""
        await self.dtm.write(DM_ABSTRACTCS, ABSTRACTCS_CMDERR_MASK)

    async def wait_command(self) -> int:
        """Poll abstractcs until the command completes; return cmderr."""
        for _ in range(400):
            cs = await self.abstractcs()
            if not cs & ABSTRACTCS_BUSY:
                return (cs & ABSTRACTCS_CMDERR_MASK) >> ABSTRACTCS_CMDERR_SHIFT
        raise DebugError("abstract command never completed")

    async def command(self, value: int, expect: int = CMDERR_NONE) -> int:
        """Issue an abstract command and require cmderr == ``expect``."""
        await self.dtm.write(DM_COMMAND, value)
        err = await self.wait_command()
        if err != expect:
            raise DebugError(f"command {value:#x}: cmderr {err} (expected {expect})")
        return err

    @staticmethod
    def access_register(
        regno: int,
        write: bool,
        size: int = 64,
        postexec: bool = False,
        transfer: bool = True,
    ) -> int:
        """Encode an Access Register abstract-command word."""
        aarsize = {32: 2, 64: 3, 128: 4}[size]
        return (
            (0 << 24)
            | (aarsize << 20)
            | ((1 if postexec else 0) << 18)
            | ((1 if transfer else 0) << 17)
            | ((1 if write else 0) << 16)
            | (regno & 0xFFFF)
        )

    async def read_gpr(self, n: int, size: int = 64) -> int:
        """Read GPR ``n`` through an abstract register command."""
        await self.command(
            self.access_register(GPR_REGNO_BASE + n, write=False, size=size)
        )
        value = await self.dtm.read(DM_DATA0)
        if size == 64:
            value |= (await self.dtm.read(DM_DATA1)) << 32
        return value

    async def write_gpr(self, n: int, value: int) -> None:
        """Write GPR ``n`` through an abstract register command."""
        await self.dtm.write(DM_DATA0, value & 0xFFFFFFFF)
        await self.dtm.write(DM_DATA1, (value >> 32) & 0xFFFFFFFF)
        await self.command(
            self.access_register(GPR_REGNO_BASE + n, write=True, size=64)
        )

    async def write_progbuf(self, insns: list[int]) -> None:
        """Load ``insns`` into progbuf0..7."""
        if len(insns) > 8:
            raise DebugError("program buffer holds 8 words")
        for i, insn in enumerate(insns):
            await self.dtm.write(DM_PROGBUF0 + i, insn)

    async def exec_progbuf(self, insns: list[int], expect: int = CMDERR_NONE) -> int:
        """Run ``insns`` from the program buffer.

        Like OpenOCD's riscv_program_exec: an ``ebreak`` is appended after
        the program unless the buffer is completely full (then the module's
        implicit ebreak terminates it).
        """
        if len(insns) < 8:
            insns = list(insns) + [INSN_EBREAK]
        await self.write_progbuf(insns)
        return await self.command(
            self.access_register(0, write=False, transfer=False, postexec=True),
            expect=expect,
        )

    # ---- progbuf-based CSR and memory access (OpenOCD's fallback paths) ---
    async def read_csr(self, csr: int) -> int:
        """Read a CSR via the progbuf, preserving s0."""
        saved = await self.read_gpr(self.S0)
        await self.exec_progbuf([csrr(self.S0, csr)])
        value = await self.read_gpr(self.S0)
        await self.write_gpr(self.S0, saved)
        return value

    async def write_csr(self, csr: int, value: int) -> None:
        """Write a CSR via the progbuf, preserving s0."""
        saved = await self.read_gpr(self.S0)
        await self.write_gpr(self.S0, value)
        await self.exec_progbuf([csrw(csr, self.S0)])
        await self.write_gpr(self.S0, saved)

    async def read_mem(self, addr: int, size: int, expect: int = CMDERR_NONE) -> int:
        """Read memory via a progbuf load; ``expect`` admits a cmderr."""
        saved = await self.read_gpr(self.S0)
        await self.write_gpr(self.S0, addr)
        err = await self.exec_progbuf(
            [load(self.S0, self.S0, size, unsigned=True)], expect=expect
        )
        value = await self.read_gpr(self.S0) if err == CMDERR_NONE else 0
        if err != CMDERR_NONE:
            await self.clear_cmderr()
        await self.write_gpr(self.S0, saved)
        return value

    async def write_mem(
        self, addr: int, size: int, value: int, fence: bool = True
    ) -> None:
        """Write memory via a progbuf store, preserving s0/s1."""
        saved0 = await self.read_gpr(self.S0)
        saved1 = await self.read_gpr(self.S1)
        await self.write_gpr(self.S0, addr)
        await self.write_gpr(self.S1, value)
        insns = [store(self.S1, self.S0, size)]
        if fence:
            insns += [INSN_FENCE_I, INSN_FENCE]
        await self.exec_progbuf(insns)
        await self.write_gpr(self.S1, saved1)
        await self.write_gpr(self.S0, saved0)

    async def fence_i(self) -> None:
        """Run fence.i; fence from the progbuf (post-store visibility)."""
        await self.exec_progbuf([INSN_FENCE_I, INSN_FENCE])

    # ---- debug CSR conveniences ------------------------------------------
    async def read_dcsr(self) -> int:
        """Read dcsr."""
        return await self.read_csr(CSR_DCSR)

    async def write_dcsr(self, value: int) -> None:
        """Write dcsr."""
        await self.write_csr(CSR_DCSR, value)

    async def read_dpc(self) -> int:
        """Read dpc."""
        return await self.read_csr(CSR_DPC)

    async def write_dpc(self, value: int) -> None:
        """Write dpc."""
        await self.write_csr(CSR_DPC, value)

    async def set_step(
        self, step: bool, ebreak_bits: int = DCSR_EBREAKM | DCSR_EBREAKS | DCSR_EBREAKU
    ) -> None:
        """Set dcsr.step and the ebreak-to-debug bits."""
        dcsr = await self.read_dcsr()
        dcsr = (
            dcsr & ~(DCSR_STEP | DCSR_EBREAKM | DCSR_EBREAKS | DCSR_EBREAKU)
        ) | ebreak_bits
        if step:
            dcsr |= DCSR_STEP
        await self.write_dcsr(dcsr)

    async def step(self) -> int:
        """Single-step once (dcsr.step assumed set); returns the new dpc."""
        await self.resume(wait_halted=True)
        return await self.read_dpc()
