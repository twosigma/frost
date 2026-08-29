# Contributing to FROST Software

This covers bare-metal software. For RTL, verification, or FPGA work, see the
[main guide](../CONTRIBUTING.md).

## Getting Started

Install a RISC-V cross-compiler such as `riscv-none-elf-gcc`, then verify it:

```bash
cd sw/apps/hello_world
make
```

## Project Structure

```
sw/
├── common/             # Shared build infrastructure
│   ├── common.mk       # RISC-V compilation rules and flags (MEM_CONFIG bram|ddr)
│   ├── standalone_asm.mk # Rules for applications that define their own _start
│   ├── crt0.S          # Assembly startup code (stack init, BSS zeroing)
│   ├── crt0_ddr_boot.S # ROM boot stub for MEM_CONFIG=ddr (far-jumps to DDR _start)
│   ├── link.ld         # Linker script (low BRAM + 1 GiB cached DDR region)
│   └── link_ddr.ld     # DDR-tier linker (whole program in the cached DDR region)
├── lib/                # Reusable bare-metal libraries
│   ├── include/        # Public headers (uart.h, timer.h, memory.h, etc.)
│   └── src/            # Library implementations
├── apps/               # Application programs (each independently buildable)
│   ├── hello_world/    # Basic UART demo
│   ├── coremark/       # CoreMark benchmark
│   ├── isa_test/       # ISA self-test for the Frost extensions
│   ├── freertos_demo/  # FreeRTOS RTOS example
│   ├── build_all_apps.py # Build ordinary standalone applications
│   └── ...             # Other applications
└── FreeRTOS-Kernel/    # FreeRTOS submodule (git submodule)
```

## Memory Constraints

FROST programs link into **256 KiB of low BRAM** (96 KiB ROM at `0x0000_0000` +
160 KiB RAM at `0x0001_8000`, 1-cycle, uncached) plus a **1 GiB cached DDR
region** at `0x8000_0000`. See `common/link.ld` for the full map; the
[software README](README.md#memory-map) has the address table.

| Section | Region | Description |
|---------|--------|-------------|
| `.text` | ROM | Code (starts at 0x0) |
| `.rodata` | ROM | Read-only data |
| `.data` / `.sdata` | RAM | Initialized data (copied from ROM by crt0) |
| `.sbss` / `.bss` | RAM | Zero-initialized data |
| Stack | RAM | Grows down from top of low RAM (`0x0004_0000`) |
| `.ddr_*` / heap | DDR | Opt-in code/data sections and the malloc heap (cached region) |

Keep the low-BRAM footprint compact (the linker asserts on ROM/stack overflow).
Use `make size` to check memory usage. Large datasets and the heap belong in the
cached DDR region via the `.ddr_*` sections or the allocator. The whole program
can instead be relocated into the cached region and executed through L1I with
`make MEM_CONFIG=ddr` (see the
[README build options](README.md#memory-configuration-bram-vs-ddr-tier)).

## License Headers

All source files must include the Apache 2.0 license header:

**C/C++ (block comment):**
```c
/*
 *    Copyright 2026 Two Sigma Open Source, LLC
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */
```

**Assembly:**
```assembly
# Copyright 2026 Two Sigma Open Source, LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# ...
```

## Code Style

Pre-commit enforces:

- **C**: clang-format (indentation, braces, spacing) and clang-tidy (static analysis)
- **Python**: Ruff (formatting and linting)

### C Code

- **Indentation**: 4 spaces (no tabs)
- **Brace style**: K&R style (opening brace on same line for control structures)
- **Line length**: 100 columns, enforced by clang-format's `ColumnLimit` (the
  pre-commit hook reflows anything longer)
- **Include guards**: Use `#ifndef FILENAME_H` / `#define FILENAME_H` / `#endif`

#### Naming Conventions

| Element | Convention | Example |
|---------|------------|---------|
| Functions | `snake_case` | `uart_printf()`, `read_timer()` |
| Variables | `snake_case` | `timer_value`, `byte_count` |
| Macros/Constants | `UPPER_CASE` | `UART_BASE_ADDR`, `MAX_BUFFER_SIZE` |
| Types | `snake_case_t` | `uart_config_t` |

#### Type Usage

- Use `stdint.h` types for hardware-related variables: `uint32_t`, `uint8_t`, etc.
- Use `volatile` for all MMIO pointers: `volatile uint32_t *reg`
- Prefer `unsigned` for bit manipulation and hardware registers

#### Example

```c
/*
 * Module purpose.
 */

#ifndef EXAMPLE_H
#define EXAMPLE_H

#include <stdint.h>

#define STATUS_READY_MASK 0x01

/**
 * Wait for hardware readiness and process value.
 *
 * @param value Input value to process
 * @return Processed result
 */
uint32_t process_value(uint32_t value)
{
    volatile uint32_t *status_reg = (volatile uint32_t *)MMIO_STATUS_ADDR;

    // Wait for hardware readiness
    while ((*status_reg & STATUS_READY_MASK) == 0) {
        // Spin wait
    }

    return value * 2;
}

#endif /* EXAMPLE_H */
```

### Assembly Code

- Use 4-space indentation for instructions
- Comment each logical section explaining what it does
- Use meaningful label names in `snake_case`
- Align operands for readability

```assembly
# Initialize stack pointer and call main
_start:
    la      sp, _stack_top      # Load stack pointer
    call    _zero_bss           # Clear BSS section
    call    main                # Call main program
    j       .                   # Loop forever on return
```

### Documentation

- State each source file's purpose in a file-level comment
- Document public API parameters and behavior briefly
- Use `//` for inline comments, `/* */` for block comments and headers

## Adding a New Library

1. Add the public header under `lib/include/`, with a license header, include
   guard, and function documentation.

2. Add the implementation under `lib/src/`, with a license header and no libc
   dependency.

3. Add documentation to `sw/README.md` under the Libraries section

4. Add an app-level test when useful.

## Adding a New Application

1. Create `apps/<app_name>/` and add licensed source files.

2. Add a `Makefile`:

```makefile
# <Application Name>: brief purpose

# Application sources
SRC_C := ../../lib/src/uart.c your_app.c

# Optional; defaults to -O3
# OPT_LEVEL := -O2

# Disable loop unrolling
# UNROLL_LOOPS :=

# Shared build rules
include ../../common/common.mk
```

An assembly application that defines its own `_start` cannot link `crt0.S`.
Use the shared standalone backend instead so it retains the same
configuration-aware BRAM/DDR image handling:

```makefile
# Architecture constants: rv64 / lp64 (see arch.mk)
include ../../common/arch.mk
ARCH := $(FROST_XLEN_PREFIX)imac_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause
ABI := $(FROST_INT_ABI)
ASM_SRC := your_app.S

include ../../common/standalone_asm.mk
```

3. `build_all_apps.py` discovers non-hidden app directories with a
   `Makefile`, so ordinary standalone apps need no manual registration for the
   build sweep. It explicitly skips the parameterized `arch_test`,
   `riscv_tests`, and `riscv_torture` suites, and skips the 30-60 minute
   `linux_boot` Buildroot build unless `--include-linux-boot` is passed. Run it
   with `--list` to review the build/skip decisions.

4. Register the app where it must run; neither registry is
   auto-discovered: add a `CocotbRunConfig` entry to `TEST_REGISTRY` in
   `tests/test_run_cocotb.py` if it should be runnable as
   `./scripts/frost.py cocotb <app>`, and add its name to `VALID_APPS` in
   `fpga/load_software/load_software.py` if it should be loadable on hardware.

5. Document the app's purpose in its source file.

### Build Outputs

Applications built through `common.mk` generate these files:

| File | Purpose |
|------|---------|
| `sw.elf` | ELF executable with debug info |
| `sw.mem` | Verilog hex for `$readmemh` (low BRAM image) |
| `sw.bin` | Raw binary (no ELF headers, low BRAM image) |
| `sw.txt` | BRAM initialization format (Vivado) |
| `sw_ddr.mem` / `sw_ddr.txt` | Cached-region (DDR) image for sim/JTAG, region-relative to `0x8000_0000` |
| `sw_ddr.bin` | Raw cached-region image (intermediate for `sw_ddr.txt`) |
| `sw.S` | Human-readable disassembly |

`standalone_asm.mk` applications emit the same set minus `sw_ddr.bin` and
`sw_ddr.txt`, and have no `make size` target. Applications that set
`GENERATE_IMEM_INIT=1` additionally emit the `sw_imem_*.mem` bank-init files
consumed by the Vivado flow.

### Build Options

Set these `common.mk` overrides before `include`:

| Variable | Default | Description |
|----------|---------|-------------|
| `RISCV_PREFIX` | `riscv-none-elf-` | Toolchain prefix |
| `OPT_LEVEL` | `-O3` | Optimization level |
| `UNROLL_LOOPS` | `-funroll-loops` | Loop unrolling (set empty to disable) |
| `MABI` | `lp64d` | ABI |
| `MEM_CONFIG` | `bram` | Memory tier: `bram` (low BRAM) or `ddr` (whole program in the cached DDR region) |
| `LINKER_SCRIPT` | `../../common/link.ld` | Linker script path (defaults to `link_ddr.ld` when `MEM_CONFIG=ddr`) |
| `EXTRA_ASM_SRC` | (empty) | Additional assembly files |
| `EXTRA_CFLAGS` | (empty) | Additional C flags |
| `EXTRA_LDFLAGS` | (empty) | Additional linker flags (e.g. `-lgcc`) |

## ISA Support

The toolchain is configured for RV64GCB plus these extensions:

| Extension | Description |
|-----------|-------------|
| I | Base integer instructions |
| M | Multiply/divide |
| A | Atomics (LR/SC, AMO; word and doubleword forms) |
| F | Single-precision floating point |
| D | Double-precision floating point |
| C | Compressed (16-bit encoding) |
| B | Bit manipulation (Zba + Zbb + Zbs) |
| Zicsr | CSR instructions |
| Zicntr | Base counters (cycle, time, instret) |
| Zifencei | Instruction fetch fence |
| Zicond | Conditional operations |
| Zbkb | Bit manipulation for crypto |
| Zihintpause | Pause hint for spin loops |

## Testing

### Test Markers

Applications used for automated testing should print these markers:
- `<<PASS>>` on success
- `<<FAIL>>` on failure

### Running Tests

Build aggregation uses the pinned toolchain from the repository root:

```bash
# Clean and build ordinary standalone applications (special suites are reported as skipped)
./scripts/frost.py run python3 sw/apps/build_all_apps.py
```

Cocotb regression evidence must use the repository's pinned `frost` image.
`./scripts/frost.py` runs it as the host UID/GID, keeping generated files
writable for later native Vivado work. Its cocotb shortcut cleans before every
test:

```bash
# Run a specific real-program test
./scripts/frost.py cocotb hello_world

# Run that suite from the cached DDR tier
FROST_COCOTB_MEM_CONFIG=ddr ./scripts/frost.py cocotb hello_world

# List the available tests
./scripts/frost.py cocotb --list-tests
```

Parameterized runners use the wrapper's `run` workflow after an explicit
`./scripts/frost.py run make -C tests clean`; they accept
`--mem-config ddr` (`test_arch_compliance.py`, `test_riscv_tests.py`, and
`test_riscv_torture.py`).

### Hardware Testing

Test on FPGA hardware when practical:

```bash
# From the repository root; Vivado and board flows run natively, not in Docker.
# Program bitstream (once) - specify your board: x3 or genesys2
./fpga/program_bitstream/program_bitstream.py x3

# Load software (fast reload)
./fpga/load_software/load_software.py x3 hello_world
```

## FreeRTOS Applications

For FreeRTOS apps:

1. Initialize submodules: `git submodule update --init --recursive`.

2. Configure `FreeRTOSConfig.h`:
   - `configCPU_CLOCK_HZ` must match FPGA clock
   - Timer interrupt configuration for MTIP

3. See `apps/freertos_demo/` for the port and a complete example.

## Bare-Metal Constraints

Constraints:

- **No standard library**: `-nostdlib`, `-ffreestanding` are set
- **Use provided libraries**: `sw/lib/` provides uart, timer, memory, string functions
- **No heap by default**: Use `memory.h` allocator or static allocation
- **No exceptions**: C++ exceptions and RTTI are not supported
- **Volatile for MMIO**: All hardware register accesses must use `volatile`
- **Aligned access**: Some instructions require aligned memory access

## Pull Request Guidelines

1. Keep changes focused and atomic - one feature or fix per PR
2. Ensure all affected ordinary applications still build:
   `./scripts/frost.py run python3 sw/apps/build_all_apps.py` (from the
   repository root; the same pinned-toolchain form given under Running Tests).
   Run parameterized or long-build apps through their dedicated workflow when
   your change affects them.
3. Test your changes on hardware or in simulation
4. Add license headers to new files
5. Update documentation if adding or changing functionality
6. Follow the existing code style

## Commit Messages

- Use imperative mood: "Add feature" not "Added feature"
- Keep the first line under 72 characters
- Reference issues if applicable

Example:
```
Add arena allocator overflow check

The arena_push function now returns NULL if the requested allocation
would exceed the arena capacity, preventing buffer overflows.
```

## Questions

For questions, open an issue. See the [main guide](../CONTRIBUTING.md) for
project-wide rules and `hw/rtl/README.md` for the hardware architecture.
