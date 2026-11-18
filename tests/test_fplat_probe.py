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

"""Scalar floating-point test targets and the latency probe's calling convention."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_run_cocotb import TEST_REGISTRY


def test_scalar_fp_targets_link_to_their_implementations() -> None:
    """Keep the scalar FP guide's target names and links aligned with the registry."""
    root = Path(__file__).resolve().parents[1]
    guide = (root / "tests/README.md").read_text()
    for name in ("fp_engine_equiv", "fp_shim", "fplat_probe"):
        config = TEST_REGISTRY[name]
        if config.app_name is None:
            source = Path("verif", *config.python_test_module.split(".")).with_suffix(
                ".py"
            )
        else:
            source = Path("sw/apps") / config.app_name
        assert (root / source).exists()
        assert f"[`{name}`](../{source.as_posix()})" in guide


@pytest.mark.skipif(
    not shutil.which("spike") or not shutil.which("riscv64-linux-gcc"),
    reason="requires Spike and the RISC-V toolchain",
)
def test_throughput_loops_preserve_fp_registers(tmp_path: Path) -> None:
    """An LP64D caller can keep double-precision values live across each loop."""
    root = Path(__file__).resolve().parents[1]
    startup = root / "sw/apps/vec_common/spike"
    elf = tmp_path / "fplat_caller.elf"
    subprocess.run(
        [
            "riscv64-linux-gcc",
            "-march=rv64gc_zicntr",
            "-mabi=lp64d",
            "-mcmodel=medany",
            "-nostdlib",
            "-static",
            "-no-pie",
            "-T",
            str(startup / "link_spike.ld"),
            str(startup / "crt0_spike.S"),
            str(root / "tests/fixtures/fplat_caller.S"),
            str(root / "sw/apps/fplat_probe/loops.S"),
            "-o",
            str(elf),
        ],
        check=True,
        timeout=30,
    )
    subprocess.run(
        ["spike", "--isa=rv64gc_zicntr", "-m0x80000000:0x400000", str(elf)],
        check=True,
        timeout=15,
    )
