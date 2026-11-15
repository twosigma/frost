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

"""nic_top with the GMII MAC: every diagnostic counter (21..35) reads back at its register.

The NIC is built with GMII_MODE = 1 and RX_PREAMBLE_ER_TOLERANT = 1. GMII symbols, the PCS
status_vector and the acknowledged PHY management bus (i_phy_diag/o_phy_diag_ack) are driven; counters 21..30
are the MAC-domain totals, 31..35 the PHY counters, all read at 0x140 + 8 * (n - 21). A RESET clears
the PHY counters and a toggle that does not change afterwards is not a poll.
"""

from collections import deque
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer

from cocotb_tests.axi.axil_model import AxilMaster
from cocotb_tests.nic.test_nic_mac_gmii import _wire_frame
from cocotb_tests.nic.test_nic_top import (
    CTRL,
    CTRL_RESET,
    CTRL_RX_EN,
    RX_BASE,
    RX_RING,
    RX_SIZE,
    RX_SIZE_LOG2,
    ST_RESET_BUSY,
    STATUS,
)

COUNTERS, COUNTERS_EXT, NUM_BASE = 0x080, 0x140, 21
(ER_PREAMBLE, ER_EXT, SHORT_IFG, PRE_ACCEPT, NO_DESC) = range(21, 26)
(SYNC_LOSS, RUDI_C, RUDI_INVALID, RXDISPERR, RXNOTINTABLE) = range(26, 31)
PHY_RXERR_LAST, PHY_RXERR_SUM, PHY_FCS_LAST, PHY_FCS_SUM, PHY_POLLS = range(31, 36)
PREAMBLE_DROP, RX_ER = 16, 17


def _offset(index: int) -> int:
    if index < NUM_BASE:
        return COUNTERS + 8 * index
    return COUNTERS_EXT + 8 * (index - NUM_BASE)


class _Bench:
    def __init__(self, dut: Any) -> None:
        self.dut = dut
        self.regs = AxilMaster(dut, "reg_axil")
        self.symbols: deque[int] = deque()
        self.status = 0
        self.core_clock: Clock | None = None

    async def rd64(self, off: int) -> int:
        return await self.regs.read(off)

    async def wr(self, off: int, val: int) -> None:
        await self.regs.write(off, (val << 32) | val, 0xF0 if off & 4 else 0x0F)

    async def count(self, index: int) -> int:
        return await self.rd64(_offset(index))

    async def drive(self) -> None:
        while True:
            await FallingEdge(self.dut.i_rx_clk)
            symbol = self.symbols.popleft() if self.symbols else 0
            self.dut.i_rx_raw_data.value = symbol | (self.status << 10)

    async def drain(self) -> None:
        while self.symbols:
            await RisingEdge(self.dut.i_rx_clk)
        await ClockCycles(self.dut.i_clk, 300)

    async def poll(self, recr: int, fcs: int, toggle: int) -> None:
        """Present new values, then flip the toggle once they have been stable."""
        self.dut.i_phy_diag.value = (toggle ^ 1) << 32 | fcs << 16 | recr
        await ClockCycles(self.dut.i_clk, 4)
        self.dut.i_phy_diag.value = toggle << 32 | fcs << 16 | recr
        await ClockCycles(self.dut.i_clk, 20)
        assert int(self.dut.o_phy_diag_ack.value) == toggle


async def _start(dut: Any, core_ps: int = 3334) -> _Bench:
    Clock(dut.i_tx_clk, 8000, unit="ps").start()
    Clock(dut.i_rx_clk, 8000, unit="ps").start()
    bench = _Bench(dut)
    bench.core_clock = Clock(dut.i_clk, core_ps, unit="ps")
    bench.core_clock.start()
    bench.regs.idle()
    for sig in (
        dut.i_dma_axi_awready,
        dut.i_dma_axi_wready,
        dut.i_dma_axi_arready,
        dut.i_dma_axi_bvalid,
        dut.i_dma_axi_rvalid,
        dut.i_rx_raw_data,
        dut.i_phy_diag,
    ):
        sig.value = 0
    dut.i_rx_raw_valid.value = 1
    dut.i_tx_clk_ok.value = 1
    dut.i_rx_clk_ok.value = 1
    dut.i_phy_status.value = 0xF
    dut.i_rx_signal_ok.value = 1
    dut.i_rst.value = 1
    await ClockCycles(dut.i_clk, 5)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await ClockCycles(dut.i_clk, 200)
    cocotb.start_soon(bench.drive())
    return bench


@cocotb.test()
async def supported_diagnostics_and_reserved_fcs_slots_read_back(dut: Any) -> None:
    """Read supported diagnostics at their offsets while both reserved FCS slots stay zero."""
    bench = await _start(dut)
    # An empty RX ring: enabled, so frames queue in the FIFO with no descriptor to take them.
    await bench.wr(RX_BASE, RX_RING)
    await bench.wr(RX_SIZE, RX_SIZE_LOG2)
    await bench.wr(CTRL, CTRL_RX_EN)
    await ClockCycles(dut.i_clk, 20)

    wire = _wire_frame(bytes(range(80)))
    # rx_er in a preamble (tolerated), carrier extend twice, and a gap of eight byte times.
    bench.symbols.extend(
        b | 0x100 | (0x200 if i == 3 else 0) for i, b in enumerate(wire)
    )
    bench.symbols.extend([0] * 12)
    bench.symbols.extend([0x20F] * 3 + [0] * 12 + [0x21F] + [0] * 12)
    bench.symbols.extend(b | 0x100 for b in wire)
    bench.symbols.extend([0] * 8)
    bench.symbols.extend(b | 0x100 for b in wire)
    bench.symbols.extend([0] * 12)
    await bench.drain()
    # PCS status_vector events.
    for status in (
        0x0002,
        0,
        0x0002,
        0x0006,
        0x0002,
        0x0012,
        0x0002,
        0x0022,
        0x0042,
        0x0002,
    ):
        bench.status = status
        await ClockCycles(dut.i_rx_clk, 4)
    await ClockCycles(dut.i_clk, 300)
    # MAC overflow with the engine starved: far more frames than the MAC and FIFO hold.
    for _ in range(700):
        bench.symbols.extend(b | 0x100 for b in wire)
        bench.symbols.extend([0] * 12)
    await bench.drain()
    # The DP83867 publisher preserves the bus layout and zeros its reserved FCS field.
    await bench.poll(5, 0, 1)
    await bench.poll(7, 0, 0)

    for index in range(ER_PREAMBLE, PHY_POLLS + 1):
        if index not in (PHY_FCS_LAST, PHY_FCS_SUM):
            assert await bench.count(index) != 0, (
                f"counter {index} at {_offset(index):#x}"
            )
    assert await bench.count(ER_PREAMBLE) == 1
    assert await bench.count(PRE_ACCEPT) == 1
    assert await bench.count(ER_EXT) == 2
    assert await bench.count(SHORT_IFG) == 1
    assert await bench.count(SYNC_LOSS) == 1
    assert await bench.count(RUDI_C) == 1
    assert await bench.count(RUDI_INVALID) == 1
    assert await bench.count(RXDISPERR) >= 1
    assert await bench.count(RXNOTINTABLE) >= 1
    assert await bench.count(NO_DESC) > 0
    assert await bench.count(PREAMBLE_DROP) == 0
    assert await bench.count(PHY_RXERR_LAST) == 7
    assert await bench.count(PHY_RXERR_SUM) == 12
    assert await bench.count(PHY_FCS_LAST) == 0
    assert await bench.count(PHY_FCS_SUM) == 0
    assert await bench.count(PHY_POLLS) == 2

    # RESET clears the PHY counters; the held toggle is not a new poll.
    await bench.wr(CTRL, CTRL_RESET)
    await ClockCycles(dut.i_clk, 20)
    for _ in range(2000):
        if not await bench.rd64(STATUS) & ST_RESET_BUSY:
            break
    await ClockCycles(dut.i_clk, 100)
    for index in (PHY_RXERR_LAST, PHY_RXERR_SUM, PHY_FCS_LAST, PHY_FCS_SUM, PHY_POLLS):
        assert await bench.count(index) == 0, index
    await bench.poll(9, 0, 1)
    assert await bench.count(PHY_POLLS) == 1
    assert await bench.count(PHY_RXERR_SUM) == 9


@cocotb.test()
async def phy_transfer_survives_slow_clock_and_reset(dut: Any) -> None:
    """Capture each held sample once, discard transfers during reset, and resume after a stop."""
    bench = await _start(dut, core_ps=31000)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 1
    dut.i_phy_diag.value = (1 << 32) | 7
    await ClockCycles(dut.i_clk, 20)
    assert int(dut.o_phy_diag_ack.value) == 1
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await ClockCycles(dut.i_clk, 200)
    assert await bench.count(PHY_POLLS) == 0
    assert await bench.count(PHY_RXERR_SUM) == 0
    await bench.poll(9, 0, 0)
    assert await bench.count(PHY_POLLS) == 1
    assert await bench.count(PHY_RXERR_SUM) == 9
    assert bench.core_clock is not None
    await FallingEdge(dut.i_clk)
    bench.core_clock.stop()
    dut.i_phy_diag.value = (1 << 32) | 13
    await Timer(17000, unit="ns")
    assert int(dut.o_phy_diag_ack.value) == 0
    bench.core_clock.start()
    await ClockCycles(dut.i_clk, 30)
    assert int(dut.o_phy_diag_ack.value) == 1
    assert await bench.count(PHY_POLLS) == 2
    assert await bench.count(PHY_RXERR_SUM) == 22
    assert await bench.count(PHY_FCS_SUM) == 0
    await ClockCycles(dut.i_clk, 30)
    assert await bench.count(PHY_POLLS) == 2
