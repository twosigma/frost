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

import json
import os
import re
import subprocess
from fnmatch import fnmatchcase
from pathlib import Path

import pytest
import yaml  # type: ignore[import-untyped]

from ci_matrix import (
    COVERAGE_AXES,
    UPLOAD_STEP,
    WORKFLOW,
    coverage_artifacts,
    expand_matrix,
    workflow_jobs,
)
from ci_verilator import job_matrix
from coverage_report import HEADER, ci_coverage_files, main
from test_rvv_ci import job_condition

EXPECTED_COVERAGE_JOBS = 29
EXPECTED_TOGGLE_JOBS = 32


@pytest.mark.parametrize("toggle", (False, True))
def test_coverage_is_selected_by_the_matrix(toggle: bool) -> None:
    """Exactly the listed matrix entries collect coverage, and steps follow it."""
    jobs = workflow_jobs()
    selecting = {
        name
        for name, job in jobs.items()
        if any(
            step.get("with", {}).get("name", "").startswith("coverage-job-")
            for step in job.get("steps", [])
        )
    }
    assert selecting == COVERAGE_AXES.keys()
    artifacts = coverage_artifacts(jobs, toggle_coverage=toggle)
    assert len(artifacts) == (
        EXPECTED_TOGGLE_JOBS if toggle else EXPECTED_COVERAGE_JOBS
    )
    if toggle:
        assert list(artifacts) == [
            f"coverage-job-test-verilator-{index}"
            for index in range(EXPECTED_TOGGLE_JOBS)
        ]
    cocotb_files = []
    for name, axis in COVERAGE_AXES.items():
        job = jobs[name]
        steps = {s.get("name"): s for s in job["steps"]}
        matrix = (
            job_matrix(coverage_only=toggle)
            if name == "test-verilator"
            else job["strategy"]["matrix"]
        )
        for combo in expand_matrix(matrix):
            if axis is not None:
                assert "coverage" in combo["shard"], (name, combo)
            else:
                assert combo.get("coverage") in (0, 1), (name, combo)
            if (
                name == "test-verilator"
                and combo["mem_config"] in combo["shard"]["coverage"]
            ):
                label = steps["Merge the job's coverage"]["env"]["COVERAGE_NAME"]
                label = label.replace(
                    "${{ matrix.shard.name }}", combo["shard"]["name"]
                ).replace("${{ matrix.mem_config }}", combo["mem_config"])
                cocotb_files.append(re.sub(r"[^A-Za-z0-9]+", "_", label))
        coverage_condition = (
            f"contains(matrix.shard.coverage, matrix.{axis})"
            if axis is not None
            else "matrix.coverage == 1"
        )
        assert steps[UPLOAD_STEP]["with"]["if-no-files-found"] == "error"
        for step in (steps["Merge the job's coverage"], steps[UPLOAD_STEP]):
            assert step["if"] == f"${{{{ !cancelled() && {coverage_condition} }}}}", (
                name
            )
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
    merge = next(s for s in report["steps"] if s.get("name") == "Merge and report")
    assert "--require-ci-artifacts" in merge["run"]
    assert "${{ inputs.toggle_coverage && '--toggle-coverage' || '' }}" in merge["run"]


@pytest.fixture(params=(False, True), ids=("ordinary", "toggle"))
def toggle_mode(request: pytest.FixtureRequest) -> bool:
    """Exercise both sets of expected artifact names."""
    return bool(request.param)


@pytest.fixture
def coverage_payloads(toggle_mode: bool) -> dict[str, str]:
    """Supply a sample coverage record for each artifact in the CI matrix."""
    return {
        artifact: HEADER + "C '\x01t\x02line\x01f\x02test.sv' 1\n"
        for artifact in coverage_artifacts(workflow_jobs(), toggle_coverage=toggle_mode)
    }


def _write_download(directory: Path, contents: dict[str, str]) -> list[Path]:
    payloads = []
    for artifact, content in contents.items():
        payload = directory / artifact / "coverage.dat"
        payload.parent.mkdir()
        payload.write_text(content)
        payloads.append(payload)
    return payloads


def test_complete_ci_download_supplies_one_input_per_job(
    tmp_path: Path, coverage_payloads: dict[str, str], toggle_mode: bool
) -> None:
    """Accept the layout produced by the workflow's coverage download step."""
    payloads = _write_download(tmp_path, coverage_payloads)
    assert ci_coverage_files(tmp_path, toggle_coverage=toggle_mode) == sorted(payloads)


@pytest.mark.parametrize(
    "payload", [None, "", HEADER], ids=["missing", "empty", "header-only"]
)
def test_report_requires_every_ci_payload(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    coverage_payloads: dict[str, str],
    toggle_mode: bool,
    payload: str | None,
) -> None:
    """The report command fails before merging an incomplete download."""
    artifact = next(iter(coverage_payloads))
    if payload is None:
        del coverage_payloads[artifact]
        diagnostic = f"missing {artifact}"
    else:
        coverage_payloads[artifact] = payload
        diagnostic = "has no coverage records"
    _write_download(tmp_path, coverage_payloads)
    output = tmp_path / "report"
    assert (
        main(
            [
                "report",
                str(tmp_path),
                "--output-dir",
                str(output),
                "--require-ci-artifacts",
                *(["--toggle-coverage"] if toggle_mode else []),
            ]
        )
        == 1
    )
    stderr = capsys.readouterr().err
    assert "Incomplete CI coverage" in stderr
    assert artifact in stderr and diagnostic in stderr
    assert not output.exists()


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
    jobs = workflow_jobs()
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
        cwd=WORKFLOW.parents[2],
        env={
            **os.environ,
            "GITHUB_OUTPUT": str(output),
            "TOGGLE_COVERAGE": str(toggle).lower(),
        },
        timeout=30,
    )
    key, data = output.read_text().strip().split("=", 1)
    assert key == "matrix"
    matrix = job_matrix(coverage_only=toggle)
    assert json.loads(data) == matrix
    assert len(matrix["include"]) == (EXPECTED_TOGGLE_JOBS if toggle else 70)


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
    for combo in job_matrix(coverage_only=requested)["include"]:
        shard = combo["shard"]
        covered = combo["mem_config"] in shard["coverage"]
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
