#    Copyright 2026 John Goodacre
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

"""RX ingress FIFO limit and the GMII receive-error counters of nic_mac_1g.

The wrap is built in GMII mode with an 8192-word RX FIFO. With the core side
stalled, back-to-back frames fill the FIFO until its occupancy reaches the
limit; later frames overflow in the MAC and are counted. A new limit crosses
to the RX clock through the mailbox, which the test waits out (busy) before
sending traffic.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

from cocotb_tests.nic.test_nic_mac_gmii import (
    GmiiPeer,
    _restart_and_wait_ready,
    _wire_frame,
)

BUILT_DEPTH = 8192
# A 60-byte payload is eight FIFO words.
FRAME_WORDS = 8
READY_MARGIN = 2
# The receive MAC's store-and-forward buffer: 4096 words at the default frame size.
MAC_BUFFER_WORDS = 4096
OVERFLOW, BAD_FRAME, BAD_FCS = 0, 1, 2
PREAMBLE_DROP, RX_ER = 6, 7
# o_totals index = nic_pkg counter index - 10
# A stalled reader stores (512 + 4096) / 8 = 576 frames before the MAC overflows
FRAMES_PAST_STORAGE = 700
(ER_PREAMBLE, ER_EXT, SHORT_IFG, PRE_ACCEPT, NO_DESC) = (11, 12, 13, 14, 15)
(PCS_SYNC_LOSS, PCS_RUDI_C, PCS_RUDI_INVALID, PCS_RXDISPERR, PCS_RXNOTINTABLE) = (
    16,
    17,
    18,
    19,
    20,
)


class StalledPeer(GmiiPeer):
    """A GMII peer whose CPU-side reader runs only while ``ready`` is set."""

    def __init__(self, dut: Any) -> None:
        """Start with the reader stalled."""
        super().__init__(dut)
        self.ready = False

    async def collect(self) -> None:
        """Take beats only while the reader is released."""
        frame = bytearray()
        while True:
            await FallingEdge(self.dut.i_clk)
            ready = self.ready
            self.dut.m_axis_rx_tready.value = int(ready)
            await RisingEdge(self.dut.i_clk)
            if ready and int(self.dut.m_axis_rx_tvalid.value):
                nbytes = int(self.dut.m_axis_rx_tkeep.value).bit_count()
                data = int(self.dut.m_axis_rx_tdata.value).to_bytes(8, "little")
                frame.extend(data[:nbytes])
                if int(self.dut.m_axis_rx_tlast.value):
                    self.received.append(bytes(frame))
                    frame.clear()


def _total(dut: Any, index: int) -> int:
    return (int(dut.o_totals.value) >> (64 * index)) & ((1 << 64) - 1)


async def _set_limit(dut: Any, words: int) -> None:
    await FallingEdge(dut.i_clk)
    dut.i_rx_fifo_limit.value = words
    dut.i_rx_fifo_limit_wr.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_rx_fifo_limit_wr.value = 0
    await ClockCycles(dut.i_clk, 2)
    for _ in range(200):
        if not int(dut.o_rx_fifo_limit_busy.value):
            return
        await ClockCycles(dut.i_clk, 1)
    raise AssertionError("the limit crossing never completed")


async def _start(dut: Any) -> StalledPeer:
    for name, value in {
        "i_rst": 1,
        "i_soft_rst": 0,
        "i_restart": 0,
        "i_tx_clk_ok": 1,
        "i_rx_clk_ok": 1,
        "i_mac_loopback": 0,
        "s_axis_tx_tvalid": 0,
        "s_axis_tx_tdata": 0,
        "s_axis_tx_tkeep": 0,
        "s_axis_tx_tlast": 0,
        "s_axis_tx_tuser": 0,
        "i_tx_csum": 0,
        "i_station_mac": 0,
        "i_pause_ctrl": 0,
        "i_pause_high_water": 0,
        "i_pause_low_water": 0,
        "i_pause_interval": 0xFFFF,
        "m_axis_rx_tready": 0,
        "i_gmii_rxd": 0,
        "i_gmii_rx_dv": 0,
        "i_gmii_rx_er": 0,
        "i_gmii_rx_clk_en": 1,
        "i_pcs_status": 0,
        "i_rx_signal_ok": 1,
        "i_rx_fifo_limit": 0,
        "i_rx_fifo_limit_wr": 0,
        "i_rx_desc_starved": 0,
    }.items():
        getattr(dut, name).value = value
    for name, period in (("i_clk", 6), ("i_tx_clk", 8), ("i_rx_clk", 8)):
        Clock(getattr(dut, name), period, unit="ns").start()
    await ClockCycles(dut.i_clk, 20)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await _restart_and_wait_ready(dut)
    peer = StalledPeer(dut)
    cocotb.start_soon(peer.wire())
    cocotb.start_soon(peer.collect())
    await ClockCycles(dut.i_clk, 40)
    return peer


async def _fill(dut: Any, peer: StalledPeer, frames: int) -> tuple[int, int]:
    """Send frames with the reader stalled, release it, and return (delivered, overflowed)."""
    before = _total(dut, OVERFLOW)
    peer.received.clear()
    peer.ready = False
    payload = bytes(range(60))
    for _ in range(frames):
        peer.inject(_wire_frame(payload))
    while peer.symbols:
        await RisingEdge(dut.i_rx_clk)
    await ClockCycles(dut.i_clk, 200)
    peer.ready = True
    # Drain until no frame has arrived for a long while.
    quiet = 0
    while quiet < 3000:
        count = len(peer.received)
        await ClockCycles(dut.i_clk, 100)
        quiet = quiet + 100 if len(peer.received) == count else 0
    peer.ready = False
    await ClockCycles(dut.i_clk, 10)
    overflowed = _total(dut, OVERFLOW) - before
    delivered = len(peer.received)
    assert all(frame == bytes(range(60)) for frame in peer.received)
    return delivered, overflowed


@cocotb.test()
async def overflow_occurs_at_the_limit(dut: Any) -> None:
    """Storage is the MAC's buffer plus the FIFO up to its limit; the rest overflows, counted.

    The receive MAC keeps complete frames in its own buffer while the FIFO is full, so a stalled
    reader fills FIFO + MAC buffer before any frame is lost. Raising the limit from L1 to L2 adds
    exactly L2 - L1 words of storage: (L2 - L1) / 8 more frames are delivered.
    """
    assert int(dut.RX_FIFO_DEPTH.value) == BUILT_DEPTH
    peer = await _start(dut)
    results: list[tuple[int, int, int]] = []
    # 512 is the reset value, so the first run reproduces the original 512-word FIFO.
    for limit in (512, 2048, 8192, 64, 512):
        if results:
            await _set_limit(dut, limit)
        frames = (limit + MAC_BUFFER_WORDS) // FRAME_WORDS + 120
        delivered, overflowed = await _fill(dut, peer, frames)
        assert delivered + overflowed == frames, (limit, delivered, overflowed)
        assert overflowed > 0, (limit, "storage was never exhausted")
        results.append((limit, delivered, overflowed))
        dut._log.info(
            "limit %d: delivered %d overflowed %d", limit, delivered, overflowed
        )
    # The MAC's own storage, from the reset-value run (the FIFO holds 512 - 2 words + the skid).
    mac_words = results[0][1] * FRAME_WORDS - 512
    assert 3800 <= mac_words <= 4200, mac_words
    for limit, delivered, _ in results:
        stored = delivered * FRAME_WORDS
        # The limit sets storage in whole frames: within a frame or two of the formula.
        assert abs(stored - (limit + mac_words)) <= 2 * FRAME_WORDS, (
            limit,
            stored,
            mac_words,
        )
    # Lowering the limit again returns to the same capacity as before.
    assert results[-1][1] == results[0][1]
    # Below the limit and the MAC buffer nothing overflows.
    await _set_limit(dut, 2048)
    delivered, overflowed = await _fill(dut, peer, 200)
    assert (delivered, overflowed) == (200, 0)


@cocotb.test()
async def gmii_preamble_and_error_counters(dut: Any) -> None:
    """Preamble-stage discards and rx_er bursts reach the totals, one event each."""
    peer = await _start(dut)
    peer.ready = True
    payload = bytes(range(80))
    wire = _wire_frame(payload)
    # A frame with rx_er inside the preamble (byte 3), one whose first byte is wrong,
    # and one whose preamble breaks off at its second byte.
    peer.inject(wire, error_byte=3)
    peer.inject(b"\x54" + wire[1:])
    peer.inject(b"\x55\x54\xd5" + wire[8:])
    # rx_er inside the data: one burst of two symbols, then two separate single errors.
    peer.inject(wire, error_byte=30, extra_errors=(31,))
    peer.inject(wire, error_byte=40, extra_errors=(44,))
    # A clean frame still gets through.
    peer.inject(wire)
    await ClockCycles(dut.i_clk, 3000)
    assert [bytes(frame) for frame in peer.received] == [payload]
    assert _total(dut, PREAMBLE_DROP) == 3
    # The two-symbol burst and the two separate errors inside frames; the preamble's rx_er has its own
    # counter.
    assert _total(dut, RX_ER) == 3
    assert _total(dut, ER_PREAMBLE) == 1
    assert _total(dut, ER_EXT) == 0
    assert _total(dut, PRE_ACCEPT) == 0
    assert _total(dut, BAD_FRAME) >= 2
    assert _total(dut, BAD_FCS) == 0


@cocotb.test()
async def gmii_error_position_and_gap_counters(dut: Any) -> None:
    """rx_er outside a frame and a short inter-frame gap each have a counter."""
    peer = await _start(dut)
    peer.ready = True
    payload = bytes(range(80))
    wire = _wire_frame(payload)
    # Carrier extend: rx_er with the data enable low, one burst of three symbols, then a second burst.
    peer.symbols.extend([0x20F] * 3 + [0] * 12 + [0x21F] + [0] * 12)
    peer.inject(wire)
    # A gap of eight byte times, shorter than the 12 of a conforming sender.
    peer.symbols.extend(byte | 0x100 for byte in wire)
    peer.symbols.extend([0] * 8)
    peer.symbols.extend(byte | 0x100 for byte in wire)
    peer.symbols.extend([0] * 12)
    # And one of exactly twelve, which is conforming.
    peer.inject(wire)
    await ClockCycles(dut.i_clk, 4000)
    assert [bytes(frame) for frame in peer.received] == [payload] * 4
    assert _total(dut, ER_EXT) == 2
    assert _total(dut, ER_PREAMBLE) == 0
    assert _total(dut, RX_ER) == 0
    assert _total(dut, SHORT_IFG) == 1
    assert _total(dut, PREAMBLE_DROP) == 0


@cocotb.test()
async def pcs_status_vector_events(dut: Any) -> None:
    """Each status_vector event bit reaches its own total."""
    peer = await _start(dut)
    peer.ready = True
    await ClockCycles(dut.i_rx_clk, 10)
    # Link synchronised (bit 1), then lost, then regained: one loss.
    peer.status = 0x0002
    await ClockCycles(dut.i_rx_clk, 10)
    peer.status = 0x0000
    await ClockCycles(dut.i_rx_clk, 10)
    peer.status = 0x0002
    await ClockCycles(dut.i_rx_clk, 10)
    # RUDI(/C/) held for many clocks counts once; RUDI(INVALID) twice; RXDISPERR for three clocks;
    # RXNOTINTABLE for two.
    peer.status = 0x0006
    await ClockCycles(dut.i_rx_clk, 20)
    peer.status = 0x0002
    await ClockCycles(dut.i_rx_clk, 4)
    for _ in range(2):
        peer.status = 0x0012
        await ClockCycles(dut.i_rx_clk, 3)
        peer.status = 0x0002
        await ClockCycles(dut.i_rx_clk, 3)
    peer.status = 0x0022
    await ClockCycles(dut.i_rx_clk, 3)
    peer.status = 0x0042
    await ClockCycles(dut.i_rx_clk, 2)
    peer.status = 0x0002
    await ClockCycles(dut.i_clk, 200)
    assert _total(dut, PCS_SYNC_LOSS) == 1
    assert _total(dut, PCS_RUDI_C) == 1
    assert _total(dut, PCS_RUDI_INVALID) == 2
    assert _total(dut, PCS_RXDISPERR) == 3
    assert _total(dut, PCS_RXNOTINTABLE) == 2


@cocotb.test()
async def overflow_with_no_descriptor_is_counted_apart(dut: Any) -> None:
    """Count a MAC overflow while the RX engine has no descriptor as dropped for that reason."""
    peer = await _start(dut)
    await _set_limit(dut, 512)
    delivered, overflowed = await _fill(dut, peer, FRAMES_PAST_STORAGE)
    assert overflowed > 0
    assert _total(dut, NO_DESC) == 0
    dut.i_rx_desc_starved.value = 1
    await ClockCycles(dut.i_rx_clk, 8)
    before = _total(dut, OVERFLOW)
    delivered, overflowed = await _fill(dut, peer, FRAMES_PAST_STORAGE)
    assert overflowed > 0
    assert _total(dut, OVERFLOW) - before == overflowed
    assert _total(dut, NO_DESC) == overflowed
