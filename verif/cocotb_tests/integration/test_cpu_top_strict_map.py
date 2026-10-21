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

"""Reject holes in an otherwise default FROST map when compatibility is disabled."""

from typing import Any

import cocotb
from cocotb_tests.integration.test_cpu_top import System, store, trap_program


@cocotb.test()
async def unmapped_device_store_faults_without_an_axi_transaction(dut: Any) -> None:
    """Trap an untranslated store outside configured Device regions before AXI."""
    s = System(dut)
    fault_pc = trap_program(s, [0x40100237, store(0, 4, 0, 2)]) + 4
    await s.reset()
    await s.until_write(0x40000020)
    values = {addr: value for _, addr, value in s.effects}
    assert values[0x40000010] == 7
    assert values[0x40000018] == fault_pc
    assert 0x40000008 not in values
    assert not any(addr == 0x40100000 for _, _, addr, *_ in s.transactions)
