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
that passes validates its expected values without vector hardware. Source
comments identify restart and reserved-encoding cases checked only on RTL
because the reference simulator does not support them.

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


@pytest.mark.parametrize("vlen", (128, 256, 512))
def test_integer_execution_program(vlen: int, tmp_path: Path) -> None:
    """The fixed register-image expectations agree with the reference ISA."""
    build_and_run(
        "vec_integer_test", vlen, vlen, tmp_path, extra_cflags=f"-DVEC_VLEN={vlen}"
    )


def test_integer_program_negative_control(tmp_path: Path) -> None:
    """Flipping an expected destination bit must be detected by the program."""
    with pytest.raises(AssertionError, match="1 failures"):
        build_and_run(
            "vec_integer_test",
            128,
            128,
            tmp_path,
            extra_cflags="-DVEC_VLEN=128 -DVEC_NEGATIVE_CONTROL",
        )


@pytest.mark.parametrize("vlen", (128, 256, 512))
def test_fp_execution_program(vlen: int, tmp_path: Path) -> None:
    """FP register images and flags agree with the reference ISA."""
    build_and_run(
        "vec_fp_test", vlen, vlen, tmp_path, extra_cflags=f"-DVEC_VLEN={vlen}"
    )


def test_fp_program_negative_control(tmp_path: Path) -> None:
    """A wrong FP expected result must fail the program."""
    with pytest.raises(AssertionError, match="1 failures"):
        build_and_run(
            "vec_fp_test",
            128,
            128,
            tmp_path,
            extra_cflags="-DVEC_VLEN=128 -DVEC_NEGATIVE_CONTROL",
        )


@pytest.mark.parametrize("vlen", (128, 256, 512))
def test_crypto_execution_program(vlen: int, tmp_path: Path) -> None:
    """Crypto register groups and reserved geometry agree with the reference ISA."""
    build_and_run(
        "vec_crypto_exec_test", vlen, vlen, tmp_path, extra_cflags=f"-DVEC_VLEN={vlen}"
    )


@pytest.mark.parametrize("vlen", (128, 256, 512))
def test_mem_reserved_forms_program(vlen: int, tmp_path: Path) -> None:
    """Exhaustive unit-stride legality matches Spike at each vector length."""
    output = build_and_run("vec_mem_reserved_forms_test", vlen, vlen, tmp_path)
    assert " 0 failures" in output


@pytest.mark.skipif(
    shutil.which("sail_riscv_sim") is None,
    reason="needs sail_riscv_sim (the frost image)",
)
@pytest.mark.parametrize("vlen", (128, 256, 512))
def test_mem_reserved_forms_on_sail(vlen: int, tmp_path: Path) -> None:
    """Exhaustive unit-stride legality matches the Sail RISC-V model."""
    build = subprocess.run(
        [
            "make",
            "-s",
            "-f",
            SPIKE_MAKEFILE,
            f"VLEN={vlen}",
            f"BUILD={tmp_path}",
            f"EXTS={SPIKE_EXTENSIONS}",
        ],
        cwd=APPS_DIR / "vec_mem_reserved_forms_test",
        capture_output=True,
        text=True,
        check=False,
    )
    assert build.returncode == 0, f"build failed:\n{build.stderr[-2000:]}"
    term_log = tmp_path / f"sail_vlen{vlen}.log"
    testrig = REPO_ROOT / "verif" / "testrig"
    run = subprocess.run(
        [
            "sail_riscv_sim",
            # The sweep triggers 8,114 deliberate illegal-instruction traps
            # through a non-mret M-mode handler, which trips Sail's heuristic.
            "--disable-trap-loop-detection",
            "--config-override",
            str(testrig / "sail_frost.json"),
            "--config-override",
            str(testrig / f"sail_frost_vlen{vlen}.json"),
            "--terminal-log",
            str(term_log),
            str(tmp_path / f"sw_vlen{vlen}.elf"),
        ],
        capture_output=True,
        text=True,
        timeout=SPIKE_TIMEOUT_SECONDS,
        check=False,
    )
    term = term_log.read_text(encoding="utf-8") if term_log.exists() else ""
    assert run.returncode == 0 and "<<PASS>>" in term and " 0 failures" in term, (
        f"sail_riscv_sim (VLEN {vlen}) exit {run.returncode}:\n"
        f"{run.stdout[-1000:]}\n{term[-1000:]}"
    )


def test_crypto_program_negative_control(tmp_path: Path) -> None:
    """A wrong crypto expected result must fail the program."""
    with pytest.raises(AssertionError, match="1 failures"):
        build_and_run(
            "vec_crypto_exec_test",
            128,
            128,
            tmp_path,
            extra_cflags="-DVEC_VLEN=128 -DVEC_NEGATIVE_CONTROL",
        )
