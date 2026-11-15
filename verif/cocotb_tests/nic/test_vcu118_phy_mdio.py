#    Copyright (c) 2026 John Goodacre.
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


"""The VCU118 PHY management sequencer against a model of the DP83867's Clause-22 interface.

The model checks the PHY address, accepts the bootstrap writes (including the REGCR/ADDAR extended
register access) and answers RECR reads. A dummy write clears RECR; reading does not.
The reserved FCS diagnostic field stays zero, and polling leaves extended registers alone.
Waits are shortened by parameters (RST_BIT, SETTLE_BIT, POLL_BIT).
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

PHY_ADDR = 3
REG_BMCR, REG_REGCR, REG_ADDAR, REG_PHYCR, REG_RECR = 0x00, 0x0D, 0x0E, 0x10, 0x15
EXT_SECUREON_LOW = 0x0139


class Dp83867:
    """Bit-level Clause-22 slave on the shared MDIO line, stepped once per system clock."""

    def __init__(self, dut: Any) -> None:
        """Bind the sequencer's MDC/MDIO pins and set the counters the model reports."""
        self.dut = dut
        self.ack = True
        self.recr = 0
        self.direct: dict[int, int] = {}
        self.ext: dict[int, int] = {EXT_SECUREON_LOW: 0xBEEF}
        self.regcr_mode = 0
        self.addar = 0
        self.reads: list[tuple[str, int]] = []
        self.phy_out = 1  # the line level the PHY drives while it owns the line
        self.phy_drives = False
        self._ones = 0
        self._bits: list[int] = []
        self._read_slot = -1
        self._read_data = 0
        self._mdc = 0
        self._cycle = 0
        self._edge_cycle = 0

    def _line(self) -> int:
        if not int(self.dut.o_mdio_t.value):
            return int(self.dut.o_mdio_o.value)
        return self.phy_out if self.phy_drives else 1

    def _read_value(self, reg: int) -> int:
        if reg == REG_RECR:
            self.reads.append(("recr", self.recr))
            return self.recr
        if reg == REG_ADDAR and self.regcr_mode == 0x4000:
            value = self.ext.get(self.addar, 0)
            self.reads.append((f"ext{self.addar:04x}", value))
            return value
        return self.direct.get(reg, 0)

    def _write(self, reg: int, data: int) -> None:
        if reg == REG_RECR:
            self.recr = 0
        elif reg == REG_REGCR:
            self.regcr_mode = data & 0xC000
        elif reg == REG_ADDAR:
            if self.regcr_mode == 0x4000:
                self.ext[self.addar] = data
            else:
                self.addar = data
        else:
            self.direct[reg] = data

    def rising(self) -> None:
        """Process one MDC rising edge: the line level is the bit sampled."""
        bit = self._line()
        if self._read_slot >= 0:
            # n counts MDC rising edges since the header: 0 samples TA[1], 1 TA[0], 2..17 data.
            n = self._read_slot
            self._read_slot += 1
            if n == 0:
                self.phy_drives, self.phy_out = True, 0
            elif n <= 16:
                self.phy_out = (self._read_data >> (16 - n)) & 1
            else:
                self.phy_drives, self.phy_out = False, 1
                self._read_slot = -1
                self._bits = []
                self._ones = 0
            return
        if not self._bits:
            if bit:
                self._ones += 1
            elif self._ones >= 32:
                self._bits = [0]
            else:
                self._ones = 0
            return
        self._bits.append(bit)
        # 0 1 op1 op0 pa4..pa0 ra4..ra0 = 14 header bits
        if len(self._bits) == 14:
            assert self._bits[:2] == [0, 1], self._bits
            op = (self._bits[2] << 1) | self._bits[3]
            pa = int("".join(map(str, self._bits[4:9])), 2)
            ra = int("".join(map(str, self._bits[9:14])), 2)
            assert pa == PHY_ADDR, f"frame for PHY address {pa}"
            if op == 0b10:
                self._read_data = self._read_value(ra)
                self._reg = ra
                self._read_slot = 0
            else:
                assert op == 0b01, f"unexpected opcode {op}"
                self._reg = ra
        elif len(self._bits) == 14 + 18:
            # write: TA (1 0) then 16 data bits
            assert self._bits[14:16] == [1, 0], self._bits[14:16]
            data = int("".join(map(str, self._bits[16:])), 2)
            self._write(self._reg, data)
            self._bits = []
            self._ones = 0

    async def run(self) -> None:
        """Sample the pins once per clock and feed the line level back."""
        while True:
            await FallingEdge(self.dut.i_clk)
            if self.ack:
                self.dut.i_phy_diag_ack.value = int(self.dut.o_phy_diag.value) >> 32
            if not int(self.dut.o_phy_rst_n.value):
                self._bits = []
                self._ones = 0
                self._read_slot = -1
                self.phy_drives = False
                self.phy_out = 1
            self._cycle += 1
            mdc = int(self.dut.o_phy_mdc.value)
            if mdc != self._mdc:
                if int(self.dut.o_phy_rst_n.value):
                    width = self._cycle - self._edge_cycle
                    assert width >= 16, f"short MDC half-period: {width} clocks"
                    if not mdc:
                        assert width == 16, f"MDC high period: {width} clocks"
                self._edge_cycle = self._cycle
            if self.phy_drives:
                assert int(self.dut.o_mdio_t.value), (
                    "master drove during PHY turnaround/data"
                )
            if mdc and not self._mdc:
                self.rising()
            self._mdc = mdc
            self.dut.i_mdio_i.value = self._line()


async def _wait_poll(dut: Any, toggle: int) -> None:
    for _ in range(200000):
        await ClockCycles(dut.i_clk, 1)
        if (int(dut.o_phy_diag.value) >> 32) != toggle:
            return
    raise AssertionError("no poll completed")


@cocotb.test()
async def bootstrap_and_reserved_fcs_field(dut: Any) -> None:
    """Poll RECR with zero FCS despite a nonzero SecureOn password; preserve link configuration."""
    Clock(dut.i_clk, 20, unit="ns").start()
    dut.i_rst.value = 1
    dut.i_mdio_i.value = 1
    dut.i_phy_diag_ack.value = int(dut.o_phy_diag.value) >> 32
    phy = Dp83867(dut)
    phy.recr = 0x1234
    cocotb.start_soon(phy.run())
    await ClockCycles(dut.i_clk, 10)
    dut.i_rst.value = 0
    await ClockCycles(dut.i_clk, 200)
    assert not int(dut.o_phy_init_done.value)
    toggle = int(dut.o_phy_diag.value) >> 32
    await _wait_poll(dut, toggle)
    assert int(dut.o_phy_init_done.value) == 1
    assert int(dut.o_phy_rst_n.value) == 1
    assert phy.ext == {EXT_SECUREON_LOW: 0xBEEF, 0x31: 0x70, 0xD3: 0x4000, 0x16F: 0x15}
    assert phy.direct[REG_PHYCR] == 0x5848
    assert phy.direct[REG_BMCR] == 0x1340
    diag = int(dut.o_phy_diag.value)
    assert (diag & 0xFFFF, (diag >> 16) & 0xFFFF) == (0x1234, 0)
    assert phy.reads == [("recr", 0x1234)]
    # A later poll picks up new errors without disturbing link configuration or extended registers.
    phy.recr = 0x0007
    toggle = int(dut.o_phy_diag.value) >> 32
    await _wait_poll(dut, toggle)
    diag = int(dut.o_phy_diag.value)
    assert (diag & 0xFFFF, (diag >> 16) & 0xFFFF) == (0x0007, 0)
    assert phy.reads == [("recr", 0x1234), ("recr", 7)]
    assert phy.direct == {REG_PHYCR: 0x5848, REG_BMCR: 0x1340}
    assert phy.ext == {EXT_SECUREON_LOW: 0xBEEF, 0x31: 0x70, 0xD3: 0x4000, 0x16F: 0x15}


@cocotb.test()
async def receive_counter_is_cleared_after_read(dut: Any) -> None:
    """Clear an acknowledged RECR so unchanged errors are counted once."""
    Clock(dut.i_clk, 20, unit="ns").start()
    dut.i_rst.value = 1
    dut.i_mdio_i.value = 1
    dut.i_phy_diag_ack.value = int(dut.o_phy_diag.value) >> 32
    phy = Dp83867(dut)
    phy.recr = 0xFFFF
    cocotb.start_soon(phy.run())
    await ClockCycles(dut.i_clk, 10)
    dut.i_rst.value = 0
    toggle = int(dut.o_phy_diag.value) >> 32
    await _wait_poll(dut, toggle)
    assert phy.recr == 0, "RECR requires a dummy write; reading does not clear it"
    assert int(dut.o_phy_diag.value) & 0xFFFF == 0xFFFF, (
        "an acknowledged saturated value is valid"
    )
    toggle = int(dut.o_phy_diag.value) >> 32
    await _wait_poll(dut, toggle)
    assert int(dut.o_phy_diag.value) & 0xFFFF == 0, (
        "unchanged errors were sampled again"
    )


@cocotb.test()
async def missing_phy_does_not_publish(dut: Any) -> None:
    """Reject a released MDIO line without a turnaround response."""
    Clock(dut.i_clk, 20, unit="ns").start()
    dut.i_rst.value = 1
    dut.i_mdio_i.value = 1
    dut.i_phy_diag_ack.value = int(dut.o_phy_diag.value) >> 32
    await ClockCycles(dut.i_clk, 10)
    dut.i_rst.value = 0
    before = int(dut.o_phy_diag.value)
    for _ in range(800):
        await ClockCycles(dut.i_clk, 100)
        assert int(dut.o_phy_diag.value) == before, "unanswered MDIO poll was published"
    assert int(dut.o_phy_init_done.value)


@cocotb.test()
async def published_sample_waits_for_acknowledgement(dut: Any) -> None:
    """Preserve a pending sample across a stopped consumer and source reset."""
    Clock(dut.i_clk, 20, unit="ns").start()
    dut.i_rst.value = 1
    dut.i_mdio_i.value = 1
    dut.i_phy_diag_ack.value = int(dut.o_phy_diag.value) >> 32
    phy = Dp83867(dut)
    phy.ack = False
    phy.recr = 9
    cocotb.start_soon(phy.run())
    await ClockCycles(dut.i_clk, 10)
    dut.i_rst.value = 0
    toggle = int(dut.o_phy_diag.value) >> 32
    await _wait_poll(dut, toggle)
    published = int(dut.o_phy_diag.value)
    phy.recr = 17
    await ClockCycles(dut.i_clk, 50000)
    assert int(dut.o_phy_diag.value) == published
    dut.i_rst.value = 1
    await ClockCycles(dut.i_clk, 10)
    dut.i_rst.value = 0
    await ClockCycles(dut.i_clk, 50000)
    assert int(dut.o_phy_diag.value) == published
    phy.ack = True
    await _wait_poll(dut, published >> 32)
    assert int(dut.o_phy_diag.value) & 0xFFFF == 17
