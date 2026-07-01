<!--
   Copyright 2026 Two Sigma Open Source, LLC

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
-->

# FROST Buildroot external tree (`BR2_EXTERNAL`)

Reproducibly builds the FROST **RV32 / no-MMU / M-mode Linux** kernel (6.18.7),
a busybox initramfs, and packages them into the memory images the FROST cocotb
`linux_boot` simulation (and the FPGA JTAG loader) consume.

This is a standard Buildroot [`BR2_EXTERNAL`](https://buildroot.org/downloads/manual/manual.html#outside-br-custom)
tree. It carries **no** Buildroot source itself — point an out-of-tree build at
a pinned upstream Buildroot checkout (see *Buildroot pin* below).

## Layout

```
linux/buildroot-external/
├── external.desc                          # BR2_EXTERNAL manifest (name: FROST)
├── external.mk                            # package include hook (no packages today)
├── Config.in                              # package menu hook (empty today)
├── configs/
│   └── frost_nommu_rv32_defconfig         # the FROST Buildroot defconfig
└── board/frost/
    ├── linux-nommu-base.config            # base kernel config (from buildroot board/qemu/riscv32-virt)
    ├── linux-nommu-frost.config.fragment  # FROST kernel CONFIG delta, merged on top of the base
    ├── frost-nommu-fpga.dts               # reference DTB source (the packer regenerates it per build)
    ├── build_fpga_boot.py                 # packer: Image + DTB + initramfs -> sw.{mem,txt}, sw_ddr.{mem,txt}
    ├── post-image.sh                      # Buildroot post-image hook -> runs the packer
    └── patches/linux/linux.hash           # sha256 for the custom linux-6.18.7 tarball
```

## Buildroot pin

Buildroot is vendored as a submodule at `linux/buildroot`, pinned to the exact
commit **`67449130`** (a `2026.08-git` snapshot). That commit provides the
defaults this defconfig relies on: **gcc 15.2.0**, **binutils 2.45.1**, the
internal rv32-nommu **uClibc** toolchain, and the **Linux 6.18** host-headers
option. The pin is the exact commit rather than a release tag so the build is
reproducible regardless of tag movement.

A fresh checkout only needs the submodule initialized:

```bash
git submodule update --init linux/buildroot
```

To bump the pin, checkout the new commit in the submodule and commit the
updated gitlink:

```bash
git -C linux/buildroot checkout <new-sha>
git add linux/buildroot
git commit -m "linux: bump vendored buildroot to <new-sha>"
```

> Re-verify a bump ships `BR2_GCC_VERSION_15_X` (15.2.0),
> `BR2_BINUTILS_VERSION_2_45_X` (2.45.1) and
> `BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_6_18`, which this defconfig relies on.

## Build

Out-of-tree build (keeps the Buildroot submodule pristine):

```bash
# from the repo root
make -C linux/buildroot O="$(pwd)/linux/build" \
     BR2_EXTERNAL="$(pwd)/linux/buildroot-external" frost_nommu_rv32_defconfig
make -C linux/buildroot O="$(pwd)/linux/build"
```

First build is ~30–60 min (it builds the cross toolchain from source). Outputs
land in `linux/build/images/`:

| File | Purpose |
|---|---|
| `Image` | rv32 no-MMU kernel (flat, uncompressed) |
| `rootfs.cpio.gz` | busybox initramfs |
| `frost-nommu-fpga.dtb` | generated FROST device tree (UART/CLINT @ 0x4000_xxxx, 133.333 MHz) |
| `sw.mem` / `sw.txt` | low-BRAM boot shim (`a0=0`, `a1=DTB`, jump to kernel) |
| `sw_ddr.mem` / `sw_ddr.txt` | DDR image: kernel @ 0x8000_0000, DTB @ 0x8080_0000, initramfs @ 0x8081_0000 |

## Feeding the cocotb `linux_boot` test

`tests/test_run_cocotb.py` resolves an app's images at
`sw/apps/<app>/sw.mem` (+ `sw_ddr.mem`). Stage the build outputs there:

```bash
mkdir -p sw/apps/linux_boot
cp linux/build/images/sw.mem     sw/apps/linux_boot/sw.mem
cp linux/build/images/sw_ddr.mem sw/apps/linux_boot/sw_ddr.mem
# then, per the repo CLAUDE.md test flow:
cd tests && make clean && ./test_run_cocotb.py linux_boot
```

Or let the app Makefile self-build straight from this tree (it runs the whole
Buildroot build if `linux/build/images/Image` is absent, then packs for the
board clock) -- this is what `fpga/load_software.py <board> linux_boot` and the
CI `build-frost-linux` job drive:

```bash
make -C sw/apps/linux_boot            # genesys2 clock (133.33 MHz) by default
make -C sw/apps/linux_boot FPGA_CPU_CLK_FREQ=300000000   # x3 clock
```

The `linux_boot` cocotb registry entry (`linux_boot` / `linux_boot_128k`) and
its `build-frost-linux` + `linux-boot-cocotb` + `linux-boot-qemu` CI jobs live
on `main`.

## How the kernel config is assembled

`BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG` uses `board/frost/linux-nommu-base.config`
as the base, and `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES` merges
`board/frost/linux-nommu-frost.config.fragment` on top (kconfig
`merge_config.sh` semantics). The fragment retargets the known-good QEMU-virt
nommu kernel at FROST: it keeps M-mode / rv32 / no-MMU / bFLT, switches the
rootfs to an initramfs (`BLK_DEV_INITRD` + `RD_GZIP`), and drops
virtio / PCI / net / ext2 / PLIC. See the header of the fragment for the full,
per-symbol rationale and the hardware caveats.

## Notes, assumptions and gaps

- **Rootfs reproduction.** `rootfs.cpio.gz` is reproduced from Buildroot's
  default busybox (`busybox-minimal.config`) + `BR2_TARGET_ROOTFS_CPIO[_GZIP]`,
  not vendored. It is functionally equivalent to the hand-made
  `frost-artifacts/rootfs.cpio.gz` but **not** byte-identical. Add a
  `rootfs-overlay/` + `BR2_ROOTFS_OVERLAY` here if a specific userspace is
  required.
- **Fragment vs. the latest hand-built Image.** This defconfig *applies* the
  FROST fragment (per the build notes' "Option A"). The most recent artifact
  `Image` checked on the dev box was actually built from the **stock**
  `qemu_riscv32_nommu_virt_defconfig` *without* the fragment (it still had
  `CONFIG_NET` / `CONFIG_VIRTIO_BLK` / `CONFIG_SIFIVE_PLIC` / `CONFIG_EXT2_FS`
  set). Decide whether the fragment-applied kernel here is the intended target
  (it should be — it is strictly closer to FROST and the generated DTB has no
  PLIC/virtio nodes) or whether to drop the fragment to match that artifact
  bit-for-bit.
- **Boot shim toolchain.** Standalone, the packer uses the xPack
  `riscv-none-elf-*` bare-metal toolchain (`rv32i_zicsr` / `ilp32`). In CI
  `post-image.sh` instead uses the Buildroot-built `riscv32-*-` toolchain with
  its own default `-march`/`-mabi` (the shim is ABI-agnostic integer code).
- **`dtc`.** `post-image.sh` prefers `$HOST_DIR/bin/dtc`, then the kernel's
  `scripts/dtc/dtc`, then `$PATH`. Enable `BR2_PACKAGE_HOST_DTC=y` if you want
  to guarantee a host `dtc` independent of the kernel build.
