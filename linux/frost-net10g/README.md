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

The Linux driver for the FROST NIC (`hw/rtl/peripherals/nic`), the device
tree node with `compatible = "frost,net10g"`
(`../buildroot-external/board/frost/frost,net10g.yaml`). The register map and
the descriptor, interrupt and RESET contract it follows are in
[`../../hw/rtl/peripherals/nic/README.md`](../../hw/rtl/peripherals/nic/README.md).

The driver is packaged as an out-of-tree module for Debian's kernel. DKMS
rebuilds it for installed kernels with matching headers; `debian_kernel.py`
also builds it for the FROST test initramfs.

| File | What |
|---|---|
| `frost_net10g.c` | the driver (GPL-2.0-only OR BSD-2-Clause; `MODULE_LICENSE("Dual BSD/GPL")`) |
| `Kconfig` | `NET_VENDOR_FROST` and `FROST_NET10G` in kernel-tree form, for an in-tree build of this directory; `dkms.conf`'s `BUILD_EXCLUSIVE_CONFIG` is the dependencies it declares |
| `Makefile` | the kbuild file: `drivers/net/ethernet/frost/Makefile` in the kernel tree, and an external module build (`make -C <kernel build dir> M=$PWD`), where it always builds a module |
| `dkms.conf` | the DKMS package `frost-net10g`; its `PACKAGE_VERSION` is the driver's `MODULE_VERSION` |

## In the FROST test initramfs

`../debian_kernel.py module` builds against the pinned Debian kernel's
headers. `../debian_kernel.py initramfs` adds the module and a boot script
that loads it. See [NIC module commands](../README.md#nic-module).

## As a DKMS module on Debian

Debian's kernel does not include the FROST driver. Install it with DKMS so
kernel updates rebuild the module automatically when headers are available.

As root on the board, from a checkout of this repository (for a riscv64 root
tree on another machine, steps 1 and 3 of
[`../../docs/debian_nfsroot.md`](../../docs/debian_nfsroot.md) run these
commands through `chroot`):

```bash
apt install dkms linux-headers-<kernel version>
dkms add linux/frost-net10g
ver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' linux/frost-net10g/dkms.conf)
dkms build frost-net10g/$ver -k <kernel version>
dkms install frost-net10g/$ver -k <kernel version>
```

`ls /lib/modules` lists the installed kernel versions; on the board, `uname
-r` is the running one, and without `-k` DKMS builds for it. `dkms add` copies
the directory to `/usr/src/frost-net10g-<version>`. For later kernels to
arrive with their headers, install the metapackages together:
`apt install linux-image-riscv64 linux-headers-riscv64`. DKMS installs
`/lib/modules/<version>/updates/dkms/frost_net10g.ko.xz` and runs `depmod`.
The module's `of:N*T*Cfrost,net10g` aliases let udev load it when the kernel
finds the NIC's device tree node. Loading it taints the kernel as
out-of-tree and, unless the module is signed with a key the kernel trusts,
unsigned (`OE`); its license adds no taint.

### An NFS root needs the module in the initramfs

Debian's kernel builds its NFS client as a module and has no `ip=`
autoconfiguration, so it mounts an NFS root from its initramfs
(initramfs-tools, `boot=nfs`), which must carry the driver. initramfs-tools'
default `MODULES=most` picks network drivers by directory
(`drivers/net`), which leaves out DKMS's `updates/dkms`, so list the module:

```bash
echo frost_net10g >> /etc/initramfs-tools/modules
update-initramfs -u -k <kernel version>
```

A kernel update then carries it into the new kernel's initramfs by itself:
apt unpacks the new kernel and its headers before configuring them, so the
kernel's hooks build the module before the initramfs. Check with
`lsinitramfs /boot/initrd.img-<version> | grep frost_net10g`. If a kernel's
headers arrive in a later apt run than the kernel, DKMS builds the module
only then, after that kernel's initramfs was made; run `update-initramfs -u
-k <version>` once more.

### Upgrading the package

DKMS keeps each `PACKAGE_VERSION` as its own package. To move to a new
version, remove the old one, add and install the new one as above, and
rebuild the initramfs images, which DKMS leaves alone:

```bash
dkms remove frost-net10g/<old version> --all
rm -r /usr/src/frost-net10g-<old version>
# dkms add, build and install the new version as above, then:
update-initramfs -u -k all
```

## Changing the driver

- Keep one source compatible with the Debian kernels you deploy. Guard newer
  kernel APIs with `LINUX_VERSION_CODE` and test against each target kernel's
  headers with `dkms build`; CI covers the pinned kernel only.
- Bump `MODULE_VERSION` in `frost_net10g.c` and `PACKAGE_VERSION` in
  `dkms.conf` together whenever the driver changes;
  `tests/test_frost_net10g_driver.py` checks that they match and that the
  driver, its DKMS packaging and the module build agree.
- Keep the kernel's coding style: run the kernel's `scripts/checkpatch.pl
  --no-tree -f` on the changed files. The repository's C formatter and
  license-header hooks skip this directory.
- If Debian moves to a newer kernel series, rebuild the module against its
  headers (`dkms build`) before relying on it; within a series, kernel
  updates rebuild it unchanged.
