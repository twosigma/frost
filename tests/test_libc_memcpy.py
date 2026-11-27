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

"""Exhaustive memcpy and memset checks on sw/lib/src/string.c under Spike."""

from pathlib import Path
import shutil
import subprocess

import pytest

REPO = Path(__file__).resolve().parents[1]
APP = REPO / "sw" / "apps" / "strings_test"
CC = "riscv64-linux-gcc"
OBJCOPY = "riscv64-linux-objcopy"


@pytest.mark.skipif(
    not (shutil.which(CC) and shutil.which("spike")),
    reason="needs the RISC-V cross compiler and Spike",
)
def test_memcpy_memset_all_offsets_and_lengths(tmp_path: Path) -> None:
    """Lengths 0 to 80 and 1,048,113 at every src/dst offset 0 to 7 match a byte copy."""
    # The code-generation flags sw/common/common.mk builds sw/lib with.
    flags = [
        "-march=rv64imafdc_zicsr_zba_zbb_zbs_zicond_zcb",
        "-mabi=lp64d",
        "-mcmodel=medany",
        "-O3",
        "-funroll-loops",
        "-fno-strict-aliasing",
        "-ffreestanding",
        "-fno-unwind-tables",
        "-fno-asynchronous-unwind-tables",
        "-ffunction-sections",
        "-fdata-sections",
    ]
    lib = tmp_path / "string.o"
    subprocess.run(
        [CC, *flags, "-I", str(REPO / "sw/lib/include"), "-c",
         str(REPO / "sw/lib/src/string.c"), "-o", str(lib)],
        check=True,
    )  # fmt: skip
    subprocess.run(
        [OBJCOPY, "--redefine-sym", "memcpy=frost_memcpy",
         "--redefine-sym", "memset=frost_memset", str(lib)],
        check=True,
    )  # fmt: skip
    exe = tmp_path / "memcpy_host_test"
    subprocess.run(
        [CC, *flags, "-nostdlib", "-static", "-T", str(APP / "memcpy_host.ld"), "-Wl,--gc-sections", "-I", str(APP),
         str(APP / "memcpy_host_start.S"), str(APP / "memcpy_host_test.c"), str(lib),
         "-o", str(exe)],
        check=True,
    )  # fmt: skip
    result = subprocess.run(
        ["spike", "--isa=rv64imafdc_zicsr_zba_zbb_zbs_zicond_zcb", str(exe)],
        capture_output=True, text=True, check=False, timeout=600,
    )  # fmt: skip
    assert result.returncode == 0, result.stdout + result.stderr
