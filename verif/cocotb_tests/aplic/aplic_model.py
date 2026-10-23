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

"""Register-level model of the APLIC (hw/rtl/peripherals/aplic/aplic.sv).

The model follows RISC-V AIA 1.0 chapter 4 for a machine-level root domain
with one supervisor-level child, both in direct delivery mode, plus the
implementation's choices where the spec leaves one (see the module's
README.md). It describes the state once every registered effect has
settled: the bench lets a few cycles pass after each operation.

Each domain is described separately, as software sees it: a sourcecfg value
per domain and source, and pending, enable and target state for the domain
that holds a source. Offsets are byte offsets inside the 4 MiB window.
"""

from dataclasses import dataclass, field

ROOT = 0
SUPERVISOR = 1
DOMAIN_BASE = (0x0000, 0x8000)  # control region of each domain in the window
REGION_BYTES = 0x8000

DOMAINCFG = 0x0000
SOURCECFG = 0x0000  # sourcecfg[i] at +4*i
MMSIADDRCFG = 0x1BC0  # the four MSI address registers, 0x1BC0..0x1BCC
SETIP = 0x1C00  # setip[k] at +4*k
SETIPNUM = 0x1CDC
IN_CLRIP = 0x1D00
CLRIPNUM = 0x1DDC
SETIE = 0x1E00
SETIENUM = 0x1EDC
CLRIE = 0x1F00
CLRIENUM = 0x1FDC
SETIPNUM_LE = 0x2000
SETIPNUM_BE = 0x2004
GENMSI = 0x3000
TARGET = 0x3000  # target[i] at +4*i
IDC = 0x4000  # IDC of hart index h at +32*h
IDELIVERY = 0x00
IFORCE = 0x04
ITHRESHOLD = 0x08
TOPI = 0x18
CLAIMI = 0x1C

SM_INACTIVE = 0
SM_DETACHED = 1
SM_EDGE1 = 4
SM_EDGE0 = 5
SM_LEVEL1 = 6
SM_LEVEL0 = 7
SOURCE_MODES = (SM_INACTIVE, SM_DETACHED, SM_EDGE1, SM_EDGE0, SM_LEVEL1, SM_LEVEL0)
SOURCECFG_D = 1 << 10


def byteswap32(value: int) -> int:
    """Reverse the byte order of a 32-bit value."""
    return int.from_bytes((value & 0xFFFF_FFFF).to_bytes(4, "little"), "big")


@dataclass
class Source:
    """One interrupt source: the wire and the state of the domain holding it."""

    wire: int = 0
    delegated: bool = False  # root sourcecfg.D
    mode: int = SM_INACTIVE  # source mode in the domain that holds the source
    pending: bool = False
    enabled: bool = False
    hart: int = 0
    priority: int = 1


@dataclass
class Idc:
    """One interrupt delivery control structure."""

    idelivery: int = 0
    iforce: int = 0
    ithreshold: int = 0


@dataclass
class AplicModel:
    """Settled register-level state of the two-domain APLIC."""

    num_sources: int
    num_harts: int
    iprio_len: int
    sources: list[Source] = field(default_factory=list)
    domain_ie: list[int] = field(default_factory=list)
    idcs: list[list[Idc]] = field(default_factory=list)

    def __post_init__(self) -> None:
        """Start from the reset state."""
        self.reset()

    def reset(self) -> None:
        """Reset values: everything zero, priorities 1, wires kept."""
        wires = [source.wire for source in self.sources]
        self.sources = [Source() for _ in range(self.num_sources + 1)]
        for source, wire in zip(self.sources, wires):
            source.wire = wire
        self.domain_ie = [0, 0]
        self.idcs = [[Idc() for _ in range(self.num_harts)] for _ in range(2)]

    # -- source helpers ------------------------------------------------------

    def implemented(self, number: int) -> bool:
        """Return whether a source number names an existing source."""
        return 1 <= number <= self.num_sources

    def holder(self, number: int) -> int:
        """Return the domain that holds a source, which may be inactive there."""
        return SUPERVISOR if self.sources[number].delegated else ROOT

    def active_in(self, domain: int, number: int) -> bool:
        """Return whether a source is active in a domain."""
        if not self.implemented(number):
            return False
        return (
            self.holder(number) == domain and self.sources[number].mode != SM_INACTIVE
        )

    def rect(self, number: int) -> int:
        """Return the rectified input: the wire, inverted for Edge0 and Level0."""
        source = self.sources[number]
        if source.mode in (SM_EDGE1, SM_LEVEL1):
            return source.wire
        if source.mode in (SM_EDGE0, SM_LEVEL0):
            return source.wire ^ 1
        return 0

    @staticmethod
    def is_level(mode: int) -> bool:
        """Return whether a source mode is level-sensitive."""
        return mode in (SM_LEVEL1, SM_LEVEL0)

    @staticmethod
    def is_edge(mode: int) -> bool:
        """Return whether a source mode is edge-sensitive."""
        return mode in (SM_EDGE1, SM_EDGE0)

    def latched(self, number: int) -> bool:
        """Pending bit set by writes, cleared by claims and writes."""
        mode = self.sources[number].mode
        return mode == SM_DETACHED or self.is_edge(mode)

    def hart_bits(self) -> int:
        """Return the width of a target's hart index."""
        return max(1, (self.num_harts - 1).bit_length())

    # -- inputs --------------------------------------------------------------

    def set_wire(self, number: int, value: int) -> None:
        """Drive source wire `number` and settle its pending bit."""
        before = self.rect(number)
        self.sources[number].wire = value
        self._settle(number, before)

    def _settle(self, number: int, rect_before: int) -> None:
        """Apply the input rules after the rectified input may have moved."""
        source = self.sources[number]
        after = self.rect(number)
        if self.is_level(source.mode):
            source.pending = bool(after)
        elif self.is_edge(source.mode) and after and not rect_before:
            source.pending = True

    # -- register access -----------------------------------------------------

    @staticmethod
    def split(offset: int) -> tuple[int, int] | None:
        """(domain, offset inside its region), or None outside both regions."""
        if offset >> 16:
            return None
        return (offset >> 15) & 1, offset & (REGION_BYTES - 4)

    def write(self, offset: int, data: int) -> None:
        """Apply a 32-bit store at a window offset."""
        data &= 0xFFFF_FFFF
        location = self.split(offset)
        if location is None:
            return
        domain, reg = location
        if reg == DOMAINCFG:
            self.domain_ie[domain] = (data >> 8) & 1
        elif reg < 0x1000:
            if self.implemented(reg >> 2):
                self._write_sourcecfg(domain, reg >> 2, data)
        elif SETIP <= reg < SETIP + 0x80:
            for number in self._bitmap_sources(reg - SETIP, data):
                self._set_pending(domain, number)
        elif reg in (SETIPNUM, SETIPNUM_LE):
            self._set_pending(domain, data)
        elif reg == SETIPNUM_BE:
            self._set_pending(domain, byteswap32(data))
        elif IN_CLRIP <= reg < IN_CLRIP + 0x80:
            for number in self._bitmap_sources(reg - IN_CLRIP, data):
                self._clear_pending(domain, number)
        elif reg == CLRIPNUM:
            self._clear_pending(domain, data)
        elif SETIE <= reg < SETIE + 0x80:
            for number in self._bitmap_sources(reg - SETIE, data):
                self._set_enable(domain, number, True)
        elif reg == SETIENUM:
            self._set_enable(domain, data, True)
        elif CLRIE <= reg < CLRIE + 0x80:
            for number in self._bitmap_sources(reg - CLRIE, data):
                self._set_enable(domain, number, False)
        elif reg == CLRIENUM:
            self._set_enable(domain, data, False)
        elif TARGET < reg < IDC:
            # A write from the domain holding the source lands even while the
            # source is inactive there (the register then reads zero); the
            # source uses the value once active.
            number = (reg - TARGET) >> 2
            if self.implemented(number) and self.holder(number) == domain:
                source = self.sources[number]
                hart_mask = (1 << self.hart_bits()) - 1
                source.hart = (data >> 18) & hart_mask if self.num_harts > 1 else 0
                priority = data & ((1 << self.iprio_len) - 1)
                source.priority = priority or 1
        elif reg >= IDC:
            hart, word = (reg - IDC) >> 5, reg & 0x1F
            if hart < self.num_harts:
                idc = self.idcs[domain][hart]
                if word == IDELIVERY:
                    idc.idelivery = data & 1
                elif word == IFORCE:
                    idc.iforce = data & 1
                elif word == ITHRESHOLD:
                    idc.ithreshold = data & ((1 << self.iprio_len) - 1)

    def _bitmap_sources(self, word_offset: int, data: int) -> list[int]:
        base = (word_offset >> 2) * 32
        return [base + bit for bit in range(32) if (data >> bit) & 1]

    def _write_sourcecfg(self, domain: int, number: int, data: int) -> None:
        source = self.sources[number]
        rect_before = self.rect(number)
        mode = data & 7
        if mode in (2, 3):
            mode = SM_INACTIVE
        cleared = False
        moved = False
        if domain == ROOT:
            if data & SOURCECFG_D:
                if not source.delegated:
                    source.delegated = True
                    source.mode = SM_INACTIVE
                    cleared = moved = True
            else:
                cleared = source.delegated or mode == SM_INACTIVE
                moved = source.delegated
                source.delegated = False
                source.mode = mode
        elif source.delegated:
            source.mode = SM_INACTIVE if data & SOURCECFG_D else mode
            cleared = source.mode == SM_INACTIVE
        if cleared:
            source.pending = False
            source.enabled = False
        if moved:
            source.hart = 0
            source.priority = 1
        self._settle(number, rect_before)

    def _set_pending(self, domain: int, number: int) -> None:
        if self.active_in(domain, number) and self.latched(number):
            self.sources[number].pending = True

    def _clear_pending(self, domain: int, number: int) -> None:
        if self.active_in(domain, number) and self.latched(number):
            self.sources[number].pending = False

    def _set_enable(self, domain: int, number: int, value: bool) -> None:
        if self.active_in(domain, number):
            self.sources[number].enabled = value

    def read(self, offset: int) -> int:
        """Return a 32-bit load at a window offset, without side effects."""
        location = self.split(offset)
        if location is None:
            return 0
        domain, reg = location
        if reg == DOMAINCFG:
            return 0x8000_0000 | (self.domain_ie[domain] << 8)
        if reg < 0x1000:
            number = reg >> 2
            if not self.implemented(number):
                return 0
            source = self.sources[number]
            if domain == ROOT:
                return SOURCECFG_D if source.delegated else source.mode
            return source.mode if source.delegated else 0
        for base, bit_of in (
            (SETIP, lambda n: self.sources[n].pending),
            (IN_CLRIP, self.rect),
            (SETIE, lambda n: self.sources[n].enabled),
        ):
            if base <= reg < base + 0x80:
                value = 0
                for bit in range(32):
                    number = ((reg - base) >> 2) * 32 + bit
                    if (
                        self.implemented(number)
                        and self.holder(number) == domain
                        and bit_of(number)
                    ):
                        value |= 1 << bit
                return value
        if TARGET < reg < IDC:
            number = (reg - TARGET) >> 2
            if self.active_in(domain, number):
                source = self.sources[number]
                return (source.hart << 18) | source.priority
            return 0
        if reg >= IDC:
            hart, word = (reg - IDC) >> 5, reg & 0x1F
            if hart >= self.num_harts:
                return 0
            idc = self.idcs[domain][hart]
            if word == IDELIVERY:
                return idc.idelivery
            if word == IFORCE:
                return idc.iforce
            if word == ITHRESHOLD:
                return idc.ithreshold
            if word in (TOPI, CLAIMI):
                return self.topi(domain, hart)
        return 0

    # -- delivery ------------------------------------------------------------

    def topi(self, domain: int, hart: int) -> int:
        """Highest-priority pending, enabled source for an IDC, as topi reads."""
        threshold = self.idcs[domain][hart].ithreshold
        best: tuple[int, int] | None = None
        for number in range(1, self.num_sources + 1):
            source = self.sources[number]
            if not (
                self.holder(number) == domain
                and source.pending
                and source.enabled
                and source.hart == hart
                and (threshold == 0 or source.priority < threshold)
            ):
                continue
            if best is None or (source.priority, number) < best:
                best = (source.priority, number)
        if best is None:
            return 0
        return (best[1] << 16) | best[0]

    def claim(self, domain: int, hart: int) -> int:
        """Read claimi: topi, clearing a latched pending bit or else iforce."""
        value = self.topi(domain, hart)
        if value:
            number = value >> 16
            if self.latched(number):
                self.sources[number].pending = False
        else:
            self.idcs[domain][hart].iforce = 0
        return value

    def eip(self, domain: int, hart: int) -> int:
        """Return the domain's external interrupt line to a hart (MEIP or SEIP)."""
        idc = self.idcs[domain][hart]
        if not (self.domain_ie[domain] and idc.idelivery):
            return 0
        return int(bool(idc.iforce or self.topi(domain, hart)))


def idc_offset(domain: int, hart: int, word: int) -> int:
    """Window offset of an IDC register."""
    return DOMAIN_BASE[domain] + IDC + 32 * hart + word


def reg_offset(domain: int, reg: int) -> int:
    """Window offset of a register in a domain's control region."""
    return DOMAIN_BASE[domain] + reg
