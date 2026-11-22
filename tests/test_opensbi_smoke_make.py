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
        "import sys\n"
        "assert sys.argv[sys.argv.index('--board') + 1] == 'vcu118'\n"
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
        "-o",
        str(tmp_path / "firmware.bin"),
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


def test_firmware_checks_inputs_on_every_make(
    tmp_path: Path,
) -> None:
    """Run the helper even when changed inputs have an older timestamp."""
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
        "firmware = out / 'firmware.bin'\n"
        "if not firmware.exists() or firmware.read_text() != config.read_text():\n"
        "    firmware.write_text(config.read_text())\n"
        "with (out / 'checks').open('a') as log: log.write('check\\n')\n"
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
    previous_mtime = None
    for check_count, changed in enumerate((None, None, config, builder), start=1):
        if changed is not None:
            for dependency in (config, builder):
                os.utime(dependency, ns=(1, 1))
            if changed == config:
                config.write_text(config.read_text() + "CONFIG_FDT_IRQCHIP=y\n")
            else:
                builder.write_text(builder.read_text() + "# helper changed\n")
            os.utime(changed, ns=(1, 1))
        result = subprocess.run(
            command, cwd=tmp_path, capture_output=True, text=True, timeout=30
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert (output / "checks").read_text().splitlines() == ["check"] * check_count
        assert firmware.read_text() == config.read_text()
        if check_count == 2:
            assert firmware.stat().st_mtime_ns == previous_mtime
        previous_mtime = firmware.stat().st_mtime_ns
