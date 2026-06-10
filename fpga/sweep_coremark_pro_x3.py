#!/usr/bin/env python3

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

"""Sweep CoreMark-PRO workloads on X3 hardware and judge each UART run.

For every requested app this script runs fpga/load_software/load_software.py
(clean rebuild with the official registry args + JTAG load) while holding the
board UART open, then applies the strict pass rule to the captured output:
``<<PASS>>`` present, no ``ERROR``/``<<FAIL>>``/``<<TRAP>>``, and every
``:fails=N`` counter zero. Each workload's ``time(secs)`` is extracted for
the summary table. Exits 0 only if every app passes.

With no app arguments, all hardware-supported workloads are swept
(from sw/apps/software_registry.py).

Examples (from the repo root):

    # -v1 validation sweep of every hardware-supported workload
    ./fpga/sweep_coremark_pro_x3.py -v1

    # -v0 performance sweep (registry-calibrated iteration counts)
    ./fpga/sweep_coremark_pro_x3.py -v0

    # Sweep a subset
    ./fpga/sweep_coremark_pro_x3.py -v0 coremark_pro_core coremark_pro_sha
"""

import argparse
import collections
import os
import re
import select
import subprocess
import sys
import termios
import time
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_DEFAULT = SCRIPT_DIR.parent

sys.path.insert(0, str(REPO_DEFAULT / "sw" / "apps"))
from software_registry import COREMARK_PRO_PROGRAMS  # noqa: E402

HW_APPS = tuple(p.app_name for p in COREMARK_PRO_PROGRAMS if p.hardware_supported)

BAUD = termios.B115200
DEFAULT_TARGET = "localhost:3121/xilinx_tcf/Xilinx/507711333S8VAA"


def configure_serial(path: str) -> int:
    """Open the UART raw/non-blocking at 115200 8N1 and flush stale bytes."""
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CLOCAL | termios.CREAD | termios.CS8
    attrs[3] = 0
    attrs[4] = BAUD
    attrs[5] = BAUD
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def drain(fd: int, seconds: float = 0.3) -> None:
    """Discard any buffered UART bytes from a previous run."""
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        readable, _, _ = select.select([fd], [], [], 0.05)
        if not readable:
            continue
        try:
            os.read(fd, 4096)
        except BlockingIOError:
            pass


def read_available(fd: int) -> bytes:
    """Read whatever the UART has buffered without blocking."""
    chunks = []
    while True:
        try:
            data = os.read(fd, 4096)
        except BlockingIOError:
            break
        if not data:
            break
        chunks.append(data)
        if len(data) < 4096:
            break
    return b"".join(chunks)


def run_one(
    repo: Path,
    serial_fd: int,
    app: str,
    mode: str,
    timeout_s: float,
    loader_extra: list[str],
    target: str,
) -> dict[str, Any]:
    """Load one app and watch the UART until a terminal marker or timeout."""
    drain(serial_fd)
    cmd = [
        "./fpga/load_software/load_software.py",
        "x3",
        app,
        mode,
        "--target",
        target,
        *loader_extra,
    ]
    proc = subprocess.Popen(
        cmd,
        cwd=repo,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    loader_tail: collections.deque[str] = collections.deque(maxlen=80)
    serial_buf = ""
    loader_done = False
    deadline = time.monotonic() + timeout_s
    terminal_seen = False

    while time.monotonic() < deadline:
        rlist: list[Any] = [serial_fd]
        if proc.stdout is not None:
            rlist.append(proc.stdout)
        readable, _, _ = select.select(rlist, [], [], 0.1)
        for item in readable:
            if item == serial_fd:
                data = read_available(serial_fd)
                if data:
                    text = data.decode("utf-8", errors="replace")
                    serial_buf += text
                    sys.stdout.write(text)
                    sys.stdout.flush()
                    if (
                        "<<PASS>>" in serial_buf
                        or "<<FAIL>>" in serial_buf
                        or "<<TRAP>>" in serial_buf
                    ):
                        terminal_seen = True
            else:
                line = proc.stdout.readline() if proc.stdout else ""
                if line:
                    loader_tail.append(line.rstrip("\n"))

        if not loader_done and proc.poll() is not None:
            loader_done = True
            if proc.stdout is not None:
                for line in proc.stdout:
                    loader_tail.append(line.rstrip("\n"))
            if proc.returncode != 0:
                return {
                    "app": app,
                    "mode": mode,
                    "status": "LOAD_FAIL",
                    "elapsed": None,
                    "serial": serial_buf,
                    "loader_tail": list(loader_tail),
                }

        if loader_done and terminal_seen:
            break

    if not loader_done and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()

    fail_values = [int(x) for x in re.findall(r":fails=(\d+)", serial_buf)]
    has_pass = "<<PASS>>" in serial_buf
    has_fail = "<<FAIL>>" in serial_buf
    has_trap = "<<TRAP>>" in serial_buf
    has_error = re.search(r"\bERROR\b", serial_buf) is not None
    nonzero_fails = any(value != 0 for value in fail_values)
    if (
        has_pass
        and not has_fail
        and not has_trap
        and not has_error
        and not nonzero_fails
    ):
        status = "PASS"
    elif terminal_seen:
        status = "FAIL"
    else:
        status = "TIMEOUT"

    workload_time = None
    match = re.search(r"-- [^:\r\n]+:time\(secs\)=\s*([0-9.]+)", serial_buf)
    if match:
        workload_time = float(match.group(1))

    return {
        "app": app,
        "mode": mode,
        "status": status,
        "elapsed": workload_time,
        "serial": serial_buf,
        "loader_tail": list(loader_tail),
    }


def main() -> int:
    """Run the sweep and print the summary table."""
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode_group = parser.add_mutually_exclusive_group(required=True)
    mode_group.add_argument(
        "-v0",
        dest="mode",
        action="store_const",
        const="-v0",
        help="performance/score sweep (registry-calibrated iterations)",
    )
    mode_group.add_argument(
        "-v1",
        dest="mode",
        action="store_const",
        const="-v1",
        help="validation sweep (official result checking)",
    )
    parser.add_argument(
        "--repo",
        type=Path,
        default=REPO_DEFAULT,
        help=f"FROST repo root (default: {REPO_DEFAULT})",
    )
    parser.add_argument(
        "--serial",
        default="/dev/ttyUSB2",
        help="Board UART device (default: /dev/ttyUSB2)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=300.0,
        help="Per-app timeout in seconds, build included (default: 300)",
    )
    parser.add_argument(
        "--loader-extra",
        action="append",
        default=[],
        help="Extra argument to append to every load_software.py invocation",
    )
    parser.add_argument(
        "--target",
        default=DEFAULT_TARGET,
        help="JTAG hardware target pattern passed to the loader",
    )
    parser.add_argument(
        "apps",
        nargs="*",
        default=None,
        help=f"coremark_pro_* app names to sweep (default: {' '.join(HW_APPS)})",
    )
    args = parser.parse_args()

    apps = list(args.apps) if args.apps else list(HW_APPS)
    unknown = [a for a in apps if a not in {p.app_name for p in COREMARK_PRO_PROGRAMS}]
    if unknown:
        parser.error(f"unknown app(s): {', '.join(unknown)}")

    fd = configure_serial(args.serial)
    results = []
    try:
        for app in apps:
            print(f"\n===== {app} {args.mode} =====", flush=True)
            result = run_one(
                args.repo,
                fd,
                app,
                args.mode,
                args.timeout,
                args.loader_extra,
                args.target,
            )
            results.append(result)
            print(
                f"\nRESULT {result['app']} {result['mode']}: {result['status']} "
                f"time={result['elapsed']}",
                flush=True,
            )
            if result["status"] == "LOAD_FAIL":
                print("loader tail:", flush=True)
                print("\n".join(result["loader_tail"]), flush=True)
    finally:
        os.close(fd)

    bad = [r for r in results if r["status"] != "PASS"]
    print("\nSUMMARY")
    for r in results:
        print(f"{r['app']} {r['mode']} {r['status']} time={r['elapsed']}")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
