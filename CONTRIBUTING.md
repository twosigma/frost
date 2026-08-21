# Contributing to FROST

**Quick start:** Fork the repo, build the pinned `frost` development image, make
your changes, run the affected workflows through `./scripts/frost.py`, and open
a PR. Run `./scripts/frost.py check` before submitting.

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

FROST is an out-of-order **RV64GCB** (G = IMAFD) processor with a Tomasulo
back-end and Machine + User (M/U) privilege modes.

### Architecture Outline

```
IF -> PD -> ID -> dispatch -> Tomasulo back-end -> commit
 │    │    │        │          │                  └─ ROB commit to INT/FP regfiles
 │    │    │        │          ├─ ROB, RAT, reservation stations, CDB
 │    │    │        │          └─ Load queue, store queue, FU shims
 │    │    │        └─ Rename and resource allocation
 │    │    └─ Instruction decode, CSR reads, branch target precompute
 │    └─ Pre-decode and C-extension decompression
 └─ Instruction fetch, branch prediction, return address stack
```

### Key Design Principles

- **Portability**: No vendor-specific primitives in core CPU (board wrappers may use them)
- **Timing**: Registered outputs manage critical paths
- **Verification**: Cocotb directed tests, riscv-tests / riscv-arch-test
  compliance, and Spike-referenced random torture, mirrored across the `bram`
  and `ddr` memory tiers
- **Verilator simulation**: All tests run under Verilator

### Memory Map

| Address Range | Description |
|---------------|-------------|
| `0x0000_0000` | ROM: code and read-only data, fast BRAM (96 KiB) |
| `0x4000_0000` | MMIO region (UART, FIFOs, CLINT-style timer) |
| `0x8000_0000` | DDR: cached region for code (`.ddr_text`), heap, and large data (1 GiB) |

See `hw/rtl/README.md` for the authoritative memory map and per-register MMIO layout.

## Getting Started

### Prerequisites

Local simulation, formal, synthesis, and lint workflows require Docker. The
repository image contains the same pinned Verilator, Cocotb, Yosys,
SymbiYosys, RISC-V GCC, and lint tools used by CI; host-native copies are not
valid regression evidence. Vivado and physical-board workflows are the
exception and run natively because Vivado is not distributed in the image.

See the [main README](README.md#prerequisites) for validated Docker and Vivado
versions.

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

3. Build the pinned development image:

   ```bash
   docker build -t frost .
   ```

4. Diagnose the local setup:

   ```bash
   ./scripts/frost.py doctor
   ```

   `doctor` is read-only. It reports Docker, image, submodule, cache, and
   ownership diagnostics as `PASS`, `WARN`, `FAIL`, or dependency-gated
   `SKIP`, and exits nonzero on failure. The ownership scan skips `./hw`.

5. Verify the simulator and cross-toolchain with a small real-program test:

   ```bash
   ./scripts/frost.py cocotb hello_world
   ```

6. Run the fast repository checks:

   ```bash
   ./scripts/frost.py check
   ```

   This runs CI's `Lint` and `Fast Python Tests` jobs, not the full
   simulator/formal/synthesis regression. Both phases run after a failure
   unless `--fail-fast` is set. Lint hooks can modify files; review the diff.

### Pinned Development Workflows

`./scripts/frost.py` runs the pinned image as the invoking UID/GID with its home
under `/tmp`, leaving generated files writable by native tools. The `cocotb`
and `pytest` shortcuts first run `make clean` in `tests/`; `pytest` is scoped to
`tests/test_run_cocotb.py` for marker-based Cocotb shards. Hook environments
are cached under
`$XDG_CACHE_HOME/frost/container` when that variable is set, or under
`~/.cache/frost/container` otherwise, so only the first lint run needs to
install the pinned pre-commit environments.

```bash
./scripts/frost.py doctor
./scripts/frost.py check
./scripts/frost.py cocotb hello_world
./scripts/frost.py pytest -m "cocotb and cocotb_unit" -v
./scripts/frost.py formal --target trap_unit
./scripts/frost.py synthesis --target generic
./scripts/frost.py lint
```

Use `./scripts/frost.py run <command> ...` for other pinned-toolchain commands.
The wrapper forwards `COCOTB_*`, `FROST_*`, proxy variables, `WAVES`, and
`DDR_MODEL_LATENCY`. Run `./scripts/frost.py --help` for the full interface.

## Development Workflow

### Before Making Changes

1. Create a new branch for your feature or fix:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. Run the fast checks and the affected pinned workflow to establish a baseline:

   ```bash
   ./scripts/frost.py check
   ./scripts/frost.py cocotb hello_world
   ```

### Submitting Changes

1. Ensure all tests pass
2. Update documentation if your change affects user-facing behavior
3. Run `./scripts/frost.py lint` so new files pick up the Apache 2.0 license
   header (see [License Headers](#license-headers))
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

The remaining guidelines document project conventions.

### License Headers

All source files carry the Apache 2.0 header in `.license-header.txt`. The
`insert-license` pre-commit hooks add it automatically for `.py`,
`.c`/`.h`/`.cpp`/`.hpp`, `.sv`/`.svh`/`.v`/`.vh`, `.tcl`, `Makefile`, `.mk`, and
`.sh` files, so run `./scripts/frost.py lint` on new files rather than pasting
the text by hand.

### SystemVerilog (RTL)

#### Naming Conventions

| Element | Convention | Example |
|---------|------------|---------|
| Input ports | `i_` prefix | `i_clk`, `i_rst`, `i_data_valid` |
| Output ports | `o_` prefix | `o_result`, `o_mem_addr` |
| Internal signals | No prefix, `snake_case` | `data_valid`, `next_state` |
| Registered signals | `*_registered` suffix | `branch_target_registered` |
| Struct/union types | `snake_case_t` | `interrupt_t`, `from_if_to_pd_t` |
| Enum types | `snake_case_e` | `csr_op_e`, `fu_type_e` |
| Enum values | `UPPER_CASE` | `OPC_ADD`, `STATE_IDLE` |
| Parameters | `UPPER_CASE` | `XLEN`, `MEM_DEPTH` |
| Module names | `snake_case` | `branch_jump_unit` |

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

- **Module headers**: State purpose and behavior; use diagrams for complex modules
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

- Follow **PEP 8**
- Use **type hints** on all public functions
- Use **dataclasses** for configuration objects
- Formatting is ruff-format's default 88-column style; run
  `./scripts/frost.py lint` and let it reflow code (it does not wrap comments or
  long string literals, so keep those readable by hand)
- Every module, class, and function needs a docstring (ruff `D`, pep257 convention)
- Every function in `verif/` and `tests/` needs full annotations (mypy
  `disallow_untyped_defs`)

#### Naming Conventions

| Element | Convention | Example |
|---------|------------|---------|
| Functions/variables | `snake_case` | `encode_instruction()` |
| Classes | `CamelCase` | `InstructionEncoder` |
| Constants | `UPPER_CASE` | `MASK32`, `XLEN` |
| Private functions | `_underscore_prefix` | `_validate_input()` |
| Type aliases / NewTypes | `CamelCase`, no suffix | `RegisterValue`, `ProgramCounter` (see `verif/verification_types.py`) |

#### Module Organization

```python
"""Module docstring explaining purpose.

Detailed description of module functionality.

Usage:
    >>> from config import MASK32
"""

# Standard library imports
from dataclasses import dataclass
from typing import Final

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
    seed: int | None = None


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
- Test on hardware when possible
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

# Architecture constants: provides FROST_XLEN_PREFIX / FROST_INT_ABI (rv64 / lp64)
include ../../common/arch.mk

# Compilation flags
# -march: Specify ISA extensions (I=base, M=multiply, A=atomics, C=compressed)
CFLAGS := -march=$(FROST_XLEN_PREFIX)imac -mabi=$(FROST_INT_ABI) -O3 -Wall -Wextra

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
- Validate inputs and report errors clearly
- Use descriptive variable names
- Handle errors with useful messages

## Testing Requirements

### Test Markers

The project uses pytest markers to categorize tests:

| Marker | Description | When to Run |
|--------|-------------|-------------|
| `@pytest.mark.cocotb` | Cocotb simulation tests | RTL changes |
| `@pytest.mark.cocotb_real_program` | Cocotb real-program tests (CI shard of the cocotb job) | RTL changes |
| `@pytest.mark.cocotb_unit` | Cocotb unit-bench tests (CI shard of the cocotb job) | RTL changes |
| `@pytest.mark.coremark_pro` | CoreMark-PRO real-program tests (CI shard of the cocotb job) | RTL changes |
| `@pytest.mark.synthesis` | Yosys synthesis tests | RTL changes |
| `@pytest.mark.formal` | SymbiYosys formal tests | RTL or property changes |
| `@pytest.mark.slow` | Long-running tests | When their covered path changes |
| (default) | Pure Python tests | Python changes |

### RTL Changes

Run the full CPU suite. The RV64-only core needs one registry entry per test;
CI mirrors real-program, riscv-tests, torture, and arch-compliance suites
across `bram` and `ddr`, and
`FROST_COCOTB_MEM_CONFIG=ddr` selects the cached-DDR tier locally:

```bash
# Full cocotb test suite
./scripts/frost.py pytest -v

# Directed trap/exception tests
./scripts/frost.py cocotb directed_traps

# ISA compliance tests (bram tier, then the cached-DDR tier)
./scripts/frost.py cocotb isa_test
FROST_COCOTB_MEM_CONFIG=ddr ./scripts/frost.py cocotb isa_test

# Synthesis verification
./scripts/frost.py synthesis
```

### Software Changes

Build and run Hello World:

```bash
./scripts/frost.py cocotb hello_world
```

Build all applications to verify no breakage:

```bash
./scripts/frost.py run python3 sw/apps/build_all_apps.py
```

### Python/Verification Changes

Run the fast Python tests and lint checks. If the change affects Cocotb-facing
verification code, run the relevant Cocotb target or marker shard too:

```bash
./scripts/frost.py check
./scripts/frost.py pytest -m "cocotb and cocotb_unit" -v
```

### Formal Changes

Run the affected target, then the full formal registry when appropriate:

```bash
./scripts/frost.py formal --target trap_unit
./scripts/frost.py formal
```

## Adding New Components

### Adding a New FPGA Board

1. Create board wrapper in `boards/<board_name>/`:
   ```
   boards/
   └── new_board/
       ├── new_board_frost.sv     # Top-level wrapper
       ├── new_board_frost.f      # RTL filelist read by the Vivado build
       └── constr/
           └── new_board.xdc      # Constraints file
   ```

   Both paths are hard-coded in `fpga/build/build_step.tcl`: the filelist at
   `boards/<board_name>/<board_name>_frost.f` and the constraints at
   `boards/<board_name>/constr/<board_name>.xdc`.

2. The wrapper should:
   - Instantiate `xilinx_frost_subsystem` (for Xilinx boards) or create equivalent
   - Configure clock generation (use MMCM/PLL for target frequency)
   - Map board-specific I/O (UART pins, LEDs, buttons)
   - Handle reset synchronization

3. Register the board in `fpga/build/build.py`. This step is mandatory: add a
   `BOARD_CONFIG` entry (clock frequency and UltraScale flag) and add the name
   to the `board_name` argument's `choices`, or argparse rejects the board
   before the build starts.

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
   # Source files: the app's own sources plus any sw/lib sources it uses
   SRC_C := new_app.c ../../lib/src/uart.c

   # Optional (default 0): emit the split instruction-memory .mem init files
   GENERATE_IMEM_INIT := 1

   # Include common build rules
   include ../../common/common.mk
   ```

3. Ordinary app directories with a `Makefile` are discovered automatically by
   `sw/apps/build_all_apps.py`; no build-list edit is needed. Parameterized or
   unusually long builds may need an explicit skip policy there.

4. Add a `CocotbRunConfig` entry to `TEST_REGISTRY` in
   `tests/test_run_cocotb.py` if the application should run in simulation.

### Adding a New Verification Test

1. For Cocotb tests, add to `verif/cocotb_tests/`:
   ```python
   @cocotb.test()
   async def test_new_feature(dut):
       """Test description."""
       # Test implementation
   ```

2. For pytest integration, register the testbench in
   `TEST_REGISTRY` in `tests/test_run_cocotb.py`:

   ```python
   "new_feature": CocotbRunConfig(
       python_test_module="cocotb_tests.path.test_new_feature",
       hdl_toplevel_module="new_feature",
       description="New feature unit tests",
   ),
   ```

3. Confirm the target appears in
   `./scripts/frost.py cocotb --list-tests`, then run it with
   `./scripts/frost.py cocotb new_feature`.

### Adding a New Peripheral

1. Create peripheral module in `hw/rtl/peripherals/`
2. Add memory-mapped interface following existing patterns
3. Update memory map documentation in `hw/rtl/README.md`
4. Add software driver in `sw/lib/`
5. Create test application in `sw/apps/`

## Types of Contributions

### Bug Reports

Bug reports should include:
- FROST version or commit hash
- Simulator and version used
- Minimal reproduction steps
- Expected vs. actual behavior
- Relevant log output or waveforms

### Feature Requests

Feature requests should describe:
- The use case for the feature
- How it fits with FROST's goals (simplicity, portability, educational value)
- Any implementation ideas you have

### Code Contributions

Contribution areas include:

| Area | Examples |
|------|----------|
| Bug fixes | OOO ordering, instruction encoding, timing issues |
| ISA extensions | Additional standard or custom extensions |
| Privilege modes | S-mode (supervisor), PMP, virtual memory (M and U modes already supported) |
| Board support | New FPGA boards, SoC integrations |
| Performance | Branch predictor, scheduler, memory-system, or cache improvements |
| Peripherals | SPI, I2C, GPIO, timers |
| Documentation | Architecture guides, tutorials, examples |
| Verification | New test cases, coverage improvements, formal verification |

### Documentation

Documentation contributions can:
- Fix typos or unclear explanations
- Add examples and tutorials
- Improve ASCII diagrams
- Document edge cases and design decisions

## Code Review Process

Review covers:

| Aspect | What We Look For |
|--------|------------------|
| Correctness | Does the code work as intended? Are edge cases handled? |
| Style | Does it follow project conventions (naming, formatting, comments)? |
| Testing | Are there adequate tests? Do existing tests still pass? |
| Documentation | Are changes documented? Are comments clear? |
| Portability | Does it maintain Verilator, Yosys, and Vivado compatibility? |
| Performance | Does it meet timing on target FPGAs? Are there regressions? |

## Questions?

For help:
- Open an issue for discussion
- Review existing issues and pull requests for context
- Check the documentation in `hw/rtl/README.md` for architecture details
- See `fpga/README.md` for FPGA-specific questions
- See `boards/README.md` for board support questions
