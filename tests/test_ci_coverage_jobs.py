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
import re
from fnmatch import fnmatchcase
from pathlib import Path
from typing import Any

import yaml  # type: ignore[import-untyped]

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml"

# Jobs that collect coverage: every one of these has a `coverage` field in its
# matrix, and the rest of the matrix entries have it switched off.
EXPECTED_COVERAGE_JOBS = 23


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
        for index, combo in enumerate(_expand(job["strategy"]["matrix"])):
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
