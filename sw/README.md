# FROST Software

Bare-metal software for FROST's RV64 core: a small freestanding C runtime in
`lib/`, the shared build rules, linker scripts, and startup code in `common/`,
and the applications in `apps/`. The applications range from Hello World,
CoreMark, and CoreMark-PRO to directed tests, many of them minimal
reproducers of specific hardware bugs. See [Linux](../linux/README.md) for
operating-system images and [CONTRIBUTING.md](CONTRIBUTING.md) to add an
application or library.

## Building

Simulation and the FPGA loader build applications on demand. To build by
hand, run the [pinned toolchain](../docs/tooling.md#shared-risc-v-toolchain)
through `scripts/frost.py`:

```bash
./scripts/frost.py run python3 sw/apps/compile_app.py hello_world                   # one app, low BRAM
./scripts/frost.py run python3 sw/apps/compile_app.py hello_world --mem-config ddr  # one app, cached DDR
./scripts/frost.py run python3 sw/apps/build_all_apps.py                            # every ordinary app
./scripts/frost.py run python3 sw/apps/build_all_apps.py --list                     # what it builds and skips
```

`compile_app.py` always cleans first and builds the simulation variant
(CoreMark, for example, runs one iteration). `build_all_apps.py` cleans and
builds every app directory with a Makefile except the parameterized
compliance and torture suites, which have their own
[test runners](../tests/README.md), and `linux_boot`, whose first build
downloads a toolchain and kernel (`--include-linux-boot` adds it).
`clean_all_apps.py` runs `make clean` in every app.

With the toolchain on your PATH, `make -C sw/apps/<app>` works natively.
Incremental builds track the compiler, flags, memory tier, linker script,
included headers, and (for CoreMark-PRO) the selected workload, so changing
any of them rebuilds.

### Build options

| Variable | Default | Purpose |
|----------|---------|---------|
| `RISCV_PREFIX` | `riscv64-linux-` | Toolchain prefix |
| `MEM_CONFIG` | `bram` | Program placement: `bram` or `ddr` |
| `OPT_LEVEL` | `-O3` | Optimization level |
| `UNROLL_LOOPS` | `-funroll-loops` | Set empty to disable loop unrolling |
| `MABI` | `lp64d` | ABI |
| `FPGA_CPU_CLK_FREQ` | `322265625` | CPU clock in Hz; the FPGA loader sets it from the board, or from `FROST_CPU_CLK_HZ` for a [divided-clock build](../fpga/README.md#divided-clock-builds) such as `161132812` |
| `FROST_DEBUG` | `0` | `1` builds with `-Og -g3` for source debugging |
| `FROST_DEBUG_FRAME_POINTER` | `1` | Keep frame pointers in debug C builds |
| `APP_TUNE_FLAGS` | empty | Compiler flags placed after the defaults, so they override them |
| `EXTRA_CFLAGS` / `EXTRA_LDFLAGS` | empty | Additional compile and link flags |
| `EXTRA_ASM_SRC` | empty | Assembly sources linked with the C startup code |
| `LINKER_SCRIPT` | set by `MEM_CONFIG` | Replaces the common linker script |
| `GENERATE_IMEM_INIT` | `0` | `1` also writes the split instruction-BRAM init files for Vivado |

`-march` is `rv64` followed by `FROST_MARCH_EXTENSIONS`, which defaults to
`imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause`. An app
sets it, or `APP_TUNE_FLAGS`, before including `common.mk`. The `FROST_DEBUG=1`
flags come after the tuning flags, so debug builds stay debuggable. Backends
that build their own flags take the names from `common/arch.mk`:
`FROST_XLEN_PREFIX` (`rv64`), `FROST_INT_ABI` (`lp64`), `FROST_FP_ABI`
(`lp64d`), and `FROST_LD_EMULATION` (`elf64lriscv`).

### Memory configuration

| `MEM_CONFIG` | Linker script | Placement |
|--------------|---------------|-----------|
| `bram` | `common/link.ld` | Code and data in low BRAM; only opt-in `.ddr_*` sections and the heap in DDR |
| `ddr` | `common/link_ddr.ld` | The whole program in DDR, entered through a boot stub in low BRAM, so code and static data go through the caches |

Both linker scripts place the stack in low BRAM. Select the tier with
`FROST_COCOTB_MEM_CONFIG=ddr` in simulation or `--ddr` on the FPGA loader.
Some apps choose for themselves: several interrupt and trap tests force
`MEM_CONFIG=ddr` in their Makefiles, and apps with their own linker scripts,
such as `opensbi_smoke`, keep a fixed layout.

### Build outputs

| File | Contents |
|------|----------|
| `sw.elf` | Executable, with DWARF when `FROST_DEBUG=1` |
| `sw.mem` | Low-BRAM image for `$readmemh`, in 32-bit words |
| `sw64.mem` | The same image in 64-bit words, for the 64-bit data BRAM |
| `sw.txt` / `sw.bin` | Low-BRAM image for the JTAG loader / raw binary |
| `sw_ddr.mem` / `sw_ddr.txt` / `sw_ddr.bin` | DDR image for simulation / the JTAG loader / raw, relative to `0x80000000` |
| `sw.S` | Disassembly |
| `sw_imem_*.mem` | Split instruction-BRAM init files for Vivado, with `GENERATE_IMEM_INIT=1` |

When a program places nothing in DDR, `sw_ddr.mem` holds one zero word, so
`$readmemh` always finds a file, and `sw_ddr.txt` is empty. The JTAG images
are dense 32-bit hex words with no address records.

## Memory map

Simulation and the board use the same address map. The default
[linker script](common/link.ld) divides it as follows:

| Region | Address | Size | Use |
|--------|---------|------|-----|
| ROM | `0x00000000` | 95 KiB | Code and read-only data |
| DEBUG | `0x00017C00` | 1 KiB | Reserved for the debug module's execution area |
| RAM | `0x00018000` | 160 KiB | Data, BSS, and stack |
| DDR | `0x80000000` | 1 GiB | Cached code and data, then the heap |

ROM, DEBUG, and RAM make up the 256 KiB low BRAM, which is uncached. The
linker reserves 112 KiB of RAM for the stack and fails the link if data and
BSS reach into it. DDR holds `.ddr_text`, `.ddr_rodata`, `.ddr_data`, and
`.ddr_bss`, followed by the heap, which runs to the end of the region. The
lowest loaded DDR section must start at `0x80000000`, because the JTAG image
is dense from the region base. Move a large object to DDR with a `.ddr_*`
section attribute, such as `__attribute__((section(".ddr_rodata")))`, or a
per-object linker rule.

Low BRAM keeps separate instruction and data copies, so ordinary stores never
change the code being fetched. Self-modifying code must live in DDR and run
`fence.i` after writing it; `fence.i` drains stores, writes back the L1D, and
invalidates the L1I and the fetch buffer. Stores made in Debug Mode, such as
a debugger's software breakpoints, are mirrored into the BRAM instruction
copy.

### Peripheral addresses

| Peripheral | Address | Description |
|------------|---------|-------------|
| UART_TX | `0x40000000` | UART transmit register (write-only) |
| UART_RX_DATA | `0x40000004` | UART receive data; a read pops one byte |
| FIFO0 | `0x40000008` | MMIO FIFO channel 0 |
| FIFO1 | `0x4000000C` | MMIO FIFO channel 1 |
| MTIME_LO | `0x40000010` | Machine timer, low 32 bits |
| MTIME_HI | `0x40000014` | Machine timer, high 32 bits |
| MTIMECMP_LO | `0x40000018` | Timer compare, low 32 bits |
| MTIMECMP_HI | `0x4000001C` | Timer compare, high 32 bits |
| MSIP | `0x40000020` | Machine software interrupt pending |
| UART_RX_STATUS | `0x40000024` | Bit 0: receive data available |
| UART_TX_STATUS | `0x40000028` | Bit 0: TX ready, at least 64 more bytes fit in the transmit FIFO |
| NS16550 | `0x40001000` | 16550-compatible UART registers, `0x40001000` to `0x4000101C` |
| CLINT | `0x40010000` | SiFive CLINT-compatible alias of MSIP, `mtimecmp`, and `mtime`, for Linux |
| DMA test engine | `0x40020000` | Coherent DMA copy and fill engine |
| NIC | `0x40030000` | 10G Ethernet control, descriptor rings, and counters |
| PLIC | `0x44000000` | Platform-level interrupt controller: 4 MiB window, M and S contexts for hart 0 |

[`mmio.h`](lib/include/mmio.h) defines `volatile` accessors named after the
native registers, `UART_TX` through `UART_TX_STATUS`. Use naturally aligned
accesses. Misaligned loads and stores trap once a trap vector is installed (a
nonzero `mtvec` base); before that, the hardware does not check alignment. See
the
[RTL bus contract](../hw/rtl/README.md#data-tier-bus-contract) for access
widths, ordering, and device-read side effects.

## Startup sequence

`common/crt0.S` sets `sp` and `gp`, copies `.data` from its load image in ROM
to RAM (a no-op in DDR builds, where `.data` loads in place), zeroes `.sbss`,
`.bss`, and `.ddr_bss`, and calls `main()`, spinning if it returns.
`.ddr_data` is loaded in place and never copied. With `MEM_CONFIG=ddr`, a
boot stub at address 0 jumps to `_start` at `0x80000000`. Standalone assembly
apps supply their own `_start`. The compliance suites, FreeRTOS, and OpenSBI
use their own linker scripts on the same memory map.

## Libraries

Each header in [lib/include/](lib/include/) documents its API. The runtime is
freestanding: add the matching `lib/src/*.c` file to `SRC_C` for `uart`,
`string`, `ctype`, `stdlib`, `memory`, `sprintf`, and `fix`. The other headers
need no source file, except as noted for `tomasulo_profile.h`. `stdlib.c`
calls into `ctype.c`, `memory.c` and `sprintf.c` call into `string.c`, and
`strdup` needs `memory.c`.

| Header | Purpose |
|--------|---------|
| [uart.h](lib/include/uart.h) | Console I/O and `uart_printf`; the hardware UART runs at 115200 baud, 8N1 |
| [string.h](lib/include/string.h), [ctype.h](lib/include/ctype.h) | String and memory functions, character classification |
| [stdlib.h](lib/include/stdlib.h), [limits.h](lib/include/limits.h) | Numeric conversion and LP64 integer limits |
| [memory.h](lib/include/memory.h) | Arena allocator and a coalescing `malloc`/`free` heap in DDR |
| [sprintf.h](lib/include/sprintf.h) | `sprintf`/`snprintf` without stdio; link with `EXTRA_LDFLAGS := -lgcc` |
| [timer.h](lib/include/timer.h), [csr.h](lib/include/csr.h) | Cycle timing, counters, and CSR access |
| [trap.h](lib/include/trap.h) | Trap handlers, interrupt enables, `mtime`/`mtimecmp`, and software interrupts |
| [sync.h](lib/include/sync.h) | `fence` and `fence.i` |
| [mmio.h](lib/include/mmio.h) | Peripheral register names |
| [fifo.h](lib/include/fifo.h) | The two MMIO FIFOs |
| [nic.h](lib/include/nic.h), [dma_engine.h](lib/include/dma_engine.h) | NIC and DMA test engine registers |
| [fix.h](lib/include/fix.h) | FIX timestamp and price parsing |
| [tomasulo_profile.h](lib/include/tomasulo_profile.h) | [Performance-counter API](../hw/rtl/cpu_and_mem/cpu/cpu_ooo/perf/README.md); prints through `uart.c`, and the report and cache-counter functions need `tomasulo_profile_cache.c` |

Library limits:

- `uart_printf` handles `%c`, `%s`, signed and unsigned decimal, and hex
  (with `l` and `ll`), right-aligned widths up to 255, and zero-padding for
  integers. `%f` needs `-DUART_PRINTF_ENABLE_FLOAT=1`; its precision is
  capped at 9, and finite magnitudes of 2^64 or more print as `ovf` or `-ovf`.
- `snprintf` supports integer, floating-point, string, character, and pointer
  conversions, the standard flags, `*` width and precision, and the
  `hh`/`h`/`l`/`ll`/`z`/`t` modifiers. Floating-point output is correctly
  rounded to nearest (ties to even) for every finite double; the dynamic
  rounding mode in `frm` does not change it. If the full output would be
  longer than `INT_MAX`, `snprintf` returns -1 and still terminates a
  nonempty buffer.
- `strtol` accepts base 0 or 2 to 36 and saturates on overflow. An invalid
  base or a string with no digits returns 0 and sets `endptr` to the input.
- A failed `arena_alloc` returns `start == NULL` and zero capacity. `malloc`
  returns `NULL` for zero-size, overflowing, or oversized requests without
  consuming heap.
- `rdcycle()`, `rdtime()`, and `rdinstret()` return the low 32 bits, and the
  `*64()` forms read the whole counter. The low word of `cycle` wraps after
  about 13.3 seconds at 322.265625 MHz. RV64 has no `cycleh`-style CSRs, and
  reading one traps. `time` reads `mtime`, which software can rewrite and
  simulation can speed up, so measure intervals with `cycle`.

## Testing and debugging

Test apps print `<<PASS>>` or `<<FAIL>>` on the UART. The simulation harness
fails a program that prints `<<FAIL>>` or exceeds its cycle budget: 500,000
cycles unless the app has its own, and `COCOTB_MAX_CYCLES` changes the
default. Hello World passes on its greeting, and `uart_echo` passes when it
echoes input the harness injects.

In the BRAM tier the harness normally runs each program twice, with a reset
but no reload in between, so a program must reinitialize its own state. `crt0.S`
restores `.data` and clears the BSS sections, but `.ddr_data` is not
reinitialized and may still hold writes from the first run. DDR-tier
programs run once.

```bash
./scripts/frost.py cocotb hello_world                               # simulate from low BRAM
FROST_COCOTB_MEM_CONFIG=ddr ./scripts/frost.py cocotb hello_world   # simulate from cached DDR
./fpga/load_software/load_software.py x3 hello_world --debug        # debug build on the board (native)
```

Debug builds (`FROST_DEBUG=1`, or the loader's `--debug`) use `-Og -g3`;
don't report benchmark scores from them. `isa_test` builds without frame
pointers because its tests clobber `s0`, and hand-written assembly, trap
handlers, and FreeRTOS context switches can cut a backtrace short. The
[debugger guide](../tools/vscode-frost/README.md) lists which applications
can be debugged and where each one first stops.

## Applications

`./scripts/frost.py cocotb --list-tests` lists the simulation targets, and
`load_software.py --help` lists the applications the FPGA loader accepts.

| App | Description |
|-----|-------------|
| `ad_fault_test/` | Sv39 A/D faults: after a live PTE's A or D bit is cleared and fenced, the next access that needs the bit must page-fault (the walker never sets A or D) |
| `amo_irq_torture/` | Timer interrupts swept across cached-DDR AMO bursts; counts every update to catch lost or duplicated ones |
| `arch_test/` | riscv-arch-test cases compared with committed Spike signatures; built per test with `TEST_SRC` |
| `branch_pred_test/` | Self-checking branch, loop, call, and indirect-jump cases in assembly |
| `c_ext_test/` | Calls and returns through mixed 16- and 32-bit code, plus value checks of the RV64C-only encodings |
| `call_stress/` | Repeated and nested calls and returns, built with compressed instructions |
| `cf_ext_test/` | Compressed double-precision FP loads and stores (Zcd) |
| `clint_test/` | SiFive CLINT alias: writes reach the native timer registers, and a timer interrupt armed through the alias fires |
| `coremark/` | EEMBC CoreMark, built without the C extension by default; see the [measurement sweeps](../docs/single_core_performance.md#reproducing-and-retaining-measurements) and [Spike tools](apps/coremark/iss/README.md) |
| `coremark_pro/` | All nine EEMBC CoreMark-PRO workloads, loaded as `coremark_pro_<workload>`; the heap and large datasets live in DDR |
| `csr_rmw_test/` | Old and new values for `csrrw`/`csrrs`/`csrrc`, including the same-register `mscratch` swap that OpenSBI's trap entry uses |
| `csr_test/` | `mstatus.MIE` writes and the M-mode counter controls: `mcountinhibit` and 64-bit `mcycle`/`minstret` writes |
| `ddr_atomic_test/` | Word LR/SC and AMOs on cached DDR, printing a progress letter before each step |
| `ddr_exec_test/` | Code in DDR: calls into BRAM, recursion, a body larger than the fetch buffer, cold and warm runs |
| `ddr_heap_test/` | Multi-MiB `malloc` from the DDR heap, checked for address aliasing |
| `ddr_mlp_test/` | Independent cold DDR loads must overlap their L1D misses (measured with the profiling counters); a pointer chase is the control |
| `ddr_smc_test/` | Self-modifying code in DDR: store, `fence.i`, then execute cold and warm |
| `ddr_test/` | Cached-DDR loads and stores, byte strobes, evictions, the preloaded `.ddr_rodata` image, and AMOs |
| `debug_target/` | Debuggee with known symbols for the JTAG debug tests; waits for a debugger to write its flags |
| `dma_torture/` | DMA test engine against the CPU caches: visibility, ordering, atomics, the completion interrupt, abort and reuse |
| `drain_trapframe_test/` | Trap-frame stores to DDR must survive the L1D evicting their line during a timer interrupt |
| `fetch_lead_repro/` | A call into a cold cached line whose first bundle advances 6 bytes, followed by a 32-bit instruction split across fetch words |
| `fetch_stall_repro/` | 32-bit instructions near cache-line boundaries, fetched cold from DDR; a PC+2 mis-step traps |
| `fpu_assembly_test/` | FP hazards: squashed FP loads and load-use stalls |
| `fpu_test/` | Subnormals, fused multiply-add, rounding, and conversions |
| `freertos_demo/` | FreeRTOS tasks passing data through a queue and sharing the UART under a mutex, while worker tasks increment one counter with `amoadd.w` and the 1 ms tick time-slices them; a tick inside a critical section must defer its task switch |
| `fs_off_test/` | F/D instructions with `mstatus.FS` Off: illegal-instruction ahead of access and misaligned faults, no device read by a trapping FP load, and `mstatus.FS` writes, through `mstatus` or `sstatus`, that apply from the next instruction |
| `hello_world/` | Prints a greeting and the cycle-count delta once a second; the program the bitstream boots |
| `irq_mie_window/` | A pending timer interrupt must be taken when a `csrsi`/`csrci` pair opens `mstatus.MIE` for one instruction |
| `isa_test/` | Self-checks for RV64IMAFDCB, Zicsr, Zicntr, Zifencei, Zicond, Zbkb, and Zihintpause, plus M-mode CSRs and traps |
| `itlb_test/` | Sv39 instruction translation in S- and U-mode: superpages, page-crossing instructions, fetch faults, `sfence.vma` and `satp` changes |
| `jal_target_seam/` | A 4-byte `jal` entered as a taken-branch target at dword offset 4; needs the cached fetch path (`FROST_COCOTB_MEM_CONFIG=ddr`) |
| `linux_boot/` | Debian's riscv64 kernel, OpenSBI, and a Buildroot initramfs, packed for loading; see the [Linux guide](../linux/README.md) |
| `linux_clksrc_faithful/` | The Linux CLINT clocksource sequence (MTIE before the RV32 kernel's torn `mtimecmp` write, handler re-arm, bare `wfi`) under DDR traffic |
| `linux_irq_active_ddr_test/` | Timer interrupts landing in active DDR code with a Linux-style trap frame; `ra` must stay valid |
| `linux_irq_ddr_test/` | Linux-style timer interrupt path from `wfi` idle, with code, data, and stack in DDR |
| `linux_irq_find_next_slot_test/` | Timer interrupts swept across a `_find_next_bit`-shaped loop whose saved-`ra` slot is poisoned |
| `linux_irq_stack_slot_test/` | A timer interrupt inside a callee whose saved-`ra` stack slot was poisoned beforehand |
| `lq_stale_slot_probe/` | Cached-load results must reach the right load across two partial flushes and ROB-tag reuse, with slow, reordered DDR responses |
| `mem_divergence_probe/` | Cold versus warm reads of cached DDR (both dword halves, 64-bit reads, store forwarding) |
| `memory_test/` | Arena allocator and `malloc`/`free`/`calloc`/`realloc`, including coalescing and overflow rejection |
| `mret_drain_deadlock/` | `mret` right after cached-DDR stores must wait for them to drain, then continue |
| `mret_timer_resume_test/` | A timer pending as `mret` drops to U-mode must save the U-mode entry point in `mepc` |
| `mtimer_stress/` | Frequent timer interrupts swept across an M-mode loop and its `mret`; a deadlock times out |
| `nic_echo/` | Interrupt-driven Ethernet echo; needs a link partner, which the simulation bench provides |
| `nic_loopback/` | NIC loopback, descriptor rings, interrupts, filtering, and reset during traffic |
| `ns16550_irq_console_test/` | Console output written one byte per THRE interrupt, each claimed and completed through the PLIC |
| `ns16550_test/` | The 16550 UART registers: Linux 8250 initialization, register file, LSR.THRE and LSR.TEMT around a write, and transmit |
| `opensbi_smoke/` | OpenSBI boots a bare S-mode payload that tests SBI calls; fixed layout, ignores `MEM_CONFIG` |
| `packet_parser/` | FIX message parser demo fed through the MMIO FIFOs; reports parse time in cycles |
| `pause_test/` | `pause` (`0x0100000F`) retires without draining committed stores, while `fence r,0` and the other FENCE encodings next to it wait for the drain |
| `pde_return_hazard/` | A return value computed from `s1` just before the epilogue restores `s1` (Linux `pde_subdir_find` shape) |
| `perf_off_test/` | Core built without profiling counters: `mperf*` CSRs read zero and ignore writes, while `cycle` and `instret` count |
| `plic_test/` | PLIC registers, level gateway, claim and complete, threshold, both contexts, an M-mode external interrupt, and completions from contexts that do not enable the source |
| `pma_fault_test/` | Access faults for fetch, load, store, AMO, and LR outside the physical map, with exact `mepc` and `mtval` |
| `print_clock_speed/` | Prints the `FPGA_CPU_CLK_FREQ` it was built with |
| `ptw_coherence_test/` | Sv39 walks must see page tables still dirty in the L1D, without `sfence.vma` |
| `ras_slot_bench/` | Return prediction with the call and the return in either slot of their fetch bundle: per-phase cycles and flush-recovery cycles from the profiling counters (`PERF_COUNTERS=1`) |
| `ras_stress_test/` | Return-address-stack stress: calls mixed with branches, data-dependent calls, and function pointers |
| `ras_test/` | Return-address stack: deep nesting, overflow and underflow, coroutine swaps, compressed returns, and calls at halfword offsets |
| `restore_window_stress/` | Timer interrupts swept across a Linux-style M-mode exception return; none may be taken between its `csrci` and `mret` |
| `riscv_tests/` | Upstream riscv-tests ISA suites, built per test with `TEST_SRC`, and benchmarks, built with `Makefile.bench` |
| `riscv_torture/` | Committed riscv-torture random tests compared with Spike register signatures; built per test with `TEST_SRC` |
| `rv64_amo_test/` | Doubleword AMOs, LR.D/SC.D, and word AMOs on a dword cell, with full 64-bit value checks |
| `rv64_smoke/` | The smallest RV64I program: W-form operations, 6-bit shift amounts, and 64-bit loads and stores |
| `satp_drain_test/` | A store committed just before a `satp` or `mstatus` write must drain before that write retires and flushes the pipeline |
| `slot2_fault_test/` | A fetch fault on the second instruction of a fetch pair, one whose bytes encode a NOP included, must trap at that instruction with exact `mepc` and `mtval` |
| `smc_fencei_test/` | Self-modifying code with `fence.i` across store-to-fence gaps, warm and cold L1D, and tight loops |
| `smode_test/` | S-mode: delegation, `sret`, TSR/TVM/TW, supervisor CSRs, counter permissions, and interrupts |
| `spanning_test/` | 32-bit instructions that straddle a fetch-word boundary |
| `sprintf_test/` | `sprintf`/`snprintf` checked against constant expected strings |
| `sstc_test/` | Sstc: `menvcfg.STCE`, `stimecmp` access rules, and an S-mode timer interrupt through `stimecmp` |
| `strings_test/` | `string.h`, `ctype.h`, and `stdlib.h` functions |
| `tick_torture/` | CLINT timer re-arming, lost-tick detection, and `wfi` wakeup under DDR traffic |
| `tomasulo_perf/` | IPC of dependent and independent integer and FP instruction chains; `-DTOMASULO_PERF_ENABLE_PROFILE=1` adds profiling-counter reports |
| `tomasulo_test/` | RAW/WAR/WAW hazards, register renaming, and out-of-order execution, with order-independent results |
| `trap_s2l_fwd/` | A counter a timer handler stores to cached DDR must be visible to later loads (Linux `handle_exception` pattern) |
| `uart_echo/` | Interactive UART receive demo with `echo`, `hex`, and `count` commands |
| `umode_test/` | U-mode: `ecall`, timer preemption, illegal CSR and `mret` access, and `mcounteren` gating |
| `vm_test/` | Sv39 data translation through MPRV: page sizes, permissions, Svade, malformed PTEs, `sfence.vma`, atomics, MMIO |
| `wfi_drain_mepc_test/` | A timer interrupt at `wfi` while a cached store drains must set `mepc` past the `wfi` |
| `wfi_lost_tick/` | The Linux idle loop (`wfi` with MIE toggling and CLINT re-arm) must not lose timer ticks |
| `wfi_mepc_test/` | A timer interrupt at `wfi` must set `mepc` to the next instruction |
| `window_skip_repro/` | After a branch trained taken resolves not-taken, fetch must not skip the fall-through window |
| `writecount_probe/` | `lr.w` sign extension on both dword halves in the Linux `i_writecount` sequence, with `sc.w` and `amoadd.w` |
