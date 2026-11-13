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

"""Run the vector bring-up programs on Spike, the reference simulator.

The programs in sw/apps/vec_* check the RISC-V vector extension: configuration
and CSRs, loads and stores, string routines, integer and floating-point dot
products, vector cryptography, and bit manipulation. The same sources run on
FROST through sw/common/common.mk and on Spike through
sw/apps/vec_common/spike/Makefile.spike (HTIF console, -DVT_SPIKE). A program
that does not pass on Spike is wrong, not the core, so these tests guard the
programs themselves and need no vector hardware.

Each program is built for a vector length of 128, 256 and 512 bits and run at
that length, then the 128-bit build is run at 256 and 512 to check that the
programs do not depend on the length they were built for.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
APPS_DIR = REPO_ROOT / "sw" / "apps"
SPIKE_MAKEFILE = "../vec_common/spike/Makefile.spike"

PROGRAMS = (
    "vec_smoke",
    "vec_ldst",
    "vec_string",
    "vec_dot_int",
    "vec_dot_fp",
    "vec_crypto",
    "vec_zvbb",
)

# (build VLEN, run VLEN): each length on its own, then the 128-bit build on
# wider hardware.
LENGTH_PAIRS = ((128, 128), (256, 256), (512, 512), (128, 256), (128, 512))

SPIKE_EXTENSIONS = (
    "zicsr_zifencei_zfh_zvfh_zvfhmin_zvbb_zvbc_zvkt_zvkg_zvkned_zvknhb_zvksed_zvksh"
)
# Zvfh left out: vec_dot_fp then builds with -DVT_NO_ZVFH and checks half
# precision through conversions only (Zvfhmin).
ZVFHMIN_EXTENSIONS = (
    "zicsr_zifencei_zfh_zvfhmin_zvbb_zvbc_zvkt_zvkg_zvkned_zvknhb_zvksed_zvksh"
)

SPIKE_TIMEOUT_SECONDS = 300

pytestmark = pytest.mark.skipif(
    shutil.which("spike") is None or shutil.which("riscv64-linux-gcc") is None,
    reason="needs spike and riscv64-linux-gcc (the frost image)",
)


def build_and_run(
    program: str,
    build_vlen: int,
    run_vlen: int,
    build_dir: Path,
    extensions: str = SPIKE_EXTENSIONS,
    extra_cflags: str = "",
) -> str:
    """Build a program for Spike, run it, and return its console output."""
    build = subprocess.run(
        [
            "make",
            "-s",
            "-f",
            SPIKE_MAKEFILE,
            f"VLEN={build_vlen}",
            f"BUILD={build_dir}",
            f"EXTS={extensions}",
            f"EXTRA_CFLAGS={extra_cflags}",
        ],
        cwd=APPS_DIR / program,
        capture_output=True,
        text=True,
        check=False,
    )
    assert build.returncode == 0, f"{program} did not build:\n{build.stderr[-2000:]}"
    run = subprocess.run(
        [
            "spike",
            f"--isa=rv64imafdcv_{extensions}_zvl{run_vlen}b",
            "-m0x80000000:0x400000",
            str(build_dir / f"sw_vlen{build_vlen}.elf"),
        ],
        capture_output=True,
        text=True,
        timeout=SPIKE_TIMEOUT_SECONDS,
        check=False,
    )
    output = run.stdout + run.stderr
    assert run.returncode == 0 and "<<PASS>>" in output, (
        f"{program} (built for {build_vlen}, run at {run_vlen}) exit "
        f"{run.returncode}:\n{output[-2000:]}"
    )
    return output


@pytest.mark.parametrize(("build_vlen", "run_vlen"), LENGTH_PAIRS)
@pytest.mark.parametrize("program", PROGRAMS)
def test_program_passes_on_spike(
    program: str, build_vlen: int, run_vlen: int, tmp_path: Path
) -> None:
    """The program passes all its checks on Spike."""
    output = build_and_run(program, build_vlen, run_vlen, tmp_path)
    assert " 0 failures" in output


def test_dot_fp_without_zvfh_on_spike(tmp_path: Path) -> None:
    """Half-precision checks pass through conversions on a Zvfhmin-only core."""
    build_and_run(
        "vec_dot_fp",
        128,
        128,
        tmp_path,
        extensions=ZVFHMIN_EXTENSIONS,
        extra_cflags="-DVT_NO_ZVFH",
    )


def test_stale_disassembly_is_not_linked(tmp_path: Path) -> None:
    """The disassembly a FROST build leaves in a program's directory is not linked."""
    apps = tmp_path / "apps"
    for name in ("vec_common", "vec_zvbb"):
        shutil.copytree(APPS_DIR / name, apps / name)
    (apps / "vec_zvbb" / "sw.S").write_text("this is not assembly\n")
    build = subprocess.run(
        ["make", "-s", "-f", SPIKE_MAKEFILE, f"BUILD={tmp_path / 'build'}"],
        cwd=apps / "vec_zvbb",
        capture_output=True,
        text=True,
        check=False,
    )
    assert build.returncode == 0, build.stderr[-1000:]
