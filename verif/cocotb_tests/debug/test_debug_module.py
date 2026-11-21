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
requests, target alignment, acknowledgement and cancellation. Slice requests
exercise writer backpressure and overlapping program-buffer writes.
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
        dut.i_hart_fatal_stop,
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


@cocotb.test()
async def test_dirty_words_wait_and_preserve_overlapping_write(dut: Any) -> None:
    """Writer stalls hold the selected word, and a concurrent DMI write wins."""
    await _setup(dut)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    dut.i_slice_req_ready.value = 0
    await FallingEdge(dut.i_clk)
    assert await _request(dut, OP_WRITE, DM_DMCONTROL, 1) == (STATUS_OK, 0)
    assert int(dut.o_slice_req_valid.value)
    base_word = int(dut.o_slice_word_addr.value)
    assert int(dut.o_slice_data.value) == 0x0000_006F
    for _ in range(3):
        await FallingEdge(dut.i_clk)
        assert int(dut.o_slice_req_valid.value)
        assert int(dut.o_slice_word_addr.value) == base_word
        assert int(dut.o_slice_data.value) == 0x0000_006F

    assert await _request(dut, OP_WRITE, 0x20, 0x1122_3344) == (STATUS_OK, 0)
    dut.i_slice_req_ready.value = 1
    for index in range(5):
        assert int(dut.o_slice_req_valid.value)
        assert int(dut.o_slice_word_addr.value) == base_word + index
        await FallingEdge(dut.i_clk)
    dut.i_slice_req_ready.value = 0
    assert int(dut.o_slice_word_addr.value) == base_word + 5
    assert int(dut.o_slice_data.value) == 0x1122_3344
    await FallingEdge(dut.i_clk)
    dut.i_dmi_req_valid.value = 1
    dut.i_dmi_req_op.value = OP_WRITE
    dut.i_dmi_req_addr.value = 0x20
    dut.i_dmi_req_data.value = 0x5566_7788
    dut.i_slice_req_ready.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_dmi_req_valid.value = 0
    dut.i_slice_req_ready.value = 0
    answer = _answer(dut)
    assert answer is not None and answer[0] == STATUS_OK
    assert int(dut.o_slice_req_valid.value)
    assert int(dut.o_slice_word_addr.value) == base_word + 5
    assert int(dut.o_slice_data.value) == 0x5566_7788
    await FallingEdge(dut.i_clk)
    dut.i_slice_req_ready.value = 1
    for index in range(5, 16):
        assert int(dut.o_slice_req_valid.value)
        assert int(dut.o_slice_word_addr.value) == base_word + index
        await FallingEdge(dut.i_clk)
    dut.i_slice_req_ready.value = 0
    assert not int(dut.o_slice_req_valid.value)

    assert await _request(dut, OP_WRITE, 0x28, 0xAABB_CCDD) == (STATUS_OK, 0)
    assert not int(dut.o_slice_req_valid.value)
    assert await _request(dut, OP_WRITE, 0x27, 0x99AA_BBCC) == (STATUS_OK, 0)
    assert int(dut.o_slice_req_valid.value)
    assert int(dut.o_slice_word_addr.value) == base_word + 12
    assert int(dut.o_slice_data.value) == 0x99AA_BBCC
    dut.i_slice_req_ready.value = 1
    await FallingEdge(dut.i_clk)
    assert not int(dut.o_slice_req_valid.value)


DM_ABSTRACTCS = 0x16
DM_HALTSUM0 = 0x40
DMSTATUS_HALTED = 0b11 << 8
DMSTATUS_RUNNING = 0b11 << 10
DMSTATUS_UNAVAIL = 0b11 << 12
ABSTRACTCS_BUSY = 1 << 12
CMDERR_HALT_RESUME = 4


async def _dmstatus(dut: Any) -> int:
    status, value = await _request(dut, OP_READ, DM_DMSTATUS)
    assert status == STATUS_OK
    return value


async def _abstractcs(dut: Any) -> tuple[int, int]:
    """Return (busy, cmderr)."""
    status, value = await _request(dut, OP_READ, DM_ABSTRACTCS)
    assert status == STATUS_OK
    return (value >> 12) & 1, (value >> 8) & 7


async def _clear_cmderr(dut: Any) -> None:
    assert (await _request(dut, OP_WRITE, DM_ABSTRACTCS, 0x700))[0] == STATUS_OK


@cocotb.test()
async def test_fatal_stop_reports_unavailable(dut: Any) -> None:
    """A fatal stop reads as unavailable, also for a hart already in Debug Mode."""
    await _setup(dut)
    await _activate_hart(dut)
    status = await _dmstatus(dut)
    assert status & DMSTATUS_HALTED == DMSTATUS_HALTED, f"dmstatus {status:#x}"
    assert not status & (DMSTATUS_RUNNING | DMSTATUS_UNAVAIL)
    assert (await _request(dut, OP_READ, DM_HALTSUM0))[1] == 1
    await _go_edge(dut, i_hart_fatal_stop=1)
    status = await _dmstatus(dut)
    assert status & DMSTATUS_UNAVAIL == DMSTATUS_UNAVAIL, f"dmstatus {status:#x}"
    assert not status & (DMSTATUS_HALTED | DMSTATUS_RUNNING), f"dmstatus {status:#x}"
    assert (await _request(dut, OP_READ, DM_HALTSUM0))[1] == 0
    await _go_edge(dut, i_hart_fatal_stop=0)
    status = await _dmstatus(dut)
    assert status & DMSTATUS_HALTED == DMSTATUS_HALTED and not status & DMSTATUS_UNAVAIL


@cocotb.test()
async def test_fatal_stop_refuses_a_command(dut: Any) -> None:
    """A command written while the hart is unavailable starts nothing: cmderr 4."""
    await _setup(dut)
    await _activate_hart(dut)
    await _go_edge(dut, i_hart_fatal_stop=1, i_slice_all_done=1)
    assert await _request(dut, OP_WRITE, DM_COMMAND, 0) == (STATUS_OK, 0)
    for _ in range(10):
        assert (await _go_edge(dut))[0] == 0, "a refused command requested a GO"
    assert await _abstractcs(dut) == (0, CMDERR_HALT_RESUME)
    await _clear_cmderr(dut)
    assert await _abstractcs(dut) == (0, 0)


@cocotb.test()
async def test_fatal_stop_ends_a_command_in_flight(dut: Any) -> None:
    """A command in flight ends with cmderr 4 and busy clears, in every state."""
    await _setup(dut)
    for state in ("go", "start", "done"):
        await _go_edge(dut, i_rst=1, i_hart_fatal_stop=0, i_go_taken=0, i_parked=1)
        await _activate_hart(dut)
        await _prepare_go(dut, resume=False)
        assert (await _go_edge(dut))[0] == 1
        assert (await _abstractcs(dut))[0] == 1
        if state != "go":
            await _go_edge(dut, i_go_taken=1)
            await _go_edge(dut, i_go_taken=0)
        if state == "done":
            await _go_edge(dut, i_parked=0)
        await _go_edge(dut, i_hart_fatal_stop=1)
        for _ in range(3):
            assert (await _go_edge(dut))[0] == 0, f"GO after the stop ({state})"
        assert await _abstractcs(dut) == (0, CMDERR_HALT_RESUME), state
        await _clear_cmderr(dut)


@cocotb.test()
async def test_fatal_stop_ignores_resume_and_keeps_the_halt_level(dut: Any) -> None:
    """Resumereq starts nothing and a resume in flight ends; haltreq stays a level."""
    await _setup(dut)
    await _activate_hart(dut)
    await _prepare_go(dut, resume=True)
    assert (await _go_edge(dut))[0] == 1
    await _go_edge(dut, i_hart_fatal_stop=1)
    for _ in range(3):
        assert (await _go_edge(dut))[0] == 0, "resume GO after the stop"
    assert not (await _dmstatus(dut)) & (1 << 17), "resumeack after an ended resume"
    assert await _request(dut, OP_WRITE, DM_DMCONTROL, (1 << 30) | 1) == (STATUS_OK, 1)
    for _ in range(10):
        assert (await _go_edge(dut))[0] == 0, "resumereq started a resume"
    assert not (await _dmstatus(dut)) & (1 << 17)
    assert await _request(dut, OP_WRITE, DM_DMCONTROL, (1 << 31) | 1) == (STATUS_OK, 1)
    assert int(dut.o_haltreq.value) == 1, "haltreq is a level the module keeps"
    assert (await _dmstatus(dut)) & DMSTATUS_UNAVAIL == DMSTATUS_UNAVAIL


@cocotb.test()
async def test_fatal_stop_resumereq_clears_a_stale_acknowledge(dut: Any) -> None:
    """A resumereq after the stop clears the old acknowledge and starts nothing."""
    await _setup(dut)
    await _activate_hart(dut)
    await _prepare_go(dut, resume=True)
    assert (await _go_edge(dut))[0] == 1
    await _complete_go(dut, resume=True)
    assert (await _dmstatus(dut)) & (1 << 17), (
        "the completed resume was not acknowledged"
    )
    await _go_edge(dut, i_hart_fatal_stop=1)
    assert (await _dmstatus(dut)) & (1 << 17), (
        "the stop alone must not clear the acknowledge"
    )
    assert await _request(dut, OP_WRITE, DM_DMCONTROL, (1 << 30) | 1) == (STATUS_OK, 1)
    for _ in range(10):
        assert (await _go_edge(dut))[0] == 0, "resumereq started a resume"
    status = await _dmstatus(dut)
    assert not status & (0b11 << 16), f"stale resumeack survived the write: {status:#x}"
    assert status & DMSTATUS_UNAVAIL == DMSTATUS_UNAVAIL
