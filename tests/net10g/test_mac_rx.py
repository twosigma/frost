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

"""Receive MAC tests with independently constructed Ethernet wire packets.

The expected FCS comes from Python's zlib, not the RTL CRC implementation.
Wire packets include preamble and XGMII delimiters; expected AXI Stream
packets include destination address through padding and exclude the FCS.
"""

from collections.abc import Iterable
import random
from typing import Any
import zlib

import cocotb
from cocotb.triggers import Timer


IDLE = (0x07, 1)
IDLE_WORD = (0x0707070707070707, 0xFF)
MAX_FRAME_BYTES = 9216
Symbol = tuple[int, int]
Word = tuple[int, int]


def pack_symbols(symbols: Iterable[Symbol]) -> list[Word]:
    """Pack chronological (byte, control) symbols into little-endian XGMII."""
    symbols = list(symbols)
    symbols += [IDLE] * (-len(symbols) % 8)
    return [
        (
            sum(
                byte << (8 * lane) for lane, (byte, _) in enumerate(symbols[n : n + 8])
            ),
            sum(
                control << lane for lane, (_, control) in enumerate(symbols[n : n + 8])
            ),
        )
        for n in range(0, len(symbols), 8)
    ]


def frame_symbols(
    payload: bytes, start_lane: int = 0, bad_crc: bool = False
) -> list[Symbol]:
    """Build a full wire packet with a zlib-generated little-endian FCS."""
    fcs = bytearray(zlib.crc32(payload).to_bytes(4, "little"))
    if bad_crc:
        fcs[0] ^= 0x80
    return (
        [IDLE] * start_lane
        + [(0xFB, 1)]
        + [(0x55, 0)] * 6
        + [(0xD5, 0)]
        + [(byte, 0) for byte in payload + fcs]
        + [(0xFD, 1)]
    )


class ReceiveBench:
    """Drive XGMII and independently capture and check AXI Stream handshakes."""

    def __init__(self, dut: Any) -> None:
        """Initialize scoreboard and protocol stability checks."""
        self.dut = dut
        self.received: list[bytes] = []
        self.partial = bytearray()
        self.stalled: tuple[int, int, int, int, int] | None = None
        self.bad_frames = 0
        self.bad_fcs = 0
        self.overflows = 0

    def reset_observation(self) -> None:
        """Clear the scoreboard after DUT reset."""
        self.received.clear()
        self.partial.clear()
        self.stalled = None
        self.bad_frames = 0
        self.bad_fcs = 0
        self.overflows = 0

    async def step(
        self,
        word: Word = IDLE_WORD,
        ready: bool = True,
        enable: bool = True,
        reset: bool = False,
    ) -> None:
        """Advance one clock and sample the accepted beat before its rising edge."""
        dut = self.dut
        dut.i_clk.value = 0
        dut.i_rst.value = int(reset)
        dut.i_enable.value = int(enable)
        dut.i_xgmii_data.value, dut.i_xgmii_ctrl.value = word
        dut.m_axis_tready.value = int(ready)
        await Timer(2, unit="ns")

        snapshot = (
            int(dut.m_axis_tvalid.value),
            int(dut.m_axis_tdata.value),
            int(dut.m_axis_tkeep.value),
            int(dut.m_axis_tlast.value),
            int(dut.m_axis_tuser.value),
        )
        if not reset:
            if self.stalled is not None:
                assert snapshot == self.stalled, "AXI Stream changed while stalled"
            valid, data, keep, last, user = snapshot
            self.stalled = snapshot if valid and not ready else None
            if valid and ready:
                assert user == 0, "A bad frame escaped store-and-forward validation"
                assert keep > 0 and (keep & (keep + 1)) == 0
                if not last:
                    assert keep == 0xFF
                self.partial.extend(data.to_bytes(8, "little")[: keep.bit_count()])
                if last:
                    self.received.append(bytes(self.partial))
                    self.partial.clear()
        else:
            self.stalled = None
            self.partial.clear()

        dut.i_clk.value = 1
        await Timer(2, unit="ns")
        if not reset:
            self.bad_frames += int(dut.o_bad_frame.value)
            self.bad_fcs += int(dut.o_bad_fcs.value)
            self.overflows += int(dut.o_overflow.value)

    async def reset(self) -> None:
        """Reset the DUT and scoreboard, discarding any partial output packet."""
        await self.step(reset=True)
        await self.step(reset=True)
        self.reset_observation()
        await self.step()

    async def send(
        self,
        payload: bytes,
        start_lane: int = 0,
        ready: bool = True,
        bad_crc: bool = False,
    ) -> None:
        """Send one packet followed by two idle words."""
        for word in pack_symbols(frame_symbols(payload, start_lane, bad_crc)):
            await self.step(word, ready=ready)
        await self.step(ready=ready)
        await self.step(ready=ready)

    async def drain(self, cycles: int = 64) -> None:
        """Keep the sink ready while presenting idle words."""
        for _ in range(cycles):
            await self.step()


@cocotb.test()
async def good_frames_all_alignments(dut: Any) -> None:
    """Both start lanes, all terminate lanes, min/max sizes, consecutive packets."""
    bench = ReceiveBench(dut)
    await bench.reset()
    rng = random.Random(0x10_64_66)
    expected = []
    for start_lane in (0, 4):
        for length in list(range(60, 84)) + [128, 1514, MAX_FRAME_BYTES]:
            payload = rng.randbytes(length)
            expected.append(payload)
            await bench.send(payload, start_lane)
    await bench.drain(MAX_FRAME_BYTES // 8 + 32)
    assert bench.received == expected
    assert not bench.partial
    assert (bench.bad_frames, bench.bad_fcs, bench.overflows) == (0, 0, 0)


@cocotb.test()
async def bad_packets_and_recovery(dut: Any) -> None:
    """Every corrupt packet is followed by a known good packet."""
    bench = ReceiveBench(dut)
    await bench.reset()
    rng = random.Random(0xBAD_FC5)
    payload = rng.randbytes(100)
    malformed = []
    malformed.append(frame_symbols(payload, bad_crc=True))
    malformed.append(frame_symbols(rng.randbytes(59)))  # CRC-correct runt
    malformed.append(frame_symbols(rng.randbytes(MAX_FRAME_BYTES + 1)))
    for index in range(1, 8):
        symbols = frame_symbols(payload)
        symbols[index] = (0x54 if index != 7 else 0xD4, 0)
        malformed.append(symbols)
    symbols = frame_symbols(payload, start_lane=4)
    symbols[4 + 8 + 13] = (0xFE, 1)  # XGMII error in the body
    malformed.append(symbols)
    symbols = frame_symbols(payload)
    symbols[8 + 7] = (0x07, 1)  # unexpected idle in the body
    malformed.append(symbols)
    symbols = frame_symbols(payload)
    symbols[8 + 5] = (0xFB, 1)  # /S/ on illegal lane 5
    malformed.append(symbols)

    expected = []
    for index, symbols in enumerate(malformed):
        before_bad = bench.bad_frames
        before_received = len(bench.received)
        for word in pack_symbols(symbols):
            await bench.step(word)
        await bench.drain(32)
        assert (
            bench.bad_frames == before_bad + 1
        ), f"Missing drop event for case {index}"
        assert len(bench.received) == before_received, f"Corrupt case {index} escaped"
        good = rng.randbytes(60 + index)
        expected.append(good)
        await bench.send(good, start_lane=4 * (index % 2))
        await bench.drain(32)
        assert bench.received == expected
    assert bench.bad_fcs == 1
    assert bench.overflows == 0

    # An unterminated frame must not capture a subsequent legitimate /S/.
    for start_lane in (0, 4):
        truncated = [(0xFB, 1)] + [(0x55, 0)] * 6 + [(0xD5, 0)] + [(0xA5, 0)] * 24
        for word in pack_symbols(truncated):
            await bench.step(word)
        good = rng.randbytes(80)
        expected.append(good)
        await bench.send(good, start_lane=start_lane)
        await bench.drain()
        assert bench.received == expected


@cocotb.test()
async def stalls_enable_and_full_buffers(dut: Any) -> None:
    """Queued packets survive arbitrary stalls; overflow rolls back a whole frame."""
    bench = ReceiveBench(dut)
    await bench.reset()
    rng = random.Random(0x57A11)
    packets = [rng.randbytes(MAX_FRAME_BYTES) for _ in range(4)]
    packets.append(rng.randbytes(81))
    await bench.send(packets[0], ready=False)
    await bench.send(packets[1], start_lane=4, ready=False)
    await bench.send(packets[2], ready=False)
    # The fourth jumbo exhausts the remaining storage partway through RX.
    await bench.send(packets[3], start_lane=4, ready=False)
    for _ in range(20):
        await bench.step(ready=False)
    assert bench.received == []
    assert (bench.bad_frames, bench.bad_fcs, bench.overflows) == (1, 0, 1)

    # AXI Stream keeps running while the XGMII enable is deasserted.
    for _ in range(3 * MAX_FRAME_BYTES // 8 + 32):
        await bench.step((rng.getrandbits(64), rng.getrandbits(8)), enable=False)
    assert bench.received == packets[:3]
    assert (bench.bad_frames, bench.bad_fcs, bench.overflows) == (1, 0, 1)

    # Ignore arbitrary XGMII values on disabled clocks, including valid /S/.
    for word in pack_symbols(frame_symbols(packets[4], start_lane=4)):
        for _ in range(rng.randrange(4)):
            await bench.step(
                (0x55555555555555FB, 1), enable=False, ready=bool(rng.randrange(2))
            )
        await bench.step(word, ready=bool(rng.randrange(2)))
    await bench.drain()
    assert bench.received == packets[:3] + [packets[4]]

    # Reset invalidates a queued packet, an in-progress frame, and stalled data.
    await bench.send(packets[4], ready=False)
    for word in pack_symbols(frame_symbols(packets[0]))[:4]:
        await bench.step(word, ready=False)
    await bench.reset()
    await bench.drain()
    assert bench.received == []
    await bench.send(packets[4], start_lane=4)
    await bench.drain()
    assert bench.received == [packets[4]]
    assert (bench.bad_frames, bench.bad_fcs, bench.overflows) == (0, 0, 0)


@cocotb.test()
async def ring_wrap_and_mixed_line_rate(dut: Any) -> None:
    """Wrap both rings with mixed sizes and 12..15-byte gaps aligned to /S/."""
    bench = ReceiveBench(dut)
    await bench.reset()
    rng = random.Random(0xB0FF3E)
    expected = []
    symbols: list[Symbol] = []
    for index in range(700):
        length = MAX_FRAME_BYTES if index % 31 == 0 else 60 + rng.randrange(16)
        payload = rng.randbytes(length)
        corrupt = index % 29 == 7
        if symbols:
            symbols.extend([IDLE] * 12)
            symbols.extend([IDLE] * (-len(symbols) % 4))
        symbols.extend(frame_symbols(payload, bad_crc=corrupt))
        if not corrupt:
            expected.append(payload)
    for word in pack_symbols(symbols):
        await bench.step(word)
    await bench.drain(MAX_FRAME_BYTES // 8 + 64)
    assert bench.received == expected
    assert (
        bench.overflows == 0
    ), "Continuously ready output must sustain mixed-size traffic"
    assert (
        bench.bad_frames
        == bench.bad_fcs
        == sum(index % 29 == 7 for index in range(700))
    )


@cocotb.test()
async def descriptor_full_and_post_terminate_noise(dut: Any) -> None:
    """Exact full queue and word-ring wrap, plus isolation of interframe symbols."""
    bench = ReceiveBench(dut)
    await bench.reset()
    rng = random.Random(0xD35C)
    # The default 32768-byte data ring holds 512 minimum-size wire frames.
    packets = [rng.randbytes(60) for _ in range(512)]
    for packet in packets:
        await bench.send(packet, ready=False)
    await bench.send(rng.randbytes(60), ready=False)
    assert (bench.bad_frames, bench.bad_fcs, bench.overflows) == (1, 0, 1)
    # The next /S/ coincides with the consumer releasing a descriptor from
    # the previously full queue. It must be available to RX on that edge.
    for _ in range(7):
        await bench.step()
    replacement = rng.randbytes(60)
    await bench.send(replacement)
    packets.append(replacement)
    await bench.drain(512 * 8 + 32)
    assert bench.received == packets

    packet = rng.randbytes(61)
    symbols = frame_symbols(packet)
    # /T/ is lane 1; non-start symbols following it are interframe traffic.
    symbols += [(0xA5, 0), (0xFE, 1), (0xD3, 0), IDLE, IDLE, IDLE]
    for word in pack_symbols(symbols):
        await bench.step(word)
    await bench.drain()
    await bench.send(packets[0], start_lane=4)
    await bench.drain()
    assert bench.received == packets + [packet, packets[0]]
    assert (bench.bad_frames, bench.bad_fcs, bench.overflows) == (1, 0, 1)


@cocotb.test()
async def random_backpressure_and_overflow(dut: Any) -> None:
    """Preserve packet order and bytes through concurrent stalls, drops and reuse."""
    bench = ReceiveBench(dut)
    await bench.reset()
    rng = random.Random(0xC0111DE)
    expected = []
    for index in range(250):
        length = MAX_FRAME_BYTES if index % 9 == 0 else rng.randrange(60, 600)
        packet = rng.randbytes(length)
        corrupt = index % 23 == 4
        before_bad, before_overflow = bench.bad_frames, bench.overflows
        for word in pack_symbols(frame_symbols(packet, 4 * (index % 2), corrupt)):
            if rng.randrange(4) == 0:
                await bench.step(enable=False, ready=rng.randrange(2) == 0)
            await bench.step(word, ready=rng.randrange(2) == 0)
        await bench.step(ready=rng.randrange(2) == 0)
        await bench.step(ready=rng.randrange(2) == 0)
        if corrupt:
            assert bench.bad_frames == before_bad + 1
        elif bench.overflows == before_overflow:
            assert bench.bad_frames == before_bad
            expected.append(packet)
        else:
            assert bench.overflows == before_overflow + 1
            assert bench.bad_frames == before_bad + 1
    await bench.drain(32768 // 8 + 64)
    assert bench.received == expected
    assert bench.overflows > 0
    assert len(expected) > 30
