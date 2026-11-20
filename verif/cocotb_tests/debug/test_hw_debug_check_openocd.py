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
"""Run the debug-port check of ``fpga/hw_regression.py`` on the simulated core.

``fpga/debug/hw_debug_check.tcl`` is what ``fpga/hw_regression.py``'s
``debug_port`` stage runs on the board. Here OpenOCD runs it on the
remote_bitbang server of test_debug_openocd.py, with the simulation's
configuration in place of the board's, and the stage's own verdict function
judges the transcript. The simulated debug module is the board's, behind a
standard five-bit-IR TAP. ``cache_counter_target`` sleeps in wfi after it
prints its banner, so the hart is running when the check starts. After each
check the program must answer a UART byte (the first starts its second run
and the second ends it), which shows that the hart was resumed. The second
check finds the hart running again, and the resume-only procedure is run last
and must find nothing to do. Both readings of dtmcs must agree.

If openocd is missing from PATH, the test warns and passes. Set
FROST_REQUIRE_OPENOCD=1 to fail instead, as CI does.
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import subprocess
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

REPO = Path(__file__).resolve().parents[3]
BANNER_READY = "cache_counter_target: ready"
BANNER_DONE = "cache_counter_target: done"
BANNER_RESUMED = "cache_counter_target: resumed"


def _load_hw_regression() -> Any:
    """Import fpga/hw_regression.py by path (it is a script, not a package)."""
    spec = importlib.util.spec_from_file_location(
        "hw_regression", REPO / "fpga" / "hw_regression.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


async def _run_openocd(dut: Any, command: list[str]) -> tuple[str, str]:
    """Run OpenOCD while the simulation runs, and return its stdout and stderr.

    The script's transcript is on stdout; OpenOCD's own log, on stderr, goes
    to a file and is logged.
    """
    cocotb.log.info("launching: " + " ".join(command))
    log = tempfile.TemporaryFile("w+")
    proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=log, text=True)
    for _ in range(40000):
        if proc.poll() is not None:
            break
        await ClockCycles(dut.i_clk, 2000)
    else:
        proc.kill()
        raise AssertionError("OpenOCD did not finish")
    output = proc.communicate()[0]
    log.seek(0)
    stderr = log.read()
    cocotb.log.info(f"OpenOCD stdout:\n{output}\nOpenOCD log:\n{stderr}")
    log.close()
    assert proc.returncode == 0, f"OpenOCD exited {proc.returncode}"
    return output, stderr


@cocotb.test()
async def test_hw_debug_check_openocd(dut: Any) -> None:
    """The board's debug-port check passes on the simulated core, twice."""
    log = cocotb.log
    openocd = shutil.which("openocd")
    if openocd is None:
        message = "openocd not on PATH: the debug-port check test did not run"
        if os.environ.get("FROST_REQUIRE_OPENOCD") == "1":
            raise AssertionError(message)
        log.warning(message)
        return
    hw = _load_hw_regression()

    Clock(dut.i_clk, CLK_PERIOD_NS, unit="ns").start()
    start_cpu_clock(dut)
    cocotb.start_soon(generate_divided_clock(dut))
    # Two checks and the resume-only procedure.
    server = RemoteBitbangServer(dut, sessions=3)
    await _reset(dut)
    monitor = UartMonitor(dut)
    await monitor.start()
    await _wait_text(monitor, dut, BANNER_READY, max_cycles=5_000_000)
    cocotb.start_soon(server.serve())

    def command(procedure: str) -> list[str]:
        return hw.debug_openocd_command(
            openocd,
            REPO,
            OPENOCD_CFG.relative_to(REPO),
            procedure,
            setup=[f"set FROST_RBB_PORT {server.port}"],
        )

    # The program's answer to the byte sent after each check.
    for attempt, banner in ((1, BANNER_DONE), (2, BANNER_RESUMED)):
        output, stderr = await _run_openocd(dut, command("frost_debug_check"))
        ok, note = hw.judge_debug_output(output)
        assert ok, f"check {attempt}: {note}\n{output}"
        assert hw._find_error_marker(stderr) is None, stderr
        values = hw.debug_values(output)
        assert values["state_before"] == "running", output
        assert values["state_left"] == "running", output
        # Polling is off during the raw scans, so both readings agree.
        assert values["dtmcs"] == values["dtmcs_after"], output
        # The hart really is back: it answers a UART byte.
        await UartRxDriver(dut).send(b"g")
        await _wait_text(monitor, dut, banner, max_cycles=10_000_000)

    output, stderr = await _run_openocd(dut, command("frost_debug_recover"))
    ok, note = hw.judge_debug_recovery(output, stderr, False, 0)
    assert ok, f"recover: {note}\n{output}\n{stderr}"
    server.quit = True
    await ClockCycles(dut.i_clk, 200)
    log.info(f"remote_bitbang: {server.writes} pin writes, {server.reads} tdo reads")
