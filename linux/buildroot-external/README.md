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

This tree builds the FROST no-MMU, M-mode rv64 Linux kernel (6.18.7) and a
busybox initramfs, then packages them into the memory images that the cocotb
`linux_boot` test and the FPGA JTAG loader consume. The `-rv64` suffixes on
the defconfig, build directory, CI artifact, and ccache keys date from a
retired rv32 lane; they stay so caches and artifact names remain stable.

It is a standard Buildroot [`BR2_EXTERNAL`](https://buildroot.org/downloads/manual/manual.html#outside-br-custom)
tree and carries no Buildroot source. Use the pinned submodule below.

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

The `linux/buildroot` submodule is pinned to commit `67449130`, a
`2026.08-git` snapshot. Its defaults supply gcc 15.2.0, binutils 2.45.1, the
internal no-MMU rv64 uClibc toolchain with an `lp64d` userspace ABI, and the
Linux 6.18 host-headers option. The pin is a commit rather than a tag so it
cannot move underneath the build.

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

After a bump, confirm the new snapshot still offers `BR2_GCC_VERSION_15_X`
(15.2.0), `BR2_BINUTILS_VERSION_2_45_X` (2.45.1) and
`BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_6_18`. The defconfig sets the headers
symbol and takes gcc and binutils from the snapshot's defaults.

## Build

Build out of tree to keep the submodule pristine:

```bash
# from the repo root
./scripts/frost.py run make -C linux/buildroot O=/workspace/linux/build-rv64 \
  BR2_EXTERNAL=/workspace/linux/buildroot-external frost_nommu_rv64_defconfig
./scripts/frost.py run make -C linux/buildroot O=/workspace/linux/build-rv64
```

The first build takes 30–60 min because it builds the cross toolchain from
source. Outputs land in `linux/build-rv64/images/`:

| File | Purpose |
|---|---|
| `Image` | no-MMU rv64 kernel (flat, uncompressed) |
| `rootfs.cpio.gz` | busybox initramfs |
| `frost-nommu-fpga.dtb` | generated FROST device tree (ns16550a UART @ 0x4000_1000, CLINT @ 0x4001_0000; clock/timebase = `FPGA_CPU_CLK_FREQ`, 300 MHz X3 default) |
| `sw.mem` / `sw.txt` | low-BRAM boot shim (`a0=0`, `a1=DTB`, jump to kernel) |
| `sw_ddr.mem` / `sw_ddr.txt` | DDR image: kernel @ 0x8000_0000, DTB @ 0x8080_0000, initramfs @ 0x8081_0000 |

## Feeding the cocotb `linux_boot` test

`tests/test_run_cocotb.py` takes an app's images from `sw/apps/<app>/sw.mem`
(plus `sw_ddr.mem`) and runs `make clean` then `make` in that app directory
before every run. The `sw/apps/linux_boot` Makefile runs Buildroot if
`linux/build-rv64/images/Image` is absent, then packs and post-processes the
images for the board clock. After a Buildroot build the test therefore runs
directly:

```bash
# The wrapper runs in the pinned image and cleans tests/ before launching.
./scripts/frost.py cocotb linux_boot
```

The same Makefile is what `fpga/load_software/load_software.py <board>
linux_boot` drives:

```bash
./scripts/frost.py run make -C sw/apps/linux_boot  # X3 (300 MHz) default
```

To run images built elsewhere (another checkout, or the CI artifact) in a
tree with no kernel build, stage them and set `FROST_LINUX_PREBUILT=1`. The
Makefile then checks that they exist and re-derives `sw64.mem` from `sw.mem`;
its `make clean` keeps them instead of deleting them and starting a full
Buildroot build:

```bash
cp linux/build-rv64/images/sw.mem     sw/apps/linux_boot/sw.mem
cp linux/build-rv64/images/sw_ddr.mem sw/apps/linux_boot/sw_ddr.mem
FROST_LINUX_PREBUILT=1 ./scripts/frost.py cocotb linux_boot
```

Three CI jobs cover Linux. `build-frost-linux` invokes Buildroot directly and
uploads `frost-linux-boot-images-rv64`. `linux-boot-cocotb` downloads that
artifact, stages it with `FROST_LINUX_PREBUILT=1`, runs the `linux_boot`
registry entry for 22M cycles with the X3 hierarchy (16 KiB L1I and 2 MiB L2),
then grades the log with `tests/check_linux_boot_regression.py`.
`linux-boot-qemu` boots the same `Image` and `rootfs.cpio.gz` with
`qemu-system-riscv64 -M virt -bios none -cpu rv64,mmu=off` and requires the
stress token and the login prompt. The `linux_boot` entry sets
`include_in_pytest=False` and runs only when selected explicitly or by CI.

## How the kernel config is assembled

The base is `board/frost/linux-nommu-base-rv64.config`, a copy of upstream
Buildroot's `board/qemu/riscv64-virt/linux-nommu.config` mini-config, selected
by `BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG`. `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES`
merges `board/frost/linux-nommu-frost.config.fragment` on top with
`merge_config.sh` semantics, so a symbol restated in the fragment overrides the
base. That is why the fragment carries no XLEN symbols: `CONFIG_ARCH_RV64I` and
`CONFIG_64BIT` live only in the base. The fragment keeps M-mode, no-MMU and
bFLT, enables an external initramfs, and unsets virtio, PCI, networking, ext2
and PLIC. Each symbol is commented in the fragment itself.

## Notes, assumptions, and gaps

`rootfs.cpio.gz` is not vendored. Buildroot builds it from the committed
`board/frost/busybox.config` (BusyBox 1.38.0; this replaces Buildroot's
`busybox-minimal.config` no-MMU default) and packs it with
`BR2_TARGET_ROOTFS_CPIO` and `BR2_TARGET_ROOTFS_CPIO_GZIP`.
`BR2_ROOTFS_DEVICE_TABLE` applies `board/frost/device_table.txt` after
Buildroot's own `system/device_table.txt` for the static `/dev` nodes, and
`BR2_ROOTFS_OVERLAY` adds `board/frost/rootfs-overlay/`, currently only
`etc/inittab`. Edit those files to change userspace.

The `frost-stress` package installs `/usr/bin/frost_stress`, which the overlay
inittab runs once as a sysinit entry, before the getty. It runs a timer storm
with signal delivery, vfork/exec context switching, futex ping-pong over a
`MAP_SHARED` file mapping, two processes contending on an LR/SC counter, and
Zicntr counter deltas (`cycles=`, `instret=`, `time=`, `ipc_x1000=`) around a
fixed workload. It prints one stats line followed by
`FROST_USERSPACE_STRESS_PASS` or `FROST_USERSPACE_STRESS_FAIL`. The
`linux-boot-qemu` CI job and `fpga/linux_boot_soak.py` require the pass token,
so they test userspace rather than only the kernel banner. Under QEMU the
counter phase reports `counters=unavailable`: QEMU resets `mcounteren` to 0
and the M-mode kernel never writes it, whereas FROST resets it to 0x7 (see
[`../README.md`](../README.md), "Counters and mcounteren"). The hardware soak
fails any boot that shows that degradation. The payload builds with
Buildroot's riscv FLAT flags, `-fPIC` plus `-Wl,-elf2flt="-r -s<stack>"`;
without either, the GOT is left unrelocated and the binary SIGSEGVs on its
first global store.

After the packer, `post-image.sh` runs `patch_linux_image.py` over the packed
`sw_ddr.{mem,txt}` when they exist. Every run replaces `/etc/init.d/S01seedrng`
with a no-op and adds missing `/dev` nodes; the bring-up hooks are gated by
`FROST_LINUX_*` environment variables. `sw/apps/linux_boot` runs the same
script from its own identical copy. The script's former `ret_from_exception`
mutation was retired on 2026-07-26: the suspected race is absent from the
pinned kernel, the hangs it masked came from interrupt-latch and AMO bugs that
have since been fixed, and `sw/apps/restore_window_stress` covers the relevant
interleavings. The script's history note has the details.

The rv32-era bring-up booted an externally built `Image` from the stock
`qemu_riscv32_nommu_virt_defconfig` without the fragment, so it still had
`CONFIG_NET`, `CONFIG_VIRTIO_BLK`, `CONFIG_SIFIVE_PLIC` and `CONFIG_EXT2_FS`
set. The current kernel applies the fragment and its DT has no PLIC or virtio
nodes; reproducing that artifact bit-for-bit was never a goal.

Standalone, `build_fpga_boot.py` uses the xPack `riscv-none-elf-` bare-metal
toolchain and builds the shim with `-march=rv64i_zicsr -mabi=lp64`
(`FROST_SHIM_MARCH` and `FROST_SHIM_MABI` override these). In the Buildroot
flow `post-image.sh` points it at the Buildroot-built `riscv64-*-` toolchain
and clears both variables, so that toolchain's own default `-march`/`-mabi`
apply; the shim is plain integer code and does not depend on the ABI. The
packer is hardcoded to rv64: `XLEN = 64` fills the DTS `rv64i*` isa strings,
and the shim defaults above are rv64 literals.

`post-image.sh` looks for `dtc` in `$HOST_DIR/bin`, then in the kernel's
`scripts/dtc/dtc`, then on `$PATH`. Set `BR2_PACKAGE_HOST_DTC=y` to guarantee
a host `dtc` that does not depend on the kernel build.
