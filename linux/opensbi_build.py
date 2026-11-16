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
STAMP_FORMAT = "frost-opensbi"


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


def make_arguments(cross: str, description: str = "") -> list[str]:
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
        f"OPENSBI_VERSION_GIT={description}",
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


def source_identity(environment: Mapping[str, str]) -> dict[str, str] | None:
    """Identify source contents, or disable reuse when Git cannot identify them."""
    source = OPENSBI_DIR.resolve()
    git = ["git", "-c", f"safe.directory={source}", "-C", str(source)]
    try:
        top = command_output(
            [*git, "rev-parse", "--show-toplevel"], environment
        ).strip()
        if Path(top).resolve() != source:
            raise ValueError(
                "Git metadata does not identify the OpenSBI source directory"
            )
        revision = command_output([*git, "rev-parse", "HEAD"], environment).strip()
        description = command_output(
            [*git, "describe", "--always"], environment
        ).strip()
        files = command_output(
            [*git, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            environment,
        )
        contents = hashlib.sha256()
        for name in sorted(set(files.split("\0")) - {""}):
            path = source / name
            contents.update(os.fsencode(name) + b"\0")
            if path.is_symlink():
                data = b"symlink\0" + os.fsencode(os.readlink(path))
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
    except (OSError, subprocess.SubprocessError, UnicodeError, ValueError) as error:
        detail = (
            error.stderr
            if isinstance(error, subprocess.CalledProcessError)
            else str(error)
        )
        reason = (detail or str(error)).splitlines()[0][:300]
        print(
            f"opensbi_build.py: source identity unavailable ({reason}); "
            "rebuilding without a stamp",
            file=sys.stderr,
        )
        return None


def build_inputs(
    cross: str, environment: Mapping[str, str], source: dict[str, str]
) -> dict[str, object]:
    """Describe every selected input without relying on file timestamps."""
    tools = {}
    for tool in ("gcc", "as", "ld", "ar", "objcopy"):
        command = cross + tool
        path = shutil.which(command, path=environment.get("PATH"))
        tools[command] = {
            "path": str(Path(path).resolve()) if path else None,
            "version": command_output([command, "--version"], environment),
        }
    return {
        "builder": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "source_path": str(OPENSBI_DIR.resolve()),
        "source": source,
        "defconfig": hashlib.sha256(FROST_DEFCONFIG.read_bytes()).hexdigest(),
        "arguments": make_arguments(cross, source["description"]),
        "environment": {
            key: value
            for key, value in environment.items()
            if key not in {"PATH", "HOME", "TMPDIR"}
        },
        "toolchain": tools,
    }


def regular_output(path: Path) -> bool:
    """Require a regular file reached without following any symlink."""
    return path.is_file() and not any(
        part.is_symlink() for part in (path, *path.parents)
    )


def read_stamp(path: Path) -> dict[str, object] | None:
    """Read a stamp carrying this helper's format marker."""
    try:
        if not regular_output(path):
            return None
        value = json.loads(path.read_text())
        if (
            isinstance(value, dict)
            and value.get("format") == STAMP_FORMAT
            and value.get("schema") == 2
            and isinstance(value.get("inputs"), dict)
            and isinstance(value.get("outputs"), dict)
        ):
            return value
    except (OSError, UnicodeError, ValueError):
        pass
    return None


def firmware_identity(out_dir: Path) -> dict[str, dict[str, str | int]] | None:
    """Hash both complete firmware files before stamping or reusing them."""
    outputs: dict[str, dict[str, str | int]] = {}
    try:
        for path in firmware_paths(out_dir):
            if not regular_output(path):
                return None
            data = path.read_bytes()
            if not data:
                return None
            outputs[path.name] = {
                "size": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
            }
    except OSError:
        return None
    return outputs


def output_directory(value: str) -> Path:
    """Reject an empty command-line output path before converting it to Path."""
    if not value:
        raise argparse.ArgumentTypeError("OpenSBI output directory must not be empty")
    return Path(value)


def checked_output_directory(path: Path) -> Path:
    """Reject symlink paths and directories containing build inputs."""
    absolute = path.absolute()
    if any(part.is_symlink() for part in (absolute, *absolute.parents)):
        sys.exit(f"opensbi_build.py: refusing symlink output path: {path}")
    absolute = absolute.resolve()
    if any(
        source.resolve().is_relative_to(absolute)
        for source in (OPENSBI_DIR, FROST_DEFCONFIG, Path(__file__))
    ):
        sys.exit(
            f"opensbi_build.py: output directory contains build inputs: {absolute}"
        )
    return absolute


def remove_output_directory(out_dir: Path) -> None:
    """Replace only empty, stamped, or recognisable OpenSBI output directories."""
    checked_output_directory(out_dir)
    if not out_dir.exists():
        return
    if not out_dir.is_dir():
        sys.exit(f"opensbi_build.py: output path is not a directory: {out_dir}")
    markers = (
        ("platform/generic/kconfig/auto.conf", "platform/generic/kconfig/autoconf.h"),
        (
            "platform/generic/firmware/fw_jump.bin",
            "platform/generic/firmware/fw_jump.elf",
        ),
    )
    recognised = any(
        all(regular_output(out_dir / name) for name in pair) for pair in markers
    )
    if (
        next(out_dir.iterdir(), None) is not None
        and read_stamp(out_dir / BUILD_STAMP) is None
        and not recognised
    ):
        sys.exit(
            "opensbi_build.py: refusing to replace unrecognised non-empty "
            f"output directory: {out_dir}"
        )
    shutil.rmtree(out_dir)


def build(out_dir: Path, cross: str, jobs: int, verbose: bool = False) -> Path:
    """Reuse matching firmware, or build fw_jump in an empty output directory."""
    if not (OPENSBI_DIR / "Makefile").exists():
        sys.exit(
            "opensbi_build.py: linux/opensbi is not initialized "
            "(run: git submodule update --init linux/opensbi)"
        )
    out_dir = checked_output_directory(out_dir)
    out_dir.parent.mkdir(parents=True, exist_ok=True)
    # The lock survives replacement of the output directory by either caller.
    with (out_dir.parent / f".{out_dir.name}.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        environment = build_environment()
        source = source_identity(environment)
        inputs = build_inputs(cross, environment, source) if source else None
        stamp = out_dir / BUILD_STAMP
        fw_bin, _ = firmware_paths(out_dir)
        recorded = read_stamp(stamp)
        outputs = firmware_identity(out_dir)
        if (
            inputs is not None
            and recorded is not None
            and outputs is not None
            and recorded.get("inputs") == inputs
            and recorded.get("outputs") == outputs
        ):
            return fw_bin
        remove_output_directory(out_dir)
        out_dir.mkdir()
        cmd = [
            "make",
            "-C",
            str(OPENSBI_DIR),
            f"-j{jobs}",
            f"O={out_dir}",
            *make_arguments(cross, source["description"] if source else ""),
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
        outputs = firmware_identity(out_dir)
        if outputs is None:
            sys.exit(
                f"opensbi_build.py: build produced no fw_jump image under {out_dir}"
            )
        if inputs is not None:
            record = {
                "format": STAMP_FORMAT,
                "schema": 2,
                "inputs": inputs,
                "outputs": outputs,
            }
            pending = stamp.with_suffix(".tmp")
            pending.write_text(json.dumps(record, sort_keys=True, indent=2) + "\n")
            pending.replace(stamp)
        return fw_bin


def main() -> int:
    """Parse arguments and build the firmware."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--out",
        required=True,
        type=output_directory,
        help="OpenSBI build directory (O=)",
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
