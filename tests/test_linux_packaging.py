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
import io
import os
import re
import struct
import subprocess
import sys
import tarfile
from pathlib import Path
from types import ModuleType
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
DEBIAN_KERNEL = REPO_ROOT / "linux" / "debian_kernel.py"
DRIVER_DIR = REPO_ROOT / "linux" / "frost-net10g"
LOADER = REPO_ROOT / "fpga" / "load_software" / "load_software.py"
X3_DDR_BD = REPO_ROOT / "fpga" / "build" / "x3_ddr_bd.tcl"
APPS = REPO_ROOT / "sw" / "apps"
TESTS_MAKEFILE = REPO_ROOT / "tests" / "Makefile"
CI_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "ci.yml"
POST_IMAGE = (
    REPO_ROOT / "linux" / "buildroot-external" / "board" / "frost" / "post-image-mmu.sh"
)


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
# /boot/vmlinux-6.12.107+deb13-riscv64, which FROST boots everywhere.
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
    """Lay out linux_boot's Makefile, the packer, and synthetic build inputs.

    The Makefile finds the packer, Buildroot's images (fw_jump.bin,
    rootfs.cpio) and the Debian kernel helper relative to the directory make
    runs in, not its own file (a symlink here), so make packs those and writes
    only under tmp_path. The Debian cache holds a synthetic kernel Image and
    the NIC module a synthetic .ko, so no make in these tests downloads
    anything or needs a cross toolchain. Returns the app directory.
    """
    packer = _load_module(SBI_PACKER)
    helper = _load_module(DEBIAN_KERNEL)
    app = tmp_path / "sw" / "apps" / "linux_boot"
    board = tmp_path / "linux" / "buildroot-external" / "board" / "frost"
    common = tmp_path / "sw" / "common"
    images = tmp_path / "linux" / "build-mmu" / "images"
    driver = tmp_path / "linux" / "frost-net10g"
    for directory in (app, board, common, images, driver):
        directory.mkdir(parents=True)
    (app / "Makefile").symlink_to(LINUX_BOOT_MAKEFILE)
    (board / SBI_PACKER.name).symlink_to(SBI_PACKER)
    (common / DWORD_MEM_HELPER.name).symlink_to(DWORD_MEM_HELPER)
    (tmp_path / "linux" / DEBIAN_KERNEL.name).symlink_to(DEBIAN_KERNEL)
    for name in ("Makefile", "frost_net10g.c"):
        (driver / name).symlink_to(DRIVER_DIR / name)
    (images / "fw_jump.bin").write_bytes(bytes(range(256)))
    # A real newc archive, with the frost_stress the Makefile's preflight looks
    # inside for the counter mode it has to type.
    (images / "rootfs.cpio").write_bytes(_newc_archive(BASE_ENTRIES))
    # A complete Debian cache entry, so no make in these tests reaches the
    # network: the helper names the directory and says what has to be in it.
    cache = tmp_path / "debian-kernel"
    root = helper.sysroot(cache)
    for name, path in helper.required_files(root).items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(
            _linux_image(packer, image_size=0x1000)
            if name == "image"
            else f"# synthetic {name}\n".encode()
        )
    helper.write_manifest(root)
    (tmp_path / "frost_net10g.ko").write_bytes(bytes(range(97)) * 5)
    return app


def _make_linux_boot(app: Path, **variables: str) -> subprocess.CompletedProcess[str]:
    """Run make clean, then make, in the app with only these FROST_* variables set.

    They go in the environment, and make cleans first, as load_software.py and
    compile_app.py do. The shim builds with the packer's default cross prefix,
    and the clock is the Makefile's default. The Debian cache and the prebuilt
    module are the synthetic ones _linux_boot_tree laid down.
    """
    tree = app.parents[2]
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("FROST_", "MAKE", "MFLAGS"))
        and key not in {"RISCV_PREFIX", "FPGA_CPU_CLK_FREQ"}
    }
    env["FROST_DEBIAN_KERNEL_CACHE"] = str(tree / "debian-kernel")
    env["FROST_NET10G_MODULE"] = str(tree / "frost_net10g.ko")
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
    """FROST_LINUX_KERNEL and _INITRD replace Debian's Image and the initramfs.

    Substitutes with the default inputs' bytes pack every output exactly as the
    defaults do. Other files are packed in their place, the DTB placed by the
    substituted Image's header, with the default bootargs. Needs make, dtc and
    the riscv-none-elf- toolchain (all in the Docker image).
    """
    packer = _load_module(SBI_PACKER)
    helper = _load_module(DEBIAN_KERNEL)
    app = _linux_boot_tree(tmp_path)
    result = _make_linux_boot(app)
    assert result.returncode == 0, result.stderr
    defaults = _output_digests(app)
    copies = tmp_path / "copies"
    copies.mkdir()
    debian_image = helper.kernel_image(tmp_path / "debian-kernel")
    (copies / "Image").write_bytes(debian_image.read_bytes())
    # The composed initramfs make just wrote; the next make clean removes it.
    (copies / "rootfs.cpio").write_bytes((app / "rootfs.cpio").read_bytes())
    result = _make_linux_boot(
        app,
        FROST_LINUX_KERNEL=str(copies / "Image"),
        FROST_LINUX_INITRD=str(copies / "rootfs.cpio"),
    )
    assert result.returncode == 0, result.stderr
    assert _output_digests(app) == defaults

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
    """Buildroot's kernel mini-config uses syntax olddefconfig understands.

    It also keeps its load-bearing symbols, networking, the NFS root, systemd's
    requirements and the NIC driver among them, keeps IPv6 off, and leaves out
    the M-mode build's. Nothing boots this kernel any more -- FROST boots
    Debian's (linux/debian_kernel.py) -- so this guards the retained
    configuration rather than the booted one; it goes when the file does.
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


# --- Debian's kernel ------------------------------------------------------------


def test_debian_kernel_pin_is_self_consistent() -> None:
    """Every pinned package names one snapshot, version, size and sha256.

    The pin is the only place the kernel is named, so a hand edit that leaves a
    filename and a release disagreeing has to fail here rather than at a
    download that returns the wrong kernel.
    """
    helper = _load_module(DEBIAN_KERNEL)
    assert helper.KERNEL_RELEASE.startswith(helper.KERNEL_ABI + "-")
    # The banner ends at the release: the kernel prints "Linux version <release>
    # (<builder>) ...", and without the trailing space the marker would also
    # match a release this one is only a prefix of.
    assert helper.KERNEL_BANNER == f"Linux version {helper.KERNEL_RELEASE} "
    assert not f"Linux version {helper.KERNEL_RELEASE}-debug (x)".startswith(
        helper.KERNEL_BANNER
    )
    assert f"Linux version {helper.KERNEL_RELEASE} (deb)".startswith(
        helper.KERNEL_BANNER
    )
    assert helper.SOURCE_VERSION.split("-")[0] == helper.KERNEL_ABI.split("+")[0]
    assert re.fullmatch(r"\d{8}T\d{6}Z", helper.SNAPSHOT)
    names = set()
    for package in helper.PACKAGES:
        assert re.fullmatch(r"[0-9a-f]{64}", package.sha256), package.name
        assert package.size > 0
        assert package.members
        assert package.filename.endswith(f"_{helper.SOURCE_VERSION}_{package.arch}.deb")
        assert package.url.startswith(helper.SNAPSHOT_BASE + "/")
        assert helper.SNAPSHOT in package.url
        names.add(package.name)
    assert helper.KERNEL_PACKAGE.name == f"linux-image-{helper.KERNEL_RELEASE}"
    assert f"linux-headers-{helper.KERNEL_RELEASE}" in names
    assert f"linux-headers-{helper.KERNEL_ABI}-common" in names
    # linux-kbuild is Multi-Arch: foreign, so the host build of it drives the
    # riscv64 headers tree; every other package is riscv64 or architecture-less.
    kbuild = next(p for p in helper.PACKAGES if p.name.startswith("linux-kbuild"))
    assert kbuild.arch == "amd64"
    assert {p.arch for p in helper.PACKAGES} == {"riscv64", "all", "amd64"}


def test_debian_kernel_paths_need_no_network() -> None:
    """The path queries are pure: no download, and they honor the cache override.

    Every published directory is named after a digest of its inputs, so a
    changed pin or extraction revision names a new one instead of rewriting the
    one a concurrent reader is using.
    """
    helper = _load_module(DEBIAN_KERNEL)
    cache = Path("/tmp/frost-debian-cache")
    assert helper.cache_dir(cache) == cache
    key = helper.pin_digest()
    assert re.fullmatch(r"[0-9a-f]{16}", key)
    assert helper.sysroot(cache) == cache / f"sysroot-{key}"
    assert helper.kernel_image(cache) == (
        helper.sysroot(cache) / "boot" / f"vmlinux-{helper.KERNEL_RELEASE}"
    )
    assert helper.kernel_build_dir(cache) == (
        helper.sysroot(cache) / "usr" / "src" / f"linux-headers-{helper.KERNEL_RELEASE}"
    )
    assert helper.symvers(cache) == helper.kernel_build_dir(cache) / "Module.symvers"


def test_debian_kernel_entries_are_keyed_on_their_inputs(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A changed pin, extraction revision or toolchain names a new directory.

    kbuild records the compiler by Debian's riscv64-linux-gnu-gcc name and the
    headers by path, so nothing inside a build directory changes when the
    toolchain behind that name does; keying the directory is what keeps stale
    objects out.
    """
    helper = _load_module(DEBIAN_KERNEL)
    cache = Path("/tmp/frost-debian-cache")
    monkeypatch.setattr(
        helper, "toolchain_identity", lambda cross=None: (Path("gcc"), "A")
    )
    first_sysroot, first_module = helper.sysroot(cache), helper.module_dir(cache)
    monkeypatch.setattr(
        helper, "toolchain_identity", lambda cross=None: (Path("gcc"), "B")
    )
    assert helper.sysroot(cache) == first_sysroot  # the pin did not change
    assert helper.module_dir(cache) != first_module  # the toolchain did
    monkeypatch.setattr(helper, "EXTRACT_VERSION", helper.EXTRACT_VERSION + 1)
    assert helper.sysroot(cache) != first_sysroot
    assert helper.module_dir(cache) != first_module


# --- a cold cache, offline ------------------------------------------------------
# The packages are rebuilt here rather than downloaded: verifying the CLI's
# contract on a cold cache is the point (a warm one hides it), and the real .debs
# are 128 MB and need the network.


def _ar_archive(members: list[tuple[str, bytes]]) -> bytes:
    """Return an ar archive of (name, bytes), the container format of a .deb."""
    out = b"!<arch>\n"
    for name, data in members:
        header = (
            f"{name:<16}{0:<12}{0:<6}{0:<6}{0o100644:<8o}{len(data):<10}".encode()
            + b"`\n"
        )
        assert len(header) == 60, len(header)
        out += header + data + (b"\n" if len(data) % 2 else b"")
    return out


def _data_tar(entries: list[tuple[str, str, bytes]]) -> bytes:
    """Return a data.tar.xz of (kind, name, payload); kinds: dir, file, link."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:xz") as tar:
        for kind, name, payload in entries:
            info = tarfile.TarInfo("./" + name)  # Debian's own spelling
            if kind == "dir":
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tar.addfile(info)
            elif kind == "link":
                info.type = tarfile.SYMTYPE
                info.linkname = payload.decode()
                tar.addfile(info)
            else:
                info.size = len(payload)
                info.mode = 0o755 if name.endswith(("fixdep", "modpost")) else 0o644
                tar.addfile(info, io.BytesIO(payload))
    return buffer.getvalue()


def _synthetic_packages(helper: ModuleType) -> dict[str, bytes]:
    """Return one synthetic .deb per pinned package, keyed by file name.

    Each carries exactly the members the extraction selects, including the two
    the fixups rewrite and check, so a cold run exercises them for real.
    """
    release, abi = helper.KERNEL_RELEASE, helper.KERNEL_ABI
    headers = f"usr/src/linux-headers-{release}"
    common = f"usr/src/linux-headers-{abi}-common"
    kbuild = f"usr/lib/linux-kbuild-{abi}"
    contents: dict[str, list[tuple[str, str, bytes]]] = {
        f"linux-image-{release}": [
            ("dir", "boot", b""),
            ("file", f"boot/vmlinux-{release}", b"Image" * 100),
            ("file", f"boot/config-{release}", b"CONFIG_MODVERSIONS=y\n"),
            # Skipped by the member filter: the modules FROST never loads.
            ("file", f"usr/lib/modules/{release}/kernel/drivers/x.ko", b"x" * 1000),
        ],
        f"linux-headers-{abi}-common": [
            ("dir", common, b""),
            ("file", f"{common}/Makefile", b"VERSION = 6\n"),
            ("dir", f"{common}/include", b""),
            ("file", f"{common}/include/linux/kernel.h", b"/* h */\n"),
        ],
        f"linux-headers-{release}": [
            ("dir", headers, b""),
            (
                "file",
                f"{headers}/Makefile",
                f"include /usr/src/linux-headers-{abi}-common/Makefile\n".encode(),
            ),
            (
                "file",
                f"{headers}/.kernelvariables",
                f"override ARCH = riscv\noverride CROSS_COMPILE = "
                f"{helper.DEBIAN_CROSS_COMPILE}\n".encode(),
            ),
            ("file", f"{headers}/.config", b"CONFIG_MODVERSIONS=y\n"),
            ("file", f"{headers}/Module.symvers", b"0x12345678\tfoo\tvmlinux\n"),
            ("dir", f"{headers}/arch", b""),
            ("file", f"{headers}/arch/riscv/Makefile", b"# arch\n"),
            ("dir", f"{headers}/include", b""),
            ("file", f"{headers}/include/generated/autoconf.h", b"/* c */\n"),
            (
                "link",
                f"{headers}/scripts",
                f"../../lib/linux-kbuild-{abi}/scripts".encode(),
            ),
            (
                "link",
                f"{headers}/tools",
                f"../../lib/linux-kbuild-{abi}/tools".encode(),
            ),
            # Deliberately not selected: the BTF base, whose absence makes
            # kbuild skip module BTF instead of demanding pahole.
            ("file", f"{headers}/vmlinux", b"btf-base"),
        ],
        f"linux-kbuild-{abi}": [
            ("dir", kbuild, b""),
            ("file", f"{kbuild}/scripts/basic/fixdep", b"\x7fELF-fixdep"),
            ("file", f"{kbuild}/scripts/mod/modpost", b"\x7fELF-modpost"),
        ],
    }
    debs = {}
    for package in helper.PACKAGES:
        debs[package.filename] = _ar_archive(
            [
                ("debian-binary", b"2.0\n"),
                ("control.tar.xz", _data_tar([("file", "control", b"Package: x\n")])),
                ("data.tar.xz", _data_tar(contents[package.name])),
            ]
        )
    return debs


def _offline_download(helper: ModuleType, monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """Serve the synthetic packages in place of the network; return a fetch log."""
    debs = _synthetic_packages(helper)
    fetched: list[str] = []

    def download(package: Any, dl_dir: Path) -> Path:
        dl_dir.mkdir(parents=True, exist_ok=True)
        path = dl_dir / package.filename
        if not path.exists():
            fetched.append(package.filename)
            path.write_bytes(debs[package.filename])
        return path

    monkeypatch.setattr(helper, "download", download)
    return fetched


def test_debian_kernel_cli_prints_only_the_path_on_a_cold_cache(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Stdout is the answer; the work it had to do first goes to stderr.

    Buildroot's post-image hook captures `image` in a shell substitution, so a
    progress line on stdout would make the captured value a multiline blob and
    the next command fail. A warm cache hides that, which is why this runs cold.
    """
    helper = _load_module(DEBIAN_KERNEL)
    fetched = _offline_download(helper, monkeypatch)
    cache = tmp_path / "cache"
    assert helper.main(["--cache", str(cache), "image"]) == 0
    captured = capsys.readouterr()
    assert captured.out == f"{helper.kernel_image(cache)}\n"
    assert Path(captured.out.strip()).is_file()
    assert len(fetched) == len(helper.PACKAGES)  # it really was cold
    assert "extracted into" in captured.err  # the progress went the other way

    # Warm: same single line, no work, and no re-download.
    assert helper.main(["--cache", str(cache), "image"]) == 0
    warm = capsys.readouterr()
    assert warm.out == f"{helper.kernel_image(cache)}\n"
    assert warm.err == ""
    assert len(fetched) == len(helper.PACKAGES)

    for command in (["fetch"], ["release"], ["image", "--no-fetch"]):
        assert helper.main(["--cache", str(cache), *command]) == 0
        assert len(capsys.readouterr().out.splitlines()) == 1, command


def test_debian_kernel_cold_extraction_selects_and_fixes_the_tree(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The extraction keeps what the module build needs and drops the rest.

    The arch Makefile's absolute include is rewritten relative to itself, so the
    tree builds outside /usr/src, and the BTF-base vmlinux is left out so kbuild
    skips module BTF rather than demanding pahole.
    """
    helper = _load_module(DEBIAN_KERNEL)
    _offline_download(helper, monkeypatch)
    cache = tmp_path / "cache"
    root = helper.fetch(cache)
    assert root == helper.sysroot(cache)
    for path in helper.required_files(root).values():
        assert path.is_file(), path
    build = helper.kernel_build_dir(cache)
    assert not (build / "vmlinux").exists()
    assert not (root / "usr" / "lib" / "modules").exists()
    makefile = (build / "Makefile").read_text()
    assert "/usr/src/" not in makefile
    assert "$(dir $(lastword $(MAKEFILE_LIST)))" in makefile
    # The relative include resolves, and the kbuild symlinks resolve inside.
    assert (build / makefile.split("include ", 1)[1].strip().split(")))")[1]).exists()
    assert (build / "scripts" / "basic" / "fixdep").exists()


def test_debian_kernel_rejects_packaging_that_moved(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A changed include line or cross prefix fails loudly, not silently."""
    helper = _load_module(DEBIAN_KERNEL)
    _offline_download(helper, monkeypatch)
    root = tmp_path / "root"
    headers = root / "usr" / "src" / f"linux-headers-{helper.KERNEL_RELEASE}"
    headers.mkdir(parents=True)
    (headers / "Makefile").write_text("include /somewhere/else/Makefile\n")
    (headers / ".kernelvariables").write_text(
        "override CROSS_COMPILE = riscv64-linux-\n"
    )
    with pytest.raises(RuntimeError, match="expected an include"):
        helper.fix_headers_tree(root)
    (headers / "Makefile").write_text(
        f"include /usr/src/linux-headers-{helper.KERNEL_ABI}-common/Makefile\n"
    )
    with pytest.raises(RuntimeError, match="DEBIAN_CROSS_COMPILE"):
        helper.fix_headers_tree(root)


def test_debian_kernel_revalidates_a_damaged_entry(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A truncated or partly deleted extraction is replaced, not trusted.

    The published directory is the only record that the work finished, and it is
    validated against the manifest written with it, so an interrupted run or a
    stray delete cannot be mistaken for a complete tree.
    """
    helper = _load_module(DEBIAN_KERNEL)
    fetched = _offline_download(helper, monkeypatch)
    cache = tmp_path / "cache"
    root = helper.fetch(cache)
    assert helper.manifest_holds(root)
    downloads = len(fetched)

    image = helper.kernel_image(cache)
    image.write_bytes(image.read_bytes()[:-1])  # truncated
    assert not helper.manifest_holds(root)
    assert helper.fetch(cache) == root
    assert helper.manifest_holds(root)
    assert len(fetched) == downloads  # the verified .debs were reused

    (root / helper.MANIFEST_NAME).unlink()  # an interrupted publish
    assert not helper.manifest_holds(root)
    helper.fetch(cache)
    assert helper.manifest_holds(root)

    image.unlink()
    assert not helper.manifest_holds(root)
    helper.fetch(cache)
    assert helper.kernel_image(cache).is_file()


def test_debian_kernel_publishes_whole_entries(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A reader sees a complete entry or none: staging is private and renamed.

    A failure part-way leaves nothing published, and nothing under staging.
    """
    helper = _load_module(DEBIAN_KERNEL)
    _offline_download(helper, monkeypatch)
    cache = tmp_path / "cache"

    def boom(root: Path) -> None:
        raise RuntimeError("extraction interrupted")

    monkeypatch.setattr(helper, "fix_headers_tree", boom)
    with pytest.raises(RuntimeError, match="interrupted"):
        helper.fetch(cache)
    assert not helper.sysroot(cache).exists()
    assert list((cache / "staging").iterdir()) == []
    # No stray partial downloads either.
    assert [p.name for p in (cache / "dl").iterdir() if p.name.startswith(".")] == []


def test_debian_kernel_download_rejects_a_wrong_payload(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A truncated or substituted download is refused and leaves nothing behind."""
    helper = _load_module(DEBIAN_KERNEL)
    package = helper.KERNEL_PACKAGE
    dl_dir = tmp_path / "dl"

    class Response(io.BytesIO):
        def __enter__(self) -> "Response":
            return self

        def __exit__(self, *_: object) -> None:
            return None

    monkeypatch.setattr(
        helper.urllib.request, "urlopen", lambda url, timeout=0: Response(b"not it")
    )
    with pytest.raises(RuntimeError, match="expected 112012420 bytes"):
        helper.download(package, dl_dir)
    assert list(dl_dir.iterdir()) == []


def test_debian_kernel_verifies_the_module_it_builds(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """A module is published only if its metadata and symbol CRCs are the pin's.

    With CONFIG_MODVERSIONS the kernel ignores vermagic's release field, so the
    release is checked here; the CRCs then tie the module to the pinned tree's
    exported symbols, which a build against other headers would not match.
    """
    helper = _load_module(DEBIAN_KERNEL)
    release = helper.KERNEL_RELEASE
    good_magic = f"{release} SMP mod_unload modversions riscv"
    symvers = tmp_path / "Module.symvers"
    symvers.write_text("0x0800473f\t__cond_resched\tvmlinux\tEXPORT_SYMBOL\t\n")
    monkeypatch.setattr(helper, "symvers", lambda cache=None: symvers)
    assert helper.kernel_symbol_crcs(symvers) == {"__cond_resched": 0x0800473F}

    def stub(magic: str, crcs: dict[str, int], name: str = "frost_net10g") -> None:
        monkeypatch.setattr(
            helper,
            "module_info",
            lambda module, objcopy: {"name": [name], "vermagic": [magic]},
        )
        monkeypatch.setattr(helper, "module_symbol_crcs", lambda module, objcopy: crcs)

    module = tmp_path / "frost_net10g.ko"
    module.write_bytes(b"ko")
    stub(good_magic, {"__cond_resched": 0x0800473F})
    helper.verify_module(module, None, "objcopy")  # the pinned kernel's module

    # A release this one is a prefix of must not pass.
    stub(f"{release}-debug SMP mod_unload modversions riscv", {})
    with pytest.raises(RuntimeError, match="is not .*'s"):
        helper.verify_module(module, None, "objcopy")
    stub("6.18.7 SMP mod_unload modversions riscv", {})
    with pytest.raises(RuntimeError, match="is not"):
        helper.verify_module(module, None, "objcopy")
    stub(f"{release} SMP mod_unload riscv", {})  # no modversions
    with pytest.raises(RuntimeError, match="modversions"):
        helper.verify_module(module, None, "objcopy")
    stub(good_magic, {"__cond_resched": 0xDEADBEEF})  # another kernel's CRC
    with pytest.raises(RuntimeError, match="symbol CRCs do not match"):
        helper.verify_module(module, None, "objcopy")
    stub(good_magic, {"not_exported": 0x1})  # a symbol the pin does not export
    with pytest.raises(RuntimeError, match="symbol CRCs do not match"):
        helper.verify_module(module, None, "objcopy")
    stub(good_magic, {"__cond_resched": 0x0800473F}, name="something_else")
    with pytest.raises(RuntimeError, match="modinfo name"):
        helper.verify_module(module, None, "objcopy")


def _parse_versions(
    helper: ModuleType, monkeypatch: pytest.MonkeyPatch, blob: bytes
) -> dict[str, int]:
    """Run module_symbol_crcs over a given __versions section."""
    monkeypatch.setattr(helper, "elf_section", lambda module, section, objcopy: blob)
    return dict(helper.module_symbol_crcs(Path("x.ko"), "objcopy"))


@pytest.mark.parametrize("blob", [b"", b"\x00" * 65], ids=["empty", "truncated"])
def test_debian_kernel_module_versions_section_must_parse(
    blob: bytes, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A module with no symbol CRCs, or a truncated section, is refused."""
    helper = _load_module(DEBIAN_KERNEL)
    with pytest.raises(RuntimeError, match="__versions"):
        _parse_versions(helper, monkeypatch, blob)


def test_debian_kernel_module_versions_entries_decode(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A well-formed __versions section decodes to name/CRC pairs.

    The layout is struct modversion_info: an unsigned long CRC then a 56-byte
    name, which is what the pinned kernel's modpost emits.
    """
    helper = _load_module(DEBIAN_KERNEL)
    names = ("__platform_driver_register", "memcpy")
    blob = b"".join(
        struct.pack("<Q", crc) + name.encode().ljust(56, b"\0")
        for crc, name in zip((0xF5150B14, 0x69ACDF38), names)
    )
    assert _parse_versions(helper, monkeypatch, blob) == {
        "__platform_driver_register": 0xF5150B14,
        "memcpy": 0x69ACDF38,
    }
    assert helper.MODVERSION_ENTRY == 64


def _newc_archive(entries: list[tuple[str, int, bytes]]) -> bytes:
    """Return a real newc cpio archive, padded to 512 as GNU cpio writes one."""
    helper = _load_module(DEBIAN_KERNEL)
    out = b""
    for index, (name, mode, data) in enumerate(entries, start=1):
        out += helper.cpio_entry(name, mode, data, ino=index)
    out += helper.cpio_entry(helper.CPIO_TRAILER, 0)
    return out + b"\0" * (-len(out) % helper.CPIO_BLOCK)


# A base archive shaped like Buildroot's: the programs the gates type, one of
# which the initramfs check looks inside.
BASE_ENTRIES = [
    ("etc", 0o040755, b""),
    ("etc/init.d", 0o040755, b""),
    ("etc/init.d/rcS", 0o100755, b"#!/bin/sh\nfor i in /etc/init.d/S??*; do\n"),
    ("usr", 0o040755, b""),
    ("usr/bin", 0o040755, b""),
    (
        "usr/bin/frost_stress",
        0o100755,
        b"ELF...FROST_COUNTERS...FROST_USERSPACE_STRESS",
    ),
]


def test_debian_kernel_initramfs_appends_a_second_real_archive(
    tmp_path: Path,
) -> None:
    """The composed initramfs is two real cpio archives, base first, unmodified.

    The kernel unpacks concatenated archives in order, which is how the module
    reaches Buildroot's userspace without rebuilding it; the base must come
    through byte for byte, and both archives' members must still parse.
    """
    helper = _load_module(DEBIAN_KERNEL)
    base_bytes = _newc_archive(BASE_ENTRIES)
    base = tmp_path / "rootfs.cpio"
    base.write_bytes(base_bytes)
    module = tmp_path / "frost_net10g.ko"
    module.write_bytes(bytes(range(211)) * 3)
    out = helper.compose_initramfs(base, tmp_path / "composed.cpio", module=module)
    composed = out.read_bytes()
    assert composed.startswith(base_bytes)
    assert len(composed) % helper.CPIO_ALIGN == 0

    members = dict(
        (name, (mode, data)) for name, mode, data in helper.cpio_members(composed)
    )
    # Both archives' members are visible, in one walk.
    for name, mode, data in BASE_ENTRIES:
        assert members[name] == (mode, data)
    release = helper.KERNEL_RELEASE
    assert members[f"lib/modules/{release}/frost_net10g.ko"] == (
        0o100644,
        module.read_bytes(),
    )
    assert members[f"lib/modules/{release}/modules.dep"][1] == b"frost_net10g.ko:\n"
    mode, script = members[helper.MODULE_INIT_SCRIPT]
    assert mode == 0o100755, "rcS runs /etc/init.d/S??* as programs"
    for directory in ("lib", "lib/modules", f"lib/modules/{release}"):
        assert members[directory][0] == 0o040755, directory


def test_debian_kernel_loader_script_checks_the_running_release(
    tmp_path: Path,
) -> None:
    """The script compares uname -r before it loads, and says so when it differs.

    CONFIG_MODVERSIONS makes the kernel skip vermagic's release field once a
    module carries symbol CRCs, so a successful insmod does not identify the
    kernel; this test is what keeps the release check in the script.
    """
    helper = _load_module(DEBIAN_KERNEL)
    members = dict(
        (name, data) for name, _, data in helper.cpio_members(helper.module_cpio(b"ko"))
    )
    script = members[helper.MODULE_INIT_SCRIPT].decode()
    assert script.startswith("#!/bin/sh\n")
    assert "$(uname -r)" in script
    assert f"EXPECT={helper.KERNEL_RELEASE}" in script
    assert '"$RUNNING" != "$EXPECT"' in script
    assert f'echo "{helper.MODULE_PASS_TOKEN} $RUNNING"' in script
    assert helper.MODULE_FAIL_TOKEN in script
    assert helper.MODULE_PASS_LINE == (
        f"{helper.MODULE_PASS_TOKEN} {helper.KERNEL_RELEASE}"
    )
    # It is a shell script the target's /bin/sh will run, and it never fails rcS.
    path = tmp_path / "S03frost-net10g"
    path.write_text(script)
    subprocess.run(["sh", "-n", str(path)], check=True)

    # Run it with a stub uname on PATH: a mismatch prints the fail token and the
    # release it saw, and never reaches insmod.
    stubs = tmp_path / "bin"
    stubs.mkdir()
    (stubs / "uname").write_text("#!/bin/sh\necho 6.12.107+deb13-riscv64-debug\n")
    (stubs / "insmod").write_text("#!/bin/sh\necho INSMOD-RAN\n")
    for stub in stubs.iterdir():
        stub.chmod(0o755)
    path.chmod(0o755)
    done = subprocess.run(
        ["sh", str(path), "start"],
        capture_output=True,
        text=True,
        env={"PATH": f"{stubs}:/usr/bin:/bin"},
        check=True,
    )
    assert helper.MODULE_FAIL_TOKEN in done.stdout
    assert "6.12.107+deb13-riscv64-debug" in done.stdout
    assert "INSMOD-RAN" not in done.stdout
    assert helper.MODULE_PASS_TOKEN not in done.stdout


def test_debian_kernel_initramfs_rejects_an_unaligned_base(tmp_path: Path) -> None:
    """A base whose length is not a multiple of four breaks the kernel's padding.

    init/initramfs.c's do_reset walks the NULs between two archives and then
    requires the remainder to be four-byte aligned -- four, not the 512 GNU cpio
    happens to pad a whole archive to.
    """
    helper = _load_module(DEBIAN_KERNEL)
    assert helper.CPIO_ALIGN == 4
    module = tmp_path / "frost_net10g.ko"
    module.write_bytes(b"ko")
    base = tmp_path / "rootfs.cpio"

    # A complete archive with no block padding: every newc member is already
    # four-byte aligned, so this is acceptable even though 512 does not divide
    # it. Requiring 512 would have refused an archive the kernel accepts.
    unpadded = _newc_archive(BASE_ENTRIES).rstrip(b"\0")
    unpadded += b"\0" * (-len(unpadded) % helper.CPIO_ALIGN)
    assert len(unpadded) % helper.CPIO_ALIGN == 0
    assert len(unpadded) % helper.CPIO_BLOCK != 0
    base.write_bytes(unpadded)
    composed = helper.compose_initramfs(base, tmp_path / "ok.cpio", module=module)
    assert composed.read_bytes().startswith(unpadded)

    # One byte more is not aligned, and the kernel's unpacker would reject it.
    base.write_bytes(unpadded + b"\0")
    with pytest.raises(RuntimeError, match="multiple of 4"):
        helper.compose_initramfs(base, tmp_path / "no.cpio", module=module)


def test_default_bootargs_disable_ipv6() -> None:
    """Debian's kernel builds IPv6 in; its frames would fail frost_nettest's idle."""
    packer = _load_module(SBI_PACKER)
    assert "ipv6.disable=1" in packer.DEFAULT_BOOTARGS
    assert "rdinit=/sbin/init" in packer.DEFAULT_BOOTARGS


def test_post_image_packs_debian_kernel_and_the_composed_initramfs() -> None:
    """Buildroot's post-image hook packs Debian's Image, not the one it built."""
    text = POST_IMAGE.read_text()
    assert "debian_kernel.py" in text
    assert '--payload "${BINARIES_DIR}/Image-debian"' in text
    assert '--initrd "${BINARIES_DIR}/rootfs-frost.cpio"' in text
    assert '--payload "${BINARIES_DIR}/Image"' not in text


def test_qemu_ci_job_boots_the_packed_debian_pair() -> None:
    """CI's QEMU job boots the post-image hook's own files with its bootargs.

    The -append string has to stay the packer's DEFAULT_BOOTARGS, or the job
    stops testing the boot the board gets.
    """
    packer = _load_module(SBI_PACKER)
    helper = _load_module(DEBIAN_KERNEL)
    text = CI_WORKFLOW.read_text()
    assert "-kernel /img/Image-debian" in text
    assert "-initrd /img/rootfs-frost.cpio" in text
    assert f'-append "{packer.DEFAULT_BOOTARGS}"' in text
    assert f'grep -q "{helper.MODULE_PASS_TOKEN}"' in text
    assert "images/Image-debian" in text and "images/rootfs-frost.cpio" in text
    # The Debian packages are cached like Buildroot's downloads.
    assert "linux/debian-kernel/dl" in text


def test_debian_kernel_refuses_a_base_that_cannot_drive_the_gates(
    tmp_path: Path,
) -> None:
    """A base archive whose frost_stress predates the counter mode is refused.

    Buildroot does not notice an edited package source, so an archive built
    before ``--counters`` existed would pack happily, boot happily, and leave the
    hardware regression waiting out its whole deadline for a line the program
    cannot print. The refusal names the rebuild.
    """
    helper = _load_module(DEBIAN_KERNEL)
    module = tmp_path / "frost_net10g.ko"
    module.write_bytes(b"ko")
    base = tmp_path / "rootfs.cpio"

    stale = [
        (
            name,
            mode,
            b"ELF...FROST_USERSPACE_STRESS" if "frost_stress" in name else data,
        )
        for name, mode, data in BASE_ENTRIES
    ]
    base.write_bytes(_newc_archive(stale))
    with pytest.raises(RuntimeError, match="predates FROST_COUNTERS"):
        helper.compose_initramfs(base, tmp_path / "out.cpio", module=module)
    try:
        helper.compose_initramfs(base, tmp_path / "out.cpio", module=module)
    except RuntimeError as refused:
        assert "frost-stress-rebuild" in str(refused)

    without = [entry for entry in BASE_ENTRIES if "frost_stress" not in entry[0]]
    base.write_bytes(_newc_archive(without))
    with pytest.raises(RuntimeError, match="holds no /usr/bin/frost_stress"):
        helper.compose_initramfs(base, tmp_path / "out.cpio", module=module)

    # The current archive passes, and nothing was written for the refusals.
    base.write_bytes(_newc_archive(BASE_ENTRIES))
    assert helper.compose_initramfs(base, tmp_path / "out.cpio", module=module).exists()


def test_counter_token_matches_the_program_that_prints_it() -> None:
    """The token the initramfs check looks for is the one frost_stress prints."""
    helper = _load_module(DEBIAN_KERNEL)
    source = (
        REPO_ROOT
        / "linux"
        / "buildroot-external"
        / "package"
        / "frost-stress"
        / "src"
        / "frost_stress.c"
    ).read_text()
    assert f'printf("{helper.INITRAMFS_COUNTER_TOKEN}:' in source
    assert helper.INITRAMFS_COUNTER_PROGRAM.endswith("frost_stress")
    # The mode the stage types, and the scope it requires, are implemented.
    assert '"--counters"' in source
    assert 'scope = "exec-child"' in source
    assert "enable_on_exec = 1" in source
    assert "attr.inherit = 1" in source


def test_linux_boot_make_rebuilds_a_stale_test_userspace() -> None:
    """The Makefile names the userspace sources, so an edit rebuilds the archive.

    Buildroot has no idea a package source changed; without this the cached
    rootfs.cpio keeps the old programs and a healthy boot fails the stage.
    """
    text = LINUX_BOOT_MAKEFILE.read_text()
    assert "FROST_STRESS_SRC := $(wildcard" in text
    assert "package/frost-stress/src/*.c" in text
    assert "$(BR2_INITRD) $(FW_JUMP) &: $(FROST_STRESS_SRC)" in text
    assert "frost-stress-rebuild" in text
    # The cold path runs the defconfig; a warm one must not, or it would discard
    # what the build directory already carries (CI appends to that config).
    assert 'if [ ! -f "$(BR2_OUT)/.config" ]' in text
    # A build directory configured for another view of the checkout is reported,
    # not reconfigured: its .config stores that path.
    assert 'elif [ "$(BR2_RECORDED)" != "$(BR2_EXTERNAL)" ]' in text
    assert "BR2_EXTERNAL_FROST_PATH" in text


def test_linux_boot_make_passes_br2_external_to_every_buildroot_call() -> None:
    """Buildroot regenerates its record of BR2_EXTERNAL from this variable.

    Omitting it on one invocation leaves the build directory with no external
    tree at all, which breaks every later call until it is reconfigured.
    """
    text = LINUX_BOOT_MAKEFILE.read_text()
    calls = [line for line in text.splitlines() if '$(MAKE) -C "$(BR2_SRC)"' in line]
    assert len(calls) == 3, calls  # defconfig, frost-stress-rebuild, the build
    for call in calls:
        assert 'BR2_EXTERNAL="$(BR2_EXTERNAL)"' in call, call
