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

"""Regenerate CoreMark's profile-guided-optimization training data.

CoreMark's run rules allow profile-guided optimization when the profile comes
from the official profile data set: ``TOTAL_DATA_SIZE`` 1200 with seeds
8/8/8, which ``core_portme.h`` selects as ``PROFILE_RUN``.  This builds the
benchmark sources against the Spike port layer with ``-fprofile-generate
-fprofile-info-section``, runs it under Spike, streams the gcda out over the
HTIF syscall proxy, and installs the five benchmark-source ``.gcda`` files
next to the app Makefile.

Execution counts are architectural, so Spike and the RTL agree on them; Spike
is used because the FROST UART would need tens of millions of simulated cycles
to print the same bytes.  The port layer differs from the FROST one, so only
the five benchmark translation units get a profile; ``uart.c``,
``core_portme.c`` and ``tomasulo_profile_cache.c`` are not hot and are built
without one.

Two build details matter and are easy to get wrong:

* The benchmark sources must be compiled from the app directory with the same
  relative path spellings the app Makefile uses.  GCC folds the source path
  into each function's line-number checksum, so an absolute path here makes
  every record mismatch at ``-fprofile-use``.
* GCC derives the gcda name from the link output, so the training link writes
  to ``sw.elf`` and the installed files are ``sw.elf-<source>.gcda``.

Runs inside the pinned image:
    ./scripts/frost.py run sw/apps/coremark/iss/generate_profile.py
"""

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP_DIR = HERE.parent
COREMARK_DIR = APP_DIR / "coremark"
EXTENSIONS = "imafd_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause"
# The five benchmark translation units; the port layer is deliberately excluded.
PROFILED_SOURCES = (
    "core_list_join",
    "core_main",
    "core_matrix",
    "core_state",
    "core_util",
)
# Matches the app Makefile's ordinary flags. APP_TUNE_FLAGS is appended last
# there too, so the training and measured builds see the same optimizer.
BASE_FLAGS = (
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
)
DEFAULT_TUNE_FLAGS = (
    "--param",
    "max-inline-insns-auto=200",
    "-fira-algorithm=priority",
    "-fstrict-aliasing",
)


def build(work_dir: Path, tune_flags: list[str]) -> Path:
    """Compile the instrumented training image and return its path."""
    elf_path = work_dir / "sw.elf"
    command = [
        "riscv-none-elf-gcc",
        f"-march=rv64{EXTENSIONS}",
        "-mabi=lp64d",
        *BASE_FLAGS,
        "-I../../lib/include",
        "-I.",
        "-I./coremark",
        "-Iiss",
        "-DITERATIONS=1",
        "-DMEM_METHOD=MEM_STACK",
        '-DMEM_LOCATION="STACK"',
        # The official profile data set: PROFILE_RUN, seeds 8/8/8.
        "-DTOTAL_DATA_SIZE=1200",
        '-DCOMPILER_VERSION="iss"',
        '-DCOMPILER_FLAGS="iss"',
        "-DFROST_PGO_DUMP=1",
        "iss/crt0_spike.S",
        "iss/stub.c",
        "iss/pgo_dump.c",
        "iss/core_portme.c",
        *[f"coremark/{name}.c" for name in PROFILED_SOURCES],
        "-T",
        "iss/link_spike_pgo.ld",
        "-Wl,--gc-sections",
        "-Wl,--no-warn-rwx-segments",
        "-fprofile-generate",
        "-fprofile-info-section",
        "-fprofile-update=single",
        *tune_flags,
        "-lgcov",
        "-lgcc",
        "-o",
        str(elf_path),
    ]
    subprocess.run(command, cwd=APP_DIR, check=True)
    return elf_path


def run_and_merge(elf_path: Path, work_dir: Path) -> None:
    """Run the training image under Spike and turn its stream into gcda files."""
    stream_path = work_dir / "stream.bin"
    with stream_path.open("wb") as stream:
        subprocess.run(
            ["spike", f"--isa=rv64{EXTENSIONS}", str(elf_path)],
            check=True,
            stdout=stream,
        )
    if b"GCOV-ABORT" in stream_path.read_bytes():
        raise RuntimeError("the gcov dumper aborted; see iss/pgo_dump.c")
    subprocess.run(
        ["riscv-none-elf-gcov-tool", "merge-stream", stream_path.name],
        cwd=work_dir,
        check=True,
    )


def main() -> int:
    """Command-line entry point."""
    parser = argparse.ArgumentParser(
        description="Regenerate CoreMark's PGO training data under Spike",
    )
    parser.add_argument(
        "tune_flags",
        nargs="*",
        help="extra compiler flags (after --) matching the measured build",
    )
    arguments = parser.parse_args()

    for tool in ("riscv-none-elf-gcc", "riscv-none-elf-gcov-tool", "spike"):
        if shutil.which(tool) is None:
            print(
                f"error: {tool} not found; run this inside the pinned image "
                "(./scripts/frost.py run ...)",
                file=sys.stderr,
            )
            return 1

    tune_flags = arguments.tune_flags or list(DEFAULT_TUNE_FLAGS)
    with tempfile.TemporaryDirectory(prefix="coremark_pgo_") as temporary:
        work_dir = Path(temporary)
        elf_path = build(work_dir, tune_flags)
        run_and_merge(elf_path, work_dir)
        for name in PROFILED_SOURCES:
            source = work_dir / f"sw.elf-{name}.gcda"
            if not source.exists():
                print(f"error: {source.name} was not produced", file=sys.stderr)
                return 1
            shutil.copy(source, APP_DIR / source.name)
            print(f"installed {source.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
