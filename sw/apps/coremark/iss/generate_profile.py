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
8/8/8, which ``core_portme.h`` selects as ``PROFILE_RUN``. This builds the
benchmark sources against the Spike port layer with ``-fprofile-arcs
-fprofile-info-section``, runs it under Spike, streams the gcda out over the
HTIF syscall proxy, converts the stream with ``gcov-tool merge-stream``, and
installs the five benchmark-source ``.gcda`` files next to the app Makefile.

Edge counts are architectural, so Spike's match the RTL's, except in
``core_main.c``'s checks of elapsed time: the Spike port's ``get_time()``
always returns 1, while FROST's measures cycles. Spike also avoids the tens of
millions of simulated cycles the FROST UART would need to print the profile.
Only the five benchmark translation units get a profile; ``uart.c``,
``core_portme.c`` and ``tomasulo_profile_cache.c`` sit outside the timed
region and build without one.

Two build details matter and are easy to get wrong:

* The benchmark sources must be compiled from the app directory with the same
  relative path spellings the app Makefile uses. GCC folds the source path
  into each function's line-number checksum, so an absolute path here makes
  every record mismatch under ``-fbranch-probabilities``.
* GCC derives the gcda name from the link output, so the training link writes
  to ``sw.elf`` and the installed files are ``sw.elf-<source>.gcda``.

Run it inside the pinned image:

    ./scripts/frost.py run sw/apps/coremark/iss/generate_profile.py
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
EXTENSIONS = "imafd_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause"
# The five benchmark translation units; the port layer is deliberately excluded.
PROFILED_SOURCES = (
    "core_list_join",
    "core_main",
    "core_matrix",
    "core_state",
    "core_util",
)
# Matches the app Makefile's ordinary flags. The tuning flags follow them, as
# APP_TUNE_FLAGS does there.
BASE_FLAGS = (
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
)
# The Makefile's COREMARK_BASE_TUNE and COREMARK_CPU_TUNE. The published build
# reads the profiles with -mtune=generic-ooo instead; with the pinned GCC, the
# -mtune used for training does not change the counts.
DEFAULT_TUNE_FLAGS = (
    "--param",
    "max-inline-insns-auto=200",
    "-fira-algorithm=CB",
    "-fstrict-aliasing",
    "-fselective-scheduling",
    "-mtune=sifive-7-series",
)


def build(work_dir: Path, tune_flags: list[str]) -> Path:
    """Compile the instrumented training image and return its path."""
    elf_path = work_dir / "sw.elf"
    command = [
        f"{RISCV_PREFIX}gcc",
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
        # The measured build reads only edge counts (-fbranch-probabilities), so
        # train without value profiling, which would pull in libgcov's Linux TLS
        # runtime.
        "-fprofile-arcs",
        "-fprofile-info-section",
        "-fprofile-update=single",
        *tune_flags,
        "-lgcov",
        "-lgcc",
        "-o",
        str(elf_path),
    ]
    subprocess.run(command, cwd=APP_DIR, check=True)
    # Bootlin's libgcov was built for Linux. Only its freestanding streaming
    # objects belong here: reject accidental TLS, dynamic loading or syscalls.
    headers = subprocess.check_output(
        [f"{RISCV_PREFIX}readelf", "-lW", str(elf_path)], text=True
    )
    assembly = subprocess.check_output(
        [f"{RISCV_PREFIX}objdump", "-d", str(elf_path)], text=True
    )
    if re.search(r"^\s+(TLS|INTERP|DYNAMIC)\s", headers, re.MULTILINE) or re.search(
        r"\becall\b", assembly
    ):
        raise RuntimeError("training image unexpectedly contains a Linux runtime")
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
        [f"{RISCV_PREFIX}gcov-tool", "merge-stream", stream_path.name],
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
        help=(
            "tuning flags (after --) that replace the defaults; "
            "match the measured build"
        ),
    )
    arguments = parser.parse_args()

    for tool in (f"{RISCV_PREFIX}gcc", f"{RISCV_PREFIX}gcov-tool", "spike"):
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
