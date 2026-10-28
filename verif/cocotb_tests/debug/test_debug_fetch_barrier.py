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

"""Debug requests cross a fetch invalidation edge before reaching the CPU."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


async def _cycle(dut: Any, **inputs: int) -> tuple[int, int, int]:
    await FallingEdge(dut.i_clk)
    for name, value in inputs.items():
        getattr(dut, name).value = value
    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")
    return (
        int(dut.o_invalidate.value),
        int(dut.o_go_valid.value),
        int(dut.o_go_addr.value),
    )


async def _reset(dut: Any) -> None:
    dut.i_rst.value = 1
    dut.i_req_valid.value = 0
    dut.i_req_addr.value = 0
    dut.i_go_taken.value = 0
    dut.i_pc.value = 0x100
    dut.i_line_req_ready.value = 0
    dut.i_line_resp_valid.value = 0
    dut.i_line_resp_error.value = 0
    dut.i_line_resp_id.value = 0
    dut.i_line_resp_rdata.value = 0
    for _ in range(3):
        assert await _cycle(dut) == (0, 0, 0)
    await _cycle(dut, i_rst=0)


async def _setup(dut: Any) -> None:
    Clock(dut.i_clk, 10, unit="ns").start()
    await _reset(dut)


@cocotb.test()
async def test_invalidate_then_go_with_backpressure_and_no_replay(dut: Any) -> None:
    """Each request clears fetch first and keeps its target through acceptance."""
    await _setup(dut)
    for target in (0x17C08, 0x17C38, 0x1234ABCE):
        assert await _cycle(dut, i_req_valid=1, i_req_addr=target) == (1, 0, target)
        assert await _cycle(dut) == (0, 1, target)
        for value in range(8):
            assert await _cycle(dut, i_req_addr=value) == (0, 1, target)
        assert await _cycle(dut, i_go_taken=1) == (0, 0, target)
        for _ in range(4):
            assert await _cycle(dut, i_go_taken=0) == (0, 0, target)
        assert await _cycle(dut, i_req_valid=0) == (0, 0, target)


@cocotb.test()
async def test_withdrawal_before_and_after_release(dut: Any) -> None:
    """A requester can cancel while invalidating or while waiting for acceptance."""
    await _setup(dut)
    for release in (False, True):
        assert await _cycle(dut, i_req_valid=1, i_req_addr=0x17C08) == (1, 0, 0x17C08)
        if release:
            assert await _cycle(dut) == (0, 1, 0x17C08)
        await FallingEdge(dut.i_clk)
        dut.i_req_valid.value = 0
        await Timer(1, unit="ns")
        assert int(dut.o_go_valid.value) == 0
        for _ in range(3):
            assert (await _cycle(dut))[:2] == (0, 0)
    assert await _cycle(dut, i_req_valid=1, i_req_addr=0x17C38) == (1, 0, 0x17C38)
    assert await _cycle(dut) == (0, 1, 0x17C38)


@cocotb.test()
async def test_reset_in_each_request_phase(dut: Any) -> None:
    """Reset clears idle, invalidation, released and acknowledged requests."""
    await _setup(dut)
    for phase in range(4):
        await _cycle(dut, i_req_valid=0, i_go_taken=0)
        if phase >= 1:
            assert await _cycle(dut, i_req_valid=1, i_req_addr=0x17C08) == (
                1,
                0,
                0x17C08,
            )
        if phase >= 2:
            assert await _cycle(dut) == (0, 1, 0x17C08)
        if phase >= 3:
            assert await _cycle(dut, i_go_taken=1) == (0, 0, 0x17C08)
        for _ in range(3):
            assert await _cycle(dut, i_rst=1, i_go_taken=0) == (0, 0, 0)
        assert await _cycle(dut, i_rst=0, i_req_valid=1, i_req_addr=0x17C38) == (
            1,
            0,
            0x17C38,
        )
        assert await _cycle(dut) == (0, 1, 0x17C38)


def _line(word: int) -> int:
    return sum(word << (32 * index) for index in range(8))


async def _accept_fill(dut: Any) -> int:
    for _ in range(50):
        if int(dut.o_line_req_valid.value):
            assert int(dut.o_line_req_addr.value) == 0x100
            request_id = int(dut.o_line_req_id.value)
            await _cycle(dut, i_line_req_ready=1)
            await _cycle(dut, i_line_req_ready=0)
            return request_id
        await _cycle(dut)
    raise AssertionError("fetch did not request the target line")


async def _wait_instruction(dut: Any, word: int) -> None:
    for _ in range(50):
        if int(dut.o_instr_valid.value):
            assert int(dut.o_instr.value) == word | (word << 32)
            return
        await _cycle(dut)
    raise AssertionError("fetch did not publish the expected instruction")


async def _fresh_fill(dut: Any) -> None:
    for _ in range(6):
        await _cycle(dut)
        assert not int(dut.o_instr_valid.value), "pre-GO instructions survived"
    request_id = await _accept_fill(dut)
    await _cycle(
        dut,
        i_line_resp_valid=1,
        i_line_resp_id=request_id,
        i_line_resp_rdata=_line(0x00200093),
    )
    await _cycle(dut, i_line_resp_valid=0)
    await _wait_instruction(dut, 0x00200093)


@cocotb.test()
async def test_go_discards_inflight_fetch_response(dut: Any) -> None:
    """Responses on or after debug invalidation cannot publish old instructions."""
    await _setup(dut)
    for delay in (0, 4):
        await _reset(dut)
        request_id = await _accept_fill(dut)
        assert await _cycle(dut, i_req_valid=1, i_req_addr=0x100) == (1, 0, 0x100)
        if delay:
            assert await _cycle(dut) == (0, 1, 0x100)
            await _cycle(dut, i_go_taken=1)
            await _cycle(dut, i_go_taken=0, i_req_valid=0)
            for _ in range(delay):
                await _cycle(dut)
                assert not int(dut.o_instr_valid.value)
        assert await _cycle(
            dut,
            i_line_resp_valid=1,
            i_line_resp_id=request_id,
            i_line_resp_rdata=_line(0x00100093),
        ) == (0, int(delay == 0), 0x100)
        assert not int(dut.o_instr_valid.value)
        await _cycle(dut, i_go_taken=int(delay == 0), i_line_resp_valid=0)
        await _cycle(dut, i_go_taken=0, i_req_valid=0)
        await _fresh_fill(dut)


@cocotb.test()
async def test_go_clears_cached_instructions_before_release(dut: Any) -> None:
    """The target requires a fresh fill even when its old window is ready."""
    await _setup(dut)
    request_id = await _accept_fill(dut)
    await _cycle(
        dut,
        i_line_resp_valid=1,
        i_line_resp_id=request_id,
        i_line_resp_rdata=_line(0x00100093),
    )
    await _cycle(dut, i_line_resp_valid=0)
    await _wait_instruction(dut, 0x00100093)
    assert await _cycle(dut, i_req_valid=1, i_req_addr=0x100) == (1, 0, 0x100)
    assert await _cycle(dut) == (0, 1, 0x100)
    assert not int(dut.o_instr_valid.value), "GO released before the window cleared"
    await _cycle(dut, i_go_taken=1)
    await _cycle(dut, i_go_taken=0, i_req_valid=0)
    await _fresh_fill(dut)
