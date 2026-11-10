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

# `frost_net10g`: the NIC's Linux driver

`frost_net10g` is the Linux driver for FROST's 10GBASE-R NIC, the
`frost,net10g` device-tree node. It is packaged as an out-of-tree module for
Debian's kernel: DKMS rebuilds it for each installed kernel that has matching
headers, and `debian_kernel.py` builds it for the FROST test initramfs. The
[NIC hardware reference](../../hw/rtl/peripherals/nic/README.md) covers the
registers, descriptors, interrupts, and reset behavior.

On hardware advertising `ABI_CTRL.EXTENDED_SUPPORTED`, the driver requests a
64-bit coherent/streaming DMA mask and selects extended mode after each NIC
reset. It posts full 64-bit buffer addresses in the extended 16-byte
descriptor layout and programs each ring base with one aligned 64-bit MMIO
store. The completion word is then word 3 rather than legacy word 2. If the
hardware or the kernel DMA API does not support that mode, the driver keeps
the reset-default legacy descriptor layout and a 32-bit DMA mask. The
hardware still rejects descriptors outside its configured DDR aperture;
the kernel's memory map must describe only installed usable RAM.

Offloads, reported by `ethtool -k <interface>`:

| Feature | `ethtool -k` line | What the hardware does |
|---|---|---|
| Scatter-gather | `scatter-gather: on`, `tx-scatter-gather: on` | A frame is a chain of descriptors, one per skb segment, so the stack hands over fragments without copying them |
| TX checksum | `tx-checksum-ip-generic: on` (`NETIF_F_HW_CSUM`) | The MAC inserts the checksum a `CHECKSUM_PARTIAL` skb asks for; the driver puts the start and offset in the first descriptor and falls back to `skb_checksum_help()` for an odd or distant field |
| RX checksum | `rx-checksumming: on` | The NIC reports the sum of the frame after the Ethernet header and the driver sets `CHECKSUM_COMPLETE` |
| TCP segmentation | `tcp-segmentation-offload: on`, `tx-tcp-segmentation: on`, `tx-tcp6-segmentation: on` | One parameter descriptor and one frame of up to 64 KB become MSS-sized segments with exact headers; the driver seeds the checksum with the pseudo-header sum without the length and sends skbs the stage cannot take (tunnels, headers over 160 bytes) to software GSO |
| Interrupt moderation | `ethtool -c`, `ethtool -C rx-usecs N rx-frames N tx-usecs N tx-frames N` | The NIC's per-direction delay and completion count; 0 interrupts on the first completion |
| 64-bit DMA | `highdma: on` | Extended descriptor layout (when the hardware offers it) |
| Ring sizes | `ethtool -g`, `ethtool -G <interface> rx N tx N` | Power-of-two RX and TX rings from 64 to 4096 entries (default 512); other sizes round up, and a running interface is closed and reopened with the new rings |
| Flow control | `ethtool -a`, `ethtool -A <interface> rx on tx on` | IEEE 802.3x pause on both ports: `rx on` makes the transmitter stop for the pause time of a received PAUSE frame, `tx on` sends high-water pause frames when the RX FIFO fills past three quarters of its limit (refreshed at half the pause time) and a release pause frame when it drains below a quarter. PAUSE frames are consumed by the MAC, counted (`rx_pause_frames`) and never reach the stack. Autoneg is off; absent on hardware without `ABI_CTRL` bit 5 |
| RX FIFO size | `devlink dev param set platform/<dev> name rx_fifo_bytes value N cmode runtime` | The NIC's RX ingress FIFO occupancy limit in bytes (a multiple of 8, from 64 to the built depth, 64 KiB in the SoC; default 4096). `devlink dev` lists the device name. A running interface is closed and reopened with the new limit, as for ring sizes. Absent on hardware without `RX_FIFO_LIMIT` |
| Hardware statistics | `ethtool -S` | The NIC's 64-bit counters (frames, bytes, filtered, truncated, descriptor errors, aborts, MAC overflow, bad frame, bad FCS, PCS bad blocks, TX drops, and on the GMII port the preamble-stage discards and `rx_er` bursts, which read 0 elsewhere); the RESET at each open clears them |
| Loopback | `loopback: off` | MAC or PMA loopback, changed only while the interface is down |

The checksum features appear when `ABI_CTRL` bit 3 (checksum offload supported) reads one (segmentation when bit 4 does too),
and the driver sets bit 2 at each open so the NIC reports the RX checksum. `ethtool -K
<interface> rx off tx off sg off` turns each off for comparison; `rx` and `tx` take effect
on the next packet without reopening.

| File | Contents |
|---|---|
| `frost_net10g.c` | The driver (GPL-2.0-only OR BSD-2-Clause; `MODULE_LICENSE("Dual BSD/GPL")`) |
| `Kconfig` | `NET_VENDOR_FROST` and `FROST_NET10G` for an in-tree build of this directory. `dkms.conf`'s `BUILD_EXCLUSIVE_CONFIG` repeats its dependencies. |
| `Makefile` | The kbuild file, both as `drivers/net/ethernet/frost/Makefile` in a kernel tree and for an external module build (`make -C <kernel build dir> M=$PWD`), which always builds a module |
| `dkms.conf` | The DKMS package `frost-net10g`. Its `PACKAGE_VERSION` is the driver's `MODULE_VERSION`. |

## In the FROST test initramfs

`../debian_kernel.py module` builds the driver against the pinned Debian
kernel's headers, and `../debian_kernel.py initramfs` adds the module and a
boot script that loads it. See [Driver modules](../README.md#driver-modules).

## As a DKMS module on Debian

Debian's kernel does not include this driver. Install it with DKMS so that
kernel updates rebuild the module whenever their headers are installed.

As root on the board, from a checkout of this repository:

```bash
apt install dkms linux-headers-<kernel version>
dkms add linux/frost-net10g
ver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' linux/frost-net10g/dkms.conf)
dkms build frost-net10g/$ver -k <kernel version>
dkms install frost-net10g/$ver -k <kernel version>
```

For a riscv64 root tree on another machine, steps 1 and 3 of the
[NFS-root guide](../../docs/debian_nfsroot.md) run these commands through
`chroot`.

`ls /lib/modules` lists the installed kernel versions, and `uname -r` on the
board names the running one; without `-k`, DKMS builds for the running
kernel. `dkms add` copies the directory to `/usr/src/frost-net10g-<version>`.
DKMS installs `/lib/modules/<version>/updates/dkms/frost_net10g.ko.xz` and
runs `depmod`. To have later kernels arrive with their headers, install the
metapackages together: `apt install linux-image-riscv64 linux-headers-riscv64`.

The module's `of:N*T*Cfrost,net10g` aliases let udev load it when the kernel
finds the NIC's device-tree node. Loading it taints the kernel as out-of-tree
and, unless the module is signed with a key the kernel trusts, unsigned
(`OE`). Its license adds no taint.

### An NFS root needs the module in the initramfs

Debian's kernel builds its NFS client as a module and has no `ip=`
autoconfiguration, so it mounts an NFS root from its initramfs
(initramfs-tools, `boot=nfs`), and that initramfs must carry this driver.
initramfs-tools' default `MODULES=most` picks network drivers by directory
(`drivers/net`), which leaves out DKMS's `updates/dkms`, so list the module:

```bash
echo frost_net10g >> /etc/initramfs-tools/modules
update-initramfs -u -k <kernel version>
```

Kernel updates then carry the module into each new initramfs. apt unpacks a
new kernel and its headers before configuring either, so the kernel's hooks
build the module before the initramfs. Check with
`lsinitramfs /boot/initrd.img-<version> | grep frost_net10g`. If a kernel's
headers arrive in a later apt run than the kernel, DKMS builds the module only
then, after that kernel's initramfs was made; run
`update-initramfs -u -k <version>` again.

### Upgrading the package

DKMS keeps each `PACKAGE_VERSION` as a separate package. To move to a new
version, remove the old one, add and install the new one as above, and
rebuild the initramfs images, which DKMS leaves alone:

```bash
dkms remove frost-net10g/<old version> --all
rm -r /usr/src/frost-net10g-<old version>
# dkms add, build and install the new version as above, then:
update-initramfs -u -k all
```

## Changing the driver

- Keep one source that builds for every Debian kernel you deploy. Guard newer
  kernel APIs with `LINUX_VERSION_CODE`, and test against each target
  kernel's headers with `dkms build`. CI covers only the pinned kernel.
- Bump `MODULE_VERSION` in `frost_net10g.c` and `PACKAGE_VERSION` in
  `dkms.conf` together whenever the driver changes.
  `tests/test_frost_net10g_driver.py` checks that they match and that the
  driver, its DKMS packaging, and the module build agree.
- Follow the kernel's coding style: run the kernel's
  `scripts/checkpatch.pl --no-tree -f` on changed files. The repository's C
  formatter and license-header hooks skip this directory.
- If Debian moves to a newer kernel series, rebuild the module against its
  headers (`dkms build`) before relying on it. Within a series, kernel updates
  rebuild the same source.
