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

"""Real compiler checks in scratch app trees; run through scripts/frost.py."""

import os
from pathlib import Path
import shutil
import struct
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]


def scratch_app(tmp_path: Path, app: str) -> Path:
    """Copy app inputs while sharing read-only dependency/source directories."""
    sw = tmp_path / "sw"
    (sw / "apps").mkdir(parents=True)
    for name in ("common", "lib", "FreeRTOS-Kernel"):
        (sw / name).symlink_to(ROOT / "sw" / name, target_is_directory=True)
    target = sw / "apps" / app
    target.mkdir()
    for source in (ROOT / "sw/apps" / app).iterdir():
        if source.name.startswith(("sw.", "sw64.", "sw_ddr.", "sw_imem_", ".frost-")):
            continue
        if source.name in {".git", "build", "__pycache__"} or source.suffix == ".o":
            continue
        if source.is_dir():
            (target / source.name).symlink_to(source, target_is_directory=True)
        elif source.is_file():
            shutil.copy2(source, target / source.name)
    return target


def build(app_dir: Path, *variables: str) -> subprocess.CompletedProcess[str]:
    """Build only the isolated output directory with the pinned RISC-V tools."""
    env = {
        key: value for key, value in os.environ.items() if not key.startswith("FROST_")
    }
    env.pop("MEM_CONFIG", None)
    return subprocess.run(
        [
            "make",
            "--no-print-directory",
            "-s",
            "RISCV_PREFIX=riscv-none-elf-",
            "FPGA_CPU_CLK_FREQ=150000000",
            "GENERATE_IMEM_INIT=0",
            *variables,
        ],
        cwd=app_dir,
        env=env,
        capture_output=True,
        text=True,
        timeout=180,
    )


def section_names(path: Path) -> set[str]:
    """Read section names from a little-endian ELF64 without target execution."""
    elf = path.read_bytes()
    assert elf[:6] == b"\x7fELF\x02\x01"
    offset = struct.unpack_from("<Q", elf, 40)[0]
    size, count, names_index = struct.unpack_from("<HHH", elf, 58)
    names_offset, names_size = struct.unpack_from(
        "<QQ", elf, offset + names_index * size + 24
    )
    names = elf[names_offset : names_offset + names_size]
    return {
        names[struct.unpack_from("<I", elf, offset + index * size)[0] :]
        .split(b"\0", 1)[0]
        .decode()
        for index in range(count)
    }


@pytest.mark.parametrize("app", ["branch_pred_test", "coremark_pro"])
def test_custom_backends_rebuild_on_debug_profile_changes(
    tmp_path: Path, app: str
) -> None:
    """Normal→debug→normal rebuilds actual assembly and all PRO translation units."""
    app_dir = scratch_app(tmp_path, app)
    settings = ["MEM_CONFIG=bram"]
    if app == "coremark_pro":
        settings += [
            "WORKLOAD=core",
            "COREMARK_PRO_OFFICIAL=1",
            "COREMARK_PRO_RUN_ARGS=-v1",
        ]
    for debug in (0, 1, 0):
        result = build(
            app_dir, *settings, f"FROST_DEBUG={debug}", "FROST_DEBUG_FLAGS=-g0"
        )
        assert result.returncode == 0, result.stdout + result.stderr
        sections = section_names(app_dir / "sw.elf")
        assert ({".debug_info", ".debug_line"} <= sections) == bool(debug)
        stamp = (app_dir / ".frost-build-config.bin").read_text().split("|")
        assert f"FROST_DEBUG={debug}" in stamp
        assert "FPGA_CPU_CLK_FREQ=150000000" in stamp
        assert (app_dir / "sw_ddr.txt").read_bytes() == b""
        if app == "coremark_pro":
            for obj in (
                "mith_lib.o",
                "frost_mith_main.o",
                "al_frost.o",
                "frostlib_uart.o",
            ):
                assert (".debug_info" in section_names(app_dir / obj)) == bool(debug)


def test_standalone_assembly_ddr_loader_words_and_debug_entry(tmp_path: Path) -> None:
    """DDR output contains the actual linked image, separate from the ROM stub."""
    app_dir = scratch_app(tmp_path, "c_ext_test")
    result = build(app_dir, "MEM_CONFIG=ddr", "FROST_DEBUG=1")
    assert result.returncode == 0, result.stdout + result.stderr
    assert {".debug_info", ".debug_line"} <= section_names(app_dir / "sw.elf")
    elf = (app_dir / "sw.elf").read_bytes()
    assert struct.unpack_from("<Q", elf, 24)[0] == 0x80000000
    words = (app_dir / "sw_ddr.txt").read_text().splitlines()
    assert words and all(len(word) == 8 for word in words)
    decoded = b"".join(int(word, 16).to_bytes(4, "little") for word in words)
    assert decoded == (app_dir / "sw_ddr.bin").read_bytes()
    assert (app_dir / "sw.bin").stat().st_size == 12


def test_isa_debug_profile_keeps_s0_available(tmp_path: Path) -> None:
    """The real ISA test builds with DWARF despite its explicit s0 clobbers."""
    app_dir = scratch_app(tmp_path, "isa_test")
    result = build(app_dir, "MEM_CONFIG=bram", "FROST_DEBUG=1")
    assert result.returncode == 0, result.stdout + result.stderr
    assert {".debug_info", ".debug_line"} <= section_names(app_dir / "sw.elf")
    stamp = (app_dir / ".frost-build-config.bin").read_text()
    assert (
        "FROST_DEBUG_FLAGS=-Og -g3 -fno-unroll-loops -fno-unroll-all-loops -fomit-frame-pointer|"
        in stamp
    )


def test_ddr_smc_debug_reaches_buffer_from_low_bram(tmp_path: Path) -> None:
    """Debug can address DDR from small BRAM functions without changing release flags."""
    app_dir = scratch_app(tmp_path, "ddr_smc_test")
    for debug in (1, 0):
        result = build(app_dir, "MEM_CONFIG=bram", f"FROST_DEBUG={debug}")
        assert result.returncode == 0, result.stdout + result.stderr
        assert (".debug_info" in section_names(app_dir / "sw.elf")) == bool(debug)
        stamp = (app_dir / ".frost-build-config.bin").read_text()
        assert ("APP_TUNE_FLAGS=-mcmodel=large|" in stamp) == bool(debug)
        assert (app_dir / "sw_ddr.txt").stat().st_size > 0
