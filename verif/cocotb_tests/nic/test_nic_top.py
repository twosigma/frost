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

"""Tests for the whole NIC (hw/rtl/peripherals/nic/nic_top.sv).

Three clocks: the core clock and the MAC's TX and RX clocks (one period,
phase-aligned, as on the loopback build). The DMA line port is answered by
a memory model with out-of-order responses; registers are driven the way
the SoC does (32-bit lane writes, a 64-bit read pair by offset). Frames go
around through the raw loopback inside nic_mac_wrap, or come from the
net10g software wire model (an independent 64b/66b encoder) and go out to
its receiver.
"""

import random
from collections import deque
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from cocotb_tests.nic.dma_model import DD, EOP, SOP, Memory, desc_status, post_desc
from net10g.test_codec import encode_reference
from net10g.test_integration import WireReceiver, frame_words
from net10g.test_scrambler import SerialReference

CORE_PS = 3334
MAC_PS = 6206
LINE = 32

# Register map (nic_pkg).
ID, CTRL, STATUS, MAC_LO, MAC_HI = 0x000, 0x004, 0x008, 0x00C, 0x010
RX_BASE, RX_SIZE, RX_TAIL, RX_HEAD = 0x020, 0x024, 0x028, 0x02C
TX_BASE, TX_SIZE, TX_TAIL, TX_HEAD = 0x030, 0x034, 0x038, 0x03C
IRQ_STATUS, IRQ_MASK, RX_ITR, TX_ITR, TICK = 0x040, 0x044, 0x048, 0x04C, 0x050
LINK, PHY_CTRL, PHY_STATUS, COUNTERS = 0x060, 0x064, 0x068, 0x080
CTRL_RX_EN, CTRL_TX_EN, CTRL_PROMISC, CTRL_RESET = 1, 2, 4, 0x100
ST_RX_IDLE, ST_TX_IDLE, ST_RESET_BUSY, ST_RX_FIFO_EMPTY = 1, 2, 4, 8
ST_RX_READY, ST_TX_READY, ST_RX_CONFIG_ERR, ST_TX_CONFIG_ERR = 0x10, 0x20, 0x40, 0x80
IRQ_RX, IRQ_TX, IRQ_RX_DROP, IRQ_LINK, IRQ_DESC_ERR = 1, 2, 4, 8, 16
LINK_CARRIER = 1 << 8
CNT_RX_FRAMES, CNT_RX_BYTES, CNT_RX_FILTERED, CNT_TX_FRAMES, CNT_TX_BYTES = (
    0,
    1,
    2,
    6,
    7,
)

RX_RING, TX_RING = 0x8010_0000, 0x8011_0000
RX_SIZE_LOG2, TX_SIZE_LOG2 = 4, 4
RX_BUF, TX_BUF = 0x8020_0000, 0x8030_0000
STATION = bytes([0x02, 0x11, 0x22, 0x33, 0x44, 0x55])
OTHER = bytes([0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
BROADCAST = bytes([0xFF] * 6)


class _LinePort:
    """The coherent DMA port: a memory, random acceptance gaps, reordered responses."""

    def __init__(self, dut: Any, mem: Memory, seed: int) -> None:
        self.dut = dut
        self.mem = mem
        self.rng = random.Random(seed)
        self.pending: list[list[Any]] = []
        self.requests = 0
        self.writes = 0
        self._task = cocotb.start_soon(self._run())

    async def _run(self) -> None:
        dut = self.dut
        dut.i_dma_req_ready.value = 0
        dut.i_dma_resp_valid.value = 0
        while True:
            await FallingEdge(dut.i_clk)
            dut.i_dma_resp_valid.value = 0
            ready_ones = [p for p in self.pending if p[0] <= 0]
            if ready_ones:
                p = self.rng.choice(ready_ones)
                self.pending.remove(p)
                dut.i_dma_resp_valid.value = 1
                dut.i_dma_resp_id.value = p[1]
                dut.i_dma_resp_rdata.value = p[2]
            for p in self.pending:
                p[0] -= 1
            if (
                int(dut.o_dma_req_valid.value) == 1
                and len(self.pending) < 3
                and self.rng.random() >= 0.15
            ):
                dut.i_dma_req_ready.value = 1
                addr = int(dut.o_dma_req_addr.value)
                assert (
                    0x8000_0000 <= addr < 0xC000_0000
                ), f"request outside the aperture: {addr:#x}"
                rid = int(dut.o_dma_req_id.value)
                rdata = 0
                if int(dut.o_dma_req_write.value):
                    self.writes += 1
                    wdata = int(dut.o_dma_req_wdata.value)
                    wstrb = int(dut.o_dma_req_wstrb.value)
                    for b in range(LINE):
                        if (wstrb >> b) & 1:
                            self.mem.write(addr + b, (wdata >> (8 * b)) & 0xFF)
                else:
                    rdata = self.mem.read_line(addr)
                self.requests += 1
                self.pending.append([self.rng.randint(2, 10), rid, rdata])
            else:
                dut.i_dma_req_ready.value = 0

    def stop(self) -> None:
        self._task.cancel()


class _Wire:
    """The software wire on both sides of the raw PMA interface.

    Toward raw RX: a continuous idle stream with frames spliced in, one
    scrambler state for the whole test. From raw TX: the net10g receiver,
    restarted at every gap in valid (the PCS TX emits continuously once out
    of reset, so a gap is a reset).
    """

    IDLE = (0x0707070707070707, 0xFF)

    def __init__(self, dut: Any) -> None:
        self.dut = dut
        self.incoming: deque[int] = deque()
        self.words: deque[tuple[int, int]] = deque()
        self._scrambler = SerialReference()
        self._reservoir = 0
        self._count = 0
        self.receiver = WireReceiver()
        self.frames: list[bytes] = []
        self._streaming = False
        self._rx = cocotb.start_soon(self._feed())
        self._tx = cocotb.start_soon(self._collect())

    def _encode_next(self) -> None:
        data, ctrl = self.words.popleft() if self.words else self.IDLE
        payload, header, error = encode_reference(
            list(data.to_bytes(8, "little")), ctrl
        )
        assert not error
        block = (self._scrambler.word(payload) << 2) | header
        self._reservoir |= block << self._count
        self._count += 66
        while self._count >= 64:
            self.incoming.append(self._reservoir & ((1 << 64) - 1))
            self._reservoir >>= 64
            self._count -= 64

    async def _feed(self) -> None:
        dut = self.dut
        while True:
            await FallingEdge(dut.i_rx_clk)
            if not self.incoming:
                self._encode_next()
            dut.i_rx_raw_data.value = self.incoming.popleft()
            dut.i_rx_raw_valid.value = 1

    async def _collect(self) -> None:
        dut = self.dut
        while True:
            await FallingEdge(dut.i_tx_clk)
            if int(dut.o_tx_raw_valid.value):
                if not self._streaming:
                    self.receiver = WireReceiver()
                    self._streaming = True
                self.receiver.word(int(dut.o_tx_raw_data.value))
                if self.receiver.frames:
                    self.frames += self.receiver.frames
                    self.receiver.frames = []
            else:
                self._streaming = False

    def send(self, frames: list[bytes], lane: int = 0) -> None:
        """Splice the frames into the idle stream."""
        for f in frames:
            self.words.extend(frame_words(f, lane=lane))

    def stop(self) -> None:
        self._rx.cancel()
        self._tx.cancel()


class _Nic:
    def __init__(self, dut: Any, seed: int) -> None:
        self.dut = dut
        self.rng = random.Random(seed)
        self.mem = Memory()
        self.port = _LinePort(dut, self.mem, seed + 1)
        self.wire = _Wire(dut)
        self.rx_posted = 0
        self.tx_posted = 0
        self.rx_bufs: list[int] = []

    def stop(self) -> None:
        self.port.stop()
        self.wire.stop()

    async def wr(self, off: int, val: int) -> None:
        dut = self.dut
        await FallingEdge(dut.i_clk)
        dut.i_wr_en.value = 1
        dut.i_wr_offset.value = off
        dut.i_wr_data.value = val
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ps")
        dut.i_wr_en.value = 0

    async def rd64(self, off: int) -> int:
        dut = self.dut
        await FallingEdge(dut.i_clk)
        dut.i_rd_offset.value = off & ~7
        await Timer(1, unit="ps")
        return int(dut.o_rd_pair.value)

    async def rd(self, off: int) -> int:
        pair = await self.rd64(off)
        return (pair >> (32 if off & 4 else 0)) & 0xFFFF_FFFF

    async def cycles(self, n: int) -> None:
        for _ in range(n):
            await FallingEdge(self.dut.i_clk)

    async def wait_status(
        self, mask: int, value: int, limit: int = 20000, what: str = ""
    ) -> None:
        for _ in range(limit // 10):
            if (await self.rd(STATUS)) & mask == value:
                return
            await self.cycles(10)
        raise AssertionError(f"STATUS never reached {what}: {await self.rd(STATUS):#x}")

    async def wait_dd(self, ring: int, index: int, limit: int = 400000) -> int:
        for _ in range(limit // 20):
            s = desc_status(self.mem, ring, index)
            if s & DD:
                return s
            await self.cycles(20)
        raise AssertionError(f"descriptor {index} of ring {ring:#x} never completed")

    async def wait_irq_bits(self, bits: int, limit: int = 200000) -> None:
        for _ in range(limit // 20):
            if (await self.rd(IRQ_STATUS)) & bits == bits:
                return
            await self.cycles(20)
        raise AssertionError(
            f"IRQ_STATUS never showed {bits:#x}: {await self.rd(IRQ_STATUS):#x}"
        )

    async def wait_carrier(self, limit: int = 400000) -> None:
        for _ in range(limit // 50):
            if (await self.rd(LINK)) & LINK_CARRIER:
                return
            await self.cycles(50)
        raise AssertionError(f"no carrier: LINK={await self.rd(LINK):#x}")

    async def reset_and_ready(self) -> None:
        await self.wr(CTRL, CTRL_RESET)
        await self.wait_status(ST_RESET_BUSY, 0, what="RESET done")
        await self.wait_status(
            ST_RX_READY | ST_TX_READY, ST_RX_READY | ST_TX_READY, what="READY"
        )

    async def program_rings(self) -> None:
        await self.wr(RX_BASE, RX_RING)
        await self.wr(RX_SIZE, RX_SIZE_LOG2)
        await self.wr(TX_BASE, TX_RING)
        await self.wr(TX_SIZE, TX_SIZE_LOG2)
        self.rx_posted = 0
        self.tx_posted = 0
        self.rx_bufs = []

    async def post_rx(self, n: int, buf_len: int = 9216) -> None:
        for _ in range(n):
            i = self.rx_posted
            addr = (
                RX_BUF
                + (i % ((1 << RX_SIZE_LOG2) - 1)) * 0x4000
                + self.rng.randrange(64)
            )
            post_desc(self.mem, RX_RING, i % (1 << RX_SIZE_LOG2), addr, buf_len)
            self.rx_bufs.append(addr)
            self.rx_posted += 1
        await self.wr(RX_TAIL, self.rx_posted % (1 << RX_SIZE_LOG2))

    async def send_tx(self, frame: bytes, flags: int = SOP | EOP) -> int:
        i = self.tx_posted
        addr = (
            TX_BUF + (i % ((1 << TX_SIZE_LOG2) - 1)) * 0x4000 + self.rng.randrange(64)
        )
        self.mem.write_bytes(addr, frame)
        post_desc(self.mem, TX_RING, i % (1 << TX_SIZE_LOG2), addr, len(frame) | flags)
        self.tx_posted += 1
        await self.wr(TX_TAIL, self.tx_posted % (1 << TX_SIZE_LOG2))
        return i

    def rx_frame(self, index: int) -> bytes:
        s = desc_status(self.mem, RX_RING, index % (1 << RX_SIZE_LOG2))
        return self.mem.read_bytes(self.rx_bufs[index], s & 0xFFFF)

    def frame(self, length: int, da: bytes = STATION) -> bytes:
        return da + bytes(self.rng.getrandbits(8) for _ in range(length - 6))


async def _start(dut: Any, seed: int, loopback: bool) -> _Nic:
    Clock(dut.i_clk, CORE_PS, unit="ps").start()
    Clock(dut.i_tx_clk, MAC_PS, unit="ps").start()
    Clock(dut.i_rx_clk, MAC_PS, unit="ps").start()
    for sig in (
        dut.i_wr_en,
        dut.i_wr_offset,
        dut.i_wr_data,
        dut.i_rd_offset,
        dut.i_dma_req_ready,
        dut.i_dma_resp_valid,
        dut.i_dma_resp_id,
        dut.i_dma_resp_rdata,
        dut.i_rx_raw_data,
        dut.i_rx_raw_valid,
    ):
        sig.value = 0
    dut.i_tx_clk_ok.value = 1
    dut.i_rx_clk_ok.value = 1
    dut.i_phy_status.value = 0xF
    dut.i_rx_signal_ok.value = 1
    dut.i_rst.value = 1
    for _ in range(5):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    nic = _Nic(dut, seed)
    await nic.wait_status(
        ST_RX_READY | ST_TX_READY, ST_RX_READY | ST_TX_READY, what="READY at start"
    )
    if loopback:
        await nic.wr(PHY_CTRL, 1)
        await nic.reset_and_ready()
    await nic.wr(MAC_LO, int.from_bytes(STATION[:4], "little"))
    await nic.wr(MAC_HI, int.from_bytes(STATION[4:], "little"))
    return nic


@cocotb.test()
async def test_registers_and_bringup(dut: Any) -> None:
    """ID, defaults, a refused enable, an accepted one, ring register rules, RESET."""
    nic = await _start(dut, 1, loopback=False)
    assert await nic.rd(ID) == 0x4E49_4301
    assert await nic.rd(TICK) == 300
    assert await nic.rd(PHY_STATUS) == 0xF
    assert await nic.rd(MAC_LO) == int.from_bytes(STATION[:4], "little")
    assert await nic.rd(MAC_HI) == int.from_bytes(STATION[4:], "little")
    status = await nic.rd(STATUS)
    assert (
        status & (ST_RX_IDLE | ST_TX_IDLE | ST_RX_FIFO_EMPTY)
        == ST_RX_IDLE | ST_TX_IDLE | ST_RX_FIFO_EMPTY
    )
    # An enable with unprogrammed rings is refused.
    await nic.wr(CTRL, CTRL_RX_EN | CTRL_TX_EN)
    await nic.cycles(3)
    assert await nic.rd(CTRL) & (CTRL_RX_EN | CTRL_TX_EN) == 0
    assert (
        await nic.rd(STATUS) & (ST_RX_CONFIG_ERR | ST_TX_CONFIG_ERR)
        == ST_RX_CONFIG_ERR | ST_TX_CONFIG_ERR
    )
    assert await nic.rd(IRQ_STATUS) & IRQ_DESC_ERR
    await nic.wr(IRQ_STATUS, IRQ_DESC_ERR)
    # A ring outside the aperture or misaligned is refused too.
    await nic.wr(RX_BASE, 0x1000_0000)
    await nic.wr(RX_SIZE, 4)
    await nic.wr(CTRL, CTRL_RX_EN)
    await nic.cycles(3)
    assert await nic.rd(CTRL) & CTRL_RX_EN == 0
    await nic.wr(RX_BASE, RX_RING + 16)
    assert await nic.rd(RX_BASE) == RX_RING, "BASE bits 4:0 must read 0"
    await nic.wr(RX_SIZE, 17)
    await nic.wr(CTRL, CTRL_RX_EN)
    await nic.cycles(3)
    assert await nic.rd(CTRL) & CTRL_RX_EN == 0
    # Valid rings: accepted, CONFIG_ERR clears.
    await nic.program_rings()
    await nic.wr(CTRL, CTRL_RX_EN | CTRL_TX_EN)
    await nic.cycles(3)
    assert await nic.rd(CTRL) & (CTRL_RX_EN | CTRL_TX_EN) == CTRL_RX_EN | CTRL_TX_EN
    assert await nic.rd(STATUS) & (ST_RX_CONFIG_ERR | ST_TX_CONFIG_ERR) == 0
    # BASE is not writable while enabled; TAIL is.
    await nic.wr(RX_BASE, 0x8050_0000)
    assert await nic.rd(RX_BASE) == RX_RING
    await nic.wr(RX_TAIL, 3)
    assert await nic.rd(RX_TAIL) == 3
    # Disable, then a BASE write starts a new generation: TAIL and HEAD read 0.
    await nic.wr(CTRL, 0)
    await nic.wait_status(ST_RX_IDLE, ST_RX_IDLE, what="RX idle")
    await nic.wr(RX_BASE, 0x8050_0000)
    assert await nic.rd(RX_BASE) == 0x8050_0000
    assert await nic.rd(RX_TAIL) == 0 and await nic.rd(RX_HEAD) == 0
    # RESET: busy then done, rings back to defaults, station address kept.
    await nic.wr(CTRL, CTRL_RESET)
    assert await nic.rd(STATUS) & ST_RESET_BUSY
    await nic.wait_status(ST_RESET_BUSY, 0, what="RESET done")
    assert await nic.rd(RX_BASE) == 0 and await nic.rd(TX_SIZE) == 0
    assert await nic.rd(MAC_LO) == int.from_bytes(STATION[:4], "little")
    # The TAIL write above posted three descriptors: one line read, and no write
    # since no frame arrived.
    assert nic.port.requests == 1 and nic.port.writes == 0, (
        nic.port.requests,
        nic.port.writes,
    )
    nic.stop()


@cocotb.test()
async def test_loopback_frames(dut: Any) -> None:
    """Frames around the raw loopback into RX buffers: data, status, counters, interrupts."""
    nic = await _start(dut, 2, loopback=True)
    await nic.program_rings()
    await nic.post_rx(8)
    await nic.wr(RX_ITR, 0)
    await nic.wr(TX_ITR, 0)
    await nic.wr(IRQ_MASK, 0x1F)
    await nic.wr(CTRL, CTRL_RX_EN | CTRL_TX_EN)
    await nic.wait_carrier()
    await nic.wait_irq_bits(IRQ_LINK)
    await nic.wr(IRQ_STATUS, IRQ_LINK)
    frames = [nic.frame(n) for n in (60, 61, 64, 100, 1518, 9000, 20, 200)]
    for f in frames:
        await nic.send_tx(f)
    for i, f in enumerate(frames):
        s = await nic.wait_dd(RX_RING, i)
        expected = f.ljust(60, b"\0")
        assert s == DD | len(expected), f"RX descriptor {i}: {s:#x}"
        assert nic.rx_frame(i) == expected, f"frame {i} differs"
        assert desc_status(nic.mem, TX_RING, i) == DD
    assert await nic.rd(RX_HEAD) == 8 and await nic.rd(TX_HEAD) == 8
    assert await nic.rd64(COUNTERS + 8 * CNT_RX_FRAMES) == 8
    assert await nic.rd64(COUNTERS + 8 * CNT_TX_FRAMES) == 8
    assert await nic.rd64(COUNTERS + 8 * CNT_TX_BYTES) == sum(len(f) for f in frames)
    assert await nic.rd64(COUNTERS + 8 * CNT_RX_BYTES) == sum(
        max(len(f), 60) for f in frames
    )
    irq = await nic.rd(IRQ_STATUS)
    assert irq & (IRQ_RX | IRQ_TX) == IRQ_RX | IRQ_TX and int(dut.o_irq.value) == 1
    await nic.wr(IRQ_MASK, 0)
    await nic.cycles(2)
    assert int(dut.o_irq.value) == 0
    await nic.wr(IRQ_STATUS, IRQ_RX | IRQ_TX)
    assert await nic.rd(IRQ_STATUS) & (IRQ_RX | IRQ_TX) == 0
    # Moderation: RX raises after 3 completions, TX after a delay of 4 ticks.
    await nic.wr(RX_ITR, (3 << 16) | 0xFFFF)
    await nic.wr(TX_ITR, 4)
    await nic.wr(TICK, 50)
    await nic.wr(IRQ_MASK, 0x1F)
    await nic.post_rx(4)
    for n in (70, 71, 72):
        await nic.send_tx(nic.frame(n))
    await nic.wait_dd(RX_RING, 10)
    await nic.wait_irq_bits(IRQ_RX | IRQ_TX)
    await nic.wait_status(ST_TX_IDLE, ST_TX_IDLE, what="TX idle")
    nic.stop()


@cocotb.test()
async def test_wire_rx_filter_and_tx_capture(dut: Any) -> None:
    """Frames from the software wire: station and group taken, another unicast filtered; TX seen on the wire."""
    nic = await _start(dut, 3, loopback=False)
    await nic.program_rings()
    await nic.post_rx(6)
    await nic.wr(IRQ_MASK, 0x1F)
    await nic.wr(CTRL, CTRL_RX_EN | CTRL_TX_EN)
    await nic.wait_carrier()
    frames = [
        nic.frame(80, STATION),
        nic.frame(90, OTHER),
        nic.frame(100, BROADCAST),
        nic.frame(110, OTHER),
    ]
    nic.wire.send(frames)
    taken = [f for f in frames if f[:6] != OTHER]
    for i, f in enumerate(taken):
        s = await nic.wait_dd(RX_RING, i)
        assert s == DD | len(f)
        assert nic.rx_frame(i) == f
    for _ in range(50):
        await nic.cycles(50)
        if await nic.rd64(COUNTERS + 8 * CNT_RX_FILTERED) == 2:
            break
    assert await nic.rd64(COUNTERS + 8 * CNT_RX_FILTERED) == 2
    assert await nic.rd(IRQ_STATUS) & IRQ_RX_DROP
    assert await nic.rd(RX_HEAD) == 2
    # Promiscuous: the other unicast is taken now.
    await nic.wr(CTRL, CTRL_RX_EN | CTRL_TX_EN | CTRL_PROMISC)
    other = nic.frame(120, OTHER)
    nic.wire.send([other])
    s = await nic.wait_dd(RX_RING, 2)
    assert s == DD | 120 and nic.rx_frame(2) == other
    # TX: the wire receiver validates the frame independently.
    out = nic.frame(300, OTHER)
    idx = await nic.send_tx(out)
    for _ in range(4000):
        await nic.cycles(20)
        if nic.wire.frames:
            break
    assert nic.wire.frames == [out]
    assert desc_status(nic.mem, TX_RING, idx) == DD
    nic.stop()


@cocotb.test()
async def test_reset_mid_traffic(dut: Any) -> None:
    """RESET while frames are in flight and the RX ring is empty: busy clears, state returns to defaults, the NIC works again."""
    nic = await _start(dut, 4, loopback=True)
    await nic.program_rings()
    await nic.post_rx(1)
    await nic.wr(IRQ_MASK, 0x1F)
    await nic.wr(CTRL, CTRL_RX_EN | CTRL_TX_EN)
    await nic.wait_carrier()
    for n in (9000, 9000, 9000, 9000):
        await nic.send_tx(nic.frame(n))
    await nic.wait_dd(RX_RING, 0)
    # The ring is now empty with frames still arriving; reset in the middle of that.
    await nic.cycles(500)
    await nic.wr(CTRL, CTRL_RESET)
    await nic.wait_status(ST_RESET_BUSY, 0, limit=100000, what="RESET done")
    assert not nic.port.pending
    assert await nic.rd(CTRL) & (CTRL_RX_EN | CTRL_TX_EN) == 0
    assert (
        await nic.rd(RX_HEAD) == 0
        and await nic.rd(TX_HEAD) == 0
        and await nic.rd(RX_BASE) == 0
    )
    assert await nic.rd64(COUNTERS + 8 * CNT_RX_FRAMES) == 0
    assert await nic.rd(PHY_CTRL) == 1, "PHY_CTRL survives RESET"
    await nic.wait_status(
        ST_RX_READY | ST_TX_READY, ST_RX_READY | ST_TX_READY, what="READY after RESET"
    )
    await nic.program_rings()
    await nic.post_rx(2)
    await nic.wr(CTRL, CTRL_RX_EN | CTRL_TX_EN)
    await nic.wait_carrier()
    f = nic.frame(500)
    await nic.send_tx(f)
    s = await nic.wait_dd(RX_RING, 0)
    assert s == DD | 500 and nic.rx_frame(0) == f
    nic.stop()
