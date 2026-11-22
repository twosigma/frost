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
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Mapping
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
DEMO_SHOW_CPP = REPO_ROOT / "demo" / "frost_show.cpp"
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
    # --stats activity counters.
    ("public_flat_rd", "cpu_ooo", "instruction_retired_count"),
    ("public_flat_rd", "cpu_ooo", "commit_branch_retired_count"),
    ("public_flat_rd", "cpu_ooo", "commit_branch_mispredict_count"),
    ("public_flat_rd", "reorder_buffer", "count"),
    # --regions: the PCs of the instructions at the head of the reorder buffer.
    ("public_flat_rd", "reorder_buffer", "head_pc"),
    ("public_flat_rd", "reorder_buffer", "head_next_pc"),
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

# Forbid grouped or plain 5- to 6-digit cycle or tick counts in the two READMEs
# while permitting non-workload constants like 10,000 drain cycles or 5,000,000.
README_HARDCODED_CYCLE_OR_TICK_RE = re.compile(
    r"(?<![,\d])(?:\d{2,3},\d{3}|\d{5,6})(?![,\d])\s+(?:simulated\s+)?(?:cycles|ticks)\b"
    r"|\b(?:Simulated\s+cycles|CoreMark\s+ticks|Total(?:\s+64-bit)?\s+ticks)\s*:\s*(?:\d{2,3},\d{3}|\d{5,6})(?![,\d])",
    re.IGNORECASE,
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
    # The unseeded reference has no decimal DDR overrides to filter.
    makefile_text = makefile_text.replace(
        "$(filter-out $(DDR_RUNTIME_PATTERNS),$(FROST_VERILATOR_EXTRA_ARGS))",
        "$(FROST_VERILATOR_EXTRA_ARGS)",
    )
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


def check_case_and_record_comparison(
    case: NativeCase,
    summary: dict[str, Any],
    uart_bytes: bytes,
    live_cocotb: Mapping[str, ParsedRunResult],
    compared: set[str],
    *,
    expected_threads: int,
) -> None:
    """Verify one native case's invariants and record live cocotb parity if present."""
    assert_program_and_summary_invariants(
        case,
        summary,
        uart_bytes,
        expected_threads=expected_threads,
    )
    if case.name in live_cocotb:
        assert_native_matches_cocotb(
            case.name,
            summary,
            uart_bytes,
            live_cocotb[case.name],
        )
        compared.add(case.name)


def assert_all_live_cocotb_cases_compared(
    compared: set[str],
    live_cocotb: Mapping[str, ParsedRunResult],
) -> None:
    """Fail if any live cocotb run was not matched and compared against a native run."""
    expected = set(live_cocotb)
    assert compared == expected, (
        "live cocotb parity comparison set mismatch: "
        f"compared={sorted(compared)}, live_cocotb={sorted(expected)}"
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
    with tempfile.TemporaryFile() as log:
        proc = subprocess.run(
            ["./test_run_cocotb.py", app],
            cwd=TESTS_DIR,
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            timeout=1800,
            check=False,
        )
        if log.tell() > 64 * 1024 * 1024:
            raise RuntimeError(f"{app}: cocotb log exceeds 64 MiB")
        log.seek(0)
        raw_log = log.read(64 * 1024 * 1024)
    elapsed = time.monotonic() - t0
    if proc.returncode != 0:
        sys.stderr.buffer.write(raw_log)
        sys.stderr.flush()
        raise subprocess.CalledProcessError(proc.returncode, proc.args)
    parsed = parse_cocotb_program_log(raw_log)
    print(
        f"[cocotb] {app} ({mem_config}) completed in {elapsed:.2f}s "
        f"(cycles={parsed.cycles}, ticks={parsed.coremark_ticks}, "
        f"uart_bytes={parsed.uart_bytes})",
        flush=True,
    )
    return parsed


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
    assert "to stop marker + 10,000 drain" in proc.stdout
    assert "RTL assertions   : enabled after reset" in proc.stdout
    assert proc.stdout.index("Frost: Hello, world!") < proc.stdout.index(
        "--- FROST RTL simulation summary ---"
    )
    assert not proc.stderr


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

    for case in selected:
        live_cocotb[case.name] = run_live_cocotb_case(
            case.app,
            case.mem_config,
            clean_first=True,
        )

    if ci_only:
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
    compared: set[str] = set()
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
        run_elapsed = time.monotonic() - t_run
        assert not retire_log.exists(), (
            f"{case.name}: unexpected retire_trace.log written in working directory"
        )
        summary = json.loads(json_path.read_text(encoding="utf-8"))
        uart_bytes = uart_path.read_bytes()
        print(
            f"\n[native] {case.name} completed in {run_elapsed:.2f}s "
            f"(cycles={summary['cycles']}, ticks={summary['coremark_ticks']}, "
            f"uart_bytes={summary['uart_bytes']})",
            flush=True,
        )
        check_case_and_record_comparison(
            case,
            summary,
            uart_bytes,
            live_cocotb,
            compared,
            expected_threads=threads,
        )
    assert_all_live_cocotb_cases_compared(compared, live_cocotb)

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
  // --stats reads the occupancy; this harness keeps three entries in flight.
  logic [5:0] count = 6'd3;
  // --regions reads the head PCs; two instructions retire every cycle, as in the
  // activity signals below.
  logic [63:0] head_pc = 64'h100;
  logic [63:0] head_next_pc = 64'h104;
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

// --stats activity signals: two instructions and one branch retire every
// cycle.
module cpu_ooo (input logic i_clk);
  logic [1:0] instruction_retired_count = 2'd2;
  logic [1:0] commit_branch_retired_count = 2'd1;
  logic [1:0] commit_branch_mispredict_count = 2'd0;
  sub_tomasulo u_tomasulo (.i_clk(i_clk));
endmodule

module sub_hart (input logic i_clk);
  cpu_ooo cpu_inst (.i_clk(i_clk));
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
  string pass_text = "Hello, world!\\n<<PASS>>TAIL\\n";

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
      end else if ($test$plusargs("SPLIT_PASS_MARKER")) begin
        if (post_rst_step < 21) begin
          uart_write_enable_from_cpu <= 1'b1;
          uart_write_data_from_cpu <= pass_text[post_rst_step];
        end else if (post_rst_step >= 34 && post_rst_step < 40) begin
          uart_write_enable_from_cpu <= 1'b1;
          uart_write_data_from_cpu <= pass_text[post_rst_step - 13];
        end
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
    """Compile the native runner on a test top to check arming, faults, and UART order."""
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

    # --stats: cumulative counts every --stats-interval cycles from reset
    # release (cycle 20) and a final line.
    stats_path = work_dir / "activity.stats"
    subprocess.run(
        [
            str(bin_path),
            "--mem-dir",
            str(mem_dir),
            "--max-cycles",
            "70",
            "--stop",
            "",
            "--quiet-summary",
            "--stats",
            str(stats_path),
            "--stats-interval",
            "30",
        ],
        cwd=work_dir,
        capture_output=True,
        text=True,
        check=True,
    )
    stats_lines = stats_path.read_text(encoding="utf-8").splitlines()
    assert [line.split()[0] for line in stats_lines] == [
        "cycle=30",
        "cycle=60",
        "cycle=70",
    ]
    final_stats = dict(item.split("=") for item in stats_lines[-1].split())
    assert final_stats["final"] == "1"
    assert final_stats["instructions"] == str(2 * 50)
    assert final_stats["retired2"] == "50" and final_stats["retired0"] == "0"
    assert final_stats["branches"] == "50" and final_stats["mispredicts"] == "0"
    assert final_stats["rob_occupancy_sum"] == str(3 * 50)

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

    # The final '>' arrives after a gap. A partial marker cannot stop the run.
    for max_cycles, drain, expected_cycles, expected_uart in (
        (55, 0, 55, b"Hello, world!\n<<PASS>"),
        (100, 0, 56, b"Hello, world!\n<<PASS>>"),
        (100, 5, 61, b"Hello, world!\n<<PASS>>TAIL\n"),
    ):
        pass_json = work_dir / f"split_pass_{max_cycles}_{drain}.json"
        pass_uart = pass_json.with_suffix(".uart")
        pass_proc = subprocess.run(
            [
                str(bin_path),
                "--mem-dir",
                str(mem_dir),
                "--max-cycles",
                str(max_cycles),
                "--drain",
                str(drain),
                "--uart-out",
                str(pass_uart),
                "--summary-json",
                str(pass_json),
                "+SPLIT_PASS_MARKER",
            ],
            cwd=work_dir,
            capture_output=True,
            timeout=30,
            check=False,
        )
        passed = max_cycles == 100
        assert pass_proc.returncode == (0 if passed else 1)
        assert pass_proc.stdout == expected_uart
        assert pass_uart.read_bytes() == expected_uart
        pass_summary = json.loads(pass_json.read_text(encoding="utf-8"))
        assert pass_summary["cycles"] == expected_cycles
        assert pass_summary["marker_cycle"] == (56 if passed else None)
        assert pass_summary["passed"] is passed

    _verify_demo_uart_summary_order(bin_path, mem_dir, work_dir)


def _verify_demo_uart_summary_order(
    binary: Path, mem_dir: Path, work_dir: Path
) -> None:
    """Relay stderr before the final UART byte to force separate-pipe reordering."""
    demo_root = work_dir / "demo_order"
    bin_dir = demo_root / "bin"
    apps_dir = demo_root / "apps"
    bin_dir.mkdir(parents=True)
    apps_dir.mkdir()
    for app in ("hello_world", "coremark"):
        (apps_dir / f"{app}_bram").symlink_to(mem_dir)
    wrapper = bin_dir / "frost-native-t1"
    wrapper.write_text(
        f'#!/bin/sh\nexec {shlex.quote(str(binary))} "$@" +SPLIT_PASS_MARKER\n',
        encoding="utf-8",
    )
    wrapper.chmod(0o755)
    env = dict(os.environ, FROST_DEMO_ROOT=str(demo_root))
    summary_header = b"--- FROST RTL simulation summary ---"

    for app in ("coremark", "all", "hello_world"):
        # Spool stdout until stderr reaches EOF, then forward stderr at the
        # final '>' to model a delayed stdout relay without a scheduling race.
        stdout_log = work_dir / f"demo_order_{app}.stdout"
        with stdout_log.open("wb") as stdout_file:
            proc = subprocess.run(
                [str(DEMO_SCRIPT), "--threads", "1", "--app", app],
                cwd=work_dir,
                env=env,
                stdout=stdout_file,
                stderr=subprocess.PIPE,
                timeout=30,
                check=False,
            )
        assert proc.returncode == 0
        stdout_bytes = stdout_log.read_bytes()
        delay_at = stdout_bytes.index(b"<<PASS>>") + len(b"<<PASS>>") - 1
        relayed = stdout_bytes[:delay_at] + proc.stderr + stdout_bytes[delay_at:]
        expected_uart = (
            b"Hello, world!\n<<PASS>>"
            if app == "coremark"
            else b"Hello, world!\n<<PASS>>TAIL\n"
        )
        assert b"<<PASS>>" in relayed, "summary split the UART success marker"
        assert relayed.index(expected_uart) < relayed.index(summary_header)
        assert not proc.stderr, "demo output must share one stdout pipe"
        assert relayed.count(summary_header) == (2 if app == "all" else 1)
        if app == "all":
            assert relayed.rindex(b"<<PASS>>") < relayed.rindex(summary_header)


def test_cocotb_makefile_waveform_flags() -> None:
    """Pin the compile and runtime trace flags under WAVES=1."""
    makefile = TESTS_MAKEFILE.read_text(encoding="utf-8")
    assert parse_makefile_default_vars(makefile)["WAVES"] == "0"

    waves_block = makefile.partition("ifeq ($(WAVES),1)\n")[2].partition("\nendif")[0]
    enabled, disabled = waves_block.split("\nelse\n", 1)
    compile_args = re.search(r"(?m)^\s*export EXTRA_ARGS := (.+)$", enabled)
    assert compile_args is not None
    assert {"--trace-fst", "--trace-structs"} <= set(
        _group_verilator_tokens(compile_args.group(1))
    )
    assert "SIM_ARGS += --trace" in {line.strip() for line in enabled.splitlines()}
    assert "--trace" not in disabled


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
    assert cocotb_frost_flags == EXPECTED_SHARED_VERILATOR_FLAGS | {
        "-j $(NUMBER_OF_CPU_CORES)",
        "+define+FROST_RUNTIME_DDR",
    }

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
    for sample in (
        "completes in 12,345 cycles",
        "takes 345,678 simulated cycles",
        "prints 234,567 ticks",
        "Simulated cycles : 12,345",
        "CoreMark ticks   : 234,567",
        "Total 64-bit ticks : 234567",
    ):
        assert README_HARDCODED_CYCLE_OR_TICK_RE.search(sample) is not None
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
        match = README_HARDCODED_CYCLE_OR_TICK_RE.search(doc_text)
        assert match is None, (
            f"{doc_name} hard-codes cycle or tick figure: {match.group(0)!r}"
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

    # Key-name drift in live_cocotb must never silently skip parity comparison.
    cm_case = NATIVE_CASES["coremark_bram"]
    full_summary: dict[str, Any] = {
        "cycles": live.cycles,
        "advanced_cycles": live.cycles,
        "marker_cycle": live.cycles,
        "drain_cycles": 0,
        "uart_bytes": len(uart),
        "coremark_ticks": live.coremark_ticks,
        "wall_seconds": 1.0,
        "cycles_per_second": float(live.cycles),
        "threads": 4,
        "assertions_compiled": True,
        "assertions_armed": True,
        "passed": True,
        "failed": False,
    }
    compared_ok: set[str] = set()
    live_ok = {"coremark_bram": live}
    check_case_and_record_comparison(
        cm_case,
        full_summary,
        uart,
        live_ok,
        compared_ok,
        expected_threads=4,
    )
    assert_all_live_cocotb_cases_compared(compared_ok, live_ok)
    assert compared_ok == {"coremark_bram"}

    compared_drifted: set[str] = set()
    live_drifted = {"coremark_brm": live}
    check_case_and_record_comparison(
        cm_case,
        full_summary,
        uart,
        live_drifted,
        compared_drifted,
        expected_threads=4,
    )
    with pytest.raises(AssertionError, match="coremark_brm"):
        assert_all_live_cocotb_cases_compared(compared_drifted, live_drifted)


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

    # Execute the actual BUILD_JOBS shell sanitiser from demo/Dockerfile.
    joined_dockerfile = dockerfile.replace("\\\n", "\n")
    start_marker = 'jobs="${BUILD_JOBS}";'
    end_marker = "make -C /src/hw/sim/native stage-app"
    assert start_marker in joined_dockerfile and end_marker in joined_dockerfile
    jobs_snippet = joined_dockerfile.split(start_marker, 1)[1].split(end_marker, 1)[0]
    sh_script = f'{start_marker}\n{jobs_snippet}\nprintf "%s\\n" "$jobs"\n'

    def _eval_build_jobs(raw_val: str) -> str:
        proc = subprocess.run(
            ["/bin/sh", "-eu", "-c", sh_script],
            env={
                "BUILD_JOBS": raw_val,
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            },
            capture_output=True,
            text=True,
            check=True,
        )
        return proc.stdout.strip()

    auto_jobs = int(_eval_build_jobs(""))
    assert 1 <= auto_jobs <= 8
    for bad_jobs in ("0", "000", "abc", "-2", "2.5", " 4"):
        assert _eval_build_jobs(bad_jobs) == "1"
    assert _eval_build_jobs("08") == "8"
    assert _eval_build_jobs("4") == "4"
    assert _eval_build_jobs("16") == "16"


def test_ci_workflow_runs_native_and_demo_image_jobs() -> None:
    """CI workflow runs both test-native and test-demo-image without pushing."""
    workflow = yaml.safe_load(CI_WORKFLOW.read_text(encoding="utf-8"))
    jobs = workflow["jobs"]

    assert "test-native" in jobs
    native_job = jobs["test-native"]
    assert set(native_job["needs"]) == {"build-docker", "build-sim-models", "gate"}
    assert "needs.gate.outputs.full == 'true'" in native_job["if"]
    assert int(native_job["timeout-minutes"]) >= 35
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
    assert "docker run --rm frost-demo:local --quick" in demo_cmds
    assert "docker run --rm frost-demo:local --raw" in demo_cmds
    assert "docker run --rm frost-demo:local --threads 1 --app hello_world" in demo_cmds
    assert "Frost: Hello, world!" in demo_cmds
    # The closing table's CoreMark cycles must equal the iteration's cycles it reports.
    assert "Counted while rendering and inside CoreMark's timed loop" in demo_cmds
    assert "clock cycles for this first iteration" in demo_cmds
    # The step's shell is executed against inputs in tests/test_demo_show.py.
    assert "Correct operation validated." in demo_cmds
    assert "Demonstration finished:" in demo_cmds
    # The quick demonstration's self-checks, as frost-show prints them.
    for phrase in (
        "clock cycles, checksum verified.",
        "every CRC correct (validated by CoreMark)",
        "Both programs verified their own results.",
    ):
        assert phrase in demo_cmds
        assert phrase in DEMO_SHOW_CPP.read_text(encoding="utf-8")
    assert "docker push" not in demo_cmds


def test_native_runner_rtl_assertion_finish_and_split_fail(tmp_path: Path) -> None:
    """Native runner checks arming, HDL exits, complete markers, and demo UART order."""
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
            "compare live unseeded cocotb runs of BRAM and DDR hello_world and BRAM "
            "coremark with the shipped portable checked native binary and check "
            "demo/run_demo.sh"
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


# A scripted retirement timeline for the --regions counters. As in the RTL, the
# head PCs are valid in the clock in which an instruction commits and the
# retirement counts are registered one clock later. Events (clock: PCs): 100: 0x10;
# 103: 0x14 and 0x18 together; 104: 0x1c, a branch; 108: 0x20; 109: 0x24 and 0x28
# together; 112: 0x2c; 116: 0x30 and 0x34, both branches.
_REGION_TIMELINE_SV = """\
module reorder_buffer (
    input  logic        i_clk,
    output logic [ 1:0] o_retire_now,
    output logic [ 1:0] o_branch_now
);
  integer retire_trace_fd;
  logic [ 5:0] count = 6'd3;
  logic [63:0] head_pc;
  logic [63:0] head_next_pc;
  int unsigned k = 0;
  initial retire_trace_fd = $fopen("retire_trace.log", "w");
  always_ff @(posedge i_clk) k <= k + 1;
  always_comb begin
    o_retire_now = 2'd0;
    o_branch_now = 2'd0;
    head_pc = 64'h0;
    head_next_pc = 64'h0;
    case (k)
      100: begin o_retire_now = 2'd1; head_pc = 64'h10; end
      103: begin o_retire_now = 2'd2; head_pc = 64'h14; head_next_pc = 64'h18; end
      104: begin o_retire_now = 2'd1; head_pc = 64'h1c; o_branch_now = 2'd1; end
      108: begin o_retire_now = 2'd1; head_pc = 64'h20; end
      109: begin o_retire_now = 2'd2; head_pc = 64'h24; head_next_pc = 64'h28; end
      112: begin o_retire_now = 2'd1; head_pc = 64'h2c; end
      116: begin
        o_retire_now = 2'd2; head_pc = 64'h30; head_next_pc = 64'h34; o_branch_now = 2'd2;
      end
      default: ;
    endcase
  end
endmodule

module sub_tomasulo (
    input  logic       i_clk,
    output logic [1:0] o_retire_now,
    output logic [1:0] o_branch_now
);
  reorder_buffer u_rob (.i_clk(i_clk), .o_retire_now(o_retire_now), .o_branch_now(o_branch_now));
endmodule

module cpu_ooo (input logic i_clk);
  logic [1:0] now_count;
  logic [1:0] now_branch;
  logic [1:0] instruction_retired_count = 2'd0;
  logic [1:0] commit_branch_retired_count = 2'd0;
  logic [1:0] commit_branch_mispredict_count = 2'd0;
  always_ff @(posedge i_clk) begin
    instruction_retired_count <= now_count;
    commit_branch_retired_count <= now_branch;
  end
  sub_tomasulo u_tomasulo (.i_clk(i_clk), .o_retire_now(now_count), .o_branch_now(now_branch));
endmodule

"""


@pytest.fixture(scope="module")
def region_runner(
    tmp_path_factory: pytest.TempPathFactory,
) -> Callable[..., dict[str, int]]:
    """Build the scripted-timeline runner once; return a function that counts a region."""
    if shutil.which("verilator") is None:
        pytest.skip("verilator is not installed in this environment")
    tmp_path = tmp_path_factory.mktemp("region_runner")
    head = _SYNTHETIC_FROST_HARNESS_SV[
        : _SYNTHETIC_FROST_HARNESS_SV.index("module reorder_buffer")
    ]
    tail = _SYNTHETIC_FROST_HARNESS_SV[
        _SYNTHETIC_FROST_HARNESS_SV.index("module sub_hart") :
    ]
    harness_sv = tmp_path / "region_harness.sv"
    harness_sv.write_text(head + _REGION_TIMELINE_SV + tail, encoding="utf-8")
    mdir = tmp_path / "obj_dir"
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
            "frost-native-region-test",
            "--Mdir",
            str(mdir),
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
        cwd=tmp_path,
    )
    cores = max(1, min(4, _effective_cpu_count()))
    _run_checked(["make", "-C", str(mdir), "-f", "Vtop.mk", f"-j{cores}"], cwd=tmp_path)
    mem_dir = tmp_path / "mem"
    mem_dir.mkdir()
    (mem_dir / "sw.mem").write_text("00000000\n", encoding="utf-8")
    (mem_dir / "sw64.mem").write_text("0000000000000000\n", encoding="utf-8")
    (mem_dir / "sw_ddr.mem").write_text("00000000\n", encoding="utf-8")

    def counted(
        start: int, end: int, skips: tuple[tuple[int, int], ...] = ()
    ) -> dict[str, int]:
        regions = tmp_path / f"regions_{start:x}_{end:x}.txt"
        regions.write_text(
            f"start {start:#x}\nend {end:#x}\n"
            + "".join(f"skip {lo:#x} {hi:#x}\n" for lo, hi in skips)
            + "rob_depth 32\n",
            encoding="utf-8",
        )
        stats = tmp_path / f"stats_{start:x}_{end:x}.txt"
        subprocess.run(
            [
                str(mdir / "frost-native-region-test"),
                "--mem-dir",
                str(mem_dir),
                "--max-cycles",
                "400",
                "--stop",
                "",
                "--stats",
                str(stats),
                "--stats-interval",
                "100",
                "--regions",
                str(regions),
                "--quiet-summary",
            ],
            cwd=tmp_path,
            capture_output=True,
            text=True,
            check=False,
        )
        last = stats.read_text(encoding="utf-8").splitlines()[-1]
        return {k: int(v) for k, v in (f.split("=") for f in last.split() if "=" in f)}

    return counted


def test_region_counts_follow_the_retirement_clock(
    region_runner: Callable[..., dict[str, int]],
) -> None:
    """--regions charges width and branches to the instructions that retired them."""
    # From the first retirement to the last: 12 clocks; 7 instructions retire in
    # five clocks (two retire two together, three retire one); the branch is one.
    whole = region_runner(0x10, 0x2C)
    assert whole["region_cycles"] == 12
    assert whole["region_instructions"] == 7
    assert whole["region_retired2"] == 2
    assert whole["region_retired1"] == 3
    assert whole["region_retired0"] == 7
    assert whole["region_branches"] == 1
    assert whole["rob_depth"] == 32
    # The second instruction of a dual retirement starts it; the branch alone
    # follows one clock later.
    branch = region_runner(0x18, 0x1C)
    assert (branch["region_cycles"], branch["region_instructions"]) == (1, 1)
    assert (branch["region_retired1"], branch["region_retired2"]) == (1, 0)
    assert branch["region_branches"] == 1
    # A dual retirement in the region is charged as dual, not split across clocks.
    dual = region_runner(0x20, 0x28)
    assert (dual["region_cycles"], dual["region_instructions"]) == (1, 2)
    assert (dual["region_retired2"], dual["region_retired1"]) == (1, 0)


def test_region_with_start_and_end_on_the_same_retirement_is_empty(
    region_runner: Callable[..., dict[str, int]],
) -> None:
    """A start and an end that retire together bound a region of zero cycles."""
    empty = region_runner(0x14, 0x18)
    assert (empty["region_cycles"], empty["region_instructions"]) == (0, 0)
    assert empty["region_branches"] == 0
    assert (
        empty["region_retired0"]
        == empty["region_retired1"]
        == empty["region_retired2"]
        == 0
    )


def test_region_leaves_out_cycles_that_end_in_skipped_instructions(
    region_runner: Callable[..., dict[str, int]],
) -> None:
    """Cycles that end in a skipped instruction are left out with that instruction."""
    skipped = region_runner(0x10, 0x2C, skips=((0x1C, 0x20),))
    assert skipped["region_cycles"] == 12 - 1
    assert skipped["region_instructions"] == 6
    assert skipped["region_branches"] == 0


def test_region_splits_the_branches_of_a_pair_that_straddles_a_skipped_range(
    region_runner: Callable[..., dict[str, int]],
) -> None:
    """Two branch events in a pair with one skipped instruction count one."""
    straddle = region_runner(0x2C, 0x34, skips=((0x34, 0x38),))
    assert (straddle["region_cycles"], straddle["region_instructions"]) == (4, 1)
    assert straddle["region_branches"] == 1
