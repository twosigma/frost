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

# `frost_memerr`: the memory error unit's Linux driver

`frost_memerr` is the Linux driver for FROST's memory error unit, the
`frost,memory-error` device-tree node. The unit
([`memory_error_unit.sv`](../../hw/rtl/cpu_and_mem/memory_error_unit.sv))
counts the DDR controller's corrected and uncorrectable ECC errors, which the
X3's reader polls from the controller, and the error responses DDR returns to
the cache hierarchy. The pinned Debian kernel has no EDAC core (`CONFIG_EDAC`
is not set), so the driver reports through the kernel log and sysfs. It is packaged like the
[NIC driver](../frost-net10g/README.md): an out-of-tree module that DKMS
rebuilds for each installed kernel and `debian_kernel.py` builds for the FROST
test initramfs.

| File | Contents |
|---|---|
| `frost_memerr.c` | The driver (GPL-2.0-only OR BSD-2-Clause; `MODULE_LICENSE("Dual BSD/GPL")`) |
| `Kconfig` | `FROST_MEMERR` for an in-tree build. `dkms.conf`'s `BUILD_EXCLUSIVE_CONFIG` repeats its dependencies. |
| `Makefile` | The kbuild file, for a kernel tree and for an external module build (`make -C <kernel build dir> M=$PWD`), which always builds a module |
| `dkms.conf` | The DKMS package `frost-memerr`. Its `PACKAGE_VERSION` is the driver's `MODULE_VERSION`. |

## What it does

At probe the driver logs any errors the unit counted since its reset, clears
the unit's status, and enables its interrupt for every kind. Each interrupt
logs what arrived since the last one: an uncorrectable error at `KERN_CRIT`,
with its address or, when the controller's capture was lost, without one;
the number of corrected errors, and each newly captured corrected-error
address, as rate-limited warnings; and DDR error responses with the latest
one's response code and AXI id as a rate-limited error. A read that ends in an error response
still delivers its data, so the log is the only sign of it; the driver does not
stop the kernel.

The device's sysfs directory,
`/sys/bus/platform/drivers/frost_memerr/40021000.memory-controller/`, holds
read-only attributes that read the unit's registers:

| Attribute | Contents |
|---|---|
| `ecc_active` | 1 if a board's ECC reader is active (on the X3: polling, with checking on) |
| `ecc_polls` | The reader's completed polls, which advance about once a millisecond on the X3 |
| `ce_count`, `ue_count` | Corrected errors, and uncorrectable errors the reader reported |
| `axi_read_errors`, `axi_write_errors` | DDR error responses to the cache hierarchy's reads and writes |
| `ce_addr`, `ue_addr` | The physical address of the 64-byte line of the latest error of each kind with a captured address |

Counts start at the unit's reset, the CPU reset before the kernel was loaded.
The X3's controller captures one corrected-error address per poll interval,
and one uncorrectable-error address until its UE status is cleared over JTAG.
Each uncorrectable read the CPU makes also returns an error response, which
`axi_read_errors` counts.

## In the FROST test initramfs and the hardware regression

`../debian_kernel.py module` builds the driver against the pinned Debian
kernel's headers, and `../debian_kernel.py initramfs` adds the module and a
boot script that loads it and prints `FROST_MEMERR_MODULE_PASS <release>`. See
[Driver modules](../README.md#driver-modules). The hardware regression's
`linux_boot` stage builds the module, installs it in the NFS root's
`/usr/local/bin`, loads it after login, and requires the reader to be active
and polling with every count zero.

## As a DKMS module on Debian

As root on the board, from a checkout of this repository:

```bash
apt install dkms linux-headers-<kernel version>
dkms add linux/frost-memerr
ver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' linux/frost-memerr/dkms.conf)
dkms build frost-memerr/$ver -k <kernel version>
dkms install frost-memerr/$ver -k <kernel version>
```

udev then loads the module at boot from the device tree's node. Unlike the NIC
driver, it is not needed to mount an NFS root, so it need not be in the
initramfs.

## Changing the driver

- Bump `MODULE_VERSION` in `frost_memerr.c` and `PACKAGE_VERSION` in
  `dkms.conf` together whenever the driver changes.
  `tests/test_frost_memerr_driver.py` checks that they match, and that the
  driver's register map is the unit's and `sw/lib/include/memory_error.h`'s.
- Follow the kernel's coding style: run the kernel's
  `scripts/checkpatch.pl --no-tree -f` on changed files. The repository's C
  formatter and license-header hooks skip this directory.
