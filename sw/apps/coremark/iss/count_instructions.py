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

"""Count CoreMark's timed-region instructions under Spike.

The count separates "the compiler emits more instructions" from "the core
retires them more slowly"; the second still needs a cocotb or board run. This
is a measurement tool, not part of any build or test flow.

The matrix uses fixed flag sets, not the Makefile's APP_TUNE_FLAGS, and every
row keeps the C extension. The port layer shifts the timed-region boundary
slightly, so absolute counts are estimates. See "Measurement limits" in
README.md.

    ./count_instructions.py
    ./count_instructions.py -- --param max-inline-insns-auto=200
    ./count_instructions.py --matrix

Run it inside the pinned image:

    ./scripts/frost.py run sw/apps/coremark/iss/count_instructions.py --matrix
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP_DIR = HERE.parent
COREMARK_DIR = APP_DIR / "coremark"
RISCV_PREFIX = os.environ.get("RISCV_PREFIX", "riscv64-linux-")

# common.mk's default extension set. Every row keeps C: the shipped CoreMark
# build leaves C out for FROST's fetch throughput, not for instruction count.
ISA = "rv64imafdc_zicsr_zicntr_zifencei_zba_zbb_zbc_zbs_zicond_zbkb_zbkc_zihintpause"
BASE_FLAGS = [
    "-mcmodel=medany",
    "-Wall",
    "-Wextra",
    "-nostdlib",
    "-nostartfiles",
    "-ffreestanding",
    "-static",
    "-fno-pie",
    "-no-pie",
    "-fno-stack-protector",
    "-fno-unwind-tables",
    "-fno-asynchronous-unwind-tables",
    "-ffunction-sections",
    "-fdata-sections",
    "-O3",
    "-funroll-loops",
    "-fno-strict-aliasing",
]

# Fixed flag sets; each row adds one option to the row before.
MATRIX = [
    ("stock", []),
    ("inline", ["--param", "max-inline-insns-auto=200"]),
    ("inline_sa", ["--param", "max-inline-insns-auto=200", "-fstrict-aliasing"]),
    (
        "full",
        [
            "--param",
            "max-inline-insns-auto=200",
            "-fstrict-aliasing",
            "-fira-algorithm=priority",
        ],
    ),
]

# Spike prints one of these per retired instruction under --log-commits -l.
FETCH_LINE = re.compile(r"^core\s+\d+: 0x")


def build(extra_flags: list[str], elf_path: Path) -> None:
    """Compile CoreMark plus the Spike port layer into elf_path."""
    command = [
        f"{RISCV_PREFIX}gcc",
        f"-march={ISA}",
        "-mabi=lp64d",
        *BASE_FLAGS,
        f"-I{HERE}",
        f"-I{APP_DIR}",
        f"-I{COREMARK_DIR}",
        "-DITERATIONS=1",
        "-DMEM_METHOD=MEM_STACK",
        '-DMEM_LOCATION="STACK"',
        '-DCOMPILER_VERSION="iss"',
        '-DCOMPILER_FLAGS="iss"',
        str(HERE / "crt0_spike.S"),
        str(HERE / "stub.c"),
        str(HERE / "core_portme.c"),
        *[
            str(COREMARK_DIR / name)
            for name in (
                "core_list_join.c",
                "core_main.c",
                "core_matrix.c",
                "core_state.c",
                "core_util.c",
            )
        ],
        "-T",
        str(HERE / "link_spike.ld"),
        "-Wl,--gc-sections",
        # Flat single-segment image; RWX is intended here.
        "-Wl,--no-warn-rwx-segments",
        "-lgcc",
        *extra_flags,
        "-o",
        str(elf_path),
    ]
    subprocess.run(command, check=True)


def count(elf_path: Path) -> tuple[int, int]:
    """Return (timed-region instructions, whole-program instructions)."""
    process = subprocess.Popen(
        ["spike", f"--isa={ISA}", "--log-commits", "-l", str(elf_path)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        errors="replace",
        bufsize=1,
    )
    assert process.stderr is not None
    total = 0
    markers: list[int] = []
    for line in process.stderr:
        if not FETCH_LINE.match(line):
            continue
        total += 1
        # start_time()/stop_time() are the program's only `cycle` reads.
        if "cycle" in line:
            markers.append(total)
    process.wait()
    if len(markers) != 2:
        raise RuntimeError(
            f"expected 2 timed-region markers, saw {len(markers)} in {total} "
            "instructions; did the program trap before finishing?"
        )
    return markers[1] - markers[0] - 1, total


def measure(extra_flags: list[str], work_dir: Path) -> tuple[int, int]:
    """Build and run one configuration."""
    elf_path = work_dir / "coremark.elf"
    build(extra_flags, elf_path)
    return count(elf_path)


def main() -> int:
    """Command-line entry point."""
    parser = argparse.ArgumentParser(
        description="Count CoreMark timed-region instructions under Spike",
    )
    parser.add_argument(
        "--matrix", action="store_true", help="measure the fixed flag-set matrix"
    )
    parser.add_argument(
        "flags", nargs="*", help="extra compiler flags (after --), without --matrix"
    )
    arguments = parser.parse_args()
    if arguments.matrix and arguments.flags:
        parser.error("--matrix uses fixed flag sets; drop the extra flags")

    for tool in (f"{RISCV_PREFIX}gcc", "spike"):
        if shutil.which(tool) is None:
            print(
                f"error: {tool} not found; run this inside the pinned image "
                "(./scripts/frost.py run ...)",
                file=sys.stderr,
            )
            return 1

    with tempfile.TemporaryDirectory(prefix="coremark_iss_") as temporary:
        work_dir = Path(temporary)
        if arguments.matrix:
            print(f"{'flags':<38}{'instructions':>20}")
            for name, flags in MATRIX:
                timed, _ = measure(flags, work_dir)
                print(f"{name:<38}{timed:>20,}")
            return 0

        timed, total = measure(arguments.flags, work_dir)
        print(f"timed-region instructions {timed:,} (whole program {total:,})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
