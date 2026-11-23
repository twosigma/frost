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
import shlex
import shutil
import subprocess
from fnmatch import fnmatchcase
from pathlib import Path
from typing import Any

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
from ci_sim_plan import cocotb_jobs
from ci_verilator import job_matrix
from coverage_report import HEADER, ci_coverage_files, main, report as run_report
from test_rvv_ci import job_condition

EXPECTED_COVERAGE_JOBS = 33
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
    assert len(matrix["include"]) == (EXPECTED_TOGGLE_JOBS if toggle else 78)


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


REPO_ROOT = WORKFLOW.parents[2]
TESTS_DIR = REPO_ROOT / "tests"
MAKEFILE = TESTS_DIR / "Makefile"
HDL_SOURCE_SUFFIXES = (".sv", ".v", ".svh", ".vh")
_IGNORED_SIM_BUILD_VARS = frozenset(
    {"SIM_BUILD", "TOGGLE_CONFIG", "TOGGLE_SCAN", "GENERATED_COVERAGE_SOURCES"}
)


def _join_continued_lines(text: str) -> list[str]:
    """Join backslash-continued Makefile or shell lines."""
    return re.sub(r"\\\n[ \t]*", " ", text).splitlines()


def _workflow_coverage_make_commands(merge_run: str) -> list[list[str]]:
    """Extract make commands run before coverage_report.py in Merge and report."""
    commands: list[list[str]] = []
    for raw in _join_continued_lines(merge_run):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        tokens = shlex.split(line)
        if any("coverage_report.py" in token for token in tokens):
            break
        if tokens[:2] == ["./scripts/frost.py", "--image"] and "run" in tokens:
            tokens = tokens[tokens.index("run") + 1 :]
        if tokens and tokens[0] == "make":
            commands.append(tokens)
    return commands


def _makefile_sim_build_selectors(makefile_text: str) -> tuple[set[str], set[str]]:
    """Find TOPLEVEL and extra-arg tokens guarding SIM_BUILD source rules."""
    lines = _join_continued_lines(makefile_text)
    sim_build_vars: set[str] = set()
    for raw in lines:
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        assign = re.match(r"^([A-Za-z0-9_]+)\s*(?::=|\+=|\?=|=)\s*(.+)$", stripped)
        if assign:
            name, value = assign.group(1), assign.group(2)
            if name not in _IGNORED_SIM_BUILD_VARS and (
                "$(SIM_BUILD)/" in value or "sim_build/" in value
            ):
                sim_build_vars.add(name)

    var_pattern = (
        re.compile(
            r"\$\((" + "|".join(sorted(re.escape(v) for v in sim_build_vars)) + r")\)"
        )
        if sim_build_vars
        else None
    )
    toplevels: set[str] = set()
    extra_tokens: set[str] = set()
    stack: list[str] = []
    for raw in lines:
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith(("ifeq ", "ifneq ")):
            stack.append(stripped)
            continue
        if stripped.startswith(("else ifeq ", "else ifneq ")):
            if stack:
                stack[-1] = stripped
            continue
        if stripped == "else":
            if stack:
                stack[-1] = "else"
            continue
        if stripped == "endif":
            if stack:
                stack.pop()
            continue
        if any(
            ignored in stripped
            for ignored in (
                "Vtop.mk",
                "clean-local",
                "TOGGLE_CONFIG",
                "TOGGLE_SCAN",
                "GENERATED_COVERAGE_SOURCES",
            )
        ):
            continue
        touches_sim_build = (
            "$(SIM_BUILD)/" in stripped
            or "sim_build/" in stripped
            or (var_pattern is not None and var_pattern.search(stripped) is not None)
        )
        if not touches_sim_build:
            continue
        for cond in stack:
            eq_match = re.search(r"ifeq\s*\(\$\(TOPLEVEL\)\s*,\s*([^)]+)\)", cond)
            if eq_match:
                toplevels.add(eq_match.group(1).strip())
            filt_match = re.search(r"filter\s+\$\(TOPLEVEL\)\s*,\s*([^)]+)\)", cond)
            if filt_match:
                toplevels.update(filt_match.group(1).split())
            find_match = re.search(
                r"findstring\s+([^,]+)\s*,\s*\$\(FROST_VERILATOR_EXTRA_ARGS\)", cond
            )
            if find_match:
                extra_tokens.add(find_match.group(1).strip())
    return toplevels, extra_tokens


def _coverage_builds_touching_sim_build(
    jobs: dict[str, Any], makefile_text: str
) -> list[tuple[str, str]]:
    """Return CI coverage (TOPLEVEL, defines) pairs that reach SIM_BUILD branches."""
    toplevels, extra_tokens = _makefile_sim_build_selectors(makefile_text)
    selected: set[tuple[str, str]] = set()
    for toggle in (False, True):
        for _, _, configs in cocotb_jobs(
            jobs, full=not toggle, toggle=toggle, event="push"
        ):
            for cfg in configs:
                if cfg.get("FROST_COVERAGE") != "1":
                    continue
                top = cfg["TOPLEVEL"]
                extra = cfg.get("FROST_VERILATOR_EXTRA_ARGS", "")
                defines = " ".join(
                    sorted(
                        tok
                        for tok in shlex.split(extra)
                        if tok.startswith(("+define+", "-D"))
                    )
                )
                if top in toplevels or any(tok in extra for tok in extra_tokens):
                    selected.add((top, defines))
    selected.add(("frost", ""))
    return sorted(selected)


def _collect_sim_build_hdl_from_filelist(
    filelist: Path, sim_build_prefix: str, visited: set[Path]
) -> set[str]:
    """Recursively read a generated .f filelist for generated HDL source paths."""
    if filelist in visited or not filelist.is_file():
        return set()
    visited.add(filelist)
    found: set[str] = set()
    tokens = shlex.split(filelist.read_text(encoding="utf-8"), comments=True)
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token == "-f" and index + 1 < len(tokens):
            nested = tokens[index + 1]
            if nested.startswith(sim_build_prefix):
                found.update(
                    _collect_sim_build_hdl_from_filelist(
                        Path(nested), sim_build_prefix, visited
                    )
                )
            index += 2
            continue
        if token.startswith(sim_build_prefix) and token.endswith(HDL_SOURCE_SUFFIXES):
            found.add(token.removeprefix(sim_build_prefix))
        index += 1
    return found


def _probe_makefile_coverage_generated_sources(
    builds: list[tuple[str, str]], tmp_path: Path
) -> set[str]:
    """Query tests/Makefile for generated HDL sources needed by coverage builds."""
    probe_dir = tmp_path / "probe_sim_build"
    probe_prefix = f"{probe_dir}/"
    probe_mk = tmp_path / "probe.mk"
    probe_mk.write_text(
        f"include {MAKEFILE}\n"
        "_print_generated_sources:\n"
        "\t@printf 'VS=%s\\nCD=%s\\nCA=%s\\n' "
        "'$(VERILOG_SOURCES)' '$(CUSTOM_COMPILE_DEPS)' '$(COMPILE_ARGS)'\n",
        encoding="utf-8",
    )
    env = {
        **os.environ,
        "ROOT": str(REPO_ROOT),
        "NUMBER_OF_CPU_CORES": "4",
        "FROST_COVERAGE": "1",
    }
    generated: set[str] = set()
    for top, defs in builds:
        common_args = [
            "make",
            "--no-print-directory",
            "-C",
            str(TESTS_DIR),
            "-f",
            str(probe_mk),
            f"ROOT={REPO_ROOT}",
            "NUMBER_OF_CPU_CORES=4",
            "FROST_COVERAGE=1",
            f"SIM_BUILD={probe_dir}",
            f"TOPLEVEL={top}",
            f"FROST_VERILATOR_EXTRA_ARGS={defs}",
        ]
        result = subprocess.run(
            [*common_args, "_print_generated_sources"],
            env=env,
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        )
        filelists: list[str] = []
        for line in result.stdout.splitlines():
            _, _, payload = line.partition("=")
            tokens = shlex.split(payload)
            for idx, token in enumerate(tokens):
                if token.startswith(probe_prefix) and token.endswith(
                    HDL_SOURCE_SUFFIXES
                ):
                    generated.add(token.removeprefix(probe_prefix))
                if (
                    token == "-f"
                    and idx + 1 < len(tokens)
                    and tokens[idx + 1].startswith(probe_prefix)
                ):
                    filelists.append(tokens[idx + 1])
        if filelists:
            subprocess.run(
                [*common_args, *filelists],
                env=env,
                capture_output=True,
                text=True,
                check=True,
                timeout=30,
            )
            visited: set[Path] = set()
            for filelist in filelists:
                generated.update(
                    _collect_sim_build_hdl_from_filelist(
                        Path(filelist), probe_prefix, visited
                    )
                )
    return generated


def test_coverage_report_regenerates_all_makefile_generated_sources(
    tmp_path: Path,
) -> None:
    """The Coverage Report job regenerates every generated HDL source for coverage builds."""
    jobs = workflow_jobs()
    merge = next(
        s
        for s in jobs["coverage-report"]["steps"]
        if s.get("name") == "Merge and report"
    )
    make_commands = _workflow_coverage_make_commands(merge["run"])
    assert make_commands, (
        "Coverage Report's Merge and report step must regenerate generated sources "
        "before running tests/coverage_report.py"
    )

    makefile_text = MAKEFILE.read_text(encoding="utf-8")
    builds = _coverage_builds_touching_sim_build(jobs, makefile_text)
    assert builds

    if shutil.which("cocotb-config") is None:
        pytest.skip("cocotb-config is not on PATH")

    required_sources = _probe_makefile_coverage_generated_sources(builds, tmp_path)
    assert {"vcu118_ddr_cone.sv", "riscv_pkg.sv"} <= required_sources

    regen_dir = tmp_path / "regen_sim_build"
    env = {
        **os.environ,
        "ROOT": str(REPO_ROOT),
        "NUMBER_OF_CPU_CORES": "4",
    }
    for cmd in make_commands:
        rewritten = [
            f"{regen_dir}/{tok.removeprefix('sim_build/')}"
            if tok.startswith("sim_build/")
            else tok
            for tok in cmd
        ]
        subprocess.run(
            [*rewritten, f"SIM_BUILD={regen_dir}", f"ROOT={REPO_ROOT}"],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=True,
            timeout=60,
        )

    regenerated = {
        path.relative_to(regen_dir).as_posix()
        for path in regen_dir.rglob("*")
        if path.is_file()
        and path.name.endswith(HDL_SOURCE_SUFFIXES)
        and path.stat().st_size > 0
    }
    missing = sorted(required_sources - regenerated)
    assert not missing, (
        "Coverage Report does not regenerate generated HDL sources required by "
        f"coverage builds: {missing} (regenerated: {sorted(regenerated)})"
    )

    if shutil.which("verilator_coverage") is not None:
        dat = tmp_path / "generated_sources.dat"
        records = [
            f"C '\x01f\x02{regen_dir / rel}\x01l\x021\x01n\x021\x01t\x02line"
            f"\x01page\x02v_line/gen_{idx}\x01o\x02block\x01h\x02gen_{idx}' 0\n"
            for idx, rel in enumerate(sorted(required_sources))
        ]
        dat.write_text(HEADER + "".join(records), encoding="utf-8")
        report_out = tmp_path / "report_out"
        assert run_report([dat], report_out, annotate=True) == 0
        annotated_names = {
            p.name for p in (report_out / "annotated").rglob("*") if p.is_file()
        }
        assert {Path(rel).name for rel in required_sources} <= annotated_names
