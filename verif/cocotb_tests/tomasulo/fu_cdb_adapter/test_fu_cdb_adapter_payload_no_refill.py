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

"""Contract test for the adapter's simplified payload write enable."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from .fu_cdb_adapter_interface import FuCdbAdapterInterface

CLOCK_PERIOD_NS = 10


@cocotb.test()
async def test_payload_write_without_refill_qualification(dut: Any) -> None:
    """Exercise capture and drain while honoring valid -> !pending."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    dut_if = FuCdbAdapterInterface(dut)
    await dut_if.reset_dut()

    # An ungranted idle result is captured and becomes pending.
    dut_if.drive_fu_result(tag=3, value=0x1234)
    await dut_if.step()
    dut_if.clear_fu_result()
    await Timer(1, unit="ns")

    assert dut_if.read_result_pending()
    held = dut_if.read_fu_complete()
    assert held.valid and held.tag == 3 and held.value == 0x1234

    # While pending, the integration contract keeps the FU input invalid.
    # A grant therefore drains the existing payload through the unchanged
    # ALLOW_GRANT_REFILL state transition.
    dut_if.drive_grant()
    await dut_if.step()
    dut_if.clear_grant()
    await Timer(1, unit="ns")
    assert not dut_if.read_result_pending()

    # Same-cycle pass-through/grant still has zero latency and stays idle.
    dut_if.drive_fu_result(tag=4, value=0x5678)
    dut_if.drive_grant()
    await Timer(1, unit="ns")
    passthrough = dut_if.read_fu_complete()
    assert passthrough.valid and passthrough.tag == 4 and passthrough.value == 0x5678
    await dut_if.step()
    assert not dut_if.read_result_pending()

