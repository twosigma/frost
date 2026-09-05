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

"""Independent wire-level checks for the isolated Ethernet transmitter.

No RX RTL is involved: the monitor checks XGMII framing and compares each FCS
with Python's zlib implementation. Enabled clocks are the XGMII word cadence.
"""

import os
import random
import zlib
from typing import Any

import cocotb
from cocotb.triggers import Timer

MAX_FRAME_BYTES = int(os.environ.get("NET10G_MAX_FRAME_BYTES", "9216"))
IDLE_WORD = 0x0707070707070707


def wire_frame(payload: bytes) -> bytes:
    """Frame bytes following SFD and before /T/, including padding and FCS."""
    padded = payload + bytes(max(0, 60 - len(payload)))
    return padded + zlib.crc32(padded).to_bytes(4, "little")


class TxBench:
    """Drive AXIS while independently checking every emitted XGMII word."""

    def __init__(self, dut: Any, seed: int = 0x10A0) -> None:
        """Initialize deterministic random stimulus and wire monitor state."""
        self.dut = dut
        self.rng = random.Random(seed)
        self.frames: list[bytes] = []
        self.partial: bytearray | None = None
        self.idle_bytes = 100
        self.drops = 0
        self.stalled = 0
        self.disabled = 0
        self.held_output: tuple[int, int] | None = None
        self.ticks = 0

    def observe(self, data: int, ctrl: int) -> None:
        """Validate framing and collect payload, padding and FCS bytes."""
        lanes = data.to_bytes(8, "little")
        if ctrl & 1 and lanes[0] == 0xFB:
            assert self.partial is None, "nested start"
            assert self.idle_bytes >= 12, f"IFG too short: {self.idle_bytes}"
            assert ctrl == 1
            assert lanes[1:] == b"\x55" * 6 + b"\xd5"
            self.partial = bytearray()
            return
        for lane, byte in enumerate(lanes):
            if ctrl & (1 << lane):
                if byte == 0xFD:
                    assert self.partial is not None, "termination without start"
                    self.frames.append(bytes(self.partial))
                    self.partial = None
                    self.idle_bytes = 0
                else:
                    assert byte == 0x07, f"unexpected control {byte:#x}"
                    assert self.partial is None, "wire paused inside frame"
                    self.idle_bytes += 1
            else:
                assert self.partial is not None, "data outside frame"
                self.partial.append(byte)

    async def cycle(
        self,
        beat: tuple[int, int, int, int] | None = None,
        *,
        enable: bool | None = None,
        reset: bool = False,
    ) -> bool:
        """Advance one physical clock and return whether AXIS transferred."""
        dut = self.dut
        if enable is None:
            enable = self.rng.randrange(5) != 0
        dut.i_clk.value = 0
        dut.i_rst.value = int(reset)
        dut.i_enable.value = int(enable)
        dut.s_axis_tvalid.value = int(beat is not None)
        data, keep, last, user = beat if beat is not None else (0, 0, 0, 0)
        dut.s_axis_tdata.value = data
        dut.s_axis_tkeep.value = keep
        dut.s_axis_tlast.value = last
        dut.s_axis_tuser.value = user
        await Timer(5, unit="ns")
        ready = int(dut.s_axis_tready.value)
        if not enable or reset:
            assert not ready, "AXIS handshake advertised while disabled/reset"
        accepted = beat is not None and bool(ready)
        self.stalled += int(beat is not None and enable and not ready and not reset)
        dut.i_clk.value = 1
        await Timer(5, unit="ns")
        output = (int(dut.o_xgmii_data.value), int(dut.o_xgmii_ctrl.value))
        drop = int(dut.o_drop.value)
        if reset:
            assert output == (IDLE_WORD, 0xFF)
            assert not drop
            self.partial = None
            self.idle_bytes = 100
        elif enable:
            self.observe(*output)
            self.drops += drop
        else:
            self.disabled += 1
            assert output == self.held_output, "XGMII changed on disabled clock"
            assert not drop, "drop event lasted more than one physical clock"
        self.held_output = output
        self.ticks += 1
        return accepted

    async def reset(self) -> None:
        """Reset both sides of the transmitter."""
        for _ in range(3):
            await self.cycle(reset=True, enable=True)
        await self.cycle(enable=True)

    async def beat(
        self,
        data: int,
        keep: int = 0xFF,
        last: bool = False,
        user: bool = False,
        *,
        stall: bool = True,
    ) -> None:
        """Hold a beat stable until an enabled AXIS handshake."""
        if stall:
            for _ in range(self.rng.randrange(3)):
                await self.cycle()
        packed = (data, keep, int(last), int(user))
        for _ in range(10000):
            if await self.cycle(packed):
                return
        raise AssertionError("AXIS failed to accept a beat")

    async def packet(
        self, data: bytes, *, user_beat: int | None = None, stall: bool = True
    ) -> None:
        """Send a packet, optionally marking one beat with the abort flag."""
        for index, offset in enumerate(range(0, len(data), 8)):
            chunk = data[offset : offset + 8]
            await self.beat(
                int.from_bytes(chunk, "little"),
                (1 << len(chunk)) - 1,
                offset + len(chunk) == len(data),
                index == user_beat,
                stall=stall,
            )

    async def drain(self, frames: int) -> None:
        """Wait for expected frames and check that no extra packet follows."""
        for _ in range(4 * MAX_FRAME_BYTES + 100):
            if len(self.frames) >= frames and self.partial is None:
                break
            await self.cycle()
        else:
            raise AssertionError(f"only {len(self.frames)} of {frames} frames arrived")
        for _ in range(50):
            await self.cycle()
        assert len(self.frames) == frames
        assert self.partial is None


@cocotb.test()
async def padding_crc_stalls_and_lane_endings(dut: Any) -> None:
    """Check payload preservation, padding, independent FCS and clock gating."""
    bench = TxBench(dut)
    await bench.reset()
    sizes = [1, 7, 8, 9, *range(55, 81), 127, 1518, 1522, 9014, MAX_FRAME_BYTES]
    sizes = [size for size in sizes if size <= MAX_FRAME_BYTES]
    sizes += [bench.rng.randint(1, min(2048, MAX_FRAME_BYTES)) for _ in range(50)]
    expected = []
    for size in sizes:
        payload = bench.rng.randbytes(size)
        expected.append(wire_frame(payload))
        await bench.packet(payload)
    await bench.drain(len(expected))
    assert bench.frames == expected
    assert bench.drops == 0
    assert bench.disabled > 100


@cocotb.test()
async def malformed_abort_oversize_and_recovery(dut: Any) -> None:
    """Require invalid packets to disappear completely and recover cleanly."""
    bench = TxBench(dut, 0xBAD)
    await bench.reset()
    expected = []
    rejected = 0
    for keep in [0, 0x55, 0xFE, 0x80]:
        await bench.beat(0xDEADBEEF, keep, True)
        rejected += 1
    for bad_keep in [0, 0x0F, 0x7F]:
        await bench.beat(0x0102030405060708, bad_keep)
        await bench.beat(0, 0xFF)
        await bench.beat(0, 0x01, True)
        rejected += 1
    for aborted_beat in [0, 1, 7]:
        await bench.packet(bytes(range(64)), user_beat=aborted_beat)
        rejected += 1
    await bench.packet(bench.rng.randbytes(MAX_FRAME_BYTES + 65))
    rejected += 1
    for size in [1, 60, 61, min(1000, MAX_FRAME_BYTES)]:
        payload = bench.rng.randbytes(size)
        await bench.packet(payload)
        expected.append(wire_frame(payload))
    await bench.drain(len(expected))
    assert bench.frames == expected, "rejected packet leaked onto wire"
    assert bench.drops == rejected


@cocotb.test()
async def back_to_back_packets_exercise_both_buffers(dut: Any) -> None:
    """Saturate ingress while checking queue order and wire continuity."""
    bench = TxBench(dut, 0xB0FF)
    await bench.reset()
    expected = []
    # Small packets fill both buffers faster than preamble/padding/FCS/IFG drain
    # them, forcing genuine backpressure even though the wire never pauses.
    for index in range(50):
        payload = bytes([index]) * 8
        expected.append(wire_frame(payload))
        await bench.packet(payload, stall=False)
    await bench.drain(len(expected))
    assert bench.frames == expected
    assert bench.stalled > 100
    assert bench.drops == 0


@cocotb.test()
async def reset_discards_partial_queued_and_transmitting_frames(
    dut: Any,
) -> None:
    """Reset ingress and transmission state without leaking stale packets."""
    bench = TxBench(dut, 0xAE5E7)
    await bench.reset()
    # Reset with an unfinished AXIS packet.
    await bench.beat(0x1234567890ABCDEF)
    await bench.cycle(reset=True, enable=False)
    for _ in range(30):
        await bench.cycle()
    assert not bench.frames
    # Reset while wire output is active and the other input buffer is occupied.
    await bench.packet(bytes(range(200)), stall=False)
    for _ in range(20):
        if bench.partial is not None:
            break
        await bench.cycle(enable=True)
    assert bench.partial is not None
    await bench.beat(0xFEDCBA9876543210, last=True)
    await bench.cycle(reset=True, enable=False)
    for _ in range(100):
        await bench.cycle()
    assert not bench.frames
    expected = bytes(range(101))
    await bench.packet(expected)
    await bench.drain(1)
    assert bench.frames == [wire_frame(expected)]
    assert bench.drops == 0
