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

# Vendored from frost-artifacts/build_fpga_boot.py; style carve-outs pending a refactor.
# ruff: noqa: D103, UP031

"""Build a FROST FPGA / sim no-MMU Linux boot image.

Derived from frost-artifacts/build_fpga_boot.py. The packing logic (memory
layout, word format, DTB template and boot shim) is unchanged; the only
additions are environment overrides so the script runs both:

  * standalone on a dev box (xPack riscv-none-elf toolchain, original paths), and
  * as a Buildroot post-image hook in CI (board/frost/post-image.sh sets the
    env to point at Buildroot's $BINARIES_DIR and its just-built toolchain).

Emits BOTH forms of each image:
  sw.{mem,txt}      low BRAM: boot shim (a0=0, a1=DTB, jr kernel entry).
  sw_ddr.{mem,txt}  DDR (offset 0 == 0x8000_0000): kernel Image @ 0,
                    DTB @ 0x80_0000, initramfs (cpio.gz) @ 0x81_0000.

  .mem = $readmemh form (sim): "@<word-index>" directives + word values.
  .txt = FPGA-loader form: dense, one little-endian word value per line from
         offset 0 (file_to_bram.tcl / file_to_ddr.tcl burst it sequentially).
Both carry identical little-endian word values.

Environment overrides (all optional; defaults reproduce the standalone build):
  FROST_IMAGE          kernel Image path        (default: ~/bigger_l0/linux-mvp/buildroot/output/images/Image)
  FROST_INITRD         rootfs.cpio.gz path      (default: <script dir>/rootfs.cpio.gz)
  FROST_OUTDIR         where to write outputs   (default: <script dir>)
  FROST_CROSS_COMPILE  cross toolchain prefix   (default: riscv-none-elf-)
  FROST_DTC            device-tree compiler     (default: dtc)
  FROST_SHIM_MARCH     shim -march (empty=omit) (default: rv32i_zicsr)
  FROST_SHIM_MABI      shim -mabi  (empty=omit) (default: ilp32)
  FPGA_CPU_CLK_FREQ    timebase/uart clock Hz   (default: 133333333, genesys2)
"""

import os
import struct
import subprocess

ART = os.path.dirname(os.path.abspath(__file__))
IMAGE = os.environ.get(
    "FROST_IMAGE",
    os.path.expanduser("~/bigger_l0/linux-mvp/buildroot/output/images/Image"),
)
INITRD = os.environ.get("FROST_INITRD", os.path.join(ART, "rootfs.cpio.gz"))
OUTDIR = os.environ.get("FROST_OUTDIR", ART)
DTS = os.path.join(OUTDIR, "frost-nommu-fpga.dts")
DTB = os.path.join(OUTDIR, "frost-nommu-fpga.dtb")

CROSS = os.environ.get("FROST_CROSS_COMPILE", "riscv-none-elf-")
GCC = CROSS + "gcc"
OBJCOPY = CROSS + "objcopy"
DTC = os.environ.get("FROST_DTC", "dtc")
SHIM_MARCH = os.environ.get("FROST_SHIM_MARCH", "rv32i_zicsr")
SHIM_MABI = os.environ.get("FROST_SHIM_MABI", "ilp32")

KERNEL_ENTRY = 0x80000000
DTB_BASE = 0x80800000  # 8 MiB: clear of the kernel image_size footprint
INITRD_BASE = 0x80810000  # 8 MiB + 64 KiB: clear of the (small) DTB
DTB_WORD = (DTB_BASE - KERNEL_ENTRY) // 4  # 0x200000
INITRD_WORD = (INITRD_BASE - KERNEL_ENTRY) // 4  # 0x204000
MEM_SIZE = 0x4000000  # 64 MiB.
CLK = int(os.environ.get("FPGA_CPU_CLK_FREQ", "133333333"))  # genesys2 default

OUT = {
    k: os.path.join(OUTDIR, k) for k in ("sw.mem", "sw.txt", "sw_ddr.mem", "sw_ddr.txt")
}


def to_words(data: bytes):
    """Bytes -> 8-hex-digit little-endian WORD VALUES (xxd -e style)."""
    if len(data) % 4:
        data += b"\x00" * (4 - len(data) % 4)
    return [
        "{:08x}".format(struct.unpack_from("<I", data, i)[0])
        for i in range(0, len(data), 4)
    ]


def gen_dtb(initrd_size: int) -> bytes:
    initrd_end = INITRD_BASE + initrd_size
    dts = f"""/dts-v1/;

/ {{
\t#address-cells = <0x01>;
\t#size-cells = <0x01>;
\tcompatible = "frost,nommu-rv32", "frost";
\tmodel = "FROST RV32 (no-MMU, M-mode Linux)";

\tchosen {{
\t\tstdout-path = "/soc/serial@40001000";
\t\tbootargs = "earlycon=uart8250,mmio32,0x40001000 console=ttyS0 rdinit=/sbin/init";
\t\tlinux,initrd-start = <0x{INITRD_BASE:08x}>;
\t\tlinux,initrd-end = <0x{initrd_end:08x}>;
\t}};

\tcpus {{
\t\t#address-cells = <0x01>;
\t\t#size-cells = <0x00>;
\t\ttimebase-frequency = <{CLK}>;

\t\tcpu@0 {{
\t\t\tdevice_type = "cpu";
\t\t\treg = <0x00>;
\t\t\tstatus = "okay";
\t\t\tcompatible = "riscv";
\t\t\triscv,isa-base = "rv32i";
\t\t\triscv,isa = "rv32imafdc_zicsr_zifencei_zicntr_zba_zbb_zbs_zbkb_zicond_zihintpause";
\t\t\triscv,isa-extensions = "i", "m", "a", "f", "d", "c",
\t\t\t\t"zicsr", "zifencei", "zicntr",
\t\t\t\t"zba", "zbb", "zbs", "zbkb",
\t\t\t\t"zicond", "zihintpause";

\t\t\tcpu0_intc: interrupt-controller {{
\t\t\t\t#interrupt-cells = <0x01>;
\t\t\t\tinterrupt-controller;
\t\t\t\tcompatible = "riscv,cpu-intc";
\t\t\t\tphandle = <0x01>;
\t\t\t}};
\t\t}};
\t}};

\tmemory@80000000 {{
\t\tdevice_type = "memory";
\t\treg = <0x80000000 0x{MEM_SIZE:08x}>;
\t}};

\tsoc {{
\t\t#address-cells = <0x01>;
\t\t#size-cells = <0x01>;
\t\tcompatible = "simple-bus";
\t\tranges;

\t\tserial@40001000 {{
\t\t\tcompatible = "ns16550a";
\t\t\treg = <0x40001000 0x100>;
\t\t\treg-shift = <0x02>;
\t\t\treg-io-width = <0x04>;
\t\t\tclock-frequency = <{CLK}>;
\t\t}};

\t\tclint@40010000 {{
\t\t\tcompatible = "sifive,clint0", "riscv,clint0";
\t\t\treg = <0x40010000 0x10000>;
\t\t\tinterrupts-extended = <&cpu0_intc 3 &cpu0_intc 7>;
\t\t}};
\t}};
}};
"""
    with open(DTS, "w") as f:
        f.write(dts)
    subprocess.run([DTC, "-I", "dts", "-O", "dtb", "-o", DTB, DTS], check=True)
    return open(DTB, "rb").read()


def build_shim() -> bytes:
    src = os.path.join(OUTDIR, "frost_boot_shim.S")
    with open(src, "w") as f:
        f.write(
            ".section .text\n.globl _start\n_start:\n"
            "    li   a0, 0\n"  # boot hart id (FROST single-hart)
            f"    li   a1, 0x{DTB_BASE:08x}\n"  # a1 = DTB physical address
            f"    li   t0, 0x{KERNEL_ENTRY:08x}\n"  # kernel entry in DDR
            "    jr   t0\n"
        )
    elf = os.path.join(OUTDIR, "shim.elf")
    binf = os.path.join(OUTDIR, "shim.bin")
    cmd = [GCC]
    if SHIM_MARCH:
        cmd.append("-march=" + SHIM_MARCH)
    if SHIM_MABI:
        cmd.append("-mabi=" + SHIM_MABI)
    cmd += ["-nostdlib", "-Wl,-Ttext=0", "-o", elf, src]
    subprocess.run(cmd, check=True)
    subprocess.run([OBJCOPY, "-O", "binary", elf, binf], check=True)
    return open(binf, "rb").read()


def main():
    img = open(IMAGE, "rb").read()
    initrd = open(INITRD, "rb").read()
    dtb = gen_dtb(len(initrd))
    shim = build_shim()

    iw, dw, rw = to_words(img), to_words(dtb), to_words(initrd)
    assert (
        len(iw) <= DTB_WORD
    ), f"kernel Image (0x{len(iw):x} words) overruns the DTB slot 0x{DTB_WORD:x}"
    assert DTB_WORD + len(dw) <= INITRD_WORD, "DTB overruns the initramfs slot"

    sw = to_words(shim)
    open(OUT["sw.mem"], "w").write("@00000000\n" + "\n".join(sw) + "\n")
    open(OUT["sw.txt"], "w").write("\n".join(sw) + "\n")

    with open(OUT["sw_ddr.mem"], "w") as f:
        f.write("@00000000\n" + "\n".join(iw) + "\n")
        f.write(f"@{DTB_WORD:08x}\n" + "\n".join(dw) + "\n")
        f.write(f"@{INITRD_WORD:08x}\n" + "\n".join(rw) + "\n")
    dense = (
        iw
        + ["00000000"] * (DTB_WORD - len(iw))
        + dw
        + ["00000000"] * (INITRD_WORD - DTB_WORD - len(dw))
        + rw
    )
    open(OUT["sw_ddr.txt"], "w").write("\n".join(dense) + "\n")

    print(
        "kernel %d B (%d w); DTB %d B @ 0x%08x; initrd %d B @ 0x%08x (end 0x%08x)"
        % (
            len(img),
            len(iw),
            len(dtb),
            DTB_BASE,
            len(initrd),
            INITRD_BASE,
            INITRD_BASE + len(initrd),
        )
    )
    print(
        "sw_ddr.txt: %d dense words (~%.1f MB), timebase/uart-clk = %d Hz"
        % (len(dense), len(dense) * 4 / 1e6, CLK)
    )
    print(f"outputs written to {OUTDIR}")


if __name__ == "__main__":
    main()
