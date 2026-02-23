# Frost Software

Bare-metal C software for the Frost RISC-V processor.

This directory contains libraries and applications that run directly on Frost hardware without an operating system. The code is designed for low-latency, deterministic execution on FPGA-based systems.

## Directory Structure

```
sw/
├── common/           # Shared build infrastructure
│   ├── common.mk     # Common Makefile definitions
│   ├── crt0.S        # C runtime startup (runs before main)
│   └── link.ld       # Linker script (memory layout)
├── lib/              # Reusable libraries
│   ├── include/      # Header files
│   └── src/          # Source files
├── FreeRTOS-Kernel/  # FreeRTOS kernel (submodule)
└── apps/             # Application programs
    ├── compile_app.py    # Compile a single application
    ├── build_all_apps.py # Compile all applications
    ├── clean_all_apps.py # Clean all build artifacts
    ├── <app_name>/       # One directory per software app
    └── ...
```

Individual apps are listed in the [Applications](#applications) section below.
The filesystem is the authoritative inventory: `find sw/apps -maxdepth 1 -type d | sort`

## Libraries

### UART (`lib/include/uart.h`, `lib/src/uart.c`)

Serial console I/O driver with printf-style formatting and character input.

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
- `%c` - character
- `%s` - string
- `%d`, `%ld`, `%lld` - signed decimal
- `%u`, `%lu`, `%llu` - unsigned decimal
- `%x`, `%X` - hexadecimal (lowercase/uppercase)
- `%%` - literal percent sign
- Field width and zero-padding: `%8d`, `%04x`

### String (`lib/include/string.h`, `lib/src/string.c`)

Minimal C library replacements for bare-metal operation.

```c
#include "string.h"

memset(buffer, 0, sizeof(buffer));        // Fill memory
memcpy(dest, src, len);                   // Copy memory
size_t len = strlen(str);                 // String length
strncpy(dest, src, n);                    // Bounded string copy
int cmp = strcmp(a, b);                   // Compare strings
int cmp = strncmp(a, b, n);               // Compare up to n chars
char *p = strchr(str, 'x');               // Find character
char *p = strstr(haystack, needle);       // Find substring
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
```

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

// Traditional malloc/free - first-fit freelist allocator
void *ptr = malloc(128);                  // Allocate 128 bytes
free(ptr);                                // Return to freelist
```

**Arena vs malloc:**
- Arena: Fast allocation, bulk deallocation, no fragmentation, fixed lifetime
- malloc/free: Flexible lifetime, individual deallocation, potential fragmentation

### Limits (`lib/include/limits.h`)

Integer limit constants for 32-bit systems.

```c
#include "limits.h"

INT_MIN   // -2147483648
INT_MAX   // 2147483647
LONG_MIN  // -2147483648L
LONG_MAX  // 2147483647L
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
uint64_t elapsed64 = read_timer64() - start64;  // For benchmarks >13 seconds

delay_ticks(1000);                        // Busy-wait for N cycles
delay_1_second();                         // Wait ~1 second
```

**Note:** Timer functionality is implemented using the Zicntr CSR cycle counter,
providing single-instruction access (faster than MMIO). Use `read_timer64()` for
long-running benchmarks to avoid 32-bit overflow (which occurs after ~13 seconds
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
- `fence()`: Ensure memory operations complete before subsequent accesses (NOP on Frost's in-order core)
- `fence_i()`: Synchronize instruction stream after modifying code in memory (NOP on Frost - no I-cache)

### CSR Access (`lib/include/csr.h`)

Control and Status Register access for performance counters and machine-mode control (Zicsr + Zicntr extensions).

```c
#include "csr.h"

// Read individual counter halves
uint32_t cycles_lo = rdcycle();           // Low 32 bits of cycle counter
uint32_t cycles_hi = rdcycleh();          // High 32 bits of cycle counter
uint32_t instret_lo = rdinstret();        // Low 32 bits of instructions retired
uint32_t time_lo = rdtime();              // Low 32 bits of time (aliased to cycle)

// Read full 64-bit counters atomically
uint64_t start = rdcycle64();
// ... code to benchmark ...
uint64_t elapsed = rdcycle64() - start;

uint64_t instructions = rdinstret64();    // Total instructions retired

// Direct CSR access macros (for M-mode CSRs)
uint32_t status = csr_read(mstatus);      // Read any CSR by name
csr_write(mtvec, handler_addr);           // Write to CSR
csr_set(mie, MIE_MTIE);                   // Set bits in CSR
csr_clear(mstatus, MSTATUS_MIE);          // Clear bits in CSR
```

**Available counters:**
- `cycle`/`cycleh`: Clock cycles since reset (64-bit)
- `time`/`timeh`: Wall-clock time (aliased to cycle on Frost)
- `instret`/`instreth`: Instructions retired since reset (64-bit)

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
uint32_t prev = disable_interrupts();     // Clear MIE, return previous state
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
Apps are also discoverable via `./tests/test_run_cocotb.py --list-tests`.

| App | Description |
|-----|-------------|
| `arch_test/` | RISC-V Architecture Compliance suite (riscv-arch-test, 400+ tests, Verilator only) |
| `branch_pred_test/` | Assembly-level branch predictor verification (45 BTB tests) |
| `c_ext_test/` | Compressed (C ext) instruction test -- JAL/JALR/JR alignment cases |
| `call_stress/` | Nested function call stress test for call stack and compressed returns |
| `cf_ext_test/` | Compressed floating-point (C.FLW/C.FSW/C.FLD/C.FSD) instruction test |
| `coremark/` | Industry-standard EEMBC CoreMark CPU benchmark |
| `csr_test/` | CSR access and M-mode trap handling verification |
| `fpu_assembly_test/` | FP hazard corner-case tests (squashed loads, load-use stalls) |
| `fpu_test/` | FPU compliance tests (subnormals, FMA, rounding, conversions) |
| `freertos_demo/` | FreeRTOS preemptive multitasking demo (requires `git submodule update --init`) |
| `hello_world/` | Minimal UART/timer sanity check -- prints a greeting every second |
| `isa_test/` | Comprehensive ISA self-test for all Frost extensions (RV32GCB + M-mode) |
| `memory_test/` | Arena allocator and malloc/free test suite |
| `packet_parser/` | FIX protocol message parser demo with latency measurement |
| `print_clock_speed/` | Clock frequency measurement utility |
| `ras_stress_test/` | BTB+RAS stress test mixing loops, branches, and function pointers |
| `ras_test/` | Return Address Stack verification (deep nesting, coroutines, alignment) |
| `spanning_test/` | 32-bit instruction fetch across word boundary verification |
| `strings_test/` | String/ctype/stdlib library test suite |
| `uart_echo/` | Interactive UART RX demo with echo, hex, and count commands |

## Building

### Automatic Compilation

Applications are compiled automatically when needed by:
- `./tests/test_run_cocotb.py` — compiles before simulation
- `./fpga/load_software/load_software.py` — compiles before loading to FPGA
- `./fpga/build/build.py` — compiles hello_world for initial BRAM contents

No manual build step is required for normal use.

### Prerequisites

- RISC-V GCC toolchain (`riscv-none-elf-gcc` from [xPack](https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack), or similar)
- GNU Make

### Manual Compilation (Optional)

```bash
cd apps/hello_world
make
```

### Compile a Single Application

```bash
./sw/apps/compile_app.py hello_world        # Compile hello_world
./sw/apps/compile_app.py coremark -v        # Compile with verbose output
```

### Build All Applications

```bash
./sw/apps/build_all_apps.py
```

### Clean All Applications

```bash
./sw/apps/clean_all_apps.py
```

This removes all build artifacts (sw.elf, sw.mem, sw.bin, sw.txt, sw.S) from every application directory.

### Build Outputs

Compilation produces:
- `sw.elf` - ELF executable with debug symbols
- `sw.mem` - Verilog hex format for `$readmemh`
- `sw.bin` - Raw binary
- `sw.txt` - BRAM initialization for Vivado
- `sw.S` - Disassembly listing

### Toolchain Override

```bash
make RISCV_PREFIX=riscv-none-elf-
```

### Clock Frequency

The default CPU clock is 300 MHz. Override for different hardware:

```bash
make FPGA_CPU_CLK_FREQ=100000000  # 100 MHz
```

## Memory Map

Defined in `common/link.ld`:

| Region | Address      | Size  | Description                   |
|--------|--------------|-------|-------------------------------|
| ROM    | `0x00000000` | 96 KB | Code and read-only data       |
| RAM    | `0x00018000` | 32 KB | Variables, BSS, and stack     |
| MMIO   | `0x40000000` | 40 B  | Memory-mapped I/O peripherals |

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

**Notes:**
- Simple timing uses Zicntr CSR counters (cycle, instret) via single-instruction reads. See `csr.h` and `timer.h`.
- RTOS-style timer interrupts use the CLINT-compatible mtime/mtimecmp registers. See `trap.h`.

## Startup Sequence

The C runtime (`common/crt0.S`) executes before `main()`:

1. Initialize stack pointer (`sp`) to top of RAM
2. Initialize global pointer (`gp`) for small data access
3. Copy `.data` section from ROM to RAM
4. Zero-initialize `.bss` and `.sbss` sections
5. Call `main()`
6. Loop forever if `main()` returns

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

Frost implements **RV32GCB** with full M-mode privilege support. See the [root README](../README.md) for the full ISA extension table and architecture details.

### Test Result Markers

All test applications print standardized markers that the cocotb verification framework uses to determine pass/fail status:

- **`<<PASS>>`**: Printed when all tests pass successfully
- **`<<FAIL>>`**: Printed when any test fails

These markers are distinct from individual test output (like `PASS: test_name`) and signal the overall result to the simulation testbench. The cocotb test (`test_real_program.py`) monitors UART output and fails the simulation if:
- The `<<FAIL>>` marker is detected
- The `<<PASS>>` marker is not detected within 500,000 clock cycles

**Special cases:**
- **hello_world**: Open-ended (loops forever); passes when "Hello, world!" is printed
- **coremark**: Long-running benchmark; passes when "CoreMark" welcome message is printed
- **freertos_demo**: Runs multiple iterations; passes when "PASS" is printed

### Other Details

- **ABI**: ILP32D (32-bit integers, longs, pointers; hardware double-precision float)
- **Floating-point**: Hardware F/D extensions (single/double-precision IEEE 754)
- **No OS/libc**: Fully bare-metal, minimal dependencies
- **Optimization**: Default `-O3` (can be overridden per-app, e.g., isa_test uses `-O2`)
