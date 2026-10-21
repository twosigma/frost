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

"""External errors survive every cache, arbiter, and coherence path."""

from typing import Any

import cocotb
from cocotb_tests.cache.test_frost_cache import _port_transaction, _setup


@cocotb.test()
async def read_errors_all_clients_and_retry(dut: Any) -> None:
    """Check read errors all clients and retry."""
    await _setup(dut)
    dut.i_coh_admit_ready.value = 1
    dut.i_coh_inval_done.value = 1
    for index, port in enumerate(("up", "iup", "wup", "dma")):
        addr = 0x80004000 + index * 0x1000
        dut.i_down_response_error.value = 1
        await _port_transaction(dut, port, write=False, addr=addr)
        assert int(getattr(dut, f"o_{port}_resp_error").value) == 1, port
        assert not int(dut.o_fatal_error.value), port
        dut.i_down_response_error.value = 0
        await _port_transaction(dut, port, write=False, addr=addr)
        assert not int(getattr(dut, f"o_{port}_resp_error").value), port
        # This time memory fails, but the successful retry must have filled
        # the shared cache. A hit does not create another bus transaction.
        dut.i_down_response_error.value = 1
        await _port_transaction(dut, port, write=False, addr=addr)
        assert not int(getattr(dut, f"o_{port}_resp_error").value), port
