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

"""Unit tests for debug_module's DMI face (hw/rtl/cpu_and_mem/debug/debug_module.sv).

dtm_core waits for an answer to every request it issues, so the module must
answer each one exactly once: the next cycle, or, for a request that arrives
while the module is in reset, once the reset ends, when the request is also
handled. Like dtm_core, the bench holds a request's payload until the
answer. The hart and slice-writer inputs sit idle: no hart is halted and no
command runs.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

DM_DATA0 = 0x04
DM_DMCONTROL = 0x10
DM_DMSTATUS = 0x11
OP_READ, OP_WRITE = 1, 2
STATUS_OK = 0


async def _setup(dut: Any) -> None:
    Clock(dut.i_clk, 10, unit="ns").start()
    for sig in (
        dut.i_dmi_req_valid,
        dut.i_dmi_req_op,
        dut.i_dmi_req_addr,
        dut.i_dmi_req_data,
        dut.i_data_we,
        dut.i_data_wdata,
        dut.i_debug_mode,
        dut.i_parked,
        dut.i_cmd_err,
        dut.i_go_taken,
        dut.i_core_in_reset,
        dut.i_slice_overflow,
    ):
        sig.value = 0
    dut.i_slice_req_ready.value = 1
    dut.i_slice_all_done.value = 1
    dut.i_rst.value = 1
    for _ in range(4):
        await RisingEdge(dut.i_clk)


async def _present(dut: Any, op: int, addr: int, data: int = 0) -> None:
    """Pulse one request's valid for one cycle; the payload stays until the answer."""
    await FallingEdge(dut.i_clk)
    dut.i_dmi_req_valid.value = 1
    dut.i_dmi_req_op.value = op
    dut.i_dmi_req_addr.value = addr
    dut.i_dmi_req_data.value = data
    await FallingEdge(dut.i_clk)
    dut.i_dmi_req_valid.value = 0


def _answer(dut: Any) -> tuple[int, int] | None:
    """Return the (status, data) answered in this cycle, or None."""
    if not int(dut.o_dmi_resp_valid.value):
        return None
    return int(dut.o_dmi_resp_op.value), int(dut.o_dmi_resp_data.value)


async def _request(dut: Any, op: int, addr: int, data: int = 0) -> tuple[int, int]:
    """One request out of reset: answered the next cycle, once."""
    await _present(dut, op, addr, data)
    answer = _answer(dut)
    assert answer is not None, "no answer the cycle after the request"
    await FallingEdge(dut.i_clk)
    assert _answer(dut) is None, "one request was answered twice"
    return answer


@cocotb.test()
async def test_request_in_reset_waits_for_the_reset_to_end(dut: Any) -> None:
    """A request made in reset is answered and handled once, after the reset ends.

    The write sets dmactive, the one register a write reaches while the
    module is inactive, so its effect shows that the request was handled.
    """
    await _setup(dut)
    await _present(dut, OP_WRITE, DM_DMCONTROL, 1)
    for _ in range(20):
        assert _answer(dut) is None, "answered while the module was in reset"
        await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    answers = []
    for _ in range(5):
        await FallingEdge(dut.i_clk)
        answer = _answer(dut)
        if answer is not None:
            answers.append(answer)
    assert answers == [(STATUS_OK, 0)], f"answers after the reset: {answers}"
    status, dmcontrol = await _request(dut, OP_READ, DM_DMCONTROL)
    assert status == STATUS_OK and dmcontrol & 1 == 1, (
        f"the write made in reset was not handled: dmcontrol {dmcontrol:#x}"
    )


@cocotb.test()
async def test_answers_every_request_the_next_cycle(dut: Any) -> None:
    """Out of reset, reads and writes are answered the next cycle with their data."""
    await _setup(dut)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await FallingEdge(dut.i_clk)
    assert await _request(dut, OP_WRITE, DM_DMCONTROL, 1) == (STATUS_OK, 0)
    status, dmstatus = await _request(dut, OP_READ, DM_DMSTATUS)
    assert status == STATUS_OK and dmstatus & 0xF == 2, f"dmstatus {dmstatus:#x}"
    assert await _request(dut, OP_WRITE, DM_DATA0, 0xCAFE_F00D) == (STATUS_OK, 0)
    assert await _request(dut, OP_READ, DM_DATA0) == (STATUS_OK, 0xCAFE_F00D)
