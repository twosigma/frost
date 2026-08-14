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

"""Unit tests for the clang-tidy pre-commit wrapper."""

import importlib.util
import subprocess
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest


SCRIPT_PATH = Path(__file__).resolve().parent.parent / "scripts" / "run-clang-tidy.py"


def _load_wrapper() -> ModuleType:
    """Load the hyphenated wrapper filename as a Python module."""
    spec = importlib.util.spec_from_file_location("frost_run_clang_tidy", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


wrapper = _load_wrapper()


def _write_common_mk(root_dir: Path) -> None:
    """Write a minimal common.mk with the assignment forms used by FROST."""
    common_dir = root_dir / "sw" / "common"
    common_dir.mkdir(parents=True)
    (common_dir / "common.mk").write_text(
        """\
MABI ?= lp64d
OPT_LEVEL ?= -O3
RISCV_FLAGS = -march=rv64imafdc -mabi=$(MABI) $(OPT_LEVEL)
FPGA_CPU_CLK_FREQ ?= 300000000
CFLAGS = $(RISCV_FLAGS) -I. $(addprefix -I,$(INCLUDE_DIR)) -DFPGA_CPU_CLK_FREQ=$(FPGA_CPU_CLK_FREQ)
"""
    )


def test_extract_flags_uses_make_expansion(tmp_path: Path) -> None:
    """Resolve conditional assignments and nested Make variables."""
    _write_common_mk(tmp_path)

    flags, clock = wrapper.extract_flags_from_common_mk(tmp_path)

    assert flags == "-march=rv64imafdc -mabi=lp64d -O3"
    assert clock == "300000000"


def test_extract_flags_honors_environment_overrides(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Preserve Make's environment override behavior for question assignments."""
    _write_common_mk(tmp_path)
    monkeypatch.setenv("MABI", "lp64f")
    monkeypatch.setenv("FPGA_CPU_CLK_FREQ", "125000000")

    flags, clock = wrapper.extract_flags_from_common_mk(tmp_path)

    assert "-mabi=lp64f" in flags
    assert clock == "125000000"


def test_extract_flags_reports_make_errors(tmp_path: Path) -> None:
    """Surface Make evaluation failures instead of returning invalid flags."""
    common_dir = tmp_path / "sw" / "common"
    common_dir.mkdir(parents=True)
    (common_dir / "common.mk").write_text("$(error broken configuration)\n")

    with pytest.raises(RuntimeError, match="broken configuration"):
        wrapper.extract_flags_from_common_mk(tmp_path)


def test_extract_flags_for_file_uses_app_makefile(tmp_path: Path) -> None:
    """Use app ABI and include overrides, resolving paths from the app directory."""
    _write_common_mk(tmp_path)
    app_dir = tmp_path / "sw" / "apps" / "demo"
    app_dir.mkdir(parents=True)
    (app_dir / "Makefile").write_text(
        """\
MABI := lp64f
INCLUDE_DIR := include
include ../../common/common.mk
"""
    )
    default_flags, default_clock = wrapper.extract_flags_from_common_mk(tmp_path)

    flags, clock = wrapper.extract_flags_for_file(
        "sw/apps/demo/main.c",
        tmp_path,
        default_flags,
        default_clock,
    )

    assert "-mabi=lp64f" in flags
    assert f"-I{app_dir}" in flags
    assert f"-I{app_dir / 'include'}" in flags
    assert clock == "300000000"


def test_run_clang_tidy_builds_resolved_command(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Pass resolved ABI, clock, and application include flags to clang-tidy."""
    commands: list[list[str]] = []

    def fake_run(command: list[str], **_: Any) -> subprocess.CompletedProcess[str]:
        """Record a successful clang-tidy invocation."""
        commands.append(command)
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(wrapper.subprocess, "run", fake_run)

    passed = wrapper.run_clang_tidy(
        "sw/apps/demo/main.c",
        Path("/repo"),
        "-march=rv64imafdc -mabi=lp64d -O3 -I/repo/sw/lib/include",
        "300000000",
    )

    assert passed
    assert commands == [
        [
            "clang-tidy",
            "--quiet",
            "--warnings-as-errors=clang-diagnostic-*",
            "sw/apps/demo/main.c",
            "--",
            "--target=riscv64-unknown-elf",
            "-DFPGA_CPU_CLK_FREQ=300000000",
            "-march=rv64imafdc",
            "-mabi=lp64d",
            "-O3",
            "-I/repo/sw/lib/include",
        ]
    ]


def test_run_clang_tidy_prints_and_returns_failure(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Expose clang-tidy diagnostics and report a failed file."""

    def fake_run(command: list[str], **_: Any) -> subprocess.CompletedProcess[str]:
        """Return representative diagnostics from a failed invocation."""
        return subprocess.CompletedProcess(
            command,
            7,
            "warning: suspicious code\n",
            "error: invalid source\n",
        )

    monkeypatch.setattr(wrapper.subprocess, "run", fake_run)

    passed = wrapper.run_clang_tidy("sw/lib/src/string.c", Path("/repo"), "", "1")

    assert not passed
    captured = capsys.readouterr()
    assert "clang-tidy failed for sw/lib/src/string.c (exit 7)" in captured.err
    assert "warning: suspicious code" in captured.err
    assert "error: invalid source" in captured.err


def test_run_clang_tidy_summarizes_non_blocking_findings(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Keep advisory checks visible even though only compiler diagnostics gate."""

    def fake_run(command: list[str], **_: Any) -> subprocess.CompletedProcess[str]:
        """Return a successful run containing two advisory diagnostics."""
        return subprocess.CompletedProcess(
            command,
            0,
            "demo.c:2:3: warning: first [readability-demo]\n"
            "demo.c:4:5: warning: second [bugprone-demo]\n"
            "2 warnings generated.\n",
            "",
        )

    monkeypatch.delenv("FROST_CLANG_TIDY_SHOW_ADVISORIES", raising=False)
    monkeypatch.setattr(wrapper.subprocess, "run", fake_run)

    assert wrapper.run_clang_tidy("demo.c", Path("/repo"), "", "1")
    captured = capsys.readouterr()
    assert "demo.c has 2 non-blocking finding(s)" in captured.err
    assert "first [readability-demo]" not in captured.err


def test_main_checks_every_file_and_propagates_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Return nonzero after any file fails without hiding later diagnostics."""
    checked_files: list[str] = []

    def fake_extract_flags(_: Path) -> tuple[str, str]:
        """Return a valid evaluated configuration."""
        return "-mabi=lp64d", "300000000"

    def fake_extract_file_flags(
        _file_path: str,
        _root_dir: Path,
        default_flags: str,
        default_clock: str,
    ) -> tuple[str, str]:
        """Return the default configuration for every synthetic file."""
        return default_flags, default_clock

    def fake_run_clang_tidy(
        file_path: str,
        _root_dir: Path,
        _riscv_flags: str,
        _fpga_clk_freq: str,
    ) -> bool:
        """Fail the first file and pass the second."""
        checked_files.append(file_path)
        return file_path.endswith("second.c")

    monkeypatch.setattr(wrapper, "extract_flags_from_common_mk", fake_extract_flags)
    monkeypatch.setattr(wrapper, "extract_flags_for_file", fake_extract_file_flags)
    monkeypatch.setattr(wrapper, "get_riscv_sysroot", lambda _root_dir: "/sysroot")
    monkeypatch.setattr(wrapper, "run_clang_tidy", fake_run_clang_tidy)
    monkeypatch.setattr(wrapper.sys, "argv", [str(SCRIPT_PATH), "first.c", "second.c"])

    assert wrapper.main() == 1
    assert checked_files == ["first.c", "second.c"]
