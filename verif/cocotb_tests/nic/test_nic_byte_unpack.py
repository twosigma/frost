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

"""Unit tests for nic_byte_unpack (hw/rtl/peripherals/nic/nic_byte_unpack.sv).

The mirror of the packer's invariant: the LEN bytes at offset OFF of the
lines fed in order come out as contiguous 8-byte beats, the last carrying
the remaining 1..8 bytes with the last flag, whatever the stalls on the
beat output or the line input. Swept over every offset, lengths 1..100 and
long ones, with a stalled final beat and lines arriving late.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

LINE = 32


async def _setup(dut: Any) -> None:
    Clock(dut.i_clk, 10, unit="ns").start()
    for sig in (
        dut.i_flush,
        dut.i_start,
        dut.i_offset,
        dut.i_len,
        dut.i_line_valid,
        dut.i_line_data,
        dut.i_beat_ready,
    ):
        sig.value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await FallingEdge(dut.i_clk)


async def _feed_lines(
    dut: Any, lines: list[int], rng: random.Random, gap: float
) -> None:
    for line in lines:
        while rng.random() < gap:
            await FallingEdge(dut.i_clk)
        dut.i_line_data.value = line
        dut.i_line_valid.value = 1
        for _ in range(4000):
            await RisingEdge(dut.i_clk)
            if int(dut.o_line_ready.value) == 1:
                break
        else:
            raise AssertionError("line never accepted")
        await FallingEdge(dut.i_clk)
        dut.i_line_valid.value = 0


async def _run(
    dut: Any,
    offset: int,
    length: int,
    rng: random.Random,
    beat_gap: float,
    line_gap: float,
) -> None:
    payload = bytes(rng.getrandbits(8) for _ in range(length))
    # Lines covering [offset, offset + length), bytes outside the frame random.
    span = offset + length
    n_lines = (span + LINE - 1) // LINE
    mem = bytearray(rng.getrandbits(8) for _ in range(n_lines * LINE))
    mem[offset : offset + length] = payload
    lines = [
        int.from_bytes(mem[i * LINE : (i + 1) * LINE], "little") for i in range(n_lines)
    ]
    dut.i_start.value = 1
    dut.i_offset.value = offset
    dut.i_len.value = length
    await FallingEdge(dut.i_clk)
    dut.i_start.value = 0
    feeder = cocotb.start_soon(_feed_lines(dut, lines, rng, line_gap))
    got = bytearray()
    beats = 0
    last_seen = False
    for _ in range(20000):
        await FallingEdge(dut.i_clk)
        if int(dut.o_beat_valid.value) == 1 and rng.random() >= beat_gap:
            n = int(dut.o_beat_bytes.value)
            data = int(dut.o_beat_data.value).to_bytes(8, "little")
            last = int(dut.o_beat_last.value) == 1
            assert 1 <= n <= 8
            assert last or n == 8, "a nonfinal beat must carry 8 bytes"
            got += data[:n]
            beats += 1
            dut.i_beat_ready.value = 1
            await RisingEdge(dut.i_clk)
            await FallingEdge(dut.i_clk)
            dut.i_beat_ready.value = 0
            if last:
                last_seen = True
                break
        else:
            dut.i_beat_ready.value = 0
    await feeder
    assert last_seen, f"no last beat (offset {offset}, length {length})"
    assert bytes(got) == payload, f"payload mismatch at offset {offset} length {length}"
    assert beats == (length + 7) // 8
    for _ in range(3):
        await FallingEdge(dut.i_clk)
    assert int(dut.o_beat_valid.value) == 0 and int(dut.o_busy.value) == 0


@cocotb.test()
async def test_every_offset_short_lengths(dut: Any) -> None:
    """Every offset with lengths 1..100."""
    await _setup(dut)
    rng = random.Random(5)
    for offset in range(32):
        for length in list(range(1, 20)) + [31, 32, 33, 40, 63, 64, 65, 100]:
            await _run(dut, offset, length, rng, beat_gap=0.1, line_gap=0.1)


@cocotb.test()
async def test_long_frames_with_stalls(dut: Any) -> None:
    """Long frames with a stalled consumer and late lines."""
    await _setup(dut)
    rng = random.Random(6)
    for offset, length in [(2, 1518), (31, 1500), (17, 9216), (0, 4096), (30, 60)]:
        await _run(dut, offset, length, rng, beat_gap=0.6, line_gap=0.5)
