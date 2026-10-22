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
one's response code and AXI id as a rate-limited error. A read that ends in an
error response still delivers its data. The driver reports the error without
stopping the kernel.

Each new corrected-error address queues a scrub in a work item. The driver
maps its page with `vmap(..., PAGE_KERNEL)` and performs an `atomic64_add(0)`
on each of the line's eight words. FROST writes even an unchanged AMO result.
The caches hold the corrected data until the dirty line reaches DDR and gets
fresh ECC. Coherent DMA and NIC writes wait for each AMO's atomic window, so
the scrub cannot overwrite a concurrent device write with an older value.
The temporary mapping is writable even when the linear-map alias is not.
Only lines wholly within System RAM with an online `struct page` are touched.
Other addresses, including reserved firmware outside System RAM, are skipped.

The unit retains only the latest address. The X3 reader captures at most one
corrected-error address per poll interval, and some captures have no address.
Scrubbing therefore cannot account for every corrected-error count. The
driver queues up to 64 observed addresses. A full queue, an unsafe address,
or a failed temporary mapping increments `scrub_skipped`.

A delayed work item patrols System RAM with one 8-byte
`copy_from_kernel_nofault` read per 64-byte line through the linear map.
An L2 miss fetches the whole line and lets the DDR controller check its ECC.
An L2 hit does not check DDR again. Unmapped pages are tolerated, and pages
without an online `struct page` are not read. A batch attempts at most 4096
lines, yields between pages, and stops at a time limit checked after each
page. Corrected errors found by patrol use the same interrupt and scrub path.

The read-only module parameter `patrol_seconds` sets the target time for a
full pass. Its default is `86400` (one day); `0` disables patrol. Work is
spread over the pass, with smaller batches at low rates. Scheduling and the
batch limits can make a fast requested pass take longer. Set the parameter
when loading the module, for example `modprobe frost_memerr patrol_seconds=3600`.
Reload the module to change it.

The device's sysfs directory,
`/sys/bus/platform/drivers/frost_memerr/40021000.memory-controller/`, holds
read-only attributes:

| Attribute | Contents |
|---|---|
| `ecc_active` | 1 if a board's ECC reader is active (on the X3: polling, with checking on) |
| `ecc_polls` | The reader's completed polls, which advance about once a millisecond on the X3 |
| `ce_count`, `ue_count` | Corrected errors, and uncorrectable errors the reader reported |
| `axi_read_errors`, `axi_write_errors` | DDR error responses to the cache hierarchy's reads and writes |
| `ce_addr`, `ue_addr` | The physical address of the 64-byte line of the latest error of each kind with a captured address |
| `scrubbed_lines` | Line scrubs completed, including debugfs requests |
| `scrub_skipped` | Scrub requests skipped, including the self-test's deliberate MMIO request |
| `patrol_lines` | Successful patrol reads, one per line |
| `patrol_passes` | Completed traversals of System RAM, including lines whose read was skipped or faulted |

Hardware counts start at the unit's reset, the CPU reset before the kernel was
loaded. The four software counters start at driver probe and reset on reload.
The X3's controller captures one corrected-error address per poll interval,
and one uncorrectable-error address until its UE status is cleared over JTAG.
Each uncorrectable read the CPU makes also returns an error response, which
`axi_read_errors` counts.

## debugfs

With debugfs mounted at `/sys/kernel/debug`, the driver provides two files in
`frost_memerr/`. Root can write a physical address to `scrub`. The driver
rounds it down to a 64-byte line and scrubs it synchronously. A skipped request
returns `ENXIO` for an address outside eligible RAM or `ENOMEM` for a failed
mapping. For example:

```bash
echo 0x80200000 > /sys/kernel/debug/frost_memerr/scrub
cat /sys/kernel/debug/frost_memerr/selftest
```

Reading `selftest` allocates a page, fills a pattern, scrubs all its lines
through the physical-address path, and checks that the pattern survived.
It also requires the unit's own MMIO address to be rejected. It prints exactly
`FROST_MEMERR_SELFTEST_PASS` or `FROST_MEMERR_SELFTEST_FAIL`. On the pinned
kernel's 4 KiB pages, a successful run adds 64 scrubbed lines and one skipped
request. This tests the software path without injecting an ECC error.

The simulation program `sw/apps/ecc_scrub_test` runs from BRAM and tests the
writeback mechanism. The DDR model returns SLVERR on writes of its test line,
`AXI_WR_ERRS` counts those writes, and a failed writeback stops the CPU. A
clean read followed by eviction produces no write. Eight AMO no-ops preserve
the data and produce exactly one write after `fence.i` and L2 eviction, which
the bench checks at the fatal stop. Run it with
`./scripts/frost.py cocotb ecc_scrub_test`.

## In the FROST test initramfs and the hardware regression

`../debian_kernel.py module` builds the driver against the pinned Debian
kernel's headers, and `../debian_kernel.py initramfs` adds the module and a
boot script that loads it and prints `FROST_MEMERR_MODULE_PASS <release>`. See
[Driver modules](../README.md#driver-modules). The hardware regression's
`linux_boot` stage builds the module, installs it in the NFS root's
`/usr/local/bin`, loads it after login with `patrol_seconds=10`, and runs the
debugfs self-test. It requires its pass line, the expected scrub counters,
advancing patrol reads, and a full patrol pass within 150 one-second waits.
The reader must be active and polling, with all four hardware error counts
zero. The stage reloads the module at the default daily rate before continuing.

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
