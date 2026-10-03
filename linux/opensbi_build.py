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

Builds the generic platform with ``opensbi_frost_defconfig``, the firmware at
0x80000000 and the payload at +2 MiB. An empty FW_JUMP_FDT_OFFSET passes the
packer's DTB address in a1 through unchanged, and FDT_ASSUME_MASK=7 lets
libfdt trust that DTB. The linux/opensbi submodule is unmodified: every
setting is an OpenSBI Make variable.

Writes <out>/platform/generic/firmware/fw_jump.{bin,elf}. The default cross
prefix is riscv64-linux- (the Bootlin toolchain). FROST_LINUX_CROSS_COMPILE or
--cross selects another, whose linker must support PIE.
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

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


def firmware_paths(out_dir: Path) -> tuple[Path, Path]:
    """Return the (bin, elf) paths of the fw_jump build under ``out_dir``."""
    fw_dir = out_dir / "platform" / "generic" / "firmware"
    return fw_dir / "fw_jump.bin", fw_dir / "fw_jump.elf"


def build(out_dir: Path, cross: str, jobs: int, verbose: bool = False) -> Path:
    """Build fw_jump into ``out_dir`` and return the .bin path."""
    if not (OPENSBI_DIR / "Makefile").exists():
        sys.exit(
            "opensbi_build.py: linux/opensbi is not initialized "
            "(run: git submodule update --init linux/opensbi)"
        )
    out_dir = out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        "make",
        "-C",
        str(OPENSBI_DIR),
        f"-j{jobs}",
        f"O={out_dir}",
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
    result = subprocess.run(
        cmd,
        cwd=OPENSBI_DIR,
        stdout=None if verbose else subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        if result.stdout:
            print(result.stdout[-4000:], file=sys.stderr)
        sys.exit(f"opensbi_build.py: OpenSBI build failed (exit {result.returncode})")
    fw_bin, fw_elf = firmware_paths(out_dir)
    if not fw_bin.exists() or not fw_elf.exists():
        sys.exit(f"opensbi_build.py: build produced no fw_jump image under {out_dir}")
    return fw_bin


def main() -> int:
    """Parse arguments and build the firmware."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--out", required=True, type=Path, help="OpenSBI build directory (O=)"
    )
    parser.add_argument(
        "--cross",
        default=os.environ.get("FROST_LINUX_CROSS_COMPILE", "riscv64-linux-"),
        help="cross-toolchain prefix with a PIE-capable linker "
        "(default: riscv64-linux-, or FROST_LINUX_CROSS_COMPILE)",
    )
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    parser.add_argument("--verbose", action="store_true", help="stream the make output")
    args = parser.parse_args()
    fw_bin = build(args.out, args.cross, args.jobs, args.verbose)
    print(f"opensbi_build.py: {fw_bin} ({fw_bin.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
