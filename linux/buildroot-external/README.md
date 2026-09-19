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

This tree builds the FROST Linux lane and packages it into the memory images
that the cocotb `linux_boot` test and the FPGA JTAG loader consume:

- `frost_rv64_defconfig`: the mainline Sv39 kernel (6.18.7 with the NIC
  driver from `../frost-net10g`, `board/frost/linux-frost.config`) under
  OpenSBI fw_jump, with a musl ELF userspace (static busybox, `frost-stress`,
  `perf` with elfutils) on the Bootlin riscv64 external toolchain, packed with
  `board/frost/frost_boot_image.py` from `post-image-mmu.sh` (which also
  builds the firmware from the `linux/opensbi` submodule via
  `linux/opensbi_build.py`). Build it with `O=linux/build-mmu`.

The no-MMU M-mode lane was retired in Phase 3, along with its defconfig,
kernel configs, packer and CI jobs; this is the only lane.

It is a standard Buildroot [`BR2_EXTERNAL`](https://buildroot.org/downloads/manual/manual.html#outside-br-custom)
tree and carries no Buildroot source. Use the pinned submodule below.

## Layout

```
linux/buildroot-external/
├── external.desc                          # BR2_EXTERNAL manifest (name: FROST)
├── external.mk                            # package include hook; installs ../frost-net10g into the kernel tree
├── Config.in                              # package menu hook
├── configs/
│   └── frost_rv64_defconfig               # Buildroot defconfig (OpenSBI + Sv39, musl, perf)
├── package/frost-stress/                  # userspace boot stress payload and test programs (see below)
│   ├── Config.in
│   ├── frost-stress.mk
│   └── src/
│       ├── frost_stress.c                 # boot stress payload (inittab)
│       ├── frost_sigprobe.c               # signal-return probe (inittab)
│       └── frost_nettest.c                # NIC driver loopback test (hardware regression)
└── board/frost/
    ├── linux-frost.config                 # kernel mini-config (olddefconfig fills the rest)
    ├── busybox-mmu.fragment               # static busybox on top of Buildroot's default config
    ├── rootfs-overlay-mmu/etc/            # overlay: inittab (devtmpfs, rcS, frost_stress, getty), no-op S01seedrng
    ├── post-image-mmu.sh                  # post-image hook: OpenSBI build + frost_boot_image.py
    ├── frost_boot_image.py                # packer: fw_jump + payload/Image + DTB [+ initramfs] (see ../../README.md)
    ├── frost,net10g.yaml                  # DT binding of the NIC node the packer emits
    └── patches/                           # BR2_GLOBAL_PATCH_DIR
        └── linux/
            ├── linux.hash                 # sha256 for the custom linux-6.18.7 tarball (BR2_DOWNLOAD_FORCE_CHECK_HASHES)
            └── 0001-net-ethernet-hook-in-the-FROST-net10g-driver.patch # adds drivers/net/ethernet/frost/ to the kernel build
```

## Buildroot pin

The `linux/buildroot` submodule is pinned to commit `67449130`, a
`2026.08-git` snapshot. The target toolchain is not built from source: the
defconfig selects the external Bootlin riscv64 `lp64d` musl release. The pin
is a commit rather than a tag so it cannot move underneath the build.

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

After a bump, confirm the new snapshot still offers
`BR2_TOOLCHAIN_EXTERNAL_BOOTLIN_RISCV64_LP64D_MUSL_STABLE` and the custom
kernel version the defconfig pins.

## Build

Build out of tree to keep the submodule pristine:

```bash
# from the repo root
./scripts/frost.py run make -C linux/buildroot O=/workspace/linux/build-mmu \
  BR2_EXTERNAL=/workspace/linux/buildroot-external frost_rv64_defconfig
./scripts/frost.py run make -C linux/buildroot O=/workspace/linux/build-mmu
```

The first build takes 30–60 min. Outputs land in `linux/build-mmu/images/`:

| File | Purpose |
|---|---|
| `Image` | Sv39 rv64 kernel (flat, uncompressed) |
| `rootfs.cpio` | musl busybox initramfs, uncompressed (a gzip'd one costs the simulated core tens of cycles per byte to inflate) |
| `fw_jump.bin` | OpenSBI firmware, built by `post-image-mmu.sh` from the `linux/opensbi` submodule |
| `frost.dtb` | generated FROST device tree (ns16550a UART @ 0x4000_1000, CLINT @ 0x4001_0000, PLIC; clock/timebase = `FPGA_CPU_CLK_FREQ`, 300 MHz X3 default; 64 MiB of memory, the simulation DDR model's size) |
| `sw.mem` / `sw.txt` | low-BRAM boot shim (`a0=0`, `a1=DTB`, jump to fw_jump) |
| `sw_ddr.mem` / `sw_ddr.txt` | DDR image: firmware @ 0x8000_0000, Image @ +2 MiB, DTB @ the first 2 MiB boundary at or above +16 MiB and the Image's end, initramfs after it |

## Feeding the cocotb `linux_boot` test

`tests/test_run_cocotb.py` takes an app's images from `sw/apps/<app>/sw.mem`
(plus `sw_ddr.mem`) and runs `make clean` then `make` in that app directory
before every run. The `sw/apps/linux_boot` Makefile runs Buildroot if
`linux/build-mmu/images/Image` is absent, then packs the images for the board
clock. After a Buildroot build the test therefore runs directly:

```bash
# The wrapper runs in the pinned image and cleans tests/ before launching.
./scripts/frost.py cocotb linux_boot
```

The same Makefile is what `fpga/load_software/load_software.py <board>
linux_boot` drives. The loader sets the board's clock (`FPGA_CPU_CLK_FREQ`) and
DDR size (`FROST_LINUX_MEM_SIZE`: the CPU's range in
`fpga/build/<board>_ddr_bd.tcl`, 1 GiB on the X3); without them the Makefile
packs for the X3 clock and the simulation model's 64 MiB, and cocotb builds
never take a board's memory size (`sw/apps/compile_app.py`):

```bash
./scripts/frost.py run make -C sw/apps/linux_boot  # X3 (300 MHz) default
```

`FROST_LINUX_NFSROOT=<server-ip>:/<path>` packs an NFS-root image instead:
bootargs that mount that export as the root, with the interface configured
from `FROST_LINUX_IP` (`ip=` in the kernel's syntax, `dhcp` by default), and
by default no initramfs, so the kernel mounts it. `FROST_LINUX_KERNEL` and
`FROST_LINUX_INITRD` pack another kernel `Image` and initramfs, such as
Debian's, in place of Buildroot's `Image` and `rootfs.cpio`; the firmware
still comes from this build. Give them as absolute paths (under `/workspace`
in `./scripts/frost.py run`, which sees only the checkout). With
`FROST_LINUX_NFSROOT` too, that initramfs mounts the export through
initramfs-tools' NFS boot (`boot=nfs`), which Debian's kernel needs.
`FROST_LINUX_MAC=aa:bb:cc:dd:ee:ff` sets the NIC's MAC address in any image;
each board on a shared network needs its own locally administered address
([`../README.md`](../README.md), "NFS root"). `load_software.py` passes them
all through from the environment:

```bash
FROST_LINUX_NFSROOT=192.0.2.1:/srv/nfs/debian \
  ./fpga/load_software/load_software.py x3 linux_boot
# Debian's own kernel and initramfs, from the export's /boot:
FROST_LINUX_NFSROOT=192.0.2.1:/srv/nfs/debian \
FROST_LINUX_KERNEL=/srv/nfs/debian/boot/vmlinux-<version> \
FROST_LINUX_INITRD=/srv/nfs/debian/boot/initrd.img-<version> \
  ./fpga/load_software/load_software.py x3 linux_boot
```

To run images built elsewhere (another checkout, or the CI artifact) in a
tree with no kernel build, stage them and set `FROST_LINUX_PREBUILT=1`. The
Makefile then checks that they exist and re-derives `sw64.mem` from `sw.mem`;
its `make clean` keeps them instead of deleting them and starting a full
Buildroot build:

```bash
cp linux/build-mmu/images/sw.mem     sw/apps/linux_boot/sw.mem
cp linux/build-mmu/images/sw_ddr.mem sw/apps/linux_boot/sw_ddr.mem
FROST_LINUX_PREBUILT=1 ./scripts/frost.py cocotb linux_boot
```

Three CI jobs cover Linux. `build-frost-linux-mmu` invokes Buildroot directly
and uploads `frost-linux-boot-images-mmu`. `linux-boot-cocotb-mmu` downloads
that artifact, stages it with `FROST_LINUX_PREBUILT=1`, and runs the
`linux_boot` registry entry with the X3 hierarchy (16 KiB L1I and 2 MiB L2).
`linux-boot-qemu-mmu` boots the same `Image` and `rootfs.cpio` under
`qemu-system-riscv64 -M virt`, with both QEMU's bundled OpenSBI and the FROST
firmware, and requires the stress token and the login prompt. The `linux_boot`
entry sets `include_in_pytest=False` and runs only when selected explicitly or
by CI.

## How the kernel config is assembled

`BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG` points at
`board/frost/linux-frost.config`, a mini-config rather than a full defconfig:
Buildroot runs `olddefconfig` over it, so unlisted symbols take their
architecture defaults. It sets `CONFIG_MMU`, `CONFIG_RISCV_SBI`, the SBI PMU,
emulated misaligned access, an external initramfs, the NFS root, ELF
userspace, the cgroups and AF_UNIX sockets systemd requires, the 8250 console,
packet sockets, IPv4 with `ip=` configuration (static or DHCP) and the NIC
driver, and it leaves `CONFIG_IPV6`, `CONFIG_NONPORTABLE` and
`CONFIG_RISCV_M_MODE` unset.
`tests/test_linux_packaging.py` asserts those load-bearing symbols and
that the file uses Kconfig syntax `olddefconfig` understands. Each symbol is
commented in the config itself; the contract is in
[`../README.md`](../README.md), "Kernel configuration contract".

The NIC driver (`CONFIG_FROST_NET10G`) is not in mainline. Its one source
is [`../frost-net10g`](../frost-net10g/README.md), which is also the DKMS
package that builds it as a module for Debian's kernels. Two pieces put it
into this kernel. The patch
`board/frost/patches/linux/0001-net-ethernet-hook-in-the-FROST-net10g-driver.patch`
adds `drivers/net/ethernet/frost/` to the kernel's `drivers/net/ethernet`
Kconfig and Makefile. Buildroot applies every `*.patch` in that directory
when it extracts the kernel (`BR2_GLOBAL_PATCH_DIR`), so a changed patch
needs the `linux-dirclean` target before the next build. Then `external.mk`
installs the driver's `Kconfig`, `Makefile` and `frost_net10g.c` into that
directory after patching (`LINUX_POST_PATCH_HOOKS`), and `frost_net10g.c` and
`Makefile` again before every kernel build (`LINUX_PRE_BUILD_HOOKS`), so the
`linux-rebuild` target picks up an edited driver. The kernel configuration
reads `Kconfig` before any build step, so an edited `Kconfig`, like a changed
patch, needs `linux-dirclean`. `legal-info` saves the three files and the
driver's README next to the kernel's tarball and patches
(`LINUX_POST_LEGAL_INFO_HOOKS`). Refresh the
patch when the pinned kernel version changes.
`tests/test_frost_net10g_driver.py` checks that the patch, the hooks and the
driver directory agree.

## Notes, assumptions, and gaps

`rootfs.cpio` is not vendored. Buildroot builds it from its default BusyBox
config plus `board/frost/busybox-mmu.fragment` (static busybox: every
init-time exec is one page-fault storm cheaper in simulation) and packs it
with `BR2_TARGET_ROOTFS_CPIO` and `BR2_TARGET_ROOTFS_CPIO_NONE`.
`BR2_ROOTFS_OVERLAY` adds `board/frost/rootfs-overlay-mmu/`: the inittab
(devtmpfs, `rcS`, `frost_stress`, getty) and a no-op `S01seedrng`. Edit those
files to change userspace. The initramfs does no IP networking
(`frost_nettest` uses packet sockets), so `BR2_PACKAGE_IFUPDOWN_SCRIPTS` stays
unset.

The `frost-stress` package installs `/usr/bin/frost_stress`, which the overlay
inittab runs once as a sysinit entry, before the getty. It runs a timer storm
with signal delivery, `fork`+`exec` and a copy-on-write child, `mmap` phases,
futex ping-pong, two processes contending on an LR/SC counter, and counter
deltas (`cycles=`, `instret=`, `time=`, `ipc_x1000=`) around a fixed workload,
read through `perf_event_open`. It prints one stats line followed by
`FROST_USERSPACE_STRESS_PASS` or `FROST_USERSPACE_STRESS_FAIL`. The
`linux-boot-qemu-mmu` CI job and `fpga/linux_boot_soak.py` require the pass
token, so they test userspace rather than only the kernel banner. Under QEMU
the counter phase reports `counters=unavailable`: QEMU resets `mcounteren` to
0 (see [`../README.md`](../README.md), "Counters and mcounteren"). The
hardware soak fails any boot that shows that degradation. The same package
also installs `frost_sigprobe`, the vDSO signal-return bring-up probe, and
`frost_nettest`, which the hardware regression's Linux stage types after
logging in. It drives the `frost_net10g` driver through the driver's loopback
feature (the NIC's raw MAC loopback when both MAC directions share a clock, the
transceiver's PMA loopback otherwise): MTU 9000, frame lengths 14 to 9014
bytes, a 300-frame burst, a down during a burst, loopback off and on again, and
the driver's statistics. Nothing is judged while loopback is off, since a link
partner may raise the carrier and send frames then. It leaves the interface
down with loopback off and prints `FROST_NET_LOOPBACK_PASS` or
`FROST_NET_LOOPBACK_FAIL <reason>`.

`post-image-mmu.sh` runs after the image stage. It locates
`riscv64-linux-gcc` in `$HOST_DIR/bin`, finds `dtc` in `$HOST_DIR/bin`, then
the kernel's `scripts/dtc/dtc`, then `$PATH`, builds the firmware through
`linux/opensbi_build.py`, and packs `fw_jump.bin`, the kernel `Image`, the
generated DTB and the initramfs with `frost_boot_image.py`. Set
`BR2_PACKAGE_HOST_DTC=y` to guarantee a host `dtc` that does not depend on the
kernel build.
