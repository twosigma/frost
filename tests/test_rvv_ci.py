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

import hashlib
import json
import os
import subprocess
from collections import Counter
from pathlib import Path

import pytest
import yaml  # type: ignore[import-untyped]

import rvv_ci as ci
import rvv_simulator
import test_riscv_vector_tests as suite

ROOT = Path(__file__).resolve().parents[1]


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
    assert set(job["needs"]) == {"gate", "build-docker"}
    assert "needs.gate.outputs.full == 'true'" in job["if"]
    assert job["strategy"]["fail-fast"] is False
    assert "needs.build-docker.outputs.rvv_matrix" in job["strategy"]["matrix"]
    assert (
        jobs["build-docker"]["outputs"]["rvv_matrix"]
        == "${{ steps.rvv.outputs.matrix }}"
    )
    step = next(s for s in jobs["build-docker"]["steps"] if s.get("id") == "rvv")
    for event, part in [("rotation", ""), ("rotation", "0"), ("complete", "")]:
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
                "SLICE": part,
                "CAMPAIGN": event,
            },
        )
        key, data = output.read_text().strip().split("=", 1)
        assert key == "matrix"
        rows = json.loads(data)["include"]
        if event == "complete":
            assert len(rows) == 20
            assert {r["mode"] for r in rows} == {"complete"}
            assert Counter(r["vlen"] for r in rows) == {128: 3, 256: 3, 512: 14}
        else:
            assert [r["vlen"] for r in rows] == [128, 256, 512]
            assert {r["part"] for r in rows} == {part or "19"}
    run = next(s for s in job["steps"] if s.get("name") == "Run vector programs")
    assert 'tests/rvv_ci.py run "$VLEN" "$MODE" "$PART"' in run["run"]
    assert run["env"] == {
        "VLEN": "${{ matrix.vlen }}",
        "MODE": "${{ matrix.mode }}",
        "PART": "${{ matrix.part }}",
    }
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

    def simulate(command: list[str]) -> subprocess.CompletedProcess:
        if "--build-sim" in command:
            path = Path(command[command.index("--build-sim") + 1])
            path.parent.mkdir()
            Path(f"{path}.json").write_text("{}")
        else:
            assert "--prebuilt-sim" in command and "--one-per-form" in command
            assert command[command.index("--shard") + 1] == "1/20"
            workdir = Path(command[command.index("--workdir") + 1])
            (workdir / "Makefrag").write_text("tests =\n" + "\n".join(names))
            rows = [result(names[0]), {**result(names[1]), "assertions_armed": False}]
            dest = Path(command[command.index("--results-jsonl") + 1])
            dest.write_text("".join(json.dumps(r) + "\n" for r in rows))
        return subprocess.CompletedProcess(command, 0)

    monkeypatch.setattr(subprocess, "run", simulate)
    assert ci.run_shard(128, "slice", "0", tmp_path, None) == 1
    summary = (tmp_path / "summary.md").read_text()
    assert "VLEN 128, slice 0" in summary and "2 selected, 2 ran, 1 failed" in summary
    assert "FROST_DDR_MODEL_SEED=rvv-42 ./scripts/frost.py run" in summary
    assert "--vlen 128 --test vsub_vx-2" in summary


@suite.needs_suite
def test_campaign_evidence(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """The complete union includes all checked models and rejects lost evidence."""
    monkeypatch.setattr(ci, "COMPLETE_SHARDS", {128: 2})
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
