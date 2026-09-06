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
"""OpenOCD in the loop (Phase 3 M3).

The bench serves OpenOCD's `remote_bitbang` protocol on a localhost TCP port
and toggles frost's JTAG pins on OpenOCD's behalf, so a real `openocd`
(the pinned container image installs it) examines the debug module and runs
a scripted session against `debug_target`: halt, read/write registers and
memory (the program observes the writes), plant a software breakpoint,
resume to it, single-step, resume to the pass banner, and `reset halt`.
This is the debug module's acceptance test proper: hardware bring-up runs
the same protocol over the boards' BSCAN chains (fpga/debug/).

Without `openocd` on PATH the test logs a warning and passes; set
FROST_REQUIRE_OPENOCD=1 to make that a failure (CI does).
"""

from __future__ import annotations

import os
import re
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from cocotb_tests.debug.test_debug import (
    BANNER_PASS,
    BANNER_PHASE_U,
    BANNER_START,
    _read_symbols,
    _reset,
    _wait_text,
)
from cocotb_tests.test_real_program import (
    CLK_PERIOD_NS,
    UartMonitor,
    generate_divided_clock,
)

OPENOCD_CFG = Path(__file__).resolve().parents[3] / "fpga" / "debug" / "openocd_sim.cfg"
# Core clock cycles the bench advances per remote_bitbang write (TCK edge).
CYCLES_PER_EDGE = 4


class RemoteBitbangServer:
    """Serve one OpenOCD remote_bitbang client from the simulator."""

    def __init__(self, dut: Any) -> None:
        """Open the listening socket and park the JTAG pins."""
        self.dut = dut
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.listener.setblocking(False)
        self.port = self.listener.getsockname()[1]
        self.conn: socket.socket | None = None
        self.quit = False
        self.writes = 0
        self.reads = 0
        dut.i_jtag_tck.value = 0
        dut.i_jtag_tms.value = 0
        dut.i_jtag_tdi.value = 0
        dut.i_jtag_trst_n.value = 1

    async def serve(self) -> None:
        """Translate remote_bitbang bytes to pin wiggles until Q arrives."""
        clk = self.dut.i_clk
        while not self.quit:
            if self.conn is None:
                try:
                    self.conn, _ = self.listener.accept()
                    self.conn.setblocking(False)
                except BlockingIOError:
                    await ClockCycles(clk, 50)
                    continue
            try:
                data = self.conn.recv(4096)
            except BlockingIOError:
                await ClockCycles(clk, 8)
                continue
            if not data:
                self.conn.close()
                self.conn = None
                continue
            responses = bytearray()
            for byte in data:
                c = chr(byte)
                if "0" <= c <= "7":
                    v = ord(c) - ord("0")
                    self.dut.i_jtag_tck.value = (v >> 2) & 1
                    self.dut.i_jtag_tms.value = (v >> 1) & 1
                    self.dut.i_jtag_tdi.value = v & 1
                    self.writes += 1
                    await ClockCycles(clk, CYCLES_PER_EDGE)
                elif c == "R":
                    responses.append(
                        ord("1") if int(self.dut.o_jtag_tdo.value) else ord("0")
                    )
                    self.reads += 1
                elif "r" <= c <= "u":
                    trst = ((ord(c) - ord("r")) >> 1) & 1
                    self.dut.i_jtag_trst_n.value = 0 if trst else 1
                    await ClockCycles(clk, CYCLES_PER_EDGE)
                elif c == "Q":
                    self.quit = True
                # 'B'/'b' blink: ignored
            if responses:
                self.conn.sendall(bytes(responses))
        if self.conn is not None:
            self.conn.close()
        self.listener.close()


def _session_script(syms: dict[str, int]) -> str:
    bp = syms["bp_target"]
    return f"""
init
puts "FROST_TARGETS=[target names]"
halt
wait_halt 2000
set pc0 [dict get [get_reg -force pc] pc]
puts [format "FROST_HALT_PC=0x%x" $pc0]
set misa [dict get [get_reg -force misa] misa]
puts [format "FROST_MISA=0x%x" $misa]
set_reg {{t0 0x1122334455667788}}
puts [format "FROST_T0=0x%x" [dict get [get_reg -force t0] t0]]
set flag_before [lindex [read_memory {syms["flag"]:#x} 64 1] 0]
puts [format "FROST_FLAG0=0x%x" $flag_before]
write_memory {syms["table"] + 16:#x} 64 {{0xa5a5a5a5a5a5a5a5}}
puts [format "FROST_TABLE2=0x%x" [lindex [read_memory {syms["table"] + 16:#x} 64 1] 0]]
bp {bp:#x} 4
resume
wait_halt 5000
set pc1 [dict get [get_reg -force pc] pc]
puts [format "FROST_BP_PC=0x%x" $pc1]
rbp {bp:#x}
step
puts [format "FROST_STEP1_PC=0x%x" [dict get [get_reg -force pc] pc]]
step
puts [format "FROST_STEP2_PC=0x%x" [dict get [get_reg -force pc] pc]]
write_memory {syms["flag"]:#x} 64 {{1}}
resume
sleep 20
# The U-mode loop ecalls into an M-mode handler every 64th iteration; halt
# again until the halt lands in U (priv 0).
set priv 3
for {{set i 0}} {{$i < 8}} {{incr i}} {{
    halt
    wait_halt 2000
    set priv [dict get [get_reg -force priv] priv]
    if {{$priv == 0}} break
    resume
    sleep 5
}}
puts [format "FROST_PRIV=%d" $priv]
write_memory {syms["flag"]:#x} 64 {{2}}
resume
sleep 50
halt
wait_halt 2000
puts [format "FROST_WFI_PC=0x%x" [dict get [get_reg -force pc] pc]]
reset halt
puts [format "FROST_RESET_PC=0x%x" [dict get [get_reg -force pc] pc]]
resume
shutdown
"""


@cocotb.test()
async def test_debug_openocd(dut: Any) -> None:
    """Run a real OpenOCD session against the simulated hart."""
    log = cocotb.log
    openocd = shutil.which("openocd")
    if openocd is None:
        message = "openocd not on PATH: OpenOCD-in-the-loop test not run"
        if os.environ.get("FROST_REQUIRE_OPENOCD") == "1":
            raise AssertionError(message)
        log.warning(message)
        return

    Clock(dut.i_clk, CLK_PERIOD_NS, unit="ns").start()
    cocotb.start_soon(generate_divided_clock(dut))
    syms = _read_symbols()
    server = RemoteBitbangServer(dut)
    await _reset(dut)
    monitor = UartMonitor(dut)
    await monitor.start()
    await _wait_text(monitor, dut, BANNER_START)
    cocotb.start_soon(server.serve())

    with tempfile.NamedTemporaryFile("w", suffix=".tcl", delete=False) as script:
        script.write(_session_script(syms))
        script_path = script.name
    cmd = [
        openocd,
        "-c",
        f"set FROST_RBB_PORT {server.port}",
        "-f",
        str(OPENOCD_CFG),
        "-f",
        script_path,
    ]
    log.info("launching: " + " ".join(cmd))
    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )

    # Let the simulator run while OpenOCD works; poll the process.
    output = ""
    for _ in range(20000):
        if proc.poll() is not None:
            break
        await ClockCycles(dut.i_clk, 2000)
    else:
        proc.kill()
        raise AssertionError("openocd session did not finish")
    output = proc.communicate()[0]
    server.quit = True
    await ClockCycles(dut.i_clk, 200)
    Path(script_path).unlink(missing_ok=True)
    log.info("openocd output:\n" + output)
    assert proc.returncode == 0, f"openocd exited {proc.returncode}"
    log.info(f"remote_bitbang: {server.writes} pin writes, {server.reads} tdo reads")

    def value(key: str) -> int:
        match = re.search(rf"^{key}=(0x[0-9a-fA-F]+|\d+)$", output, re.M)
        assert match, f"{key} missing from openocd output"
        return int(match.group(1), 0)

    errors = [line for line in output.splitlines() if line.startswith("Error: ")]
    assert not errors, "openocd reported errors: " + "; ".join(errors)
    assert re.search(
        r"Info : Listening|Info : \S+: hart 0|Examined RISC-V core", output
    ), output
    assert value("FROST_MISA") == 0x8000_0000_0014_112F
    assert value("FROST_T0") == 0x1122334455667788
    assert value("FROST_TABLE2") == 0xA5A5A5A5A5A5A5A5
    bp = syms["bp_target"]
    assert value("FROST_BP_PC") == bp
    assert value("FROST_STEP1_PC") == bp + 4
    assert value("FROST_STEP2_PC") == bp + 6
    assert value("FROST_PRIV") == 0, "the halt after flag=1 should land in U-mode"
    assert value("FROST_RESET_PC") < 0x1000
    assert monitor.contains(BANNER_PHASE_U) and monitor.contains(
        BANNER_PASS
    ), monitor.get_output()
    assert "<<FAIL>>" not in monitor.get_output()
