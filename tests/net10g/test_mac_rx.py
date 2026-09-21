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

NET10G_MAX_FRAME_BYTES selects the frame limit, as the Makefile passes it to
the RTL; storage sizes follow from it as in eth10g_mac_rx. Cycle-exact cases
use the MAC's timing contract: an XGMII word presented on clock t is decided
on clock t + 1, and storage or a descriptor released by the output handshake
on clock t is visible to decisions on clock t + 2.
"""

from collections.abc import Iterable
import os
import random
from typing import Any
import zlib

import cocotb
from cocotb.triggers import Timer


IDLE = (0x07, 1)
IDLE_WORD = (0x0707070707070707, 0xFF)
MAX_FRAME_BYTES = int(os.environ.get("NET10G_MAX_FRAME_BYTES", "9216"))
# Data ring and descriptor queue, derived as in eth10g_mac_rx.
MEMORY_WORDS = 1 << (2 * ((MAX_FRAME_BYTES + 11) // 8) - 1).bit_length()
DESCRIPTOR_SLOTS = MEMORY_WORDS // 8
Symbol = tuple[int, int]
Word = tuple[int, int]


def storage_words(length: int) -> int:
    """Return the data-ring words a packet uses: payload plus FCS, word-aligned."""
    return (length + 11) // 8


def payload_for_words(words: int) -> int:
    """Return the largest payload length that occupies exactly this many words."""
    return 8 * words - 4


# The largest frame, plus FCS, fills its last word only at some limits; there
# its first excess byte also needs a new storage word.
LIMIT_ON_WORD_BOUNDARY = (MAX_FRAME_BYTES + 4) % 8 == 0


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


def wire_words(
    payload: bytes, start_lane: int = 0, bad_crc: bool = False
) -> list[Word]:
    """Return the XGMII words of one wire packet, padded with idles."""
    return pack_symbols(frame_symbols(payload, start_lane, bad_crc))


def fill_plan(words: int) -> list[int]:
    """Choose payload lengths of committed packets that occupy exactly `words`."""
    lengths = []
    largest = storage_words(MAX_FRAME_BYTES)
    while words:
        take = min(words, largest)
        if 0 < words - take < 8:
            take = words - 8
        assert 8 <= take <= largest, f"no packet mix occupies {words} words"
        lengths.append(min(payload_for_words(take), MAX_FRAME_BYTES))
        words -= take
    return lengths


def reservation_plan() -> tuple[list[int], int]:
    """Queue packets so that fewer words are free than a maximum frame needs.

    Returns the queued payload lengths and the free words left. At a 60-byte
    limit every packet is exactly eight words, so none remain.
    """
    largest = storage_words(MAX_FRAME_BYTES)
    lengths: list[int] = []
    free = MEMORY_WORDS
    while free > largest:
        lengths.append(MAX_FRAME_BYTES)
        free -= largest
    if free == largest:
        lengths.append(60)
        free -= 8
    return lengths, free


RESERVATION_FILLS, RESERVATION_FREE = reservation_plan()


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

    def events(self) -> tuple[int, int, int]:
        """Return the bad-frame, FCS and overflow event counts."""
        return (self.bad_frames, self.bad_fcs, self.overflows)

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

    async def present(self, words: Iterable[Word], ready: bool = False) -> None:
        """Present XGMII words on consecutive enabled clocks."""
        for word in words:
            await self.step(word, ready=ready)

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
    lengths = [n for n in [*range(60, 84), 128, 1514] if n < MAX_FRAME_BYTES]
    for start_lane in (0, 4):
        for length in lengths + [MAX_FRAME_BYTES]:
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
    payload = rng.randbytes(min(100, MAX_FRAME_BYTES))
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
        assert bench.bad_frames == before_bad + 1, (
            f"Missing drop event for case {index}"
        )
        assert len(bench.received) == before_received, f"Corrupt case {index} escaped"
        good = rng.randbytes(min(60 + index, MAX_FRAME_BYTES))
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
        good = rng.randbytes(min(80, MAX_FRAME_BYTES))
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
    fit = MEMORY_WORDS // storage_words(MAX_FRAME_BYTES)
    packets = [rng.randbytes(MAX_FRAME_BYTES) for _ in range(fit + 1)]
    packets.append(rng.randbytes(min(81, MAX_FRAME_BYTES)))
    for index in range(fit):
        await bench.send(packets[index], start_lane=4 * (index % 2), ready=False)
    # One more maximum frame exhausts the remaining storage (partway through RX
    # at the default limit; at its /S/ when the ring holds whole maximum frames).
    await bench.send(packets[fit], start_lane=4 * (fit % 2), ready=False)
    for _ in range(20):
        await bench.step(ready=False)
    assert bench.received == []
    assert (bench.bad_frames, bench.bad_fcs, bench.overflows) == (1, 0, 1)

    # AXI Stream keeps running while the XGMII enable is deasserted.
    for _ in range(fit * MAX_FRAME_BYTES // 8 + 32):
        await bench.step((rng.getrandbits(64), rng.getrandbits(8)), enable=False)
    assert bench.received == packets[:fit]
    assert (bench.bad_frames, bench.bad_fcs, bench.overflows) == (1, 0, 1)

    # Ignore arbitrary XGMII values on disabled clocks, including valid /S/.
    for word in pack_symbols(frame_symbols(packets[fit + 1], start_lane=4)):
        for _ in range(rng.randrange(4)):
            await bench.step(
                (0x55555555555555FB, 1), enable=False, ready=bool(rng.randrange(2))
            )
        await bench.step(word, ready=bool(rng.randrange(2)))
    await bench.drain()
    assert bench.received == packets[:fit] + [packets[fit + 1]]

    # Reset invalidates a queued packet, an in-progress frame, and stalled data.
    await bench.send(packets[fit + 1], ready=False)
    for word in pack_symbols(frame_symbols(packets[0]))[:4]:
        await bench.step(word, ready=False)
    await bench.reset()
    await bench.drain()
    assert bench.received == []
    await bench.send(packets[fit + 1], start_lane=4)
    await bench.drain()
    assert bench.received == [packets[fit + 1]]
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
        if index % 31 == 0:
            length = MAX_FRAME_BYTES
        else:
            length = min(60 + rng.randrange(16), MAX_FRAME_BYTES)
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
    assert bench.overflows == 0, (
        "Continuously ready output must sustain mixed-size traffic"
    )
    assert (
        bench.bad_frames
        == bench.bad_fcs
        == sum(index % 29 == 7 for index in range(700))
    )


@cocotb.test()
async def descriptor_full_and_post_terminate_noise(dut: Any) -> None:
    """Exact full queue, release timing, and isolation of interframe symbols."""
    bench = ReceiveBench(dut)
    await bench.reset()
    rng = random.Random(0xD35C)
    # The data ring holds exactly one minimum-size wire frame per descriptor.
    packets = [rng.randbytes(60) for _ in range(DESCRIPTOR_SLOTS)]
    for packet in packets:
        await bench.send(packet, ready=False)
    await bench.send(rng.randbytes(60), ready=False)
    assert (bench.bad_frames, bench.bad_fcs, bench.overflows) == (1, 0, 1)

    # The stalled output register holds the first two beats of packets[0], so
    # seven handshakes leave its final beat there. The next /S/ arrives on the
    # clock whose handshake consumes that beat. The reader copied the beat
    # earlier, but the descriptor is released by the handshake and reaches the
    # word stage two clocks later: this start is refused although seven freed
    # words are already visible.
    for _ in range(7):
        await bench.step()
    await bench.step(wire_words(rng.randbytes(60))[0])
    # One clock later the descriptor is available. The output register holds
    # one beat when this start is decided.
    replacement = rng.randbytes(60)
    words = wire_words(replacement)
    await bench.step(words[0])
    await bench.present(words[1:], ready=False)
    await bench.step(ready=False)
    await bench.step(ready=False)
    assert (bench.bad_frames, bench.bad_fcs, bench.overflows) == (2, 0, 2)

    # Full again, with packets[1] now at the output from its second beat.
    # Seven handshakes consume it, and a start on the following clock, with the
    # output stalled and full, is admitted.
    for _ in range(7):
        await bench.step()
    second = rng.randbytes(60)
    await bench.present(wire_words(second), ready=False)
    await bench.step(ready=False)
    await bench.step(ready=False)
    assert (bench.bad_frames, bench.bad_fcs, bench.overflows) == (2, 0, 2)
    packets += [replacement, second]
    await bench.drain(DESCRIPTOR_SLOTS * 8 + 32)
    assert bench.received == packets

    packet = rng.randbytes(61 if MAX_FRAME_BYTES > 60 else 60)
    symbols = frame_symbols(packet)
    # /T/ is lane 1 (lane 0 at a 60-byte limit); non-start symbols following
    # it are interframe traffic.
    symbols += [(0xA5, 0), (0xFE, 1), (0xD3, 0), IDLE, IDLE, IDLE]
    for word in pack_symbols(symbols):
        await bench.step(word)
    await bench.drain()
    await bench.send(packets[0], start_lane=4)
    await bench.drain()
    assert bench.received == packets + [packet, packets[0]]
    assert (bench.bad_frames, bench.bad_fcs, bench.overflows) == (2, 0, 2)


@cocotb.test()
async def random_backpressure_and_overflow(dut: Any) -> None:
    """Preserve packet order and bytes through concurrent stalls, drops and reuse."""
    bench = ReceiveBench(dut)
    await bench.reset()
    rng = random.Random(0xC0111DE)
    expected = []
    for index in range(250):
        if index % 9 == 0:
            length = MAX_FRAME_BYTES
        else:
            length = min(rng.randrange(60, 600), MAX_FRAME_BYTES)
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
    await bench.drain(MEMORY_WORDS + 64)
    assert bench.received == expected
    assert bench.overflows > 0
    assert len(expected) > 30


@cocotb.test()
async def start_lane4_across_enable_gaps(dut: Any) -> None:
    """Finish a preamble begun by /S/ on lane 4 in the next enabled word."""
    bench = ReceiveBench(dut)
    await bench.reset()
    rng = random.Random(0x546A9)
    lengths = sorted({min(n, MAX_FRAME_BYTES) for n in (60, 61, 64, 67, 71, 131)})
    disabled_words = [
        (0x555555FB07070707, 0x1F),
        (0x55555555555555FB, 0x01),
        (0xD5555555AAAAAAAA, 0x00),
    ]
    expected = []
    # Disabled clocks follow the /S/ word, the preamble's final word, or the
    # first data word; they carry start-like and preamble-like values.
    for gap_after in range(3):
        for length in lengths:
            payload = rng.randbytes(length)
            expected.append(payload)
            for index, word in enumerate(wire_words(payload, start_lane=4)):
                await bench.step(word)
                if index == gap_after:
                    for _ in range(1 + rng.randrange(3)):
                        await bench.step(rng.choice(disabled_words), enable=False)
            await bench.step()
    await bench.drain(MAX_FRAME_BYTES // 8 + 32)
    assert bench.received == expected
    assert bench.events() == (0, 0, 0)


@cocotb.test()
async def preamble_corruption_every_position(dut: Any) -> None:
    """Drop one frame for a wrong byte or control character in its preamble."""
    bench = ReceiveBench(dut)
    await bench.reset()
    rng = random.Random(0x9EA3B1E)
    expected = []
    for start_lane in (0, 4):
        # Position 7 is the SFD; after /S/ on lane 4, positions 4-7 are in the
        # next word.
        for position in range(1, 8):
            wanted = 0xD5 if position == 7 else 0x55
            swapped = 0x55 if position == 7 else 0xD5
            for corrupt in ((wanted ^ 0x01, 0), (swapped, 0), (0xFE, 1)):
                symbols = frame_symbols(
                    rng.randbytes(min(70, MAX_FRAME_BYTES)), start_lane
                )
                symbols[start_lane + position] = corrupt
                before = bench.events()
                await bench.present(pack_symbols(symbols), ready=True)
                await bench.drain(4)
                assert bench.events() == (before[0] + 1, before[1], before[2]), (
                    start_lane,
                    position,
                    corrupt,
                )
                good = rng.randbytes(min(60 + position, MAX_FRAME_BYTES))
                expected.append(good)
                await bench.send(good, start_lane=4 - start_lane)
    await bench.drain(32)
    assert bench.received == expected


@cocotb.test()
async def runts_and_fcs_errors_every_termination_lane(dut: Any) -> None:
    """Short frames, including /T/ right after the SFD, and bad FCS at every lane."""
    bench = ReceiveBench(dut)
    await bench.reset()
    rng = random.Random(0x7E12)
    expected = []
    for start_lane in (0, 4):
        # Bytes between SFD and /T/ with no valid FCS: an FCS error needs at
        # least four frame bytes (independently judged by zlib).
        for count in range(64):
            body = rng.randbytes(count)
            fcs_error = count >= 4 and zlib.crc32(body[:-4]) != int.from_bytes(
                body[-4:], "little"
            )
            symbols = [IDLE] * start_lane + [(0xFB, 1)] + [(0x55, 0)] * 6
            symbols += [(0xD5, 0)] + [(byte, 0) for byte in body] + [(0xFD, 1)]
            before = bench.events()
            await bench.present(pack_symbols(symbols), ready=True)
            await bench.drain(2)
            assert bench.events() == (
                before[0] + 1,
                before[1] + int(fcs_error),
                before[2],
            ), (start_lane, count)
        # CRC-correct runts and full-size frames with a bad FCS, over every
        # termination lane.
        for length in range(60):
            before = bench.events()
            await bench.send(rng.randbytes(length), start_lane)
            assert bench.events() == (before[0] + 1, before[1], before[2]), length
        for length in range(60, 68):
            length = min(length, MAX_FRAME_BYTES)
            before = bench.events()
            await bench.send(rng.randbytes(length), start_lane, bad_crc=True)
            assert bench.events() == (before[0] + 1, before[1] + 1, before[2]), length
            good = rng.randbytes(length)
            expected.append(good)
            await bench.send(good, start_lane)
    await bench.drain(32)
    assert bench.received == expected
    assert bench.overflows == 0


@cocotb.test(skip=not LIMIT_ON_WORD_BOUNDARY)
async def overlength_outranks_no_space(dut: Any) -> None:
    """Report the first byte past the limit as overlength, even with no free word."""
    bench = ReceiveBench(dut)
    await bench.reset()
    rng = random.Random(0x0F11)
    largest = storage_words(MAX_FRAME_BYTES)
    queued: list[bytes] = []
    while MEMORY_WORDS - largest * len(queued) > largest:
        queued.append(rng.randbytes(MAX_FRAME_BYTES))
    for packet in queued:
        await bench.send(packet, ready=False)
    # Exactly `largest` words are free. The overlength frame reserves all of
    # them; its next byte starts a word with none free and is past the limit.
    await bench.send(rng.randbytes(MAX_FRAME_BYTES + 1), ready=False)
    assert bench.events() == (1, 0, 0)
    # Where a frame can run out of words before its limit, that is overflow.
    if largest - 8 > 0:
        small = rng.randbytes(60)
        queued.append(small)
        await bench.send(small, ready=False)
        await bench.send(rng.randbytes(payload_for_words(largest - 7)), ready=False)
        assert bench.events() == (2, 0, 1)
    await bench.drain(MEMORY_WORDS + 32)
    assert bench.received == queued


@cocotb.test()
async def start_recovery_after_early_drop(dut: Any) -> None:
    """Admit a legal /S/ on lane 0 or 4 against the words of the frame it drops."""
    bench = ReceiveBench(dut)
    rng = random.Random(0x5EC0)
    largest = storage_words(MAX_FRAME_BYTES)
    for case in ("control", "no_space", "restart", "partial"):
        await bench.reset()
        queued: list[bytes] = []
        while MEMORY_WORDS - largest * len(queued) > largest:
            queued.append(rng.randbytes(MAX_FRAME_BYTES))
        for packet in queued:
            await bench.send(packet, ready=False)
        free = MEMORY_WORDS - largest * len(queued)
        # An unterminated frame reserves every free word ("partial": all but
        # one, which the next word's lane 0 takes before an /E/ on lane 2).
        claimed = free - 1 if case == "partial" else free
        symbols = [(0xFB, 1)] + [(0x55, 0)] * 6 + [(0xD5, 0)]
        symbols += [(byte, 0) for byte in rng.randbytes(8 * claimed)]
        if case == "control":
            symbols += [(0xFE, 1), IDLE, IDLE, IDLE]
        elif case == "no_space":
            # Lane 0 needs a new word and none is free: an overflow drop,
            # unless that byte is also past the limit.
            symbols += [(byte, 0) for byte in rng.randbytes(3)] + [IDLE]
        elif case == "partial":
            symbols += [(byte, 0) for byte in rng.randbytes(2)] + [(0xFE, 1), IDLE]
        # The replacement needs every word the dropped frame held, and starts on
        # lane 4 of the dropping word, or restarts on lane 0 of the next.
        replacement = rng.randbytes(payload_for_words(free))
        symbols += frame_symbols(replacement)
        await bench.present(pack_symbols(symbols), ready=False)
        await bench.step(ready=False)
        await bench.step(ready=False)
        overflow = case == "no_space" and 8 * free < MAX_FRAME_BYTES + 4
        assert bench.events() == (1, 0, int(overflow)), case
        await bench.drain(MEMORY_WORDS + 32)
        assert bench.received == queued + [replacement], case


@cocotb.test()
async def start_in_terminating_word_is_ignored(dut: Any) -> None:
    """Ignore an /S/ in the word whose /T/ ends a frame; no Clause 49 block has both."""
    bench = ReceiveBench(dut)
    await bench.reset()
    rng = random.Random(0x7E5)
    expected = []
    for length in sorted({min(n, MAX_FRAME_BYTES) for n in (60, 61, 62, 63)}):
        for bad_crc in (False, True):
            first = rng.randbytes(length)
            symbols = frame_symbols(first, bad_crc=bad_crc)
            symbols += [IDLE] * (-len(symbols) % 8 - 4)
            symbols += frame_symbols(rng.randbytes(60))
            before = bench.events()
            await bench.present(pack_symbols(symbols), ready=True)
            await bench.drain(16)
            assert bench.events() == (
                before[0] + int(bad_crc),
                before[1] + int(bad_crc),
                before[2],
            )
            if not bad_crc:
                expected.append(first)
            assert bench.received == expected
    good = rng.randbytes(60)
    await bench.send(good, start_lane=4)
    await bench.drain(16)
    assert bench.received == expected + [good]


@cocotb.test(skip=RESERVATION_FREE == 0)
async def reservation_sees_output_credit_two_clocks_later(dut: Any) -> None:
    """Words freed by the output handshake reach a word reservation two clocks later."""
    bench = ReceiveBench(dut)
    rng = random.Random(0xC4ED17)
    free = RESERVATION_FREE
    # Handshake clocks relative to the word whose lane 0 needs one word more
    # than is free, and whether the frame survives. A handshake on that word's
    # clock is two clocks too late; one clock earlier is in time. The output
    # register holds one beat at the decision when the word's own clock
    # handshakes, two otherwise; free words are one, then two, before it.
    for handshakes, accepted in (
        ((), False),
        ((0,), False),
        ((-1,), True),
        ((-1, 0), True),
    ):
        await bench.reset()
        queued = [rng.randbytes(length) for length in RESERVATION_FILLS]
        for packet in queued:
            await bench.send(packet, ready=False)
        frame = rng.randbytes(payload_for_words(free + 1))
        for index, word in enumerate(wire_words(frame)):
            await bench.step(word, ready=index - (free + 1) in handshakes)
        await bench.step(ready=False)
        await bench.step(ready=False)
        assert bench.events() == ((0, 0, 0) if accepted else (1, 0, 1)), handshakes
        await bench.drain(MEMORY_WORDS + 32)
        assert bench.received == queued + ([frame] if accepted else []), handshakes


@cocotb.test(skip=DESCRIPTOR_SLOTS != 2)
async def descriptor_release_with_empty_output(dut: Any) -> None:
    """With two descriptors, starts decided while the output register is empty."""
    bench = ReceiveBench(dut)
    rng = random.Random(0xE0D7)
    # The first packet's eight beats are consumed on eight clocks; the second
    # packet's /T/ word and the third packet's /S/ word are placed around the
    # last of them. On the decision clock nothing is left to copy, so the
    # output register is empty. Refused: the consumed packet's release is
    # still in flight. Admitted: it has landed.
    for terminate_clock, start_clock, accepted in ((7, 8, False), (8, 9, True)):
        await bench.reset()
        first, second, third = (rng.randbytes(60) for _ in range(3))
        await bench.send(first, ready=False)
        second_words = wire_words(second)
        await bench.present(second_words[:-1], ready=False)
        third_words = wire_words(third)
        for clock in range(1, start_clock + 1):
            ready = clock <= 8
            if clock == terminate_clock:
                await bench.step(second_words[-1], ready=ready)
            elif clock == start_clock:
                await bench.step(third_words[0], ready=ready)
            else:
                await bench.step((0x55555555555555FB, 0x01), ready=ready, enable=False)
        await bench.present(third_words[1:], ready=False)
        await bench.step(ready=False)
        await bench.step(ready=False)
        assert bench.events() == ((0, 0, 0) if accepted else (1, 0, 1)), start_clock
        await bench.drain(64)
        assert bench.received == [first, second] + ([third] if accepted else [])


@cocotb.test()
async def final_beat_credit_one_or_two_words(dut: Any) -> None:
    """Return a consumed packet's words: its final beat credits one or two."""
    bench = ReceiveBench(dut)
    rng = random.Random(0xF1CA)
    for length in sorted({min(n, MAX_FRAME_BYTES) for n in (60, 64, 65, 68)}):
        await bench.reset()
        freed = storage_words(length)
        first = rng.randbytes(length)
        queued = [rng.randbytes(n) for n in fill_plan(MEMORY_WORDS - freed)]
        await bench.send(first, ready=False)
        for packet in queued:
            await bench.send(packet, ready=False)
        # The output register holds the first two beats, so one handshake per
        # beat consumes exactly this packet.
        for _ in range((length + 7) // 8):
            await bench.step()
        for _ in range(3):
            await bench.step(ready=False)
        # Exactly `freed` words are free: one more is an overflow, that many fit.
        if payload_for_words(freed + 1) <= MAX_FRAME_BYTES:
            await bench.send(rng.randbytes(payload_for_words(freed + 1)), ready=False)
            assert bench.events() == (1, 0, 1), length
        exact = rng.randbytes(payload_for_words(freed))
        before = bench.events()
        await bench.send(exact, ready=False)
        assert bench.events() == before, length
        await bench.drain(MEMORY_WORDS + 32)
        assert bench.received == [first] + queued + [exact], length


@cocotb.test()
async def reset_clears_pipeline_and_output(dut: Any) -> None:
    """Reset drops a decoded /T/ word, beats in the output register and credit."""
    bench = ReceiveBench(dut)
    await bench.reset()
    rng = random.Random(0x2E5E7)
    await bench.send(rng.randbytes(min(100, MAX_FRAME_BYTES)), ready=False)
    pending = wire_words(rng.randbytes(60))
    await bench.present(pending[:-1], ready=False)
    # The good frame's /T/ word is decoded, and a beat handshakes, on the last
    # clock before reset.
    await bench.step(pending[-1])
    await bench.reset()
    await bench.drain(32)
    assert bench.received == []
    assert bench.events() == (0, 0, 0)

    # Storage is whole again, without the credit that was in flight: after
    # packets leaving eight words free, a nine-word frame (where the limit
    # allows one) overflows and an eight-word frame fits.
    fills = [rng.randbytes(n) for n in fill_plan(MEMORY_WORDS - 8)]
    for packet in fills:
        await bench.send(packet, ready=False)
    if payload_for_words(9) <= MAX_FRAME_BYTES:
        await bench.send(rng.randbytes(payload_for_words(9)), ready=False)
        assert bench.events() == (1, 0, 1)
    last = rng.randbytes(60)
    before = bench.events()
    await bench.send(last, ready=False)
    assert bench.events() == before
    await bench.drain(MEMORY_WORDS + 32)
    assert bench.received == fills + [last]
