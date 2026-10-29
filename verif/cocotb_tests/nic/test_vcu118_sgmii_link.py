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

"""Check the SGMII status contract without vendor IP."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


@cocotb.test()
async def copper_link_and_duplex(dut: Any) -> None:
    """Only a synchronized, negotiated full-duplex copper link permits traffic."""
    Clock(dut.i_clk, 8, unit="ns").start()
    for reset, loopback, status, expected in (
        (1, 1, 0xFFFF, 0),
        (0, 0, 0x1803, 0),  # serial link up, copper down
        (0, 0, 0x0883, 0),  # copper link in half duplex
        (0, 0, 0x1882, 0),  # incomplete negotiation
        (0, 0, 0x1881, 0),  # no serial synchronization
        (0, 0, 0x1883, 1),  # full-duplex gigabit
        (0, 0, 0x1483, 1),  # full-duplex 100 Mb/s
        (0, 0, 0x1083, 1),  # full-duplex 10 Mb/s
        (0, 1, 0, 1),  # internal loopback
        (1, 0, 0x1883, 0),
    ):
        await FallingEdge(dut.i_clk)
        dut.i_rst.value = reset
        dut.i_loopback.value = loopback
        dut.i_status.value = status
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        assert int(dut.o_ready.value) == expected
