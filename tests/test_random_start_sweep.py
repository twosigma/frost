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

"""Regression coverage for startup seed selection and failure reporting."""

import json
from pathlib import Path
import subprocess
from typing import Any

import pytest

import random_start_sweep as sweep


def test_seed_sets_rotate_and_keep_reproducible_prefixes() -> None:
    """Changing the job rotates seeds without changing a replayed prefix."""
    first = sweep.startup_seeds("run-job-a", 16)
    assert first == sweep.startup_seeds("run-job-a", 201)[:16]
    assert set(first).isdisjoint(sweep.startup_seeds("run-job-b", 16))
    assert all(0 < seed < 2**31 for seed in first)
    assert sweep.startup_seeds(sweep.DEFAULT_BASE, 16) == sweep.startup_seeds(
        sweep.DEFAULT_BASE, 16
    )


@pytest.mark.parametrize(
    ("returncode", "xml", "transcript", "expected"),
    [
        (
            0,
            "<testsuite><testcase/></testsuite>",
            "STARTUP_SMOKE_PASS\nSimulation assertions armed after reset",
            True,
        ),
        (0, "<testsuite><testcase/></testsuite>", "STARTUP_SMOKE_PASS", False),
        (
            0,
            "<testsuite><testcase><failure/></testcase></testsuite>",
            "STARTUP_SMOKE_PASS\nSimulation assertions armed after reset",
            False,
        ),
        (0, None, "STARTUP_SMOKE_PASS\nSimulation assertions armed after reset", False),
        (-6, None, "%Error: protocol violation", False),
    ],
)
def test_startup_requires_fresh_report_and_arming(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: Any,
    returncode: int,
    xml: str | None,
    transcript: str,
    expected: bool,
) -> None:
    """Require both simulator success and a fresh armed smoke-test result."""
    binary = tmp_path / "Vtop"
    binary.write_bytes(b"model")
    (tmp_path / "Vtop__verFiles.dat").write_text("+define+FROST_RANDOM_START")
    output = tmp_path / "output"
    output.mkdir()
    report = output / "seed_7.xml"
    report.write_text("<testsuite><testcase/></testsuite>")
    monkeypatch.setattr(
        sweep.subprocess, "check_output", lambda *a, **kw: "/lib/libpython.so"
    )

    def simulate(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        assert not report.exists(), "a stale passing report must be removed"
        assert "+verilator+seed+7" in command
        assert "+verilator+noassert" in command
        assert kwargs["env"]["FROST_RANDOM_START_VERILATOR_SEED"] == "7"
        assert "COCOTB_TEST_FILTER" not in kwargs["env"]
        assert "FROST_STARTUP_ASSERTION_CONTROL" not in kwargs["env"]
        assert "FROST_STARTUP_WITHHOLD_ASSERTIONS" not in kwargs["env"]
        if xml is not None:
            Path(kwargs["env"]["COCOTB_RESULTS_FILE"]).write_text(xml)
        return subprocess.CompletedProcess(command, returncode, transcript)

    monkeypatch.setattr(sweep.subprocess, "run", simulate)
    assert (
        sweep.run_startup_sweep(
            binary,
            {
                "COCOTB_TEST_FILTER": "ordinary",
                "FROST_STARTUP_ASSERTION_CONTROL": "bridge",
                "FROST_STARTUP_WITHHOLD_ASSERTIONS": "1",
            },
            output,
            seeds=[7],
            controls=False,
        )
        is expected
    )
    result = json.loads((output / "results.json").read_text())
    assert result["base"] == sweep.DEFAULT_BASE
    assert result["results"][0]["passed"] is expected
    if not expected:
        assert "Rerun this seed in the image:" in capsys.readouterr().out
        assert "+verilator+seed+7" in result["results"][0]["command"]


def test_failed_checks_are_not_cached_and_binary_changes_invalidate_success(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Retry failures and changed models while reusing an identical success."""
    monkeypatch.setattr(sweep, "__file__", str(tmp_path / "random_start_sweep.py"))
    Path(sweep.__file__).write_text("runner")
    monkeypatch.setenv("FROST_STARTUP_SEEDS", "2")
    binary = tmp_path / "Vtop"
    binary.write_bytes(b"first model")
    (tmp_path / "Vtop__verFiles.dat").write_text("+define+FROST_RANDOM_START")
    fixture = tmp_path.parent / "verif/cocotb_tests"
    fixture.mkdir(parents=True, exist_ok=True)
    for name in (
        "test_random_start_smoke.py",
        "test_real_program.py",
        "sim_assertions.py",
    ):
        (fixture / name).write_text("fixture")
    outcomes = iter([False, True, True, True, True])
    calls = []

    def run(
        binary: Path, environment: dict[str, str], output: Path, **kwargs: Any
    ) -> bool:
        calls.append((binary.read_bytes(), environment.copy(), kwargs))
        output.mkdir(parents=True, exist_ok=True)
        return next(outcomes)

    monkeypatch.setattr(sweep, "run_startup_sweep", run)
    with pytest.raises(RuntimeError, match="startup check failed"):
        sweep.check_built_model(binary, {"FROST_RANDOM_START_SEED": "job-a"})
    sweep.check_built_model(binary, {"FROST_RANDOM_START_SEED": "job-a"})
    sweep.check_built_model(binary, {"FROST_RANDOM_START_SEED": "job-a"})
    assert len(calls) == 2
    binary.write_bytes(b"second model")
    sweep.check_built_model(binary, {"FROST_RANDOM_START_SEED": "job-a"})
    sweep.check_built_model(binary, {"FROST_RANDOM_START_SEED": "job-b"})
    timing = {
        "FROST_RANDOM_START_SEED": "job-b",
        "FROST_DDR_TIMING_ARGS": "-GDDR_MODEL_REORDER=1",
    }
    sweep.check_built_model(binary, timing)
    sweep.check_built_model(binary, timing)
    assert len(calls) == 5


def test_full_sweep_has_a_bounded_allocation(monkeypatch: pytest.MonkeyPatch) -> None:
    """Full sweeps include every control and reject requests beyond the limit."""
    monkeypatch.delenv("FROST_STARTUP_SEEDS", raising=False)
    assert sweep.startup_count(12) == 12
    assert sweep.startup_count(2.5, 0) == 72
    assert sweep.startup_count(2.5) == 69
    assert sweep.startup_count(5, 7.5) == 34
    assert sweep.startup_count(61, 0) == 2
    with pytest.raises(ValueError, match="startup budget"):
        sweep.startup_count(61)
    monkeypatch.setenv("FROST_STARTUP_SEEDS", "201")
    assert sweep.startup_count(6.5) == 201
    with pytest.raises(ValueError, match="startup budget"):
        sweep.startup_count(12)
    monkeypatch.setenv("FROST_STARTUP_SEEDS", "0")
    with pytest.raises(ValueError):
        sweep.startup_count(12)


@pytest.mark.parametrize(("timeout", "count"), [("", 3), ("2400", 69)])
def test_pinned_program_seed_uses_the_ci_job_base_and_budget(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    timeout: str,
    count: int,
) -> None:
    """Use the job's seed base and discard a plan with a different limit."""
    monkeypatch.setattr(sweep, "__file__", str(tmp_path / "random_start_sweep.py"))
    Path(sweep.__file__).write_text("runner")
    monkeypatch.delenv("FROST_STARTUP_SEEDS", raising=False)
    monkeypatch.setenv("FROST_STARTUP_TIMEOUT_SEC", timeout)
    binary = tmp_path / "Vtop"
    binary.write_bytes(b"model")
    (tmp_path / "Vtop__verFiles.dat").write_text("+define+FROST_RANDOM_START")
    fixture = tmp_path.parent / "verif/cocotb_tests"
    fixture.mkdir(parents=True, exist_ok=True)
    for name in (
        "test_random_start_smoke.py",
        "test_real_program.py",
        "sim_assertions.py",
    ):
        (fixture / name).write_text("fixture")
    output = tmp_path / "startup_sweep"
    output.mkdir()
    (output / "plan.json").write_text(
        json.dumps(
            {"base": "run-job", "count": 3, "limit_seconds": 300, "used_seconds": 0}
        )
    )
    calls = []

    def run(
        binary: Path, environment: dict[str, str], output: Path, **kwargs: Any
    ) -> bool:
        calls.append(
            (sweep.startup_base(environment), kwargs["count"], kwargs["budget_seconds"])
        )
        output.mkdir(parents=True, exist_ok=True)
        return True

    monkeypatch.setattr(sweep, "run_startup_sweep", run)
    sweep.check_built_model(
        binary,
        {
            "FROST_RANDOM_START_SEED": "pinned-program",
            "FROST_STARTUP_SEED_BASE": "run-job",
        },
    )
    assert calls == [("run-job", count, int(timeout or "300"))]


def test_job_budget_deduplicates_programs_sharing_clock_mode(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Common and asynchronous binaries share one budget across four programs."""
    monkeypatch.setattr(sweep, "__file__", str(tmp_path / "random_start_sweep.py"))
    for name in (
        "FROST_STARTUP_SEEDS",
        "FROST_STARTUP_SEED_BASE",
        "FROST_CPU_PERIOD_PS",
        "FROST_DDR_MODEL_SEED",
        "FROST_VERILATOR_EXTRA_ARGS",
    ):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("FROST_RANDOM_START_SEED", "budget-test")
    monkeypatch.setenv("FROST_COVERAGE", "0")
    sweep.plan_startup_sweeps(
        ["nic_loopback", "dma_torture", "async_nic_loopback", "async_dma_torture"]
    )
    plan = json.loads((tmp_path / "startup_sweep/plan.json").read_text())
    assert plan["builds"] == 2
    assert plan["count"] == sweep.startup_count(2 * sweep.startup_seed_cost({}))
    assert "FROST_CPU_PERIOD_PS" not in sweep.os.environ


def test_startup_images_respect_code_region_capacity(tmp_path: Path) -> None:
    """The split code banks fit 128 KiB within a 256 KiB low-memory image."""
    sweep.write_startup_images(tmp_path, "-GMEM_SIZE_BYTES=262144")
    assert len((tmp_path / "sw.mem").read_text().splitlines()) == 65536
    assert len((tmp_path / "sw64.mem").read_text().splitlines()) == 32768
    for parity in ("even", "odd"):
        assert (
            len((tmp_path / f"sw_imem_{parity}_sideband.mem").read_text().splitlines())
            == 16384
        )


@pytest.mark.parametrize(
    "outcome", ("fires", "disabled", "wrong_check", "pre_reset", "timeout")
)
def test_assertion_controls_require_original_post_reset_failures(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    outcome: str,
) -> None:
    """An arming marker alone cannot substitute for working system assertions."""
    binary = tmp_path / "Vtop"
    binary.write_bytes(b"model")
    (tmp_path / "Vtop__verFiles.dat").write_text("+define+FROST_RANDOM_START")
    monkeypatch.setattr(
        sweep.subprocess, "check_output", lambda *a, **kw: "/lib/libpython.so"
    )
    calls = []

    def simulate(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        env = kwargs["env"]
        control = env.get("FROST_STARTUP_ASSERTION_CONTROL")
        calls.append(control)
        armed = "Simulation assertions armed after reset\n"
        if control is None:
            assert not any(
                arg.startswith("+frost_startup_assertion_control=") for arg in command
            )
            Path(env["COCOTB_RESULTS_FILE"]).write_text(
                "<testsuite><testcase/></testsuite>"
            )
            return subprocess.CompletedProcess(command, 0, armed + "STARTUP_SMOKE_PASS")
        assert f"+frost_startup_assertion_control={control}" in command
        injected = f"STARTUP_ASSERTION_CONTROL {control}\n"
        if env.get("FROST_STARTUP_WITHHOLD_ASSERTIONS") == "1":
            assert control == "bridge"
            assert "+frost_startup_withhold_assertions=1" in command
            Path(env["COCOTB_RESULTS_FILE"]).write_text(
                "<testsuite><testcase/></testsuite>"
            )
            return subprocess.CompletedProcess(
                command,
                0,
                "Simulation assertions deliberately withheld after reset\n"
                + injected
                + "STARTUP_WITHHELD_ASSERTIONS_PASS\nSTARTUP_SMOKE_PASS",
            )
        diagnostic = "%Error: " + sweep.ASSERTION_CONTROLS[control]
        if outcome == "disabled":
            return subprocess.CompletedProcess(
                command, 0, armed + injected + "STARTUP_SMOKE_PASS"
            )
        if outcome == "pre_reset":
            return subprocess.CompletedProcess(
                command, -6, diagnostic + "\n" + armed + injected
            )
        if outcome == "wrong_check":
            diagnostic = "%Error: unrelated failure"
        if outcome == "timeout":
            raise subprocess.TimeoutExpired(command, 120, output=armed + injected)
        return subprocess.CompletedProcess(command, -6, armed + injected + diagnostic)

    monkeypatch.setattr(sweep.subprocess, "run", simulate)
    output = tmp_path / "output"
    assert sweep.run_startup_sweep(binary, {}, output, seeds=[7]) is (
        outcome == "fires"
    )
    assert calls == [None, "bridge", "nic_reset", "bridge"]
    results = json.loads((output / "results.json").read_text())
    assert all(row["passed"] is (outcome == "fires") for row in results["controls"])
    assert all(row["passed"] for row in results["withheld_controls"])


@pytest.mark.parametrize(
    "missing",
    (None, "bridge", "nic_reset", "bridge_withheld", "marker", "fixture", "base"),
)
def test_job_requires_all_assertion_controls(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    missing: str | None,
) -> None:
    """No controls, stale results, or one absent direction fail the CI summary."""
    monkeypatch.setattr(sweep, "startup_fixture_digest", lambda: "current")
    assert not sweep.require_assertion_controls(tmp_path, "job")
    output = tmp_path / "model"
    output.mkdir()
    result = {
        "base": "old" if missing == "base" else "job",
        "fixture": "old" if missing == "fixture" else "current",
        "controls": [
            {"control": name, "passed": True}
            for name in sweep.ASSERTION_CONTROLS
            if name != missing
        ],
        "withheld_controls": [] if missing == "bridge_withheld" else [{"passed": True}],
    }
    (output / "results.json").write_text(json.dumps(result))
    if missing != "marker":
        (output / "passed").touch()
    assert sweep.require_assertion_controls(tmp_path, "job") is (missing is None)
    assert (
        "Startup assertion controls REQUIRED:"
        in (tmp_path / "control_summary.txt").read_text()
    )


def test_designated_ci_job_requires_control_summary() -> None:
    """The full PR and merge workflow cannot pass without an attested control pair."""
    import yaml  # type: ignore[import-untyped]

    workflow = yaml.safe_load(
        (Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml").read_text()
    )
    job = workflow["jobs"]["test-testrig"]
    step = next(
        step
        for step in job["steps"]
        if step["name"] == "Require startup assertion controls"
    )
    assert "always()" in step["if"] and "matrix.shard == 3" in step["if"]
    assert "--require-controls" in step["run"] and 'exit "$status"' in step["run"]
    assert "GITHUB_STEP_SUMMARY" in step["run"]


@pytest.mark.parametrize(
    "tests, controls, count",
    [
        (["ddr_reset_distribution"], 0, 72),
        (["nic_loopback"], 1, 69),
        (["ddr_reset_distribution", "nic_loopback"], 1, 34),
    ],
)
@pytest.mark.parametrize("timeout", ["", "2400"])
def test_plan_reserves_only_executed_controls(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    tests: list[str],
    controls: int,
    count: int,
    timeout: str,
) -> None:
    """BRAM-tier builds spend their share on seeds instead of absent probes."""
    monkeypatch.setattr(sweep, "__file__", str(tmp_path / "random_start_sweep.py"))
    for name in (
        "FROST_STARTUP_SEEDS",
        "FROST_VERILATOR_EXTRA_ARGS",
        "FROST_CPU_PERIOD_PS",
        "FROST_DDR_MODEL_SEED",
    ):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("FROST_COVERAGE", "0")
    monkeypatch.setenv("FROST_STARTUP_TIMEOUT_SEC", timeout)
    sweep.plan_startup_sweeps(tests)
    plan = json.loads((tmp_path / "startup_sweep/plan.json").read_text())
    assert plan["control_builds"] == controls and plan["count"] == count
    assert plan["estimated_seconds"] <= 180
    assert plan["limit_seconds"] == int(timeout or "300")


def test_exhausted_job_budget_starts_no_simulator(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A job limit cannot silently become another per-process allowance."""
    monkeypatch.setattr(
        sweep.subprocess, "run", lambda *a, **kw: pytest.fail("started past job limit")
    )
    with pytest.raises(ValueError, match="job time budget exhausted"):
        sweep.run_startup_sweep(
            tmp_path / "Vtop", {}, tmp_path / "out", budget_seconds=0
        )


def test_job_budget_is_shared_across_models(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A later binary receives the remaining allowance, not a fresh job budget."""
    monkeypatch.delenv("FROST_STARTUP_SEEDS", raising=False)
    monkeypatch.setattr(sweep, "__file__", str(tmp_path / "runner.py"))
    monkeypatch.setattr(sweep, "startup_fixture_digest", lambda: "fixture")
    binary = tmp_path / "Vtop"
    binary.write_bytes(b"one")
    (tmp_path / "Vtop__verFiles.dat").write_text("FROST_RANDOM_START")
    clock = [0.0]
    monkeypatch.setattr(sweep.time, "monotonic", lambda: clock[0])
    budgets = []

    def simulate(
        binary: Path, env: dict[str, str], output: Path, **kwargs: Any
    ) -> bool:
        budgets.append(kwargs["budget_seconds"])
        output.mkdir(parents=True, exist_ok=True)
        clock[0] += 160
        return True

    monkeypatch.setattr(sweep, "run_startup_sweep", simulate)
    env = {"FROST_RANDOM_START_SEED": "shared-budget"}
    sweep.check_built_model(binary, env)
    binary.write_bytes(b"two")
    with pytest.raises(RuntimeError, match="startup check failed"):
        sweep.check_built_model(binary, env)
    assert budgets == [300, 140]
    assert len(list((tmp_path / "startup_sweep").glob("*/passed"))) == 1


def test_job_deadline_limits_controls_too(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Time spent on seeds reduces the control allowance and expiry fails the sweep."""
    binary = tmp_path / "Vtop"
    binary.write_bytes(b"model")
    (tmp_path / "Vtop__verFiles.dat").write_text("FROST_RANDOM_START")
    monkeypatch.setattr(
        sweep.subprocess, "check_output", lambda *a, **kw: "/lib/libpython.so"
    )
    clock = [0.0]
    calls = []
    monkeypatch.setattr(sweep.time, "monotonic", lambda: clock[0])

    def simulate(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        calls.append(command)
        assert kwargs["timeout"] == 2
        Path(kwargs["env"]["COCOTB_RESULTS_FILE"]).write_text(
            "<testsuite><testcase/></testsuite>"
        )
        clock[0] = 2
        return subprocess.CompletedProcess(
            command, 0, "Simulation assertions armed after reset\nSTARTUP_SMOKE_PASS"
        )

    monkeypatch.setattr(sweep.subprocess, "run", simulate)
    assert not sweep.run_startup_sweep(
        binary, {}, tmp_path / "out", seeds=[7], budget_seconds=2
    )
    assert len(calls) == 1
    result = json.loads((tmp_path / "out/results.json").read_text())
    assert all(
        row["returncode"] == 124
        for row in result["controls"] + result["withheld_controls"]
    )


@pytest.mark.parametrize(
    "transcript, code, expected",
    [
        (
            "Simulation assertions deliberately withheld after reset\nSTARTUP_ASSERTION_CONTROL bridge\nSTARTUP_WITHHELD_ASSERTIONS_PASS\nSTARTUP_SMOKE_PASS",
            0,
            True,
        ),
        (
            "Simulation assertions armed after reset\nSTARTUP_ASSERTION_CONTROL bridge\nSTARTUP_WITHHELD_ASSERTIONS_PASS\nSTARTUP_SMOKE_PASS",
            0,
            False,
        ),
        (
            "Simulation assertions deliberately withheld after reset\nSTARTUP_WITHHELD_ASSERTIONS_PASS\nSTARTUP_SMOKE_PASS",
            0,
            False,
        ),
        (
            "Simulation assertions deliberately withheld after reset\nSTARTUP_ASSERTION_CONTROL bridge\n%Error: assertion fired",
            -6,
            False,
        ),
    ],
)
def test_withheld_control_requires_a_real_completed_violation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    transcript: str,
    code: int,
    expected: bool,
) -> None:
    """The reverse case must finish with injection and disabled readback evidence."""
    binary = tmp_path / "Vtop"
    binary.write_bytes(b"model")
    (tmp_path / "Vtop__verFiles.dat").write_text("+define+FROST_RANDOM_START")
    monkeypatch.setattr(
        sweep.subprocess, "check_output", lambda *a, **kw: "/lib/libpython.so"
    )

    def simulate(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        env = kwargs["env"]
        Path(env["COCOTB_RESULTS_FILE"]).write_text(
            "<testsuite><testcase/></testsuite>"
        )
        if env.get("FROST_STARTUP_WITHHOLD_ASSERTIONS"):
            return subprocess.CompletedProcess(command, code, transcript)
        armed = "Simulation assertions armed after reset\n"
        control = env.get("FROST_STARTUP_ASSERTION_CONTROL")
        if control:
            return subprocess.CompletedProcess(
                command,
                -6,
                armed
                + f"STARTUP_ASSERTION_CONTROL {control}\n%Error: "
                + sweep.ASSERTION_CONTROLS[control],
            )
        return subprocess.CompletedProcess(command, 0, armed + "STARTUP_SMOKE_PASS")

    monkeypatch.setattr(sweep.subprocess, "run", simulate)
    assert sweep.run_startup_sweep(binary, {}, tmp_path / "out", seeds=[7]) is expected
