# Frost Software

Bare-metal libraries and applications for the Frost RISC-V processor.

## Directory Structure

```
sw/
├── common/           # Shared build infrastructure
│   ├── arch.mk       # rv64/lp64 architecture strings shared by every build backend
│   ├── common.mk     # Common Makefile definitions (MEM_CONFIG bram|ddr)
│   ├── standalone_asm.mk # Shared rules for apps that define their own _start
│   ├── crt0.S        # C runtime startup (runs before main)
│   ├── crt0_ddr_boot.S # ROM boot stub: far-jumps to a DDR-resident _start (MEM_CONFIG=ddr)
│   ├── generate_imem_predecode_init.py # Split-bank IMEM init generator (opt-in)
│   ├── link.ld       # Unified linker script (low BRAM + 1 GiB cached DDR)
│   ├── link_ddr.ld   # DDR-tier linker: whole program in the cached DDR region (MEM_CONFIG=ddr)
│   └── make_dword_mem.py # Pairs sw.mem words into sw64.mem for the 64-bit data BRAM
├── lib/              # Reusable libraries
│   ├── include/      # Header files
│   └── src/          # Source files
├── FreeRTOS-Kernel/  # FreeRTOS kernel (submodule)
└── apps/             # Application programs
    ├── compile_app.py    # Clean and compile a single application
    ├── build_all_apps.py # Clean and compile ordinary standalone apps
    ├── clean_all_apps.py # Clean all build artifacts
    ├── <app_name>/       # One directory per software app
    └── ...
```

The [Applications](#applications) table summarizes the main apps. For the
complete inventory: `find sw/apps -maxdepth 1 -type d | sort`.

## Libraries

### UART (`lib/include/uart.h`, `lib/src/uart.c`)

Serial console I/O driver with printf-style formatting and character input.
On hardware, use 115200 baud, 8 data bits, no parity, and 1 stop bit (8N1).

```c
#include "uart.h"

// Transmit
uart_putchar('A');                         // Single character
uart_puts("Hello\n");                     // String
uart_printf("Value: %d (0x%08X)\n", x, x); // Formatted output

// Receive
if (uart_rx_available()) { ... }           // Data available
char c = uart_getchar();                   // Blocking
int c = uart_getchar_nonblocking();        // -1 if no data
size_t n = uart_getline(buf, sizeof(buf)); // Echo and backspace handling
```

Supported printf format specifiers:
- `%c`: character
- `%s`: string
- `%d`, `%ld`, `%lld`: signed decimal
- `%u`, `%lu`, `%llu`: unsigned decimal
- `%x`, `%lx`, `%llx` (and uppercase variants): hexadecimal
- `%f`: floating point when compiled with `UART_PRINTF_ENABLE_FLOAT=1`;
  finite magnitudes of 2^64 or more print as `ovf` or `-ovf`
- `%%`: literal percent sign
- Right-aligned field width (up to 255) and integer zero-padding: `%8d`, `%04x`
- Floating-point precision is capped at 9 digits

### String (`lib/include/string.h`, `lib/src/string.c`)

Minimal libc string and memory functions.

```c
#include "string.h"

memset(buffer, 0, sizeof(buffer));         // Fill memory
memcpy(dest, src, len);                   // Non-overlapping regions
memmove(dest, src, len);                  // Overlap-safe
int cmp = memcmp(a, b, len);              // Compare memory
size_t len = strlen(str);                 // String length
size_t len = strnlen(str, n);             // Bounded length
strcpy(dest, src);                        // Copy
strncpy(dest, src, n);                    // Bounded copy
strcat(dest, src);                        // Concatenate
int cmp = strcmp(a, b);                   // Compare strings
int cmp = strncmp(a, b, n);               // Bounded compare
char *p = strchr(str, 'x');               // Find first character
char *p = strrchr(str, 'x');              // Find last character
char *p = strstr(haystack, needle);       // Find substring
size_t n = strspn(s, accept);             // Accepted prefix length
size_t n = strcspn(s, reject);            // Prefix before rejection
char *p = strpbrk(s, accept);             // Find character from set
char *dup = strdup(s);                    // Heap duplicate
```

### Ctype (`lib/include/ctype.h`, `lib/src/ctype.c`)

Character classification and case conversion.

```c
#include "ctype.h"

if (isdigit(c)) { ... }                   // Decimal digit
if (isalpha(c)) { ... }                   // Letter
if (isupper(c)) { ... }                   // Uppercase letter
if (islower(c)) { ... }                   // Lowercase letter
if (isspace(c)) { ... }                   // Whitespace
char upper = toupper('a');                // 'A'
char lower = tolower('Z');                // 'z'
```

### Stdlib (`lib/include/stdlib.h`, `lib/src/stdlib.c`)

String-to-number conversion and integer helpers.

```c
#include "stdlib.h"

long val = strtol("123", &endptr, 10);    // Explicit base
long hex = strtol("0xff", NULL, 16);      // Hexadecimal
long oct = strtol("077", NULL, 0);        // Auto-detect base
int i = atoi("-42");                      // String to int
long l = atol("12345");                   // String to long
int a = abs(-7);                          // Absolute value
```

`strtol` accepts base 0 or bases 2 through 36. It saturates to `LONG_MIN` or
`LONG_MAX` on overflow. Invalid bases and inputs with no digits return zero and
leave `endptr` pointing at the original input.

### Memory (`lib/include/memory.h`, `lib/src/memory.c`)

Arena and first-fit freelist allocators.

```c
#include "memory.h"

// Bump arena with manual lifetime
arena_t arena = arena_alloc(4096);        // Create 4 KiB arena from heap
void *p1 = arena_push(&arena, 64);        // Allocate 64 bytes, 8-byte aligned
void *p2 = arena_push_zero(&arena, 32);   // Allocate and zero-initialize
char *p3 = arena_push_align(&arena, 16, 32); // Allocate with 32-byte alignment
arena_pop(&arena, 16);                    // Deallocate from end
arena_clear(&arena);                      // Reset arena (free all at once)

// First-fit, coalescing freelist
void *ptr = malloc(128);                  // Allocate 128 bytes
void *arr = calloc(16, 8);                // Allocate and zero 16x8 bytes
ptr = realloc(ptr, 256);                  // Grow/shrink an allocation
free(ptr);                                // Return to freelist
```

An arena allocates fast, frees everything at once, and never fragments, at the
cost of a fixed lifetime. `malloc`/`free` give each block its own lifetime;
adjacent free blocks are coalesced to limit fragmentation.

Arena allocation failure is represented by `arena.start == NULL` and zero
capacity. Oversized requests and size-arithmetic overflow return `NULL` from
`malloc`, `calloc`, and `realloc` without consuming or corrupting the heap.

### Sprintf (`lib/include/sprintf.h`, `lib/src/sprintf.c`)

`sprintf`/`snprintf` without `<stdio.h>`, using integer-scaled floating-point
formatting to avoid cascading rounding errors.

```c
#include "sprintf.h"

char buf[128];
sprintf(buf, "x=%d y=%s", 42, "hello");       // Unbounded format
snprintf(buf, sizeof(buf), "%.2f", 3.14159);   // Bounded (C99 semantics)
```

Supported format specifiers:
- `%d`/`%i`, `%u`, `%o`, `%x`/`%X`: integer (signed/unsigned, octal, hex)
- `%f`/`%F`, `%e`/`%E`, `%g`/`%G`: floating-point (fixed, scientific, shortest)
- `%c` (character), `%s` (string), `%p` (pointer), `%%` (literal percent)
- Flags: `-` `+` `space` `0` `#`
- Width/precision: literal or `*`
- Length modifiers: `hh` `h` `l` `ll` `z` `t`

Large widths and floating-point precisions are counted and truncated directly
into the caller's destination; they do not allocate precision-sized scratch
buffers. If the would-be output length cannot fit in `int`, the function returns
`-1` while still terminating a non-empty destination buffer.

The internal 64-bit arithmetic requires `-lgcc` before the Makefile include:
```makefile
EXTRA_LDFLAGS := -lgcc
SRC_C := ../../lib/src/uart.c ../../lib/src/sprintf.c your_app.c
include ../../common/common.mk
```

### Limits (`lib/include/limits.h`)

Integer limits for the LP64 ABI: 32-bit `int`, 64-bit `long` and pointers.

```c
#include "limits.h"

INT_MIN   // -2147483648
INT_MAX   // 2147483647
LONG_MIN  // -9223372036854775808L
LONG_MAX  // 9223372036854775807L
```

### Timer (`lib/include/timer.h`)

Zicntr timing and delay helpers.

```c
#include "timer.h"

uint32_t start = read_timer();            // Low 32 bits
// ... do work ...
uint32_t elapsed = read_timer() - start;  // Elapsed cycles

uint64_t start64 = read_timer64();        // Full counter
// ... long-running work ...
uint64_t elapsed64 = read_timer64() - start64;  // For benchmarks >14 seconds

delay_ticks(1000);                        // Busy-wait in cycles
delay_1_second();                         // Approximate one second
```

These use the single-instruction Zicntr cycle CSR, not MMIO. Use
`read_timer64()` beyond the 32-bit wrap interval (~14 seconds at 300 MHz).

### FIFO (`lib/include/fifo.h`)

Memory-mapped inter-module FIFOs.

```c
#include "fifo.h"

fifo0_write(0x12345678);                  // Write one word
uint32_t data = fifo0_read();             // Read one word
```

### Synchronization (`lib/include/sync.h`)

Memory and instruction synchronization barriers (Zifencei extension).

```c
#include "sync.h"

fence();                                  // Memory ordering fence
fence_i();                                // Instruction fetch fence
```

`fence()` orders memory operations. `fence_i()` synchronizes modified code by
writing L1D back through the line port, then invalidating L1I and the fetch
buffer. Cached self-modifying code requires it; see `apps/ddr_smc_test/`.

### CSR Access (`lib/include/csr.h`)

Zicsr/Zicntr counter and machine-mode CSR access.

```c
#include "csr.h"

// Read counter low words
uint32_t cycles_lo = rdcycle();           // Low 32 bits of cycle counter
uint32_t instret_lo = rdinstret();        // Low 32 bits of instructions retired
uint32_t time_lo = rdtime();              // Low 32 bits of time (backed by CLINT mtime)

// Read full 64-bit counters atomically
uint64_t start = rdcycle64();
// ... code to benchmark ...
uint64_t elapsed = rdcycle64() - start;

uint64_t instructions = rdinstret64();    // Total instructions retired

// Direct CSR access macros (for M-mode CSRs)
unsigned long status = csr_read(mstatus); // Read any CSR by name (XLEN-wide)
csr_write(mtvec, handler_addr);           // Write to CSR
csr_set(mie, MIE_MTIE);                   // Set bits in CSR
csr_clear(mstatus, MSTATUS_MIE);          // Clear bits in CSR
```

Available counters:
- `cycle`: Clock cycles since reset (64-bit)
- `time`: Wall-clock time (backed by CLINT mtime, which ticks at the core clock on Frost)
- `instret`: Instructions retired since reset (64-bit)

Each counter is a single 64-bit CSR. The rv32-style `*h` high-half aliases do
not exist at rv64; accessing one raises an illegal-instruction trap. The
`rd*64()` helpers read the full value; the plain `rd*()` forms return the low
32 bits.

M-mode CSRs (for RTOS support):
- `mstatus`: Machine status (global interrupt enable, privilege state)
- `mie`/`mip`: Interrupt enable and pending bits
- `mtvec`: Trap vector base address
- `mepc`: Exception program counter
- `mcause`: Trap cause (interrupt bit + cause code)
- `mtval`: Trap value (faulting address/instruction)
- `mscratch`: Scratch register for trap handlers

### Trap Handling (`lib/include/trap.h`)

Machine-mode trap handling utilities for RTOS support.

```c
#include "trap.h"

// Set up trap handler
set_trap_handler(&my_trap_handler);

// Interrupt control
enable_interrupts();                      // Set mstatus.MIE
unsigned long prev = disable_interrupts(); // Clear MIE, return previous state
restore_interrupts(prev);                 // Restore previous state

// Timer interrupt (CLINT-compatible)
enable_timer_interrupt();                 // Set mie.MTIE
uint64_t now = rdmtime();                 // Read 64-bit machine timer
set_timer_cmp(now + 1000000);             // Set timer compare value

// Software interrupt
enable_software_interrupt();              // Set mie.MSIE
trigger_software_interrupt();             // Set MSIP (causes interrupt)
clear_software_interrupt();               // Clear MSIP

// Privileged instructions
wfi();                                    // Wait for interrupt (low-power idle)
ecall();                                  // Environment call (syscall)
ebreak();                                 // Breakpoint exception
```

CLINT-compatible timer registers (memory-mapped at `0x40000010`-`0x40000020`):
- `mtime`: 64-bit free-running timer counter
- `mtimecmp`: 64-bit timer compare value (interrupt when mtime >= mtimecmp)
- `msip`: Machine software interrupt pending bit

### FIX Protocol (`lib/include/fix.h`, `lib/src/fix.c`)

Parser for FIX (Financial Information eXchange) protocol fields.

```c
#include "fix.h"

// Parse timestamp: "20250807-19:36:55.528" -> nanoseconds
uint64_t ts = parse_timestamp("20250807-19:36:55.528");

// Parse price: "94.5000" -> fixed-point {amount=9450000000, scale=8}
fix_price_t price = parse_price("94.5000");
```

## Applications

Source comments document each app in detail; this table is a summary.
Runnable cocotb entries are listed by `./scripts/frost.py cocotb --list-tests`.

| App | Description |
|-----|-------------|
| `arch_test/` | RISC-V Architecture Compliance suite (riscv-arch-test, 260+ tests against Spike references, Verilator only) |
| `branch_pred_test/` | Assembly-level branch predictor verification (45 BTB tests) |
| `c_ext_test/` | Compressed (C ext) instruction test: JAL/JALR/JR alignment cases |
| `call_stress/` | Nested function call stress test for call stack and compressed returns |
| `cf_ext_test/` | Compressed double-precision FP (Zcd) test: C.FLD/C.FSD. Zcf is rv32-only; at rv64 those slots encode C.LD/C.SD, covered by `c_ext_test` |
| `coremark/` | Industry-standard EEMBC CoreMark CPU benchmark. The only app that narrows `FROST_MARCH_EXTENSIONS` (it builds without C) and sets `APP_TUNE_FLAGS`; its Makefile records the measured reason for each setting |
| `coremark_pro/` | EEMBC CoreMark-PRO suite (git submodule). All nine official workloads run on X3, with per-workload iteration counts calibrated in `apps/software_registry.py`. Builds use the unified linker script, so the malloc heap and large datasets such as radix2's FFT tables sit in the 1 GiB cached DDR region |
| `csr_test/` | CSR access and M-mode trap handling verification |
| `fpu_assembly_test/` | FP hazard corner-case tests (squashed loads, load-use stalls) |
| `fpu_test/` | FPU compliance tests (subnormals, FMA, rounding, conversions) |
| `freertos_demo/` | FreeRTOS preemptive multitasking demo (requires `git submodule update --init`) |
| `hello_world/` | Minimal UART/timer sanity check: prints a greeting every second |
| `isa_test/` | ISA self-test for all Frost extensions (RV64GCB + M-mode) |
| `linux_boot/` | No-MMU Linux boot: Buildroot builds the kernel and busybox initramfs from the vendored submodule, then the images are packed into the low-BRAM boot shim (`sw.mem`) and the DDR image (`sw_ddr.mem`) |
| `memory_test/` | Arena allocator and malloc/free test suite |
| `packet_parser/` | FIX protocol message parser demo with latency measurement |
| `print_clock_speed/` | Clock frequency measurement utility |
| `ras_stress_test/` | BTB+RAS stress test mixing loops, branches, and function pointers |
| `ras_test/` | Return Address Stack verification (deep nesting, coroutines, alignment) |
| `riscv_tests/` | Upstream riscv-tests ISA suite + benchmark harness (parameterized by `TEST_SRC`; run via `./tests/test_riscv_tests.py`) |
| `riscv_torture/` | Randomized riscv-torture harness; signatures compared against Spike (run via `./tests/test_riscv_torture.py`) |
| `spanning_test/` | 32-bit instruction fetch across word boundary verification |
| `sprintf_test/` | sprintf/snprintf formatting test suite (~200 cases) |
| `strings_test/` | String/ctype/stdlib library test suite |
| `tomasulo_perf/` | IPC measurement across dependent/independent workloads to quantify OOO benefit |
| `tomasulo_test/` | Tomasulo correctness test: RAW/WAR/WAW hazards, renaming, OOO execution |
| `uart_echo/` | Interactive UART RX demo with echo, hex, and count commands |
| `ddr_exec_test/` | Execute-from-DDR test: runs `.ddr_text` functions through the L1I fetch path (leaf/loop/recursion, cross-quadrant calls, bodies larger than the fetch buffer, warm-vs-cold) |
| `ddr_heap_test/` | Multi-MB malloc capacity test through the cache hierarchy into DDR |
| `ddr_smc_test/` | Self-modifying-code / `fence.i` test: writes instruction words into a DDR buffer and executes them, exercising the full L1D-writeback then L1I-invalidate sync chain |
| `ddr_test/` | Cached-region bring-up test (stores/loads, byte strobes, eviction sweeps, and the preloaded `.ddr_rodata` image path) |
| `amo_irq_torture/` | Machine-timer IRQs swept across cached-DDR AMO bursts; a counter-array sum check catches any double-applied or lost atomic. This is the directed regression for the interrupt-orphaned AMO write that made `linux_boot` flaky |
| `tick_torture/` | Linux-faithful CLINT tick re-arm (hi=-1/lo/hi order, torn-read mtime loop, catch-up) under multi-MB DDR thrash, with re-arm readback verify, a lost-tick watchdog, and a bounded-WFI wake check |

## Building

### Automatic compilation

These flows compile the application themselves:
- `./scripts/frost.py cocotb <test>`: cleans, then compiles before simulation
- `./fpga/load_software/load_software.py`: compiles before loading to the FPGA
- `./fpga/build/build.py`: compiles hello_world for the initial BRAM contents

### Prerequisites

- RISC-V GCC toolchain (`riscv-none-elf-gcc` from [xPack](https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack), or similar)
- GNU Make

### Manual compilation

From the repository root:

```bash
cd sw/apps/hello_world
make clean
make
```

### Compile a Single Application

```bash
./sw/apps/compile_app.py hello_world        # Compile hello_world
./sw/apps/compile_app.py coremark -v        # Compile with verbose output
./sw/apps/compile_app.py hello_world --mem-config ddr
```

The CLI runs `make clean` first and stops if it fails, preventing reuse of an
image linked for another memory tier.
Most app builds have a two-minute timeout; `linux_boot` allows up to 90 minutes
because a fresh checkout builds its Buildroot toolchain, kernel, and initramfs
before packing the images.

### Build Ordinary Standalone Applications

```bash
./sw/apps/build_all_apps.py                       # Clean and build ordinary apps
./sw/apps/build_all_apps.py --list                # Show build/skip decisions
./sw/apps/build_all_apps.py --include-linux-boot  # Opt in to the long Linux build
```

The script discovers non-hidden directories with a `Makefile`. It skips the
parameterized `arch_test`, `riscv_tests`, and `riscv_torture` suites, whose
runners select a source, and skips the 30-60 minute first `linux_boot` build
unless opted in. It prints each skip reason.

### Clean All Applications

```bash
./sw/apps/clean_all_apps.py
```

This runs `make clean` in every app directory that has a `Makefile`, which
removes `sw.elf`, `sw.mem`, `sw64.mem`, `sw.bin`, `sw.txt`, `sw.S`,
`sw_ddr.{mem,txt,bin}`, `sw_imem_*.mem`, and the build-config and dependency
stamps.

### Build Outputs

Compilation produces:
- `sw.elf`: ELF executable with debug symbols
- `sw.mem`: Verilog hex format for `$readmemh` (low BRAM image, 32-bit words)
- `sw64.mem`: dword-paired copy of `sw.mem` for the 64-bit data BRAM's `$readmemh` (hw/rtl/README.md, "Data-tier bus contract")
- `sw.bin`: raw binary (low BRAM image)
- `sw.txt`: BRAM initialization for Vivado
- `sw_ddr.mem`: cached-region (DDR) image for `$readmemh`, region-relative (offset 0 = `0x8000_0000`); a single zero word when the program puts nothing in the cached region
- `sw_ddr.txt`: cached-region (DDR) image for the JTAG loader (dense words)
- `sw.S`: disassembly listing

### Toolchain Override

```bash
make RISCV_PREFIX=riscv-none-elf-
```

### Architecture Constants (`common/arch.mk`)

The core is RV64-only; rv32 support was retired after Phase 1.
`common/arch.mk` defines the constants every build backend composes its flags
from: the `-march` prefix `rv64`, the integer ABI `lp64`, the FP ABI `lp64d`,
and the linker emulation `elf64lriscv`. Apps and backends share this one
definition of the target.

`common.mk` adds two per-app hooks on top of those constants, both `?=` so an
app sets them before its `include`:

- `FROST_MARCH_EXTENSIONS` — the extension string appended to the `rv64` prefix
  (default `imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause`).
  Only `coremark/` narrows it, dropping `c`.
- `APP_TUNE_FLAGS` — codegen flags appended *after* everything `common.mk`
  composes, so they win over its defaults (`coremark/` uses this to restore
  `-fstrict-aliasing`). Additive flags that need no override belong in
  `EXTRA_CFLAGS` instead. The value is part of the build fingerprint and of the
  `COMPILER_FLAGS` string a program can print, so changing it forces a rebuild
  and stays visible in benchmark output.

### Memory Configuration (BRAM vs DDR tier)

`common.mk` takes a `MEM_CONFIG` knob selecting which memory tier the *whole*
program is linked into:

```bash
make                    # MEM_CONFIG=bram (default): whole program in low BRAM
make MEM_CONFIG=ddr     # whole program relocated to the cached DDR region
```

Each backend records a fingerprint of its tools, flags, and linker settings, so
a plain `make` rebuilds after a tracked header, the memory tier, or (for
CoreMark-PRO) the workload changes. C apps use `common.mk`, self-starting
assembly apps use `standalone_asm.mk`, and the CoreMark-PRO Makefile also
tracks its workload object graph and included headers. Unknown `MEM_CONFIG`
values are rejected. The `compile_app.py` CLI still runs `make clean` first.

- `bram` (default): the program lives in low BRAM; only opt-in `.ddr_*` sections
  (and the malloc heap) sit in the cached DDR region. Every board integration
  uses this configuration in the FPGA flow.
- `ddr`: the program is linked at `0x8000_0000` behind a ROM boot stub
  (`common/crt0_ddr_boot.S`) that far-jumps to the DDR-resident `_start`, so the
  L1I fetch path and the D-side cached load/store path are both exercised. This
  selects `common/link_ddr.ld` and splits all loadable sections into the DDR
  image (`sw_ddr.mem`), leaving only the boot stub in `sw.mem`.

CI runs the cocotb real-program, riscv-tests, and riscv-torture suites in both
the `bram` and `ddr` tiers as separate jobs. Arch compliance uses the same
tier matrix, but CI skips the F/D DDR batches, which exceed the hosted-runner
budget; the F/D BRAM jobs cover FPU conformance and the other DDR jobs cover
the cache hierarchy. The suite runners take `--mem-config`
(`test_arch_compliance.py`, `test_riscv_tests.py`, `test_riscv_torture.py`);
`test_run_cocotb.py` reads `FROST_COCOTB_MEM_CONFIG=ddr`, and `compile_app.py`
takes `--mem-config ddr`. Four suites keep their own per-tier linker scripts:
`riscv_tests`, `arch_test`, `riscv_torture`, and `freertos_demo`. The first
three also keep their own boot stubs; `freertos_demo` uses
`common/crt0_ddr_boot.S`. File names differ per suite; see each app's
Makefile.

### Clock Frequency

The default CPU clock is 300 MHz. Override for different hardware:

```bash
make FPGA_CPU_CLK_FREQ=100000000  # 100 MHz
```

Board-aware loaders set `FPGA_CPU_CLK_FREQ` automatically so timing printouts
and benchmark normalization match the target board.

## Memory Map

The memory map is identical across board integrations and simulation. The
cache hierarchy behind it is opaque to software. The current X3 hierarchy has
a 128 KiB L1D, a 16 KiB L1I, and a 2 MiB UltraRAM L2 before the board's DDR4.

Defined in `common/link.ld`:

| Region | Address      | Size    | Description                                        |
|--------|--------------|---------|----------------------------------------------------|
| ROM    | `0x00000000` | 95 KiB  | Code and small read-only data in uncached BRAM; fetch windows wholly below 16 KiB are 1-cycle, while later windows repeat once for registered predecode metadata |
| DEBUG  | `0x00017C00` | 1 KiB   | Debug-module execution slice (park loop, abstract-command and program-buffer words); reserved by every linker script, never allocated, written only by the debug module |
| RAM    | `0x00018000` | 160 KiB | Variables, BSS, and stack in uncached BRAM; data accesses remain 1-cycle |
| MMIO   | `0x40000000` | 44 B    | Native UART/FIFO/timer/MSIP registers (the linker's window); the NS16550 UART at `0x40001000` and the SiFive CLINT alias at `0x40010000` sit above it |
| DDR    | `0x80000000` | 1 GiB   | Cached region: execute-from-DDR code, heap, large `.ddr_*` data |

Within the DDR region, opt-in `.ddr_text` code comes first, then the loaded
`.ddr_rodata` and `.ddr_data` sections, then `.ddr_bss`, then the heap to the
end of the gigabyte. An object reaches `.ddr_rodata` either through a
per-object rule in the linker script (radix2's ~800 KiB FFT tables) or an
explicit `__attribute__((section(".ddr_rodata")))`. The dense `sw_ddr.txt`
loader image starts at the lowest `.ddr_*` LMA, which must stay exactly at the
region base. The low-BRAM stack carries a 112 KiB reserve sized from measured
per-workload high-water marks (parser's recursive XML cleanup is the deepest
user at 112 KiB); a link-time assert keeps data+bss from growing into it.

Image delivery is split: `sw.mem`/`sw.txt` carry the low-BRAM image, and
`sw_ddr.mem`/`sw_ddr.txt` carry the cached-region image (region-relative,
offset 0 = `0x8000_0000`), consumed by the behavioral DDR model in simulation
and by the JTAG DDR loader on hardware.

The suites with their own linker scripts (`riscv_tests`, `arch_test`,
`riscv_torture`, `freertos_demo`) lay out their own sections on the same
256 KiB low-BRAM map.

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
| PLIC           | `0x44000000` | Platform-level interrupt controller (4 MiB window; M and S contexts for hart 0) |

Simple timing uses the Zicntr `cycle`/`instret` CSRs (`csr.h`, `timer.h`).
RTOS timer interrupts use CLINT-compatible `mtime`/`mtimecmp` (`trap.h`).

## Startup Sequence

The C runtime (`common/crt0.S`) executes before `main()`:

1. Initialize stack pointer (`sp`) to top of RAM
2. Initialize global pointer (`gp`) for small data access
3. Copy `.data`/`.sdata` section from ROM to RAM
4. Zero-initialize `.sbss` and `.bss` sections
5. Zero-initialize the cached-region `.ddr_bss` (empty unless a program places zero-init data there)
6. Call `main()`
7. Loop forever if `main()` returns

## Adding a New Application

1. Create a new directory under `apps/`
2. Add your C source file(s)
3. Create a `Makefile`:

```makefile
SRC_C := ../../lib/src/uart.c your_app.c
include ../../common/common.mk
```

4. Build with `make`

## Architecture Notes

Frost implements RV64GCB with Machine, Supervisor, and User privilege modes;
traps can be delegated to S-mode. See the [root README](../README.md) for the
complete extension table.

### Test Result Markers

Test apps print one of two markers on the UART:

- `<<PASS>>`: all tests passed
- `<<FAIL>>`: a test failed

`verif/cocotb_tests/test_real_program.py` monitors the UART and fails the run
if `<<FAIL>>` appears, or if `<<PASS>>` has not appeared within 500,000 clock
cycles (the default `COCOTB_MAX_CYCLES`; some apps carry larger budgets).

Special cases:
- hello_world: open-ended (loops forever); passes when "Hello, world!" is printed
- linux_boot: passes when the "Linux version" boot banner is printed; the CI
  linux-boot-cocotb job instead runs the full window (`FROST_LINUX_RUN_FULL=1`)
  and checks boot health afterwards with `tests/check_linux_boot_regression.py`
- uart_echo: interactive; the harness injects UART input and passes when the prompt, echo, and response are observed (no `<<PASS>>` marker)

### Other details

- ABI: LP64D (64-bit `long` and pointers, hardware double-precision float)
- Floating point: hardware F and D extensions (IEEE 754 single and double precision)
- No OS or libc: bare-metal programs with minimal dependencies
- Optimization: `-O3` by default; an app may override `OPT_LEVEL` (isa_test uses `-O2`)
