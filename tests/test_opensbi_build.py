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

"""Exercise firmware reuse with a small Git tree and stand-in build tools."""

import importlib.util
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ("gcc", "as", "ld", "ar", "objcopy")


def git(source: Path, *args: str, input_text: str | None = None) -> str:
    """Run a bounded Git command against the test source tree."""
    return subprocess.run(
        ["git", "-C", str(source), *args],
        input=input_text,
        capture_output=True,
        text=True,
        timeout=30,
        check=True,
    ).stdout.strip()


def revision(source: Path, message: str) -> None:
    """Install a synthetic commit object without changing Git identity settings."""
    tree = git(source, "write-tree")
    commit = git(
        source,
        "hash-object",
        "-w",
        "-t",
        "commit",
        "--stdin",
        input_text=(
            f"tree {tree}\n"
            "author Test <test@example.invalid> 0 +0000\n"
            "committer Test <test@example.invalid> 0 +0000\n\n"
            f"{message}\n"
        ),
    )
    git(source, "update-ref", "HEAD", commit)


@pytest.fixture
def builder(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> ModuleType:
    """Load the helper with fake tools; each make requires an empty output tree."""
    spec = importlib.util.spec_from_file_location(
        "opensbi_build", ROOT / "linux/opensbi_build.py"
    )
    assert spec is not None and spec.loader is not None
    helper = importlib.util.module_from_spec(spec)
    saved_path = sys.path.copy()
    try:
        spec.loader.exec_module(helper)
    finally:
        sys.path[:] = saved_path
    source = tmp_path / "source"
    source.mkdir()
    (source / "Makefile").write_text("all:\n")
    (source / "driver.c").write_text("driver one\n")
    git(source, "init", "-q")
    git(source, "add", ".")
    revision(source, "first")
    config = tmp_path / "defconfig"
    config.write_text("CONFIG_DRIVER=y\n")
    monkeypatch.setattr(helper, "OPENSBI_DIR", source)
    monkeypatch.setattr(
        helper, "GENERIC_CONFIGS_DIR", source / "platform/generic/configs"
    )
    monkeypatch.setattr(helper, "FROST_DEFCONFIG", config)
    script = tmp_path / "builder.py"
    script.write_bytes((ROOT / "linux/opensbi_build.py").read_bytes())
    helper.__file__ = str(script)
    tools = tmp_path / "tools"
    tools.mkdir()
    for prefix in ("riscv64-linux-", "other-"):
        for name in TOOLS:
            path = tools / (prefix + name)
            path.write_text(f"#!/bin/sh\nprintf 'test {name} version 1\\n'\n")
            path.chmod(0o755)
    make = tools / "make"
    make.write_text(
        f"#!{sys.executable}\n"
        "import sys\n"
        "from pathlib import Path\n"
        "out = Path(next(a[2:] for a in sys.argv if a.startswith('O=')))\n"
        "assert not (out / 'old.o').exists(), 'incremental output was reused'\n"
        "assert not (out / '.frost-build.json').exists()\n"
        "with (out.parent / 'make-calls').open('a') as log: log.write('make\\n')\n"
        "(out / 'old.o').write_text('intermediate')\n"
        "firmware = out / 'platform/generic/firmware'\n"
        "firmware.mkdir(parents=True)\n"
        "for ext in ('bin', 'elf'):\n"
        "    (firmware / ('fw_jump.' + ext)).write_text('firmware')\n"
    )
    make.chmod(0o755)
    monkeypatch.setenv("PATH", str(tools) + os.pathsep + os.environ["PATH"])
    return helper


def test_unchanged_inputs_reuse_firmware(builder: ModuleType, tmp_path: Path) -> None:
    """A repeated invocation preserves intermediates and firmware timestamps."""
    out = tmp_path / "out"
    firmware = builder.build(out, "riscv64-linux-", 1)
    before = firmware.stat().st_mtime_ns
    assert builder.build(out, "riscv64-linux-", 8, verbose=True) == firmware
    assert firmware.stat().st_mtime_ns == before
    assert (tmp_path / "make-calls").read_text().splitlines() == ["make"]


@pytest.mark.parametrize(
    "change",
    [
        "defconfig",
        "revision",
        "tracked",
        "staged",
        "untracked",
        "untracked_edit",
        "untracked_delete",
        "symlink",
        "deleted",
        "mode",
        "builder",
        "prefix",
        "tool_path",
        "environment",
        *TOOLS,
        "PLATFORM_RISCV_ISA",
        "PLATFORM_RISCV_ABI",
        "FW_TEXT_START",
        "FW_JUMP_OFFSET",
        "LIBFDT_ASSUME_MASK",
    ],
)
def test_changed_input_discards_intermediates(
    builder: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    change: str,
) -> None:
    """Each determining input forces a complete build, even with preserved mtimes."""
    out = tmp_path / "out"
    source = builder.OPENSBI_DIR
    if change in ("untracked_edit", "untracked_delete"):
        (source / "added.c").write_text("driver two\n")
    if change == "symlink":
        (tmp_path / "linked.h").write_text("linked one\n")
        (source / "linked.h").symlink_to(tmp_path / "linked.h")
    builder.build(out, "riscv64-linux-", 1)
    prefix = "riscv64-linux-"
    if change == "revision":
        revision(source, "second")
    elif change in ("defconfig", "tracked", "staged", "builder"):
        assert builder.__file__ is not None
        path = {
            "defconfig": builder.FROST_DEFCONFIG,
            "tracked": source / "driver.c",
            "staged": source / "driver.c",
            "builder": Path(builder.__file__),
        }[change]
        old = path.stat()
        data = path.read_bytes()
        path.write_bytes(bytes([data[0] ^ 1]) + data[1:])
        os.utime(path, ns=(old.st_atime_ns, old.st_mtime_ns))
        if change == "staged":
            git(source, "add", "driver.c")
    elif change == "untracked":
        (source / "added.c").write_text("driver two\n")
    elif change == "untracked_edit":
        path = source / "added.c"
        before = path.stat()
        path.write_text("driver six\n")
        os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
    elif change == "untracked_delete":
        (source / "added.c").unlink()
    elif change == "symlink":
        (tmp_path / "linked.h").write_text("linked two\n")
    elif change == "deleted":
        (source / "driver.c").unlink()
    elif change == "mode":
        (source / "driver.c").chmod(0o755)
    elif change == "prefix":
        prefix = "other-"
    elif change == "tool_path":
        tools = tmp_path / "other-tools"
        tools.mkdir()
        for name in TOOLS:
            (tools / (prefix + name)).symlink_to(tmp_path / "tools" / (prefix + name))
        monkeypatch.setenv("PATH", str(tools) + os.pathsep + os.environ["PATH"])
    elif change == "environment":
        monkeypatch.setenv("SOURCE_DATE_EPOCH", "1234")
    elif change in TOOLS:
        (tmp_path / "tools" / (prefix + change)).write_text(
            "#!/bin/sh\necho 'version 2'\n"
        )
    else:
        value = getattr(builder, change)
        monkeypatch.setattr(
            builder, change, value + ("_zba" if isinstance(value, str) else 1)
        )
    builder.build(out, prefix, 1)
    assert (tmp_path / "make-calls").read_text().splitlines() == ["make", "make"]


@pytest.mark.parametrize("stamp", [None, b"", b"{broken", b"{}\n", b"\xff"])
def test_missing_or_corrupt_stamp_discards_intermediates(
    builder: ModuleType,
    tmp_path: Path,
    stamp: bytes | None,
) -> None:
    """Only a complete matching stamp permits firmware reuse."""
    out = tmp_path / "out"
    builder.build(out, "riscv64-linux-", 1)
    path = out / builder.BUILD_STAMP
    if stamp is None:
        path.unlink()
    else:
        path.write_bytes(stamp)
    builder.build(out, "riscv64-linux-", 1)
    assert (tmp_path / "make-calls").read_text().splitlines() == ["make", "make"]


@pytest.mark.parametrize("extension", ["bin", "elf"])
def test_missing_firmware_discards_intermediates(
    builder: ModuleType,
    tmp_path: Path,
    extension: str,
) -> None:
    """A stamp cannot stand in for either firmware output."""
    out = tmp_path / "out"
    builder.build(out, "riscv64-linux-", 1)
    (out / f"platform/generic/firmware/fw_jump.{extension}").unlink()
    builder.build(out, "riscv64-linux-", 1)
    assert (tmp_path / "make-calls").read_text().splitlines() == ["make", "make"]


def test_failed_build_has_no_stamp(builder: ModuleType, tmp_path: Path) -> None:
    """A partial firmware from a failed make must be discarded on retry."""
    out = tmp_path / "out"
    make = tmp_path / "tools/make"
    working = make.read_text()
    make.write_text(working + "sys.exit(1)\n")
    with pytest.raises(SystemExit, match="build failed"):
        builder.build(out, "riscv64-linux-", 1)
    assert not (out / builder.BUILD_STAMP).exists()
    make.write_text(working)
    builder.build(out, "riscv64-linux-", 1)
    assert (tmp_path / "make-calls").read_text().splitlines() == ["make", "make"]


def test_concurrent_callers_build_once(builder: ModuleType, tmp_path: Path) -> None:
    """Callers sharing an output directory serialize the check and replacement."""
    out = tmp_path / "out"
    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(
            executor.map(lambda _: builder.build(out, "riscv64-linux-", 1), range(2))
        )
    assert results[0] == results[1]
    assert (tmp_path / "make-calls").read_text().splitlines() == ["make"]


def test_refuse_to_delete_build_inputs(builder: ModuleType, tmp_path: Path) -> None:
    """An invalid output path must not remove its own sources or configuration."""
    with pytest.raises(SystemExit, match="contains build inputs"):
        builder.build(tmp_path, "riscv64-linux-", 1)
    assert (builder.OPENSBI_DIR / "driver.c").exists()


def test_parent_make_options_do_not_enter_firmware_build(
    builder: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Only the helper's explicit options configure the OpenSBI make."""
    for name in ("MAKEFLAGS", "MAKEOVERRIDES", "DEBUG", "LLVM"):
        monkeypatch.setenv(name, "unexpected")
        assert name not in builder.build_environment()
