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

"""Unit tests for dc_fifo (hw/rtl/lib/fifo/dc_fifo.sv), read side.

The bench builds the FIFO like frost.sv's UART FIFOs, scaled down, with the
read clock a quarter of the write clock and its rising edges on write-clock
edges. The reader behaves like uart_tx: when idle it takes a byte as soon as
one is presented, then stays busy for a byte time.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge


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
