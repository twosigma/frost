# Frost RISC-V CPU Verification Framework

## Overview

This directory contains a comprehensive Python-based verification framework for the Frost RISC-V CPU core. The framework uses [Cocotb](https://www.cocotb.org/) to verify the RTL implementation against software reference models.

## Architecture

### Verification Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                       TEST ORCHESTRATION                        │
│  ┌──────────────────┐    ┌──────────────────┐                   │
│  │ InstructionGen   │───>│ Test Loop        │                   │
│  │ (random/directed)│    │ (test_cpu.py)    │                   │
│  └──────────────────┘    └────────┬─────────┘                   │
│                                   │                             │
│  ┌──────────────────┐    ┌────────▼─────────┐    ┌────────────┐ │
│  │ TestState        │<───│ CPUModel         │───>│ Encoders   │ │
│  │ (expected vals)  │    │ (compute expect) │    │ (binary)   │ │
│  └────────┬─────────┘    └──────────────────┘    └─────┬──────┘ │
│           │                                            │        │
│  ┌────────▼─────────┐                         ┌────────▼──────┐ │
│  │ Monitors         │◄────────────────────────│ DUT           │ │
│  │ (verify outputs) │                         │ (hardware)    │ │
│  └──────────────────┘                         └───────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

1. **Instruction Generation**: Test generates instruction parameters (random or directed)
2. **CPU Model**: Software reference computes expected results
3. **Encoders**: Convert instruction parameters to binary machine code
4. **TestState**: Queues expected values for monitor verification
5. **DUT**: Binary instruction driven to hardware Design Under Test
6. **Monitors**: Compare DUT outputs against expected values

### Design Under Test (DUT)

The Frost CPU implements **RV32GCB** (G = IMAFD, plus C and B) plus additional extensions:

| Extension        | Description                                                                        |
|------------------|------------------------------------------------------------------------------------|
| **RV32I**        | 32-bit base integer instruction set                                                |
| **M**            | Integer multiply/divide (mul, div, rem variants)                                   |
| **A**            | Atomic memory operations (lr.w, sc.w, amoswap/add/xor/and/or/min/max.w)            |
| **F**            | Single-precision floating-point (32-bit IEEE 754)                                 |
| **D**            | Double-precision floating-point (64-bit IEEE 754)                                 |
| **B**            | Bit manipulation (B = Zba + Zbb + Zbs)                                             |
| **C**            | Compressed instructions (16-bit encodings for reduced code size)                   |
| **Zba**          | Address generation (sh1add, sh2add, sh3add) - part of B                            |
| **Zbb**          | Basic bit manipulation (clz, ctz, cpop, min/max, sext, zext, rotations, orc.b, rev8) - part of B |
| **Zbs**          | Single-bit operations (bset, bclr, binv, bext + immediate variants) - part of B    |
| **Zicsr**        | CSR access instructions                                                            |
| **Zicntr**       | Base counters (cycle, time, instret)                                               |
| **Zifencei**     | Instruction fence (fence.i)                                                        |
| **Zicond**       | Conditional zero (czero.eqz, czero.nez) - not part of B                            |
| **Zbkb**         | Bit manipulation for crypto (pack, packh, brev8, zip, unzip) - part of Zk, not B   |
| **Zihintpause**  | Pause hint for spin-wait loops                                                     |
| **Machine Mode** | M-mode privilege (RTOS support): mret, wfi, ecall, ebreak                          |

Additional features:
- 32 general-purpose registers
- Harvard architecture with separate instruction and data memory interfaces
- 6-stage pipeline (IF → PD → ID → EX → MA → WB) with flush mechanisms

### Verification Methodology

The framework employs multiple verification strategies:

1. **Constrained Random Testing**: Generates thousands of random instruction sequences
2. **Directed Testing**: Runs real programs (Hello World, CoreMark)
3. **Coverage-Driven Verification**: Ensures all instruction types are thoroughly tested

## Directory Structure

```
verif/
├── config.py              # Central configuration constants
├── verification_types.py  # Type aliases for type safety
├── exceptions.py          # Custom exception hierarchy
├── cocotb_tests/          # Cocotb test cases
│   ├── test_cpu.py        # Main random regression test
│   ├── test_common.py     # Shared test utilities (TestConfig, branch flush)
│   ├── test_directed_atomics.py  # LR.W/SC.W atomic operation tests
│   ├── test_directed_traps.py    # ECALL, EBREAK, MRET, interrupt tests
│   ├── test_compressed.py # C extension compressed instruction tests
│   ├── test_state.py      # Test state management (pipeline tracking)
│   ├── cpu_model.py       # CPU software reference model
│   ├── instruction_generator.py  # Random instruction generation
│   ├── test_real_program.py  # Integration tests with real programs
│   └── test_helpers.py    # Test infrastructure helpers
├── models/                # Reference models for verification
│   ├── alu_model.py       # ALU operations reference model
│   ├── branch_model.py    # Branch decision model
│   └── memory_model.py    # Memory subsystem model
├── encoders/              # RISC-V instruction encoding
│   ├── instruction_encode.py  # Binary instruction encoders
│   └── op_tables.py       # Instruction mapping tables
├── monitors/              # Runtime verification monitors
│   └── monitors.py        # Register, PC, and memory monitors
└── utils/                 # Utility functions
    ├── riscv_utils.py     # RISC-V data type utilities
    ├── memory_utils.py    # Memory alignment and address helpers
    ├── instruction_logger.py  # Structured logging
    └── validation.py      # Enhanced assertion framework
```

## Key Components

### Test Infrastructure (`/cocotb_tests`)

#### Main CPU Test (`test_cpu.py`)
The primary test orchestration that:
- Generates constrained-random instruction sequences
- Coordinates between instruction generation, modeling, and DUT driving
- Manages expected value queues for verification monitors
- Handles pipeline effects (stalls, flushes, branch mispredictions)

Key class:
- `TestConfig`: Dataclass for test configuration (passed explicitly, not global state)

#### Test State (`test_state.py`)
Manages CPU state tracking across pipeline stages:
- `TestState`: Maintains register file state, program counter history, and expected value queues
- Tracks branch taken/not-taken for pipeline flush handling
- Provides helper methods for state updates and queue management

#### CPU Model (`cpu_model.py`)
Software reference model that computes expected behavior:
- `model_instruction_execution()`: Models complete instruction execution
- `_compute_writeback_value()`: Calculates register writeback values
- `_compute_expected_program_counter()`: Determines next PC
- `model_memory_write()`: Models store operations with byte masks

#### Instruction Generator (`instruction_generator.py`)
Random instruction generation with constraints:
- Generates valid RISC-V instruction parameters
- Enforces alignment requirements (halfword, word)
- Encodes instructions into 32-bit binary format
- Supports optional address constraints to allocated memory

Key types:
- `InstructionParams`: NamedTuple with named fields for readable instruction handling

#### Integration Test (`test_real_program.py`)
- Runs actual compiled programs (Hello World, CoreMark)
- Tests system-level functionality
- Validates long-running software execution

#### Test Helpers (`test_helpers.py`)
- `DUTInterface`: Clean abstraction for DUT signal access with configurable paths
- `TestStatistics`: Comprehensive test metrics and coverage tracking

### Reference Models (`/models`)

#### ALU Model (`alu_model.py`)
Implements all arithmetic and logical operations:
- Base operations: ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU
- M-extension: MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU
- A-extension: LR.W, SC.W, AMOSWAP.W, AMOADD.W, AMOXOR.W, AMOAND.W, AMOOR.W, AMOMIN.W, AMOMAX.W, AMOMINU.W, AMOMAXU.W
- Load operations: LW, LH, LHU, LB, LBU
- B extension (Zba): SH1ADD, SH2ADD, SH3ADD
- B extension (Zbb): ANDN, ORN, XNOR, CLZ, CTZ, CPOP, MIN, MINU, MAX, MAXU, ROL, ROR, RORI, SEXT.B, SEXT.H, ORC.B, REV8
- B extension (Zbs): BSET, BCLR, BINV, BEXT (and immediate variants)
- Zicond extension: CZERO.EQZ, CZERO.NEZ
- Zbkb extension: PACK, PACKH, BREV8, ZIP, UNZIP
- Decorators for automatic result masking and shift limiting

#### Branch Model (`branch_model.py`)
Models branch decision logic for:
- BEQ, BNE, BLT, BGE, BLTU, BGEU
- Proper signed/unsigned comparison handling

#### Memory Model (`memory_model.py`)
Simulates data memory interface:
- Byte-addressable memory with configurable address width
- Support for byte, halfword, and word accesses
- Store byte-enable generation
- Synchronized with DUT memory via driver/monitor coroutine

### Instruction Encoding (`/encoders`)

#### Instruction Encoders (`instruction_encode.py`)
Provides binary encoding for all RISC-V instruction formats:
- R-type (register-register operations)
- I-type (immediate operations, loads)
- S-type (stores)
- B-type (branches)
- J-type (jumps)

#### Operation Tables (`op_tables.py`)
Maps instruction mnemonics to encoder/evaluator pairs:
- Binary encoders for instruction generation
- Evaluation functions for result modeling
- Comprehensive coverage of all supported extensions

### Monitors (`/monitors`)

Real-time verification monitors that continuously check (`monitors.py`):
- **Register File Monitor**: Validates all register writes against expected values
- **Program Counter Monitor**: Verifies control flow correctness
- **Memory Interface Monitor**: Checks load/store operations (integrated in memory_model.py)

## Test Execution

### Test Configuration

`TestConfig` is a dataclass with the following parameters:

| Parameter                      | Default | Description                                        |
|--------------------------------|---------|----------------------------------------------------|
| `num_loops`                    | 16000   | Number of random instructions to generate          |
| `min_coverage_count`           | 80      | Minimum executions required per instruction type   |
| `memory_init_size`             | 0x2000  | Size of initialized memory region (8KB)            |
| `clock_period_ns`              | 3       | Clock period in nanoseconds                        |
| `reset_cycles`                 | 3       | Number of clock cycles to hold reset               |
| `use_structured_logging`       | False   | Enable rich formatted debug output                 |
| `constrain_addresses_to_memory`| False   | Limit generated addresses to allocated space       |
| `force_one_address`            | False   | Use rs1=0 and imm=0 to stress memory hazards       |

### Enabling Advanced Features

To customize test behavior, pass a `TestConfig` instance to the test:

```python
from cocotb_tests.test_cpu import TestConfig, test_random_riscv_regression_main

# Enable structured logging for debugging
config = TestConfig(use_structured_logging=True)
await test_random_riscv_regression_main(dut, config=config)

# Constrain addresses and run fewer iterations
config = TestConfig(
    num_loops=1000,
    constrain_addresses_to_memory=True,
)
await test_random_riscv_regression_main(dut, config=config)
```

Structured logging output example:
```
[Cycle   123] add    PC: 0x00000310 → 0x00000314 x5 ← 0x00001234 (x3, x4)
[Cycle   124] lw     PC: 0x00000314 → 0x00000318 x6 ← 0x87654321 (x1, x2) imm=16 @0x00001010
[Cycle   125] beq    PC: 0x00000318 → 0x0000031c (x5, x6) imm=8 [NOT-TAKEN]
```

### Running Tests

Run the default random instruction test:
```bash
./tests/test_run_cocotb.py cpu
```

Run with forced single address (stress memory hazards):
```bash
TESTCASE=test_random_riscv_regression_force_one_address ./tests/test_run_cocotb.py cpu
```

Run integration tests with real programs:
```bash
./tests/test_run_cocotb.py hello_world
```

Run directed test for LR.W/SC.W atomic instructions:
```bash
TESTCASE=test_directed_lr_sc ./tests/test_run_cocotb.py cpu
```

Run directed test for trap handling (ECALL, EBREAK, MRET):
```bash
TESTCASE=test_directed_trap_handling ./tests/test_run_cocotb.py cpu
```

### Customizing for Different DUT Implementations

If your DUT has a different signal hierarchy, configure signal paths:
```python
from config import DUTSignalPaths

custom_paths = DUTSignalPaths(
    regfile_ram_rs1_path="my_cpu.registers.rs1_port.data",
    regfile_ram_rs2_path="my_cpu.registers.rs2_port.data",
)

dut_if = DUTInterface(dut, signal_paths=custom_paths)
```

## Architecture & Design Principles

### Modular Design
- **Separation of Concerns**: Each module has a single, clear responsibility
- **Instruction Generation**: Isolated in dedicated module
- **CPU Modeling**: Software reference model in separate module
- **Test Orchestration**: High-level test flow coordination only

### Configurability
- **Centralized Configuration**: All constants in `config.py`
- **DUT Signal Paths**: Configurable via `DUTSignalPaths` for different implementations
- **Optional Features**: Address constraints, structured logging
- **Test Parameters**: Easy adjustment of loops, coverage, memory size

### Type Safety & Error Handling
- **Type Aliases**: Clear, semantic types (`Address`, `RegisterIndex`, etc.)
- **Custom Exceptions**: Rich context for debugging failures
- **Hardware Assertions**: RISC-V-specific validations

### Extensibility
- **Adding Instructions**: Update `op_tables.py` with encoder/evaluator pairs
- **New Monitors**: Simple coroutine interface
- **Different DUTs**: Configure signal paths without code changes
- **Plugin Architecture**: Encoders and models are decoupled
