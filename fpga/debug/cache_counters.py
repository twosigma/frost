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

r"""Read FROST's cache and load-wait profiling counters over JTAG.

The profiling counters are machine-mode CSRs, which software in S or U mode,
Linux among it, cannot read. This tool reads them through the debug module
with OpenOCD (cache_counters.tcl) while the hart runs anything: each OpenOCD
run halts the hart, takes a counter snapshot, and resumes it. The core needs
the profiling counters (build.py --perf-counters), and OpenOCD needs the JTAG
cable, so stop Vivado's hw_server first.

    sample              print one snapshot of the cache counters
    resume              resume the hart if an interrupted run left it halted
    window --seconds S  take a snapshot, wait S seconds, take another, and
                        print the deltas with the L2's write costs, then the
                        second snapshot
    window -- COMMAND   the same around COMMAND, run on this machine (an ssh
                        to the board, for example)
    window --load-waits report indices 79, 80 and 120 with both snapshots
                        around --seconds S or -- COMMAND
    summarize LOG...    the same for each FROST_CACHE_COUNTERS line in the
                        logs, such as those of a CoreMark-PRO sweep built with
                        COREMARK_PRO_CACHE_COUNTERS=1

For example:

    ./fpga/debug/cache_counters.py window --seconds 30
    ./fpga/debug/cache_counters.py window --load-waits --seconds 30
    ./fpga/debug/cache_counters.py window -- ssh root@192.0.2.2 \
        'dd if=/root/big of=/dev/null bs=1M'
    ./fpga/debug/cache_counters.py summarize sweep.log

A cache window starts with a snapshot alone, which halts the hart briefly, and
ends with one that reads both it and the cache block's preceding snapshot,
the window's start. With --load-waits, each halt sends one snapshot request
and saves all three values from the current bank. Both modes include the
halts between captures, during which DMA traffic can continue. Elapsed cycles
come from the time CSR, the CLINT's mtime, which counts core cycles. The Tcl
helper requests riscv autofence off when supported. A resume FENCE.I drains
committed stores, invalidates L1I and synchronizes instruction-copy writes.
Dirty L1D data remains available to coherent home probes. Runs of this tool
on one host take turns. FROST_JTAG_SERIAL selects the JTAG cable as for
openocd_x3.cfg.
"""

import argparse
import fcntl
import re
import subprocess
import sys
import tempfile
import time
from collections.abc import Sequence
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]
SNAPSHOT_TCL = SCRIPT_DIR / "cache_counters.tcl"
DEFAULT_CONFIG = SCRIPT_DIR / "openocd_x3.cfg"
# Runs on one host take turns, so one run's snapshot cannot replace the
# preceding bank in the middle of another's window.
LOCK_PATH = Path(tempfile.gettempdir()) / "frost_cache_counters.lock"

# The cache block of the profiling counters by global index
# (hw/rtl/cpu_and_mem/cpu/cpu_ooo/perf/README.md, "Numbering contract").
CACHE_COUNTERS: dict[int, str] = {
    106: "L1I_ACCESS",
    107: "L1I_HIT",
    108: "L1I_MISS",
    109: "L1I_WRITEBACK",
    110: "L1D_ACCESS",
    111: "L1D_HIT",
    112: "L1D_MISS",
    113: "L1D_WRITEBACK",
    114: "L2_ACCESS",
    115: "L2_HIT",
    116: "L2_MISS",
    117: "L2_WRITEBACK",
    118: "L1I_FETCH_MISS_STALL",
    119: "L1D_MISS_CYCLES_SUM",
    120: "L2_MISS_CYCLES_SUM",
    121: "L1I_HIT_UNDER_MISS",
    122: "L1D_HIT_UNDER_MISS",
    123: "L2_HIT_UNDER_MISS",
    124: "L1D_SLOT_FULL_STALL",
    125: "L2_SLOT_FULL_STALL",
    126: "L1D_CONFLICT_STALL",
    127: "L2_CONFLICT_STALL",
    128: "L1D_MISS_OVERLAP_CYCLES",
    129: "L2_MISS_OVERLAP_CYCLES",
    130: "L2_WRITE_FILL",
    131: "L2_WRITE_FILL_CYCLES_SUM",
    132: "L2_WRITE_READ_WAIT",
    133: "L2_WRITE_READ_WAIT_CYCLES",
}
FIRST_CACHE_COUNTER = min(CACHE_COUNTERS)
INDEX = {name: index for index, name in CACHE_COUNTERS.items()}
NAME_WIDTH = max(len(name) for name in CACHE_COUNTERS.values())
L2_LINE_BYTES = 64
LOAD_WAIT_INDICES = (79, 80, 120)

SNAPSHOT_RE = re.compile(r"^FROST_CACHE_SNAPSHOT((?: [^ \r\n]+)+)[ \t\r]*$", re.M)
PREVIOUS_RE = re.compile(r"^FROST_CACHE_PREVIOUS((?: [^ \r\n]+)+)[ \t\r]*$", re.M)
MARK_RE = re.compile(r"^FROST_CACHE_MARK((?: [^ \r\n]+)+)[ \t\r]*$", re.M)
LOAD_SNAPSHOT_RE = re.compile(r"^FROST_LOAD_SNAPSHOT(?:[ \t]+([^\r\n]*))?\r?$", re.M)
LOAD_VALUE_RE = re.compile(r"(?:[0-9]{1,20}|0[xX][0-9a-fA-F]{1,16})")
RESUME_RE = re.compile(r"^FROST_CACHE_HART (\w+)[ \t\r]*$", re.M)
COUNTERS_RE = re.compile(r"FROST_CACHE_COUNTERS((?: [^ \r\n]+)+)")
SECTION_RE = re.compile(r"^===== (.+) =====[ \t\r]*$")
# sweep_coremark_pro.py's verdict on each workload.
RESULT_RE = re.compile(r"^RESULT \S+ (\S+) \S+: (\w+)")

# Counters, by global index, and a clock field under its name ("time" in a
# snapshot, "cycles" in a delta).
Counters = dict[int | str, int]


class LoadCountersUnavailableError(RuntimeError):
    """The core lacks one or more load-window counters."""


def parse_fields(
    text: str, *, required_indices: Sequence[int] | None = None
) -> Counters | None:
    """Return the fields of a snapshot or counters line, or None for "absent".

    With required indices, require them and a time field as unsigned 64-bit
    values. Otherwise the indices run without gaps from the first cache
    counter.
    """
    fields = text.split()
    if fields == ["absent"]:
        return None
    values: Counters = {}
    for field in fields:
        key, separator, value = field.partition("=")
        if not separator or not value:
            raise ValueError(f"malformed counter field {field!r}")
        name: int | str = int(key) if key.isdigit() else key
        if name in values:
            raise ValueError(f"counter field {key} repeats")
        if required_indices is None:
            values[name] = int(value, 0)
            continue
        if not LOAD_VALUE_RE.fullmatch(value):
            raise ValueError(f"invalid unsigned 64-bit value {value!r} for {key}")
        number = int(value, 16 if value.lower().startswith("0x") else 10)
        if number >= 1 << 64:
            raise ValueError(f"invalid unsigned 64-bit value {value!r} for {key}")
        values[name] = number
    if required_indices is not None:
        if values.keys() != {"time", *required_indices}:
            raise ValueError(f"snapshot requires time and counters {required_indices}")
        return values
    indices = sorted(k for k in values if isinstance(k, int))
    expected = list(range(FIRST_CACHE_COUNTER, FIRST_CACHE_COUNTER + len(indices)))
    if indices != expected:
        raise ValueError(
            f"cache counters are not {FIRST_CACHE_COUNTER} onward: {indices}"
        )
    return values


def openocd_command(
    openocd: str, config: Path, commands: Sequence[str], procedure: str
) -> list[str]:
    """Return the OpenOCD command line that runs one cache_counters.tcl procedure."""
    # The configurations find their shared files from the repository root.
    command = [openocd, "-s", str(REPO_ROOT)]
    for text in ("gdb_port disabled", "telnet_port disabled", "tcl_port disabled"):
        command += ["-c", text]
    for text in commands:
        command += ["-c", text]
    command += ["-f", str(config), "-f", str(SNAPSHOT_TCL)]
    command += ["-c", "init", "-c", procedure, "-c", "shutdown"]
    return command


def run_openocd(args: argparse.Namespace, procedure: str) -> str:
    """Run a cache_counters.tcl procedure in OpenOCD and return its output."""
    command = openocd_command(args.openocd, args.config, args.commands, procedure)
    try:
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=args.timeout, check=False
        )
    except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        how = (
            "was interrupted"
            if isinstance(error, KeyboardInterrupt)
            else f"did not finish in {args.timeout:g} s"
        )
        raise RuntimeError(
            f"OpenOCD {how} in {procedure} and was stopped, which can leave the "
            "hart halted; run cache_counters.py resume"
        ) from error
    output = result.stdout + result.stderr
    if result.returncode != 0:
        tail = "\n".join(output.splitlines()[-20:])
        raise RuntimeError(
            f"OpenOCD exited {result.returncode} in {procedure}:\n{tail}"
        )
    return output


def run_procedure(
    args: argparse.Namespace, procedure: str, patterns: Sequence[re.Pattern[str]]
) -> list[Counters]:
    """Run a procedure in OpenOCD and return the fields of each line it prints."""
    output = run_openocd(args, procedure)
    found = [pattern.findall(output) for pattern in patterns]
    if found[0] and parse_fields(found[0][-1]) is None:
        raise RuntimeError(
            "the core has no profiling counters; build it with --perf-counters"
        )
    if not all(found):
        raise RuntimeError(f"OpenOCD printed no result in {procedure}")
    values = [parse_fields(lines[-1]) for lines in found]
    return [value for value in values if value is not None]


def take_mark(args: argparse.Namespace) -> int:
    """Take a snapshot to start a window and return the time CSR at it."""
    return run_procedure(args, "frost_cache_mark", [MARK_RE])[0]["time"]


def take_snapshot(args: argparse.Namespace) -> tuple[Counters, Counters]:
    """Take a snapshot and return it, with the time CSR, and the one before it."""
    current, previous = run_procedure(
        args, "frost_cache_snapshot", [SNAPSHOT_RE, PREVIOUS_RE]
    )
    return current, previous


def take_load_snapshot(args: argparse.Namespace) -> Counters:
    """Take one snapshot and return its load-window counters and time CSR."""
    procedure = "frost_load_snapshot"
    found = LOAD_SNAPSHOT_RE.findall(run_openocd(args, procedure))
    if len(found) != 1:
        raise RuntimeError(f"OpenOCD must print one result in {procedure}")
    try:
        values = parse_fields(found[0], required_indices=LOAD_WAIT_INDICES)
    except ValueError as error:
        raise RuntimeError(f"invalid load snapshot: {error}") from error
    if values is None:
        raise LoadCountersUnavailableError("the core lacks the load-window counters")
    return values


def resume_hart(args: argparse.Namespace) -> str:
    """Resume the hart if it is halted, and say which it was."""
    found = RESUME_RE.findall(run_openocd(args, "frost_cache_resume"))
    if not found:
        raise RuntimeError("OpenOCD printed no result in frost_cache_resume")
    if found[-1] == "resumed":
        return "resumed the halted hart"
    return f"the hart is {found[-1]}; nothing to resume"


def deltas(
    start: Counters, end: Counters, *, distinguish_wrap: bool = False
) -> Counters:
    """Return each counter's change from start to end, with "cycles" from time.

    Reject a decrease. An isolated decrease in the load window suggests a
    wrap, while simultaneous decreases suggest a reset.
    """
    indices = sorted(k for k in end if isinstance(k, int))
    if indices != sorted(k for k in start if isinstance(k, int)):
        raise RuntimeError("the two snapshots cover different counters")
    change: Counters = {"cycles": end["time"] - start["time"]}
    for key in indices:
        change[key] = end[key] - start[key]
    fell = [CACHE_COUNTERS.get(k, str(k)) for k, v in change.items() if v < 0]
    if fell:
        reason = "the core was reset during the window"
        if distinguish_wrap:
            reason = (
                "an isolated decrease suggests a 64-bit wrap"
                if len(fell) == 1
                else "multiple decreases suggest a reset"
            )
        raise RuntimeError(f"{', '.join(fell)} went down: {reason}")
    return change


def counter_line(prefix: str, values: Counters, clock_field: str) -> str:
    """Print a clock field followed by the counters in index order."""
    fields = [prefix, f"{clock_field}={values[clock_field]}"]
    fields += [
        f"{key}={values[key]}"
        for key in sorted(k for k in values if isinstance(k, int))
    ]
    return " ".join(fields)


def _share(part: int, whole: int) -> str:
    return f"{100.0 * part / whole:.2f}%" if whole else "n/a"


def _each(total: int, count: int) -> str:
    return f"{total / count:.1f}" if count else "n/a"


def write_cost_lines(change: Counters) -> list[str]:
    """Return the L2's write costs derived from a set of counter deltas."""
    names = (
        "L2_ACCESS",
        "L2_MISS",
        "L2_MISS_CYCLES_SUM",
        "L2_WRITE_FILL",
        "L2_WRITE_FILL_CYCLES_SUM",
        "L2_WRITE_READ_WAIT",
        "L2_WRITE_READ_WAIT_CYCLES",
    )
    missing = [name for name in names if INDEX[name] not in change]
    if missing:
        return [f"L2 write costs: n/a (no {', '.join(missing)})"]
    value = {name: change[INDEX[name]] for name in names}
    fills = value["L2_WRITE_FILL"]
    fill_cycles = value["L2_WRITE_FILL_CYCLES_SUM"]
    waits = value["L2_WRITE_READ_WAIT"]
    wait_cycles = value["L2_WRITE_READ_WAIT_CYCLES"]
    return [
        f"L2 write fills: {fills}, {_share(fills, value['L2_MISS'])} of L2 misses, "
        f"{fills * L2_LINE_BYTES} bytes read from DDR, {_each(fill_cycles, fills)} "
        f"slot-cycles each, {_share(fill_cycles, value['L2_MISS_CYCLES_SUM'])} of "
        "L2 slot-cycles",
        f"L2 writes held behind reads: {waits}, {_share(waits, value['L2_ACCESS'])} "
        f"of L2 accesses, {wait_cycles} cycles held, {_each(wait_cycles, waits)} "
        f"per write, {_share(wait_cycles, int(change['cycles']))} of all cycles",
    ]


def report_lines(change: Counters) -> list[str]:
    """Return the counters line, each counter by name, and the write costs."""
    lines = [
        counter_line("FROST_CACHE_COUNTERS", change, "cycles"),
        f"  {'cycles':<{NAME_WIDTH + 4}} {change['cycles']:>16}",
    ]
    for key in sorted(k for k in change if isinstance(k, int)):
        name = CACHE_COUNTERS.get(key, f"counter {key}")
        lines.append(f"  {key} {name:<{NAME_WIDTH}} {change[key]:>16}")
    lines += [f"  {line}" for line in write_cost_lines(change)]
    return lines


def snapshot_lines(values: Counters) -> list[str]:
    """Return a snapshot as its OpenOCD line and each counter by name."""
    lines = [counter_line("FROST_CACHE_SNAPSHOT", values, "time")]
    for key in sorted(k for k in values if isinstance(k, int)):
        name = CACHE_COUNTERS.get(key, f"counter {key}")
        lines.append(f"  {key} {name:<{NAME_WIDTH}} {values[key]:>16}")
    return lines


def summarize(paths: Sequence[Path]) -> list[str]:
    """Report each FROST_CACHE_COUNTERS line of the logs under its sweep section.

    A section's heading carries the sweep's verdict on its workload when the
    log has one, so a workload that failed is marked as such.
    """
    out: list[str] = []
    for path in paths:
        # Each section's heading, verdict, and reports, in log order.
        sections: list[tuple[str, list[str], list[list[str]]]] = [(str(path), [], [])]
        for text in path.read_text(errors="replace").splitlines():
            heading = SECTION_RE.match(text)
            if heading:
                sections.append((heading.group(1), [], []))
                continue
            section, verdict, reports = sections[-1]
            result = RESULT_RE.match(text)
            if result and f" {result.group(1)} " in f" {section} ":
                verdict[:] = [f" ({result.group(2)})"]
                continue
            match = COUNTERS_RE.search(text)
            if match:
                change = parse_fields(match.group(1))
                reports.append(
                    ["  profiling counters absent"]
                    if change is None
                    else [f"  {line}" for line in report_lines(change)]
                )
        for section, verdict, reports in sections:
            for lines in reports:
                out += [f"{section}{''.join(verdict)}:", *lines]
    return out


def window_command(command: Sequence[str]) -> list[str]:
    """Return the command after an optional leading "--"."""
    return list(command[1:] if command and command[0] == "--" else command)


def main(argv: Sequence[str] | None = None) -> int:
    """Run the selected action and print its report."""
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--openocd", default="openocd", help="OpenOCD executable")
    parser.add_argument(
        "--config",
        type=Path,
        default=DEFAULT_CONFIG,
        help=f"OpenOCD board or simulation configuration (default: {DEFAULT_CONFIG})",
    )
    parser.add_argument(
        "-c",
        "--command",
        dest="commands",
        action="append",
        default=[],
        metavar="TCL",
        help="OpenOCD command to run before the configuration; repeatable",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=120.0,
        help="seconds each OpenOCD run may take (default: 120)",
    )
    actions = parser.add_subparsers(dest="action", required=True)
    actions.add_parser("sample", help="print one snapshot")
    actions.add_parser("resume", help="resume the hart if a stopped run left it halted")
    window = actions.add_parser(
        "window", help="print the deltas over a wait or a command"
    )
    window.add_argument(
        "--load-waits",
        action="store_true",
        help="read head load waits and home fill occupancy at both ends",
    )
    window.add_argument(
        "--seconds", type=float, help="wait this long between snapshots"
    )
    window.add_argument(
        "--run-timeout",
        type=float,
        help=(
            "seconds COMMAND may run before it is killed (default: no limit); "
            "bound remote work with timeout on the board too"
        ),
    )
    window.add_argument(
        "run", nargs=argparse.REMAINDER, help="-- COMMAND to run between snapshots"
    )
    summary = actions.add_parser(
        "summarize", help="report the FROST_CACHE_COUNTERS lines of logs"
    )
    summary.add_argument("logs", nargs="+", type=Path)
    args = parser.parse_args(argv)

    if args.action == "summarize":
        lines = summarize(args.logs)
        if not lines:
            print("Error: no FROST_CACHE_COUNTERS lines in the logs", file=sys.stderr)
            return 1
        print("\n".join(lines))
        return 0
    command = window_command(getattr(args, "run", []))
    if args.action == "window" and (args.seconds is None) == (not command):
        parser.error("window takes either --seconds or -- COMMAND")
    with LOCK_PATH.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(
                "waiting for another cache_counters.py run to finish", file=sys.stderr
            )
            fcntl.flock(lock, fcntl.LOCK_EX)
        return measure(args, command)


def measure(args: argparse.Namespace, command: list[str]) -> int:
    """Run sample, resume, or window while holding the host's lock."""
    failure = ""
    try:
        if args.action == "resume":
            print(resume_hart(args))
            return 0
        if args.action == "sample":
            print("\n".join(snapshot_lines(take_snapshot(args)[0])))
            return 0
        start: Counters = (
            take_load_snapshot(args) if args.load_waits else {"time": take_mark(args)}
        )
        if command:
            try:
                status = subprocess.run(
                    command, check=False, timeout=args.run_timeout
                ).returncode
                if status:
                    failure = f"the command exited {status}"
            except subprocess.TimeoutExpired:
                failure = f"the command ran past {args.run_timeout:g} s and was stopped"
        else:
            time.sleep(args.seconds)
        if args.load_waits:
            end = take_load_snapshot(args)
        else:
            end, previous = take_snapshot(args)
            start = {**previous, **start}
        change = deltas(start, end, distinguish_wrap=args.load_waits)
    except LoadCountersUnavailableError:
        print("FROST_LOAD_WINDOW unavailable")
        return 1
    except RuntimeError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    if args.load_waits:
        print(counter_line("FROST_LOAD_WINDOW", change, "cycles"))
        print(counter_line("FROST_LOAD_START", start, "time"))
        print(counter_line("FROST_LOAD_END", end, "time"))
    else:
        print("\n".join(report_lines(change)))
        print(counter_line("FROST_CACHE_SNAPSHOT", end, "time"))
    if failure:
        print(f"Error: {failure}", file=sys.stderr)
    return 1 if failure else 0


if __name__ == "__main__":
    sys.exit(main())
