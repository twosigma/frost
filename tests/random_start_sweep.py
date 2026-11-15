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
STARTUP_TIMEOUT_SECONDS = 300
FULL_SWEEP_TIMEOUT_SECONDS = 1800
CONTROL_STARTS = 3
ASSERTION_CONTROLS = {
    "bridge": "line_port_axi_bridge: multi-beat read response (expected single beat)",
    "nic_reset": "nic_rst_q is not the registered reset OR the RESET pulse",
}


def startup_base(environment: dict[str, str]) -> str:
    """Keep the CI job's base independent of a registry test's pinned seed."""
    return (
        environment.get("FROST_STARTUP_SEED_BASE", "").strip()
        or environment.get("FROST_RANDOM_START_SEED", "").strip()
        or DEFAULT_BASE
    )


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
        return 2.6 if environment.get("FROST_COVERAGE") == "1" else 1.3
    if "-GL2_CACHE_BYTES=4194304" in arguments:
        return 4.25
    if environment.get("FROST_COVERAGE") == "1":
        return 4.25
    if "-GVECTOR=1" in arguments:
        return 2.75
    return 2.5


def has_assertion_controls(arguments: str) -> bool:
    """Only cached-tier models contain the two controlled NIC checks."""
    values = re.findall(r"-GENABLE_CACHED_TIER=(\d+)", arguments)
    return not values or int(values[-1]) != 0


def startup_limits() -> tuple[int, int]:
    """Return the estimated allocation and hard cumulative job limit."""
    if os.environ.get("FROST_STARTUP_SEEDS", "").strip():
        return FULL_SWEEP_TIMEOUT_SECONDS, FULL_SWEEP_TIMEOUT_SECONDS
    return STARTUP_BUDGET_SECONDS, STARTUP_TIMEOUT_SECONDS


def startup_count(cost: float, control_cost: float | None = None) -> int:
    """Allocate a fixed seed count within the job's estimated startup budget."""
    override = os.environ.get("FROST_STARTUP_SEEDS", "").strip()
    if control_cost is None:
        control_cost = CONTROL_STARTS * cost
    allocation, _ = startup_limits()
    count = (
        int(override) if override else min(200, int((allocation - control_cost) / cost))
    )
    if not 1 <= count <= 201 or count * cost + control_cost > allocation:
        raise ValueError(
            f"startup budget cannot fit {count} seeds plus controls: "
            f"{count * cost + control_cost:g}s exceeds {allocation}s, "
            "or seed count is outside 1..201"
        )
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
            cost = startup_seed_cost(environment)
            costs[key] = (
                cost,
                CONTROL_STARTS * cost if has_assertion_controls(key[0]) else 0,
            )
        finally:
            runner.restore_environment()
    if costs:
        seed_cost = sum(value[0] for value in costs.values())
        control_cost = sum(value[1] for value in costs.values())
        count = startup_count(seed_cost, control_cost)
        plan = {
            "base": startup_base(dict(os.environ)),
            "count": count,
            "builds": len(costs),
            "control_builds": sum(value[1] > 0 for value in costs.values()),
            "estimated_seconds": count * seed_cost + control_cost,
            "limit_seconds": startup_limits()[1],
            "used_seconds": 0,
            "requested_seeds": os.environ.get("FROST_STARTUP_SEEDS", "").strip(),
        }
        directory = Path(__file__).resolve().parent / "startup_sweep"
        directory.mkdir(exist_ok=True)
        (directory / "plan.json").write_text(json.dumps(plan) + "\n")
        print(f"Startup plan: {plan}", flush=True)


def startup_fixture_digest() -> str:
    """Identify the runner and all Python code that controls the reset sample."""
    fixture = hashlib.sha256()
    fixture.update(Path(__file__).read_bytes())
    for name in (
        "test_random_start_smoke.py",
        "test_real_program.py",
        "sim_assertions.py",
    ):
        path = Path(__file__).resolve().parents[1] / "verif/cocotb_tests" / name
        fixture.update(path.read_bytes())
    return fixture.hexdigest()


def check_built_model(binary: Path, environment: dict[str, str]) -> None:
    """Check each model once and charge its elapsed time to the shared job limit."""
    base = startup_base(environment)
    directory = Path(__file__).resolve().parent / "startup_sweep"
    cost = startup_seed_cost(environment)
    controls = has_assertion_controls(
        (binary.parent / "Vtop__verFiles.dat").read_text()
    )
    plan_path = directory / "plan.json"
    plan = json.loads(plan_path.read_text()) if plan_path.exists() else {}
    requested = environment.get("FROST_STARTUP_SEEDS", "").strip()
    if (
        plan.get("base") != base
        or "limit_seconds" not in plan
        or plan.get("requested_seeds", "") != requested
    ):
        plan = {
            "base": base,
            "count": startup_count(cost, CONTROL_STARTS * cost if controls else 0),
            "limit_seconds": startup_limits()[1],
            "used_seconds": 0,
            "requested_seeds": requested,
        }
    count = plan["count"]
    with binary.open("rb") as executable:
        digest = hashlib.file_digest(executable, "sha256").hexdigest()
    identity = hashlib.sha256(
        f"{digest}:{startup_fixture_digest()}:{base}:{count}".encode()
    ).hexdigest()
    output = directory / identity
    marker = output / "passed"
    if marker.exists():
        return
    started = time.monotonic()
    try:
        passed = run_startup_sweep(
            binary,
            environment,
            output,
            count=count,
            workers=1,
            budget_seconds=plan["limit_seconds"] - plan["used_seconds"],
        )
    finally:
        plan["used_seconds"] += time.monotonic() - started
        directory.mkdir(exist_ok=True)
        plan_path.write_text(json.dumps(plan) + "\n")
    if not passed or plan["used_seconds"] > plan["limit_seconds"]:
        raise RuntimeError(f"Random-start startup check failed; logs: {output}")
    marker.touch()


def require_assertion_controls(directory: Path, base: str) -> bool:
    """Fail the designated CI job unless both controls and the reverse case ran."""
    counts = {**dict.fromkeys(ASSERTION_CONTROLS, 0), "bridge_withheld": 0}
    fixture = startup_fixture_digest()
    for path in directory.glob("*/results.json"):
        result = json.loads(path.read_text())
        if (
            result.get("base") != base
            or result.get("fixture") != fixture
            or not (path.parent / "passed").exists()
        ):
            continue
        for row in result["controls"]:
            if row["passed"]:
                counts[row["control"]] += 1
        for row in result.get("withheld_controls", []):
            if row["passed"]:
                counts["bridge_withheld"] += 1
    passed = all(counts.values())
    summary = "Startup assertion controls REQUIRED: " + ("PASS" if passed else "FAIL")
    summary += (
        "\n"
        + "\n".join(f"{name}: {count} confirmed runs" for name, count in counts.items())
        + "\n"
    )
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "control_summary.txt").write_text(summary)
    print(summary, flush=True)
    return passed


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
    controls: bool = True,
    budget_seconds: float | None = None,
) -> bool:
    """Check seeded startups and require two deliberate post-reset failures."""
    started = time.monotonic()
    budget_seconds = startup_limits()[1] if budget_seconds is None else budget_seconds
    if budget_seconds <= 0:
        raise ValueError("startup job time budget exhausted")
    deadline = started + budget_seconds
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
    environment.pop("FROST_STARTUP_ASSERTION_CONTROL", None)
    environment.pop("FROST_STARTUP_WITHHOLD_ASSERTIONS", None)
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
        controls = False
    else:
        environment.pop("FROST_STARTUP_BASELINE", None)
    base = startup_base(environment)
    seeds = startup_seeds(base, count) if seeds is None else seeds
    if not seeds or any(seed < 1 or seed >= 2**31 for seed in seeds):
        raise ValueError("Verilator seeds must be between 1 and 2**31 - 1")
    print(f"Startup base={base!r}, seeds={len(seeds)}, binary={binary}", flush=True)
    if not has_assertion_controls(build_record.read_text()):
        controls = False
    estimate = (len(seeds) + (CONTROL_STARTS if controls else 0)) * startup_seed_cost(
        environment
    )
    if len(seeds) > 201 or estimate > startup_limits()[0]:
        raise ValueError(
            f"startup seeds and controls need {estimate:g}s, outside the allocation"
        )

    def run_one(
        index: int, seed: int, control: str | None = None, withheld: bool = False
    ) -> dict[str, Any]:
        env = environment.copy()
        label = f"control_{control}" if control else f"seed_{seed}"
        if withheld:
            label += "_withheld"
        report = output / f"{label}.xml"
        report.unlink(missing_ok=True)
        env["COCOTB_RESULTS_FILE"] = str(report)
        env["FROST_RANDOM_START_SEED"] = base
        env["FROST_RANDOM_START_VERILATOR_SEED"] = str(seed)
        arguments = [
            str(binary),
            "+verilator+rand+reset+2",
            f"+verilator+seed+{seed}",
            "+verilator+coverage+file+/dev/null",
        ]
        if not baseline:
            arguments.append("+verilator+noassert")
        if control:
            env["FROST_STARTUP_ASSERTION_CONTROL"] = control
            arguments.append(f"+frost_startup_assertion_control={control}")
        if withheld:
            env["FROST_STARTUP_WITHHOLD_ASSERTIONS"] = "1"
            arguments.append("+frost_startup_withhold_assertions=1")
        print(
            f"Startup {'control=' + control if control else 'index=' + str(index)} Verilator seed={seed} withheld={withheld}",
            flush=True,
        )
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
            remaining = deadline - started
            if remaining <= 0:
                raise subprocess.TimeoutExpired(
                    arguments,
                    budget_seconds,
                    output="startup job time budget exhausted",
                )
            result = subprocess.run(
                arguments,
                cwd=working_directory,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=min(120, remaining),
            )
            returncode, transcript = result.returncode, result.stdout
        except subprocess.TimeoutExpired as exc:
            captured = exc.stdout or b""
            transcript = (
                (
                    captured.decode(errors="replace")
                    if isinstance(captured, bytes)
                    else captured
                )
                + "\nAssertionError: startup simulation exceeded its process or job time limit\n"
            )
            returncode = 124
        (output / f"{label}.log").write_text(transcript)
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
        if control and not withheld:
            armed_at = transcript.find("Simulation assertions armed after reset")
            injected_at = transcript.find(f"STARTUP_ASSERTION_CONTROL {control}")
            diagnostic_at = transcript.find(ASSERTION_CONTROLS[control], injected_at)
            passed = (
                returncode not in (0, 124)
                and 0 <= armed_at < injected_at < diagnostic_at
                and "%Error" in transcript[injected_at:]
                and "STARTUP_SMOKE_PASS" not in transcript
            )
        if withheld:
            held_at = transcript.find(
                "Simulation assertions deliberately withheld after reset"
            )
            injected_at = transcript.find("STARTUP_ASSERTION_CONTROL bridge")
            completed_at = transcript.find("STARTUP_WITHHELD_ASSERTIONS_PASS")
            passed = (
                returncode == 0
                and bool(cases)
                and not any(
                    case.find("failure") is not None or case.find("error") is not None
                    for case in cases
                )
                and 0 <= held_at < injected_at < completed_at
                and "STARTUP_SMOKE_PASS" in transcript
                and "Simulation assertions armed after reset" not in transcript
                and "%Error" not in transcript
            )
        return {
            "index": index,
            "seed": seed,
            "control": control,
            "withheld": withheld,
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
    control_results = []
    withheld_results = []
    if controls:
        for control in ASSERTION_CONTROLS:
            result = run_one(len(results), seeds[0], control)
            control_results.append(result)
            if result["passed"]:
                print(
                    f"Startup control {control}: expected failure confirmed", flush=True
                )
            else:
                print(
                    f"Startup control {control} FAILED: expected the original post-reset diagnostic; got {result['errors']}",
                    flush=True,
                )
                print(
                    f"Rerun this control in the image: {result['command']}", flush=True
                )
        result = run_one(len(results), seeds[0], "bridge", withheld=True)
        withheld_results.append(result)
        print(
            "Startup withheld-arming control: "
            + ("PASS" if result["passed"] else "FAIL"),
            flush=True,
        )
        if not result["passed"]:
            print(f"Rerun this control in the image: {result['command']}", flush=True)
    elapsed = time.monotonic() - started
    with binary.open("rb") as executable:
        digest = hashlib.file_digest(executable, "sha256").hexdigest()
    summary = {
        "base": base,
        "binary": str(binary),
        "sha256": digest,
        "fixture": startup_fixture_digest(),
        "baseline": baseline,
        "workers": workers,
        "seconds": round(elapsed, 3),
        "results": sorted(results, key=lambda row: row["index"]),
        "controls": control_results,
        "withheld_controls": withheld_results,
        "budget_seconds": budget_seconds,
    }
    (output / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
    passed = sum(result["passed"] for result in results)
    control_summary = (
        f"controls {sum(row['passed'] for row in control_results)}/{len(control_results)}, "
        f"withheld {sum(row['passed'] for row in withheld_results)}/{len(withheld_results)}"
        if controls
        else "controls not applicable (baseline or BRAM-tier model; no starts reserved)"
    )
    print(
        f"Startup sweep: {passed}/{len(results)} passed; "
        f"{control_summary} "
        f"in {elapsed:.1f}s",
        flush=True,
    )
    return (
        passed == len(results)
        and all(row["passed"] for row in control_results + withheld_results)
        and elapsed <= budget_seconds
    )


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
        "--require-controls",
        action="store_true",
        help="fail unless the job ran both controls and the withheld-arming case",
    )
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
    if args.require_controls:
        return (
            0
            if require_assertion_controls(args.output, startup_base(dict(os.environ)))
            else 1
        )
    if args.count is not None:
        os.environ["FROST_STARTUP_SEEDS"] = str(args.count)
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
        environment = runner.setup_environment()
        controls = not args.baseline and has_assertion_controls(
            (args.binary.parent / "Vtop__verFiles.dat").read_text()
        )
        cost = startup_seed_cost(environment)
        return (
            0
            if run_startup_sweep(
                args.binary,
                environment,
                args.output,
                count=args.count
                if args.count is not None
                else startup_count(cost, CONTROL_STARTS * cost if controls else 0),
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
