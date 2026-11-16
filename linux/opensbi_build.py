#!/usr/bin/env python3

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

"""Build OpenSBI fw_jump for the FROST boot layout.

Build the generic platform with ``opensbi_frost_defconfig``, firmware at
0x80000000, and payload at +2 MiB. FW_JUMP_FDT_OFFSET is empty to preserve the
packer's DTB address in a1; FDT_ASSUME_MASK=7 lets libfdt trust it. Configure
linux/opensbi through Make variables without modifying the submodule.

Writes <out>/platform/generic/firmware/fw_jump.{bin,elf}. The default cross
prefix is riscv64-linux- (the Bootlin toolchain), found on PATH or else in the
checkout's Buildroot output, linux/build-mmu/host/bin.
FROST_LINUX_CROSS_COMPILE or --cross selects another, whose linker must support
PIE.
"""

import argparse
import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Mapping
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "sw" / "apps"))
from riscv_toolchain import default_riscv_prefix  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
OPENSBI_DIR = REPO_ROOT / "linux" / "opensbi"
FROST_DEFCONFIG = REPO_ROOT / "linux" / "opensbi_frost_defconfig"
# The Makefile resolves PLATFORM_DEFCONFIG under platform/generic/configs/.
GENERIC_CONFIGS_DIR = OPENSBI_DIR / "platform" / "generic" / "configs"
LIBFDT_ASSUME_MASK = 0x7  # ASSUME_VALID_DTB | ASSUME_VALID_INPUT | ASSUME_LATEST

FW_TEXT_START = 0x8000_0000
FW_JUMP_OFFSET = 0x20_0000

# The ISA string the firmware is compiled for: GCC 12+ needs the explicit
# Zicsr/Zifencei spelling, and OpenSBI's own code uses nothing beyond G+C.
PLATFORM_RISCV_ISA = "rv64imafdc_zicsr_zifencei"
PLATFORM_RISCV_ABI = "lp64d"
BUILD_STAMP = ".frost-build.json"


def firmware_paths(out_dir: Path) -> tuple[Path, Path]:
    """Return the (bin, elf) paths of the fw_jump build under ``out_dir``."""
    fw_dir = out_dir / "platform" / "generic" / "firmware"
    return fw_dir / "fw_jump.bin", fw_dir / "fw_jump.elf"


def default_cross(
    repo: Path = REPO_ROOT, environment: Mapping[str, str] = os.environ
) -> str:
    """Return FROST_LINUX_CROSS_COMPILE if set, else the Bootlin riscv64-linux- prefix.

    An empty setting selects unprefixed tools, as for a native build. The
    fallback looks on PATH, then in the checkout's Buildroot output, as the
    bare-metal build helpers do.
    """
    configured = environment.get("FROST_LINUX_CROSS_COMPILE")
    return default_riscv_prefix(repo) if configured is None else configured


def make_arguments(cross: str) -> list[str]:
    """Return the firmware options used by both make and the build stamp."""
    return [
        "PLATFORM=generic",
        f"CROSS_COMPILE={cross}",
        "PLATFORM_RISCV_XLEN=64",
        f"PLATFORM_RISCV_ISA={PLATFORM_RISCV_ISA}",
        f"PLATFORM_RISCV_ABI={PLATFORM_RISCV_ABI}",
        f"FW_TEXT_START=0x{FW_TEXT_START:x}",
        f"FW_JUMP_OFFSET=0x{FW_JUMP_OFFSET:x}",
        # Empty on purpose: pass a1 (the DTB address) through untouched.
        "FW_JUMP_FDT_OFFSET=",
        "FW_PAYLOAD=n",
        "FW_DYNAMIC=n",
        "PLATFORM_DEFCONFIG=" + os.path.relpath(FROST_DEFCONFIG, GENERIC_CONFIGS_DIR),
        f"platform-cflags-y=-DFDT_ASSUME_MASK={LIBFDT_ASSUME_MASK:#x}",
    ]


def build_environment() -> dict[str, str]:
    """Pass tool search paths, keeping inherited Make options out of the build."""
    names = (
        "PATH",
        "HOME",
        "TMPDIR",
        "SOURCE_DATE_EPOCH",
        "GCC_EXEC_PREFIX",
        "COMPILER_PATH",
        "LIBRARY_PATH",
        "CPATH",
        "C_INCLUDE_PATH",
    )
    return {
        **{name: os.environ[name] for name in names if name in os.environ},
        "LC_ALL": "C",
    }


def command_output(command: list[str], environment: Mapping[str, str]) -> str:
    """Read a short, bounded Git or toolchain query."""
    return subprocess.run(
        command,
        cwd=OPENSBI_DIR,
        env=environment,
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    ).stdout


def source_identity(environment: Mapping[str, str]) -> dict[str, str]:
    """Hash the revision and tracked and untracked source contents, including edits."""
    git = ["git", "-C", str(OPENSBI_DIR)]
    revision = command_output([*git, "rev-parse", "HEAD"], environment).strip()
    description = command_output([*git, "describe", "--always"], environment).strip()
    files = command_output(
        [*git, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        environment,
    )
    contents = hashlib.sha256()
    for name in sorted(set(files.split("\0")) - {""}):
        path = OPENSBI_DIR / name
        contents.update(os.fsencode(name) + b"\0")
        if path.is_symlink():
            data = (
                b"symlink\0"
                + os.fsencode(os.readlink(path))
                + b"\0"
                + path.read_bytes()
            )
        elif path.is_file():
            data = str(path.stat().st_mode).encode() + b"\0" + path.read_bytes()
        else:
            data = b"missing"
        contents.update(hashlib.sha256(data).digest())
    return {
        "revision": revision,
        "description": description,
        "contents": contents.hexdigest(),
    }


def build_inputs(cross: str, environment: Mapping[str, str]) -> str:
    """Describe every selected input without relying on file timestamps."""
    tools = {}
    for tool in ("gcc", "as", "ld", "ar", "objcopy"):
        command = cross + tool
        tools[command] = {
            "path": shutil.which(command, path=environment.get("PATH")),
            "version": command_output([command, "--version"], environment),
        }
    return (
        json.dumps(
            {
                "schema": 1,
                "builder": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                "source_path": str(OPENSBI_DIR.resolve()),
                "source": source_identity(environment),
                "defconfig": hashlib.sha256(FROST_DEFCONFIG.read_bytes()).hexdigest(),
                "arguments": make_arguments(cross),
                "environment": dict(environment),
                "toolchain": tools,
            },
            sort_keys=True,
            indent=2,
        )
        + "\n"
    )


def build(out_dir: Path, cross: str, jobs: int, verbose: bool = False) -> Path:
    """Reuse matching firmware, or build fw_jump in an empty output directory."""
    if not (OPENSBI_DIR / "Makefile").exists():
        sys.exit(
            "opensbi_build.py: linux/opensbi is not initialized "
            "(run: git submodule update --init linux/opensbi)"
        )
    out_dir = out_dir.resolve()
    if any(
        path.resolve().is_relative_to(out_dir)
        for path in (OPENSBI_DIR, FROST_DEFCONFIG, Path(__file__))
    ):
        sys.exit(f"opensbi_build.py: output directory contains build inputs: {out_dir}")
    out_dir.parent.mkdir(parents=True, exist_ok=True)
    # The lock survives replacement of the output directory by either caller.
    with (out_dir.parent / f".{out_dir.name}.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        environment = build_environment()
        inputs = build_inputs(cross, environment)
        stamp = out_dir / BUILD_STAMP
        fw_bin, fw_elf = firmware_paths(out_dir)
        try:
            matches = stamp.read_text() == inputs
        except (OSError, UnicodeError):
            matches = False
        if matches and fw_bin.is_file() and fw_elf.is_file():
            return fw_bin
        if out_dir.exists():
            shutil.rmtree(out_dir)
        out_dir.mkdir()
        cmd = [
            "make",
            "-C",
            str(OPENSBI_DIR),
            f"-j{jobs}",
            f"O={out_dir}",
            *make_arguments(cross),
        ]
        with tempfile.TemporaryFile(mode="w+t") as log:
            result = subprocess.run(
                cmd,
                cwd=OPENSBI_DIR,
                env=environment,
                stdout=None if verbose else log,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
                timeout=600,
            )
            if result.returncode != 0:
                log.seek(max(0, log.tell() - 4000))
                print(log.read(), file=sys.stderr)
                sys.exit(
                    f"opensbi_build.py: OpenSBI build failed (exit {result.returncode})"
                )
        if not fw_bin.is_file() or not fw_elf.is_file():
            sys.exit(
                f"opensbi_build.py: build produced no fw_jump image under {out_dir}"
            )
        pending = stamp.with_suffix(".tmp")
        pending.write_text(inputs)
        pending.replace(stamp)
        return fw_bin


def main() -> int:
    """Parse arguments and build the firmware."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--out", required=True, type=Path, help="OpenSBI build directory (O=)"
    )
    parser.add_argument(
        "--cross",
        default=default_cross(),
        help="cross-toolchain prefix with a PIE-capable linker (default: "
        "FROST_LINUX_CROSS_COMPILE if set, else riscv64-linux- from PATH or "
        "linux/build-mmu/host/bin)",
    )
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    parser.add_argument("--verbose", action="store_true", help="stream the make output")
    args = parser.parse_args()
    fw_bin = build(args.out, args.cross, args.jobs, args.verbose)
    print(f"opensbi_build.py: {fw_bin} ({fw_bin.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
