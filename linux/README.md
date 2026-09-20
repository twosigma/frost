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

# FROST Linux boot ABI

Boot contract between the FROST SoC/loaders and the Sv39 Linux kernel that
boots through OpenSBI. The kernel is Debian's own riscv64 kernel, pinned by
[`debian_kernel.py`](debian_kernel.py) (see "Kernel"); the build flow around it
is in [`buildroot-external/README.md`](buildroot-external/README.md), which
builds the firmware and the test initramfs. This file defines what a kernel or
other supervisor payload can rely on. The no-MMU M-mode lane was retired in
Phase 3; this is the only lane.

## Boot chain and entry state

After DDR calibration, the CPU leaves reset and fetches the boot shim from
address `0` in low BRAM. `frost_boot_image.py` writes the shim, assembles it,
and packs it into `sw.mem`. The shim enters the firmware:

```asm
li   a0, 0            # hart ID
li   a1, <dtb>        # physical address of the DTB
li   t0, 0x80000000   # OpenSBI fw_jump entry
jr   t0
```

`<dtb>` is the DTB address the packer computes from the payload (see the DDR
layout below): `0x81000000` for any payload up to 14 MiB, and `0x82200000` for
today's kernel, whose footprint is about 31 MiB.

The firmware is the unmodified OpenSBI v1.7 generic platform from the
`linux/opensbi` submodule, built by `linux/opensbi_build.py` with the
Linux-targeted Bootlin toolchain in the Docker image (OpenSBI links as a PIE,
which the bare-metal xPack linker cannot do). It is built with
`FW_TEXT_START=0x80000000`, the default `FW_JUMP_OFFSET=0x200000`, an empty
`FW_JUMP_FDT_OFFSET` (so fw_jump passes the shim's `a1`, the DTB address,
through untouched), the driver set in `linux/opensbi_frost_defconfig`
(uart8250, PLIC, ACLINT mswi/mtimer only), and libfdt's assume mask
(`FDT_ASSUME_MASK=7`), the last two because OpenSBI's device-tree probing
otherwise costs millions of simulated cycles per boot.

Entry state handed to the payload: S-mode, `satp` Bare, `sstatus.SIE=0`,
`mideleg` = SSI/STI/SEI, `medeleg` = misaligned-fetch, breakpoint, U-ecall and
the three page faults, `mcounteren` and `scounteren` = 0x7, `menvcfg.STCE=1`
(OpenSBI only programs `menvcfg` on a hart it classifies as privileged v1.12,
which is why `mcountinhibit` exists), and misaligned loads/stores emulated in
M-mode until the supervisor asks the FWFT extension to delegate them (Linux
does).

The firmware side is exercised on its own by the cocotb `opensbi_smoke` test
(a bare S-mode payload under the real firmware); the whole chain by the Linux
boot jobs in CI.

## Memory map

The map is identical across board integrations and simulation; caches are
transparent to software.

| Range | What |
|---|---|
| `[0x0000_0000, 256 KiB)` | Uncached BRAM. Data access is 1-cycle; fetch windows wholly below 64 KiB are 1-cycle and other low-BRAM windows repeat once. Holds the boot shim; free for supervisor use after boot. |
| `[0x4000_0000, +196 KiB)` | Native FROST MMIO window: UART, FIFOs, timer (`sw/lib/include/mmio.h` is the authoritative register map), the DMA test engine at `+0x2_0000` and the NIC at `+0x3_0000`. |
| `[0x4000_1000, +0x100)` | ns16550a UART face (`reg-shift = 2`, `reg-io-width = 4`) aliasing the native UART. Takes PLIC source 1. |
| `[0x4001_0000, +0xC000)` | SiFive-layout CLINT alias (`sifive,clint0`): `msip` at `+0x0000`, `mtimecmp` at `+0x4000`, `mtime` at `+0xBFF8`. Same physical registers as the native timer block. The DTB node and the RTL's CLINT decode both end after `mtime`, at `0x4001_C000`; the MMIO window itself continues to `0x4003_1000`, past the DMA test engine and the NIC. |
| `[0x4003_0000, +4 KiB)` | NIC registers. The DTB advertises `ethernet@40030000` (`frost,net10g`, `dma-coherent`, `local-mac-address`); the binding is in `buildroot-external/board/frost/frost,net10g.yaml`, and the kernel's `frost_net10g` driver binds to the node. |
| `[0x4400_0000, +4 MiB)` | PLIC (M and S contexts for hart 0; source 1 is the ns16550 UART, source 2 the board's external-interrupt pin, source 3 the DMA test engine, source 4 the NIC). The DTB advertises both contexts and `riscv,ndev = 4`; OpenSBI hides the M context from the kernel. |
| `[0x8000_0000, +1 GiB)` | Cached DDR. The DTB advertises `memory@80000000` with the packer's `--mem-size`, 64 MiB by default (`MEM_SIZE` in `frost_boot_image.py`, the simulation DDR model's size), which a plain `make` and the CI images use. `load_software.py` passes the board's DDR, the range its block design (`fpga/build/<board>_ddr_bd.tcl`) maps for the CPU: all 1 GiB on the X3, so the hardware regression's Linux stage runs with 1 GiB. Simulation builds pack for the DDR model (`DDR_MODEL_BYTES` when set, else the default), never for a board. The NIC and the DMA test engine reach the whole region. |

The PMA map has three regions: the BRAM, the device quadrant
`[0x4000_0000, 0x8000_0000)`, and cached DDR. An access anywhere else,
including any address with bits [63:32] set, raises a precise access fault
(instruction/load/store causes 1/5/7 with the exact address in `mtval`).
Instruction fetch from the device quadrant is also an access fault.
Out-of-map addresses do not alias onto the map.

DDR layout as packed by `buildroot-external/board/frost/frost_boot_image.py`
(offsets from `0x8000_0000`): `fw_jump.bin` at `+0` (at most 1 MiB; its
runtime rw/heap/scratch regions follow it and are reserved by OpenSBI's
`reserved-memory` fixup), the S-mode payload or kernel `Image` at `+2 MiB`
(the rv64 kernel's 2 MiB PMD alignment), the DTB in a 64 KiB slot (OpenSBI
grows it in place), and the initramfs, when present, right after that slot.
The DTB goes on the first 2 MiB boundary at or above both `+16 MiB` and the
payload's end (a Linux `Image` ends at its header's `image_size`, bss
included; a raw payload at its length). With `STRICT_KERNEL_RWX` (the rv64
default) Linux reserves its image up to the 2 MiB boundary past its end, and
it drops an initramfs that overlaps a reservation, so the DTB and the
initramfs start at or above that boundary.
For payloads up to 14 MiB the floor wins: the DTB sits at `+16 MiB` and the
initramfs at `+16 MiB + 64 KiB`. The floor only preserves that layout;
neither Linux nor OpenSBI requires it. The packer fails if the DTB slot or the
initramfs would end past the advertised memory.

## Interrupts and time

The DT wires the CLINT to the hart's `cpu-intc` for machine software (cause 3)
and machine timer (cause 7) interrupts, and advertises the PLIC with the M and
S contexts (`&cpu0_intc 11`, `9`). The dword-aligned CLINT registers support
native 64-bit access: `ld` reads `mtime` atomically, without the rv32
hi/lo/hi loop, and an 8-byte `mtimecmp` store lands atomically.
`timebase-frequency` equals the CPU clock: `mtime` increments every core cycle
with no divider (simulation builds may scale it via the `SIM_TIMER_SPEEDUP`
parameter). The packer stamps it into the DTB from `FPGA_CPU_CLK_FREQ`
(300 MHz by default for X3), and the UART `clock-frequency` the same way.
Because OpenSBI leaves `menvcfg.STCE=1`, the supervisor arms timers through
Sstc (`stimecmp`) rather than an SBI timer call.

## Advertised ISA

The DTB advertises
`rv64imafdc_zicsr_zifencei_zicntr_zba_zbb_zbs_zbkb_zicond_zihintpause` plus
`sstc` and `svade`, and the cpu node carries `mmu-type = "riscv,sv39"`, so the
DT describes an M/S/U hart with Sv39 translation. Userspace is ordinary ELF
(`CONFIG_BINFMT_ELF`) with a full address space: `fork`, `mmap` and shared
memory behave normally.

## Counters and mcounteren

FROST implements `cycle`, `time`, and `instret` as 64-bit Zicntr CSRs.
The rv32-only `*h` aliases are illegal instructions at every privilege.
`time` reads the CLINT's `mtime` at the CPU clock rate. Two WARL registers
gate access from below M-mode: S-mode needs the counter's bit set in
`mcounteren` (0x306), and U-mode needs it set in both `mcounteren` and
`scounteren` (0x106). M-mode access is never gated.

- Only the CY/TM/IR bits exist in either register; bits 31:3 read as zero
  and discard writes. There are no hpmcounters: their CSR addresses are
  unimplemented, and accessing an unimplemented CSR raises an illegal
  instruction at every privilege (the privileged-spec rule that lets
  firmware probe optional CSRs by trapping).
- `mcountinhibit` (0x320) exists with functional CY (bit 0) and IR (bit 2)
  bits that stop `cycle` and `instret` while set; TM reads 0 and bits 31:3
  are WARL-0. `mcycle` (0xB00) and `minstret` (0xB02) accept full 64-bit
  M-mode writes. Both are what OpenSBI's SBI PMU uses to stop, start and
  preload the fixed counters, and the inhibit CSR is also what its
  privileged-version probe requires before it programs `menvcfg.STCE`.
- Both registers reset to `0x7`, and OpenSBI hands the kernel `mcounteren`
  and `scounteren` = 0x7 (see the entry state above), so userspace can use
  `rdcycle`/`rdtime`/`rdinstret`.
- With a bit clear in either register, a U-mode access to that counter's
  CSR is an illegal instruction (mcause=2, mtval=0).

The kernel reaches the same counters through the SBI PMU
(`CONFIG_RISCV_PMU_SBI`), which is what `perf_event_open` on
`PERF_COUNT_HW_CPU_CYCLES` and `PERF_COUNT_HW_INSTRUCTIONS` gets; a `riscv,pmu`
device-tree node maps those two events onto the fixed counters. That is how
`frost_stress` reads them, at boot and in its `--counters` mode, since direct
userspace reads are what the kernel gates rather than what it offers. The counts
come out on FROST and under QEMU alike, so `counters=unavailable` is a
degradation rather than a platform difference. Two gates reject it:
`linux_boot_soak.py` fails a boot whose payload reports it, and the hardware
regression fails a `--counters` run that does. CI's `linux-boot-qemu-mmu` job
does not look at the counters at all -- it requires the module, stress and login
markers -- so a counter regression is caught on the board, not in CI.

`--counters` measures a child from its exec to its exit, which its `scope=`
field names and the hardware regression requires: `enable_on_exec` arms the
events at the child's exec and `inherit` follows its descendants, so the
measurement covers a task that execs and then exits, as the `perf stat
<command>` it replaced did. The boot payload's own phase 5 measures itself.

## Kernel

FROST boots Debian's own riscv64 kernel everywhere: the hardware regression's
Linux stage, the board soaks, and CI's QEMU boot job.
[`debian_kernel.py`](debian_kernel.py) is the one place that names it -- the
snapshot.debian.org timestamp, the package version, and each package's size and
sha256 -- and it fetches, verifies and extracts the packages into
`linux/debian-kernel`, a download cache like `linux/dl`. Today's pin is
`6.12.107+deb13-riscv64`, and its `/boot/vmlinux-<release>` is an uncompressed
flat `Image` the packer takes as its payload. It is the same version
[`../docs/debian_nfsroot.md`](../docs/debian_nfsroot.md) installs on the NFS
root, so a board runs one kernel whichever root it boots.

Nothing FROST-specific is patched into it. The one piece it lacks is the NIC
driver, which is built as a module for exactly that kernel (see "NIC module")
and travels in the initramfs.

`debian_kernel.py`'s subcommands are `fetch`, `release`, `image`, `module` and
`initramfs`, and each prints just its answer on stdout with progress on stderr,
so a shell substitution around one is the path even on a cold cache.
`FROST_DEBIAN_KERNEL_CACHE` moves the cache, and `FROST_NET10G_MODULE` names a
module built elsewhere, for a tree with no kernel headers or cross toolchain.
The consumers are the `sw/apps/linux_boot` Makefile and Buildroot's post-image
hook (see "Consumers").

The cache holds immutable directories named after a digest of their inputs --
the pin for the extracted tree, the pin and the toolchain for the module
objects, since kbuild records the compiler by Debian's `riscv64-linux-gnu-gcc`
name and would not otherwise notice a different toolchain behind it. Each is
built under `staging/` and published with one rename, downloads land in a
per-process temporary first, and mutations hold `.lock`, so a native loader and
a container build over the same checkout cannot see a half-built tree or tear
down each other's work. A published tree is validated against the manifest
stored with it before it is reused, so a truncated or partly deleted one is
rebuilt instead of trusted. Changing the pin leaves the old directories in
place, because removing them could pull the ground from under a concurrent
reader; delete `linux/debian-kernel` to reclaim the space.

To bump the pin, put the new snapshot, version, sizes and checksums in
`debian_kernel.py`, delete `linux/debian-kernel`, and re-run the gates: the
kernel release appears in the boot banner the hardware regression requires and
in the module's vermagic, so a half-finished bump fails rather than boots. A
bump also moves each board's NFS root, which the hardware regression boots: its
kernel has to reach the new version, with `frost_net10g` in the new initramfs
([`../docs/debian_nfsroot.md`](../docs/debian_nfsroot.md), "Operation"). The
stage's preflight reads the release out of the `Image` it is given and refuses a
version that is not the pin, so the two cannot drift apart unnoticed.

Nothing here builds a kernel any more. What a kernel packed by this tree has to
provide, whether it is the pin or one named by `FROST_LINUX_KERNEL`:

| Option | Why |
|---|---|
| `CONFIG_MMU`, `CONFIG_ARCH_RV64I` + `CONFIG_64BIT` | Sv39 rv64 kernel. `CONFIG_RISCV_M_MODE` (behind the `CONFIG_NONPORTABLE` gate) must stay unset: OpenSBI hands this kernel S-mode, not the retired M-mode build's entry. |
| `CONFIG_RISCV_SBI` | Boots under OpenSBI and calls the SBI interface. |
| `CONFIG_RISCV_PMU`, `CONFIG_RISCV_PMU_SBI` | The SBI PMU's cycle and instret counters, which `frost_stress` reads and the gates require. |
| `CONFIG_RISCV_MISALIGNED` | Misaligned accesses once the supervisor takes FWFT delegation. Either choice provides it: the pin's `CONFIG_RISCV_PROBE_UNALIGNED_ACCESS` or `CONFIG_RISCV_EMULATED_UNALIGNED_ACCESS`. |
| `CONFIG_BINFMT_ELF`, `CONFIG_FPU` | Ordinary ELF userspace, lp64d hard-float. |
| `CONFIG_BLK_DEV_INITRD` | External initramfs via `linux,initrd-*`. A compressed replacement also needs its `CONFIG_RD_*` decompressor; the test initramfs is uncompressed. |
| `CONFIG_DEVTMPFS`, `CONFIG_TMPFS`, `CONFIG_PROC_FS`, `CONFIG_SYSFS` | What the test initramfs's inittab mounts. It mounts devtmpfs itself, so `CONFIG_DEVTMPFS_MOUNT` is not needed (the pin leaves it unset). |
| `CONFIG_SERIAL_8250[_CONSOLE]`, `CONFIG_SERIAL_OF_PLATFORM` | Console on the ns16550a face, bound from the DT. Built in: the test initramfs carries no serial modules. |
| `CONFIG_OF`, `CONFIG_OF_EARLY_FLATTREE` | DT-driven probe; earlycon (`earlycon=uart8250,mmio32,0x40001000`). |
| `CONFIG_NET`, `CONFIG_INET`, `CONFIG_PACKET` | Packet sockets, which `frost_nettest` uses, and IPv4 for any NFS root. |
| `CONFIG_MODULES`, or the driver built in (`CONFIG_NETDEVICES`, `CONFIG_ETHERNET`, `CONFIG_NET_VENDOR_FROST`, `CONFIG_FROST_NET10G`) | The `frost_net10g` driver for the `frost,net10g` node (`frost-net10g/`). The pin takes it as a module (see "NIC module"). |
| `CONFIG_NFS_FS`, `CONFIG_NFS_V3` | The kernel's NFS client, for either NFS root (see "NFS root"): the mount is a kernel mount even when an initramfs asks for it. The pin builds them as modules, which that initramfs carries. |
| `CONFIG_ROOT_NFS`, `CONFIG_IP_PNP` (`CONFIG_IP_PNP_DHCP` for `ip=dhcp`) | Only for a kernel that mounts the NFS root itself, from `ip=` and `nfsroot=`; that kernel also needs the NFS client and the NIC driver built in. The pin has neither symbol. |
| `CONFIG_CGROUPS`, `CONFIG_UNIX` | Required by systemd on the NFS root (it uses the cgroup v2 hierarchy with no controllers). `CONFIG_AUTOFS_FS`, `CONFIG_TMPFS_POSIX_ACL` and `CONFIG_TMPFS_XATTR` are recommended; its other requirements, and the seccomp filters it recommends, are kernel defaults. |

Debian's kernel meets that contract with three differences the boot accounts
for. It builds `CONFIG_IPV6` in, so the packer's default bootargs
carry `ipv6.disable=1`: the autoconfiguration frames IPv6 sends whenever an
interface comes up return through the NIC's loopback and fail
`frost_nettest`'s idle checks. It has no `CONFIG_IP_PNP` or `CONFIG_ROOT_NFS`,
so it cannot mount an NFS root itself and does so from an initramfs instead (see
"NFS root"). And it has no FROST driver, so the driver is a module.

## NIC module

`debian_kernel.py module` builds [`frost-net10g/`](frost-net10g/README.md) as a
module for the pinned kernel, and `debian_kernel.py initramfs` appends it, a
one-line `modules.dep`, and `/etc/init.d/S03frost-net10g` to Buildroot's
`rootfs.cpio`. The kernel unpacks concatenated cpio archives -- each newc member
is four-byte aligned and the unpacker only requires the gap between two archives
to keep that alignment, so GNU cpio's 512-byte block padding is padding, not a
requirement -- and so Buildroot's own archive is untouched and no Buildroot
rebuild is needed to change any of this.
Buildroot's `/etc/init.d/rcS`, which the overlay inittab runs as a sysinit
entry, runs that script, so the module is loaded before the getty and before any
network test. It prints `FROST_NET10G_MODULE_PASS <release>`, or
`FROST_NET10G_MODULE_FAIL <reason>`, which `fpga/linux_boot_soak.py` and CI's
QEMU boot job both require. The hardware regression boots the NFS root instead,
whose initramfs modprobes the DKMS build of the same driver quietly, so there it
is the driver's own probe message that says the module is in the kernel, and the
kernel's banner that says which kernel it went into.

That the module loaded is not by itself evidence of which kernel is running. The
pin sets `CONFIG_MODVERSIONS`, and once a module carries symbol CRCs Linux
compares vermagic with its first field -- the release -- skipped, so this module
would load into any ABI-compatible kernel. The script therefore compares
`uname -r` with the pinned release before it loads anything, and prints the
release it read; the gates require that line, with the release, exactly. The
release strings say which kernel booted, not which bytes were packed: two builds
of one version share a release, and only the pinned `.deb`'s sha256 fixes the
`Image`'s contents.

What the module build itself checks, before anything is published: the module's
`vermagic` names the pinned release exactly, it was built with modversions, and
every symbol CRC it recorded matches the pinned tree's `Module.symvers`. The
last one is what a build against another kernel's headers fails.

The build needs no new tool. It uses Debian's own `linux-headers` tree for
riscv64, whose kbuild host tools come from `linux-kbuild` (`Multi-Arch:
foreign`, so the amd64 build of it drives the riscv64 tree), and a
Linux-targeted riscv64 cross toolchain: Buildroot's own, which the same build
produced, when the `sw/apps/linux_boot` Makefile and the post-image hook drive
it, so a host with none installed needs nothing; otherwise the one the Docker
image carries for OpenSBI (`FROST_LINUX_CROSS_COMPILE`), or `--cross`. Two
details make that work: Debian's
headers tree hard-overrides `CROSS_COMPILE` to `riscv64-linux-gnu-`, so the
helper generates wrapper scripts under that prefix around the installed
toolchain; and the headers tree's BTF base `vmlinux` is left unextracted, so
kbuild skips module BTF generation instead of demanding `pahole`, which the
image does not ship.

## Bring-up probe

The initramfs also runs `frost_sigprobe` from inittab, one line per
signal-return variant (`FROST_SIGPROBE v<n> ...: ok`), because the first board
boot lost busybox to a SIGILL at the vDSO sigreturn trampoline after a child
exit; see `buildroot-external/package/frost-stress/src/frost_sigprobe.c`.

## Consumers

`sw.{mem,txt}` (shim, low BRAM) and `sw_ddr.{mem,txt}` (DDR image) are loaded by
`fpga/load_software/load_software.py` over JTAG. The app Makefile also derives
`sw64.mem`, the dword-paired copy of `sw.mem` for the 64-bit data BRAM's
`$readmemh`. The kernel comes from `linux/debian-kernel` (see "Kernel"); the
firmware and the test initramfs from `linux/build-mmu` and the
`frost_rv64_defconfig` Buildroot config
([`buildroot-external/README.md`](buildroot-external/README.md)), with the NIC
module appended to that initramfs. `FROST_LINUX_KERNEL` or `FROST_LINUX_INITRD`
names another kernel or initramfs in their place (see "NFS root").

Booting this kernel is validated on hardware, not in RTL simulation: the
simulated core reaches only early boot in hours, and both core bugs that
Debian's kernel exposed (a load-queue stale slot, and a page-table walker that
missed the L1D's dirty lines) were found on the board. The gates are the
hardware regression's Linux stage (`fpga/hw_regression.py`) and the board soaks
(`fpga/linux_boot_soak.py`), with CI's `linux-boot-qemu-mmu` job booting the
same kernel and rootfs through userspace under QEMU. Simulation still covers
the firmware half of this contract through the cocotb `opensbi_smoke` test, and
the kernel's timer, trap, atomic and MMIO patterns through directed bare-metal
apps (`linux_irq_*`, `linux_clksrc_faithful`, `tick_torture`, `amo_irq_torture`,
`ns16550_test`, `clint_test`).

In the test initramfs, `rcS` loads the NIC module (`FROST_NET10G_MODULE_PASS`,
see "NIC module") and inittab runs `frost_stress --boot`, which prints the
`FROST_USERSPACE_STRESS_PASS`/`_FAIL` token; both precede the login prompt, and
the QEMU CI job and `fpga/linux_boot_soak.py` assert both.

The hardware regression's Linux stage boots the NFS root instead (see "NFS
root"), where no init script of this tree's runs, so it requires the kernel's own
version banner and the driver's probe line before the login prompt and then types
the programs itself: `findmnt`, which must show `/` mounted from the packed
export over NFSv3; `systemctl`, which must report a finished startup with no
failed unit; `frost_stress --boot` for the same token; `frost_stress --counters`,
whose cycle and instruction counts for a child measured through an exec must both
be nonzero; and `frost_nettest`, which drives the NIC driver through its loopback
feature (the NIC's raw loopback on a shared MAC clock, the transceiver's PMA
loopback otherwise) and must print `FROST_NET_LOOPBACK_PASS` and then let the
root come back, since that test takes the interface the root is mounted over
down. Those two programs
come from the `frost-stress` package, cross-compiled statically and installed in
the export by the stage's own preflight, since the copies in the test initramfs
are linked against musl. The counter command replaced `perf stat`: `perf` builds
only against a kernel tree, and this tree builds no kernel, so nothing packs it
for the target. The stage requires the kernel banner to name the pinned release
exactly, so a kernel this one's release is only a prefix of fails rather than
passes.
The payload's summary line carries per-boot Zicntr evidence for hardware
performance tracking: `cycles=`/`instret=`/`time=`/`ipc_x1000=` deltas around
a fixed workload (see "Counters and mcounteren").

## NFS root

`sw/apps/linux_boot` packs the initramfs unless `FROST_LINUX_NFSROOT` names an
NFS export as `<server-ip>:/<path>`. Then, unless `FROST_LINUX_INITRD` names
an initramfs (below), it packs none, and the DTB's bootargs are:

```
earlycon console=ttyS0 root=/dev/nfs nfsroot=<server-ip>:/<path>,vers=3,tcp,hard rw ip=<FROST_LINUX_IP>
```

`FROST_LINUX_IP` is the kernel's `ip=` parameter and defaults to `dhcp`; a
static address is `<client>::<gateway>:<netmask>:<hostname>:<device>:off`,
for example `192.0.2.2::192.0.2.1:255.255.255.0:frost:eth0:off`; set
without `FROST_LINUX_NFSROOT`, it fails the pack. The kernel configures the
interface, waits for its carrier, mounts the export read-write over NFSv3/TCP
(nfsroot adds `nolock`, so file locks stay local) and runs its `/sbin/init`.
The export must be a riscv64 root filesystem, such as Debian 13's, shared
read-write with the board's address without root squashing. Without an
initramfs the packed kernel mounts the export itself, which needs
`CONFIG_IP_PNP` and `CONFIG_ROOT_NFS`; Debian's has neither, so that form needs
`FROST_LINUX_KERNEL` as well.

`FROST_LINUX_KERNEL` and `FROST_LINUX_INITRD` name a Linux `Image` and an
initramfs, by absolute path, to pack in place of Debian's `Image` and the test
initramfs; OpenSBI and the device tree stay this tree's. The Debian root's own
`/boot/vmlinux-<version>` and `/boot/initrd.img-<version>` are what
[`../docs/debian_nfsroot.md`](../docs/debian_nfsroot.md) passes: the same kernel
version as the pin, with the initramfs that Debian's initramfs-tools generates
mounting the export, since the kernel cannot.
The hardware regression's Linux stage is that combination: it requires all four
of `FROST_LINUX_NFSROOT`, `FROST_LINUX_IP`, `FROST_LINUX_KERNEL` and
`FROST_LINUX_INITRD` from the environment, with no defaults, and checks them
before it loads anything (`fpga/hw_regression.py`, and
[`../docs/debian_nfsroot.md`](../docs/debian_nfsroot.md), "Hardware
regression"). `fpga/linux_boot_soak.py` and CI leave them unset and boot the
test initramfs, which is why the pin and the root's kernel are kept at the same
version.
With `FROST_LINUX_NFSROOT` and `FROST_LINUX_INITRD` both set, the packer packs
that initramfs, and `boot=nfs` selects initramfs-tools' NFS boot:

```
earlycon console=ttyS0 boot=nfs root=/dev/nfs nfsroot=<server-ip>:/<path>,vers=3,tcp,hard rw ip=<FROST_LINUX_IP>
```

The initramfs's klibc `ipconfig` reads `ip=` in the kernel's syntax, so
`FROST_LINUX_IP` takes the same forms, and its `nfsmount` accepts the same
options and adds `nolock`, but leaves `rsize` and `wsize` to the server, where
the kernel's nfsroot asks for 4 KiB. The initramfs must hold the NFS client
and the NIC driver
([`frost-net10g/README.md`](frost-net10g/README.md#an-nfs-root-needs-the-module-in-the-initramfs)).
[`../docs/debian_nfsroot.md`](../docs/debian_nfsroot.md) builds, exports and
boots a Debian root this way, on Debian's own kernel.
Without `FROST_LINUX_NFSROOT`, the default bootargs run a
substitute initramfs's `/sbin/init`, as they do the test initramfs's; an
initramfs-tools initramfs, which starts at `/init`, boots only through the NFS
root above. Debian's kernel puts the DTB at `0x82200000`, which leaves
under 30 MiB of the 64 MiB default memory node for the initramfs (the test one
is about 5 MiB); the packer fails when it does not fit, and `load_software.py`
advertises the board's memory (see "Memory map").

`FROST_LINUX_MAC=aa:bb:cc:dd:ee:ff`, with or without an NFS root, replaces the
NIC's `local-mac-address` in the DTB (default `02:11:22:33:44:55`); each board
on a shared network needs its own locally administered address. The packer
rejects malformed, multicast and all-zero addresses, which the driver would
replace with a random one.
