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

Boot contract between the FROST SoC/loaders and the no-MMU M-mode Linux
kernel. For the build flow, see
[`buildroot-external/README.md`](buildroot-external/README.md); this file
defines what a kernel or other supervisor payload can rely on.

## Boot chain and entry state

After DDR calibration, the CPU leaves reset and fetches the boot shim from
address `0` in low BRAM. `build_fpga_boot.py` writes the shim as
`sw/apps/linux_boot/frost_boot_shim.S`, assembles it, and packs it into
`sw.mem`. The shim implements the bare-metal RISC-V Linux boot protocol:

```asm
li   a0, 0            # hart ID
li   a1, 0x80800000   # physical address of the DTB
li   t0, 0x80000000   # kernel entry (Image base in cached DDR)
jr   t0
```

Entry state at the kernel's first instruction: M-mode, `mstatus.MIE=0`,
`mtvec`/`mepc` unwritten, `mtimecmp` reset to all-ones (no timer interrupt
pending until software arms one), instruction fetch running from cached DDR
through the L1I. There is no SBI firmware. The kernel runs in M-mode
(`CONFIG_RISCV_M_MODE`) and does not use the core's S-mode or Sv39
translation.

## Memory map

The map is identical across board integrations and simulation; caches are
transparent to software.

| Range | What |
|---|---|
| `[0x0000_0000, 256 KiB)` | Uncached BRAM. Data access is 1-cycle; fetch windows wholly below 64 KiB are 1-cycle and other low-BRAM windows repeat once. Holds the boot shim; free for supervisor use after boot. |
| `[0x4000_0000, +112 KiB)` | Native FROST MMIO window: UART, FIFOs, timer (`sw/lib/include/mmio.h` is the authoritative register map). |
| `[0x4000_1000, +0x100)` | ns16550a UART face (`reg-shift = 2`, `reg-io-width = 4`) aliasing the native UART. Polled; the DT gives it no interrupt line. |
| `[0x4001_0000, +0xC000)` | SiFive-layout CLINT alias (`sifive,clint0`): `msip` at `+0x0000`, `mtimecmp` at `+0x4000`, `mtime` at `+0xBFF8`. Same physical registers as the native timer block. The DTB and RTL decode both end after `mtime`, at the `0x4001_C000` top of the MMIO window. |
| `[0x4400_0000, +4 MiB)` | PLIC (M and S contexts for hart 0; source 1 is the ns16550 UART, source 2 the board's external-interrupt pin). Absent from the DTB; this kernel does not use it. |
| `[0x8000_0000, +1 GiB)` | Cached DDR. The DTB advertises `memory@80000000` with 64 MiB (`MEM_SIZE` in `build_fpga_boot.py`), not the full physical DDR. |

The PMA map has three regions: the BRAM, the device quadrant
`[0x4000_0000, 0x8000_0000)`, and cached DDR. An access anywhere else,
including any address with bits [63:32] set, raises a precise access fault
(instruction/load/store causes 1/5/7 with the exact address in `mtval`).
Instruction fetch from the device quadrant is also an access fault.
Out-of-map addresses do not alias onto the map.

DDR layout as packed by `build_fpga_boot.py` (offsets from `0x8000_0000`):
kernel `Image` at `+0`, DTB at `+8 MiB` (`0x8080_0000`), gzip'd initramfs
cpio at `+8 MiB + 64 KiB` (`0x8081_0000`, bounds passed via
`linux,initrd-start/end`). The kernel image must stay under 8 MiB
(currently ~5 MiB) or the DTB/initramfs bases must move; the packer asserts
that fit, and that the DTB clears the initramfs slot.

## Interrupts and time

The DT advertises no PLIC. It wires the CLINT to the hart's `cpu-intc` for
machine software (cause 3) and machine timer (cause 7) interrupts, and
`CONFIG_RISCV_TIMER` drives clocksource/clockevents from `mtime`/`mtimecmp`
with no SBI calls. The dword-aligned CLINT registers support native 64-bit
access: `ld` reads `mtime` atomically, without the rv32 hi/lo/hi loop, and
an 8-byte `mtimecmp` store lands atomically. `timebase-frequency` equals
the CPU clock: `mtime` increments every core cycle with no divider
(simulation builds may scale it via the `SIM_TIMER_SPEEDUP` parameter). The
packer stamps it into the DTB from `FPGA_CPU_CLK_FREQ` (300 MHz by default for
X3), and the UART `clock-frequency` the same way. The UART
node carries no interrupt, so the 8250 driver runs polled;
`FROST_LINUX_SERIAL_IRQ_MODE=cpu-local-meip` makes `patch_linux_image.py`
wire it to `cpu-intc` line 11 as a bring-up hook.

## Advertised ISA

The DTB advertises
`rv64imafdc_zicsr_zifencei_zicntr_zba_zbb_zbs_zbkb_zicond_zihintpause`,
with no supervisor extension and no `mmu-type`, so the DT describes an M/U
hart. Userspace is no-MMU bFLT (`CONFIG_BINFMT_FLAT`): no `fork` (use
`vfork`+`exec`), shared memory via `MAP_SHARED` file mappings.

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
- Both registers reset to `0x7`, so all three counters are U-readable out
  of reset. The pinned 6.18.7 kernel writes neither (its `scounteren` write
  in `head.S` is compiled out under `CONFIG_RISCV_M_MODE`), so userspace
  inherits the reset value and can use `rdcycle`/`rdtime`/`rdinstret`
  without kernel support.
- With a bit clear in either register, a U-mode access to that counter's
  CSR is an illegal instruction (mcause=2, mtval=0).

QEMU resets `mcounteren` to 0, so userspace reads raise an illegal-instruction
signal under `linux-boot-qemu`, and `frost_stress` reports
`counters=unavailable` there. On FROST the phase must run: `linux_boot_soak.py`
fails a boot that reports counters unavailable.

## Kernel configuration contract

The configuration merges `board/frost/linux-nommu-frost.config.fragment` onto
`board/frost/linux-nommu-base-rv64.config` (both under `buildroot-external/`).
The base is a copy of upstream Buildroot's
`board/qemu/riscv64-virt/linux-nommu.config` mini-config; its `-rv64` suffix
dates from when an rv32 lane existed. The load-bearing options:

| Option | Why |
|---|---|
| `CONFIG_NONPORTABLE`, `CONFIG_RISCV_M_MODE`, `CONFIG_ARCH_RV64I` + `CONFIG_64BIT` | M-mode, no-MMU rv64 kernel. |
| `CONFIG_BINFMT_FLAT` | bFLT userspace. |
| `CONFIG_BLK_DEV_INITRD`, `CONFIG_RD_GZIP` | External gzip'd initramfs via `linux,initrd-*`. |
| `CONFIG_SERIAL_8250[_CONSOLE]`, `CONFIG_SERIAL_OF_PLATFORM`, `NR_UARTS=1` | Console on the ns16550a face, bound from the DT. |
| `CONFIG_RISCV_TIMER` | CLINT-driven clocksource in M-mode. |
| `CONFIG_OF`, `CONFIG_OF_EARLY_FLATTREE` | DT-driven probe; earlycon (`earlycon=uart8250,mmio32,0x40001000`). |
| `CONFIG_SOC_VIRT` | Boot glue carried from the virt base config; revisit if a dedicated FROST machine is added. |

## OpenSBI boot chain (the MMU lane)

The MMU Linux lane boots through OpenSBI as the M-mode firmware. The no-MMU
contract above stays the default lane until Phase 3 M8 retires it;
`FROST_LINUX_LANE=mmu` selects this one. The firmware side is exercised on
its own by the cocotb `opensbi_smoke` test (a bare S-mode payload under the
real firmware), the whole chain by the MMU boot jobs in CI.

- Firmware: the unmodified OpenSBI v1.7 generic platform from the
  `linux/opensbi` submodule, built by `linux/opensbi_build.py` with the
  Linux-targeted Bootlin toolchain in the Docker image (OpenSBI links as a
  PIE, which the bare-metal xPack linker cannot do). It is built with
  `FW_TEXT_START=0x80000000`, the default `FW_JUMP_OFFSET=0x200000`, an
  empty `FW_JUMP_FDT_OFFSET` (so fw_jump passes the shim's `a1`, the DTB
  address, through untouched), the driver set in `linux/opensbi_frost_defconfig`
  (uart8250, PLIC, ACLINT mswi/mtimer only), and libfdt's assume mask
  (`FDT_ASSUME_MASK=7`), the last two because OpenSBI's device-tree probing
  otherwise costs millions of simulated cycles per boot.
- Layout, packed by `buildroot-external/board/frost/frost_boot_image.py`
  (offsets from `0x8000_0000`): `fw_jump.bin` at `+0` (at most 1 MiB; its
  runtime rw/heap/scratch regions follow it and are reserved by OpenSBI's
  `reserved-memory` fixup), the S-mode payload or kernel `Image` at `+2 MiB`
  (the rv64 kernel's 2 MiB PMD alignment; a Linux `Image` is checked against
  its header's `image_size`), the DTB at `+16 MiB` in a 64 KiB slot (OpenSBI
  grows it in place), and the initramfs, when present, at `+16 MiB + 64 KiB`.
  The shim is `a0=0; a1=0x8100_0000; jr 0x8000_0000`.
- Device tree: `riscv,isa-extensions` gains `sstc` and `svade`, the cpu
  carries `mmu-type = "riscv,sv39"`, the ns16550a takes PLIC source 1, and
  the PLIC node advertises the M and S contexts (`&cpu0_intc 11`, `9`);
  OpenSBI hides the M context from the kernel. The CLINT node is unchanged.
- Entry state handed to the payload: S-mode, `satp` Bare, `sstatus.SIE=0`,
  `mideleg` = SSI/STI/SEI, `medeleg` = misaligned-fetch, breakpoint,
  U-ecall and the three page faults, `mcounteren` and `scounteren` = 0x7,
  `menvcfg.STCE=1` (OpenSBI only programs `menvcfg` on a hart it classifies
  as privileged v1.12, which is why `mcountinhibit` exists), and misaligned
  loads/stores emulated in M-mode until the supervisor asks the FWFT
  extension to delegate them (Linux does).
- Running the lane: `FROST_LINUX_LANE=mmu` selects it wherever `linux_boot`
  is built (`sw/apps/linux_boot`, the cocotb test, `load_software.py`,
  `hw_regression.py`); the images come from `linux/build-mmu` and the
  `frost_rv64_defconfig` Buildroot config (`buildroot-external/README.md`).
  On hardware the regression's Linux stage then also requires the stress
  token before the login prompt, logs in as root, and runs `perf stat` on
  the cycle and instruction counters; `fpga/linux_boot_soak.py` scores the
  same token across repeated boots on either lane.

## Consumers

`sw.{mem,txt}` (shim, low BRAM) and `sw_ddr.{mem,txt}` (DDR image) are
loaded by the cocotb `linux_boot` simulation and by
`fpga/load_software/load_software.py` over JTAG. The simulation also reads
`sw64.mem`, the dword-paired copy of `sw.mem` for the 64-bit data BRAM,
which the app Makefile derives. After packing, `patch_linux_image.py`
applies the mandatory initramfs fixups and any env-gated bring-up hooks. At
boot, inittab runs `frost_stress --boot`, which prints the
`FROST_USERSPACE_STRESS_PASS`/`_FAIL` token before the login prompt; the
QEMU CI job and `fpga/linux_boot_soak.py` assert it. The payload's summary
line carries per-boot Zicntr evidence for hardware performance tracking:
`cycles=`/`instret=`/`time=`/`ipc_x1000=` deltas around a fixed workload
(see "Counters and mcounteren").
