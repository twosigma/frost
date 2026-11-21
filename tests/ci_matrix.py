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

"""Expand the CI matrices that select programs and coverage artifacts."""

from itertools import product
from pathlib import Path
from typing import Any

import yaml  # type: ignore[import-untyped]

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml"
COVERAGE_AXES = {
    "test-verilator": "mem_config",
    "test-pa-width": "capacity_gib",
    "test-arch-compliance": None,
    "test-riscv-tests": None,
    "test-riscv-torture": None,
    "test-testrig": None,
}
UPLOAD_STEP = "Upload the job's coverage"


def workflow_jobs(path: Path = WORKFLOW) -> dict[str, Any]:
    """Read the jobs in the given workflow."""
    jobs: dict[str, Any] = yaml.safe_load(path.read_text())["jobs"]
    return jobs


def expand_matrix(matrix: dict[str, Any]) -> list[dict[str, Any]]:
    """Expand the axes and include entries in strategy.job-index order."""
    axes = {k: v for k, v in matrix.items() if k not in ("include", "exclude")}
    original = [dict(zip(axes, values)) for values in product(*axes.values())]
    original = [
        combo
        for combo in original
        if combo
        and not any(
            all(combo.get(key) == value for key, value in excluded.items())
            for excluded in matrix.get("exclude", [])
        )
    ]
    expanded = [dict(combo) for combo in original]
    for extra in matrix.get("include", []):
        matches = [
            index
            for index, combo in enumerate(original)
            if all(combo[key] == value for key, value in extra.items() if key in combo)
        ]
        if matches:
            for index in matches:
                expanded[index].update(extra)
        else:
            expanded.append(dict(extra))
    return expanded


def coverage_artifacts(jobs: dict[str, Any]) -> dict[str, str]:
    """Return each expected artifact name and a description of its matrix entry."""
    artifacts = {}
    for name, axis in COVERAGE_AXES.items():
        job = jobs[name]
        upload = next(step for step in job["steps"] if step.get("name") == UPLOAD_STEP)
        template = upload["with"]["name"]
        for index, combo in enumerate(expand_matrix(job["strategy"]["matrix"])):
            if axis is not None:
                shard = combo["shard"]
                label = f"{name} / {shard['name']} / {combo[axis]}"
                enabled = combo[axis] in shard["coverage"]
            else:
                label = f"{name} / matrix entry {index}"
                enabled = combo["coverage"] == 1
            if enabled:
                artifact = template.replace("${{ github.job }}", name).replace(
                    "${{ strategy.job-index }}", str(index)
                )
                if "${{" in artifact or artifact in artifacts:
                    raise ValueError(f"Invalid coverage artifact name {artifact!r}")
                artifacts[artifact] = label
    return artifacts
