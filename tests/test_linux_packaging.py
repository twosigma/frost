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

Covers the OpenSBI boot-image packer and the kernel configuration.
"""

import importlib.util
from types import ModuleType
import re
import struct
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
MMU_KERNEL_CONFIG = (
    REPO_ROOT
    / "linux"
    / "buildroot-external"
    / "board"
    / "frost"
    / "linux-frost.config"
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


def _load_module(path: Path) -> ModuleType:
    """Import a script by path (the packers are CLI tools, not packages)."""
    spec = importlib.util.spec_from_file_location(path.stem, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[path.stem] = module
    spec.loader.exec_module(module)
    return module


# --- OpenSBI boot image (frost_boot_image.py) ------------------------------


PMD_BYTES = 2 << 20  # the rv64 kernel's alignment
FORMER_DTB_OFFSET = 0x100_0000  # the fixed DTB offset the layout rule replaced


def _rtl_localparam(text: str, name: str) -> int:
    match = re.search(rf"localparam int unsigned {name} = 32'h([0-9A-Fa-f_]+);", text)
    assert match is not None, name
    return int(match.group(1).replace("_", ""), 16)


def _linux_image(packer: ModuleType, image_size: int, length: int = 0x40) -> bytes:
    """Return a synthetic Linux Image: header image_size and magic, zeros elsewhere."""
    image = bytearray(length)
    struct.pack_into("<Q", image, packer.LINUX_IMAGE_SIZE_OFFSET, image_size)
    image[0x30:0x38] = packer.LINUX_IMAGE_MAGIC
    return bytes(image)


def _decode_words(lines: str, start: int, length: int) -> bytes:
    """Decode length bytes of word lines (8 hex digits, newline) from index start."""
    words = lines[start : start + 9 * ((length + 3) // 4)].split()
    return b"".join(struct.pack("<I", int(word, 16)) for word in words)[:length]


def test_sbi_layout_slots_are_ordered_and_aligned() -> None:
    """The firmware and payload slots are fixed, ordered and aligned."""
    packer = _load_module(SBI_PACKER)
    assert packer.FW_OFFSET == 0
    assert packer.FW_OFFSET + packer.FW_MAX_BYTES <= packer.PAYLOAD_OFFSET
    # The rv64 kernel Image must sit on a PMD (2 MiB) boundary.
    assert packer.PMD_BYTES == PMD_BYTES
    assert packer.PAYLOAD_OFFSET % PMD_BYTES == 0
    assert packer.DTB_MIN_OFFSET == FORMER_DTB_OFFSET
    assert packer.PAYLOAD_OFFSET < packer.DTB_MIN_OFFSET
    assert packer.DTB_GROWTH_BYTES < packer.DTB_SLOT_BYTES
    assert packer.DTB_MIN_OFFSET + packer.DTB_SLOT_BYTES < packer.MEM_SIZE


# Payload footprints below, at and above the 14 MiB that fit under the former
# fixed DTB offset: a small raw binary, the kernel packed when the rule came
# in, exactly 14 MiB, one byte more, and a kernel with systemd's options.
@pytest.mark.parametrize(
    "footprint", [0x100, 0xCE7000, 0xE00000, 0xE00001, 0xF03000], ids=hex
)
def test_sbi_layout_rule_invariants(footprint: int) -> None:
    """The DTB takes the first PMD boundary at or above +16 MiB and the payload."""
    packer = _load_module(SBI_PACKER)
    layout = packer.plan_layout(footprint)
    assert layout.footprint == footprint
    assert layout.dtb_offset % PMD_BYTES == 0
    assert layout.dtb_offset >= FORMER_DTB_OFFSET
    assert layout.dtb_offset >= packer.PAYLOAD_OFFSET + footprint
    lowest = max(FORMER_DTB_OFFSET, packer.PAYLOAD_OFFSET + footprint)
    assert layout.dtb_offset < lowest + PMD_BYTES
    assert layout.initrd_offset == layout.dtb_offset + packer.DTB_SLOT_BYTES


def test_sbi_layout_keeps_the_former_offsets_up_to_14_mib() -> None:
    """Payloads that fit the former slot keep their addresses; larger ones move up.

    0xce7000 is the image_size of the kernel packed when the rule replaced the
    fixed offsets, so those images stay bit-identical.
    """
    packer = _load_module(SBI_PACKER)
    for footprint in (0x0, 0xCE7000, 0xE00000):
        layout = packer.plan_layout(footprint)
        assert (layout.dtb_offset, layout.initrd_offset) == (0x100_0000, 0x101_0000)
    layout = packer.plan_layout(0xF03000)
    assert (layout.dtb_offset, layout.initrd_offset) == (0x120_0000, 0x121_0000)


def test_sbi_layout_ends_inside_memory() -> None:
    """The DTB slot must end inside memory with or without an initramfs.

    An initramfs, when given, must end inside memory too. An empty initramfs
    passes and fails with the DTB slot, like an absent one.
    """
    packer = _load_module(SBI_PACKER)
    firmware, dtb = bytes(0x1000), bytes(0x800)
    # The highest DTB slot that ends inside memory, and the largest payload
    # footprint that still places the DTB there.
    top_dtb = (packer.MEM_SIZE - packer.DTB_SLOT_BYTES) // PMD_BYTES * PMD_BYTES
    highest = packer.plan_layout(top_dtb - packer.PAYLOAD_OFFSET)
    assert highest.dtb_offset == top_dtb
    room = packer.MEM_SIZE - highest.initrd_offset
    for initrd in (None, b"", bytes(room)):
        packer.check_layout(highest, firmware, dtb, initrd)
    with pytest.raises(
        AssertionError, match=rf"initramfs 0x{room + 1:x} bytes .* memory"
    ):
        packer.check_layout(highest, firmware, dtb, bytes(room + 1))
    # One more byte of payload puts the DTB slot past the end of memory.
    crossing = packer.plan_layout(highest.footprint + 1)
    assert crossing.dtb_offset + packer.DTB_SLOT_BYTES > packer.MEM_SIZE
    for initrd in (None, b""):
        with pytest.raises(
            AssertionError, match=rf"DTB slot at \+0x{crossing.dtb_offset:x}, .* memory"
        ):
            packer.check_layout(crossing, firmware, dtb, initrd)


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
    """PLIC, CLINT, UART, DMA engine and NIC addresses in the generated DT match the RTL."""
    packer = _load_module(SBI_PACKER)
    rtl_text = CPU_AND_MEM.read_text()
    assert packer.CLINT_BASE == _rtl_localparam(rtl_text, "ClintMsip")
    mmio_size = re.search(r"MmioSizeBytes = 32'h([0-9A-Fa-f_]+);", rtl_text)
    assert mmio_size is not None
    rtl_mmio_end = 0x40000000 + int(mmio_size.group(1).replace("_", ""), 16)
    # The DMA test engine's window follows the CLINT; the NIC's window follows
    # it and closes the MMIO region.
    assert packer.DMA_ENGINE_BASE == _rtl_localparam(rtl_text, "DmaEngineBase")
    assert packer.CLINT_BASE + packer.CLINT_SIZE <= packer.DMA_ENGINE_BASE
    assert packer.NIC_BASE == _rtl_localparam(rtl_text, "NicBase")
    assert packer.DMA_ENGINE_BASE + packer.DMA_ENGINE_SIZE <= packer.NIC_BASE
    assert packer.NIC_BASE + packer.NIC_SIZE == rtl_mmio_end
    assert packer.UART_BASE == _rtl_localparam(rtl_text, "Ns16550ThrRbr")
    # PLIC window: bits [31:22] select it (PlicWindowSel), 4 MiB wide.
    window_sel = re.search(r"PlicWindowSel = 10'h([0-9A-Fa-f]+);", rtl_text)
    assert window_sel is not None
    assert packer.PLIC_BASE == int(window_sel.group(1), 16) << 22
    assert packer.PLIC_SIZE == 1 << 22
    # The SoC's PLIC instance sets the source count (the module default is
    # generic): 1 = ns16550, 2 = board pin, 3 = DMA test engine, 4 = NIC.
    sources = re.search(r"\.NUM_SOURCES\s*\((\d+)\)", rtl_text)
    assert sources is not None and packer.PLIC_NDEV == int(sources.group(1))
    assert packer.NIC_PLIC_SOURCE == packer.PLIC_NDEV
    dts = packer.gen_dts(clk_hz=300_000_000, initrd_range=None, bootargs="", model="t")
    assert "interrupts-extended = <&cpu0_intc 11 &cpu0_intc 9>;" in dts
    assert f"interrupts = <{packer.UART_PLIC_SOURCE}>;" in dts
    # The NIC node: the binding in frost,net10g.yaml next to the packer.
    assert 'compatible = "frost,net10g";' in dts
    assert f"reg = <0x{packer.NIC_BASE:08x} 0x{packer.NIC_SIZE:x}>;" in dts
    assert f"interrupts = <{packer.NIC_PLIC_SOURCE}>;" in dts
    assert "dma-coherent;" in dts
    assert f"local-mac-address = [{packer.NIC_MAC_ADDRESS}];" in dts
    assert "clock-frequency = <300000000>;" in dts
    assert 'mmu-type = "riscv,sv39";' in dts
    for ext in ("sstc", "svade", "zicntr"):
        assert f'"{ext}"' in dts and f"_{ext}" in packer.ISA_STRING
    assert "bootargs" not in dts and "initrd" not in dts
    # The SBI-v3 EVENT_GET_INFO probe only reports events present in OpenSBI's
    # hw_event_map, which comes from this node; without it perf reports even
    # the fixed cycle/instret counters as unsupported.
    assert 'compatible = "riscv,pmu";' in dts
    assert "riscv,event-to-mhpmcounters = <0x00000001 0x00000001 0x00000001>" in dts
    assert "<0x00000002 0x00000002 0x00000004>" in dts


def test_sbi_packer_recognizes_linux_image_header() -> None:
    """A Linux Image is sized by its header; a raw payload by its length."""
    packer = _load_module(SBI_PACKER)
    raw = bytes(range(64))
    assert packer.linux_image_size(raw) is None
    assert packer.payload_footprint(raw) == len(raw)
    image = _linux_image(packer, image_size=0x123456)
    assert packer.linux_image_size(image) == 0x123456
    assert packer.payload_footprint(image) == 0x123456


def test_sbi_packer_places_the_dtb_by_image_size(tmp_path: Path) -> None:
    """The Image header's image_size places the DTB, and every output agrees.

    The file is exactly 14 MiB, so its length would leave the DTB at +16 MiB,
    but its bss (image_size 0xe01000) crosses that boundary and moves the DTB
    to +18 MiB. The shim's a1, the /chosen initramfs bounds, the sparse
    sw_ddr.mem that simulation reads and the dense sw_ddr.txt that the JTAG
    loader streams must all carry that one layout. Needs dtc and the
    riscv-none-elf- toolchain (both in the Docker image).
    """
    packer = _load_module(SBI_PACKER)
    image = _linux_image(packer, image_size=0xE01000, length=0xE00000)
    assert packer.plan_layout(len(image)).dtb_offset == FORMER_DTB_OFFSET
    dtb_offset, initrd_offset = 0x120_0000, 0x121_0000
    firmware = bytes(range(256)) * 16
    initrd = bytes(range(251)) * 17  # not a whole number of words
    inputs = {"fw_jump.bin": firmware, "Image": image, "rootfs.cpio": initrd}
    for name, content in inputs.items():
        (tmp_path / name).write_bytes(content)
    out = tmp_path / "out"
    argv = [
        "--firmware",
        str(tmp_path / "fw_jump.bin"),
        "--payload",
        str(tmp_path / "Image"),
        "--initrd",
        str(tmp_path / "rootfs.cpio"),
        "--out",
        str(out),
    ]
    assert packer.main(argv) == 0

    assert "    li   a1, 0x81200000\n" in (out / "frost_boot_shim.S").read_text()
    dts = (out / "frost.dts").read_text()
    initrd_start = packer.DDR_BASE + initrd_offset
    assert f"linux,initrd-start = <0x{initrd_start:08x}>;" in dts
    assert f"linux,initrd-end = <0x{initrd_start + len(initrd):08x}>;" in dts
    dtb = (out / "frost.dtb").read_bytes()
    regions = [
        (packer.FW_OFFSET, firmware),
        (packer.PAYLOAD_OFFSET, image),
        (dtb_offset, dtb),
        (initrd_offset, initrd),
    ]

    # sw_ddr.mem: one readmemh address record (in words) per region, in order.
    fields = re.split(
        r"^@([0-9a-f]{8})\n", (out / "sw_ddr.mem").read_text(), flags=re.M
    )
    assert fields[0] == ""
    assert fields[1::2] == [f"{offset // 4:08x}" for offset, _ in regions]
    records = dict(zip(fields[1::2], fields[2::2]))
    for offset, content in regions:
        body = records[f"{offset // 4:08x}"]
        assert len(body) == 9 * ((len(content) + 3) // 4)  # "xxxxxxxx\n" per word
        prefix = content[:0x2000]  # all of every region but the Image
        assert _decode_words(body, 0, len(prefix)) == prefix

    # sw_ddr.txt: every word from offset zero, zeros in the gaps.
    dense = (out / "sw_ddr.txt").read_text()
    assert len(dense) == 9 * ((initrd_offset + len(initrd) + 3) // 4)
    for offset, content in regions:
        prefix = content[:0x2000]
        assert _decode_words(dense, 9 * (offset // 4), len(prefix)) == prefix
    gap = dense[9 * (FORMER_DTB_OFFSET // 4) : 9 * (dtb_offset // 4)]
    assert set(gap.split()) == {"00000000"}


def test_mmu_kernel_config_uses_kconfig_syntax() -> None:
    """The MMU mini-config uses Kconfig syntax olddefconfig understands.

    It also keeps its load-bearing symbols, networking and the NIC driver
    among them, and leaves out the M-mode build's.
    """
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
        "CONFIG_NET=y",
        "CONFIG_FROST_NET10G=y",
    ):
        assert required in text, required
    for forbidden in ("CONFIG_NONPORTABLE=y", "CONFIG_RISCV_M_MODE=y"):
        assert forbidden not in text, forbidden
