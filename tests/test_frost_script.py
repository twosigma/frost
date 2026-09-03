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

"""Tests for the host-side pinned-container workflow wrapper."""

import json
import os
import stat
from collections.abc import Callable, Iterator, Sequence
from pathlib import Path
from types import SimpleNamespace

import pytest

import scripts.frost as frost
from scripts.frost import (
    CommandOutcome,
    build_image_probe_command,
    build_docker_command,
    cache_diagnostics,
    default_cache_directory,
    dockerfile_version_pins,
    forwarded_environment_names,
    image_fingerprint_problems,
    image_runtime_problems,
    prepare_cache_directory,
    run_captured_command,
    run_doctor,
    run_fast_checks,
    scan_root_owned_paths,
    sha256_file,
    submodule_diagnostic,
    tool_version_problems,
    validate_image_reference,
    workflow_command,
)


def test_cocotb_workflow_always_cleans_before_running() -> None:
    """The convenience path must retain the repository's clean-build rule."""
    command = workflow_command("cocotb", ["hello_world", "--random-seed=7"])

    assert command[:4] == [
        "bash",
        "-c",
        'cd tests && make clean && exec ./test_run_cocotb.py "$@"',
        "frost-cocotb",
    ]
    assert command[4:] == ["hello_world", "--random-seed=7"]


def test_pytest_workflow_always_cleans_before_running() -> None:
    """The pytest shortcut must clean before entering the cocotb runner."""
    command = workflow_command("pytest", ["-m", "cocotb and cocotb_unit"])

    assert "make clean" in command[2]
    assert command[4:] == ["-m", "cocotb and cocotb_unit"]


def test_lint_defaults_to_every_tracked_file() -> None:
    """Lint should match the CI gate unless the caller supplies other args."""
    assert workflow_command("lint", []) == ["pre-commit", "run", "--all-files"]
    assert workflow_command("lint", ["ruff", "--all-files"]) == [
        "pre-commit",
        "run",
        "ruff",
        "--all-files",
    ]


def test_run_requires_a_command() -> None:
    """An empty arbitrary-command invocation should fail clearly."""
    with pytest.raises(ValueError, match="requires a command"):
        workflow_command("run", [])


def test_environment_forwarding_is_scoped_and_deterministic() -> None:
    """Only relevant, non-secret workflow controls should cross the boundary."""
    environment = {
        "FROST_COCOTB_MEM_CONFIG": "ddr",
        "COCOTB_RANDOM_SEED": "7",
        "DDR_MODEL_LATENCY": "80",
        "PYTEST_ADDOPTS": "-q",
        "PATH": "/host/bin",
        "AWS_SECRET_ACCESS_KEY": "do-not-forward",
    }

    assert forwarded_environment_names(environment) == [
        "COCOTB_RANDOM_SEED",
        "DDR_MODEL_LATENCY",
        "FROST_COCOTB_MEM_CONFIG",
        "PYTEST_ADDOPTS",
    ]


def test_docker_command_runs_as_host_user_and_mounts_checkout() -> None:
    """Generated runs should preserve ownership and use the local pinned image."""
    command = build_docker_command(
        ["python3", "tests/test_run_formal.py", "--list-targets"],
        repository_root=Path("/work/frost"),
        image="frost:test",
        uid=1234,
        gid=5678,
        environment={"FROST_FORMAL_JOBS": "2", "PATH": "/bin"},
        cache_directory=Path("/tmp/frost-cache"),
    )

    assert command[:5] == ["docker", "run", "--rm", "--init", "--pull=never"]
    assert ["--user", "1234:5678"] == command[5:7]
    assert "HOME=/tmp/frost-home-1234" in command
    assert ["--env", "FROST_FORMAL_JOBS"] == command[9:11]
    assert [
        "--volume",
        "/tmp/frost-cache:/tmp/frost-home-1234/.cache",
    ] == command[11:13]
    assert ["--volume", "/work/frost:/workspace"] == command[13:15]
    assert command[-4:] == [
        "frost:test",
        "python3",
        "tests/test_run_formal.py",
        "--list-targets",
    ]


@pytest.mark.parametrize(
    "image", ("", "-frost", "frost latest", "frost\nlatest", "x;echo${IFS}oops")
)
def test_image_reference_rejects_option_like_or_ambiguous_values(image: str) -> None:
    """An image name must not inject Docker options or split arguments."""
    with pytest.raises(ValueError, match="invalid Docker image reference"):
        validate_image_reference(image)

    validate_image_reference("registry.example/frost:dev")


def test_image_probe_is_networkless_read_only_and_checkout_free() -> None:
    """Doctor must inspect an image without exposing or changing the checkout."""
    command = build_image_probe_command("frost:test", uid=1234, gid=5678)

    assert command[:4] == ["docker", "run", "--rm", "--pull=never"]
    assert command[command.index("--network") : command.index("--network") + 2] == [
        "--network",
        "none",
    ]
    assert "--read-only" in command
    assert ["--cpus", "1"] == command[
        command.index("--cpus") : command.index("--cpus") + 2
    ]
    assert ["--memory", "512m"] == command[
        command.index("--memory") : command.index("--memory") + 2
    ]
    assert ["--cap-drop", "ALL"] == command[
        command.index("--cap-drop") : command.index("--cap-drop") + 2
    ]
    assert ["--security-opt", "no-new-privileges"] == command[
        command.index("--security-opt") : command.index("--security-opt") + 2
    ]
    assert "--volume" not in command
    assert not any("/workspace" in argument for argument in command)
    assert command[-3:-1] == ["frost:test", "-c"]


def test_timed_out_probe_container_is_force_removed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A bounded doctor probe must not leak its container after client timeout."""
    commands: list[list[str]] = []

    def fake_run(command: Sequence[str], **_kwargs: object) -> SimpleNamespace:
        commands.append(list(command))
        if list(command[:2]) == ["docker", "run"]:
            raise frost.subprocess.TimeoutExpired(command, 30)
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    monkeypatch.setattr(frost.subprocess, "run", fake_run)

    outcome = run_captured_command(
        ["docker", "run", "--name", "frost-doctor-test", "image"]
    )

    assert outcome.returncode == 124
    assert commands[-1] == ["docker", "rm", "--force", "frost-doctor-test"]


def test_image_helpers_validate_fingerprints_versions_and_runtime(
    tmp_path: Path,
) -> None:
    """The image inventory is checked against the checkout and Dockerfile pins."""
    dockerfile = tmp_path / "Dockerfile"
    dockerfile.write_text(
        "\n".join(
            (
                "ARG VERILATOR_VERSION=5.050",
                "ARG YOSYS_VERSION=0.64",
                "ARG SBY_VERSION=0.63",
                "ARG Z3_VERSION=4.15.0",
                "ARG BOOLECTOR_VERSION=3.2.4",
                "ARG XPACK_RISCV_VERSION=15.2.0-1",
                "ARG CLANG_TIDY_VERSION=18.1.3",
                "ARG VERIBLE_VERSION=0.0-4051-g9fdb4057",
                "ARG COCOTB_VERSION=2.0.1",
                "ARG PYTEST_VERSION=9.1.1",
                "ARG PYTEST_COV_VERSION=7.1.0",
                "ARG PRE_COMMIT_VERSION=4.6.0",
                "ARG CLICK_VERSION=8.4.2",
            )
        )
        + "\n"
    )
    entrypoint = tmp_path / "docker_entrypoint.py"
    entrypoint.write_text("#!/usr/bin/env python3\n")
    pins = dockerfile_version_pins(dockerfile)
    tools = {
        tool: {
            "version": (
                pins[argument].rsplit("-", maxsplit=1)[0]
                if tool == "riscv_gcc"
                else pins[argument]
            )
        }
        for tool, argument in frost.TOOL_VERSION_ARGUMENTS.items()
    }
    probe: dict[str, object] = {
        "architecture": "x86_64",
        "python": "3.12.10",
        "entrypoint_mode": 0o755,
        "fingerprints": {
            "Dockerfile": sha256_file(dockerfile),
            "docker_entrypoint.py": sha256_file(entrypoint),
        },
        "tools": tools,
    }

    assert image_fingerprint_problems(tmp_path, probe) == []
    assert tool_version_problems(probe, pins) == []
    assert image_runtime_problems(probe) == []

    probe["fingerprints"] = {"Dockerfile": "stale"}
    assert image_fingerprint_problems(tmp_path, probe) == [
        "embedded Dockerfile differs from the checkout",
        "image does not embed docker_entrypoint.py",
    ]
    tools["yosys"] = {"version": "Yosys 0.63"}
    assert tool_version_problems(probe, pins) == ["yosys expected 0.64, got Yosys 0.63"]
    tools["yosys"] = {"version": "Yosys 0.640"}
    tools["pytest"] = {"version": "9.1.10"}
    assert tool_version_problems(probe, pins) == [
        "yosys expected 0.64, got Yosys 0.640",
        "pytest expected 9.1.1, got 9.1.10",
    ]
    probe.update(architecture="aarch64", python="3.11.9", entrypoint_mode=0o700)
    assert len(image_runtime_problems(probe)) == 3


@pytest.mark.parametrize(
    ("prefix", "status", "detail"),
    (
        ("-", "FAIL", "uninitialized"),
        ("+", "WARN", "different commit"),
    ),
)
def test_submodule_diagnostic_distinguishes_missing_and_drifted_checkouts(
    tmp_path: Path, prefix: str, status: str, detail: str
) -> None:
    """Uninitialized modules fail; modules checked out at another commit warn."""
    (tmp_path / ".gitmodules").write_text('[submodule "dependency"]\n')
    commands: list[list[str]] = []

    def runner(command: Sequence[str]) -> CommandOutcome:
        commands.append(list(command))
        return CommandOutcome(0, f"{prefix}0123456 deps/example\n")

    diagnostic = submodule_diagnostic(tmp_path, runner)

    assert diagnostic.status == status
    assert detail in diagnostic.detail
    assert commands == [
        ["git", "-C", str(tmp_path), "submodule", "status", "--recursive"]
    ]


def test_root_ownership_scan_prunes_git_and_hardware(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The ownership walk must never descend into Git metadata or ``hw``."""
    for excluded in (tmp_path / ".git", tmp_path / "hw"):
        excluded.mkdir()
        (excluded / "never-inspect").write_text("ignored")
    (tmp_path / "ordinary").mkdir()

    def guarded_lstat(path: Path) -> object:
        if (tmp_path / "hw") == path or (tmp_path / "hw") in path.parents:
            pytest.fail("ownership scan inspected hw/")
        if (tmp_path / ".git") == path or (tmp_path / ".git") in path.parents:
            pytest.fail("ownership scan inspected .git/")
        return SimpleNamespace(st_uid=1234)

    monkeypatch.setattr(Path, "lstat", guarded_lstat)

    scan = scan_root_owned_paths(tmp_path, uid=1234)

    assert scan.count == 0
    assert scan.errors == ()


def test_root_ownership_scan_reports_traversal_errors(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """An unreadable subtree must not be silently reported as ownership-clean."""

    def failed_walk(
        _root: Path, *, onerror: Callable[[OSError], None], **_kwargs: object
    ) -> Iterator[tuple[str, list[str], list[str]]]:
        onerror(PermissionError(13, "permission denied", str(tmp_path / "blocked")))
        return iter(())

    monkeypatch.setattr(frost.os, "walk", failed_walk)

    scan = scan_root_owned_paths(tmp_path, uid=1234)

    assert scan.count == 0
    assert "permission denied" in scan.errors[0]


def test_missing_and_private_cache_diagnostics_do_not_mutate(tmp_path: Path) -> None:
    """Doctor reports cache state but neither creates nor repairs it."""
    cache = tmp_path / "cache"

    missing = cache_diagnostics(cache, os.getuid())
    assert missing[0].status == "PASS"
    assert not cache.exists()

    cache.mkdir(mode=0o700)
    private = cache_diagnostics(cache, os.getuid())
    assert private[0].status == "PASS"
    assert stat.S_IMODE(cache.stat().st_mode) == 0o700


def test_missing_cache_fails_when_parent_is_not_writable(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Doctor must catch a cache root that workflows cannot populate."""
    monkeypatch.setattr(frost.os, "access", lambda _path, _mode: False)

    diagnostic = cache_diagnostics(tmp_path / "missing" / "cache", os.getuid())[0]

    assert diagnostic.status == "FAIL"
    assert "not a writable directory" in diagnostic.detail


def test_cache_path_defaults_and_preparation_are_secure(tmp_path: Path) -> None:
    """The cache honors XDG and is created with private permissions."""
    assert default_cache_directory({"XDG_CACHE_HOME": str(tmp_path / "xdg")}) == (
        tmp_path / "xdg" / "frost" / "container"
    )
    assert default_cache_directory({"HOME": str(tmp_path / "home")}) == (
        tmp_path / "home" / ".cache" / "frost" / "container"
    )

    cache = tmp_path / "created" / "container"
    prepare_cache_directory(cache, os.getuid())
    assert stat.S_IMODE(cache.stat().st_mode) == 0o700


def test_cache_symlinks_are_rejected(tmp_path: Path) -> None:
    """A cache mount may not redirect Docker writes through a symlink."""
    target = tmp_path / "target"
    target.mkdir()
    cache = tmp_path / "cache"
    cache.symlink_to(target, target_is_directory=True)

    assert cache_diagnostics(cache, os.getuid())[0].status == "FAIL"
    with pytest.raises(OSError, match="symbolic link"):
        prepare_cache_directory(cache, os.getuid())


def test_cache_entry_inspection_errors_are_failures(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Doctor must not call a partially unreadable executable cache healthy."""
    cache = tmp_path / "cache"
    cache.mkdir(mode=0o700)
    blocked = cache / "blocked"
    blocked.write_text("data")
    original_lstat = Path.lstat

    def selective_lstat(path: Path) -> os.stat_result:
        if path == blocked:
            raise PermissionError("blocked for test")
        return original_lstat(path)

    monkeypatch.setattr(Path, "lstat", selective_lstat)

    diagnostic = cache_diagnostics(cache, os.getuid())[0]

    assert diagnostic.status == "FAIL"
    assert "blocked for test" in diagnostic.detail


def test_doctor_gates_docker_checks_and_remains_read_only(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A missing CLI skips dependent checks while local diagnostics continue."""
    home = tmp_path / "home"
    cache = home / ".cache" / "frost" / "container"

    def unexpected_runner(command: Sequence[str]) -> CommandOutcome:
        pytest.fail(f"unexpected command: {command}")

    status = run_doctor(
        repository_root=tmp_path,
        image="frost",
        uid=0,
        gid=0,
        environment={"HOME": str(home)},
        command_runner=unexpected_runner,
        docker_finder=lambda _name: None,
    )

    output = capsys.readouterr().out
    assert status == 1
    assert "[FAIL] Docker CLI" in output
    assert "[SKIP] Docker daemon" in output
    assert "[SKIP] Docker image" in output
    assert "[SKIP] Image probe" in output
    assert "[PASS] Submodules" in output
    assert not cache.exists()


def test_doctor_does_not_inspect_an_image_when_daemon_fails(tmp_path: Path) -> None:
    """Image commands are gated on a healthy Docker daemon."""
    commands: list[list[str]] = []
    outcomes = iter(
        (
            CommandOutcome(0, "Docker version 28"),
            CommandOutcome(1, stderr="daemon unavailable"),
        )
    )

    def runner(command: Sequence[str]) -> CommandOutcome:
        commands.append(list(command))
        return next(outcomes)

    assert (
        run_doctor(
            repository_root=tmp_path,
            image="frost",
            uid=0,
            gid=0,
            environment={"HOME": str(tmp_path)},
            command_runner=runner,
            docker_finder=lambda _name: "/usr/bin/docker",
        )
        == 1
    )
    assert commands == [
        ["docker", "--version"],
        ["docker", "info", "--format", "{{.ServerVersion}}"],
    ]


def test_doctor_marks_probe_dependents_skipped_for_invalid_inventory(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A malformed image inventory fails the probe and marks dependents SKIP."""
    outcomes = iter(
        (
            CommandOutcome(0, "Docker version 28"),
            CommandOutcome(0, "28.3.3"),
            CommandOutcome(0, "sha256:1234"),
            CommandOutcome(0, "not-json"),
        )
    )

    status = run_doctor(
        repository_root=tmp_path,
        image="frost",
        uid=0,
        gid=0,
        environment={"HOME": str(tmp_path)},
        command_runner=lambda _command: next(outcomes),
        docker_finder=lambda _name: "/usr/bin/docker",
    )

    output = capsys.readouterr().out
    assert status == 1
    assert "[FAIL] Image probe" in output
    assert "[SKIP] Image runtime" in output
    assert "[SKIP] Image freshness" in output
    assert "[SKIP] Pinned tools" in output


def test_doctor_successfully_aggregates_a_valid_image_inventory(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A fully compatible image and healthy checkout produce a zero status."""
    versions = {
        "VERILATOR_VERSION": "5.050",
        "YOSYS_VERSION": "0.64",
        "SBY_VERSION": "0.63",
        "Z3_VERSION": "4.15.0",
        "BOOLECTOR_VERSION": "3.2.4",
        "XPACK_RISCV_VERSION": "15.2.0-1",
        "CLANG_TIDY_VERSION": "18.1.3",
        "VERIBLE_VERSION": "0.0-4051-g9fdb4057",
        "COCOTB_VERSION": "2.0.1",
        "PYTEST_VERSION": "9.1.1",
        "PYTEST_COV_VERSION": "7.1.0",
        "PRE_COMMIT_VERSION": "4.6.0",
        "CLICK_VERSION": "8.4.2",
    }
    dockerfile = tmp_path / "Dockerfile"
    dockerfile.write_text(
        "".join(f"ARG {name}={version}\n" for name, version in versions.items())
    )
    entrypoint = tmp_path / "docker_entrypoint.py"
    entrypoint.write_text("#!/usr/bin/env python3\n")
    tools = {
        tool: {
            "version": (
                versions[argument].rsplit("-", maxsplit=1)[0]
                if tool == "riscv_gcc"
                else versions[argument]
            )
        }
        for tool, argument in frost.TOOL_VERSION_ARGUMENTS.items()
    }
    probe = json.dumps(
        {
            "architecture": "x86_64",
            "python": "3.12.3",
            "entrypoint_mode": 0o755,
            "fingerprints": {
                "Dockerfile": sha256_file(dockerfile),
                "docker_entrypoint.py": sha256_file(entrypoint),
            },
            "tools": tools,
        }
    )
    outcomes = iter(
        (
            CommandOutcome(0, "Docker version 28"),
            CommandOutcome(0, "28.3.3"),
            CommandOutcome(0, "sha256:1234"),
            CommandOutcome(0, probe),
        )
    )

    status = run_doctor(
        repository_root=tmp_path,
        image="frost",
        uid=os.getuid(),
        gid=os.getgid(),
        environment={"HOME": str(tmp_path)},
        command_runner=lambda _command: next(outcomes),
        docker_finder=lambda _name: "/usr/bin/docker",
    )

    output = capsys.readouterr().out
    assert status == 0
    assert "[PASS] Image probe" in output
    assert "[PASS] Image runtime" in output
    assert "[PASS] Image freshness" in output
    assert "[PASS] Pinned tools" in output
    assert "0 failed" in output


def test_fast_checks_run_exact_lanes_keep_going_and_report_first_failure(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Ordinary lane failures aggregate, preserve order, status, and timings."""
    commands: list[list[str]] = []
    statuses = iter((3, 4))
    clock = iter((10.0, 11.25, 20.0, 22.5))

    def runner(command: Sequence[str]) -> int:
        commands.append(list(command))
        return next(statuses)

    status = run_fast_checks(
        repository_root=tmp_path,
        image="frost",
        uid=1234,
        gid=5678,
        environment={
            "PYTEST_ADDOPTS": "-q",
            "FROST_SKIP_SUBMODULE_INIT": "0",
        },
        cache_directory=tmp_path / "cache",
        fail_fast=False,
        command_runner=runner,
        clock=lambda: next(clock),
    )

    assert status == 3
    assert len(commands) == 2
    assert [command[command.index("frost") + 1 :] for command in commands] == [
        ["pre-commit", "run", "--all-files"],
        [
            "pytest",
            "tests",
            "-m",
            "not cocotb and not synthesis and not formal and not slow",
            "-v",
        ],
    ]
    for command in commands:
        assert "PYTEST_ADDOPTS" not in command
        assert "FROST_SKIP_SUBMODULE_INIT=1" in command
        assert "FROST_SKIP_SUBMODULE_INIT" not in command
    output = capsys.readouterr().out
    assert "1.25s" in output
    assert "2.50s" in output
    assert output.index("Lint") < output.index("Fast Python Tests")


def test_fast_checks_fail_fast_skips_the_second_lane(tmp_path: Path) -> None:
    """Fail-fast mode stops after the first ordinary failure."""
    commands: list[list[str]] = []

    def runner(command: Sequence[str]) -> int:
        commands.append(list(command))
        return 7

    times = iter((1.0, 1.5))
    status = run_fast_checks(
        repository_root=tmp_path,
        image="frost",
        uid=1234,
        gid=5678,
        environment={},
        cache_directory=tmp_path / "cache",
        fail_fast=True,
        command_runner=runner,
        clock=lambda: next(times),
    )

    assert status == 7
    assert len(commands) == 1


def test_fast_checks_return_success_when_both_lanes_pass(tmp_path: Path) -> None:
    """The aggregate command succeeds only after both fast lanes pass."""
    commands: list[list[str]] = []

    def runner(command: Sequence[str]) -> int:
        commands.append(list(command))
        return 0

    times = iter((1.0, 1.1, 2.0, 2.2))
    status = run_fast_checks(
        repository_root=tmp_path,
        image="frost",
        uid=1234,
        gid=5678,
        environment={},
        cache_directory=tmp_path / "cache",
        fail_fast=False,
        command_runner=runner,
        clock=lambda: next(times),
    )

    assert status == 0
    assert len(commands) == 2


def test_fast_checks_stop_after_docker_infrastructure_failure(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Docker launch failures stop even when ordinary failures would aggregate."""
    commands: list[list[str]] = []

    def runner(command: Sequence[str]) -> int:
        commands.append(list(command))
        return 125

    times = iter((1.0, 1.5))
    status = run_fast_checks(
        repository_root=tmp_path,
        image="frost",
        uid=1234,
        gid=5678,
        environment={},
        cache_directory=tmp_path / "cache",
        fail_fast=False,
        command_runner=runner,
        clock=lambda: next(times),
    )

    assert status == 125
    assert len(commands) == 1
    assert "SKIP" in capsys.readouterr().out
