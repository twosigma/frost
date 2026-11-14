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

"""Run short seeded startups against one compiled system simulation."""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
from typing import Any
from xml.etree import ElementTree

from cocotb_tools import config

from test_run_cocotb import CocotbRunner


def run_startup_sweep(
    binary: Path,
    environment: dict[str, str],
    output: Path,
    *,
    count: int = 200,
    workers: int = 2,
    baseline: bool = False,
) -> bool:
    """Reuse a random-start model for reset and 300 cycles under each seed."""
    binary = binary.resolve()
    output = output.resolve()
    if not binary.is_file():
        raise ValueError(f"simulator does not exist: {binary}")
    build_record = binary.parent / "Vtop__verFiles.dat"
    if (
        not build_record.is_file()
        or "FROST_RANDOM_START" not in build_record.read_text()
    ):
        raise ValueError("the simulator must have been built with random start enabled")
    if count < 1 or workers not in (1, 2):
        raise ValueError("count must be positive and workers must be 1 or 2")
    output.mkdir(parents=True, exist_ok=True)
    environment = environment.copy()
    environment.update(
        COCOTB_TEST_MODULES="cocotb_tests.test_random_start_smoke",
        COCOTB_TOPLEVEL="frost",
        TOPLEVEL_LANG="verilog",
        PYGPI_PYTHON_BIN=sys.executable,
        GPI_USERS=(
            subprocess.check_output(
                [sys.executable, "-m", "find_libpython"], text=True
            ).strip()
            + ";"
            + config.pygpi_entry_point()
        ),
    )
    # Select the smoke test even when the caller restricts its ordinary tests.
    for key in ("COCOTB_TESTCASE", "COCOTB_TEST_FILTER"):
        environment.pop(key, None)
    if baseline:
        environment["FROST_STARTUP_BASELINE"] = "1"
    else:
        environment.pop("FROST_STARTUP_BASELINE", None)
    seeds = list(dict.fromkeys([1231038950, *range(1, count + 1)]))

    def run_one(seed: int) -> dict[str, Any]:
        env = environment.copy()
        report = output / f"seed_{seed}.xml"
        report.unlink(missing_ok=True)
        env["COCOTB_RESULTS_FILE"] = str(report)
        arguments = [
            str(binary),
            "+verilator+rand+reset+2",
            f"+verilator+seed+{seed}",
            "+verilator+coverage+file+/dev/null",
        ]
        if not baseline:
            arguments.append("+verilator+noassert")
        started = time.monotonic()
        result = subprocess.run(
            arguments,
            cwd=Path(__file__).resolve().parent,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=120,
        )
        (output / f"seed_{seed}.log").write_text(result.stdout)
        try:
            cases = ElementTree.parse(report).findall(".//testcase")
        except (OSError, ElementTree.ParseError):
            cases = []
        passed = (
            result.returncode == 0
            and "STARTUP_SMOKE_PASS" in result.stdout
            and bool(cases)
            and not any(
                case.find("failure") is not None or case.find("error") is not None
                for case in cases
            )
            and (baseline or "Simulation assertions armed after reset" in result.stdout)
        )
        return {
            "seed": seed,
            "passed": passed,
            "returncode": result.returncode,
            "seconds": round(time.monotonic() - started, 3),
            "errors": [
                line
                for line in result.stdout.splitlines()
                if "%Error" in line or "AssertionError" in line
            ],
        }

    started = time.monotonic()
    results: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=workers) as pool:
        pending = {pool.submit(run_one, seed): seed for seed in seeds}
        for future in as_completed(pending):
            result = future.result()
            results.append(result)
            if not result["passed"]:
                print(
                    f"Startup seed {result['seed']} FAILED: {result['errors']}",
                    flush=True,
                )
    elapsed = time.monotonic() - started
    summary = {
        "binary": str(binary),
        "sha256": hashlib.file_digest(binary.open("rb"), "sha256").hexdigest(),
        "baseline": baseline,
        "workers": workers,
        "seconds": round(elapsed, 3),
        "results": sorted(results, key=lambda row: row["seed"]),
    }
    (output / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
    passed = sum(result["passed"] for result in results)
    print(
        f"Startup sweep: {passed}/{len(results)} passed in {elapsed:.1f}s", flush=True
    )
    return passed == len(results)


def main() -> int:
    """Use a registry entry's environment with an already compiled model."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--test", required=True, help="registry entry used for the build"
    )
    parser.add_argument("--binary", type=Path, default=Path("tests/sim_build/Vtop"))
    parser.add_argument("--output", type=Path, default=Path("tests/startup_sweep"))
    parser.add_argument("--count", type=int, default=200)
    parser.add_argument("--workers", type=int, choices=(1, 2), default=2)
    parser.add_argument(
        "--baseline",
        action="store_true",
        help="observe a model with checks active at time zero",
    )
    args = parser.parse_args()
    runner = CocotbRunner.for_test(args.test)
    try:
        if runner.hdl_toplevel_module != "frost":
            parser.error("startup sweeps require a frost system build")
        return (
            0
            if run_startup_sweep(
                args.binary,
                runner.setup_environment(),
                args.output,
                count=args.count,
                workers=args.workers,
                baseline=args.baseline,
            )
            else 1
        )
    finally:
        runner.restore_environment()


if __name__ == "__main__":
    raise SystemExit(main())
