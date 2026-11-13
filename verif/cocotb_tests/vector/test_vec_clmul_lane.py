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

"""Check vec_clmul_lane against a Python carry-less multiply.

Random and directed operands (zero, one, all ones, single bits), low and high
halves, one input per cycle; each result is compared two cycles after the
cycle that takes it.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

LATENCY = 2
M64 = (1 << 64) - 1


def clmul(a: int, b: int) -> int:
    """Return the 128-bit carry-less product."""
    r = 0
    for i in range(64):
        if (b >> i) & 1:
            r ^= a << i
    return r


def operand(rng: random.Random) -> int:
    """Return a random or directed operand."""
    pick = rng.random()
    if pick < 0.15:
        return rng.choice([0, 1, M64, 1 << 63])
    if pick < 0.3:
        return 1 << rng.randrange(64)
    return rng.getrandbits(64)


@cocotb.test()
async def test_vec_clmul_lane_random(dut: Any) -> None:
    """Random carry-less products, back to back."""
    rng = random.Random(2031)
    Clock(dut.i_clk, 2, unit="ns").start()
    for sig in ("i_valid", "i_high", "i_a", "i_b"):
        getattr(dut, sig).value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0

    count = 4000
    pending: dict[int, tuple[int, int, int, int]] = {}
    checked = 0
    for cycle in range(count + LATENCY + 1):
        if cycle < count:
            a, b, high = operand(rng), operand(rng), rng.getrandbits(1)
            dut.i_valid.value = 1
            dut.i_high.value = high
            dut.i_a.value = a
            dut.i_b.value = b
            p = clmul(a, b)
            pending[cycle] = (a, b, high, (p >> 64) if high else (p & M64))
        else:
            dut.i_valid.value = 0
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        origin = cycle - LATENCY
        if origin in pending:
            a, b, high, want = pending.pop(origin)
            assert int(dut.o_valid.value) == 1
            got = int(dut.o_result.value)
            assert got == want, (
                f"a={a:#x} b={b:#x} high={high}: {got:#x} want {want:#x}"
            )
            checked += 1
        await FallingEdge(dut.i_clk)
    assert checked == count
    dut._log.info(f"{checked} products checked")
