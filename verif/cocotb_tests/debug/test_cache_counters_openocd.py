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
"""Read the cache profiling counters over OpenOCD while a program runs.

``cache_counter_target`` makes L2 write fills, prints the cache counters from
its own profiling-counter snapshot, and sleeps in wfi in low BRAM without
touching the caches until a UART byte starts a second run, which ends with a
DMA fill of a fresh region. ``fpga/debug/cache_counters.py``, with OpenOCD on
the remote_bitbang server of test_debug_openocd.py, measures a window around
that run: its command asks the bench to send the byte and returns once the
program says it is done.

The window's start, read back from the cache block's preceding bank, must be
the program's own snapshot, since nothing touched the caches in between; its
end must be the aggregator's current bank; and the deltas must be the
difference of the two banks, with a write fill for each line of the DMA fill.
The program finishing its run and answering a last UART byte afterward shows
that the hart, in a wfi loop at both halts, resumed after each.

If openocd is missing from PATH, the test warns and passes. Set
FROST_REQUIRE_OPENOCD=1 to fail instead, as CI does.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from cocotb_tests.debug.test_debug import _reset, _wait_text
from cocotb_tests.debug.test_debug_openocd import OPENOCD_CFG, RemoteBitbangServer
from cocotb_tests.test_real_program import (
    CLK_PERIOD_NS,
    UartMonitor,
    UartRxDriver,
    generate_divided_clock,
    start_cpu_clock,
)

TOOL = Path(__file__).resolve().parents[3] / "fpga" / "debug" / "cache_counters.py"
BANNER_READY = "cache_counter_target: ready"
BANNER_DONE = "cache_counter_target: done"
BANNER_DMA_ERROR = "cache_counter_target: DMA status"
BANNER_RESUMED = "cache_counter_target: resumed"
PROGRAM_SNAPSHOT_RE = re.compile(r"cache_counter_target: snapshot((?: \d+=\d+)+)")
TOOL_SNAPSHOT_RE = re.compile(r"^FROST_CACHE_SNAPSHOT time=\d+((?: \d+=\d+)+)$", re.M)
TOOL_WINDOW_RE = re.compile(
    r"^FROST_CACHE_COUNTERS cycles=(\d+)((?: \d+=-?\d+)+)$", re.M
)
AGGREGATOR = (
    "cpu_and_memory_subsystem.cpu.hart.cpu_inst.gen_perf_counters."
    "perf_counter_aggregator_inst"
)
# The cache block: global indices 106 up to the counter count.
FIRST_CACHE_INDEX = 106
CACHE_INDICES = list(range(FIRST_CACHE_INDEX, 134))
L2_ACCESS = 114
L2_WRITE_FILL = 130
L2_WRITE_FILL_CYCLES_SUM = 131
# The second run's DMA fill: 4 KiB of fresh 64-byte L2 lines, written in
# 32-byte halves, so at least one write fill per line.
DMA_FILL_LINES = 4096 // 64
# The window command: report that the window has started, then wait for the
# bench to say the program's second run is done.
WINDOW_COMMAND = """
import pathlib, sys, time
started, done = map(pathlib.Path, sys.argv[1:])
started.touch()
deadline = time.monotonic() + 3600
while not done.exists():
    if time.monotonic() > deadline:
        sys.exit("the bench never reported the second run done")
    time.sleep(0.1)
"""


def _counters(fields: str) -> dict[int, int]:
    return {
        int(index): int(value)
        for index, value in (field.split("=") for field in fields.split())
    }


def _bank(dut: Any, name: str) -> dict[int, int]:
    """Return one of the aggregator's cache snapshot banks by global index."""
    handle = dut
    for part in f"{AGGREGATOR}.{name}".split("."):
        handle = getattr(handle, part)
    return {
        index: int(handle[index - FIRST_CACHE_INDEX].value) for index in CACHE_INDICES
    }


async def _run_tool(dut: Any, openocd: str, port: int, *action: str) -> str:
    """Run cache_counters.py while the simulation runs, and return its output."""
    cmd = [
        sys.executable,
        str(TOOL),
        "--openocd",
        openocd,
        "--config",
        str(OPENOCD_CFG),
        "-c",
        f"set FROST_RBB_PORT {port}",
        # The simulated JTAG is far slower than a cable.
        "--timeout",
        "3600",
        *action,
    ]
    cocotb.log.info("launching: " + " ".join(cmd))
    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    for _ in range(40000):
        if proc.poll() is not None:
            break
        await ClockCycles(dut.i_clk, 2000)
    else:
        proc.kill()
        raise AssertionError(f"cache_counters.py {' '.join(action)} did not finish")
    output = proc.communicate()[0]
    cocotb.log.info(f"cache_counters.py {' '.join(action)}:\n{output}")
    assert proc.returncode == 0, f"cache_counters.py exited {proc.returncode}"
    return output


async def _second_run(
    dut: Any, monitor: UartMonitor, started: Path, done: Path
) -> None:
    """Start the program's second run once the window has started."""
    while not started.exists():
        await ClockCycles(dut.i_clk, 2000)
    await UartRxDriver(dut).send(b"g")
    for _ in range(10_000):
        if monitor.contains(BANNER_DONE) or monitor.contains(BANNER_DMA_ERROR):
            break
        await ClockCycles(dut.i_clk, 2000)
    assert monitor.contains(BANNER_DONE), monitor.get_output()
    done.touch()


@cocotb.test()
async def test_cache_counters_openocd(dut: Any) -> None:
    """The JTAG reader's window measures the program's second run exactly."""
    log = cocotb.log
    openocd = shutil.which("openocd")
    if openocd is None:
        message = "openocd not on PATH: the JTAG cache-counter test did not run"
        if os.environ.get("FROST_REQUIRE_OPENOCD") == "1":
            raise AssertionError(message)
        log.warning(message)
        return

    Clock(dut.i_clk, CLK_PERIOD_NS, unit="ns").start()
    start_cpu_clock(dut)
    cocotb.start_soon(generate_divided_clock(dut))
    # The window's two OpenOCD runs.
    server = RemoteBitbangServer(dut, sessions=2)
    await _reset(dut)
    monitor = UartMonitor(dut)
    await monitor.start()
    await _wait_text(monitor, dut, BANNER_READY, max_cycles=5_000_000)
    program_match = PROGRAM_SNAPSHOT_RE.search(monitor.get_output())
    assert program_match, monitor.get_output()
    program = _counters(program_match.group(1))
    assert sorted(program) == CACHE_INDICES, program
    # The program's dirty lines came back to the L2 after it lost them.
    assert program[L2_WRITE_FILL] > 0, program
    assert program[L2_WRITE_FILL_CYCLES_SUM] > program[L2_WRITE_FILL], program
    cocotb.start_soon(server.serve())

    with tempfile.TemporaryDirectory() as handshake:
        started = Path(handshake) / "started"
        done = Path(handshake) / "done"
        run = cocotb.start_soon(_second_run(dut, monitor, started, done))
        output = await _run_tool(
            dut,
            openocd,
            server.port,
            "window",
            "--",
            sys.executable,
            "-c",
            WINDOW_COMMAND,
            str(started),
            str(done),
        )
        assert run.done(), "the window ended before the second run"

    current = _bank(dut, "perf_cache_snapshot")
    previous = _bank(dut, "perf_cache_previous_snapshot")
    assert previous == program, (
        "the window did not start at the program's snapshot: "
        + str({i: (program[i], previous[i]) for i in CACHE_INDICES})
    )
    tool_match = TOOL_SNAPSHOT_RE.search(output)
    assert tool_match, output
    assert _counters(tool_match.group(1)) == current, output

    window_match = TOOL_WINDOW_RE.search(output)
    assert window_match, output
    assert int(window_match.group(1)) > 0, "the window took no cycles"
    change = _counters(window_match.group(2))
    assert change == {i: current[i] - previous[i] for i in CACHE_INDICES}, change
    assert change[L2_ACCESS] > 0, change
    assert change[L2_WRITE_FILL] >= DMA_FILL_LINES, change
    assert change[L2_WRITE_FILL_CYCLES_SUM] > change[L2_WRITE_FILL], change

    # The hart runs again after the window's last snapshot.
    await UartRxDriver(dut).send(b"r")
    await _wait_text(monitor, dut, BANNER_RESUMED, max_cycles=2_000_000)
    server.quit = True
    await ClockCycles(dut.i_clk, 200)
    log.info(f"remote_bitbang: {server.writes} pin writes, {server.reads} tdo reads")
