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
    _line_slave,
    _setup,
    _wait_window,
)


async def redirect(dut: Any, pc: int) -> None:
    """Retarget the served-window identity exactly as the core does."""
    await FallingEdge(dut.i_clk)
    _drive_pc(dut, pc)
    dut.i_retarget.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_retarget.value = 0


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
