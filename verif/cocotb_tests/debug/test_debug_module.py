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

"""Test debug_module's DMI interface (hw/rtl/cpu_and_mem/debug/debug_module.sv).

Each request requires one answer: the next cycle, or after reset ends if
it arrives during reset. Hold the payload until the answer, as dtm_core
does. GO tests drive the hart and slice-writer handshakes to check registered
requests, target alignment, acknowledgement and cancellation.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

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
    dut.i_power_on_rst.value = 1
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_power_on_rst.value = 0


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


DM_COMMAND = 0x17
DEBUG_ABSTRACT_ADDR = 0x17C08
DEBUG_RESUME_ADDR = 0x17C38


async def _go_edge(dut: Any, **inputs: int) -> tuple[int, int]:
    await FallingEdge(dut.i_clk)
    for name, value in inputs.items():
        getattr(dut, name).value = value
    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")
    return int(dut.o_go.value), int(dut.o_go_addr.value)


async def _drain_slice(dut: Any) -> None:
    for _ in range(40):
        await FallingEdge(dut.i_clk)
        assert not int(dut.o_go.value), "GO preceded slice publication"
        if not int(dut.o_slice_req_valid.value):
            return
    raise AssertionError("slice words did not drain")


async def _activate_hart(dut: Any) -> None:
    await _go_edge(
        dut,
        i_rst=0,
        i_debug_mode=1,
        i_parked=1,
        i_go_taken=0,
        i_slice_req_ready=1,
        i_slice_all_done=0,
    )
    assert await _request(dut, OP_WRITE, DM_DMCONTROL, 1) == (STATUS_OK, 0)
    await _drain_slice(dut)


async def _prepare_go(dut: Any, *, resume: bool, publish: bool = True) -> int:
    await _go_edge(dut, i_slice_all_done=0)
    if resume:
        assert await _request(dut, OP_WRITE, DM_DMCONTROL, (1 << 30) | 1) == (
            STATUS_OK,
            1,
        )
        target = DEBUG_RESUME_ADDR
    else:
        assert await _request(dut, OP_WRITE, DM_COMMAND, 0) == (STATUS_OK, 0)
        target = DEBUG_ABSTRACT_ADDR
    await _drain_slice(dut)
    for _ in range(3):
        assert (await _go_edge(dut))[0] == 0
    if publish:
        assert (await _go_edge(dut, i_slice_all_done=1))[0] == 0
    return target


async def _complete_go(dut: Any, *, resume: bool) -> None:
    assert (await _go_edge(dut, i_go_taken=1))[0] == 0
    if resume:
        await _go_edge(dut, i_go_taken=0, i_debug_mode=0)
        await _go_edge(dut, i_debug_mode=1, i_parked=1)
    else:
        await _go_edge(dut, i_go_taken=0, i_parked=0)
        await _go_edge(dut, i_parked=1)
    for _ in range(6):
        assert (await _go_edge(dut))[0] == 0, "acknowledged GO replayed"


@cocotb.test()
async def test_registered_go_target_and_acknowledgement(dut: Any) -> None:
    """Command and resume targets align with GO and stay stable until acceptance."""
    await _setup(dut)
    await _activate_hart(dut)
    for resume in (False, True, False):
        target = await _prepare_go(dut, resume=resume)
        assert await _go_edge(dut) == (1, target)
        for _ in range(8):
            assert await _go_edge(dut) == (1, target)
        await _complete_go(dut, resume=resume)


@cocotb.test()
async def test_module_reset_clears_pending_and_presented_go(dut: Any) -> None:
    """Reset cancels requests before release and while they wait for acceptance."""
    await _setup(dut)
    for resume in (False, True):
        for released in (False, True):
            await _activate_hart(dut)
            target = await _prepare_go(dut, resume=resume)
            if released:
                assert await _go_edge(dut) == (1, target)
            assert (await _go_edge(dut, i_rst=1))[0] == 0
            for _ in range(3):
                assert (await _go_edge(dut))[0] == 0
    await _activate_hart(dut)
    target = await _prepare_go(dut, resume=False)
    assert await _go_edge(dut) == (1, target)
    await _complete_go(dut, resume=False)


@cocotb.test()
async def test_deactivation_cancels_go_and_allows_a_fresh_request(dut: Any) -> None:
    """Clearing dmactive resets the request with the command/resume sequencer."""
    await _setup(dut)
    for resume in (False, True):
        for released in (False, True):
            await _activate_hart(dut)
            target = await _prepare_go(dut, resume=resume, publish=released)
            if released:
                assert await _go_edge(dut) == (1, target)
                assert await _request(dut, OP_WRITE, DM_DMCONTROL, 0) == (STATUS_OK, 1)
            else:
                assert (
                    await _go_edge(
                        dut,
                        i_slice_all_done=1,
                        i_dmi_req_valid=1,
                        i_dmi_req_op=OP_WRITE,
                        i_dmi_req_addr=DM_DMCONTROL,
                        i_dmi_req_data=0,
                    )
                )[0] == 0
                assert _answer(dut) == (STATUS_OK, 1)
                assert (await _go_edge(dut, i_dmi_req_valid=0))[0] == 0
            for _ in range(5):
                assert (await _go_edge(dut))[0] == 0
    await _activate_hart(dut)
    target = await _prepare_go(dut, resume=True)
    assert await _go_edge(dut) == (1, target)
    await _complete_go(dut, resume=True)
