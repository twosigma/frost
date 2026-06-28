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

"""fence.i maintenance cycle-count measurement (frost_cache_test_harness DUT).

Drives the cache hierarchy at the real L1 geometry (128 KiB D-side / 16 KiB
I-side, set via -G in the registry), dirties a handful of D-side lines, then
issues one fence.i cache-sync handshake and counts the cycles from sync-assert
to done. Run the two registry builds to see the speedup directly:

    ./test_run_cocotb.py fence_speed_slow   # SIM_FAST_MAINT=0 (FPGA-path FSM)
    ./test_run_cocotb.py fence_speed_fast   # SIM_FAST_MAINT=1 (fast sim path)

The slow build walks every line (writeback-all over 4096 lines + invalidate-all
over 512 lines, ~thousands of cycles); the fast build touches only the dirty
lines and bulk-clears the tags (low hundreds or fewer). The measured count is
logged as `FENCE_I_MAINT_CYCLES=<n>` for easy comparison.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

CLOCK_PERIOD_NS = 10
LINE_BYTES = 32
BASE_ADDR = 0x8000_0000

# Generous: the slow reset sweep walks every L1 line (4096) before ready.
READY_TIMEOUT_CYCLES = 100_000
RESP_TIMEOUT_CYCLES = 20_000
FENCE_TIMEOUT_CYCLES = 200_000

# Number of distinct dirty D-side lines to publish before the fence.
NUM_DIRTY_LINES = 16


def _clear_inputs(dut: Any) -> None:
    dut.i_up_req_valid.value = 0
    dut.i_up_req_write.value = 0
    dut.i_up_req_addr.value = 0
    dut.i_up_req_wdata.value = 0
    dut.i_up_req_wstrb.value = 0
    dut.i_iup_req_valid.value = 0
    dut.i_iup_req_write.value = 0
    dut.i_iup_req_addr.value = 0
    dut.i_iup_req_wdata.value = 0
    dut.i_iup_req_wstrb.value = 0
    dut.i_fence_sync.value = 0


async def _setup(dut: Any) -> None:
    """Start the clock, reset, and wait out the tag-invalidate sweep."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    dut.i_rst.value = 1
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    for _ in range(READY_TIMEOUT_CYCLES):
        await FallingEdge(dut.i_clk)
        if int(dut.o_up_req_ready.value) == 1 and int(dut.o_iup_req_ready.value) == 1:
            return
    raise AssertionError("cache never became ready after reset (sweep stuck?)")


async def _write_line(dut: Any, addr: int, wdata: int) -> None:
    """Whole-line D-side write (dirties the line in L1)."""
    full = (1 << LINE_BYTES) - 1
    await FallingEdge(dut.i_clk)
    dut.i_up_req_valid.value = 1
    dut.i_up_req_write.value = 1
    dut.i_up_req_addr.value = addr
    dut.i_up_req_wdata.value = wdata
    dut.i_up_req_wstrb.value = full
    for _ in range(RESP_TIMEOUT_CYCLES):
        if int(dut.o_up_req_ready.value) == 1:
            break
        await FallingEdge(dut.i_clk)
    else:
        raise AssertionError(f"write never accepted (addr=0x{addr:08x})")
    await FallingEdge(dut.i_clk)
    dut.i_up_req_valid.value = 0
    dut.i_up_req_write.value = 0
    for _ in range(RESP_TIMEOUT_CYCLES):
        if int(dut.o_up_resp_valid.value) == 1:
            return
        await FallingEdge(dut.i_clk)
    raise AssertionError(f"no write response (addr=0x{addr:08x})")


async def _measure_fence_cycles(dut: Any) -> int:
    """Assert i_fence_sync and count cycles until o_fence_done rises."""
    await FallingEdge(dut.i_clk)
    dut.i_fence_sync.value = 1
    cycles = 0
    for _ in range(FENCE_TIMEOUT_CYCLES):
        await RisingEdge(dut.i_clk)
        cycles += 1
        if int(dut.o_fence_done.value) == 1:
            break
    else:
        raise AssertionError("fence sync never completed")
    await FallingEdge(dut.i_clk)
    dut.i_fence_sync.value = 0
    await FallingEdge(dut.i_clk)
    return cycles


@cocotb.test()
async def test_fence_i_maintenance_cycles(dut: Any) -> None:
    """Dirty several lines, fence, and report the maintenance cycle count."""
    await _setup(dut)

    for i in range(NUM_DIRTY_LINES):
        addr = BASE_ADDR + i * LINE_BYTES
        wdata = int.from_bytes(bytes([(i * 7 + b) & 0xFF for b in range(32)]), "little")
        await _write_line(dut, addr, wdata)

    cycles = await _measure_fence_cycles(dut)
    dut._log.info(
        f"FENCE_I_MAINT_CYCLES={cycles} (dirty_lines={NUM_DIRTY_LINES}, "
        f"L1=128KiB/4096 lines, L1I=16KiB/512 lines)"
    )

    # Sanity only: completion within the timeout. The slow vs fast comparison is
    # read from the logged FENCE_I_MAINT_CYCLES line across the two builds.
    assert cycles < FENCE_TIMEOUT_CYCLES, "fence.i maintenance did not complete"
