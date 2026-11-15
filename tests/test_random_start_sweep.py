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
        if xml is not None:
            Path(kwargs["env"]["COCOTB_RESULTS_FILE"]).write_text(xml)
        return subprocess.CompletedProcess(command, returncode, transcript)

    monkeypatch.setattr(sweep.subprocess, "run", simulate)
    assert (
        sweep.run_startup_sweep(
            binary, {"COCOTB_TEST_FILTER": "ordinary"}, output, seeds=[7]
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
    monkeypatch.setenv("FROST_STARTUP_SEEDS", "2")
    binary = tmp_path / "Vtop"
    binary.write_bytes(b"first model")
    fixture = tmp_path.parent / "verif/cocotb_tests"
    fixture.mkdir(parents=True, exist_ok=True)
    for name in (
        "test_random_start_smoke.py",
        "test_real_program.py",
        "sim_assertions.py",
    ):
        (fixture / name).write_text("fixture")
    outcomes = iter([False, True, True, True])
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
    assert len(calls) == 4


def test_full_sweep_overrides_job_budget(monkeypatch: pytest.MonkeyPatch) -> None:
    """A requested full sweep takes precedence over the CI allocation."""
    monkeypatch.delenv("FROST_STARTUP_SEEDS", raising=False)
    assert sweep.startup_count(12) == 15
    monkeypatch.setenv("FROST_STARTUP_SEEDS", "201")
    assert sweep.startup_count(12) == 201
    monkeypatch.setenv("FROST_STARTUP_SEEDS", "0")
    with pytest.raises(ValueError):
        sweep.startup_count(12)


def test_pinned_program_seed_uses_the_ci_job_base_and_budget(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A registry seed override must not replace the job's rotating sample."""
    monkeypatch.setattr(sweep, "__file__", str(tmp_path / "random_start_sweep.py"))
    monkeypatch.delenv("FROST_STARTUP_SEEDS", raising=False)
    binary = tmp_path / "Vtop"
    binary.write_bytes(b"model")
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
    (output / "plan.json").write_text(json.dumps({"base": "run-job", "count": 3}))
    calls = []

    def run(
        binary: Path, environment: dict[str, str], output: Path, **kwargs: Any
    ) -> bool:
        calls.append((sweep.startup_base(environment), kwargs["count"]))
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
    assert calls == [("run-job", 3)]


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
