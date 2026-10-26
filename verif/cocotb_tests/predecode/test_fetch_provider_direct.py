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

"""Exercise instruction-cache hits and ownership without victim-copy staging."""

from typing import Any
import cocotb
from cocotb.triggers import FallingEdge
from cocotb_tests.predecode.test_fetch_provider import (
    DDR_BASE,
    _drive_pc,
    _line_at,
    _line_slave,
    _setup,
    _wait_window,
)
from cocotb_tests.predecode.test_fetch_provider_errors import wait_fault


async def redirect(dut: Any, pc: int) -> None:
    """Retarget the served-window identity exactly as the core does."""
    await FallingEdge(dut.i_clk)
    _drive_pc(dut, pc)
    dut.i_retarget.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_retarget.value = 0


async def accept_request(dut: Any, pc: int) -> int:
    """Accept one fill while keeping its response under test control."""
    for _ in range(100):
        await FallingEdge(dut.i_clk)
        if int(dut.o_line_req_valid.value):
            assert int(dut.o_line_req_addr.value) == pc
            request_id = int(dut.o_line_req_id.value)
            dut.i_line_req_ready.value = 1
            await FallingEdge(dut.i_clk)
            dut.i_line_req_ready.value = 0
            return request_id
    raise AssertionError("fill request never issued")


async def response_during_clear(dut: Any, *, reset: bool) -> None:
    """Check that a coincident clear hides payload until a fresh fill completes."""
    await _setup(dut)
    dut.i_line_after_ok.value = 0
    pc = DDR_BASE + 0x200
    await redirect(dut, pc)
    request_id = await accept_request(dut, pc)
    dut.i_line_resp_id.value = request_id
    dut.i_line_resp_rdata.value = (1 << 256) - 1
    dut.i_line_resp_valid.value = 1
    clear = dut.i_rst if reset else dut.i_invalidate
    clear.value = 1
    await FallingEdge(dut.i_clk)
    clear.value = 0
    dut.i_line_resp_valid.value = 0
    for _ in range(10):
        await FallingEdge(dut.i_clk)
        assert not int(dut.o_instr_valid.value), "cleared response became visible"
    log: list[int] = []
    cocotb.start_soon(_line_slave(dut, 5, log))
    await _wait_window(dut, pc)
    assert log == [pc], "fetch must obtain a fresh line after the clear"


@cocotb.test()
async def invalidate_wins_over_coincident_response(dut: Any) -> None:
    """Discard a response on the invalidation edge, including its predecode."""
    await response_during_clear(dut, reset=False)


@cocotb.test()
async def reset_wins_over_coincident_response(dut: Any) -> None:
    """Discard a response on the reset edge, including its predecode."""
    await response_during_clear(dut, reset=True)


@cocotb.test()
async def failed_conflicting_fill_preserves_valid_line(dut: Any) -> None:
    """Check that a failed fill preserves a valid line at the same cache index."""
    await _setup(dut)
    dut.i_line_after_ok.value = 0
    first = DDR_BASE + 0x100
    await redirect(dut, first)
    request_id = await accept_request(dut, first)
    dut.i_line_resp_id.value = request_id
    dut.i_line_resp_rdata.value = _line_at(first)
    dut.i_line_resp_valid.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_line_resp_valid.value = 0
    await _wait_window(dut, first)
    other = first + 0x800
    await redirect(dut, other)
    request_id = await accept_request(dut, other)
    dut.i_line_resp_id.value = request_id
    dut.i_line_resp_rdata.value = (1 << 256) - 1
    dut.i_line_resp_error.value = 1
    dut.i_line_resp_valid.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_line_resp_valid.value = 0
    dut.i_line_resp_error.value = 0
    await redirect(dut, first)
    await _wait_window(dut, first)
    for _ in range(10):
        await FallingEdge(dut.i_clk)
        assert not int(dut.o_line_req_valid.value), "valid line was lost on an error"


@cocotb.test()
async def fault_window_preserves_payload_after_coincident_invalidation(
    dut: Any,
) -> None:
    """Fault-window metadata reflects the last successful write at its index."""
    await _setup(dut)
    dut.i_line_after_ok.value = 0
    first = DDR_BASE + 0x100
    other = first + 0x800
    await redirect(dut, first)
    request_id = await accept_request(dut, first)
    dut.i_line_resp_id.value = request_id
    dut.i_line_resp_rdata.value = _line_at(first)
    dut.i_line_resp_valid.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_line_resp_valid.value = 0
    await _wait_window(dut, first)
    fields = (
        "o_instr",
        "o_instr_sideband",
        "o_pc_metadata_by_parity",
        "o_pc_pairability_by_parity",
        "o_slot2_start_valid_lo_by_parity",
        "o_instr_bank_sel_r",
    )
    payload = {field: int(getattr(dut, field).value) for field in fields}
    await redirect(dut, other)
    request_id = await accept_request(dut, other)
    dut.i_line_resp_id.value = request_id
    dut.i_line_resp_rdata.value = (1 << 256) - 1
    dut.i_line_resp_valid.value = 1
    dut.i_invalidate.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_invalidate.value = 0
    dut.i_line_resp_valid.value = 0
    request_id = await accept_request(dut, other)
    dut.i_line_resp_id.value = request_id
    dut.i_line_resp_error.value = 1
    dut.i_line_resp_valid.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_line_resp_valid.value = 0
    dut.i_line_resp_error.value = 0
    await wait_fault(dut, other, 1, 1)
    for field, expected in payload.items():
        assert int(getattr(dut, field).value) == expected, field


@cocotb.test()
async def hits_conflicts_and_straddles_keep_correct_data(dut: Any) -> None:
    """Reuse cached lines, then replace the same index with a different tag."""
    await _setup(dut)
    dut.i_line_after_ok.value = 0
    log: list[int] = []
    cocotb.start_soon(_line_slave(dut, 11, log, accept_gap=3))
    first = DDR_BASE + 0x100
    other = first + 0x800
    for pc in (first, first + 28, first + 128, first + 4):
        await redirect(dut, pc)
        await _wait_window(dut, pc)
    before = len(log)
    await redirect(dut, first + 8)
    await _wait_window(dut, first + 8)
    assert len(log) == before
    await redirect(dut, other)
    await _wait_window(dut, other)
    await redirect(dut, first)
    await _wait_window(dut, first)
    assert log.count(first) == 2


@cocotb.test()
async def invalidate_discards_late_fill_and_forces_refetch(dut: Any) -> None:
    """Prevent a delayed pre-fence response from reinstalling an executable line."""
    await _setup(dut)
    dut.i_line_after_ok.value = 0
    log: list[int] = []
    pending: list[tuple[int, int]] = []
    pc = DDR_BASE + 0x200
    cocotb.start_soon(_line_slave(dut, 29, log, accept_gap=4, inflight=pending))
    await redirect(dut, pc)
    for _ in range(100):
        await FallingEdge(dut.i_clk)
        if pending:
            break
    assert pending
    dut.i_invalidate.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_invalidate.value = 0
    await _wait_window(dut, pc)
    assert log.count(pc) >= 2
    before = len(log)
    dut.i_invalidate.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_invalidate.value = 0
    await _wait_window(dut, pc)
    assert len(log) > before


@cocotb.test()
async def prefetch_stops_at_configured_executable_limit(dut: Any) -> None:
    """Contiguous translation cannot authorize a read beyond the PMA region."""
    await _setup(dut)
    log: list[int] = []
    cocotb.start_soon(_line_slave(dut, 5, log))
    pc = 0xBFFFFFE0
    await redirect(dut, pc)
    await _wait_window(dut, pc)
    for _ in range(30):
        await FallingEdge(dut.i_clk)
    assert log and all(DDR_BASE <= address < 0xC0000000 for address in log)


@cocotb.test()
async def every_word_position_and_line_crossing(dut: Any) -> None:
    """Check data and all predecode views for both parities at every offset."""
    await _setup(dut)
    dut.i_line_after_ok.value = 0
    log: list[int] = []
    cocotb.start_soon(_line_slave(dut, 7, log, accept_gap=2))
    first = DDR_BASE + 0xFE0
    for base in (first, first + 0x800, first):
        for offset in range(0, 64, 4):
            await redirect(dut, base + offset)
            await _wait_window(dut, base + offset)
