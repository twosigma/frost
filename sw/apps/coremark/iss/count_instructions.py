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

"""Count CoreMark's timed-region instructions under Spike, at either XLEN.

The FROST core is RV64-only, so the retired rv32 lane cannot be re-measured on
the RTL.  Instruction counts, however, depend only on the toolchain, and this
harness runs the identical CoreMark sources through ilp32d and lp64d with
matched flags.  Use it to separate "the compiler emits more instructions" from
"the machine retires them more slowly" -- the latter still needs the cocotb
run.  It is a measurement tool, not part of any build or test flow.

Calibration: with the flags FROST ships, this harness lands within 0.4% of the
cocotb timed-region instret at both XLENs, and the offset has the same sign and
magnitude in both lanes, so ratios between configurations are trustworthy.

    ./count_instructions.py --xlen 64
    ./count_instructions.py --xlen 32 -- --param max-inline-insns-auto=200
    ./count_instructions.py --matrix

Runs inside the pinned image:  ./scripts/frost.py run sw/apps/coremark/iss/count_instructions.py --matrix
"""

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP_DIR = HERE.parent
COREMARK_DIR = APP_DIR / "coremark"

# Matches common.mk's RISCV_FLAGS minus the parts that are FROST-specific.
EXTENSIONS = "imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause"
BASE_FLAGS = [
    "-mcmodel=medany",
    "-Wall",
    "-Wextra",
    "-nostdlib",
    "-nostartfiles",
    "-ffreestanding",
    "-fno-unwind-tables",
    "-fno-asynchronous-unwind-tables",
    "-ffunction-sections",
    "-fdata-sections",
    "-O3",
    "-funroll-loops",
    "-fno-strict-aliasing",
]

# The ablation reported in ../Makefile, innermost flag last.
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


def build(xlen: int, extra_flags: list[str], elf_path: Path) -> None:
    """Compile CoreMark plus the Spike port layer into elf_path."""
    march = f"rv{xlen}{EXTENSIONS}"
    mabi = "ilp32d" if xlen == 32 else "lp64d"
    command = [
        "riscv-none-elf-gcc",
        f"-march={march}",
        f"-mabi={mabi}",
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


def count(xlen: int, elf_path: Path) -> tuple[int, int]:
    """Return (timed-region instructions, whole-program instructions)."""
    isa = f"rv{xlen}{EXTENSIONS}"
    process = subprocess.Popen(
        ["spike", f"--isa={isa}", "--log-commits", "-l", str(elf_path)],
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
            "instructions -- did the program trap before finishing?"
        )
    return markers[1] - markers[0] - 1, total


def measure(xlen: int, extra_flags: list[str], work_dir: Path) -> tuple[int, int]:
    """Build and run one configuration."""
    elf_path = work_dir / f"coremark_rv{xlen}.elf"
    build(xlen, extra_flags, elf_path)
    return count(xlen, elf_path)


def main() -> int:
    """Command-line entry point."""
    parser = argparse.ArgumentParser(
        description="Count CoreMark timed-region instructions under Spike",
    )
    parser.add_argument(
        "--xlen", type=int, choices=(32, 64), help="measure one XLEN and exit"
    )
    parser.add_argument(
        "--matrix",
        action="store_true",
        help="measure the flag ablation at both XLENs and print the ABI penalty",
    )
    parser.add_argument(
        "flags", nargs="*", help="extra compiler flags (after --) for --xlen mode"
    )
    arguments = parser.parse_args()

    for tool in ("riscv-none-elf-gcc", "spike"):
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
            print(f"{'flags':<38}{'rv32/ilp32d':>13}{'rv64/lp64d':>13}{'lp64':>8}")
            for name, flags in MATRIX:
                rv32, _ = measure(32, flags, work_dir)
                rv64, _ = measure(64, flags, work_dir)
                penalty = (rv64 / rv32 - 1.0) * 100.0
                print(f"{name:<38}{rv32:>13,}{rv64:>13,}{penalty:>7.1f}%")
            return 0

        if arguments.xlen is None:
            parser.error("pass --xlen or --matrix")
        timed, total = measure(arguments.xlen, arguments.flags, work_dir)
        print(
            f"rv{arguments.xlen}: timed-region instructions {timed:,} "
            f"(whole program {total:,})"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
