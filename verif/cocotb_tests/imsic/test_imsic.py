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

"""Unit tests for the IMSIC (hw/rtl/peripherals/imsic/imsic.sv).

The bench drives the memory-mapped write port as the SoC will, with 32-bit
stores by physical address, and each interrupt file's hart-side port as a
CSR file will: an *iselect value, *ireg writes in the Zicsr keep/set form,
and *topei claims. Every cycle it compares each file's *ireg read, illegal
flag and *topei with the cycle-level model in imsic_model.py, and after
every clock edge both interrupt lines of every hart; the directed tests also
check the values the AIA specification gives. A file reports *topei a cycle
behind its registers, so the directed tests, like the CPU, leave a cycle
after each write or claim; the random test does not, and the model checks
every cycle of it. IMSIC_NUM_HARTS,
IMSIC_NUM_IDS, IMSIC_APLIC_DELIVERY, IMSIC_M_BASE_ADDR and IMSIC_S_BASE_ADDR
must match the -G parameters of the build (test_run_cocotb.py sets both).
"""

import os
import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from cocotb_tests.imsic.imsic_model import (
    EIDELIVERY,
    EIDELIVERY_APLIC,
    EIE0,
    EIP0,
    EITHRESHOLD,
    LEVELS,
    MACHINE,
    MASK64,
    PAGE_BYTES,
    SETEIPNUM_BE,
    SETEIPNUM_LE,
    SUPERVISOR,
    CsrAccess,
    ImsicModel,
    byteswap32,
    topei_value,
)

NUM_HARTS = int(os.environ.get("IMSIC_NUM_HARTS", "1"))
NUM_IDS = int(os.environ.get("IMSIC_NUM_IDS", "63"))
APLIC_DELIVERY = os.environ.get("IMSIC_APLIC_DELIVERY", "1") == "1"
M_BASE = int(os.environ.get("IMSIC_M_BASE_ADDR", "0x48000000"), 0)
S_BASE = int(os.environ.get("IMSIC_S_BASE_ADDR", "0x48100000"), 0)
ID_BITS = NUM_IDS.bit_length()
NUM_WORDS = (NUM_IDS + 1) // 64
FILES = [(level, hart) for level in LEVELS for hart in range(NUM_HARTS)]
PREFIX = {MACHINE: "m", SUPERVISOR: "s"}
SETTLE_CYCLES = 3  # a write's effects reach the registered interrupt lines
# eidelivery after reset, and after a write of 0x40000000.
EIDELIVERY_RESET = EIDELIVERY_APLIC if APLIC_DELIVERY else 0


def eip_select(identity: int) -> int:
    """*iselect of the eip register holding an identity (RV64)."""
    return EIP0 + 2 * (identity // 64)


def eie_select(identity: int) -> int:
    """*iselect of the eie register holding an identity (RV64)."""
    return EIE0 + 2 * (identity // 64)


def sample_identities() -> list[int]:
    """Identities to try one by one: all of them, or a spread of 2047."""
    if NUM_IDS <= 255:
        return list(range(1, NUM_IDS + 1))
    rng = random.Random(NUM_IDS)
    picked = set(range(1, 70)) | set(range(NUM_IDS - 69, NUM_IDS + 1))
    picked |= set(rng.sample(range(70, NUM_IDS - 69), 120))
    picked |= {64 * k for k in range(1, NUM_WORDS)} | {
        64 * k - 1 for k in range(1, NUM_WORDS)
    }
    return sorted(picked)


class Bench:
    """Drives the IMSIC and checks every observation against the model."""

    def __init__(self, dut: Any) -> None:
        """Keep the DUT and a model in its reset state."""
        self.dut = dut
        self.model = ImsicModel(NUM_HARTS, NUM_IDS, M_BASE, S_BASE, APLIC_DELIVERY)
        self.selects = dict.fromkeys(FILES, 0)
        self.aplic = [0, 0]  # APLIC lines by level, bit h for hart h

    def port(self, name: str, level: int) -> Any:
        """Return a level's port, i_m_iselect or i_s_iselect and so on."""
        return getattr(self.dut, name.replace("*", PREFIX[level]))

    async def start(self) -> None:
        """Start the clock and reset the DUT."""
        assert len(self.dut.o_meip) == NUM_HARTS, (
            "IMSIC_NUM_HARTS differs from the build"
        )
        assert len(self.dut.o_m_ireg) == 64 * NUM_HARTS
        Clock(self.dut.i_clk, 10, unit="ns").start()
        self.dut.i_rst.value = 1
        self._drive(None, {})
        for _ in range(3):
            await RisingEdge(self.dut.i_clk)
        await FallingEdge(self.dut.i_clk)
        self.dut.i_rst.value = 0
        self.model.reset()
        self.check_lines()
        await self.idle(SETTLE_CYCLES)

    def _drive(
        self, write: tuple[int, int] | None, accesses: dict[tuple[int, int], CsrAccess]
    ) -> None:
        """Drive one cycle's inputs; files without an access hold their select."""
        self.dut.i_wr_en.value = int(write is not None)
        address, data = write if write is not None else (0, 0)
        self.dut.i_wr_addr.value = address & 0xFFFF_FFFF
        self.dut.i_wr_data.value = data & 0xFFFF_FFFF
        for level in LEVELS:
            iselect = we = keep = set_ = claim = 0
            for hart in range(NUM_HARTS):
                access = accesses.get((level, hart))
                if access is None:
                    access = CsrAccess(select=self.selects[(level, hart)])
                self.selects[(level, hart)] = access.select
                iselect |= access.select << (8 * hart)
                we |= int(access.write) << hart
                keep |= (access.keep & MASK64) << (64 * hart)
                set_ |= (access.set_ & MASK64) << (64 * hart)
                claim |= int(access.claim) << hart
            self.port("i_*_iselect", level).value = iselect
            self.port("i_*_ireg_we", level).value = we
            self.port("i_*_ireg_keep", level).value = keep
            self.port("i_*_ireg_set", level).value = set_
            self.port("i_*_topei_claim", level).value = claim
        self.dut.i_aplic_meip.value = self.aplic[MACHINE]
        self.dut.i_aplic_seip.value = self.aplic[SUPERVISOR]

    def check_lines(self) -> None:
        """Compare every hart's MEIP and SEIP with the model."""
        for level, name in ((MACHINE, "o_meip"), (SUPERVISOR, "o_seip")):
            lines = int(getattr(self.dut, name).value)
            for hart in range(NUM_HARTS):
                expected = self.model.files[level][hart].line()
                assert (lines >> hart) & 1 == expected, (
                    f"{name}[{hart}] is {(lines >> hart) & 1}, model {expected}"
                )

    async def cycle(
        self,
        write: tuple[int, int] | None = None,
        accesses: dict[tuple[int, int], CsrAccess] | None = None,
    ) -> dict[tuple[int, int], tuple[int, int]]:
        """One clock cycle from a falling edge; return each file's (ireg, topei).

        The reads are taken before the rising edge and checked against the
        model, which then takes the edge; the lines are checked after it.
        """
        accesses = accesses or {}
        self._drive(write, accesses)
        await ReadOnly()
        samples = {}
        for level in LEVELS:
            ireg = int(self.port("o_*_ireg", level).value)
            illegal = int(self.port("o_*_ireg_illegal", level).value)
            topei = int(self.port("o_*_topei", level).value)
            for hart in range(NUM_HARTS):
                interrupt_file = self.model.files[level][hart]
                select = self.selects[(level, hart)]
                value = (ireg >> (64 * hart)) & MASK64
                top = (topei >> (32 * hart)) & 0xFFFF_FFFF
                where = f"{PREFIX[level]}-level file of hart {hart}"
                assert value == interrupt_file.read(select), (
                    f"{where}: select 0x{select:02x} reads 0x{value:016x}, "
                    f"model 0x{interrupt_file.read(select):016x}"
                )
                assert (illegal >> hart) & 1 == interrupt_file.illegal(select), (
                    f"{where}: select 0x{select:02x} illegal flag"
                )
                assert top == interrupt_file.topei(), (
                    f"{where}: topei 0x{top:08x}, model 0x{interrupt_file.topei():08x}"
                )
                samples[(level, hart)] = (value, top)
        await RisingEdge(self.dut.i_clk)
        self.model.clock(write, accesses, (self.aplic[MACHINE], self.aplic[SUPERVISOR]))
        await FallingEdge(self.dut.i_clk)
        self.check_lines()
        return samples

    async def idle(self, cycles: int = 1) -> None:
        """Cycles with no write and no hart-side activity."""
        for _ in range(cycles):
            await self.cycle()

    async def settle(self) -> None:
        """Let a write reach its file and the interrupt lines."""
        await self.idle(SETTLE_CYCLES)

    # -- operations ----------------------------------------------------------

    async def mmio_write(self, address: int, data: int) -> None:
        """One 32-bit store, then the settling cycles."""
        await self.cycle(write=(address, data))
        await self.settle()

    async def msi(
        self, level: int, hart: int, identity: int, big_endian: bool = False
    ) -> None:
        """Send an MSI to a file's seteipnum_le or seteipnum_be."""
        page = self.model.page_address(level, hart)
        if big_endian:
            await self.mmio_write(page + SETEIPNUM_BE, byteswap32(identity))
        else:
            await self.mmio_write(page + SETEIPNUM_LE, identity)

    async def access(self, level: int, hart: int, access: CsrAccess) -> tuple[int, int]:
        """One hart-side access; return the (ireg, topei) read with it.

        A write or claim is followed by an idle cycle, as the CPU leaves one
        between CSR accesses, so the next access sees *topei after it.
        """
        samples = await self.cycle(accesses={(level, hart): access})
        if access.write or access.claim:
            await self.idle()
        return samples[(level, hart)]

    async def read(self, level: int, hart: int, select: int) -> int:
        """Read a register through *ireg."""
        value, _ = await self.access(level, hart, CsrAccess(select=select))
        return value

    async def csrrw(self, level: int, hart: int, select: int, value: int) -> int:
        """Write a register through *ireg; return the old value."""
        old, _ = await self.access(level, hart, CsrAccess(select, True, 0, value))
        return old

    async def csrrs(self, level: int, hart: int, select: int, mask: int) -> int:
        """Set bits of a register through *ireg; return the old value."""
        old, _ = await self.access(level, hart, CsrAccess(select, True, MASK64, mask))
        return old

    async def csrrc(self, level: int, hart: int, select: int, mask: int) -> int:
        """Clear bits of a register through *ireg; return the old value."""
        old, _ = await self.access(
            level, hart, CsrAccess(select, True, ~mask & MASK64, 0)
        )
        return old

    async def claim(self, level: int, hart: int) -> int:
        """Claim with csrrw *topei: return the value read, which the write claims."""
        _, topei = await self.access(
            level, hart, CsrAccess(self.selects[(level, hart)], claim=True)
        )
        return topei

    async def topei(self, level: int, hart: int) -> int:
        """Read *topei without claiming."""
        _, topei = await self.access(
            level, hart, CsrAccess(self.selects[(level, hart)])
        )
        return topei

    async def sweep(self) -> None:
        """Read every select of every file, all files at once."""
        for select in range(256):
            await self.cycle(accesses={key: CsrAccess(select=select) for key in FILES})

    async def deliver(self, level: int, hart: int, threshold: int = 0) -> None:
        """Let a file deliver: eithreshold, then eidelivery 1."""
        await self.csrrw(level, hart, EITHRESHOLD, threshold)
        await self.csrrw(level, hart, EIDELIVERY, 1)

    async def enable(self, level: int, hart: int, identities: list[int]) -> None:
        """Set the enable bits of identities with csrrs."""
        for identity in identities:
            await self.csrrs(level, hart, eie_select(identity), 1 << (identity % 64))

    async def enable_all(self, level: int, hart: int) -> None:
        """Enable every identity of a file."""
        for word in range(NUM_WORDS):
            await self.csrrw(level, hart, EIE0 + 2 * word, MASK64)

    async def expect_read(self, level: int, hart: int, select: int, value: int) -> None:
        """Check a register against a value the spec gives."""
        got = await self.read(level, hart, select)
        assert got == value, (
            f"select 0x{select:02x} reads 0x{got:016x}, expected 0x{value:016x}"
        )

    async def expect_topei(self, level: int, hart: int, identity: int) -> None:
        """Check *topei against an identity the spec gives (0 for none)."""
        got = await self.topei(level, hart)
        assert got == topei_value(identity), (
            f"topei 0x{got:08x}, expected identity {identity}"
        )

    def line(self, level: int, hart: int) -> int:
        """Return a hart's MEIP or SEIP as the DUT drives it now."""
        lines = int((self.dut.o_meip if level == MACHINE else self.dut.o_seip).value)
        return (lines >> hart) & 1


@cocotb.test()
async def test_reset_values(dut: Any) -> None:
    """Every register of every file reads its reset value; the lines are low."""
    bench = Bench(dut)
    await bench.start()
    await bench.sweep()
    for level, hart in FILES:
        await bench.expect_read(level, hart, EIDELIVERY, EIDELIVERY_RESET)
        await bench.expect_read(level, hart, EITHRESHOLD, 0)
        await bench.expect_topei(level, hart, 0)
        assert bench.line(level, hart) == 0


@cocotb.test()
async def test_select_map(dut: Any) -> None:
    """Only eidelivery, eithreshold and the even eip and eie selects hold state.

    Writing all ones and then zeros to each of the 256 selects of every file
    changes exactly the registers the spec maps there. Odd selects from 0x81
    are illegal at XLEN 64; the reserved selects 0x71 and 0x73-0x7F and those
    below 0x70 read zero and are not illegal.
    """
    bench = Bench(dut)
    await bench.start()
    for value in (MASK64, 0, 0x5555_5555_5555_5555):
        for select in range(256):
            await bench.cycle(
                accesses={key: CsrAccess(select, True, 0, value) for key in FILES}
            )
        await bench.sweep()
    for level, hart in FILES:
        for select in (0x30, 0x6F, 0x71, 0x73, 0x7F):
            await bench.expect_read(level, hart, select, 0)
    # After all ones: bit 0 of eip0 and the bits above NUM_IDS stay zero, and
    # eithreshold keeps ID_BITS bits.
    for select in range(256):
        await bench.cycle(
            accesses={key: CsrAccess(select, True, 0, MASK64) for key in FILES}
        )
    for level, hart in FILES:
        await bench.expect_read(level, hart, EIP0, MASK64 - 1)
        await bench.expect_read(level, hart, EIE0, MASK64 - 1)
        await bench.expect_read(
            level, hart, EIP0 + 2 * NUM_WORDS - 2, MASK64 - (NUM_WORDS == 1)
        )
        if NUM_WORDS < 32:
            await bench.expect_read(level, hart, EIP0 + 2 * NUM_WORDS, 0)
            await bench.expect_read(level, hart, EIE0 + 2 * NUM_WORDS, 0)
        await bench.expect_read(level, hart, EITHRESHOLD, (1 << ID_BITS) - 1)
        await bench.expect_read(level, hart, EIDELIVERY, EIDELIVERY_RESET or 1)
        for select in (0x81, 0xBF, 0xC1, 0xFF):
            await bench.expect_read(level, hart, select, 0)


@cocotb.test()
async def test_eidelivery(dut: Any) -> None:
    """Eidelivery holds 0, 1 or, where supported, 0x40000000 (WARL)."""
    bench = Bench(dut)
    await bench.start()
    aplic = EIDELIVERY_APLIC if APLIC_DELIVERY else None
    for level, hart in FILES:
        for written, expected in (
            (1, 1),
            (0, 0),
            (EIDELIVERY_APLIC, aplic or 0),
            (EIDELIVERY_APLIC | 1, aplic or 1),
            (MASK64, aplic or 1),
            (2, 0),
            (0x8000_0000_0000_0001, 1),
            (0xBFFF_FFFF, 1),
        ):
            await bench.csrrw(level, hart, EIDELIVERY, written)
            await bench.expect_read(level, hart, EIDELIVERY, expected)
        # The set and clear forms work on the value read.
        await bench.csrrw(level, hart, EIDELIVERY, 0)
        await bench.csrrs(level, hart, EIDELIVERY, 1)
        await bench.expect_read(level, hart, EIDELIVERY, 1)
        await bench.csrrc(level, hart, EIDELIVERY, 1)
        await bench.expect_read(level, hart, EIDELIVERY, 0)
        await bench.csrrs(level, hart, EIDELIVERY, EIDELIVERY_APLIC)
        await bench.expect_read(level, hart, EIDELIVERY, aplic or 0)


@cocotb.test()
async def test_delivery_and_lines(dut: Any) -> None:
    """A line follows its file with eidelivery 1, the APLIC with 0x40000000.

    With eidelivery 0 it stays low, whatever is pending; eidelivery does not
    change *topei.
    """
    bench = Bench(dut)
    await bench.start()
    for level, hart in FILES:
        identity = min(5, NUM_IDS)
        await bench.enable(level, hart, [identity])
        await bench.csrrw(level, hart, EIDELIVERY, 0)
        await bench.msi(level, hart, identity)
        await bench.expect_topei(level, hart, identity)
        assert bench.line(level, hart) == 0, "eidelivery 0 holds the line low"
        await bench.csrrw(level, hart, EIDELIVERY, 1)
        await bench.settle()
        assert bench.line(level, hart) == 1
        # Disabling the identity, or a threshold at it, drops the line.
        await bench.csrrc(level, hart, eie_select(identity), 1 << (identity % 64))
        await bench.settle()
        assert bench.line(level, hart) == 0
        await bench.enable(level, hart, [identity])
        await bench.csrrw(level, hart, EITHRESHOLD, identity)
        await bench.settle()
        assert bench.line(level, hart) == 0
        await bench.csrrw(level, hart, EITHRESHOLD, identity + 1)
        await bench.settle()
        assert bench.line(level, hart) == 1
        # The APLIC's line, with this file's own interrupt still pending.
        bench.aplic[level] |= 1 << hart
        await bench.csrrw(level, hart, EIDELIVERY, EIDELIVERY_APLIC)
        await bench.settle()
        assert bench.line(level, hart) == int(APLIC_DELIVERY)
        bench.aplic[level] &= ~(1 << hart)
        await bench.settle()
        assert bench.line(level, hart) == 0
        await bench.expect_topei(level, hart, identity)
        # The other harts' and the other level's lines never moved; the model
        # checks them every cycle. Clean up.
        assert await bench.claim(level, hart) == topei_value(identity)
        await bench.csrrw(level, hart, EIDELIVERY, 0)


@cocotb.test()
async def test_eithreshold(dut: Any) -> None:
    """Eithreshold P hides identities P and above; zero hides none (WLRL)."""
    bench = Bench(dut)
    await bench.start()
    level, hart = FILES[-1]
    await bench.enable_all(level, hart)
    await bench.deliver(level, hart)
    identities = {1, 2, 63, 64, NUM_IDS // 2, NUM_IDS - 1, NUM_IDS}
    for identity in sorted(identities & set(range(1, NUM_IDS + 1))):
        await bench.msi(level, hart, identity)
        for threshold, visible in (
            (0, True),
            (identity, False),
            (identity + 1, True),
            (1, False),
            (NUM_IDS, identity < NUM_IDS),
        ):
            await bench.csrrw(level, hart, EITHRESHOLD, threshold)
            await bench.settle()
            await bench.expect_topei(level, hart, identity if visible else 0)
            assert bench.line(level, hart) == int(visible)
        await bench.csrrw(level, hart, EITHRESHOLD, 0)
        assert await bench.claim(level, hart) == topei_value(identity)
    # The register holds every value from 0 to NUM_IDS and keeps ID_BITS bits.
    for value in (0, 1, NUM_IDS, (1 << ID_BITS) - 1, (1 << ID_BITS) | 5, MASK64):
        await bench.csrrw(level, hart, EITHRESHOLD, value)
        await bench.expect_read(level, hart, EITHRESHOLD, value & ((1 << ID_BITS) - 1))


@cocotb.test()
async def test_eip_eie_arrays(dut: Any) -> None:
    """The eip and eie words through *ireg: write, set and clear forms.

    Bit 0 of eip0 and eie0 and the bits above NUM_IDS are read-only zeros;
    software can set and clear pending bits through eip; each bit is its
    identity's, in the even registers 0x80 + 2w and 0xC0 + 2w.
    """
    bench = Bench(dut)
    await bench.start()
    rng = random.Random(1)
    for level, hart in FILES:
        for word in range(NUM_WORDS):
            for base in (EIP0, EIE0):
                select = base + 2 * word
                pattern = rng.getrandbits(64)
                await bench.csrrw(level, hart, select, pattern)
                await bench.csrrs(level, hart, select, rng.getrandbits(64))
                await bench.csrrc(level, hart, select, rng.getrandbits(64))
                # A pure read (csrrs with x0) leaves the register alone.
                await bench.csrrs(level, hart, select, 0)
                await bench.csrrw(level, hart, select, 0)
    # Pending bits set through eip behave like MSIs: the lowest enabled one
    # is *topei, and claims take them in order.
    level, hart = FILES[0]
    identities = sorted({1, 3, 64, NUM_IDS} & set(range(1, NUM_IDS + 1)))
    for identity in identities:
        await bench.csrrs(level, hart, eip_select(identity), 1 << (identity % 64))
    await bench.expect_topei(level, hart, 0)  # nothing enabled yet
    await bench.enable(level, hart, identities)
    for identity in identities:
        await bench.expect_topei(level, hart, identity)
        await bench.csrrc(level, hart, eip_select(identity), 1 << (identity % 64))
    await bench.expect_topei(level, hart, 0)


@cocotb.test()
async def test_msi_writes(dut: Any) -> None:
    """seteipnum_le and seteipnum_be set exactly the identity written.

    Identity 0, identities above NUM_IDS, the other offsets of a page, pages
    of hart indices without a file, and addresses outside both regions
    change nothing. Every write is checked in every file by the model.
    """
    bench = Bench(dut)
    await bench.start()
    for level, hart in FILES:
        await bench.enable_all(level, hart)
    rng = random.Random(2)
    for identity in sample_identities():
        level, hart = rng.choice(FILES)
        big_endian = bool(rng.getrandbits(1))
        await bench.msi(level, hart, identity, big_endian)
        await bench.expect_topei(level, hart, identity)
        assert await bench.claim(level, hart) == topei_value(identity)
    await bench.sweep()
    # Rejected writes, to every file's page.
    for level, hart in FILES:
        page = bench.model.page_address(level, hart)
        for offset, data in (
            (SETEIPNUM_LE, 0),
            (SETEIPNUM_BE, 0),
            (SETEIPNUM_LE, NUM_IDS + 1),
            (SETEIPNUM_LE, 0x0100_0000),  # identity 1, but in big-endian byte order
            (SETEIPNUM_BE, 1),  # identity 0x01000000 in big-endian byte order
            (SETEIPNUM_BE, byteswap32(NUM_IDS + 1)),
            (SETEIPNUM_LE, 0xFFFF_FFFF),
            (SETEIPNUM_LE, 0x1_0000 | 1),
            (0x008, 1),
            (0x00C, 1),
            (0x800, 1),
            (0xFFC, 1),
        ):
            await bench.mmio_write(page + offset, data)
            await bench.expect_topei(level, hart, 0)
    # Pages without a file, and addresses just outside the regions.
    region = bench.model.region_bytes()
    for base in (M_BASE, S_BASE):
        for hart in range(NUM_HARTS, region // PAGE_BYTES):
            await bench.mmio_write(base + PAGE_BYTES * hart, 1)
        for address in (base - 4, base - PAGE_BYTES, base + region, base ^ 0x8000_0000):
            await bench.mmio_write(address, 1)
    await bench.sweep()
    for level, hart in FILES:
        assert bench.model.files[level][hart].eip == 0


@cocotb.test()
async def test_topei_and_claims(dut: Any) -> None:
    """*topei reports the lowest pending and enabled identity; a claim clears it.

    A claim with nothing to report changes nothing; a disabled identity is
    neither reported nor cleared; claims a cycle apart take the identities in
    order. A claim in the cycle right after another, which the CPU never
    issues, reads the same identity again and clears nothing.
    """
    bench = Bench(dut)
    await bench.start()
    level, hart = FILES[-1]
    await bench.deliver(level, hart)
    identities = sorted({2, 7, 63, 64, 100, NUM_IDS} & set(range(1, NUM_IDS + 1)))
    disabled = 5
    for identity in identities + [disabled]:
        await bench.msi(level, hart, identity)
    await bench.expect_topei(level, hart, 0)
    assert await bench.claim(level, hart) == 0
    await bench.enable(level, hart, identities)
    for identity in identities:
        assert await bench.claim(level, hart) == topei_value(identity)
    assert await bench.claim(level, hart) == 0
    await bench.settle()
    assert bench.line(level, hart) == 0
    assert await bench.read(level, hart, eip_select(disabled)) == 1 << disabled
    # The same claims a cycle apart, with no settling between them.
    for identity in identities:
        await bench.msi(level, hart, identity)
    values = []
    for _ in range(len(identities) + 1):
        values.append(await bench.claim(level, hart))
    assert values == [topei_value(identity) for identity in identities] + [0]
    # Back-to-back claims: the second reads the first's identity again.
    first, second = identities[:2]
    for identity in (first, second):
        await bench.msi(level, hart, identity)
    claim = {(level, hart): CsrAccess(bench.selects[(level, hart)], claim=True)}
    values = [(await bench.cycle(accesses=claim))[(level, hart)][1] for _ in range(2)]
    assert values == [topei_value(first)] * 2
    await bench.expect_topei(level, hart, second)
    assert await bench.claim(level, hart) == topei_value(second)


@cocotb.test()
async def test_msi_with_csr_access(dut: Any) -> None:
    """An MSI and a hart-side access to the same file in one cycle.

    The access takes effect first and its read does not see the MSI: a clear
    of the identity's pending bit, a zero written over its eip word, or a
    claim of it all leave the identity pending, and writes of eie and
    eithreshold combine with the MSI. A store reaches its file a cycle after
    the bus delivers it, so the race is set up with the store one cycle
    ahead; a store in the same cycle as the access lands a cycle later still.
    """
    bench = Bench(dut)
    await bench.start()
    level, hart = FILES[-1]
    page = bench.model.page_address(level, hart)
    identity = min(9, NUM_IDS)
    bit = 1 << (identity % 64)
    await bench.deliver(level, hart)

    async def race(access: CsrAccess) -> tuple[int, int]:
        """Store identity, then make the access in the cycle it reaches the file."""
        await bench.cycle(write=(page + SETEIPNUM_LE, identity))
        samples = await bench.cycle(accesses={(level, hart): access})
        await bench.settle()
        return samples[(level, hart)]

    # csrrc of the pending bit: the old value lacks it, and it ends pending.
    await bench.csrrw(level, hart, eip_select(identity), 0)
    old, _ = await race(CsrAccess(eip_select(identity), True, ~bit & MASK64, 0))
    assert old == 0
    assert await bench.read(level, hart, eip_select(identity)) == bit
    # csrrw of zero over the word.
    old, _ = await race(CsrAccess(eip_select(identity), True, 0, 0))
    assert old == bit
    assert await bench.read(level, hart, eip_select(identity)) == bit
    await bench.csrrw(level, hart, eip_select(identity), 0)
    # An eie write that enables the identity: both land.
    old, _ = await race(CsrAccess(eie_select(identity), True, MASK64, bit))
    assert old == 0
    await bench.expect_topei(level, hart, identity)
    assert bench.line(level, hart) == 1
    assert await bench.claim(level, hart) == topei_value(identity)
    # An eithreshold write that admits the identity.
    await bench.csrrw(level, hart, EITHRESHOLD, identity)
    await race(CsrAccess(EITHRESHOLD, True, 0, identity + 1))
    await bench.expect_topei(level, hart, identity)
    assert await bench.claim(level, hart) == topei_value(identity)
    await bench.csrrw(level, hart, EITHRESHOLD, 0)
    # The store in the same cycle as a read of its word: the read and the
    # next one miss it, the third sees it.
    await bench.csrrw(level, hart, eip_select(identity), 0)
    samples = await bench.cycle(
        write=(page + SETEIPNUM_LE, identity),
        accesses={(level, hart): CsrAccess(eip_select(identity))},
    )
    assert samples[(level, hart)][0] == 0
    assert await bench.read(level, hart, eip_select(identity)) == 0
    assert await bench.read(level, hart, eip_select(identity)) == bit
    assert await bench.claim(level, hart) == topei_value(identity)


@cocotb.test()
async def test_claim_races_msi(dut: Any) -> None:
    """A claim in the cycle an MSI arrives at the same file.

    The claim reads and clears the identity *topei reported before the MSI:
    an MSI for that identity leaves it pending again, one for a lower
    identity becomes the next *topei, and with nothing to claim the MSI
    still lands.
    """
    bench = Bench(dut)
    await bench.start()
    level, hart = FILES[0]
    page = bench.model.page_address(level, hart)
    await bench.enable_all(level, hart)
    await bench.deliver(level, hart)
    claimed, lower, higher = min(20, NUM_IDS), min(4, NUM_IDS), NUM_IDS

    async def race(identity: int) -> int:
        """Store identity, then claim in the cycle it reaches the file."""
        await bench.cycle(write=(page + SETEIPNUM_LE, identity))
        _, topei = await bench.access(
            level, hart, CsrAccess(bench.selects[(level, hart)], claim=True)
        )
        await bench.settle()
        return topei

    # The same identity: claimed, and pending again; the line stays up.
    await bench.msi(level, hart, claimed)
    assert await race(claimed) == topei_value(claimed)
    await bench.expect_topei(level, hart, claimed)
    assert bench.line(level, hart) == 1
    # A lower identity arrives while the claim takes the reported one.
    assert await race(lower) == topei_value(claimed)
    await bench.expect_topei(level, hart, lower)
    assert await bench.claim(level, hart) == topei_value(lower)
    assert await bench.claim(level, hart) == 0
    # A higher identity, and a claim with nothing to report.
    await bench.msi(level, hart, claimed)
    assert await race(higher) == topei_value(claimed)
    await bench.expect_topei(level, hart, higher)
    assert await race(claimed) == topei_value(higher)
    await bench.expect_topei(level, hart, claimed)
    assert await bench.claim(level, hart) == topei_value(claimed)
    assert await race(claimed) == 0
    await bench.expect_topei(level, hart, claimed)


@cocotb.test()
async def test_harts_and_levels(dut: Any) -> None:
    """Each hart's machine and supervisor files are separate.

    An MSI to one page reaches only that file, and an inter-processor
    interrupt is a store of an identity to another hart's machine-level
    page.
    """
    bench = Bench(dut)
    await bench.start()
    for level, hart in FILES:
        await bench.enable(level, hart, [1, 2])
        await bench.deliver(level, hart)
    for target in FILES:
        await bench.msi(*target, 2)
        for level, hart in FILES:
            await bench.expect_topei(level, hart, 2 if (level, hart) == target else 0)
            assert bench.line(level, hart) == int((level, hart) == target)
        assert await bench.claim(*target) == topei_value(2)
    # IPIs: each hart sends identity 1 to every machine-level file at once,
    # then the targets claim them.
    for hart in range(NUM_HARTS):
        await bench.cycle(write=(bench.model.page_address(MACHINE, hart), 1))
    await bench.settle()
    for hart in range(NUM_HARTS):
        assert bench.line(MACHINE, hart) == 1
        assert bench.line(SUPERVISOR, hart) == 0
    claims = await bench.cycle(
        accesses={
            (MACHINE, hart): CsrAccess(bench.selects[(MACHINE, hart)], claim=True)
            for hart in range(NUM_HARTS)
        }
    )
    assert all(
        claims[(MACHINE, hart)][1] == topei_value(1) for hart in range(NUM_HARTS)
    )
    await bench.settle()
    assert int(dut.o_meip.value) == 0


@cocotb.test()
async def test_firmware_and_kernel_sequences(dut: Any) -> None:
    """The register sequences of OpenSBI's and Linux's IMSIC drivers.

    OpenSBI (lib/utils/irqchip/imsic.c) clears every machine-level enable bit
    and the IPI's pending bit, sets eithreshold 0 and eidelivery 1, enables
    identity 1, and sends an IPI by storing 1 to the target's page; its
    handler claims with csrrw mtopei until it reads zero. Linux
    (irq-riscv-imsic-state.c) does the same at supervisor level, enables
    identities with csrrs, moves one with csrrc's read-and-clear of its
    pending bit, and claims in a csrrw stopei loop.
    """
    bench = Bench(dut)
    await bench.start()
    ipi = 1
    for hart in range(NUM_HARTS):
        # imsic_warm_irqchip_init and imsic_local_irqchip_init; the enable
        # bits are cleared a register at a time, as imsic_local_eix_update does.
        await bench.csrrw(MACHINE, hart, EIDELIVERY, 0)
        identity = 1
        while identity <= NUM_IDS:
            count = min(64 - identity % 64, NUM_IDS + 1 - identity)
            mask = ((1 << count) - 1) << (identity % 64)
            await bench.csrrc(MACHINE, hart, eie_select(identity), mask)
            identity += count
        await bench.csrrc(MACHINE, hart, eip_select(ipi), 1 << ipi)
        await bench.csrrw(MACHINE, hart, EITHRESHOLD, 0)
        await bench.csrrw(MACHINE, hart, EIDELIVERY, 1)
        await bench.csrrs(MACHINE, hart, eie_select(ipi), 1 << ipi)
        # Linux: imsic_local_delivery(true), then enable some vectors.
        await bench.csrrw(SUPERVISOR, hart, EITHRESHOLD, 0)
        await bench.csrrw(SUPERVISOR, hart, EIDELIVERY, 1)
        await bench.enable(SUPERVISOR, hart, [ipi, 3, min(66, NUM_IDS)])
    # OpenSBI's IPI to every hart (twice, which coalesces), then its handler.
    for hart in range(NUM_HARTS):
        for _ in range(2):
            await bench.mmio_write(bench.model.page_address(MACHINE, hart), ipi)
        assert bench.line(MACHINE, hart) == 1
        values = []
        while True:
            value = await bench.claim(MACHINE, hart)
            if not value:
                break
            values.append(value >> 16)
        assert values == [ipi]
        await bench.settle()
        assert bench.line(MACHINE, hart) == 0
    # Linux: a device MSI and an IPI to the last hart, handled in one loop.
    hart = NUM_HARTS - 1
    device = min(66, NUM_IDS)
    await bench.msi(SUPERVISOR, hart, device, big_endian=True)
    await bench.msi(SUPERVISOR, hart, ipi)
    values = []
    while value := await bench.claim(SUPERVISOR, hart):
        values.append(value >> 16)
    assert values == [ipi, device]
    # Moving vector 3 to the first hart: mask it on the old hart, then
    # read-and-clear its pending bit there; the new hart enables its vector
    # and a pending one is retriggered with a store to the new hart's page.
    await bench.msi(SUPERVISOR, hart, 3)
    await bench.csrrc(SUPERVISOR, hart, eie_select(3), 1 << 3)
    old = await bench.csrrc(SUPERVISOR, hart, eip_select(3), 1 << 3)
    assert old & (1 << 3)
    await bench.expect_topei(SUPERVISOR, hart, 0)
    await bench.csrrs(SUPERVISOR, 0, eie_select(3), 1 << 3)
    await bench.msi(SUPERVISOR, 0, 3)
    await bench.expect_topei(SUPERVISOR, 0, 3)
    assert await bench.claim(SUPERVISOR, 0) == topei_value(3)


@cocotb.test()
async def test_random_against_model(dut: Any) -> None:
    """Random stores, hart-side accesses and APLIC lines, on back-to-back cycles."""
    bench = Bench(dut)
    await bench.start()
    rng = random.Random(int(os.environ.get("IMSIC_SEED", "7")))
    interesting = [EIDELIVERY, EITHRESHOLD, 0x71, 0x7F, 0x00, 0x81, 0xC1, 0xFF]
    interesting += [EIP0 + 2 * word for word in range(min(NUM_WORDS + 1, 32))]
    interesting += [EIE0 + 2 * word for word in range(min(NUM_WORDS + 1, 32))]
    # Start with delivery on and most identities enabled.
    for level, hart in FILES:
        await bench.enable_all(level, hart)
        await bench.deliver(level, hart)

    def random_write() -> tuple[int, int] | None:
        """Pick a store: usually a valid MSI, sometimes one that is ignored."""
        if rng.random() < 0.4:
            return None
        level, hart = rng.choice(FILES)
        page = bench.model.page_address(level, hart)
        identity = rng.choice(
            [rng.randint(1, NUM_IDS), rng.randint(1, min(NUM_IDS, 12))]
        )
        kind = rng.random()
        if kind < 0.45:
            return page + SETEIPNUM_LE, identity
        if kind < 0.8:
            return page + SETEIPNUM_BE, byteswap32(identity)
        if kind < 0.9:
            return page + rng.choice([0x008, 0x010, 0xFFC]), identity
        return page, rng.choice([0, NUM_IDS + 1, rng.getrandbits(32)])

    def random_access(level: int, hart: int) -> CsrAccess:
        """Pick a hart-side access: a read, a Zicsr write, or a claim."""
        select = rng.choice(interesting)
        kind = rng.random()
        if kind < 0.3:
            return CsrAccess(select)
        if kind < 0.55:
            return CsrAccess(bench.selects[(level, hart)], claim=True)
        if select == EIDELIVERY:
            value = rng.choice([0, 1, 1, 1, EIDELIVERY_APLIC])
        elif select == EITHRESHOLD:
            value = rng.choice([0, 0, rng.randint(0, NUM_IDS)])
        else:
            value = rng.getrandbits(64)
        form = rng.randrange(3)
        if form == 0:
            return CsrAccess(select, True, 0, value)
        if form == 1:
            return CsrAccess(select, True, MASK64, value & rng.getrandbits(64))
        return CsrAccess(select, True, ~(value & rng.getrandbits(64)) & MASK64, 0)

    for _ in range(4000):
        accesses = {}
        for key in FILES:
            if rng.random() < 0.3:
                accesses[key] = random_access(*key)
        if rng.random() < 0.1:
            bench.aplic[rng.choice(LEVELS)] ^= 1 << rng.randrange(NUM_HARTS)
        await bench.cycle(write=random_write(), accesses=accesses)
    await bench.settle()
    await bench.sweep()
