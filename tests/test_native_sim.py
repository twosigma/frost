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

"""Verify the C++ Verilator RTL runner against live cocotb runs and workload invariants."""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest
import yaml  # type: ignore[import-untyped]

REPO_ROOT = Path(__file__).resolve().parents[1]
ROOT_README = REPO_ROOT / "README.md"
NATIVE_DIR = REPO_ROOT / "hw" / "sim" / "native"
NATIVE_README = NATIVE_DIR / "README.md"
NATIVE_MAIN_CPP = NATIVE_DIR / "main.cpp"
NATIVE_MAKEFILE = NATIVE_DIR / "Makefile"
NATIVE_VLT = NATIVE_DIR / "frost_native.vlt"
SIM_ASSERTIONS_CPP = REPO_ROOT / "hw" / "sim" / "sim_assertions.cpp"
REMOVED_BASELINE_PATH = NATIVE_DIR / "exactness_baseline.json"
TESTS_DIR = REPO_ROOT / "tests"
TESTS_MAKEFILE = TESTS_DIR / "Makefile"
DEMO_DOCKERFILE = REPO_ROOT / "demo" / "Dockerfile"
DEMO_SCRIPT = REPO_ROOT / "demo" / "run_demo.sh"
CI_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "ci.yml"
COREMARK_MAIN_C = REPO_ROOT / "sw" / "apps" / "coremark" / "coremark" / "core_main.c"

EXPECTED_TOP_PARAM_DEFAULTS = {
    "SIM_MEM_SIZE_BYTES": "262144",
    "ENABLE_CACHED_TIER": "1",
    "DDR_MODEL_BYTES": "67108864",
    "DDR_MODEL_LATENCY": "80",
    "SIM_FAST_MAINT": "1",
    "MEMORY_LINK_STAGES": "0",
    "MISALIGNED_HW": "$(if $(filter 0,$(ENABLE_CACHED_TIER)),0,1)",
}

EXPECTED_VERILATOR_G_ARGS = {
    "MEM_SIZE_BYTES": "$(SIM_MEM_SIZE_BYTES)",
    "ENABLE_CACHED_TIER": "$(ENABLE_CACHED_TIER)",
    "DDR_MODEL_BYTES": "$(DDR_MODEL_BYTES)",
    "DDR_MODEL_LATENCY": "$(DDR_MODEL_LATENCY)",
    "SIM_FAST_MAINT": "$(SIM_FAST_MAINT)",
    "MEMORY_LINK_STAGES": "$(MEMORY_LINK_STAGES)",
    "MISALIGNED_HW": "$(MISALIGNED_HW)",
}

EXPECTED_SHARED_VERILATOR_FLAGS = {
    "-f $(ROOT)/hw/rtl/frost.f",
    "--assert",
    "+define+FROST_SIM_ASSERTIONS",
    "-Wno-UNOPTFLAT",
    "-Wno-MODDUP",
    "-GMEM_SIZE_BYTES=$(SIM_MEM_SIZE_BYTES)",
    "-GENABLE_CACHED_TIER=$(ENABLE_CACHED_TIER)",
    "-GDDR_MODEL_BYTES=$(DDR_MODEL_BYTES)",
    "-GDDR_MODEL_LATENCY=$(DDR_MODEL_LATENCY)",
    "-GSIM_FAST_MAINT=$(SIM_FAST_MAINT)",
    "-GMEMORY_LINK_STAGES=$(MEMORY_LINK_STAGES)",
    "-GMISALIGNED_HW=$(MISALIGNED_HW)",
    "$(FROST_VERILATOR_EXTRA_ARGS)",
}

EXPECTED_NATIVE_ONLY_VERILATOR_FLAGS = {
    "--cc",
    "--exe",
    "--MMD",
    "--top-module frost",
    "--prefix Vtop",
    "-o frost-native",
    "--Mdir $(MODEL_DIR)",
    "$(ROOT)/hw/sim/native/frost_native.vlt",
    "--timescale 1ns/1ps",
    "-O3",
    "--threads $(THREADS)",
    "-Wno-UNOPTTHREADS",
    "--savable",
    '-LDFLAGS "$(EFFECTIVE_LDFLAGS)"',
    '-CFLAGS "$(NATIVE_CFLAGS)"',
}

EXPECTED_DOCUMENTED_DIFF_TOKENS = (
    "frost_native.vlt",
    "--public-flat-rw",
    "--vpi",
    "-O3",
    "--threads",
    "-Wno-UNOPTTHREADS",
    "ASSERTIONS=0",
    "sim_assertions.cpp",
    "frost_sim_assertions_enable",
    "--savable",
    "-GCLK_FREQ_HZ=3686400",
    "OPT_FAST=-O3",
    "OPT_SLOW=-O0",
    "OPT_GLOBAL=-O2",
)

EXPECTED_EXPOSED_SIGNALS = {
    ("public_flat_rw", "frost", "uart_write_enable_from_cpu"),
    ("public_flat_rw", "frost", "uart_write_data_from_cpu"),
    ("public_flat_rw", "frost", "reset_synchronizer_shift_register"),
    ("public_flat_rw", "frost", "reset_synchronized"),
    ("public_flat_rw", "frost", "reset_div4_synchronizer_shift_register"),
    ("public_flat_rw", "reorder_buffer", "retire_trace_fd"),
}

UNSEEDED_COCOTB_STRIP_ENV = (
    "FROST_DDR_MODEL_SEED",
    "FROST_RANDOM_START",
    "FROST_RANDOM_START_SEED",
    "FROST_RANDOM_START_VERILATOR_SEED",
    "FROST_STARTUP_SWEEP",
    "FROST_STARTUP_SEED_BASE",
    "FROST_STARTUP_BASELINE",
    "FROST_COVERAGE",
    "FROST_COVERAGE_TOGGLE",
    "FROST_COVERAGE_FILE",
    "WAVES",
    "COCOTB_TEST_FILTER",
)

COREMARK_REQUIRED_UART_LINES: tuple[bytes, ...] = (
    b"2K performance run parameters for coremark.",
    b"CoreMark Size    : 666",
    b"seedcrc          : 0xe9f5",
    b"[0]crclist       : 0xe714",
    b"[0]crcmatrix     : 0x1fd7",
    b"[0]crcstate      : 0x8e3a",
    b"[0]crcfinal      : 0xe714",
    b"Correct operation validated.",
    b"<<PASS>>",
)

EXPECTED_SUMMARY_KEYS = {
    "cycles",
    "advanced_cycles",
    "marker_cycle",
    "drain_cycles",
    "uart_bytes",
    "coremark_ticks",
    "wall_seconds",
    "cycles_per_second",
    "threads",
    "assertions_compiled",
    "assertions_armed",
    "passed",
    "failed",
}

FORBIDDEN_README_CYCLE_FIGURES = (
    11792,
    11824,
    12821,
    333130,
    223556,
    410310,
    285889,
)


@dataclass(frozen=True)
class NativeCase:
    """Workload and stop-condition specification for one simulator configuration."""

    name: str
    app: str
    mem_config: str
    stop_marker: str
    drain_cycles: int
    ci: bool


NATIVE_CASES: dict[str, NativeCase] = {
    "hello_world_bram": NativeCase(
        name="hello_world_bram",
        app="hello_world",
        mem_config="bram",
        stop_marker="Hello, world!",
        drain_cycles=10000,
        ci=True,
    ),
    "hello_world_ddr": NativeCase(
        name="hello_world_ddr",
        app="hello_world",
        mem_config="ddr",
        stop_marker="Hello, world!",
        drain_cycles=10000,
        ci=True,
    ),
    "coremark_bram": NativeCase(
        name="coremark_bram",
        app="coremark",
        mem_config="bram",
        stop_marker="<<PASS>>",
        drain_cycles=0,
        ci=True,
    ),
    "coremark_ddr": NativeCase(
        name="coremark_ddr",
        app="coremark",
        mem_config="ddr",
        stop_marker="<<PASS>>",
        drain_cycles=0,
        ci=False,
    ),
}


@dataclass(frozen=True)
class ParsedRunResult:
    """Cycle count, tick count, and UART digest from a live cocotb run."""

    cycles: int
    coremark_ticks: int | None
    uart_bytes: int
    uart_sha256: str


def parse_makefile_default_vars(text: str) -> dict[str, str]:
    """Extract top-level ``VAR ?= value`` defaults from a Makefile."""
    defaults: dict[str, str] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = re.match(r"^([A-Z0-9_]+)\s*\?=\s*(.*)$", stripped)
        if match:
            defaults[match.group(1)] = match.group(2).strip()
    return defaults


def parse_verilator_g_flags(text: str) -> dict[str, str]:
    """Extract ``-GNAME=VALUE`` parameter assignments from a Makefile."""
    flags: dict[str, str] = {}
    for match in re.finditer(r"-G([A-Z0-9_]+)=(\$\([^)]+\)|[^\s\\]+)", text):
        flags[match.group(1)] = match.group(2)
    return flags


_TWO_TOKEN_VERILATOR_OPTS = {
    "--top-module",
    "--prefix",
    "-o",
    "--Mdir",
    "-Mdir",
    "-f",
    "--timescale",
    "--threads",
    "-j",
    "-CFLAGS",
    "-LDFLAGS",
}


def _group_verilator_tokens(raw_expr: str) -> list[str]:
    """Tokenize a Makefile flag fragment and pair two-argument Verilator options."""
    tokens = re.findall(r'"[^"]*"|(?:\$\([^)]+\)|[^\s"])+', raw_expr)
    grouped: list[str] = []
    idx = 0
    while idx < len(tokens):
        tok = tokens[idx]
        if tok in _TWO_TOKEN_VERILATOR_OPTS and idx + 1 < len(tokens):
            grouped.append(f"{tok} {tokens[idx + 1]}")
            idx += 2
        else:
            grouped.append(tok)
            idx += 1
    return grouped


def parse_native_verilator_flags(makefile_text: str) -> set[str]:
    """Extract every Verilator option assigned to ``VERILATOR_FLAGS``."""
    joined = re.sub(r"\\\n[ \t]*", " ", makefile_text)
    flags: set[str] = set()
    for line in joined.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = re.match(r"^VERILATOR_FLAGS\s*(?::=|\+=)\s*(.*)$", stripped)
        if match:
            flags.update(_group_verilator_tokens(match.group(1)))
    return flags


def parse_cocotb_frost_verilator_flags(makefile_text: str) -> set[str]:
    """Extract default ``TOPLEVEL=frost`` Verilator flags from ``tests/Makefile``."""
    joined = re.sub(r"\\\n[ \t]*", " ", makefile_text)
    lines = joined.splitlines()
    flags: set[str] = set()

    for idx, line in enumerate(lines):
        stripped = line.strip()
        if stripped == "# Full chip or CPU tests - use complete RTL":
            for sub in lines[idx + 1 : idx + 6]:
                sub_s = sub.strip()
                match = re.match(r"^COMPILE_ARGS\s*:=\s*(.*)$", sub_s)
                if match:
                    flags.update(_group_verilator_tokens(match.group(1)))
                    break
        elif stripped == "ifeq ($(WAVES),1)":
            in_else = False
            for sub in lines[idx + 1 : idx + 8]:
                sub_s = sub.strip()
                if sub_s == "else":
                    in_else = True
                elif sub_s == "endif":
                    break
                elif in_else:
                    match = re.match(r"^export\s+EXTRA_ARGS\s*:=\s*(.*)$", sub_s)
                    if match:
                        flags.update(_group_verilator_tokens(match.group(1)))
        elif stripped == "ifeq ($(TOPLEVEL),frost)":
            skip_async = False
            for sub in lines[idx + 1 : idx + 10]:
                sub_s = sub.strip()
                if sub_s.startswith("ifneq ($(strip $(FROST_CPU_PERIOD_PS))"):
                    skip_async = True
                elif skip_async and sub_s == "endif":
                    skip_async = False
                elif sub_s == "endif":
                    break
                elif not skip_async:
                    match = re.match(
                        r"^(?:EXTRA_ARGS|COMPILE_ARGS)\s*\+=\s*(.*)$", sub_s
                    )
                    if match:
                        flags.update(_group_verilator_tokens(match.group(1)))
        elif stripped == "ifneq ($(strip $(FROST_VERILATOR_EXTRA_ARGS)),)":
            for sub in lines[idx + 1 : idx + 4]:
                sub_s = sub.strip()
                match = re.match(r"^EXTRA_ARGS\s*\+=\s*(.*)$", sub_s)
                if match:
                    flags.update(_group_verilator_tokens(match.group(1)))
                    break
    return flags


def parse_cocotb_program_log(raw_log: bytes) -> ParsedRunResult:
    """Extract total cycles, CoreMark ticks, and raw CPU UART bytes from cocotb."""
    start_match = re.search(rb"=== Starting run 1 of \d+ ===\r?\n", raw_log)
    end_match = re.search(
        rb"\n\n([ ]*(\d+\.\d+)ns[ ]+INFO[ ]+test[ ]+Run 1 completed after (\d+) cycles)",
        raw_log,
    )
    if start_match is None or end_match is None:
        raise ValueError("cocotb log is missing run 1 start or completion markers")

    body = raw_log[start_match.end() : end_match.start()]
    uart = re.sub(
        rb"[ ]*\d+\.\d+ns[ ]+(?:INFO|WARNING|ERROR)[ ]+test[ ]+[^\n]*\n",
        b"",
        body,
    )
    sim_time_ns = float(end_match.group(2).decode("ascii"))
    cycles = round(sim_time_ns / 3.0)
    ticks_match = re.search(rb"Total 64-bit ticks\s*:\s*(\d+)", uart)
    coremark_ticks = int(ticks_match.group(1)) if ticks_match is not None else None
    return ParsedRunResult(
        cycles=cycles,
        coremark_ticks=coremark_ticks,
        uart_bytes=len(uart),
        uart_sha256=hashlib.sha256(uart).hexdigest(),
    )


def _parse_cgroup_v2_cpu_max(text: str) -> int | None:
    """Parse cgroup v2 ``cpu.max`` content into whole available CPUs."""
    parts = text.strip().split()
    if len(parts) != 2 or parts[0] == "max":
        return None
    try:
        quota = int(parts[0], 10)
        period = int(parts[1], 10)
    except ValueError:
        return None
    if quota <= 0 or period <= 0:
        return None
    return max(1, quota // period)


def _parse_cgroup_v1_quota(quota_text: str, period_text: str) -> int | None:
    """Parse cgroup v1 CFS quota/period files into whole available CPUs."""
    try:
        quota = int(quota_text.strip(), 10)
        period = int(period_text.strip(), 10)
    except ValueError:
        return None
    if quota <= 0 or period <= 0:
        return None
    return max(1, quota // period)


def _effective_cpu_count(
    *,
    cgroup_v2_path: Path | None = None,
    cgroup_v1_quota_path: Path = Path("/sys/fs/cgroup/cpu/cpu.cfs_quota_us"),
    cgroup_v1_period_path: Path = Path("/sys/fs/cgroup/cpu/cpu.cfs_period_us"),
) -> int:
    """Return available CPUs honoring both CPU affinity and cgroup CPU quotas."""
    try:
        affinity_cpus = len(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        affinity_cpus = os.cpu_count() or 1
    cpus = max(1, affinity_cpus)

    v2_path = cgroup_v2_path or Path(
        os.environ.get("FROST_CGROUP_CPU_MAX", "/sys/fs/cgroup/cpu.max")
    )
    if v2_path.is_file():
        try:
            cg_cpus = _parse_cgroup_v2_cpu_max(v2_path.read_text(encoding="utf-8"))
        except OSError:
            cg_cpus = None
        if cg_cpus is not None:
            cpus = min(cpus, cg_cpus)
    elif cgroup_v1_quota_path.is_file() and cgroup_v1_period_path.is_file():
        try:
            cg_cpus = _parse_cgroup_v1_quota(
                cgroup_v1_quota_path.read_text(encoding="utf-8"),
                cgroup_v1_period_path.read_text(encoding="utf-8"),
            )
        except OSError:
            cg_cpus = None
        if cg_cpus is not None:
            cpus = min(cpus, cg_cpus)

    return max(1, cpus)


def _default_threads() -> int:
    """Choose a partition count matching demo/run_demo.sh and CPU quotas."""
    raw = os.environ.get("FROST_NATIVE_TEST_THREADS")
    if raw is not None:
        return max(1, int(raw))
    return 4 if _effective_cpu_count() >= 4 else 1


def _run_checked(
    command: list[str],
    *,
    cwd: Path = REPO_ROOT,
    env: dict[str, str] | None = None,
) -> None:
    """Run a subprocess and raise with context on failure."""
    subprocess.run(command, cwd=cwd, env=env, check=True)


def _is_strict_int(value: object) -> bool:
    """Return True when value is an integer and not a boolean."""
    return isinstance(value, int) and not isinstance(value, bool)


def _is_strict_number(value: object) -> bool:
    """Return True when value is an int or float and not a boolean."""
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def assert_program_and_summary_invariants(
    case: NativeCase,
    summary: dict[str, Any],
    uart_bytes: bytes,
    *,
    expected_threads: int,
    expected_advanced_cycles: int | None = None,
) -> None:
    """Check workload pass conditions and summary invariants independent of cycle count."""
    assert set(summary.keys()) == EXPECTED_SUMMARY_KEYS, (
        f"{case.name}: unexpected summary keys {sorted(summary.keys())}"
    )
    assert summary["passed"] is True, f"{case.name}: simulation did not report pass"
    assert summary["failed"] is False, f"{case.name}: simulation reported failure"
    assert summary["assertions_compiled"] is True, (
        f"{case.name}: checked native run did not record assertions_compiled=true"
    )
    assert summary["assertions_armed"] is True, (
        f"{case.name}: checked native run did not arm assertions after reset "
        "(assertions_armed=false)"
    )

    cycles = summary["cycles"]
    assert _is_strict_int(cycles) and cycles > 20 + case.drain_cycles, (
        f"{case.name}: invalid cycles={cycles!r} for drain_cycles={case.drain_cycles}"
    )

    advanced_cycles = summary["advanced_cycles"]
    target_advanced = (
        expected_advanced_cycles if expected_advanced_cycles is not None else cycles
    )
    assert _is_strict_int(advanced_cycles) and advanced_cycles > 0, (
        f"{case.name}: invalid advanced_cycles={advanced_cycles!r}"
    )
    assert advanced_cycles == target_advanced, (
        f"{case.name}: advanced_cycles ({advanced_cycles}) != expected ({target_advanced})"
    )

    drain_cycles = summary["drain_cycles"]
    assert _is_strict_int(drain_cycles) and drain_cycles == case.drain_cycles, (
        f"{case.name}: drain_cycles ({drain_cycles!r}) != {case.drain_cycles}"
    )

    marker_cycle = summary["marker_cycle"]
    assert _is_strict_int(marker_cycle) and marker_cycle > 20, (
        f"{case.name}: invalid marker_cycle={marker_cycle!r}"
    )
    assert cycles == marker_cycle + case.drain_cycles, (
        f"{case.name}: cycles ({cycles}) != marker_cycle ({marker_cycle}) + "
        f"drain_cycles ({case.drain_cycles})"
    )

    threads = summary["threads"]
    assert _is_strict_int(threads) and threads == expected_threads, (
        f"{case.name}: summary threads ({threads!r}) != {expected_threads}"
    )

    wall_seconds = summary["wall_seconds"]
    assert _is_strict_number(wall_seconds) and wall_seconds > 0.0, (
        f"{case.name}: invalid wall_seconds={wall_seconds!r}"
    )
    cycles_per_second = summary["cycles_per_second"]
    assert _is_strict_number(cycles_per_second) and cycles_per_second > 0.0, (
        f"{case.name}: invalid cycles_per_second={cycles_per_second!r}"
    )

    summary_uart_bytes = summary["uart_bytes"]
    assert _is_strict_int(summary_uart_bytes) and summary_uart_bytes > 0, (
        f"{case.name}: invalid summary uart_bytes={summary_uart_bytes!r}"
    )
    assert summary_uart_bytes == len(uart_bytes), (
        f"{case.name}: summary uart_bytes ({summary_uart_bytes}) != "
        f"captured UART byte length ({len(uart_bytes)})"
    )

    assert b"<<FAIL>>" not in uart_bytes, f"{case.name}: UART output contained <<FAIL>>"
    assert b"ERROR!" not in uart_bytes, f"{case.name}: UART output contained ERROR!"
    assert case.stop_marker.encode("utf-8") in uart_bytes, (
        f"{case.name}: UART output missing stop marker {case.stop_marker!r}"
    )

    if case.app == "hello_world":
        assert b"Frost: Hello, world!" in uart_bytes, (
            f"{case.name}: UART output missing hello banner 'Frost: Hello, world!'"
        )
        assert summary["coremark_ticks"] is None, (
            f"{case.name}: expected coremark_ticks=None, got {summary['coremark_ticks']!r}"
        )
    elif case.app == "coremark":
        for required_line in COREMARK_REQUIRED_UART_LINES:
            assert required_line in uart_bytes, (
                f"{case.name}: CoreMark UART output missing {required_line.decode('ascii')!r}"
            )
        ticks_32_match = re.search(rb"Total ticks\s*:\s*(\d+)\r?\n", uart_bytes)
        ticks_64_match = re.search(rb"Total 64-bit ticks\s*:\s*(\d+)\r?\n", uart_bytes)
        assert ticks_32_match is not None, (
            f"{case.name}: CoreMark UART output missing 'Total ticks' line"
        )
        assert ticks_64_match is not None, (
            f"{case.name}: CoreMark UART output missing 'Total 64-bit ticks' line"
        )
        uart_ticks_32 = int(ticks_32_match.group(1))
        uart_ticks_64 = int(ticks_64_match.group(1))
        assert uart_ticks_32 == uart_ticks_64, (
            f"{case.name}: CoreMark Total ticks ({uart_ticks_32}) != "
            f"Total 64-bit ticks ({uart_ticks_64})"
        )
        cm_ticks = summary["coremark_ticks"]
        assert _is_strict_int(cm_ticks), (
            f"{case.name}: summary coremark_ticks must be an int, got {cm_ticks!r}"
        )
        assert cm_ticks == uart_ticks_64, (
            f"{case.name}: summary coremark_ticks ({cm_ticks}) != "
            f"UART Total 64-bit ticks ({uart_ticks_64})"
        )
        assert 0 < cm_ticks < cycles, (
            f"{case.name}: CoreMark ticks ({cm_ticks}) must satisfy 0 < ticks < cycles ({cycles})"
        )
    else:
        raise ValueError(f"unsupported app {case.app!r}")


def assert_native_matches_cocotb(
    case_name: str,
    summary: dict[str, Any],
    uart_bytes: bytes,
    live_cocotb: ParsedRunResult,
) -> None:
    """Verify exact cycle, tick, and UART byte agreement with a live cocotb run."""
    actual_cycles = int(summary["cycles"])
    assert actual_cycles == live_cocotb.cycles, (
        f"{case_name}: native cycles ({actual_cycles}) != "
        f"live cocotb cycles ({live_cocotb.cycles})"
    )
    assert summary["coremark_ticks"] == live_cocotb.coremark_ticks, (
        f"{case_name}: native coremark_ticks ({summary['coremark_ticks']!r}) != "
        f"live cocotb coremark_ticks ({live_cocotb.coremark_ticks!r})"
    )
    actual_uart_len = len(uart_bytes)
    assert int(summary["uart_bytes"]) == actual_uart_len, (
        f"{case_name}: summary uart_bytes ({summary['uart_bytes']}) != "
        f"captured UART byte length ({actual_uart_len})"
    )
    assert actual_uart_len == live_cocotb.uart_bytes, (
        f"{case_name}: native uart_bytes ({actual_uart_len}) != "
        f"live cocotb uart_bytes ({live_cocotb.uart_bytes})"
    )
    actual_sha256 = hashlib.sha256(uart_bytes).hexdigest()
    assert actual_sha256 == live_cocotb.uart_sha256, (
        f"{case_name}: native uart_sha256 ({actual_sha256}) != "
        f"live cocotb uart_sha256 ({live_cocotb.uart_sha256})"
    )


def run_live_cocotb_case(
    app: str,
    mem_config: str,
    *,
    clean_first: bool,
) -> ParsedRunResult:
    """Run one unseeded cocotb simulation and parse its Run 1 log."""
    env = dict(os.environ)
    for var in UNSEEDED_COCOTB_STRIP_ENV:
        env.pop(var, None)
    env["FROST_COCOTB_MEM_CONFIG"] = mem_config
    env.setdefault("NUMBER_OF_CPU_CORES", str(_effective_cpu_count()))

    if clean_first:
        _run_checked(["make", "-C", str(TESTS_DIR), "clean"], env=env)

    t0 = time.monotonic()
    proc = subprocess.run(
        ["./test_run_cocotb.py", app],
        cwd=TESTS_DIR,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    elapsed = time.monotonic() - t0
    if proc.returncode != 0:
        sys.stderr.buffer.write(proc.stdout)
        sys.stderr.flush()
        raise subprocess.CalledProcessError(proc.returncode, proc.args)
    print(
        f"[cocotb] {app} ({mem_config}) completed in {elapsed:.2f}s",
        flush=True,
    )
    return parse_cocotb_program_log(proc.stdout)


def _verify_static_runtime_linkage(binary: Path) -> None:
    """Confirm C++ and atomic runtime libraries are linked statically."""
    proc = subprocess.run(
        ["readelf", "-d", str(binary)],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    for forbidden in ("libstdc++", "libgcc_s", "libatomic"):
        assert forbidden not in proc.stdout, (
            f"{binary} unexpectedly links {forbidden} dynamically:\n{proc.stdout}"
        )


def _verify_demo_script_on_binary(
    binary: Path,
    threads: int,
    hello_stage_dir: Path,
    work_dir: Path,
) -> None:
    """Exercise demo/run_demo.sh against the compiled portable static binary."""
    demo_root = work_dir / "demo_stage"
    bin_dir = demo_root / "bin"
    apps_dir = demo_root / "apps"
    bin_dir.mkdir(parents=True, exist_ok=True)
    apps_dir.mkdir(parents=True, exist_ok=True)

    staged_bin = bin_dir / f"frost-native-t{threads}"
    if staged_bin.exists() or staged_bin.is_symlink():
        staged_bin.unlink()
    staged_bin.symlink_to(binary)

    staged_hello = apps_dir / "hello_world_bram"
    if staged_hello.exists() or staged_hello.is_symlink():
        staged_hello.unlink()
    staged_hello.symlink_to(hello_stage_dir)

    env = dict(os.environ)
    env["FROST_DEMO_ROOT"] = str(demo_root)
    proc = subprocess.run(
        [str(DEMO_SCRIPT), "--threads", str(threads), "--app", "hello_world"],
        cwd=work_dir,
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    assert "Frost: Hello, world!" in proc.stdout
    assert "to stop marker + 10,000 drain" in proc.stderr
    assert "RTL assertions   : enabled after reset" in proc.stderr


def _verify_thread_cli_bounds(
    binary: Path,
    threads: int,
    hello_stage_dir: Path,
    work_dir: Path,
) -> None:
    """Verify default thread count matches compiled partition and invalid values fail."""
    default_json = work_dir / "default_threads.json"
    _run_checked(
        [
            str(binary),
            "--mem-dir",
            str(hello_stage_dir),
            "--max-cycles",
            "25",
            "--stop",
            "",
            "--summary-json",
            str(default_json),
            "--quiet-summary",
        ],
        cwd=work_dir,
    )
    summary = json.loads(default_json.read_text(encoding="utf-8"))
    assert int(summary["threads"]) == threads
    assert summary["assertions_compiled"] is True
    assert summary["assertions_armed"] is True

    too_high = subprocess.run(
        [str(binary), "--mem-dir", str(hello_stage_dir), "--threads", "257"],
        cwd=work_dir,
        capture_output=True,
        text=True,
        check=False,
    )
    assert too_high.returncode == 2

    if threads > 1:
        too_low = subprocess.run(
            [str(binary), "--mem-dir", str(hello_stage_dir), "--threads", "1"],
            cwd=work_dir,
            capture_output=True,
            text=True,
            check=False,
        )
        assert too_low.returncode == 2


def run_exactness_suite(
    *,
    ci_only: bool,
    check_checkpoints: bool,
    work_dir: Path,
) -> None:
    """Build the checked native runner and verify live cocotb parity and invariants."""
    if shutil.which("verilator") is None:
        raise RuntimeError(
            "verilator not found; run inside the frost container:\n"
            "  ./scripts/frost.py run python3 tests/test_native_sim.py --all"
        )
    if not COREMARK_MAIN_C.is_file():
        raise RuntimeError(
            "coremark submodule is not initialized; run:\n"
            "  git submodule update --init --recursive sw/apps/coremark/coremark"
        )

    selected = [
        case for case in NATIVE_CASES.values() if (case.ci if ci_only else True)
    ]
    threads = _default_threads()
    cores = _effective_cpu_count()
    sim_build = NATIVE_DIR / "sim_build"
    live_cocotb: dict[str, ParsedRunResult] = {}

    if ci_only:
        # Compare one live unseeded cocotb run directly with the native run of
        # the same tree so cocotb and the native runner cannot drift apart.
        live_cocotb["hello_world_bram"] = run_live_cocotb_case(
            "hello_world", "bram", clean_first=True
        )

        checked_bin = (
            sim_build / f"model_t{threads}_a1_s0_x86_64_static" / "frost-native"
        )
        build_args = [
            "make",
            "-C",
            str(NATIVE_DIR),
            "build",
            f"THREADS={threads}",
            f"NUMBER_OF_CPU_CORES={cores}",
            "ASSERTIONS=1",
            "SAVABLE=0",
            "PORTABLE=1",
            "STATIC_RUNTIME=1",
        ]
    else:
        for index, case in enumerate(selected):
            live_cocotb[case.name] = run_live_cocotb_case(
                case.app,
                case.mem_config,
                clean_first=(index == 0),
            )

        checked_bin = sim_build / f"model_t{threads}_a1_s0_host" / "frost-native"
        build_args = [
            "make",
            "-C",
            str(NATIVE_DIR),
            "build",
            f"THREADS={threads}",
            f"NUMBER_OF_CPU_CORES={cores}",
            "ASSERTIONS=1",
            "SAVABLE=0",
        ]

    t_build = time.monotonic()
    _run_checked(build_args)
    print(
        f"[native] built {checked_bin.parent.name} in {time.monotonic() - t_build:.2f}s",
        flush=True,
    )
    assert checked_bin.is_file(), f"missing compiled binary {checked_bin}"
    if ci_only:
        _verify_static_runtime_linkage(checked_bin)

    retire_log = work_dir / "retire_trace.log"
    for case in selected:
        _run_checked(
            [
                "make",
                "-C",
                str(NATIVE_DIR),
                "stage-app",
                f"APP={case.app}",
                f"MEM_CONFIG={case.mem_config}",
            ]
        )
        uart_path = work_dir / f"{case.name}.uart"
        json_path = work_dir / f"{case.name}.json"
        app_stage_dir = sim_build / "apps" / f"{case.app}_{case.mem_config}"
        t_run = time.monotonic()
        _run_checked(
            [
                str(checked_bin),
                "--mem-dir",
                str(app_stage_dir),
                "--threads",
                str(threads),
                "--stop",
                case.stop_marker,
                "--drain",
                str(case.drain_cycles),
                "--uart-out",
                str(uart_path),
                "--summary-json",
                str(json_path),
                "--quiet-summary",
            ],
            cwd=work_dir,
        )
        print(
            f"[native] {case.name} completed in {time.monotonic() - t_run:.2f}s",
            flush=True,
        )
        assert not retire_log.exists(), (
            f"{case.name}: unexpected retire_trace.log written in working directory"
        )
        summary = json.loads(json_path.read_text(encoding="utf-8"))
        uart_bytes = uart_path.read_bytes()
        assert_program_and_summary_invariants(
            case,
            summary,
            uart_bytes,
            expected_threads=threads,
        )
        if case.name in live_cocotb:
            assert_native_matches_cocotb(
                case.name,
                summary,
                uart_bytes,
                live_cocotb[case.name],
            )

    hello_stage_dir = sim_build / "apps" / "hello_world_bram"
    _verify_thread_cli_bounds(checked_bin, threads, hello_stage_dir, work_dir)
    if ci_only:
        _verify_demo_script_on_binary(checked_bin, threads, hello_stage_dir, work_dir)

    if check_checkpoints:
        savable_bin = sim_build / f"model_t{threads}_a1_s1_host" / "frost-native"
        _run_checked(
            [
                "make",
                "-C",
                str(NATIVE_DIR),
                "build",
                f"THREADS={threads}",
                f"NUMBER_OF_CPU_CORES={cores}",
                "ASSERTIONS=1",
                "SAVABLE=1",
            ]
        )
        hello_case = NATIVE_CASES["hello_world_bram"]
        live_hello = live_cocotb["hello_world_bram"]
        _run_checked(
            [
                "make",
                "-C",
                str(NATIVE_DIR),
                "stage-app",
                f"APP={hello_case.app}",
                f"MEM_CONFIG={hello_case.mem_config}",
            ]
        )
        empty_run_dir = work_dir / "restore_only_cwd"
        empty_run_dir.mkdir(parents=True, exist_ok=True)

        # 1. Mid-execution checkpoint before stop marker is printed (--stop ""),
        # restored with --retire-trace and checked against the live cocotb run.
        mid_exec_cycle = max(100, (live_hello.cycles - hello_case.drain_cycles) // 2)
        ckpt_exec = work_dir / "hello_exec.ckpt"
        restored_exec_uart = work_dir / "hello_exec_restored.uart"
        restored_exec_json = work_dir / "hello_exec_restored.json"
        restored_exec_retire = work_dir / "hello_exec_restored.retire.log"
        _run_checked(
            [
                str(savable_bin),
                "--mem-dir",
                str(hello_stage_dir),
                "--threads",
                str(threads),
                "--max-cycles",
                str(mid_exec_cycle),
                "--stop",
                "",
                "--save",
                str(ckpt_exec),
                "--save-at",
                str(mid_exec_cycle),
                "--quiet-summary",
            ],
            cwd=work_dir,
        )
        assert ckpt_exec.is_file(), "mid-execution checkpoint file was not created"

        _run_checked(
            [
                str(savable_bin),
                "--restore",
                str(ckpt_exec),
                "--threads",
                str(threads),
                "--stop",
                hello_case.stop_marker,
                "--drain",
                str(hello_case.drain_cycles),
                "--uart-out",
                str(restored_exec_uart),
                "--summary-json",
                str(restored_exec_json),
                "--retire-trace",
                str(restored_exec_retire),
                "--quiet-summary",
            ],
            cwd=empty_run_dir,
        )
        assert not (empty_run_dir / "retire_trace.log").exists()
        assert restored_exec_retire.is_file()
        assert restored_exec_retire.stat().st_size > 0, (
            "--restore with --retire-trace produced an empty retirement trace"
        )
        restored_exec_summary = json.loads(
            restored_exec_json.read_text(encoding="utf-8")
        )
        restored_exec_bytes = restored_exec_uart.read_bytes()
        assert_program_and_summary_invariants(
            hello_case,
            restored_exec_summary,
            restored_exec_bytes,
            expected_threads=threads,
            expected_advanced_cycles=live_hello.cycles - mid_exec_cycle,
        )
        assert_native_matches_cocotb(
            "hello_world_bram (restored mid-exec)",
            restored_exec_summary,
            restored_exec_bytes,
            live_hello,
        )

        # 2. Mid-drain checkpoint after stop marker has already matched.
        mid_drain_cycle = live_hello.cycles - (hello_case.drain_cycles // 2)
        ckpt_drain = work_dir / "hello_drain.ckpt"
        restored_drain_uart = work_dir / "hello_drain_restored.uart"
        restored_drain_json = work_dir / "hello_drain_restored.json"
        _run_checked(
            [
                str(savable_bin),
                "--mem-dir",
                str(hello_stage_dir),
                "--threads",
                str(threads),
                "--max-cycles",
                str(mid_drain_cycle),
                "--stop",
                hello_case.stop_marker,
                "--drain",
                str(hello_case.drain_cycles),
                "--save",
                str(ckpt_drain),
                "--save-at",
                str(mid_drain_cycle),
                "--quiet-summary",
            ],
            cwd=work_dir,
        )
        assert ckpt_drain.is_file(), "mid-drain checkpoint file was not created"

        _run_checked(
            [
                str(savable_bin),
                "--restore",
                str(ckpt_drain),
                "--threads",
                str(threads),
                "--stop",
                hello_case.stop_marker,
                "--drain",
                str(hello_case.drain_cycles),
                "--uart-out",
                str(restored_drain_uart),
                "--summary-json",
                str(restored_drain_json),
                "--quiet-summary",
            ],
            cwd=empty_run_dir,
        )
        assert not (empty_run_dir / "retire_trace.log").exists()
        restored_drain_summary = json.loads(
            restored_drain_json.read_text(encoding="utf-8")
        )
        restored_drain_bytes = restored_drain_uart.read_bytes()
        assert_program_and_summary_invariants(
            hello_case,
            restored_drain_summary,
            restored_drain_bytes,
            expected_threads=threads,
            expected_advanced_cycles=live_hello.cycles - mid_drain_cycle,
        )
        assert_native_matches_cocotb(
            "hello_world_bram (restored mid-drain)",
            restored_drain_summary,
            restored_drain_bytes,
            live_hello,
        )

        # 3. --save-at beyond the stop cycle fails nonzero rather than succeeding
        # without writing a checkpoint.
        unreached_ckpt = work_dir / "unreached.ckpt"
        unreached_json = work_dir / "unreached.json"
        unreached = subprocess.run(
            [
                str(savable_bin),
                "--mem-dir",
                str(hello_stage_dir),
                "--threads",
                str(threads),
                "--stop",
                hello_case.stop_marker,
                "--drain",
                str(hello_case.drain_cycles),
                "--save",
                str(unreached_ckpt),
                "--save-at",
                str(live_hello.cycles + 10000),
                "--summary-json",
                str(unreached_json),
                "--quiet-summary",
            ],
            cwd=work_dir,
            capture_output=True,
            text=True,
            check=False,
        )
        assert unreached.returncode == 1
        assert "--save-at" in unreached.stderr
        assert not unreached_ckpt.exists()
        unreached_summary = json.loads(unreached_json.read_text(encoding="utf-8"))
        assert unreached_summary["passed"] is False
        assert unreached_summary["failed"] is True

    verify_runner_assertion_finish_and_split_fail(work_dir / "runner_fault_paths")


_SYNTHETIC_FROST_HARNESS_SV = """\
module reorder_buffer (
    input logic i_clk
);
  integer retire_trace_fd;
  initial begin
    retire_trace_fd = $fopen("retire_trace.log", "w");
  end
  always_ff @(posedge i_clk) begin
    if (retire_trace_fd != 0) begin
      $fwrite(retire_trace_fd, "retire\\n");
    end
  end
endmodule

module sub_tomasulo (input logic i_clk);
  reorder_buffer u_rob (.i_clk(i_clk));
endmodule

module sub_cpu_inst (input logic i_clk);
  sub_tomasulo u_tomasulo (.i_clk(i_clk));
endmodule

module sub_hart (input logic i_clk);
  sub_cpu_inst cpu_inst (.i_clk(i_clk));
endmodule

module sub_cpu (input logic i_clk);
  sub_hart hart (.i_clk(i_clk));
endmodule

module sub_subsystem (input logic i_clk);
  sub_cpu cpu (.i_clk(i_clk));
endmodule

module frost (
    input logic        i_clk,
    input logic        i_cpu_clk,
    input logic        i_clk_div4,
    input logic        i_rst_n,
    input logic        i_power_on_rst,
    input logic        i_instr_mem_en,
    input logic [ 3:0] i_instr_mem_we,
    input logic [31:0] i_instr_mem_addr,
    input logic [31:0] i_instr_mem_wrdata,
    input logic        i_uart_rx,
    input logic        i_external_interrupt,
    input logic        i_jtag_tck,
    input logic        i_jtag_tms,
    input logic        i_jtag_tdi,
    input logic        i_jtag_trst_n,
    input logic        i_ddr_axi_rst_n,
    input logic        i_nic_tx_clk,
    input logic        i_nic_rx_clk,
    input logic        i_nic_tx_clk_ok,
    input logic        i_nic_rx_clk_ok,
    input logic [ 4:0] i_nic_phy_status,
    input logic        i_nic_rx_raw_valid,
    input logic [63:0] i_nic_rx_raw_data,
    input logic        i_nic_rx_signal_ok,
    input logic        i_nic_1g_tx_clk,
    input logic        i_nic_1g_rx_clk,
    input logic        i_nic_1g_tx_clk_ok,
    input logic        i_nic_1g_rx_clk_ok
);
  logic [2:0] reset_synchronizer_shift_register;
  logic       reset_synchronized;
  logic [2:0] reset_div4_synchronizer_shift_register;
  logic       uart_write_enable_from_cpu;
  logic [7:0] uart_write_data_from_cpu;

  sub_subsystem cpu_and_memory_subsystem (.i_clk(i_clk));

  int unsigned clk_edge_count = 0;
  int unsigned post_rst_step;

  always_ff @(posedge i_clk) begin
    clk_edge_count <= clk_edge_count + 1;
    if ($test$plusargs("CHECK_ARMING_BOUNDARY")) begin
      assert (clk_edge_count >= 18)
      else $error("tripped_before_arming");
    end
    if ($test$plusargs("FORCE_EARLY_ARMED_FAIL") && clk_edge_count == 18) begin
      assert (clk_edge_count != 18)
      else $error("tripped_at_edge_18");
    end
    if (!i_rst_n) begin
      post_rst_step <= 0;
      uart_write_enable_from_cpu <= 1'b0;
      uart_write_data_from_cpu <= 8'h00;
    end else begin
      post_rst_step <= post_rst_step + 1;
      uart_write_enable_from_cpu <= 1'b0;
      if ($test$plusargs("FORCE_ASSERT_FAIL")) begin
        case (post_rst_step)
          0: begin
            uart_write_enable_from_cpu <= 1'b1;
            uart_write_data_from_cpu <= "O";
          end
          1: begin
            uart_write_enable_from_cpu <= 1'b1;
            uart_write_data_from_cpu <= "K";
          end
          2: begin
            uart_write_enable_from_cpu <= 1'b1;
            uart_write_data_from_cpu <= 8'h0a;
          end
          3: begin
            assert (post_rst_step != 3)
            else $error("forced_rtl_assertion");
          end
          default: ;
        endcase
      end else if ($test$plusargs("CHECK_ARMING_BOUNDARY")) begin
        case (post_rst_step)
          0: begin
            uart_write_enable_from_cpu <= 1'b1;
            uart_write_data_from_cpu <= "O";
          end
          1: begin
            uart_write_enable_from_cpu <= 1'b1;
            uart_write_data_from_cpu <= "K";
          end
          2: begin
            uart_write_enable_from_cpu <= 1'b1;
            uart_write_data_from_cpu <= 8'h0a;
          end
          default: ;
        endcase
      end else if ($test$plusargs("FORCE_FINISH")) begin
        case (post_rst_step)
          0: begin
            uart_write_enable_from_cpu <= 1'b1;
            uart_write_data_from_cpu <= "B";
          end
          1: begin
            uart_write_enable_from_cpu <= 1'b1;
            uart_write_data_from_cpu <= "Y";
          end
          2: begin
            uart_write_enable_from_cpu <= 1'b1;
            uart_write_data_from_cpu <= "E";
          end
          3: $finish;
          default: ;
        endcase
      end else if ($test$plusargs("SPLIT_FAIL_MARKER")) begin
        case (post_rst_step)
          0: begin
            uart_write_enable_from_cpu <= 1'b1;
            uart_write_data_from_cpu <= "<";
          end
          1: begin
            uart_write_enable_from_cpu <= 1'b1;
            uart_write_data_from_cpu <= "<";
          end
          2: begin
            uart_write_enable_from_cpu <= 1'b1;
            uart_write_data_from_cpu <= "F";
          end
          3: begin
            uart_write_enable_from_cpu <= 1'b1;
            uart_write_data_from_cpu <= "A";
          end
          4: begin
            uart_write_enable_from_cpu <= 1'b1;
            uart_write_data_from_cpu <= "I";
          end
          5: begin
            uart_write_enable_from_cpu <= 1'b1;
            uart_write_data_from_cpu <= "L";
          end
          6: begin
            uart_write_enable_from_cpu <= 1'b1;
            uart_write_data_from_cpu <= ">";
          end
          7: begin
            uart_write_enable_from_cpu <= 1'b1;
            uart_write_data_from_cpu <= ">";
          end
          default: ;
        endcase
      end
    end
  end
endmodule
"""


def verify_runner_assertion_finish_and_split_fail(work_dir: Path) -> None:
    """Compile main.cpp + sim_assertions.cpp on a test top to check arming and faults."""
    work_dir.mkdir(parents=True, exist_ok=True)
    harness_sv = work_dir / "frost_fault_harness.sv"
    harness_sv.write_text(_SYNTHETIC_FROST_HARNESS_SV, encoding="utf-8")

    mdir = work_dir / "obj_dir"
    bin_path = mdir / "frost-native-fault-test"
    cores = max(1, min(4, _effective_cpu_count()))
    _run_checked(
        [
            "verilator",
            "--cc",
            "--exe",
            "--top-module",
            "frost",
            "--prefix",
            "Vtop",
            "-o",
            "frost-native-fault-test",
            "--Mdir",
            str(mdir),
            str(NATIVE_VLT),
            str(harness_sv),
            "--timescale",
            "1ns/1ps",
            "-Wno-UNUSED",
            "-Wno-UNDRIVEN",
            "--assert",
            "+define+FROST_SIM_ASSERTIONS",
            "--savable",
            "-CFLAGS",
            "-std=c++17 -Wall -Wextra -DFROST_COMPILED_THREADS=1 "
            "-DFROST_NATIVE_ASSERTIONS -DFROST_NATIVE_SAVABLE",
            str(NATIVE_MAIN_CPP),
            str(SIM_ASSERTIONS_CPP),
        ],
        cwd=work_dir,
    )
    _run_checked(
        ["make", "-C", str(mdir), "-f", "Vtop.mk", f"-j{cores}"],
        cwd=work_dir,
    )

    mdir_a0 = work_dir / "obj_dir_a0"
    bin_a0_path = mdir_a0 / "frost-native-fault-test-a0"
    _run_checked(
        [
            "verilator",
            "--cc",
            "--exe",
            "--top-module",
            "frost",
            "--prefix",
            "Vtop",
            "-o",
            "frost-native-fault-test-a0",
            "--Mdir",
            str(mdir_a0),
            str(NATIVE_VLT),
            str(harness_sv),
            "--timescale",
            "1ns/1ps",
            "-Wno-UNUSED",
            "-Wno-UNDRIVEN",
            "-CFLAGS",
            "-std=c++17 -Wall -Wextra -DFROST_COMPILED_THREADS=1",
            str(NATIVE_MAIN_CPP),
            str(SIM_ASSERTIONS_CPP),
        ],
        cwd=work_dir,
    )
    _run_checked(
        ["make", "-C", str(mdir_a0), "-f", "Vtop.mk", f"-j{cores}"],
        cwd=work_dir,
    )

    mem_dir = work_dir / "mem"
    mem_dir.mkdir(parents=True, exist_ok=True)
    (mem_dir / "sw.mem").write_text("00000000\n", encoding="utf-8")
    (mem_dir / "sw64.mem").write_text("0000000000000000\n", encoding="utf-8")
    (mem_dir / "sw_ddr.mem").write_text("00000000\n", encoding="utf-8")

    # 1. Checked build (ASSERTIONS=1): assertions stay off across the first 18
    # reset rising edges (0..17), arm via frost_sim_assertions_enable() after
    # edge 17, and are recorded as enabled after reset in both summaries.
    boundary_json = work_dir / "arming_boundary.json"
    boundary_proc = subprocess.run(
        [
            str(bin_path),
            "--mem-dir",
            str(mem_dir),
            "--stop",
            "OK\n",
            "--summary-json",
            str(boundary_json),
            "+CHECK_ARMING_BOUNDARY",
        ],
        cwd=work_dir,
        capture_output=True,
        text=True,
        check=True,
    )
    assert "tripped_before_arming" not in (boundary_proc.stderr + boundary_proc.stdout)
    assert "RTL assertions   : enabled after reset" in boundary_proc.stderr
    boundary_summary = json.loads(boundary_json.read_text(encoding="utf-8"))
    assert boundary_summary["passed"] is True
    assert boundary_summary["failed"] is False
    assert boundary_summary["assertions_compiled"] is True
    assert boundary_summary["assertions_armed"] is True

    # Right after edge 17 arms checks, an assertion on edge 18 (still in reset
    # before i_rst_n releases on edge 19) trips immediately.
    early_json = work_dir / "early_armed_fail.json"
    early_proc = subprocess.run(
        [
            str(bin_path),
            "--mem-dir",
            str(mem_dir),
            "--max-cycles",
            "100",
            "--summary-json",
            str(early_json),
            "--quiet-summary",
            "+FORCE_EARLY_ARMED_FAIL",
        ],
        cwd=work_dir,
        capture_output=True,
        text=True,
        check=False,
    )
    assert early_proc.returncode == 1
    assert "tripped_at_edge_18" in (early_proc.stderr + early_proc.stdout)
    early_summary = json.loads(early_json.read_text(encoding="utf-8"))
    assert early_summary["passed"] is False
    assert early_summary["failed"] is True
    assert early_summary["assertions_compiled"] is True
    assert early_summary["assertions_armed"] is True

    # Forced RTL assertion failure after reset writes --uart-out and
    # --summary-json, records assertions_armed=true, and exits 1.
    assert_uart = work_dir / "assert_fail.uart"
    assert_json = work_dir / "assert_fail.json"
    assert_proc = subprocess.run(
        [
            str(bin_path),
            "--mem-dir",
            str(mem_dir),
            "--max-cycles",
            "100",
            "--uart-out",
            str(assert_uart),
            "--summary-json",
            str(assert_json),
            "+FORCE_ASSERT_FAIL",
        ],
        cwd=work_dir,
        capture_output=True,
        text=True,
        check=False,
    )
    assert assert_proc.returncode == 1
    assert "forced_rtl_assertion" in (assert_proc.stderr + assert_proc.stdout)
    assert "RTL assertions   : enabled after reset" in assert_proc.stderr
    assert assert_uart.is_file()
    assert assert_uart.read_bytes() == b"OK\n"
    assert assert_json.is_file()
    assert_summary = json.loads(assert_json.read_text(encoding="utf-8"))
    assert assert_summary["passed"] is False
    assert assert_summary["failed"] is True
    assert assert_summary["assertions_compiled"] is True
    assert assert_summary["assertions_armed"] is True
    assert assert_summary["uart_bytes"] == 3

    # 2. +verilator+noassert and --no-assert keep assertions off for the whole run,
    # and ASSERTIONS=0 builds never compile or enable assertions.
    for idx, disable_flag in enumerate(("+verilator+noassert", "--no-assert")):
        noassert_json = work_dir / f"noassert_{idx}.json"
        noassert_proc = subprocess.run(
            [
                str(bin_path),
                "--mem-dir",
                str(mem_dir),
                "--stop",
                "OK\n",
                "--drain",
                "5",
                "--summary-json",
                str(noassert_json),
                "+FORCE_ASSERT_FAIL",
                disable_flag,
            ],
            cwd=work_dir,
            capture_output=True,
            text=True,
            check=True,
        )
        assert "RTL assertions   : disabled\n" in noassert_proc.stderr
        noassert_summary = json.loads(noassert_json.read_text(encoding="utf-8"))
        assert noassert_summary["passed"] is True
        assert noassert_summary["failed"] is False
        assert noassert_summary["assertions_compiled"] is True
        assert noassert_summary["assertions_armed"] is False

    a0_json = work_dir / "assertions_zero.json"
    a0_proc = subprocess.run(
        [
            str(bin_a0_path),
            "--mem-dir",
            str(mem_dir),
            "--stop",
            "OK\n",
            "--drain",
            "5",
            "--summary-json",
            str(a0_json),
            "+FORCE_ASSERT_FAIL",
            "+CHECK_ARMING_BOUNDARY",
        ],
        cwd=work_dir,
        capture_output=True,
        text=True,
        check=True,
    )
    assert "RTL assertions   : disabled (not compiled)" in a0_proc.stderr
    a0_summary = json.loads(a0_json.read_text(encoding="utf-8"))
    assert a0_summary["passed"] is True
    assert a0_summary["failed"] is False
    assert a0_summary["assertions_compiled"] is False
    assert a0_summary["assertions_armed"] is False

    # 3. --stop "" combined with an HDL $finish exits 1 with passed=false.
    finish_uart = work_dir / "finish.uart"
    finish_json = work_dir / "finish.json"
    finish_proc = subprocess.run(
        [
            str(bin_path),
            "--mem-dir",
            str(mem_dir),
            "--stop",
            "",
            "--max-cycles",
            "100",
            "--uart-out",
            str(finish_uart),
            "--summary-json",
            str(finish_json),
            "--quiet-summary",
            "+FORCE_FINISH",
        ],
        cwd=work_dir,
        capture_output=True,
        text=True,
        check=False,
    )
    assert finish_proc.returncode == 1
    assert "$finish" in finish_proc.stderr
    assert finish_uart.read_bytes() == b"BYE"
    finish_summary = json.loads(finish_json.read_text(encoding="utf-8"))
    assert finish_summary["passed"] is False
    assert finish_summary["failed"] is True
    assert finish_summary["assertions_armed"] is True

    # 4. <<FAIL>> split across a checkpoint --save-at / --restore exits 1, and
    # restoring at cycle 25 (>= 18) re-arms assertions via frost_sim_assertions_enable().
    split_ckpt = work_dir / "split_fail.ckpt"
    _run_checked(
        [
            str(bin_path),
            "--mem-dir",
            str(mem_dir),
            "--stop",
            "",
            "--max-cycles",
            "25",
            "--save",
            str(split_ckpt),
            "--save-at",
            "25",
            "--quiet-summary",
            "+SPLIT_FAIL_MARKER",
        ],
        cwd=work_dir,
    )
    assert split_ckpt.is_file()

    restore_cwd = work_dir / "split_restore_cwd"
    restore_cwd.mkdir(parents=True, exist_ok=True)
    split_uart = work_dir / "split_fail.uart"
    split_json = work_dir / "split_fail.json"
    split_proc = subprocess.run(
        [
            str(bin_path),
            "--restore",
            str(split_ckpt),
            "--stop",
            "<<PASS>>",
            "--max-cycles",
            "100",
            "--uart-out",
            str(split_uart),
            "--summary-json",
            str(split_json),
            "--quiet-summary",
            "+SPLIT_FAIL_MARKER",
        ],
        cwd=restore_cwd,
        capture_output=True,
        text=True,
        check=False,
    )
    assert split_proc.returncode == 1
    assert split_uart.read_bytes() == b"<<FAIL>>"
    split_summary = json.loads(split_json.read_text(encoding="utf-8"))
    assert split_summary["passed"] is False
    assert split_summary["failed"] is True
    assert split_summary["assertions_armed"] is True


def test_native_makefile_matches_cocotb_toplevel_parameters(tmp_path: Path) -> None:
    """Native Makefile matches tests/Makefile parameters and documented flag diffs."""
    native_text = NATIVE_MAKEFILE.read_text(encoding="utf-8")
    cocotb_text = TESTS_MAKEFILE.read_text(encoding="utf-8")
    native_readme = NATIVE_README.read_text(encoding="utf-8")
    root_readme = ROOT_README.read_text(encoding="utf-8")
    demo_script_text = DEMO_SCRIPT.read_text(encoding="utf-8")
    main_cpp_text = NATIVE_MAIN_CPP.read_text(encoding="utf-8")

    assert not REMOVED_BASELINE_PATH.exists()

    native_defaults = parse_makefile_default_vars(native_text)
    cocotb_defaults = parse_makefile_default_vars(cocotb_text)
    for var_name, expected in EXPECTED_TOP_PARAM_DEFAULTS.items():
        assert native_defaults.get(var_name) == expected
        assert cocotb_defaults.get(var_name) == expected

    native_g = parse_verilator_g_flags(native_text)
    cocotb_g = parse_verilator_g_flags(cocotb_text)
    for param_name, expected_expr in EXPECTED_VERILATOR_G_ARGS.items():
        assert native_g.get(param_name) == expected_expr
        assert cocotb_g.get(param_name) == expected_expr

    cocotb_frost_flags = parse_cocotb_frost_verilator_flags(cocotb_text)
    assert (
        cocotb_frost_flags - {"-j $(NUMBER_OF_CPU_CORES)"}
        == EXPECTED_SHARED_VERILATOR_FLAGS
    )

    native_verilator_flags = parse_native_verilator_flags(native_text)
    assert EXPECTED_SHARED_VERILATOR_FLAGS.issubset(native_verilator_flags)
    assert (
        native_verilator_flags - EXPECTED_SHARED_VERILATOR_FLAGS
        == EXPECTED_NATIVE_ONLY_VERILATOR_FLAGS
    )

    assert 'verilator -j "$(NUMBER_OF_CPU_CORES)" $(VERILATOR_FLAGS)' in native_text
    assert SIM_ASSERTIONS_CPP.is_file()
    assert "$(ROOT)/hw/sim/sim_assertions.cpp" in cocotb_text
    assert "$(ROOT)/hw/sim/sim_assertions.cpp" in native_text
    assert "COCOTB_PLUSARGS += +verilator+noassert" in cocotb_text
    for flag in native_verilator_flags:
        assert "NUMBER_OF_CPU_CORES" not in flag
        assert not flag.startswith("-j ")

    config_lines = [
        line
        for line in native_text.splitlines()
        if line.strip().startswith("EFFECTIVE_MODEL_CONFIG :=")
    ]
    assert len(config_lines) == 1
    assert "NUMBER_OF_CPU_CORES" not in config_lines[0]
    assert "VERILATOR=$(VERILATOR_VERSION)" in config_lines[0]

    # Changing NUMBER_OF_CPU_CORES must not rewrite .build-config or force re-verilation,
    # and ASSERTIONS=1 vs ASSERTIONS=0 must toggle --assert and FROST_SIM_ASSERTIONS.
    if shutil.which("make") is not None:
        stamp = tmp_path / "sim_build" / "model_t1_a1_s0_host" / ".build-config"
        _run_checked(
            [
                "make",
                "-C",
                str(NATIVE_DIR),
                f"SIM_BUILD={tmp_path / 'sim_build'}",
                "NUMBER_OF_CPU_CORES=2",
                str(stamp),
            ]
        )
        stamp_first = stamp.read_text(encoding="utf-8")
        assert "--assert" in stamp_first
        assert "+define+FROST_SIM_ASSERTIONS" in stamp_first
        assert "-DFROST_NATIVE_ASSERTIONS" in stamp_first
        _run_checked(
            [
                "make",
                "-C",
                str(NATIVE_DIR),
                f"SIM_BUILD={tmp_path / 'sim_build'}",
                "NUMBER_OF_CPU_CORES=8",
                str(stamp),
            ]
        )
        assert stamp.read_text(encoding="utf-8") == stamp_first

        stamp_a0 = tmp_path / "sim_build" / "model_t1_a0_s0_host" / ".build-config"
        _run_checked(
            [
                "make",
                "-C",
                str(NATIVE_DIR),
                f"SIM_BUILD={tmp_path / 'sim_build'}",
                "ASSERTIONS=0",
                str(stamp_a0),
            ]
        )
        stamp_a0_text = stamp_a0.read_text(encoding="utf-8")
        assert "--assert" not in stamp_a0_text
        assert "+define+FROST_SIM_ASSERTIONS" not in stamp_a0_text
        assert "-DFROST_NATIVE_ASSERTIONS" not in stamp_a0_text

    assert native_defaults.get("CXX_OPT_SLOW") == "-O0"
    assert "--public-flat-rw" not in native_text
    assert "--vpi" not in native_text
    assert "--x-assign" not in native_text
    assert "--x-initial" not in native_text
    assert "FROST_RANDOM_START" not in native_text
    assert "tests/sim_build" not in native_text

    cflags_lines = [
        line
        for line in native_text.splitlines()
        if line.strip().startswith("NATIVE_CFLAGS :=")
    ]
    assert len(cflags_lines) == 1
    assert "-O3" not in cflags_lines[0]
    assert "CXX_OPT_FAST" not in cflags_lines[0]

    # Native README must document every remaining difference, the reset arming
    # point, both CI and full modes, and the bare-metal scope, and avoid stale claims.
    for token in EXPECTED_DOCUMENTED_DIFF_TOKENS:
        assert token in native_readme, f"native README omits diff token {token!r}"
    assert "18th rising edge" in native_readme
    assert "bare-metal programs only" in native_readme
    assert "tens of millions of simulated cycles" in native_readme
    assert "minutes" in native_readme
    assert "test-native" in native_readme
    assert "test-demo-image" in native_readme
    assert "--all" in native_readme
    assert "default Verilator options" not in native_readme
    assert "is not defined in" not in native_readme
    assert "not referenced in `hw/rtl`" not in native_readme
    for doc_text in (root_readme, native_readme, demo_script_text):
        assert "thousands of times faster" not in doc_text
        assert "hardware cycle count" not in doc_text

    # Neither README may reference a stored baseline file or hard-code cycle/tick counts.
    for doc_name, doc_text in (
        ("README.md", root_readme),
        ("hw/sim/native/README.md", native_readme),
    ):
        assert "exactness_baseline" not in doc_text, (
            f"{doc_name} references removed exactness_baseline.json"
        )
        assert "--update-baseline" not in doc_text, (
            f"{doc_name} references removed --update-baseline"
        )
        for value in FORBIDDEN_README_CYCLE_FIGURES:
            for rendered in (str(value), f"{value:,}"):
                assert rendered not in doc_text, (
                    f"{doc_name} hard-codes cycle or tick figure {rendered}"
                )

    assert "frost_sim_assertions_enable();" in main_cpp_text
    assert "frost_sim_assertions_enabled()" in main_cpp_text
    assert "threadContextp" not in main_cpp_text
    assert "addExitCb" not in main_cpp_text
    assert "on_verilator_exit_cb" not in main_cpp_text


def test_frost_native_vlt_exposes_only_harness_signals() -> None:
    """Verilator configuration exposes only the signals main.cpp accesses."""
    text = NATIVE_VLT.read_text(encoding="utf-8")
    assert "`verilator_config" in text

    exposed: set[tuple[str, str, str]] = set()
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("//") or stripped == "`verilator_config":
            continue
        match = re.match(
            r'^(public\w*)\s+-module\s+"([^"]+)"\s+-var\s+"([^"]+)"\s*$',
            stripped,
        )
        assert match is not None, f"unexpected verilator_config rule: {stripped}"
        rule, module, signal = match.groups()
        assert "*" not in signal, f"wildcard signal exposure is forbidden: {stripped}"
        exposed.add((rule, module, signal))

    assert exposed == EXPECTED_EXPOSED_SIGNALS


def _sample_coremark_uart(ticks: int, *, flags: str = "-O2 -march=rv64gcb") -> bytes:
    """Build representative CoreMark 2K UART output for invariant unit tests."""
    return (
        b"\r\nBaremetal Coremark 1 iterations, assuming 20000 Hz FPGA clock.\r\n"
        b"2K performance run parameters for coremark.\r\n"
        b"CoreMark Size    : 666\r\n"
        + f"Total ticks      : {ticks}\r\n".encode("ascii")
        + b"Total time (secs): 11.177800\r\n"
        b"Iterations/Sec   : 0.089463\r\n"
        b"Iterations       : 1\r\n"
        b"Compiler version : GCC16.2.0\r\n"
        + f"Compiler flags   : {flags}\r\n".encode("ascii")
        + b"Memory location  : STACK\r\n"
        b"seedcrc          : 0xe9f5\r\n"
        b"[0]crclist       : 0xe714\r\n"
        b"[0]crcmatrix     : 0x1fd7\r\n"
        b"[0]crcstate      : 0x8e3a\r\n"
        b"[0]crcfinal      : 0xe714\r\n"
        b"Correct operation validated. See README.md for run and reporting rules.\r\n"
        b"CoreMark 1.0 : 0.089463 / GCC16.2.0 / STACK\r\n"
        + f"Total 64-bit ticks : {ticks}\r\n".encode("ascii")
        + b"<<PASS>>"
    )


def test_program_and_summary_invariants_are_cycle_independent() -> None:
    """Invariants accept cycle/flag/print drift and reject bad output or summaries."""
    assert set(NATIVE_CASES) == {
        "hello_world_bram",
        "hello_world_ddr",
        "coremark_bram",
        "coremark_ddr",
    }
    ci_cases = {name for name, case in NATIVE_CASES.items() if case.ci}
    assert ci_cases == {"hello_world_bram", "hello_world_ddr", "coremark_bram"}
    for case in NATIVE_CASES.values():
        assert case.mem_config in {"bram", "ddr"}

    hello_case = NATIVE_CASES["hello_world_ddr"]
    for marker_cycle, extra_prefix in (
        (1792, b""),
        (1824, b""),
        (2410, b"Extra boot line before banner\r\n"),
    ):
        hello_uart = extra_prefix + b"[     0 s] Frost: Hello, world!\r\n"
        total_cycles = marker_cycle + hello_case.drain_cycles
        hello_summary: dict[str, Any] = {
            "cycles": total_cycles,
            "advanced_cycles": total_cycles,
            "marker_cycle": marker_cycle,
            "drain_cycles": hello_case.drain_cycles,
            "uart_bytes": len(hello_uart),
            "coremark_ticks": None,
            "wall_seconds": 0.125,
            "cycles_per_second": float(total_cycles) / 0.125,
            "threads": 4,
            "assertions_compiled": True,
            "assertions_armed": True,
            "passed": True,
            "failed": False,
        }
        assert_program_and_summary_invariants(
            hello_case,
            hello_summary,
            hello_uart,
            expected_threads=4,
        )

    bad_hello_uart = b"Greeting without expected prefix: Hello, world!\r\n"
    with pytest.raises(AssertionError, match="Frost: Hello, world!"):
        assert_program_and_summary_invariants(
            hello_case,
            {**hello_summary, "uart_bytes": len(bad_hello_uart)},
            bad_hello_uart,
            expected_threads=4,
        )

    with pytest.raises(AssertionError, match="assertions_armed"):
        assert_program_and_summary_invariants(
            hello_case,
            {**hello_summary, "assertions_armed": False},
            hello_uart,
            expected_threads=4,
        )

    cm_case = NATIVE_CASES["coremark_bram"]
    for cycles, ticks, flags in (
        (333130, 223556, "-O2 -march=rv64gcb"),
        (295000, 194321, "-O3 -march=rv64gcb_zcb"),
    ):
        cm_uart = _sample_coremark_uart(ticks, flags=flags)
        cm_summary: dict[str, Any] = {
            "cycles": cycles,
            "advanced_cycles": cycles,
            "marker_cycle": cycles,
            "drain_cycles": 0,
            "uart_bytes": len(cm_uart),
            "coremark_ticks": ticks,
            "wall_seconds": 1.5,
            "cycles_per_second": float(cycles) / 1.5,
            "threads": 4,
            "assertions_compiled": True,
            "assertions_armed": True,
            "passed": True,
            "failed": False,
        }
        assert_program_and_summary_invariants(
            cm_case,
            cm_summary,
            cm_uart,
            expected_threads=4,
        )

    for bad_token, replacement in (
        (b"Correct operation validated.", b"Operation not validated."),
        (b"seedcrc          : 0xe9f5", b"seedcrc          : 0xdead"),
        (b"[0]crclist       : 0xe714", b"[0]crclist       : 0x0000"),
        (b"[0]crcmatrix     : 0x1fd7", b"[0]crcmatrix     : 0x0000"),
        (b"[0]crcstate      : 0x8e3a", b"[0]crcstate      : 0x0000"),
        (b"[0]crcfinal      : 0xe714", b"[0]crcfinal      : 0x0000"),
        (b"<<PASS>>", b"DONE"),
    ):
        corrupted_uart = cm_uart.replace(bad_token, replacement)
        with pytest.raises(AssertionError):
            assert_program_and_summary_invariants(
                cm_case,
                {**cm_summary, "uart_bytes": len(corrupted_uart)},
                corrupted_uart,
                expected_threads=4,
            )

    zero_tick_uart = _sample_coremark_uart(0)
    with pytest.raises(AssertionError, match="0 < ticks < cycles"):
        assert_program_and_summary_invariants(
            cm_case,
            {
                **cm_summary,
                "uart_bytes": len(zero_tick_uart),
                "coremark_ticks": 0,
            },
            zero_tick_uart,
            expected_threads=4,
        )

    with pytest.raises(AssertionError, match="coremark_ticks"):
        assert_program_and_summary_invariants(
            cm_case,
            {**cm_summary, "coremark_ticks": None},
            cm_uart,
            expected_threads=4,
        )

    fail_uart = cm_uart + b"\r\n<<FAIL>>"
    with pytest.raises(AssertionError, match="<<FAIL>>"):
        assert_program_and_summary_invariants(
            cm_case,
            {**cm_summary, "uart_bytes": len(fail_uart)},
            fail_uart,
            expected_threads=4,
        )


def test_live_cocotb_mismatch_messages_name_differing_figure() -> None:
    """Mismatches between native and live cocotb fail naming the differing figure."""
    uart = _sample_coremark_uart(223556)
    live = ParsedRunResult(
        cycles=333130,
        coremark_ticks=223556,
        uart_bytes=len(uart),
        uart_sha256=hashlib.sha256(uart).hexdigest(),
    )
    summary: dict[str, Any] = {
        "cycles": live.cycles,
        "coremark_ticks": live.coremark_ticks,
        "uart_bytes": len(uart),
    }

    assert_native_matches_cocotb("coremark_bram", summary, uart, live)

    with pytest.raises(AssertionError) as cyc_err:
        assert_native_matches_cocotb(
            "coremark_bram",
            {**summary, "cycles": live.cycles + 32},
            uart,
            live,
        )
    assert "coremark_bram" in str(cyc_err.value)
    assert "cycles" in str(cyc_err.value)
    assert str(live.cycles + 32) in str(cyc_err.value)
    assert str(live.cycles) in str(cyc_err.value)

    with pytest.raises(AssertionError) as tick_err:
        assert_native_matches_cocotb(
            "coremark_bram",
            {**summary, "coremark_ticks": 223560},
            uart,
            live,
        )
    assert "coremark_ticks" in str(tick_err.value)
    assert "223560" in str(tick_err.value)

    extra_uart = uart + b"\n"
    with pytest.raises(AssertionError) as bytes_err:
        assert_native_matches_cocotb(
            "coremark_bram",
            {**summary, "uart_bytes": len(extra_uart)},
            extra_uart,
            live,
        )
    assert "uart_bytes" in str(bytes_err.value)

    altered_same_len = uart[:-1] + b"?"
    with pytest.raises(AssertionError) as sha_err:
        assert_native_matches_cocotb(
            "coremark_bram",
            summary,
            altered_same_len,
            live,
        )
    assert "uart_sha256" in str(sha_err.value)


def test_effective_cpu_count_and_demo_script_respect_cgroup_quotas(
    tmp_path: Path,
) -> None:
    """CPU detection honors cgroup CPU quotas rather than bare host nproc."""
    assert _parse_cgroup_v2_cpu_max("200000 100000\n") == 2
    assert _parse_cgroup_v2_cpu_max("50000 100000\n") == 1
    assert _parse_cgroup_v2_cpu_max("max 100000\n") is None
    assert _parse_cgroup_v1_quota("300000\n", "100000\n") == 3
    assert _parse_cgroup_v1_quota("-1\n", "100000\n") is None

    cg_two = tmp_path / "cpu_2.max"
    cg_two.write_text("200000 100000\n", encoding="utf-8")
    assert _effective_cpu_count(cgroup_v2_path=cg_two) <= 2

    # Verify demo/run_demo.sh picks 1 thread on a 2-CPU cgroup quota even on a
    # wide host, and forwards arguments through exec on a single-app invocation.
    demo_root = tmp_path / "demo"
    (demo_root / "bin").mkdir(parents=True)
    (demo_root / "apps" / "hello_world_bram").mkdir(parents=True)
    stub_t1 = demo_root / "bin" / "frost-native-t1"
    stub_t1.write_text(
        '#!/usr/bin/env bash\necho "stub_t1:$*"\n',
        encoding="utf-8",
    )
    stub_t1.chmod(0o755)
    stub_t4 = demo_root / "bin" / "frost-native-t4"
    stub_t4.write_text(
        '#!/usr/bin/env bash\necho "stub_t4:$*"\n',
        encoding="utf-8",
    )
    stub_t4.chmod(0o755)

    env = dict(os.environ)
    env.pop("FROST_THREADS", None)
    env["FROST_DEMO_ROOT"] = str(demo_root)
    env["FROST_CGROUP_CPU_MAX"] = str(cg_two)
    proc = subprocess.run(
        [str(DEMO_SCRIPT), "--app", "hello_world"],
        cwd=tmp_path,
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    assert "Simulator threads: 1" in proc.stdout
    assert "stub_t1:" in proc.stdout

    # Non-numeric cpu.max values must not abort run_demo.sh under set -e.
    for idx, bad_content in enumerate(
        ("100.5 100000\n", "bad-quota 100000\n", "200000 bad-period\n", "")
    ):
        cg_bad = tmp_path / f"cpu_bad_{idx}.max"
        cg_bad.write_text(bad_content, encoding="utf-8")
        assert _parse_cgroup_v2_cpu_max(bad_content) is None
        env_bad = dict(env)
        env_bad["FROST_CGROUP_CPU_MAX"] = str(cg_bad)
        bad_proc = subprocess.run(
            [str(DEMO_SCRIPT), "--app", "hello_world"],
            cwd=tmp_path,
            env=env_bad,
            capture_output=True,
            text=True,
            check=True,
        )
        assert "stub_t" in bad_proc.stdout


def test_parse_cocotb_program_log_extracts_cycles_ticks_and_uart() -> None:
    """Log parser strips cocotb status lines and preserves exact UART bytes."""
    hello_cycles = 11824
    hello_uart = b"[     0 s] Frost: Hello, world!\r\n"
    hello_ns = f"{hello_cycles * 3:.2f}".encode("ascii")
    hello_log = (
        b"    57.00ns INFO     test   === Starting run 1 of 1 ===\n"
        b"[     0 s] Frost: Hello, world!"
        b"  5472.00ns INFO     test   Run 1 PASSED: Found expected text 'Hello, world!'\n"
        b"\r\n\n\n"
        b" " + hello_ns + b"ns INFO     test   Run 1 completed after 1805 cycles\n"
    )
    parsed_hello = parse_cocotb_program_log(hello_log)
    assert parsed_hello.cycles == hello_cycles
    assert parsed_hello.coremark_ticks is None
    assert parsed_hello.uart_bytes == len(hello_uart)
    assert parsed_hello.uart_sha256 == hashlib.sha256(hello_uart).hexdigest()

    cm_cycles = 333130
    cm_ticks = 223556
    cm_ticks_bytes = str(cm_ticks).encode("ascii")
    cm_ns = f"{cm_cycles * 3:.2f}".encode("ascii")
    cm_uart = (
        b"CoreMark Size : 666\r\nTotal 64-bit ticks : "
        + cm_ticks_bytes
        + b"\r\n<<PASS>>"
    )
    cm_log = (
        b"    57.00ns INFO     test   === Starting run 1 of 1 ===\n"
        + cm_uart
        + b" "
        + cm_ns
        + b"ns INFO     test   Run 1 PASSED: Program printed success marker\n\n\n"
        + b" "
        + cm_ns
        + b"ns INFO     test   Run 1 completed after 333111 cycles\n"
        b"1050000.00ns INFO     cocotb.regression   passed\n"
    )
    parsed_cm = parse_cocotb_program_log(cm_log)
    assert parsed_cm.cycles == cm_cycles
    assert parsed_cm.coremark_ticks == cm_ticks
    assert parsed_cm.uart_bytes == len(cm_uart)
    assert parsed_cm.uart_sha256 == hashlib.sha256(cm_uart).hexdigest()


def test_demo_dockerfile_uses_checked_portable_baseline_build() -> None:
    """Demo Dockerfile builds checked portable x86-64 binaries and handles signals."""
    dockerfile = DEMO_DOCKERFILE.read_text(encoding="utf-8")
    dockerignore = (REPO_ROOT / "demo" / "Dockerfile.dockerignore").read_text(
        encoding="utf-8"
    )
    script_text = DEMO_SCRIPT.read_text(encoding="utf-8")

    assert "PORTABLE=1" in dockerfile
    assert "ASSERTIONS=1" in dockerfile
    assert "ASSERTIONS=0" not in dockerfile
    assert "SAVABLE=0" in dockerfile
    assert "STATIC_RUNTIME=1" in dockerfile
    assert "-march=native" not in dockerfile
    assert "/sys/fs/cgroup/cpu.max" in dockerfile
    assert "FROM ubuntu:26.04" in dockerfile
    assert "USER ubuntu" in dockerfile
    assert "COPY hw/sim/sim_assertions.cpp /src/hw/sim/sim_assertions.cpp" in dockerfile
    assert "!hw/sim/sim_assertions.cpp" in dockerignore
    assert "hw/sim/native/**" in dockerignore
    assert "frost-native-t" in script_text
    assert "trap 'forward_signal INT 130' INT" in script_text
    assert "trap 'forward_signal TERM 143' TERM" in script_text
    assert 'exec "$MODEL_BIN"' in script_text
    assert "not meaningful at" in script_text


def test_ci_workflow_runs_native_and_demo_image_jobs() -> None:
    """CI workflow runs both test-native and test-demo-image without pushing."""
    workflow = yaml.safe_load(CI_WORKFLOW.read_text(encoding="utf-8"))
    jobs = workflow["jobs"]

    assert "test-native" in jobs
    native_job = jobs["test-native"]
    assert set(native_job["needs"]) == {"build-docker", "gate"}
    assert "needs.gate.outputs.full == 'true'" in native_job["if"]
    assert int(native_job["timeout-minutes"]) == 25
    native_cmds = "\n".join(
        str(step.get("run", "")) for step in native_job.get("steps", [])
    )
    assert "sw/apps/coremark/coremark" in native_cmds
    assert "python3 tests/test_native_sim.py --ci" in native_cmds

    assert "test-demo-image" in jobs
    demo_job = jobs["test-demo-image"]
    assert set(demo_job["needs"]) == {"build-docker", "gate"}
    assert "needs.gate.outputs.full == 'true'" in demo_job["if"]
    assert int(demo_job["timeout-minutes"]) >= 25
    demo_cmds = "\n".join(
        str(step.get("run", "")) for step in demo_job.get("steps", [])
    )
    assert "sw/apps/coremark/coremark" in demo_cmds
    assert "docker load --input /tmp/frost-dev.tar" in demo_cmds
    assert "docker tag frost-dev:latest frost:latest" in demo_cmds
    assert "docker build -f demo/Dockerfile -t frost-demo:local ." in demo_cmds
    assert "docker run --rm frost-demo:local " in demo_cmds
    assert "docker run --rm frost-demo:local --threads 1 --app hello_world" in demo_cmds
    assert "Frost: Hello, world!" in demo_cmds
    assert "Correct operation validated." in demo_cmds
    assert "<<PASS>>" in demo_cmds
    assert "Demonstration finished:" in demo_cmds
    assert "docker push" not in demo_cmds


def test_native_runner_rtl_assertion_finish_and_split_fail(tmp_path: Path) -> None:
    """Native C++ runner reports RTL assertion, $finish, and split-marker failures."""
    if shutil.which("verilator") is None:
        pytest.skip("verilator is not installed in this environment")
    verify_runner_assertion_finish_and_split_fail(tmp_path)


@pytest.mark.slow
def test_native_exactness_and_checkpoints(tmp_path: Path) -> None:
    """Checked native simulation matches live cocotb runs across BRAM, DDR, and restore."""
    if shutil.which("verilator") is None:
        pytest.skip("verilator is not installed in this environment")
    if not COREMARK_MAIN_C.is_file():
        pytest.skip("coremark submodule is not initialized")
    run_exactness_suite(ci_only=False, check_checkpoints=True, work_dir=tmp_path)


def main(argv: list[str] | None = None) -> int:
    """Run the native simulation checks from the command line."""
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--ci",
        action="store_true",
        help=(
            "compare one live cocotb BRAM hello_world run with the native runner, "
            "then build the shipped portable checked native binary once and check "
            "DDR hello_world, BRAM coremark, and demo/run_demo.sh"
        ),
    )
    mode.add_argument(
        "--all",
        action="store_true",
        help=(
            "compare all four BRAM/DDR hello_world and coremark runs against live "
            "unseeded cocotb runs plus SAVABLE=1 checkpoint save and restore"
        ),
    )
    args = parser.parse_args(argv)

    with tempfile.TemporaryDirectory(prefix="frost-native-test-") as tmp:
        run_exactness_suite(
            ci_only=bool(args.ci),
            check_checkpoints=not bool(args.ci),
            work_dir=Path(tmp),
        )
    print("Native RTL simulation checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
