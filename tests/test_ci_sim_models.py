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
import json
from pathlib import Path
import subprocess
import sys

import pytest
import yaml  # type: ignore[import-untyped]

import ci_sim_models as models
from ci_sim_plan import cocotb_jobs, parse_vectors, plan
from ci_verilator import job_matrix
from rvv_ci import matrix
from test_rvv_ci import job_condition

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
        entry = consumers["test-testrig-vector"][width]
        assert not entry["shared"] and len(entry["local"]) == 1
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


def test_runtime_inputs_and_build_modes() -> None:
    """Separate runtime draws from assertion, geometry and instrumentation modes."""
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
            },
        )
        == base
    )
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
        ("WAVES", "1"),
    ):
        assert models.settings("frost", {**env, name: value}) != base, name
    assert models.settings(
        "frost", {**env, "FROST_CPU_PERIOD_PS": "1500"}
    ) == models.settings("frost", {**env, "FROST_CPU_PERIOD_PS": "3000"})


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
