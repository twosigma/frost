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

This tree builds the FROST Linux lane's firmware and test userspace, and
packages them, with Debian's kernel, into the memory images that the FPGA JTAG
loader consumes:

- `frost_rv64_defconfig`: OpenSBI fw_jump and a musl ELF userspace (static
  busybox, `frost-stress`) on the Bootlin riscv64 external toolchain, packed
  with `board/frost/frost_boot_image.py` from `post-image-mmu.sh` (which also
  builds the firmware from the `linux/opensbi` submodule via
  `linux/opensbi_build.py`, and stages Debian's kernel and the NIC module built
  for it via `../debian_kernel.py`). Build it with `O=linux/build-mmu`.

No kernel is built here. FROST boots Debian's own pinned kernel
([`../README.md`](../README.md), "Kernel"), so this tree carries no kernel
configuration, no kernel patches and no `perf` (which builds only against a
kernel tree; `frost_stress` reads the counters through `perf_event_open`
instead).

The no-MMU M-mode lane was retired in Phase 3, along with its defconfig,
kernel configs, packer and CI jobs; this is the only lane.

It is a standard Buildroot [`BR2_EXTERNAL`](https://buildroot.org/downloads/manual/manual.html#outside-br-custom)
tree and carries no Buildroot source. Use the pinned submodule below.

## Layout

```
linux/buildroot-external/
├── external.desc                          # BR2_EXTERNAL manifest (name: FROST)
├── external.mk                            # package include hook
├── Config.in                              # package menu hook
├── configs/
│   └── frost_rv64_defconfig               # Buildroot defconfig (OpenSBI + musl test userspace, no kernel)
├── package/frost-stress/                  # userspace boot stress payload and test programs (see below)
│   ├── Config.in
│   ├── frost-stress.mk
│   └── src/
│       ├── frost_stress.c                 # boot stress payload (inittab)
│       ├── frost_sigprobe.c               # signal-return probe (inittab)
│       └── frost_nettest.c                # NIC driver loopback test (hardware regression)
└── board/frost/
    ├── busybox-mmu.fragment               # static busybox on top of Buildroot's default config
    ├── rootfs-overlay-mmu/etc/            # overlay: inittab (devtmpfs, rcS, frost_stress, getty), no-op S01seedrng
    ├── post-image-mmu.sh                  # post-image hook: OpenSBI build + Debian kernel staging + frost_boot_image.py
    ├── frost_boot_image.py                # packer: fw_jump + payload/Image + DTB [+ initramfs] (see ../../README.md)
    └── frost,net10g.yaml                  # DT binding of the NIC node the packer emits
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
`BR2_TOOLCHAIN_EXTERNAL_BOOTLIN_RISCV64_LP64D_MUSL_STABLE`.

## Build

Build out of tree to keep the submodule pristine:

```bash
# from the repo root
./scripts/frost.py run make -C linux/buildroot O=/workspace/linux/build-mmu \
  BR2_EXTERNAL=/workspace/linux/buildroot-external frost_rv64_defconfig
./scripts/frost.py run make -C linux/buildroot O=/workspace/linux/build-mmu
```

The first build takes a few minutes, most of it downloading the Bootlin
toolchain; no kernel is compiled. Outputs land in `linux/build-mmu/images/`:

| File | Purpose |
|---|---|
| `Image-debian` | Debian's Sv39 rv64 kernel (flat, uncompressed), staged from `../debian-kernel` by `post-image-mmu.sh`: the packed payload |
| `rootfs-frost.cpio` | `rootfs.cpio` with the NIC module and the `/etc/init.d` script that insmods it appended: the packed initramfs |
| `rootfs.cpio` | musl busybox initramfs, uncompressed (inflating a gzip'd one costs the core tens of cycles per byte at boot) |
| `fw_jump.bin` | OpenSBI firmware, built by `post-image-mmu.sh` from the `linux/opensbi` submodule |
| `frost.dtb` | generated FROST device tree (ns16550a UART @ 0x4000_1000, CLINT @ 0x4001_0000, PLIC; clock/timebase = `FPGA_CPU_CLK_FREQ`, 300 MHz X3 default; 64 MiB of memory by default, the board's DDR size when `load_software.py` packs it) |
| `sw.mem` / `sw.txt` | low-BRAM boot shim (`a0=0`, `a1=DTB`, jump to fw_jump) |
| `sw_ddr.mem` / `sw_ddr.txt` | DDR image: firmware @ 0x8000_0000, Image @ +2 MiB, DTB @ the first 2 MiB boundary at or above +16 MiB and the Image's end, initramfs after it |

## Packing the images for a board

The `sw/apps/linux_boot` Makefile runs Buildroot if
`linux/build-mmu/images/rootfs.cpio` is absent, fetches Debian's kernel and
builds the NIC module into a copy of that initramfs if
`linux/debian-kernel` has no kernel, then packs the images for the board
clock. `fpga/load_software/load_software.py <board> linux_boot` drives that
Makefile: the loader sets the board's clock (`FPGA_CPU_CLK_FREQ`) and DDR size
(`FROST_LINUX_MEM_SIZE`: the CPU's range in `fpga/build/<board>_ddr_bd.tcl`,
1 GiB on the X3). Without them the Makefile packs for the X3 clock and the
packer's default 64 MiB, which is also what a plain `make` produces
(`sw/apps/compile_app.py` keeps a board's memory size out of such a build):

```bash
./scripts/frost.py run make -C sw/apps/linux_boot  # X3 (300 MHz) default
```

`FROST_LINUX_NFSROOT=<server-ip>:/<path>` packs an NFS-root image instead:
bootargs that mount that export as the root, with the interface configured
from `FROST_LINUX_IP` (`ip=` in the kernel's syntax, `dhcp` by default), and
by default no initramfs, so the kernel mounts it -- which needs a kernel with
`CONFIG_IP_PNP` and `CONFIG_ROOT_NFS`, not Debian's. `FROST_LINUX_KERNEL` and
`FROST_LINUX_INITRD` pack another kernel `Image` and initramfs in place of
Debian's `Image` and the test initramfs; the firmware
still comes from this build. Give them as absolute paths (under `/workspace`
in `./scripts/frost.py run`, which sees only the checkout). With
`FROST_LINUX_NFSROOT` too, that initramfs mounts the export through
initramfs-tools' NFS boot (`boot=nfs`), which is how a Debian root boots.
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

To load images built elsewhere (another checkout, or a machine that can run
Buildroot) in a tree with no Buildroot build, stage them and set
`FROST_LINUX_PREBUILT=1`. The Makefile then checks that they exist and
re-derives `sw64.mem` from `sw.mem`; its `make clean`, which the loader runs
before every load, keeps them instead of deleting them and starting a full
Buildroot build:

```bash
cp <elsewhere>/sw.mem     sw/apps/linux_boot/sw.mem
cp <elsewhere>/sw_ddr.mem sw/apps/linux_boot/sw_ddr.mem
FROST_LINUX_PREBUILT=1 ./fpga/load_software/load_software.py x3 linux_boot
```

Two CI jobs cover Linux. `build-frost-linux-mmu` invokes Buildroot directly
(its post-image hook fetches Debian's kernel and packs the board images, so a
broken packer fails the job) and uploads `frost-linux-boot-images-mmu`.
`linux-boot-qemu-mmu` boots that artifact's `Image-debian` and
`rootfs-frost.cpio` under `qemu-system-riscv64 -M virt`, with
both QEMU's bundled OpenSBI and the FROST firmware, and requires the NIC
module's load token, the stress token and the login prompt. Booting the kernel
on the FROST RTL is retired:
the boot gate is the hardware regression's Linux stage
(`fpga/hw_regression.py --board x3 linux_boot`) and the board soaks
(`fpga/linux_boot_soak.py`), and there is no `linux_boot` cocotb entry
([`../README.md`](../README.md), "Consumers").

## The kernel and the NIC driver

No kernel is built here. The kernel is Debian's, pinned, fetched and verified by
[`../debian_kernel.py`](../debian_kernel.py) ([`../README.md`](../README.md),
"Kernel"); the kernel contract this tree's images have to satisfy -- entry
state, memory map, DT nodes -- is in [`../README.md`](../README.md).

The NIC driver (`CONFIG_FROST_NET10G`) is not in mainline, and Debian's kernel
has no FROST driver, so it travels as a module. Its one source is
[`../frost-net10g`](../frost-net10g/README.md), which is also the DKMS package
that builds it as a module for Debian's kernels. The post-image hook builds it
the same way: `../debian_kernel.py` compiles it against the pinned kernel's
headers and appends it, with the init script that loads it, to this tree's
`rootfs.cpio` ([`../README.md`](../README.md), "NIC module"). No kernel tree is
patched and no driver files are installed into one.
`tests/test_frost_net10g_driver.py` checks that the driver, its DKMS packaging
and that build agree.

## Notes, assumptions, and gaps

`rootfs.cpio` is not vendored. Buildroot builds it from its default BusyBox
config plus `board/frost/busybox-mmu.fragment` (static busybox: every
init-time exec is one page-fault storm cheaper) and packs it with
`BR2_TARGET_ROOTFS_CPIO` and `BR2_TARGET_ROOTFS_CPIO_NONE`.
`BR2_ROOTFS_OVERLAY` adds `board/frost/rootfs-overlay-mmu/`: the inittab
(devtmpfs, `rcS`, `frost_stress`, getty) and a no-op `S01seedrng`. Edit those
files to change userspace. The initramfs does no IP networking
(`frost_nettest` uses packet sockets), so `BR2_PACKAGE_IFUPDOWN_SCRIPTS` stays
unset.

The `frost-stress` package installs `/usr/bin/frost_stress`, which the overlay
inittab runs once as a sysinit entry, before the getty. Buildroot does not
notice an edit to the package's sources on its own, so the `sw/apps/linux_boot`
Makefile names them as prerequisites of `rootfs.cpio` and runs
`frost-stress-rebuild` when they are newer; editing them by hand in a Buildroot
build needs that target too, or the cached `rootfs.cpio` keeps the old programs.
The packer refuses an archive whose `frost_stress` predates the counter mode, so
a stale one cannot reach a board soak or CI. The hardware regression boots the
Debian NFS root instead, and cross-compiles these same sources into it before
every run ([`../../fpga/README.md`](../../fpga/README.md), "Hardware
regression"), so an edit here reaches that stage without any Buildroot step.

A build directory configured before this tree stopped building a kernel cannot
be reused. Its `.config` still selects `BR2_LINUX_KERNEL` and points
`BR2_GLOBAL_PATCH_DIR` at the deleted `board/frost/patches`, so Buildroot stops
with `BR2_GLOBAL_PATCH_DIR contains nonexistent directory` before it runs
anything. Re-running the defconfig over it would clear those symbols but leave
`perf` and elfutils installed in `target/`, since Buildroot does not uninstall a
deselected package, so start over instead:
`make -C sw/apps/linux_boot distclean`, or delete the `O=` directory. The
`linux_boot` Makefile detects such a directory and says so rather than letting
Buildroot fail obscurely.

One build directory belongs to one view of the checkout. `make <defconfig>`
writes `BR2_EXTERNAL_FROST_PATH` into `.config` as an absolute path, and passing
`BR2_EXTERNAL` later does not move it, so a directory configured in the
container (`/workspace/...`) cannot be built from a native loader or the
reverse. Every Buildroot invocation still has to pass `BR2_EXTERNAL`: the
directory's record of it is regenerated from that variable, and one call without
it leaves the tree with no external tree at all. The `linux_boot` Makefile does
both -- it passes the variable everywhere and reports a directory configured
elsewhere rather than silently reconfiguring it.

`frost_stress` runs a timer storm
with signal delivery, `fork`+`exec` and a copy-on-write child, `mmap` phases,
futex ping-pong, two processes contending on an LR/SC counter, and counter
deltas (`cycles=`, `instret=`, `time=`, `ipc_x1000=`) around a fixed workload,
read through `perf_event_open`. It prints one stats line followed by
`FROST_USERSPACE_STRESS_PASS` or `FROST_USERSPACE_STRESS_FAIL`. The
`linux-boot-qemu-mmu` CI job and `fpga/linux_boot_soak.py` require the pass
token, so they test userspace rather than only the kernel banner. The counter
phase reports counts on FROST and under QEMU alike (the SBI PMU's fixed
counters; see [`../README.md`](../README.md), "Counters and mcounteren"), and
the hardware soak fails any boot that reports `counters=unavailable`.
`frost_stress --counters` prints the same counters for a child measured from its
exec to its exit, as the `perf stat <command>` it replaced did; the hardware
regression's Linux stage types it after logging in and requires that scope, from
a static build of this source installed on the Debian root -- the binaries here
are linked against musl, which that root has no loader for. The same package also
installs `frost_sigprobe`, the vDSO signal-return bring-up probe, and
`frost_nettest`, which the stage types last.
It drives the `frost_net10g` driver through the driver's loopback
feature (the NIC's raw MAC loopback when both MAC directions share a clock, the
transceiver's PMA loopback otherwise): MTU 9000, frame lengths 14 to 9014
bytes, a 300-frame burst, a down during a burst, loopback off and on again, and
the driver's statistics. Nothing is judged while loopback is off, since a link
partner may raise the carrier and send frames then. It leaves the interface
down with loopback off and prints `FROST_NET_LOOPBACK_PASS` or
`FROST_NET_LOOPBACK_FAIL <reason>`.

`post-image-mmu.sh` runs after the image stage. It locates
`riscv64-linux-gcc` in `$HOST_DIR/bin`, finds `dtc` in `$HOST_DIR/bin` and then
`$PATH`, builds the firmware through
`linux/opensbi_build.py`, stages `Image-debian` and composes
`rootfs-frost.cpio` through `../debian_kernel.py` (which builds the NIC module
with the toolchain it just located), and packs `fw_jump.bin`, `Image-debian`,
the generated DTB and `rootfs-frost.cpio` with `frost_boot_image.py`. There is
no kernel tree to borrow `scripts/dtc/dtc` from any more, so a host without
`dtc` (the frost image installs `device-tree-compiler`) needs
`BR2_PACKAGE_HOST_DTC=y`.
