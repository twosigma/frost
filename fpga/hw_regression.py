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

"""Run all hardware apps, CoreMark-PRO, and Linux on a FROST board.

Each bare-metal app is rebuilt, JTAG-loaded, and checked from UART output:
``<<PASS>>`` must appear; ``<<FAIL>>``, ``<<TRAP>>``, ``ERROR``, or nonzero
``:fails=N`` counters fail. ``hello_world`` instead requires two one-second
greetings, and ``uart_echo`` must return a typed probe. CoreMark uses
``ITERATIONS * FPGA_CPU_CLK_FREQ / Total 64-bit ticks`` because its printed
``Iterations/Sec`` uses a 32-bit tick count that overflows after about 14 s at
300 MHz and can hide slowdowns.

Next, ``sweep_coremark_pro.py -v0`` runs all nine workloads with exclusive UART
access; both its status and official mark are checked. The forwarded common
timeout is a base budget; the sweep honors any larger per-workload minimum in
the software registry. Linux runs last and requires the Buildroot banner and
login prompt; traps or panics fail, but the bare-metal ``ERROR`` rule does not
apply to kernel logs. ``--linux-timeout`` covers build, DDR loading, and boot;
a cold Buildroot build takes 30-60 min.
``amo_irq_torture`` separately guards the former mid-AMO interrupt race that
caused intermittent boot corruption.

Scores may fall at most ``--score-tolerance`` percent below the board baseline.
A ``None`` baseline reports the measurement without failing. The regression
stops at the first failure unless ``--keep-going`` and exits zero only when all
selected stages pass.

Examples (from the repo root):

    # Full regression on X3
    ./fpga/hw_regression.py --board x3

    # Run everything even past failures, with a looser score gate
    ./fpga/hw_regression.py --board x3 --keep-going --score-tolerance 2

    # Re-run a subset (stage names = app names plus coremark_pro/linux_boot)
    ./fpga/hw_regression.py --board x3 uart_echo coremark_pro linux_boot
"""

import argparse
import collections
import os
import re
import select
import subprocess
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_DEFAULT = SCRIPT_DIR.parent

sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(SCRIPT_DIR / "common"))
sys.path.insert(0, str(SCRIPT_DIR / "load_software"))
sys.path.insert(0, str(REPO_DEFAULT / "sw" / "apps"))
from hw_defaults import (  # noqa: E402
    DEFAULT_SERIALS,
    DEFAULT_TARGETS,
    DEFAULT_TIMEOUTS,
)
from load_software import BOARD_CONFIG, VALID_APPS  # noqa: E402
from software_registry import COREMARK_PRO_APP_NAMES  # noqa: E402
from sweep_coremark_pro import (  # noqa: E402
    LOAD_COMPLETE_SENTINEL,
    configure_serial,
    drain,
    read_available,
    serial_holders,
)

# ``None`` leaves a score unarmed. The CoreMark baseline below predates the
# 2026-08-27 CoreMark build retune in sw/apps/coremark/Makefile (C extension
# dropped for that program, GCC auto-inline budget raised, priority RA,
# -fstrict-aliasing). The original -16.2% cycle result was measured before the
# Phase 3 16 KiB low-BRAM predecode overlay, which raised the unchanged tuned
# build to 353,923 mean timed-region cycles. Its 64 KiB replacement recovers
# 304,893 cycles in matched two-run cocotb; neither executable bytes nor
# benchmark settings changed. CoreMark-PRO has its own Makefile and did not
# receive the compiler retune, but benefits from the RTL recovery. Both
# baselines below were re-armed from the 2026-09-05 X3 board sweep of the
# recovered build (the first silicon measurement after the retune and the
# 64 KiB overlay).
BASELINE_SCORES: dict[str, dict[str, float | None]] = {
    "x3": {"coremark": 986.34, "coremark_pro": 144.98},
}

# FROST is cycle-deterministic; only DDR refresh adds sub-percent score jitter.
DEFAULT_SCORE_TOLERANCE_PCT = 1.0

# Non-app stage names; linux_boot also names its loader app.
SWEEP_STAGE = "coremark_pro"
LINUX_STAGE = "linux_boot"

# Two greetings prove boot and the one-second timer; no pass marker is printed.
HELLO_GREETING = "Frost: Hello, world!"
HELLO_MIN_GREETINGS = 2

# A returned probe proves every byte crossed UART RX and TX.
ECHO_PROMPT = "frost> "
ECHO_PROBE = "FROST_HW_REGRESSION_ECHO_PROBE"
ECHO_EXPECTED = f'You typed: "{ECHO_PROBE}" ({len(ECHO_PROBE)} chars)'

# A healthy kernel log can contain ``ERROR``, so Linux is judged by these
# markers instead of the bare-metal word rule.
LINUX_SUCCESS_MARKERS = ("Welcome to Buildroot", "buildroot login:")
LINUX_FAILURE_MARKERS = ("<<TRAP>>", "Kernel panic")

# Covers a warm rebuild, multi-MB JTAG load, and boot to login.
DEFAULT_LINUX_TIMEOUT = 300.0

# The FROST coremark port prints "Total 64-bit ticks : N" plus this formula;
# see the module docstring for why Iterations/Sec is not trusted instead.
COREMARK_TICKS_RE = re.compile(r"Total 64-bit ticks : (\d+)")


def check_score(
    board: str, key: str, measured: float, tolerance_pct: float
) -> tuple[bool, str]:
    """Judge a measured score against BASELINE_SCORES[board][key].

    Returns (ok, note). A missing (None) baseline reports the measured value
    and passes; a recorded baseline fails the check when the measured score
    is more than tolerance_pct percent below it.
    """
    baseline = BASELINE_SCORES.get(board, {}).get(key)
    if baseline is None:
        return True, (
            f"{key} score {measured:.2f} -- no {board} baseline recorded; "
            "paste it into BASELINE_SCORES to arm the regression check"
        )
    delta_pct = (measured - baseline) / baseline * 100.0
    if measured < baseline * (1.0 - tolerance_pct / 100.0):
        return False, (
            f"{key} score {measured:.2f} regressed vs baseline {baseline:.2f} "
            f"({delta_pct:+.2f}%, tolerance -{tolerance_pct:g}%)"
        )
    return True, (
        f"{key} score {measured:.2f} vs baseline {baseline:.2f} ({delta_pct:+.2f}%)"
    )


def marker_verdict(serial_buf: str) -> tuple[bool, str]:
    """Apply the sweep's strict pass rule to a captured UART buffer.

    Pass = <<PASS>> present, no <<FAIL>>/<<TRAP>>, no standalone ERROR word,
    and every ":fails=N" counter zero.
    """
    problems = []
    if "<<PASS>>" not in serial_buf:
        problems.append("no <<PASS>>")
    if "<<FAIL>>" in serial_buf:
        problems.append("<<FAIL>> present")
    if "<<TRAP>>" in serial_buf:
        problems.append("<<TRAP>> present")
    if re.search(r"\bERROR\b", serial_buf):
        problems.append("ERROR in output")
    if any(int(x) != 0 for x in re.findall(r":fails=(\d+)", serial_buf)):
        problems.append("nonzero :fails counter")
    if problems:
        return False, ", ".join(problems)
    return True, ""


def _default_failure_done(serial_buf: str) -> bool:
    return "<<FAIL>>" in serial_buf or "<<TRAP>>" in serial_buf


@dataclass
class UartStage:
    """UART terminal predicates, verdict, and optional stimulus.

    Done predicates end capture; ``judge`` evaluates all post-sentinel output.
    ``stimulus_text`` is sent once ``stimulus_trigger`` appears.
    """

    app: str
    success_done: Callable[[str], bool]
    failure_done: Callable[[str], bool]
    judge: Callable[[str], tuple[bool, str]]
    stimulus_trigger: str | None = None
    stimulus_text: str | None = None


def build_stage(app: str, board: str, tolerance_pct: float) -> UartStage:
    """Build the UART rules for one phase-1 app."""
    if app == "hello_world":

        def hello_judge(serial_buf: str) -> tuple[bool, str]:
            """Pass when the once-per-second greeting proves boot + timer."""
            greetings = serial_buf.count(HELLO_GREETING)
            if _default_failure_done(serial_buf) or re.search(r"\bERROR\b", serial_buf):
                return False, "failure marker in output"
            if greetings < HELLO_MIN_GREETINGS:
                return False, (
                    f"only {greetings} greeting(s); "
                    f"need {HELLO_MIN_GREETINGS} to prove the timer tick"
                )
            return True, f"{greetings} greetings observed"

        return UartStage(
            app,
            success_done=lambda buf: buf.count(HELLO_GREETING) >= HELLO_MIN_GREETINGS,
            failure_done=_default_failure_done,
            judge=hello_judge,
        )

    if app == "uart_echo":

        def echo_judge(serial_buf: str) -> tuple[bool, str]:
            """Pass when the typed probe line was echoed back verbatim."""
            if _default_failure_done(serial_buf):
                return False, "failure marker in output"
            if ECHO_EXPECTED in serial_buf:
                return True, (
                    f"probe line round-tripped ({len(ECHO_PROBE)} chars echoed)"
                )
            if ECHO_PROMPT not in serial_buf:
                return False, "no 'frost> ' prompt seen -- program never started"
            return False, "prompt seen but probe response missing -- UART RX broken?"

        return UartStage(
            app,
            success_done=lambda buf: ECHO_EXPECTED in buf,
            failure_done=_default_failure_done,
            judge=echo_judge,
            stimulus_trigger=ECHO_PROMPT,
            stimulus_text=ECHO_PROBE + "\r",
        )

    if app == "coremark":
        board_config = BOARD_CONFIG[board]

        def coremark_judge(serial_buf: str) -> tuple[bool, str]:
            """Apply the marker rule, then gate on the 64-bit-tick score."""
            ok, note = marker_verdict(serial_buf)
            if not ok:
                return False, note
            ticks_match = COREMARK_TICKS_RE.search(serial_buf)
            if not ticks_match:
                return False, (
                    "<<PASS>> but 'Total 64-bit ticks' missing from the capture"
                )
            score = (
                board_config["coremark_iterations"]
                * board_config["clock_freq"]
                / int(ticks_match.group(1))
            )
            return check_score(board, "coremark", score, tolerance_pct)

        return UartStage(
            app,
            success_done=lambda buf: "<<PASS>>" in buf,
            failure_done=_default_failure_done,
            judge=coremark_judge,
        )

    return UartStage(
        app,
        success_done=lambda buf: "<<PASS>>" in buf,
        failure_done=_default_failure_done,
        judge=marker_verdict,
    )


def linux_stage() -> UartStage:
    """Build the linux_boot stage: pass on the Buildroot login prompt."""

    def lx_success(serial_buf: str) -> bool:
        """Return True once both Buildroot login markers have been captured."""
        return all(marker in serial_buf for marker in LINUX_SUCCESS_MARKERS)

    def lx_failure(serial_buf: str) -> bool:
        """Return True on a CPU trap or kernel panic during boot."""
        return any(marker in serial_buf for marker in LINUX_FAILURE_MARKERS)

    def lx_judge(serial_buf: str) -> tuple[bool, str]:
        """Fail on trap/panic, else require both login markers."""
        hit = [m for m in LINUX_FAILURE_MARKERS if m in serial_buf]
        if hit:
            return False, f"failure marker: {', '.join(hit)}"
        missing = [m for m in LINUX_SUCCESS_MARKERS if m not in serial_buf]
        if missing:
            return False, f"missing: {', '.join(repr(m) for m in missing)}"
        return True, "buildroot login prompt reached"

    return UartStage(
        LINUX_STAGE,
        success_done=lx_success,
        failure_done=lx_failure,
        judge=lx_judge,
    )


def send_uart_probe(serial_fd: int, text: str) -> None:
    """Pace bytes so ``uart_echo`` never overfills its RX FIFO."""
    for byte in text.encode():
        os.write(serial_fd, bytes([byte]))
        time.sleep(0.002)


def run_uart_stage(
    repo: Path,
    serial_fd: int,
    board: str,
    stage: UartStage,
    timeout_s: float,
    loader_extra: list[str],
    target: str,
) -> dict[str, Any]:
    """Build and load one app, then capture UART to completion or timeout.

    A raw nonblocking loader fd avoids buffering the load sentinel. UART output
    before ``FROST_LOAD_COMPLETE`` belongs to the previous program and is
    discarded.
    """
    drain(serial_fd)
    cmd = [
        "./fpga/load_software/load_software.py",
        board,
        stage.app,
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
    loader_fd = proc.stdout.fileno() if proc.stdout is not None else None
    if loader_fd is not None:
        os.set_blocking(loader_fd, False)

    loader_tail: collections.deque[str] = collections.deque(maxlen=80)
    loader_line_buf = ""
    serial_buf = ""
    loader_done = False
    program_started = False
    stimulus_sent = False
    start = time.monotonic()
    deadline = start + timeout_s

    def consume_loader(text: str) -> None:
        """Split loader stdout into lines; reset capture at the load sentinel."""
        nonlocal loader_line_buf, program_started, serial_buf
        loader_line_buf += text
        while "\n" in loader_line_buf:
            line, loader_line_buf = loader_line_buf.split("\n", 1)
            loader_tail.append(line)
            if not program_started and LOAD_COMPLETE_SENTINEL in line:
                # Drop UART output from the previous image.
                program_started = True
                serial_buf = ""

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
            else:
                data = read_available(loader_fd)
                if data:
                    consume_loader(data.decode("utf-8", errors="replace"))

        if (
            stage.stimulus_text is not None
            and not stimulus_sent
            and program_started
            and stage.stimulus_trigger is not None
            and stage.stimulus_trigger in serial_buf
        ):
            print(f"\n[hw_regression] typing UART probe: {ECHO_PROBE}", flush=True)
            send_uart_probe(serial_fd, stage.stimulus_text)
            stimulus_sent = True

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
                    "stage": stage.app,
                    "status": "LOAD_FAIL",
                    "elapsed": time.monotonic() - start,
                    "note": f"load_software.py exited {proc.returncode}",
                    "loader_tail": list(loader_tail),
                }

        # The sentinel is the loader's final line, so both conditions are needed.
        if (
            loader_done
            and program_started
            and (stage.success_done(serial_buf) or stage.failure_done(serial_buf))
        ):
            break

    killed_loader = False
    if not loader_done and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        killed_loader = True

    elapsed = time.monotonic() - start
    if not program_started:
        status = "TIMEOUT"
        note = (
            f"loader never reached {LOAD_COMPLETE_SENTINEL} " f"within {timeout_s:.0f}s"
        )
    elif stage.success_done(serial_buf) or stage.failure_done(serial_buf):
        ok, note = stage.judge(serial_buf)
        status = "PASS" if ok else "FAIL"
        if killed_loader:
            note = (note + "; " if note else "") + "loader hung and was killed"
    else:
        status = "TIMEOUT"
        note = f"no terminal UART output within {timeout_s:.0f}s"

    return {
        "stage": stage.app,
        "status": status,
        "elapsed": elapsed,
        "note": note,
        "loader_tail": list(loader_tail),
    }


def run_sweep_stage(
    repo: Path,
    board: str,
    serial: str,
    target: str,
    timeout_s: float,
    loader_extra: list[str],
    tolerance_pct: float,
) -> dict[str, Any]:
    """Run the -v0 CoreMark-PRO sweep and judge its status and mark.

    The sweep owns the UART and times each workload. It can raise this stage's
    base timeout to a workload-specific registry minimum. Its status covers all
    nine workloads; its printed official mark is checked against the board
    baseline.
    """
    cmd = [
        "./fpga/sweep_coremark_pro.py",
        "--board",
        board,
        "-v0",
        "--serial",
        serial,
        "--target",
        target,
        "--timeout",
        str(timeout_s),
    ]
    for extra in loader_extra:
        cmd.extend(["--loader-extra", extra])
    start = time.monotonic()
    proc = subprocess.Popen(
        cmd,
        cwd=repo,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    captured: list[str] = []
    assert proc.stdout is not None
    for line in proc.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        captured.append(line)
    returncode = proc.wait()
    elapsed = time.monotonic() - start
    output = "".join(captured)

    if returncode != 0:
        return {
            "stage": SWEEP_STAGE,
            "status": "FAIL",
            "elapsed": elapsed,
            "note": f"sweep exited {returncode} -- not all nine workloads passed",
        }
    score_match = re.search(
        r"CoreMark-PRO score \(single context\): ([0-9]+(?:\.[0-9]+)?)", output
    )
    if not score_match:
        return {
            "stage": SWEEP_STAGE,
            "status": "FAIL",
            "elapsed": elapsed,
            "note": "sweep passed but printed no official CoreMark-PRO score",
        }
    ok, note = check_score(
        board, "coremark_pro", float(score_match.group(1)), tolerance_pct
    )
    return {
        "stage": SWEEP_STAGE,
        "status": "PASS" if ok else "FAIL",
        "elapsed": elapsed,
        "note": note,
    }


def main() -> int:
    """Run the selected stages in order and print the final summary."""
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--board",
        required=True,
        choices=list(BOARD_CONFIG),
        help="Target FPGA board",
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
        help="Board UART device (default: per --board, see shared hardware defaults)",
    )
    parser.add_argument(
        "--target",
        default=None,
        help="JTAG hardware target pattern (default: per --board)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=None,
        help=(
            "Base per-app timeout in seconds, build included; also forwarded "
            "to the sweep, where a workload minimum may raise it (default: "
            "per --board)"
        ),
    )
    parser.add_argument(
        "--linux-timeout",
        type=float,
        default=DEFAULT_LINUX_TIMEOUT,
        help=(
            "linux_boot timeout in seconds covering rebuild, JTAG DDR image "
            f"load, and boot to the login prompt (default: "
            f"{DEFAULT_LINUX_TIMEOUT:.0f}; raise it for a cold Buildroot "
            "first build, which takes 30-60 min)"
        ),
    )
    parser.add_argument(
        "--score-tolerance",
        type=float,
        default=DEFAULT_SCORE_TOLERANCE_PCT,
        metavar="PCT",
        help=(
            "Allowed percent drop below a recorded baseline score before the "
            f"stage fails (default: {DEFAULT_SCORE_TOLERANCE_PCT:g}%%)"
        ),
    )
    parser.add_argument(
        "--keep-going",
        action="store_true",
        help="Run every stage even after a failure (default: stop at the first)",
    )
    parser.add_argument(
        "--loader-extra",
        action="append",
        default=[],
        help=(
            "Extra argument appended to every load_software.py invocation "
            "(also forwarded to the sweep)"
        ),
    )
    parser.add_argument(
        "stages",
        nargs="*",
        help=(
            "Optional subset of stages to run, in canonical order (app names "
            f"plus '{SWEEP_STAGE}' and '{LINUX_STAGE}'; default: all)"
        ),
    )
    args = parser.parse_args()

    board = args.board
    target = args.target if args.target else DEFAULT_TARGETS[board]
    serial = args.serial if args.serial else DEFAULT_SERIALS[board]
    timeout = args.timeout if args.timeout is not None else DEFAULT_TIMEOUTS[board]

    # Stage order: hello_world first as the bring-up smoke test, the remaining
    # apps in VALID_APPS order, then the CoreMark-PRO sweep. linux_boot runs
    # last because it is the longest, whole-system stage and should only run
    # once everything else has passed.
    phase1 = [
        app
        for app in VALID_APPS
        if app != LINUX_STAGE and app not in COREMARK_PRO_APP_NAMES
    ]
    phase1.remove("hello_world")
    phase1.insert(0, "hello_world")
    all_stages = [*phase1, SWEEP_STAGE, LINUX_STAGE]

    if args.stages:
        unknown = sorted(set(args.stages) - set(all_stages))
        if unknown:
            parser.error(
                f"unknown stage(s): {', '.join(unknown)}\n"
                f"valid stages: {', '.join(all_stages)}"
            )
        requested = set(args.stages)
        selected = [stage for stage in all_stages if stage in requested]
    else:
        selected = all_stages

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

    results: list[dict[str, Any]] = []
    serial_fd: int | None = None
    try:
        for index, stage_name in enumerate(selected, start=1):
            print(
                f"\n===== {board} {stage_name} [{index}/{len(selected)}] =====",
                flush=True,
            )
            if stage_name == SWEEP_STAGE:
                # Release the UART before the sweep requests exclusive access.
                if serial_fd is not None:
                    os.close(serial_fd)
                    serial_fd = None
                result = run_sweep_stage(
                    args.repo,
                    board,
                    serial,
                    target,
                    timeout,
                    args.loader_extra,
                    args.score_tolerance,
                )
            else:
                if serial_fd is None:
                    serial_fd = configure_serial(serial)
                if stage_name == LINUX_STAGE:
                    stage = linux_stage()
                    stage_timeout = args.linux_timeout
                else:
                    stage = build_stage(stage_name, board, args.score_tolerance)
                    stage_timeout = timeout
                result = run_uart_stage(
                    args.repo,
                    serial_fd,
                    board,
                    stage,
                    stage_timeout,
                    args.loader_extra,
                    target,
                )
            results.append(result)

            note = f" -- {result['note']}" if result["note"] else ""
            print(
                f"\nRESULT {board} {result['stage']}: {result['status']} "
                f"time={result['elapsed']:.1f}s{note}",
                flush=True,
            )
            if result["status"] in ("LOAD_FAIL", "TIMEOUT") and result.get(
                "loader_tail"
            ):
                print("loader tail:", flush=True)
                print("\n".join(result["loader_tail"]), flush=True)

            if result["status"] != "PASS" and not args.keep_going:
                break
    finally:
        if serial_fd is not None:
            os.close(serial_fd)

    skipped = selected[len(results) :]
    bad = [r for r in results if r["status"] != "PASS"]

    print(f"\nSUMMARY ({board})")
    name_width = max(len(r["stage"]) for r in results) if results else 12
    for r in results:
        note = f"  {r['note']}" if r["note"] else ""
        print(
            f"  {r['stage']:<{name_width}} {r['status']:>9} "
            f"{r['elapsed']:>8.1f}s{note}"
        )
    if skipped:
        print(f"  skipped after failure: {', '.join(skipped)}")

    passed = len(results) - len(bad)
    verdict = "PASS" if not bad and not skipped else "FAIL"
    print(f"\nREGRESSION {verdict}: {passed}/{len(selected)} stages passed")
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
