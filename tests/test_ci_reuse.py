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

"""Check the formal and synthesis reuse keys, markers and CI planning."""

import io
import json
import re
import os
import shutil
import subprocess
import tarfile
from contextlib import contextmanager
from pathlib import Path
from typing import Any
from collections.abc import Iterator

import pytest
import yaml  # type: ignore[import-untyped]

import ci_reuse
import sby_config
import test_run_formal
import test_run_yosys

ROOT = Path(__file__).resolve().parents[1]
TOOLS = "image-test"


class Capsys:
    """A stand-in for pytest's capsys fixture when calling a test directly."""

    @contextmanager
    def disabled(self) -> Iterator[None]:
        """Do nothing."""
        yield


# ---------------------------------------------------------------------------
# Every formal task and the synthesis check have complete keys
# ---------------------------------------------------------------------------


def test_every_formal_task_has_a_key() -> None:
    """Every registered task has a key, and the registry matches pytest's."""
    registry = ci_reuse.FormalRegistry(ROOT)
    expected = {
        f"{target.name}_{task}"
        for target in test_run_formal.FORMAL_TARGETS
        for task, _ in test_run_formal.SBY_TASKS
        if task in target.tasks
    }
    assert set(registry.tasks) == expected
    assert set(registry.define_inputs) == {
        f"{task.target}:{task.task}" for task in registry.tasks.values()
    }
    cache = ci_reuse.FileCache()
    keys = set()
    for test_id, task in registry.tasks.items():
        target = next(
            t for t in test_run_formal.FORMAL_TARGETS if t.name == task.target
        )
        assert target.sby_file == task.sby_file
        assert registry.timeout(task) == test_run_formal.formal_task_timeout_s(
            task.target, task.task
        )
        keys.add(ci_reuse.formal_task_key(ROOT, test_id, TOOLS, registry, cache))
    assert len(keys) == len(registry.tasks)


def test_synthesis_key_covers_the_script_sources(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The synthesis key holds every file the Yosys script reads."""
    monkeypatch.setattr(test_run_yosys.YosysRunner, "setup_sw_mem", lambda self: None)
    monkeypatch.setattr(
        test_run_yosys.YosysRunner,
        "convert_nic_sources",
        lambda self, files, directory, defines, timeout: files,
    )
    monkeypatch.delenv("FROST_DDR_CAPACITY_LOG2_BYTES", raising=False)
    monkeypatch.delenv("FROST_ASYNC_CPU_CLOCK", raising=False)

    def yosys(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(command, 0, "End of script", "")

    monkeypatch.setattr(subprocess, "run", yosys)
    for target_name, synth_command, _ in test_run_yosys.SYNTHESIS_TARGETS:
        runner = test_run_yosys.YosysRunner()
        sources = runner.parse_filelist(runner.filelist)
        seen: dict[str, Any] = {}

        def hook(script: str, temp_dir: Path, timeout: int, after: bool) -> None:
            seen["key"] = ci_reuse.synthesis_key(
                ROOT, target_name, script, ROOT / "tests", temp_dir, timeout, TOOLS
            )
            seen["script"] = script

        runner.run_synthesis(synth_command=synth_command, reuse_hook=hook)
        assert seen["key"]
        for source in sources:
            assert f" {source}\n" in seen["script"] + "\n"


# ---------------------------------------------------------------------------
# Formal key sensitivity
# ---------------------------------------------------------------------------

TRAP_PROOF = ROOT / "formal/trap_unit.sby"
TRAP_FILES = tuple(
    path.resolve().relative_to(ROOT).as_posix()
    for path in sby_config.proof_inputs(TRAP_PROOF)[1:]
)


def formal_tree(root: Path) -> Path:
    """Stage the trap-unit proof and the files its reuse key reads."""
    sby_config.stage_proof(TRAP_PROOF, ROOT, root)
    for name in (
        "tests/test_run_formal.py",
        "tests/sby_config.py",
        sby_config.DEFINE_INPUTS_PATH,
        "tests/sby_dump.sby",
        "tests/formal_model.cc",
        "tests/formal_predicates.py",
        "tests/conftest.py",
        "pyproject.toml",
    ):
        (root / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / name, root / name)
    return root


def formal_key(root: Path, test_id: str = "trap_unit_bmc", tools: str = TOOLS) -> str:
    """Return a formal key computed from scratch."""
    return ci_reuse.formal_task_key(root, test_id, tools)


def test_formal_key_contains_the_task_define_declaration(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Record the selected task's expected define inputs in its reuse key."""
    key_payloads = []
    digest = ci_reuse.canonical_digest

    def record_digest(payload: dict[str, Any]) -> str:
        if payload.get("kind") == "formal":
            key_payloads.append(payload)
        return digest(payload)

    monkeypatch.setattr(ci_reuse, "canonical_digest", record_digest)
    formal_key(ROOT, "pm_mode_select_bmc_ddr36")
    (payload,) = key_payloads
    declaration = sby_config.read_define_inputs(ROOT)["pm_mode_select:bmc_ddr36"]
    assert payload["define_inputs"] == declaration


def edit(path: Path, old: str, new: str) -> None:
    """Replace one occurrence of old in a file."""
    text = path.read_text()
    assert text.count(old) >= 1, old
    path.write_text(text.replace(old, new, 1))


@pytest.mark.parametrize(
    "change",
    [
        *(f"file:{name}" for name in TRAP_FILES),
        "sby",
        "timeout",
        "tools",
        "conftest",
        "pytest_ini",
        "root_pytest_ini",
        "native_pytest_section",
        "commented_pytest_header",
        "wrapper",
        "runner:class FormalRunner:",
        "runner:def fatal_frame_completed(output: str) -> bool:",
        "runner:    def prove(",
        "helper:tests/sby_config.py",
        "helper:tests/sby_dump.sby",
        "helper:tests/formal_model.cc",
        "helper:tests/formal_predicates.py",
        "new_helper",
    ],
)
def test_formal_key_changes_with_each_input(tmp_path: Path, change: str) -> None:
    """Changing any single input of a formal task changes its key."""
    root = formal_tree(tmp_path)
    before = formal_key(root)
    kind, _, name = change.partition(":")
    if kind in ("file", "helper"):
        with open(root / name, "a") as stream:
            stream.write("# changed\n")
    elif kind == "sby":
        edit(root / "formal/trap_unit.sby", "bmc: depth 20", "bmc: depth 21")
    elif kind == "timeout":
        edit(
            root / "tests/test_run_formal.py",
            "SBY_TASK_TIMEOUT_OVERRIDES_S = {\n",
            'SBY_TASK_TIMEOUT_OVERRIDES_S = {\n    ("trap_unit", "bmc"): 600,\n',
        )
    elif kind == "tools":
        assert formal_key(root, tools="image-other") != before
        return
    elif kind == "conftest":
        with open(root / "tests/conftest.py", "a") as stream:
            stream.write("# changed\n")
    elif kind == "pytest_ini":
        edit(root / "pyproject.toml", '"--tb=short",', '"--tb=long",')
    elif kind == "root_pytest_ini":
        (root / "pytest.ini").write_text("[pytest]\naddopts = -p no:doctest\n")
    elif kind == "commented_pytest_header":
        edit(
            root / "pyproject.toml",
            "[tool.pytest.ini_options]\n",
            "[tool.pytest.ini_options] # settings\n",
        )
        before = formal_key(root)
        edit(root / "pyproject.toml", '"--tb=short",', '"--tb=long",')
    elif kind == "wrapper":
        (root / "scripts").mkdir()
        (root / "scripts/frost.py").write_text("# wrapper\n")
    elif kind == "native_pytest_section":
        with open(root / "pyproject.toml", "a") as stream:
            stream.write('\n[tool.pytest]\naddopts = ["-q"]\n')
    elif kind == "new_helper":
        with open(root / "tests/test_run_formal.py", "a") as stream:
            stream.write("\n\ndef helper() -> None:\n    pass\n")
    else:
        indent = " " * (len(name) - len(name.lstrip()) + 4)
        edit(root / "tests/test_run_formal.py", name + "\n", f"{name}\n{indent}# x\n")
    assert formal_key(root) != before


@pytest.mark.parametrize(
    "change",
    [
        "description",
        "task_description",
        "other_timeout",
        "other_function",
        "checkout_path",
        "file_order",
        "unrelated_file",
    ],
)
def test_formal_key_ignores_everything_else(tmp_path: Path, change: str) -> None:
    """Edits outside a task's inputs, and the checkout's location, keep its key."""
    root = formal_tree(tmp_path / "a")
    before = formal_key(root)
    module = root / "tests/test_run_formal.py"
    if change == "description":
        edit(
            module,
            '"Trap-unit exception and interrupt',
            '"Trap unit exception and interrupt',
        )
    elif change == "task_description":
        task_line = test_run_formal.SBY_TASKS[0][1]
        edit(module, task_line, task_line + " ")
    elif change == "other_timeout":
        edit(module, '("csr_file", "bmc"): 5400,', '("csr_file", "bmc"): 5401,')
    elif change == "other_function":
        edit(
            module,
            "def test_formal_target_tasks_are_registered() -> None:\n",
            "def test_formal_target_tasks_are_registered() -> None:\n    # x\n",
        )
    elif change == "checkout_path":
        other = formal_tree(tmp_path / "b")
        assert formal_key(other) == before
        return
    elif change == "file_order":
        proof = root / TRAP_PROOF.relative_to(ROOT)
        body = proof.read_text().splitlines()
        start = body.index("[files]") + 1
        entries = sby_config.source(proof).sections["files"]
        paths = [line for line in entries if line.strip() and not line.startswith("#")]
        first, second = (body.index(line, start) for line in paths[:2])
        body[first], body[second] = body[second], body[first]
        proof.write_text("\n".join(body) + "\n")
    else:
        (root / "hw/rtl/unrelated.sv").write_text("module unrelated; endmodule\n")
    assert formal_key(root) == before


def test_home_cmo_replay_staging_and_key(tmp_path: Path) -> None:
    """Stage the replay separately and invalidate only its cover when it changes."""
    root = formal_tree(tmp_path / "repo")
    sby = ROOT / "formal/coherence_home.sby"
    staged = sby_config.stage_proof(sby, ROOT, root)
    helper = root / "tests/coherence_home_cmo_replay.py"
    assert helper.read_bytes() == (ROOT / "tests" / helper.name).read_bytes()
    assert helper.resolve() not in {
        p.resolve() for p in sby_config.proof_inputs(staged)
    }
    assert sby_config.cmo_replay_helper(staged, "coh_home_cmo_cover") == helper
    assert sby_config.cmo_replay_helper(staged, "coh_home_control_prove") is None

    cover = "coherence_home_coh_home_cmo_cover"
    control = "coherence_home_coh_home_control_prove"
    cover_key, control_key = formal_key(root, cover), formal_key(root, control)
    with helper.open("a") as stream:
        stream.write("# changed replay\n")
    assert formal_key(root, cover) != cover_key
    assert formal_key(root, control) == control_key
    helper.unlink()
    with pytest.raises(ci_reuse.ReuseKeyError, match="missing formal replay helper"):
        formal_key(root, cover)
    assert formal_key(root, control) == control_key


def test_store_completion_projection_staging_and_keys(tmp_path: Path) -> None:
    """Both tasks consume the source projection staged with the wrapper."""
    root = formal_tree(tmp_path / "repo")
    proof = ROOT / "formal/store_completion_cofactor.sby"
    staged = sby_config.stage_proof(proof, ROOT, root)
    helper = root / "tests/store_completion_cofactor.py"
    assert sby_config.store_completion_cone_helper(staged) == helper
    assert helper.read_bytes() == (ROOT / "tests" / helper.name).read_bytes()
    tasks = ("store_completion_cofactor_prove", "store_completion_cofactor_cover")
    before = {task: formal_key(root, task) for task in tasks}
    trap_key = formal_key(root)
    with helper.open("a") as stream:
        stream.write("# changed projection\n")
    for task in tasks:
        assert formal_key(root, task) != before[task]
    assert formal_key(root) == trap_key


def test_formal_key_file_list_is_order_independent() -> None:
    """The [files] entries enter the key sorted by path."""
    preimages: list[Any] = []
    original = ci_reuse.canonical_digest

    def capture(value: Any) -> str:
        preimages.append(value)
        return original(value)

    ci_reuse.canonical_digest = capture
    try:
        ci_reuse.formal_task_key(ROOT, "trap_unit_bmc", TOOLS)
    finally:
        ci_reuse.canonical_digest = original
    files = preimages[-1]["files"]
    assert files == sorted(files, key=lambda f: (f["path"], f["entry"]))


@pytest.mark.parametrize(
    "files_line",
    [
        "/workspace/hw/rtl/x.sv",
        "../../outside.sv",
        "src/x.sv ../hw/x.sv",
        "../hw/rtl/missing.sv",
        "missing_helper",
        None,
    ],
)
def test_formal_key_rejects_files_outside_the_checkout(
    tmp_path: Path, files_line: str | None
) -> None:
    """A [files] entry must be one relative path to a file of the checkout."""
    root = formal_tree(tmp_path / "repo")
    (tmp_path / "outside.sv").write_text("module x; endmodule\n")
    sby = root / "formal/trap_unit.sby"
    if files_line == "missing_helper":
        (root / "tests/sby_config.py").unlink()
    elif files_line is None:
        text = sby.read_text()
        sby.write_text(text[: text.index("[files]")])
    else:
        edit(sby, "[files]\n", f"[files]\n{files_line}\n")
    with pytest.raises(ci_reuse.ReuseKeyError):
        formal_key(root)


# ---------------------------------------------------------------------------
# Synthesis key sensitivity
# ---------------------------------------------------------------------------


def synthesis_tree(root: Path) -> tuple[Path, str]:
    """Build a small checkout with sources, an include and a memory image."""
    for name in ("tests/test_run_yosys.py", "tests/conftest.py", "pyproject.toml"):
        (root / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / name, root / name)
    (root / "rtl/inc").mkdir(parents=True)
    (root / "rtl/top.sv").write_text(
        '`include "defs.svh"\nmodule top #(parameter INIT_FILE = "sw.mem") ();\n'
        "  initial $readmemh(INIT_FILE, m);\nendmodule\n"
    )
    (root / "rtl/inc/defs.svh").write_text("`define WIDTH 8\n")
    (root / "tests/sw.mem").write_text("00000013\n")
    script = (
        f"read_verilog -sv -DSYNTHESIS -I{root}/rtl/inc {root}/rtl/top.sv\n"
        "hierarchy -top top\nsynth -top top -run coarse\nhierarchy -check"
    )
    return root, script


def synthesis_key(
    root: Path, script: str, timeout: int = 1800, tools: str = TOOLS
) -> str:
    """Return a synthesis key for the small checkout."""
    return ci_reuse.synthesis_key(
        root,
        "test_synthesis[generic]",
        script,
        root / "tests",
        root / "tmp",
        timeout,
        tools,
    )


@pytest.mark.parametrize(
    "change",
    [
        "source",
        "include",
        "memory",
        "shadowing_include",
        "new_memory",
        "script",
        "timeout",
        "tools",
        "runner",
        "conftest",
        "template_include_shadow",
        "indirect_memory_name",
        "root_pytest_ini",
        "shadowing_symlink",
    ],
)
def test_synthesis_key_changes_with_each_input(tmp_path: Path, change: str) -> None:
    """Changing any single input of a synthesis run changes its key."""
    root, script = synthesis_tree(tmp_path)
    (root / "tmp").mkdir()
    before = synthesis_key(root, script)
    if change == "source":
        edit(root / "rtl/top.sv", "endmodule", "  // x\nendmodule")
    elif change == "include":
        edit(root / "rtl/inc/defs.svh", "8", "9")
    elif change == "memory":
        edit(root / "tests/sw.mem", "13", "93")
    elif change == "shadowing_include":
        # Yosys looks in the working directory before the -I directories.
        (root / "tests/defs.svh").write_text("`define WIDTH 4\n")
    elif change == "new_memory":
        (root / "rtl/sw.mem").write_text("00000000\n")
    elif change == "script":
        script = script.replace("-run coarse", "")
    elif change == "timeout":
        assert synthesis_key(root, script, timeout=1801) != before
        return
    elif change == "tools":
        assert synthesis_key(root, script, tools="image-other") != before
        return
    elif change == "template_include_shadow":
        # Yosys's own techmap templates include files from the working
        # directory first.
        (root / "tests/brams_defs.vh").write_text("`define X 1\n")
    elif change == "indirect_memory_name":
        # A name that reaches $readmemh through parameters.
        (root / "rtl/boot.hex").write_text("00\n")
    elif change == "root_pytest_ini":
        (root / "pytest.ini").write_text("[pytest]\n")
    elif change == "shadowing_symlink":
        # A link to a file the key already holds still adds a name.
        (root / "tests/defs.svh").symlink_to(root / "rtl/inc/defs.svh")
    elif change == "runner":
        edit(
            root / "tests/test_run_yosys.py",
            "    def check_for_errors(\n",
            "    # x\n    def check_for_errors(\n",
        )
    else:
        with open(root / "tests/conftest.py", "a") as stream:
            stream.write("# x\n")
    assert synthesis_key(root, script) != before


def test_synthesis_key_is_independent_of_the_checkout_path(tmp_path: Path) -> None:
    """Two checkouts of the same content have the same key."""
    first, first_script = synthesis_tree(tmp_path / "a")
    second, second_script = synthesis_tree(tmp_path / "b")
    (first / "tmp").mkdir()
    (second / "tmp").mkdir()
    assert synthesis_key(first, first_script) == synthesis_key(second, second_script)


@pytest.mark.parametrize(
    "line",
    [
        "read_verilog -sv -I/etc /SOURCE",
        "read_verilog -sv /etc/hostname",
        "read_verilog -sv /SOURCE.missing",
    ],
)
def test_synthesis_key_rejects_reads_outside_the_checkout(
    tmp_path: Path, line: str
) -> None:
    """A source or include directory outside the checkout is an error."""
    root, script = synthesis_tree(tmp_path)
    (root / "tmp").mkdir()
    script += "\n" + line.replace("/SOURCE", f"{root}/rtl/top.sv")
    with pytest.raises(ci_reuse.ReuseKeyError):
        synthesis_key(root, script)


# ---------------------------------------------------------------------------
# Markers, canary and decisions
# ---------------------------------------------------------------------------


def test_marker_is_trusted_only_for_its_own_check_and_key(tmp_path: Path) -> None:
    """A marker matches one check, one key, one kind and the schema."""
    store = ci_reuse.MarkerStore(tmp_path, "formal")
    assert store.valid("a_bmc", "k1") is None
    store.record_pass("a_bmc", "k1", {"run_url": "https://example.invalid/1"})
    assert store.valid("a_bmc", "k1") is not None
    assert store.valid("a_bmc", "k2") is None
    assert store.valid("b_bmc", "k1") is None
    assert ci_reuse.MarkerStore(tmp_path, "synthesis").valid("a_bmc", "k1") is None
    path = store.path("a_bmc")
    marker = json.loads(path.read_text())
    marker["schema"] = ci_reuse.SCHEMA + 1
    path.write_text(json.dumps(marker))
    assert store.valid("a_bmc", "k1") is None
    path.write_text("{not json")
    assert store.valid("a_bmc", "k1") is None
    assert list(tmp_path.rglob("*.tmp*")) == []


def test_canary_rotates_through_every_check() -> None:
    """Over CANARY_PERIOD consecutive runs each check is chosen exactly once."""
    tests = [f"target_{n}_bmc" for n in range(200)]
    for test in tests:
        picks = [
            seed
            for seed in range(1000, 1000 + ci_reuse.CANARY_PERIOD)
            if ci_reuse.canary(test, str(seed))
        ]
        assert len(picks) == 1
    share = sum(ci_reuse.canary(t, "1234") for t in tests) / len(tests)
    assert 0.0 < share < 0.15
    assert not ci_reuse.canary(tests[0], "")


def test_decision_reuses_only_valid_markers(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Missing markers and forced runs prove; canary checks prove again."""
    monkeypatch.setenv("FROST_REUSE_DIR", str(tmp_path))
    monkeypatch.setenv("FROST_REUSE_TOOLS_ID", TOOLS)
    monkeypatch.delenv("FROST_REUSE_FORCE", raising=False)
    monkeypatch.delenv("FROST_REUSE_MAIN_RUN", raising=False)
    monkeypatch.delenv("FROST_REUSE_MAIN_LIFETIME", raising=False)
    test = next(
        t for t in (f"t{n}" for n in range(1000)) if not ci_reuse.canary(t, "7")
    )
    chosen = next(t for t in (f"t{n}" for n in range(1000)) if ci_reuse.canary(t, "7"))
    monkeypatch.setenv("FROST_REUSE_CANARY_SEED", "7")
    reuse = ci_reuse.Reuse(ROOT, "formal")
    assert reuse.decide(test, "k").action == "prove"
    reuse.store.record_pass(test, "k", {})
    reuse.store.record_pass(chosen, "k", {})
    assert reuse.decide(test, "k").action == "reuse"
    assert reuse.decide(test, "other").action == "prove"
    assert reuse.decide(chosen, "k").action == "canary"
    monkeypatch.setenv("FROST_REUSE_FORCE", "true")
    assert ci_reuse.Reuse(ROOT, "formal").decide(test, "k").action == "prove"
    reuse.host_keys = {test: "different"}
    with pytest.raises(ci_reuse.ReuseKeyError):
        reuse.decide(test, "k")
    monkeypatch.delenv("FROST_REUSE_DIR")
    assert ci_reuse.Reuse.from_env(ROOT, "formal") is None


@pytest.mark.parametrize(
    "written,now,action",
    [
        ("", "", "reuse"),  # outside main, any marker
        ("12", "", "reuse"),
        ("", "12", "prove"),  # a marker from outside main
        ("10", "19", "reuse"),  # the same block of ten main runs
        ("19", "20", "prove"),  # the next block proves again
        ("20", "21", "reuse"),
        ("11", "21", "prove"),  # a block whose first run did not finish it
        ("25", "15", "prove"),  # a count that went back
        ("25", "23", "prove"),  # a count that went back within a block
        ("0", "0", "prove"),  # a count of 0 reuses nothing
        ("3", "0", "prove"),
        ("20", "20", "prove"),  # a rerun of a block's first run
        ("12", "15@2", "prove"),  # a count that started again, at run 2
    ],
)
def test_main_runs_reuse_only_markers_of_their_block(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    written: str,
    now: str,
    action: str,
) -> None:
    """A run on main reuses a marker only from its own block of ten main runs."""
    monkeypatch.setenv("FROST_REUSE_DIR", str(tmp_path))
    monkeypatch.delenv("FROST_REUSE_FORCE", raising=False)
    monkeypatch.delenv("FROST_REUSE_CANARY_SEED", raising=False)
    monkeypatch.setenv("FROST_REUSE_MAIN_RUN", written)
    monkeypatch.setenv("FROST_REUSE_MAIN_LIFETIME", "1")
    ci_reuse.Reuse(ROOT, "formal").store.record_pass("t_bmc", "k", {})
    now, _, lifetime = now.partition("@")
    monkeypatch.setenv("FROST_REUSE_MAIN_RUN", now)
    monkeypatch.setenv("FROST_REUSE_MAIN_LIFETIME", lifetime or "1")
    reuse = ci_reuse.Reuse(ROOT, "formal")
    assert reuse.decide("t_bmc", "k").action == action
    assert bool(ci_reuse.full_run_reason()) == (now in ("20", "0"))
    monkeypatch.setenv("FROST_REUSE_FORCE", "true")
    assert ci_reuse.Reuse(ROOT, "formal").decide("t_bmc", "k").action == "prove"
    monkeypatch.setenv("FROST_REUSE_MAIN_RUN", "x")
    with pytest.raises(ci_reuse.ReuseKeyError):
        ci_reuse.Reuse(ROOT, "formal")


# ---------------------------------------------------------------------------
# The formal and synthesis hooks
# ---------------------------------------------------------------------------


def run_formal_test(test_id: str) -> str:
    """Run test_formal for one task; return passed, skipped or failed."""
    target = next(
        t for t in test_run_formal.FORMAL_TARGETS if test_id.startswith(t.name + "_")
    )
    task = test_id[len(target.name) + 1 :]
    try:
        test_run_formal.TestFormalVerification().test_formal(target, task, "", Capsys())
    except pytest.skip.Exception:
        return "skipped"
    except pytest.fail.Exception as failure:
        return f"failed: {failure}"
    return "passed"


@pytest.fixture
def formal_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """Run formal tests with reuse on, a fake sby and a marker directory."""
    pass_output = (
        "SBY 00:00:01 [t] engine_0: Status returned by engine: pass\n"
        "SBY 00:00:01 [t] summary: engine_0 (smtbmc boolector) returned pass\n"
        "SBY 00:00:01 [t] DONE (PASS, rc=0)\n"
    )
    outcome: dict[str, Any] = {
        "returncode": 0,
        "output": pass_output,
        "pass_output": pass_output,
        "calls": 0,
    }

    def sby(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        if command[:2] == ["sby", "--version"]:
            return subprocess.CompletedProcess(command, 0, "sby", "")
        outcome["calls"] += 1
        if outcome.get("timeout"):
            raise subprocess.TimeoutExpired(command, 1)
        return subprocess.CompletedProcess(
            command, outcome["returncode"], outcome["output"], ""
        )

    monkeypatch.setattr(subprocess, "run", sby)
    monkeypatch.setattr(
        test_run_formal.FormalRunner,
        "verify_model_artifacts",
        lambda *args, **kwargs: None,
    )
    monkeypatch.setenv("FROST_REUSE_DIR", str(tmp_path / "markers"))
    monkeypatch.setenv("FROST_REUSE_TOOLS_ID", TOOLS)
    monkeypatch.setenv("FROST_REUSE_REPORT", str(tmp_path / "report.jsonl"))
    monkeypatch.setenv("FROST_REUSE_RUN_URL", "https://example.invalid/runs/1")
    monkeypatch.delenv("FROST_REUSE_FORCE", raising=False)
    monkeypatch.delenv("FROST_REUSE_MAIN_RUN", raising=False)
    monkeypatch.delenv("FROST_REUSE_MAIN_LIFETIME", raising=False)
    monkeypatch.delenv("FROST_REUSE_CANARY_SEED", raising=False)
    monkeypatch.delenv("FROST_REUSE_HOST_KEYS", raising=False)
    outcome["report"] = tmp_path / "report.jsonl"
    return outcome


def report_statuses(path: Path) -> list[str]:
    """Return the statuses in a reuse report."""
    return [json.loads(line)["status"] for line in path.read_text().splitlines()]


def test_formal_hook_marks_passes_and_skips_them(formal_env: dict[str, Any]) -> None:
    """A pass writes a marker; the next run skips; a failure writes none."""
    assert run_formal_test("trap_unit_bmc") == "passed"
    assert run_formal_test("trap_unit_bmc") == "skipped"
    assert formal_env["calls"] == 1
    formal_env["returncode"] = 1
    formal_env["output"] = "DONE (FAIL, rc=2)"
    assert run_formal_test("trap_unit_cover").startswith("failed")
    formal_env["returncode"] = 0
    formal_env["output"] = formal_env["pass_output"]
    formal_env["timeout"] = True
    assert run_formal_test("trap_unit_prove").startswith("failed")
    formal_env["timeout"] = False
    assert run_formal_test("trap_unit_cover") == "passed"
    assert report_statuses(formal_env["report"]) == [
        "proved",
        "reused",
        "failed",
        "failed",
        "proved",
    ]


def test_formal_hook_canary_failure_is_loud(
    formal_env: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    """A canary task with a marker that fails names the marker and drops it."""
    test_id = "trap_unit_bmc"
    seed = next(
        str(seed)
        for seed in range(ci_reuse.CANARY_PERIOD)
        if ci_reuse.canary(test_id, str(seed))
    )
    assert run_formal_test(test_id) == "passed"
    monkeypatch.setenv("FROST_REUSE_CANARY_SEED", seed)
    assert run_formal_test(test_id) == "passed"
    formal_env["returncode"] = 1
    formal_env["output"] = "DONE (FAIL, rc=2)"
    result = run_formal_test(test_id)
    assert result.startswith("failed: CANARY")
    assert "example.invalid/runs/1" in result
    monkeypatch.delenv("FROST_REUSE_CANARY_SEED")
    formal_env["returncode"] = 0
    formal_env["output"] = formal_env["pass_output"]
    calls = formal_env["calls"]
    assert run_formal_test(test_id) == "passed"
    assert formal_env["calls"] == calls + 1
    assert report_statuses(formal_env["report"]) == [
        "proved",
        "canary",
        "canary-failed",
        "proved",
    ]


@pytest.mark.parametrize(
    "output",
    [
        "DONE (TIMEOUT, rc=0)",
        "DONE (UNKNOWN, rc=0)",
        "",
        "DONE (PASS, rc=0)",
        "summary: engine_0 (smtbmc boolector) did not return a status\nDONE (PASS, rc=0)",
        "engine_0: Status returned by engine: pass\nDONE (PASS, rc=0)\nDONE (TIMEOUT, rc=0)",
    ],
)
def test_formal_hook_needs_a_pass_summary_for_a_marker(
    formal_env: dict[str, Any], output: str
) -> None:
    """A run that exits with 0 without an engine PASS verdict fails and writes no marker."""
    formal_env["output"] = output
    assert run_formal_test("trap_unit_bmc").startswith("failed")
    formal_env["output"] = formal_env["pass_output"]
    assert run_formal_test("trap_unit_bmc") == "passed"
    assert run_formal_test("trap_unit_bmc") == "skipped"
    assert report_statuses(formal_env["report"]) == [
        "failed",
        "proved",
        "reused",
    ]


def test_formal_hook_forced_run_without_pass_summary_drops_the_marker(
    formal_env: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    """A forced re-proof without an engine PASS verdict fails loud and drops the marker."""
    assert run_formal_test("trap_unit_bmc") == "passed"
    monkeypatch.setenv("FROST_REUSE_FORCE", "true")
    formal_env["output"] = "DONE (TIMEOUT, rc=0)"
    assert run_formal_test("trap_unit_bmc").startswith("failed: CANARY")
    monkeypatch.delenv("FROST_REUSE_FORCE")
    formal_env["output"] = formal_env["pass_output"]
    calls = formal_env["calls"]
    assert run_formal_test("trap_unit_bmc") == "passed"
    assert formal_env["calls"] == calls + 1


def test_formal_hook_forced_failure_drops_the_marker(
    formal_env: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    """A forced run of a marked task that fails is loud and removes the marker."""
    assert run_formal_test("trap_unit_bmc") == "passed"
    monkeypatch.setenv("FROST_REUSE_FORCE", "true")
    formal_env["returncode"] = 1
    formal_env["output"] = "DONE (FAIL, rc=2)"
    assert run_formal_test("trap_unit_bmc").startswith("failed: CANARY")
    monkeypatch.delenv("FROST_REUSE_FORCE")
    formal_env["returncode"] = 0
    formal_env["output"] = formal_env["pass_output"]
    assert run_formal_test("trap_unit_bmc") == "passed"


def test_formal_hook_off_without_marker_directory(
    formal_env: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    """Without FROST_REUSE_DIR every run proves and nothing is written."""
    monkeypatch.delenv("FROST_REUSE_DIR")
    assert run_formal_test("trap_unit_bmc") == "passed"
    assert run_formal_test("trap_unit_bmc") == "passed"
    assert formal_env["calls"] == 2
    assert not formal_env["report"].exists()


def test_synthesis_hook_marks_passes_and_skips_them(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A synthesis pass writes a marker and the next run skips Yosys."""
    monkeypatch.setattr(test_run_yosys.YosysRunner, "setup_sw_mem", lambda self: None)
    monkeypatch.setattr(
        test_run_yosys.YosysRunner,
        "convert_nic_sources",
        lambda self, files, directory, defines, timeout: files,
    )
    calls = {"yosys": 0}
    result = {"returncode": 0}

    def yosys(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        if command[:2] != ["yosys", "-V"]:
            calls["yosys"] += 1
        output = "Yosys\nEnd of script." if result.get("complete", True) else "Yosys"
        return subprocess.CompletedProcess(command, result["returncode"], output, "")

    monkeypatch.setattr(subprocess, "run", yosys)
    monkeypatch.setenv("FROST_REUSE_DIR", str(tmp_path))
    monkeypatch.setenv("FROST_REUSE_TOOLS_ID", TOOLS)
    monkeypatch.delenv("FROST_REUSE_FORCE", raising=False)
    monkeypatch.delenv("FROST_REUSE_MAIN_RUN", raising=False)
    monkeypatch.delenv("FROST_REUSE_MAIN_LIFETIME", raising=False)
    monkeypatch.delenv("FROST_REUSE_CANARY_SEED", raising=False)
    monkeypatch.delenv("FROST_REUSE_HOST_KEYS", raising=False)
    monkeypatch.delenv("FROST_REUSE_REPORT", raising=False)

    def run() -> str:
        try:
            test_run_yosys.TestYosysSynthesis().test_synthesis(
                "generic", test_run_yosys.GENERIC_SYNTH_COMMAND, "", Capsys()
            )
        except pytest.skip.Exception:
            return "skipped"
        except pytest.fail.Exception:
            return "failed"
        return "passed"

    result["returncode"] = 1
    assert run() == "failed"
    result["returncode"] = 0
    result["complete"] = False
    assert run() == "passed"  # no end-of-script line: no marker
    result["complete"] = True
    assert run() == "passed"
    assert run() == "skipped"
    assert calls["yosys"] == 3
    # A forced run that fails drops the marker and says so.
    monkeypatch.setenv("FROST_REUSE_FORCE", "true")
    result["returncode"] = 1
    assert run() == "failed"
    monkeypatch.delenv("FROST_REUSE_FORCE")
    result["returncode"] = 0
    assert run() == "passed"


# ---------------------------------------------------------------------------
# CI planning
# ---------------------------------------------------------------------------


def test_linux_cache_excludes_firmware_outputs() -> None:
    """Linux cache restore keys can reuse downloads and ccache, never firmware."""
    workflow = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text())
    steps = workflow["jobs"]["build-frost-linux-mmu"]["steps"]
    caches = [
        step["with"]
        for step in steps
        if step.get("uses", "").startswith("actions/cache")
    ]
    assert {cache["path"] for cache in caches} == {
        "linux/dl",
        "linux/ccache",
        "linux/debian-kernel/dl",
    }


def test_collection_output_is_checked() -> None:
    """A selection record needs output whose node count matches its summary."""
    nodes = "a.py::t[x]\na.py::t[y]\n\n2/9 tests collected (7 deselected) in 0.1s\n"
    assert ci_reuse.parse_collection(nodes) == ["a.py::t[x]", "a.py::t[y]"]
    with pytest.raises(ValueError):
        ci_reuse.parse_collection("a.py::t[x]\n\n2 tests collected in 0.1s\n")
    with pytest.raises(ValueError):
        ci_reuse.parse_collection("ERROR collecting a.py\n")
    with pytest.raises(ValueError):
        ci_reuse.parse_collection(
            "a.py::t[x]\n\n1/9 tests collected (8 deselected), 1 error in 0.1s\n"
        )


def plan(root: Path, markers: Path, expression: str = "trap_unit") -> str:
    """Run formal-plan and return its need_image decision."""
    output = markers / "output"
    output.unlink(missing_ok=True)
    os.environ["GITHUB_OUTPUT"] = str(output)
    try:
        ci_reuse.main(
            [
                "formal-plan",
                "--dir",
                str(markers),
                "--expression",
                expression,
                "--root",
                str(root),
                "--report",
                str(markers / "report.jsonl"),
            ]
        )
    finally:
        del os.environ["GITHUB_OUTPUT"]
    return output.read_text().strip()


def test_plan_skips_the_image_only_when_every_task_is_reusable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The host plan needs a matching selection record and a valid marker per task."""
    root = formal_tree(tmp_path / "repo")
    for name in (".github/workflows/ci.yml",):
        (root / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / name, root / name)
    markers = tmp_path / "markers"
    markers.mkdir()
    monkeypatch.setenv("FROST_REUSE_TOOLS_ID", TOOLS)
    monkeypatch.delenv("FROST_REUSE_FORCE", raising=False)
    monkeypatch.delenv("FROST_REUSE_MAIN_RUN", raising=False)
    monkeypatch.delenv("FROST_REUSE_MAIN_LIFETIME", raising=False)
    monkeypatch.delenv("FROST_REUSE_CANARY_SEED", raising=False)
    tasks = ["trap_unit_bmc", "trap_unit_cover"]
    collected = tmp_path / "collected.txt"
    collected.write_text(
        "".join(
            f"tests/test_run_formal.py::TestFormalVerification::test_formal[{t}]\n"
            for t in tasks
        )
        + "\n2/900 tests collected (898 deselected) in 1.0s\n"
    )

    def record(status: int = 0) -> None:
        ci_reuse.main(
            [
                "formal-record",
                "--collect-status",
                str(status),
                "--dir",
                str(markers),
                "--expression",
                "trap_unit",
                "--tools-id",
                TOOLS,
                "--collected",
                str(collected),
                "--root",
                str(root),
            ]
        )

    assert plan(root, markers) == "need_image=true"  # no record yet
    record()
    assert plan(root, markers) == "need_image=true"  # no markers yet
    store = ci_reuse.MarkerStore(markers, "formal")
    store.record_pass(tasks[0], formal_key(root, tasks[0]), {})
    assert plan(root, markers) == "need_image=true"  # one marker missing
    store.record_pass(tasks[1], formal_key(root, tasks[1]), {})
    assert plan(root, markers) == "need_image=false"
    record(status=2)  # a failed collection removes the record
    assert plan(root, markers) == "need_image=true"
    record()
    assert plan(root, markers) == "need_image=false"
    assert plan(root, markers, expression="other") == "need_image=true"
    monkeypatch.setenv("FROST_REUSE_FORCE", "true")
    assert plan(root, markers) == "need_image=true"
    monkeypatch.delenv("FROST_REUSE_FORCE")
    # Markers written outside main are not reused on main; a block's markers
    # are reused for the rest of the block only.
    monkeypatch.setenv("FROST_REUSE_MAIN_RUN", "21")
    monkeypatch.setenv("FROST_REUSE_MAIN_LIFETIME", "5")
    assert plan(root, markers) == "need_image=true"
    for task in tasks:
        ci_reuse.Reuse(root, "formal").store.record_pass(
            task, formal_key(root, task), {}
        )
    assert plan(root, markers) == "need_image=false"
    monkeypatch.setenv("FROST_REUSE_MAIN_LIFETIME", "6")
    assert plan(root, markers) == "need_image=true"
    monkeypatch.setenv("FROST_REUSE_MAIN_LIFETIME", "5")
    monkeypatch.setenv("FROST_REUSE_MAIN_RUN", "30")
    assert plan(root, markers) == "need_image=true"
    monkeypatch.delenv("FROST_REUSE_MAIN_RUN")
    monkeypatch.delenv("FROST_REUSE_MAIN_LIFETIME")
    seed = next(
        str(s)
        for s in range(ci_reuse.CANARY_PERIOD)
        if ci_reuse.canary(tasks[1], str(s))
    )
    monkeypatch.setenv("FROST_REUSE_CANARY_SEED", seed)
    assert plan(root, markers) == "need_image=true"
    monkeypatch.delenv("FROST_REUSE_CANARY_SEED")
    with open(root / TRAP_FILES[0], "a") as stream:
        stream.write("// x\n")
    assert plan(root, markers) == "need_image=true"  # stale key
    with open(root / ".github/workflows/ci.yml", "a") as stream:
        stream.write("# x\n")
    assert plan(root, markers) == "need_image=true"  # selection inputs changed
    for task in tasks:
        store.record_pass(task, formal_key(root, task), {})
    record()
    assert plan(root, markers) == "need_image=false"
    with open(root / "tests/sby_config.py", "a") as stream:
        stream.write("# x\n")
    assert plan(root, markers) == "need_image=true"  # formal helper changed
    collected.write_text(
        "tests/test_run_formal.py::TestFormalVerification::test_sby_installed\n"
        "\n1/900 tests collected (899 deselected) in 1.0s\n"
    )
    record()
    assert plan(root, markers) == "need_image=true"  # a non-reusable test


def test_image_identity_from_archive(tmp_path: Path) -> None:
    """The archive identity reads the layers and environment of its one image."""
    config = {
        "rootfs": {"type": "layers", "diff_ids": ["sha256:aa", "sha256:bb"]},
        "config": {"Env": ["PATH=/usr/bin"]},
        "created": "2026-01-01T00:00:00Z",
    }
    archive = tmp_path / "image.tar"
    with tarfile.open(archive, "w") as tar:
        for name, data in (
            ("manifest.json", json.dumps([{"Config": "blobs/sha256/c", "Layers": []}])),
            ("blobs/sha256/c", json.dumps(config)),
        ):
            info = tarfile.TarInfo(name)
            payload = data.encode()
            info.size = len(payload)
            tar.addfile(info, io.BytesIO(payload))
    identity = ci_reuse.archive_identity(archive)
    assert identity == ci_reuse.image_identity(config)
    later = dict(config, created="2026-02-01T00:00:00Z")
    assert ci_reuse.image_identity(later) == identity
    changed = dict(config, rootfs={"diff_ids": ["sha256:aa", "sha256:cc"]})
    assert ci_reuse.image_identity(changed) != identity
    other_env = dict(config, config={"Env": ["PATH=/opt/bin"]})
    assert ci_reuse.image_identity(other_env) != identity


def test_workflow_job_outputs_name_steps_of_their_job() -> None:
    """Each job output, such as the gate's, reads a step that the job has."""
    workflow = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text())
    for name, job in workflow["jobs"].items():
        ids = {step.get("id") for step in job.get("steps", [])}
        for output in (job.get("outputs") or {}).values():
            for step in re.findall(r"steps\.([\w-]+)\.outputs", output):
                assert step in ids, f"{name} output reads missing step {step}"


def test_reuse_off_when_the_count_could_not_be_kept(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """An empty marker directory proves everything, reads and writes nothing.

    The gate turns reuse off when it cannot keep the main-run count, and the
    formal and synthesis jobs then get an empty FROST_REUSE_DIR.
    """
    workflow = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text())
    jobs = workflow["jobs"]
    assert "steps.count.outcome" in jobs["gate"]["outputs"]["reuse"]
    assert (
        "steps.restore-count.outputs.cache-matched-key"
        in (jobs["gate"]["outputs"]["reuse"])
    )
    assert "steps.check-count.outputs.cache-hit" in jobs["gate"]["outputs"]["reuse"]
    for name in ("test-formal", "test-synthesis", "test-pa-synthesis-width"):
        assert (
            "needs.gate.outputs.reuse == 'true'" in jobs[name]["env"]["FROST_REUSE_DIR"]
        )
        for step in jobs[name]["steps"]:
            if "pass markers" in step["name"]:
                assert "env.FROST_REUSE_DIR != ''" in step["if"]
    for step in jobs["gate"]["steps"]:
        assert step.get("id") == "select" or step.get("continue-on-error") is True
    monkeypatch.setenv("FROST_REUSE_DIR", "")
    assert ci_reuse.Reuse.from_env(ROOT, "formal") is None
    markers = tmp_path / "markers"
    markers.mkdir()
    ci_reuse.MarkerStore(markers, "formal").record_pass("trap_unit_bmc", "k", {})
    output = tmp_path / "output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    ci_reuse.main(["formal-plan", "--dir", "", "--expression", "trap_unit"])
    assert output.read_text() == "need_image=true\n"
    record = ["formal-record", "--dir", "", "--expression", "x", "--tools-id", TOOLS]
    ci_reuse.main([*record, "--collected", "missing", "--collect-status", "0"])
    ci_reuse.main(["summary", "--report", str(tmp_path / "none"), "--title", "t"])
    assert ci_reuse.REUSE_OFF in capsys.readouterr().out
    assert sorted(p.name for p in tmp_path.rglob("*")) == sorted(
        p.name for p in [markers, output, *markers.rglob("*")]
    )
