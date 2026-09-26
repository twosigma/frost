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

"""Test the whole MAC/PCS in both directions against software raw-bitstream peers."""

from collections import deque
import random
from typing import Any
import zlib

import cocotb
from cocotb.triggers import Timer

from net10g.test_codec import decode_reference, encode_reference
from net10g.test_scrambler import SerialReference


def frame_words(
    payload: bytes, lane: int = 0, bad_crc: bool = False
) -> list[tuple[int, int]]:
    """Return one frame's XGMII words: /S/, preamble, body, zlib FCS, /T/, idles.

    /S/ is on ``lane`` (0 or 4), the body is padded to 60 bytes, ``bad_crc``
    flips one FCS bit, and at least 16 idles follow /T/.
    """
    body = payload.ljust(60, b"\0")
    crc = zlib.crc32(body) ^ int(bad_crc)
    symbols = [(7, 1)] * lane + [(0xFB, 1)]
    symbols += [
        (value, 0) for value in b"\x55" * 6 + b"\xd5" + body + crc.to_bytes(4, "little")
    ]
    symbols += [(0xFD, 1)]
    symbols += [(7, 1)] * ((-len(symbols)) % 8 + 16)
    return [
        (
            sum(
                value << (8 * lane)
                for lane, (value, _) in enumerate(symbols[pos : pos + 8])
            ),
            sum(
                control << lane
                for lane, (_, control) in enumerate(symbols[pos : pos + 8])
            ),
        )
        for pos in range(0, len(symbols), 8)
    ]


def raw_stream(words: list[tuple[int, int]], offset: int = 0) -> deque[int]:
    """Encode and scramble words, then pack the 66-bit blocks into 64-bit raw words.

    The first block starts ``offset`` bits in, after that many one bits.
    """
    scrambler = SerialReference()
    reservoir, count = (1 << offset) - 1, offset
    result: deque[int] = deque()
    for data, ctrl in words:
        payload, header, error = encode_reference(
            list(data.to_bytes(8, "little")), ctrl
        )
        assert not error
        block = (scrambler.word(payload) << 2) | header
        reservoir |= block << count
        count += 66
        while count >= 64:
            result.append(reservoir & ((1 << 64) - 1))
            reservoir >>= 64
            count -= 64
    return result


class WireReceiver:
    """Software receiver for the DUT's raw transmit stream; checks each frame."""

    def __init__(self) -> None:
        """Start at the reset stream's first sync-header bit."""
        self.reservoir = 0
        self.count = 0
        self.descrambler = SerialReference(True)
        self.active: bytearray | None = None
        self.frames: list[bytes] = []

    def word(self, value: int) -> None:
        """Consume one raw word and check every frame it completes."""
        self.reservoir |= value << self.count
        self.count += 64
        while self.count >= 66:
            header = self.reservoir & 3
            payload = (self.reservoir >> 2) & ((1 << 64) - 1)
            self.reservoir >>= 66
            self.count -= 66
            assert header in (1, 2)
            data, ctrl, error = decode_reference(self.descrambler.word(payload), header)
            assert not error, "DUT emitted an invalid block"
            for lane, byte in enumerate(data.to_bytes(8, "little")):
                if ctrl >> lane & 1:
                    if byte == 0xFB:
                        assert lane in (0, 4)
                        assert self.active is None
                        self.active = bytearray()
                    elif byte == 0xFD:
                        assert self.active is not None
                        packet = bytes(self.active)
                        assert packet[:7] == b"\x55" * 6 + b"\xd5"
                        assert len(packet) >= 71
                        body, fcs = packet[7:-4], packet[-4:]
                        assert zlib.crc32(body) == int.from_bytes(fcs, "little")
                        self.frames.append(body)
                        self.active = None
                    elif self.active is not None:
                        raise AssertionError("unexpected control character in a frame")
                elif self.active is not None:
                    self.active.append(byte)


async def initialize(dut: Any) -> None:
    """Reset both clock domains with idle inputs, then release reset with signal OK."""
    dut.i_tx_clk.value = 0
    dut.i_rx_clk.value = 0
    dut.i_tx_rst.value = 1
    dut.i_rx_rst.value = 1
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tdata.value = 0
    dut.s_axis_tkeep.value = 0
    dut.s_axis_tlast.value = 0
    dut.s_axis_tuser.value = 0
    dut.m_axis_tready.value = 1
    dut.i_rx_raw_data.value = 0
    dut.i_rx_raw_valid.value = 0
    dut.i_rx_signal_ok.value = 0
    for _ in range(3):
        dut.i_tx_clk.value = 0
        dut.i_rx_clk.value = 0
        await Timer(3, unit="ns")
        dut.i_tx_clk.value = 1
        dut.i_rx_clk.value = 1
        await Timer(3, unit="ns")
    dut.i_tx_clk.value = 0
    dut.i_rx_clk.value = 0
    dut.i_tx_rst.value = 0
    dut.i_rx_rst.value = 0
    dut.i_rx_signal_ok.value = 1


async def exchange(
    dut: Any,
    incoming: deque[int],
    tx_frames: list[bytes],
    rx_expected: list[bytes],
    rng: random.Random,
    stalls: bool = True,
    signal_loss: range = range(0),
) -> None:
    """Run both directions at once and check each end.

    ``tx_frames`` go in over AXIS and must appear on the raw transmit stream.
    ``incoming`` raw words go in, and the AXIS output must match
    ``rx_expected`` and hold steady while stalled. The PMA signal is down on
    the cycles in ``signal_loss``.
    """
    tx_beats: deque[tuple[int, int, int]] = deque()
    for frame in tx_frames:
        for pos in range(0, len(frame), 8):
            beat = frame[pos : pos + 8]
            tx_beats.append(
                (
                    int.from_bytes(beat, "little"),
                    (1 << len(beat)) - 1,
                    int(pos + 8 >= len(frame)),
                )
            )
    offered: tuple[int, int, int] | None = None
    received: list[bytes] = []
    packet = bytearray()
    wire = WireReceiver()
    previous: tuple[int, int, int, int] | None = None
    raw_started = False
    for cycle in range(len(incoming) + 5000):
        dut.i_tx_clk.value = 0
        dut.i_rx_clk.value = 0
        dut.i_rx_signal_ok.value = int(cycle not in signal_loss)
        if incoming:
            dut.i_rx_raw_data.value = incoming.popleft()
            dut.i_rx_raw_valid.value = 1
        else:
            dut.i_rx_raw_valid.value = 0
        ready = not stalls or rng.random() < 0.85
        dut.m_axis_tready.value = int(ready)
        if offered is None and tx_beats and (not stalls or rng.random() < 0.8):
            offered = tx_beats[0]
        dut.s_axis_tvalid.value = int(offered is not None)
        if offered:
            dut.s_axis_tdata.value, dut.s_axis_tkeep.value, dut.s_axis_tlast.value = (
                offered
            )
        await Timer(3, unit="ns")
        assert not int(dut.s_axis_tready.value) or int(dut.o_tx_link_ready.value)
        if int(dut.o_tx_raw_valid.value):
            raw_started = True
            wire.word(int(dut.o_tx_raw_data.value))
        elif raw_started:
            raise AssertionError("transmit raw stream paused after startup")
        if offered and int(dut.s_axis_tready.value):
            tx_beats.popleft()
            offered = None
        valid = int(dut.m_axis_tvalid.value)
        values = (
            int(dut.m_axis_tdata.value),
            int(dut.m_axis_tkeep.value),
            int(dut.m_axis_tlast.value),
            int(dut.m_axis_tuser.value),
        )
        if previous is not None:
            assert valid and values == previous, "AXIS output changed while stalled"
        previous = values if valid and not ready else None
        if valid and ready:
            data, keep, last, bad = values
            assert not bad
            assert keep != 0 and (keep & (keep + 1)) == 0
            if not last:
                assert keep == 255
            packet += data.to_bytes(8, "little")[: keep.bit_count()]
            if last:
                received.append(bytes(packet))
                packet.clear()
        assert not int(dut.o_rx_overflow.value)
        assert not int(dut.o_tx_drop.value)
        assert not int(dut.o_tx_bad_block.value)
        dut.i_tx_clk.value = 1
        # Deliberately different clock phase: no shared edge assumptions.
        await Timer(1, unit="ns")
        dut.i_rx_clk.value = 1
        await Timer(2, unit="ns")
        if (
            not incoming
            and not tx_beats
            and len(wire.frames) == len(tx_frames)
            and len(received) == len(rx_expected)
        ):
            break
    assert received == rx_expected, (
        [len(frame) for frame in received],
        [len(frame) for frame in rx_expected],
    )
    assert wire.frames == [frame.ljust(60, b"\0") for frame in tx_frames], (
        [len(frame) for frame in wire.frames],
        [len(frame) for frame in tx_frames],
    )
    assert int(dut.o_rx_locked.value)


@cocotb.test()
async def independent_full_duplex_peers(dut: Any) -> None:
    """Check mixed frame sizes both ways, CRC rejection, /T/ lookahead, and stalls."""
    rng = random.Random(0x10_64_66)
    await initialize(dut)
    idle = (0x0707070707070707, 255)
    words = [idle] * 700
    rx_frames = [
        rng.randbytes(length) for length in [9216, *range(60, 76), 1500, 9018, 60, 64]
    ]
    for index, frame in enumerate(rx_frames):
        words += frame_words(frame, 4 * (index % 2))
        if index == 3:
            words += frame_words(rng.randbytes(137), bad_crc=True)
            # A /T/ followed by an illegal next block fails the frame even with a
            # correct FCS: the PCS lookahead must keep the MAC from publishing it.
            for following in [
                (rng.getrandbits(64), 0),
                (0x07070707070707FD, 255),
                (0xFEFEFEFEFEFEFEFE, 255),
            ]:
                malformed = frame_words(rng.randbytes(89))
                terminate = next(
                    pos
                    for pos, (data, ctrl) in enumerate(malformed)
                    if any(
                        ctrl >> lane & 1 and data >> (8 * lane) & 255 == 0xFD
                        for lane in range(8)
                    )
                )
                malformed[terminate + 1] = following
                words += malformed + [idle] * 4
    words += [idle] * 5000
    tx_frames = [
        rng.randbytes(length)
        for length in [1, 59, *range(60, 76), 1518, 9216, 60, 1024]
    ]
    await exchange(dut, raw_stream(words, 37), tx_frames, rx_frames, rng)


@cocotb.test()
async def every_receive_bit_phase(dut: Any) -> None:
    """Lock to the raw stream at each of the 66 bit offsets and receive a frame."""
    rng = random.Random(66)
    idle = (0x0707070707070707, 255)
    for offset in range(66):
        await initialize(dut)
        frame = rng.randbytes(60 + offset)
        words = [idle] * 700 + frame_words(frame, 4 * (offset % 2)) + [idle] * 150
        await exchange(dut, raw_stream(words, offset), [], [frame], rng, stalls=False)


@cocotb.test()
async def signal_loss_discards_partial_frame_and_relocks(dut: Any) -> None:
    """Drop the frame in progress on PMA signal loss, then relock for the next one."""
    rng = random.Random(0x1055)
    await initialize(dut)
    idle = (0x0707070707070707, 255)
    damaged = rng.randbytes(9216)
    recovered = rng.randbytes(1500)
    words = [idle] * 700 + frame_words(damaged, 4) + [idle] * 700
    words += frame_words(recovered) + [idle] * 300
    await exchange(
        dut, raw_stream(words, 11), [], [recovered], rng, signal_loss=range(800, 820)
    )
