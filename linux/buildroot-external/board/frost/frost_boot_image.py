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
  +16 MiB     the DTB, in a 64 KiB slot (OpenSBI grows it in place)
  +16 MiB+64K the initramfs cpio, when given (bounds via linux,initrd-*)

The boot shim in low BRAM sets a0 = hart id, a1 = the DTB address and jumps to
the firmware; fw_jump passes a1 through (it is built without an FDT offset), so
the addresses here are the only copy of the layout.

Outputs (in --out):
  sw.{mem,txt}      the low-BRAM shim
  sw_ddr.{mem,txt}  the DDR image, sparse ``.mem`` (readmemh address
                    directives) and dense ``.txt`` (the JTAG loader's stream)
  frost.{dts,dtb}   the generated device tree

A Linux ``Image`` is recognized by its header magic and checked against the
header's ``image_size`` (text plus bss) rather than the file size. Every
placement is asserted against the slot table, and the DTB is given growth
slack for OpenSBI's reserved-memory and cpu fixups.
"""

import argparse
import os
import struct
import subprocess
import sys
from pathlib import Path

DDR_BASE = 0x8000_0000
FW_OFFSET = 0x0
PAYLOAD_OFFSET = 0x20_0000
DTB_OFFSET = 0x100_0000
DTB_SLOT_BYTES = 0x1_0000
INITRD_OFFSET = DTB_OFFSET + DTB_SLOT_BYTES
MEM_SIZE = 0x400_0000  # 64 MiB advertised in /memory (also the sim DDR model)

# fw_jump.bin is ~270 KiB; its runtime rw/heap/scratch regions follow the
# binary and OpenSBI reserves them below the payload (banner "Firmware Size").
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

DEFAULT_BOOTARGS = "earlycon console=ttyS0 rdinit=/sbin/init"
DEFAULT_MODEL = "FROST RV64 (Sv39, OpenSBI)"
DEFAULT_CLK_HZ = 300_000_000  # X3
DEFAULT_SHIM_MARCH = "rv64i_zicsr"
DEFAULT_SHIM_MABI = "lp64"

UART_BASE = 0x4000_1000
CLINT_BASE = 0x4001_0000
CLINT_SIZE = 0xC000
PLIC_BASE = 0x4400_0000
PLIC_SIZE = 0x40_0000
PLIC_NDEV = 2
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


def gen_dts(
    *,
    clk_hz: int,
    initrd_range: tuple[int, int] | None,
    bootargs: str,
    model: str,
) -> str:
    """Return the FROST device tree source for the OpenSBI + Sv39 boot."""
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
\t\treg = <0x{DDR_BASE:08x} 0x{MEM_SIZE:08x}>;
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


def build_shim(out_dir: Path, cross: str, march: str, mabi: str) -> bytes:
    """Assemble the low-BRAM boot shim and return its raw bytes."""
    src = out_dir / "frost_boot_shim.S"
    src.write_text(
        ".section .text\n.globl _start\n_start:\n"
        "    li   a0, 0\n"  # boot hart id (FROST is single-hart)
        f"    li   a1, 0x{DDR_BASE + DTB_OFFSET:08x}\n"  # a1 = DTB physical address
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
    firmware: bytes, payload: bytes, dtb: bytes, initrd: bytes | None
) -> int:
    """Assert every region fits its slot; return the payload's footprint."""
    assert len(firmware) <= FW_MAX_BYTES, (
        f"firmware is 0x{len(firmware):x} bytes; the slot below the payload holds "
        f"0x{FW_MAX_BYTES:x} plus OpenSBI's runtime regions"
    )
    footprint = linux_image_size(payload)
    if footprint is None:
        footprint = len(payload)
    else:
        assert footprint >= len(
            payload
        ), "Linux Image header image_size below the file size"
    assert PAYLOAD_OFFSET + footprint <= DTB_OFFSET, (
        f"payload footprint 0x{footprint:x} at +0x{PAYLOAD_OFFSET:x} overruns the DTB "
        f"slot at +0x{DTB_OFFSET:x}"
    )
    assert len(dtb) + DTB_GROWTH_BYTES <= DTB_SLOT_BYTES, (
        f"DTB is 0x{len(dtb):x} bytes; the slot holds 0x{DTB_SLOT_BYTES:x} minus "
        f"0x{DTB_GROWTH_BYTES:x} of fixup growth"
    )
    if initrd is not None:
        assert INITRD_OFFSET + len(initrd) <= MEM_SIZE, (
            f"initramfs 0x{len(initrd):x} bytes at +0x{INITRD_OFFSET:x} overruns the "
            f"0x{MEM_SIZE:x} memory node"
        )
    return footprint


def write_images(
    out_dir: Path,
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
               (DTB_OFFSET, to_words(dtb))]  # fmt: skip
    if initrd is not None:
        regions.append((INITRD_OFFSET, to_words(initrd)))

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
    parser.add_argument(
        "--bootargs", default=DEFAULT_BOOTARGS, help='"" to omit bootargs'
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
    return args


def main(argv: list[str] | None = None) -> int:
    """Pack the images and print the layout."""
    args = parse_args(argv)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    firmware = Path(args.firmware).read_bytes()
    payload = Path(args.payload).read_bytes()
    initrd = Path(args.initrd).read_bytes() if args.initrd else None
    initrd_range = None
    if initrd is not None:
        initrd_range = (
            DDR_BASE + INITRD_OFFSET,
            DDR_BASE + INITRD_OFFSET + len(initrd),
        )
    dtb = compile_dtb(
        gen_dts(
            clk_hz=args.clk,
            initrd_range=initrd_range,
            bootargs=args.bootargs,
            model=args.model,
        ),
        out_dir,
        args.dtc,
    )
    footprint = check_layout(firmware, payload, dtb, initrd)
    shim = build_shim(out_dir, args.cross, args.shim_march, args.shim_mabi)
    dense_words = write_images(out_dir, shim, firmware, payload, dtb, initrd)

    kind = "Linux Image" if linux_image_size(payload) is not None else "raw payload"
    print(
        f"firmware {len(firmware)} B @ 0x{DDR_BASE + FW_OFFSET:08x}; {kind} {len(payload)} B "
        f"(footprint 0x{footprint:x}) @ 0x{DDR_BASE + PAYLOAD_OFFSET:08x}; DTB {len(dtb)} B "
        f"@ 0x{DDR_BASE + DTB_OFFSET:08x}"
        + (
            f"; initrd {len(initrd)} B @ 0x{initrd_range[0]:08x} (end 0x{initrd_range[1]:08x})"
            if initrd is not None and initrd_range is not None
            else ""
        )
    )
    print(
        f"sw_ddr.txt: {dense_words} dense words (~{dense_words * 4 / 1e6:.1f} MB), "
        f"timebase/uart-clk = {args.clk} Hz; outputs in {out_dir}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
