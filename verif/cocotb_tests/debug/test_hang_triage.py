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

"""Unit tests for hang_triage (hw/rtl/cpu_and_mem/hang_triage.sv).

The registry builds the module with short quiet and re-emit windows. Checked:
a quiet console starts a snapshot that begins with the "!!HANG" prefix, and
the takeover never shares an edge with a CPU byte entering the console, the
case in which cpu_and_mem's output mux would drop that byte.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

CLOCK_PERIOD_NS = 10
QUIET_CYCLES = 40  # -GQUIET_CYCLES in the registry entry
INPUTS = (
    "i_commit",
    "i_timer_event",
    "i_cread_req",
    "i_cread_resp",
    "i_cwrite_req",
    "i_cwrite_done",
    "i_pc",
    "i_commit0_valid",
    "i_commit0_pc",
    "i_commit1_valid",
    "i_commit1_pc",
    "i_mtime_lo",
    "i_mtime_hi",
    "i_mtimecmp_lo",
    "i_mtimecmp_hi",
    "i_mtimecmp_delta_lo",
    "i_irq_status",
    "i_uart_busy",
)


async def _start(dut: Any) -> None:
    """Start the clock, drive every input idle with the FIFO ready, and reset."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    for name in INPUTS:
        getattr(dut, name).value = 0
    dut.i_uart_ready.value = 1
    dut.i_rst.value = 1
    for _ in range(3):
        await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0


@cocotb.test()
async def test_quiet_console_starts_a_snapshot(dut: Any) -> None:
    """After QUIET_CYCLES without a CPU byte the block takes over and prints a newline, then "!!HANG"."""
    await _start(dut)
    emitted: list[int] = []
    for _ in range(QUIET_CYCLES + 40):
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        if int(dut.o_wr_en.value):
            emitted.append(int(dut.o_wr_data.value))
        if len(emitted) == 8:
            break
    assert int(dut.o_active.value) == 1, "the block never took over the console"
    assert bytes(emitted) == b"\n!!HANG ", f"unexpected prefix {bytes(emitted)!r}"


@cocotb.test()
async def test_takeover_waits_for_an_edge_without_a_cpu_byte(dut: Any) -> None:
    """A CPU byte entering the console on the deciding edge holds off the takeover."""
    await _start(dut)
    # Wait for the deciding cycle: the quiet count has reached the threshold.
    for _ in range(QUIET_CYCLES + 10):
        await FallingEdge(dut.i_clk)
        if int(dut.quiet_cnt.value) >= QUIET_CYCLES:
            break
    else:
        raise AssertionError("the quiet count never reached the threshold")
    dut.i_uart_busy.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_uart_busy.value = 0
    assert int(dut.o_active.value) == 0, (
        "the block took over on the edge a CPU byte entered the console"
    )
    assert int(dut.quiet_cnt.value) == 0, "the CPU byte did not restart the quiet timer"


@cocotb.test()
async def test_takeover_never_shares_an_edge_with_a_cpu_byte(dut: Any) -> None:
    """Under random CPU bytes near the threshold, o_active rises only after a quiet edge."""
    await _start(dut)
    rng = random.Random(0x7A1A6E)
    takeovers = 0
    active_prev = int(dut.o_active.value)
    for _ in range(6000):
        # Single bytes separated by gaps around the quiet threshold. The edge
        # that samples this byte is the one that may raise o_active.
        busy = int(rng.random() < 0.02)
        dut.i_uart_busy.value = busy
        await FallingEdge(dut.i_clk)
        active = int(dut.o_active.value)
        if active and not active_prev:
            takeovers += 1
            assert not busy, "the takeover shared an edge with a CPU byte"
        active_prev = active
    assert takeovers > 0, "the random pattern never let the block take over"
