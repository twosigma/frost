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

"""Run and score CoreMark-PRO workloads on FROST hardware.

Each selected workload is rebuilt with its registry arguments, JTAG-loaded,
and checked from UART output: ``<<PASS>>`` must appear; ``ERROR``, ``<<FAIL>>``,
``<<TRAP>>``, or nonzero ``:fails=N`` counters fail. The summary reports
iterations per second and exits zero only if every workload passes.

A complete -v0 sweep also prints the official mark: 1000 times the geometric
mean of each iter/s result scaled against its reference score (EEMBC Symmetric
Multicore Benchmark User Guide 2.1.4, section 4.4; also
``util/perl/cert_mark.pl``). FROST's single context supplies both the
SingleCore and MultiCore result. Validation (-v1) is not score-eligible. A -v0
run under the ten-second minimum warns that its registry iterations need
recalibration.

``--board`` selects a registered FPGA board. With no app arguments, all nine
hardware-supported registry workloads run. UART and JTAG targets have
per-board defaults. The script refuses an already-open UART and holds it with
``TIOCEXCL`` so another reader cannot steal capture bytes.

``--timeout`` is the base end-to-end budget for each workload. The software
registry can raise it for a board/workload pair whose conforming, untimed setup
needs longer; the X3 ZIP workload has such a floor.

Examples (from the repo root):

    # -v1 validation sweep of every hardware-supported workload on X3
    ./fpga/sweep_coremark_pro.py --board x3 -v1

    # -v0 performance sweep on X3 (registry-calibrated iteration counts)
    ./fpga/sweep_coremark_pro.py --board x3 -v0

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

sys.path.insert(0, str(SCRIPT_DIR / "common"))
sys.path.insert(0, str(REPO_DEFAULT / "sw" / "apps"))
from hw_defaults import (  # noqa: E402
    DEFAULT_SERIALS,
    DEFAULT_TARGETS,
    DEFAULT_TIMEOUTS,
)
from software_registry import (  # noqa: E402
    COREMARK_PRO_PROGRAM_BY_APP,
    COREMARK_PRO_PROGRAMS,
    coremark_pro_hardware_timeout,
)

HW_APPS = tuple(p.app_name for p in COREMARK_PRO_PROGRAMS if p.hardware_supported)

BAUD = termios.B115200

# Reset capture at this loader sentinel; earlier UART bytes belong to the
# previous image and could contain stale pass or timing markers.
LOAD_COMPLETE_SENTINEL = "FROST_LOAD_COMPLETE"

# Official (scale, reference score) pairs from EEMBC guide 2.1.4 section 4.4
# and coremark-pro util/perl/cert_mark.pl. Mark = 1000 times the geometric mean
# of ``iter/s * scale / reference`` across all nine workloads.
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

# Registry iterations must clear this official -v0 minimum.
SCORE_RULE_MIN_SECS = 10.0

# ``%8g`` may emit decimal or exponent notation.
MITH_NUMBER = r"([0-9]+(?:\.[0-9]*)?(?:[eE][+-]?[0-9]+)?)"


def parse_workload_perf(serial_buf: str, workload: str) -> dict[str, Any]:
    """Extract workload iterations and seconds, then derive iter/s.

    Matching the official workload name excludes -v1 item lines; only the
    workload-level block has ``iterations=``.
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
    """Return the full-set official mark, or ``None`` and missing workloads."""
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
    """Return ``pid: cmdline`` for visible processes holding the serial device.

    A second reader steals capture bytes. ``/proc`` limits discovery to
    processes visible to this user.
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
    """Load one app and capture UART output until a marker or timeout."""
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

    # Buffered readline() can hide the sentinel while select() reports no data;
    # use a raw nonblocking fd so capture resets at the true image boundary.
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
                # Drop UART output from the previous image.
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
            "Base per-app timeout in seconds, build included; a registry "
            "workload minimum may raise it (default: per --board, see "
            "DEFAULT_TIMEOUTS)"
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
    base_timeout = (
        args.timeout if args.timeout is not None else DEFAULT_TIMEOUTS[args.board]
    )

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
            timeout = coremark_pro_hardware_timeout(app, args.board, base_timeout)
            if timeout > base_timeout:
                print(
                    f"timeout: {timeout:g}s (registry minimum; "
                    f"base {base_timeout:g}s)",
                    flush=True,
                )
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
