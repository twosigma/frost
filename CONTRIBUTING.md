# Contributing to FROST

Thank you for your interest in contributing to FROST. We welcome contributions of all sizes, from documentation fixes to new features.

**Quick start:** Fork the repo, make your changes, run the tests, and open a PR. Pre-commit hooks enforce formatting automatically.

This document provides guidelines for contributors. The detailed style sections are primarily for reference.

## Table of Contents

- [Project Overview](#project-overview)
- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Coding Style Guide](#coding-style-guide)
- [Testing Requirements](#testing-requirements)
- [Adding New Components](#adding-new-components)
- [Types of Contributions](#types-of-contributions)
- [Code Review Process](#code-review-process)
- [Questions?](#questions)

## Project Overview

FROST is a 6-stage pipelined RISC-V processor implementing **RV32IMACB** with full machine-mode privilege support. Understanding the architecture helps you contribute effectively:

### Pipeline Stages

```
IF → PD → ID → EX → MA → WB
 │    │    │    │    │    └─ Write-back to register file
 │    │    │    │    └─ Memory access (load/store completion)
 │    │    │    └─ Execute (ALU, branch resolution)
 │    │    └─ Instruction decode, register file read
 │    └─ Pre-decode (C-extension decompression)
 └─ Instruction fetch, branch prediction
```

### Key Design Principles

- **Portability**: No vendor-specific primitives in core CPU (board wrappers may use them)
- **Timing optimization**: Critical paths carefully managed with registered outputs
- **Comprehensive verification**: Cocotb-based testing with 16,000+ random instructions
- **Multi-simulator support**: Tested on Verilator and Icarus Verilog

### Memory Map

| Address Range | Description |
|---------------|-------------|
| `0x0000_0000` - `0x0000_FFFF` | Main memory (64KB) |
| `0x4000_0000` | MMIO region (UART, FIFOs) |

## Getting Started

### Prerequisites

Before contributing, ensure you have the required tools installed. See the [main README](README.md#prerequisites) for validated versions.

Required tools:
- **RISC-V GCC** (`riscv-none-elf-gcc`) - for compiling bare-metal software
- **Cocotb** - Python-based verification framework
- **Simulator** (one or more): Verilator or Icarus Verilog
- **Yosys** - for synthesis verification

### Setting Up Your Development Environment

1. Fork and clone the repository:
   ```bash
   git clone https://github.com/YOUR_USERNAME/frost.git
   cd frost
   ```

2. Initialize submodules (required for FreeRTOS demo):
   ```bash
   git submodule update --init --recursive
   ```

3. Verify your setup by running the test suite:
   ```bash
   pytest tests/test_run_cocotb.py -s
   ```

4. Build sample software to verify toolchain:
   ```bash
   cd sw/apps/hello_world && make
   ```

## Development Workflow

### Before Making Changes

1. Create a new branch for your feature or fix:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. Run the existing test suite to ensure everything passes:
   ```bash
   pytest tests/ -s
   ```

### Submitting Changes

1. Ensure all tests pass
2. Update documentation if your change affects user-facing behavior
3. Add Apache 2.0 license headers to new files (see [License Headers](#license-headers))
4. Write a clear commit message:
   ```
   Short summary (50 chars or less)

   More detailed explanation if needed. Explain the problem
   this commit solves and why this approach was chosen.
   ```
5. Push your branch and open a pull request
6. Respond to review feedback

## Coding Style Guide

Pre-commit hooks automatically enforce formatting:

- **SystemVerilog**: Verible formatter
- **C**: clang-format and clang-tidy
- **Python**: Ruff formatter and linter, mypy for type checking

The guidelines below document the project conventions for reference.

### License Headers

All source files must include the Apache 2.0 license header. Use the appropriate comment style for each language:

**SystemVerilog/Verilog:**
```systemverilog
/*
 * Copyright 2024-2025 Two Sigma Open Source, LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * ...
 */
```

**Python:**
```python
# Copyright 2024-2025 Two Sigma Open Source, LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# ...
```

**C:**
```c
// Copyright 2024-2025 Two Sigma Open Source, LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// ...
```

### SystemVerilog (RTL)

#### Naming Conventions

| Element | Convention | Example |
|---------|------------|---------|
| Input ports | `i_` prefix | `i_clk`, `i_rst`, `i_data_valid` |
| Output ports | `o_` prefix | `o_result`, `o_mem_addr` |
| Internal signals | No prefix, `snake_case` | `data_valid`, `next_state` |
| Registered signals | `*_registered` suffix | `branch_target_registered` |
| Type names | `CamelCase` or `*_t` suffix | `interrupt_t`, `PipelineState` |
| Enum values | `UPPER_CASE` | `OPC_ADD`, `STATE_IDLE` |
| Parameters | `UPPER_CASE` | `XLEN`, `MEM_DEPTH` |
| Module names | `snake_case` | `hazard_resolution_unit` |

#### Formatting

- **Indentation**: 2 spaces (no tabs)
- **Line length**: Keep reasonable (~100 chars), break long port lists
- **Alignment**: Align port assignments and signal declarations for readability

#### Example Module

```systemverilog
/*
 * Example Module - Brief description of purpose
 *
 * Detailed explanation of functionality, interfaces, and behavior.
 * Include ASCII diagrams for complex data flow.
 */
module example_unit #(
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned DEPTH = 16
) (
    input  logic                    i_clk,
    input  logic                    i_rst,
    input  logic                    i_valid,
    input  logic [DATA_WIDTH-1:0]   i_data,
    output logic                    o_ready,
    output logic [DATA_WIDTH-1:0]   o_result
);

  // =========================================================================
  // Internal Signals
  // =========================================================================
  logic [DATA_WIDTH-1:0] data_registered;
  logic                  valid_registered;

  // =========================================================================
  // Sequential Logic
  // =========================================================================
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      data_registered  <= '0;
      valid_registered <= 1'b0;
    end else begin
      data_registered  <= i_data;
      valid_registered <= i_valid;
    end
  end

  // =========================================================================
  // Combinational Logic
  // =========================================================================
  always_comb begin
    o_ready  = ~valid_registered;
    o_result = data_registered;
  end

endmodule
```

#### Comments and Documentation

- **Module headers**: Include purpose, behavior, and ASCII diagrams for complex modules
- **Section dividers**: Use `// =====` to organize logical sections
- **Inline comments**: Explain "why" not "what"; highlight timing-critical paths
- **Timing notes**: Document critical path considerations

```systemverilog
// This comparison is timing-critical: keep as single-cycle operation
// Alternative: pipeline if frequency target increases
assign cache_hit = (tag_stored == tag_incoming);
```

#### Portability Requirements

- No vendor-specific primitives in core CPU (`hw/rtl/cpu_and_mem/`)
- Synthesis attributes are acceptable for optimization hints
- Board-specific code goes in `boards/` directory
- Library primitives (`hw/rtl/lib/`) should be generic or have vendor alternatives

### Python (Verification and Tools)

#### Style Guidelines

- Follow **PEP 8** style guidelines
- Use **type hints** on all public functions
- Use **dataclasses** for configuration objects
- Maximum line length: 100 characters

#### Naming Conventions

| Element | Convention | Example |
|---------|------------|---------|
| Functions/variables | `snake_case` | `encode_instruction()` |
| Classes | `CamelCase` | `InstructionEncoder` |
| Constants | `UPPER_CASE` | `MASK32`, `XLEN` |
| Private functions | `_underscore_prefix` | `_validate_input()` |
| Type aliases | `CamelCase` with `_t` | `RegisterValue_t` |

#### Module Organization

```python
"""Module docstring explaining purpose.

Detailed description of module functionality.

Usage:
    >>> from config import MASK32
"""

# Standard library imports
from dataclasses import dataclass
from typing import Final, Optional

# Third-party imports
import cocotb

# Local imports
from config import XLEN

# ============================================================================
# Constants
# ============================================================================

MASK32: Final[int] = 0xFFFF_FFFF
"""Mask for 32-bit values."""

# ============================================================================
# Classes
# ============================================================================

@dataclass
class TestConfig:
    """Configuration for test execution.

    Attributes:
        num_instructions: Number of random instructions to generate.
        seed: Random seed for reproducibility.
    """
    num_instructions: int = 1000
    seed: Optional[int] = None


# ============================================================================
# Functions
# ============================================================================

def encode_instruction(opcode: int, rd: int, rs1: int) -> int:
    """Encode a RISC-V instruction.

    Args:
        opcode: 7-bit opcode field.
        rd: Destination register (0-31).
        rs1: Source register 1 (0-31).

    Returns:
        32-bit encoded instruction.

    Raises:
        ValueError: If register indices are out of range.
    """
    if not (0 <= rd <= 31 and 0 <= rs1 <= 31):
        raise ValueError("Register index out of range")
    return (opcode & 0x7F) | ((rd & 0x1F) << 7) | ((rs1 & 0x1F) << 15)
```

#### Test Files

- Use `pytest` with Cocotb integration
- Document test purpose and coverage
- Use appropriate markers: `@pytest.mark.cocotb`, `@pytest.mark.synthesis`
- Keep test configuration explicit (pass config objects, avoid global state)

### C (Bare-Metal Software)

#### Style Guidelines

- **Indentation**: 4 spaces
- Use `stdint.h` types for hardware-related variables (`uint32_t`, `uint8_t`)
- Use `volatile` for MMIO pointers
- Minimize dynamic memory allocation

#### Naming Conventions

| Element | Convention | Example |
|---------|------------|---------|
| Functions | `snake_case` | `uart_printf()`, `read_timer()` |
| Variables | `snake_case` | `timer_value`, `byte_count` |
| Constants/Macros | `UPPER_CASE` | `UART_BASE_ADDR`, `MAX_BUFFER_SIZE` |
| Types | `snake_case_t` | `uart_config_t` |

#### Example

```c
/**
 * Brief description of function.
 *
 * Detailed explanation of behavior, parameters, and return value.
 *
 * @param value Input value to process
 * @return Processed result
 */
uint32_t process_value(uint32_t value)
{
    volatile uint32_t *status_reg = (volatile uint32_t *)MMIO_STATUS_ADDR;

    // Wait for hardware ready (explain why this wait is needed)
    while ((*status_reg & STATUS_READY_MASK) == 0) {
        // Spin wait
    }

    return value * 2;
}
```

#### Bare-Metal Constraints

- No standard library (`-nostdlib`, `-ffreestanding`)
- Use provided libraries in `sw/lib/` or implement minimal versions
- Test on actual hardware when possible
- Memory layout defined in `sw/common/link.ld`

### Makefiles

- Use `?=` for overridable defaults
- Add comments explaining non-obvious build steps
- Use descriptive variable names
- Group related variables and targets

```makefile
# RISC-V toolchain configuration
RISCV_PREFIX ?= riscv-none-elf-
CC := $(RISCV_PREFIX)gcc

# Compilation flags
# -march: Specify ISA extensions (I=base, M=multiply, A=atomics, C=compressed)
# -mabi: ABI (ilp32 = 32-bit int/long/pointer)
CFLAGS := -march=rv32imac -mabi=ilp32 -O3 -Wall -Wextra

# Build targets
.PHONY: all clean

all: $(TARGET).elf $(TARGET).hex

clean:
	rm -f *.o *.elf *.hex
```

### Shell Scripts

- Add shebang: `#!/bin/bash`
- Use `set -e` for error handling
- Quote variables: `"$variable"`
- Add usage comments at top of file

### TCL (FPGA Build Scripts)

- Add comments explaining each major step
- Validate inputs and provide clear error messages
- Use descriptive variable names
- Handle errors gracefully with informative messages

## Testing Requirements

### Test Markers

The project uses pytest markers to categorize tests:

| Marker | Description | When to Run |
|--------|-------------|-------------|
| `@pytest.mark.cocotb` | Cocotb simulation tests | RTL changes |
| `@pytest.mark.synthesis` | Yosys synthesis tests | RTL changes |
| (default) | Pure Python tests | Python changes |

### RTL Changes

Run the full CPU test suite:
```bash
# Full random instruction test (16,000+ instructions)
pytest tests/test_run_cocotb.py::TestCPU -s

# ISA compliance tests
pytest tests/test_run_cocotb.py::TestRealPrograms::test_frost_isa_test -s

# Synthesis verification
pytest tests/test_run_yosys.py -s
```

Test with multiple simulators when possible:
```bash
# Icarus Verilog
pytest tests/test_run_cocotb.py -s --sim icarus

# Verilator
pytest tests/test_run_cocotb.py -s --sim verilator
```

### Software Changes

Build and run Hello World:
```bash
cd sw/apps/hello_world && make
pytest tests/test_run_cocotb.py::TestRealPrograms::test_frost_hello_world -s
```

Build all applications to verify no breakage:
```bash
cd sw/apps && ./build_all_apps.py
```

### Python/Verification Changes

Run the integration tests:
```bash
pytest tests/test_run_cocotb.py -s
```

## Adding New Components

### Adding a New FPGA Board

1. Create board wrapper in `boards/<board_name>/`:
   ```
   boards/
   └── new_board/
       ├── new_board_frost.sv     # Top-level wrapper
       └── new_board.xdc          # Constraints file
   ```

2. The wrapper should:
   - Instantiate `xilinx_frost_subsystem` (for Xilinx boards) or create equivalent
   - Configure clock generation (use MMCM/PLL for target frequency)
   - Map board-specific I/O (UART pins, LEDs, buttons)
   - Handle reset synchronization

3. Add build configuration in `fpga/build/` if needed

4. Document the board in `boards/README.md`

### Adding a New Software Application

1. Create directory in `sw/apps/<app_name>/`:
   ```
   sw/apps/
   └── new_app/
       ├── new_app.c    # Main source file
       └── Makefile     # Build configuration
   ```

2. Makefile template:
   ```makefile
   # Application name
   APP := new_app

   # Source files
   SRC_C := new_app.c

   # Include common build rules
   include ../../common/common.mk
   ```

3. Add to `build_all_apps.py` if it should be built in CI

4. Add test case in `tests/test_run_cocotb.py` if needed

### Adding a New Verification Test

1. For Cocotb tests, add to `verif/cocotb_tests/`:
   ```python
   @cocotb.test()
   async def test_new_feature(dut):
       """Test description."""
       # Test implementation
   ```

2. For pytest integration, add to `tests/test_run_cocotb.py`:
   ```python
   def test_new_feature(self):
       """Test description."""
       # Call Cocotb test
   ```

3. Use appropriate fixtures from `tests/conftest.py`

### Adding a New Peripheral

1. Create peripheral module in `hw/rtl/peripherals/`
2. Add memory-mapped interface following existing patterns
3. Update memory map documentation in `hw/rtl/README.md`
4. Add software driver in `sw/lib/`
5. Create test application in `sw/apps/`

## Types of Contributions

### Bug Reports

When reporting bugs, please include:
- FROST version or commit hash
- Simulator and version used
- Minimal reproduction steps
- Expected vs. actual behavior
- Relevant log output or waveforms

### Feature Requests

Feature requests are welcome! Please describe:
- The use case for the feature
- How it fits with FROST's goals (simplicity, portability, educational value)
- Any implementation ideas you have

### Code Contributions

We welcome contributions in these areas:

| Area | Examples |
|------|----------|
| Bug fixes | Pipeline hazards, instruction encoding, timing issues |
| ISA extensions | F (floating-point), D (double), Zfinx, custom extensions |
| Privilege modes | S-mode (supervisor), U-mode (user) support |
| Board support | New FPGA boards, SoC integrations |
| Performance | Branch predictor improvements, cache enhancements |
| Peripherals | SPI, I2C, GPIO, timers |
| Documentation | Architecture guides, tutorials, examples |
| Verification | New test cases, coverage improvements, formal verification |

### Documentation

Documentation improvements are always appreciated:
- Fix typos or unclear explanations
- Add examples and tutorials
- Improve ASCII diagrams
- Document edge cases and design decisions

## Code Review Process

All contributions go through code review. Reviewers will check:

| Aspect | What We Look For |
|--------|------------------|
| Correctness | Does the code work as intended? Are edge cases handled? |
| Style | Does it follow project conventions (naming, formatting, comments)? |
| Testing | Are there adequate tests? Do existing tests still pass? |
| Documentation | Are changes documented? Are comments clear? |
| Portability | Does it maintain cross-simulator and cross-tool compatibility? |
| Performance | Does it meet timing on target FPGAs? Are there regressions? |

## Questions?

If you have questions about contributing, feel free to:
- Open an issue for discussion
- Review existing issues and pull requests for context
- Check the documentation in `hw/rtl/README.md` for architecture details
- See `fpga/README.md` for FPGA-specific questions
- See `boards/README.md` for board support questions

Thank you for contributing to FROST!
