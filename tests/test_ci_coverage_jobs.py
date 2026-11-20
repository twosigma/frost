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

"""Check which CI jobs collect coverage and that their steps agree."""

import itertools
import json
import os
import re
import subprocess
from fnmatch import fnmatchcase
from pathlib import Path
from typing import Any

import pytest
import yaml  # type: ignore[import-untyped]

from ci_verilator import VERILATOR_MATRIX
from test_rvv_ci import job_condition

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/ci.yml"

# Jobs that collect coverage: every one of these has a `coverage` field in its
# matrix, and the rest of the matrix entries have it switched off.
EXPECTED_COVERAGE_JOBS = 29


def _expand(matrix: dict[str, Any]) -> list[dict[str, Any]]:
    """Expand a job matrix the way GitHub does, for the shapes the workflow uses."""
    axes = {k: v for k, v in matrix.items() if k not in ("include", "exclude")}
    combos = (
        [dict(zip(axes, values)) for values in itertools.product(*axes.values())]
        if axes
        else []
    )
    for extra in matrix.get("include", []):
        matched = [
            c for c in combos if all(c[k] == v for k, v in extra.items() if k in c)
        ]
        if matched and axes:
            for combo in matched:
                combo.update({k: v for k, v in extra.items() if k not in combo})
        else:
            combos.append(dict(extra))
    return combos


def _collects(job: str, combo: dict[str, Any]) -> bool:
    if job == "test-verilator":
        return bool(combo["mem_config"] in combo["shard"]["coverage"])
    if job == "test-pa-width":
        return bool(combo["capacity_gib"] in combo["shard"]["coverage"])
    return bool(combo["coverage"] == 1)


def test_coverage_is_selected_by_the_matrix() -> None:
    """Exactly the listed matrix entries collect coverage, and steps follow it."""
    jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
    selecting = [
        "test-verilator",
        "test-pa-width",
        "test-arch-compliance",
        "test-riscv-tests",
        "test-riscv-torture",
        "test-testrig",
    ]
    enabled = 0
    artifacts = []
    cocotb_files = []
    for name in selecting:
        job = jobs[name]
        steps = {s.get("name"): s for s in job["steps"]}
        matrix = (
            VERILATOR_MATRIX if name == "test-verilator" else job["strategy"]["matrix"]
        )
        for index, combo in enumerate(_expand(matrix)):
            if name in ("test-verilator", "test-pa-width"):
                assert "coverage" in combo["shard"], (name, combo)
            else:
                assert combo.get("coverage") in (0, 1), (name, combo)
            enabled += _collects(name, combo)
            if _collects(name, combo):
                artifact = steps["Upload the job's coverage"]["with"]["name"]
                artifact = artifact.replace("${{ github.job }}", name).replace(
                    "${{ strategy.job-index }}", str(index)
                )
                assert "${{" not in artifact, artifact
                artifacts.append(artifact)
                if name == "test-verilator":
                    label = steps["Merge the job's coverage"]["env"]["COVERAGE_NAME"]
                    label = label.replace(
                        "${{ matrix.shard.name }}", combo["shard"]["name"]
                    ).replace("${{ matrix.mem_config }}", combo["mem_config"])
                    cocotb_files.append(re.sub(r"[^A-Za-z0-9]+", "_", label))
        for step in (
            steps["Merge the job's coverage"],
            steps["Upload the job's coverage"],
        ):
            assert "shard.name" not in step["if"], name
        assert "coverage" in steps["Merge the job's coverage"]["if"], name
        assert "coverage" in steps["Upload the job's coverage"]["if"], name
    assert enabled == EXPECTED_COVERAGE_JOBS
    assert len(set(artifacts)) == enabled, "Coverage artifact names must be unique"
    assert len(set(cocotb_files)) == len(cocotb_files), (
        "Merged filenames must be unique"
    )
    report = jobs["coverage-report"]
    assert set(selecting) <= set(report["needs"])
    download = next(
        s for s in report["steps"] if s.get("name") == "Download the jobs' coverage"
    )
    assert all(
        fnmatchcase(artifact, download["with"]["pattern"]) for artifact in artifacts
    )


def _env_value(expression: str, event: str, predicates: dict[str, bool]) -> str:
    """Evaluate the Verilator job's conditional environment values."""
    expression = expression.removeprefix("${{").removesuffix("}}").strip()
    guard, choices = expression.rsplit(" && ", 1)
    on, off = choices.split(" || ")
    for predicate, value in predicates.items():
        guard = guard.replace(f"!{predicate}", str(not value).lower())
        guard = guard.replace(predicate, str(value).lower())
    return (on if job_condition(guard, {"github.event_name": event}) else off).strip(
        "'"
    )


@pytest.mark.parametrize("toggle", (False, True))
def test_cocotb_matrix_output(tmp_path: Path, toggle: bool) -> None:
    """The image job emits the full or coverage-only matrix in order."""
    jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
    build = jobs["build-docker"]
    planner = next(s for s in build["steps"] if s.get("id") == "verilator")
    assert planner["env"]["TOGGLE_COVERAGE"] == "${{ inputs.toggle_coverage }}"
    assert (
        build["outputs"]["verilator_matrix"] == "${{ steps.verilator.outputs.matrix }}"
    )
    assert jobs["test-verilator"]["strategy"]["matrix"] == (
        "${{ fromJSON(needs.build-docker.outputs.verilator_matrix) }}"
    )
    output = tmp_path / "github-output"
    subprocess.run(
        ["bash", "-eu", "-c", planner["run"]],
        check=True,
        cwd=ROOT,
        env={
            **os.environ,
            "GITHUB_OUTPUT": str(output),
            "TOGGLE_COVERAGE": str(toggle).lower(),
        },
        timeout=30,
    )
    key, data = output.read_text().strip().split("=", 1)
    assert key == "matrix"
    full = _expand(VERILATOR_MATRIX)
    covered = [row for row in full if _collects("test-verilator", row)]
    assert len(covered) == 19
    assert sum(row["shard"]["name"].startswith("Unit Tests") for row in covered) == 2
    assert json.loads(data) == {"include": covered if toggle else full}


@pytest.mark.parametrize(
    ("event", "requested"),
    [
        ("push", False),
        ("pull_request", False),
        ("workflow_dispatch", False),
        ("workflow_dispatch", True),
    ],
)
def test_verilator_toggle_coverage_expansion(event: str, requested: bool) -> None:
    """Dispatch adds toggles and startup time to the covered program shards."""
    workflow = yaml.safe_load(WORKFLOW.read_text())
    spec = workflow[True]["workflow_dispatch"]["inputs"]["toggle_coverage"]
    assert spec["type"] == "boolean" and spec["default"] is False
    job = workflow["jobs"]["test-verilator"]
    step = next(s for s in job["steps"] if s.get("name", "").startswith("Run Cocotb"))
    env = step["env"]
    for combo in _expand(VERILATOR_MATRIX):
        shard = combo["shard"]
        covered = _collects("test-verilator", combo)
        unit = shard["name"].startswith("Unit Tests")
        opted_in = event == "workflow_dispatch" and requested and covered
        timeout = "2400" if opted_in and not unit else ""
        predicates = {
            "inputs.toggle_coverage": requested,
            "contains(matrix.shard.coverage, matrix.mem_config)": covered,
            "startsWith(matrix.shard.name, 'Unit Tests')": unit,
        }
        assert _env_value(env["FROST_COVERAGE"], event, predicates) == str(int(covered))
        assert _env_value(env["FROST_COVERAGE_TOGGLE"], event, predicates) == str(
            int(unit or opted_in)
        ), combo
        assert (
            _env_value(env["FROST_STARTUP_TIMEOUT_SEC"], event, predicates) == timeout
        ), combo
        if timeout:
            assert int(timeout) < shard.get("timeout_minutes", 240) * 60, combo
