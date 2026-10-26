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

"""Held snapshots under unrelated clocks, stalls, and overlapping resets."""

import random
from collections import deque

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer, with_timeout


async def _reset(dut: Any) -> None:
    dut.i_src_rst.value = 1
    dut.i_dst_rst.value = 1
    dut.i_src_valid.value = 0
    dut.i_dst_ready.value = 0
    await Timer(250, unit="ns")
    await FallingEdge(dut.i_src_clk)
    dut.i_src_rst.value = 0
    await FallingEdge(dut.i_dst_clk)
    dut.i_dst_rst.value = 0


async def _transfer(dut: Any, count: int, seed: int) -> None:
    rng = random.Random(seed)
    expected: deque[int] = deque()
    received = 0

    async def source() -> None:
        for _ in range(count):
            data = rng.getrandbits(len(dut.i_src_data))
            await FallingEdge(dut.i_src_clk)
            dut.i_src_valid.value = 1
            dut.i_src_data.value = data
            while True:
                await RisingEdge(dut.i_src_clk)
                if int(dut.o_src_ready.value):
                    expected.append(data)
                    break
            await FallingEdge(dut.i_src_clk)
            dut.i_src_valid.value = 0

    async def destination() -> None:
        nonlocal received
        held = None
        while received < count:
            await FallingEdge(dut.i_dst_clk)
            ready = rng.randrange(4) == 0
            dut.i_dst_ready.value = ready
            await RisingEdge(dut.i_dst_clk)
            valid = int(dut.o_dst_valid.value)
            data = int(dut.o_dst_data.value)
            if held is not None:
                assert valid and data == held
            held = data if valid and not ready else None
            if valid and ready:
                assert expected and data == expected.popleft()
                received += 1

    writer = cocotb.start_soon(source())
    await with_timeout(destination(), 200, "us")
    await writer
    assert not expected
    await Timer(250, unit="ns")
    assert int(dut.o_src_idle.value)
    assert not int(dut.o_dst_valid.value)


@cocotb.test()
async def snapshots(dut: Any) -> None:
    """Snapshots cross intact and reset cancels them at three clock ratios."""
    for index, (src, dst) in enumerate(((10, 10), (6, 17), (17, 6))):
        dut.i_src_clk.value = 0
        dut.i_dst_clk.value = 0
        a = Clock(dut.i_src_clk, src, unit="ns").start()
        await Timer(3, unit="ns")
        b = Clock(dut.i_dst_clk, dst, unit="ns").start()
        await _reset(dut)
        await _transfer(dut, 200, index)
        # Reset cancels an accepted snapshot with a stalled receiver.
        await FallingEdge(dut.i_dst_clk)
        dut.i_dst_ready.value = 0
        await FallingEdge(dut.i_src_clk)
        dut.i_src_data.value = 0xDEADBEEF
        dut.i_src_valid.value = 1
        await RisingEdge(dut.i_src_clk)
        assert int(dut.o_src_ready.value)
        await FallingEdge(dut.i_src_clk)
        assert not int(dut.o_src_ready.value)
        await _reset(dut)
        await _transfer(dut, 50, index + 10)
        a.cancel()
        b.cancel()
