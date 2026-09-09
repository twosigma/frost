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

"""Unit tests for cdc_gray_count (hw/rtl/lib/cdc/cdc_gray_count.sv).

Events pulse in a 161 MHz source domain, the total is read in a 300 MHz
destination domain. Checked: bursts of consecutive events, sparse events,
more than 2^WIDTH events (the source counter wraps, the total does not),
a source reset with the rebase held (no invented events, the total keeps
its value), and a source reset without rebase (the documented failure: the
total jumps by the wrap), so the rebase contract is shown to matter.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

SRC_PERIOD_PS = 6206
DST_PERIOD_PS = 3334


async def _setup(dut: Any) -> None:
    Clock(dut.i_src_clk, SRC_PERIOD_PS, unit="ps").start()
    Clock(dut.i_dst_clk, DST_PERIOD_PS, unit="ps").start()
    dut.i_src_event.value = 0
    dut.i_dst_rebase.value = 0
    dut.i_src_rst.value = 1
    dut.i_dst_rst.value = 1
    for _ in range(5):
        await RisingEdge(dut.i_src_clk)
    await FallingEdge(dut.i_src_clk)
    dut.i_src_rst.value = 0
    await FallingEdge(dut.i_dst_clk)
    dut.i_dst_rst.value = 0
    for _ in range(6):
        await RisingEdge(dut.i_dst_clk)


async def _events(dut: Any, pattern: list[int]) -> None:
    """Drive one event per source cycle where pattern is 1."""
    for p in pattern:
        await FallingEdge(dut.i_src_clk)
        dut.i_src_event.value = p
    await FallingEdge(dut.i_src_clk)
    dut.i_src_event.value = 0


async def _settle(dut: Any, cycles: int = 12) -> int:
    for _ in range(cycles):
        await RisingEdge(dut.i_dst_clk)
    return int(dut.o_dst_total.value)


@cocotb.test()
async def test_bursts_and_gaps(dut: Any) -> None:
    """Consecutive events and sparse events all count exactly once."""
    await _setup(dut)
    rng = random.Random(11)
    pattern = [1] * 10 + [0] * 5 + [1, 0] * 20 + [rng.randrange(2) for _ in range(200)]
    await _events(dut, pattern)
    assert await _settle(dut) == sum(pattern)


@cocotb.test()
async def test_wrap_beyond_width(dut: Any) -> None:
    """More than 2^WIDTH events: the source wraps, the total keeps counting."""
    await _setup(dut)
    width = int(dut.WIDTH.value)
    n = (1 << width) * 3 + 17
    await _events(dut, [1] * n)
    assert await _settle(dut) == n


@cocotb.test()
async def test_source_reset_with_rebase_keeps_total(dut: Any) -> None:
    """A source reset under a held rebase adds nothing; counting resumes after."""
    await _setup(dut)
    await _events(dut, [1] * 100)
    before = await _settle(dut)
    assert before == 100
    # Rebase first (the reset handshake raises it before the source resets),
    # then reset the source, then release both in that order.
    await FallingEdge(dut.i_dst_clk)
    dut.i_dst_rebase.value = 1
    for _ in range(4):
        await RisingEdge(dut.i_dst_clk)
    await FallingEdge(dut.i_src_clk)
    dut.i_src_rst.value = 1
    for _ in range(8):
        await RisingEdge(dut.i_src_clk)
    await FallingEdge(dut.i_src_clk)
    dut.i_src_rst.value = 0
    for _ in range(6):
        await RisingEdge(dut.i_dst_clk)
    await FallingEdge(dut.i_dst_clk)
    dut.i_dst_rebase.value = 0
    assert await _settle(dut) == before, "the rebase invented or lost events"
    await _events(dut, [1] * 33)
    assert await _settle(dut) == before + 33


@cocotb.test()
async def test_source_reset_without_rebase_is_wrong(dut: Any) -> None:
    """Without the rebase a source reset reads as a wrap: the contract's reason."""
    await _setup(dut)
    await _events(dut, [1] * 100)
    before = await _settle(dut)
    await FallingEdge(dut.i_src_clk)
    dut.i_src_rst.value = 1
    for _ in range(8):
        await RisingEdge(dut.i_src_clk)
    await FallingEdge(dut.i_src_clk)
    dut.i_src_rst.value = 0
    after = await _settle(dut)
    width = int(dut.WIDTH.value)
    assert after == before + (
        (-100) % (1 << width)
    ), f"expected the documented wrap error, got {after - before}"
