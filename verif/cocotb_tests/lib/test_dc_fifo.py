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

"""Unit tests for dc_fifo (hw/rtl/lib/fifo/dc_fifo.sv) as the UART transmit FIFO.

The bench builds the FIFO like frost.sv's TX FIFO, scaled down (DEPTH 128,
ALMOST_FULL_MARGIN 64), with the read clock a quarter of the write clock and
its rising edges on write-clock edges. The reader behaves like uart_tx: when
idle it takes a byte as soon as one is presented, then stays busy for a byte
time. The writer behaves like a 16550 driver: it samples the TX status (not
almost full) and then writes a burst without checking again.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

DEPTH = 128
MARGIN = 64
BURST = 16


async def _divided_clock(dut: Any) -> None:
    """o_clk at a quarter of i_clk, its rising edges on i_clk rising edges."""
    counter = 0
    dut.o_clk.value = 0
    while True:
        await RisingEdge(dut.i_clk)
        counter += 1
        if counter == 2:
            counter = 0
            dut.o_clk.value = 0 if int(dut.o_clk.value) else 1


async def _setup(dut: Any) -> None:
    Clock(dut.i_clk, 10, unit="ns").start()
    cocotb.start_soon(_divided_clock(dut))
    dut.i_rst.value = 1
    dut.o_rst.value = 1
    dut.i_valid.value = 0
    dut.i_data.value = 0
    dut.i_ready.value = 0
    for _ in range(40):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    dut.o_rst.value = 0
    for _ in range(40):
        await RisingEdge(dut.i_clk)


class TxLikeReader:
    """Takes a byte in its first idle cycle, then stays busy ``byte_cycles`` o_clk cycles."""

    def __init__(self, dut: Any, byte_cycles: int) -> None:
        """Start the reader on ``dut``'s read port."""
        self.dut = dut
        self.byte_cycles = byte_cycles
        self.out: list[int] = []
        self._task = cocotb.start_soon(self._run())

    async def _run(self) -> None:
        dut = self.dut
        busy = 0
        while True:
            await FallingEdge(dut.o_clk)
            if busy:
                busy -= 1
                dut.i_ready.value = 0
                continue
            dut.i_ready.value = 1
            if int(dut.o_valid.value):
                self.out.append(int(dut.o_data.value))
                busy = self.byte_cycles

    def stop(self) -> None:
        """Stop taking bytes."""
        self._task.cancel()


async def _write(dut: Any, value: int) -> None:
    """Present one write for one i_clk cycle; it must find room."""
    await FallingEdge(dut.i_clk)
    dut.i_data.value = value
    dut.i_valid.value = 1
    assert int(dut.o_ready.value) == 1, f"write {value:#x} refused (no room)"
    await FallingEdge(dut.i_clk)
    dut.i_valid.value = 0


@cocotb.test()
async def test_back_to_back_writes_into_an_idle_reader(dut: Any) -> None:
    """Bytes written on consecutive cycles come out once each, in order.

    The reader takes the first byte in the cycle after it appears, which is
    also the cycle after the FIFO loaded it.
    """
    await _setup(dut)
    reader = TxLikeReader(dut, byte_cycles=40)
    sent = [0x41, 0x42, 0x43, 0x44, 0x45]
    await FallingEdge(dut.i_clk)
    for b in sent:
        dut.i_data.value = b
        dut.i_valid.value = 1
        assert int(dut.o_ready.value) == 1
        await FallingEdge(dut.i_clk)
    dut.i_valid.value = 0
    for _ in range(4 * 45 * len(sent) + 100):
        await RisingEdge(dut.i_clk)
    reader.stop()
    assert reader.out == sent, f"sent {sent} got {reader.out}"


@cocotb.test()
async def test_status_levels_while_filling(dut: Any) -> None:
    """o_ready, o_almost_full and o_empty follow the occupancy as the FIFO fills.

    With the reader stalled, one entry waits in the output register and the
    RAM takes DEPTH - 1 more. o_almost_full rises once fewer than MARGIN more
    writes fit, o_ready falls when none fits, and o_empty is set only when
    every entry has left the RAM.
    """
    await _setup(dut)
    assert int(dut.o_empty.value) == 1 and int(dut.o_ready.value) == 1
    assert int(dut.o_almost_full.value) == 0
    dut.i_ready.value = 0
    pushed = 0
    while int(dut.o_ready.value) == 1:
        await _write(dut, pushed & 0xFF)
        pushed += 1
        assert int(dut.o_empty.value) == 0, "o_empty set with an entry just written"
        for _ in range(16):  # let the pointers cross both ways
            await RisingEdge(dut.i_clk)
        await FallingEdge(dut.i_clk)
        in_ram = pushed - 1  # the first entry sits in the output register
        fit = DEPTH - 1 - in_ram  # further writes the RAM takes
        assert int(dut.o_almost_full.value) == int(fit < MARGIN), (
            f"{in_ram} in the RAM: almost_full {int(dut.o_almost_full.value)}"
        )
        assert int(dut.o_ready.value) == int(fit > 0), (
            f"{in_ram} in the RAM: ready {int(dut.o_ready.value)}"
        )
        assert int(dut.o_empty.value) == int(in_ram == 0)
        assert pushed <= DEPTH, "the FIFO accepted more than it holds"
    assert pushed == DEPTH, f"the FIFO took {pushed} entries, expected {DEPTH}"
    got = []
    reader = TxLikeReader(dut, byte_cycles=1)
    for _ in range(40 * DEPTH):
        await RisingEdge(dut.i_clk)
        if len(reader.out) == pushed:
            break
    got = reader.out
    reader.stop()
    assert got == [i & 0xFF for i in range(pushed)]
    for _ in range(16):
        await RisingEdge(dut.i_clk)
    assert int(dut.o_empty.value) == 1 and int(dut.o_almost_full.value) == 0


@cocotb.test()
async def test_bursts_at_the_warning_level_lose_nothing(dut: Any) -> None:
    """16-byte bursts written whenever the status allows never find the FIFO full.

    The writer samples o_almost_full once per burst and writes the burst on
    consecutive cycles; a slow reader keeps the FIFO at its warning level, and
    the pointers wrap several times. Every byte comes out once, in order.
    """
    await _setup(dut)
    reader = TxLikeReader(dut, byte_cycles=6)
    rng = random.Random(7)
    sent: list[int] = []
    warning_seen = 0
    while len(sent) < 6 * DEPTH:
        await FallingEdge(dut.i_clk)
        if int(dut.o_almost_full.value):
            warning_seen += 1
            continue
        for _ in range(BURST):
            b = rng.getrandbits(8)
            dut.i_data.value = b
            dut.i_valid.value = 1
            assert int(dut.o_ready.value) == 1, (
                f"a burst byte was refused after {len(sent)} bytes"
            )
            sent.append(b)
            await FallingEdge(dut.i_clk)
        dut.i_valid.value = 0
        # A few cycles before the next status read, as a store and a load take.
        for _ in range(rng.randrange(1, 6)):
            await FallingEdge(dut.i_clk)
    assert warning_seen > 0, "the writer never reached the warning level"
    for _ in range(40 * 8 * DEPTH):
        await RisingEdge(dut.i_clk)
        if len(reader.out) == len(sent):
            break
    reader.stop()
    assert reader.out == sent, (
        f"{len(sent)} sent, {len(reader.out)} received; first difference at "
        f"{next((i for i, (a, b) in enumerate(zip(sent, reader.out)) if a != b), None)}"
    )
