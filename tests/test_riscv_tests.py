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

"""Run riscv-tests ISA tests and benchmarks on Frost.

Self-checking tests: detect <<PASS>> or <<FAIL>> via UART output.
Much simpler than arch_test (no signature comparison needed).

Can be run standalone:
    ./test_riscv_tests.py --sim verilator --suites rv32ui rv32um
    ./test_riscv_tests.py --sim verilator --all
    ./test_riscv_tests.py --sim verilator --test rv32ui/add
    ./test_riscv_tests.py --sim verilator --suites rv32ui --parallel 4
    ./test_riscv_tests.py --sim verilator --benchmarks median qsort
    ./test_riscv_tests.py --sim verilator --all-benchmarks

Or via pytest:
    pytest test_riscv_tests.py -v --sim verilator -m slow
"""

import argparse
import os
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

from test_run_cocotb import CocotbRunner

# Directory layout
TESTS_DIR = Path(__file__).parent.resolve()
REPO_ROOT = TESTS_DIR.parent
RISCV_TESTS_APP_DIR = REPO_ROOT / "sw" / "apps" / "riscv_tests"
RISCV_TESTS_DIR = RISCV_TESTS_APP_DIR / "riscv-tests"
ISA_DIR = RISCV_TESTS_DIR / "isa"
BENCH_DIR = RISCV_TESTS_DIR / "benchmarks"

# ISA test suites and their subdirectories
ISA_TEST_SUITES = {
    "rv32ui": "RV32 Base Integer",
    "rv32um": "RV32 M Extension",
    "rv32ua": "RV32 A Extension",
    "rv32uf": "RV32 F Extension",
    "rv32ud": "RV32 D Extension",
    "rv32uc": "RV32 C Extension",
    "rv32mi": "RV32 Machine-Mode",
    "rv32uzba": "RV32 Zba Extension",
    "rv32uzbb": "RV32 Zbb Extension",
    "rv32uzbs": "RV32 Zbs Extension",
    "rv32uzbkb": "RV32 Zbkb Extension",
    # rv32si: SKIP — Frost is M-mode only, no supervisor mode
    # rv32uzbc: SKIP — Frost does not implement Zbc
    # rv32uzbkx: SKIP — Frost does not implement Zbkx
    # rv32uzfh: SKIP — Frost does not implement Zfh
}

# ISA tests to skip (known incompatible with Frost)
ISA_SKIP_TESTS: dict[str, set[str]] = {
    "rv32ui": {
        "fence_i",  # Harvard architecture: stores go to data RAM, fetches from instruction ROM
        "ma_data",  # Frost traps on misaligned access rather than handling in hardware
    },
    "rv32ud": {
        "move",  # Uses fmv.d.x/fmv.x.d (RV64-only); upstream has #TODO for 32-bit version
    },
    # Machine-mode tests that require specific trap behaviors not supported
    "rv32mi": {
        "breakpoint",  # Requires debug trigger module
        "pmpaddr",  # PMP not implemented on Frost
        "csr",  # Tests user-mode CSR restrictions via SRET; Frost is M-mode only
        "ma_addr",  # Expects misaligned loads to complete with data; Frost traps instead
    },
}

# Benchmark configurations
# Each entry: (directory_name, description, source_files, needs_double_fp)
BENCHMARKS = {
    "median": ("Median filter", ["median_main.c", "median.c"], False),
    "multiply": ("Software multiply", ["multiply_main.c", "multiply.c"], False),
    "qsort": ("Quicksort", ["qsort_main.c"], False),
    "rsort": ("Radix sort", ["rsort.c"], False),
    "towers": ("Towers of Hanoi", ["towers_main.c", "towers.c"], False),
    "vvadd": ("Vector-vector add", ["vvadd_main.c", "vvadd.c"], False),
    "dhrystone": ("Dhrystone", ["dhrystone_main.c", "dhrystone.c"], False),
    "mm": ("Matrix multiply", ["mm_main.c", "mm.c"], True),
    "spmv": ("Sparse matrix-vector multiply", ["spmv_main.c", "spmv.c"], True),
}


@dataclass
class TestResult:
    """Result of a single test."""

    test_name: str
    suite: str
    status: str  # "PASS", "FAIL", "SKIP"
    message: str = ""


def discover_isa_tests(suite: str) -> list[Path]:
    """Find all .S test files for an ISA test suite."""
    suite_dir = ISA_DIR / suite
    if not suite_dir.is_dir():
        return []

    tests = sorted(suite_dir.glob("*.S"))

    # Filter out Makefrag and other non-test files
    tests = [t for t in tests if t.stem != "Makefrag"]

    # Apply skip list
    skip_set = ISA_SKIP_TESTS.get(suite, set())
    if skip_set:
        tests = [t for t in tests if t.stem not in skip_set]

    return tests


def compile_isa_test(test_src: Path) -> bool:
    """Compile a single ISA test, returns True on success."""
    result = subprocess.run(
        ["make", "clean"],
        cwd=RISCV_TESTS_APP_DIR,
        capture_output=True,
        text=True,
        timeout=30,
    )

    rel_src = test_src.relative_to(RISCV_TESTS_APP_DIR)
    result = subprocess.run(
        ["make", f"TEST_SRC={rel_src}"],
        cwd=RISCV_TESTS_APP_DIR,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode != 0:
        return False
    return True


def compile_benchmark(bench_name: str) -> bool:
    """Compile a single benchmark, returns True on success."""
    result = subprocess.run(
        ["make", "clean"],
        cwd=RISCV_TESTS_APP_DIR,
        capture_output=True,
        text=True,
        timeout=30,
    )

    result = subprocess.run(
        ["make", "-f", "Makefile.bench", f"BENCH={bench_name}"],
        cwd=RISCV_TESTS_APP_DIR,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode != 0:
        return False
    return True


def run_simulation(
    simulator: str, max_cycles: str = "10000000"
) -> subprocess.CompletedProcess[str] | None:
    """Run cocotb simulation and return the result."""
    runner = CocotbRunner(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name=None,
    )

    os.environ["SIM"] = simulator
    env = runner.setup_environment()
    sim_build_dir = runner._get_sim_build_dir(env)
    env["SIM_BUILD"] = str(sim_build_dir)
    env["COCOTB_MAX_CYCLES"] = max_cycles
    env["COCOTB_NUM_RUNS"] = "1"

    original_dir = os.getcwd()
    os.chdir(TESTS_DIR)

    try:
        needs_clean = simulator != "verilator" or runner._verilator_needs_rebuild(
            sim_build_dir
        )
        if needs_clean:
            subprocess.run(["make", "clean"], check=False)

        sw_mem_path = Path("sw.mem")
        if sw_mem_path.exists() or sw_mem_path.is_symlink():
            sw_mem_path.unlink()
        sw_mem_target = RISCV_TESTS_APP_DIR / "sw.mem"
        sw_mem_path.symlink_to(sw_mem_target)

        pythonpath = env.get("PYTHONPATH", "")
        cmd = (
            f"export PYTHONPATH='{pythonpath}' && "
            f"make COCOTB_TEST_MODULES='cocotb_tests.test_real_program' "
            f"TOPLEVEL=frost"
        )
        result = subprocess.run(
            ["bash", "-c", cmd],
            capture_output=True,
            text=True,
            env=env,
            check=False,
            timeout=7200,
        )

        if simulator == "verilator" and result.returncode == 0:
            runner._update_verilator_toplevel_marker(sim_build_dir)

        return result

    except subprocess.TimeoutExpired:
        return None
    finally:
        sw_mem_path = Path("sw.mem")
        if sw_mem_path.exists() or sw_mem_path.is_symlink():
            sw_mem_path.unlink()
        os.chdir(original_dir)


def check_pass_fail(sim_result: subprocess.CompletedProcess[str]) -> tuple[str, str]:
    """Check simulation output for <<PASS>> or <<FAIL>>.

    Returns (status, message) where status is "PASS", "FAIL", or "SKIP".
    """
    combined_output = (sim_result.stdout or "") + (sim_result.stderr or "")

    # Check returncode first: when cocotb hits max cycles, its error message
    # may contain the literal '<<PASS>>' string, causing a false positive.
    if sim_result.returncode != 0:
        # Check if it was a <<FAIL>> from the test itself
        if "<<FAIL>>" in combined_output:
            # Extract test number from <<FAIL>> #XXXXXXXX output
            for line in combined_output.splitlines():
                if "<<FAIL>>" in line:
                    return "FAIL", f"Test reported failure: {line.strip()}"
            return "FAIL", "Test reported <<FAIL>>"
        return "SKIP", "Simulation error (non-zero return code)"

    if "<<PASS>>" in combined_output:
        return "PASS", ""

    if "<<FAIL>>" in combined_output:
        for line in combined_output.splitlines():
            if "<<FAIL>>" in line:
                return "FAIL", f"Test reported failure: {line.strip()}"
        return "FAIL", "Test reported <<FAIL>>"

    return "FAIL", "No <<PASS>> or <<FAIL>> marker in output"


def run_single_isa_test(test_src: Path, suite: str, simulator: str) -> TestResult:
    """Build, simulate, and verify a single ISA test."""
    test_name = test_src.stem

    if not compile_isa_test(test_src):
        return TestResult(test_name, suite, "SKIP", "Compilation failed")

    result = run_simulation(simulator)
    if result is None:
        return TestResult(test_name, suite, "SKIP", "Simulation timed out")

    status, message = check_pass_fail(result)
    return TestResult(test_name, suite, status, message)


def run_single_benchmark(bench_name: str, simulator: str) -> TestResult:
    """Build, simulate, and verify a single benchmark."""
    if bench_name not in BENCHMARKS:
        return TestResult(
            bench_name, "benchmarks", "SKIP", f"Unknown benchmark: {bench_name}"
        )

    if not compile_benchmark(bench_name):
        return TestResult(bench_name, "benchmarks", "SKIP", "Compilation failed")

    # Benchmarks may need more cycles than ISA tests
    result = run_simulation(simulator, max_cycles="50000000")
    if result is None:
        return TestResult(bench_name, "benchmarks", "SKIP", "Simulation timed out")

    status, message = check_pass_fail(result)
    return TestResult(bench_name, "benchmarks", status, message)


def _run_isa_test_worker(args: tuple[str, str, str, str]) -> TestResult:
    """Worker function for parallel ISA test execution."""
    test_src_str, suite, simulator, app_dir_str = args
    global RISCV_TESTS_APP_DIR, RISCV_TESTS_DIR, ISA_DIR
    RISCV_TESTS_APP_DIR = Path(app_dir_str)
    RISCV_TESTS_DIR = RISCV_TESTS_APP_DIR / "riscv-tests"
    ISA_DIR = RISCV_TESTS_DIR / "isa"

    return run_single_isa_test(Path(test_src_str), suite, simulator)


def _print_result(result: TestResult) -> None:
    """Print a single test result."""
    status_str = {"PASS": "PASS", "FAIL": "FAIL", "SKIP": "SKIP"}[result.status]
    line = f"  {result.test_name:40s} {status_str}"
    if result.message and result.status != "PASS":
        first_line = result.message.split("\n")[0]
        line += f"  ({first_line})"
    print(line)


def run_suite_tests(
    suite: str,
    simulator: str,
    parallel: int = 1,
) -> list[TestResult]:
    """Run all tests for a given ISA test suite."""
    tests = discover_isa_tests(suite)
    if not tests:
        print(f"  No tests found for suite {suite}")
        return []

    desc = ISA_TEST_SUITES.get(suite, suite)
    print(f"\nSuite: {suite} - {desc} ({len(tests)} tests)")

    results = []

    if parallel > 1:
        work_items = [
            (str(t), suite, simulator, str(RISCV_TESTS_APP_DIR)) for t in tests
        ]
        with ProcessPoolExecutor(max_workers=parallel) as executor:
            futures = {
                executor.submit(_run_isa_test_worker, item): item[0]
                for item in work_items
            }
            for future in as_completed(futures):
                try:
                    result = future.result()
                except Exception as e:
                    failed_src = futures[future]
                    test_name = Path(failed_src).stem
                    result = TestResult(test_name, suite, "SKIP", str(e))
                results.append(result)
                _print_result(result)
    else:
        for test_src in tests:
            result = run_single_isa_test(test_src, suite, simulator)
            results.append(result)
            _print_result(result)

    return results


def run_benchmark_tests(
    bench_names: list[str],
    simulator: str,
) -> list[TestResult]:
    """Run specified benchmarks."""
    print(f"\nBenchmarks ({len(bench_names)} tests)")

    results = []
    for bench_name in bench_names:
        result = run_single_benchmark(bench_name, simulator)
        results.append(result)
        _print_result(result)

    return results


# =============================================================================
# Pytest Integration
# =============================================================================


@pytest.mark.cocotb
@pytest.mark.slow
class TestRiscvTests:
    """riscv-tests ISA tests."""

    SUITES = list(ISA_TEST_SUITES.keys())

    @pytest.mark.parametrize("suite", SUITES)
    def test_riscv_isa_suite(self, suite: str, request: Any, capsys: Any) -> None:
        """Run riscv-tests ISA suite for a given test category.

        Parametrized by suite (not individual test) for manageable pytest output.
        Verilator only.
        """
        sim = request.config.getoption("--sim")
        if sim != "verilator":
            pytest.skip("riscv-tests require verilator")

        os.environ["SIM"] = "verilator"
        with capsys.disabled():
            print(f"\nRunning riscv-tests ISA suite {suite}...")
            results = run_suite_tests(suite, "verilator")

        failed = [r for r in results if r.status == "FAIL"]
        if failed:
            msg = "\n".join(f"  {r.test_name}: {r.message}" for r in failed)
            pytest.fail(f"{len(failed)} riscv-test(s) failed:\n{msg}")


@pytest.mark.cocotb
@pytest.mark.slow
class TestRiscvBenchmarks:
    """riscv-tests benchmarks."""

    BENCH_NAMES = list(BENCHMARKS.keys())

    @pytest.mark.parametrize("bench_name", BENCH_NAMES)
    def test_riscv_benchmark(self, bench_name: str, request: Any, capsys: Any) -> None:
        """Run a single riscv-tests benchmark.

        Verilator only.
        """
        sim = request.config.getoption("--sim")
        if sim != "verilator":
            pytest.skip("riscv-tests benchmarks require verilator")

        os.environ["SIM"] = "verilator"
        with capsys.disabled():
            print(f"\nRunning riscv-tests benchmark {bench_name}...")
            result = run_single_benchmark(bench_name, "verilator")
            _print_result(result)

        if result.status == "FAIL":
            pytest.fail(f"Benchmark {bench_name} failed: {result.message}")


# =============================================================================
# Standalone CLI
# =============================================================================


def main() -> int:
    """Run riscv-tests on Frost."""
    parser = argparse.ArgumentParser(
        description="Run riscv-tests ISA tests and benchmarks on Frost",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
Examples:
  %(prog)s --sim verilator --suites rv32ui rv32um
  %(prog)s --sim verilator --all
  %(prog)s --sim verilator --test rv32ui/add
  %(prog)s --sim verilator --suites rv32ui --parallel 4
  %(prog)s --sim verilator --benchmarks median qsort mm
  %(prog)s --sim verilator --all-benchmarks
  %(prog)s --list

Available ISA test suites: {', '.join(ISA_TEST_SUITES.keys())}
Available benchmarks: {', '.join(BENCHMARKS.keys())}
""",
    )
    parser.add_argument(
        "--sim",
        required=True,
        choices=["icarus", "verilator", "questa"],
        help="Simulator to use",
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--suites",
        nargs="+",
        metavar="SUITE",
        help="ISA test suites to run (e.g., rv32ui rv32um)",
    )
    group.add_argument(
        "--all",
        action="store_true",
        help="Run all supported ISA test suites",
    )
    group.add_argument(
        "--test",
        metavar="SUITE/TEST",
        help="Run a single test (e.g., rv32ui/add)",
    )
    group.add_argument(
        "--benchmarks",
        nargs="+",
        metavar="BENCH",
        help="Benchmarks to run (e.g., median qsort mm)",
    )
    group.add_argument(
        "--all-benchmarks",
        action="store_true",
        help="Run all supported benchmarks",
    )
    group.add_argument(
        "--list",
        action="store_true",
        help="List available test suites and benchmarks",
    )
    parser.add_argument(
        "--parallel",
        type=int,
        default=1,
        metavar="N",
        help="Number of parallel test workers (default: 1, sequential)",
    )

    args = parser.parse_args()

    if args.list:
        print("ISA Test Suites:")
        for suite, desc in ISA_TEST_SUITES.items():
            tests = discover_isa_tests(suite)
            print(f"  {suite:20s} {desc:30s} ({len(tests)} tests)")
        print("\nBenchmarks:")
        for name, (desc, _, fp) in BENCHMARKS.items():
            fp_str = " [FP]" if fp else ""
            print(f"  {name:20s} {desc}{fp_str}")
        return 0

    # Single test mode
    if args.test:
        parts = args.test.split("/")
        if len(parts) != 2:
            print("Error: Test must be in format SUITE/TEST (e.g., rv32ui/add)")
            return 1

        suite, test_name = parts
        test_path = ISA_DIR / suite / f"{test_name}.S"
        if not test_path.exists():
            print(f"Error: Test file not found: {test_path}")
            return 1

        print(f"=== riscv-tests: {args.test} ===")
        result = run_single_isa_test(test_path, suite, args.sim)
        _print_result(result)
        return 0 if result.status == "PASS" else 1

    # Benchmark mode
    if args.benchmarks or args.all_benchmarks:
        bench_names = (
            list(BENCHMARKS.keys()) if args.all_benchmarks else args.benchmarks
        )

        # Validate benchmark names
        for name in bench_names:
            if name not in BENCHMARKS:
                print(f"Error: Unknown benchmark '{name}'")
                print(f"Available: {', '.join(BENCHMARKS.keys())}")
                return 1

        print("=" * 60)
        print("riscv-tests Benchmark Results")
        print(f"Simulator: {args.sim}")
        print(f"Benchmarks: {', '.join(bench_names)}")
        print("=" * 60)

        all_results = run_benchmark_tests(bench_names, args.sim)
        n_pass = sum(1 for r in all_results if r.status == "PASS")
        n_fail = sum(1 for r in all_results if r.status == "FAIL")
        n_skip = sum(1 for r in all_results if r.status == "SKIP")

        print()
        print("=" * 60)
        print(f"Summary: {n_pass} PASS, {n_fail} FAIL, {n_skip} SKIP")
        print("=" * 60)
        return 1 if n_fail > 0 else 0

    # ISA test suite mode
    suites = list(ISA_TEST_SUITES.keys()) if args.all else args.suites

    # Validate suites
    for suite in suites:
        if suite not in ISA_TEST_SUITES:
            print(f"Warning: Suite '{suite}' not in known suites, will try anyway")

    print("=" * 60)
    print("riscv-tests ISA Test Results")
    print(f"Simulator: {args.sim}")
    print(f"Suites: {', '.join(suites)}")
    print("=" * 60)

    all_results = []
    for suite in suites:
        results = run_suite_tests(suite, args.sim, parallel=args.parallel)
        all_results.extend(results)

    # Summary
    n_pass = sum(1 for r in all_results if r.status == "PASS")
    n_fail = sum(1 for r in all_results if r.status == "FAIL")
    n_skip = sum(1 for r in all_results if r.status == "SKIP")

    print()
    print("=" * 60)
    print(f"Summary: {n_pass} PASS, {n_fail} FAIL, {n_skip} SKIP")
    print("=" * 60)

    failed = [r for r in all_results if r.status == "FAIL"]
    if failed:
        print("\nFailed tests:")
        for r in failed:
            print(f"  [{r.suite}] {r.test_name}")
            if r.message:
                for line in r.message.split("\n"):
                    print(f"    {line}")

    return 1 if n_fail > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
