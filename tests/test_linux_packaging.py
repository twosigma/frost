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

"""Static contracts for the no-MMU Linux configuration and device tree."""

import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
KERNEL_FRAGMENT = (
    REPO_ROOT
    / "linux"
    / "buildroot-external"
    / "board"
    / "frost"
    / "linux-nommu-frost.config.fragment"
)
BOOT_PACKER = (
    REPO_ROOT
    / "linux"
    / "buildroot-external"
    / "board"
    / "frost"
    / "build_fpga_boot.py"
)
CPU_AND_MEM = REPO_ROOT / "hw" / "rtl" / "cpu_and_mem" / "cpu_and_mem.sv"


def test_kernel_fragment_uses_merge_config_disable_syntax() -> None:
    """Disabled symbols must use the exact syntax recognized by merge_config."""
    malformed = []
    for line_number, line in enumerate(KERNEL_FRAGMENT.read_text().splitlines(), 1):
        if re.match(r"# CONFIG_\w+ is not set", line) and not re.fullmatch(
            r"# CONFIG_\w+ is not set", line
        ):
            malformed.append((line_number, line))

    assert not malformed, f"malformed Kconfig disable directives: {malformed}"


def test_kernel_fragment_keeps_numeric_values_comment_free() -> None:
    """Kconfig rejects trailing text on integer assignments."""
    malformed = []
    for line_number, line in enumerate(KERNEL_FRAGMENT.read_text().splitlines(), 1):
        if re.match(r"CONFIG_\w+=(?:0[xX][0-9a-fA-F]+|\d+)", line) and not re.fullmatch(
            r"CONFIG_\w+=(?:0[xX][0-9a-fA-F]+|\d+)", line
        ):
            malformed.append((line_number, line))

    assert not malformed, f"numeric Kconfig assignments have trailing text: {malformed}"


def test_generated_clint_range_matches_rtl_mmio_window() -> None:
    """The DT must not advertise addresses beyond the served MMIO window."""
    packer_text = BOOT_PACKER.read_text()
    rtl_text = CPU_AND_MEM.read_text()

    clint_reg = re.search(
        r"reg = <(0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)>;",
        packer_text[packer_text.index("clint@40010000") :],
    )
    mmio_size = re.search(r"MmioSizeBytes = 32'h([0-9A-Fa-f_]+);", rtl_text)
    assert clint_reg is not None
    assert mmio_size is not None

    clint_base = int(clint_reg.group(1), 16)
    clint_size = int(clint_reg.group(2), 16)
    rtl_mmio_end = 0x40000000 + int(mmio_size.group(1).replace("_", ""), 16)
    assert clint_base + clint_size == rtl_mmio_end
