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


"""Check run-local simulator selection, compatibility, and failure visibility."""

from collections import Counter
from collections.abc import Iterator
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

import pytest
import yaml  # type: ignore[import-untyped]

from ci_matrix import expand_matrix
import ci_sim_models as models
from ci_sim_plan import (
    aperture_tests,
    cocotb_jobs,
    config_for,
    parse_vectors,
    plan,
    registry_tests,
)
from ci_verilator import job_matrix
from rvv_ci import matrix
from test_native_sim import UNSEEDED_COCOTB_STRIP_ENV
from test_run_cocotb import TEST_REGISTRY, CocotbRunConfig
from test_rvv_ci import job_condition
from test_testrig import DEFAULT_DDR_CAPACITY_LOG2_BYTES, simulator_config, wfi

WORKFLOW = models.ROOT / ".github/workflows/ci.yml"
CONSUMER_JOBS = (
    "test-verilator",
    "test-pa-width",
    "test-arch-compliance",
    "test-riscv-tests",
    "test-riscv-benchmarks",
    "test-riscv-torture",
    "test-testrig",
    "test-testrig-vector",
    "test-native",
    "test-rvv",
)
RAW_DOCKER_CONSUMERS = (
    "test-arch-compliance",
    "test-riscv-tests",
    "test-riscv-benchmarks",
    "test-riscv-torture",
)


def _assert_plan_consistent(
    producers: list[dict], consumers: dict
) -> dict[str, list[str]]:
    built = {
        bundle["artifact"]: [m["key"] for m in bundle["models"]] for bundle in producers
    }
    counts = Counter(model for bundle in built.values() for model in bundle)
    if producers:
        assert set(counts.values()) == {1}
    for shards in consumers.values():
        for selection in shards.values():
            assert sorted(selection["shared"]) == sorted(
                model
                for artifact in selection.get("artifacts", [])
                for model in built[artifact]
            )
            assert not counts.keys() & set(selection["local"])
            assert not set(selection["shared"]) & set(selection["local"])
    return built


def test_shared_models_match_the_consumers() -> None:
    """Each requested artifact has one producer across all workflow event scopes."""
    producers, consumers = plan(True, matrix("rotation", 1, "", 20), event="push")
    _assert_plan_consistent(producers, consumers)
    assert set(consumers) == set(CONSUMER_JOBS)
    covered = consumers["test-arch-compliance"]["0"]["shared"]
    plain = consumers["test-arch-compliance"]["1"]["shared"]
    assert len(covered) == len(plain) == 1 and covered != plain
    assert consumers["test-riscv-tests"]["0"]["shared"] == covered
    assert consumers["test-riscv-benchmarks"]["3"]["shared"] == plain
    assert consumers["test-rvv"]["512"]["shared"] == ["rvv-512"]
    assert len(consumers["test-testrig"]["1"]["shared"]) == 1
    assert len(consumers["test-testrig"]["1"]["local"]) == 1
    assert (
        consumers["test-testrig"]["2"]["shared"]
        == consumers["test-testrig"]["4"]["shared"]
        == consumers["test-testrig"]["1"]["shared"]
    )
    assert not consumers["test-testrig"]["3"]["shared"]
    assert len(consumers["test-testrig"]["3"]["local"]) == 1
    for width in ("128", "256", "512"):
        core_entry = consumers["test-testrig-vector"][f"{width}/core"]
        seg_entry = consumers["test-testrig-vector"][f"{width}/segment"]
        ext_entry = consumers["test-testrig-vector"][f"{width}/ext"]
        assert len(core_entry["shared"]) == 1 and not core_entry["local"]
        assert seg_entry == core_entry
        assert ext_entry == core_entry
    assert len(consumers["test-native"]["live"]["shared"]) == 1
    assert len(consumers["test-native"]["live"]["local"]) == 1

    # Manual regular CI omits test-testrig-vector and runs one vector slice.
    manual_producers, manual_consumers = plan(
        True, matrix("rotation", 1, ""), event="workflow_dispatch"
    )
    _assert_plan_consistent(manual_producers, manual_consumers)
    assert "test-testrig-vector" not in manual_consumers
    assert all(not row["shared"] for row in manual_consumers["test-rvv"].values())

    # Manual toggle coverage shares toggle-instrumented models across its 32 shards.
    toggle_producers, toggle_consumers = plan(
        False, [], toggle=True, event="workflow_dispatch"
    )
    _assert_plan_consistent(toggle_producers, toggle_consumers)
    assert set(toggle_consumers) == {"test-verilator"}
    assert len(toggle_consumers["test-verilator"]) == len(
        job_matrix(coverage_only=True)["include"]
    )
    assert toggle_producers

    # Single-slice vector dispatch has zero shared models; complete shares all three.
    single, vector_jobs = plan(
        False, matrix("rotation", 1, "0"), event="workflow_dispatch"
    )
    assert not single and set(vector_jobs) == {"test-rvv"}
    complete, complete_jobs = plan(
        False, matrix("complete", 1, ""), event="workflow_dispatch"
    )
    _assert_plan_consistent(complete, complete_jobs)
    assert {m["vlen"] for b in complete for m in b["models"]} == {128, 256, 512}


def test_every_full_push_cocotb_execution_is_assigned_once() -> None:
    """Every planned cocotb execution maps to one shared or local configuration."""
    workflow = yaml.safe_load(WORKFLOW.read_text())
    jobs = workflow["jobs"]
    producers, consumers = plan(True, matrix("rotation", 1, "", 20), event="push")
    shared_keys = {m["key"] for bundle in producers for m in bundle["models"]}
    assigned = 0
    for job, label, cases in cocotb_jobs(jobs, full=True, toggle=False, event="push"):
        request = consumers[job][label]
        allowed = set(request["shared"]) | set(request["local"])
        assert set(request["shared"]) <= shared_keys
        assert not (set(request["local"]) & shared_keys)
        for config in cases:
            key = models.group(config)
            assert key in allowed, (job, label, key, config)
            assigned += 1
    assert assigned > 0


@pytest.mark.parametrize(
    ("full", "toggle", "event", "vectors_json", "expect_matrix"),
    [
        ("true", "false", "push", None, True),
        ("true", "false", "pull_request", None, True),
        ("true", "false", "workflow_dispatch", None, True),
        ("false", "true", "workflow_dispatch", "", True),
        ("false", "false", "workflow_dispatch", "slice", False),
        ("false", "false", "workflow_dispatch", "complete", True),
    ],
)
def test_planner_cli_outputs_valid_github_step_outputs(
    full: str,
    toggle: str,
    event: str,
    vectors_json: str | None,
    expect_matrix: bool,
) -> None:
    """The build-docker planner CLI produces valid outputs under every trigger."""
    if vectors_json is None:
        rows = matrix("rotation", 1, "", 20 if event == "push" else 1)
        vectors = json.dumps({"include": rows}, separators=(",", ":"))
    elif vectors_json == "slice":
        vectors = json.dumps(
            {"include": matrix("rotation", 1, "0")}, separators=(",", ":")
        )
    elif vectors_json == "complete":
        vectors = json.dumps(
            {"include": matrix("complete", 1, "")}, separators=(",", ":")
        )
    else:
        vectors = vectors_json
    assert parse_vectors(vectors) == (json.loads(vectors)["include"] if vectors else [])
    result = subprocess.run(
        [
            sys.executable,
            str(models.TESTS / "ci_sim_plan.py"),
            "--full",
            full,
            "--toggle",
            toggle,
            "--event",
            event,
            "--vectors",
            vectors,
        ],
        cwd=models.ROOT,
        capture_output=True,
        text=True,
        check=True,
        timeout=60,
    )
    outputs = dict(line.split("=", 1) for line in result.stdout.splitlines())
    assert set(outputs) == {"sim_matrix", "sim_consumers"}
    assert len(outputs["sim_matrix"]) < 1_000_000
    assert len(outputs["sim_consumers"]) < 1_000_000
    sim_matrix = json.loads(outputs["sim_matrix"])
    assert bool(sim_matrix) is expect_matrix
    if expect_matrix:
        assert 1 <= len(sim_matrix["include"]) <= 256


def test_runtime_inputs_and_build_modes(monkeypatch: pytest.MonkeyPatch) -> None:
    """Separate runtime draws from assertion, geometry, visibility and instrumentation modes."""
    monkeypatch.setattr(os, "process_cpu_count", lambda: 8, raising=False)
    env = {
        "FROST_VERILATOR_EXTRA_ARGS": (
            "-GDDR_MODEL_LATENCY=12 --assert -GDDR_MODEL_LATENCY=60"
        ),
        "FROST_RANDOM_START_SEED": "job-a",
    }
    base = models.settings("frost", env)
    assert models.ddr_timing_args(env["FROST_VERILATOR_EXTRA_ARGS"]) == [
        "-GDDR_MODEL_LATENCY=60"
    ]
    assert (
        models.settings(
            "frost",
            {
                **env,
                "FROST_VERILATOR_EXTRA_ARGS": "-GDDR_MODEL_REORDER=0",
                "FROST_RANDOM_START_SEED": "job-b",
                "FROST_COCOTB_MEM_CONFIG": "ddr",
                "FROST_COVERAGE_FILE": "other.dat",
                "FROST_TESTRIG_VECTOR_RESULT_CONTROL": "state",
                "FROST_FULL_VISIBILITY": "0",
                "FROST_HANG_PROBE": "",
                "FROST_RETIRE_TRACE": "0",
                "FROST_VERILATOR_THREADS": "1",
            },
        )
        == base
    )
    assert models.settings("frost", {**env, "FROST_HANG_PROBE": "   "}) == base
    for name, value in (
        ("FROST_VERILATOR_EXTRA_ARGS", "-GDDR_MODEL_LATENCY=32'h10"),
        ("FROST_VERILATOR_EXTRA_ARGS", "--no-assert"),
        ("FROST_VERILATOR_EXTRA_ARGS", "-DMODE=1"),
        ("FROST_VERILATOR_EXTRA_ARGS", "-GENABLE_CACHED_TIER=0"),
        ("FROST_VERILATOR_EXTRA_ARGS", "../verif/cocotb_tests/fatal_stop_irq.vlt"),
        ("FROST_RANDOM_START_SEED", ""),
        ("FROST_CPU_PERIOD_PS", "1500"),
        ("SIM_FAST_MAINT", "0"),
        ("FROST_COVERAGE", "1"),
        ("FROST_COVERAGE_TOGGLE", "1"),
        ("FROST_FULL_VISIBILITY", "1"),
        ("FROST_HANG_PROBE", "1"),
        ("FROST_RETIRE_TRACE", "1"),
        ("FROST_VERILATOR_THREADS", "4"),
        ("WAVES", "1"),
    ):
        assert models.settings("frost", {**env, name: value}) != base, name
    assert models.settings(
        "frost", {**env, "FROST_CPU_PERIOD_PS": "1500"}
    ) == models.settings("frost", {**env, "FROST_CPU_PERIOD_PS": "3000"})
    assert models.settings(
        "frost", {**env, "FROST_HANG_PROBE": "1"}
    ) == models.settings("frost", {**env, "FROST_HANG_PROBE": "hang.log"})
    # Thread count caps at NUMBER_OF_CPU_CORES and collapses to 1 when waves,
    # coverage, full visibility, hang probe, or a unit top is selected.
    assert models.settings(
        "frost", {**env, "FROST_VERILATOR_THREADS": "8", "NUMBER_OF_CPU_CORES": "2"}
    ) == models.settings("frost", {**env, "FROST_VERILATOR_THREADS": "2"})
    assert (
        models.settings(
            "frost", {**env, "FROST_VERILATOR_THREADS": "4", "NUMBER_OF_CPU_CORES": "1"}
        )
        == base
    )
    for single_thread_override in (
        {"WAVES": "1"},
        {"FROST_COVERAGE": "1"},
        {"FROST_FULL_VISIBILITY": "1"},
        {"FROST_HANG_PROBE": "1"},
    ):
        assert models.settings(
            "frost", {**env, **single_thread_override, "FROST_VERILATOR_THREADS": "4"}
        ) == models.settings("frost", {**env, **single_thread_override})
    unit_base = models.settings("cdb_arbiter", {})
    assert (
        models.settings(
            "cdb_arbiter",
            {
                "FROST_FULL_VISIBILITY": "1",
                "FROST_HANG_PROBE": "1",
                "FROST_RETIRE_TRACE": "1",
                "FROST_VERILATOR_THREADS": "4",
            },
        )
        == unit_base
    )


def test_named_parameter_order_matches_at_planning_and_restore() -> None:
    """Share equivalent cache probes while preserving override precedence."""
    options = [
        "-GPERF_COUNTERS=1",
        "-GL1_CACHE_BYTES=4096",
        "-GL2_CACHE_BYTES=4096",
    ]
    reordered = [*options[1:], options[0]]
    assert models.settings(
        "frost", {"FROST_VERILATOR_EXTRA_ARGS": " ".join(options)}
    ) == models.settings("frost", {"FROST_VERILATOR_EXTRA_ARGS": " ".join(reordered)})
    assert models.compile_command(options, "") == models.compile_command(reordered, "")
    assert models.compile_command(["-GA=0", "-GA=1"], "") != models.compile_command(
        ["-GA=1", "-GA=0"], ""
    )
    assert models.ordered_parameters(["-GB=3", "-DA=1", "-GA=2"]) == [
        "-GB=3",
        "-DA=1",
        "-GA=2",
    ]


@pytest.mark.parametrize(
    "change",
    (
        "none",
        "run",
        "image",
        "commit",
        "source",
        "vlt",
        "binary",
        "record",
        "coverage",
        "full_visibility",
        "retire_trace",
        "threads",
        "cxx",
        "missing",
    ),
)
def test_restore_requires_the_matching_build(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, change: str
) -> None:
    """Only the matching compiler invocation and intact inputs can supply Vtop."""
    artifact = tmp_path / "artifact"
    output = tmp_path / "build"
    tests_dir = tmp_path / "tests"
    verif_dir = tmp_path / "verif"
    artifact.mkdir()
    output.mkdir()
    tests_dir.mkdir()
    verif_dir.mkdir()
    (tests_dir / "Makefile").write_text("# makefile\n")
    source = tmp_path / "example.sv"
    source.write_text("module example; endmodule\n")
    vlt = verif_dir / "extra.vlt"
    vlt.write_text("`verilator_config\n")
    binary = artifact / "Vtop"
    binary.write_bytes(b"example simulator")
    record = artifact / "Vtop__verFiles.dat"
    record.write_text(f'S 0 "{source}"\n')
    monkeypatch.setattr(models, "ROOT", tmp_path)
    monkeypatch.setattr(models, "TESTS", tests_dir)
    identity = ["42:image-a", "revision"]
    monkeypatch.setattr(models, "scope", lambda: identity)
    monkeypatch.setenv("FROST_SIM_IMPORT", str(artifact))
    args = [
        "-cc",
        "-Mdir",
        str(output),
        "--assert",
        "-fico-change-detect",
        "+define+FROST_NO_RETIRE_TRACE",
        "-j",
        "4",
        "../verif/extra.vlt",
        str(source),
    ]
    command = models.compile_command(["verilator", *args], "-j4")
    manifest = {
        "scope": identity,
        "command": command,
        "sources": models.source_digest(record, command),
        "files": {
            name: models.checksum(artifact / name) for name in ("Vtop", record.name)
        },
    }
    (artifact / "manifest.json").write_text(json.dumps(manifest))
    if change == "run":
        identity[0] = "43:image-a"
    elif change == "image":
        identity[0] = "42:image-b"
    elif change == "commit":
        identity[1] = "other revision"
    elif change == "source":
        source.write_text("module changed; endmodule\n")
    elif change == "vlt":
        vlt.write_text("`verilator_config\n// modified\n")
    elif change == "binary":
        binary.write_bytes(b"incomplete executable")
    elif change == "record":
        record.write_text("")
    elif change == "coverage":
        args.append("--coverage-line")
    elif change == "full_visibility":
        args.remove("-fico-change-detect")
        args.append("--public-flat-rw")
    elif change == "retire_trace":
        args.remove("+define+FROST_NO_RETIRE_TRACE")
    elif change == "threads":
        args.extend(["--threads", "2", "-Wno-UNOPTTHREADS"])
    elif change == "cxx":
        monkeypatch.setenv("CXXFLAGS", "-g")
    elif change == "missing":
        binary.unlink()
    if change != "none":
        with pytest.raises((FileNotFoundError, ValueError)):
            models.verilate("verilator", "-j16", args)
        assert not (output / "Vtop.mk").exists()
    else:
        models.verilate("verilator", "-j16", args)
        subprocess.run(["make", "-f", "Vtop.mk"], cwd=output, check=True)
        assert (output / "Vtop").read_bytes() == binary.read_bytes()
        assert (output / "Vtop").stat().st_mode & 0o111
        assert (output / record.name).read_bytes() == record.read_bytes()


def test_workflow_consumers_do_not_skip_when_shared_build_fails() -> None:
    """When build-sim-models fails, every consumer runs and reaches its Fetch check."""
    workflow = yaml.safe_load(WORKFLOW.read_text())
    jobs = workflow["jobs"]
    producer = jobs["build-sim-models"]
    assert producer["strategy"]["fail-fast"] is False
    upload = next(
        s
        for s in producer["steps"]
        if s.get("uses", "").startswith("actions/upload-artifact@")
    )
    assert upload["with"]["if-no-files-found"] == "error"

    base_context = {
        "github.event_name": "push",
        "inputs.toggle_coverage": "false",
        "needs.gate.outputs.full": "true",
        "needs.build-docker.result": "success",
        "needs.build-docker.outputs.verilator_matrix": "planned",
        "needs.build-sim-models.result": "failure",
    }
    for name in CONSUMER_JOBS:
        job = jobs[name]
        deps = job.get("needs", [])
        dep_list = [deps] if isinstance(deps, str) else deps
        assert "build-sim-models" in dep_list, name
        assert job.get("permissions", {}).get("actions") == "read", name
        guard = job["if"]
        assert "!cancelled()" in guard, name
        assert "needs.build-sim-models" not in guard, name
        assert job_condition(guard, base_context), (
            f"{name} must run (not skip silently) when build-sim-models fails"
        )
        assert not job_condition(
            guard, {**base_context, "needs.build-docker.result": "failure"}
        ), f"{name} must not run when build-docker fails"
        fetch_indices = [
            i
            for i, step in enumerate(job["steps"])
            if step.get("uses") == "./.github/actions/sim-models"
        ]
        assert len(fetch_indices) == 1, name
        assert fetch_indices[0] < len(job["steps"]) - 1, name
        if name in RAW_DOCKER_CONSUMERS:
            run_steps = [
                step.get("run", "")
                for step in job["steps"][fetch_indices[0] + 1 :]
                if "docker run " in step.get("run", "")
                and "coverage_report.py" not in step.get("run", "")
            ]
            assert run_steps, name
            for script in run_steps:
                assert "-e FROST_SIM_MODELS -e FROST_SIM_SCOPE" in script, name

    # Manual toggle coverage also runs test-verilator when build-sim-models fails.
    toggle_context = {
        "github.event_name": "workflow_dispatch",
        "inputs.toggle_coverage": "true",
        "needs.gate.outputs.full": "",
        "needs.build-docker.result": "success",
        "needs.build-docker.outputs.verilator_matrix": "planned",
        "needs.build-sim-models.result": "failure",
    }
    assert job_condition(jobs["test-verilator"]["if"], toggle_context)


@pytest.mark.parametrize(
    "failure_mode",
    (
        "download_failed",
        "null_selection",
        "missing_manifest",
        "wrong_scope",
        "missing_vtop",
        "missing_verfiles",
        "rvv_missing_binary",
        "rvv_bad_checksum",
        "rvv_wrong_vlen",
    ),
)
def test_receive_and_select_fail_visibly_on_missing_or_corrupt_build(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, failure_mode: str
) -> None:
    """Missing, failed, or incompatible artifacts fail visibly with no silent skip."""
    store = tmp_path / ".ci-sim-models"
    monkeypatch.setattr(models, "STORE", store)
    monkeypatch.setenv("GITHUB_RUN_ID", "999")
    identity = ["999:sha256:img", "deadbeef"]
    monkeypatch.setattr(models, "scope", lambda: identity)
    models.selection.cache_clear()

    if failure_mode == "null_selection":
        with pytest.raises(ValueError, match="missing simulator selection"):
            models.receive(None)  # type: ignore[arg-type]
        assert not (store / "selection.json").exists()
        return

    if failure_mode == "download_failed":

        def fail_download(cmd: list[str], **kwargs: object) -> None:
            raise subprocess.CalledProcessError(1, cmd, stderr="artifact not found")

        monkeypatch.setattr(models.subprocess, "run", fail_download)
        with pytest.raises(subprocess.CalledProcessError):
            models.receive(
                {
                    "artifacts": ["sim-deadbeef"],
                    "shared": ["deadbeef"],
                    "local": [],
                }
            )
        assert not (store / "selection.json").exists()
        return

    is_rvv = failure_mode.startswith("rvv_")
    key = "rvv-128" if is_rvv else "abcd1234abcd1234abcd1234"

    def fake_download(cmd: list[str], **kwargs: object) -> subprocess.CompletedProcess:
        dest = Path(cmd[cmd.index("--dir") + 1]) / key
        dest.mkdir(parents=True, exist_ok=True)
        if failure_mode == "missing_manifest":
            return subprocess.CompletedProcess(cmd, 0)
        if is_rvv:
            binary = dest / "frost-native"
            meta = dest / "frost-native.json"
            binary.write_bytes(b"native-bin")
            meta.write_text("{}")
            record = {
                "scope": identity,
                "vlen": 256 if failure_mode == "rvv_wrong_vlen" else 128,
                "threads": 4,
                "files": {
                    "frost-native": models.checksum(binary),
                    "frost-native.json": models.checksum(meta),
                },
            }
            (dest / "manifest.json").write_text(json.dumps(record))
            if failure_mode == "rvv_missing_binary":
                binary.unlink()
            elif failure_mode == "rvv_bad_checksum":
                binary.write_bytes(b"corrupted")
        else:
            vtop = dest / "Vtop"
            verfiles = dest / "Vtop__verFiles.dat"
            vtop.write_bytes(b"vtop-bin")
            verfiles.write_text("")
            record = {
                "scope": ["other:img", "deadbeef"]
                if failure_mode == "wrong_scope"
                else identity,
                "files": {
                    "Vtop": models.checksum(vtop),
                    "Vtop__verFiles.dat": models.checksum(verfiles),
                },
            }
            (dest / "manifest.json").write_text(json.dumps(record))
            if failure_mode == "missing_vtop":
                vtop.unlink()
            elif failure_mode == "missing_verfiles":
                verfiles.unlink()
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(models.subprocess, "run", fake_download)
    with pytest.raises((FileNotFoundError, ValueError)):
        models.receive({"artifacts": [f"sim-{key}"], "shared": [key], "local": []})
    assert not (store / "selection.json").exists()


def test_select_model_fails_visibly_when_selection_missing_or_unplanned(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A consumer with FROST_SIM_MODELS=1 cannot silently rebuild an unplanned model."""
    store = tmp_path / ".ci-sim-models"
    monkeypatch.setattr(models, "STORE", store)
    models.selection.cache_clear()

    # Missing selection.json fails visibly.
    with pytest.raises(FileNotFoundError):
        models.select_model("frost", {})

    # Local-only receive needs no gh download and allows only its planned local key.
    def forbid_gh(*args: object, **kwargs: object) -> None:
        pytest.fail("local-only consumer must not invoke gh run download")

    monkeypatch.setattr(models.subprocess, "run", forbid_gh)
    local_env = {"FROST_RANDOM_START": "1"}
    local_key = models.group(models.settings("frost", local_env))
    models.receive({"shared": [], "local": [local_key]})
    models.selection.cache_clear()

    env = dict(local_env)
    models.select_model("frost", env)
    assert "FROST_SIM_IMPORT" not in env

    # An unplanned configuration raises ValueError instead of rebuilding silently.
    with pytest.raises(ValueError, match="unplanned simulator configuration"):
        models.select_model("frost", {**local_env, "FROST_COVERAGE": "1"})
    models.selection.cache_clear()


def _workflow_job_threads(job: dict) -> str:
    """Read FROST_VERILATOR_THREADS from a CI job's job-level or step env."""
    candidates = [
        job.get("env", {}),
        *(step.get("env", {}) for step in job.get("steps", [])),
    ]
    values = [
        str(env_map["FROST_VERILATOR_THREADS"])
        for env_map in candidates
        if isinstance(env_map, dict) and "FROST_VERILATOR_THREADS" in env_map
    ]
    assert values and len(set(values)) == 1, values
    return values[0]


def _workflow_runtime_cases(
    jobs: dict, *, full: bool, toggle: bool, event: str
) -> Iterator[tuple[str, str, list[tuple[CocotbRunConfig, dict[str, str]]]]]:
    """Build each CI job's actual runtime environment from .github/workflows/ci.yml."""
    if full or toggle:
        threads = _workflow_job_threads(jobs["test-verilator"])
        for index, row in enumerate(expand_matrix(job_matrix(coverage_only=toggle))):
            tier, shard = row["mem_config"], row["shard"]
            unit = shard["name"].startswith("Unit Tests")
            covered = tier in shard["coverage"]
            env = {
                "FROST_COCOTB_MEM_CONFIG": tier,
                "FROST_REQUIRE_OPENOCD": "1",
                "FROST_DDR_MODEL_SEED": f"999-test-verilator-{index}",
                "FROST_STARTUP_SWEEP": "0" if unit else "1",
                "FROST_STARTUP_SEED_BASE": f"999-test-verilator-{index}",
                "FROST_RANDOM_START_SEED": ""
                if unit
                else f"999-test-verilator-{index}",
                "FROST_COVERAGE": str(int(covered)),
                "FROST_COVERAGE_TOGGLE": str(int(unit or (toggle and covered))),
                "FROST_VERILATOR_THREADS": threads,
            }
            yield (
                "test-verilator",
                f"{tier}/{shard['name']}",
                [(TEST_REGISTRY[name], env) for name in registry_tests(row)],
            )
    if not full:
        return
    pa_threads = _workflow_job_threads(jobs["test-pa-width"])
    for index, row in enumerate(
        expand_matrix(jobs["test-pa-width"]["strategy"]["matrix"])
    ):
        capacity, shard = row["capacity_gib"], row["shard"]
        unit = shard["name"] == "Unit boundaries"
        env = {
            "SIM_FAST_MAINT": str(int((capacity, shard["name"]) != (1, "Bare access"))),
            "FROST_COVERAGE": str(int(capacity in shard["coverage"])),
            "FROST_VERILATOR_THREADS": pa_threads,
            "FROST_DDR_MODEL_SEED": f"999-test-pa-width-{index}",
            "FROST_STARTUP_SWEEP": "0" if unit else "1",
            "FROST_STARTUP_SEED_BASE": f"999-test-pa-width-{index}",
            "FROST_RANDOM_START_SEED": "" if unit else f"999-test-pa-width-{index}",
        }
        yield (
            "test-pa-width",
            f"{capacity}/{shard['name']}",
            [(TEST_REGISTRY[name], env) for name in aperture_tests(capacity, shard)],
        )
    default = CocotbRunConfig("cocotb_tests.test_real_program", "frost")
    for job_name in RAW_DOCKER_CONSUMERS:
        threads = _workflow_job_threads(jobs[job_name])
        for index, row in enumerate(
            expand_matrix(jobs[job_name]["strategy"]["matrix"])
        ):
            env = {
                "FROST_DDR_MODEL_SEED": f"999-{job_name}-{index}",
                "FROST_RANDOM_START_SEED": f"999-{job_name}-{index}",
                "FROST_VERILATOR_THREADS": threads,
            }
            if "coverage" in row:
                env["FROST_COVERAGE"] = str(row["coverage"])
            yield job_name, str(index), [(default, env)]
    tr_threads = _workflow_job_threads(jobs["test-testrig"])
    for index, row in enumerate(
        expand_matrix(jobs["test-testrig"]["strategy"]["matrix"])
    ):
        env = {
            "FROST_STARTUP_SWEEP": "1",
            "FROST_STARTUP_SEED_BASE": f"999-test-testrig-{index}",
            "FROST_DDR_MODEL_SEED": f"999-test-testrig-{index}",
            "FROST_RANDOM_START_SEED": f"999-test-testrig-{index}",
            "FROST_COVERAGE": str(row["coverage"]),
            "FROST_VERILATOR_THREADS": tr_threads,
        }
        cases: list[tuple[CocotbRunConfig, dict[str, str]]] = [
            (simulator_config(DEFAULT_DDR_CAPACITY_LOG2_BYTES, None), env)
        ]
        if row["shard"] == 1:
            cases.append(
                (
                    simulator_config(
                        DEFAULT_DDR_CAPACITY_LOG2_BYTES,
                        None,
                        wfi_timeout_cycles=wfi.DUT_TIMEOUT_CYCLES,
                    ),
                    {**env, "FROST_STARTUP_SWEEP": "0"},
                )
            )
        yield "test-testrig", str(row["shard"]), cases
    if event in ("push", "pull_request"):
        vec_threads = _workflow_job_threads(jobs["test-testrig-vector"])
        shard_controls = {
            "core": ("state",),
            "segment": ("segment", "segment-matrix"),
            "ext": ("zvfhmin", "zvbb", "zvbc-zvkned-zvkg", "zvknhb"),
        }
        for row in expand_matrix(jobs["test-testrig-vector"]["strategy"]["matrix"]):
            shard = row["shard"]
            controls = shard_controls[shard]
            env = {
                "FROST_DDR_MODEL_SEED": "testrig-vector",
                "FROST_RANDOM_START_SEED": "testrig-vector",
                "COCOTB_RANDOM_SEED": "42",
                "FROST_VERILATOR_THREADS": vec_threads,
            }
            cases = [
                (simulator_config(DEFAULT_DDR_CAPACITY_LOG2_BYTES, row["vlen"]), env)
            ]
            if row["vlen"] == 128:
                for selector in controls:
                    cases.append(
                        (
                            simulator_config(
                                DEFAULT_DDR_CAPACITY_LOG2_BYTES, row["vlen"]
                            ),
                            {**env, "FROST_TESTRIG_VECTOR_RESULT_CONTROL": selector},
                        )
                    )
            yield "test-testrig-vector", f"{row['vlen']}/{shard}", cases
    native_threads = _workflow_job_threads(jobs["test-native"])
    native_env = {"FROST_VERILATOR_THREADS": native_threads}
    stripped_native_env = {
        k: v for k, v in native_env.items() if k not in UNSEEDED_COCOTB_STRIP_ENV
    }
    yield (
        "test-native",
        "live",
        [
            (TEST_REGISTRY["hello_world"], native_env),
            (TEST_REGISTRY["hello_world"], stripped_native_env),
            (TEST_REGISTRY["coremark"], stripped_native_env),
        ],
    )


@pytest.mark.parametrize(
    ("full", "toggle", "event"),
    [
        (True, False, "push"),
        (True, False, "pull_request"),
        (False, True, "workflow_dispatch"),
    ],
)
def test_plan_and_job_keys_match_for_every_ci_job(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    full: bool,
    toggle: bool,
    event: str,
) -> None:
    """Every CI job's runtime env produces the exact key planned by ci_sim_plan.py."""
    workflow = yaml.safe_load(WORKFLOW.read_text())
    jobs = workflow["jobs"]
    store = tmp_path / ".ci-sim-models"
    store.mkdir()
    monkeypatch.setattr(models, "STORE", store)
    monkeypatch.setattr(os, "process_cpu_count", lambda: 8, raising=False)

    _, consumers = plan(full, [], toggle=toggle, event=event)
    planned = {
        (job, label): [models.group(cfg) for cfg in cases]
        for job, label, cases in cocotb_jobs(
            jobs, full=full, toggle=toggle, event=event
        )
    }
    seen: set[tuple[str, str]] = set()
    checked_cases = 0
    for job, label, runtime_cases in _workflow_runtime_cases(
        jobs, full=full, toggle=toggle, event=event
    ):
        seen.add((job, label))
        selection = consumers[job][label]
        (store / "selection.json").write_text(json.dumps(selection))
        models.selection.cache_clear()
        plan_keys = planned[(job, label)]
        job_keys = [models.group(config_for(test, env)) for test, env in runtime_cases]
        assert set(job_keys) == set(plan_keys), (job, label, job_keys, plan_keys)
        if len(job_keys) == len(plan_keys):
            assert job_keys == plan_keys, (job, label)
        for test, env in runtime_cases:
            run_env = {**env, **dict(test.extra_env)}
            run_env["FROST_VERILATOR_EXTRA_ARGS"] = " ".join(
                (
                    *test.verilator_extra_args,
                    run_env.get("FROST_VERILATOR_EXTRA_ARGS", ""),
                )
            ).strip()
            models.select_model(test.hdl_toplevel_module, run_env)
            key = models.group(models.settings(test.hdl_toplevel_module, run_env))
            if key in selection["shared"]:
                assert run_env["FROST_SIM_IMPORT"] == str(store / key)
            else:
                assert key in selection["local"]
                assert "FROST_SIM_IMPORT" not in run_env
            checked_cases += 1
    assert seen == set(planned)
    assert checked_cases > 0

    # Non-default visibility, retire-trace, hang-probe, or thread overrides
    # on a selective frost job must fail visibly as unplanned configurations.
    if full:
        plain_selection = consumers["test-arch-compliance"]["1"]
        (store / "selection.json").write_text(json.dumps(plain_selection))
        models.selection.cache_clear()
        base_env = {
            "FROST_RANDOM_START_SEED": "999-test-arch-compliance-1",
            "FROST_COVERAGE": "0",
            "FROST_VERILATOR_THREADS": "1",
        }
        models.select_model("frost", dict(base_env))
        for override in (
            {"FROST_FULL_VISIBILITY": "1"},
            {"FROST_HANG_PROBE": "1"},
            {"FROST_RETIRE_TRACE": "1"},
            {"FROST_VERILATOR_THREADS": "2", "NUMBER_OF_CPU_CORES": "2"},
        ):
            with pytest.raises(ValueError, match="unplanned simulator configuration"):
                models.select_model("frost", {**base_env, **override})
    models.selection.cache_clear()


# Variables referenced in tests/Makefile's Verilator-configuration lines that
# are handled separately in ci_sim_models.py or do not affect the compiled Vtop.
_NON_KEY_MAKEFILE_FROST_VARS = frozenset(
    {
        "FROST_COVERAGE_FILE",
        "FROST_DDR_TIMING_ARGS",
        "FROST_NO_RETIRE_TRACE",
        "FROST_RANDOM_START",
        "FROST_RANDOM_START_VERILATOR_SEED",
        "FROST_RUNTIME_DDR",
        "FROST_SELECTIVE_VISIBILITY",
        "FROST_SIM_ASSERTIONS",
        "FROST_SIM_EXPORT",
        "FROST_SIM_IMPORT",
        "FROST_SRAM_MACROS",
        "FROST_VERILATOR_EXTRA_ARGS",
        "FROST_VISIBILITY_CONFIG",
    }
)

_MAKEFILE_BUILD_KNOB_PROBES: tuple[tuple[str, dict[str, str], dict[str, str]], ...] = (
    ("WAVES", {}, {"WAVES": "1"}),
    ("FROST_COVERAGE", {}, {"FROST_COVERAGE": "1"}),
    (
        "FROST_COVERAGE_TOGGLE",
        {"FROST_COVERAGE": "1"},
        {"FROST_COVERAGE": "1", "FROST_COVERAGE_TOGGLE": "1"},
    ),
    ("FROST_FULL_VISIBILITY", {}, {"FROST_FULL_VISIBILITY": "1"}),
    ("FROST_HANG_PROBE", {}, {"FROST_HANG_PROBE": "1"}),
    ("FROST_RETIRE_TRACE", {}, {"FROST_RETIRE_TRACE": "1"}),
    (
        "FROST_VERILATOR_THREADS",
        {"NUMBER_OF_CPU_CORES": "2"},
        {"NUMBER_OF_CPU_CORES": "2", "FROST_VERILATOR_THREADS": "2"},
    ),
    ("SIM_MEM_SIZE_BYTES", {}, {"SIM_MEM_SIZE_BYTES": "131072"}),
    ("FROST_CPU_PERIOD_PS", {}, {"FROST_CPU_PERIOD_PS": "1500"}),
    ("ENABLE_CACHED_TIER", {}, {"ENABLE_CACHED_TIER": "0"}),
    ("DDR_MODEL_BYTES", {}, {"DDR_MODEL_BYTES": "33554432"}),
    ("DDR_MODEL_LATENCY", {}, {"DDR_MODEL_LATENCY": "40"}),
    ("SIM_FAST_MAINT", {}, {"SIM_FAST_MAINT": "0"}),
    ("MEMORY_LINK_STAGES", {}, {"MEMORY_LINK_STAGES": "1"}),
    ("MISALIGNED_HW", {}, {"MISALIGNED_HW": "0"}),
)


def _verilator_stub_args(tmp_path: Path) -> list[str]:
    """Use the host Verilator if it supports -fico-change-detect, else a stub."""
    verilator = shutil.which("verilator")
    if verilator is not None:
        probe = subprocess.run(
            [verilator, "-E", "-fico-change-detect", "/dev/null"],
            capture_output=True,
            timeout=15,
        )
        if probe.returncode == 0:
            return []
    stub_dir = tmp_path / "verilator_stub"
    stub_dir.mkdir(exist_ok=True)
    stub = stub_dir / "verilator"
    if not stub.exists():
        stub.write_text(
            "#!/usr/bin/env bash\n"
            'if [[ "$1" == "--version" ]]; then echo "Verilator 5.054"; exit 0; fi\n'
            "exit 0\n",
            encoding="utf-8",
        )
        stub.chmod(0o755)
    return [f"VERILATOR_BIN_DIR={stub_dir}"]


def _makefile_compile_command(tmp_path: Path, env_overrides: dict[str, str]) -> dict:
    """Return models.compile_command() for the Verilator line tests/Makefile emits."""
    build = tmp_path / "sim_build"
    build.mkdir(exist_ok=True)
    env = {
        key: value
        for key, value in os.environ.items()
        if key not in models.MAKEFILE_BUILD_VARIABLES
        and key
        not in (
            "FROST_FULL_VISIBILITY",
            "FROST_HANG_PROBE",
            "FROST_RETIRE_TRACE",
            "FROST_VERILATOR_THREADS",
            "FROST_RANDOM_START",
            "FROST_RANDOM_START_SEED",
            "FROST_DDR_TIMING_ARGS",
            "FROST_SIM_EXPORT",
            "FROST_SIM_IMPORT",
            "FROST_VERILATOR_EXTRA_ARGS",
            "NUMBER_OF_CPU_CORES",
        )
    }
    env["NUMBER_OF_CPU_CORES"] = env_overrides.get("NUMBER_OF_CPU_CORES", "4")
    env.update(env_overrides)
    result = subprocess.run(
        [
            "make",
            "--no-print-directory",
            "-f",
            str(models.TESTS / "Makefile"),
            f"ROOT={models.ROOT}",
            "TOPLEVEL=frost",
            f"SIM_BUILD={build}",
            *_verilator_stub_args(tmp_path),
            f"{build}/Vtop.mk",
            "-n",
        ],
        cwd=tmp_path,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    line = next(raw for raw in result.stdout.splitlines() if " -cc --exe " in raw)
    return models.compile_command(shlex.split(line), "")


def _assert_makefile_frost_vars_covered() -> None:
    """Fail if tests/Makefile reads any FROST_* build knob missing from MAKEFILE_BUILD_VARIABLES."""
    makefile_text = (models.TESTS / "Makefile").read_text(encoding="utf-8")
    referenced = {
        match.group(1)
        for line in makefile_text.splitlines()
        if not line.lstrip().startswith("#")
        for match in re.finditer(r"\$\((FROST_[A-Z0-9_]+)\)", line)
    }
    referenced.update(
        match.group(1)
        for line in makefile_text.splitlines()
        if not line.lstrip().startswith("#")
        for match in re.finditer(r"^(FROST_[A-Z0-9_]+)\s*\?=", line)
    )
    missing = (
        referenced - set(models.MAKEFILE_BUILD_VARIABLES) - _NON_KEY_MAKEFILE_FROST_VARS
    )
    assert not missing, (
        f"tests/Makefile uses FROST_* variables missing from "
        f"ci_sim_models.MAKEFILE_BUILD_VARIABLES: {sorted(missing)}"
    )


def _assert_knob_tracked_by_settings(
    name: str,
    base_env: dict[str, str],
    toggled_env: dict[str, str],
    base_cmd: dict,
    toggled_cmd: dict,
) -> None:
    """Fail if a knob changes tests/Makefile's Verilator command without changing settings()."""
    assert toggled_cmd != base_cmd, (
        f"{name} did not change tests/Makefile's Verilator compile_command"
    )
    assert name in models.MAKEFILE_BUILD_VARIABLES, (
        f"{name} changes the Verilator build but is missing from MAKEFILE_BUILD_VARIABLES"
    )
    assert models.group(models.settings("frost", toggled_env)) != models.group(
        models.settings("frost", base_env)
    ), f"{name} changes the Verilator build but not ci_sim_models.settings()"


def test_makefile_build_variables_cover_every_verilator_build_knob(
    tmp_path: Path,
) -> None:
    """Every tests/Makefile Verilator build knob is in MAKEFILE_BUILD_VARIABLES and changes the key."""
    _assert_makefile_frost_vars_covered()
    assert {name for name, _, _ in _MAKEFILE_BUILD_KNOB_PROBES} == set(
        models.MAKEFILE_BUILD_VARIABLES
    )
    if shutil.which("cocotb-config") is None:
        pytest.skip("cocotb-config is not on PATH")
    process_cpus = getattr(os, "process_cpu_count", None)
    available_cpus = (
        process_cpus() if process_cpus is not None else len(os.sched_getaffinity(0))
    ) or 1
    for name, base_env, toggled_env in _MAKEFILE_BUILD_KNOB_PROBES:
        if name == "FROST_VERILATOR_THREADS" and available_cpus < 2:
            continue
        base_cmd = _makefile_compile_command(tmp_path, base_env)
        toggled_cmd = _makefile_compile_command(tmp_path, toggled_env)
        _assert_knob_tracked_by_settings(
            name, base_env, toggled_env, base_cmd, toggled_cmd
        )


@pytest.mark.parametrize(
    "omitted",
    (
        "FROST_FULL_VISIBILITY",
        "FROST_HANG_PROBE",
        "FROST_RETIRE_TRACE",
        "FROST_VERILATOR_THREADS",
        "WAVES",
        "FROST_COVERAGE",
        "SIM_FAST_MAINT",
    ),
)
def test_missing_build_variable_fails_makefile_consistency_check(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, omitted: str
) -> None:
    """Dropping any build variable from MAKEFILE_BUILD_VARIABLES fails the consistency check."""
    monkeypatch.setattr(os, "process_cpu_count", lambda: 8, raising=False)
    _, base_env, toggled_env = next(
        probe for probe in _MAKEFILE_BUILD_KNOB_PROBES if probe[0] == omitted
    )
    if shutil.which("cocotb-config") is not None:
        # Note: make runs in a subprocess using real host affinity, not monkeypatched os.
        real_cpus = len(os.sched_getaffinity(0)) or 1
        if omitted == "FROST_VERILATOR_THREADS" and real_cpus < 2:
            base_cmd = {"verilator": ["verilator", "-cc"]}
            toggled_cmd = {"verilator": ["verilator", "-cc", "--threads", "2"]}
        else:
            base_cmd = _makefile_compile_command(tmp_path, base_env)
            toggled_cmd = _makefile_compile_command(tmp_path, toggled_env)
    else:
        base_cmd = {"verilator": ["verilator", "-cc"]}
        toggled_cmd = {"verilator": ["verilator", "-cc", f"--probe-{omitted}"]}

    # With the full tuple, the check passes.
    _assert_knob_tracked_by_settings(
        omitted, base_env, toggled_env, base_cmd, toggled_cmd
    )

    # Removing the variable from MAKEFILE_BUILD_VARIABLES makes settings()
    # collide with the base build and fails both checks.
    monkeypatch.setattr(
        models,
        "MAKEFILE_BUILD_VARIABLES",
        tuple(var for var in models.MAKEFILE_BUILD_VARIABLES if var != omitted),
    )
    assert models.group(models.settings("frost", toggled_env)) == models.group(
        models.settings("frost", base_env)
    )
    with pytest.raises(AssertionError):
        _assert_knob_tracked_by_settings(
            omitted, base_env, toggled_env, base_cmd, toggled_cmd
        )
    if omitted.startswith("FROST_"):
        with pytest.raises(AssertionError, match=omitted):
            _assert_makefile_frost_vars_covered()
