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
    ├── hello_world/  # Simple test program
    ├── isa_test/     # ISA compliance test suite
    ├── packet_parser/# FIX protocol message parser
    ├── coremark/     # CPU benchmark
    ├── freertos_demo/# FreeRTOS demo with multiple tasks
    ├── csr_test/     # CSR and trap handling tests
    ├── strings_test/ # String library test suite
    ├── memory_test/  # Memory allocator test suite
    ├── c_ext_test/   # C extension (compressed) instruction test
    ├── cf_ext_test/  # Compressed floating-point (C.FLW/C.FSW/C.FLD/C.FSD) test
    ├── fpu_test/     # FPU compliance test suite (F/D extensions)
    ├── fpu_assembly_test/ # FPU assembly hazard tests
    ├── call_stress/  # Function call stress test
    ├── spanning_test/# Instruction spanning boundary test
    ├── uart_echo/    # UART RX echo demo with interactive commands
    ├── branch_pred_test/ # Branch predictor verification (assembly)
    ├── ras_test/     # Return Address Stack (RAS) verification (assembly)
    ├── ras_stress_test/  # Stress test mixing calls, returns, and branches
    └── print_clock_speed/ # Clock speed measurement utility
```

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

### Hello World (`apps/hello_world/`)

Minimal test program that prints a message every second. Useful for verifying UART output and timer functionality.

```
[     0 s] Frost: Hello, world!
Δticks = 300000000 (expect ≈ 300000000)
[     1 s] Frost: Hello, world!
...
```

### ISA Test (`apps/isa_test/`)

Comprehensive RISC-V ISA compliance test suite. Tests all instructions from every extension supported by Frost with known inputs and expected outputs. Provides clear pass/fail reporting per-instruction and per-extension.

**Tested extensions (RV32GCB (G = IMAFD) + additional):**
- RV32I (base integer), M (multiply/divide), A (atomics), C (compressed)
- F/D (single- and double-precision floating-point)
- B (bit manipulation: B = Zba + Zbb + Zbs)
- Zicsr, Zicntr (CSR access and counters)
- Zifencei (instruction fence)
- Zicond (conditional zero), Zbkb (crypto bit ops), Zihintpause (pause hint)
- Machine mode (M-mode CSRs, trap handling, ECALL, EBREAK, MRET, WFI)

Note: Output now includes F and D sections for single/double-precision tests; counts may vary as tests evolve.

```
============================================================
                    ISA TEST SUMMARY
============================================================

  RV32I        [PASS]  87/87 tests passed
  M            [PASS]  49/49 tests passed
  A            [PASS]  31/31 tests passed
  C            [PASS]  33/33 tests passed
  Zicsr        [PASS]  3/3 tests passed
  Zicntr       [PASS]  7/7 tests passed
  Zifencei     [PASS]  1/1 tests passed
  Zba          [PASS]  14/14 tests passed
  Zbb          [PASS]  65/65 tests passed
  Zbs          [PASS]  31/31 tests passed
  Zicond       [PASS]  8/8 tests passed
  Zbkb         [PASS]  12/12 tests passed
  Zihintpause  [PASS]  2/2 tests passed
  MachMode     [PASS]  23/23 tests passed

------------------------------------------------------------
  EXTENSIONS: 14 PASSED, 0 FAILED
  TESTS:      366 PASSED, 0 FAILED
------------------------------------------------------------

  *** ALL TESTS PASSED - PROCESSOR IS COMPLIANT ***
```

### Packet Parser (`apps/packet_parser/`)

Demonstrates FIX protocol message parsing. Reads tag/value pairs from FIFOs and constructs structured message objects. Measures parsing latency in clock cycles.

### CoreMark (`apps/coremark/`)

Industry-standard CPU benchmark from EEMBC. Measures processor performance in CoreMark/MHz. Configured for bare-metal operation with hardware timer.

### FreeRTOS Demo (`apps/freertos_demo/`)

Demonstrates FreeRTOS running on the FROST processor with multiple tasks using preemptive scheduling. The demo creates three tasks that print messages and demonstrates context switching via timer interrupts.

**Requirements:**
- Run `git submodule update --init` to fetch the FreeRTOS-Kernel

**Features demonstrated:**
- Timer interrupt-driven preemptive scheduling
- Multiple FreeRTOS tasks with different priorities
- Context save/restore via custom FROST port
- CLINT-compatible timer for tick generation

### CSR Test (`apps/csr_test/`)

Tests CSR (Control and Status Register) access and M-mode trap handling functionality. Verifies correct behavior of machine-mode CSRs including mstatus, mtvec, mepc, mcause, and timer registers.

### Strings Test (`apps/strings_test/`)

Library test suite that exercises all functions in `string.c`, `ctype.c`, and `stdlib.c`. Tests include:

- **string.c**: memset, memcpy, memmove, memcmp, strlen, strncpy, strcmp, strncmp, strchr, strstr
- **ctype.c**: isdigit, isalpha, isupper, islower, toupper, tolower, isspace
- **stdlib.c**: strtol, atoi, atol

Provides pass/fail reporting for each test with comprehensive edge case coverage.

### Memory Test (`apps/memory_test/`)

Test suite for the memory allocation library (`memory.c`). Tests include:

- **Arena allocator**: arena_alloc, arena_push, arena_push_zero, arena_push_align, arena_pop, arena_clear
- **malloc/free**: Basic allocation, freelist reuse, alignment verification

Provides pass/fail reporting for each test.

### C Extension Test (`apps/c_ext_test/`)

Assembly-level test for RISC-V C extension (compressed 16-bit instructions). Tests function calls (JAL, C.JAL, C.JALR) and returns (C.JR) from various instruction alignments. Written in raw assembly to precisely control instruction encoding and verify correct decompression and PC handling.

### Call Stress (`apps/call_stress/`)

Stress test for nested function calls with C extension enabled. Tests the call stack and return address handling by making many levels of nested calls, verifying that the compressed call/return instructions work correctly under stress.

### Spanning Test (`apps/spanning_test/`)

Tests instruction fetch across word boundaries. Verifies correct handling of 32-bit instructions that span memory word boundaries, which is important for compressed extension support where the instruction stream contains mixed 16-bit and 32-bit instructions.

### UART Echo (`apps/uart_echo/`)

Interactive demo that exercises the UART receive functionality. Provides a command-line interface with the following commands:

- `help` - Show available commands
- `echo` - Enter character echo mode (Ctrl+C to exit)
- `hex` - Show hex value of each typed character
- `count` - Count received characters for ~10 seconds
- `info` - Show UART status

Any other input is echoed back with a character count. Use a serial terminal at 115200 baud to interact.

### Branch Predictor Test (`apps/branch_pred_test/`)

Assembly-level verification suite for the branch predictor. Contains 45 targeted tests that exercise the Branch Target Buffer (BTB) with various branch patterns, loop structures, and edge cases. Written in raw assembly for precise control over instruction placement and timing.

### Return Address Stack Test (`apps/ras_test/`)

Comprehensive assembly-level verification suite for the Return Address Stack (RAS). Exercises 32-bit and compressed calls/returns, deep nesting (2-level through 8-level), alignment cases, coroutines, and edge cases with pass/fail output.

### RAS Stress Test (`apps/ras_stress_test/`)

C-based stress test that mixes loops, branches, function pointers, and nested calls to stress BTB+RAS interactions (CoreMark-like patterns).

### Print Clock Speed (`apps/print_clock_speed/`)

Simple utility that measures and reports the CPU clock frequency. Useful for verifying the clock configuration on different FPGA boards.

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
| ROM    | `0x00000000` | 48 KB | Code and read-only data       |
| RAM    | `0x0000C000` | 16 KB | Variables, BSS, and stack     |
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

### Supported RISC-V Extensions

**ISA: RV32GCB** (G = IMAFD) plus additional extensions

| Extension       | Description                                                                        |
|-----------------|------------------------------------------------------------------------------------|
| **RV32I**       | Base integer instruction set                                                       |
| **M**           | Integer multiply/divide                                                            |
| **A**           | Atomic memory operations (LR.W, SC.W, AMO instructions)                            |
| **F**           | Single-precision floating-point (32-bit IEEE 754)                                  |
| **D**           | Double-precision floating-point (64-bit IEEE 754)                                  |
| **C**           | Compressed instructions (16-bit encodings for reduced code size)                   |
| **B**           | Bit manipulation (B = Zba + Zbb + Zbs)                                             |
| **Zba**         | Address generation (sh1add, sh2add, sh3add) - part of B                            |
| **Zbb**         | Basic bit manipulation (clz, ctz, cpop, min/max, sext, zext, rotations, orc.b, rev8) - part of B |
| **Zbs**         | Single-bit operations (bset, bclr, binv, bext + immediate variants) - part of B    |
| **Zicsr**       | CSR access instructions                                                            |
| **Zicntr**      | Base counters (cycle, time, instret)                                               |
| **Zifencei**    | Instruction fence (fence.i)                                                        |
| **Zicond**      | Conditional zero (czero.eqz, czero.nez) - not part of B                            |
| **Zbkb**        | Bit manipulation for crypto (pack, packh, brev8, zip, unzip) - part of Zk, not B   |
| **Zihintpause** | Pause hint for spin-wait loops                                                     |

### Machine Mode (M-mode) Support

Frost implements machine-mode only (no S-mode or U-mode), providing full privilege for all code. This is suitable for bare-metal or RTOS operation.

**Trap handling:**
- `mtvec`: Trap vector in direct mode (all traps jump to single handler address)
- `mepc`: Saved PC on trap, restored by MRET
- `mcause`: Interrupt bit + cause code (ECALL=11, EBREAK=3, timer=7, software=3, external=11)
- `mtval`: Faulting address or instruction

**Privileged instructions:**
- `WFI`: Wait for interrupt (low-power idle)
- `ECALL`: Environment call (generates exception with mcause=11)
- `EBREAK`: Breakpoint (generates exception with mcause=3)
- `MRET`: Return from trap handler

**CLINT-compatible timer:**
- Memory-mapped mtime/mtimecmp at 0x40000010-0x4000001C
- Software interrupt pending (msip) at 0x40000020
- Timer interrupt when mtime >= mtimecmp

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
