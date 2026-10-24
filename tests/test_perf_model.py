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

"""Self-checks of the performance model in perf-modeling/.

The model's self-test, its trace-contract unit tests, replays of the sample
traces, and a check that the model still writes the results stored beside it.
"""

import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PERF_MODELING = REPO_ROOT / "perf-modeling"
RESULTS = PERF_MODELING / "results"
SAMPLE_TRACES = sorted((PERF_MODELING / "traces").glob("*.jsonl"))
# Fields that measure the host, not the model.
WALL_CLOCK_FIELDS = {
    "wall_time_seconds",
    "simulated_cycles_per_second",
    "micro_ops_per_second",
}


def _load(relative: str, name: str) -> Any:
    """Load a perf-modeling module by path, with perf-modeling on sys.path."""
    module_path = PERF_MODELING / relative
    spec = importlib.util.spec_from_file_location(name, module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    original_path = sys.path.copy()
    sys.path.insert(0, str(PERF_MODELING))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path[:] = original_path
    return module


model: Any = _load("frost_perf_model.py", "frost_perf_model_test")
trace_contract: Any = _load(
    "calibration/trace_contract.py", "frost_trace_contract_test"
)
# The model's own unit tests, collected here by pytest.
TraceContractTest = _load(
    "tests/test_trace_contract.py", "frost_trace_contract_unit_test"
).TraceContractTest


def _without_wall_clock(value: Any) -> Any:
    """Return value with the wall-clock fields removed at every level."""
    if isinstance(value, dict):
        return {
            key: _without_wall_clock(item)
            for key, item in value.items()
            if key not in WALL_CLOCK_FIELDS
        }
    if isinstance(value, list):
        return [_without_wall_clock(item) for item in value]
    return value


def _stored(relative: str) -> Any:
    return json.loads((RESULTS / relative).read_text(encoding="utf-8"))


def _serialized(value: Any) -> Any:
    """Round-trip value through the model's own JSON encoding."""
    return json.loads(json.dumps(value, default=model.json_default))


def test_selftest_passes() -> None:
    """Every architectural check of the model's self-test passes."""
    result = model.selftest()
    failed = [check["name"] for check in result["checks"] if not check["passed"]]
    assert result["passed"] and not failed, f"failed self-checks: {failed}"


def test_selftest_command_exits_cleanly(tmp_path: Path) -> None:
    """The command-line self-test writes its record and exits with 0."""
    out = tmp_path / "selftest.json"
    subprocess.run(
        [sys.executable, str(PERF_MODELING / "frost_perf_model.py"), "selftest"]
        + ["--out", str(out)],
        check=True,
        timeout=120,
    )
    assert json.loads(out.read_text(encoding="utf-8"))["passed"]


@pytest.mark.parametrize("trace", SAMPLE_TRACES, ids=lambda path: path.stem)
def test_sample_traces_meet_the_contract_and_replay(trace: Path) -> None:
    """Each sample trace passes the contract, and the model replays all of it."""
    summary = trace_contract.summarize(trace_contract.read_trace(trace))
    assert summary["event_counts"]["meta"] == 1
    operations = model.load_trace_ops(trace)
    result = model.FrostPipeline(model.ModelConfig(), operations).run()
    assert result["retired"] == len(operations) > 0


def test_the_model_reproduces_its_stored_results() -> None:
    """The results directory holds the self-test, the audit, and the CoreMark run.

    A change to the model that moves its results must rewrite them with the
    commands in perf-modeling/README.md.
    """
    assert _serialized(model.selftest()) == _stored("frost_perf_selftest.json")
    assert _serialized(model.rtl_audit()) == _stored("frost_perf_rtl_alignment.json")
    run = model.run_workload(model.ModelConfig(), "coremark", 11)
    assert _without_wall_clock(_serialized(run)) == _without_wall_clock(
        _stored("coremark/model_coremark_output.json")
    )


def test_the_model_reproduces_its_stored_exploration_and_sweep() -> None:
    """The CoreMark exploration, the sweep, and their reports match the model."""
    exploration = model.explore_design_variants("coremark", seed=11)
    assert _serialized(exploration) == _stored("coremark_exploration.json")
    assert model.generate_optimization_report(exploration) == (
        RESULTS / "coremark_optimization_report.md"
    ).read_text(encoding="utf-8")
    sweep = _serialized(model.sweep_configurations())
    assert _without_wall_clock(sweep) == _without_wall_clock(
        _stored("frost_perf_sweep.json")
    )
    assert model.report_markdown(sweep) == (
        RESULTS / "FROST_perf_model_report.md"
    ).read_text(encoding="utf-8")


def test_run_calibration_records_a_sample_trace(tmp_path: Path) -> None:
    """The calibration comparator validates a sample trace against a model run."""
    trace = PERF_MODELING / "traces" / "coremark_head5k.jsonl"
    commit = trace_contract.read_trace(trace)[0]["rtl_commit"]
    model_run = tmp_path / "model.json"
    model_run.write_text(
        json.dumps(
            model.run_workload(model.ModelConfig(), "coremark", 11),
            default=model.json_default,
        ),
        encoding="utf-8",
    )
    out = tmp_path / "calibration.json"
    subprocess.run(
        [sys.executable, str(PERF_MODELING / "tools" / "run_calibration.py")]
        + ["--trace", str(trace), "--out", str(out), "--rtl-commit", commit]
        + ["--model-run", str(model_run)],
        check=True,
        timeout=120,
    )
    record = json.loads(out.read_text(encoding="utf-8"))
    assert record["status"] == "comparison-recorded"
    assert record["observed"]["event_counts"]["dispatch"] > 0
