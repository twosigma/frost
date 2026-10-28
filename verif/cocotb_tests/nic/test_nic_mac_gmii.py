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

"""Exercise the NIC's GMII boundary with independent Ethernet byte streams."""

from collections import deque
import zlib
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.handle import LogicObject
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer, with_timeout


def _wire_frame(payload: bytes) -> bytes:
    padded = payload.ljust(60, b"\0")
    return b"\x55" * 7 + b"\xd5" + padded + zlib.crc32(padded).to_bytes(4, "little")


class GmiiPeer:
    """Drive independent receive symbols and collect the transmitted wire bytes."""

    def __init__(self, dut: Any) -> None:
        """Bind the MAC boundary and initialize the packet queues."""
        self.dut = dut
        self.period = 1
        self.symbols: deque[int] = deque()
        self.transmitted: deque[bytes] = deque()
        self.received: deque[bytes] = deque()

    async def wire(self) -> None:
        """Sample the registered TX outputs at the PHY's active clock edge."""
        cycle = 0
        frame = bytearray()
        while True:
            await FallingEdge(self.dut.i_rx_clk)
            enabled = cycle % self.period == 0
            self.dut.i_rx_raw_valid.value = int(enabled)
            self.dut.i_rx_raw_data.value = (
                self.symbols.popleft() if enabled and self.symbols else 0
            )
            await RisingEdge(self.dut.i_rx_clk)
            if enabled:
                value = int(self.dut.o_tx_raw_data.value)
                assert not value & 0x200, "unexpected GMII transmit error"
                if value & 0x100:
                    frame.append(value & 0xFF)
                elif frame:
                    self.transmitted.append(bytes(frame))
                    frame.clear()
            cycle += 1

    async def collect(self) -> None:
        """Accept CPU-side beats with periodic backpressure."""
        cycle = 0
        frame = bytearray()
        while True:
            await FallingEdge(self.dut.i_clk)
            ready = cycle % 7 != 0
            self.dut.i_rx_ready.value = int(ready)
            await RisingEdge(self.dut.i_clk)
            if ready and int(self.dut.o_rx_valid.value):
                code = int(self.dut.o_rx_code.value)
                data = int(self.dut.o_rx_data.value).to_bytes(8, "little")
                frame.extend(data[: (code & 7) + 1])
                if code & 8:
                    self.received.append(bytes(frame))
                    frame.clear()
            cycle += 1

    def inject(self, frame: bytes, error_byte: int = -1) -> None:
        """Queue a GMII frame followed by the minimum Ethernet interpacket gap."""
        self.symbols.extend(
            byte | 0x100 | (0x200 if index == error_byte else 0)
            for index, byte in enumerate(frame)
        )
        self.symbols.extend([0] * 12)


async def _send(dut: Any, payload: bytes) -> None:
    for offset in range(0, len(payload), 8):
        word = payload[offset : offset + 8]
        while True:
            await FallingEdge(dut.i_clk)
            dut.i_tx_valid.value = 1
            dut.i_tx_data.value = int.from_bytes(word, "little")
            dut.i_tx_code.value = (
                len(word) - 1 + (8 if offset + 8 >= len(payload) else 0)
            )
            await Timer(1, unit="ns")
            ready = int(dut.o_tx_ready.value)
            await RisingEdge(dut.i_clk)
            if ready:
                break
    await FallingEdge(dut.i_clk)
    dut.i_tx_valid.value = 0


async def _take(queue: deque[bytes], clock: LogicObject) -> bytes:
    while not queue:
        await RisingEdge(clock)
    return queue.popleft()


@cocotb.test()
async def gmii_frames_and_errors(dut: Any) -> None:
    """Check each termination lane, jumbo frames, rate enables and error recovery."""
    for name, value in {
        "i_rst": 1,
        "i_soft_rst": 0,
        "i_req": 3,
        "i_gen": 0,
        "i_core_rst_dom": 3,
        "i_mac_loopback": 0,
        "i_tx_valid": 0,
        "i_tx_data": 0,
        "i_tx_code": 0,
        "i_rx_ready": 0,
        "i_rx_raw_data": 0,
        "i_rx_raw_valid": 1,
        "i_rx_signal_ok": 1,
    }.items():
        getattr(dut, name).value = value
    for name, period in (("i_clk", 6), ("i_tx_clk", 8), ("i_rx_clk", 8)):
        Clock(getattr(dut, name), period, unit="ns").start()
    await ClockCycles(dut.i_clk, 20)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    dut.i_req.value = 0
    dut.i_core_rst_dom.value = 0
    peer = GmiiPeer(dut)
    cocotb.start_soon(peer.wire())
    cocotb.start_soon(peer.collect())
    await ClockCycles(dut.i_clk, 40)

    cases = [(1, length) for length in (14, *range(60, 68), 1514, 9014)]
    cases.extend([(10, 61), (100, 67)])
    for period, length in cases:
        peer.period = period
        payload = bytes((index * 19 + length) & 255 for index in range(length))
        peer.inject(_wire_frame(payload))
        await with_timeout(_send(dut, payload), 10, "ms")
        transmitted = await with_timeout(_take(peer.transmitted, dut.i_clk), 10, "ms")
        received = await with_timeout(_take(peer.received, dut.i_clk), 10, "ms")
        assert transmitted == _wire_frame(payload), (period, length, transmitted[:16])
        assert received == payload.ljust(60, b"\0"), (period, length)

    peer.period = 1
    payload = bytes(range(80))
    bad_fcs = bytearray(_wire_frame(payload))
    bad_fcs[-1] ^= 1
    peer.inject(bytes(bad_fcs))
    peer.inject(_wire_frame(payload), error_byte=21)
    peer.inject(b"\x55\x54\xd5" + _wire_frame(payload)[8:])
    peer.inject(_wire_frame(payload))
    assert await with_timeout(_take(peer.received, dut.i_clk), 1, "ms") == payload
    await ClockCycles(dut.i_clk, 100)
    assert not peer.received, "an invalid frame reached the NIC"
    totals = int(dut.o_totals.value)
    assert (totals >> 128) & ((1 << 64) - 1), "bad FCS was not counted"
    assert (totals >> 64) & ((1 << 64) - 1), "GMII receive error was not counted"
