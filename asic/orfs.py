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

"""Run FROST through OpenROAD-flow-scripts (ORFS) on the Nangate45 platform.

``./asic/orfs.py run`` prepares the sources in the frost image, runs the flow
from synthesis to GDS in the pinned ORFS image, and writes a summary. Both
images run as the invoking user with the checkout mounted at /workspace, and
everything the flow writes goes under asic/build.

``prepare`` runs inside the frost image, like tests/test_run_yosys.py: it
converts the NIC and MAC/PCS sources with sv2v. ``summary`` rereads a
finished or partial build.
"""

import argparse
import contextlib
import csv
import json
import math
import os
import re
import secrets
import signal
import subprocess
import sys
import threading
import time
from collections import defaultdict
from collections.abc import Callable, Iterable, Iterator, Sequence, Set
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
BUILD_DIRECTORY = REPOSITORY_ROOT / "asic" / "build"
# The SRAM macros' views, one directory each, from asic/openram.py.
SRAM_MACRO_DIRECTORY = REPOSITORY_ROOT / "asic" / "sram" / "macros"
SDC_PATH = REPOSITORY_ROOT / "asic" / "constraint.sdc"
# constraint.sdc reads the core clock period from this environment variable,
# which run --clock-period passes to the flow's make.
CLOCK_PERIOD_VARIABLE = "FROST_CORE_CLOCK_PERIOD"

# The ORFS 26Q4 release (commit ecb3cfdeb). Docker Hub publishes the image
# built from that commit under its git-describe tag; the digest pins it.
ORFS_IMAGE = (
    "openroad/orfs:26Q3-705-gecb3cfdeb"
    "@sha256:6da005d1c3447799f7401215174196c75ba9ec7e28417624d0c20225f85d594c"
)
ORFS_MAKEFILE = "/OpenROAD-flow-scripts/flow/Makefile"
# Where both images see the checkout and the build directory.
CONTAINER_ROOT = Path("/workspace")
CONTAINER_BUILD = CONTAINER_ROOT / "asic" / "build"

# ORFS's stages in order, as make goals: grt is global routing and route is
# detailed routing.
STAGES = ("synth", "floorplan", "place", "cts", "grt", "route", "finish")
# ORFS's targets that rerun a stage unconditionally. ORFS's do-route also
# reruns global routing, so detailed routing names its steps; finishing
# includes the GDS.
RESUME_GOALS = {
    "floorplan": ("do-floorplan",),
    "place": ("do-place",),
    "cts": ("do-cts",),
    "grt": ("do-grt",),
    "route": ("do-5_2_route", "do-5_3_fillcell", "do-5_route", "do-5_route.sdc"),
    "finish": ("do-finish", "do-gds"),
}
# ORFS's per-run layout under WORK_HOME: {kind} is logs, reports, or results.
FLOW_SUBDIRECTORY = "{kind}/nangate45/frost/base"
# The steps whose metrics hold OpenSTA's worst slack: (stage, step, prefix).
STAGE_TIMING = (
    ("Floorplan", "2_1_floorplan", "floorplan"),
    ("Global placement", "3_3_place_gp", "globalplace"),
    ("Detailed placement", "3_5_place_dp", "detailedplace"),
    ("Clock tree synthesis", "4_1_cts", "cts"),
    ("Global routing", "5_1_grt", "globalroute"),
    ("Final, extracted parasitics", "6_report", "finish"),
)

# The databases that `paths` reads, by stage, and the stage's name in its
# report.
PATH_DATABASES = {
    "place": ("3_place", "detailed placement"),
    "cts": ("4_cts", "clock tree synthesis"),
    "grt": ("5_1_grt", "global routing"),
    "final": ("6_final", "the final report"),
}
# Where `paths` logs OpenROAD, under the build directory.
PATHS_LOG_SUBDIRECTORY = "logs/paths"
# The core clock and its quarter-rate programming clock.
CORE_CLOCKS = ("core_clk", "core_clk_div4")
# asic/constraint.sdc times each clock's ports against an I/O copy of it,
# generated inside the chip and named after it with this suffix.
IO_CLOCK_SUFFIX = "_io"
# Endpoints within this many ns of the worst core clock slack are near it.
CRITICAL_WINDOW_NS = 0.1

SV2V_DEFINES = "-DSYNTHESIS"
SV2V_TIMEOUT_SECONDS = 1800

# The ORFS container's out-of-memory score, the highest: when the host runs
# out of memory, the kernel's choice of a process to stop favors the flow over
# every process with a lower score, such as a CI runner's agent.
OOM_SCORE_ADJUSTMENT = 1000
# Seconds between run's lines on the host's and the flow's memory.
MEMORY_REPORT_SECONDS = 60
# Seconds that a command which was asked to stop, or a Docker call that
# inspects or removes the flow's container, may take before run gives up on
# it, so that no cleanup can hold the flow past its CI step's time limit.
STOP_SECONDS = 60
# Seconds that an interrupted command and the processes it started get to
# stop on SIGINT before run kills them. Short, because a CI runner sends
# SIGTERM 7.5 seconds after it cancels a step and SIGKILL 2.5 seconds later;
# a removal that Docker has not finished by then is left to the workflow's
# sweep step.
INTERRUPT_SECONDS = 2
# Seconds that the summary's make elapsed may take.
SUMMARY_SECONDS = 300
# Every container that orfs.py starts carries this label, with the checkout's
# path as its value, and run's containers also have names, so that a
# container left behind, say after run itself was killed, can be found and
# removed without its ID: docker ps --all --filter label=org.frost.asic-flow.
CONTAINER_LABEL = "org.frost.asic-flow"
# Docker's smallest memory limit. A limit that rounds to zero bytes would
# mean no limit at all.
MINIMUM_MEMORY_LIMIT = 6 << 20
# Where the kernel reports the host's memory and memory stalls, and where
# the control groups of Docker's containers live.
PROC_DIRECTORY = Path("/proc")
CGROUP_DIRECTORY = Path("/sys/fs/cgroup")
GIB = 1 << 30


def _write_if_changed(path: Path, content: bytes) -> None:
    """Write content to path unless it already holds it, keeping make's timestamps."""
    if path.exists() and path.read_bytes() == content:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)


def sources_makefile(
    sources: Sequence[str], nic_source: str, include_dirs: Sequence[str] = ()
) -> str:
    """Return sources.mk with sources and header directories for asic/config.mk.

    Repository paths become $(FROST_ROOT)-relative so the list holds wherever
    the checkout is mounted; the converted NIC lives in $(WORK_HOME).
    """
    root = str(REPOSITORY_ROOT)
    lines = ["$(WORK_HOME)/src/nic.v"]
    for source in sources:
        if source == nic_source:
            continue
        resolved = str(Path(source).resolve())
        if not resolved.startswith(root + os.sep):
            raise ValueError(f"source outside the repository: {source}")
        lines.append("$(FROST_ROOT)" + resolved[len(root) :])
    body = " \\\n  ".join(lines)
    includes = []
    for directory in include_dirs:
        resolved = str(Path(directory).resolve())
        if resolved != root and not resolved.startswith(root + os.sep):
            raise ValueError(f"include directory outside the repository: {directory}")
        includes.append("$(FROST_ROOT)" + resolved[len(root) :])
    include_list = " ".join(includes)
    return (
        "# Generated by asic/orfs.py prepare from hw/rtl/frost.f.\n"
        f"export VERILOG_FILES = \\\n  {body}\n"
        f"export VERILOG_INCLUDE_DIRS = {include_list}\n"
    )


def prepare(build_directory: Path) -> None:
    """Write the flow's inputs into build_directory; run in the frost image."""
    sys.path.insert(0, str(REPOSITORY_ROOT / "tests"))
    try:
        import test_run_yosys
    finally:
        sys.path.pop(0)

    # The memories read no $readmemh images in this flow: the SRAM macros
    # have none, and the instruction memory's PC-metadata overlays read
    # their images only outside Yosys.
    runner = test_run_yosys.YosysRunner(memory_images=False)
    sources = runner.parse_filelist(runner.filelist)
    with TemporaryDirectory(prefix="frost-orfs-") as temporary:
        converted = runner.convert_nic_sources(
            sources, Path(temporary), SV2V_DEFINES, SV2V_TIMEOUT_SECONDS
        )
        nic_source = converted[0]
        if Path(nic_source).parent != Path(temporary):
            raise RuntimeError("hw/rtl/frost.f lists no NIC sources to convert")
        _write_if_changed(
            build_directory / "src" / "nic.v", Path(nic_source).read_bytes()
        )
        makefile = sources_makefile(converted, nic_source, sorted(runner.include_dirs))
    _write_if_changed(build_directory / "sources.mk", makefile.encode())
    print(f"Prepared {len(converted)} sources in {build_directory}")


def container_name(purpose: str) -> str:
    """Return a name for one of run's containers that no other run uses."""
    return f"frost-asic-{purpose}-{os.getpid()}-{secrets.token_hex(4)}"


def orfs_command(
    make_arguments: Sequence[str],
    *,
    uid: int,
    gid: int,
    name: str | None = None,
    memory_limit: int | None = None,
    cidfile: Path | None = None,
) -> list[str]:
    """Return the docker command that runs ORFS's Makefile in the pinned image.

    The container carries CONTAINER_LABEL. With name, it has that name from
    its creation, so that the caller can remove it before Docker reports its
    ID. With memory_limit, it holds at most that many bytes of RAM and keeps
    the rest of what it needs in the host's swap space. With cidfile, Docker
    writes the container's ID there and keeps the container when it stops,
    so that the caller can ask whether the kernel stopped it for memory
    before removing it.
    """
    removal = ["--rm"] if cidfile is None else [f"--cidfile={cidfile}"]
    naming = [] if name is None else ["--name", name]
    memory = (
        [] if memory_limit is None else [f"--memory={memory_limit}", "--memory-swap=-1"]
    )
    return [
        "docker",
        "run",
        *removal,
        *naming,
        "--label",
        f"{CONTAINER_LABEL}={REPOSITORY_ROOT}",
        "--init",
        f"--oom-score-adj={OOM_SCORE_ADJUSTMENT}",
        *memory,
        "--user",
        f"{uid}:{gid}",
        "--env",
        "HOME=/tmp",
        "--volume",
        f"{REPOSITORY_ROOT}:{CONTAINER_ROOT}",
        "--workdir",
        str(CONTAINER_BUILD),
        ORFS_IMAGE,
        "make",
        f"--file={ORFS_MAKEFILE}",
        f"DESIGN_CONFIG={CONTAINER_ROOT}/asic/config.mk",
        f"WORK_HOME={CONTAINER_BUILD}",
        *make_arguments,
    ]


# Global placement's Nesterov table: iteration, overflow, then HPWL in um.
NESTEROV_ROW = re.compile(r"^\s*(\d+) \|\s+[-\d.]+ \|\s+([-\d.]+e[+-]\d+) \|")
# A placement that converges ends with a wirelength under about ten times its
# first iteration's. One that diverges grows it a hundredfold and runs to
# OpenROAD's 5,000-iteration limit (GPL-1010), hours later. This stops it in
# minutes, and stops at once on the limit's warning.
PLACEMENT_MAX_HPWL_GROWTH = 30.0
PLACEMENT_ITERATION_LIMIT_WARNING = "GPL-1010"


class PlacementWatchdog:
    """Report when a global placement's Nesterov table shows it diverging."""

    def __init__(self) -> None:
        """Start without a placement's first wirelength."""
        self.first_hpwl: float | None = None

    def check(self, line: str) -> str | None:
        """Return why the flow should stop after this log line, if it should."""
        if PLACEMENT_ITERATION_LIMIT_WARNING in line:
            return "global placement reached OpenROAD's iteration limit"
        if "Execute Nesterov Global Placement" in line:
            self.first_hpwl = None
            return None
        match = NESTEROV_ROW.match(line)
        if match is None:
            return None
        iteration, hpwl = int(match.group(1)), float(match.group(2))
        if self.first_hpwl is None:
            self.first_hpwl = hpwl
            return None
        if hpwl > PLACEMENT_MAX_HPWL_GROWTH * self.first_hpwl:
            return (
                f"global placement diverged: wirelength {hpwl:.3e} um at iteration "
                f"{iteration} is over {PLACEMENT_MAX_HPWL_GROWTH:g} times its "
                f"first iteration's {self.first_hpwl:.3e} um"
            )
        return None


def run_logged(
    command: Sequence[str],
    log_path: Path,
    environment: dict[str, str] | None = None,
    watchdog: PlacementWatchdog | None = None,
    report: Callable[[], str | None] | None = None,
    report_seconds: float = MEMORY_REPORT_SECONDS,
) -> int:
    """Run command, echoing its output and appending it to log_path.

    With a watchdog, stop the command when it reports a failure and return 1.
    With report, add the line it returns every report_seconds while the
    command runs, however long the command stays silent.
    """
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as log:
        lock = threading.Lock()

        def emit(text: str) -> None:
            with lock:
                sys.stdout.write(text)
                sys.stdout.flush()
                log.write(text)
                log.flush()

        emit(f"$ {' '.join(command)}\n")
        done = threading.Event()

        def report_periodically() -> None:
            assert report is not None
            while not done.wait(report_seconds):
                # A report that fails must not stop the flow it describes.
                try:
                    line = report()
                except Exception as error:
                    line = f"Memory report failed: {error}"
                if line is not None:
                    emit(line + "\n")

        reporter = threading.Thread(target=report_periodically, daemon=True)
        # In a process group of its own, so that an interruption reaches the
        # command's own children too, such as frost.py's docker client.
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            env=environment,
            start_new_session=True,
        )
        assert process.stdout is not None
        # Kills the command if it has not closed its output STOP_SECONDS
        # after the watchdog asked it to stop.
        killer = threading.Timer(STOP_SECONDS, process.kill)
        killer.daemon = True
        stopped = False
        try:
            if report is not None:
                reporter.start()
            for line in process.stdout:
                emit(line)
                reason = (
                    watchdog.check(line)
                    if watchdog is not None and not stopped
                    else None
                )
                if reason is not None:
                    emit(f"Error: {reason}; stopping the flow\n")
                    # Keep reading until the command closes its output, so that
                    # what it writes while stopping cannot fill the pipe.
                    process.terminate()
                    killer.start()
                    stopped = True
            status = process.wait()
        except BaseException:
            # Interrupted, say by a signal: leave no command behind.
            with _signals_ignored():
                _interrupt(process)
            raise
        finally:
            killer.cancel()
            done.set()
            if reporter.is_alive():
                reporter.join(timeout=STOP_SECONDS)
            process.stdout.close()
        return 1 if stopped else status


@contextlib.contextmanager
def _signals_ignored() -> Iterator[None]:
    """Ignore SIGINT and SIGTERM, so that a second signal cannot cut a cleanup short."""
    previous = {
        number: signal.signal(number, signal.SIG_IGN)
        for number in (signal.SIGINT, signal.SIGTERM)
    }
    try:
        yield
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def _interrupt(process: subprocess.Popen[str]) -> None:
    """Stop an interrupted command and every process in its group.

    SIGINT first, which a docker client passes on to its container, then
    SIGKILL; each wait is bounded.
    """
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGINT)
    with contextlib.suppress(subprocess.TimeoutExpired):
        process.wait(timeout=INTERRUPT_SECONDS)
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGKILL)
    try:
        process.wait(timeout=STOP_SECONDS)
    except subprocess.TimeoutExpired:
        print(
            f"Warning: process {process.pid} did not stop within {STOP_SECONDS} seconds",
            file=sys.stderr,
        )


def _report(message: str, log_path: Path) -> None:
    """Print a message and add it to the log; a full disk loses only the log line."""
    print(message, file=sys.stderr)
    try:
        with log_path.open("a", encoding="utf-8") as log:
            log.write(message + "\n")
    except OSError as error:
        print(
            f"Warning: could not add that line to {log_path}: {error}", file=sys.stderr
        )


def meminfo(text: str) -> dict[str, int]:
    """Return the fields of /proc/meminfo in bytes."""
    fields = {}
    for line in text.splitlines():
        name, _, value = line.partition(":")
        parts = value.split()
        if parts and parts[0].isdigit():
            fields[name] = int(parts[0]) * (1024 if parts[1:] == ["kB"] else 1)
    return fields


def memory_stalls(text: str) -> dict[str, float]:
    """Return the shares in % of the last minute that tasks waited for memory.

    /proc/pressure/memory reports "some", when at least one task waited,
    and "full", when every task that could run waited.
    """
    stalls = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        kind, *fields = line.split()
        values = dict(field.partition("=")[::2] for field in fields)
        if "avg60" in values:
            stalls[kind] = float(values["avg60"])
    return stalls


def container_cgroup(container: str, cgroups: Path = CGROUP_DIRECTORY) -> Path | None:
    """Return a Docker container's control group directory, or None.

    Docker puts each container's group under system.slice with systemd's
    group driver and under docker with its own.
    """
    for directory in (
        cgroups / "system.slice" / f"docker-{container}.scope",
        cgroups / "docker" / container,
    ):
        if (directory / "memory.current").is_file():
            return directory
    return None


def _read(path: Path) -> str | None:
    """Return a file's text, or None if it cannot be read."""
    try:
        return path.read_text()
    except OSError:
        return None


def _gib(size: int) -> str:
    """Format a size in bytes in GiB with one decimal."""
    return f"{size / GIB:.1f}"


def _duration(seconds: float) -> str:
    """Format seconds as hours, minutes, and seconds."""
    minutes, second = divmod(int(seconds), 60)
    hour, minute = divmod(minutes, 60)
    return f"{hour}:{minute:02d}:{second:02d}"


class MemoryReport:
    """Describe the host's memory and swap, and the flow container's, in a line."""

    def __init__(
        self,
        cidfile: Path | None = None,
        proc: Path = PROC_DIRECTORY,
        cgroups: Path = CGROUP_DIRECTORY,
    ) -> None:
        """Measure time from now; find the container through the ID in cidfile."""
        self.cidfile = cidfile
        self.proc = proc
        self.cgroups = cgroups
        self.start = time.monotonic()

    def _container(self) -> str | None:
        """Return the container's memory and swap use and its limit, or None."""
        if self.cidfile is None:
            return None
        container = (_read(self.cidfile) or "").strip()
        directory = container_cgroup(container, self.cgroups) if container else None
        if directory is None:
            return None
        current = _read(directory / "memory.current")
        swap = _read(directory / "memory.swap.current")
        limit = (_read(directory / "memory.max") or "max").strip()
        if current is None or not current.strip().isdigit():
            return None
        text = f"flow container {_gib(int(current))}"
        if limit.isdigit():
            text += f" of {_gib(int(limit))}"
        text += " GiB"
        # The rest of the container's RAM is file cache, which the kernel
        # can drop without swapping.
        stat = dict(
            line.split(maxsplit=1)
            for line in (_read(directory / "memory.stat") or "").splitlines()
            if line.strip()
        )
        if stat.get("anon", "").strip().isdigit():
            text += f" ({_gib(int(stat['anon']))} GiB anonymous)"
        if swap is not None and swap.strip().isdigit():
            text += f", swap {_gib(int(swap))} GiB"
        return text + _stall_text(_read(directory / "memory.pressure"))

    def __call__(self) -> str | None:
        """Return the line, or None if the host does not report its memory."""
        fields = meminfo(_read(self.proc / "meminfo") or "")
        if "MemTotal" not in fields or "MemAvailable" not in fields:
            return None
        total, available = fields["MemTotal"], fields["MemAvailable"]
        swap_total = fields.get("SwapTotal", 0)
        swap_used = swap_total - fields.get("SwapFree", swap_total)
        parts = [
            f"host RAM {_gib(total - available)} of {_gib(total)} GiB in use, "
            f"swap {_gib(swap_used)} of {_gib(swap_total)} GiB"
            + _stall_text(_read(self.proc / "pressure" / "memory"))
        ]
        container = self._container()
        if container is not None:
            parts.append(container)
        elapsed = _duration(time.monotonic() - self.start)
        return f"Memory after {elapsed}: {'; '.join(parts)}"


def _stall_text(pressure: str | None) -> str:
    """Describe a memory.pressure file's last minute, or return "" without one."""
    stalls = memory_stalls(pressure or "")
    if "some" not in stalls:
        return ""
    text = f", waiting for memory {stalls['some']:.0f}% of the last minute"
    if "full" in stalls:
        text += f", every task {stalls['full']:.0f}%"
    return text


def _docker(arguments: Sequence[str]) -> subprocess.CompletedProcess[str] | str:
    """Run a short Docker command; return its result, or why it gave none.

    Output that is not UTF-8 is decoded with replacement characters.
    """
    try:
        return subprocess.run(
            ["docker", *arguments],
            capture_output=True,
            text=True,
            errors="replace",
            check=False,
            timeout=STOP_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return f"it did not finish within {STOP_SECONDS} seconds"
    except OSError as error:
        return f"it could not start: {error}"


def stopped_for_memory(container: str) -> bool | None:
    """Return whether the kernel stopped a process in the container for memory.

    None means that Docker could not say: it failed, or answered neither
    true nor false.
    """
    result = _docker(["inspect", "--format", "{{.State.OOMKilled}}", container])
    if isinstance(result, str) or result.returncode != 0:
        return None
    return {"true": True, "false": False}.get(result.stdout.strip())


def remove_container(container: str) -> str | None:
    """Stop and remove a container, whatever state it is in.

    Return None once it is gone, also when it never existed, for which
    docker rm --force succeeds, or why it may still be there.
    """
    result = _docker(["rm", "--force", container])
    if isinstance(result, str):
        return f"Docker did not remove container {container}: {result}"
    if result.returncode != 0:
        reason = (
            result.stderr.strip() or f"docker rm exited with status {result.returncode}"
        )
        return f"Docker did not remove container {container}: {reason}"
    return None


def _interruption(signum: int) -> BaseException:
    """Return the exception with which a signal unwinds run or summary."""
    if signum == signal.SIGINT:
        return KeyboardInterrupt()
    return SystemExit(128 + signum)


class _Signals:
    """The handler for SIGINT and SIGTERM while run or summary works.

    A signal raises its exception, KeyboardInterrupt or SystemExit(143), which
    unwinds through the cleanup of the commands and containers started so
    far. While deferring is set, during that cleanup, a signal is recorded
    instead, and honor raises it once the cleanup is done.
    """

    def __init__(self) -> None:
        """Start with no signal recorded, outside a cleanup."""
        self.deferring = False
        self.deferred: list[int] = []

    def __call__(self, signum: int, frame: object) -> None:
        """Raise the signal's exception, or record the signal during a cleanup."""
        if self.deferring:
            self.deferred.append(signum)
            return
        raise _interruption(signum)

    def honor(self) -> None:
        """Raise the exception of the first signal recorded during a cleanup."""
        if self.deferred:
            raise _interruption(self.deferred[0])


@contextlib.contextmanager
def _signals_handled(signals: _Signals) -> Iterator[None]:
    """Make signals the handler of SIGINT and SIGTERM, then restore the old ones."""
    previous = {
        number: signal.signal(number, signals)
        for number in (signal.SIGINT, signal.SIGTERM)
    }
    try:
        yield
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


@dataclass(frozen=True)
class MemoryLimit:
    """The ORFS container's RAM: a size in GiB, or a share of the host's RAM."""

    size_gib: float | None = None
    percent: float | None = None

    def size(self, host_ram: Callable[[], int]) -> int:
        """Return the limit in bytes; host_ram gives the host's RAM in bytes.

        Only a share of the RAM asks for it, so that a size in GiB works on a
        host that does not report its memory. A limit below Docker's smallest
        raises ValueError, since one that rounds to zero would be no limit.
        """
        if self.percent is not None:
            size = int(host_ram() * self.percent / 100)
        else:
            assert self.size_gib is not None
            size = int(self.size_gib * GIB)
        if size < MINIMUM_MEMORY_LIMIT:
            raise ValueError(
                f"a memory limit of {size:,} bytes is below Docker's smallest, 6 MiB"
            )
        return size


def host_ram(proc: Path = PROC_DIRECTORY) -> int:
    """Return the host's RAM in bytes."""
    fields = meminfo(_read(proc / "meminfo") or "")
    if "MemTotal" not in fields:
        raise RuntimeError(f"{proc / 'meminfo'} reports no MemTotal")
    return fields["MemTotal"]


def default_clock_period() -> float:
    """Return the core clock period in ns that asic/constraint.sdc sets by default."""
    match = re.search(r"^set clk_period (\S+)$", SDC_PATH.read_text(), re.M)
    if match is None:
        raise RuntimeError(f"{SDC_PATH} sets no default clk_period")
    return float(match[1])


def built_clock_period(
    build_directory: Path, clock_name: str = "core_clk"
) -> float | None:
    """Clock periods come from written stage constraints.

    Synthesis evaluates constraint.sdc, and OpenSTA writes the result next to
    each stage's database, so any of those SDC files holds the period.
    """
    results = build_directory / FLOW_SUBDIRECTORY.format(kind="results")
    for sdc in sorted(results.glob("*.sdc")):
        match = re.search(
            rf"^create_clock -name {re.escape(clock_name)} -period ([\d.]+) ",
            sdc.read_text(),
            re.M,
        )
        if match:
            return float(match[1])
    return None


def format_period(period: float) -> str:
    """Format a period in ns with the four decimals of the flow's SDC files."""
    return f"{period:.4f}".rstrip("0").rstrip(".")


def make_variables(
    num_cores: int, clock_period: float | None, cpu_clock_period: float | None = None
) -> list[str]:
    """Return the variables that the flow's make takes from the command line."""
    variables = [f"NUM_CORES={num_cores}"]
    if clock_period is not None:
        variables.append(f"{CLOCK_PERIOD_VARIABLE}={format_period(clock_period)}")
    if cpu_clock_period is not None:
        variables.append(f"FROST_CPU_CLOCK_PERIOD={format_period(cpu_clock_period)}")
    return variables


def make_goals(first: str | None, last: str) -> list[str]:
    """Return the make goals that run the flow through stage last.

    With no first stage, make runs every stage whose inputs changed. Otherwise
    ORFS's do- targets rerun first through last unconditionally, from the
    results of the stage before first, whatever the files' timestamps.
    """
    if first is None:
        return [last]
    stages = STAGES[STAGES.index(first) : STAGES.index(last) + 1]
    if not stages:
        raise ValueError(f"--from {first} comes after --target {last}")
    return [goal for stage in stages for goal in RESUME_GOALS[stage]]


def run(args: argparse.Namespace) -> int:
    """Prepare the sources unless resuming, run the flow, and summarize it."""
    try:
        goals = make_goals(args.first, args.target)
    except ValueError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2
    if args.first is not None and not (BUILD_DIRECTORY / "sources.mk").exists():
        print(
            f"Error: --from needs an earlier build in {BUILD_DIRECTORY}",
            file=sys.stderr,
        )
        return 2
    if args.first is not None and (
        args.clock_period is not None or args.cpu_clock_period is not None
    ):
        print(
            "Error: the clock period takes effect at synthesis; "
            "--clock-period and --cpu-clock-period cannot be combined with --from",
            file=sys.stderr,
        )
        return 2
    if args.first is None:
        # Make does not see a changed period, so it would keep stale stages.
        requested = args.clock_period or default_clock_period()
        built = built_clock_period(BUILD_DIRECTORY)
        if built is not None and format_period(built) != format_period(requested):
            print(
                f"Error: {BUILD_DIRECTORY} holds a build with a "
                f"{format_period(built)} ns core clock; delete it to run the flow "
                f"at {format_period(requested)} ns",
                file=sys.stderr,
            )
            return 2
    built_cpu_period = built_clock_period(BUILD_DIRECTORY, "cpu_clk")
    if args.first is None and built_clock_period(BUILD_DIRECTORY) is not None:
        if built_cpu_period != args.cpu_clock_period:
            print(
                "Error: CPU clock configuration differs from the build; use an empty build directory",
                file=sys.stderr,
            )
            return 2
    cpu_period = built_cpu_period if args.first is not None else args.cpu_clock_period
    try:
        memory_limit = (
            None if args.memory_limit is None else args.memory_limit.size(host_ram)
        )
    except (RuntimeError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2
    BUILD_DIRECTORY.mkdir(parents=True, exist_ok=True)
    log_path = BUILD_DIRECTORY / "orfs.log"
    # From here on SIGTERM unwinds run as SIGINT does, so that the commands it
    # started, preparation's included, and their containers stop.
    signals = _Signals()
    with _signals_handled(signals):
        if args.first is None:
            log_path.unlink(missing_ok=True)
            status = prepare_in_frost_image(args.frost_image, log_path)
            if status != 0:
                return status
        make_arguments = [
            *make_variables(args.num_cores, args.clock_period, cpu_period),
            *goals,
        ]
        return _run_flow(make_arguments, memory_limit, log_path, signals)


def _run_flow(
    make_arguments: Sequence[str],
    memory_limit: int | None,
    log_path: Path,
    signals: _Signals,
) -> int:
    """Run the flow's make in its container, remove the container, and summarize.

    The status is the flow's if it failed, whatever the diagnostics after it
    do. Otherwise it is 1 if Docker did not remove the container, and the
    summary's status if it did. A signal during the removal stops run once
    the container is gone.
    """
    uid, gid = os.getuid(), os.getgid()
    name = container_name("flow")
    flow_status: int | None = None
    out_of_memory: bool | None = False
    removal_error: str | None = None
    with TemporaryDirectory(prefix="frost-orfs-") as temporary:
        cidfile = Path(temporary) / "container"
        try:
            flow_status = run_logged(
                orfs_command(
                    make_arguments,
                    uid=uid,
                    gid=gid,
                    name=name,
                    memory_limit=memory_limit,
                    cidfile=cidfile,
                ),
                log_path,
                watchdog=PlacementWatchdog(),
                report=MemoryReport(cidfile),
            )
        finally:
            # From here a signal is recorded, not raised, until the container
            # is gone. CPython 3.12 and later, which this repository requires,
            # run signal handlers only on calls and loop iterations, and this
            # first statement is neither, so no signal can come between the
            # flow's end and the flag and skip the removal.
            signals.deferring = True
            try:
                # The container stays after it stops, so that Docker can say
                # whether the kernel stopped it for memory; a question that
                # fails leaves that unknown. The container is removed by its
                # name, which it has from its creation, so also when run is
                # interrupted before Docker reports its ID. Each Docker call
                # is bounded.
                if flow_status not in (None, 0):
                    try:
                        out_of_memory = stopped_for_memory(name)
                    except Exception as error:
                        out_of_memory = None
                        _report(
                            f"Warning: could not ask Docker about memory: {error}",
                            log_path,
                        )
                removal_error = remove_container(name)
                if removal_error is not None:
                    _report(
                        f"Error: {removal_error}; remove it with: "
                        f"docker rm --force {name}",
                        log_path,
                    )
            finally:
                signals.deferring = False
    signals.honor()
    assert flow_status is not None
    if out_of_memory:
        allowed = "the host's RAM and swap space"
        if memory_limit is not None:
            allowed = f"{_gib(memory_limit)} GiB of RAM and the host's swap space"
        _report(
            "Error: the kernel stopped the flow for lack of memory; "
            f"its container may use {allowed}",
            log_path,
        )
    elif out_of_memory is None:
        _report(
            "Warning: Docker could not say whether the kernel stopped the flow "
            "for lack of memory",
            log_path,
        )
    try:
        summary_status = summarize(uid=uid, gid=gid, signals=signals)
    except Exception as error:
        # A summary that fails must not hide the flow's own status.
        _report(f"Error: the summary failed: {error}", log_path)
        summary_status = 1
    if flow_status != 0:
        _report(f"Error: the flow failed with status {flow_status}", log_path)
        return flow_status
    if removal_error is not None:
        return 1
    return summary_status


def prepare_in_frost_image(frost_image: str, log_path: Path) -> int:
    """Run the prepare command in the frost image and return its status."""
    frost = [
        sys.executable,
        str(REPOSITORY_ROOT / "scripts" / "frost.py"),
        "--image",
        frost_image,
        "run",
        "python3",
        "asic/orfs.py",
        "prepare",
    ]
    # sv2v needs no submodules.
    environment = {**os.environ, "FROST_SKIP_SUBMODULE_INIT": "1"}
    status = run_logged(frost, log_path, environment)
    if status != 0:
        print(f"Error: source preparation failed with status {status}", file=sys.stderr)
    return status


def _metrics(build_directory: Path, step: str) -> dict[str, object]:
    """Return a step's ORFS metrics, or an empty dict if the step has not run."""
    path = build_directory / FLOW_SUBDIRECTORY.format(kind="logs") / f"{step}.json"
    try:
        loaded = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return loaded if isinstance(loaded, dict) else {}


def _number(value: object, digits: int = 0) -> str:
    """Format a metric with thousands separators, or a dash if it is missing."""
    if isinstance(value, bool) or not isinstance(value, int | float):
        return "-"
    return f"{value:,.{digits}f}"


def summary_markdown(build_directory: Path, elapsed: str) -> str:
    """Return a Markdown summary of the cell counts, slack, and run time."""
    synth = _metrics(build_directory, "1_synth")
    final = _metrics(build_directory, "6_report")
    route = _metrics(build_directory, "5_2_route")
    lines = ["# FROST on Nangate45", ""]
    period = built_clock_period(build_directory)
    if period is not None:
        lines += [f"Core clock period: {format_period(period)} ns.", ""]
    lines += [
        "| Metric | After synthesis | Final |",
        "| --- | ---: | ---: |",
        "| Standard cells | "
        f"{_number(synth.get('synth__design__instance__count__stdcell'))} | "
        f"{_number(final.get('finish__design__instance__count__stdcell'))} |",
        "| Standard-cell area (um^2) | "
        f"{_number(synth.get('synth__design__instance__area__stdcell'))} | "
        f"{_number(final.get('finish__design__instance__area__stdcell'))} |",
        "| SRAM macros | "
        f"{_number(synth.get('synth__design__instance__count__macros'))} | "
        f"{_number(final.get('finish__design__instance__count__macros'))} |",
        "| SRAM macro area (um^2) | "
        f"{_number(synth.get('synth__design__instance__area__macros'))} | "
        f"{_number(final.get('finish__design__instance__area__macros'))} |",
        f"| Die area (um^2) | | {_number(final.get('finish__design__die__area'))} |",
        "| Standard-cell utilization | | "
        f"{_number(final.get('finish__design__instance__utilization__stdcell'), 3)} |",
        "| Detailed-route DRC errors | | "
        f"{_number(route.get('detailedroute__route__drc_errors'))} |",
        "",
    ]

    lines += [
        "## Worst slack after each stage",
        "",
        "| Stage | Setup (ns) | Hold (ns) |",
        "| --- | ---: | ---: |",
    ]
    for stage, step, prefix in STAGE_TIMING:
        metrics = _metrics(build_directory, step)
        if metrics:
            lines.append(
                f"| {stage} | {_number(metrics.get(f'{prefix}__timing__setup__ws'), 3)}"
                f" | {_number(metrics.get(f'{prefix}__timing__hold__ws'), 3)} |"
            )
    lines.append("")

    reports = build_directory / FLOW_SUBDIRECTORY.format(kind="reports")
    slack = reports / "6_clock_slack.rpt"
    lines += ["## Final worst slack by capture clock", ""]
    if slack.exists():
        rows = [row.split() for row in slack.read_text().splitlines() if row.strip()]
        lines += ["| Clock | Period (ns) | Setup (ns) | Hold (ns) |"]
        lines += ["| --- | ---: | ---: | ---: |"]
        lines += [f"| {' | '.join(row)} |" for row in rows[1:] if len(row) == 4]
    else:
        lines += ["The final report has not run."]
    lines += ["", "## Elapsed time and peak memory", "", "```", elapsed.strip(), "```"]

    macros = sram_macros(reports / "synth_stat.txt")
    if macros:
        lines += [
            "",
            "## SRAM macros",
            "",
            "| Macro | Instances | Size (um) | Area (um^2) |",
            "| --- | ---: | --- | ---: |",
        ]
        for name, count in macros:
            size = macro_size(name)
            if size is None:
                lines.append(f"| `{name}` | {count:,} | - | - |")
            else:
                width, height = size
                lines.append(
                    f"| `{name}` | {count:,} | {width:g} x {height:g} | "
                    f"{count * width * height:,.0f} |"
                )

    mocked = mocked_memories(
        build_directory / FLOW_SUBDIRECTORY.format(kind="logs") / "1_2_yosys.log"
    )
    if mocked:
        lines += [
            "",
            "## Memories mocked as one row",
            "",
            "| Memory | Rows | Width |",
            "| --- | ---: | ---: |",
        ]
        lines += [f"| `{name}` | {rows:,} | {width} |" for name, rows, width in mocked]
    return "\n".join(lines) + "\n"


def sram_macros(synth_stat: Path) -> list[tuple[str, int]]:
    """Return (macro, instances) for each SRAM macro in the synthesized design.

    The design hierarchy at the end of Yosys's statistics counts each cell
    type over the whole design.
    """
    try:
        statistics = synth_stat.read_text(errors="replace")
    except OSError:
        return []
    hierarchy = statistics.rpartition("=== design hierarchy ===")[2]
    return [
        (match[2], int(match[1]))
        for match in re.finditer(
            r"^\s*(\d+)\s+\S+\s+\S+\s+\S+\s+(sram_\w+)\s*$", hierarchy, re.M
        )
    ]


def macro_size(
    name: str, directory: Path = SRAM_MACRO_DIRECTORY
) -> tuple[float, float] | None:
    """Return an SRAM macro's width and height in um from its LEF, or None."""
    try:
        lef = (directory / name / f"{name}.lef").read_text()
    except OSError:
        return None
    match = re.search(r"^\s*SIZE\s+([\d.]+)\s+BY\s+([\d.]+)\s*;", lef, re.M)
    return (float(match[1]), float(match[2])) if match else None


def mocked_memories(yosys_log: Path) -> list[tuple[str, int, int]]:
    """Return (memory, rows, width) for each memory synthesis shrank, largest first.

    ORFS logs every inferred memory's dimensions and then each one it shrinks
    to a single row (SYNTH_MOCK_LARGE_MEMORIES).
    """
    try:
        log = yosys_log.read_text(errors="replace")
    except OSError:
        return []
    dimensions = {
        match[1]: (int(match[2]), int(match[3]))
        for match in re.finditer(
            r"^Memory (\S+) has dimensions (\d+) x (\d+) =", log, re.M
        )
    }
    shrunk = re.findall(r"^Shrunk memory (\S+) from \d+ rows to 1$", log, re.M)
    memories = [(name, *dimensions[name]) for name in shrunk if name in dimensions]
    return sorted(memories, key=lambda memory: (-memory[1] * memory[2], memory[0]))


def summarize(*, uid: int, gid: int, signals: _Signals | None = None) -> int:
    """Write elapsed.txt and summary.md into the build directory and print them.

    With signals, a signal during the removal of make elapsed's container
    takes effect once it is gone.
    """
    # Docker would create a missing working directory as root.
    if not BUILD_DIRECTORY.is_dir():
        print(
            f"Error: {BUILD_DIRECTORY} does not exist; run the flow first",
            file=sys.stderr,
        )
        return 1
    name = container_name("summary")
    elapsed: subprocess.CompletedProcess[str] | None = None
    failure: str | None = None
    try:
        elapsed = subprocess.run(
            orfs_command(["elapsed"], uid=uid, gid=gid, name=name),
            capture_output=True,
            text=True,
            errors="replace",
            check=False,
            timeout=SUMMARY_SECONDS,
        )
    except subprocess.TimeoutExpired:
        failure = f"make elapsed did not finish within {SUMMARY_SECONDS} seconds"
    except OSError as error:
        failure = f"make elapsed could not start: {error}"
    finally:
        # A docker client that fails, also after Docker made the container
        # (status 125), times out, or is interrupted can leave the container,
        # which --rm removes only when it runs to its end.
        if signals is not None:
            signals.deferring = True
        try:
            if elapsed is None or elapsed.returncode != 0:
                removal_error = remove_container(name)
                if removal_error is not None:
                    print(
                        f"Error: {removal_error}; remove it with: "
                        f"docker rm --force {name}",
                        file=sys.stderr,
                    )
        finally:
            if signals is not None:
                signals.deferring = False
    if signals is not None:
        signals.honor()
    if elapsed is None:
        print(f"Error: {failure}", file=sys.stderr)
        return 1
    try:
        (BUILD_DIRECTORY / "elapsed.txt").write_text(elapsed.stdout + elapsed.stderr)
        summary = summary_markdown(BUILD_DIRECTORY, elapsed.stdout)
        (BUILD_DIRECTORY / "summary.md").write_text(summary)
    except OSError as error:
        print(f"Error: could not write the summary: {error}", file=sys.stderr)
        return 1
    print(summary)
    return elapsed.returncode


@dataclass(frozen=True)
class TimingPath:
    """The worst setup path to one endpoint, as asic/critical_paths.tcl writes it.

    Times are in ns. launched is the arrival time at the startpoint, the
    register's output or the input port; cells counts the cells after it,
    and buffers those of them that are buffers or inverters. The register
    table also records the launch and capture clock edges, without latency.
    """

    capture: str
    launch: str
    slack: float
    launched: float
    arrival: float
    required: float
    skew: float
    cells: int
    buffers: int
    startpoint: str
    endpoint: str
    launch_edge: float | None
    capture_edge: float | None


def read_paths(table: Path) -> list[TimingPath]:
    """Read the table of paths that asic/critical_paths.tcl writes."""
    with table.open(newline="") as handle:
        return [
            TimingPath(
                capture=row["capture"],
                launch=row["launch"],
                slack=float(row["slack"]),
                launched=float(row["launched"]),
                arrival=float(row["arrival"]),
                required=float(row["required"]),
                skew=float(row["skew"]),
                cells=int(row["cells"]),
                buffers=int(row["buffers"]),
                startpoint=row["startpoint"],
                endpoint=row["endpoint"],
                launch_edge=(
                    float(row["launch_edge"])
                    if row.get("launch_edge", "-") != "-"
                    else None
                ),
                capture_edge=(
                    float(row["capture_edge"])
                    if row.get("capture_edge", "-") != "-"
                    else None
                ),
            )
            for row in csv.DictReader(handle, delimiter="\t", quoting=csv.QUOTE_NONE)
        ]


def clock_periods(sdc: str) -> dict[str, float]:
    """Return each clock's period in ns from an SDC file that OpenSTA wrote.

    A generated clock has its master's period over its divisor; its master
    is the clock created on its source port.
    """
    periods: dict[str, float] = {}
    sources: dict[str, str] = {}
    for name, period, port in re.findall(
        r"^create_clock -name (\S+) -period (\S+) .*\[get_ports \{([^}]+)\}\]",
        sdc,
        re.M,
    ):
        periods[name] = float(period)
        sources[port] = name
    for name, port, divisor in re.findall(
        r"^create_generated_clock -name (\S+) -source \[get_ports \{([^}]+)\}\] "
        r"-divide_by (\d+) ",
        sdc,
        re.M,
    ):
        periods[name] = periods[sources[port]] / int(divisor)
    return periods


def master_clock(clock: str) -> str:
    """Return the clock that an I/O copy is generated from, or the clock itself."""
    return clock.removesuffix(IO_CLOCK_SUFFIX)


def port_names(sdc: str) -> set[str]:
    """Return the ports that an SDC file that OpenSTA wrote constrains."""
    return set(re.findall(r"get_ports \{([^}]+)\}", sdc))


# Hierarchy separators: Yosys joins flattened names with dots, and OpenROAD
# joins the modules that synthesis kept with slashes. Dots inside brackets
# belong to the name.
_SCOPE_SEPARATOR = re.compile(r"[./](?![^\[]*\])")


def block(point: str, ports: Set[str] = frozenset(), levels: int = 4) -> str:
    """Return the block of a path's startpoint or endpoint.

    A register's block is the first levels of its hierarchy, or "top" for a
    register at the top level; the ports form the block "ports". Four levels
    reach a unit of the core, such as cpu.hart.cpu_inst.u_tomasulo.
    """
    if point in ports:
        return "ports"
    scopes = _SCOPE_SEPARATOR.split(point)[:-1]
    return ".".join(scopes[:levels]) if scopes else "top"


# A register of a memory's row: the memory, the row, and the bit index unless
# the memory is one bit wide.
_ROW = re.compile(r"^(?P<memory>.+?)\[(?P<row>\d+)\](?:\[\d+\])?\$_")


def mocked_rows(points: Iterable[str], memories: Iterable[str]) -> set[str]:
    """Return the points that are registers of a mocked memory's single row.

    memories are Yosys's module/memory names. In the netlist, the row's
    registers carry the memory's instance path, row 0, and the bit; an array
    of the same name with a second row is not mocked.
    """
    names = [memory.split("/", 1)[-1] for memory in memories]
    flat = {point: point.replace("/", ".") for point in points}
    rows = {
        match["memory"]
        for match in map(_ROW.match, flat.values())
        if match and match["row"] != "0"
    }
    mocked = set()
    for point, name in flat.items():
        match = _ROW.match(name)
        if match is None or match["row"] != "0" or match["memory"] in rows:
            continue
        memory = match["memory"]
        if any(memory == mock or memory.endswith("." + mock) for mock in names):
            mocked.add(point)
    return mocked


# An SRAM macro: asic/sram names every macro instance u_macro.
_SRAM_MACRO = re.compile(r"(?:^|[./])u_macro$")


def _path_note(
    path: TimingPath, mocked: set[str], ports: set[str], clocks: bool = True
) -> str:
    """Describe what makes a path differ from one between core registers."""
    notes = []
    if clocks and master_clock(path.launch) != master_clock(path.capture):
        notes.append(f"from {master_clock(path.launch)}")
    if path.startpoint in mocked:
        notes.append("reads a mocked memory")
    if path.endpoint in mocked:
        notes.append("writes a mocked memory")
    if _SRAM_MACRO.search(path.startpoint):
        notes.append("from an SRAM macro")
    if _SRAM_MACRO.search(path.endpoint):
        notes.append("to an SRAM macro")
    if path.startpoint in ports:
        notes.append("from an input")
    if path.endpoint in ports:
        notes.append("to an output")
    return "; ".join(notes)


def core_cycles(path: TimingPath, period: float) -> float:
    """Return the core periods between a path's launch and capture clock edges."""
    if path.launch_edge is None or path.capture_edge is None:
        raise ValueError("register path has no clock edges; rerun the paths report")
    cycles = (path.capture_edge - path.launch_edge) / period
    if cycles <= 0:
        raise ValueError("register path must have a positive clock edge span")
    return cycles


def path_fmax(path: TimingPath, period: float) -> float:
    """Return the core clock frequency in MHz at which a register path just fits.

    If its clock edges span f core periods, its minimum period is P - slack/f.
    Clock skew can leave no delay to fit, and then no frequency limit.
    """
    minimum_period = period - path.slack / core_cycles(path, period)
    return 1e3 / minimum_period if minimum_period > 0 else math.inf


def _megahertz(frequency: float) -> str:
    """Format a frequency limit in MHz; a path that sets none shows a dash."""
    return "-" if math.isinf(frequency) else f"{frequency:.1f}"


def paths_markdown(
    stage: str,
    paths: Sequence[TimingPath],
    register_paths: Sequence[TimingPath],
    periods: dict[str, float],
    mocked: set[str],
    ports: set[str],
    rows: int = 30,
) -> str:
    """Return a Markdown report of one stage's setup paths.

    paths has the worst path to each endpoint, and register_paths the worst
    path between registers for each pair of core clock edges, which set the fmax.
    """
    period = periods["core_clk"]
    fmax = min(path_fmax(path, period) for path in register_paths)
    lines = [
        f"# Setup paths after {PATH_DATABASES[stage][1]}",
        "",
        f"Core clock period: {format_period(period)} ns. Core clock fmax "
        f"estimate: {_megahertz(fmax)} MHz, from the paths between registers.",
        "",
        "## Worst slack by capture clock",
        "",
        "| Clock | Period (ns) | Endpoints | Failing | WNS (ns) | TNS (ns) |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for clock, clock_period in periods.items():
        slacks = [path.slack for path in paths if path.capture == clock]
        if slacks:
            lines.append(
                f"| {clock} | {format_period(clock_period)} | {len(slacks):,} | "
                f"{sum(slack < 0 for slack in slacks):,} | {min(slacks):.3f} | "
                f"{sum(min(slack, 0) for slack in slacks):,.1f} |"
            )

    lines += [
        "",
        "## Paths between core clock registers",
        "",
        "The worst path for each pair of launching and capturing clock edges. "
        "For an edge span of f core periods, the minimum period is P - slack/f.",
        "",
        "| Launch | Capture | Core periods | Slack (ns) | fmax (MHz) | Startpoint "
        "| Endpoint | Note |",
        "| --- | --- | ---: | ---: | ---: | --- | --- | --- |",
    ]
    for path in register_paths:
        lines.append(
            f"| {path.launch} | {path.capture} | {core_cycles(path, period):g} | "
            f"{path.slack:.3f} | {_megahertz(path_fmax(path, period))} | "
            f"`{path.startpoint}` | `{path.endpoint}` | "
            f"{_path_note(path, mocked, ports, clocks=False)} |"
        )

    core = sorted(
        (path for path in paths if master_clock(path.capture) == "core_clk"),
        key=lambda path: path.slack,
    )
    worst = core[0].slack
    window = worst + CRITICAL_WINDOW_NS
    blocks: dict[str, list[TimingPath]] = defaultdict(list)
    for path in core:
        blocks[block(path.endpoint, ports)].append(path)
    lines += [
        "",
        "## Core clock endpoints by block",
        "",
        f"The blocks whose registers have the worst core clock slack. Near: within "
        f"{CRITICAL_WINDOW_NS:g} ns of the worst.",
        "",
        "| End block | Endpoints | Failing | Near | Worst slack (ns) |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    for name, members in list(blocks.items())[:rows]:
        lines.append(
            f"| `{name}` | {len(members):,} | "
            f"{sum(path.slack < 0 for path in members):,} | "
            f"{sum(path.slack <= window for path in members):,} | "
            f"{members[0].slack:.3f} |"
        )

    families: dict[tuple[str, str], list[TimingPath]] = defaultdict(list)
    for path in core:
        families[block(path.startpoint, ports), block(path.endpoint, ports)].append(
            path
        )
    lines += [
        "",
        "## Core clock paths by start and end block",
        "",
        "Each endpoint's worst path, grouped by the blocks of its startpoint "
        "and endpoint; a row shows the group's worst path and its cells after "
        "the startpoint (buffers and inverters in parentheses), and counts the "
        "endpoints in the group.",
        "",
        "| Start block | End block | Endpoints | Worst slack (ns) | Cells | Note |",
        "| --- | --- | ---: | ---: | ---: | --- |",
    ]
    for (start, end), members in list(families.items())[:rows]:
        path = members[0]
        lines.append(
            f"| `{start}` | `{end}` | {len(members):,} | {path.slack:.3f} | "
            f"{path.cells} ({path.buffers}) | {_path_note(path, mocked, ports)} |"
        )
    return "\n".join(lines) + "\n"


def report_paths(stage: str, num_cores: int, *, uid: int, gid: int) -> int:
    """Run asic/critical_paths.tcl on a stage's database and report its paths."""
    database = PATH_DATABASES[stage][0]
    results = BUILD_DIRECTORY / FLOW_SUBDIRECTORY.format(kind="results")
    if not (results / f"{database}.odb").exists():
        print(f"Error: {results} has no {database}.odb", file=sys.stderr)
        return 1
    status = subprocess.run(
        orfs_command(
            [
                f"NUM_CORES={num_cores}",
                "run",
                f"RUN_SCRIPT={CONTAINER_ROOT}/asic/critical_paths.tcl",
                # Outside the flow's logs, which make elapsed totals.
                f"LOG_DIR={CONTAINER_BUILD}/{PATHS_LOG_SUBDIRECTORY}",
                f"RUN_LOG_NAME_STEM={database}",
                f"FROST_PATHS_STAGE={database}",
            ],
            uid=uid,
            gid=gid,
        ),
        check=False,
    ).returncode
    if status != 0:
        print(f"Error: the path report failed with status {status}", file=sys.stderr)
        return status
    reports = BUILD_DIRECTORY / FLOW_SUBDIRECTORY.format(kind="reports")
    logs = BUILD_DIRECTORY / FLOW_SUBDIRECTORY.format(kind="logs")
    paths = read_paths(reports / f"{database}_paths.tsv")
    register_paths = read_paths(reports / f"{database}_register_paths.tsv")
    memories = [name for name, _, _ in mocked_memories(logs / "1_2_yosys.log")]
    mocked = mocked_rows(
        {
            point
            for path in (*paths, *register_paths)
            for point in (path.startpoint, path.endpoint)
        },
        memories,
    )
    sdc = (results / f"{database}.sdc").read_text()
    report = paths_markdown(
        stage, paths, register_paths, clock_periods(sdc), mocked, port_names(sdc)
    )
    (BUILD_DIRECTORY / f"paths_{stage}.md").write_text(report)
    print(report)
    return 0


def _positive_integer(text: str) -> int:
    """Parse a thread count for argparse."""
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError(f"expected a positive integer, got {text}")
    return value


# A period in ns as constraint.sdc accepts it: below 100 ns, with at most
# four decimals.
_PERIOD = re.compile(r"(?:0|[1-9][0-9]?)(?:\.[0-9]{1,4})?")


def _clock_period(text: str) -> float:
    """Parse a clock period in ns for argparse."""
    if not _PERIOD.fullmatch(text) or float(text) == 0:
        raise argparse.ArgumentTypeError(
            "expected a positive period in ns below 100 with at most four "
            f"decimals, got {text}"
        )
    return float(text)


# A memory limit as run takes it: GiB, or a percentage of the host's RAM.
_MEMORY_LIMIT = re.compile(r"(?P<value>[0-9]+(?:\.[0-9]+)?)(?P<percent>%?)")


def _memory_limit(text: str) -> MemoryLimit:
    """Parse a memory limit in GiB, or in % of the host's RAM, for argparse."""
    match = _MEMORY_LIMIT.fullmatch(text)
    value = float(match["value"]) if match else 0.0
    if match is None or value <= 0 or (match["percent"] and value > 100):
        raise argparse.ArgumentTypeError(
            f"expected a size in GiB or a percentage of RAM up to 100%, got {text}"
        )
    if match["percent"]:
        return MemoryLimit(percent=value)
    if int(value * GIB) < MINIMUM_MEMORY_LIMIT:
        raise argparse.ArgumentTypeError(
            f"expected a size of at least 6 MiB, Docker's smallest, got {text} GiB"
        )
    return MemoryLimit(size_gib=value)


def _argument_parser() -> argparse.ArgumentParser:
    """Create the command-line parser."""
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  %(prog)s run                      # the whole flow with every CPU
  %(prog)s run --num-cores 16       # limit OpenROAD and Yosys threads
  %(prog)s run --target grt         # stop after global routing
  %(prog)s run --from route         # rerun detailed routing and finishing
  %(prog)s run --clock-period 1.6   # ask for 625 MHz to find the fmax
  %(prog)s run --memory-limit 75%%   # keep a quarter of the RAM outside the flow
  %(prog)s summary                  # summarize asic/build again
  %(prog)s paths --stage grt        # report the critical paths
""",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    run_parser = commands.add_parser("run", help="prepare, run the flow, summarize")
    run_parser.add_argument(
        "--frost-image",
        default=os.environ.get("FROST_DOCKER_IMAGE", "frost"),
        help="frost image for source preparation (default: %(default)s)",
    )
    run_parser.add_argument(
        "--num-cores",
        type=_positive_integer,
        default=os.cpu_count() or 1,
        help="threads for the flow's tools (default: %(default)s)",
    )
    run_parser.add_argument(
        "--target",
        choices=STAGES,
        default="finish",
        help="last ORFS stage to run (default: %(default)s)",
    )
    run_parser.add_argument(
        "--clock-period",
        type=_clock_period,
        metavar="NS",
        help=(
            "core clock period in ns, which the quarter-rate clock and the I/O "
            "delays follow (default: the X3's, from asic/constraint.sdc)"
        ),
    )
    run_parser.add_argument(
        "--cpu-clock-period",
        type=_clock_period,
        metavar="NS",
        help="enable the asynchronous CPU boundary with this CPU clock period in ns",
    )
    run_parser.add_argument(
        "--memory-limit",
        type=_memory_limit,
        metavar="GIB|PERCENT%",
        help=(
            "RAM that the ORFS container may hold, in GiB or as a percentage of "
            "the host's; it keeps the rest of what it needs in swap, and the "
            "kernel stops the flow when that runs out too (default: no limit)"
        ),
    )
    run_parser.add_argument(
        "--from",
        dest="first",
        choices=STAGES[1:],
        help=(
            "rerun from this stage with the results already in asic/build, "
            "without preparing the sources"
        ),
    )
    commands.add_parser("prepare", help="write the flow's sources (frost image)")
    commands.add_parser("summary", help="summarize an existing build")
    paths_parser = commands.add_parser(
        "paths", help="report a stage's setup paths by block"
    )
    paths_parser.add_argument(
        "--stage",
        choices=tuple(PATH_DATABASES),
        default="grt",
        help="stage whose database to read (default: %(default)s)",
    )
    paths_parser.add_argument(
        "--num-cores",
        type=_positive_integer,
        default=4,
        help="threads for OpenROAD (default: %(default)s)",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Run the selected command."""
    args = _argument_parser().parse_args(argv)
    try:
        if args.command == "prepare":
            prepare(BUILD_DIRECTORY)
            return 0
        if args.command == "summary":
            signals = _Signals()
            with _signals_handled(signals):
                return summarize(uid=os.getuid(), gid=os.getgid(), signals=signals)
        if args.command == "paths":
            return report_paths(
                args.stage, args.num_cores, uid=os.getuid(), gid=os.getgid()
            )
        return run(args)
    except KeyboardInterrupt:
        print("Error: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
