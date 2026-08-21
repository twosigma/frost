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

> Boot ABI (entry state, memory map, DT contract, interrupt model, kernel
> config requirements): see [`../README.md`](../README.md).

This tree builds the FROST **no-MMU / M-mode rv64 Linux** kernel (6.18.7) and
a busybox initramfs, then packages images for cocotb `linux_boot` and the FPGA
JTAG loader. The `-rv64` suffixes on configs, build directories, CI artifacts,
and ccache keys distinguish a retired rv32 lane; they remain for cache reuse
and stable golden names.

It is a standard Buildroot [`BR2_EXTERNAL`](https://buildroot.org/downloads/manual/manual.html#outside-br-custom)
tree with no Buildroot source. Use the pinned submodule below.

## Layout

```
linux/buildroot-external/
├── external.desc                          # BR2_EXTERNAL manifest (name: FROST)
├── external.mk                            # package include hook
├── Config.in                              # package menu hook
├── configs/
│   └── frost_nommu_rv64_defconfig         # the FROST Buildroot defconfig
├── package/frost-stress/                  # userspace boot stress payload (see below)
│   ├── Config.in
│   ├── frost-stress.mk
│   └── src/frost_stress.c
└── board/frost/
    ├── linux-nommu-base-rv64.config       # base kernel config (upstream buildroot board/qemu/riscv64-virt linux-nommu.config)
    ├── linux-nommu-frost.config.fragment  # FROST kernel CONFIG delta, merged on top of the base (XLEN-free)
    ├── busybox.config                     # BusyBox config (BR2_PACKAGE_BUSYBOX_CONFIG)
    ├── device_table.txt                   # static /dev nodes (BR2_ROOTFS_DEVICE_TABLE)
    ├── rootfs-overlay/etc/inittab         # rootfs overlay (BR2_ROOTFS_OVERLAY)
    ├── build_fpga_boot.py                 # packer: Image + DTB + initramfs -> sw.{mem,txt}, sw_ddr.{mem,txt}
    ├── post-image.sh                      # Buildroot post-image hook -> packer, then image post-processing
    ├── patch_linux_image.py               # that post-processing (copy of sw/apps/linux_boot/patch_linux_image.py)
    └── patches/                           # BR2_GLOBAL_PATCH_DIR
        ├── linux/linux.hash               # sha256 for the custom linux-6.18.7 tarball (BR2_DOWNLOAD_FORCE_CHECK_HASHES)
        └── uclibc/0001-nommu-default-dl_pagesize-to-PAGE_SIZE.patch  # no-MMU page-size fix (malloc)
```

## Buildroot pin

The `linux/buildroot` submodule is pinned to **`67449130`**, a `2026.08-git`
snapshot. Its defaults provide **gcc 15.2.0**, **binutils 2.45.1**, the internal
no-MMU rv64 **uClibc** toolchain with an `lp64d` userspace ABI, and the
**Linux 6.18** host-headers option. Pinning a commit avoids tag movement.

Initialize it after checkout:

```bash
git submodule update --init linux/buildroot
```

To bump it, update and commit the gitlink:

```bash
git -C linux/buildroot checkout <new-sha>
git add linux/buildroot
git commit -m "linux: bump vendored buildroot to <new-sha>"
```

> Re-verify a bump ships `BR2_GCC_VERSION_15_X` (15.2.0),
> `BR2_BINUTILS_VERSION_2_45_X` (2.45.1) and
> `BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_6_18`, which this defconfig relies on.

## Build

Build out of tree to keep the submodule pristine:

```bash
# from the repo root
./scripts/frost.py run make -C linux/buildroot O=/workspace/linux/build-rv64 \
  BR2_EXTERNAL=/workspace/linux/buildroot-external frost_nommu_rv64_defconfig
./scripts/frost.py run make -C linux/buildroot O=/workspace/linux/build-rv64
```

First build is ~30–60 min (it builds the cross toolchain from source).
Outputs land in `linux/build-rv64/images/`:

| File | Purpose |
|---|---|
| `Image` | no-MMU rv64 kernel (flat, uncompressed) |
| `rootfs.cpio.gz` | busybox initramfs |
| `frost-nommu-fpga.dtb` | generated FROST device tree (ns16550a UART @ 0x4000_1000, CLINT @ 0x4001_0000; clock/timebase = `FPGA_CPU_CLK_FREQ`, 133.333 MHz genesys2 default) |
| `sw.mem` / `sw.txt` | low-BRAM boot shim (`a0=0`, `a1=DTB`, jump to kernel) |
| `sw_ddr.mem` / `sw_ddr.txt` | DDR image: kernel @ 0x8000_0000, DTB @ 0x8080_0000, initramfs @ 0x8081_0000 |

## Feeding the cocotb `linux_boot` test

`tests/test_run_cocotb.py` resolves an app's images at
`sw/apps/<app>/sw.mem` (+ `sw_ddr.mem`). Stage the build outputs there:

```bash
mkdir -p sw/apps/linux_boot
cp linux/build-rv64/images/sw.mem     sw/apps/linux_boot/sw.mem
cp linux/build-rv64/images/sw_ddr.mem sw/apps/linux_boot/sw_ddr.mem
# The wrapper runs in the pinned image and cleans tests/ before launching.
./scripts/frost.py cocotb linux_boot
```

The app Makefile runs Buildroot if `linux/build-rv64/images/Image` is absent,
then packs and post-processes the images for the board clock. This is the path
used by `fpga/load_software/load_software.py <board> linux_boot`:

```bash
./scripts/frost.py run make -C sw/apps/linux_boot  # genesys2 (133.33 MHz) default
FPGA_CPU_CLK_FREQ=300000000 ./scripts/frost.py run make -C sw/apps/linux_boot
```

Three CI jobs cover Linux. `build-frost-linux` invokes Buildroot directly and
uploads `frost-linux-boot-images-rv64`. `linux-boot-cocotb` runs the
`linux_boot_128k` entry for 22M cycles in the genesys2 shape (128 KiB L1I, no
L2), then grades the log with `check_linux_boot_regression.py`.
`CACHED_HAS_L2=0` must be an env/make variable because the `tests/Makefile`
default overrides the registry argument. `linux-boot-qemu` boots the same
`Image` and `rootfs.cpio.gz` with `qemu-system-riscv64 -cpu rv64,mmu=off`.
The plain `linux_boot` entry is not in CI; both entries set
`include_in_pytest=False`.

## How the kernel config is assembled

`BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG` selects
`board/frost/linux-nommu-base-rv64.config` (a copy of upstream Buildroot's
`board/qemu/riscv64-virt/linux-nommu.config` mini-config) as the base, and
`BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES` merges
`board/frost/linux-nommu-frost.config.fragment` with `merge_config.sh`
semantics. The fragment is XLEN-free: `CONFIG_ARCH_RV64I` and `CONFIG_64BIT`
stay in the base because a fragment restatement would override its base. It
keeps M-mode/no-MMU/bFLT, selects an initramfs, and drops virtio, PCI,
networking, ext2, and PLIC. The fragment documents each symbol and caveat.

## Notes, assumptions, and gaps

- **Rootfs reproduction.** `rootfs.cpio.gz` is built from the committed
  `board/frost/busybox.config` (BusyBox 1.38.0, overriding Buildroot's
  `busybox-minimal.config` no-MMU default) + `BR2_TARGET_ROOTFS_CPIO[_GZIP]`,
  not vendored. `BR2_ROOTFS_DEVICE_TABLE` applies `board/frost/device_table.txt`
  on top of Buildroot's own `system/device_table.txt` for the static `/dev`
  nodes. `BR2_ROOTFS_OVERLAY` adds `board/frost/rootfs-overlay/`, currently
  `etc/inittab`. Edit those files to change userspace.
- **Userspace boot stress payload.** The `frost-stress` package installs
  `/usr/bin/frost_stress`, run once from the overlay inittab (sysinit, before
  the getty): a timer storm with signal delivery, vfork/exec context
  switching, futex ping-pong over a `MAP_SHARED` file mapping, lock-free
  LR/SC contention between two processes, and Zicntr counter deltas
  (`cycles=`/`instret=`/`time=`/`ipc_x1000=`) around a fixed workload. It
  prints one stats line and the stable
  `FROST_USERSPACE_STRESS_PASS`/`_FAIL` token; the `linux-boot-qemu`
  CI job and `fpga/linux_boot_soak.py` assert the token, testing userspace rather
  than only the kernel banner.
  Under QEMU the counter phase degrades to `counters=unavailable` (QEMU
  resets `mcounteren` to 0 and the M-mode kernel never sets it; FROST resets
  it to 0x7 — see `linux/README.md`), and the hardware soak fails any boot
  showing that degradation.
  bFLT note: the payload builds with buildroot's riscv FLAT flags (`-fPIC` +
  `-Wl,-elf2flt="-r -s<stack>"`); dropping either leaves the GOT unrelocated
  and the binary SIGSEGVs on its first global store.
- **Image post-processing.** After the packer, `post-image.sh` runs
  `patch_linux_image.py` over the packed `sw_ddr.{mem,txt}` when present:
  mandatory seedrng and `/dev` fixups plus env-gated bring-up hooks. The
  `sw/apps/linux_boot` path uses the same script. Its former
  `ret_from_exception` mutation was retired 2026-07-26: the suspected race is
  absent, the implicated hangs came from fixed interrupt-latch and AMO bugs,
  and `sw/apps/restore_window_stress` covers the relevant interleavings. See the
  script's history note.
- **Historical bring-up image.** This defconfig applies the FROST fragment. The
  rv32-era bring-up used a
  externally built `Image` from the **stock**
  `qemu_riscv32_nommu_virt_defconfig` *without* the fragment (it still had
  `CONFIG_NET` / `CONFIG_VIRTIO_BLK` / `CONFIG_SIFIVE_PLIC` / `CONFIG_EXT2_FS`
  set). The current kernel supersedes it and omits PLIC/virtio DT nodes; it was
  never intended to reproduce that artifact bit-for-bit.
- **Boot shim toolchain.** Standalone, the packer uses the xPack
  `riscv-none-elf-*` bare-metal toolchain with `rv64i_zicsr` / `lp64` shim
  defaults (`FROST_SHIM_MARCH` / `FROST_SHIM_MABI` override them). In the
  Buildroot flow `post-image.sh` instead uses the Buildroot-built
  `riscv64-*-` toolchain with its own default `-march`/`-mabi` (the shim is
  ABI-agnostic integer code). `build_fpga_boot.py` is hardcoded to rv64
  (DTS `rv64i*` isa strings, shim defaults).
- **`dtc`.** `post-image.sh` prefers `$HOST_DIR/bin/dtc`, then the kernel's
  `scripts/dtc/dtc`, then `$PATH`. Enable `BR2_PACKAGE_HOST_DTC=y` if you want
  to guarantee a host `dtc` independent of the kernel build.
