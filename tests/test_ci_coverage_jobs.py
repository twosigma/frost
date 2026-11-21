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

import re
from fnmatch import fnmatchcase
from pathlib import Path

import pytest

from ci_matrix import (
    COVERAGE_AXES,
    UPLOAD_STEP,
    coverage_artifacts,
    expand_matrix,
    workflow_jobs,
)
from coverage_report import HEADER, ci_coverage_files, main

EXPECTED_COVERAGE_JOBS = 29


def test_coverage_is_selected_by_the_matrix() -> None:
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
    artifacts = coverage_artifacts(jobs)
    assert len(artifacts) == EXPECTED_COVERAGE_JOBS
    cocotb_files = []
    for name, axis in COVERAGE_AXES.items():
        job = jobs[name]
        steps = {s.get("name"): s for s in job["steps"]}
        for combo in expand_matrix(job["strategy"]["matrix"]):
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


@pytest.fixture
def coverage_payloads() -> dict[str, str]:
    """Supply a sample coverage record for each artifact in the CI matrix."""
    return {
        artifact: HEADER + "C '\x01t\x02line\x01f\x02test.sv' 1\n"
        for artifact in coverage_artifacts(workflow_jobs())
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
    tmp_path: Path, coverage_payloads: dict[str, str]
) -> None:
    """Accept the layout produced by the workflow's coverage download step."""
    payloads = _write_download(tmp_path, coverage_payloads)
    assert ci_coverage_files(tmp_path) == sorted(payloads)


@pytest.mark.parametrize(
    "payload", [None, "", HEADER], ids=["missing", "empty", "header-only"]
)
def test_report_requires_every_ci_payload(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    coverage_payloads: dict[str, str],
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
            ]
        )
        == 1
    )
    stderr = capsys.readouterr().err
    assert "Incomplete CI coverage" in stderr
    assert artifact in stderr and diagnostic in stderr
    assert not output.exists()
