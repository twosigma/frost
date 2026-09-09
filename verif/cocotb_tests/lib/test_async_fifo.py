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

"""Unit tests for async_fifo (hw/rtl/lib/fifo/async_fifo.sv).

Two free-running clocks of arbitrary ratio and phase; a writer with random
valid gaps and a reader with random ready gaps; every word pushed must come
out once, in order, with no extra word. Checked: fast-to-slow, slow-to-fast,
equal periods with a phase offset, incommensurate periods, a continuous
writer against a stalled reader (full, then ready margin), a reader that
outruns the writer (empty, output stable while stalled), and a reset of
both sides mid-stream (nothing from before the reset reappears; the stream
restarts empty).
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

DATA_MASK = (1 << 68) - 1
TIMEOUT_CYCLES = 20_000


async def _reset_both(dut: Any, cycles: int = 6) -> None:
    dut.i_rst.value = 1
    dut.o_rst.value = 1
    dut.i_valid.value = 0
    dut.i_data.value = 0
    dut.i_ready.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.i_clk)
    for _ in range(cycles):
        await RisingEdge(dut.o_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await FallingEdge(dut.o_clk)
    dut.o_rst.value = 0
    # Let the pointer synchronizers settle before traffic.
    for _ in range(4):
        await RisingEdge(dut.i_clk)
        await RisingEdge(dut.o_clk)


def _start_clocks(
    dut: Any, wr_period_ps: int, rd_period_ps: int, rd_phase_ps: int = 0
) -> None:
    Clock(dut.i_clk, wr_period_ps, unit="ps").start()
    cocotb.start_soon(_start_delayed(dut, rd_period_ps, rd_phase_ps))


async def _start_delayed(dut: Any, period_ps: int, phase_ps: int) -> None:
    if phase_ps:
        await Timer(phase_ps, unit="ps")
    Clock(dut.o_clk, period_ps, unit="ps").start()


async def _writer(
    dut: Any, words: list[int], gap_prob: float, rng: random.Random
) -> None:
    """Push every word, honouring ready, with random idle cycles."""
    for w in words:
        while rng.random() < gap_prob:
            await FallingEdge(dut.i_clk)
        dut.i_data.value = w
        dut.i_valid.value = 1
        for _ in range(TIMEOUT_CYCLES):
            await RisingEdge(dut.i_clk)
            if int(dut.o_ready.value) == 1:
                break
        else:
            raise AssertionError("writer: never ready")
        await FallingEdge(dut.i_clk)
        dut.i_valid.value = 0


async def _reader(
    dut: Any, expected: list[int], gap_prob: float, rng: random.Random, stop: list[bool]
) -> list[int]:
    """Pop with random ready gaps; check order; the output must hold while stalled."""
    got: list[int] = []
    held: int | None = None
    while len(got) < len(expected) and not stop[0]:
        await FallingEdge(dut.o_clk)
        if int(dut.o_valid.value) == 1:
            data = int(dut.o_data.value)
            if held is not None:
                assert data == held, "output changed while stalled"
            if rng.random() < gap_prob:
                dut.i_ready.value = 0
                held = data
                continue
            dut.i_ready.value = 1
            await RisingEdge(dut.o_clk)
            got.append(data)
            held = None
            assert (
                data == expected[len(got) - 1]
            ), f"word {len(got) - 1}: got {data:#x} expected {expected[len(got) - 1]:#x}"
            await Timer(1, unit="ps")
            dut.i_ready.value = 0
        else:
            dut.i_ready.value = 1
    dut.i_ready.value = 0
    return got


async def _stream(dut: Any, n: int, wr_gap: float, rd_gap: float, seed: int) -> None:
    rng = random.Random(seed)
    words = [rng.getrandbits(68) & DATA_MASK for _ in range(n)]
    stop = [False]
    reader = cocotb.start_soon(_reader(dut, words, rd_gap, rng, stop))
    await _writer(dut, words, wr_gap, rng)
    got = await reader
    assert got == words, "stream mismatch"
    # Nothing may follow.
    for _ in range(40):
        await FallingEdge(dut.o_clk)
        assert int(dut.o_valid.value) == 0, "extra word after the stream"


@cocotb.test()
async def test_fast_writer_slow_reader(dut: Any) -> None:
    """300 MHz writer into a 161 MHz reader, both with gaps."""
    _start_clocks(dut, 3334, 6206, 1500)
    await _reset_both(dut)
    await _stream(dut, 600, 0.3, 0.3, 1)


@cocotb.test()
async def test_slow_writer_fast_reader(dut: Any) -> None:
    """161 MHz writer into a 300 MHz reader."""
    _start_clocks(dut, 6206, 3334, 700)
    await _reset_both(dut)
    await _stream(dut, 600, 0.2, 0.5, 2)


@cocotb.test()
async def test_equal_periods_with_phase(dut: Any) -> None:
    """Same nominal period, offset phase."""
    _start_clocks(dut, 5000, 5000, 1900)
    await _reset_both(dut)
    await _stream(dut, 400, 0.1, 0.1, 3)


@cocotb.test()
async def test_incommensurate_periods(dut: Any) -> None:
    """Periods with no common multiple in the run, drifting phase."""
    _start_clocks(dut, 3702, 6202, 0)
    await _reset_both(dut)
    await _stream(dut, 800, 0.05, 0.6, 4)


@cocotb.test()
async def test_full_then_drain(dut: Any) -> None:
    """A continuous writer against a stalled reader fills to the margin, then drains."""
    _start_clocks(dut, 3334, 6206, 0)
    await _reset_both(dut)
    depth = int(dut.DEPTH.value)
    margin = int(dut.READY_MARGIN.value)
    rng = random.Random(5)
    words = [rng.getrandbits(68) for _ in range(depth + 40)]
    dut.i_ready.value = 0
    pushed = 0
    dut.i_valid.value = 1
    dut.i_data.value = words[0]
    # Push until ready drops for good.
    for _ in range(4 * depth):
        await RisingEdge(dut.i_clk)
        if int(dut.o_ready.value) == 1:
            pushed += 1
            await Timer(1, unit="ps")
            dut.i_data.value = words[pushed] if pushed < len(words) else 0
    dut.i_valid.value = 0
    # The read side's two-entry skid drains two words out of the RAM even
    # with the consumer stalled, so the writer gets those two on top of the
    # RAM's capacity below the margin.
    expected = depth - margin + 2
    assert pushed == expected, f"stalled writer pushed {pushed}, expected {expected}"
    # Drain in order.
    got: list[int] = []
    dut.i_ready.value = 1
    for _ in range(4 * depth):
        await FallingEdge(dut.o_clk)
        if int(dut.o_valid.value) == 1:
            got.append(int(dut.o_data.value))
            await RisingEdge(dut.o_clk)
        else:
            await RisingEdge(dut.o_clk)
        if len(got) == pushed:
            break
    dut.i_ready.value = 0
    assert got == words[:pushed], "drain mismatch"


@cocotb.test()
async def test_reader_outruns_writer(dut: Any) -> None:
    """Each word is presented exactly once with a reader always ready."""
    _start_clocks(dut, 6206, 3334, 0)
    await _reset_both(dut)
    await _stream(dut, 300, 0.7, 0.0, 6)


@cocotb.test()
async def test_reset_both_sides_mid_stream(dut: Any) -> None:
    """After a reset of both sides nothing from before reappears."""
    _start_clocks(dut, 3334, 6206, 0)
    await _reset_both(dut)
    rng = random.Random(7)
    words = [0xA00 + i for i in range(50)]
    # Push some, pop a few, leave the rest inside, then reset both.
    dut.i_ready.value = 0
    for w in words[:20]:
        dut.i_data.value = w
        dut.i_valid.value = 1
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ps")
    dut.i_valid.value = 0
    dut.i_ready.value = 1
    popped = 0
    for _ in range(12):
        await FallingEdge(dut.o_clk)
        if int(dut.o_valid.value) == 1:
            popped += 1
    dut.i_ready.value = 0
    assert 0 < popped < 20
    await _reset_both(dut)
    for _ in range(30):
        await FallingEdge(dut.o_clk)
        assert int(dut.o_valid.value) == 0, "a word from before the reset reappeared"
    await _stream(dut, 100, 0.2, 0.2, rng.getrandbits(16))
