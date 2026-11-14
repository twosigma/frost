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
register access) and answers the two counter reads of the poll: RECR directly and the FCS counter
through ADDAR. Waits are shortened by parameters (RST_BIT, SETTLE_BIT, POLL_BIT).
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

PHY_ADDR = 3
REG_BMCR, REG_REGCR, REG_ADDAR, REG_PHYCR, REG_RECR = 0x00, 0x0D, 0x0E, 0x10, 0x15
EXT_FCS_COUNTER = 0x0139


class Dp83867:
    """Bit-level Clause-22 slave on the shared MDIO line, stepped once per system clock."""

    def __init__(self, dut: Any) -> None:
        """Bind the sequencer's MDC/MDIO pins and set the counters the model reports."""
        self.dut = dut
        self.recr = 0
        self.fcs = 0
        self.direct: dict[int, int] = {}
        self.ext: dict[int, int] = {}
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

    def _line(self) -> int:
        if not int(self.dut.o_mdio_t.value):
            return int(self.dut.o_mdio_o.value)
        return self.phy_out if self.phy_drives else 1

    def _read_value(self, reg: int) -> int:
        if reg == REG_RECR:
            self.reads.append(("recr", self.recr))
            return self.recr
        if reg == REG_ADDAR and self.regcr_mode == 0x4000:
            value = self.fcs if self.addar == EXT_FCS_COUNTER else 0
            self.reads.append((f"ext{self.addar:04x}", value))
            return value
        return self.direct.get(reg, 0)

    def _write(self, reg: int, data: int) -> None:
        if reg == REG_REGCR:
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
            mdc = int(self.dut.o_phy_mdc.value)
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
async def bootstrap_writes_and_counter_polls(dut: Any) -> None:
    """Land the init writes, raise init_done, and deliver both counters and a toggle per poll."""
    Clock(dut.i_clk, 20, unit="ns").start()
    dut.i_rst.value = 1
    dut.i_mdio_i.value = 1
    phy = Dp83867(dut)
    phy.recr, phy.fcs = 0x1234, 0x00AB
    cocotb.start_soon(phy.run())
    await ClockCycles(dut.i_clk, 10)
    dut.i_rst.value = 0
    await ClockCycles(dut.i_clk, 200)
    assert not int(dut.o_phy_init_done.value)
    toggle = int(dut.o_phy_diag.value) >> 32
    await _wait_poll(dut, toggle)
    assert int(dut.o_phy_init_done.value) == 1
    assert int(dut.o_phy_rst_n.value) == 1
    assert phy.ext == {0x31: 0x70, 0xD3: 0x4000, 0x16F: 0x15}
    assert phy.direct[REG_PHYCR] == 0x5848
    assert phy.direct[REG_BMCR] == 0x1340
    diag = int(dut.o_phy_diag.value)
    assert (diag & 0xFFFF, (diag >> 16) & 0xFFFF) == (0x1234, 0x00AB)
    assert phy.reads[:2] == [("recr", 0x1234), (f"ext{EXT_FCS_COUNTER:04x}", 0x00AB)]
    # A later poll picks up new counter values and flips the toggle again
    phy.recr, phy.fcs = 0x0007, 0xFFFE
    toggle = int(dut.o_phy_diag.value) >> 32
    await _wait_poll(dut, toggle)
    diag = int(dut.o_phy_diag.value)
    assert (diag & 0xFFFF, (diag >> 16) & 0xFFFF) == (0x0007, 0xFFFE)
    assert len(phy.reads) == 4
