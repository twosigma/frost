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

"""Clocked APLIC MSI tests: every read pair, offered store and pin is modeled.

APLIC_* environment variables match the RTL parameters in the registry. The
direct-mode tests remain separate and run with and without MSI_ENABLE.
"""

import os
import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from cocotb_tests.aplic.aplic_model import (
    CLAIMI,
    CLRIE,
    CLRIENUM,
    CLRIPNUM,
    DOMAINCFG,
    GENMSI,
    IDC,
    IDELIVERY,
    IN_CLRIP,
    MMSIADDRCFG,
    MMSIADDRCFGH,
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
    SMSIADDRCFG,
    SMSIADDRCFGH,
    SOURCE_MODES,
    SOURCECFG_D,
    SUPERVISOR,
    TARGET,
    AplicModel,
    Msi,
    byteswap32,
    idc_offset,
    reg_offset,
)

NUM_SOURCES = int(os.environ.get("APLIC_NUM_SOURCES", "40"))
NUM_HARTS = int(os.environ.get("APLIC_NUM_HARTS", "2"))
IPRIOLEN = int(os.environ.get("APLIC_IPRIOLEN", "3"))
ADDR_WIDTH = int(os.environ.get("APLIC_MSI_ADDR_WIDTH", "56"))
CFG_RESET = tuple(
    int(os.environ.get(f"APLIC_{reg}_RESET", "0"))
    for reg in ("MMSIADDRCFG", "MMSIADDRCFGH", "SMSIADDRCFG", "SMSIADDRCFGH")
)
LOCKED_RESET = bool(CFG_RESET[1] & (1 << 31))


class MsiBench:
    """Sample both interfaces before each edge, then advance the model once."""

    def __init__(self, dut: Any) -> None:
        """Keep the DUT and a model with the registry shape."""
        self.dut = dut
        self.model = AplicModel(
            NUM_SOURCES,
            NUM_HARTS,
            IPRIOLEN,
            True,
            ADDR_WIDTH,
            (CFG_RESET[0], CFG_RESET[1], CFG_RESET[2], CFG_RESET[3]),
        )
        self.wires = 0
        self.ready = False
        self.sent: list[Msi] = []
        self.cycles = 0

    async def start(self) -> None:
        """Start the clock and apply system reset."""
        Clock(self.dut.i_clk, 10, unit="ns").start()
        await self.step(reset=True)
        await self.step(reset=True)
        await self.step()

    async def step(
        self,
        *,
        write: tuple[int, int] | None = None,
        read: int = 0,
        capture: bool = False,
        wires: int | None = None,
        ready: bool | None = None,
        reset: bool = False,
    ) -> int:
        """Drive one cycle and check every observable output."""
        await FallingEdge(self.dut.i_clk)
        if wires is not None:
            self.wires = wires
        if ready is not None:
            self.ready = ready
        self.dut.i_rst.value = int(reset)
        self.dut.i_src.value = self.wires
        self.dut.i_wr_en.value = int(write is not None)
        self.dut.i_wr_offset.value = write[0] if write else 0
        self.dut.i_wr_data.value = (write[1] & 0xFFFF_FFFF) if write else 0
        self.dut.i_rd_offset.value = read
        self.dut.i_rd_capture.value = int(capture)
        self.dut.i_msi_ready.value = int(self.ready)
        for number in range(1, NUM_SOURCES + 1):
            self.model.sources[number].wire = (self.wires >> (number - 1)) & 1
        await Timer(1, unit="ns")
        await ReadOnly()
        value = int(self.dut.o_rd_pair.value)
        if not reset:
            base = read & ~7
            expected = self.model.read(base) | (self.model.read(base + 4) << 32)
            assert value == expected, (
                f"cycle {self.cycles}, read {read:#x}: {value:#x} != {expected:#x}"
            )
            message = self.model.inflight
            assert int(self.dut.o_msi_valid.value) == int(message is not None), (
                f"valid at cycle {self.cycles}"
            )
            if message is not None:
                got = (int(self.dut.o_msi_addr.value), int(self.dut.o_msi_data.value))
                assert got == (message.address, message.data), (
                    f"MSI at cycle {self.cycles}: {got}, expected {message}"
                )
                assert got[0] < 1 << ADDR_WIDTH and got[0] & 0xFFF == 0
                if self.ready:
                    self.sent.append(message)
            lines = self.model.tick(
                write=write, capture=read if capture else None, ready=self.ready
            )
        else:
            assert not int(self.dut.o_msi_valid.value)
            self.model.reset()
            lines = (0, 0)
        await RisingEdge(self.dut.i_clk)
        await ReadOnly()
        assert (int(self.dut.o_meip.value), int(self.dut.o_seip.value)) == lines
        self.cycles += 1
        return (value >> 32) if read & 4 else value & 0xFFFF_FFFF

    async def write(self, offset: int, data: int) -> None:
        """Perform one register store."""
        await self.step(write=(offset, data))

    async def expect(self, offset: int, expected: int) -> None:
        """Compare a register with both the model and a directed value."""
        assert await self.step(read=offset) == expected, f"register {offset:#x}"

    async def pending(self, domain: int, number: int) -> bool:
        """Read a source pending bit."""
        word = await self.step(read=reg_offset(domain, SETIP + 4 * (number // 32)))
        return bool(word & (1 << (number % 32)))

    async def wire(self, number: int, value: int) -> None:
        """Drive one source wire for a cycle."""
        wires = (self.wires & ~(1 << (number - 1))) | (value << (number - 1))
        await self.step(wires=wires)

    async def mode(self, domain: int, *, enable: bool = True, msi: bool = True) -> None:
        """Set one domain delivery mode and global enable."""
        await self.write(
            reg_offset(domain, DOMAINCFG), (int(enable) << 8) | (int(msi) << 2)
        )

    async def activate(
        self,
        domain: int,
        number: int,
        mode: int = SM_DETACHED,
        hart: int = 0,
        eiid: int = 37,
    ) -> None:
        """Configure, target and enable one source."""
        if domain == SUPERVISOR:
            await self.write(4 * number, SOURCECFG_D)
        await self.write(reg_offset(domain, 4 * number), mode)
        await self.write(reg_offset(domain, TARGET + 4 * number), (hart << 18) | eiid)
        await self.write(reg_offset(domain, SETIENUM), number)

    async def drain(self, count: int = 0) -> None:
        """Accept all queued work and check the number of stores."""
        before = len(self.sent)
        for _ in range(4 * (NUM_SOURCES + 2) + 10):
            await self.step(ready=True)
            if self.model.inflight is None and self.model.choose_msi() is None:
                break
        else:
            raise AssertionError("forwarder did not drain")
        assert len(self.sent) - before == count


@cocotb.test()
async def test_msi_configuration(dut: Any) -> None:
    """Reset parameters, domain DM, all address fields, shared lock and S isolation."""
    b = MsiBench(dut)
    await b.start()
    for domain in (ROOT, SUPERVISOR):
        await b.expect(reg_offset(domain, DOMAINCFG), 0x80000000)
        await b.write(reg_offset(domain, DOMAINCFG), 0xFFFFFFFF)
        await b.expect(reg_offset(domain, DOMAINCFG), 0x80000104)
        await b.mode(domain, enable=False)
        await b.expect(reg_offset(domain, DOMAINCFG), 0x80000004)
    for index, reg in enumerate(range(MMSIADDRCFG, SMSIADDRCFGH + 4, 4)):
        initial = b.model.legal_msicfg(index, CFG_RESET[index])
        await b.expect(reg, initial)
        await b.write(reg_offset(SUPERVISOR, reg), 0xFFFFFFFF)
        await b.expect(reg_offset(SUPERVISOR, reg), 0)
        await b.expect(reg, initial)
    if not LOCKED_RESET:
        for value in (0xFFFFFFFF, 0xAAAAAAAA, 0x55555555, 0):
            for index, reg in enumerate(range(MMSIADDRCFG, SMSIADDRCFGH + 4, 4)):
                written = value & ~(1 << 31) if index == 1 else value
                await b.write(reg, written)
                await b.expect(reg, b.model.legal_msicfg(index, written))
        # Lock and write fields in the same beat; all four remain readable.
        await b.write(MMSIADDRCFG, 0x48000)
        await b.write(SMSIADDRCFG, 0x48100)
        await b.write(SMSIADDRCFGH, 2 << 20)
        await b.write(MMSIADDRCFGH, 0x80001000)
    values = b.model.msicfg.copy()
    for value in (0, 0xFFFFFFFF, 0x12345678):
        for reg in range(MMSIADDRCFG, SMSIADDRCFGH + 4, 4):
            await b.write(reg, value)
    for index, reg in enumerate(range(MMSIADDRCFG, SMSIADDRCFGH + 4, 4)):
        await b.expect(reg, values[index])
    await b.step(reset=True)
    for index, reg in enumerate(range(MMSIADDRCFG, SMSIADDRCFGH + 4, 4)):
        await b.expect(reg, b.model.legal_msicfg(index, CFG_RESET[index]))


@cocotb.test()
async def test_msi_targets_and_addresses(dut: Any) -> None:
    """Two harts in each domain, high PPN, low/high index groups, shifts and OR."""
    b = MsiBench(dut)
    await b.start()
    for d in (ROOT, SUPERVISOR):
        await b.mode(d)
    configs = [(CFG_RESET[0], CFG_RESET[1], CFG_RESET[2], CFG_RESET[3])]
    if not LOCKED_RESET:
        configs += [
            (0x48000, (1 << 12) | (3 << 20) | 0xABC, 0x48100, (2 << 20) | 0x123),
            (0xA0000, (1 << 16) | (1 << 24), 0xB0000, 7 << 20),
            # All low/high field widths and maximum shift; overlap uses OR.
            (0xFFFFFFFF, 0x7F77FFFF, 0xFFFFFFFF, 0x00700FFF),
        ]
    for cfg in configs:
        for reg, value in zip(range(MMSIADDRCFG, SMSIADDRCFGH + 4, 4), cfg):
            await b.write(reg, value)
        for d in (ROOT, SUPERVISOR):
            for hart in (0, 1):
                n = 1 + 2 * d + hart
                await b.activate(d, n, hart=hart, eiid=0x765)
                await b.write(reg_offset(d, TARGET + 4 * n), (hart << 18) | 0x3FFFF)
                await b.expect(reg_offset(d, TARGET + 4 * n), (hart << 18) | 0x7FF)
                await b.write(reg_offset(d, SETIPNUM), n)
                address = b.model.msi_address(d, hart)
                await b.drain(1)
                assert (b.sent[-1].address, b.sent[-1].data) == (address, 0x7FF)
                assert not await b.pending(d, n)
                # EIID zero is legal and emitted as zero, not coerced to one.
                await b.write(reg_offset(d, TARGET + 4 * n), hart << 18)
                await b.write(reg_offset(d, SETIPNUM), n)
                await b.drain(1)
                assert b.sent[-1].data == 0
                await b.step(ready=False)
    # Independent concrete formulas for the reset layout.
    if not LOCKED_RESET:
        for reg, value in zip(range(MMSIADDRCFG, SMSIADDRCFGH + 4, 4), CFG_RESET):
            await b.write(reg, value)
    assert b.model.msi_address(ROOT, 0) == 0x48000000
    assert b.model.msi_address(ROOT, 1) == 0x48001000
    assert b.model.msi_address(SUPERVISOR, 0) == 0x48100000
    assert b.model.msi_address(SUPERVISOR, 1) == 0x48101000


@cocotb.test()
async def test_msi_genmsi(dut: Any) -> None:
    """Busy, ignored writes, IE independence, EIID zero and ordered markers."""
    b = MsiBench(dut)
    await b.start()
    for d in (ROOT, SUPERVISOR):
        await b.write(reg_offset(d, GENMSI), 0xFFFFFFFF)
        await b.expect(reg_offset(d, GENMSI), 0)
        await b.mode(d, enable=False)
        value = (1 << 18) | 0x456
        await b.write(reg_offset(d, GENMSI), value | 0x3F800)
        await b.expect(reg_offset(d, GENMSI), value | (1 << 12))
        for _ in range(8):
            await b.write(reg_offset(d, GENMSI), 0)
        await b.expect(reg_offset(d, GENMSI), value | (1 << 12))
        # A write on the accepting edge still sees Busy and is ignored.
        await b.step(write=(reg_offset(d, GENMSI), 1), ready=True)
        await b.expect(reg_offset(d, GENMSI), value)
        assert b.sent[-1].data == 0x456
        await b.step(ready=False)
        await b.write(reg_offset(d, GENMSI), 0)
        await b.drain(1)
        assert b.sent[-1].data == 0
        await b.step(ready=False)
    await b.mode(ROOT)
    await b.activate(ROOT, 1, eiid=17)
    await b.write(SETIPNUM, 1)
    await b.step()
    await b.write(GENMSI, 19)
    await b.drain(2)
    assert [m.data for m in b.sent[-2:]] == [17, 19]


@cocotb.test()
async def test_msi_pending_modes(dut: Any) -> None:
    """Every source mode, both polarities, all set/clear forms and level rearming."""
    b = MsiBench(dut)
    await b.start()
    n = NUM_SOURCES
    bit = 1 << (n % 32)
    for d in (ROOT, SUPERVISOR):
        await b.mode(d, enable=False)
        for mode in SOURCE_MODES:
            await b.step(ready=False)
            await b.write(4 * n, SM_INACTIVE)
            inverted = int(mode in (SM_EDGE0, SM_LEVEL0))
            await b.wire(n, inverted)
            await b.activate(d, n, mode, eiid=n)
            for reg, value in (
                (SETIPNUM, n),
                (SETIPNUM_LE, n),
                (SETIPNUM_BE, byteswap32(n)),
                (SETIP + 4 * (n // 32), bit),
            ):
                await b.write(reg_offset(d, reg), value)
                assert await b.pending(d, n) == (
                    mode in (SM_DETACHED, SM_EDGE0, SM_EDGE1)
                )
                await b.write(reg_offset(d, CLRIPNUM), n)
            await b.wire(n, 1 - inverted)
            assert await b.pending(d, n) == (mode >= 4)
            if mode == SM_DETACHED:
                await b.write(reg_offset(d, SETIPNUM), n)
            if mode != SM_INACTIVE:
                # A captured claimi in MSI mode has no effect.
                assert await b.step(read=idc_offset(d, 0, CLAIMI), capture=True) == 0
                assert await b.pending(d, n)
                await b.mode(d)
                await b.drain(1)
                assert not await b.pending(d, n)
                for _ in range(5):
                    await b.step()
                assert not await b.pending(d, n), "held input must not send repeatedly"
                await b.mode(d, enable=False)
                # Linux's EOI rearm works only while a level input is high.
                for clear in (CLRIPNUM, IN_CLRIP + 4 * (n // 32)):
                    await b.write(reg_offset(d, SETIPNUM_LE), n)
                    assert await b.pending(d, n)
                    await b.write(reg_offset(d, clear), n if clear == CLRIPNUM else bit)
                    assert not await b.pending(d, n)
                await b.write(reg_offset(d, SETIPNUM), n)
                await b.wire(n, inverted)
                assert await b.pending(d, n) == (
                    mode in (SM_DETACHED, SM_EDGE0, SM_EDGE1)
                )
                await b.write(reg_offset(d, CLRIPNUM), n)
                if mode >= 4:
                    await b.wire(n, 1 - inverted)
                    assert await b.pending(d, n)
            await b.write(4 * n, SM_INACTIVE)


@cocotb.test()
async def test_msi_backpressure_and_reconfiguration(dut: Any) -> None:
    """Stable offers, selection retirement and writes during backpressure."""
    b = MsiBench(dut)
    await b.start()
    await b.mode(ROOT)
    await b.mode(SUPERVISOR)
    await b.activate(ROOT, 1, eiid=11)
    await b.write(SETIPNUM, 1)
    await b.step()
    for _ in range(20):
        assert not await b.pending(ROOT, 1)
    original = b.model.inflight
    assert original is not None
    await b.write(TARGET + 4, (1 << 18) | 12)
    if not LOCKED_RESET:
        await b.write(MMSIADDRCFG, 0x55000)
    await b.write(CLRIENUM, 1)
    await b.mode(ROOT, enable=False)
    await b.step(ready=True)
    assert b.sent[-1] == original
    assert not await b.pending(ROOT, 1)
    # A clear followed by a new set is a different pending episode.
    await b.step(ready=False)
    await b.write(SETIENUM, 1)
    await b.mode(ROOT)
    await b.write(SETIPNUM, 1)
    await b.step()
    await b.write(CLRIPNUM, 1)
    await b.write(SETIPNUM, 1)
    await b.step(ready=True)
    assert await b.pending(ROOT, 1)
    await b.drain(1)
    # A source handed to S while its old M store is stalled retains the new
    # S pending bit when that old store is accepted.
    await b.step(ready=False)
    await b.write(SETIPNUM, 1)
    await b.step()
    await b.activate(SUPERVISOR, 1, eiid=31)
    await b.write(reg_offset(SUPERVISOR, SETIPNUM), 1)
    await b.step(ready=True)
    assert await b.pending(SUPERVISOR, 1)
    await b.drain(1)
    assert b.sent[-1].domain == SUPERVISOR and b.sent[-1].data == 31


@cocotb.test()
async def test_msi_acceptance_collisions(dut: Any) -> None:
    """An edge or set on acceptance remains pending; a low level clears pending."""
    b = MsiBench(dut)
    await b.start()
    await b.mode(ROOT)
    for mode in (SM_DETACHED, SM_EDGE1, SM_EDGE0, SM_LEVEL1, SM_LEVEL0):
        await b.step(ready=False)
        await b.write(4, SM_INACTIVE)
        inverted = int(mode in (SM_EDGE0, SM_LEVEL0))
        await b.wire(1, inverted)
        await b.activate(ROOT, 1, mode)
        await b.wire(1, 1 - inverted)
        await b.write(SETIPNUM, 1)
        await b.step()
        await b.step(write=(SETIPNUM_LE, 1), ready=True)
        assert await b.pending(ROOT, 1), "set on acceptance remains pending"
        await b.drain(1)
        await b.step(ready=False)
        if mode in (SM_EDGE1, SM_EDGE0):
            await b.write(SETIPNUM, 1)
            await b.wire(1, inverted)
            await b.step(wires=1 - inverted, ready=True)
            assert await b.pending(ROOT, 1), "edge on acceptance remains pending"
            await b.drain(1)
        if mode in (SM_LEVEL1, SM_LEVEL0):
            await b.write(SETIPNUM, 1)
            await b.step()
            await b.wire(1, inverted)
            assert not await b.pending(ROOT, 1)
            await b.wire(1, 1 - inverted)
            await b.step(ready=True)
            assert await b.pending(ROOT, 1), "old episode cannot retire a new assertion"
            await b.drain(1)


@cocotb.test()
async def test_msi_sourcecfg_transitions(dut: Any) -> None:
    """Every pair of source modes, including writes that end a stalled episode."""
    b = MsiBench(dut)
    await b.start()
    for d in (ROOT, SUPERVISOR):
        await b.mode(d, enable=False)
        for old in SOURCE_MODES:
            for new in SOURCE_MODES:
                for wire in (0, 1):
                    await b.write(4, SM_INACTIVE)
                    await b.wire(1, wire)
                    await b.activate(d, 1, old)
                    await b.write(reg_offset(d, SETIPNUM), 1)
                    before = await b.pending(d, 1)
                    old_rect = wire ^ (old & 1) if old >= 4 else 0
                    new_rect = wire ^ (new & 1) if new >= 4 else 0
                    expected = before or bool(new_rect and not old_rect)
                    if new == SM_INACTIVE or (
                        new in (SM_LEVEL1, SM_LEVEL0) and not new_rect
                    ):
                        expected = False
                    await b.write(reg_offset(d, 4), new)
                    assert await b.pending(d, 1) == expected
        await b.write(4, SM_INACTIVE)
    await b.mode(ROOT)
    await b.wire(1, 0)
    await b.activate(ROOT, 1)
    await b.write(SETIPNUM, 1)
    await b.step()
    # The sourcecfg write itself clears pending under the new level mode.
    # A rising wire in the immediately following cycle starts a new episode.
    await b.write(4, SM_LEVEL1)
    await b.wire(1, 1)
    await b.step(ready=True)
    assert await b.pending(ROOT, 1)
    await b.drain(1)


@cocotb.test()
async def test_msi_fairness(dut: Any) -> None:
    """Every continuously eligible source and both generators get a bounded turn."""
    b = MsiBench(dut)
    await b.start()
    for d in (ROOT, SUPERVISOR):
        await b.mode(d, enable=False)
    for n in range(1, NUM_SOURCES + 1):
        d = n % 2
        await b.activate(d, n, eiid=n)
        await b.write(reg_offset(d, SETIPNUM), n)
    for d in (ROOT, SUPERVISOR):
        await b.mode(d)
        await b.write(reg_offset(d, GENMSI), 1000 + d)
    rng = random.Random(73)
    last_seen = {slot: 0 for slot in range(NUM_SOURCES + 2)}
    for _ in range(20 * (NUM_SOURCES + 2)):
        message = b.model.inflight
        write = None
        if message is not None and message.slot < NUM_SOURCES:
            write = (reg_offset(message.domain, SETIPNUM), message.slot + 1)
        elif message is None:
            for d in (0, 1):
                if not b.model.genmsi[d] & (1 << 12):
                    write = (reg_offset(d, GENMSI), 1000 + d)
                    break
        count = len(b.sent)
        await b.step(write=write, ready=rng.randrange(4) != 0)
        if len(b.sent) != count:
            slot = b.sent[-1].slot
            assert len(b.sent) - last_seen[slot] <= NUM_SOURCES + 3
            last_seen[slot] = len(b.sent)
    assert min(last_seen.values()) > 2 * (NUM_SOURCES + 2)


@cocotb.test()
async def test_msi_mode_changes(dut: Any) -> None:
    """Mixed delivery, retained IDC and target state, delegation, and reset in flight."""
    b = MsiBench(dut)
    await b.start()
    await b.activate(ROOT, 1, SM_LEVEL1, eiid=3)
    await b.mode(ROOT, msi=False)
    await b.write(idc_offset(ROOT, 0, IDELIVERY), 1)
    await b.wire(1, 1)
    await b.step()
    assert int(dut.o_meip.value) == 1
    await b.mode(SUPERVISOR)
    await b.activate(SUPERVISOR, 2, eiid=42)
    await b.write(reg_offset(SUPERVISOR, SETIPNUM), 2)
    await b.drain(1)
    assert int(dut.o_meip.value) == 1
    await b.step(ready=False)
    await b.mode(ROOT)
    await b.expect(idc_offset(ROOT, 0, IDELIVERY), 0)
    await b.write(idc_offset(ROOT, 0, IDELIVERY), 0)
    await b.expect(TARGET + 4, 1)  # retained MSI EIID, reset to 1
    await b.drain(1)
    assert not await b.pending(ROOT, 1)
    await b.mode(ROOT, msi=False)
    await b.expect(idc_offset(ROOT, 0, IDELIVERY), 1)
    await b.expect(TARGET + 4, 3)
    assert await b.pending(ROOT, 1)
    await b.write(4, SM_DETACHED)
    await b.write(CLRIPNUM, 1)
    await b.step(ready=False)
    await b.mode(ROOT)
    await b.write(SETIPNUM, 1)
    await b.step()
    assert not await b.pending(ROOT, 1)
    await b.mode(ROOT, msi=False)
    await b.write(SETIPNUM, 1)
    await b.step(ready=True)
    assert await b.pending(ROOT, 1), "old MSI cannot clear direct-mode pending state"
    await b.write(CLRIPNUM, 1)
    await b.mode(ROOT)
    await b.step(ready=False)
    await b.write(GENMSI, 72)
    await b.step()
    await b.step(reset=True, ready=True, write=(GENMSI, 73))
    await b.expect(GENMSI, 0)
    assert b.model.inflight is None


@cocotb.test()
async def test_msi_offer_after_mask_and_ie_clear(dut: Any) -> None:
    """AIA 4.9: forwarding requires pending, source enable and domain IE."""
    b = MsiBench(dut)
    await b.start()
    await b.mode(ROOT)
    await b.activate(ROOT, 1, eiid=11)
    await b.write(SETIPNUM, 1)
    await b.step()
    await b.write(CLRIENUM, 1)
    await b.mode(ROOT, enable=False)
    await b.expect(SETIE, 0)
    pending = await b.pending(ROOT, 1)
    await b.step(ready=True)
    assert b.sent[-1].data == 11
    assert await b.pending(ROOT, 1) == pending, (
        "acceptance cannot retire a disabled source"
    )
    assert not pending, (
        "the pending interrupt was forwarded when the offer was selected"
    )


@cocotb.test()
async def test_msi_set_after_stalled_retarget(dut: Any) -> None:
    """A set after mask and retarget must reach the new hart and EIID."""
    b = MsiBench(dut)
    await b.start()
    for set_reg in (SETIP, SETIPNUM):
        await b.step(ready=False)
        await b.mode(ROOT)
        await b.activate(ROOT, 1, hart=0, eiid=11)
        await b.write(SETIPNUM, 1)
        await b.step()
        old_address = b.model.msi_address(ROOT, 0)
        await b.write(CLRIENUM, 1)
        await b.write(TARGET + 4, (1 << 18) | 12)
        await b.write(set_reg, 2 if set_reg == SETIP else 1)
        await b.step(ready=True)
        assert (b.sent[-1].address, b.sent[-1].data) == (old_address, 11)
        assert await b.pending(ROOT, 1), (
            "the set during the stall must survive acceptance"
        )
        await b.step(ready=False)
        await b.write(SETIENUM, 1)
        await b.drain(1)
        assert (b.sent[-1].address, b.sent[-1].data) == (
            b.model.msi_address(ROOT, 1),
            12,
        )


@cocotb.test()
async def test_msi_selection_collisions(dut: Any) -> None:
    """A software set or rising edge on the selection edge wins over retirement."""
    b = MsiBench(dut)
    await b.start()
    for mode in (SM_DETACHED, SM_EDGE1, SM_EDGE0, SM_LEVEL1, SM_LEVEL0):
        inverted = int(mode in (SM_EDGE0, SM_LEVEL0))
        await b.step(reset=True, wires=inverted, ready=False)
        await b.step()
        await b.mode(ROOT)
        await b.activate(ROOT, 1, mode)
        if mode == SM_DETACHED:
            await b.write(SETIPNUM, 1)
        else:
            await b.wire(1, 1 - inverted)
        await b.write(SETIPNUM_LE, 1)  # selection and a new set on the same edge
        assert await b.pending(ROOT, 1)
        await b.drain(2)
        if mode in (SM_EDGE1, SM_EDGE0):
            await b.step(ready=False)
            await b.wire(1, inverted)
            await b.write(SETIPNUM, 1)
            await b.wire(1, 1 - inverted)  # selection and a rising rectified input
            assert await b.pending(ROOT, 1)
            await b.drain(2)


@cocotb.test()
async def test_genmsi_delivery_mode_change(dut: Any) -> None:
    """Direct mode reads zero and ignores writes; a queued marker still completes."""
    b = MsiBench(dut)
    await b.start()
    for domain in (ROOT, SUPERVISOR):
        await b.step(ready=False)
        await b.mode(domain)
        await b.activate(domain, 1, eiid=11)
        await b.write(reg_offset(domain, SETIPNUM), 1)
        await b.step()  # stall a source so the marker cannot yet be selected
        await b.write(reg_offset(domain, GENMSI), 71)
        await b.mode(domain, msi=False)
        await b.expect(reg_offset(domain, GENMSI), 0)
        await b.write(reg_offset(domain, GENMSI), 72)
        await b.drain(2)
        assert [m.data for m in b.sent[-2:]] == [11, 71]
        await b.mode(domain)
        await b.expect(reg_offset(domain, GENMSI), 71)
        await b.drain(0)
        await b.step(ready=False)
        await b.write(reg_offset(domain, GENMSI), 73)
        await b.step()  # an offered marker also survives a switch to direct mode
        await b.mode(domain, msi=False)
        await b.expect(reg_offset(domain, GENMSI), 0)
        await b.drain(1)
        assert b.sent[-1].data == 73


@cocotb.test()
async def test_msi_firmware_and_kernel_setup(dut: Any) -> None:
    """OpenSBI address setup and delegation, then Linux target and level EOI writes."""
    b = MsiBench(dut)
    await b.start()
    # OpenSBI clears sources and targets before configuring delegation and
    # the root MSI addresses from the IMSIC layout in the device tree.
    await b.write(DOMAINCFG, 0)
    for n in range(1, NUM_SOURCES + 1):
        await b.write(4 * n, 0)
        await b.write(TARGET + 4 * n, 1)
        await b.write(4 * n, SOURCECFG_D)
    for reg, value in (
        (MMSIADDRCFG, 0x48000),
        (MMSIADDRCFGH, 0x1000),
        (SMSIADDRCFG, 0x48100),
        (SMSIADDRCFGH, 0x1000),
    ):
        await b.write(reg, value)
    await b.mode(ROOT)
    # Linux initializes the S domain in direct mode, then selects MSI mode.
    for n in range(0, NUM_SOURCES + 1, 32):
        await b.write(reg_offset(SUPERVISOR, CLRIE + (n // 32) * 4), 0xFFFFFFFF)
    for n in range(1, NUM_SOURCES + 1):
        await b.write(reg_offset(SUPERVISOR, 4 * n), 0)
        await b.write(reg_offset(SUPERVISOR, TARGET + 4 * n), 1)
    await b.write(reg_offset(SUPERVISOR, DOMAINCFG), 0)
    await b.mode(SUPERVISOR)
    n = NUM_SOURCES
    target = reg_offset(SUPERVISOR, TARGET + 4 * n)
    await b.write(target, (1 << 18) | 33)
    await b.expect(target, 0)  # target writes while inactive take effect on activation
    await b.wire(n, 1)
    await b.write(reg_offset(SUPERVISOR, 4 * n), SM_LEVEL1)
    await b.write(reg_offset(SUPERVISOR, SETIPNUM_LE), n)
    await b.expect(target, (1 << 18) | 33)
    await b.write(reg_offset(SUPERVISOR, SETIENUM), n)
    await b.drain(1)
    assert (b.sent[-1].address, b.sent[-1].data) == (0x48101000, 33)
    assert not await b.pending(SUPERVISOR, n)
    # EOI while the level is still high requests another delivery.
    await b.write(reg_offset(SUPERVISOR, SETIPNUM_LE), n)
    await b.drain(1)
    await b.wire(n, 0)
    await b.write(reg_offset(SUPERVISOR, SETIPNUM_LE), n)
    await b.drain(0)
    assert not await b.pending(SUPERVISOR, n)


@cocotb.test()
async def test_msi_random_model(dut: Any) -> None:
    """Random wires, reads, claims, writes, delivery modes and ready each cycle."""
    b = MsiBench(dut)
    await b.start()
    rng = random.Random(int(os.environ.get("APLIC_SEED", "19")))
    for d in (ROOT, SUPERVISOR):
        await b.mode(d)
    for n in range(1, NUM_SOURCES + 1):
        await b.activate(n % 2, n, rng.choice(SOURCE_MODES[1:]), hart=n % 2, eiid=n)
    for cycle in range(int(os.environ.get("APLIC_RANDOM_OPS", "12000"))):
        d = rng.randrange(2)
        n = rng.randint(1, NUM_SOURCES)
        reg, value = rng.choice(
            (
                (4 * n, rng.choice(SOURCE_MODES + (2, 3, SOURCECFG_D))),
                (TARGET + 4 * n, rng.getrandbits(32)),
                (DOMAINCFG, rng.choice((0x104, 0x104, 0x100, 4, 0))),
                (SETIPNUM, n),
                (SETIPNUM_LE, n),
                (SETIPNUM_BE, byteswap32(n)),
                (CLRIPNUM, n),
                (SETIENUM, n),
                (CLRIENUM, n),
                (SETIP + 4 * (n // 32), rng.getrandbits(32)),
                (IN_CLRIP + 4 * (n // 32), rng.getrandbits(32)),
                (SETIE + 4 * (n // 32), rng.getrandbits(32)),
                (CLRIE + 4 * (n // 32), rng.getrandbits(32)),
                (GENMSI, rng.getrandbits(32)),
                (MMSIADDRCFG + 4 * rng.randrange(4), rng.getrandbits(31)),
                (
                    IDC + 32 * rng.randrange(NUM_HARTS) + rng.choice((0, 4, 8)),
                    rng.getrandbits(32),
                ),
            )
        )
        read = rng.choice(
            (
                reg_offset(d, reg),
                reg_offset(d, SETIP + 4 * (n // 32)),
                idc_offset(d, 0, CLAIMI),
                reg_offset(d, GENMSI),
                rng.randrange(0, 0x10000, 4),
            )
        )
        await b.step(
            write=(reg_offset(d, reg), value) if rng.random() < 0.85 else None,
            read=read,
            capture=rng.random() < 0.25,
            wires=rng.getrandbits(NUM_SOURCES) if rng.random() < 0.2 else b.wires,
            ready=rng.random() < 0.65,
        )
        if cycle % 3000 == 0:
            dut._log.info("MSI random cycle %d, %d accepted stores", cycle, len(b.sent))
    assert len(b.sent) > 50
    for offset in range(0, 0x10000, 8):
        await b.step(read=offset)
