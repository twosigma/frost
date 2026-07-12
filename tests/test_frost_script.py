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

from pathlib import Path

import pytest

from scripts.frost import (
    build_docker_command,
    forwarded_environment_names,
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
