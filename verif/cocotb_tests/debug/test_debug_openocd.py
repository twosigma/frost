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
"""Run OpenOCD against ``debug_target`` through a localhost remote_bitbang server.

The server translates OpenOCD requests into frost JTAG pin transitions.
Board configurations in fpga/debug/ use the same dtmcs/dmi protocol over
FPGA BSCAN chains.

If OpenOCD or the cross GDB is missing from PATH, its test warns and passes. Set
FROST_REQUIRE_OPENOCD=1 to fail instead, as CI does.
"""

from __future__ import annotations

import os
import re
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

import cocotb
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
    start_clocks,
    takes_last_edge,
)

OPENOCD_CFG = Path(__file__).resolve().parents[3] / "fpga" / "debug" / "openocd_sim.cfg"
# Core clock cycles the bench advances per remote_bitbang write (TCK edge).
CYCLES_PER_EDGE = 4


class RemoteBitbangServer:
    """Serve OpenOCD remote_bitbang clients from the simulator, one at a time."""

    def __init__(self, dut: Any, sessions: int = 1) -> None:
        """Open the listening socket and park the JTAG pins.

        The server stops once `sessions` clients have sent Q.
        """
        self.dut = dut
        self.sessions = sessions
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
                    self.sessions -= 1
                    self.quit = self.sessions == 0
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
# The U-mode loop ecalls into M every 64th iteration, so most halts land in
# U. The JTAG traffic between a resume and the next halt takes a fixed time,
# which can be a whole number of loop periods and put every halt on the same
# handler instruction; idle TCK cycles that grow with each attempt move the
# halts through the loop. Exhaustion must fail here, before a write to a
# still-running target.
set priv 3
for {{set i 0}} {{$i < 64}} {{incr i}} {{
    halt
    wait_halt 2000
    set priv [dict get [get_reg -force priv] priv]
    if {{$priv == 0}} break
    resume
    runtest [expr {{29 * ($i + 1)}}]
}}
puts [format "FROST_PRIV=%d" $priv]
if {{$priv != 0}} {{error "hart did not reach U-mode within 64 halt attempts"}}
puts [format "FROST_U_POLLS=%d" [expr {{$i + 1}}]]
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
@takes_last_edge
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

    start_clocks((dut.i_clk,), CLK_PERIOD_NS * 1000)
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
    assert monitor.contains(BANNER_PHASE_U) and monitor.contains(BANNER_PASS), (
        monitor.get_output()
    )
    assert "<<FAIL>>" not in monitor.get_output()


@cocotb.test()
@takes_last_edge
async def test_debug_gdb(dut: Any) -> None:
    """Check GDB register, memory, breakpoint and step commands through OpenOCD."""
    openocd = shutil.which("openocd")
    prefix = os.environ.get("RISCV_PREFIX", "riscv64-linux-")
    gdb = shutil.which(f"{prefix}gdb")
    if openocd is None or gdb is None:
        message = "OpenOCD or cross GDB not on PATH: GDB test not run"
        if os.environ.get("FROST_REQUIRE_OPENOCD") == "1":
            raise AssertionError(message)
        cocotb.log.warning(message)
        return

    start_clocks((dut.i_clk,), CLK_PERIOD_NS * 1000)
    cocotb.start_soon(generate_divided_clock(dut))
    syms = _read_symbols()
    server = RemoteBitbangServer(dut)
    await _reset(dut)
    monitor = UartMonitor(dut)
    await monitor.start()
    await _wait_text(monitor, dut, BANNER_START)
    server_task = cocotb.start_soon(server.serve())

    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]

    with tempfile.TemporaryDirectory(prefix="frost_gdb_") as temporary:
        directory = Path(temporary)
        script = directory / "session.gdb"
        script.write_text(
            f"""set pagination off
set confirm off
set remotetimeout 120
set trust-readonly-sections on
target extended-remote 127.0.0.1:{port}
monitor halt
printf "FROST_GDB_MISA=0x%lx\\n", $misa
set $t0 = 0x1122334455667788
printf "FROST_GDB_T0=0x%lx\\n", $t0
set {{unsigned long long}}{syms["table"] + 16:#x} = 0x5a5a1234fedc9876
printf "FROST_GDB_TABLE2=0x%lx\\n", *(unsigned long long *){syms["table"] + 16:#x}
break *{syms["bp_target"]:#x}
continue
printf "FROST_GDB_BP_PC=0x%lx\\n", $pc
delete breakpoints
stepi
printf "FROST_GDB_STEP1_PC=0x%lx\\n", $pc
stepi
printf "FROST_GDB_STEP2_PC=0x%lx\\n", $pc
detach
quit
"""
        )
        openocd_path = directory / "openocd.log"
        gdb_path = directory / "gdb.log"
        command = [
            openocd,
            "-c",
            f"set FROST_RBB_PORT {server.port}",
            "-f",
            str(OPENOCD_CFG),
            "-c",
            f"bindto 127.0.0.1; gdb_port {port}; init; halt",
        ]
        gdb_proc = None
        with openocd_path.open("w") as openocd_log, gdb_path.open("w") as gdb_log:
            proc = subprocess.Popen(
                command, stdout=openocd_log, stderr=subprocess.STDOUT
            )
            try:
                started = time.monotonic()
                for _ in range(20000):
                    output = openocd_path.read_text(errors="replace")
                    assert proc.poll() is None, output
                    assert time.monotonic() - started < 120, output
                    if f"Listening on port {port} for gdb connections" in output:
                        break
                    await ClockCycles(dut.i_clk, 2000)
                else:
                    raise AssertionError("OpenOCD GDB server did not start")
                gdb_proc = subprocess.Popen(
                    [
                        gdb,
                        "-nx",
                        "-nh",
                        "-batch",
                        "../sw/apps/debug_target/sw.elf",
                        "-x",
                        str(script),
                    ],
                    stdout=gdb_log,
                    stderr=subprocess.STDOUT,
                )
                started = time.monotonic()
                for _ in range(20000):
                    if gdb_proc.poll() is not None:
                        break
                    assert time.monotonic() - started < 900, "GDB session timed out"
                    await ClockCycles(dut.i_clk, 2000)
                else:
                    raise AssertionError("GDB session did not finish")
                output = gdb_path.read_text(errors="replace")
                assert gdb_proc.returncode == 0, output
                expected = {
                    "MISA": 0x8000_0000_0014_112F,
                    "T0": 0x1122334455667788,
                    "TABLE2": 0x5A5A1234FEDC9876,
                    "BP_PC": syms["bp_target"],
                    "STEP1_PC": syms["bp_target"] + 4,
                    "STEP2_PC": syms["bp_target"] + 6,
                }
                for key, value in expected.items():
                    match = re.search(
                        rf"^FROST_GDB_{key}=(0x[0-9a-fA-F]+)$", output, re.M
                    )
                    assert match and int(match[1], 16) == value, output
            finally:
                for process in (gdb_proc, proc):
                    if process is not None and process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)
                server_task.cancel()
                if server.conn is not None:
                    server.conn.close()
                server.listener.close()
                cocotb.log.info(
                    "OpenOCD GDB server output:\n"
                    + openocd_path.read_text(errors="replace")
                )
                cocotb.log.info("GDB output:\n" + gdb_path.read_text(errors="replace"))
