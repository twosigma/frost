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
import re
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


def _write_trace(path: Path, cycles: int, retired: int, events: set[str]) -> None:
    """Write a trace of cycles cycles that retires one micro-op in each of the first retired.

    Its records are the events named in events: dispatch, one each cycle,
    and axi, one request and its response.
    """
    rows: list[dict[str, Any]] = [
        {
            "cycle": 0,
            "event": "meta",
            "source": "test",
            "rtl_commit": "abc",
            "clock_domain": "cpu",
            "memory_configuration": "axi_behavioral_memory",
        }
    ]
    if "axi" in events:
        rows.append(
            {
                "cycle": 0,
                "event": "axi_request",
                "source": "axi",
                "axi_id": 34,
                "address": "0x00005880",
                "is_write": False,
                "bytes": 64,
            }
        )
        rows.append(
            {
                "cycle": 0,
                "event": "axi_response",
                "source": "axi",
                "axi_id": 34,
                "ok": True,
            }
        )
    for cycle in range(cycles):
        if "dispatch" in events:
            rows.append(
                {"cycle": cycle, "event": "dispatch", "source": "rob", "uops": 1}
            )
        if cycle < retired:
            rows.append({"cycle": cycle, "event": "retire", "source": "rob", "uops": 1})
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")


def _baseline(path: Path, ipc: float) -> None:
    """Write a stored baseline whose RTL and model both ran at ipc."""
    figures = {"cycles": 100, "retired_uops": round(100 * ipc), "ipc": ipc}
    baseline = {
        "benchmark": "coremark",
        "test": "coremark",
        "memory_tier": "bram",
        "model_workload": "coremark",
        "model_seed": 11,
        "required_events": ["dispatch", "retire", "axi_request", "axi_response"],
        "ipc_tolerance": 0.1,
        "rtl": {
            "commit": "old",
            **figures,
            "dispatched_uops": 100,
            "event_counts": {"dispatch": 100, "retire": 100},
        },
        "model": figures,
        "ipc_delta": 0.0,
    }
    path.write_text(json.dumps(baseline, indent=2) + "\n", encoding="utf-8")


ALL_EVENTS = frozenset({"dispatch", "axi"})


def _check(
    tmp_path: Path,
    *extra: str,
    cycles: int = 100,
    events: frozenset[str] = ALL_EVENTS,
) -> subprocess.CompletedProcess[str]:
    """Run run_calibration.py's check of a 100-uop trace against a model IPC of 1."""
    trace = tmp_path / "trace.jsonl"
    _write_trace(trace, cycles, 100, set(events))
    model_run = tmp_path / "model.json"
    model_run.write_text(json.dumps({"cycles": 100, "retired": 100}), encoding="utf-8")
    return subprocess.run(
        [sys.executable, str(PERF_MODELING / "tools" / "run_calibration.py")]
        + ["--trace", str(trace), "--rtl-commit", "abc", "--model-run", str(model_run)]
        + ["--baseline", str(tmp_path / "baseline.json")]
        + ["--out", str(tmp_path / "record.json"), *extra],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


def test_calibration_check_passes_within_the_tolerance(tmp_path: Path) -> None:
    """A trace whose IPC is within the tolerance of the model's passes."""
    _baseline(tmp_path / "baseline.json", 1.0)
    result = _check(tmp_path)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "model vs RTL IPC: +0.00%" in result.stdout
    assert result.stdout.rstrip().endswith("PASS")


@pytest.mark.parametrize(
    "cycles,events,reason",
    [
        (100, frozenset({"axi"}), "the trace has no dispatch records"),
        (100, frozenset({"dispatch"}), "the trace has no axi_request, axi_response"),
        # 100 retirements in 120 cycles put the model's IPC 20% above the RTL's.
        (
            120,
            ALL_EVENTS,
            r"the model's IPC differs from the RTL's by \+20\.00%, beyond the tolerance",
        ),
    ],
)
def test_calibration_check_fails_and_prints_the_deltas(
    tmp_path: Path, cycles: int, events: frozenset[str], reason: str
) -> None:
    """A missing event class or an IPC beyond the tolerance fails the check."""
    _baseline(tmp_path / "baseline.json", 1.0)
    result = _check(tmp_path, cycles=cycles, events=events)
    assert result.returncode == 1, result.stdout + result.stderr
    assert re.search(f"^FAIL: {reason}", result.stdout, re.MULTILINE), result.stdout
    assert "model vs RTL IPC" in result.stdout


@pytest.mark.parametrize("ipc_ratio,passes", [(1.1, True), (0.9, True), (1.11, False)])
def test_calibration_check_takes_the_tolerance_as_inclusive(
    ipc_ratio: float, passes: bool
) -> None:
    """A model IPC exactly 10% from the RTL's passes; one further out fails."""
    baseline = {
        "required_events": ["retire"],
        "ipc_tolerance": 0.1,
        "rtl": {"ipc": 1.0, "cycles": 100},
        "model": {"ipc": 1.0},
        "ipc_delta": 0.0,
    }
    rtl = {"ipc": 1.0, "cycles": 100, "event_counts": {"retire": 100}}
    _, failures = trace_contract.check_calibration(rtl, {"ipc": ipc_ratio}, baseline)
    assert (not failures) == passes, failures


def test_calibration_check_compares_the_counters_and_the_manifest(
    tmp_path: Path,
) -> None:
    """The trace must agree with its counters, and come from the baseline's run."""
    _baseline(tmp_path / "baseline.json", 1.0)
    counters = tmp_path / "counters.json"
    counters.write_text(
        json.dumps(
            {
                "cycles": 100,
                "retired_uops": 99,
                "dispatch_distribution": {
                    "cycles_1_uop": 100,
                    "cycles_2_uops": 0,
                    "total_dispatched_uops": 100,
                },
                "commit_distribution": {"cycles_1_uop": 99, "cycles_2_uops": 0},
                "axi_totals": {
                    "ar_requests": 1,
                    "aw_requests": 1,
                    "r_responses": 1,
                    "b_responses": 0,
                },
            }
        ),
        encoding="utf-8",
    )
    manifest = tmp_path / "manifest.json"
    manifest.write_text(
        json.dumps({"benchmark": "coremark", "memory_configuration": {"tier": "ddr"}}),
        encoding="utf-8",
    )
    result = _check(tmp_path, "--counters", str(counters), "--manifest", str(manifest))
    assert result.returncode == 1
    assert "FAIL: the trace has 100 retired_uops, its counters 99" in result.stdout
    assert "FAIL: the trace has 100 retire records, its counters 99" in result.stdout
    assert "FAIL: the trace has 1 axi_request records, its counters 2" in result.stdout
    assert "axi_response records" not in result.stdout
    assert "dispatch records" not in result.stdout
    assert "FAIL: the trace is from the ddr tier, the baseline from the bram tier" in (
        result.stdout
    )


def test_refresh_rewrites_the_figures_only_when_the_check_passes(
    tmp_path: Path,
) -> None:
    """--refresh keeps the tolerance and the run, and refuses a failing check."""
    baseline = tmp_path / "baseline.json"
    _baseline(baseline, 0.95)
    passing = _check(tmp_path, "--refresh")
    assert passing.returncode == 0, passing.stdout + passing.stderr
    refreshed = json.loads(baseline.read_text(encoding="utf-8"))
    assert refreshed["rtl"]["commit"] == "abc"
    assert refreshed["rtl"]["ipc"] == 1.0
    assert refreshed["rtl"]["event_counts"]["axi_request"] == 1
    assert refreshed["ipc_delta"] == 0.0
    assert refreshed["ipc_tolerance"] == 0.1

    before = baseline.read_text(encoding="utf-8")
    failing = _check(tmp_path, "--refresh", events=frozenset({"axi"}))
    assert failing.returncode == 1
    assert baseline.read_text(encoding="utf-8") == before


def test_the_stored_baseline_matches_the_model() -> None:
    """The baseline's model figures are the model's, and its RTL within tolerance."""
    baseline = json.loads(
        (PERF_MODELING / "calibration" / "ci_baseline.json").read_text(encoding="utf-8")
    )
    run = model.run_workload(
        model.ModelConfig(), baseline["model_workload"], baseline["model_seed"]
    )
    assert trace_contract.model_figures(run) == baseline["model"]
    delta = baseline["model"]["ipc"] / baseline["rtl"]["ipc"] - 1
    assert delta == pytest.approx(baseline["ipc_delta"])
    assert abs(delta) <= baseline["ipc_tolerance"]
