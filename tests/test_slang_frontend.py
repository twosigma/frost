#!/usr/bin/env python3

#    Copyright 2026 John Goodacre
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

"""Read the synthesizable RTL with a strict SystemVerilog front end.

Yosys' own Verilog reader, Verilator and Vivado accept constructs that
IEEE Std 1800-2017 rejects, such as a reference that precedes its
declaration (clause 6.21). yosys-slang, built on the slang compiler,
enforces the standard. This check reads each top below with
``read_slang --error-limit=0`` with the Yosys in the ORFS image that
asic/orfs.py pins, which has yosys-slang built in, and fails on any error.

Run it from the repository root, on a host with Docker:

    pytest tests/test_slang_frontend.py -v
    python3 tests/test_slang_frontend.py

The host needs no Yosys, slang, or pytest for the second form.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY_ROOT))

from asic.orfs import ORFS_IMAGE  # noqa: E402

CONTAINER_ROOT = "/workspace"
CONTAINER_FILELIST = "/slang/files.f"
ORFS_YOSYS = "/OpenROAD-flow-scripts/tools/install/yosys/bin/yosys"
TIMEOUT_SECONDS = 1800
# The RAM models clear their arrays in initial loops of up to a million
# iterations, far past the default limit of 4000.
UNROLL_LIMIT = 1 << 24


@dataclass(frozen=True)
class SlangCase:
    """One top module read from one filelist."""

    name: str
    filelist: str
    top: str
    # Errors that come from a construct slang accepts but yosys-slang cannot
    # yet elaborate, or from simulation-only code; each entry is a substring
    # of the error line. Any other error fails the case.
    tolerated: tuple[str, ...] = ()


CASES = (
    SlangCase("cpu_top", "hw/rtl/cpu_top/cpu_top.f", "cpu_top"),
    SlangCase(
        "platform_top",
        "hw/rtl/frost.f",
        "platform_top",
        # The behavioral DDR model passes a bit-vector parameter to $fopen,
        # which slang wants as a string. It is simulation-only code.
        tolerated=("axi_behavioral_memory.sv:140:",),
    ),
)


def expand_filelist(filelist: Path) -> list[str]:
    """Return the source paths and include options a filelist names.

    Build scripts expand $(ROOT) to the repository root; here it is the
    container's mount point. Each file is listed once, in first-seen order.
    """
    seen: set[str] = set()
    entries: list[str] = []

    def read(path: Path) -> None:
        for raw in path.read_text().splitlines():
            line = raw.split("//")[0].split("#")[0].strip()
            if not line:
                continue
            line = line.replace("$(ROOT)", CONTAINER_ROOT)
            if line.startswith("-f "):
                nested = line[3:].strip().replace(CONTAINER_ROOT, str(REPOSITORY_ROOT))
                read(Path(nested))
            elif line.startswith("+incdir+"):
                option = "-I" + line[len("+incdir+") :]
                if option not in seen:
                    seen.add(option)
                    entries.append(option)
            elif line not in seen:
                seen.add(line)
                entries.append(line)

    read(filelist)
    return entries


def slang_errors(case: SlangCase) -> list[str]:
    """Return the error lines yosys-slang reports for a case."""
    entries = expand_filelist(REPOSITORY_ROOT / case.filelist)
    with tempfile.TemporaryDirectory(prefix="frost-slang-") as temp_dir:
        (Path(temp_dir) / "files.f").write_text("\n".join(entries) + "\n")
        script = (
            f"read_slang --error-limit=0 --unroll-limit={UNROLL_LIMIT} "
            f"--top {case.top} -DSYNTHESIS "
            f"-f {CONTAINER_FILELIST}"
        )
        command = [
            "docker",
            "run",
            "--rm",
            "--init",
            "--user",
            f"{os.getuid()}:{os.getgid()}",
            "--env",
            "HOME=/tmp",
            "--volume",
            f"{REPOSITORY_ROOT}:{CONTAINER_ROOT}:ro",
            "--volume",
            f"{temp_dir}:/slang:ro",
            "--workdir",
            CONTAINER_ROOT,
            ORFS_IMAGE,
            ORFS_YOSYS,
            "-p",
            script,
        ]
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=TIMEOUT_SECONDS
        )
    output = result.stdout + result.stderr
    errors = sorted({line for line in output.splitlines() if "error:" in line})
    if result.returncode != 0 and not errors:
        errors = [f"yosys exited with status {result.returncode}", output[-2000:]]
    return errors


def unexpected_errors(case: SlangCase) -> list[str]:
    """Return the errors of a case that its tolerated list does not cover."""
    return [
        line
        for line in slang_errors(case)
        if not any(known in line for known in case.tolerated)
    ]


def _docker_available() -> bool:
    return shutil.which("docker") is not None


def test_cases_name_existing_filelists() -> None:
    """Every case reads a filelist that exists."""
    for case in CASES:
        assert (REPOSITORY_ROOT / case.filelist).is_file(), case.filelist


def test_filelist_expansion_lists_each_file_once() -> None:
    """Nested filelists repeat dependencies; the expansion keeps the first."""
    entries = expand_filelist(REPOSITORY_ROOT / "hw/rtl/frost.f")
    assert len(entries) == len(set(entries))
    assert f"{CONTAINER_ROOT}/hw/rtl/frost.sv" in entries


def test_slang_reads_the_rtl() -> None:
    """Fail on any error yosys-slang reports, e.g. a use before declaration."""
    import pytest

    if not _docker_available():
        pytest.skip("Docker is not installed")
    for case in CASES:
        errors = unexpected_errors(case)
        assert not errors, f"{case.name}:\n" + "\n".join(errors)


def main() -> int:
    """Run every case; return nonzero if any reports an unexpected error."""
    if not _docker_available():
        print("Error: Docker is not installed", file=sys.stderr)
        return 1
    failed = []
    for case in CASES:
        errors = unexpected_errors(case)
        if errors:
            failed.append(case.name)
            print(f"{case.name}: FAILED")
            for line in errors:
                print(f"  {line}")
        else:
            print(f"{case.name}: ok")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
