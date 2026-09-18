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

import hashlib
import importlib.util
from types import ModuleType
import os
import re
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any

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
LOADER = REPO_ROOT / "fpga" / "load_software" / "load_software.py"
X3_DDR_BD = REPO_ROOT / "fpga" / "build" / "x3_ddr_bd.tcl"
APPS = REPO_ROOT / "sw" / "apps"
TESTS_MAKEFILE = REPO_ROOT / "tests" / "Makefile"


def _load_module(path: Path) -> ModuleType:
    """Import a script by path (the packers are CLI tools, not packages)."""
    spec = importlib.util.spec_from_file_location(path.stem, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[path.stem] = module
    spec.loader.exec_module(module)
    return module


def _load_script(name: str, path: Path, *import_dirs: Path) -> ModuleType:
    """Import a script that puts its own directories on sys.path; restore it."""
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    original = sys.path.copy()
    sys.path[:0] = [str(directory) for directory in import_dirs]
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path[:] = original
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


def _ddr_records(path: Path) -> dict[int, bytes]:
    """Decode a sparse sw_ddr.mem into its records' byte offsets and bytes, in order."""
    fields = re.split(r"^@([0-9a-f]{8})\n", path.read_text(), flags=re.M)
    assert fields[0] == ""
    return {
        int(address, 16) * 4: _decode_words(body, 0, len(body) // 9 * 4)
        for address, body in zip(fields[1::2], fields[2::2])
    }


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


# The header image_size of Debian 13's riscv64 kernel Image,
# /boot/vmlinux-6.12.107+deb13-riscv64.
DEBIAN_KERNEL_FOOTPRINT = 0x1E6B000


# Payload footprints below, at and above the 14 MiB that fit under the former
# fixed DTB offset: a small raw binary, the kernel packed when the rule came
# in, exactly 14 MiB, one byte more, a kernel with every option Buildroot's
# systemd package enables, and Debian's kernel.
@pytest.mark.parametrize(
    "footprint",
    [0x100, 0xCE7000, 0xE00000, 0xE00001, 0xF03000, DEBIAN_KERNEL_FOOTPRINT],
    ids=hex,
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


STATIC_IP = "192.0.2.2::192.0.2.1:255.255.255.0:frost:eth0:off"


@pytest.mark.parametrize(
    ("ip_args", "ip"),
    [([], "dhcp"), (["--ip", STATIC_IP], STATIC_IP)],
    ids=["dhcp", "static"],
)
def test_sbi_packer_nfsroot_packs_no_initramfs(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, ip_args: list[str], ip: str
) -> None:
    """--nfsroot alone packs the kernel's NFS-root bootargs, ip=dhcp unless --ip.

    No initramfs is packed: /chosen has no linux,initrd-* and sw_ddr.mem holds
    the firmware, the payload and the DTB only. Needs dtc and the
    riscv-none-elf- toolchain (both in the Docker image).
    """
    monkeypatch.delenv("FROST_INITRD", raising=False)
    packer = _load_module(SBI_PACKER)
    export = "192.0.2.1:/srv/nfs/debian"
    (tmp_path / "fw_jump.bin").write_bytes(bytes(range(256)))
    (tmp_path / "Image").write_bytes(_linux_image(packer, image_size=0x1000))
    out = tmp_path / "out"
    argv = [
        "--firmware",
        str(tmp_path / "fw_jump.bin"),
        "--payload",
        str(tmp_path / "Image"),
        "--out",
        str(out),
        "--nfsroot",
        export,
        *ip_args,
    ]
    assert packer.main(argv) == 0

    dts = (out / "frost.dts").read_text()
    bootargs = (
        f"earlycon console=ttyS0 root=/dev/nfs nfsroot={export},vers=3,tcp,hard rw "
        f"ip={ip}"
    )
    assert f'bootargs = "{bootargs}";' in dts
    assert "initrd" not in dts
    records = re.findall(r"^@([0-9a-f]{8})$", (out / "sw_ddr.mem").read_text(), re.M)
    offsets = (packer.FW_OFFSET, packer.PAYLOAD_OFFSET, FORMER_DTB_OFFSET)
    assert records == [f"{offset // 4:08x}" for offset in offsets]


def test_sbi_packer_nfsroot_arguments(monkeypatch: pytest.MonkeyPatch) -> None:
    """--nfsroot takes <server-ip>:/<path> and replaces the bootargs.

    --ip applies only with it, with or without an initramfs.
    """
    monkeypatch.delenv("FROST_INITRD", raising=False)
    packer = _load_module(SBI_PACKER)
    export = "192.0.2.1:/srv/nfs/debian"
    base = ["--firmware", "fw_jump.bin", "--payload", "Image"]
    for extra in (
        ["--nfsroot", "/srv/nfs/debian"],
        ["--nfsroot", export, "--bootargs", "quiet"],
        ["--nfsroot", export, "--initrd", "initrd.img", "--bootargs", "quiet"],
        ["--ip", "dhcp"],
        ["--ip", "dhcp", "--initrd", "initrd.img"],
    ):
        with pytest.raises(SystemExit):
            packer.parse_args(base + extra)
    args = packer.parse_args(base + ["--nfsroot", export])
    assert args.bootargs == packer.nfsroot_bootargs(export)
    args = packer.parse_args(base + ["--nfsroot", export, "--initrd", "initrd.img"])
    assert args.bootargs == packer.nfsroot_bootargs(export, initramfs=True)


# klibc 2.0.14 (Debian trixie's klibc-utils) nfsmount, which initramfs-tools'
# NFS boot runs as `nfsmount -o nolock -o rw -o <nfsroot options>`
# (scripts/nfs:76): the option names it accepts (usr/kinit/nfsmount/main.c
# int_opts and bool_opts, lines 40-85). Any other name fails the mount with
# "bad option", values must be integers (parse_int, lines 87-98), and vers= and
# nfsvers= take only 2 or 3 (lines 136-149).
KLIBC_NFSMOUNT_VALUE_OPTIONS = frozenset(
    "port nfsvers vers rsize wsize timeo retrans acregmin acregmax acdirmin "
    "acdirmax".split()
)
KLIBC_NFSMOUNT_FLAG_OPTIONS = frozenset(
    "soft hard intr nointr posix noposix cto nocto ac noac lock nolock acl noacl "
    "v2 v3 udp tcp broken_suid ro rw".split()
)


def test_sbi_nfsroot_options_suit_the_kernel_and_initramfs_tools() -> None:
    """Both NFS roots mount NFSv3 over TCP, hard, with options klibc accepts.

    The kernel's NFS root and initramfs-tools' NFS boot both split nfsroot= at
    its first comma into the export and the mount options. initramfs-tools
    hands the options to klibc's nfsmount, whose option names are not nfs(5)'s,
    so every option must be one it knows.
    """
    packer = _load_module(SBI_PACKER)
    assert packer.NFSROOT_OPTIONS == "vers=3,tcp,hard"
    for option in packer.NFSROOT_OPTIONS.split(","):
        name, _, value = option.partition("=")
        if value:
            assert name in KLIBC_NFSMOUNT_VALUE_OPTIONS and value.isdigit()
            if name in {"vers", "nfsvers"}:
                assert value in {"2", "3"}
        else:
            assert name in KLIBC_NFSMOUNT_FLAG_OPTIONS
    export = "192.0.2.1:/srv/nfs/debian"
    for initramfs in (False, True):
        words = packer.nfsroot_bootargs(export, initramfs=initramfs).split()
        assert f"nfsroot={export},{packer.NFSROOT_OPTIONS}" in words
        assert ("boot=nfs" in words) == initramfs
        # initramfs-tools mounts the root read-only unless rw is given.
        assert {"root=/dev/nfs", "rw", "ip=dhcp"} <= set(words)


@pytest.mark.parametrize(
    ("ip_args", "ip"),
    [([], "dhcp"), (["--ip", STATIC_IP], STATIC_IP)],
    ids=["dhcp", "static"],
)
def test_sbi_packer_nfsroot_through_an_initramfs(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, ip_args: list[str], ip: str
) -> None:
    """--nfsroot with --initrd packs the initramfs and initramfs-tools NFS bootargs.

    boot=nfs selects initramfs-tools' NFS boot; ip= and the nfsroot= options
    are the ones the kernel's own NFS root gets. The initramfs is packed after
    the DTB slot as usual. Needs dtc and the riscv-none-elf- toolchain (both in
    the Docker image).
    """
    monkeypatch.delenv("FROST_INITRD", raising=False)
    packer = _load_module(SBI_PACKER)
    export = "192.0.2.1:/srv/nfs/debian"
    initrd = bytes(range(7, 256)) * 13  # not a whole number of words
    (tmp_path / "initrd.img").write_bytes(initrd)
    extra = ["--nfsroot", export, "--initrd", str(tmp_path / "initrd.img")]
    out = _pack_minimal(packer, tmp_path, *extra, *ip_args)

    dts = (out / "frost.dts").read_text()
    bootargs = (
        "earlycon console=ttyS0 boot=nfs root=/dev/nfs "
        f"nfsroot={export},vers=3,tcp,hard rw ip={ip}"
    )
    assert f'bootargs = "{bootargs}";' in dts
    initrd_start = packer.DDR_BASE + FORMER_DTB_OFFSET + packer.DTB_SLOT_BYTES
    assert f"linux,initrd-start = <0x{initrd_start:08x}>;" in dts
    assert f"linux,initrd-end = <0x{initrd_start + len(initrd):08x}>;" in dts
    records = _ddr_records(out / "sw_ddr.mem")
    assert list(records) == [
        packer.FW_OFFSET,
        packer.PAYLOAD_OFFSET,
        FORMER_DTB_OFFSET,
        FORMER_DTB_OFFSET + packer.DTB_SLOT_BYTES,
    ]
    assert records[FORMER_DTB_OFFSET + packer.DTB_SLOT_BYTES][: len(initrd)] == initrd


@pytest.mark.parametrize(
    ("mac_args", "mac"),
    [([], "02:11:22:33:44:55"), (["--mac", "0A:bc:DE:01:23:45"], "0a:bc:de:01:23:45")],
    ids=["default", "override"],
)
def test_sbi_packer_nic_mac_address(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, mac_args: list[str], mac: str
) -> None:
    """The NIC's local-mac-address is 02:11:22:33:44:55 unless --mac names one.

    Needs dtc and the riscv-none-elf- toolchain (both in the Docker image).
    """
    monkeypatch.delenv("FROST_INITRD", raising=False)
    packer = _load_module(SBI_PACKER)
    (tmp_path / "fw_jump.bin").write_bytes(bytes(range(256)))
    (tmp_path / "Image").write_bytes(_linux_image(packer, image_size=0x1000))
    out = tmp_path / "out"
    argv = [
        "--firmware",
        str(tmp_path / "fw_jump.bin"),
        "--payload",
        str(tmp_path / "Image"),
        "--out",
        str(out),
        *mac_args,
    ]
    assert packer.main(argv) == 0
    dts = (out / "frost.dts").read_text()
    assert f"local-mac-address = [{mac.replace(':', ' ')}];" in dts
    assert bytes.fromhex(mac.replace(":", "")) in (out / "frost.dtb").read_bytes()


def test_sbi_packer_rejects_bad_mac_addresses() -> None:
    """--mac takes a unicast aa:bb:cc:dd:ee:ff; anything else is a usage error."""
    packer = _load_module(SBI_PACKER)
    base = ["--firmware", "fw_jump.bin", "--payload", "Image", "--mac"]
    for bad in (
        "02:11:22:33:44",
        "02:11:22:33:44:55:66",
        "02-11-22-33-44-55",
        "021122334455",
        "2:11:22:33:44:55",
        "02:11:22:33:44:5g",
        "03:11:22:33:44:55",  # multicast
        "ff:ff:ff:ff:ff:ff",  # broadcast
        "00:00:00:00:00:00",
    ):
        with pytest.raises(SystemExit):
            packer.parse_args(base + [bad])


def _pack_minimal(packer: ModuleType, tmp_path: Path, *extra: str) -> Path:
    """Pack a small firmware and Linux Image (plus extra arguments); return --out."""
    (tmp_path / "fw_jump.bin").write_bytes(bytes(range(256)))
    (tmp_path / "Image").write_bytes(_linux_image(packer, image_size=0x1000))
    out = tmp_path / "out"
    argv = [
        "--firmware",
        str(tmp_path / "fw_jump.bin"),
        "--payload",
        str(tmp_path / "Image"),
        "--out",
        str(out),
        *extra,
    ]
    assert packer.main(argv) == 0
    return out


@pytest.mark.parametrize(
    ("mem_args", "size"),
    [
        ([], 0x0400_0000),
        (["--mem-size", "0x40000000"], 0x4000_0000),
        (["--mem-size", "1073741824"], 0x4000_0000),
    ],
    ids=["default", "hex", "decimal"],
)
def test_sbi_packer_memory_node_size(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, mem_args: list[str], size: int
) -> None:
    """/memory advertises MEM_SIZE (64 MiB) unless --mem-size names a size.

    Needs dtc and the riscv-none-elf- toolchain (both in the Docker image).
    """
    monkeypatch.delenv("FROST_INITRD", raising=False)
    packer = _load_module(SBI_PACKER)
    assert packer.MEM_SIZE == 0x0400_0000
    out = _pack_minimal(packer, tmp_path, *mem_args)
    assert f"reg = <0x80000000 0x{size:08x}>;" in (out / "frost.dts").read_text()


def test_sbi_layout_checks_use_the_memory_size(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The memory size, not MEM_SIZE, bounds the DTB slot and the initramfs."""
    monkeypatch.delenv("FROST_INITRD", raising=False)
    packer = _load_module(SBI_PACKER)
    firmware, dtb = bytes(0x1000), bytes(0x800)
    # A payload whose DTB slot ends past 64 MiB fits a 1 GiB memory node.
    beyond = packer.plan_layout(packer.MEM_SIZE)
    with pytest.raises(AssertionError, match=r"overruns the 0x4000000 memory node"):
        packer.check_layout(beyond, firmware, dtb, None)
    packer.check_layout(beyond, firmware, dtb, None, packer.CACHED_REGION_BYTES)
    # An 18 MiB node leaves room for the initramfs up to its end and not past it.
    small = 0x120_0000
    layout = packer.plan_layout(0x1000)
    room = small - layout.initrd_offset
    packer.check_layout(layout, firmware, dtb, bytes(room), small)
    with pytest.raises(AssertionError, match=r"overruns the 0x1200000 memory node"):
        packer.check_layout(layout, firmware, dtb, bytes(room + 1), small)
    # 16 MiB cannot hold the DTB slot at +16 MiB.
    with pytest.raises(AssertionError, match=r"overruns the 0x1000000 memory node"):
        _pack_minimal(packer, tmp_path, "--mem-size", "0x1000000")


def test_sbi_layout_fits_debian_kernel_and_initramfs_in_1_gib() -> None:
    """Debian's kernel puts the DTB at +34 MiB; its initramfs needs a board's memory.

    A 40 MB initramfs after it ends past the 64 MiB default memory node, and
    the failure names the node's size and --mem-size. It fits the X3's 1 GiB,
    which load_software.py advertises.
    """
    packer = _load_module(SBI_PACKER)
    layout = packer.plan_layout(DEBIAN_KERNEL_FOOTPRINT)
    assert (layout.dtb_offset, layout.initrd_offset) == (0x220_0000, 0x221_0000)
    firmware, dtb, initrd = bytes(0x2_1000), bytes(0x900), bytes(40_000_000)
    packer.check_layout(layout, firmware, dtb, initrd, packer.CACHED_REGION_BYTES)
    overrun = (
        r"initramfs 0x2625a00 bytes at \+0x2210000 overruns the 0x4000000 memory "
        r"node \(its size is --mem-size\)"
    )
    with pytest.raises(AssertionError, match=overrun):
        packer.check_layout(layout, firmware, dtb, initrd)


def test_sbi_packer_rejects_bad_memory_sizes() -> None:
    """--mem-size takes a multiple of 2 MiB within the 1 GiB cached region."""
    packer = _load_module(SBI_PACKER)
    base = ["--firmware", "fw_jump.bin", "--payload", "Image", "--mem-size"]
    for bad in (
        "0",
        "-0x200000",
        "0x100000",  # 1 MiB
        "0x4000001",
        "0x40200000",  # past the cached region
        "0x80000000",
        "64M",
        "",
    ):
        with pytest.raises(SystemExit):
            packer.parse_args(base + [bad])


def test_sbi_memory_bounds_match_the_rtl_and_the_ddr_model() -> None:
    """The cached region caps --mem-size, and the default is the DDR model's size.

    Simulation packs the default, so it never advertises more memory than the
    cocotb DDR model (tests/Makefile DDR_MODEL_BYTES) holds.
    """
    packer = _load_module(SBI_PACKER)
    rtl = CPU_AND_MEM.read_text()
    base = re.search(r"CACHED_BASE = 32'h([0-9A-Fa-f_]+)", rtl)
    size = re.search(r"CACHED_SIZE_BYTES = 32'h([0-9A-Fa-f_]+)", rtl)
    assert base is not None and size is not None
    assert packer.DDR_BASE == int(base.group(1).replace("_", ""), 16)
    assert packer.CACHED_REGION_BYTES == int(size.group(1).replace("_", ""), 16)
    model = re.search(r"^DDR_MODEL_BYTES \?= (\d+)$", TESTS_MAKEFILE.read_text(), re.M)
    assert model is not None and packer.MEM_SIZE == int(model.group(1))


def test_load_software_takes_each_board_ddr_from_its_block_design(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The board's DDR size is the CPU port's range in fpga/build/<board>_ddr_bd.tcl.

    Every board the loader runs linux_boot on (those with DDR) has one the
    packer accepts; the X3 maps the whole 1 GiB cached region, as much as its
    CPU port (S00_AXI) addresses. The range of the JTAG master's port does not
    count.
    """
    loader = _load_script("linux_packaging_loader", LOADER)
    packer = _load_module(SBI_PACKER)
    ddr_boards = [board for board, cfg in loader.BOARD_CONFIG.items() if cfg["has_ddr"]]
    assert "x3" in ddr_boards
    for board in ddr_boards:
        size = loader.board_ddr_bytes(board)
        assert packer.memory_size(str(size)) == size
    width = re.search(r"CONFIG\.ADDR_WIDTH \{(\d+)\}", X3_DDR_BD.read_text())
    assert width is not None
    assert loader.board_ddr_bytes("x3") == 1 << int(width.group(1))
    assert loader.board_ddr_bytes("x3") == packer.CACHED_REGION_BYTES

    build = tmp_path / "fpga" / "build"
    build.mkdir(parents=True)
    segment = "[get_bd_addr_segs ddr4_0/C0_DDR4_MEMORY_MAP/C0_DDR4_ADDRESS_BLOCK]"
    (build / "two_ddr_bd.tcl").write_text(
        "  assign_bd_address -offset 0x00000000 -range 0x40000000 \\\n"
        "      -target_address_space [get_bd_addr_spaces jtag_axi_ddr/Data] \\\n"
        f"      {segment} -force\n"
        "  assign_bd_address -offset 0x00000000 -range 0x20000000 \\\n"
        "      -target_address_space [get_bd_addr_spaces S00_AXI] \\\n"
        f"      {segment} -force\n"
    )
    (build / "none_ddr_bd.tcl").write_text('create_bd_design "ddr_subsys"\n')
    monkeypatch.setattr(loader, "PROJECT_ROOT", tmp_path)
    assert loader.board_ddr_bytes("two") == 0x2000_0000
    with pytest.raises(ValueError, match="S00_AXI"):
        loader.board_ddr_bytes("none")


def test_load_software_packs_linux_boot_for_the_board_ddr(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """load_software hands linux_boot the board's DDR size as FROST_LINUX_MEM_SIZE."""
    loader = _load_script("linux_packaging_loader", LOADER)
    compile_app_for_board = loader.compile_app_for_board
    monkeypatch.setattr(
        sys, "argv", ["load_software.py", "x3", "linux_boot", "--build-only"]
    )
    monkeypatch.setattr(loader, "_linux_boot_preflight", lambda: None)
    monkeypatch.setattr(
        loader, "select_target", lambda *a, **k: pytest.fail("cable touched")
    )
    builds: list[dict[str, Any]] = []

    def build(*args: Any, **kwargs: Any) -> bool:
        builds.append(kwargs)
        return True

    monkeypatch.setattr(loader, "compile_app_for_board", build)
    loader.main()
    assert [kwargs["ddr_bytes"] for kwargs in builds] == [1 << 30]

    monkeypatch.delenv("FROST_LINUX_MEM_SIZE", raising=False)
    environments: list[dict[str, str]] = []

    def run(command: list[str], **kwargs: Any) -> Any:
        environments.append(kwargs["env"])
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(loader.subprocess, "run", run)
    (tmp_path / "sw.mem").write_text("")
    (tmp_path / "sw.txt").write_text("")
    assert compile_app_for_board("linux_boot", tmp_path, 1, 1, ddr_bytes=1 << 30)
    assert compile_app_for_board("hello_world", tmp_path, 1, 1)
    assert [env.get("FROST_LINUX_MEM_SIZE") for env in environments] == [
        str(1 << 30),
        str(1 << 30),
        None,
        None,
    ]


@pytest.mark.parametrize("model", [None, "134217728"], ids=["default", "model"])
def test_simulation_never_packs_a_board_memory_size(
    monkeypatch: pytest.MonkeyPatch, model: str | None
) -> None:
    """A simulation build of linux_boot packs for the DDR model, never a board.

    A FROST_LINUX_MEM_SIZE exported for load_software.py is dropped: the build
    gets DDR_MODEL_BYTES when that is set, else the packer's default.
    """
    compile_app = _load_script(
        "linux_packaging_compile_app", APPS / "compile_app.py", APPS
    )
    monkeypatch.setenv("FROST_LINUX_MEM_SIZE", str(1 << 30))
    if model is None:
        monkeypatch.delenv("DDR_MODEL_BYTES", raising=False)
    else:
        monkeypatch.setenv("DDR_MODEL_BYTES", model)
    environments: list[dict[str, str]] = []

    def run(command: list[str], **kwargs: Any) -> Any:
        environments.append(kwargs["env"])
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(compile_app.subprocess, "run", run)
    compile_app.compile_app("linux_boot", clean_first=True)
    assert len(environments) == 2  # make clean, make
    assert all(env.get("FROST_LINUX_MEM_SIZE") == model for env in environments)


def test_kernel_and_initramfs_reach_the_linux_boot_make(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """load_software and compile_app hand FROST_LINUX_KERNEL and _INITRD to make.

    Both copy the caller's environment into make's, as for the other
    FROST_LINUX_* variables.
    """
    substitutes = {
        "FROST_LINUX_KERNEL": "/srv/images/vmlinux",
        "FROST_LINUX_INITRD": "/srv/images/initrd.img",
    }
    for name, value in substitutes.items():
        monkeypatch.setenv(name, value)
    environments: list[dict[str, str]] = []

    def run(command: list[str], **kwargs: Any) -> Any:
        environments.append(kwargs["env"])
        return subprocess.CompletedProcess(command, 0, "", "")

    loader = _load_script("linux_packaging_loader", LOADER)
    monkeypatch.setattr(loader.subprocess, "run", run)
    (tmp_path / "sw.mem").write_text("")
    (tmp_path / "sw.txt").write_text("")
    assert loader.compile_app_for_board("linux_boot", tmp_path, 1, 1, ddr_bytes=1 << 30)
    compile_app = _load_script(
        "linux_packaging_compile_app", APPS / "compile_app.py", APPS
    )
    monkeypatch.setattr(compile_app.subprocess, "run", run)
    compile_app.compile_app("linux_boot", clean_first=True)
    assert len(environments) == 4  # make clean and make, from each
    for env in environments:
        assert {name: env.get(name) for name in substitutes} == substitutes


# --- linux_boot's Makefile ------------------------------------------------------


LINUX_BOOT_MAKEFILE = APPS / "linux_boot" / "Makefile"
DWORD_MEM_HELPER = REPO_ROOT / "sw" / "common" / "make_dword_mem.py"
LINUX_BOOT_OUTPUTS = (
    "sw.mem",
    "sw.txt",
    "sw64.mem",
    "sw_ddr.mem",
    "sw_ddr.txt",
    "frost.dts",
    "frost.dtb",
    "frost_boot_shim.S",
)
NFS_EXPORT = "192.0.2.1:/srv/nfs/debian"


def _linux_boot_tree(tmp_path: Path) -> Path:
    """Lay out linux_boot's Makefile, the packer and Buildroot-like images.

    The Makefile finds the packer and Buildroot's images (fw_jump.bin, Image,
    rootfs.cpio, synthetic here) relative to the directory make runs in, not
    its own file (a symlink here), so make packs those and writes only under
    tmp_path. Returns the app directory.
    """
    packer = _load_module(SBI_PACKER)
    app = tmp_path / "sw" / "apps" / "linux_boot"
    board = tmp_path / "linux" / "buildroot-external" / "board" / "frost"
    common = tmp_path / "sw" / "common"
    images = tmp_path / "linux" / "build-mmu" / "images"
    for directory in (app, board, common, images):
        directory.mkdir(parents=True)
    (app / "Makefile").symlink_to(LINUX_BOOT_MAKEFILE)
    (board / SBI_PACKER.name).symlink_to(SBI_PACKER)
    (common / DWORD_MEM_HELPER.name).symlink_to(DWORD_MEM_HELPER)
    (images / "fw_jump.bin").write_bytes(bytes(range(256)))
    (images / "Image").write_bytes(_linux_image(packer, image_size=0x1000))
    (images / "rootfs.cpio").write_bytes(bytes(range(251)) * 3)
    return app


def _make_linux_boot(app: Path, **variables: str) -> subprocess.CompletedProcess[str]:
    """Run make clean, then make, in the app with only these FROST_* variables set.

    They go in the environment, and make cleans first, as load_software.py and
    compile_app.py do. The shim builds with the packer's default cross prefix,
    and the clock is the Makefile's default.
    """
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("FROST_", "MAKE", "MFLAGS"))
        and key not in {"RISCV_PREFIX", "FPGA_CPU_CLK_FREQ"}
    }
    env.update(variables)
    subprocess.run(
        ["make", "-C", str(app), "clean"],
        env=env,
        capture_output=True,
        check=True,
        timeout=60,
    )
    return subprocess.run(
        ["make", "-C", str(app)], env=env, capture_output=True, text=True, timeout=120
    )


def _output_digests(app: Path) -> dict[str, str]:
    return {
        name: hashlib.sha256((app / name).read_bytes()).hexdigest()
        for name in LINUX_BOOT_OUTPUTS
    }


def test_linux_boot_make_substitutes_the_kernel_and_initramfs(tmp_path: Path) -> None:
    """FROST_LINUX_KERNEL and FROST_LINUX_INITRD replace Image and rootfs.cpio.

    Substitutes with Buildroot's bytes pack every output exactly as Buildroot's
    files do. Other files are packed in their place, the DTB placed by the
    substituted Image's header, with the default bootargs. Needs make, dtc and
    the riscv-none-elf- toolchain (all in the Docker image).
    """
    packer = _load_module(SBI_PACKER)
    app = _linux_boot_tree(tmp_path)
    images = tmp_path / "linux" / "build-mmu" / "images"
    result = _make_linux_boot(app)
    assert result.returncode == 0, result.stderr
    buildroot = _output_digests(app)
    copies = tmp_path / "copies"
    copies.mkdir()
    for name in ("Image", "rootfs.cpio"):
        (copies / name).write_bytes((images / name).read_bytes())
    result = _make_linux_boot(
        app,
        FROST_LINUX_KERNEL=str(copies / "Image"),
        FROST_LINUX_INITRD=str(copies / "rootfs.cpio"),
    )
    assert result.returncode == 0, result.stderr
    assert _output_digests(app) == buildroot

    # A bss past +16 MiB puts the DTB at +18 MiB.
    kernel = _linux_image(packer, image_size=0xF03000) + bytes(range(256)) * 8
    initrd = bytes(range(3, 256)) * 9  # not a whole number of words
    (tmp_path / "vmlinux").write_bytes(kernel)
    (tmp_path / "initrd.img").write_bytes(initrd)
    result = _make_linux_boot(
        app,
        FROST_LINUX_KERNEL=str(tmp_path / "vmlinux"),
        FROST_LINUX_INITRD=str(tmp_path / "initrd.img"),
    )
    assert result.returncode == 0, result.stderr
    records = _ddr_records(app / "sw_ddr.mem")
    assert list(records) == [0, 0x20_0000, 0x120_0000, 0x121_0000]
    assert records[packer.PAYLOAD_OFFSET][: len(kernel)] == kernel
    assert records[0x121_0000][: len(initrd)] == initrd
    dts = (app / "frost.dts").read_text()
    assert f'bootargs = "{packer.DEFAULT_BOOTARGS}";' in dts
    assert "linux,initrd-start = <0x81210000>;" in dts
    assert f"linux,initrd-end = <0x{0x8121_0000 + len(initrd):08x}>;" in dts
    assert "li   a1, 0x81200000" in (app / "frost_boot_shim.S").read_text()


@pytest.mark.parametrize(
    ("variables", "initramfs", "ip"),
    [
        ({}, False, "dhcp"),
        ({"FROST_LINUX_IP": STATIC_IP}, False, STATIC_IP),
        ({"FROST_INITRD": "initrd.img"}, False, "dhcp"),
        ({"FROST_LINUX_INITRD": "initrd.img"}, True, "dhcp"),
        (
            {"FROST_LINUX_INITRD": "initrd.img", "FROST_LINUX_IP": STATIC_IP},
            True,
            STATIC_IP,
        ),
    ],
    ids=[
        "kernel-dhcp",
        "kernel-static",
        "kernel-packer-env",
        "initramfs-dhcp",
        "initramfs-static",
    ],
)
def test_linux_boot_make_nfsroot(
    tmp_path: Path, variables: dict[str, str], initramfs: bool, ip: str
) -> None:
    """FROST_LINUX_NFSROOT boots from the export; FROST_LINUX_INITRD mounts it.

    Without FROST_LINUX_INITRD nothing follows the DTB and the kernel mounts
    the export, even with the packer's own FROST_INITRD in the environment;
    with it, that initramfs is packed and mounts it (boot=nfs). Needs make,
    dtc and the riscv-none-elf- toolchain (all in the Docker image).
    """
    packer = _load_module(SBI_PACKER)
    app = _linux_boot_tree(tmp_path)
    initrd = bytes(range(5, 256)) * 11
    (tmp_path / "initrd.img").write_bytes(initrd)
    environment = {"FROST_LINUX_NFSROOT": NFS_EXPORT, **variables}
    for name in ("FROST_LINUX_INITRD", "FROST_INITRD"):
        if name in environment:
            environment[name] = str(tmp_path / "initrd.img")
    result = _make_linux_boot(app, **environment)
    assert result.returncode == 0, result.stderr
    dts = (app / "frost.dts").read_text()
    bootargs = packer.nfsroot_bootargs(NFS_EXPORT, ip, initramfs)
    assert f'bootargs = "{bootargs}";' in dts
    offsets = [packer.FW_OFFSET, packer.PAYLOAD_OFFSET, FORMER_DTB_OFFSET]
    records = _ddr_records(app / "sw_ddr.mem")
    if initramfs:
        offsets.append(FORMER_DTB_OFFSET + packer.DTB_SLOT_BYTES)
        assert records[offsets[-1]][: len(initrd)] == initrd
        assert "linux,initrd-start = <0x81010000>;" in dts
    else:
        assert "initrd" not in dts
    assert list(records) == offsets


@pytest.mark.parametrize(
    ("variables", "message"),
    [
        ({"FROST_LINUX_IP": STATIC_IP}, "--ip applies only with --nfsroot"),
        (
            {"FROST_LINUX_IP": "dhcp", "FROST_LINUX_INITRD": "rootfs.cpio"},
            "--ip applies only with --nfsroot",
        ),
        ({"FROST_LINUX_KERNEL": "missing"}, "No rule to make target"),
        (
            {"FROST_LINUX_NFSROOT": NFS_EXPORT, "FROST_LINUX_INITRD": "missing"},
            "No rule to make target",
        ),
    ],
    ids=["ip", "ip-initrd", "missing-kernel", "missing-initrd"],
)
def test_linux_boot_make_rejects(
    tmp_path: Path, variables: dict[str, str], message: str
) -> None:
    """Make packs nothing for ip= without an NFS root or a missing substitute."""
    app = _linux_boot_tree(tmp_path)
    images = tmp_path / "linux" / "build-mmu" / "images"
    paths = {"FROST_LINUX_KERNEL", "FROST_LINUX_INITRD"}
    environment = {
        name: str(images / value) if name in paths else value
        for name, value in variables.items()
    }
    result = _make_linux_boot(app, **environment)
    assert result.returncode != 0
    assert message in result.stderr
    assert not (app / "sw_ddr.mem").exists()


def test_mmu_kernel_config_uses_kconfig_syntax() -> None:
    """The MMU mini-config uses Kconfig syntax olddefconfig understands.

    It also keeps its load-bearing symbols, networking, the NFS root, systemd's
    requirements and the NIC driver among them, keeps IPv6 off, and leaves out
    the M-mode build's.
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
        "CONFIG_INET=y",
        "CONFIG_IP_PNP=y",
        "CONFIG_IP_PNP_DHCP=y",
        "# CONFIG_IPV6 is not set",
        "CONFIG_NFS_FS=y",
        "CONFIG_NFS_V3=y",
        "CONFIG_ROOT_NFS=y",
        "CONFIG_CGROUPS=y",
        "CONFIG_UNIX=y",
        "CONFIG_FROST_NET10G=y",
    ):
        assert required in text, required
    for forbidden in ("CONFIG_NONPORTABLE=y", "CONFIG_RISCV_M_MODE=y"):
        assert forbidden not in text, forbidden
