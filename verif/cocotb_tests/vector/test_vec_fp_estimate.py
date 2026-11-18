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

"""Reciprocal estimates: every table index, exponent boundaries and subnormals."""

import os
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from .test_vec_fp_exec import FLAGS, ROUNDING, fp_call


@cocotb.test()
async def estimates_against_softfloat(dut: Any) -> None:
    """Check both estimates and flags against the independent reference library."""
    width = len(dut.i_a)
    frac = {16: 10, 32: 23, 64: 52}[width]
    exp = width - frac - 1
    maximum = (1 << exp) - 1
    bias = maximum // 2
    values = {
        (e << frac) | (index << (frac - 7)) | low
        for e in (0, 1, 2, bias, bias + 1, maximum - 2, maximum - 1, maximum)
        for index in range(128)
        for low in (0, (1 << (frac - 7)) - 1)
    }
    values.update((1 << bit) for bit in range(frac))
    values.update((1 << bit) - 1 for bit in range(frac + 1))
    latency = frac + 3 + int(os.getenv("FROST_VECTOR_LATENCY_NEGATIVE", "0"))
    negative = bool(int(os.getenv("FROST_VECTOR_NEGATIVE_CONTROL", "0")))
    Clock(dut.i_clk, 2, unit="ns").start()
    dut.i_rst.value = 1
    dut.i_valid.value = 0
    dut.i_a.value = 0
    dut.i_rsqrt.value = 0
    dut.i_rm.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    count = 0
    for sqrt, operation in enumerate(("recip7", "rsqrte7")):
        for rm in range(5):
            for sign in (0, 1):
                for value in sorted(values):
                    value |= sign << (width - 1)
                    ROUNDING.value = rm
                    FLAGS.value = 0
                    want = fp_call(width, operation, value)
                    want_flags = int(FLAGS.value)
                    if negative and count == 0:
                        want ^= 1
                    assert int(dut.o_ready.value) == 1
                    dut.i_valid.value = 1
                    dut.i_rsqrt.value = sqrt
                    dut.i_rm.value = rm
                    dut.i_a.value = value
                    await RisingEdge(dut.i_clk)
                    await FallingEdge(dut.i_clk)
                    dut.i_valid.value = 0
                    cycles = 1
                    while True:
                        await RisingEdge(dut.i_clk)
                        await ReadOnly()
                        if int(dut.o_valid.value):
                            break
                        assert not int(dut.o_ready.value), "ready while busy"
                        cycles += 1
                        assert cycles <= latency, "missing result"
                    assert cycles == latency, f"latency {cycles}, expected {latency}"
                    got = int(dut.o_result.value), int(dut.o_flags.value)
                    assert got == (want, want_flags), (
                        operation,
                        width,
                        rm,
                        hex(value),
                        got,
                        (want, want_flags),
                    )
                    count += 1
                    await FallingEdge(dut.i_clk)
    dut._log.info("%d estimate result/flag/latency cases matched", count)
