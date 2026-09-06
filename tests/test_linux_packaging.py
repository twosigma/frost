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

"""Static contracts for the Linux configurations, device trees, and boot images.

Covers the no-MMU lane's packer and the OpenSBI lane's packer.
"""

import importlib.util
from types import ModuleType
import re
import struct
import sys
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
MMU_KERNEL_CONFIG = (
    REPO_ROOT
    / "linux"
    / "buildroot-external"
    / "board"
    / "frost"
    / "linux-frost.config"
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
SBI_PACKER = (
    REPO_ROOT
    / "linux"
    / "buildroot-external"
    / "board"
    / "frost"
    / "frost_boot_image.py"
)
OPENSBI_HELPER = REPO_ROOT / "linux" / "opensbi_build.py"
PLIC_SV = REPO_ROOT / "hw" / "rtl" / "cpu_and_mem" / "plic.sv"


def _load_module(path: Path) -> ModuleType:
    """Import a script by path (the packers are CLI tools, not packages)."""
    spec = importlib.util.spec_from_file_location(path.stem, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[path.stem] = module
    spec.loader.exec_module(module)
    return module


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


# --- OpenSBI boot image (frost_boot_image.py) ------------------------------


def _rtl_localparam(text: str, name: str) -> int:
    match = re.search(rf"localparam int unsigned {name} = 32'h([0-9A-Fa-f_]+);", text)
    assert match is not None, name
    return int(match.group(1).replace("_", ""), 16)


def test_sbi_layout_slots_are_ordered_and_aligned() -> None:
    """Firmware, payload, DTB, and initramfs occupy disjoint, ordered slots."""
    packer = _load_module(SBI_PACKER)
    assert packer.FW_OFFSET == 0
    assert packer.FW_OFFSET + packer.FW_MAX_BYTES <= packer.PAYLOAD_OFFSET
    # The rv64 kernel Image must sit on a PMD (2 MiB) boundary.
    assert packer.PAYLOAD_OFFSET % (2 << 20) == 0
    assert packer.PAYLOAD_OFFSET < packer.DTB_OFFSET
    assert packer.DTB_OFFSET + packer.DTB_SLOT_BYTES == packer.INITRD_OFFSET
    assert packer.DTB_GROWTH_BYTES < packer.DTB_SLOT_BYTES
    assert packer.INITRD_OFFSET < packer.MEM_SIZE


def test_sbi_layout_matches_opensbi_helper() -> None:
    """The packer's firmware and payload slots are what fw_jump is built for."""
    packer = _load_module(SBI_PACKER)
    helper = _load_module(OPENSBI_HELPER)
    assert helper.FW_TEXT_START == packer.DDR_BASE + packer.FW_OFFSET
    assert helper.FW_JUMP_OFFSET == packer.PAYLOAD_OFFSET - packer.FW_OFFSET
    # a1 passes through fw_jump untouched: the helper must leave the FDT
    # offset empty rather than let the generic default relocate the DTB.
    helper_text = OPENSBI_HELPER.read_text()
    assert '"FW_JUMP_FDT_OFFSET=",' in helper_text


def test_sbi_device_tree_matches_rtl_windows() -> None:
    """PLIC, CLINT, and UART addresses in the generated DT match the RTL."""
    packer = _load_module(SBI_PACKER)
    rtl_text = CPU_AND_MEM.read_text()
    assert packer.CLINT_BASE == _rtl_localparam(rtl_text, "ClintMsip")
    mmio_size = re.search(r"MmioSizeBytes = 32'h([0-9A-Fa-f_]+);", rtl_text)
    assert mmio_size is not None
    rtl_mmio_end = 0x40000000 + int(mmio_size.group(1).replace("_", ""), 16)
    assert packer.CLINT_BASE + packer.CLINT_SIZE == rtl_mmio_end
    assert packer.UART_BASE == _rtl_localparam(rtl_text, "Ns16550ThrRbr")
    # PLIC window: bits [31:22] select it (PlicWindowSel), 4 MiB wide.
    window_sel = re.search(r"PlicWindowSel = 10'h([0-9A-Fa-f]+);", rtl_text)
    assert window_sel is not None
    assert packer.PLIC_BASE == int(window_sel.group(1), 16) << 22
    assert packer.PLIC_SIZE == 1 << 22
    plic_text = PLIC_SV.read_text()
    sources = re.search(r"NUM_SOURCES\s*=\s*(\d+)", plic_text)
    assert sources is not None and packer.PLIC_NDEV == int(sources.group(1))
    dts = packer.gen_dts(clk_hz=300_000_000, initrd_range=None, bootargs="", model="t")
    assert "interrupts-extended = <&cpu0_intc 11 &cpu0_intc 9>;" in dts
    assert f"interrupts = <{packer.UART_PLIC_SOURCE}>;" in dts
    assert 'mmu-type = "riscv,sv39";' in dts
    for ext in ("sstc", "svade", "zicntr"):
        assert f'"{ext}"' in dts and f"_{ext}" in packer.ISA_STRING
    assert "bootargs" not in dts and "initrd" not in dts


def test_sbi_packer_recognizes_linux_image_header() -> None:
    """A Linux Image is sized by its header; a raw payload by its length."""
    packer = _load_module(SBI_PACKER)
    raw = bytes(range(64))
    assert packer.linux_image_size(raw) is None
    header = bytearray(64)
    struct.pack_into("<Q", header, packer.LINUX_IMAGE_SIZE_OFFSET, 0x123456)
    header[0x30:0x38] = packer.LINUX_IMAGE_MAGIC
    assert packer.linux_image_size(bytes(header)) == 0x123456


def test_mmu_kernel_config_uses_kconfig_syntax() -> None:
    """The MMU mini-config disables symbols the way olddefconfig understands."""
    malformed = []
    for line_number, line in enumerate(MMU_KERNEL_CONFIG.read_text().splitlines(), 1):
        if re.match(r"# CONFIG_\w+ is not set", line) and not re.fullmatch(
            r"# CONFIG_\w+ is not set", line
        ):
            malformed.append((line_number, line))
        if re.match(r"CONFIG_\w+=", line) and "#" in line:
            malformed.append((line_number, line))
    assert not malformed, f"malformed Kconfig lines: {malformed}"
    text = MMU_KERNEL_CONFIG.read_text()
    for required in (
        "CONFIG_MMU=y",
        "CONFIG_RISCV_SBI=y",
        "CONFIG_RISCV_EMULATED_UNALIGNED_ACCESS=y",
        "CONFIG_RISCV_PMU_SBI=y",
        "CONFIG_SERIAL_8250_CONSOLE=y",
    ):
        assert required in text, required
    for forbidden in ("CONFIG_NONPORTABLE=y", "CONFIG_RISCV_M_MODE=y"):
        assert forbidden not in text, forbidden
