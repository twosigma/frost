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

| File | Contents |
|---|---|
| `frost_net10g.c` | The driver (GPL-2.0-only OR BSD-2-Clause; `MODULE_LICENSE("Dual BSD/GPL")`) |
| `Kconfig` | `NET_VENDOR_FROST` and `FROST_NET10G` for an in-tree build of this directory. `dkms.conf`'s `BUILD_EXCLUSIVE_CONFIG` repeats its dependencies. |
| `Makefile` | The kbuild file, both as `drivers/net/ethernet/frost/Makefile` in a kernel tree and for an external module build (`make -C <kernel build dir> M=$PWD`), which always builds a module |
| `dkms.conf` | The DKMS package `frost-net10g`. Its `PACKAGE_VERSION` is the driver's `MODULE_VERSION`. |

## In the FROST test initramfs

`../debian_kernel.py module` builds the driver against the pinned Debian
kernel's headers, and `../debian_kernel.py initramfs` adds the module and a
boot script that loads it. See [NIC module](../README.md#nic-module).

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
