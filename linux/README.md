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
boots through OpenSBI. For the build flow, see
[`buildroot-external/README.md`](buildroot-external/README.md); this file
defines what a kernel or other supervisor payload can rely on. The no-MMU
M-mode lane was retired in Phase 3; this is the only lane.

## Boot chain and entry state

After DDR calibration, the CPU leaves reset and fetches the boot shim from
address `0` in low BRAM. `frost_boot_image.py` writes the shim, assembles it,
and packs it into `sw.mem`. The shim enters the firmware:

```asm
li   a0, 0            # hart ID
li   a1, 0x81000000   # physical address of the DTB
li   t0, 0x80000000   # OpenSBI fw_jump entry
jr   t0
```

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
| `[0x4000_0000, +132 KiB)` | Native FROST MMIO window: UART, FIFOs, timer (`sw/lib/include/mmio.h` is the authoritative register map), and the DMA test engine's registers at `+0x2_0000` (not advertised to the kernel). |
| `[0x4000_1000, +0x100)` | ns16550a UART face (`reg-shift = 2`, `reg-io-width = 4`) aliasing the native UART. Takes PLIC source 1. |
| `[0x4001_0000, +0xC000)` | SiFive-layout CLINT alias (`sifive,clint0`): `msip` at `+0x0000`, `mtimecmp` at `+0x4000`, `mtime` at `+0xBFF8`. Same physical registers as the native timer block. The DTB and RTL decode both end after `mtime`, at the `0x4001_C000` top of the MMIO window. |
| `[0x4400_0000, +4 MiB)` | PLIC (M and S contexts for hart 0; source 1 is the ns16550 UART, source 2 the board's external-interrupt pin, source 3 the DMA test engine). The DTB advertises both contexts and `riscv,ndev = 3`; OpenSBI hides the M context from the kernel. |
| `[0x8000_0000, +1 GiB)` | Cached DDR. The DTB advertises `memory@80000000` with 64 MiB (`MEM_SIZE` in `frost_boot_image.py`), not the full physical DDR. |

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
(the rv64 kernel's 2 MiB PMD alignment; a Linux `Image` is checked against its
header's `image_size`), the DTB at `+16 MiB` in a 64 KiB slot (OpenSBI grows
it in place), and the initramfs, when present, at `+16 MiB + 64 KiB`.

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
(`CONFIG_RISCV_PMU_SBI`), which is what `perf stat -e cycles,instructions`
uses; a `riscv,pmu` device-tree node maps those two events onto the fixed
counters. QEMU resets `mcounteren` to 0, so direct userspace reads raise an
illegal-instruction signal under `linux-boot-qemu-mmu`, and `frost_stress`
reports `counters=unavailable` there. On FROST the phase must run:
`linux_boot_soak.py` fails a boot that reports counters unavailable.

## Kernel configuration contract

The kernel configuration is `board/frost/linux-frost.config` (under
`buildroot-external/`), applied as Buildroot's custom kernel config. The
load-bearing options:

| Option | Why |
|---|---|
| `CONFIG_MMU`, `CONFIG_ARCH_RV64I` + `CONFIG_64BIT` | Sv39 rv64 kernel. `CONFIG_NONPORTABLE` and `CONFIG_RISCV_M_MODE` must stay unset: this is an ordinary S-mode kernel, not the retired M-mode build. |
| `CONFIG_RISCV_SBI` | Boots under OpenSBI and calls the SBI interface. |
| `CONFIG_RISCV_PMU`, `CONFIG_RISCV_PMU_SBI` | `perf` over the SBI PMU's cycle and instret counters. |
| `CONFIG_RISCV_EMULATED_UNALIGNED_ACCESS` | Misaligned accesses once the supervisor takes FWFT delegation. |
| `CONFIG_BINFMT_ELF` | Ordinary ELF userspace. |
| `CONFIG_BLK_DEV_INITRD` | External initramfs via `linux,initrd-*`. |
| `CONFIG_SERIAL_8250[_CONSOLE]`, `CONFIG_SERIAL_OF_PLATFORM`, `NR_UARTS=1` | Console on the ns16550a face, bound from the DT. |
| `CONFIG_OF`, `CONFIG_OF_EARLY_FLATTREE` | DT-driven probe; earlycon (`earlycon=uart8250,mmio32,0x40001000`). |

## Bring-up probe

The initramfs also runs `frost_sigprobe` from inittab, one line per
signal-return variant (`FROST_SIGPROBE v<n> ...: ok`), because the first board
boot lost busybox to a SIGILL at the vDSO sigreturn trampoline after a child
exit; see `buildroot-external/package/frost-stress/src/frost_sigprobe.c`.

## Consumers

`sw.{mem,txt}` (shim, low BRAM) and `sw_ddr.{mem,txt}` (DDR image) are
loaded by the cocotb `linux_boot` simulation and by
`fpga/load_software/load_software.py` over JTAG. The simulation also reads
`sw64.mem`, the dword-paired copy of `sw.mem` for the 64-bit data BRAM,
which the app Makefile derives. The images come from `linux/build-mmu` and
the `frost_rv64_defconfig` Buildroot config
([`buildroot-external/README.md`](buildroot-external/README.md)).

At boot, inittab runs `frost_stress --boot`, which prints the
`FROST_USERSPACE_STRESS_PASS`/`_FAIL` token before the login prompt; the
QEMU CI job and `fpga/linux_boot_soak.py` assert it. On hardware the
regression's Linux stage requires that token before the login prompt, then
logs in as root and runs `perf stat` on the cycle and instruction counters.
The payload's summary line carries per-boot Zicntr evidence for hardware
performance tracking: `cycles=`/`instret=`/`time=`/`ipc_x1000=` deltas around
a fixed workload (see "Counters and mcounteren").
