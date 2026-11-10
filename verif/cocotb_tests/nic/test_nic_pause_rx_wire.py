#!/usr/bin/env python3

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

"""Independent wire-side PAUSE validation, including frames that cannot be stored."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

from cocotb_tests.nic.test_nic_pause import OTHER, STATION, pause_frame
from net10g.test_mac_rx import frame_symbols, pack_symbols


class Bench:
    """Drive XGMII words and collect complete, validated events."""

    def __init__(self, dut: Any) -> None:
        """Bind the wire observer."""
        self.dut = dut
        self.events: list[int] = []
        self.resetting = True

    async def start(self) -> None:
        """Start the clock and reset the receiver."""
        dut = self.dut
        dut.i_rst.value = 1
        dut.i_enable.value = 0
        dut.i_xgmii_data.value = 0x0707070707070707
        dut.i_xgmii_ctrl.value = 0xFF
        dut.i_mac.value = int.from_bytes(STATION, "little")
        Clock(dut.i_clk, 6, unit="ns").start()
        cocotb.start_soon(self.observe())
        await self.reset()

    async def reset(self) -> None:
        """Discard partial input and collected events."""
        self.resetting = True
        await FallingEdge(self.dut.i_clk)
        self.dut.i_rst.value = 1
        self.dut.i_enable.value = 0
        await ClockCycles(self.dut.i_clk, 4)
        await FallingEdge(self.dut.i_clk)
        self.dut.i_rst.value = 0
        self.events.clear()
        self.resetting = False

    async def observe(self) -> None:
        """Collect events and enforce interval ownership."""
        interval, toggle = 0, 0
        while True:
            await FallingEdge(self.dut.i_clk)
            if self.resetting:
                interval, toggle = 0, 0
                continue
            event = int(self.dut.o_pause_ev.value)
            value = int(self.dut.o_pause_interval.value)
            next_toggle = int(self.dut.o_pause_tog.value)
            assert bool(next_toggle != toggle) == bool(event)
            if event:
                self.events.append(value)
            else:
                assert value == interval, "interval changed without a validated event"
            interval, toggle = value, next_toggle

    async def send(self, symbols: list[tuple[int, int]], gaps: bool = False) -> None:
        """Send encoded frame symbols with optional word-enable gaps."""
        dut = self.dut
        for index, (data, ctrl) in enumerate(pack_symbols(symbols)):
            if gaps and index % 3 == 1:
                await FallingEdge(dut.i_clk)
                dut.i_enable.value = 0
                await ClockCycles(dut.i_clk, 2)
            await FallingEdge(dut.i_clk)
            dut.i_enable.value = 1
            dut.i_xgmii_data.value = data
            dut.i_xgmii_ctrl.value = ctrl
        await FallingEdge(dut.i_clk)
        dut.i_enable.value = 0
        await ClockCycles(dut.i_clk, 4)


@cocotb.test()
async def valid_frames_cover_alignment_length_and_enable_gaps(dut: Any) -> None:
    """CRC and header extraction work for both starts and every termination lane."""
    bench = Bench(dut)
    await bench.start()
    expected = []
    for lane in (0, 4):
        for length in (*range(60, 76), 128):
            quanta = (lane * 1000 + length * 17) & 0xFFFF
            address = STATION if length & 1 else pause_frame(0)[:6]
            body = pause_frame(quanta, da=address).ljust(length, b"\xa5")
            await bench.send(frame_symbols(body, start_lane=lane), gaps=True)
            expected.append(quanta)
            assert bench.events == expected
    await bench.send(frame_symbols(pause_frame(0)))
    assert bench.events == expected + [0]


@cocotb.test()
async def invalid_frames_never_publish_a_pause(dut: Any) -> None:
    """Reject invalid framing, FCS, length, address, EtherType and opcode."""
    bench = Bench(dut)
    await bench.start()
    bodies = [
        pause_frame(42, da=OTHER),
        pause_frame(42, opcode=0x0101),
        pause_frame(42, ethertype=0x0800),
        pause_frame(42)[:59],
        pause_frame(42).ljust(129, b"\0"),
        # A wrapped count would see another complete header and a valid FCS.
        pause_frame(42) + bytes(196) + pause_frame(42),
    ]
    for lane in (0, 4):
        for body in bodies:
            await bench.send(frame_symbols(body, start_lane=lane), gaps=True)
            assert not bench.events
        await bench.send(frame_symbols(pause_frame(42), start_lane=lane, bad_crc=True))
        assert not bench.events
        preamble = frame_symbols(pause_frame(42), start_lane=lane)
        preamble[lane + 2] = (0x54, 0)
        await bench.send(preamble)
        assert not bench.events
        bad_control = frame_symbols(pause_frame(42), start_lane=lane)
        bad_control[lane + 8 + 20] = (0xFE, 1)
        await bench.send(bad_control)
        assert not bench.events
    await bench.send(frame_symbols(pause_frame(7)))
    assert bench.events == [7]


@cocotb.test()
async def reset_discards_an_incomplete_control_frame(dut: Any) -> None:
    """Discard a partial old header across reset."""
    bench = Bench(dut)
    await bench.start()
    symbols = frame_symbols(pause_frame(600))
    await bench.send(symbols[:32])
    await bench.reset()
    await bench.send(symbols[32:])
    assert not bench.events
    await bench.send(frame_symbols(pause_frame(9), start_lane=4))
    assert bench.events == [9]


@cocotb.test()
async def nested_starts_resynchronize_after_a_partial_frame(dut: Any) -> None:
    """Resynchronize at either legal start after an abandoned frame."""
    bench = Bench(dut)
    await bench.start()
    partial = frame_symbols(pause_frame(600))[:24]
    expected = []
    for lane in (0, 4):
        quanta = 70 + lane
        await bench.send(partial + frame_symbols(pause_frame(quanta), start_lane=lane))
        expected.append(quanta)
        assert bench.events == expected


@cocotb.test()
async def early_termination_suppresses_a_same_word_start(dut: Any) -> None:
    """Match MAC restart priority for an invalid start after early termination."""
    bench = Bench(dut)
    await bench.start()
    # A 60-byte body ends with /T/ on lane zero. A new /S/ on lane four
    # of that word is ignored, so only the first packet can publish.
    first = frame_symbols(pause_frame(31))[:73]
    await bench.send(first + [(7, 1)] * 3 + frame_symbols(pause_frame(32)))
    assert bench.events == [31]
    await bench.send(frame_symbols(pause_frame(33)))
    assert bench.events == [31, 33]
