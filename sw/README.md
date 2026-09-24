# FROST Software

Bare-metal applications and runtime libraries for RV64/LP64D. See
[Linux](../linux/README.md) for OS images and [CONTRIBUTING.md](CONTRIBUTING.md)
for adding applications or libraries.

## Building

Simulations and the FPGA loader compile applications automatically. For a
manual build, use the [pinned toolchain](../docs/tooling.md):

```bash
./scripts/frost.py run python3 sw/apps/compile_app.py hello_world
./scripts/frost.py run python3 sw/apps/compile_app.py hello_world --mem-config ddr
./scripts/frost.py run python3 sw/apps/build_all_apps.py
```

`compile_app.py` cleans first. `build_all_apps.py` discovers app Makefiles;
`--list` shows its decisions, and `--include-linux-boot` includes the long
Linux image build. Parameterized compliance and torture suites have their own
[test runners](../tests/README.md). `clean_all_apps.py` cleans all app builds.

With the native toolchain on PATH, `make -C sw/apps/<app>` also works.
Builds track compiler, flag, header, layout, and workload changes.

### Build options

| Variable | Default | Purpose |
|----------|---------|---------|
| `RISCV_PREFIX` | `riscv64-linux-` | Toolchain prefix |
| `MEM_CONFIG` | `bram` | Application placement: `bram` or `ddr` |
| `OPT_LEVEL` | `-O3` | Optimization level |
| `UNROLL_LOOPS` | `-funroll-loops` | Set empty to disable loop unrolling |
| `MABI` | `lp64d` | ABI |
| `FPGA_CPU_CLK_FREQ` | `300000000` | Actual CPU clock in Hz |
| `FROST_DEBUG` | `0` | Set to 1 for `-Og -g3` and source debugging |
| `FROST_DEBUG_FRAME_POINTER` | `1` | Frame pointers in debug C builds |
| `EXTRA_CFLAGS` / `EXTRA_LDFLAGS` | empty | Additional compile/link flags |
| `EXTRA_ASM_SRC` | empty | Assembly sources linked with C startup |
| `GENERATE_IMEM_INIT` | `0` | Generate split instruction-BRAM init files |

`common/arch.mk` defines `rv64`, `lp64`, `lp64d`, and `elf64lriscv`.
`common.mk` defaults to
`rv64imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause`.
Apps can set `FROST_MARCH_EXTENSIONS` and `APP_TUNE_FLAGS` before including it;
tuning flags follow common flags and are recorded in the build fingerprint.
Debug-profile flags take precedence over app tuning.

### Memory Configuration (BRAM vs DDR tier)

- `bram`: code and small data use low BRAM; opt-in `.ddr_*` sections and the
  malloc heap use cached DDR.
- `ddr`: `common/link_ddr.ld` places the program in DDR. A low-BRAM boot stub
  jumps to the DDR `_start`, exercising both instruction and data caches.

Use `FROST_COCOTB_MEM_CONFIG=ddr` for simulation or the FPGA loader's `--ddr`
option. Apps with dedicated linker scripts can retain fixed layouts.
`LINKER_SCRIPT` overrides the common linker's selection.

Board loaders set the software clock from `FROST_CPU_CLK_HZ` or the board
default. Use `FROST_CPU_CLK_HZ=322265625` for X3, or `161132812` at half rate.

### Build Outputs

| File | Contents |
|------|----------|
| `sw.elf` | Executable; DWARF information when `FROST_DEBUG=1` |
| `sw.mem` / `sw64.mem` | Low-BRAM simulation image, 32-/64-bit words |
| `sw.txt` / `sw.bin` | Low-BRAM JTAG image / raw binary |
| `sw_ddr.mem` / `sw_ddr.txt` / `sw_ddr.bin` | DDR simulation / JTAG / raw image, relative to `0x80000000` |
| `sw.S` | Disassembly |
| `sw_imem_*.mem` | Split-bank Vivado init files when enabled |

The DDR simulation image contains one zero word when no sections use DDR.
JTAG images contain dense 32-bit hex words with no address prefixes.

## Libraries

Headers under [lib/include/](lib/include/) document the APIs. Add required
implementations from `lib/src/` to `SRC_C`; this is a freestanding runtime.

| Header | Purpose |
|--------|---------|
| [uart.h](lib/include/uart.h) | Console I/O and `uart_printf`; hardware uses 115200 baud, 8N1 |
| [string.h](lib/include/string.h), [ctype.h](lib/include/ctype.h) | String/memory operations and character classification |
| [stdlib.h](lib/include/stdlib.h), [limits.h](lib/include/limits.h) | Numeric conversion and LP64 integer limits |
| [memory.h](lib/include/memory.h) | Arena allocator and coalescing `malloc`/`free` heap in DDR |
| [sprintf.h](lib/include/sprintf.h) | `sprintf`/`snprintf` without stdio; link with `EXTRA_LDFLAGS := -lgcc` |
| [timer.h](lib/include/timer.h), [csr.h](lib/include/csr.h) | Cycle timing, counters, and CSR access |
| [trap.h](lib/include/trap.h) | Trap handlers, interrupts, `mtime`/`mtimecmp`, and software interrupts |
| [sync.h](lib/include/sync.h) | Memory and instruction fences |
| [fifo.h](lib/include/fifo.h) | MMIO FIFOs |
| [nic.h](lib/include/nic.h), [dma_engine.h](lib/include/dma_engine.h) | Ethernet and coherent DMA |
| [fix.h](lib/include/fix.h) | FIX timestamp and price parsing |
| [tomasulo_profile.h](lib/include/tomasulo_profile.h) | [Performance-counter API](../hw/rtl/cpu_and_mem/cpu/cpu_ooo/perf/README.md) |

Library limits:

- `uart_printf` supports characters, strings, signed/unsigned decimal, hex,
  field widths through 255, and integer zero-padding. `%f` requires
  `UART_PRINTF_ENABLE_FLOAT=1`, caps precision at 9, and prints `ovf`/`-ovf`
  for finite magnitudes at least 2^64.
- `snprintf` supports integer, floating-point, string, character, and pointer
  formatting, flags, `*` width/precision, and `hh/h/l/ll/z/t` modifiers. It
  returns `-1` if the full output length exceeds `int`, while terminating a
  nonempty destination. Large precisions do not allocate large scratch buffers.
- `strtol` accepts base 0 or 2–36 and saturates on overflow. Invalid bases or
  no digits return zero and leave `endptr` at the original input.
- Failed arena creation yields `start == NULL` and zero capacity. Heap size
  overflow and oversized allocations return `NULL` without consuming the heap.
- `rd*64()` reads an entire 64-bit counter; plain `rd*()` returns its low word.
  Use 64-bit timing beyond about 13 seconds at 322.265625 MHz. RV32 high-half CSR aliases
  are illegal. `time` follows CLINT `mtime`; cycle timing uses `cycle`.

## Applications

List runnable targets with `./scripts/frost.py cocotb --list-tests`.

| App | Description |
|-----|-------------|
| `arch_test/` | RISC-V architecture compliance tests against Spike references; Verilator only |
| `branch_pred_test/` | Assembly-level branch predictor verification (45 BTB tests) |
| `c_ext_test/` | Compressed (C ext) instruction test: JAL/JALR/JR alignment cases |
| `call_stress/` | Nested function call stress test for call stack and compressed returns |
| `cf_ext_test/` | Compressed double-precision floating-point (Zcd) instruction tests |
| `coremark/` | EEMBC CoreMark CPU benchmark; C disabled by default, with optional C/seed/link-order [measurement sweeps](../docs/single_core_performance.md#reproducing-and-retaining-measurements) |
| `coremark_pro/` | All nine EEMBC CoreMark-PRO workloads, using DDR for the heap and large datasets |
| `csr_test/` | CSR access and M-mode trap handling verification |
| `fpu_assembly_test/` | FP hazard corner-case tests (squashed loads, load-use stalls) |
| `fpu_test/` | FPU compliance tests (subnormals, FMA, rounding, conversions) |
| `freertos_demo/` | FreeRTOS preemptive multitasking demo (requires `git submodule update --init`) |
| `hello_world/` | Minimal UART/timer sanity check: prints a greeting every second |
| `isa_test/` | ISA self-test for all Frost extensions (RV64GCB + M-mode) |
| `linux_boot/` | Debian kernel, OpenSBI, and root filesystem images for FPGA loading. See the [Linux guide](../linux/README.md) |
| `memory_test/` | Arena allocator and malloc/free test suite |
| `opensbi_smoke/` | OpenSBI boot and SBI tests with a bare supervisor payload; fixed layout, ignores `MEM_CONFIG` |
| `packet_parser/` | FIX protocol message parser demo with latency measurement |
| `print_clock_speed/` | Clock frequency measurement utility |
| `ras_stress_test/` | BTB+RAS stress test mixing loops, branches, and function pointers |
| `ras_test/` | Return Address Stack verification (deep nesting, coroutines, alignment) |
| `riscv_tests/` | Upstream riscv-tests ISA suite + benchmark harness (parameterized by `TEST_SRC`) |
| `riscv_torture/` | Randomized riscv-torture harness; signatures compared against Spike |
| `spanning_test/` | 32-bit instruction fetch across word boundary verification |
| `sprintf_test/` | sprintf/snprintf formatting test suite (~200 cases) |
| `strings_test/` | String/ctype/stdlib library test suite |
| `tomasulo_perf/` | IPC measurement across dependent/independent workloads to quantify OOO benefit |
| `tomasulo_test/` | Tomasulo correctness test: RAW/WAR/WAW hazards, renaming, OOO execution |
| `uart_echo/` | Interactive UART RX demo with echo, hex, and count commands |
| `ddr_exec_test/` | Execution from DDR, including calls, recursion, and fetch-buffer boundaries |
| `ddr_heap_test/` | Multi-MB malloc capacity test through the cache hierarchy into DDR |
| `ddr_smc_test/` | Self-modifying code and `fence.i` across the instruction and data caches |
| `ddr_test/` | Cached-DDR loads, stores, byte strobes, evictions, and preloaded data |
| `amo_irq_torture/` | Atomic DDR operations under timer interrupts; checks for lost or duplicate updates |
| `tick_torture/` | CLINT timer rearming, lost-tick detection, and WFI wakeup under DDR traffic |
| `lq_stale_slot_probe/` | Load-data correctness when branch flushes overlap outstanding DDR reads |
| `ptw_coherence_test/` | Sv39 page-table walks with dirty L1D page tables |
| `dma_torture/` | DMA coherence, CPU atomics, completion ordering, interrupts, and abort/reuse |
| `nic_loopback/` | NIC loopback, descriptor rings, interrupts, filtering, and reset during traffic |
| `nic_echo/` | Interrupt-driven Ethernet echo; requires a link partner |

## Memory Map

The board and simulation use the same address map. The default
[linker script](common/link.ld) reserves:

| Region | Address | Size | Use |
|--------|---------|------|-----|
| ROM | `0x00000000` | 95 KiB | Code and read-only data |
| DEBUG | `0x00017C00` | 1 KiB | Reserved debug-module execution area |
| RAM | `0x00018000` | 160 KiB | Data, BSS, and stack |
| DDR | `0x80000000` | 1 GiB | Cached code/data and heap |

The low-BRAM stack has a 112 KiB reserve enforced by a linker assertion.
DDR sections are `.ddr_text`, `.ddr_rodata`, `.ddr_data`, and `.ddr_bss`, followed
by the heap. The lowest loaded DDR address must remain the region base because
the JTAG image is region-relative. Large objects can use
`__attribute__((section(".ddr_rodata")))` or per-object linker rules.

Low BRAM has separate instruction and data copies: ordinary stores do not
modify fetched code. Put self-modifying code in DDR and execute `fence.i`
after writes. It writes back L1D and invalidates L1I and the fetch buffer.
Debugger writes can update the BRAM instruction copy.

### Peripheral Addresses

| Peripheral     | Address      | Description                             |
|----------------|--------------|------------------------------------------|
| UART_TX        | `0x40000000` | UART transmit register (write-only)      |
| UART_RX_DATA   | `0x40000004` | UART receive data (read pops byte)       |
| FIFO0          | `0x40000008` | MMIO FIFO channel 0                      |
| FIFO1          | `0x4000000C` | MMIO FIFO channel 1                      |
| MTIME_LO       | `0x40000010` | Machine timer low 32 bits                |
| MTIME_HI       | `0x40000014` | Machine timer high 32 bits               |
| MTIMECMP_LO    | `0x40000018` | Timer compare low 32 bits                |
| MTIMECMP_HI    | `0x4000001C` | Timer compare high 32 bits               |
| MSIP           | `0x40000020` | Machine software interrupt pending       |
| UART_RX_STATUS | `0x40000024` | UART RX status (bit 0 = data available)  |
| UART_TX_STATUS | `0x40000028` | UART TX status (bit 0 = can accept byte) |
| NS16550        | `0x40001000` | NS16550-compatible UART registers (`0x40001000`-`0x4000101C`) |
| CLINT alias    | `0x40010000` | SiFive CLINT-compatible alias of MSIP/mtimecmp/mtime (for Linux) |
| DMA test engine | `0x40020000` | Coherent DMA copy/fill engine |
| NIC | `0x40030000` | 10G Ethernet descriptor rings and control |
| PLIC           | `0x44000000` | Platform-level interrupt controller (4 MiB window; M and S contexts for hart 0) |

Use `volatile` accesses and naturally aligned addresses. Misaligned loads and
stores trap. See the [RTL bus contract](../hw/rtl/README.md#data-tier-bus-contract)
for access widths, ordering, and device-read side effects.

## Startup Sequence

`common/crt0.S` sets `sp` and `gp`, copies initialized data from ROM to RAM,
zeros BSS (including `.ddr_bss`), calls `main()`, and loops if it returns.
Standalone assembly supplies its own `_start`. Compliance suites and FreeRTOS
use dedicated linker scripts on the same memory map.

## Testing and debugging

Test apps normally print `<<PASS>>` or `<<FAIL>>` over UART. The real-program
harness fails on `<<FAIL>>` or timeout (default 500,000 cycles, overridden per
app). Hello World passes on its greeting; the UART echo test injects input
and checks responses.

```bash
./scripts/frost.py cocotb hello_world
FROST_COCOTB_MEM_CONFIG=ddr ./scripts/frost.py cocotb hello_world
./fpga/load_software/load_software.py x3 hello_world --debug
```

Debug builds are unsuitable for benchmark measurements. `isa_test` disables
frame pointers because tests use `s0`; custom assembly, traps, and FreeRTOS
context switches can limit unwinding. The [debugger guide](../tools/vscode-frost/README.md)
covers supported applications and startup behavior.
