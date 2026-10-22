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

"""Cycle-level model of the IMSIC (hw/rtl/peripherals/imsic/imsic.sv).

The model follows RISC-V AIA 1.0 chapter 3 for a machine-level and a
supervisor-level interrupt file per hart, plus the implementation's choices
where the spec leaves one (see the module's README.md): eidelivery's
0x40000000 option, the update order within a cycle, and the one-cycle decode
register between a memory-mapped write and its interrupt file.

Each call to ImsicModel.clock is one rising clock edge. Hart-side reads see
the state before the edge, as the RTL's combinational reads and registered
topei do; the interrupt lines are compared after the edge.
"""

from dataclasses import dataclass, field

MACHINE = 0
SUPERVISOR = 1
LEVELS = (MACHINE, SUPERVISOR)

# *iselect values of the interrupt-file registers.
EIDELIVERY = 0x70
EITHRESHOLD = 0x72
EIP0 = 0x80
EIE0 = 0xC0
EIDELIVERY_APLIC = 0x4000_0000

# Offsets inside an interrupt file's 4 KiB page.
SETEIPNUM_LE = 0x000
SETEIPNUM_BE = 0x004
PAGE_BYTES = 0x1000

MASK64 = (1 << 64) - 1


def byteswap32(value: int) -> int:
    """Reverse the byte order of a 32-bit value."""
    return int.from_bytes((value & 0xFFFF_FFFF).to_bytes(4, "little"), "big")


def topei_value(identity: int) -> int:
    """Return the *topei value that reports an identity (zero for none)."""
    return (identity << 16) | identity


@dataclass
class CsrAccess:
    """One cycle of hart-side activity at an interrupt file.

    select drives *iselect; write applies the Zicsr update
    (value & keep) | set_ to the selected register; claim writes *topei.
    """

    select: int = 0
    write: bool = False
    keep: int = MASK64
    set_: int = 0
    claim: bool = False


@dataclass
class InterruptFile:
    """One interrupt file: eip and eie arrays, eithreshold, eidelivery."""

    num_ids: int
    aplic_delivery: bool
    eip: int = 0  # bit i is identity i
    eie: int = 0
    eithreshold: int = 0
    eidelivery: int = 0
    aplic_line: int = 0  # the APLIC line as the last edge sampled it

    def __post_init__(self) -> None:
        """Start from the reset state."""
        self.reset()

    @property
    def id_bits(self) -> int:
        """Bits of eithreshold: enough for 0 to num_ids."""
        return self.num_ids.bit_length()

    @property
    def num_words(self) -> int:
        """Number of 64-bit eip (and eie) registers with implemented bits."""
        return (self.num_ids + 1) // 64

    @property
    def implemented(self) -> int:
        """Mask of implemented identities, 1 to num_ids."""
        return ((1 << (self.num_ids + 1)) - 1) & ~1

    def reset(self) -> None:
        """Reset: everything clear, eidelivery 0x40000000 when supported."""
        self.eip = 0
        self.eie = 0
        self.eithreshold = 0
        self.eidelivery = EIDELIVERY_APLIC if self.aplic_delivery else 0
        self.aplic_line = 0

    def candidates(self) -> int:
        """Pending and enabled identities below a nonzero eithreshold."""
        candidates = self.eip & self.eie
        if self.eithreshold:
            candidates &= (1 << self.eithreshold) - 1
        return candidates

    def top(self) -> int:
        """Return the lowest candidate identity, or zero."""
        candidates = self.candidates()
        return (candidates & -candidates).bit_length() - 1 if candidates else 0

    def topei(self) -> int:
        """Return the *topei value."""
        return topei_value(self.top())

    def line(self) -> int:
        """Return the external interrupt line for mip.MEIP or mip.SEIP."""
        if self.eidelivery == 1:
            return int(self.candidates() != 0)
        if self.eidelivery == EIDELIVERY_APLIC:
            return self.aplic_line
        return 0

    @staticmethod
    def illegal(select: int) -> bool:
        """Odd eip and eie selects name registers that RV64 lacks."""
        return select >= EIP0 and bool(select & 1)

    def read(self, select: int) -> int:
        """Return the register an *iselect value names, as *ireg reads it."""
        if select == EIDELIVERY:
            return self.eidelivery
        if select == EITHRESHOLD:
            return self.eithreshold
        if select >= EIP0 and not select & 1:
            word = (select & 0x3F) >> 1
            array = self.eie if select & 0x40 else self.eip
            return (array >> (64 * word)) & MASK64
        return 0

    def write(self, select: int, keep: int, set_: int) -> None:
        """Apply a Zicsr update, (value & keep) | set_, to a register."""
        value = ((self.read(select) & keep) | set_) & MASK64
        if select == EIDELIVERY:
            if self.aplic_delivery and value & EIDELIVERY_APLIC:
                self.eidelivery = EIDELIVERY_APLIC
            else:
                self.eidelivery = value & 1
        elif select == EITHRESHOLD:
            self.eithreshold = value & ((1 << self.id_bits) - 1)
        elif select >= EIP0 and not select & 1:
            word = (select & 0x3F) >> 1
            shift = 64 * word
            if select & 0x40:
                self.eie = (self.eie & ~(MASK64 << shift)) | (value << shift)
                self.eie &= self.implemented
            else:
                self.eip = (self.eip & ~(MASK64 << shift)) | (value << shift)
                self.eip &= self.implemented

    def claim(self) -> int:
        """Write *topei: clear the reported identity; return the value read."""
        identity = self.top()
        if identity:
            self.eip &= ~(1 << identity)
        return topei_value(identity)

    def msi(self, identity: int) -> None:
        """Set the pending bit of an implemented identity."""
        if 1 <= identity <= self.num_ids:
            self.eip |= 1 << identity


@dataclass
class ImsicModel:
    """Cycle-level state of the IMSIC's interrupt files and MSI decode."""

    num_harts: int
    num_ids: int
    m_base: int
    s_base: int
    aplic_delivery: bool
    files: list[list[InterruptFile]] = field(default_factory=list)
    # The decoded write a cycle old: (level, hart, identity).
    pending_msi: tuple[int, int, int] | None = None

    def __post_init__(self) -> None:
        """Start from the reset state."""
        self.files = [
            [
                InterruptFile(self.num_ids, self.aplic_delivery)
                for _ in range(self.num_harts)
            ]
            for _ in LEVELS
        ]

    def reset(self) -> None:
        """Reset every file and the decode register."""
        for level in LEVELS:
            for interrupt_file in self.files[level]:
                interrupt_file.reset()
        self.pending_msi = None

    @property
    def hart_bits(self) -> int:
        """Hart-index bits of a region's page number."""
        return (self.num_harts - 1).bit_length()

    def region_bytes(self) -> int:
        """Size of each level's region: a page per hart, rounded up to 2^k."""
        return PAGE_BYTES << self.hart_bits

    def page_address(self, level: int, hart: int) -> int:
        """Address of the page of a hart's file at a level."""
        return (self.m_base if level == MACHINE else self.s_base) + PAGE_BYTES * hart

    def decode(self, address: int, data: int) -> tuple[int, int, int] | None:
        """Return the (level, hart, identity) a write sets, if any."""
        shift = 12 + self.hart_bits
        for level, base in ((MACHINE, self.m_base), (SUPERVISOR, self.s_base)):
            if address >> shift != base >> shift:
                continue
            hart = (address >> 12) & ((1 << self.hart_bits) - 1)
            offset = address & 0xFFC
            if hart >= self.num_harts or offset not in (SETEIPNUM_LE, SETEIPNUM_BE):
                return None
            value = data if offset == SETEIPNUM_LE else byteswap32(data)
            if 1 <= value <= self.num_ids:
                return level, hart, value
            return None
        return None

    def clock(
        self,
        write: tuple[int, int] | None,
        accesses: dict[tuple[int, int], CsrAccess],
        aplic_lines: tuple[int, int],
    ) -> dict[tuple[int, int], int]:
        """One rising edge; return each claimed file's *topei value.

        Each file applies its claim, then its *ireg write, then the MSI the
        decode register held; the edge then decodes this cycle's write and
        samples the APLIC lines (bit h of aplic_lines[level] for hart h).
        """
        claims = {}
        for (level, hart), access in accesses.items():
            interrupt_file = self.files[level][hart]
            if access.claim:
                claims[(level, hart)] = interrupt_file.claim()
            if access.write:
                interrupt_file.write(access.select, access.keep, access.set_)
        if self.pending_msi is not None:
            level, hart, identity = self.pending_msi
            self.files[level][hart].msi(identity)
        self.pending_msi = None if write is None else self.decode(*write)
        for level in LEVELS:
            for hart in range(self.num_harts):
                self.files[level][hart].aplic_line = (aplic_lines[level] >> hart) & 1
        return claims
