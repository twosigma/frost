# Frost Software

Bare-metal C software for the Frost RISC-V processor.

This directory contains libraries and applications that run directly on Frost hardware without an operating system. The code is designed for low-latency, deterministic execution on FPGA-based systems.

## Directory Structure

```
sw/
├── common/           # Shared build infrastructure
│   ├── common.mk     # Common Makefile definitions (MEM_CONFIG bram|ddr)
│   ├── standalone_asm.mk # Shared rules for apps that define their own _start
│   ├── crt0.S        # C runtime startup (runs before main)
│   ├── crt0_ddr_boot.S # ROM boot stub: far-jumps to a DDR-resident _start (MEM_CONFIG=ddr)
│   ├── generate_imem_predecode_init.py # Split-bank IMEM init generator (opt-in)
│   ├── link.ld       # Unified linker script (low BRAM + 1 GiB cached DDR)
│   └── link_ddr.ld   # DDR-tier linker: whole program in the cached DDR region (MEM_CONFIG=ddr)
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

Individual apps are listed in the [Applications](#applications) section below.
The filesystem is the authoritative inventory: `find sw/apps -maxdepth 1 -type d | sort`

## Libraries

### UART (`lib/include/uart.h`, `lib/src/uart.c`)

Serial console I/O driver with printf-style formatting and character input.
On hardware, use 115200 baud, 8 data bits, no parity, and 1 stop bit (8N1).

```c
#include "uart.h"

// Transmit functions
uart_putchar('A');                        // Single character
uart_puts("Hello\n");                     // String
uart_printf("Value: %d (0x%08X)\n", x, x); // Formatted output

// Receive functions
if (uart_rx_available()) { ... }          // Check if data available
char c = uart_getchar();                  // Blocking read (waits for data)
int c = uart_getchar_nonblocking();       // Non-blocking (-1 if no data)
size_t n = uart_getline(buf, sizeof(buf)); // Read line with echo/backspace
```

**Supported format specifiers (printf):**
- `%c` — character
- `%s` — string
- `%d`, `%ld`, `%lld` — signed decimal
- `%u`, `%lu`, `%llu` — unsigned decimal
- `%x`, `%lx`, `%llx` (and uppercase variants) — hexadecimal
- `%f` — floating point when compiled with `UART_PRINTF_ENABLE_FLOAT=1`;
  finite magnitudes at least 2^64 are reported as `ovf` or `-ovf`
- `%%` — literal percent sign
- Right-aligned field width (up to 255) and integer zero-padding: `%8d`, `%04x`
- Floating-point precision is capped at 9 digits

### String (`lib/include/string.h`, `lib/src/string.c`)

Minimal C library replacements for bare-metal operation.

```c
#include "string.h"

memset(buffer, 0, sizeof(buffer));        // Fill memory
memcpy(dest, src, len);                   // Copy non-overlapping memory
memmove(dest, src, len);                  // Overlap-safe memory copy
int cmp = memcmp(a, b, len);              // Compare binary regions
size_t len = strlen(str);                 // String length
size_t len = strnlen(str, n);             // Bounded string length
strcpy(dest, src);                        // String copy
strncpy(dest, src, n);                    // Bounded string copy
strcat(dest, src);                        // String concatenate
int cmp = strcmp(a, b);                   // Compare strings
int cmp = strncmp(a, b, n);               // Compare up to n chars
char *p = strchr(str, 'x');               // Find character
char *p = strrchr(str, 'x');              // Find last occurrence
char *p = strstr(haystack, needle);       // Find substring
size_t n = strspn(s, accept);             // Span of accepted chars
size_t n = strcspn(s, reject);            // Span until rejected char
char *p = strpbrk(s, accept);             // First char from accept set
char *dup = strdup(s);                    // Duplicate into malloc'd buffer
```

### Ctype (`lib/include/ctype.h`, `lib/src/ctype.c`)

Character classification and conversion functions.

```c
#include "ctype.h"

if (isdigit(c)) { ... }                   // Check for 0-9
if (isalpha(c)) { ... }                   // Check for a-z, A-Z
if (isupper(c)) { ... }                   // Check for A-Z
if (islower(c)) { ... }                   // Check for a-z
if (isspace(c)) { ... }                   // Check for whitespace
char upper = toupper('a');                // Returns 'A'
char lower = tolower('Z');                // Returns 'z'
```

### Stdlib (`lib/include/stdlib.h`, `lib/src/stdlib.c`)

Standard library functions for string-to-number conversion.

```c
#include "stdlib.h"

long val = strtol("123", &endptr, 10);    // String to long with base
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

Dynamic memory allocation with arena allocator and malloc/free.

```c
#include "memory.h"

// Arena allocator - fast bump allocation with manual lifetime
arena_t arena = arena_alloc(4096);        // Create 4KB arena from heap
void *p1 = arena_push(&arena, 64);        // Allocate 64 bytes (8-byte aligned)
void *p2 = arena_push_zero(&arena, 32);   // Allocate and zero-initialize
char *p3 = arena_push_align(&arena, 16, 32); // Allocate with 32-byte alignment
arena_pop(&arena, 16);                    // Deallocate from end
arena_clear(&arena);                      // Reset arena (free all at once)

// Traditional malloc/free - first-fit, coalescing freelist allocator
void *ptr = malloc(128);                  // Allocate 128 bytes
void *arr = calloc(16, 8);                // Allocate and zero 16x8 bytes
ptr = realloc(ptr, 256);                  // Grow/shrink an allocation
free(ptr);                                // Return to freelist
```

**Arena vs malloc:**
- Arena: Fast allocation, bulk deallocation, no fragmentation, fixed lifetime
- malloc/free: Flexible lifetime and individual deallocation; adjacent free
  blocks are coalesced to limit fragmentation

Arena allocation failure is represented by `arena.start == NULL` and zero
capacity. Oversized requests and size-arithmetic overflow return `NULL` from
`malloc`, `calloc`, and `realloc` without consuming or corrupting the heap.

### Sprintf (`lib/include/sprintf.h`, `lib/src/sprintf.c`)

Portable `sprintf`/`snprintf` with no `<stdio.h>` dependency. Uses integer-scaling for floating-point formatting to avoid cascading FP-rounding errors.

```c
#include "sprintf.h"

char buf[128];
sprintf(buf, "x=%d y=%s", 42, "hello");       // Unbounded format
snprintf(buf, sizeof(buf), "%.2f", 3.14159);   // Bounded (C99 semantics)
```

**Supported format specifiers:**
- `%d`/`%i`, `%u`, `%o`, `%x`/`%X` — integer (signed/unsigned, octal, hex)
- `%f`/`%F`, `%e`/`%E`, `%g`/`%G` — floating-point (fixed, scientific, shortest)
- `%c` — character, `%s` — string, `%p` — pointer, `%%` — literal percent
- Flags: `-` `+` `space` `0` `#`
- Width/precision: literal or `*`
- Length modifiers: `hh` `h` `l` `ll` `z` `t`

Large widths and floating-point precisions are counted and truncated directly
into the caller's destination; they do not allocate precision-sized scratch
buffers. If the would-be output length cannot fit in `int`, the function returns
`-1` while still terminating a non-empty destination buffer.

**Makefile setup:** The 64-bit integer arithmetic used internally requires `-lgcc`. Add this to your app's Makefile before the `include`:
```makefile
EXTRA_LDFLAGS := -lgcc
SRC_C := ../../lib/src/uart.c ../../lib/src/sprintf.c your_app.c
include ../../common/common.mk
```

### Limits (`lib/include/limits.h`)

Integer limit constants. `int` is 32-bit at both ABIs; `long` follows the ABI width (32-bit at ilp32/rv32, 64-bit at lp64/rv64).

```c
#include "limits.h"

INT_MIN   // -2147483648
INT_MAX   // 2147483647
LONG_MIN  // -2147483648L at ilp32; -9223372036854775808L at lp64
LONG_MAX  // 2147483647L at ilp32; 9223372036854775807L at lp64
```

### Timer (`lib/include/timer.h`)

Timer utilities using Zicntr CSR counters for timing measurements and delays.

```c
#include "timer.h"

uint32_t start = read_timer();            // Read cycle counter (uses rdcycle)
// ... do work ...
uint32_t elapsed = read_timer() - start;  // Measure elapsed cycles

uint64_t start64 = read_timer64();        // Read full 64-bit cycle counter
// ... long-running work ...
uint64_t elapsed64 = read_timer64() - start64;  // For benchmarks >14 seconds

delay_ticks(1000);                        // Busy-wait for N cycles
delay_1_second();                         // Wait ~1 second
```

**Note:** Timer functionality is implemented using the Zicntr CSR cycle counter,
providing single-instruction access (faster than MMIO). Use `read_timer64()` for
long-running benchmarks to avoid 32-bit overflow (which occurs after ~14 seconds
at 300 MHz).

### FIFO (`lib/include/fifo.h`)

Memory-mapped FIFO interface for inter-module communication.

```c
#include "fifo.h"

fifo0_write(0x12345678);                  // Write 32-bit word
uint32_t data = fifo0_read();             // Read 32-bit word
```

### Synchronization (`lib/include/sync.h`)

Memory and instruction synchronization barriers (Zifencei extension).

```c
#include "sync.h"

fence();                                  // Memory ordering fence
fence_i();                                // Instruction fetch fence
```

**Use cases:**
- `fence()`: Ensure memory operations complete before subsequent accesses
- `fence_i()`: Synchronize instruction stream after modifying code in memory. On
  Frost this is a real cache-sync (writes the L1D back through the line port, then
  invalidates the L1I and the fetch buffer), required for self-modifying code in
  the cached region — see `apps/ddr_smc_test/`

### CSR Access (`lib/include/csr.h`)

Control and Status Register access for performance counters and machine-mode control (Zicsr + Zicntr extensions).

```c
#include "csr.h"

// Read individual counter halves
uint32_t cycles_lo = rdcycle();           // Low 32 bits of cycle counter
uint32_t cycles_hi = rdcycleh();          // High 32 bits (rv32 only)
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

**Available counters:**
- `cycle`/`cycleh`: Clock cycles since reset (64-bit)
- `time`/`timeh`: Wall-clock time (backed by CLINT mtime, which ticks at the core clock on Frost)
- `instret`/`instreth`: Instructions retired since reset (64-bit)

The `*h` high-half CSRs exist only at rv32: at rv64 each counter is a single
64-bit CSR (accessing `*h` traps) and the `rd*64()` helpers read it directly.

**M-mode CSRs (for RTOS support):**
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

**CLINT-compatible timer registers (memory-mapped at 0x40000010-0x40000020):**
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

Each app directory contains a source-level doc comment with full details.
The table below is a quick-reference; see the source for authoritative descriptions.
Apps are also discoverable via `./scripts/frost.py cocotb --list-tests`.

| App | Description |
|-----|-------------|
| `arch_test/` | RISC-V Architecture Compliance suite (riscv-arch-test, 400+ tests, both XLENs against per-XLEN Spike references, Verilator only) |
| `branch_pred_test/` | Assembly-level branch predictor verification (45 BTB tests) |
| `c_ext_test/` | Compressed (C ext) instruction test — JAL/JALR/JR alignment cases |
| `call_stress/` | Nested function call stress test for call stack and compressed returns |
| `cf_ext_test/` | Compressed floating-point instruction test (C.FLD/C.FSD at both XLENs; rv32-only C.FLW/C.FSW) |
| `coremark/` | Industry-standard EEMBC CoreMark CPU benchmark |
| `coremark_pro/` | EEMBC CoreMark-PRO suite (git submodule). All nine official workloads run on both boards, calibrated per workload in `apps/software_registry.py`; builds use the unified linker script, placing the malloc heap (and large datasets such as radix2's FFT tables) in the 1 GiB cached DDR region |
| `csr_test/` | CSR access and M-mode trap handling verification |
| `fpu_assembly_test/` | FP hazard corner-case tests (squashed loads, load-use stalls) |
| `fpu_test/` | FPU compliance tests (subnormals, FMA, rounding, conversions) |
| `freertos_demo/` | FreeRTOS preemptive multitasking demo (requires `git submodule update --init`) |
| `hello_world/` | Minimal UART/timer sanity check — prints a greeting every second |
| `isa_test/` | Comprehensive ISA self-test for all Frost extensions (RV32GCB/RV64GCB per build axis + M-mode) |
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
| `tomasulo_test/` | Tomasulo correctness test — RAW/WAR/WAW hazards, renaming, OOO execution |
| `uart_echo/` | Interactive UART RX demo with echo, hex, and count commands |
| `ddr_exec_test/` | Execute-from-DDR test: runs `.ddr_text` functions through the L1I fetch path (leaf/loop/recursion, cross-quadrant calls, bodies larger than the fetch buffer, warm-vs-cold) |
| `ddr_heap_test/` | Multi-MB malloc capacity test through the cache hierarchy into DDR |
| `ddr_smc_test/` | Self-modifying-code / `fence.i` test: writes instruction words into a DDR buffer and executes them, exercising the full L1D-writeback then L1I-invalidate sync chain |
| `ddr_test/` | Cached-region bring-up test (stores/loads, byte strobes, eviction sweeps, and the preloaded `.ddr_rodata` image path) |
| `amo_irq_torture/` | Machine-timer IRQs swept across cached-DDR AMO bursts; the counter-array sum-check catches any double-applied or lost atomic — the directed regression for the interrupt-orphaned AMO write that made `linux_boot` flaky |
| `tick_torture/` | Linux-faithful CLINT tick re-arm (hi=-1/lo/hi order, torn-read mtime loop, catch-up) under multi-MB DDR thrash, with re-arm readback verify, a lost-tick watchdog, and a bounded-WFI wake check |

## Building

### Automatic Compilation

Applications are compiled automatically when needed by:
- `./scripts/frost.py cocotb <test>` — cleans, then compiles before simulation
- `./fpga/load_software/load_software.py` — compiles before loading to FPGA
- `./fpga/build/build.py` — compiles hello_world for initial BRAM contents

No manual build step is required for normal use.

### Prerequisites

- RISC-V GCC toolchain (`riscv-none-elf-gcc` from [xPack](https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack), or similar)
- GNU Make

### Manual Compilation (Optional)

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

The CLI always runs `make clean` first and stops if cleaning fails. This prevents
an image linked for one memory tier from being silently reused for another.
Most app builds have a two-minute timeout; `linux_boot` allows up to 90 minutes
because a fresh checkout builds its Buildroot toolchain, kernel, and initramfs
before packing the images.

### Build Ordinary Standalone Applications

```bash
./sw/apps/build_all_apps.py                       # Clean and build ordinary apps
./sw/apps/build_all_apps.py --list                # Show build/skip decisions
./sw/apps/build_all_apps.py --include-linux-boot  # Opt in to the long Linux build
```

The script discovers non-hidden app directories that contain a `Makefile`. It
skips `arch_test`, `riscv_tests`, and `riscv_torture` because their dedicated
runners must choose a test source. It also skips `linux_boot` by default because
its first Buildroot build takes roughly 30-60 minutes; the opt-in flag above
includes it. Each skip is printed with its reason.

### Clean All Applications

```bash
./sw/apps/clean_all_apps.py
```

This removes all build artifacts (sw.elf, sw.mem, sw64.mem, sw.bin, sw.txt,
sw.S, the cached-region `sw_ddr.mem`/`sw_ddr.txt`/`sw_ddr.bin` images, and any
split-bank `sw_imem_*.mem` files) from every application directory.

### Build Outputs

Compilation produces:
- `sw.elf` — ELF executable with debug symbols
- `sw.mem` — Verilog hex format for `$readmemh` (low BRAM image, 32-bit words)
- `sw64.mem` — dword-paired copy of `sw.mem` for the 64-bit data BRAM's `$readmemh` (docs/rv64/m1_data_tier.md)
- `sw.bin` — raw binary (low BRAM image)
- `sw.txt` — BRAM initialization for Vivado
- `sw_ddr.mem` — cached-region (DDR) image for `$readmemh`, region-relative (offset 0 = `0x8000_0000`); a single zero word when the program puts nothing in the cached region
- `sw_ddr.txt` — cached-region (DDR) image for the JTAG loader (dense words)
- `sw.S` — disassembly listing

### Toolchain Override

```bash
make RISCV_PREFIX=riscv-none-elf-
```

### RV64 Build Axis

`FROST_RV64=1 make` selects the rv64/lp64 build: `sw/common/arch.mk`
derives the `-march` prefix, ABI, and linker emulation, and the same
environment variable makes `tests/Makefile` elaborate the RTL with
`-DFROST_RV64` and flips `verif/config.py` — one knob for hardware,
software, and verification (docs/rv64/phase1_plan.md, decision D1).
The default (unset/0) selects the rv32 build; both XLENs ship on hardware
(rv64 on the Alveo X3, rv32 on the Genesys2). `rv64_smoke` is the
first rv64-only app and refuses to build without the flag.

### Memory Configuration (BRAM vs DDR tier)

`common.mk` takes a `MEM_CONFIG` knob selecting which memory tier the *whole*
program is linked into:

```bash
make                    # MEM_CONFIG=bram (default): whole program in low BRAM
make MEM_CONFIG=ddr     # whole program relocated to the cached DDR region
```

The shared build backends fingerprint their effective tool/flag/link
configuration: C applications use `common.mk`, and self-starting assembly apps
use `common/standalone_asm.mk`. CoreMark-PRO applies the same guarantee to its
workload-specific object graph and tracks included headers per object. A direct
`make` therefore rebuilds when a tracked header changes, when switching between
`bram` and `ddr` in either direction, or when selecting another CoreMark-PRO
workload; unknown `MEM_CONFIG` values are rejected. The CLI still cleans first
for a deterministic standalone build.

- `bram` (default): the program lives in low BRAM; only opt-in `.ddr_*` sections
  (and the malloc heap) sit in the cached DDR region. Every board/FPGA flow uses
  this.
- `ddr`: the program is linked at `0x8000_0000` behind a ROM boot stub
  (`common/crt0_ddr_boot.S`) that far-jumps to the DDR-resident `_start`, so the
  L1I fetch path and the D-side cached load/store path are both exercised. This
  selects `common/link_ddr.ld` and splits all loadable sections into the DDR
  image (`sw_ddr.mem`), leaving only the boot stub in `sw.mem`.

The CI runs the cocotb real-program, riscv-tests, and riscv-torture suites in
both a `bram` tier and a `ddr` tier as separate jobs. Arch compliance uses the
same memory-tier machinery, but CI skips the very slow F/D DDR permutations;
FPU conformance remains covered by F/D BRAM jobs, and DDR/cache behavior by the
other DDR tiers. The harnesses select the tier via `--mem-config`
(`test_arch_compliance.py`, `test_riscv_tests.py`, `test_riscv_torture.py`) or
`FROST_COCOTB_MEM_CONFIG=ddr` (`test_run_cocotb.py` / `compile_app.py`). A
handful of suites (`riscv_tests`, `arch_test`, `riscv_torture`, `freertos_demo`)
keep their own per-config linker scripts, and all but `freertos_demo` also keep
their own boot stubs (`freertos_demo` uses `common/crt0_ddr_boot.S`); the exact
file names differ per suite — see each app's Makefile.

### Clock Frequency

The default CPU clock is 300 MHz. Override for different hardware:

```bash
make FPGA_CPU_CLK_FREQ=100000000  # 100 MHz
```

Board-aware loaders set `FPGA_CPU_CLK_FREQ` automatically so timing printouts
and benchmark normalization match the target board.

## Memory Map

The unified memory map is identical on every board and in simulation; the
cache hierarchy behind the cached region (128 KiB L1D on every board; a
16 KiB L1I plus a 2 MiB URAM L2 on UltraScale+, a 128 KiB L1I with no L2
on Genesys2; over the board's DDR) is opaque to software.

Defined in `common/link.ld`:

| Region | Address      | Size    | Description                                        |
|--------|--------------|---------|----------------------------------------------------|
| ROM    | `0x00000000` | 96 KiB  | Code and small read-only data (fast BRAM, 1-cycle) |
| RAM    | `0x00018000` | 160 KiB | Variables, BSS, and stack (fast BRAM, 1-cycle)     |
| MMIO   | `0x40000000` | 44 B    | Memory-mapped I/O peripherals (legacy/linker window; the NS16550 UART at `0x40001000` and the SiFive CLINT alias at `0x40010000` sit above it) |
| DDR    | `0x80000000` | 1 GiB   | Cached region: execute-from-DDR code, heap, large `.ddr_*` data |

Within the DDR region, opt-in `.ddr_text` code comes first, then the loaded
`.ddr_rodata`/`.ddr_data` sections (e.g. radix2's ~800 KiB FFT tables, routed
there by per-object linker rules or an explicit
`__attribute__((section(".ddr_rodata")))`), then `.ddr_bss`, then the heap to
the end of the gigabyte. The dense `sw_ddr.txt` loader image starts at the
lowest `.ddr_*` LMA, which must stay exactly at the region base. The low-BRAM
stack carries a 112 KiB reserve sized from measured per-workload high-water
marks (parser's recursive XML cleanup is the deepest user at 112 KiB), enforced
by a link-time assert against data+bss growth.

Image delivery is split: `sw.mem`/`sw.txt` carry the low-BRAM image, and
`sw_ddr.mem`/`sw_ddr.txt` carry the cached-region image (region-relative,
offset 0 = `0x8000_0000`), consumed by the behavioral DDR model in simulation
and by the JTAG DDR loader on hardware.

A few test suites keep app-specific scripts (`riscv_tests`, `arch_test`,
`riscv_torture`, `freertos_demo`) for their own section layouts; all use the
same 256 KiB low-BRAM map.

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

**Notes:**
- Simple timing uses Zicntr CSR counters (cycle, instret) via single-instruction reads. See `csr.h` and `timer.h`.
- RTOS-style timer interrupts use the CLINT-compatible mtime/mtimecmp registers. See `trap.h`.

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

Frost implements **RV64GCB** with Machine (M) and User (U) privilege modes; the same source builds as **RV32GCB** via the `FROST_RV64` build axis (unset = rv32, `FROST_RV64=1` = rv64). See the [root README](../README.md) for the full ISA extension table and architecture details.

### Test Result Markers

All test applications print standardized markers that the cocotb verification framework uses to determine pass/fail status:

- **`<<PASS>>`**: Printed when all tests pass successfully
- **`<<FAIL>>`**: Printed when any test fails

These markers are distinct from individual test output (like `PASS: test_name`) and signal the overall result to the simulation testbench. The cocotb test (`test_real_program.py`) monitors UART output and fails the simulation if:
- The `<<FAIL>>` marker is detected
- The `<<PASS>>` marker is not detected within 500,000 clock cycles

**Special cases:**
- **hello_world**: Open-ended (loops forever); passes when "Hello, world!" is printed
- **linux_boot**: Kernel boot; passes when the "Linux version" boot banner is printed (uses a boot-health checker in full CI runs)
- **uart_echo**: Interactive; the harness injects UART input and passes when the prompt, echo, and response are observed (no `<<PASS>>` marker)

### Other Details

- **ABI**: ILP32D at rv32 (the default build; 32-bit integers, longs, pointers) or LP64D at rv64 (`FROST_RV64=1`; 64-bit longs and pointers); hardware double-precision float in both
- **Floating-point**: Hardware F/D extensions (single/double-precision IEEE 754)
- **No OS/libc**: Fully bare-metal, minimal dependencies
- **Optimization**: Default `-O3` (can be overridden per-app, e.g., isa_test uses `-O2`)
