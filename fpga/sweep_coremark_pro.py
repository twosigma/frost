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

"""Sweep CoreMark-PRO workloads on FROST hardware and judge each UART run.

For every requested app this script runs fpga/load_software/load_software.py
(clean rebuild with the official registry args + JTAG load) on the selected
board while holding the board UART open, then applies the strict pass rule to
the captured output: ``<<PASS>>`` present, no ``ERROR``/``<<FAIL>>``/``<<TRAP>>``,
and every ``:fails=N`` counter zero. Each workload's ``time(secs)`` and
``iterations`` are extracted and reduced to iter/s for the summary table.
Exits 0 only if every app passes.

A full passing -v0 sweep also reports the official CoreMark-PRO score: each
workload's iter/s is multiplied by its scale factor and divided by its
reference-platform score, and the mark is 1000 x the geometric mean of the
nine normalized results (EEMBC Symmetric Multicore Benchmark User Guide 2.1.4
sec. 4.4 p.12, identical to coremark-pro's util/perl/cert_mark.pl). FROST is
single-core, so the single-context result is both the SingleCore and MultiCore
mark. -v1 sweeps print iter/s but no score (verification runs are not
score-eligible), and -v0 workloads finishing under the ~10s score-rule minimum
get a warning to recalibrate their registry iteration count.

The target board is chosen with the required ``--board`` flag (``x3`` or
``genesys2``); both expose all nine hardware-supported workloads. With no app
arguments, every hardware-supported workload is swept (from
sw/apps/software_registry.py).

The UART device (``--serial``) and JTAG target (``--target``) default per board
(X3: /dev/ttyUSB2; genesys2: /dev/ttyUSB0); override either with its flag.
The sweep refuses to start while another process holds the UART open, and
holds the port in exclusive mode (TIOCEXCL) while running -- a second reader
(e.g. a forgotten minicom) would silently steal chunks of the capture.

Examples (from the repo root):

    # -v1 validation sweep of every hardware-supported workload on X3
    ./fpga/sweep_coremark_pro.py --board x3 -v1

    # -v0 performance sweep on genesys2 (registry-calibrated iteration counts)
    ./fpga/sweep_coremark_pro.py --board genesys2 -v0

    # Sweep a subset on X3
    ./fpga/sweep_coremark_pro.py --board x3 -v0 coremark_pro_core coremark_pro_sha
"""

import argparse
import collections
import fcntl
import glob
import math
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
from software_registry import (  # noqa: E402
    COREMARK_PRO_PROGRAM_BY_APP,
    COREMARK_PRO_PROGRAMS,
)

HW_APPS = tuple(p.app_name for p in COREMARK_PRO_PROGRAMS if p.hardware_supported)

BAUD = termios.B115200

# Default JTAG target pattern per board, passed through to load_software.py
# (which vendor-filters by board first, then matches this pattern). X3 pins the
# lab board's exact Xilinx serial; genesys2 falls back to the "Digilent" vendor
# substring, which resolves to the sole Digilent target. Pass --target when more
# than one board of a vendor is attached.
DEFAULT_TARGETS = {
    "x3": "localhost:3121/xilinx_tcf/Xilinx/507711333S8VAA",
    "genesys2": "Digilent",
}

# Default UART device per board (override with --serial).
DEFAULT_SERIALS = {
    "x3": "/dev/ttyUSB2",
    "genesys2": "/dev/ttyUSB0",
}

# Default per-app timeout (seconds, build included) per board. genesys2 runs at
# ~133 MHz vs X3's ~300 MHz, so the X3-calibrated workloads take roughly twice
# as long -- double the budget. Override with --timeout.
DEFAULT_TIMEOUTS = {
    "x3": 300.0,
    "genesys2": 600.0,
}

# Sentinel printed by load_software.tcl once the image is fully loaded and the
# CPU is about to run. Anything received on the UART before the loader emits
# this line is stale output from the previously loaded program, so run_one
# resets its capture (serial_buf and the terminal-marker flag) at this point to
# avoid misreading a prior run's <<PASS>>/time as this run's result.
LOAD_COMPLETE_SENTINEL = "FROST_LOAD_COMPLETE"

# Official CoreMark-PRO scoring constants: workload -> (scale factor,
# reference-platform score), from the EEMBC Symmetric Multicore Benchmark User
# Guide 2.1.4 sec. 4.4 Figure 10 and coremark-pro util/perl/cert_mark.pl (the
# two agree). A workload's normalized result is iter/s * scale / reference,
# and the mark is 1000 x the geometric mean of the nine normalized results.
COREMARK_PRO_REFERENCE = {
    "cjpeg-rose7-preset": (1.0, 40.3438),
    "core": (10000.0, 2855.0),
    "linear_alg-mid-100x100-sp": (1.0, 38.5624),
    "loops-all-mid-10k-sp": (1.0, 0.87959),
    "nnet_test": (1.0, 1.45853),
    "parser-125k": (1.0, 4.81116),
    "radix2-big-64k": (1.0, 99.6587),
    "sha-test": (1.0, 48.5201),
    "zip-test": (1.0, 21.3618),
}

# Minimum -v0 workload runtime for an official score run; the registry
# calibrates each workload's iteration count to clear this.
SCORE_RULE_MIN_SECS = 10.0

# mith prints time(secs) with %8g: usually plain decimal, but accept the
# exponent form %g falls back to for extreme values.
MITH_NUMBER = r"([0-9]+(?:\.[0-9]*)?(?:[eE][+-]?[0-9]+)?)"


def parse_workload_perf(serial_buf: str, workload: str) -> dict[str, Any]:
    """Extract the workload-level iterations/time(secs) pair and derive iter/s.

    Mirrors coremark-pro's util/perl/results_parser.pl (iter/s = iterations /
    time(secs)). Anchoring on the official workload name keeps -v1 per-item
    lines out of the match: mith prints the workload-level block first, and
    only that block has an ``iterations=`` line.
    """
    name = re.escape(workload)
    iters_match = re.search(rf"-- {name}:iterations=([0-9]+)", serial_buf)
    secs_match = re.search(rf"-- {name}:time\(secs\)=\s*{MITH_NUMBER}", serial_buf)
    iterations = int(iters_match.group(1)) if iters_match else None
    secs = float(secs_match.group(1)) if secs_match else None
    ips = None
    if iterations and secs and secs > 0:
        ips = iterations / secs
    return {"iterations": iterations, "secs": secs, "ips": ips}


def coremark_pro_mark(
    ips_by_workload: dict[str, float],
) -> tuple[float | None, list[str]]:
    """Compute the official CoreMark-PRO mark from per-workload iter/s.

    Returns (mark, []) when every official workload has a positive iter/s,
    else (None, sorted missing workload names) -- the mark is only defined
    over the full set of nine.
    """
    missing = sorted(
        workload
        for workload in COREMARK_PRO_REFERENCE
        if not ips_by_workload.get(workload)
    )
    if missing:
        return None, missing
    log_sum = 0.0
    for workload, (scale, reference) in COREMARK_PRO_REFERENCE.items():
        log_sum += math.log(ips_by_workload[workload] * scale / reference)
    return 1000.0 * math.exp(log_sum / len(COREMARK_PRO_REFERENCE)), []


def serial_holders(path: str) -> list[str]:
    """Return 'pid: cmdline' for other processes holding the serial device.

    The tty layer delivers each received byte to exactly one reader, so a
    second attached process (a forgotten minicom, an old capture script)
    steals random chunks of the UART stream and silently corrupts the
    sweep's capture. Scans /proc, so it only sees same-user processes.
    """
    try:
        target = os.stat(path).st_rdev
    except OSError:
        return []
    holders = set()
    for fd_link in glob.glob("/proc/[0-9]*/fd/*"):
        pid = fd_link.split("/")[2]
        if pid == str(os.getpid()):
            continue
        try:
            if os.stat(fd_link).st_rdev != target:
                continue
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmdline = f.read().replace(b"\0", b" ").decode().strip()
        except OSError:
            continue
        holders.add(f"pid {pid}: {cmdline or '<unknown>'}")
    return sorted(holders)


def configure_serial(path: str) -> int:
    """Open the UART raw/non-blocking at 115200 8N1 and flush stale bytes.

    The port is put in exclusive mode (TIOCEXCL) so a terminal opened
    mid-sweep gets EBUSY instead of silently stealing capture bytes.
    """
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    fcntl.ioctl(fd, termios.TIOCEXCL)
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
    board: str,
    app: str,
    mode: str,
    timeout_s: float,
    loader_extra: list[str],
    target: str,
) -> dict[str, Any]:
    """Load one app on the given board and watch the UART until a marker/timeout."""
    program = COREMARK_PRO_PROGRAM_BY_APP.get(app)
    workload = program.workload if program else None
    drain(serial_fd)
    cmd = [
        "./fpga/load_software/load_software.py",
        board,
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

    # Read the loader's stdout through its raw fd (nonblocking) rather than
    # buffered readline(): mixing readline() with select() lets Python read
    # ahead into its own buffer, so the load-complete sentinel could sit unseen
    # until the process exits -- by which point fresh program output may already
    # have been captured and would be wrongly discarded by the reset.
    loader_fd = proc.stdout.fileno() if proc.stdout is not None else None
    if loader_fd is not None:
        os.set_blocking(loader_fd, False)

    loader_tail: collections.deque[str] = collections.deque(maxlen=80)
    loader_line_buf = ""
    serial_buf = ""
    loader_done = False
    deadline = time.monotonic() + timeout_s
    terminal_seen = False
    program_started = False

    def consume_loader(text: str) -> None:
        """Split loader stdout into lines; reset capture at the load sentinel."""
        nonlocal loader_line_buf, program_started, serial_buf, terminal_seen
        loader_line_buf += text
        while "\n" in loader_line_buf:
            line, loader_line_buf = loader_line_buf.split("\n", 1)
            loader_tail.append(line)
            if not program_started and LOAD_COMPLETE_SENTINEL in line:
                # Everything received before the freshly loaded image starts
                # running is stale output from the previous program; drop it.
                program_started = True
                serial_buf = ""
                terminal_seen = False

    while time.monotonic() < deadline:
        rlist: list[Any] = [serial_fd]
        if loader_fd is not None and not loader_done:
            rlist.append(loader_fd)
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
                data = read_available(loader_fd)
                if data:
                    consume_loader(data.decode("utf-8", errors="replace"))

        if not loader_done and proc.poll() is not None:
            loader_done = True
            if loader_fd is not None:
                while True:
                    data = read_available(loader_fd)
                    if not data:
                        break
                    consume_loader(data.decode("utf-8", errors="replace"))
                if loader_line_buf:
                    consume_loader("\n")
            if proc.returncode != 0:
                return {
                    "app": app,
                    "workload": workload,
                    "mode": mode,
                    "status": "LOAD_FAIL",
                    "elapsed": None,
                    "iterations": None,
                    "secs": None,
                    "ips": None,
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

    perf = (
        parse_workload_perf(serial_buf, workload)
        if workload
        else {"iterations": None, "secs": None, "ips": None}
    )

    return {
        "app": app,
        "workload": workload,
        "mode": mode,
        "status": status,
        "elapsed": workload_time,
        **perf,
        "serial": serial_buf,
        "loader_tail": list(loader_tail),
    }


def print_score_report(results: list[dict[str, Any]], mode: str) -> None:
    """Print the per-workload iter/s table and, for a -v0 sweep, the mark."""
    rows = [r for r in results if r["workload"]]
    if not rows:
        return

    print("\nCoreMark-PRO WORKLOAD RESULTS (single context)")
    print(
        f"{'Workload Name':<27} {'Status':>9} {'iters':>6} "
        f"{'time(s)':>10} {'iter/s':>12} {'weighted':>10}"
    )
    print(f"{'-' * 27} {'-' * 9} {'-' * 6} {'-' * 10} {'-' * 12} {'-' * 10}")
    for r in rows:
        scale_ref = COREMARK_PRO_REFERENCE.get(r["workload"])
        iters_text = "n/a" if r["iterations"] is None else str(r["iterations"])
        secs_text = "n/a" if r["secs"] is None else f"{r['secs']:.4f}"
        ips_text = "n/a" if r["ips"] is None else f"{r['ips']:.6g}"
        weighted_text = "n/a"
        if r["ips"] is not None and scale_ref is not None:
            weighted_text = f"{r['ips'] * scale_ref[0] / scale_ref[1]:.6g}"
        print(
            f"{r['workload']:<27} {r['status']:>9} {iters_text:>6} "
            f"{secs_text:>10} {ips_text:>12} {weighted_text:>10}"
        )
    print(
        "weighted = iter/s x scale / reference-platform score "
        "(EEMBC guide 2.1.4 sec. 4.4 Fig. 10)"
    )

    if mode == "-v1":
        print(
            "\nCoreMark-PRO score: n/a for -v1 validation sweeps (verification "
            "runs are not score-eligible); rerun with -v0."
        )
        return

    for r in rows:
        if (
            r["status"] == "PASS"
            and r["secs"] is not None
            and r["secs"] < SCORE_RULE_MIN_SECS
        ):
            print(
                f"warning: {r['workload']} ran {r['secs']:.1f}s, under the "
                f"~{SCORE_RULE_MIN_SECS:.0f}s score-rule minimum; recalibrate "
                "its iteration count in sw/apps/software_registry.py"
            )

    ips_by_workload = {
        r["workload"]: r["ips"] for r in rows if r["status"] == "PASS" and r["ips"]
    }
    score, missing = coremark_pro_mark(ips_by_workload)
    if score is None:
        print(
            "\nCoreMark-PRO score: n/a -- the official mark needs a passing "
            f"iter/s from all 9 workloads; missing: {', '.join(missing)}"
        )
    else:
        print(f"\nCoreMark-PRO score (single context): {score:.2f}")
        print(
            "  1000 x geomean of the 9 weighted results; single core, so "
            "SingleCore == MultiCore"
        )


def main() -> int:
    """Run the sweep and print the summary table."""
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument(
        "-v0",
        dest="mode",
        action="store_const",
        const="-v0",
        help=(
            "longer performance/score sweep: runs the registry-calibrated "
            "iteration counts and computes the official CoreMark-PRO score"
        ),
    )
    mode_group.add_argument(
        "-v1",
        dest="mode",
        action="store_const",
        const="-v1",
        help=(
            "quick validation sweep: official result checking, iterations "
            "collapse to a single pass"
        ),
    )
    parser.add_argument(
        "--board",
        required=True,
        choices=list(DEFAULT_TARGETS),
        help=(
            "Target FPGA board: selects the loader board argument and the "
            "default JTAG target/vendor filter"
        ),
    )
    parser.add_argument(
        "--repo",
        type=Path,
        default=REPO_DEFAULT,
        help=f"FROST repo root (default: {REPO_DEFAULT})",
    )
    parser.add_argument(
        "--serial",
        default=None,
        help="Board UART device (default: per --board, see DEFAULT_SERIALS)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=None,
        help=(
            "Per-app timeout in seconds, build included "
            "(default: per --board, see DEFAULT_TIMEOUTS)"
        ),
    )
    parser.add_argument(
        "--loader-extra",
        action="append",
        default=[],
        help="Extra argument to append to every load_software.py invocation",
    )
    parser.add_argument(
        "--target",
        default=None,
        help=(
            "JTAG hardware target pattern passed to the loader "
            "(default: per --board, see DEFAULT_TARGETS)"
        ),
    )
    parser.add_argument(
        "apps",
        nargs="*",
        default=None,
        help=f"coremark_pro_* app names to sweep (default: {' '.join(HW_APPS)})",
    )
    args = parser.parse_args()

    if args.mode is None:
        parser.error(
            "a run mode is required: -v0 for the longer performance/score sweep "
            "(registry-calibrated iterations), or -v1 for the quick validation "
            "sweep (official result checking)"
        )

    apps = list(args.apps) if args.apps else list(HW_APPS)
    unknown = [a for a in apps if a not in {p.app_name for p in COREMARK_PRO_PROGRAMS}]
    if unknown:
        parser.error(f"unknown app(s): {', '.join(unknown)}")

    target = args.target if args.target else DEFAULT_TARGETS[args.board]
    serial = args.serial if args.serial else DEFAULT_SERIALS[args.board]
    timeout = args.timeout if args.timeout is not None else DEFAULT_TIMEOUTS[args.board]

    holders = serial_holders(serial)
    if holders:
        print(
            f"ERROR: {serial} is already open in another process, which would "
            "steal chunks of the UART capture:",
            file=sys.stderr,
        )
        for holder in holders:
            print(f"  {holder}", file=sys.stderr)
        print("Close it (or pass another --serial) and re-run.", file=sys.stderr)
        return 1

    fd = configure_serial(serial)
    results = []
    try:
        for app in apps:
            print(f"\n===== {args.board} {app} {args.mode} =====", flush=True)
            result = run_one(
                args.repo,
                fd,
                args.board,
                app,
                args.mode,
                timeout,
                args.loader_extra,
                target,
            )
            results.append(result)
            print(
                f"\nRESULT {args.board} {result['app']} {result['mode']}: "
                f"{result['status']} time={result['elapsed']}",
                flush=True,
            )
            if result["status"] == "PASS" and result["ips"] is None:
                print(
                    "warning: PASS but iterations/time(secs) missing from the "
                    "capture -- UART bytes lost?",
                    flush=True,
                )
            if result["status"] == "LOAD_FAIL":
                print("loader tail:", flush=True)
                print("\n".join(result["loader_tail"]), flush=True)
    finally:
        os.close(fd)

    bad = [r for r in results if r["status"] != "PASS"]
    print(f"\nSUMMARY ({args.board})")
    for r in results:
        line = f"{args.board} {r['app']} {r['mode']} {r['status']} time={r['elapsed']}"
        if r["ips"] is not None:
            line += f" iter/s={r['ips']:.6g}"
        print(line)
    print_score_report(results, args.mode)
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
