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

"""APLIC MSI forwarding into the IMSIC, programmed as the drivers do.

The register sequences follow OpenSBI's lib/utils/irqchip/aplic.c and
imsic.c and Linux's irq-riscv-aplic-{main,msi}.c and irq-riscv-imsic-*.c,
with the IMSIC device-tree layout of hw/rtl/peripherals/imsic/README.md
(machine files at 0x4800_0000, supervisor files at 0x4810_0000, one 4 KiB
page per hart, hart-index bits from the interrupts-extended count).
"""

import os
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

NUM_SOURCES = int(os.environ.get("JOINT_NUM_SOURCES", "8"))
NUM_HARTS = int(os.environ.get("JOINT_NUM_HARTS", "2"))
NUM_IDS = int(os.environ.get("JOINT_NUM_IDS", "63"))
M_BASE = int(os.environ.get("JOINT_M_BASE_ADDR", "1207959552"))
S_BASE = int(os.environ.get("JOINT_S_BASE_ADDR", "1209008128"))
S_REGION = 0x8000  # supervisor domain control region offset in the APLIC window

DOMAINCFG = 0x0000
MMSIADDRCFG, MMSIADDRCFGH, SMSIADDRCFG, SMSIADDRCFGH = 0x1BC0, 0x1BC4, 0x1BC8, 0x1BCC
SETIP, CLRIPNUM, SETIENUM, CLRIE = 0x1C00, 0x1DDC, 0x1EDC, 0x1F00
SETIPNUM_LE, GENMSI, TARGET, IDC = 0x2000, 0x3000, 0x3000, 0x4000
IE, DM, D = 1 << 8, 1 << 2, 1 << 10
SM_EDGE1, SM_LEVEL1 = 4, 6
EIDELIVERY, EITHRESHOLD, EIP0, EIE0 = 0x70, 0x72, 0x80, 0xC0
LEVELS = ("m", "s")


def hart_index_bits(count: int) -> int:
    """OpenSBI fdt_parse_imsic_node and Linux imsic_populate_global_dt."""
    bits = count.bit_length() - 1  # sbi_fls / __fls
    if (1 << bits) < count:
        bits += 1
    return bits


def opensbi_msicfg(base: int, count: int) -> tuple[int, int]:
    """aplic_writel_msicfg for an IMSIC node with default guest/group fields."""
    lhxs, lhxw, hhxw, hhxs = 0, hart_index_bits(count), 0, 24 - 24
    ppn = base >> 12
    ppn &= ~((1 << lhxs) - 1)
    ppn &= ~(((1 << lhxw) - 1) << lhxs)
    ppn &= ~(((1 << hhxw) - 1) << (hhxs + 12))
    high = (
        ((ppn >> 32) & 0xFFF)
        | (lhxw << 12)
        | (hhxw << 16)
        | (lhxs << 20)
        | (hhxs << 24)
    )
    return ppn & 0xFFFF_FFFF, high


def linux_target(region_base: int, cpu: int, eiid: int) -> int:
    """aplic_msi_write_msg: hart index recovered from the per-CPU MSI page."""
    lhxw = hart_index_bits(NUM_HARTS)
    tppn = (region_base + cpu * 0x1000) >> 12
    hart = tppn & ((1 << lhxw) - 1)
    return (hart << 18) | eiid


class Joint:
    """Drives the APLIC window, wires and both IMSIC levels' CSR ports."""

    def __init__(self, dut: Any) -> None:
        """Keep the DUT and initial wire and receiver state."""
        self.dut = dut
        self.wires = 0
        self.ready = 1

    async def start(self) -> None:
        """Reset both blocks and check their shared address configuration."""
        Clock(self.dut.i_clk, 10, unit="ns").start()
        self._idle()
        self.dut.i_rst.value = 1
        for _ in range(3):
            await RisingEdge(self.dut.i_clk)
        await FallingEdge(self.dut.i_clk)
        self.dut.i_rst.value = 0
        expected = (
            M_BASE >> 12,
            (1 << 31) | (hart_index_bits(NUM_HARTS) << 12),
            S_BASE >> 12,
            0,
        )
        for reg, value in zip(
            (MMSIADDRCFG, MMSIADDRCFGH, SMSIADDRCFG, SMSIADDRCFGH), expected
        ):
            assert await self.read(reg) == value
            await self.write(reg, 0xFFFF_FFFF)
            assert await self.read(reg) == value

    def _idle(self) -> None:
        d = self.dut
        d.i_src.value = self.wires
        d.i_wr_en.value = 0
        d.i_wr_offset.value = 0
        d.i_wr_data.value = 0
        d.i_rd_offset.value = 0
        d.i_rd_capture.value = 0
        d.i_msi_ready.value = self.ready
        d.i_msi_addr_high.value = 0
        d.i_cpu_wr_en.value = 0
        d.i_cpu_wr_addr.value = 0
        d.i_cpu_wr_data.value = 0
        for level in LEVELS:
            getattr(d, f"i_{level}_iselect").value = 0
            getattr(d, f"i_{level}_ireg_we").value = 0
            getattr(d, f"i_{level}_ireg_keep").value = 0
            getattr(d, f"i_{level}_ireg_set").value = 0
            getattr(d, f"i_{level}_topei_claim").value = 0

    async def cycle(self) -> None:
        """Clock the driven inputs and return to idle at the next falling edge."""
        await RisingEdge(self.dut.i_clk)
        await FallingEdge(self.dut.i_clk)
        self._idle()

    async def idle(self, count: int = 1) -> None:
        """Advance without register accesses."""
        for _ in range(count):
            await self.cycle()

    async def write(self, offset: int, data: int) -> None:
        """Write one APLIC register."""
        self.dut.i_wr_en.value = 1
        self.dut.i_wr_offset.value = offset
        self.dut.i_wr_data.value = data & 0xFFFF_FFFF
        await self.cycle()

    async def read(self, offset: int) -> int:
        """Read one APLIC register from its aligned pair."""
        self.dut.i_rd_offset.value = offset & ~7
        await Timer(1, unit="ns")
        pair = int(self.dut.o_rd_pair.value)
        await self.cycle()
        return (pair >> 32) if offset & 4 else pair & 0xFFFF_FFFF

    async def wire(self, number: int, value: int) -> None:
        """Drive one source wire for a cycle."""
        self.wires = (self.wires & ~(1 << (number - 1))) | (value << (number - 1))
        self.dut.i_src.value = self.wires
        await self.cycle()

    def _vec(self, level: int, name: str, hart: int, width: int, value: int) -> None:
        signal = getattr(self.dut, f"i_{LEVELS[level]}_{name}")
        current = int(signal.value)
        mask = ((1 << width) - 1) << (width * hart)
        signal.value = (current & ~mask) | (
            (value & ((1 << width) - 1)) << (width * hart)
        )

    async def csr(
        self, level: int, hart: int, select: int, keep: int, setv: int
    ) -> int:
        """One *ireg access in the Zicsr keep/set form; returns the old value."""
        self._vec(level, "iselect", hart, 8, select)
        self._vec(level, "ireg_we", hart, 1, 1)
        self._vec(level, "ireg_keep", hart, 64, keep)
        self._vec(level, "ireg_set", hart, 64, setv)
        await Timer(1, unit="ns")
        old = (
            int(getattr(self.dut, f"o_{LEVELS[level]}_ireg").value) >> (64 * hart)
        ) & ((1 << 64) - 1)
        await self.cycle()
        return old

    async def csr_read(self, level: int, hart: int, select: int) -> int:
        """Read an IMSIC register without write intent."""
        self._vec(level, "iselect", hart, 8, select)
        await Timer(1, unit="ns")
        value = (
            int(getattr(self.dut, f"o_{LEVELS[level]}_ireg").value) >> (64 * hart)
        ) & ((1 << 64) - 1)
        await self.cycle()
        return value

    def topei(self, level: int, hart: int) -> int:
        """Return the selected file's top external interrupt."""
        return (
            int(getattr(self.dut, f"o_{LEVELS[level]}_topei").value) >> (32 * hart)
        ) & 0xFFFF_FFFF

    def line(self, level: int, hart: int) -> int:
        """Return the external interrupt line at one level and hart."""
        return (
            int(getattr(self.dut, f"o_{'meip' if level == 0 else 'seip'}").value)
            >> hart
        ) & 1

    async def eip_bit(self, level: int, hart: int, ident: int) -> int:
        """Read an identity's pending bit."""
        word = await self.csr_read(level, hart, EIP0 + 2 * (ident // 64))
        return (word >> (ident % 64)) & 1

    async def enable_id(self, level: int, hart: int, ident: int) -> None:
        """Set an identity's enable bit without changing other identities."""
        await self.csr(
            level, hart, EIE0 + 2 * (ident // 64), (1 << 64) - 1, 1 << (ident % 64)
        )

    async def imsic_file_init(self, level: int, hart: int) -> None:
        """OpenSBI imsic_local_irqchip_init / Linux imsic_local_delivery(true)."""
        await self.csr(level, hart, EITHRESHOLD, 0, 0)
        await self.csr(level, hart, EIDELIVERY, 0, 1)

    async def opensbi_root_init(self, *, msi: bool, delegate: range) -> None:
        """aplic_init for the root node; msi=True when it has msi-parent."""
        await self.write(DOMAINCFG, 0)
        for i in range(0, NUM_SOURCES + 1, 32):
            await self.write(CLRIE + (i // 32) * 4, 0xFFFF_FFFF)
        for n in range(1, NUM_SOURCES + 1):
            await self.write(4 * n, 0)
            await self.write(TARGET + 4 * n, 1)
        for n in delegate:
            await self.write(4 * n, D)
        if msi:
            # locked? (reads L first), then M config, then S config with the
            # S node's IMSIC (found through riscv,children's msi-parent).
            if not (await self.read(MMSIADDRCFGH)) >> 31:
                lo, hi = opensbi_msicfg(M_BASE, NUM_HARTS)
                await self.write(MMSIADDRCFG, lo)
                await self.write(MMSIADDRCFGH, hi)
                lo, hi = opensbi_msicfg(S_BASE, NUM_HARTS)
                await self.write(SMSIADDRCFG, lo)
                await self.write(SMSIADDRCFGH, hi)
        else:
            for h in range(NUM_HARTS):
                base = IDC + 32 * h
                await self.write(base + 0x00, 0)
                await self.write(base + 0x04, 0)
                await self.write(base + 0x08, 1)
        await self.write(DOMAINCFG, IE | (DM if msi else 0))

    async def linux_s_init(self, *, msi: bool) -> None:
        """aplic_init_hw_irqs, then aplic_init_hw_global (read-modify-write)."""
        for i in range(0, NUM_SOURCES + 1, 32):
            await self.write(S_REGION + CLRIE + (i // 32) * 4, 0xFFFF_FFFF)
        for n in range(1, NUM_SOURCES + 1):
            await self.write(S_REGION + 4 * n, 0)
            await self.write(S_REGION + TARGET + 4 * n, 1)
        await self.write(S_REGION + DOMAINCFG, 0)
        value = await self.read(S_REGION + DOMAINCFG)
        value |= IE | (DM if msi else 0)
        await self.write(S_REGION + DOMAINCFG, value)
        assert await self.read(S_REGION + DOMAINCFG) == value

    async def linux_s_request_level(self, n: int, cpu: int, eiid: int) -> None:
        """Wired-to-MSI request: write_msg (target), set_type + retrigger, unmask."""
        await self.write(S_REGION + TARGET + 4 * n, linux_target(S_BASE, cpu, eiid))
        await self.write(S_REGION + 4 * n, SM_LEVEL1)
        await self.write(S_REGION + SETIPNUM_LE, n)
        await self.enable_id(1, cpu, eiid)
        await self.write(S_REGION + SETIENUM, n)


@cocotb.test()
async def joint_drivers_end_to_end(dut: Any) -> None:
    """OpenSBI root+S in MSI mode, Linux S sources, M source and both genmsi."""
    j = Joint(dut)
    await j.start()
    for hart in range(NUM_HARTS):
        await j.imsic_file_init(0, hart)
        await j.enable_id(0, hart, 1)  # OpenSBI's IPI identity
    await j.opensbi_root_init(msi=True, delegate=range(2, NUM_SOURCES + 1))
    lo, hi = opensbi_msicfg(M_BASE, NUM_HARTS)
    dut._log.info("OpenSBI msicfg for %d harts: M %#x/%#x", NUM_HARTS, lo, hi)
    # OpenSBI's S node init (aplic_init for the child): MSI mode via msi-parent.
    await j.write(S_REGION + DOMAINCFG, 0)
    await j.write(S_REGION + DOMAINCFG, IE | DM)
    for hart in range(NUM_HARTS):
        await j.imsic_file_init(1, hart)
    await j.linux_s_init(msi=True)
    # One level source per hart at S level, EIIDs 10 + n.
    for n in range(2, NUM_SOURCES + 1):
        cpu = n % NUM_HARTS
        await j.linux_s_request_level(n, cpu, 10 + n)
    await j.idle(4)
    for n in range(2, NUM_SOURCES + 1):
        await j.wire(n, 1)
    await j.idle(4 * NUM_SOURCES)
    for n in range(2, NUM_SOURCES + 1):
        cpu = n % NUM_HARTS
        assert await j.eip_bit(1, cpu, 10 + n), (
            f"S source {n} not at hart {cpu} EIID {10 + n}"
        )
    for hart in range(NUM_HARTS):
        assert j.line(1, hart) == 1
    # A machine source and both generators reach every hart's interrupt files.
    await j.write(4, SM_EDGE1)
    await j.write(SETIENUM, 1)
    for hart in range(NUM_HARTS):
        await j.write(TARGET + 4, (hart << 18) | 9)
        await j.enable_id(0, hart, 9)
        await j.wire(1, 0)
        await j.wire(1, 1)
        await j.idle(6)
        assert await j.eip_bit(0, hart, 9)
        assert j.line(0, hart) == 1
        await j.write(GENMSI, (hart << 18) | 40)
        await j.write(S_REGION + GENMSI, (hart << 18) | 41)
        await j.idle(8)
        assert await j.eip_bit(0, hart, 40)
        assert await j.eip_bit(1, hart, 41)
        assert not (await j.read(GENMSI)) & (1 << 12)
        assert not (await j.read(S_REGION + GENMSI)) & (1 << 12)


@cocotb.test()
async def joint_eidelivery_passthrough_and_switch(dut: Any) -> None:
    """Eidelivery 0x40000000 passes direct lines; switching the S domain to MSI."""
    j = Joint(dut)
    await j.start()
    last = NUM_HARTS - 1
    for level in (0, 1):
        assert await j.csr_read(level, last, EIDELIVERY) == 0x4000_0000
    # Direct mode in both domains (Linux and OpenSBI without IMSIC nodes).
    await j.opensbi_root_init(msi=False, delegate=range(2, NUM_SOURCES + 1))
    await j.write(IDC + 32 * last + 0x08, 0)
    await j.write(IDC + 32 * last + 0x00, 1)
    await j.linux_s_init(msi=False)
    await j.write(S_REGION + IDC + 32 * last + 0x08, 0)
    await j.write(S_REGION + IDC + 32 * last + 0x00, 1)
    await j.write(4 * 1, SM_LEVEL1)
    await j.write(TARGET + 4, (last << 18) | 1)
    await j.write(SETIENUM, 1)
    await j.write(S_REGION + 4 * 2, SM_LEVEL1)
    await j.write(S_REGION + TARGET + 8, (last << 18) | 1)
    await j.write(S_REGION + SETIENUM, 2)
    await j.wire(1, 1)
    await j.wire(2, 1)
    await j.idle(2)
    assert j.line(0, last) == 1 and j.line(1, last) == 1
    # Switch the S domain to MSI mode before its IMSIC file delivers.
    await j.write(S_REGION + TARGET + 8, (last << 18) | 5)
    await j.write(S_REGION + DOMAINCFG, IE | DM)
    await j.write(S_REGION + TARGET + 8, (last << 18) | 5)
    await j.write(S_REGION + SETIPNUM_LE, 2)
    await j.idle(4)
    assert await j.eip_bit(1, last, 5), "MSI recorded while eidelivery=0x40000000"
    assert j.line(1, last) == 0, "file must not deliver under 0x40000000"
    assert j.line(0, last) == 1, "root direct line still passes through"
    await j.enable_id(1, last, 5)
    await j.csr(1, last, EIDELIVERY, 0, 1)
    await j.idle(2)
    assert j.line(1, last) == 1


@cocotb.test()
async def joint_root_direct_s_msi(dut: Any) -> None:
    """Root node in direct mode, S node with msi-parent, as OpenSBI programs it.

    OpenSBI writes mmsiaddrcfg*/smsiaddrcfg* only from aplic_init's MSI branch
    of the root node, so here they keep their reset values. Linux then puts
    the S domain in MSI mode. A wired S interrupt must still reach the
    S-level file of its hart.
    """
    j = Joint(dut)
    await j.start()
    cpu = NUM_HARTS - 1
    await j.opensbi_root_init(msi=False, delegate=range(2, NUM_SOURCES + 1))
    await j.write(S_REGION + DOMAINCFG, 0)
    await j.write(S_REGION + DOMAINCFG, IE | DM)
    for hart in range(NUM_HARTS):
        await j.imsic_file_init(1, hart)
    await j.linux_s_init(msi=True)
    await j.linux_s_request_level(3, cpu, 20)
    await j.wire(3, 1)
    await j.idle(6)
    cfg = [
        await j.read(r) for r in (MMSIADDRCFG, MMSIADDRCFGH, SMSIADDRCFG, SMSIADDRCFGH)
    ]
    dut._log.info("msicfg left at %s", [hex(v) for v in cfg])
    got = await j.eip_bit(1, cpu, 20)
    assert got, f"S-level MSI for hart {cpu} never reached its file (cfg {cfg})"


@cocotb.test()
async def joint_level_claim_eoi_flow(dut: Any) -> None:
    """Rearm a level source at EOI, including an MSI arriving with a claim."""
    j = Joint(dut)
    await j.start()
    cpu, eiid = NUM_HARTS - 1, 7
    await j.opensbi_root_init(msi=True, delegate=range(2, NUM_SOURCES + 1))
    await j.linux_s_init(msi=True)
    await j.imsic_file_init(1, cpu)
    await j.linux_s_request_level(2, cpu, eiid)
    await j.wire(2, 1)
    await j.idle(4)
    for _ in range(3):
        assert j.topei(1, cpu) >> 16 == eiid
        j._vec(1, "topei_claim", cpu, 1, 1)
        await j.cycle()
        assert not await j.eip_bit(1, cpu, eiid)
        await j.write(S_REGION + SETIPNUM_LE, 2)
        await j.idle(4)
        assert await j.eip_bit(1, cpu, eiid)
    # Keep the old identity pending until the rearmed MSI reaches the file.
    await j.write(S_REGION + SETIPNUM_LE, 2)
    await j.cycle()  # selection
    assert int(dut.o_msi_valid.value)
    await j.cycle()  # acceptance by the IMSIC store port
    assert j.topei(1, cpu) >> 16 == eiid
    j._vec(1, "topei_claim", cpu, 1, 1)
    await j.cycle()  # claim and delayed MSI both update the interrupt file
    assert await j.eip_bit(1, cpu, eiid)
    await j.wire(2, 0)
    j._vec(1, "topei_claim", cpu, 1, 1)
    await j.cycle()
    await j.write(S_REGION + SETIPNUM_LE, 2)
    await j.idle(4)
    assert not await j.eip_bit(1, cpu, eiid)
    assert j.line(1, cpu) == 0


@cocotb.test()
async def joint_cpu_arbitration_and_genmsi_order(dut: Any) -> None:
    """CPU IPIs stall a stable APLIC store; its marker reaches the file later."""
    j = Joint(dut)
    await j.start()
    hart = NUM_HARTS - 1
    for level, base in enumerate((M_BASE, S_BASE)):
        region = level * S_REGION
        if level:
            await j.write(4, D)
        await j.write(region + DOMAINCFG, IE | DM)
        await j.write(region + 4, 1)
        await j.write(region + TARGET + 4, (hart << 18) | 11)
        await j.write(region + SETIENUM, 1)
        j.ready = 0
        j._idle()
        await j.write(region + SETIPNUM_LE, 1)
        await j.cycle()
        await j.write(region + GENMSI, (hart << 18) | 12)
        assert int(dut.o_msi_valid.value)
        offered = (int(dut.o_msi_addr.value), int(dut.o_msi_data.value))
        j.ready = 1
        for _ in range(4):
            j._idle()
            dut.i_cpu_wr_en.value = 1
            dut.i_cpu_wr_addr.value = base + 0x1000 * hart
            dut.i_cpu_wr_data.value = 1
            await j.cycle()
            assert int(dut.o_msi_valid.value)
            assert (int(dut.o_msi_addr.value), int(dut.o_msi_data.value)) == offered
        # CSR reads leave the port free: source acceptance, then file update.
        assert await j.eip_bit(level, hart, 1)
        assert not await j.eip_bit(level, hart, 11)
        assert await j.eip_bit(level, hart, 11)
        assert not await j.eip_bit(level, hart, 12)
        assert await j.eip_bit(level, hart, 12)
        assert await j.read(region + GENMSI) == (hart << 18) | 12


@cocotb.test()
async def joint_reject_high_addresses(dut: Any) -> None:
    """Reject high addresses whose low bits name a valid IMSIC page."""
    j = Joint(dut)
    await j.start()
    for level, base in enumerate((M_BASE, S_BASE)):
        region = level * S_REGION
        await j.write(region + DOMAINCFG, DM)
        for hart in range(NUM_HARTS):
            for bit in range(24):
                j.ready = 0
                j._idle()
                await j.write(region + GENMSI, (hart << 18) | 19)
                await j.cycle()
                assert int(dut.o_msi_valid.value)
                assert int(dut.o_msi_addr.value) == base + 0x1000 * hart
                j.ready = 1
                j._idle()
                dut.i_msi_addr_high.value = 1 << bit
                await j.cycle()
                await j.idle(2)
                for file_level in range(2):
                    for file_hart in range(NUM_HARTS):
                        assert not await j.eip_bit(file_level, file_hart, 19)
                assert not (await j.read(region + GENMSI)) & (1 << 12)
            await j.write(region + GENMSI, (hart << 18) | 19)
            await j.idle(4)
            assert await j.eip_bit(level, hart, 19)
            await j.csr(level, hart, EIP0, 0, 0)
