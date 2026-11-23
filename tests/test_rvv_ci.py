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

"""Check the vector workflow's dispatch, selection and evidence."""

import csv
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import textwrap
from collections import Counter
from graphlib import TopologicalSorter
from math import ceil
from pathlib import Path

import pytest
import yaml  # type: ignore[import-untyped]

import rvv_ci as ci
import rvv_simulator
import test_riscv_vector_tests as suite

ROOT = Path(__file__).resolve().parents[1]


def test_testrig_vector_matrix_and_replay_arguments() -> None:
    """Run the seeded and directed suites with each job's vector length."""
    workflow = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text())
    job = workflow["jobs"]["test-testrig-vector"]
    assert job["timeout-minutes"] == 70, (
        "Vector TestRIG job needs the registered budget"
    )
    assert job["strategy"]["matrix"]["vlen"] == [128, 256, 512]
    replay = next(
        step
        for step in job["steps"]
        if step.get("name") == "Compare seeded and directed vector traces"
    )
    command = shlex.split(replay["run"].replace("\\\n", ""))
    assert command[command.index("--kill-after=10s") + 1] == "50m", (
        "Vector TestRIG replay needs the registered budget"
    )
    arguments = command[command.index("tests/test_testrig.py") + 1 :]
    assert arguments.count("--vlen") == 1
    assert arguments[arguments.index("--vlen") + 1] == "${{ matrix.vlen }}"
    assert arguments[arguments.index("--startup-timeout") + 1] == "1200"
    assert arguments[arguments.index("--response-timeout") + 1] == "600"
    assert "--vector-source-widths" in arguments
    assert "--vector-directed" in arguments
    control = next(
        step
        for step in job["steps"]
        if step.get("name") == "Check detection of an incorrect vector result"
    )
    assert control["if"] == "matrix.vlen == 128"
    assert control["timeout-minutes"] == 45, (
        "Vector controls need the registered budget"
    )
    control_command = shlex.split(control["run"].replace("\\\n", ""))
    assert "timeout --kill-after=10s 600s" in control["run"], (
        "Vector result controls require the 600-second outer guard"
    )
    control_arguments = control_command[
        control_command.index("tests/test_testrig.py") + 1 :
    ]
    assert control_arguments[control_arguments.index("--startup-timeout") + 1] == "360"
    assert (
        control_arguments[control_arguments.index("--response-timeout") + 1] == "180"
    ), "Vector result controls need the 180-second response timeout"
    assert job["steps"].index(replay) < job["steps"].index(control)
    calls = [
        shlex.split(line)[1:]
        for line in control["run"].replace("\\\n", "").splitlines()
        if line.startswith("check_vector_result ")
    ]
    assert calls == [
        [
            "1",
            "vector_source_widths_integer",
            "order=17 insn=0x43002557 rd=x10",
            "0x8 != 0x9",
        ],
        [
            "state",
            "vector_state_results",
            "order=52 insn=0x42182557 rd=x10",
            "0x3 != 0x2",
        ],
        [
            "fractional-lmul",
            "vector_fractional_lmul",
            "order=14 insn=0x42902557 rd=x10",
            "0x9 != 0x8",
        ],
        [
            "base-fp",
            "vector_fp_results_flags",
            "order=10 insn=0x43102557 rd=x10",
            "0x40400000 != 0x40400001",
        ],
        [
            "fma",
            "vector_fma",
            "order=14 insn=0x43602557 rd=x10",
            "0xffffffffa8800000 != 0xffffffffa8800001",
        ],
        [
            "fp-compare",
            "vector_fp_compare",
            "order=15 insn=0x43882557 rd=x10",
            "0x1 != 0x0",
        ],
        [
            "fp-convert",
            "vector_fp_convert",
            "order=9 insn=0x43802557 rd=x10",
            "0x3 != 0x2",
        ],
        [
            "unit-stride",
            "vector_unit_stride",
            "order=109 insn=0x43a02557 rd=x10",
            "0x12345678 != 0x12345679",
        ],
        [
            "int-compare",
            "vector_int_compare",
            "order=21 insn=0x43902557 rd=x10",
            "0x0 != 0x1",
        ],
        [
            "strided",
            "vector_strided",
            "order=158 insn=0x43b02557 rd=x10",
            "0x24681356 != 0x24681357",
        ],
        [
            "indexed",
            "vector_indexed",
            "order=217 insn=0x43c02557 rd=x10",
            "0x31415926 != 0x31415927",
        ],
        [
            "segment",
            "vector_segment",
            "order=45 insn=0x43e02557 rd=x10",
            "0x19475b81 != 0x19475b80",
        ],
        [
            "fof",
            "vector_fof",
            "order=29 insn=0x43f02557 rd=x10",
            "0x13572468 != 0x13572469",
        ],
        [
            "int-widen-narrow",
            "vector_int_widen_narrow",
            "order=72 insn=0x42e02557 rd=x10",
            "0x1fe != 0x1ff",
        ],
        [
            "fixed-point",
            "vector_fixed_point",
            "order=49 insn=0x42f02557 rd=x10",
            "0x7f != 0x7e",
        ],
        [
            "fp-single",
            "vector_fp_single",
            "order=30 insn=0x42d02557 rd=x10",
            "0x40100000 != 0x40100001",
        ],
        [
            "whole-reg",
            "vector_whole_reg",
            "order=45 insn=0x42c02557 rd=x10",
            "0x135724689acebdf1 != 0x135724689acebdf0",
        ],
        [
            "fp-widen",
            "vector_fp_widen",
            "order=22 insn=0x42a02557 rd=x10",
            "0x400e000000000000 != 0x400e000000000001",
        ],
        [
            "permutes",
            "vector_permutes",
            "order=23 insn=0x42b02557 rd=x10",
            "0x2468ace0 != 0x2468ace1",
        ],
        [
            "reductions",
            "vector_reductions",
            "order=30 insn=0x43202557 rd=x10",
            "0x1234a00a != 0x1234a00b",
        ],
    ]


def test_vector_workflow(tmp_path: Path) -> None:
    """Run the matrix-producing workflow step with push and manual inputs."""
    workflow = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text())
    events = workflow[True]
    assert set(events) == {"push", "pull_request", "workflow_dispatch"}
    inputs = events["workflow_dispatch"]["inputs"]
    assert inputs["campaign"]["options"] == ["rotation", "complete"]
    assert inputs["slice"]["type"] == "string"
    jobs = workflow["jobs"]
    job = jobs["test-rvv"]
    assert set(job["needs"]) == {"build-docker", "build-sim-models"}
    assert job["if"] == (
        "${{ !cancelled() && needs.build-docker.result == 'success' && !inputs.toggle_coverage }}"
    )
    assert job["strategy"]["fail-fast"] is False
    assert job["strategy"]["max-parallel"] == 20
    assert "needs.build-docker.outputs.rvv_matrix" in job["strategy"]["matrix"]
    assert (
        jobs["build-docker"]["outputs"]["rvv_matrix"]
        == "${{ steps.rvv.outputs.matrix }}"
    )
    step = next(s for s in jobs["build-docker"]["steps"] if s.get("id") == "rvv")
    assert step["env"]["MAIN_RUN"] == "${{ needs.gate.outputs.main_run }}"
    assert step["env"]["PR_NUMBER"] == "${{ github.event.pull_request.number }}"
    default = step["env"]["SLICES_PER_MAIN_RUN"]
    assert int(default) == ci.SLICES == 20
    run = next(s for s in job["steps"] if s.get("name") == "Run vector programs")
    setup = [s["timeout-minutes"] for s in job["steps"][: job["steps"].index(run)]]
    assert setup == [5, 5, 15, 5, 5]
    setup_minutes = sum(setup)
    assert ci.FORM_PLANS == {
        128: ci.ShardPlan(4, 92, 135),
        256: ci.ShardPlan(7, 92, 135),
        512: ci.ShardPlan(13, 96, 139),
    }
    assert ci.COMPLETE_PLANS == {
        128: ci.ShardPlan(7, 297, 340),
        256: ci.ShardPlan(11, 296, 339),
        512: ci.ShardPlan(25, 316, 359),
    }
    for event, campaign, part, count, per_run, mode, parts in [
        ("push", "rotation", "", "0", default, "forms", []),
        ("push", "rotation", "", "7", "20", "forms", []),
        ("push", "rotation", "", "", "20", "forms", []),
        ("push", "rotation", "", "7", "1", "slice", ["7"]),
        ("push", "rotation", "", "0", "1", "slice", ["0"]),
        ("push", "rotation", "", "", "1", "slice", ["19"]),
        ("push", "rotation", "", "6", "3", "slice", ["18", "19", "0"]),
        ("pull_request", "rotation", "", "", default, "slice", ["4"]),
        ("workflow_dispatch", "rotation", "", "", default, "slice", ["19"]),
        ("workflow_dispatch", "rotation", "0", "", default, "slice", ["0"]),
        ("workflow_dispatch", "rotation", "19", "", default, "slice", ["19"]),
        ("workflow_dispatch", "complete", "", "", default, "complete", []),
    ]:
        output = tmp_path / "outputs"
        output.write_text("")
        subprocess.run(
            ["bash", "-eu", "-c", step["run"]],
            cwd=ROOT,
            check=True,
            env={
                **os.environ,
                "GITHUB_OUTPUT": str(output),
                "GITHUB_RUN_NUMBER": "59",
                "GITHUB_EVENT_NAME": event,
                "MAIN_RUN": count,
                "PR_NUMBER": "424" if event == "pull_request" else "",
                "SLICES_PER_MAIN_RUN": per_run,
                "SLICE": part,
                "CAMPAIGN": campaign,
            },
        )
        key, data = output.read_text().strip().split("=", 1)
        assert key == "matrix"
        rows = json.loads(data)["include"]
        assert {r["mode"] for r in rows} == {mode}
        plans = ci.COMPLETE_PLANS if mode == "complete" else ci.FORM_PLANS
        if mode == "slice":
            assert [(r["part"], r["vlen"]) for r in rows] == [
                (p, v) for p in parts for v in (128, 256, 512)
            ]
        else:
            widths = {vlen: plan.shards for vlen, plan in plans.items()}
            assert Counter(r["vlen"] for r in rows) == widths
            for vlen, n in widths.items():
                assert {r["part"] for r in rows if r["vlen"] == vlen} == {
                    f"{i}/{n}" for i in range(1, n + 1)
                }
        for row in rows:
            if mode != "slice":
                plan = plans[row["vlen"]]
                step_minutes = row["step_minutes"]
                job_minutes = row["job_minutes"]
                assert step_minutes == plan.deadline_minutes + 3
                assert job_minutes == plan.job_minutes
                assert job_minutes == setup_minutes + step_minutes + 5
            else:
                assert "step_minutes" not in row and "job_minutes" not in row
                step_minutes, job_minutes = 100, 140
                assert ci.SLICE_SECONDS < step_minutes * 60
            assert setup_minutes + step_minutes < job_minutes <= 360
    assert 'tests/rvv_ci.py run "$VLEN" "$MODE" "$PART"' in run["run"]
    assert run["env"] == {
        "VLEN": "${{ matrix.vlen }}",
        "MODE": "${{ matrix.mode }}",
        "PART": "${{ matrix.part }}",
    }

    assert run["timeout-minutes"] == "${{ matrix.step_minutes || 100 }}"
    assert job["timeout-minutes"] == "${{ matrix.job_minutes || 140 }}"
    summarize, upload = job["steps"][job["steps"].index(run) + 1 :]
    assert summarize["if"] == upload["if"] == "${{ !cancelled() }}"
    assert "rvv-results/summary.md" in summarize["run"]
    assert upload["with"]["path"] == "rvv-results/"
    assert summarize["env"]["OUTCOME"] == "${{ steps.programs.outcome }}"
    summary = tmp_path / "step-summary"
    subprocess.run(
        ["bash", "-eu", "-c", summarize["run"]],
        cwd=tmp_path,
        check=True,
        env={**os.environ, "OUTCOME": "failure", "GITHUB_STEP_SUMMARY": str(summary)},
    )
    assert "failure" in summary.read_text()
    assert (tmp_path / "rvv-results/summary.md").read_text() == summary.read_text()
    assert any(
        s.get("with", {}).get("name") == "frost-docker-image" for s in job["steps"]
    )
    assert any(
        "sw/apps/riscv_tests/riscv-tests" in s.get("run", "") for s in job["steps"]
    )
    report = jobs["rvv-campaign-report"]
    assert (
        "test-rvv" in report["needs"]
        and "inputs.campaign == 'complete'" in report["if"]
    )
    assert "github.event_name == 'workflow_dispatch'" in report["if"]
    assert "!cancelled()" in report["if"]
    assert any(s.get("with", {}).get("pattern") == "rvv-v*" for s in report["steps"])
    assert any(s.get("with", {}).get("name") == "rvv-complete" for s in report["steps"])


def test_campaign_report_image_lifetime() -> None:
    """A report queued after the last shard can still load the campaign's image."""
    jobs = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text())["jobs"]
    report = jobs["rvv-campaign-report"]
    assert set(report["needs"]) == {"build-docker", "test-rvv"}
    (image,) = (
        s["with"]
        for s in jobs["build-docker"]["steps"]
        if s.get("uses", "").startswith("actions/upload-artifact@")
        and s["with"]["name"] == "frost-docker-image"
    )
    (build,) = (
        s["with"]
        for s in jobs["build-docker"]["steps"]
        if s.get("uses", "").startswith("docker/build-push-action@")
    )
    assert build["outputs"] == f"type=docker,dest={image['path']}"
    (shards,) = (
        s["with"]
        for s in jobs["test-rvv"]["steps"]
        if s.get("uses", "").startswith("actions/upload-artifact@")
        and s["with"]["name"].startswith("rvv-v")
    )
    days = shards["retention-days"]
    assert days >= 14
    condition = "inputs.campaign == 'complete' && !inputs.toggle_coverage"
    assert image["retention-days"] == "${{ " + f"{condition} && {days} || 1" + " }}"
    (download,) = (
        s["with"]
        for s in report["steps"]
        if s.get("uses", "").startswith("actions/download-artifact@")
        and s["with"].get("name") == image["name"]
    )
    archive = Path(image["path"])
    assert download == {"name": image["name"], "path": str(archive.parent)}
    assert any(
        f"docker load --input {archive}" in s.get("run", "") for s in report["steps"]
    )
    (collector,) = (
        s for s in report["steps"] if "tests/rvv_ci.py collect" in s.get("run", "")
    )
    assert f"--image {build['tags']} run" in collector["run"]
    assert (
        collector["env"]["FROST_RVV_IMAGE_ID"]
        == "${{ needs.build-docker.outputs.tools_id }}"
    )


VECTOR_JOBS = {"build-docker", "test-rvv"}
CAMPAIGN_JOBS = VECTOR_JOBS | {"build-sim-models", "rvv-campaign-report"}
TOGGLE_JOBS = {
    "build-docker",
    "build-sim-models",
    "test-verilator",
    "coverage-report",
}
REGULAR_CI = VECTOR_JOBS | {
    "build-sim-models",
    "gate",
    "lint",
    "test-python",
    "test-verilator",
    "test-pa-width",
    "test-net10g",
    "test-arch-compliance",
    "test-riscv-tests",
    "test-riscv-benchmarks",
    "test-riscv-torture",
    "test-testrig",
    "coverage-report",
    "test-synthesis",
    "test-slang-frontend",
    "test-pa-synthesis-width",
    "test-formal",
    "test-native",
    "test-demo-image",
    "build-frost-linux-mmu",
    "linux-boot-qemu-mmu",
}
RECURRING_CI = REGULAR_CI | {"test-testrig-vector"}


def job_condition(condition: str, context: dict[str, str]) -> bool:
    """Evaluate the job guard for an uncanceled workflow."""

    def compare(match: re.Match[str]) -> str:
        equal = context[match[1]].casefold() == match[3].casefold()
        return str(equal if match[2] == "==" else not equal).lower()

    expression = condition.removeprefix("${{").removesuffix("}}").strip()
    expression = re.sub(
        r"\b((?:github|inputs|needs)\.[\w.-]+)\s*(==|!=)\s*'([^']*)'",
        compare,
        expression,
    ).replace("!cancelled()", "true")
    expression = re.sub(
        r"(!?)\b(inputs\.\w+)\b",
        lambda match: str((context[match[2]] == "true") != bool(match[1])).lower(),
        expression,
    )
    assert re.fullmatch(r"(?:true|false|&&|\|\||[()\s])+", expression), condition
    result = subprocess.run(["bash", "-c", expression])
    assert result.returncode in (0, 1), condition
    return result.returncode == 0


@pytest.mark.parametrize(
    ("event", "inputs", "labels", "expected"),
    [
        ("workflow_dispatch", {"campaign": "complete"}, (), CAMPAIGN_JOBS),
        (
            "workflow_dispatch",
            {"campaign": "complete", "reprove": True},
            (),
            CAMPAIGN_JOBS,
        ),
        ("workflow_dispatch", {"slice": "0", "reprove": True}, (), VECTOR_JOBS),
        ("workflow_dispatch", {"slice": "19"}, (), VECTOR_JOBS),
        ("workflow_dispatch", {}, (), REGULAR_CI),
        ("workflow_dispatch", {"reprove": True}, (), REGULAR_CI),
        ("workflow_dispatch", {"toggle_coverage": False}, (), REGULAR_CI),
        ("workflow_dispatch", {"toggle_coverage": True}, (), TOGGLE_JOBS),
        (
            "workflow_dispatch",
            {"reprove": True, "toggle_coverage": True},
            (),
            TOGGLE_JOBS,
        ),
        ("workflow_dispatch", {"slice": "0", "toggle_coverage": True}, (), TOGGLE_JOBS),
        (
            "workflow_dispatch",
            {"campaign": "complete", "toggle_coverage": True},
            (),
            TOGGLE_JOBS,
        ),
        ("push", {}, (), REGULAR_CI),
        ("pull_request", {}, ("run-ci",), REGULAR_CI),
        ("pull_request", {}, ("documentation",), {"gate"}),
        ("pull_request", {}, ("run-ci", "documentation"), {"gate"}),
    ],
)
def test_ci_job_scope(
    tmp_path: Path,
    event: str,
    inputs: dict[str, str | bool],
    labels: tuple[str, ...],
    expected: set[str],
) -> None:
    """Check which jobs the selector, guards and dependencies enable."""
    workflow = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text())
    jobs = workflow["jobs"]
    assert set(jobs) == RECURRING_CI | CAMPAIGN_JOBS
    if expected == REGULAR_CI and event in ("push", "pull_request"):
        expected = RECURRING_CI
    needs = {}
    for name, job in jobs.items():
        deps = job.get("needs", [])
        needs[name] = [deps] if isinstance(deps, str) else deps

    context = {
        "github.event_name": event,
        "github.event.action": "labeled" if labels else "",
        "github.event.label.name": labels[-1] if labels else "",
        "contains(github.event.pull_request.labels.*.name, 'run-ci')": str(
            "run-ci" in labels
        ).lower(),
        "needs.gate.outputs.full": "",
        "needs.build-docker.outputs.verilator_matrix": "",
        "needs.build-docker.outputs.sim_matrix": "",
    }
    for key, spec in workflow[True]["workflow_dispatch"]["inputs"].items():
        value = (
            inputs.get(key, spec.get("default", ""))
            if event == "workflow_dispatch"
            else ""
        )
        context[f"inputs.{key}"] = (
            str(value).lower() if isinstance(value, bool) else value
        )
    group = workflow["concurrency"]["group"]
    _, toggle_group, vector_group = group.rsplit("${{", 2)
    toggle_guard, toggle_suffix = toggle_group.rsplit("&&", 1)
    vector_guard, vector_suffix = vector_group.rsplit("&& format", 1)
    assert toggle_suffix == " '-toggle' || '' }}"
    assert vector_suffix == "('-rvv-{0}', github.run_id) || '' }}"
    assert job_condition(toggle_guard, context) == (expected == TOGGLE_JOBS)
    assert job_condition(vector_guard, context) == (
        expected in (VECTOR_JOBS, CAMPAIGN_JOBS)
    )
    enabled: set[str] = set()
    for name in TopologicalSorter(needs).static_order():
        guard = jobs[name].get("if", "")
        assert set(re.findall(r"\bneeds\.([\w-]+)\.", guard)) <= set(needs[name])
        # Without a status function, Actions requires successful needs.
        ready = "!cancelled()" in guard or enabled.issuperset(needs[name])
        runs = ready and (not guard or job_condition(guard, context))
        context[f"needs.{name}.result"] = "success" if runs else "skipped"
        if runs:
            enabled.add(name)
        if runs and name == "gate":
            step = next(s for s in jobs[name]["steps"] if s.get("id") == "select")
            env = {
                k: context[v.removeprefix("${{").removesuffix("}}").strip()]
                for k, v in step["env"].items()
            }
            output = tmp_path / "gate"
            subprocess.run(
                ["bash", "-eu", "-c", step["run"]],
                check=True,
                env={**os.environ, **env, "GITHUB_OUTPUT": str(output)},
            )
            assert jobs[name]["outputs"]["full"] == "${{ steps.select.outputs.full }}"
            context["needs.gate.outputs.full"] = dict(
                line.split("=", 1) for line in output.read_text().splitlines()
            )["full"]
        if runs and name == "build-docker":
            steps = {s.get("id"): s for s in jobs[name]["steps"]}
            has_verilator = job_condition(steps["verilator"]["if"], context)
            assert has_verilator == ("test-verilator" in expected)
            assert job_condition(steps["rvv"]["if"], context) == (
                "test-rvv" in expected
            )
            if has_verilator:
                context["needs.build-docker.outputs.verilator_matrix"] = "planned"
            context["needs.build-docker.outputs.sim_matrix"] = (
                "models"
                if context["needs.gate.outputs.full"] == "true"
                or context["inputs.toggle_coverage"] == "true"
                or inputs.get("campaign") == "complete"
                else "{}"
            )
    assert enabled == expected


def test_rotation_and_manual_replay() -> None:
    """Every residue maps to the same one-based shard as its manual replay."""
    for run in range(37, 57):
        part = str(run % 20)
        assert ci.matrix("rotation", run, "") == ci.matrix("rotation", 1, part)
        assert ci.shard_options("slice", part) == [
            "--one-per-form",
            "--shard",
            f"{run % 20 + 1}/20",
        ]
    for invalid in ("-1", "20", "1/20", "oops"):
        with pytest.raises(ValueError, match="0 to 19"):
            ci.matrix("rotation", 1, invalid)
    with pytest.raises(ValueError, match="either"):
        ci.matrix("complete", 1, "0")

    for count in range(1, ci.SLICES):
        seen = []
        for run in range((ci.SLICES + count - 1) // count):
            rows = ci.matrix("rotation", run, "", count)
            parts = [int(row["part"]) for row in rows if row["vlen"] == 128]
            assert len(set(parts)) == count
            assert len(rows) == 3 * count
            seen.extend(parts)
        assert seen == [i % ci.SLICES for i in range(len(seen))]
        assert len(set(seen)) == ci.SLICES
    for count in (0, 21):
        with pytest.raises(ValueError, match="slices per run"):
            ci.matrix("rotation", 0, "", count)
    assert ci.matrix("rotation", 99, "19", 20) == ci.matrix("rotation", 0, "19")
    assert ci.shard_options("forms", "2/4") == [
        "--one-per-form",
        "--shard-profile",
        "tests/fixtures/rvv_ci_form_times.csv",
        "--shard",
        "2/4",
    ]
    assert ci.shard_options("complete", "2/7") == [
        "--shard-profile",
        "tests/fixtures/rvv_ci_complete_times.csv",
        "--shard",
        "2/7",
    ]


@pytest.mark.parametrize(
    ("width", "cycles", "selection"),
    [
        (
            128,
            98445694,
            "5881ecf6d7bc560f12cbda17043cf5cb6d254624f61f69be2ec686ffd5e88583",
        ),
        (
            256,
            188047010,
            "975b7c57e8a5d84d7f5ffdfb45b2851527f80143c32457c638d6a3d9fd97634d",
        ),
        (
            512,
            340151701,
            "7142a2f20a72d44f31b6cb29bda4ab0c6d494e1eacf47e9698d3e8064f274183",
        ),
    ],
)
def test_ci_profile_matches_hosted_selection(
    width: int, cycles: int, selection: str
) -> None:
    """The cycle calibration covers the original hosted selection."""
    profile = (ROOT / ci.CYCLE_PROFILE).read_bytes()
    source = {
        r["name"]: int(r["source_weight"])
        for r in csv.DictReader(profile.decode().splitlines())
        if int(r["vlen"]) == width and r["form_weight"]
    }
    measured = suite.calibrated_shard_weights(source, width, profile, one=True)
    assert len(measured) == ci.FORMS_PER_WIDTH
    assert suite.selection_sha256(list(measured), width) == selection
    assert sum(measured.values()) == cycles


@pytest.mark.parametrize(
    ("width", "build_s", "prepare_s", "observed_ms"),
    [
        (128, 260, 211, (9856268, 8915170)),
        (256, 307, 271, (13752334, 13835697)),
        (512, 382, 368, (30383066, 10942091)),
    ],
)
def test_main_shards_fit_measured_time(
    tmp_path: Path,
    width: int,
    build_s: int,
    prepare_s: int,
    observed_ms: tuple[int, int],
) -> None:
    """Each actual partition must fit with model build and guest preparation."""
    with (ROOT / ci.CYCLE_PROFILE).open() as stream:
        names = sorted(
            r["name"]
            for r in csv.DictReader(stream)
            if int(r["vlen"]) == width and r["form_weight"]
        )
    profile = (ROOT / ci.FORM_PROFILE).read_bytes()
    rows = [
        r
        for r in csv.DictReader(profile.decode().splitlines())
        if int(r["vlen"]) == width
    ]
    assert sorted(r["name"] for r in rows) == names
    assert len(names) == ci.FORMS_PER_WIDTH
    assert (
        tuple(sum(int(r[k] or 0) for r in rows) for k in ("main_ms", "complete_ms"))
        == observed_ms
    )
    observed = {
        r["name"]: max(int(r["main_ms"] or 0), int(r["complete_ms"] or 0)) for r in rows
    }
    weights = suite.shard_weights(tmp_path, names, width, profile, one=True)
    assert weights == observed
    plan = ci.FORM_PLANS[width]
    setup_ms = 1000 * (build_s + prepare_s)
    batches = [
        suite.select_shard(weights, i, plan.shards) for i in range(1, plan.shards + 1)
    ]
    peak_ms = assert_shards_fit(width, observed, plan, setup_ms, batches)
    target_ms = 54 * 60_000
    assert peak_ms < target_ms
    assert sum(observed.values()) >= (plan.shards - 1) * (target_ms - setup_ms)


@pytest.mark.parametrize(
    ("width", "build_s", "prep_ms", "prep_cases", "program_ms", "selection"),
    [
        (
            128,
            260,
            208301,
            503,
            65936307,
            "0933c01e7bbb5b7491acf9aa593879c5b8b5ca59d67892741e3424840178ef1c",
        ),
        (
            256,
            307,
            268254,
            252,
            101571876,
            "e056bf89be5b467e061d79518fb018235718cb3d50aca8b0282531b4bbb7808e",
        ),
        (
            512,
            324,
            453403,
            95,
            239939637,
            "239e4d1e894f9331f17c7f6d1920e16cb34fc156ff93f1ad919cacd124ec1be5",
        ),
    ],
)
def test_complete_shards_fit_measured_time(
    tmp_path: Path,
    width: int,
    build_s: int,
    prep_ms: int,
    prep_cases: int,
    program_ms: int,
    selection: str,
) -> None:
    """Partition every verified campaign case once within the execution and job limits."""
    profile = (ROOT / ci.COMPLETE_PROFILE).read_bytes()
    rows = [
        r
        for r in csv.DictReader(profile.decode().splitlines())
        if int(r["vlen"]) == width
    ]
    names = [r["name"] for r in rows]
    assert len(names) == len(set(names)) == ci.PROGRAMS_PER_WIDTH
    assert suite.selection_sha256(names, width) == selection
    assert all(not r["main_ms"] for r in rows)
    observed = {r["name"]: int(r["complete_ms"]) for r in rows}
    assert min(observed.values()) > 0 and sum(observed.values()) == program_ms
    weights = suite.shard_weights(tmp_path, names, width, profile)
    assert weights == observed
    plan = ci.COMPLETE_PLANS[width]
    batches = [
        suite.select_shard(weights, i, plan.shards) for i in range(1, plan.shards + 1)
    ]
    # The slowest measured preparation also had the highest cost per guest.
    largest = max(map(len, batches))
    prepare_s = ceil(prep_ms * max(largest, prep_cases) / (1000 * prep_cases)) + 2
    setup_ms = 1000 * (build_s + prepare_s)
    peak_ms = assert_shards_fit(width, observed, plan, setup_ms, batches)
    target_ms = 180 * 60_000
    assert peak_ms < target_ms
    # Even a perfectly balanced layout with one fewer job must exceed a limit.
    assert ceil(len(names) / (plan.shards - 1)) >= largest
    mean_if_fewer_ms = setup_ms + program_ms / (plan.shards - 1)
    assert (
        mean_if_fewer_ms >= target_ms
        or ceil(1.8 * mean_if_fewer_ms / 60_000) + 43 > 360
    )


def assert_shards_fit(
    width: int,
    observed: dict[str, int],
    plan: ci.ShardPlan,
    setup_ms: int,
    batches: list[list[str]],
) -> int:
    """Check each assigned batch against its measured cost and return the peak."""
    seen = []
    peak_ms = 0
    for index, batch in enumerate(batches, 1):
        assert batch
        seen.extend(batch)
        inner_ms = sum(observed[n] for n in batch) + setup_ms
        assert 5 * inner_ms < 3 * plan.deadline_minutes * 60_000, (
            width,
            index,
            inner_ms,
        )
        peak_ms = max(peak_ms, inner_ms)
    assert sorted(seen) == sorted(observed)
    assert plan.deadline_minutes == ceil(1.8 * peak_ms / 60_000)
    return peak_ms


def result(name: str) -> dict:
    """Return the fields a successfully executed program contributes."""
    return {
        "name": name,
        "vlen": 128,
        "simulator": "native",
        "verdict": "PASS",
        "image_sha256": "a" * 64,
        "cycles": 91,
        "wall_seconds": 0.1,
        "assertions_armed": True,
    }


def test_shard_failures_and_reproduction(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Even a zero process exit needs actual results for every selected split."""
    names = ["vadd_vv-7", "vsub_vx-2"]
    assert ci.check_rows([], [], 128)[2]
    assert ci.check_rows(names, [], 128)[2]
    assert ci.check_rows(names, [result(names[0])] * 2, 128)[2]
    monkeypatch.setenv("FROST_DDR_MODEL_SEED", "rvv-42")

    def simulate(command: list[str], deadline: float, transcript: object) -> int:
        if "--build-sim" in command:
            path = Path(command[command.index("--build-sim") + 1])
            path.parent.mkdir()
            Path(f"{path}.json").write_text("{}")
        else:
            assert "--prebuilt-sim" in command and "--one-per-form" in command
            assert command[command.index("--shard") + 1] == "1/20"
            workdir = Path(command[command.index("--workdir") + 1])
            (workdir / "Makefrag").write_text("tests =\n" + "\n".join(names))
            (workdir / "selection.json").write_text('{"selection_count":665}')
            log = workdir / "images" / names[1] / "native.log"
            log.parent.mkdir(parents=True)
            log.write_text("partial UART output\n")
            rows = [
                result(names[0]),
                {
                    **result(names[1]),
                    "assertions_armed": False,
                    "message": f"assertions disarmed ({log})",
                },
            ]
            dest = Path(command[command.index("--results-jsonl") + 1])
            dest.write_text("".join(json.dumps(r) + "\n" for r in rows))
        return 0

    monkeypatch.setattr(ci, "run_until", simulate)
    assert ci.run_shard(128, "slice", "0", tmp_path, None) == 1
    summary = (tmp_path / "summary.md").read_text()
    assert "VLEN 128, slice 0" in summary and "2 selected, 2 ran, 1 failed" in summary
    assert "FROST_DDR_MODEL_SEED=rvv-42 ./scripts/frost.py run" in summary
    assert "--vlen 128 --test vsub_vx-2" in summary
    assert "assertions disarmed" in summary
    assert (tmp_path / "failures/vsub_vx-2.log").read_text() == "partial UART output\n"
    assert ci.read_rows(tmp_path / "results.jsonl")[1]["message"] == (
        "assertions disarmed (failures/vsub_vx-2.log)"
    )


@pytest.mark.parametrize(
    ("mode", "part", "total"),
    [("slice", "0", 665), ("forms", "1/4", 665), ("complete", "1/7", 3017)],
)
def test_shard_requires_full_inventory(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, mode: str, part: str, total: int
) -> None:
    """All passes in a shard still require the full selection at that width."""
    selection = {"selection_count": total}
    suffix = ""
    model = tmp_path / "model"
    Path(f"{model}.json").write_text("{}")
    monkeypatch.setattr(ci.time, "monotonic", lambda: 123.0)
    seconds = {"forms": 92 * 60, "complete": 297 * 60, "slice": 90 * 60}[mode]

    def simulate(command: list[str], deadline: float, transcript: object) -> int:
        assert deadline == 123.0 + seconds
        if mode == "slice":
            assert "--cycle-profile" not in command and "--shard-profile" not in command
        else:
            profile = ci.FORM_PROFILE if mode == "forms" else ci.COMPLETE_PROFILE
            assert Path(command[command.index("--shard-profile") + 1]) == ROOT / profile
        work = Path(command[command.index("--workdir") + 1])
        (work / "Makefrag").write_text("tests =\nvadd_vv-0\n")
        (work / "selection.json").write_text(json.dumps(selection))
        (tmp_path / "results.jsonl").write_text(
            json.dumps(result("vadd_vv-0")) + "\n" + suffix
        )
        return 0

    monkeypatch.setattr(ci, "run_until", simulate)
    assert ci.run_shard(128, mode, part, tmp_path, model) == 0
    selection["selection_count"] -= 1
    assert ci.run_shard(128, mode, part, tmp_path, model) == 1
    summary = (tmp_path / "summary.md").read_text()
    assert f"Expected {total} programs before sharding, found {total - 1}" in summary
    selection["selection_count"] = total
    suffix = '{"name":'
    assert ci.run_shard(128, mode, part, tmp_path, model) == 1
    summary = (tmp_path / "summary.md").read_text()
    assert "1 selected, 1 ran" in summary and "results.jsonl:2:" in summary
    assert (tmp_path / "results.jsonl").read_text().endswith(suffix)


def test_shard_deadline_keeps_partial_results(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A stalled subprocess leaves its output, completed rows and a failed summary."""
    model = tmp_path / "model"
    model.write_text(
        f"#!{sys.executable}\n"
        "import fcntl, time\n"
        f"with open({str(tmp_path / 'active')!r}, 'w') as lock:\n"
        "    fcntl.flock(lock, fcntl.LOCK_EX)\n"
        "    print('UART before stall', flush=True)\n"
        "    time.sleep(120)\n"
    )
    model.chmod(0o755)
    Path(f"{model}.json").write_text("{}")
    driver = tmp_path / "stall.py"
    completed = json.dumps(result("vadd_vv-0")) + "\n"
    driver.write_text(
        textwrap.dedent(f"""\
        import sys
        from concurrent.futures import ThreadPoolExecutor
        from pathlib import Path
        from rvv_simulator import IMAGE_FILES, VectorSimulator

        work = Path(sys.argv[sys.argv.index("--workdir") + 1])
        out = Path(sys.argv[sys.argv.index("--results-jsonl") + 1])
        (work / "Makefrag").write_text("tests =\\nvadd_vv-0\\nvsub_vv-0\\n")
        (work / "selection.json").write_text('{{"selection_count":665}}')
        out.write_text({completed!r})
        image = work / "images/vsub_vv-0"
        image.mkdir(parents=True)
        for name in IMAGE_FILES:
            (image / name).touch()
        sim = VectorSimulator("native", 128, 4096, 100)
        sim.binary = Path(sys.argv[sys.argv.index("--prebuilt-sim") + 1])
        print("running vsub_vv-0", flush=True)
        with ThreadPoolExecutor(1) as pool:
            pool.submit(sim.run, image).result()
        """)
    )
    monkeypatch.setattr(ci, "SUITE", str(driver))
    monkeypatch.setenv("PYTHONPATH", str(ROOT / "tests"))
    monkeypatch.setattr(ci, "SLICE_SECONDS", 5)
    assert ci.run_shard(128, "slice", "0", tmp_path, model) == 1
    summary = (tmp_path / "summary.md").read_text()
    assert "5-second deadline" in summary and "2 selected, 1 ran, 1 failed" in summary
    assert "--test vsub_vv-0" in summary
    assert "running vsub_vv-0" in (tmp_path / "shard.log").read_text()
    assert (tmp_path / "failures/vsub_vv-0.log").read_text() == "UART before stall\n"
    assert [r["name"] for r in ci.read_rows(tmp_path / "results.jsonl")] == [
        "vadd_vv-0"
    ]
    assert (tmp_path / "active").is_file()
    subprocess.run(["flock", "-w", "2", str(tmp_path / "active"), "true"], check=True)


@suite.needs_suite
def test_campaign_evidence(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """The complete union includes all checked models and rejects lost evidence."""
    monkeypatch.setattr(ci, "COMPLETE_PLANS", {128: ci.ShardPlan(2, 297, 335)})
    monkeypatch.setattr(ci, "PROGRAMS_PER_WIDTH", 2)
    names = ["vadd_vv-7", "vsub_vx-2"]
    manifest = {
        "sources": rvv_simulator.native_source_identity(os.environ.copy()),
        "settings": rvv_simulator.VectorSimulator(
            "native", 128, suite.DEFAULT_DDR_BYTES, 1
        ).model_settings,
        "sha256": "b" * 64,
    }
    for i, name in enumerate(names):
        shard = tmp_path / f"rvv-v128-{i}"
        shard.mkdir()
        row = {
            **result(name),
            "selection_sha256": suite.selection_sha256(names, 128),
            "profile_sha256": hashlib.sha256(b"").hexdigest(),
        }
        (shard / "results.jsonl").write_text(json.dumps(row) + "\n")
        (shard / "selected.txt").write_text(name + "\n")
        (shard / "simulator.json").write_text(json.dumps(manifest))
    out = tmp_path / "out"
    assert ci.collect(tmp_path, out) == 0
    proof = json.loads((out / "evidence.json").read_text())
    assert proof["widths"][0]["ran"] == 2 and proof["widths"][0]["passed"]
    assert (
        "All 2 programs passed with assertions armed"
        in (out / "summary.md").read_text()
    )
    assert set(proof["tools"]) == {"generator", "merger", "pspike"}
    assert ci.collect(tmp_path, out, "failure") == 1
    assert json.loads((out / "evidence.json").read_text())["passed"] is False
    (shard / "simulator.json").write_text(json.dumps({**manifest, "sources": {}}))
    assert ci.collect(tmp_path, out) == 1
    assert "identity differs" in (out / "summary.md").read_text()
    assert not (out / "v128.jsonl").exists()
    (shard / "simulator.json").write_text(json.dumps({**manifest, "sha256": 17}))
    assert ci.collect(tmp_path, out) == 1
    shard.rename(tmp_path / "missing")
    assert ci.collect(tmp_path, out) == 1
    assert "expected 2 shards, found 1" in (out / "summary.md").read_text()
