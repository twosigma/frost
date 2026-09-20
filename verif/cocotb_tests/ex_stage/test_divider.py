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

"""Check arithmetic and cycle alignment of the two-bits-per-stage divider.

Divisors around every power of two exercise each stage's prefix-width cutoff.
The scoreboard uses integer division, independently of the restoring algorithm,
and checks every cycle, including bubbles and reset with outstanding work.
"""

from collections import deque
import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge


@cocotb.test()
async def test_streaming_division(dut: Any) -> None:
    """Preserve DIV/REM results and WIDTH/2+1 latency for a mixed input stream."""
    width = len(dut.i_dividend)
    mask = (1 << width) - 1
    sign_bit = 1 << (width - 1)
    latency = width // 2 + 1
    rng = random.Random(0xD1_71_DE + width)
    pending: deque[tuple[int, int] | None] = deque([None] * (latency - 1))
    checked = 0
    cycle = 0

    def reference(a: int, b: int, signed: bool) -> tuple[int, int]:
        if b == 0:
            return mask, a
        if signed:
            a = a - (1 << width) if a & sign_bit else a
            b = b - (1 << width) if b & sign_bit else b
        quotient = abs(a) // abs(b)
        if (a < 0) != (b < 0):
            quotient = -quotient
        return quotient & mask, (a - quotient * b) & mask

    async def step(
        a: int = 0,
        b: int = 0,
        signed: bool = False,
        *,
        valid: bool = True,
        reset: bool = False,
    ) -> None:
        nonlocal checked, cycle
        await FallingEdge(dut.i_clk)
        dut.i_rst.value = int(reset)
        dut.i_valid_input.value = int(valid)
        dut.i_is_signed_operation.value = int(signed)
        dut.i_dividend.value = a
        dut.i_divisor.value = b
        if reset:
            pending.clear()
            pending.extend([None] * (latency - 1))
            expected = None
        else:
            pending.append(reference(a, b, signed) if valid else None)
            expected = pending.popleft()
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        assert bool(dut.o_valid_output.value) == (
            expected is not None
        ), f"cycle {cycle}: valid misaligned at latency {latency}"
        if expected is not None:
            actual = (int(dut.o_quotient.value), int(dut.o_remainder.value))
            assert (
                actual == expected
            ), f"cycle {cycle}: got q/r {actual}, expected {expected}"
            checked += 1
        cycle += 1

    dut.i_clk.value = 0
    dut.i_rst.value = 1
    dut.i_valid_input.value = 0
    dut.i_is_signed_operation.value = 0
    dut.i_dividend.value = 0
    dut.i_divisor.value = 0
    Clock(dut.i_clk, 10, unit="ns").start()
    await step(reset=True)

    corners = (0, 1, 2, 3, sign_bit - 1, sign_bit, sign_bit + 1, mask - 1, mask)
    for signed in (False, True):
        for a in corners:
            for b in corners:
                await step(a, b, signed)
        for bit in range(width):
            for delta in (-1, 0, 1):
                b = ((1 << bit) + delta) & mask
                for a in (0, mask, (b - 1) & mask, b, (b + 1) & mask):
                    await step(a, b, signed)

    # Mix long runs with small divisors (many nonzero quotient digits), wide
    # divisors, signed inputs, invalid bubbles, and reset at each pipeline age.
    for age in range(latency):
        for _ in range(age):
            await step(rng.getrandbits(width), rng.getrandbits(width), bool(age & 1))
        await step(mask, 0, True, reset=True)
    for index in range(2048):
        b = rng.getrandbits((index % width) + 1)
        await step(rng.getrandbits(width), b, bool(index & 1), valid=index % 7 != 0)
    for _ in range(latency):
        await step(valid=False)
    dut._log.info(
        "Checked %d DIV/REM results at WIDTH=%d, latency=%d", checked, width, latency
    )
