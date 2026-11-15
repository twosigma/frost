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

"""Verify the C++ Verilator RTL runner against cocotb program runs."""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest
import yaml  # type: ignore[import-untyped]

REPO_ROOT = Path(__file__).resolve().parents[1]
NATIVE_DIR = REPO_ROOT / "hw" / "sim" / "native"
NATIVE_MAKEFILE = NATIVE_DIR / "Makefile"
NATIVE_VLT = NATIVE_DIR / "frost_native.vlt"
BASELINE_PATH = NATIVE_DIR / "exactness_baseline.json"
TESTS_MAKEFILE = REPO_ROOT / "tests" / "Makefile"
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

EXPECTED_EXPOSED_SIGNALS = {
    ("public_flat_rw", "frost", "uart_write_enable_from_cpu"),
    ("public_flat_rw", "frost", "uart_write_data_from_cpu"),
    ("public_flat_rw", "frost", "reset_synchronizer_shift_register"),
    ("public_flat_rw", "frost", "reset_synchronized"),
    ("public_flat_rw", "frost", "reset_div4_synchronizer_shift_register"),
    ("public_flat_rw", "reorder_buffer", "retire_trace_fd"),
}

HEX_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


@dataclass(frozen=True)
class ExactnessCase:
    """Reference values for one application and memory configuration."""

    name: str
    app: str
    mem_config: str
    stop_marker: str
    drain_cycles: int
    cycles: int
    coremark_ticks: int | None
    uart_bytes: int
    uart_sha256: str
    ci: bool


@dataclass(frozen=True)
class ParsedRunResult:
    """Cycle count, tick count, and UART digest from a simulation run."""

    cycles: int
    coremark_ticks: int | None
    uart_bytes: int
    uart_sha256: str


def load_exactness_cases(path: Path = BASELINE_PATH) -> dict[str, ExactnessCase]:
    """Load the exactness reference records from JSON."""
    payload = json.loads(path.read_text(encoding="utf-8"))
    raw_cases = payload["cases"]
    cases: dict[str, ExactnessCase] = {}
    for name, item in raw_cases.items():
        cases[name] = ExactnessCase(
            name=name,
            app=str(item["app"]),
            mem_config=str(item["mem_config"]),
            stop_marker=str(item["stop_marker"]),
            drain_cycles=int(item["drain_cycles"]),
            cycles=int(item["cycles"]),
            coremark_ticks=(
                int(item["coremark_ticks"])
                if item["coremark_ticks"] is not None
                else None
            ),
            uart_bytes=int(item["uart_bytes"]),
            uart_sha256=str(item["uart_sha256"]),
            ci=bool(item["ci"]),
        )
    return cases


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


def _default_threads() -> int:
    """Choose a bounded thread count for exactness runs."""
    raw = os.environ.get("FROST_NATIVE_TEST_THREADS")
    if raw is not None:
        return max(1, int(raw))
    return max(1, min(4, os.cpu_count() or 1))


def _run_checked(command: list[str], *, cwd: Path = REPO_ROOT) -> None:
    """Run a subprocess and raise with context on failure."""
    subprocess.run(command, cwd=cwd, check=True)


def _assert_matches_case(
    case: ExactnessCase,
    summary: dict[str, Any],
    uart_bytes: bytes,
    *,
    expected_advanced_cycles: int | None = None,
) -> None:
    """Verify one native simulation summary and UART capture against baseline."""
    assert summary["passed"] is True, f"{case.name}: simulation did not report pass"
    assert summary["failed"] is False, f"{case.name}: simulation reported failure"
    assert int(summary["cycles"]) == case.cycles, (
        f"{case.name}: cycles {summary['cycles']} != {case.cycles}"
    )
    if expected_advanced_cycles is not None:
        assert int(summary["advanced_cycles"]) == expected_advanced_cycles, (
            f"{case.name}: advanced_cycles {summary['advanced_cycles']} "
            f"!= {expected_advanced_cycles}"
        )
    assert summary["coremark_ticks"] == case.coremark_ticks, (
        f"{case.name}: coremark_ticks {summary['coremark_ticks']} "
        f"!= {case.coremark_ticks}"
    )
    assert int(summary["uart_bytes"]) == case.uart_bytes, (
        f"{case.name}: summary uart_bytes {summary['uart_bytes']} != {case.uart_bytes}"
    )
    assert len(uart_bytes) == case.uart_bytes, (
        f"{case.name}: captured UART length {len(uart_bytes)} != {case.uart_bytes}"
    )
    digest = hashlib.sha256(uart_bytes).hexdigest()
    assert digest == case.uart_sha256, (
        f"{case.name}: UART sha256 {digest} != {case.uart_sha256}"
    )


def run_exactness_suite(
    *,
    ci_only: bool,
    check_checkpoints: bool,
    work_dir: Path,
) -> None:
    """Build the checked native runner and verify selected exactness cases."""
    cases = load_exactness_cases()
    selected = [case for case in cases.values() if (case.ci if ci_only else True)]
    threads = _default_threads()
    sim_build = NATIVE_DIR / "sim_build"
    checked_bin = sim_build / f"model_t{threads}_a1_s0_host" / "frost-native"

    _run_checked(
        [
            "make",
            "-C",
            str(NATIVE_DIR),
            "build",
            f"THREADS={threads}",
            "ASSERTIONS=1",
            "SAVABLE=0",
        ]
    )
    assert checked_bin.is_file(), f"missing compiled binary {checked_bin}"

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
        assert not retire_log.exists(), (
            f"{case.name}: unexpected retire_trace.log written in working directory"
        )
        summary = json.loads(json_path.read_text(encoding="utf-8"))
        _assert_matches_case(case, summary, uart_path.read_bytes())

    if check_checkpoints:
        savable_bin = sim_build / f"model_t{threads}_a1_s1_host" / "frost-native"
        _run_checked(
            [
                "make",
                "-C",
                str(NATIVE_DIR),
                "build",
                f"THREADS={threads}",
                "ASSERTIONS=1",
                "SAVABLE=1",
            ]
        )
        hello_case = cases["hello_world_bram"]
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

        # 1. Mid-execution checkpoint before stop marker is printed (--stop "").
        ckpt_1k = work_dir / "hello_1k.ckpt"
        restored_1k_uart = work_dir / "hello_1k_restored.uart"
        restored_1k_json = work_dir / "hello_1k_restored.json"
        _run_checked(
            [
                str(savable_bin),
                "--mem-dir",
                str(sim_build / "apps" / "hello_world_bram"),
                "--threads",
                str(threads),
                "--max-cycles",
                "1000",
                "--stop",
                "",
                "--save",
                str(ckpt_1k),
                "--save-at",
                "1000",
                "--quiet-summary",
            ],
            cwd=work_dir,
        )
        assert ckpt_1k.is_file(), "mid-execution checkpoint file was not created"

        _run_checked(
            [
                str(savable_bin),
                "--restore",
                str(ckpt_1k),
                "--threads",
                str(threads),
                "--stop",
                hello_case.stop_marker,
                "--drain",
                str(hello_case.drain_cycles),
                "--uart-out",
                str(restored_1k_uart),
                "--summary-json",
                str(restored_1k_json),
                "--quiet-summary",
            ],
            cwd=empty_run_dir,
        )
        assert not (empty_run_dir / "retire_trace.log").exists()
        restored_1k_summary = json.loads(restored_1k_json.read_text(encoding="utf-8"))
        _assert_matches_case(
            hello_case,
            restored_1k_summary,
            restored_1k_uart.read_bytes(),
            expected_advanced_cycles=hello_case.cycles - 1000,
        )

        # 2. Mid-drain checkpoint after stop marker has already matched.
        ckpt_5k = work_dir / "hello_5k.ckpt"
        restored_5k_uart = work_dir / "hello_5k_restored.uart"
        restored_5k_json = work_dir / "hello_5k_restored.json"
        _run_checked(
            [
                str(savable_bin),
                "--mem-dir",
                str(sim_build / "apps" / "hello_world_bram"),
                "--threads",
                str(threads),
                "--max-cycles",
                "5000",
                "--stop",
                hello_case.stop_marker,
                "--drain",
                str(hello_case.drain_cycles),
                "--save",
                str(ckpt_5k),
                "--save-at",
                "5000",
                "--quiet-summary",
            ],
            cwd=work_dir,
        )
        assert ckpt_5k.is_file(), "mid-drain checkpoint file was not created"

        _run_checked(
            [
                str(savable_bin),
                "--restore",
                str(ckpt_5k),
                "--threads",
                str(threads),
                "--stop",
                hello_case.stop_marker,
                "--drain",
                str(hello_case.drain_cycles),
                "--uart-out",
                str(restored_5k_uart),
                "--summary-json",
                str(restored_5k_json),
                "--quiet-summary",
            ],
            cwd=empty_run_dir,
        )
        assert not (empty_run_dir / "retire_trace.log").exists()
        restored_5k_summary = json.loads(restored_5k_json.read_text(encoding="utf-8"))
        _assert_matches_case(
            hello_case,
            restored_5k_summary,
            restored_5k_uart.read_bytes(),
            expected_advanced_cycles=hello_case.cycles - 5000,
        )


def compare_baseline_against_cocotb_logs(log_dir: Path) -> None:
    """Verify every baseline entry against captured cocotb program logs."""
    cases = load_exactness_cases()
    for name, case in cases.items():
        log_path = log_dir / f"cocotb_{name}.log"
        if not log_path.is_file():
            raise FileNotFoundError(f"missing cocotb log: {log_path}")
        parsed = parse_cocotb_program_log(log_path.read_bytes())
        assert parsed.cycles == case.cycles, (
            f"{name}: cocotb cycles {parsed.cycles} != baseline {case.cycles}"
        )
        assert parsed.coremark_ticks == case.coremark_ticks, (
            f"{name}: cocotb ticks {parsed.coremark_ticks} "
            f"!= baseline {case.coremark_ticks}"
        )
        assert parsed.uart_bytes == case.uart_bytes, (
            f"{name}: cocotb uart_bytes {parsed.uart_bytes} != baseline {case.uart_bytes}"
        )
        assert parsed.uart_sha256 == case.uart_sha256, (
            f"{name}: cocotb sha256 {parsed.uart_sha256} != baseline {case.uart_sha256}"
        )


def test_native_makefile_matches_cocotb_toplevel_parameters() -> None:
    """Native Makefile and cocotb Makefile pass identical frost parameters."""
    native_text = NATIVE_MAKEFILE.read_text(encoding="utf-8")
    cocotb_text = TESTS_MAKEFILE.read_text(encoding="utf-8")

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

    assert "$(ROOT)/hw/rtl/frost.f" in native_text
    assert "$(ROOT)/hw/sim/native/frost_native.vlt" in native_text
    assert "--public-flat-rw" not in native_text
    assert "--vpi" not in native_text
    assert "tests/sim_build" not in native_text


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


def test_exactness_baseline_schema_and_invariants() -> None:
    """Exactness baseline covers hello_world and coremark in BRAM and DDR."""
    cases = load_exactness_cases()
    assert set(cases) == {
        "hello_world_bram",
        "hello_world_ddr",
        "coremark_bram",
        "coremark_ddr",
    }
    assert cases["coremark_bram"].coremark_ticks == 223556
    assert cases["coremark_ddr"].coremark_ticks is not None
    assert cases["coremark_ddr"].coremark_ticks > cases["coremark_bram"].coremark_ticks
    assert cases["hello_world_bram"].coremark_ticks is None
    assert cases["hello_world_ddr"].coremark_ticks is None

    ci_cases = {name for name, case in cases.items() if case.ci}
    assert ci_cases == {"hello_world_bram", "hello_world_ddr", "coremark_bram"}

    for case in cases.values():
        assert case.mem_config in {"bram", "ddr"}
        assert case.cycles > 20
        assert case.uart_bytes > 0
        assert HEX_SHA256_RE.match(case.uart_sha256)


def test_parse_cocotb_program_log_extracts_cycles_ticks_and_uart() -> None:
    """Log parser strips cocotb status lines and preserves exact UART bytes."""
    hello_uart = b"[     0 s] Frost: Hello, world!\r\n"
    hello_log = (
        b"    57.00ns INFO     test   === Starting run 1 of 1 ===\n"
        b"[     0 s] Frost: Hello, world!"
        b"  5376.00ns INFO     test   Run 1 PASSED: Found expected text 'Hello, world!'\n"
        b"\r\n\n\n"
        b" 35376.00ns INFO     test   Run 1 completed after 1773 cycles\n"
    )
    parsed_hello = parse_cocotb_program_log(hello_log)
    assert parsed_hello.cycles == 11792
    assert parsed_hello.coremark_ticks is None
    assert parsed_hello.uart_bytes == len(hello_uart)
    assert parsed_hello.uart_sha256 == hashlib.sha256(hello_uart).hexdigest()

    cm_uart = b"CoreMark Size : 666\r\nTotal 64-bit ticks : 223556\r\n<<PASS>>"
    cm_log = (
        b"    57.00ns INFO     test   === Starting run 1 of 1 ===\n"
        + cm_uart
        + b" 999390.00ns INFO     test   Run 1 PASSED: Program printed success marker\n"
        b"\n\n"
        b" 999390.00ns INFO     test   Run 1 completed after 333111 cycles\n"
        b"1050000.00ns INFO     cocotb.regression   passed\n"
    )
    parsed_cm = parse_cocotb_program_log(cm_log)
    assert parsed_cm.cycles == 333130
    assert parsed_cm.coremark_ticks == 223556
    assert parsed_cm.uart_bytes == len(cm_uart)
    assert parsed_cm.uart_sha256 == hashlib.sha256(cm_uart).hexdigest()


def test_demo_dockerfile_uses_portable_baseline_build() -> None:
    """Demo Dockerfile compiles portable x86-64 binaries in its own directory."""
    dockerfile = DEMO_DOCKERFILE.read_text(encoding="utf-8")
    dockerignore = (REPO_ROOT / "demo" / "Dockerfile.dockerignore").read_text(
        encoding="utf-8"
    )
    script_text = DEMO_SCRIPT.read_text(encoding="utf-8")

    assert "PORTABLE=1" in dockerfile
    assert "ASSERTIONS=0" in dockerfile
    assert "SAVABLE=0" in dockerfile
    assert "-march=native" not in dockerfile
    assert "-static-libstdc++" in dockerfile
    assert "FROM ubuntu:26.04" in dockerfile
    assert "hw/sim/native/**" in dockerignore
    assert "frost-native-t" in script_text


def test_ci_workflow_runs_native_exactness_job() -> None:
    """Regular CI workflow runs one bounded test-native exactness job."""
    workflow = yaml.safe_load(CI_WORKFLOW.read_text(encoding="utf-8"))
    jobs = workflow["jobs"]
    assert "test-native" in jobs
    job = jobs["test-native"]
    assert set(job["needs"]) == {"build-docker", "gate"}
    assert "needs.gate.outputs.full == 'true'" in job["if"]
    assert int(job["timeout-minutes"]) <= 20

    commands = "\n".join(str(step.get("run", "")) for step in job.get("steps", []))
    assert "sw/apps/coremark/coremark" in commands
    assert "python3 tests/test_native_sim.py --ci" in commands


@pytest.mark.slow
def test_native_exactness_and_checkpoints(tmp_path: Path) -> None:
    """Checked native simulation matches cocotb across BRAM, DDR, and restore."""
    if shutil.which("verilator") is None:
        pytest.skip("verilator is not installed in this environment")
    if not COREMARK_MAIN_C.is_file():
        pytest.skip("coremark submodule is not initialized")
    run_exactness_suite(ci_only=False, check_checkpoints=True, work_dir=tmp_path)


def main(argv: list[str] | None = None) -> int:
    """Run the native simulation exactness checks from the command line."""
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--ci",
        action="store_true",
        help="build checked model once and check hello_world (bram/ddr) and BRAM coremark",
    )
    mode.add_argument(
        "--all",
        action="store_true",
        help="check all four BRAM/DDR cases plus checkpoint save and restore",
    )
    parser.add_argument(
        "--compare-cocotb-dir",
        type=Path,
        default=None,
        help="verify exactness_baseline.json against cocotb_<case>.log files in DIR",
    )
    args = parser.parse_args(argv)

    if args.compare_cocotb_dir is not None:
        compare_baseline_against_cocotb_logs(args.compare_cocotb_dir)
        print("All cocotb logs match exactness_baseline.json.")
        if not args.ci and not args.all:
            return 0

    with tempfile.TemporaryDirectory(prefix="frost-native-test-") as tmp:
        run_exactness_suite(
            ci_only=bool(args.ci),
            check_checkpoints=not bool(args.ci),
            work_dir=Path(tmp),
        )
    print("Native RTL exactness checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
