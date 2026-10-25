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

"""Check cold-start history and legal channel stalls on the AXI monitor."""

import cocotb
from typing import Any
from cocotb.handle import Immediate
from cocotb.triggers import Timer


async def clock_edge(dut: Any) -> None:
    """Present one rising edge after a low half-cycle."""
    dut.i_clk.value = 0
    await Timer(1, unit="ns")
    dut.i_clk.value = 1
    await Timer(1, unit="ns")


@cocotb.test()
async def test_reset_history_and_stalls(dut: Any) -> None:
    """Arbitrary wait history is ignored until reset; legal stalls then pass."""
    for signal in dut:
        if signal._name.startswith("i_"):
            signal.value = Immediate(0)
    await Timer(1, unit="ns")
    for channel in ("aw", "w", "b", "ar", "r"):
        getattr(dut, f"{channel}_wait_q").value = 1
    await clock_edge(dut)
    assert int(dut.reset_seen_q.value) == 0
    dut.i_rst.value = 1
    await clock_edge(dut)
    assert int(dut.reset_seen_q.value) == 1
    for channel in ("aw", "w", "b", "ar", "r"):
        dut.i_rst.value = 1
        await clock_edge(dut)
        dut.i_rst.value = 0
        valid = getattr(dut, f"i_{channel}valid")
        ready = getattr(dut, f"i_{channel}ready")
        valid.value = 1
        ready.value = 0
        for _ in range(3):
            await clock_edge(dut)
        ready.value = 1
        await clock_edge(dut)
        valid.value = 0
        await clock_edge(dut)
