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

"""Tests for development-container startup behavior."""

import subprocess
import sys
from pathlib import Path

import pytest

import docker_entrypoint


def test_checkout_without_submodule_configuration_needs_no_init(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """A source tree with no .gitmodules should not invoke Git."""
    monkeypatch.setattr(docker_entrypoint, "WORKSPACE", tmp_path)

    assert not docker_entrypoint.submodules_need_init()


@pytest.mark.parametrize(
    ("status_output", "expected"),
    (
        (" 1111111 sw/FreeRTOS-Kernel (heads/main)\n", False),
        ("-2222222 sw/apps/coremark_pro/coremark-pro\n", True),
        (
            " 1111111 sw/FreeRTOS-Kernel (heads/main)\n"
            "-2222222 sw/apps/riscv_tests/riscv-tests/env\n",
            True,
        ),
    ),
)
def test_submodule_status_covers_every_configured_and_nested_module(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    status_output: str,
    expected: bool,
) -> None:
    """Recursive ``git submodule status`` decides init, so nested modules count.

    It replaced a probe of two hard-coded marker files, which said nothing
    about the rest of the tree.
    """
    (tmp_path / ".gitmodules").write_text('[submodule "example"]\n')
    monkeypatch.setattr(docker_entrypoint, "WORKSPACE", tmp_path)

    def fake_run(
        command: list[str], **kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        assert command == [
            "git",
            "-C",
            str(tmp_path),
            "submodule",
            "status",
            "--recursive",
        ]
        assert kwargs == {"check": True, "capture_output": True, "text": True}
        return subprocess.CompletedProcess(command, 0, stdout=status_output, stderr="")

    monkeypatch.setattr(docker_entrypoint.subprocess, "run", fake_run)

    assert docker_entrypoint.submodules_need_init() is expected


def test_main_can_skip_submodule_initialization_for_tooling_only_jobs(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Fast CI jobs should not fetch large submodules they never consume."""
    monkeypatch.setenv(docker_entrypoint.SKIP_SUBMODULE_INIT_ENV, "1")
    monkeypatch.setattr(
        docker_entrypoint,
        "submodules_need_init",
        lambda: pytest.fail("submodule status should be skipped"),
    )
    monkeypatch.setattr(sys, "argv", ["docker_entrypoint.py"])

    assert docker_entrypoint.main() == 0
