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

"""Unit tests for the APLIC (hw/rtl/peripherals/aplic/aplic.sv).

The bench drives the register bus as the SoC will: 32-bit writes at window
offsets, 64-bit read pairs, and a capture pulse for each performed read,
which carries a claim's side effect. Every read and both interrupt lines are
compared with the register-level model in aplic_model.py after each
operation has settled, and the directed tests also check the values the AIA
specification gives. APLIC_NUM_SOURCES, APLIC_NUM_HARTS and APLIC_IPRIOLEN
must match the -G parameters of the build (test_run_cocotb.py sets both).
"""

import os
import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from cocotb_tests.aplic.aplic_model import (
    CLAIMI,
    CLRIE,
    CLRIENUM,
    CLRIPNUM,
    DOMAIN_BASE,
    DOMAINCFG,
    GENMSI,
    IDC,
    IDELIVERY,
    IFORCE,
    IN_CLRIP,
    ITHRESHOLD,
    MMSIADDRCFG,
    ROOT,
    SETIE,
    SETIENUM,
    SETIP,
    SETIPNUM,
    SETIPNUM_BE,
    SETIPNUM_LE,
    SM_DETACHED,
    SM_EDGE0,
    SM_EDGE1,
    SM_INACTIVE,
    SM_LEVEL0,
    SM_LEVEL1,
    SOURCE_MODES,
    SOURCECFG,
    SOURCECFG_D,
    SUPERVISOR,
    TARGET,
    TOPI,
    AplicModel,
    byteswap32,
    idc_offset,
    reg_offset,
)

NUM_SOURCES = int(os.environ.get("APLIC_NUM_SOURCES", "5"))
NUM_HARTS = int(os.environ.get("APLIC_NUM_HARTS", "1"))
IPRIOLEN = int(os.environ.get("APLIC_IPRIOLEN", "3"))
MSI_ENABLE = bool(int(os.environ.get("APLIC_MSI_ENABLE", "0")))
MAX_PRIORITY = (1 << IPRIOLEN) - 1
DOMAINS = (ROOT, SUPERVISOR)
SETTLE_CYCLES = 3  # a write's effects reach the registered interrupt lines


def sourcecfg(domain: int, number: int) -> int:
    """Return the window offset of a domain's sourcecfg[number]."""
    return reg_offset(domain, SOURCECFG + 4 * number)


def target(domain: int, number: int) -> int:
    """Return the window offset of a domain's target[number]."""
    return reg_offset(domain, TARGET + 4 * number)


def bitmap(domain: int, base: int, number: int) -> tuple[int, int]:
    """Window offset of the bitmap word holding a source, and its bit."""
    return reg_offset(domain, base + 4 * (number // 32)), 1 << (number % 32)


class Bench:
    """Drives the APLIC and checks every observation against the model."""

    def __init__(self, dut: Any) -> None:
        """Keep the DUT and a model in its reset state."""
        self.dut = dut
        self.model = AplicModel(NUM_SOURCES, NUM_HARTS, IPRIOLEN, MSI_ENABLE)
        self.wires = 0

    async def start(self) -> None:
        """Start the clock and reset the DUT."""
        assert len(self.dut.i_src) == NUM_SOURCES, (
            "APLIC_NUM_SOURCES differs from the build"
        )
        assert len(self.dut.o_meip) == NUM_HARTS, (
            "APLIC_NUM_HARTS differs from the build"
        )
        Clock(self.dut.i_clk, 10, unit="ns").start()
        self.dut.i_rst.value = 1
        self.dut.i_src.value = 0
        self.dut.i_wr_en.value = 0
        self.dut.i_wr_offset.value = 0
        self.dut.i_wr_data.value = 0
        self.dut.i_rd_offset.value = 0
        self.dut.i_rd_capture.value = 0
        self.dut.i_msi_ready.value = 0
        for _ in range(3):
            await RisingEdge(self.dut.i_clk)
        await FallingEdge(self.dut.i_clk)
        self.dut.i_rst.value = 0
        await self.settle()

    async def settle(self, cycles: int = SETTLE_CYCLES) -> None:
        """Let registered effects land, then check the interrupt lines."""
        for _ in range(cycles):
            await RisingEdge(self.dut.i_clk)
        await FallingEdge(self.dut.i_clk)
        await self.check_lines()

    async def check_lines(self) -> None:
        """Compare MEIP and SEIP of every hart with the model."""
        await ReadOnly()
        meip = int(self.dut.o_meip.value)
        seip = int(self.dut.o_seip.value)
        for hart in range(NUM_HARTS):
            assert (meip >> hart) & 1 == self.model.eip(ROOT, hart), (
                f"MEIP of hart {hart} is {(meip >> hart) & 1}"
            )
            assert (seip >> hart) & 1 == self.model.eip(SUPERVISOR, hart), (
                f"SEIP of hart {hart} is {(seip >> hart) & 1}"
            )
        await FallingEdge(self.dut.i_clk)

    async def write(self, offset: int, data: int, settle: bool = True) -> None:
        """One 32-bit store, then the settling cycles unless settle is False.

        Without settling, the next operation starts in the cycle right after
        the one that took the write.
        """
        await FallingEdge(self.dut.i_clk)
        self.dut.i_wr_en.value = 1
        self.dut.i_wr_offset.value = offset
        self.dut.i_wr_data.value = data & 0xFFFF_FFFF
        await FallingEdge(self.dut.i_clk)
        self.dut.i_wr_en.value = 0
        self.model.write(offset, data)
        if settle:
            await self.settle()

    async def read_pair(self, offset: int) -> tuple[int, int]:
        """Read a dword's two registers, each checked against the model."""
        await FallingEdge(self.dut.i_clk)
        self.dut.i_rd_offset.value = offset & ~0x7
        await ReadOnly()
        pair = int(self.dut.o_rd_pair.value)
        low, high = pair & 0xFFFF_FFFF, pair >> 32
        base = offset & ~0x7
        expected = (self.model.read(base), self.model.read(base + 4))
        assert (low, high) == expected, (
            f"read 0x{base:06x}: 0x{low:08x} 0x{high:08x}, model "
            f"0x{expected[0]:08x} 0x{expected[1]:08x}"
        )
        return low, high

    async def read(self, offset: int) -> int:
        """Read one register, checked against the model."""
        low, high = await self.read_pair(offset)
        return high if offset & 4 else low

    async def claim(self, domain: int, hart: int) -> int:
        """Perform a claimi read and return its value, after the settling cycles."""
        offset = idc_offset(domain, hart, CLAIMI)
        await FallingEdge(self.dut.i_clk)
        self.dut.i_rd_offset.value = offset
        self.dut.i_rd_capture.value = 1
        await ReadOnly()
        value = int(self.dut.o_rd_pair.value) >> 32
        await FallingEdge(self.dut.i_clk)
        self.dut.i_rd_capture.value = 0
        expected = self.model.claim(domain, hart) if hart < NUM_HARTS else 0
        assert value == expected, f"claimi: 0x{value:08x}, model 0x{expected:08x}"
        await self.settle()
        return value

    async def claim_burst(
        self, domain: int, hart: int, count: int, now: bool = False
    ) -> list[int]:
        """Perform claimi reads on consecutive cycles, each checked against the model.

        With now set, the first read is in the current cycle, as after an
        unsettled write.
        """
        offset = idc_offset(domain, hart, CLAIMI)
        values = []
        if not now:
            await FallingEdge(self.dut.i_clk)
        self.dut.i_rd_offset.value = offset
        self.dut.i_rd_capture.value = 1
        for index in range(count):
            await ReadOnly()
            value = int(self.dut.o_rd_pair.value) >> 32
            expected = self.model.claim(domain, hart)
            assert value == expected, (
                f"claim {index} of a burst: 0x{value:08x}, model 0x{expected:08x}"
            )
            values.append(value)
            await FallingEdge(self.dut.i_clk)
        self.dut.i_rd_capture.value = 0
        await self.settle()
        return values

    async def write_burst(
        self, writes: list[tuple[int, int]], settle: bool = True
    ) -> None:
        """Back-to-back 32-bit stores, one per cycle."""
        await FallingEdge(self.dut.i_clk)
        for offset, data in writes:
            self.dut.i_wr_en.value = 1
            self.dut.i_wr_offset.value = offset
            self.dut.i_wr_data.value = data & 0xFFFF_FFFF
            await FallingEdge(self.dut.i_clk)
            self.model.write(offset, data)
        self.dut.i_wr_en.value = 0
        if settle:
            await self.settle()

    async def write_with_wire(
        self, offset: int, data: int, number: int, value: int
    ) -> None:
        """Change a source wire in the same cycle as a store, then settle.

        The cycle follows the old source mode's rules before the store's.
        """
        await FallingEdge(self.dut.i_clk)
        if value:
            self.wires |= 1 << (number - 1)
        else:
            self.wires &= ~(1 << (number - 1))
        self.dut.i_src.value = self.wires
        self.dut.i_wr_en.value = 1
        self.dut.i_wr_offset.value = offset
        self.dut.i_wr_data.value = data & 0xFFFF_FFFF
        await FallingEdge(self.dut.i_clk)
        self.dut.i_wr_en.value = 0
        self.model.set_wire(number, value)
        self.model.write(offset, data)
        await self.settle()

    async def claim_with_write(
        self, domain: int, hart: int, offset: int, data: int
    ) -> int:
        """Perform a claimi read and a store in the same cycle.

        The claim reads the state before the store and takes effect first.
        """
        await FallingEdge(self.dut.i_clk)
        self.dut.i_rd_offset.value = idc_offset(domain, hart, CLAIMI)
        self.dut.i_rd_capture.value = 1
        self.dut.i_wr_en.value = 1
        self.dut.i_wr_offset.value = offset
        self.dut.i_wr_data.value = data & 0xFFFF_FFFF
        await ReadOnly()
        value = int(self.dut.o_rd_pair.value) >> 32
        await FallingEdge(self.dut.i_clk)
        self.dut.i_rd_capture.value = 0
        self.dut.i_wr_en.value = 0
        expected = self.model.claim(domain, hart)
        self.model.write(offset, data)
        assert value == expected, f"claimi: 0x{value:08x}, model 0x{expected:08x}"
        await self.settle()
        return value

    async def scan(self) -> None:
        """Read every word of both control regions against the model."""
        for offset in range(0, 0x1_0000, 8):
            await self.read_pair(offset)

    async def captured_read(self, offset: int) -> int:
        """Perform a read of any register, with the capture pulse."""
        await FallingEdge(self.dut.i_clk)
        self.dut.i_rd_offset.value = offset
        self.dut.i_rd_capture.value = 1
        await ReadOnly()
        pair = int(self.dut.o_rd_pair.value)
        await FallingEdge(self.dut.i_clk)
        self.dut.i_rd_capture.value = 0
        value = (pair >> 32) if offset & 4 else pair & 0xFFFF_FFFF
        if (
            offset >> 15 in (0, 1)
            and (offset & 0x7FFF) >= IDC
            and (offset & 0x1F) == CLAIMI
            and ((offset & 0x7FFF) - IDC) >> 5 < NUM_HARTS
        ):
            expected = self.model.claim(offset >> 15, ((offset & 0x7FFF) - IDC) >> 5)
        else:
            expected = self.model.read(offset)
        assert value == expected, (
            f"read 0x{offset:06x}: 0x{value:08x}, model 0x{expected:08x}"
        )
        await self.settle()
        return value

    async def set_wire(self, number: int, value: int) -> None:
        """Drive a source wire, then the settling cycles."""
        await FallingEdge(self.dut.i_clk)
        if value:
            self.wires |= 1 << (number - 1)
        else:
            self.wires &= ~(1 << (number - 1))
        self.dut.i_src.value = self.wires
        self.model.set_wire(number, value)
        await self.settle()

    async def expect(self, offset: int, value: int) -> None:
        """Check that a register reads a value the spec gives."""
        got = await self.read(offset)
        assert got == value, f"0x{offset:06x} reads 0x{got:08x}, expected 0x{value:08x}"

    async def pending(self, domain: int, number: int) -> bool:
        """Return a source's pending bit as a domain's setip reads it."""
        offset, bit = bitmap(domain, SETIP, number)
        return bool(await self.read(offset) & bit)

    # -- common configurations ---------------------------------------------

    async def activate(
        self, domain: int, number: int, mode: int, hart: int = 0, priority: int = 1
    ) -> None:
        """Make a source active in a domain, enabled, with a target."""
        if domain == SUPERVISOR:
            await self.write(sourcecfg(ROOT, number), SOURCECFG_D)
        await self.write(sourcecfg(domain, number), mode)
        await self.write(target(domain, number), (hart << 18) | priority)
        await self.write(reg_offset(domain, SETIENUM), number)

    async def deliver(self, domain: int, hart: int) -> None:
        """Turn on delivery to a hart: domain IE, idelivery, no threshold."""
        await self.write(reg_offset(domain, DOMAINCFG), 1 << 8)
        await self.write(idc_offset(domain, hart, IDELIVERY), 1)
        await self.write(idc_offset(domain, hart, ITHRESHOLD), 0)


def topi_value(number: int, priority: int) -> int:
    """Return the topi value reporting a source with a priority number."""
    return (number << 16) | priority


@cocotb.test()
async def test_reset_values(dut: Any) -> None:
    """Every register of both domains reads its reset value, all lines low."""
    bench = Bench(dut)
    await bench.start()
    for domain in DOMAINS:
        base = DOMAIN_BASE[domain]
        for offset in range(base, base + 0x8000, 8):
            low, high = await bench.read_pair(offset)
            expected_low = 0x8000_0000 if offset == base + DOMAINCFG else 0
            assert (low, high) == (expected_low, 0), f"0x{offset:06x} after reset"
    # The rest of the window, outside both regions.
    for offset in (0x1_0000, 0x1_8000, 0x10_4018, 0x20_0000, 0x3F_FFF8):
        assert await bench.read_pair(offset) == (0, 0)
    assert int(dut.o_meip.value) == 0 and int(dut.o_seip.value) == 0


@cocotb.test()
async def test_domaincfg(dut: Any) -> None:
    """IE and implemented DM are writable; bits 31:24 read 0x80 and BE is zero."""
    bench = Bench(dut)
    await bench.start()
    for domain in DOMAINS:
        offset = reg_offset(domain, DOMAINCFG)
        other = reg_offset(1 - domain, DOMAINCFG)
        await bench.write(offset, 0xFFFF_FFFF)
        await bench.expect(offset, 0x8000_0100 | (4 if MSI_ENABLE else 0))
        await bench.expect(other, 0x8000_0000)
        # The spec's write for an unknown byte order, (x << 24) | x, with BE
        # and DM requested: only an implemented DM bit is retained.
        await bench.write(offset, (0x05 << 24) | 0x05)
        await bench.expect(offset, 0x8000_0000 | (4 if MSI_ENABLE else 0))
        await bench.write(offset, 0x0100)
        await bench.expect(offset, 0x8000_0100)
        await bench.write(offset, 0)
        await bench.expect(offset, 0x8000_0000)


@cocotb.test()
async def test_sourcecfg_and_delegation(dut: Any) -> None:
    """Sourcecfg WARL modes, delegation, and each domain's view of a source."""
    bench = Bench(dut)
    await bench.start()
    # Every source, or with many sources the first 40 and the last 8.
    numbers = list(range(1, NUM_SOURCES + 1))
    if NUM_SOURCES > 48:
        numbers = numbers[:40] + numbers[-8:]
    for number in numbers:
        root_cfg, s_cfg = sourcecfg(ROOT, number), sourcecfg(SUPERVISOR, number)
        # Root domain: every SM encoding; the reserved 2 and 3 read Inactive.
        for mode in range(8):
            await bench.write(root_cfg, 0xFFFF_F800 | mode)
            await bench.expect(root_cfg, mode if mode in SOURCE_MODES else 0)
        # A source the supervisor domain does not hold is not implemented there.
        await bench.write(s_cfg, SM_LEVEL1)
        await bench.expect(s_cfg, 0)
        await bench.expect(root_cfg, SM_LEVEL0)
        # Delegation: the child index is read-only zero (one child), and the
        # child's sourcecfg reads zero until written.
        await bench.write(root_cfg, SOURCECFG_D | 0x3FF)
        await bench.expect(root_cfg, SOURCECFG_D)
        await bench.expect(s_cfg, 0)
        for mode in range(8):
            await bench.write(s_cfg, mode)
            await bench.expect(s_cfg, mode if mode in SOURCE_MODES else 0)
            await bench.expect(root_cfg, SOURCECFG_D)
        await bench.write(s_cfg, SM_EDGE0)
        # Delegating again leaves the child's configuration alone.
        await bench.write(root_cfg, SOURCECFG_D)
        await bench.expect(s_cfg, SM_EDGE0)
        # The supervisor domain is a leaf: D = 1 writes the register as zero.
        await bench.write(s_cfg, SOURCECFG_D | SM_LEVEL1)
        await bench.expect(s_cfg, 0)
        await bench.write(s_cfg, SM_DETACHED)
        # Taking the source back makes it absent below and active in the root.
        await bench.write(root_cfg, SM_EDGE1)
        await bench.expect(root_cfg, SM_EDGE1)
        await bench.expect(s_cfg, 0)
        # Re-delegating starts the child at zero again.
        await bench.write(root_cfg, SOURCECFG_D)
        await bench.expect(s_cfg, 0)
        await bench.write(root_cfg, SM_INACTIVE)
    # Sources beyond NUM_SOURCES are read-only zero in both domains.
    for number in sorted({NUM_SOURCES + 1, 1023}):
        if NUM_SOURCES < number <= 1023:
            for domain in DOMAINS:
                await bench.write(sourcecfg(domain, number), SM_LEVEL1)
                await bench.expect(sourcecfg(domain, number), 0)


@cocotb.test()
async def test_delegated_view(dut: Any) -> None:
    """A domain sees the pending, enable and target state of its own sources only."""
    bench = Bench(dut)
    await bench.start()
    mine, other = 1, min(2, NUM_SOURCES)
    mine_priority, other_priority = min(2, MAX_PRIORITY), min(3, MAX_PRIORITY)
    await bench.activate(SUPERVISOR, mine, SM_DETACHED, priority=mine_priority)
    await bench.write(reg_offset(SUPERVISOR, SETIPNUM), mine)
    assert await bench.pending(SUPERVISOR, mine)
    # The root sees the delegated source as inactive: no pending or enable
    # bit, no target, and its writes to them change nothing.
    assert not await bench.pending(ROOT, mine)
    offset, bit = bitmap(ROOT, SETIE, mine)
    assert not await bench.read(offset) & bit
    await bench.expect(target(ROOT, mine), 0)
    await bench.write(reg_offset(ROOT, CLRIPNUM), mine)
    await bench.write(reg_offset(ROOT, CLRIENUM), mine)
    await bench.write(target(ROOT, mine), 7)
    assert await bench.pending(SUPERVISOR, mine)
    offset, bit = bitmap(SUPERVISOR, SETIE, mine)
    assert await bench.read(offset) & bit
    await bench.expect(target(SUPERVISOR, mine), mine_priority)
    if other != mine:
        # A root source is invisible to the supervisor domain, which cannot
        # touch it.
        await bench.activate(ROOT, other, SM_DETACHED, priority=other_priority)
        await bench.write(reg_offset(ROOT, SETIPNUM), other)
        for reg in (SETIPNUM, SETIENUM, CLRIENUM, CLRIPNUM):
            await bench.write(reg_offset(SUPERVISOR, reg), other)
        await bench.write(target(SUPERVISOR, other), 1)
        await bench.write(sourcecfg(SUPERVISOR, other), SM_LEVEL1)
        assert not await bench.pending(SUPERVISOR, other)
        await bench.expect(target(SUPERVISOR, other), 0)
        await bench.expect(sourcecfg(SUPERVISOR, other), 0)
        assert await bench.pending(ROOT, other)
        await bench.expect(target(ROOT, other), other_priority)
        await bench.expect(sourcecfg(ROOT, other), SM_DETACHED)
    # Moving a source between domains clears its pending and enable bits.
    await bench.write(sourcecfg(ROOT, mine), SM_DETACHED)
    assert not await bench.pending(ROOT, mine)
    offset, bit = bitmap(ROOT, SETIE, mine)
    assert not await bench.read(offset) & bit


async def _check_mode(bench: Bench, domain: int, number: int, mode: int) -> None:
    """Check the pending-bit rules of one source mode, in one domain."""
    clr_offset, bit = bitmap(domain, IN_CLRIP, number)
    setip_offset, _ = bitmap(domain, SETIP, number)
    setipnum = reg_offset(domain, SETIPNUM)
    clripnum = reg_offset(domain, CLRIPNUM)
    inverted = mode in (SM_EDGE0, SM_LEVEL0)
    # Start with the rectified input low, so activation makes no edge.
    await bench.set_wire(number, int(inverted))
    await bench.activate(domain, number, mode, priority=1)
    await bench.deliver(domain, 0)

    async def rectified() -> int:
        return int(bool(await bench.read(clr_offset) & bit))

    if mode == SM_INACTIVE:
        await bench.set_wire(number, 1)
        await bench.write(setipnum, number)
        assert await rectified() == 0
        assert not await bench.pending(domain, number)
        await bench.expect(target(domain, number), 0)
        return
    if mode == SM_DETACHED:
        # The wire is ignored; writes set and clear; a claim clears.
        await bench.set_wire(number, 1)
        assert await rectified() == 0
        assert not await bench.pending(domain, number)
        await bench.write(setipnum, number)
        assert await bench.pending(domain, number)
        await bench.write(clripnum, number)
        assert not await bench.pending(domain, number)
        await bench.write(setip_offset, bit)
        assert await bench.pending(domain, number)
        await bench.write(clr_offset, bit)
        assert not await bench.pending(domain, number)
        await bench.write(setipnum, number)
        assert await bench.claim(domain, 0) == topi_value(number, 1)
        assert not await bench.pending(domain, number)
        return
    active_level = 0 if inverted else 1
    if mode in (SM_EDGE1, SM_EDGE0):
        # The assertion edge of the rectified input sets the bit; holding
        # the level or the opposite edge does not.
        await bench.set_wire(number, 1 - active_level)
        assert not await bench.pending(domain, number)
        assert await rectified() == 0
        await bench.set_wire(number, active_level)
        assert await rectified() == 1
        assert await bench.pending(domain, number)
        assert await bench.claim(domain, 0) == topi_value(number, 1)
        assert not await bench.pending(domain, number), "a claim clears an edge"
        await bench.settle(5)
        assert not await bench.pending(domain, number), "a held level is no new edge"
        await bench.set_wire(number, 1 - active_level)
        assert not await bench.pending(domain, number)
        await bench.set_wire(number, active_level)
        assert await bench.pending(domain, number)
        await bench.write(clripnum, number)
        assert not await bench.pending(domain, number)
        await bench.set_wire(number, 1 - active_level)
        await bench.write(setipnum, number)
        assert await bench.pending(domain, number), "setipnum sets an edge source"
        await bench.write(clr_offset, bit)
        assert not await bench.pending(domain, number)
        return
    # Level1/Level0: the pending bit is the rectified input, whatever
    # software does.
    await bench.set_wire(number, 1 - active_level)
    assert await rectified() == 0
    await bench.write(setipnum, number)
    await bench.write(setip_offset, bit)
    assert not await bench.pending(domain, number), "setip cannot set a level source"
    await bench.set_wire(number, active_level)
    assert await rectified() == 1
    assert await bench.pending(domain, number)
    await bench.write(clripnum, number)
    await bench.write(clr_offset, bit)
    assert await bench.pending(domain, number), "in_clrip cannot clear a level source"
    for _ in range(3):
        assert await bench.claim(domain, 0) == topi_value(number, 1)
    assert await bench.pending(domain, number), "a claim cannot clear a level source"
    await bench.set_wire(number, 1 - active_level)
    assert not await bench.pending(domain, number)
    assert await bench.claim(domain, 0) == 0


@cocotb.test()
async def test_source_modes(dut: Any) -> None:
    """Every source mode's pending-bit rules, in both domains."""
    bench = Bench(dut)
    await bench.start()
    number = NUM_SOURCES  # the highest source, at the end of its bitmap word
    for domain in DOMAINS:
        for mode in SOURCE_MODES:
            await _check_mode(bench, domain, number, mode)
            await bench.write(sourcecfg(ROOT, number), SM_INACTIVE)


@cocotb.test()
async def test_sourcecfg_write_edge(dut: Any) -> None:
    """A sourcecfg write that raises an edge source's rectified input sets it."""
    bench = Bench(dut)
    await bench.start()
    cfg = sourcecfg(ROOT, 1)
    await bench.set_wire(1, 1)
    await bench.write(cfg, SM_DETACHED)
    assert not await bench.pending(ROOT, 1)
    await bench.write(cfg, SM_EDGE1)
    assert await bench.pending(ROOT, 1), "Detached to Edge1 with the wire high"
    # A mode change that keeps the rectified input high is no edge.
    await bench.write(reg_offset(ROOT, CLRIPNUM), 1)
    await bench.write(cfg, SM_LEVEL1)
    assert await bench.pending(ROOT, 1)
    await bench.write(cfg, SM_EDGE1)
    assert await bench.pending(ROOT, 1), (
        "Level1 left the bit set, and no rule clears it"
    )
    await bench.write(reg_offset(ROOT, CLRIPNUM), 1)
    await bench.write(cfg, SM_EDGE1)
    assert not await bench.pending(ROOT, 1), "rewriting the same mode is no edge"
    # Making a source inactive clears its bits; reactivating starts at zero
    # except for the edge that the write itself makes.
    await bench.write(reg_offset(ROOT, SETIENUM), 1)
    await bench.write(cfg, SM_INACTIVE)
    await bench.set_wire(1, 0)
    await bench.write(cfg, SM_EDGE1)
    assert not await bench.pending(ROOT, 1)
    offset, bit = bitmap(ROOT, SETIE, 1)
    assert not await bench.read(offset) & bit


@cocotb.test()
async def test_bitmap_and_number_registers(dut: Any) -> None:
    """setip/in_clrip/setie/clrie words and the number registers."""
    bench = Bench(dut)
    await bench.start()
    all_sources = range(1, NUM_SOURCES + 1)
    for number in all_sources:
        await bench.write(sourcecfg(ROOT, number), SM_DETACHED)
    words = (NUM_SOURCES // 32) + 1
    for k in range(32):
        # Bit 0 of word 0 and bits beyond NUM_SOURCES are not implemented.
        mask = 0
        for bit in range(32):
            if 1 <= 32 * k + bit <= NUM_SOURCES:
                mask |= 1 << bit
        for base in (SETIP, SETIE):
            await bench.write(reg_offset(ROOT, base + 4 * k), 0xFFFF_FFFF)
            await bench.expect(reg_offset(ROOT, base + 4 * k), mask)
        await bench.write(reg_offset(ROOT, IN_CLRIP + 4 * k), 0xFFFF_FFFF)
        await bench.expect(reg_offset(ROOT, SETIP + 4 * k), 0)
        await bench.write(reg_offset(ROOT, CLRIE + 4 * k), 0xFFFF_FFFF)
        await bench.expect(reg_offset(ROOT, SETIE + 4 * k), 0)
        if k >= words:
            break
    # The number registers: each names one source; zero and numbers beyond
    # NUM_SOURCES are ignored. setipnum_be takes big-endian bytes.
    for number in (1, NUM_SOURCES):
        offset, bit = bitmap(ROOT, SETIP, number)
        ie_offset, _ = bitmap(ROOT, SETIE, number)
        await bench.write(reg_offset(ROOT, SETIPNUM_LE), number)
        assert await bench.read(offset) & bit
        await bench.write(reg_offset(ROOT, CLRIPNUM), number)
        assert not await bench.read(offset) & bit
        await bench.write(reg_offset(ROOT, SETIPNUM_BE), number)
        assert not await bench.read(offset) & bit or byteswap32(number) == number
        await bench.write(reg_offset(ROOT, SETIPNUM_BE), byteswap32(number))
        assert await bench.read(offset) & bit
        await bench.write(reg_offset(ROOT, IN_CLRIP + 4 * (number // 32)), bit)
        await bench.write(reg_offset(ROOT, SETIENUM), number)
        assert await bench.read(ie_offset) & bit
        await bench.write(reg_offset(ROOT, CLRIENUM), number)
        assert not await bench.read(ie_offset) & bit
    for bad in (0, NUM_SOURCES + 1, 1 << 16, 0xFFFF_FFFF):
        for reg in (SETIPNUM, SETIPNUM_LE, SETIENUM):
            await bench.write(reg_offset(ROOT, reg), bad)
    for k in range(words):
        await bench.expect(reg_offset(ROOT, SETIP + 4 * k), 0)
        await bench.expect(reg_offset(ROOT, SETIE + 4 * k), 0)
    # Write-only registers, unimplemented MSI registers and direct genmsi read zero.
    await bench.write(reg_offset(ROOT, SETIE), 0xFFFF_FFFF)
    for reg in (
        SETIPNUM,
        CLRIPNUM,
        SETIENUM,
        CLRIENUM,
        SETIPNUM_LE,
        SETIPNUM_BE,
        CLRIE,
        GENMSI,
    ) + (() if MSI_ENABLE else tuple(range(MMSIADDRCFG, MMSIADDRCFG + 16, 4))):
        await bench.write(reg_offset(ROOT, reg), 0xFFFF_FFFF)
        await bench.expect(reg_offset(ROOT, reg), 0)


@cocotb.test()
async def test_target(dut: Any) -> None:
    """target: WLRL hart index, WARL priority with zero written as 1."""
    bench = Bench(dut)
    await bench.start()
    hart_mask = (1 << max(1, (NUM_HARTS - 1).bit_length())) - 1 if NUM_HARTS > 1 else 0
    for domain in DOMAINS:
        number = NUM_SOURCES
        reg = target(domain, number)
        # Read-only zero while inactive.
        await bench.write(reg, (1 << 18) | 3)
        await bench.expect(reg, 0)
        if domain == SUPERVISOR:
            await bench.write(sourcecfg(ROOT, number), SOURCECFG_D)
        await bench.write(sourcecfg(domain, number), SM_DETACHED)
        await bench.write(reg, 0xFFFF_FFFF)
        await bench.expect(reg, (hart_mask << 18) | MAX_PRIORITY)
        await bench.write(reg, 0)
        await bench.expect(reg, 1)
        await bench.write(reg, 0x0003_FF00)  # bits 17:8 are not a field
        await bench.expect(reg, 1)
        for priority in range(1, MAX_PRIORITY + 1):
            await bench.write(reg, ((NUM_HARTS - 1) << 18) | priority)
            await bench.expect(reg, ((NUM_HARTS - 1) << 18) | priority)
        await bench.write(sourcecfg(ROOT, number), SM_INACTIVE)
        await bench.expect(reg, 0)


@cocotb.test()
async def test_priority_threshold(dut: Any) -> None:
    """Topi takes the smallest priority number, then the lowest ID, under ithreshold."""
    bench = Bench(dut)
    await bench.start()
    if NUM_SOURCES < 3:
        return
    numbers = (1, 2, 3)
    for domain in DOMAINS:
        topi = idc_offset(domain, 0, TOPI)
        threshold = idc_offset(domain, 0, ITHRESHOLD)
        low_priority = MAX_PRIORITY
        # Source 3 has the best priority number; 1 and 2 tie behind it.
        priorities = {1: low_priority, 2: low_priority, 3: 1 if MAX_PRIORITY > 1 else 1}
        for number in numbers:
            await bench.activate(
                domain, number, SM_DETACHED, priority=priorities[number]
            )
            await bench.write(reg_offset(domain, SETIPNUM), number)
        # topi is independent of domaincfg.IE and idelivery, both zero here.
        best = 3 if MAX_PRIORITY > 1 else 1
        await bench.expect(topi, topi_value(best, priorities[best]))
        assert await bench.read(idc_offset(domain, 0, CLAIMI)) == topi_value(
            best, priorities[best]
        )
        if MAX_PRIORITY > 1:
            # A threshold P admits only priority numbers below P.
            await bench.write(threshold, low_priority)
            await bench.expect(topi, topi_value(3, 1))
            await bench.write(threshold, 1)
            await bench.expect(topi, 0)
            await bench.write(threshold, 0)
            await bench.write(reg_offset(domain, CLRIPNUM), 3)
            await bench.expect(topi, topi_value(1, low_priority))
        # The other domain sees none of these.
        await bench.expect(idc_offset(1 - domain, 0, TOPI), 0)
        # Disabling or clearing the winner hands topi to the next one.
        await bench.write(reg_offset(domain, CLRIENUM), 1)
        await bench.expect(topi, topi_value(2, low_priority))
        await bench.write(reg_offset(domain, CLRIPNUM), 2)
        if MAX_PRIORITY > 1:
            await bench.expect(topi, 0)
        await bench.write(threshold, 0)
        for number in numbers:
            await bench.write(sourcecfg(ROOT, number), SM_INACTIVE)


@cocotb.test()
async def test_claim_and_delivery(dut: Any) -> None:
    """claimi, iforce, idelivery and domaincfg.IE on both interrupt lines."""
    bench = Bench(dut)
    await bench.start()
    for domain in DOMAINS:
        line = dut.o_meip if domain == ROOT else dut.o_seip
        await bench.activate(domain, 1, SM_EDGE1, priority=1)
        await bench.set_wire(1, 1)
        # Pending and enabled, but no IE or idelivery yet: no interrupt.
        assert int(line.value) == 0
        await bench.write(idc_offset(domain, 0, IDELIVERY), 1)
        assert int(line.value) == 0
        await bench.write(reg_offset(domain, DOMAINCFG), 1 << 8)
        assert int(line.value) & 1
        await bench.write(idc_offset(domain, 0, IDELIVERY), 0)
        assert not int(line.value) & 1
        await bench.write(idc_offset(domain, 0, IDELIVERY), 1)
        assert await bench.claim(domain, 0) == topi_value(1, 1)
        assert not int(line.value) & 1
        # An empty claim returns zero and clears iforce; iforce raises the
        # line with nothing pending (a spurious interrupt).
        await bench.write(idc_offset(domain, 0, IFORCE), 1)
        assert int(line.value) & 1
        await bench.expect(idc_offset(domain, 0, IFORCE), 1)
        await bench.write(reg_offset(domain, DOMAINCFG), 0)
        assert not int(line.value) & 1, "IE gates iforce too"
        await bench.write(reg_offset(domain, DOMAINCFG), 1 << 8)
        assert await bench.claim(domain, 0) == 0
        await bench.expect(idc_offset(domain, 0, IFORCE), 0)
        assert not int(line.value) & 1
        # A nonzero claim leaves iforce alone.
        await bench.write(idc_offset(domain, 0, IFORCE), 1)
        await bench.write(reg_offset(domain, SETIPNUM), 1)
        assert await bench.claim(domain, 0) == topi_value(1, 1)
        await bench.expect(idc_offset(domain, 0, IFORCE), 1)
        await bench.write(idc_offset(domain, 0, IFORCE), 0)
        # A plain read of claimi, without the capture pulse, claims nothing.
        await bench.write(reg_offset(domain, SETIPNUM), 1)
        assert await bench.read(idc_offset(domain, 0, CLAIMI)) == topi_value(1, 1)
        assert await bench.pending(domain, 1)
        # Performed reads of other registers have no side effect.
        assert await bench.captured_read(idc_offset(domain, 0, TOPI)) == topi_value(
            1, 1
        )
        assert await bench.pending(domain, 1)
        assert await bench.captured_read(idc_offset(domain, 0, CLAIMI)) == topi_value(
            1, 1
        )
        assert not await bench.pending(domain, 1)
        # Writes to topi and claimi are ignored.
        await bench.write(reg_offset(domain, SETIPNUM), 1)
        for reg in (TOPI, CLAIMI):
            await bench.write(idc_offset(domain, 0, reg), 0)
        assert await bench.pending(domain, 1)
        await bench.write(reg_offset(domain, CLRIPNUM), 1)
        # The IDC registers keep one bit, or IPRIOLEN bits for ithreshold.
        await bench.write(idc_offset(domain, 0, IDELIVERY), 0xFFFF_FFFE)
        await bench.expect(idc_offset(domain, 0, IDELIVERY), 0)
        await bench.write(idc_offset(domain, 0, ITHRESHOLD), 0xFFFF_FFFF)
        await bench.expect(idc_offset(domain, 0, ITHRESHOLD), MAX_PRIORITY)
        await bench.write(idc_offset(domain, 0, ITHRESHOLD), 0)
        await bench.set_wire(1, 0)
        await bench.write(sourcecfg(ROOT, 1), SM_INACTIVE)
        await bench.write(reg_offset(domain, DOMAINCFG), 0)


@cocotb.test()
async def test_back_to_back_claims(dut: Any) -> None:
    """Claims on consecutive cycles see each other's effects at once."""
    bench = Bench(dut)
    await bench.start()
    if NUM_SOURCES < 3:
        return
    for domain in DOMAINS:
        await bench.deliver(domain, 0)
        # A level source stays pending through every claim.
        await bench.activate(domain, 1, SM_LEVEL1, priority=1)
        await bench.set_wire(1, 1)
        assert await bench.claim_burst(domain, 0, 4) == [topi_value(1, 1)] * 4
        # Edge and Detached sources are claimed once each, in ID order at
        # equal priority, and then the claims find nothing.
        await bench.set_wire(1, 0)
        await bench.activate(domain, 2, SM_EDGE1, priority=1)
        await bench.activate(domain, 3, SM_DETACHED, priority=1)
        await bench.set_wire(2, 1)
        await bench.write(reg_offset(domain, SETIPNUM), 3)
        assert await bench.claim_burst(domain, 0, 3) == [
            topi_value(2, 1),
            topi_value(3, 1),
            0,
        ]
        await bench.set_wire(2, 0)
        for number in (1, 2, 3):
            await bench.write(sourcecfg(ROOT, number), SM_INACTIVE)


@cocotb.test()
async def test_claim_after_mode_change(dut: Any) -> None:
    """A claim in the cycle after a sourcecfg write sees the new mode's rules."""
    bench = Bench(dut)
    await bench.start()
    for domain in DOMAINS:
        await bench.deliver(domain, 0)
        cfg = sourcecfg(domain, 1)
        # A pending Detached source switched to Level1 with its wire low is
        # no longer pending in the very next cycle.
        await bench.activate(domain, 1, SM_DETACHED)
        await bench.write(reg_offset(domain, SETIPNUM), 1)
        await bench.write(cfg, SM_LEVEL1, settle=False)
        assert await bench.claim_burst(domain, 0, 2, now=True) == [0, 0]
        # Level1 to Level0 with the wire low makes it pending at once.
        await bench.write(cfg, SM_LEVEL0, settle=False)
        assert await bench.claim_burst(domain, 0, 2, now=True) == [topi_value(1, 1)] * 2
        # Level0 to Edge0 keeps the bit, and the first claim clears it.
        await bench.write(cfg, SM_EDGE0, settle=False)
        assert await bench.claim_burst(domain, 0, 2, now=True) == [topi_value(1, 1), 0]
        # A write that raises an edge source's rectified input sets the
        # pending bit at the write, so a claim or a clear in the next cycle
        # wins over it: pending Detached to Edge1 with the wire high.
        await bench.set_wire(1, 1)
        await bench.write(cfg, SM_DETACHED)
        await bench.write(reg_offset(domain, SETIPNUM), 1)
        await bench.write(cfg, SM_EDGE1, settle=False)
        assert await bench.claim_burst(domain, 0, 2, now=True) == [topi_value(1, 1), 0]
        await bench.write(cfg, SM_DETACHED)
        await bench.write(reg_offset(domain, SETIPNUM), 1)
        await bench.write_burst([(cfg, SM_EDGE1), (reg_offset(domain, CLRIPNUM), 1)])
        assert not await bench.pending(domain, 1)
        # A level source whose wire asserts in the cycle of a write that makes
        # it edge-sensitive is pending in its new mode; one whose wire drops
        # then is not.
        await bench.set_wire(1, 0)
        await bench.write(cfg, SM_LEVEL1)
        await bench.write_with_wire(cfg, SM_EDGE1, 1, 1)
        assert await bench.pending(domain, 1)
        assert await bench.claim(domain, 0) == topi_value(1, 1)
        await bench.write(cfg, SM_LEVEL1)
        await bench.write_with_wire(cfg, SM_EDGE1, 1, 0)
        assert not await bench.pending(domain, 1)
        await bench.set_wire(1, 1)
        await bench.write(reg_offset(domain, CLRIPNUM), 1)
        # Edge1 to Edge0 and back with the wire high: only the write that
        # raises the rectified input sets the bit.
        await bench.write_burst([(cfg, SM_EDGE0), (cfg, SM_EDGE1)], settle=False)
        assert await bench.claim_burst(domain, 0, 2, now=True) == [topi_value(1, 1), 0]
        await bench.set_wire(1, 0)
        await bench.write(sourcecfg(ROOT, 1), SM_INACTIVE)


@cocotb.test()
async def test_target_while_inactive(dut: Any) -> None:
    """A target written while inactive reads zero and applies on activation."""
    bench = Bench(dut)
    await bench.start()
    hart = NUM_HARTS - 1
    priority = min(3, MAX_PRIORITY)
    for domain in DOMAINS:
        if domain == SUPERVISOR:
            await bench.write(sourcecfg(ROOT, 1), SOURCECFG_D)
        # As Linux and OpenSBI do: the target before the source mode.
        await bench.write(target(domain, 1), (hart << 18) | priority)
        await bench.expect(target(domain, 1), 0)
        await bench.write(sourcecfg(domain, 1), SM_DETACHED)
        await bench.expect(target(domain, 1), (hart << 18) | priority)
        await bench.write(reg_offset(domain, SETIENUM), 1)
        await bench.write(reg_offset(domain, SETIPNUM), 1)
        await bench.deliver(domain, hart)
        await bench.expect(idc_offset(domain, hart, TOPI), topi_value(1, priority))
        assert await bench.claim(domain, hart) == topi_value(1, priority)
        await bench.write(sourcecfg(ROOT, 1), SM_INACTIVE)
    # The other domain cannot write it, and a move between domains resets it
    # to hart 0, priority 1.
    await bench.write(sourcecfg(ROOT, 1), SM_DETACHED)
    await bench.write(target(ROOT, 1), (hart << 18) | priority)
    await bench.write(target(SUPERVISOR, 1), 1)
    await bench.expect(target(ROOT, 1), (hart << 18) | priority)
    await bench.write(sourcecfg(ROOT, 1), SOURCECFG_D)
    await bench.write(sourcecfg(SUPERVISOR, 1), SM_DETACHED)
    await bench.expect(target(SUPERVISOR, 1), 1)
    await bench.write(target(SUPERVISOR, 1), (hart << 18) | priority)
    await bench.write(sourcecfg(ROOT, 1), SM_EDGE1)
    await bench.expect(target(ROOT, 1), 1)


@cocotb.test()
async def test_reserved_writes(dut: Any) -> None:
    """Writes to every offset that is not a writable register change nothing."""
    bench = Bench(dut)
    await bench.start()
    # State to disturb: an active, enabled, pending source in each domain,
    # delivery on, and iforce and a threshold set on every IDC.
    for domain in DOMAINS:
        number = 1 if domain == ROOT else NUM_SOURCES
        if domain == SUPERVISOR and NUM_SOURCES == 1:
            break
        await bench.activate(domain, number, SM_DETACHED, priority=1)
        await bench.write(reg_offset(domain, SETIPNUM), number)
        await bench.deliver(domain, 0)
        for hart in range(min(NUM_HARTS, 4)):
            await bench.write(idc_offset(domain, hart, IFORCE), 1)
            await bench.write(idc_offset(domain, hart, ITHRESHOLD), MAX_PRIORITY)
    writable = set()
    for domain in DOMAINS:
        base = DOMAIN_BASE[domain]
        writable.add(base + DOMAINCFG)
        for number in range(1, NUM_SOURCES + 1):
            writable.add(base + SOURCECFG + 4 * number)
            writable.add(base + TARGET + 4 * number)
        for reg in (SETIP, IN_CLRIP, SETIE, CLRIE):
            writable.update(base + reg + 4 * k for k in range(32))
        writable.update(
            base + reg
            for reg in (
                SETIPNUM,
                CLRIPNUM,
                SETIENUM,
                CLRIENUM,
                SETIPNUM_LE,
                SETIPNUM_BE,
            )
        )
        for hart in range(NUM_HARTS):
            writable.update(
                idc_offset(domain, hart, word)
                for word in (IDELIVERY, IFORCE, ITHRESHOLD)
            )
    # The registers that hold state, read after every batch of writes.
    probes = [reg_offset(d, DOMAINCFG) for d in DOMAINS]
    for domain in DOMAINS:
        for base in (SETIP, SETIE):
            probes += [
                reg_offset(domain, base + 4 * k) for k in range(NUM_SOURCES // 32 + 1)
            ]
        for number in (1, NUM_SOURCES):
            probes += [sourcecfg(domain, number), target(domain, number)]
        for hart in range(min(NUM_HARTS, 4)):
            probes += [
                idc_offset(domain, hart, word)
                for word in (IDELIVERY, IFORCE, ITHRESHOLD)
            ]
    reserved = [offset for offset in range(0, 0x1_0000, 4) if offset not in writable]
    for data in (0xFFFF_FFFF, 0x0000_0001, 0x0000_0400):
        # One write per cycle, then the probes; the model ignores the writes.
        for start in range(0, len(reserved), 512):
            await bench.write_burst(
                [(offset, data) for offset in reserved[start : start + 512]]
            )
            for offset in probes:
                await bench.read(offset)
        await bench.scan()


@cocotb.test()
async def test_claim_with_write(dut: Any) -> None:
    """A claim and a store in the same cycle: the claim reads first."""
    bench = Bench(dut)
    await bench.start()
    if NUM_SOURCES < 2:
        return
    for domain in DOMAINS:
        await bench.deliver(domain, 0)
        await bench.activate(domain, 1, SM_DETACHED)
        await bench.activate(domain, 2, SM_DETACHED)
        setipnum = reg_offset(domain, SETIPNUM)
        clripnum = reg_offset(domain, CLRIPNUM)
        # Claim with a set of the claimed source: it stays pending.
        await bench.write(setipnum, 1)
        assert await bench.claim_with_write(domain, 0, setipnum, 1) == topi_value(1, 1)
        assert await bench.pending(domain, 1)
        # Claim with a clear of another source: both end up clear.
        await bench.write(setipnum, 2)
        assert await bench.claim_with_write(domain, 0, clripnum, 2) == topi_value(1, 1)
        assert not await bench.pending(domain, 1) and not await bench.pending(domain, 2)
        # A zero claim with a write of iforce: the write lands after it.
        assert (
            await bench.claim_with_write(domain, 0, idc_offset(domain, 0, IFORCE), 1)
            == 0
        )
        await bench.expect(idc_offset(domain, 0, IFORCE), 1)
        assert await bench.claim(domain, 0) == 0
        await bench.expect(idc_offset(domain, 0, IFORCE), 0)
        # Claim with a change of the claimed source's mode or its delegation.
        await bench.write(setipnum, 1)
        assert await bench.claim_with_write(
            domain, 0, sourcecfg(domain, 1), SM_LEVEL0
        ) == topi_value(1, 1)
        assert await bench.pending(domain, 1)
        await bench.write(sourcecfg(domain, 1), SM_DETACHED)
        await bench.write(reg_offset(domain, SETIENUM), 1)
        await bench.write(setipnum, 1)
        handover = SM_EDGE1 if domain == SUPERVISOR else SOURCECFG_D
        assert await bench.claim_with_write(
            domain, 0, sourcecfg(ROOT, 1), handover
        ) == topi_value(1, 1)
        await bench.expect(sourcecfg(ROOT, 1), handover)
        # A claim of a level source with a write that makes it
        # edge-sensitive: the claim leaves a level source pending, and the
        # write keeps the bit.
        await bench.write(sourcecfg(domain, 2), SM_LEVEL1)
        await bench.set_wire(2, 1)
        assert await bench.claim_with_write(
            domain, 0, sourcecfg(domain, 2), SM_EDGE1
        ) == topi_value(2, 1)
        assert await bench.pending(domain, 2)
        await bench.set_wire(2, 0)
        for number in (1, 2):
            await bench.write(sourcecfg(ROOT, number), SM_INACTIVE)


@cocotb.test()
async def test_reset_during_traffic(dut: Any) -> None:
    """A one-cycle reset with a write and a claim in flight resets everything."""
    bench = Bench(dut)
    await bench.start()
    for domain in DOMAINS:
        number = 1 if domain == ROOT else NUM_SOURCES
        await bench.activate(domain, number, SM_EDGE1, hart=NUM_HARTS - 1)
        await bench.write(reg_offset(domain, SETIPNUM), number)
        await bench.deliver(domain, NUM_HARTS - 1)
        await bench.write(idc_offset(domain, 0, IFORCE), 1)
        await bench.write(idc_offset(domain, 0, ITHRESHOLD), MAX_PRIORITY)
    await bench.set_wire(1, 1)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 1
    dut.i_wr_en.value = 1
    dut.i_wr_offset.value = reg_offset(ROOT, DOMAINCFG)
    dut.i_wr_data.value = 1 << 8
    dut.i_rd_offset.value = idc_offset(SUPERVISOR, NUM_HARTS - 1, CLAIMI)
    dut.i_rd_capture.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    dut.i_wr_en.value = 0
    dut.i_rd_capture.value = 0
    bench.model.reset()
    await bench.settle()
    await bench.scan()


@cocotb.test()
async def test_lines_hold_during_writes(dut: Any) -> None:
    """Back-to-back writes that do not concern an interrupt leave its line up."""
    bench = Bench(dut)
    await bench.start()
    if NUM_SOURCES < 2:
        return
    for domain in DOMAINS:
        number = 1 if domain == ROOT else NUM_SOURCES
        await bench.activate(domain, number, SM_DETACHED, hart=0)
        await bench.write(reg_offset(domain, SETIPNUM), number)
        await bench.deliver(domain, 0)
    assert int(dut.o_meip.value) & 1 and int(dut.o_seip.value) & 1
    writes = []
    for index in range(64):
        domain = DOMAINS[index % 2]
        reg = (GENMSI, 0x1800, TOPI + IDC, CLAIMI + IDC)[index % 4]
        writes.append((reg_offset(domain, reg), 0xFFFF_FFFF))
    await FallingEdge(dut.i_clk)
    for offset, data in writes:
        dut.i_wr_en.value = 1
        dut.i_wr_offset.value = offset
        dut.i_wr_data.value = data
        await ReadOnly()
        assert int(dut.o_meip.value) & 1 and int(dut.o_seip.value) & 1, (
            f"a line dropped during the write of 0x{offset:06x}"
        )
        await FallingEdge(dut.i_clk)
    dut.i_wr_en.value = 0
    await bench.settle()


@cocotb.test()
async def test_priority_order(dut: Any) -> None:
    """Priority numbers compare as unsigned values across the whole range."""
    bench = Bench(dut)
    await bench.start()
    priorities = [p for p in (128, 127, MAX_PRIORITY, 129, 2) if p <= MAX_PRIORITY]
    if len(priorities) < 4 or NUM_SOURCES < len(priorities):
        return
    for domain in DOMAINS:
        topi = idc_offset(domain, 0, TOPI)
        threshold = idc_offset(domain, 0, ITHRESHOLD)
        for number, priority in enumerate(priorities, start=1):
            await bench.activate(domain, number, SM_DETACHED, priority=priority)
            await bench.write(reg_offset(domain, SETIPNUM), number)
        await bench.expect(topi, topi_value(5, 2))
        await bench.write(reg_offset(domain, CLRIPNUM), 5)
        await bench.expect(topi, topi_value(2, 127))
        for limit, expected in (
            (128, (2, 127)),
            (127, None),
            (129, (2, 127)),
            (255, (2, 127)),
        ):
            await bench.write(threshold, limit)
            await bench.expect(topi, topi_value(*expected) if expected else 0)
        await bench.write(reg_offset(domain, CLRIPNUM), 2)
        await bench.write(threshold, 129)
        await bench.expect(topi, topi_value(1, 128))
        await bench.write(threshold, 0)
        await bench.write(reg_offset(domain, CLRIPNUM), 1)
        await bench.expect(topi, topi_value(4, 129))
        await bench.write(reg_offset(domain, CLRIPNUM), 4)
        await bench.expect(topi, topi_value(3, MAX_PRIORITY))
        for number in range(1, len(priorities) + 1):
            await bench.write(sourcecfg(ROOT, number), SM_INACTIVE)


@cocotb.test()
async def test_hart_index_without_idc(dut: Any) -> None:
    """A target hart index with no IDC delivers nowhere until retargeted."""
    bench = Bench(dut)
    await bench.start()
    hart_bits = max(1, (NUM_HARTS - 1).bit_length())
    if NUM_HARTS == 1 or NUM_HARTS == 1 << hart_bits:
        return  # every hart index a target can hold has an IDC
    for domain in DOMAINS:
        line = dut.o_meip if domain == ROOT else dut.o_seip
        for hart in range(NUM_HARTS):
            await bench.deliver(domain, hart)
        await bench.activate(domain, 1, SM_DETACHED, hart=NUM_HARTS)
        await bench.expect(target(domain, 1), (NUM_HARTS << 18) | 1)
        await bench.write(reg_offset(domain, SETIPNUM), 1)
        assert int(line.value) == 0
        for hart in range(NUM_HARTS):
            await bench.expect(idc_offset(domain, hart, TOPI), 0)
        await bench.write(target(domain, 1), ((NUM_HARTS - 1) << 18) | 1)
        assert int(line.value) == 1 << (NUM_HARTS - 1)
        assert await bench.claim(domain, NUM_HARTS - 1) == topi_value(1, 1)
        await bench.write(sourcecfg(ROOT, 1), SM_INACTIVE)


@cocotb.test()
async def test_two_harts(dut: Any) -> None:
    """Each hart index has its own IDC and lines; IDCs past NUM_HARTS are absent."""
    bench = Bench(dut)
    await bench.start()
    for domain in DOMAINS:
        # The IDC after the last hart reads zero and ignores writes.
        absent = NUM_HARTS
        if absent < 512:
            for word in (IDELIVERY, IFORCE, ITHRESHOLD):
                await bench.write(idc_offset(domain, absent, word), 1)
                await bench.expect(idc_offset(domain, absent, word), 0)
            assert await bench.captured_read(idc_offset(domain, absent, CLAIMI)) == 0
    if NUM_HARTS < 2 or NUM_SOURCES < 2 or MAX_PRIORITY < 2:
        return
    for domain in DOMAINS:
        line = dut.o_meip if domain == ROOT else dut.o_seip
        other_line = dut.o_seip if domain == ROOT else dut.o_meip
        for hart in (0, 1):
            await bench.deliver(domain, hart)
        await bench.activate(domain, 1, SM_DETACHED, hart=0, priority=2)
        await bench.activate(domain, 2, SM_DETACHED, hart=1, priority=2)
        await bench.write(reg_offset(domain, SETIPNUM), 2)
        assert int(line.value) == 0b10
        assert int(other_line.value) == 0
        await bench.expect(idc_offset(domain, 0, TOPI), 0)
        await bench.expect(idc_offset(domain, 1, TOPI), topi_value(2, 2))
        await bench.write(reg_offset(domain, SETIPNUM), 1)
        assert int(line.value) == 0b11
        # Each hart claims only its own sources.
        assert await bench.claim(domain, 0) == topi_value(1, 2)
        assert int(line.value) == 0b10
        assert await bench.claim(domain, 0) == 0
        # Retargeting moves the pending interrupt to the other hart.
        await bench.write(target(domain, 2), (0 << 18) | 2)
        assert int(line.value) == 0b01
        await bench.write(target(domain, 2), (1 << 18) | 2)
        # Thresholds and iforce are per hart.
        await bench.write(idc_offset(domain, 1, ITHRESHOLD), 2)
        assert int(line.value) == 0b00
        await bench.write(idc_offset(domain, 0, IFORCE), 1)
        assert int(line.value) == 0b01
        assert await bench.claim(domain, 1) == 0, "the threshold hides source 2"
        await bench.write(idc_offset(domain, 1, ITHRESHOLD), 0)
        assert int(line.value) == 0b11
        assert await bench.claim(domain, 1) == topi_value(2, 2)
        assert await bench.claim(domain, 0) == 0
        assert int(line.value) == 0
        for number in (1, 2):
            await bench.write(sourcecfg(ROOT, number), SM_INACTIVE)
        await bench.write(reg_offset(domain, DOMAINCFG), 0)


@cocotb.test()
async def test_firmware_and_kernel_setup(dut: Any) -> None:
    """OpenSBI's and Linux's direct-mode programming sequences, then interrupts."""
    bench = Bench(dut)
    await bench.start()
    root, sup = DOMAIN_BASE
    # OpenSBI aplic_init on the root domain (lib/utils/irqchip/aplic.c),
    # delegating every source to child index 0.
    await bench.write(root + DOMAINCFG, 0)
    for i in range(0, NUM_SOURCES + 1, 32):
        await bench.write(root + CLRIE + (i // 32) * 4, 0xFFFF_FFFF)
    for i in range(1, NUM_SOURCES + 1):
        await bench.write(root + SOURCECFG + 4 * i, 0)
        await bench.write(root + TARGET + 4 * i, 1)
    for i in range(1, NUM_SOURCES + 1):
        await bench.write(root + SOURCECFG + 4 * i, SOURCECFG_D | 0)
    for hart in range(NUM_HARTS):
        await bench.write(idc_offset(ROOT, hart, IDELIVERY), 0)
        await bench.write(idc_offset(ROOT, hart, IFORCE), 0)
        await bench.write(idc_offset(ROOT, hart, ITHRESHOLD), 1)
    assert await bench.read(root + 0x1BC4) == 0, "mmsiaddrcfgh: not locked, no MSI"
    # Linux aplic_init_hw_irqs and aplic_direct_setup on the supervisor
    # domain (drivers/irqchip/irq-riscv-aplic-*.c).
    for i in range(0, NUM_SOURCES + 1, 32):
        await bench.write(sup + CLRIE + (i // 32) * 4, 0xFFFF_FFFF)
    for i in range(1, NUM_SOURCES + 1):
        await bench.write(sup + SOURCECFG + 4 * i, 0)
        await bench.write(sup + TARGET + 4 * i, 1)
    await bench.write(sup + DOMAINCFG, 0)
    for hart in range(NUM_HARTS):
        await bench.write(idc_offset(SUPERVISOR, hart, ITHRESHOLD), 0)
        await bench.write(idc_offset(SUPERVISOR, hart, IDELIVERY), 1)
    value = await bench.read(sup + DOMAINCFG) | (1 << 8)
    await bench.write(sup + DOMAINCFG, value)
    assert await bench.read(sup + DOMAINCFG) == value == 0x8000_0100
    # request_irq for each source: a level-high type, the affinity's target,
    # then unmask.
    for i in range(1, NUM_SOURCES + 1):
        await bench.write(sup + SOURCECFG + 4 * i, SM_LEVEL1)
        await bench.write(sup + TARGET + 4 * i, ((i % NUM_HARTS) << 18) | 1)
        await bench.write(sup + SETIENUM, i)
    # A device raises its line; the handler claims until zero, and the
    # device drops the line when serviced.
    for i in range(1, NUM_SOURCES + 1):
        hart = i % NUM_HARTS
        await bench.set_wire(i, 1)
        assert (int(dut.o_seip.value) >> hart) & 1
        assert int(dut.o_meip.value) == 0
        assert await bench.claim(SUPERVISOR, hart) == topi_value(i, 1)
        await bench.set_wire(i, 0)
        assert await bench.claim(SUPERVISOR, hart) == 0
        assert int(dut.o_seip.value) == 0


@cocotb.test()
async def test_random_against_model(dut: Any) -> None:
    """Random register traffic, claims and wire changes match the model."""
    bench = Bench(dut)
    await bench.start()
    rng = random.Random(int(os.environ.get("APLIC_SEED", "7")))
    operations = int(os.environ.get("APLIC_RANDOM_OPS", "3000"))

    def number() -> int:
        return rng.choice(
            (rng.randint(1, NUM_SOURCES), rng.randint(0, NUM_SOURCES + 2))
        )

    def hart() -> int:
        return (
            rng.randint(0, NUM_HARTS)
            if rng.random() < 0.1
            else rng.randrange(NUM_HARTS)
        )

    def write_op() -> tuple[int, int]:
        domain = rng.choice(DOMAINS)
        kind = rng.randrange(13)
        data = rng.getrandbits(32)
        n = number()
        if kind == 0:
            return reg_offset(domain, DOMAINCFG), rng.choice((0x100, 0, data & ~4))
        if kind <= 2:
            mode = rng.choice(SOURCE_MODES + (2, 3))
            if domain == ROOT and rng.random() < 0.4:
                return sourcecfg(ROOT, n), SOURCECFG_D | rng.choice((0, data & 0x3FF))
            return sourcecfg(domain, n), mode | (data & ~0x7FF) | (
                SOURCECFG_D if rng.random() < 0.05 else 0
            )
        if kind == 3:
            return target(domain, n), (hart() << 18) | rng.randint(0, MAX_PRIORITY + 1)
        if kind <= 5:
            reg = rng.choice((SETIPNUM, CLRIPNUM, SETIENUM, CLRIENUM, SETIPNUM_LE))
            return reg_offset(domain, reg), n
        if kind == 6:
            return reg_offset(domain, SETIPNUM_BE), byteswap32(n)
        if kind == 7:
            base = rng.choice((SETIP, IN_CLRIP, SETIE, CLRIE))
            word = rng.randrange(NUM_SOURCES // 32 + 2) % 32
            return reg_offset(domain, base + 4 * word), data
        if kind <= 9:
            word = rng.choice((IDELIVERY, IFORCE, ITHRESHOLD, TOPI, CLAIMI))
            value = rng.choice((0, 1, rng.randint(0, MAX_PRIORITY), data))
            return idc_offset(domain, hart(), word), value
        if kind == 10:
            return reg_offset(domain, GENMSI), data
        return rng.randrange(0, 0x1_0000, 4) | rng.choice((0, 0, 0x10_0000)), data

    for step in range(operations):
        choice = rng.random()
        if choice < 0.45:
            offset, data = write_op()
            if offset in (reg_offset(d, DOMAINCFG) for d in DOMAINS):
                data &= ~4  # this bench keeps random traffic in direct mode
            await bench.write(offset, data)
        elif choice < 0.6:
            await bench.set_wire(rng.randint(1, NUM_SOURCES), rng.randint(0, 1))
        elif choice < 0.75:
            await bench.claim(rng.choice(DOMAINS), rng.randrange(NUM_HARTS))
        else:
            domain = rng.choice(DOMAINS)
            reg = rng.choice(
                (
                    DOMAINCFG,
                    SOURCECFG + 4 * number(),
                    TARGET + 4 * number(),
                    SETIP + 4 * rng.randrange(NUM_SOURCES // 32 + 1),
                    IN_CLRIP + 4 * rng.randrange(NUM_SOURCES // 32 + 1),
                    SETIE + 4 * rng.randrange(NUM_SOURCES // 32 + 1),
                    IDC + 32 * hart() + rng.choice((0, 4, 8, 0x18, 0x1C)),
                )
            )
            await bench.read(reg_offset(domain, reg))
        if step % 500 == 0:
            dut._log.info(f"random step {step}")
