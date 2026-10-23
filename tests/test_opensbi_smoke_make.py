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

"""Check OpenSBI firmware dependencies and grouped image packing."""

from pathlib import Path
import os
import shutil
import subprocess


def test_parallel_image_targets_share_one_packer(tmp_path: Path) -> None:
    """Build and regenerate sibling images with exactly one packer invocation."""
    root = Path(__file__).resolve().parents[1]
    shutil.copy2(root / "sw/apps/opensbi_smoke/Makefile", tmp_path / "Makefile")
    for name in ("payload.bin", "firmware.bin"):
        (tmp_path / name).touch()
    outputs = ("sw.mem", "sw.txt", "sw_ddr.mem", "sw_ddr.txt")
    packer = tmp_path / "frost_boot_image.py"
    packer.write_text(
        "from pathlib import Path\n"
        "with Path('invocations').open('a') as log:\n"
        "    log.write('pack\\n')\n"
        f"for name in {outputs!r}:\n"
        "    Path(name).write_text('packed image\\n')\n"
    )
    command = [
        "make",
        "--no-print-directory",
        "-j8",
        "-o",
        "payload.bin",
        f"FROST_ROOT={root}",
        f"FW_BIN={tmp_path / 'firmware.bin'}",
        f"BOARD_DIR={tmp_path}",
        *outputs,
    ]
    for expected_calls in (1, 2):
        result = subprocess.run(
            command, cwd=tmp_path, capture_output=True, text=True, timeout=30
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert (tmp_path / "invocations").read_text().splitlines() == [
            "pack"
        ] * expected_calls
        assert all(
            (tmp_path / name).read_text() == "packed image\n" for name in outputs
        )
        # A missing sibling must regenerate the group, also with one invocation.
        (tmp_path / "sw.txt").unlink()


def test_firmware_rebuilds_after_configuration_or_builder_changes(
    tmp_path: Path,
) -> None:
    """A cached firmware must use the selected interrupt driver on the next build."""
    root = Path(__file__).resolve().parents[1]
    linux = tmp_path / "linux"
    linux.mkdir()
    config = linux / "opensbi_frost_defconfig"
    config.write_text("CONFIG_FDT_IRQCHIP_APLIC=y\n")
    builder = linux / "opensbi_build.py"
    builder.write_text(
        "import sys\n"
        "from pathlib import Path\n"
        "out = Path(sys.argv[sys.argv.index('--out') + 1])\n"
        "out.mkdir(parents=True, exist_ok=True)\n"
        "config = Path(__file__).with_name('opensbi_frost_defconfig')\n"
        "(out / 'firmware.bin').write_text(config.read_text())\n"
        "with (out / 'builds').open('a') as log: log.write('build\\n')\n"
    )
    output = tmp_path / "out"
    firmware = output / "firmware.bin"
    command = [
        "make",
        "--no-print-directory",
        "-f",
        str(root / "sw/apps/opensbi_smoke/Makefile"),
        f"FROST_ROOT={tmp_path}",
        f"OPENSBI_OUT={output}",
        f"FW_BIN={firmware}",
        str(firmware),
    ]
    for build_count, changed in ((1, None), (1, None), (2, config), (3, builder)):
        if changed is not None:
            # Only the chosen dependency is newer than the cached output.
            cached_ns = firmware.stat().st_mtime_ns
            for dependency in (config, builder):
                os.utime(dependency, ns=(1, 1))
            if changed == config:
                config.write_text(config.read_text() + "CONFIG_FDT_IRQCHIP=y\n")
            os.utime(changed, ns=(cached_ns + 1, cached_ns + 1))
        result = subprocess.run(
            command, cwd=tmp_path, capture_output=True, text=True, timeout=30
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert (output / "builds").read_text().splitlines() == ["build"] * build_count
        assert firmware.read_text() == config.read_text()
