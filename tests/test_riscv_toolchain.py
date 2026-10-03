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

"""Compiler selection on hosts with or without a cached Linux toolchain."""

from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "sw" / "apps"))
try:
    from riscv_toolchain import DEFAULT_PREFIX, default_riscv_prefix
finally:
    sys.path.pop(0)


def test_path_precedes_buildroot_cache(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An explicit PATH installation takes precedence over cached tools."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    compiler = bin_dir / f"{DEFAULT_PREFIX}gcc"
    compiler.touch(mode=0o755)
    cached = tmp_path / "linux/build-mmu/host/bin/riscv64-linux-gcc"
    cached.parent.mkdir(parents=True)
    cached.touch(mode=0o755)
    monkeypatch.setenv("PATH", str(bin_dir))
    assert default_riscv_prefix(tmp_path) == DEFAULT_PREFIX


def test_native_build_uses_cached_compiler(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """With no compiler on PATH, native builds use the cached Buildroot compiler."""
    monkeypatch.setenv("PATH", "")
    compiler = tmp_path / "linux/build-mmu/host/bin/riscv64-linux-gcc"
    compiler.parent.mkdir(parents=True)
    compiler.touch(mode=0o755)
    assert default_riscv_prefix(tmp_path) == str(compiler)[:-3]


def test_unavailable_compiler_preserves_command_name(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Missing tools leave a useful command-not-found error for the caller."""
    monkeypatch.setenv("PATH", "")
    assert default_riscv_prefix(tmp_path) == DEFAULT_PREFIX
