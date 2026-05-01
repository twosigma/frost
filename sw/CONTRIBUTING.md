# Contributing to FROST Software

Thank you for your interest in contributing to FROST. We welcome contributions of all sizes.

**Quick start:** Write your code, build with `make`, test, and open a PR. Pre-commit hooks enforce formatting automatically.

This document covers bare-metal software contributions. For RTL, verification, or FPGA work, see the [main CONTRIBUTING.md](../CONTRIBUTING.md).

## Getting Started

1. Ensure you have a RISC-V cross-compiler toolchain installed (e.g., `riscv-none-elf-gcc`)
2. Clone the repository and navigate to the `sw/` directory
3. Build an application to verify your setup: `cd apps/hello_world && make`

## Project Structure

```
sw/
├── common/             # Shared build infrastructure
│   ├── common.mk       # RISC-V compilation rules and flags
│   ├── crt0.S          # Assembly startup code (stack init, BSS zeroing)
│   └── link.ld         # Linker script (64KB memory layout)
├── lib/                # Reusable bare-metal libraries
│   ├── include/        # Public headers (uart.h, timer.h, memory.h, etc.)
│   └── src/            # Library implementations
├── apps/               # Application programs (each independently buildable)
│   ├── hello_world/    # Basic UART demo
│   ├── coremark/       # CoreMark benchmark
│   ├── isa_test/       # ISA compliance tests (366 tests)
│   ├── freertos_demo/  # FreeRTOS RTOS example
│   └── ...             # Other applications
├── FreeRTOS-Kernel/    # FreeRTOS submodule (git submodule)
└── build_all_apps.py   # Build script for all applications
```

## Memory Constraints

FROST has a **64KB memory** (addresses `0x0000_0000` - `0x0000_FFFF`) shared between code and data:

| Section | Description |
|---------|-------------|
| `.text` | Code (starts at 0x0) |
| `.rodata` | Read-only data |
| `.data` | Initialized data |
| `.bss` | Zero-initialized data |
| Stack | Grows down from top of memory |

Keep applications compact. Use `make size` to check memory usage.

## License Headers

All source files must include the Apache 2.0 license header:

**C/C++ (block comment):**
```c
/*
 *    Copyright 2024-2025 Two Sigma Open Source, LLC
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
# Copyright 2024-2025 Two Sigma Open Source, LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# ...
```

## Code Style

Pre-commit hooks automatically enforce formatting:

- **C**: clang-format (indentation, braces, spacing) and clang-tidy (static analysis)
- **Python**: Ruff (formatting and linting)

The guidelines below document the project conventions for reference.

### C Code

- **Indentation**: 4 spaces (no tabs)
- **Brace style**: K&R style (opening brace on same line for control structures)
- **Line length**: Aim for 100 characters max, hard limit at 120
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
 * Brief description of module.
 */

#ifndef EXAMPLE_H
#define EXAMPLE_H

#include <stdint.h>

#define STATUS_READY_MASK 0x01

/**
 * Wait for hardware ready and process value.
 *
 * @param value Input value to process
 * @return Processed result
 */
uint32_t process_value(uint32_t value)
{
    volatile uint32_t *status_reg = (volatile uint32_t *)MMIO_STATUS_ADDR;

    // Wait for hardware ready
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

- Add a file-level comment block explaining the purpose of each source file
- Document public API functions with brief descriptions of parameters and behavior
- Use `//` for inline comments, `/* */` for block comments and headers

## Adding a New Library

1. Create a header file in `lib/include/` with the public API:
   - Include license header
   - Use include guards
   - Document each function

2. Create an implementation in `lib/src/`:
   - Include license header
   - Keep dependencies minimal (no libc)

3. Add documentation to the main `README.md` under the Libraries section

4. Consider adding a test application in `apps/`

## Adding a New Application

1. Create a new directory under `apps/<app_name>/`

2. Add your source files (with license headers)

3. Create a `Makefile`:

```makefile
# Makefile for <Application Name>
# Brief description of what this application does

# Source files (include required libraries)
SRC_C := ../../lib/src/uart.c your_app.c

# Optional: Override optimization level (default: -O3)
# OPT_LEVEL := -O2

# Optional: Disable loop unrolling
# UNROLL_LOOPS :=

# Include common build rules
include ../../common/common.mk
```

4. Add to `build_all_apps.py` if appropriate

5. Document the application purpose in its source file

### Build Outputs

Each application generates these files:

| File | Purpose |
|------|---------|
| `sw.elf` | ELF executable with debug info |
| `sw.mem` | Verilog hex format for `$readmemh` (simulation) |
| `sw.bin` | Raw binary (no ELF headers) |
| `sw.txt` | BRAM initialization format (Vivado) |
| `sw.S` | Human-readable disassembly |

### Build Options

The `common.mk` provides these overridable options (set before `include`):

| Variable | Default | Description |
|----------|---------|-------------|
| `RISCV_PREFIX` | `riscv-none-elf-` | Toolchain prefix |
| `OPT_LEVEL` | `-O3` | Optimization level |
| `UNROLL_LOOPS` | `-funroll-loops` | Loop unrolling (set empty to disable) |
| `LINKER_SCRIPT` | `../../common/link.ld` | Linker script path |
| `EXTRA_ASM_SRC` | (empty) | Additional assembly files |
| `EXTRA_CFLAGS` | (empty) | Additional C flags |

## ISA Support

The toolchain is configured for RV32GCB plus these extensions:

| Extension | Description |
|-----------|-------------|
| I | Base integer instructions |
| M | Multiply/divide |
| A | Atomics (LR.W, SC.W, AMO) |
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

These markers are detected by the Cocotb verification framework.

### Running Tests

```bash
# Build all applications
./build_all_apps.py

# Run specific test in simulation
cd ../tests
pytest test_run_cocotb.py::TestRealPrograms::test_frost_hello_world -s

# Run ISA compliance tests
pytest test_run_cocotb.py::TestRealPrograms::test_frost_isa_test -s
```

### Hardware Testing

When possible, test on actual FPGA hardware:

```bash
# Program bitstream (once) - specify your board: x3 or genesys2
./fpga/program_bitstream/program_bitstream.py x3

# Load software (fast reload)
./fpga/load_software/load_software.py x3 hello_world
```

## FreeRTOS Applications

For FreeRTOS-based applications:

1. Ensure submodule is initialized: `git submodule update --init --recursive`

2. FreeRTOS port files are in `apps/freertos_demo/port/`

3. Configure FreeRTOS in `FreeRTOSConfig.h`:
   - `configCPU_CLOCK_HZ` must match FPGA clock
   - Timer interrupt configuration for MTIP

4. See `apps/freertos_demo/` for a complete example

## Bare-Metal Constraints

Remember these constraints when writing software:

- **No standard library**: `-nostdlib`, `-ffreestanding` are set
- **Use provided libraries**: `sw/lib/` provides uart, timer, memory, string functions
- **No heap by default**: Use `memory.h` allocator or static allocation
- **No exceptions**: C++ exceptions and RTTI are not supported
- **Volatile for MMIO**: All hardware register accesses must use `volatile`
- **Aligned access**: Some instructions require aligned memory access

## Pull Request Guidelines

1. Keep changes focused and atomic - one feature or fix per PR
2. Ensure all affected applications still build: `./build_all_apps.py`
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

## Questions?

If you have questions about contributing, please:
- Open an issue for discussion
- See the [main CONTRIBUTING.md](../CONTRIBUTING.md) for project-wide guidelines
- Check `hw/rtl/README.md` for hardware architecture details
