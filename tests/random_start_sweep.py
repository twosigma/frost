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
import importlib.util
import json
import os
import random
import re
import shlex
from pathlib import Path
import subprocess
import sys
import time
from typing import Any
from xml.etree import ElementTree

from cocotb_tools import config

DEFAULT_BASE = "frost-startup"
STARTUP_BUDGET_SECONDS = 180


def startup_seeds(base: str, count: int) -> list[int]:
    """Derive each simulator seed from the job base and its zero-based index."""
    return [
        random.Random(f"{base}:startup:{index}").randint(1, 2**31 - 1)
        for index in range(count)
    ]


def startup_seed_cost(environment: dict[str, str]) -> float:
    """Estimate seconds per startup on four CPUs for the build's geometry."""
    arguments = environment.get("FROST_VERILATOR_EXTRA_ARGS", "")
    if "FROST_SRAM_MACROS" in arguments:
        return 6.5
    if "FROST_RVFI_DII" in arguments:
        return 1.3
    if "-GL2_CACHE_BYTES=4194304" in arguments:
        return 4.25
    if environment.get("FROST_COVERAGE") == "1":
        return 4.25
    if "-GVECTOR=1" in arguments:
        return 2.75
    return 2.5


def startup_count(cost: float) -> int:
    """Allocate a fixed seed count within the job's estimated startup budget."""
    override = os.environ.get("FROST_STARTUP_SEEDS", "").strip()
    count = (
        int(override)
        if override
        else min(200, max(1, int(STARTUP_BUDGET_SECONDS / cost)))
    )
    if count < 1:
        raise ValueError("FROST_STARTUP_SEEDS must be positive")
    return count


def plan_startup_sweeps(test_names: list[str]) -> None:
    """Share the job budget across its distinct system build configurations."""
    from test_run_cocotb import CocotbRunner

    costs = {}
    for name in test_names:
        runner = CocotbRunner.for_test(name)
        try:
            if runner.hdl_toplevel_module != "frost":
                continue
            environment = runner.setup_environment()
            key = (
                environment["FROST_VERILATOR_EXTRA_ARGS"],
                bool(environment.get("FROST_CPU_PERIOD_PS")),
                environment.get("FROST_COVERAGE", "0"),
                environment.get("SIM_FAST_MAINT", "1"),
            )
            costs[key] = startup_seed_cost(environment)
        finally:
            runner.restore_environment()
    if costs:
        plan = {
            "base": os.environ.get("FROST_RANDOM_START_SEED", "").strip()
            or DEFAULT_BASE,
            "count": startup_count(sum(costs.values())),
            "builds": len(costs),
        }
        directory = Path(__file__).resolve().parent / "startup_sweep"
        directory.mkdir(exist_ok=True)
        (directory / "plan.json").write_text(json.dumps(plan) + "\n")
        print(f"Startup plan: {plan}", flush=True)


def check_built_model(binary: Path, environment: dict[str, str]) -> None:
    """Check each compiled model once per seed base and count, without rebuilding."""
    base = environment.get("FROST_RANDOM_START_SEED", "").strip() or DEFAULT_BASE
    directory = Path(__file__).resolve().parent / "startup_sweep"
    count = startup_count(startup_seed_cost(environment))
    plan_path = directory / "plan.json"
    if plan_path.exists() and not environment.get("FROST_STARTUP_SEEDS"):
        plan = json.loads(plan_path.read_text())
        if plan["base"] == base:
            count = plan["count"]
    with binary.open("rb") as executable:
        digest = hashlib.file_digest(executable, "sha256").hexdigest()
    fixture = hashlib.sha256()
    for name in (
        "test_random_start_smoke.py",
        "test_real_program.py",
        "sim_assertions.py",
    ):
        path = Path(__file__).resolve().parents[1] / "verif/cocotb_tests" / name
        fixture.update(path.read_bytes())
    identity = hashlib.sha256(
        f"{digest}:{fixture.hexdigest()}:{base}:{count}".encode()
    ).hexdigest()
    output = directory / identity
    marker = output / "passed"
    if marker.exists():
        return
    if not run_startup_sweep(binary, environment, output, count=count, workers=1):
        raise RuntimeError(f"Random-start startup check failed; logs: {output}")
    marker.touch()


def write_startup_images(directory: Path, build_record: str) -> None:
    """Preload consistent instruction banks without an application build."""
    model_path = (
        Path(__file__).resolve().parents[1]
        / "sw/common/generate_imem_predecode_init.py"
    )
    spec = importlib.util.spec_from_file_location("startup_imem", model_path)
    assert spec is not None and spec.loader is not None
    model = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(model)
    sizes = re.findall(r"-GMEM_SIZE_BYTES=(0x[0-9a-fA-F]+|[0-9]+)", build_record)
    words = int(sizes[-1], 0) // 4 if sizes else 2**16
    # The instruction copy covers at most the 128 KiB low-BRAM code region.
    word = 0x0000006F
    sideband = model.make_sideband(word)
    values = {
        "cold": model.pack_cold_data(word),
        "frontend_hot": model.pack_frontend_hot(word),
        "sideband": sideband,
        "compressed": model.make_fast_replica(word, sideband),
    }
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "sw.mem").write_text(f"{word:08x}\n" * words)
    (directory / "sw64.mem").write_text("0000000000000000\n" * (words // 2))
    (directory / "sw_ddr.mem").write_text("00000000\n")
    for parity in ("even", "odd"):
        for bank, value in values.items():
            (directory / f"sw_imem_{parity}_{bank}.mem").write_text(
                f"{value:x}\n" * (min(words, 32768) // 2)
            )


def run_startup_sweep(
    binary: Path,
    environment: dict[str, str],
    output: Path,
    *,
    count: int = 32,
    workers: int = 1,
    baseline: bool = False,
    seeds: list[int] | None = None,
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
    working_directory = output / "images"
    write_startup_images(working_directory, build_record.read_text())
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
    base = environment.get("FROST_RANDOM_START_SEED", "").strip() or DEFAULT_BASE
    seeds = startup_seeds(base, count) if seeds is None else seeds
    if not seeds or any(seed < 1 or seed >= 2**31 for seed in seeds):
        raise ValueError("Verilator seeds must be between 1 and 2**31 - 1")
    print(f"Startup base={base!r}, seeds={len(seeds)}, binary={binary}", flush=True)

    def run_one(index: int, seed: int) -> dict[str, Any]:
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
        print(f"Startup index={index} Verilator seed={seed}", flush=True)
        replay_environment = {
            key: value
            for key, value in env.items()
            if key.startswith(("COCOTB_", "FROST_", "DDR_MODEL_"))
            or key in ("PYTHONPATH", "PYGPI_PYTHON_BIN", "GPI_USERS", "TOPLEVEL_LANG")
        }
        command = (
            "cd "
            + shlex.quote(str(working_directory))
            + " && "
            + shlex.join(
                [
                    "env",
                    "-u",
                    "COCOTB_TESTCASE",
                    "-u",
                    "COCOTB_TEST_FILTER",
                    *(
                        f"{key}={value}"
                        for key, value in sorted(replay_environment.items())
                    ),
                    *arguments,
                ]
            )
        )
        started = time.monotonic()
        try:
            result = subprocess.run(
                arguments,
                cwd=working_directory,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=120,
            )
            returncode, transcript = result.returncode, result.stdout
        except subprocess.TimeoutExpired as exc:
            captured = exc.stdout or b""
            transcript = (
                captured.decode(errors="replace")
                if isinstance(captured, bytes)
                else captured
            ) + "\nAssertionError: startup simulation exceeded 120 seconds\n"
            returncode = 124
        (output / f"seed_{seed}.log").write_text(transcript)
        try:
            cases = ElementTree.parse(report).findall(".//testcase")
        except (OSError, ElementTree.ParseError):
            cases = []
        passed = (
            returncode == 0
            and "STARTUP_SMOKE_PASS" in transcript
            and bool(cases)
            and not any(
                case.find("failure") is not None or case.find("error") is not None
                for case in cases
            )
            and (baseline or "Simulation assertions armed after reset" in transcript)
        )
        return {
            "index": index,
            "seed": seed,
            "command": command,
            "passed": passed,
            "returncode": returncode,
            "seconds": round(time.monotonic() - started, 3),
            "errors": [
                line
                for line in transcript.splitlines()
                if "%Error" in line or "AssertionError" in line
            ],
        }

    started = time.monotonic()
    results: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=workers) as pool:
        pending = {
            pool.submit(run_one, index, seed): seed for index, seed in enumerate(seeds)
        }
        for future in as_completed(pending):
            result = future.result()
            results.append(result)
            if not result["passed"]:
                print(
                    f"Startup seed {result['seed']} FAILED: {result['errors']}",
                    flush=True,
                )
                print(f"Rerun this seed in the image: {result['command']}", flush=True)
    elapsed = time.monotonic() - started
    with binary.open("rb") as executable:
        digest = hashlib.file_digest(executable, "sha256").hexdigest()
    summary = {
        "base": base,
        "binary": str(binary),
        "sha256": digest,
        "baseline": baseline,
        "workers": workers,
        "seconds": round(elapsed, 3),
        "results": sorted(results, key=lambda row: row["index"]),
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
    parser.add_argument("--test", help="registry entry used for the build")
    parser.add_argument(
        "--plan", nargs="+", help="registry entries sharing the job budget"
    )
    parser.add_argument("--binary", type=Path, default=Path("tests/sim_build/Vtop"))
    parser.add_argument("--output", type=Path, default=Path("tests/startup_sweep"))
    parser.add_argument(
        "--count",
        type=int,
        default=None,
        help="number of derived seeds (201 for a full sweep)",
    )
    parser.add_argument("--workers", type=int, choices=(1, 2), default=1)
    parser.add_argument(
        "--seed", type=int, action="append", help="explicit Verilator seed; repeatable"
    )
    parser.add_argument(
        "--baseline",
        action="store_true",
        help="observe a model with checks active at time zero",
    )
    args = parser.parse_args()
    if args.plan:
        plan_startup_sweeps(args.plan)
        return 0
    if not args.test:
        parser.error("--test is required when running a sweep")
    from test_run_cocotb import CocotbRunner

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
                count=args.count
                if args.count is not None
                else startup_count(startup_seed_cost(runner.setup_environment())),
                seeds=args.seed,
                workers=args.workers,
                baseline=args.baseline,
            )
            else 1
        )
    finally:
        runner.restore_environment()


if __name__ == "__main__":
    raise SystemExit(main())
