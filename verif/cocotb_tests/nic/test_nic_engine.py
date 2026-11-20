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

"""Exercise nic_engine standalone against a Python AXI4-Stream MAC model.

Proves that nic_engine operates across its core-clock 64-bit AXI4-Stream and
sideband boundary with no MAC RTL attached: frame TX/RX across every TKEEP
termination lane, TX checksum metadata and abort signalling, MAC sideband
controls and counters, and RESET restart pulses.
"""

from collections import deque
import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from cocotb_tests.axi.axil_model import AxilMaster
from cocotb_tests.nic.dma_model import (
    ABORT,
    DONE,
    ERR,
    FIRST,
    LAST,
    Memory,
    desc_status,
    post_desc,
)
from cocotb_tests.nic.test_nic_top import (
    ABI_CTRL,
    ABI_RX_CSUM,
    CNT_RX_BYTES,
    CNT_RX_FRAMES,
    CNT_TX_BYTES,
    CNT_TX_FRAMES,
    COUNTERS,
    COUNTERS_EXT,
    CTRL,
    CTRL_PROMISC,
    CTRL_RESET,
    CTRL_RX_EN,
    CTRL_TX_EN,
    ID,
    IRQ_LINK,
    IRQ_MASK,
    IRQ_STATUS,
    LINK,
    LINK_CARRIER,
    MAC_HI,
    MAC_LO,
    NUM_BASE_COUNTERS,
    PAUSE_CTRL,
    PAUSE_HIGH_WATER,
    PAUSE_INTERVAL,
    PAUSE_LOW_WATER,
    PHY_CTRL,
    PHY_STATUS,
    RX_BASE,
    RX_BUF,
    RX_FIFO_LIMIT,
    RX_HEAD,
    RX_RING,
    RX_SIZE,
    RX_SIZE_LOG2,
    RX_TAIL,
    STATION,
    ST_RESET_BUSY,
    ST_RX_IDLE,
    ST_RX_READY,
    ST_TX_IDLE,
    ST_TX_READY,
    STATUS,
    TX_BASE,
    TX_BUF,
    TX_HEAD,
    TX_RING,
    TX_SIZE,
    TX_SIZE_LOG2,
    TX_TAIL,
    _AxiPort,
)

CORE_PS = 3334


def _counter_offset(index: int) -> int:
    if index < NUM_BASE_COUNTERS:
        return COUNTERS + 8 * index
    return COUNTERS_EXT + 8 * (index - NUM_BASE_COUNTERS)


class _AxisMacModel:
    """Core-clock 64-bit AXI4-Stream MAC peer with optional loopback and stalls."""

    def __init__(self, dut: Any, seed: int) -> None:
        self.dut = dut
        self.rng = random.Random(seed)
        self.loopback = True
        self.stall_tx = True
        self.tx_frames: list[tuple[bytes, int, bool]] = []
        self.rx_queue: deque[bytes] = deque()
        self.restarts = 0
        self.limit_writes: list[int] = []
        self._limit_busy = 0
        self.ready_bits = 3
        # RX_CLK_OK | TX_CLK_OK | RX_SIGNAL_OK | TX_LINK_READY | RX_LOCKED -> CARRIER=1.
        self.link_bits = 0xF1
        self.raw_loopback_en = 1
        self.totals = [0] * 21

    def pack_totals(self) -> int:
        value = 0
        for idx, count in enumerate(self.totals):
            value |= (count & ((1 << 64) - 1)) << (64 * idx)
        return value

    async def run(self) -> None:
        dut = self.dut
        tx_buf = bytearray()
        tx_csum_first: int | None = None
        rx_beats: deque[tuple[int, int, int]] = deque()
        while True:
            await FallingEdge(dut.i_clk)
            dut.i_mac_ready.value = self.ready_bits
            dut.i_mac_link.value = self.link_bits
            dut.i_mac_raw_loopback_en.value = self.raw_loopback_en
            dut.i_mac_totals.value = self.pack_totals()
            dut.i_mac_rx_fifo_limit_busy.value = int(self._limit_busy > 0)

            tx_ready = 0 if (self.stall_tx and self.rng.randrange(4) == 0) else 1
            dut.i_mac_tx_tready.value = tx_ready

            if not rx_beats and self.rx_queue:
                frame = self.rx_queue.popleft()
                for off in range(0, len(frame), 8):
                    chunk = frame[off : off + 8]
                    keep = (1 << len(chunk)) - 1
                    last = int(off + 8 >= len(frame))
                    rx_beats.append((int.from_bytes(chunk, "little"), keep, last))
            if rx_beats:
                data, keep, last = rx_beats[0]
                dut.i_mac_rx_tvalid.value = 1
                dut.i_mac_rx_tdata.value = data
                dut.i_mac_rx_tkeep.value = keep
                dut.i_mac_rx_tlast.value = last
            else:
                dut.i_mac_rx_tvalid.value = 0
                dut.i_mac_rx_tdata.value = 0
                dut.i_mac_rx_tkeep.value = 0
                dut.i_mac_rx_tlast.value = 0

            await RisingEdge(dut.i_clk)
            if int(dut.o_mac_rst.value):
                tx_buf.clear()
                tx_csum_first = None
                rx_beats.clear()
                self._limit_busy = 0
                continue
            if int(dut.o_mac_restart.value):
                self.restarts += 1
            if int(dut.o_mac_rx_fifo_limit_wr.value):
                self.limit_writes.append(int(dut.o_mac_rx_fifo_limit.value))
                self._limit_busy = 3
            elif self._limit_busy > 0:
                self._limit_busy -= 1

            if tx_ready and int(dut.o_mac_tx_tvalid.value):
                keep = int(dut.o_mac_tx_tkeep.value)
                assert keep in {0x01, 0x03, 0x07, 0x0F, 0x1F, 0x3F, 0x7F, 0xFF}, (
                    f"non-contiguous TX tkeep: {hex(keep)}"
                )
                nbytes = keep.bit_count()
                csum = int(dut.o_mac_tx_csum.value)
                if tx_csum_first is None:
                    tx_csum_first = csum
                else:
                    assert csum == tx_csum_first, "TX csum changed mid-frame"
                word = int(dut.o_mac_tx_tdata.value).to_bytes(8, "little")
                tx_buf.extend(word[:nbytes])
                last = bool(int(dut.o_mac_tx_tlast.value))
                abort = bool(int(dut.o_mac_tx_tuser.value))
                if last or abort:
                    frame_bytes = bytes(tx_buf)
                    self.tx_frames.append((frame_bytes, tx_csum_first, abort))
                    if self.loopback and not abort:
                        self.rx_queue.append(frame_bytes)
                    tx_buf.clear()
                    tx_csum_first = None

            if rx_beats and int(dut.o_mac_rx_tready.value):
                rx_beats.popleft()


class _EngineBench:
    def __init__(self, dut: Any, seed: int) -> None:
        self.dut = dut
        self.seed = seed
        self.mem = Memory()
        self.dma: _AxiPort | None = None
        self.regs = AxilMaster(dut, "reg_axil")
        self.mac = _AxisMacModel(dut, seed + 17)
        self.tasks: list[Any] = []
        self.tx_tail = 0
        self.rx_tail = 0

    async def start(self) -> None:
        dut = self.dut
        Clock(dut.i_clk, CORE_PS, unit="ps").start()
        self.regs.idle()
        for sig in (
            dut.i_dma_axi_awready,
            dut.i_dma_axi_wready,
            dut.i_dma_axi_bvalid,
            dut.i_dma_axi_bid,
            dut.i_dma_axi_bresp,
            dut.i_dma_axi_arready,
            dut.i_dma_axi_rvalid,
            dut.i_dma_axi_rid,
            dut.i_dma_axi_rdata,
            dut.i_dma_axi_rresp,
            dut.i_dma_axi_rlast,
            dut.i_mac_tx_tready,
            dut.i_mac_rx_tvalid,
            dut.i_mac_rx_tdata,
            dut.i_mac_rx_tkeep,
            dut.i_mac_rx_tlast,
            dut.i_mac_ready,
            dut.i_mac_link,
            dut.i_mac_raw_loopback_en,
            dut.i_mac_rx_fifo_limit_busy,
            dut.i_mac_totals,
            dut.i_phy_diag,
        ):
            sig.value = 0
        dut.i_phy_status.value = 0xF
        dut.i_rst.value = 1
        self.dma = _AxiPort(dut, self.mem, self.seed)
        self.tasks = [
            self.dma._task,
            cocotb.start_soon(self.mac.run()),
        ]
        await self.cycles(6)
        await FallingEdge(dut.i_clk)
        dut.i_rst.value = 0
        await self.wait_status(ST_RESET_BUSY, 0)
        await self.wait_status(ST_RX_READY | ST_TX_READY, ST_RX_READY | ST_TX_READY)

    def stop(self) -> None:
        for task in self.tasks:
            task.cancel()

    async def cycles(self, count: int) -> None:
        for _ in range(count):
            await RisingEdge(self.dut.i_clk)

    async def wr(self, offset: int, value: int) -> None:
        strb = 0xF0 if offset & 4 else 0x0F
        await self.regs.write(offset, (value << 32) | value, strb)

    async def rd(self, offset: int) -> int:
        pair = await self.regs.read(offset)
        return (pair >> (32 if offset & 4 else 0)) & 0xFFFFFFFF

    async def rd64(self, offset: int) -> int:
        return await self.regs.read(offset)

    async def wait_status(self, mask: int, want: int, limit: int = 500) -> int:
        for _ in range(limit):
            st = await self.rd(STATUS)
            if (st & mask) == want:
                return st
            await self.cycles(1)
        raise AssertionError(
            f"STATUS {hex(await self.rd(STATUS))} != {hex(want)} (mask {hex(mask)})"
        )

    async def program_rings(self, promisc: bool = False) -> None:
        await self.wr(MAC_LO, int.from_bytes(STATION[:4], "little"))
        await self.wr(MAC_HI, int.from_bytes(STATION[4:], "little"))
        await self.wr(RX_BASE, RX_RING)
        await self.wr(RX_SIZE, RX_SIZE_LOG2)
        await self.wr(TX_BASE, TX_RING)
        await self.wr(TX_SIZE, TX_SIZE_LOG2)
        for slot in range(1 << RX_SIZE_LOG2):
            post_desc(self.mem, RX_RING, slot, RX_BUF + slot * 2048, 2048)
        self.rx_tail = (1 << RX_SIZE_LOG2) - 1
        await self.wr(RX_TAIL, self.rx_tail)
        ctrl = CTRL_RX_EN | CTRL_TX_EN | (CTRL_PROMISC if promisc else 0)
        await self.wr(CTRL, ctrl)

    async def send_tx(self, frame: bytes, flags: int = FIRST | LAST) -> int:
        slot = self.tx_tail
        buf = TX_BUF + slot * 2048
        self.mem.write_bytes(buf, frame)
        post_desc(self.mem, TX_RING, slot, buf, len(frame) | flags)
        self.tx_tail = (self.tx_tail + 1) & ((1 << TX_SIZE_LOG2) - 1)
        await self.wr(TX_TAIL, self.tx_tail)
        return slot

    async def wait_desc(self, ring: int, slot: int, limit: int = 3000) -> int:
        for _ in range(limit):
            st = desc_status(self.mem, ring, slot)
            if st & DONE:
                return st
            await self.cycles(2)
        raise AssertionError(f"descriptor {slot} on ring {hex(ring)} did not complete")


@cocotb.test()
async def axis_loopback_all_keep_lanes(dut: Any) -> None:
    """Loop back frames of every TKEEP termination length over core-clock AXIS."""
    bench = _EngineBench(dut, seed=101)
    await bench.start()
    assert await bench.rd(ID) == 0x4E494301
    assert bench.mac.restarts == 1
    await bench.program_rings()

    lengths = [60, 61, 62, 63, 64, 65, 66, 67, 68, 255, 1514]
    total_bytes = 0
    for rx_slot, length in enumerate(lengths):
        frame = STATION + bytes((rx_slot * 31 + i) & 0xFF for i in range(length - 6))
        tx_slot = await bench.send_tx(frame)
        tx_st = await bench.wait_desc(TX_RING, tx_slot)
        assert tx_st == DONE, hex(tx_st)
        rx_st = await bench.wait_desc(RX_RING, rx_slot)
        assert rx_st == (DONE | length), hex(rx_st)
        got = bench.mem.read_bytes(RX_BUF + rx_slot * 2048, length)
        assert got == frame, (length, got[:16], frame[:16])
        total_bytes += length

    # Status writes apply on request acceptance; counters increment when B returns.
    await bench.cycles(30)
    assert await bench.rd64(_counter_offset(CNT_TX_FRAMES)) == len(lengths)
    assert await bench.rd64(_counter_offset(CNT_RX_FRAMES)) == len(lengths)
    assert await bench.rd64(_counter_offset(CNT_TX_BYTES)) == total_bytes
    assert await bench.rd64(_counter_offset(CNT_RX_BYTES)) == total_bytes
    assert await bench.rd(TX_HEAD) == len(lengths)
    assert await bench.rd(RX_HEAD) == len(lengths)
    assert len(bench.mac.tx_frames) == len(lengths)
    bench.stop()


@cocotb.test()
async def sideband_controls_counters_and_reset(dut: Any) -> None:
    """Verify MAC sideband wiring, CLK_SHARED masking, MAC totals and RESET."""
    bench = _EngineBench(dut, seed=202)
    await bench.start()

    # RAW_LOOPBACK capability masks PHY_STATUS.CLK_SHARED (bit 0).
    await bench.cycles(6)
    assert (await bench.rd(PHY_STATUS) & 1) == 1
    bench.mac.raw_loopback_en = 0
    await bench.cycles(4)
    assert (await bench.rd(PHY_STATUS) & 1) == 0
    bench.mac.raw_loopback_en = 1

    # Station MAC, loopback bit, RX FIFO limit, and pause registers cross sideband.
    await bench.wr(MAC_LO, int.from_bytes(STATION[:4], "little"))
    await bench.wr(MAC_HI, int.from_bytes(STATION[4:], "little"))
    await bench.wr(PHY_CTRL, 0x0F)
    await bench.wr(PAUSE_HIGH_WATER, 100)
    await bench.wr(PAUSE_LOW_WATER, 20)
    await bench.wr(PAUSE_INTERVAL, 0x1234)
    await bench.wr(PAUSE_CTRL, 3)
    await bench.wr(RX_FIFO_LIMIT, 128)
    await bench.cycles(10)
    assert int(dut.o_mac_station_addr.value) == int.from_bytes(STATION, "little")
    assert int(dut.o_mac_loopback.value) == 1
    assert int(dut.o_phy_ctrl.value) == 0x7
    assert int(dut.o_mac_pause_ctrl.value) == 3
    assert int(dut.o_mac_pause_high_water.value) == 100
    assert int(dut.o_mac_pause_low_water.value) == 20
    assert int(dut.o_mac_pause_interval.value) == 0x1234
    assert 128 in bench.mac.limit_writes

    # Link status vector and link-change interrupt (CARRIER 1 -> 0).
    assert (await bench.rd(LINK) & LINK_CARRIER) != 0
    await bench.wr(IRQ_MASK, IRQ_LINK)
    await bench.wr(IRQ_STATUS, IRQ_LINK)
    bench.mac.link_bits = 0x55
    await bench.cycles(4)
    assert (await bench.rd(LINK) & 0xFF) == 0x55
    assert (await bench.rd(LINK) & LINK_CARRIER) == 0
    assert (await bench.rd(IRQ_STATUS) & IRQ_LINK) != 0
    assert int(dut.o_irq.value) == 1
    await bench.wr(IRQ_STATUS, IRQ_LINK)
    assert int(dut.o_irq.value) == 0

    # All 21 MAC totals map to CSR counters 10..30.
    bench.mac.totals = [0x1000_0000_0000 + i * 7 + 1 for i in range(21)]
    await bench.cycles(4)
    for i in range(21):
        assert await bench.rd64(_counter_offset(10 + i)) == bench.mac.totals[i], i

    # CTRL.RESET pulses o_mac_restart once after DMA drains and leaves engines idle.
    before_restarts = bench.mac.restarts
    await bench.wr(CTRL, CTRL_RESET)
    await bench.wait_status(ST_RESET_BUSY, 0)
    assert bench.mac.restarts == before_restarts + 1
    st = await bench.rd(STATUS)
    assert (st & (ST_RX_IDLE | ST_TX_IDLE)) == (ST_RX_IDLE | ST_TX_IDLE)

    # RX checksum mode and aborted TX frame (o_mac_tx_tuser = 1).
    await bench.wr(ABI_CTRL, ABI_RX_CSUM)
    await bench.program_rings(promisc=True)
    bench.mac.loopback = False
    # Post a 2-descriptor frame where the second descriptor has an out-of-aperture address.
    good_seg = STATION + bytes(range(60))
    self_buf = TX_BUF
    bench.mem.write_bytes(self_buf, good_seg)
    post_desc(bench.mem, TX_RING, 0, self_buf, len(good_seg) | FIRST)
    post_desc(bench.mem, TX_RING, 1, 0x0000_1000, 64 | LAST)
    bench.tx_tail = 2
    await bench.wr(TX_TAIL, bench.tx_tail)
    st0 = await bench.wait_desc(TX_RING, 0)
    st1 = await bench.wait_desc(TX_RING, 1)
    assert (st0 & DONE) and (st1 & (DONE | ERR | ABORT)) == (DONE | ERR | ABORT)
    await bench.cycles(20)
    assert any(abort for _, _, abort in bench.mac.tx_frames), (
        "aborted TX frame did not assert o_mac_tx_tuser"
    )
    bench.stop()
