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

Builds OpenSBI firmware and a small BusyBox/musl test userspace for FROST's
RV64 Linux system. The images include Debian's pinned kernel and the FROST
NIC module; Buildroot does not compile a kernel here.

For the boot ABI, memory map, and kernel requirements, see the
[Linux guide](../README.md). For a full Debian installation, see the
[NFS-root setup guide](../../docs/debian_nfsroot.md).

## Layout

| Path | Purpose |
| --- | --- |
| `external.desc`, `external.mk`, `Config.in` | Buildroot external-tree registration |
| `configs/frost_rv64_defconfig` | OpenSBI and static musl test userspace on the Bootlin riscv64 `lp64d` toolchain |
| `package/frost-stress/` | Boot stress, signal-return, and NIC loopback programs |
| `board/frost/busybox-mmu.fragment` | BusyBox configuration |
| `board/frost/rootfs-overlay-mmu/` | Startup scripts and login configuration |
| `board/frost/post-image-mmu.sh` | Builds firmware, stages Debian's kernel and NIC module, and packs images |
| `board/frost/frost_boot_image.py` | Packs firmware, kernel, device tree, and optional initramfs for the JTAG loader |
| `board/frost/frost,net10g.yaml` | NIC device-tree binding |

## Toolchain

Initialize submodules before native builds. The defconfig and custom-toolchain
checksum must match the Dockerfile's Bootlin musl archive. Use a fresh output
directory after changing Buildroot or the compiler; Buildroot does not support
switching compilers inside an existing tree.

## Build

From the repository root, build in a separate output directory:

```bash
./scripts/frost.py run make -C linux/buildroot O=/workspace/linux/build-mmu \
  BR2_EXTERNAL=/workspace/linux/buildroot-external frost_rv64_defconfig
./scripts/frost.py run make -C linux/buildroot O=/workspace/linux/build-mmu \
  BR2_EXTERNAL=/workspace/linux/buildroot-external
```

The first build downloads the external toolchain. Outputs are in
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

The loader builds missing components and packs images for the board's clock
and DDR size:

```bash
./fpga/load_software/load_software.py x3 linux_boot
```

It sets `FPGA_CPU_CLK_FREQ` and `FROST_LINUX_MEM_SIZE` (1 GiB on X3).
A standalone build defaults to 322.265625 MHz and 64 MiB:

```bash
./scripts/frost.py run make -C sw/apps/linux_boot
```

For Debian over NFS, provide the export and its matching kernel/initramfs:

```bash
FROST_LINUX_NFSROOT=192.0.2.1:/srv/nfs/debian \
FROST_LINUX_KERNEL=/srv/nfs/debian/boot/vmlinux-<version> \
FROST_LINUX_INITRD=/srv/nfs/debian/boot/initrd.img-<version> \
  ./fpga/load_software/load_software.py x3 linux_boot
```

Use absolute paths. Inside `./scripts/frost.py run`, files must be under
`/workspace`, the mounted checkout. `FROST_LINUX_IP` supplies the kernel's
`ip=` setting (default `dhcp`); `FROST_LINUX_MAC` sets the board's MAC.
Give each board on a shared network a unique locally administered MAC.
See [NFS root options](../README.md#nfs-root) for details.

Debian needs an initramfs with the NIC module to mount NFS. Setting only
`FROST_LINUX_NFSROOT` omits the initramfs and requires a custom kernel with
`CONFIG_IP_PNP` and `CONFIG_ROOT_NFS`. Firmware still comes from OpenSBI in
either case.

To load images built elsewhere, stage them and set `FROST_LINUX_PREBUILT=1`:

```bash
cp <elsewhere>/sw.mem     sw/apps/linux_boot/sw.mem
cp <elsewhere>/sw_ddr.mem sw/apps/linux_boot/sw_ddr.mem
FROST_LINUX_PREBUILT=1 ./fpga/load_software/load_software.py x3 linux_boot
```

This preserves the staged files through the loader's clean step and skips
Buildroot. The images must already match the board's clock and memory map.

## The kernel and the NIC driver

[`debian_kernel.py`](../debian_kernel.py) fetches and verifies the pinned
Debian kernel, builds the [NIC module](../frost-net10g/README.md) against its
headers, and adds the module to the test initramfs. See the
[kernel](../README.md#kernel) and [module](../README.md#nic-module) guides for
standalone commands.

CI builds these images and boots them in QEMU. FROST hardware boot is checked
by `fpga/hw_regression.py --board x3 linux_boot` and `fpga/linux_boot_soak.py`;
there is no Linux-kernel cocotb target.

## Notes, assumptions, and gaps

- Edit `busybox-mmu.fragment` and `rootfs-overlay-mmu/` to customize userspace.
  The test initramfs has no IP-network setup; `frost_nettest` uses packet
  sockets.
- After changing `package/frost-stress/src/`, rebuild with
  `frost-stress-rebuild` and regenerate the images. The `sw/apps/linux_boot`
  Makefile does this automatically. The hardware regression separately
  builds static copies of these programs into the Debian NFS root.
- Each Buildroot output directory records absolute paths. Do not share it
  between Docker and host-native builds, or between checkouts. Pass
  `BR2_EXTERNAL` on every direct Buildroot invocation.
- Recreate the output tree after removing packages from the configuration;
  rerunning defconfig alone leaves obsolete packages in the rootfs.
- Image packing needs `dtc`. It is in the `frost` image; for other build
  environments, install it or enable `BR2_PACKAGE_HOST_DTC=y`.

The test programs are:

| Program | Purpose |
| --- | --- |
| `frost_stress` | Boot-time stress of signals, process/memory operations, futexes, and atomics; prints `FROST_USERSPACE_STRESS_PASS` or `FROST_USERSPACE_STRESS_FAIL` |
| `frost_stress --counters <command>` | Reports cycles, instructions, elapsed time, and IPC from the child's exec to exit through `perf_event_open`; replaces `perf stat` in this image |
| `frost_sigprobe` | vDSO signal-return probe |
| `frost_nettest` | Driver loopback test; prints `FROST_NET_LOOPBACK_PASS` or `FROST_NET_LOOPBACK_FAIL <reason>` and leaves the interface down with loopback disabled |

The soak requires working performance counters as well as a stress pass.
See [counter access](../README.md#counters-and-mcounteren).
