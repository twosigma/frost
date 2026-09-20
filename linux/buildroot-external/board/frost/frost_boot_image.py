#!/usr/bin/env python3

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

"""Pack a FROST boot image: OpenSBI, an S-mode payload, the DTB, an initramfs.

The pieces are placed in the cached-DDR image and the low-BRAM shim jumps to
the firmware.

Layout in cached DDR (offsets from 0x8000_0000; see linux/README.md):

  +0          OpenSBI fw_jump.bin (FW_TEXT_START), at most FW_MAX_BYTES
  +2 MiB      the S-mode payload: a Linux ``Image`` or a raw binary
              (2 MiB alignment is the rv64 kernel's PMD requirement)
  +D          the DTB, in a 64 KiB slot (OpenSBI grows it in place)
  +D+64K      the initramfs cpio, when given (bounds via linux,initrd-*)

  D = align_up(max(16 MiB, 2 MiB + footprint), 2 MiB)

The footprint is a Linux ``Image``'s header ``image_size`` (text plus bss), or
a raw payload's length. Linux (rv64, STRICT_KERNEL_RWX) reserves its image up
to the next 2 MiB boundary and drops an initramfs that overlaps a reservation,
so the DTB starts at or above that boundary and the initramfs follows the DTB
slot. The 16 MiB floor
(DTB_MIN_OFFSET) is for compatibility only: every payload of at most 14 MiB
packs exactly as it did when the DTB offset was fixed. The DTB slot, and the
initramfs when given, must end inside the memory node, whose size is
--mem-size (MEM_SIZE, 64 MiB, by default).

The boot shim in low BRAM sets a0 = hart id, a1 = the DTB address and jumps to
the firmware; fw_jump passes a1 through (it is built without an FDT offset).
main() plans one Layout, and every address in the outputs comes from it: the
shim's a1, the /chosen initramfs bounds and both DDR images.

Outputs (in --out):
  sw.{mem,txt}      the low-BRAM shim
  sw_ddr.{mem,txt}  the DDR image, sparse ``.mem`` (readmemh address
                    directives) and dense ``.txt`` (the JTAG loader's stream)
  frost.{dts,dtb}   the generated device tree

A Linux ``Image`` is recognized by its header magic and placed by the header's
``image_size`` rather than the file size. Every region is asserted to be
ordered and inside the memory node, and the DTB is given growth slack for
OpenSBI's reserved-memory and cpu fixups.

With --nfsroot the root is an NFS export: the bootargs (nfsroot_bootargs)
configure the interface from --ip (ip=, dhcp by default) and mount the export.
Without --initrd the kernel does both itself; with one, the initramfs does,
through initramfs-tools' NFS boot (boot=nfs), for a kernel with no NFS root of
its own, such as Debian's. --mac replaces the NIC's local-mac-address, which
boards sharing a network must not share.
"""

import argparse
import os
import re
import struct
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

DDR_BASE = 0x8000_0000
FW_OFFSET = 0x0
PAYLOAD_OFFSET = 0x20_0000
# The rv64 kernel's PMD: the Image loads on a PMD boundary, and Linux (with
# STRICT_KERNEL_RWX) reserves it up to the next boundary past its end.
PMD_BYTES = 0x20_0000
# The lowest DTB offset. A compatibility floor, not a Linux or OpenSBI
# requirement: it was the fixed DTB offset, so payloads that fit below it keep
# their DTB and initramfs addresses and pack bit-identically.
DTB_MIN_OFFSET = 0x100_0000
DTB_SLOT_BYTES = 0x1_0000
# The memory /memory advertises unless --mem-size names a board's: 64 MiB, the
# simulation DDR model's default size (tests/Makefile DDR_MODEL_BYTES).
MEM_SIZE = 0x400_0000
# The cached DDR region at DDR_BASE (hw/rtl/cpu_and_mem/cpu_and_mem.sv
# CACHED_SIZE_BYTES): the most memory the CPU, and so Linux, can reach.
CACHED_REGION_BYTES = 0x4000_0000

# fw_jump.bin is well under FW_MAX_BYTES; its runtime rw/heap/scratch regions
# follow the binary and OpenSBI reserves them below the payload (banner
# "Firmware Size").
FW_MAX_BYTES = 0x10_0000
# OpenSBI's fdt fixups each open the tree with +1 KiB of headroom; keep the
# slot roomy beyond that.
DTB_GROWTH_BYTES = 0x2000

LINUX_IMAGE_MAGIC = b"RISCV\x00\x00\x00"  # header offset 0x30
LINUX_IMAGE_SIZE_OFFSET = 0x10  # u64 image_size (text + bss)

# What the DT advertises: the ISA the core implements, in the spelling both
# OpenSBI and Linux parse. Keep it in sync with sw/common/arch.mk and
# hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv (misa), and linux/README.md.
ISA_BASE = "rv64i"
ISA_EXTENSIONS = (
    "i", "m", "a", "f", "d", "c",
    "zicsr", "zifencei", "zicntr",
    "zba", "zbb", "zbs", "zbkb", "zicond", "zihintpause",
    "sstc", "svade",
)  # fmt: skip
ISA_STRING = (
    "rv64imafdc_zicsr_zifencei_zicntr_zba_zbb_zbs_zbkb_zicond_zihintpause_sstc_svade"
)

# ipv6.disable=1 because Debian's kernel builds IPv6 in: the autoconfiguration
# frames it sends whenever an interface comes up return through the NIC's
# loopback and fail frost_nettest's idle checks, which require that no frame is
# counted while none is being sent. Nothing in the initramfs needs IPv6.
DEFAULT_BOOTARGS = "earlycon console=ttyS0 rdinit=/sbin/init ipv6.disable=1"
# The ip= for an NFS root when --ip is not given.
DEFAULT_NFSROOT_IP = "dhcp"
# The NFS root's mount options: NFSv3 over TCP, a hard mount. The kernel's NFS
# root and the klibc nfsmount that initramfs-tools' NFS boot runs both accept
# these names; klibc rejects many of nfs(5)'s (proto=, for one) and any version
# but 2 and 3.
NFSROOT_OPTIONS = "vers=3,tcp,hard"
DEFAULT_MODEL = "FROST RV64 (Sv39, OpenSBI)"
DEFAULT_CLK_HZ = 300_000_000  # X3
DEFAULT_SHIM_MARCH = "rv64i_zicsr"
DEFAULT_SHIM_MABI = "lp64"

UART_BASE = 0x4000_1000
CLINT_BASE = 0x4001_0000
CLINT_SIZE = 0xC000
PLIC_BASE = 0x4400_0000
PLIC_SIZE = 0x40_0000
PLIC_NDEV = 4  # 1 = ns16550, 2 = board pin, 3 = DMA test engine, 4 = NIC
# The DMA test engine's register window; no Linux driver binds to it, the
# node only records the device and its PLIC source.
DMA_ENGINE_BASE = 0x4002_0000
DMA_ENGINE_SIZE = 0x1000
DMA_ENGINE_PLIC_SOURCE = 3
# The NIC (hw/rtl/peripherals/nic): its register window closes the strongly
# ordered MMIO region (hw/rtl/cpu_and_mem/cpu_and_mem.sv MmioSizeBytes). The
# node follows the binding in linux/buildroot-external/board/frost/
# frost,net10g.yaml; the frost_net10g driver that binds it is
# linux/frost-net10g.
NIC_BASE = 0x4003_0000
NIC_SIZE = 0x1000
NIC_PLIC_SOURCE = 4
# The default local-mac-address, as DT bytes: locally administered; the driver
# honors it. --mac replaces it.
NIC_MAC_ADDRESS = "02 11 22 33 44 55"
UART_PLIC_SOURCE = 1


def to_words(data: bytes) -> list[str]:
    """Convert bytes to 8-hex-digit little-endian word values (xxd -e style)."""
    if len(data) % 4:
        data += b"\x00" * (4 - len(data) % 4)
    return [
        "{:08x}".format(struct.unpack_from("<I", data, i)[0])
        for i in range(0, len(data), 4)
    ]


def linux_image_size(payload: bytes) -> int | None:
    """Return a Linux Image's header image_size, or None for a raw payload."""
    if len(payload) >= 0x40 and payload[0x30:0x38] == LINUX_IMAGE_MAGIC:
        return struct.unpack_from("<Q", payload, LINUX_IMAGE_SIZE_OFFSET)[0]
    return None


class Layout(NamedTuple):
    """Where the DTB and the initramfs go, as offsets from DDR_BASE."""

    footprint: int  # the payload's size in memory (payload_footprint)
    dtb_offset: int
    initrd_offset: int


def payload_footprint(payload: bytes) -> int:
    """Return the payload's size in memory.

    A Linux Image occupies its header's image_size (text plus bss); a raw
    payload occupies its length.
    """
    image_size = linux_image_size(payload)
    if image_size is None:
        return len(payload)
    assert image_size >= len(
        payload
    ), "Linux Image header image_size below the file size"
    return image_size


def plan_layout(footprint: int) -> Layout:
    """Place the DTB and the initramfs above a payload of this footprint.

    The DTB takes the first PMD boundary at or above both the payload's end
    and DTB_MIN_OFFSET, and the initramfs follows the DTB slot. Linux (with
    STRICT_KERNEL_RWX) reserves its image up to the PMD boundary past its end
    and drops an initramfs that overlaps a reservation, so both regions start
    clear of that reservation.
    """
    lowest = max(DTB_MIN_OFFSET, PAYLOAD_OFFSET + footprint)
    dtb_offset = (lowest + PMD_BYTES - 1) // PMD_BYTES * PMD_BYTES
    return Layout(footprint, dtb_offset, dtb_offset + DTB_SLOT_BYTES)


def nfsroot_bootargs(
    export: str, ip: str | None = None, initramfs: bool = False
) -> str:
    """Return bootargs that mount an NFS export (<server-ip>:/<path>) as root.

    The interface is configured from ip= (dhcp unless given), the export is
    mounted read-write over NFSv3/TCP, and its /sbin/init runs. Without an
    initramfs the kernel does this itself (CONFIG_IP_PNP, CONFIG_ROOT_NFS). With
    one, boot=nfs selects initramfs-tools' NFS boot, whose klibc ipconfig reads
    ip= in the kernel's syntax and whose nfsmount takes the same options.
    """
    boot = "boot=nfs " if initramfs else ""
    return (
        f"earlycon console=ttyS0 {boot}root=/dev/nfs "
        f"nfsroot={export},{NFSROOT_OPTIONS} rw ip={ip or DEFAULT_NFSROOT_IP}"
    )


def mac_address(text: str) -> str:
    """Return a unicast MAC address, aa:bb:cc:dd:ee:ff, as DT bytes.

    The --mac argument type. A multicast or all-zero address is rejected like
    a malformed one: the driver would replace it with a random address.
    """
    octets = text.split(":")
    if len(octets) != 6 or not all(re.fullmatch(r"[0-9A-Fa-f]{2}", o) for o in octets):
        raise argparse.ArgumentTypeError(f"{text!r} is not aa:bb:cc:dd:ee:ff")
    if int(octets[0], 16) & 1:
        raise argparse.ArgumentTypeError(
            f"{text} is a multicast address (low bit of the first octet set)"
        )
    if not any(int(octet, 16) for octet in octets):
        raise argparse.ArgumentTypeError(f"{text} is the all-zero address")
    return " ".join(octets).lower()


def memory_size(text: str) -> int:
    """Return a memory size in bytes: a multiple of 2 MiB within the cached region.

    The --mem-size argument type. check_layout then requires the packed
    regions to fit inside it.
    """
    try:
        size = int(text, 0)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{text!r} is not a byte count") from None
    if size <= 0 or size % PMD_BYTES or size > CACHED_REGION_BYTES:
        raise argparse.ArgumentTypeError(
            f"{text} is not a multiple of 2 MiB between 2 MiB and the "
            f"0x{CACHED_REGION_BYTES:x}-byte cached region"
        )
    return size


def gen_dts(
    *,
    clk_hz: int,
    initrd_range: tuple[int, int] | None,
    bootargs: str,
    model: str,
    mac: str = NIC_MAC_ADDRESS,
    mem_size: int = MEM_SIZE,
) -> str:
    """Return the FROST device tree source for the OpenSBI + Sv39 boot.

    mac is the NIC's local-mac-address as DT bytes ("02 11 22 33 44 55");
    mem_size is the size of the memory node at DDR_BASE.
    """
    ext_list = ",\n\t\t\t\t".join(
        ", ".join(f'"{e}"' for e in ISA_EXTENSIONS[i : i + 6])
        for i in range(0, len(ISA_EXTENSIONS), 6)
    )
    chosen = [f'\t\tstdout-path = "/soc/serial@{UART_BASE:x}";']
    if bootargs:
        chosen.append(f'\t\tbootargs = "{bootargs}";')
    if initrd_range is not None:
        start, end = initrd_range
        chosen.append(f"\t\tlinux,initrd-start = <0x{start:08x}>;")
        chosen.append(f"\t\tlinux,initrd-end = <0x{end:08x}>;")
    chosen_body = "\n".join(chosen)
    return f"""/dts-v1/;

/ {{
\t#address-cells = <0x01>;
\t#size-cells = <0x01>;
\tcompatible = "frost,rv64", "frost";
\tmodel = "{model}";

\tchosen {{
{chosen_body}
\t}};

\tcpus {{
\t\t#address-cells = <0x01>;
\t\t#size-cells = <0x00>;
\t\ttimebase-frequency = <{clk_hz}>;

\t\tcpu@0 {{
\t\t\tdevice_type = "cpu";
\t\t\treg = <0x00>;
\t\t\tstatus = "okay";
\t\t\tcompatible = "riscv";
\t\t\tmmu-type = "riscv,sv39";
\t\t\triscv,isa-base = "{ISA_BASE}";
\t\t\triscv,isa = "{ISA_STRING}";
\t\t\triscv,isa-extensions = {ext_list};

\t\t\tcpu0_intc: interrupt-controller {{
\t\t\t\t#interrupt-cells = <0x01>;
\t\t\t\tinterrupt-controller;
\t\t\t\tcompatible = "riscv,cpu-intc";
\t\t\t\tphandle = <0x01>;
\t\t\t}};
\t\t}};
\t}};

\tmemory@{DDR_BASE:x} {{
\t\tdevice_type = "memory";
\t\treg = <0x{DDR_BASE:08x} 0x{mem_size:08x}>;
\t}};

\tpmu {{
\t\tcompatible = "riscv,pmu";
\t\t/* FROST has only the two fixed counters (no programmable mhpmcounters).
\t\t * Map cycle and instret to them so OpenSBI's SBI-v3 EVENT_GET_INFO
\t\t * reports them supported (without a hw_event_map entry that bulk
\t\t * probe returns even the fixed counters as unsupported and the
\t\t * kernel's perf driver disables cycles/instructions). cycle ->
\t\t * mcycle (counter 0, bit 0), instret -> minstret (counter 2, bit 2). */
\t\triscv,event-to-mhpmcounters = <0x00000001 0x00000001 0x00000001>,
\t\t\t\t      <0x00000002 0x00000002 0x00000004>;
\t}};

\tsoc {{
\t\t#address-cells = <0x01>;
\t\t#size-cells = <0x01>;
\t\tcompatible = "simple-bus";
\t\tranges;

\t\tserial@{UART_BASE:x} {{
\t\t\tcompatible = "ns16550a";
\t\t\treg = <0x{UART_BASE:08x} 0x100>;
\t\t\treg-shift = <0x02>;
\t\t\treg-io-width = <0x04>;
\t\t\tclock-frequency = <{clk_hz}>;
\t\t\tinterrupt-parent = <&plic>;
\t\t\tinterrupts = <{UART_PLIC_SOURCE}>;
\t\t}};

\t\tclint@{CLINT_BASE:x} {{
\t\t\tcompatible = "sifive,clint0", "riscv,clint0";
\t\t\treg = <0x{CLINT_BASE:08x} 0x{CLINT_SIZE:x}>;
\t\t\tinterrupts-extended = <&cpu0_intc 3 &cpu0_intc 7>;
\t\t}};

\t\tplic: interrupt-controller@{PLIC_BASE:x} {{
\t\t\tcompatible = "sifive,plic-1.0.0", "riscv,plic0";
\t\t\treg = <0x{PLIC_BASE:08x} 0x{PLIC_SIZE:08x}>;
\t\t\t#interrupt-cells = <0x01>;
\t\t\t#address-cells = <0x00>;
\t\t\tinterrupt-controller;
\t\t\triscv,ndev = <{PLIC_NDEV}>;
\t\t\tinterrupts-extended = <&cpu0_intc 11 &cpu0_intc 9>;
\t\t}};
\t\tdma-test-engine@{DMA_ENGINE_BASE:x} {{
\t\t\tcompatible = "frost,dma-test-engine";
\t\t\treg = <0x{DMA_ENGINE_BASE:08x} 0x{DMA_ENGINE_SIZE:x}>;
\t\t\tinterrupt-parent = <&plic>;
\t\t\tinterrupts = <{DMA_ENGINE_PLIC_SOURCE}>;
\t\t}};
\t\tethernet@{NIC_BASE:x} {{
\t\t\tcompatible = "frost,net10g";
\t\t\treg = <0x{NIC_BASE:08x} 0x{NIC_SIZE:x}>;
\t\t\tinterrupt-parent = <&plic>;
\t\t\tinterrupts = <{NIC_PLIC_SOURCE}>;
\t\t\tdma-coherent;
\t\t\tlocal-mac-address = [{mac}];
\t\t\tclock-frequency = <{clk_hz}>;
\t\t}};
\t}};
}};
"""


def compile_dtb(dts: str, out_dir: Path, dtc: str) -> bytes:
    """Write frost.dts, compile it with dtc, and return the DTB bytes."""
    dts_path = out_dir / "frost.dts"
    dtb_path = out_dir / "frost.dtb"
    dts_path.write_text(dts)
    subprocess.run(
        [dtc, "-I", "dts", "-O", "dtb", "-o", str(dtb_path), str(dts_path)], check=True
    )
    return dtb_path.read_bytes()


def build_shim(
    out_dir: Path, layout: Layout, cross: str, march: str, mabi: str
) -> bytes:
    """Assemble the low-BRAM boot shim and return its raw bytes."""
    src = out_dir / "frost_boot_shim.S"
    src.write_text(
        ".section .text\n.globl _start\n_start:\n"
        "    li   a0, 0\n"  # boot hart id (FROST is single-hart)
        f"    li   a1, 0x{DDR_BASE + layout.dtb_offset:08x}\n"  # a1 = DTB physical address
        f"    li   t0, 0x{DDR_BASE + FW_OFFSET:08x}\n"  # OpenSBI fw_jump entry
        "    jr   t0\n"
    )
    elf = out_dir / "shim.elf"
    binf = out_dir / "shim.bin"
    cmd = [cross + "gcc"]
    if march:
        cmd.append("-march=" + march)
    if mabi:
        cmd.append("-mabi=" + mabi)
    # -static -no-pie: a Linux-targeted toolchain (the Buildroot lane's)
    # defaults to a dynamic PIE link, which has no place in a 24-byte ROM shim.
    cmd += ["-nostdlib", "-static", "-no-pie", "-Wl,-Ttext=0", "-o", str(elf), str(src)]
    subprocess.run(cmd, check=True)
    subprocess.run([cross + "objcopy", "-O", "binary", str(elf), str(binf)], check=True)
    return binf.read_bytes()


def check_layout(
    layout: Layout,
    firmware: bytes,
    dtb: bytes,
    initrd: bytes | None,
    mem_size: int = MEM_SIZE,
) -> None:
    """Assert every region is ordered, fits its slot and ends inside memory.

    mem_size is the memory node's size, the bound for the DTB slot and the
    initramfs.
    """
    assert len(firmware) <= FW_MAX_BYTES, (
        f"firmware is 0x{len(firmware):x} bytes; the slot below the payload holds "
        f"0x{FW_MAX_BYTES:x} plus OpenSBI's runtime regions"
    )
    assert PAYLOAD_OFFSET + layout.footprint <= layout.dtb_offset, (
        f"payload footprint 0x{layout.footprint:x} at +0x{PAYLOAD_OFFSET:x} overruns "
        f"the DTB slot at +0x{layout.dtb_offset:x}"
    )
    assert len(dtb) + DTB_GROWTH_BYTES <= DTB_SLOT_BYTES, (
        f"DTB is 0x{len(dtb):x} bytes; the slot holds 0x{DTB_SLOT_BYTES:x} minus "
        f"0x{DTB_GROWTH_BYTES:x} of fixup growth"
    )
    assert layout.dtb_offset + DTB_SLOT_BYTES <= mem_size, (
        f"DTB slot at +0x{layout.dtb_offset:x}, above a payload footprint of "
        f"0x{layout.footprint:x}, overruns the 0x{mem_size:x} memory node (its "
        "size is --mem-size)"
    )
    if initrd is not None:
        assert layout.initrd_offset + len(initrd) <= mem_size, (
            f"initramfs 0x{len(initrd):x} bytes at +0x{layout.initrd_offset:x} "
            f"overruns the 0x{mem_size:x} memory node (its size is --mem-size)"
        )


def write_images(
    out_dir: Path,
    layout: Layout,
    shim: bytes,
    firmware: bytes,
    payload: bytes,
    dtb: bytes,
    initrd: bytes | None,
) -> int:
    """Write sw.{mem,txt} and sw_ddr.{mem,txt}; return the dense word count."""
    sw = to_words(shim)
    (out_dir / "sw.mem").write_text("@00000000\n" + "\n".join(sw) + "\n")
    (out_dir / "sw.txt").write_text("\n".join(sw) + "\n")

    regions = [(FW_OFFSET, to_words(firmware)), (PAYLOAD_OFFSET, to_words(payload)),
               (layout.dtb_offset, to_words(dtb))]  # fmt: skip
    if initrd is not None:
        regions.append((layout.initrd_offset, to_words(initrd)))

    with (out_dir / "sw_ddr.mem").open("w") as f:
        for offset, words in regions:
            f.write(f"@{offset // 4:08x}\n" + "\n".join(words) + "\n")

    dense: list[str] = []
    for offset, words in regions:
        assert offset // 4 >= len(dense), "regions must not overlap"
        dense.extend(["00000000"] * (offset // 4 - len(dense)))
        dense.extend(words)
    (out_dir / "sw_ddr.txt").write_text("\n".join(dense) + "\n")
    return len(dense)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse the command line.

    Environment variables supply defaults for the Buildroot post-image hook
    (FROST_FIRMWARE, FROST_IMAGE, FROST_INITRD, FROST_OUTDIR,
    FROST_CROSS_COMPILE, FROST_DTC, FROST_SHIM_MARCH/MABI, FPGA_CPU_CLK_FREQ).
    """
    env = os.environ.get
    parser = argparse.ArgumentParser(description="Pack a FROST OpenSBI boot image.")
    parser.add_argument("--firmware", default=env("FROST_FIRMWARE"), help="fw_jump.bin")
    parser.add_argument(
        "--payload", default=env("FROST_IMAGE"), help="Linux Image or raw S-mode binary"
    )
    parser.add_argument(
        "--initrd", default=env("FROST_INITRD"), help="initramfs cpio (optional)"
    )
    parser.add_argument(
        "--out", default=env("FROST_OUTDIR", "."), help="output directory"
    )
    parser.add_argument(
        "--cross", default=env("FROST_CROSS_COMPILE", "riscv-none-elf-")
    )
    parser.add_argument("--dtc", default=env("FROST_DTC", "dtc"))
    parser.add_argument(
        "--clk", type=int, default=int(env("FPGA_CPU_CLK_FREQ", str(DEFAULT_CLK_HZ)))
    )
    root = parser.add_mutually_exclusive_group()
    root.add_argument(
        "--bootargs", default=DEFAULT_BOOTARGS, help='"" to omit bootargs'
    )
    root.add_argument(
        "--nfsroot",
        metavar="SERVER_IP:/PATH",
        help="boot from this NFS export (sets the bootargs): the kernel mounts it, "
        "or with --initrd the initramfs (initramfs-tools' boot=nfs)",
    )
    parser.add_argument(
        "--ip",
        help="ip= for --nfsroot, in the kernel's syntax "
        f"(default: {DEFAULT_NFSROOT_IP})",
    )
    parser.add_argument(
        "--mac",
        type=mac_address,
        help="the NIC's local-mac-address, aa:bb:cc:dd:ee:ff "
        f"(default: {NIC_MAC_ADDRESS.replace(' ', ':')})",
    )
    parser.add_argument(
        "--mem-size",
        type=memory_size,
        default=MEM_SIZE,
        help="bytes of memory to advertise at the DDR base, a multiple of 2 MiB "
        f"(default: 0x{MEM_SIZE:x}, the simulation DDR model's size)",
    )
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument(
        "--shim-march", default=env("FROST_SHIM_MARCH", DEFAULT_SHIM_MARCH)
    )
    parser.add_argument(
        "--shim-mabi", default=env("FROST_SHIM_MABI", DEFAULT_SHIM_MABI)
    )
    args = parser.parse_args(argv)
    if not args.firmware or not args.payload:
        parser.error(
            "--firmware and --payload are required (or FROST_FIRMWARE / FROST_IMAGE)"
        )
    if args.nfsroot is not None:
        if ":/" not in args.nfsroot:
            parser.error("--nfsroot takes <server-ip>:/<path>")
        args.bootargs = nfsroot_bootargs(args.nfsroot, args.ip, bool(args.initrd))
    elif args.ip is not None:
        parser.error("--ip applies only with --nfsroot")
    return args


def main(argv: list[str] | None = None) -> int:
    """Pack the images and print the layout."""
    args = parse_args(argv)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    firmware = Path(args.firmware).read_bytes()
    payload = Path(args.payload).read_bytes()
    initrd = Path(args.initrd).read_bytes() if args.initrd else None
    layout = plan_layout(payload_footprint(payload))
    initrd_range = None
    if initrd is not None:
        initrd_range = (
            DDR_BASE + layout.initrd_offset,
            DDR_BASE + layout.initrd_offset + len(initrd),
        )
    dtb = compile_dtb(
        gen_dts(
            clk_hz=args.clk,
            initrd_range=initrd_range,
            bootargs=args.bootargs,
            model=args.model,
            mac=args.mac or NIC_MAC_ADDRESS,
            mem_size=args.mem_size,
        ),
        out_dir,
        args.dtc,
    )
    check_layout(layout, firmware, dtb, initrd, args.mem_size)
    shim = build_shim(out_dir, layout, args.cross, args.shim_march, args.shim_mabi)
    dense_words = write_images(out_dir, layout, shim, firmware, payload, dtb, initrd)

    kind = "Linux Image" if linux_image_size(payload) is not None else "raw payload"
    print(
        f"firmware {len(firmware)} B @ 0x{DDR_BASE + FW_OFFSET:08x}; {kind} {len(payload)} B "
        f"(footprint 0x{layout.footprint:x}) @ 0x{DDR_BASE + PAYLOAD_OFFSET:08x}; DTB {len(dtb)} B "
        f"@ 0x{DDR_BASE + layout.dtb_offset:08x}"
        + (
            f"; initrd {len(initrd)} B @ 0x{initrd_range[0]:08x} (end 0x{initrd_range[1]:08x})"
            if initrd is not None and initrd_range is not None
            else ""
        )
    )
    print(
        f"sw_ddr.txt: {dense_words} dense words (~{dense_words * 4 / 1e6:.1f} MB), "
        f"timebase/uart-clk = {args.clk} Hz, memory 0x{args.mem_size:x} B; "
        f"outputs in {out_dir}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
