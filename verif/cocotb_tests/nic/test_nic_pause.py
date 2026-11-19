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

"""IEEE 802.3x flow control in nic_mac_1g and nic_mac_10g across the GMII and 10GBASE-R paths.

The same tests run on both builds (nic_mac_gmii-style GMII wrap, and the 64b/66b wrap with
independent TX and RX clocks); only the wire model differs. Received PAUSE frames are consumed
and counted, delay only the next frame start for pause_time quanta, and are resumed by quanta 0;
a frame in flight finishes. A pause request goes out when the RX FIFO fills past the high-water threshold, is
refreshed at half the pause time, and is followed by a release frame when the FIFO drains.
"""

import zlib
from collections import deque
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer
from cocotb.utils import get_sim_time

from net10g.test_integration import WireReceiver, frame_words
from net10g.test_codec import encode_reference
from net10g.test_scrambler import SerialReference

STATION = bytes([0x02, 0x11, 0x22, 0x33, 0x44, 0x55])
OTHER = bytes([0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
PAUSE_DA = bytes([0x01, 0x80, 0xC2, 0x00, 0x00, 0x01])
OVERFLOW, RX_PAUSE, TX_PAUSE, TX_PAUSED = 0, 8, 9, 10
CTRL_RX, CTRL_TX = 1, 2


def _gmii() -> bool:
    return hasattr(cocotb.top, "o_gmii_txd")


def pause_frame(
    quanta: int, da: bytes = PAUSE_DA, opcode: int = 1, ethertype: int = 0x8808
) -> bytes:
    """Build a MAC control frame body (without FCS), padded to 60 bytes."""
    body = da + OTHER + ethertype.to_bytes(2, "big") + opcode.to_bytes(2, "big")
    return (body + quanta.to_bytes(2, "big")).ljust(60, b"\0")


def data_frame(length: int, tag: int, da: bytes = STATION) -> bytes:
    """Build a data frame body of the given length."""
    return da + OTHER + bytes((tag + i) & 0xFF for i in range(length - 12))


class Link:
    """The wire: frames in toward the DUT, timestamped frames out of it."""

    def __init__(self, dut: Any) -> None:
        """Start the wire coroutines for the build under test."""
        self.dut = dut
        self.tx_log: list[tuple[float, bytes]] = []  # (end time ns, body without FCS)
        self.gmii = _gmii()
        if self.gmii:
            self.symbols: deque[int] = deque()
            cocotb.start_soon(self._gmii_wire())
        else:
            self.words: deque[tuple[int, int]] = deque()
            self.incoming: deque[int] = deque()
            self._scrambler = SerialReference()
            self._reservoir = 0
            self._count = 0
            self._receiver = WireReceiver()
            self._streaming = False
            cocotb.start_soon(self._feed())
            cocotb.start_soon(self._collect())

    # ---- toward the DUT -----------------------------------------------------------------
    def send(self, body: bytes) -> None:
        """Queue a frame (without FCS; padded to 60 bytes) for the DUT's receiver."""
        if self.gmii:
            padded = body.ljust(60, b"\0")
            wire = (
                b"\x55" * 7
                + b"\xd5"
                + padded
                + zlib.crc32(padded).to_bytes(4, "little")
            )
            self.symbols.extend(b | 0x100 for b in wire)
            self.symbols.extend([0] * 12)
        else:
            self.words.extend(frame_words(body))

    def idle(self) -> bool:
        """Return whether every queued frame has been sent."""
        return not (self.symbols if self.gmii else self.words)

    async def _gmii_wire(self) -> None:
        dut = self.dut
        frame = bytearray()
        while True:
            await FallingEdge(dut.i_rx_clk)
            symbol = self.symbols.popleft() if self.symbols else 0
            dut.i_gmii_rx_clk_en.value = 1
            dut.i_gmii_rxd.value = symbol & 0xFF
            dut.i_gmii_rx_dv.value = (symbol >> 8) & 1
            dut.i_gmii_rx_er.value = (symbol >> 9) & 1
            await RisingEdge(dut.i_rx_clk)
            assert not int(dut.o_gmii_tx_er.value), "unexpected GMII transmit error"
            if int(dut.o_gmii_tx_en.value):
                frame.append(int(dut.o_gmii_txd.value))
            elif frame:
                body, fcs = bytes(frame[8:-4]), bytes(frame[-4:])
                assert zlib.crc32(body) == int.from_bytes(fcs, "little")
                self.tx_log.append((get_sim_time("ns"), body))
                frame.clear()

    IDLE = (0x0707070707070707, 0xFF)

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
                    self._receiver = WireReceiver()
                    self._streaming = True
                self._receiver.word(int(dut.o_tx_raw_data.value))
                if self._receiver.frames:
                    for body in self._receiver.frames:
                        self.tx_log.append((get_sim_time("ns"), body))
                    self._receiver.frames = []
            else:
                self._streaming = False


class Bench:
    """Clocks, reset, the core-side reader and writer, and the configuration bus."""

    def __init__(self, dut: Any) -> None:
        """Bind the DUT."""
        self.dut = dut
        self.ready = True
        self.received: list[bytes] = []
        self.depth = int(dut.RX_FIFO_DEPTH.value)
        self.link: Link
        self.tx_queue: deque[tuple[bytes, bool, int]] = deque()

    async def start(self, tx_ps: int | None = None, rx_ps: int | None = None) -> None:
        """Start."""
        dut = self.dut
        init: dict[str, int] = {
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
            "m_axis_rx_tready": 0,
            "i_rx_signal_ok": 1,
            "i_rx_fifo_limit": 512,
            "i_rx_fifo_limit_wr": 0,
            "i_rx_desc_starved": 0,
            "i_station_mac": int.from_bytes(STATION, "little"),
            "i_pause_ctrl": 0,
            "i_pause_high_water": 0,
            "i_pause_low_water": 0,
            "i_pause_interval": 0xFFFF,
        }
        if _gmii():
            init.update(
                {
                    "i_gmii_rxd": 0,
                    "i_gmii_rx_dv": 0,
                    "i_gmii_rx_er": 0,
                    "i_gmii_rx_clk_en": 1,
                    "i_pcs_status": 0,
                }
            )
        else:
            init.update({"i_rx_raw_data": 0, "i_rx_raw_valid": 1})
        for name, value in init.items():
            getattr(dut, name).value = value
        # The raw PMA clock carries encoded bits; the PCS advances 32 of every 33 cycles.
        mac_ps = 8000 if _gmii() else 6206
        Clock(dut.i_clk, 6000, unit="ps").start()
        Clock(dut.i_tx_clk, tx_ps or mac_ps, unit="ps").start()
        Clock(dut.i_rx_clk, rx_ps or mac_ps, unit="ps").start()
        await ClockCycles(dut.i_clk, 20)
        await FallingEdge(dut.i_clk)
        dut.i_rst.value = 0
        self.link = Link(dut)
        await FallingEdge(dut.i_clk)
        dut.i_restart.value = 1
        await FallingEdge(dut.i_clk)
        dut.i_restart.value = 0
        for _ in range(4000):
            if int(dut.o_ready.value) == 3:
                break
            await ClockCycles(dut.i_clk, 1)
        else:
            raise AssertionError(
                f"MAC domains did not become ready: o_ready={int(dut.o_ready.value)} "
                f"o_link={hex(int(dut.o_link.value))}"
            )
        cocotb.start_soon(self._reader())
        self.tx_task = cocotb.start_soon(self._tx_feeder())
        # Block lock (bit 0) and tx_link_ready (bit 4) take a while on 64b/66b.
        for _ in range(4000):
            if (int(dut.o_link.value) & 0x11) == 0x11:
                break
            await ClockCycles(dut.i_clk, 1)
        await ClockCycles(dut.i_clk, 200)

    async def _reader(self) -> None:
        dut = self.dut
        frame = bytearray()
        while True:
            await FallingEdge(dut.i_clk)
            ready = self.ready
            dut.m_axis_rx_tready.value = int(ready)
            await RisingEdge(dut.i_clk)
            if ready and int(dut.m_axis_rx_tvalid.value):
                nbytes = int(dut.m_axis_rx_tkeep.value).bit_count()
                data = int(dut.m_axis_rx_tdata.value).to_bytes(8, "little")
                frame.extend(data[:nbytes])
                if int(dut.m_axis_rx_tlast.value):
                    self.received.append(bytes(frame))
                    frame.clear()

    async def configure(
        self,
        ctrl: int,
        high_water: int = 0,
        low_water: int = 0,
        interval: int = 0xFFFF,
        limit: int = 512,
    ) -> None:
        """Configure."""
        dut = self.dut
        await FallingEdge(dut.i_clk)
        dut.i_pause_ctrl.value = ctrl
        dut.i_pause_high_water.value = high_water
        dut.i_pause_low_water.value = low_water
        dut.i_pause_interval.value = interval
        dut.i_rx_fifo_limit.value = limit
        dut.i_rx_fifo_limit_wr.value = 1
        await FallingEdge(dut.i_clk)
        dut.i_rx_fifo_limit_wr.value = 0
        await ClockCycles(dut.i_clk, 2)
        for _ in range(400):
            if not int(dut.o_rx_fifo_limit_busy.value):
                break
            await ClockCycles(dut.i_clk, 1)
        else:
            raise AssertionError("the configuration crossing never completed")
        await ClockCycles(dut.i_clk, 20)

    def send_tx(self, body: bytes, abort: bool = False, csum: int = 0) -> None:
        """Queue a frame for the TX FIFO."""
        self.tx_queue.append((body, abort, csum))

    async def _tx_feeder(self) -> None:
        """Feed queued frames to the TX FIFO, one beat per accepted cycle."""
        dut = self.dut
        while True:
            if not self.tx_queue:
                await FallingEdge(dut.i_clk)
                dut.s_axis_tx_tvalid.value = 0
                continue
            body, abort, csum = self.tx_queue.popleft()
            for offset in range(0, len(body), 8):
                word = body[offset : offset + 8]
                last = offset + 8 >= len(body)
                while True:
                    await FallingEdge(dut.i_clk)
                    dut.s_axis_tx_tvalid.value = 1
                    dut.s_axis_tx_tdata.value = int.from_bytes(word, "little")
                    dut.i_tx_csum.value = csum
                    dut.s_axis_tx_tuser.value = int(abort and last)
                    dut.s_axis_tx_tkeep.value = (1 << len(word)) - 1
                    dut.s_axis_tx_tlast.value = int(last)
                    await Timer(1, unit="ns")
                    accepted = int(dut.s_axis_tx_tready.value)
                    await RisingEdge(dut.i_clk)
                    if accepted:
                        break

    def total(self, index: int) -> int:
        """Total."""
        return (int(self.dut.o_totals.value) >> (64 * index)) & ((1 << 64) - 1)

    async def wait_wire(self, count: int, timeout_ns: float) -> None:
        """Wait until the DUT has put ``count`` frames on the wire."""
        waited = 0.0
        while len(self.link.tx_log) < count:
            await Timer(100, unit="ns")
            waited += 100
            assert waited < timeout_ns, (count, len(self.link.tx_log))

    async def drain_link(self) -> None:
        """Drain link."""
        while not self.link.idle():
            await ClockCycles(self.dut.i_rx_clk, 20)
        await ClockCycles(self.dut.i_clk, 100)


def quantum_ns() -> float:
    """512 bit times at the wire rate."""
    return 512.0 if _gmii() else 51.2


@cocotb.test()
async def pause_is_honoured_while_rx_data_is_blocked(dut: Any) -> None:
    """Honour a later PAUSE while an ordinary frame is stalled."""
    bench = Bench(dut)
    await bench.start()
    await bench.configure(CTRL_RX, limit=8)
    bench.ready = False
    body = data_frame(65, 1)
    bench.link.send(body)
    bench.link.send(pause_frame(0xFFFF))
    await bench.drain_link()
    assert bench.total(OVERFLOW) == 0
    assert bench.total(RX_PAUSE) == 1, "PAUSE remained behind the stalled data frame"
    assert int(dut.u_cdc.tx_paused.value)
    bench.link.send(pause_frame(0))
    await bench.drain_link()
    assert bench.total(RX_PAUSE) == 2
    assert not int(dut.u_cdc.tx_paused.value), (
        "a stalled RX path prevented PAUSE release"
    )
    bench.ready = True
    await ClockCycles(dut.i_clk, 1000)
    assert bench.received == [body]
    assert bench.total(RX_PAUSE) == 2, "draining the data path replayed a PAUSE"


@cocotb.test()
async def pause_is_honoured_after_mac_storage_overflows(dut: Any) -> None:
    """PAUSE validation does not depend on reserving ordinary packet storage."""
    bench = Bench(dut)
    await bench.start()
    await bench.configure(CTRL_RX, limit=8)
    bench.ready = False
    for tag in range(4):
        bench.link.send(data_frame(8192, tag))
    bench.link.send(pause_frame(0xFFFF))
    await bench.drain_link()
    assert bench.total(OVERFLOW) > 0
    assert bench.total(RX_PAUSE) == 1, "MAC storage exhaustion discarded the PAUSE"
    assert int(dut.u_cdc.tx_paused.value)


@cocotb.test()
async def pause_timer_counts_wire_word_enables(dut: Any) -> None:
    """Measure the complete pause interval with a bound tighter than the PCS cadence gap."""
    bench = Bench(dut)
    await bench.start()
    await bench.configure(CTRL_RX)
    quanta = 256
    bench.link.send(pause_frame(quanta))
    for _ in range(2000):
        await FallingEdge(dut.i_tx_clk)
        if int(dut.u_cdc.tx_paused.value):
            break
    else:
        raise AssertionError("the received pause never armed its timer")
    started = get_sim_time("ns")
    for _ in range(quanta * 70):
        await FallingEdge(dut.i_tx_clk)
        if not int(dut.u_cdc.tx_paused.value):
            break
    else:
        raise AssertionError("pause timer did not expire")
    elapsed = get_sim_time("ns") - started
    expected = quanta * quantum_ns()
    # The first word-time boundary is arbitrary; permit at most two raw clock cycles.
    tolerance = 16.0 if _gmii() else 12.5
    assert abs(elapsed - expected) <= tolerance, (elapsed, expected, tolerance)


@cocotb.test()
async def tx_restart_does_not_replay_an_expired_pause(dut: Any) -> None:
    """Check that a TX restart discards a received pause event without replaying it."""
    bench = Bench(dut)
    await bench.start()
    await bench.configure(CTRL_RX)
    bench.link.send(pause_frame(1))
    await bench.drain_link()
    await Timer(int(3 * quantum_ns()), unit="ns")
    assert not int(dut.u_cdc.tx_paused.value)
    assert bench.total(RX_PAUSE) == 1
    await FallingEdge(dut.i_clk)
    dut.i_tx_clk_ok.value = 0
    for _ in range(200):
        if (int(dut.o_ready.value) & 1) == 0:
            break
        await ClockCycles(dut.i_clk, 1)
    else:
        raise AssertionError("TX domain did not leave ready on clock loss")
    await ClockCycles(dut.i_clk, 40)
    await FallingEdge(dut.i_clk)
    dut.i_tx_clk_ok.value = 1
    for _ in range(100):
        await FallingEdge(dut.i_tx_clk)
        assert not int(dut.u_cdc.tx_paused.value), (
            "TX reset replayed the historical PAUSE interval"
        )
    for _ in range(400):
        if int(dut.o_ready.value) == 3:
            break
        await ClockCycles(dut.i_clk, 1)
    assert int(dut.o_ready.value) == 3
    await ClockCycles(dut.i_clk, 100)
    assert bench.total(RX_PAUSE) == 1


@cocotb.test()
async def pause_interval_is_published_with_its_event(dut: Any) -> None:
    """Hold the completed frame's interval until the next event."""
    bench = Bench(dut)
    await bench.start()
    await bench.configure(CTRL_RX)
    source = dut.u_cdc.u_pause_wire
    toggle = int(source.o_pause_tog.value)
    interval = int(source.o_pause_interval.value)
    seen = []
    for quanta in (5, 300, 0):
        bench.link.send(pause_frame(quanta))
    for _ in range(4000):
        await FallingEdge(dut.i_rx_clk)
        next_toggle = int(source.o_pause_tog.value)
        next_interval = int(source.o_pause_interval.value)
        if next_toggle != toggle:
            seen.append(next_interval)
        else:
            assert next_interval == interval, "pause interval changed before its event"
        toggle, interval = next_toggle, next_interval
        if len(seen) == 3:
            break
    assert seen == [5, 300, 0]


@cocotb.test()
async def pause_frames_are_consumed_and_counted(dut: Any) -> None:
    """Consume a PAUSE frame to the multicast or the station address without delivering it."""
    bench = Bench(dut)
    await bench.start()
    link = bench.link
    link.send(data_frame(100, 1))
    link.send(pause_frame(5))  # multicast, consumed
    link.send(data_frame(101, 2))
    link.send(pause_frame(0, da=STATION))  # station address, consumed
    link.send(
        pause_frame(5, opcode=0x0101)
    )  # priority flow control: not ours, delivered
    link.send(pause_frame(5, ethertype=0x0800))  # multicast, other EtherType: delivered
    link.send(pause_frame(5, da=OTHER))  # another station: delivered
    link.send(data_frame(102, 3))
    await bench.drain_link()
    await ClockCycles(dut.i_clk, 400)
    got = bench.received
    want = [
        data_frame(100, 1).ljust(60, b"\0"),
        data_frame(101, 2),
        pause_frame(5, opcode=0x0101),
        pause_frame(5, ethertype=0x0800),
        pause_frame(5, da=OTHER),
        data_frame(102, 3),
    ]
    assert got == want, [len(f) for f in got]
    assert bench.total(RX_PAUSE) == 2
    assert bench.total(OVERFLOW) == 0
    # No pause was sent: nothing is enabled and the FIFO never filled.
    assert bench.total(TX_PAUSE) == 0 and not bench.link.tx_log


async def _pause_run(bench: Bench, quanta: int) -> tuple[float, float]:
    """Inject PAUSE(quanta); return (time the frame was fully sent, time the pause ends)."""
    bench.link.send(pause_frame(quanta))
    await bench.drain_link()
    sent = get_sim_time("ns")
    return sent, sent + quanta * quantum_ns()


@cocotb.test()
async def received_pause_holds_the_next_frame(dut: Any) -> None:
    """With a frame in flight and one buffered, the third waits out the pause; quanta 0 resumes."""
    bench = Bench(dut)
    await bench.start()
    await bench.configure(CTRL_RX)
    quanta = 300 if _gmii() else 600
    frames = [data_frame(1500, 10 * i) for i in range(6)]
    for body in frames:
        bench.send_tx(body)
    # Let the first frames get going, then pause.
    await Timer(1500 if not _gmii() else 4000, unit="ns")
    sent, end = await _pause_run(bench, quanta)
    await bench.wait_wire(6, 3 * (end - sent) + 400_000)
    log = bench.link.tx_log
    assert [b for _, b in log[:6]] == frames
    assert bench.total(RX_PAUSE) == 1
    # The last frame started after the pause ended (its end time less its duration).
    duration = 1514 * (8.0 if _gmii() else 0.8)
    assert log[5][0] - duration >= end - 0.05 * (end - sent), (log[5][0], duration, end)
    # The first frame was not held.
    assert log[0][0] < end
    assert bench.total(TX_PAUSED) > 0

    # Quanta 0 resumes at once.
    bench.link.tx_log.clear()
    paused_before = bench.total(TX_PAUSED)
    sent, end = await _pause_run(bench, 0xFFFF)
    t0 = get_sim_time("ns")
    bench.send_tx(frames[0])
    await Timer(3000 if not _gmii() else 6000, unit="ns")
    assert not bench.link.tx_log, "frame left during a long pause"
    bench.link.send(pause_frame(0))
    await bench.drain_link()
    await bench.wait_wire(1, 200_000)
    assert bench.link.tx_log[0][1] == frames[0]
    assert bench.link.tx_log[0][0] < t0 + 60_000
    assert bench.total(TX_PAUSED) > paused_before


@cocotb.test()
async def pause_is_ignored_when_not_honoured(dut: Any) -> None:
    """With the receive-pause bit clear the transmitter ignores PAUSE (the frame is still consumed)."""
    bench = Bench(dut)
    await bench.start()
    await bench.configure(0)
    bench.send_tx(data_frame(200, 3))
    bench.link.send(pause_frame(0xFFFF))
    await bench.drain_link()
    await bench.wait_wire(1, 100_000)
    assert bench.total(RX_PAUSE) == 1 and bench.total(TX_PAUSED) == 0


def _check_pause_body(body: bytes, quanta: int) -> None:
    assert len(body) == 60, len(body)
    assert body[:6] == PAUSE_DA and body[6:12] == STATION
    assert body[12:16] == bytes([0x88, 0x08, 0x00, 0x01])
    assert int.from_bytes(body[16:18], "big") == quanta
    assert body[18:] == bytes(42)


@cocotb.test()
async def pause_refresh_and_release_follow_the_fifo(dut: Any) -> None:
    """Pause request at the threshold, refreshed at half the pause time, one release after the drain."""
    bench = Bench(dut)
    await bench.start()
    interval = 0x100
    await bench.configure(CTRL_TX, interval=interval)
    bench.ready = False
    # Fill the FIFO past three quarters of 512 words (60-byte frames are eight words each) while
    # data frames wait to go out: pause frames go between whole frames.
    for tag in range(4):
        bench.send_tx(data_frame(300, tag))
    for tag in range(56):
        bench.link.send(data_frame(60, tag))
    await bench.drain_link()

    def pause_log() -> list[tuple[float, bytes]]:
        """Pause log."""
        return [(t, b) for t, b in bench.link.tx_log if b[:6] == PAUSE_DA]

    for _ in range(2000):
        if pause_log():
            break
        await Timer(100, unit="ns")
    assert len(pause_log()) >= 1
    _check_pause_body(pause_log()[0][1], interval)
    # Still full: the pause request is refreshed every pause_time / 2, again and again.
    refresh_ns = interval / 2 * quantum_ns()
    await Timer(int(3.2 * refresh_ns), unit="ns")
    pauses = pause_log()
    assert len(pauses) >= 4, len(pauses)
    gaps = [b[0] - a[0] for a, b in zip(pauses, pauses[1:])]
    for gap in gaps:
        assert 0.9 * refresh_ns <= gap <= 1.4 * refresh_ns + 3000, (gap, refresh_ns)
    for _, body in pauses:
        _check_pause_body(body, interval)
    # The data frames made it, whole, around the pause frames.
    data = [b for _, b in bench.link.tx_log if b[:6] != PAUSE_DA]
    assert data == [data_frame(300, tag) for tag in range(4)]
    # Drain: one release (pause time 0) and then silence.
    count = len(pauses)
    bench.ready = True
    await Timer(int(2 * refresh_ns) + 20_000, unit="ns")
    pauses = pause_log()
    assert len(pauses) in (count + 1, count + 2), (count, len(pauses))
    _check_pause_body(pauses[-1][1], 0)
    final = len(pauses)
    await Timer(int(3 * refresh_ns), unit="ns")
    assert len(pause_log()) == final
    assert bench.total(TX_PAUSE) == final
    assert bench.total(OVERFLOW) == 0
    # Every frame sent toward us arrived once the reader opened.
    assert len(bench.received) == 56


@cocotb.test()
async def nothing_is_sent_without_enable(dut: Any) -> None:
    """Send nothing without TX pause enabled, though a stalled reader fills the FIFO."""
    bench = Bench(dut)
    await bench.start()
    await bench.configure(CTRL_RX)
    bench.ready = False
    for tag in range(60):
        bench.link.send(data_frame(60, tag))
    await bench.drain_link()
    await Timer(30_000 if not _gmii() else 120_000, unit="ns")
    assert not bench.link.tx_log
    assert bench.total(TX_PAUSE) == 0


@cocotb.test()
async def explicit_thresholds_and_pause_release(dut: Any) -> None:
    """Explicit high and low water words move the thresholds; a disable after pause releases with release."""
    bench = Bench(dut)
    await bench.start()
    interval = 0x4000
    await bench.configure(CTRL_TX, high_water=64, low_water=16, interval=interval)
    bench.ready = False
    for tag in range(12):  # 96 words: above 64, well under the 512-word limit
        bench.link.send(data_frame(60, tag))
    await bench.drain_link()
    await Timer(10_000 if not _gmii() else 60_000, unit="ns")
    pauses = [b for _, b in bench.link.tx_log if b[:6] == PAUSE_DA]
    assert len(pauses) == 1
    _check_pause_body(pauses[0], interval)
    # Draining below low-water releases it.
    bench.ready = True
    await Timer(10_000 if not _gmii() else 60_000, unit="ns")
    pauses = [b for _, b in bench.link.tx_log if b[:6] == PAUSE_DA]
    assert len(pauses) == 2
    _check_pause_body(pauses[1], 0)


@cocotb.test()
async def abandoned_frame_is_dropped_at_the_mac(dut: Any) -> None:
    """Drop a frame closed with the abort flag at the MAC while the next frame goes out."""
    bench = Bench(dut)
    await bench.start()
    bench.send_tx(data_frame(200, 1), abort=True)
    bench.send_tx(data_frame(120, 2))
    bench.send_tx(data_frame(64, 3), abort=True)
    bench.send_tx(data_frame(90, 4))
    await bench.wait_wire(2, 200_000)
    await Timer(5_000, unit="ns")
    assert [b for _, b in bench.link.tx_log] == [data_frame(120, 2), data_frame(90, 4)]
    assert bench.total(4) == 2  # tx_mac_drop counts the two dropped frames


@cocotb.test()
@cocotb.parametrize(clock_ps=[(31000, 17000), (4200, 5100)])
async def configuration_mailboxes_hold_and_replay(
    dut: Any, clock_ps: tuple[int, int]
) -> None:
    """Busy configuration updates coalesce, and either destination can restart."""
    bench = Bench(dut)
    await bench.start(tx_ps=clock_ps[0], rx_ps=clock_ps[1])
    cdc = dut.u_cdc
    mailboxes = (cdc.u_mac_rx_mbx, cdc.u_tx_cfg_mbx)

    async def check_hold(mailbox: Any) -> None:
        held = None
        while True:
            await FallingEdge(dut.i_clk)
            busy = not int(mailbox.o_src_idle.value)
            payload = int(mailbox.payload_q.value)
            if held is not None and busy:
                assert payload == held, "mailbox payload changed before acknowledgement"
            held = payload if busy else None

    for mailbox in mailboxes:
        cocotb.start_soon(check_hold(mailbox))
    values = (0x123456789ABC, 0xFEDCBA987654, 0x010203040506)

    async def check_values() -> None:
        allowed = {0, int.from_bytes(STATION, "little"), *values}
        while True:
            await Timer(1, unit="ns")
            assert int(cdc.mac_rx_s.value) in allowed
            assert int(cdc.mac_tx_s.value) in allowed
            if int(cdc.mac_tx_s.value) in values:
                assert int(cdc.interval_cfg_s.value) == (
                    int(cdc.mac_tx_s.value) & 0xFFFF
                )

    cocotb.start_soon(check_values())
    for value in values:
        await FallingEdge(dut.i_clk)
        dut.i_station_mac.value = value
        dut.i_pause_interval.value = value & 0xFFFF
        await ClockCycles(dut.i_clk, 2)
    await ClockCycles(dut.i_clk, 200)
    assert int(cdc.mac_rx_s.value) == values[-1]
    assert int(cdc.mac_tx_s.value) == values[-1]
    assert int(cdc.interval_cfg_s.value) == (values[-1] & 0xFFFF)
    for domain, clk_ok in ((1, dut.i_tx_clk_ok), (2, dut.i_rx_clk_ok)):
        # Launch an update immediately before the destination's reset request.
        await FallingEdge(dut.i_clk)
        dut.i_station_mac.value = values[0]
        dut.i_pause_interval.value = values[0] & 0xFFFF
        await FallingEdge(dut.i_clk)
        clk_ok.value = 0
        for _ in range(200):
            if (int(dut.o_ready.value) & domain) == 0:
                break
            await ClockCycles(dut.i_clk, 1)
        else:
            raise AssertionError(f"domain {domain} did not enter reset")
        await ClockCycles(dut.i_clk, 80)
        assert int(cdc.mac_tx_s.value if domain == 1 else cdc.mac_rx_s.value) == 0
        await FallingEdge(dut.i_clk)
        dut.i_station_mac.value = values[-1]
        dut.i_pause_interval.value = values[-1] & 0xFFFF
        clk_ok.value = 1
        for _ in range(1000):
            if int(dut.o_ready.value) == 3:
                break
            await ClockCycles(dut.i_clk, 1)
        else:
            raise AssertionError(f"domain {domain} did not recover after clock return")
        await ClockCycles(dut.i_clk, 200)
        assert int(cdc.mac_rx_s.value) == values[-1]
        assert int(cdc.mac_tx_s.value) == values[-1]
        assert int(cdc.interval_cfg_s.value) == (values[-1] & 0xFFFF)


@cocotb.skipif(_gmii(), reason="requires independent 10G receive stream")
@cocotb.test()
async def received_pause_mailbox_keeps_latest_pending_interval(dut: Any) -> None:
    """Check that a busy mailbox holds its payload, then sends the newest event."""
    bench = Bench(dut)
    await bench.start(tx_ps=140000, rx_ps=6206)
    await bench.configure(CTRL_RX)
    delivered: list[int] = []
    cdc = dut.u_cdc

    async def observe() -> None:
        while True:
            await RisingEdge(dut.i_tx_clk)
            if int(cdc.pause_ev_tx.value):
                delivered.append(int(cdc.pause_interval_tx.value))

    cocotb.start_soon(observe())
    for quanta in (0x1234, 0xABCD, 0):
        bench.link.send(pause_frame(quanta))
    await bench.drain_link()
    await ClockCycles(dut.i_tx_clk, 30)
    assert delivered == [0x1234, 0], delivered
    assert not int(cdc.tx_paused.value)


@cocotb.test()
async def tx_side_fifo_stays_with_frames_at_capacity(dut: Any) -> None:
    """Side entries stall at capacity and stay paired through abort and data stalls."""
    bench = Bench(dut)
    await bench.start()
    await bench.configure(CTRL_RX)
    cdc = dut.u_cdc
    expected: deque[tuple[int, int, int, int | None]] = deque()
    observed = 0

    async def observe() -> None:
        nonlocal observed
        while True:
            await RisingEdge(dut.i_tx_clk)
            if int(cdc.f_valid.value) and int(cdc.f_ready.value):
                assert expected, "extra FIFO beat"
                data, code, abort, csum = expected.popleft()
                word = int(cdc.f_word.value)
                assert word & ((1 << 64) - 1) == data
                assert (word >> 64) & 15 == code
                assert word >> 83 == abort
                if csum is not None:
                    assert (word >> 68) & 0x7FFF == csum
                observed += 1

    def queue(body: bytes, csum: int, abort: bool = False) -> None:
        for offset in range(0, len(body), 8):
            part = body[offset : offset + 8]
            last = offset + 8 >= len(body)
            dropped = abort and last
            code = 8 if dropped else len(part) - 1 + 8 * last
            expected.append(
                (
                    int.from_bytes(part, "little"),
                    code,
                    int(dropped),
                    csum if offset == 0 else None,
                )
            )
        bench.send_tx(body, abort=abort, csum=csum)

    async def pause() -> None:
        bench.link.send(pause_frame(0xFFFF))
        await bench.drain_link()
        assert int(cdc.tx_paused.value)

    async def release_and_drain() -> None:
        bench.link.send(pause_frame(0))
        for _ in range(10000):
            await ClockCycles(dut.i_clk, 20)
            if not expected:
                return
        raise AssertionError(f"{len(expected)} FIFO beats did not drain")

    cocotb.start_soon(observe())
    await pause()
    for index in range(40):
        body = bytes([index]) if index % 4 == 0 else data_frame(60, index)
        queue(body, (index * 997) & 0x7FFF, abort=index == 17)
    await ClockCycles(dut.i_clk, 700)
    assert not int(cdc.tx_csum_ready.value), "side FIFO did not reach capacity"
    assert int(cdc.tx_data_ready.value), "data FIFO hid the side FIFO limit"
    assert not int(dut.s_axis_tx_tready.value)
    await release_and_drain()
    await pause()
    queue(data_frame(9000, 99), 0x6543)
    await ClockCycles(dut.i_clk, 1000)
    assert not int(cdc.tx_data_ready.value), "jumbo frame did not fill the data FIFO"
    await release_and_drain()
    assert observed > 1100
    await bench.wait_wire(40, 300_000)

    # Discard a partial frame at both FIFO halves, then accept a fresh first beat.
    await pause()
    queue(data_frame(9000, 100), 0x1234)
    await ClockCycles(dut.i_clk, 200)
    bench.tx_task.cancel()
    await FallingEdge(dut.i_clk)
    dut.s_axis_tx_tvalid.value = 0
    dut.i_tx_clk_ok.value = 0
    expected.clear()
    for _ in range(200):
        if (int(dut.o_ready.value) & 1) == 0:
            break
        await ClockCycles(dut.i_clk, 1)
    await ClockCycles(dut.i_clk, 80)
    dut.i_tx_clk_ok.value = 1
    for _ in range(1000):
        if int(dut.o_ready.value) == 3:
            break
        await ClockCycles(dut.i_clk, 1)
    assert int(dut.o_ready.value) == 3
    await ClockCycles(dut.i_clk, 100)
    bench.tx_task = cocotb.start_soon(bench._tx_feeder())
    queue(data_frame(61, 101), 0x4566)
    await release_and_drain()
