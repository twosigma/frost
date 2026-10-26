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

"""Reset release waits for both clocks, including a stopped peer."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer


@cocotb.test()
async def stopped_peer(dut: Any) -> None:
    """Both domains observe reset before either can run."""
    dut.i_arst.value = 1
    dut.i_a_clk.value = 0
    dut.i_b_clk.value = 0
    a = Clock(dut.i_a_clk, 10, unit="ns").start()
    await Timer(100, unit="ns")
    dut.i_arst.value = 0
    await Timer(100, unit="ns")
    assert int(dut.o_a_rst.value) and int(dut.o_b_rst.value)
    b = Clock(dut.i_b_clk, 23, unit="ns").start()
    await Timer(200, unit="ns")
    assert not int(dut.o_a_rst.value) and not int(dut.o_b_rst.value)
    a.cancel()
    dut.i_a_clk.value = 0
    # A pulse shorter than either period must assert and stretch both resets.
    await Timer(1, unit="ns")
    dut.i_arst.value = 1
    await Timer(1, unit="ns")
    assert int(dut.o_a_rst.value) and int(dut.o_b_rst.value)
    dut.i_arst.value = 0
    await Timer(200, unit="ns")
    assert int(dut.o_a_rst.value) and int(dut.o_b_rst.value)
    a = Clock(dut.i_a_clk, 10, unit="ns").start()
    await Timer(200, unit="ns")
    assert not int(dut.o_a_rst.value) and not int(dut.o_b_rst.value)
    a.cancel()
    b.cancel()
