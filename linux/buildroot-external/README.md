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

This Buildroot external tree builds FROST's OpenSBI firmware and a small
BusyBox/musl test userspace, then packs them with Debian's pinned kernel and
the FROST NIC module into the images the JTAG loader writes to the board.
Buildroot compiles no kernel here. At boot, the test initramfs loads the NIC
module and runs FROST's userspace stress tests before the login prompt.

For the boot interface, memory map, and kernel requirements, see the
[Linux reference](../README.md). For a full Debian system, see the
[NFS-root setup guide](../../docs/debian_nfsroot.md).

## Layout

| Path | Purpose |
| --- | --- |
| `external.desc`, `external.mk`, `Config.in` | Buildroot external-tree registration |
| `configs/frost_rv64_defconfig` | OpenSBI and the musl test userspace, built with the Bootlin riscv64 `lp64d` toolchain |
| `package/frost-stress/` | Boot stress, signal-return, and NIC loopback programs |
| `board/frost/busybox-mmu.fragment` | BusyBox configuration (statically linked) |
| `board/frost/rootfs-overlay-mmu/` | Startup scripts and login configuration |
| `board/frost/post-image-mmu.sh` | Builds the firmware, stages Debian's kernel and the NIC module, and packs the images |
| `board/frost/frost_boot_image.py` | Packs firmware, kernel, device tree, and optional initramfs for the JTAG loader |
| `board/frost/frost,net10g.yaml` | NIC device-tree binding |

## Toolchain

Initialize the submodules before a native build. The defconfig's toolchain
URL and the hash in `patches/toolchain-external-custom/` must name the same
Bootlin musl archive as the Dockerfile. After changing Buildroot or the
compiler, use a fresh output directory: Buildroot cannot switch compilers
inside an existing one.

## Build

From the repository root, build in a separate output directory:

```bash
./scripts/frost.py run make -C linux/buildroot O=/workspace/linux/build-mmu \
  BR2_EXTERNAL=/workspace/linux/buildroot-external frost_rv64_defconfig
./scripts/frost.py run make -C linux/buildroot O=/workspace/linux/build-mmu \
  BR2_EXTERNAL=/workspace/linux/buildroot-external
```

The first build downloads the external toolchain. Outputs land in
`linux/build-mmu/images/`:

| File | Purpose |
| --- | --- |
| `Image-debian` | Flat, uncompressed Debian kernel |
| `rootfs-frost.cpio` | Test initramfs with the NIC module and its startup script |
| `rootfs.cpio` | Base BusyBox/musl initramfs, uncompressed |
| `fw_jump.bin` | OpenSBI firmware |
| `frost.dtb` | Device tree, generated for the selected clock and memory size |
| `sw.mem` / `sw.txt` | Low-BRAM boot shim |
| `sw_ddr.mem` / `sw_ddr.txt` | DDR image containing firmware, kernel, device tree, and initramfs |

## Packing the images for a board

The loader builds any missing component and packs the images for the board's
clock and DDR size:

```bash
./fpga/load_software/load_software.py x3 linux_boot
```

It sets `FPGA_CPU_CLK_FREQ` and `FROST_LINUX_MEM_SIZE` (1 GiB on X3). A
standalone build defaults to 322.265625 MHz and 64 MiB:

```bash
./scripts/frost.py run make -C sw/apps/linux_boot
```

For Debian over NFS, give the export and its matching kernel and initramfs:

```bash
FROST_LINUX_NFSROOT=192.0.2.1:/srv/nfs/debian \
FROST_LINUX_KERNEL=/srv/nfs/debian/boot/vmlinux-<version> \
FROST_LINUX_INITRD=/srv/nfs/debian/boot/initrd.img-<version> \
  ./fpga/load_software/load_software.py x3 linux_boot
```

Use absolute paths; under `./scripts/frost.py run` they must be inside
`/workspace`, where the checkout is mounted. `FROST_LINUX_IP` sets the
kernel's `ip=` (default `dhcp`) and `FROST_LINUX_MAC` the board's MAC, which
must be unique on a shared network. The [NFS root options](../README.md#nfs-root)
cover these variables and what an NFS boot needs from the kernel.

To load images built elsewhere, stage them and set `FROST_LINUX_PREBUILT=1`:

```bash
cp <elsewhere>/sw.mem     sw/apps/linux_boot/sw.mem
cp <elsewhere>/sw_ddr.mem sw/apps/linux_boot/sw_ddr.mem
FROST_LINUX_PREBUILT=1 ./fpga/load_software/load_software.py x3 linux_boot
```

The loader's clean step then keeps the staged files, and the build skips
Buildroot. The images must already match the board's clock and DDR size.

## The kernel and the NIC driver

[`debian_kernel.py`](../debian_kernel.py) fetches and verifies the pinned
Debian kernel, builds the [NIC module](../frost-net10g/README.md) against its
headers, and adds the module to the test initramfs. The
[kernel](../README.md#kernel) and [module](../README.md#nic-module) sections
of the Linux reference describe its commands.

CI builds these images and boots them under QEMU. On the X3,
`fpga/linux_boot_soak.py` boots the test image repeatedly, and the hardware
regression's `linux_boot` stage boots Debian from NFS with this tree's
OpenSBI. RTL simulation does not boot Linux.

## Test programs

| Program | Purpose |
| --- | --- |
| `frost_stress` | Boot-time stress of signals, process and memory operations, futexes, and atomics; prints `FROST_USERSPACE_STRESS_PASS` or `FROST_USERSPACE_STRESS_FAIL` |
| `frost_stress --counters` | Runs a fixed workload in a child process and reports its cycles and instructions (counted through `perf_event_open` from the child's exec to its exit), the elapsed time, and IPC; replaces `perf stat` in this image |
| `frost_sigprobe` | vDSO signal-return probe |
| `frost_nettest` | Driver loopback test; prints `FROST_NET_LOOPBACK_PASS` or `FROST_NET_LOOPBACK_FAIL <reason>` and leaves the interface down with loopback disabled |

`fpga/linux_boot_soak.py` fails a boot that passes the stress test but
reports `counters=unavailable`; see
[counter access](../README.md#counters-and-mcounteren).

## Notes

- Customize userspace in `busybox-mmu.fragment` and `rootfs-overlay-mmu/`.
  The test initramfs does no IP networking; `frost_nettest` uses packet
  sockets.
- Buildroot does not notice an edited package source. After changing
  `package/frost-stress/src/`, rebuild with `frost-stress-rebuild` and
  regenerate the images; the `sw/apps/linux_boot` Makefile does both
  automatically. The hardware regression builds its own static copies of
  these programs for the Debian NFS root.
- A Buildroot output directory records absolute paths, so do not share one
  between Docker and native builds, or between checkouts. Later invocations
  reuse the `BR2_EXTERNAL` saved by the defconfig step.
- After removing packages from the configuration, recreate the output tree.
  Rerunning the defconfig alone leaves the old packages in the rootfs.
- Image packing needs `dtc`. The `frost` image has it; elsewhere, install it
  or set `BR2_PACKAGE_HOST_DTC=y`.
