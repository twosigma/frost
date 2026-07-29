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

The contract between the FROST SoC + loaders and the no-MMU M-mode Linux
kernel. The build flow lives in
[`buildroot-external/README.md`](buildroot-external/README.md); this file
documents what any kernel (or other supervisor payload) can rely on.

## Boot chain and entry state

The CPU is held in reset until the DDR controller calibrates, then fetches
from address `0` in the fast low BRAM, where the loader has placed the boot
shim (`sw/apps/linux_boot/frost_boot_shim.S`, packed into `sw.mem`). The shim
implements the standard bare-metal RISC-V Linux boot protocol and nothing
else:

```asm
li   a0, 0            # hart ID
li   a1, 0x80800000   # physical address of the DTB
li   t0, 0x80000000   # kernel entry (Image base in cached DDR)
jr   t0
```

Entry state at the kernel's first instruction: M-mode, `mstatus.MIE=0`,
`mtvec`/`mepc` unwritten, `mtimecmp` reset to all-ones (no timer interrupt
pending until software arms one), instruction fetch running from cached DDR
through the L1I. There is no SBI firmware and no S-mode: the kernel owns
M-mode (`CONFIG_RISCV_M_MODE`).

## Memory map

Identical on every board and in simulation (the cache hierarchy behind it is
opaque to software):

| Range | What |
|---|---|
| `[0x0000_0000, 256 KiB)` | Fast uncached BRAM, 1-cycle. Holds the boot shim; free for supervisor use after boot. |
| `[0x4000_0000, +MMIO)` | Native FROST MMIO block: UART, FIFOs, timer (`sw/lib/include/mmio.h` is the authoritative map). |
| `[0x4000_1000, +0x100)` | ns16550a UART face (`reg-shift = 2`, `reg-io-width = 4`) aliasing the native UART. Polled — no interrupt line. |
| `[0x4001_0000, +0x10000)` | SiFive-layout CLINT alias (`sifive,clint0`): `msip` at `+0x0000`, `mtimecmp` at `+0x4000`, `mtime` at `+0xBFF8`. Same physical registers as the native timer block. |
| `[0x8000_0000, +1 GiB)` | Cached DDR. The DTB advertises `memory@80000000` with **64 MiB** (`MEM_SIZE` in `build_fpga_boot.py`), not the full physical DDR. |

DDR layout as packed by `build_fpga_boot.py` (offsets from `0x8000_0000`):
kernel `Image` at `+0`, DTB at `+8 MiB` (`0x8080_0000`), gzip'd initramfs
cpio at `+8 MiB + 64 KiB` (`0x8081_0000`, bounds passed via
`linux,initrd-start/end`). The kernel image must stay under 8 MiB
(currently ~5 MiB) or the DTB/initramfs bases must move.

## Interrupts and time

M-mode only, no PLIC. The DT wires the CLINT to the hart's `cpu-intc` for
machine software (cause 3) and machine timer (cause 7) interrupts;
`CONFIG_RISCV_TIMER` drives clocksource/clockevents directly from
`mtime`/`mtimecmp` (no SBI calls). The dword-aligned CLINT registers
support native 64-bit access on the 64-bit data tier: an 8-byte load of
`mtime` is single-copy atomic (rv32 code may still use the classic
hi/lo/hi word loop; RV64 code reads it in one `ld` with no tearing
exposure), and an 8-byte `mtimecmp` store lands atomically.
`timebase-frequency` equals the CPU clock
— `mtime` increments every core cycle, no divider (simulation builds may
scale it via the `SIM_TIMER_SPEEDUP` parameter) — and is stamped into the
DTB by the packer from `FPGA_CPU_CLK_FREQ` (133.33 MHz Genesys2 default, 300 MHz
X3), as is the UART `clock-frequency`. The UART has no interrupt line; the
8250 driver runs polled.

## Advertised ISA

The DTB advertises
`rv32imafdc_zicsr_zifencei_zicntr_zba_zbb_zbs_zbkb_zicond_zihintpause`
(M/U privilege, no S-mode). Userspace is no-MMU bFLT (`CONFIG_BINFMT_FLAT`):
no `fork` (use `vfork`+`exec`), shared memory via `MAP_SHARED` file mappings.

## Counters and mcounteren

FROST implements the Zicntr counters (`cycle`/`time`/`instret` plus high
halves; `time` reads the same `mtime` the CLINT exposes, so it ticks at
`timebase-frequency` = the CPU clock) and `mcounteren` (0x306) to gate
U-mode access to them:

- WARL: only the CY/TM/IR bits exist; bits 31:3 read as zero and discard
  writes (there are no hpmcounters — like every unimplemented CSR they
  read 0 and absorb writes rather than trapping).
- **Reset value `0x7`** — all three counters are U-readable out of reset.
  This is the load-bearing platform choice: the kernel never writes
  `mcounteren` (audited in the pinned 6.18.7 tree), so the reset value is
  what userspace gets, and `rdcycle`/`rdtime`/`rdinstret` work in plain
  user programs with no kernel cooperation.
- With a bit clear, a U-mode access to that counter's CSRs (either half)
  is an illegal instruction (mcause=2, mtval=0). M-mode access is never
  gated.

QEMU differs: it resets `mcounteren` to 0, and since the M-mode kernel
never sets it, userspace counter reads die with an illegal-instruction
signal under the `linux-boot-qemu` job. The `frost-stress` payload guards
its counter phase accordingly (`counters=unavailable`); on FROST the phase
always runs and the hardware soak fails a boot that had to skip it.

## Kernel configuration contract

`board/frost/linux-nommu-base.config` (derived from Buildroot's
`qemu/riscv32-virt`) plus `board/frost/linux-nommu-frost.config.fragment`.
The load-bearing options:

| Option | Why |
|---|---|
| `CONFIG_NONPORTABLE`, `CONFIG_RISCV_M_MODE`, `CONFIG_ARCH_RV32I` | M-mode, no-MMU, RV32 kernel. |
| `CONFIG_BINFMT_FLAT` | bFLT userspace. |
| `CONFIG_BLK_DEV_INITRD`, `CONFIG_RD_GZIP` | External gzip'd initramfs via `linux,initrd-*`. |
| `CONFIG_SERIAL_8250[_CONSOLE]`, `CONFIG_SERIAL_OF_PLATFORM`, `NR_UARTS=1` | Console on the ns16550a face, bound from the DT. |
| `CONFIG_RISCV_TIMER` | CLINT-driven clocksource in M-mode. |
| `CONFIG_OF`, `CONFIG_OF_EARLY_FLATTREE` | DT-driven probe; earlycon (`earlycon=uart8250,mmio32,0x40001000`). |
| `CONFIG_SOC_VIRT` | Boot glue carried from the virt base config; revisit if a dedicated FROST machine is added. |

## Consumers

`sw.{mem,txt}` (shim, low BRAM) and `sw_ddr.{mem,txt}` (DDR image) are
loaded by the cocotb `linux_boot` simulation and by
`fpga/load_software/load_software.py` over JTAG. After packing,
`patch_linux_image.py` applies the mandatory initramfs fixups and any
env-gated bring-up hooks (see its docstring). At boot, userspace runs the
`frost-stress` payload from inittab and prints the
`FROST_USERSPACE_STRESS_PASS`/`_FAIL` token before the login prompt; the
QEMU CI job and `fpga/linux_boot_soak.py` assert it. The payload's summary
line also carries per-boot Zicntr evidence
(`cycles=`/`instret=`/`time=`/`ipc_x1000=` deltas around a fixed workload —
see "Counters and mcounteren"), giving every hardware soak quantitative
performance numbers for free.
