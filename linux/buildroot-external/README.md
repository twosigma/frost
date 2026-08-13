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

This tree reproducibly builds the FROST **no-MMU / M-mode Linux** kernel
(6.18.7) and a busybox initramfs — in two lanes, **rv64** (the flagship X3
configuration) and **rv32** (shipped on Genesys2) — then packages them into
the memory images consumed by the FROST cocotb `linux_boot` simulation and
the FPGA JTAG loader.

This is a standard Buildroot [`BR2_EXTERNAL`](https://buildroot.org/downloads/manual/manual.html#outside-br-custom)
tree. It carries **no** Buildroot source itself — point an out-of-tree build at
a pinned upstream Buildroot checkout (see *Buildroot pin* below).

## Layout

```
linux/buildroot-external/
├── external.desc                          # BR2_EXTERNAL manifest (name: FROST)
├── external.mk                            # package include hook
├── Config.in                              # package menu hook
├── configs/
│   ├── frost_nommu_rv32_defconfig         # the FROST Buildroot defconfig (rv32 lane)
│   └── frost_nommu_rv64_defconfig         # rv64 lane (same retarget on the rv64 base)
├── package/frost-stress/                  # userspace boot stress payload (see below)
│   ├── Config.in
│   ├── frost-stress.mk
│   └── src/frost_stress.c
└── board/frost/
    ├── linux-nommu-base.config            # rv32 base kernel config (from buildroot board/qemu/riscv32-virt)
    ├── linux-nommu-base-rv64.config       # rv64 base kernel config (rv32 base + ARCH_RV64I/64BIT)
    ├── linux-nommu-frost.config.fragment  # FROST kernel CONFIG delta, merged on top of either base (XLEN-free)
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

Buildroot is vendored as a submodule at `linux/buildroot`, pinned to the exact
commit **`67449130`** (a `2026.08-git` snapshot). That commit provides the
defaults these defconfigs rely on: **gcc 15.2.0**, **binutils 2.45.1**, the
internal no-MMU **uClibc** toolchains (rv32 and rv64; the rv64 lane lands the
hard-float `lp64d` userspace ABI), and the **Linux 6.18** host-headers
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
# from the repo root (rv32 lane; for the rv64 lane substitute
# O=/workspace/linux/build-rv64 and frost_nommu_rv64_defconfig)
./scripts/frost.py run make -C linux/buildroot O=/workspace/linux/build \
  BR2_EXTERNAL=/workspace/linux/buildroot-external frost_nommu_rv32_defconfig
./scripts/frost.py run make -C linux/buildroot O=/workspace/linux/build
```

First build is ~30–60 min per lane (it builds the cross toolchain from
source). Outputs land in `linux/build/images/` (rv32) /
`linux/build-rv64/images/` (rv64):

| File | Purpose |
|---|---|
| `Image` | no-MMU kernel for the lane's XLEN (flat, uncompressed) |
| `rootfs.cpio.gz` | busybox initramfs |
| `frost-nommu-fpga.dtb` | generated FROST device tree (ns16550a UART @ 0x4000_1000, CLINT @ 0x4001_0000; clock/timebase = `FPGA_CPU_CLK_FREQ`, 133.333 MHz genesys2 default) |
| `sw.mem` / `sw.txt` | low-BRAM boot shim (`a0=0`, `a1=DTB`, jump to kernel) |
| `sw_ddr.mem` / `sw_ddr.txt` | DDR image: kernel @ 0x8000_0000, DTB @ 0x8080_0000, initramfs @ 0x8081_0000 |

## Feeding the cocotb `linux_boot` test

`tests/test_run_cocotb.py` resolves an app's images at
`sw/apps/<app>/sw.mem` (+ `sw_ddr.mem`). Stage the build outputs there:

```bash
mkdir -p sw/apps/linux_boot
cp linux/build/images/sw.mem     sw/apps/linux_boot/sw.mem
cp linux/build/images/sw_ddr.mem sw/apps/linux_boot/sw_ddr.mem
# The wrapper runs in the pinned image and cleans tests/ before launching.
./scripts/frost.py cocotb linux_boot
```

Or let the app Makefile self-build straight from this tree (it runs the whole
Buildroot build if the lane's `images/Image` is absent, then packs for the
board clock, then post-processes the images; `FROST_RV64=1` retargets the
whole flow at the rv64 lane) — this is what
`fpga/load_software/load_software.py <board> linux_boot` drives:

```bash
./scripts/frost.py run make -C sw/apps/linux_boot  # genesys2 (133.33 MHz) default
FPGA_CPU_CLK_FREQ=300000000 ./scripts/frost.py run make -C sw/apps/linux_boot
```

Three CI jobs in the main workflow cover the Linux boot, all matrixed over
both lanes. `build-frost-linux` invokes Buildroot directly (not the app
Makefile) and uploads per-lane artifacts (`frost-linux-boot-images` for rv32,
the same name `-rv64`-suffixed for rv64); `linux-boot-cocotb` then runs the
`linux_boot_128k` registry entry on each lane's artifact (the rv64 leg adds
`FROST_RV64=1`) for 22M cycles in the genesys2 shape (128 KiB L1I, L2
disabled — `CACHED_HAS_L2=0` has to come in as an env/make var because the
`tests/Makefile` default overrides the entry's own `-GCACHED_HAS_L2=0`) and
grades the log with `check_linux_boot_regression.py`; `linux-boot-qemu` boots
each lane's `Image` + `rootfs.cpio.gz` under the matching
`qemu-system-riscv{32,64}`. The plain `linux_boot` registry entry is not run
by CI, and both entries carry `include_in_pytest=False`.

## How the kernel config is assembled

`BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG` uses `board/frost/linux-nommu-base.config`
(rv32) or `linux-nommu-base-rv64.config` (rv64) as the base, and
`BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES` merges the shared
`board/frost/linux-nommu-frost.config.fragment` on top (kconfig
`merge_config.sh` semantics; the fragment is XLEN-free — the ARCH choice lives
only in the per-lane base, because fragments apply last and a restatement
would override the other lane's base). The fragment retargets the known-good
QEMU-virt nommu kernel at FROST: it keeps M-mode / no-MMU / bFLT, switches the
rootfs to an initramfs (`BLK_DEV_INITRD` + `RD_GZIP`), and drops
virtio / PCI / net / ext2 / PLIC. See the header of the fragment for the full,
per-symbol rationale and the hardware caveats.

## Notes, assumptions, and gaps

- **Rootfs reproduction.** `rootfs.cpio.gz` is built from the committed
  `board/frost/busybox.config` (BusyBox 1.38.0, overriding Buildroot's
  `busybox-minimal.config` no-MMU default) + `BR2_TARGET_ROOTFS_CPIO[_GZIP]`,
  not vendored. `BR2_ROOTFS_DEVICE_TABLE` applies `board/frost/device_table.txt`
  on top of Buildroot's own `system/device_table.txt` for the static `/dev`
  nodes, and `BR2_ROOTFS_OVERLAY` applies `board/frost/rootfs-overlay/`
  (currently just `etc/inittab`). Extend those files to change the userspace.
- **Userspace boot stress payload.** The `frost-stress` package installs
  `/usr/bin/frost_stress`, run once from the overlay inittab (sysinit, before
  the getty): a timer storm with signal delivery, vfork/exec context
  switching, futex ping-pong over a `MAP_SHARED` file mapping, lock-free
  LR/SC contention between two processes, and Zicntr counter deltas
  (`cycles=`/`instret=`/`time=`/`ipc_x1000=`) around a fixed workload. It
  prints one stats line plus the stable
  `FROST_USERSPACE_STRESS_PASS`/`_FAIL` token; the `linux-boot-qemu`
  CI job and `fpga/linux_boot_soak.py` (hardware) assert the token, so "boots"
  means "reaches PID 1 and userspace demonstrably works", not just the banner.
  Under QEMU the counter phase degrades to `counters=unavailable` (QEMU
  resets `mcounteren` to 0 and the M-mode kernel never sets it; FROST resets
  it to 0x7 — see `linux/README.md`), and the hardware soak fails any boot
  showing that degradation.
  bFLT note: the payload builds with buildroot's riscv FLAT flags (`-fPIC` +
  `-Wl,-elf2flt="-r -s<stack>"`); dropping either leaves the GOT unrelocated
  and the binary SIGSEGVs on its first global store.
- **Image post-processing.** After the packer, `post-image.sh` runs
  `patch_linux_image.py` over the packed `sw_ddr.{mem,txt}` when present:
  mandatory initramfs fixups (seedrng stub, `/dev` nodes) plus env-gated
  bring-up hooks. The `sw/apps/linux_boot` build path runs the same script.
  The `ret_from_exception` restore-window mutation this step formerly applied
  was retired 2026-07-26 — the suspected M-mode restore-window race does not
  exist on the current core (the hangs it fought were the since-fixed
  held-interrupt latch erasure and AMO orphaned-write bugs), and the window's
  interrupt interleavings are pinned by the directed
  `sw/apps/restore_window_stress` regression (see `patch_linux_image.py`'s
  History note).
- **Fragment vs. the most recent hand-built image.** This defconfig *applies*
  the FROST fragment. The most recent hand-built `Image` artifact (built
  outside this repo) came instead from the **stock**
  `qemu_riscv32_nommu_virt_defconfig` *without* the fragment (it still had
  `CONFIG_NET` / `CONFIG_VIRTIO_BLK` / `CONFIG_SIFIVE_PLIC` / `CONFIG_EXT2_FS`
  set). The fragment-applied kernel built here should be the target — it is
  strictly closer to FROST, and the generated DTB has no PLIC/virtio nodes —
  but it does not reproduce that artifact bit-for-bit; drop the fragment only
  if exact reproduction of that artifact is required.
- **Boot shim toolchain.** Standalone, the packer uses the xPack
  `riscv-none-elf-*` bare-metal toolchain with per-XLEN defaults
  (`rv{32,64}i_zicsr` / `ilp32`/`lp64`). In CI `post-image.sh` instead uses
  the Buildroot-built `riscv{32,64}-*-` toolchain with its own default
  `-march`/`-mabi` (the shim is ABI-agnostic integer code).
  `build_fpga_boot.py` derives its XLEN (DTS `rv{32,64}i` isa strings, shim
  defaults) from that cross prefix; set `FROST_XLEN` to override.
- **`dtc`.** `post-image.sh` prefers `$HOST_DIR/bin/dtc`, then the kernel's
  `scripts/dtc/dtc`, then `$PATH`. Enable `BR2_PACKAGE_HOST_DTC=y` if you want
  to guarantee a host `dtc` independent of the kernel build.
