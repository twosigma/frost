# Frost RISC-V CPU verification

The Python [Cocotb](https://www.cocotb.org/) framework checks Frost RTL against
software reference models.

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

1. **Instruction generation** produces random or directed parameters.
2. **CPU model** computes expected results.
3. **Encoders** produce machine code.
4. **TestState** queues expected values.
5. **DUT** executes the instruction.
6. **Monitors** compare DUT outputs with expectations.

### Design Under Test (DUT)

The Frost CPU implements **RV64GCB** (G = IMAFD, plus C and B) with M and U privilege modes. `verif/config.py` pins `XLEN` to 64 to match `riscv_pkg`, and every Python model and encoder imports it from there. See the [root README](../README.md) for the full ISA extension table.

The DUT has:
- 32 general-purpose registers plus a separate FP register file
- Harvard architecture with separate instruction and data memory interfaces
- 2-wide in-order IF/PD/ID front-end feeding a Tomasulo OOO back-end
- 2-wide dispatch/rename, 2-lane CDB completion broadcast, and precise in-order commit through the ROB, with branch/trap recovery paths

### Verification Methodology

Verification includes:

1. **Constrained-random testing** — thousands of generated instructions
   checked against the software reference model (`test_cpu.py`)
2. **Directed testing** — targeted scenarios for traps, atomics, compressed
   instructions, and multi-cycle hazards (`test_directed_*.py`,
   `test_compressed.py`)
3. **Real-program integration** — complete compiled applications (Hello World,
   CoreMark, CoreMark-PRO) run with pass/fail detection (`test_real_program.py`)
4. **Coverage tracking** — the random regression fails if any tracked
   instruction type falls below a minimum execution count
   (`min_coverage_count`)

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
│   ├── test_directed_multicycle.py  # Back-to-back DIV/FP-DIV and load-use hazard tests
│   ├── test_state.py      # Test state management (pipeline tracking)
│   ├── cpu_model.py       # CPU software reference model
│   ├── instruction_generator.py  # Random instruction generation
│   ├── instruction_executor.py  # Execute-and-model helper (encode/model/drive)
│   ├── test_real_program.py  # Integration tests with real programs (UART-driven)
│   ├── test_helpers.py    # Test infrastructure helpers
│   ├── if_stage/          # IF-stage block tests (PC controller, aligner, RVC
│   │                      #   decompressor, branch prediction, RAS, BTB, ...)
│   ├── pd_stage/          # Predecode-stage top-level block tests
│   ├── id_stage/          # Decode-stage top-level block tests
│   ├── ex_stage/          # EX-stage block tests (branch/jump unit)
│   ├── predecode/         # Fetch provider + predecode-line block tests (L1I fetch seam)
│   ├── cache/             # Cache hierarchy + line-port arbiter block tests
│   ├── cpu_ooo/           # OOO block tests (commit, recovery, memory router,
│   │                      #   register files, perf counters, pipeline control,
│   │                      #   frontend validity tracker)
│   ├── control/           # Control tests (trap/MRET/exception + store-drain arbitration)
│   ├── debug/             # RISC-V debug module: JTAG/DTM/DM driver, the directed
│   │                      #   bench and the OpenOCD-in-the-loop (remote_bitbang) bench
│   └── tomasulo/          # Block-level cocotb tests for Tomasulo submodules
│                          #   (ROB, RAT, RS, dispatch, CDB arbiter, LQ/SQ, FU shims)
├── models/                # Reference models for verification
│   ├── alu_model.py       # ALU operations reference model
│   ├── branch_model.py    # Branch decision model
│   ├── fp_model.py        # IEEE 754 single/double-precision FP model
│   └── memory_model.py    # Memory subsystem model
├── encoders/              # RISC-V instruction encoding
│   ├── instruction_encode.py  # Binary instruction encoders
│   ├── compressed_encode.py   # RVC compressed (16-bit) encoders
│   └── op_tables.py       # Instruction mapping tables
├── monitors/              # Runtime verification monitors
│   └── monitors.py        # Register, PC, and memory monitors
└── utils/                 # Utility functions
    ├── riscv_utils.py     # RISC-V data type utilities
    ├── memory_utils.py    # Memory alignment and address helpers
    ├── instruction_logger.py  # Structured logging
    └── validation.py      # Enhanced assertion framework
```

## Components

### Test Infrastructure (`/cocotb_tests`)

#### Main CPU test (`test_cpu.py`)

This module:
- Generates constrained-random instruction sequences
- Coordinates between instruction generation, modeling, and DUT driving
- Manages expected value queues for verification monitors
- Handles pipeline effects (stalls, flushes, branch mispredictions)

Key entry point:
- `run_random_regression()`: Shared regression driver wrapped by the `@cocotb.test()` functions (`test_random_riscv_regression`, `test_random_riscv_regression_force_one_address`, and the FP variants)

`TestConfig`, defined in `test_common.py`, passes configuration explicitly.

#### Test state (`test_state.py`)

Tracks CPU state:
- `TestState`: Maintains register file state, program counter history, and expected value queues
- Tracks branch taken/not-taken for pipeline flush handling
- Provides helper methods for state updates and queue management

#### CPU model (`cpu_model.py`)

Computes expected behavior:
- `model_instruction_execution()`: Models complete instruction execution
- `_compute_writeback_value()`: Calculates register writeback values
- `_compute_expected_program_counter()`: Determines next PC
- `model_memory_write()`: Models store operations with byte masks

#### Instruction generator (`instruction_generator.py`)

Generates constrained-random instructions:
- Generates valid RISC-V instruction parameters
- Enforces alignment requirements (halfword, word)
- Encodes instructions into 32-bit binary format
- Supports optional address constraints to allocated memory

`InstructionParams` is a named tuple for instruction fields.

#### Integration test (`test_real_program.py`)
- Runs actual compiled programs (Hello World, CoreMark, and all nine
  CoreMark-PRO workload sims `coremark_pro_{core,cjpeg,linear_alg,loops,
  nnet,parser,radix2,sha,zip}`)
- Tests system-level functionality, including the cached memory tier
  (CoreMark-PRO heaps live in the 1 GiB DDR-backed region behind the
  L1/L2 cache hierarchy; the behavioral DDR model loads each program's
  `sw_ddr.mem` image, mirroring the hardware JTAG DDR loader)
- Validates long-running software execution

#### Test helpers (`test_helpers.py`)
- `DUTInterface`: DUT signal access behind configurable hierarchy paths
- `TestStatistics`: Test metrics and coverage tracking

### Reference Models (`/models`)

#### ALU Model (`alu_model.py`)
Implements all arithmetic and logical operations:
- Base operations: ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU
- M-extension: MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU
- A-extension (AMO evaluators): AMOSWAP.W, AMOADD.W, AMOXOR.W, AMOAND.W, AMOOR.W, AMOMIN.W, AMOMAX.W, AMOMINU.W, AMOMAXU.W
  (no LR.W/SC.W evaluator: LR.W reuses `lw` for the loaded value, and the
  reservation / SC.W outcome is modelled by `TestState`)
- Load operations: LW, LD, LH, LHU, LB, LBU
- B extension (Zba): SH1ADD, SH2ADD, SH3ADD
- B extension (Zbb): ANDN, ORN, XNOR, CLZ, CTZ, CPOP, MIN, MINU, MAX, MAXU, ROL, ROR, RORI, SEXT.B, SEXT.H, ZEXT.H, ORC.B, REV8
- B extension (Zbs): BSET, BCLR, BINV, BEXT (and immediate variants)
- Zicond extension: CZERO.EQZ, CZERO.NEZ
- Zbkb extension: PACK, PACKH, BREV8 (RV32-only ZIP/UNZIP are unsupported)
- RV64 word forms: ADDW, SUBW, SLLW, SRLW, SRAW, MULW, DIVW, DIVUW, REMW, REMUW, ADD.UW, SH1ADD.UW, SH2ADD.UW, SH3ADD.UW, SLLI.UW, ROLW, RORW, CLZW, CTZW, CPOPW, PACKW
- Decorators for automatic result masking and shift limiting

#### Branch Model (`branch_model.py`)
Models branch decision logic for:
- BEQ, BNE, BLT, BGE, BLTU, BGEU
- Proper signed/unsigned comparison handling

#### Memory Model (`memory_model.py`)
Simulates data memory interface:
- Byte-addressable memory with configurable address width
- Support for byte, halfword, word, and doubleword accesses (the DUT's simulation data BRAM stores aligned 64-bit rows)
- Store byte-enable generation
- `driver_and_monitor` coroutine checks DUT store traffic (despite the name it
  drives nothing; the memory image itself is written by `cpu_model.py`)

### Instruction Encoding (`/encoders`)

#### Instruction Encoders (`instruction_encode.py`)
Encodes these RISC-V instruction formats:
- R-type (register-register operations)
- I-type (immediate operations, loads)
- S-type (stores)
- B-type (branches)
- J-type (jumps)

#### Operation Tables (`op_tables.py`)
Maps instruction mnemonics to encoder/evaluator pairs:
- Binary encoders for instruction generation
- Evaluation functions for result modeling
- All supported extensions

### Monitors (`/monitors`)

`monitors.py` checks DUT outputs throughout simulation:
- **Register File Monitor**: Validates all register writes against expected values
- **Program Counter Monitor**: Verifies control flow correctness
- **Memory Interface Monitor** (`memory_model.driver_and_monitor`): Checks store
  traffic only — whenever the byte write-enable mask is non-zero it matches the
  DUT's address and data against the expected queues, and raises on an
  unexpected write. Load results are checked indirectly via the register file
  monitor.

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
| `compressed_ratio`             | 0.0     | Ratio of compressed (C extension) ALU instructions |

### Configuring a test

Pass a `TestConfig` instance to the test:

```python
from cocotb_tests.test_common import TestConfig
from cocotb_tests.test_cpu import run_random_regression

# Enable structured logging for debugging
config = TestConfig(use_structured_logging=True)
await run_random_regression(dut, config=config)

# Constrain addresses and run fewer iterations
config = TestConfig(
    num_loops=1000,
    constrain_addresses_to_memory=True,
)
await run_random_regression(dut, config=config)
```

Structured logging output example:
```
[Cycle   123] add    PC: 0x00000310 → 0x00000314 x5 ← 0x00001234 (x3, x4)
[Cycle   124] lw     PC: 0x00000314 → 0x00000318 x6 ← 0x87654321 (x1, x2) imm=16 @0x00001010
[Cycle   125] beq    PC: 0x00000318 → 0x0000031c (x5, x6) imm=8 [NOT-TAKEN]
```

### Running Tests

Run these commands from the repository root through `./scripts/frost.py`.
The wrapper uses the pinned CI image as the invoking user's UID/GID and always
cleans `tests/` before a cocotb run. Registry-driven real-program and unit tests
use `./scripts/frost.py cocotb <name>`; pass `--list-tests` for the canonical
target list (the single source of truth is `TEST_REGISTRY` in
`tests/test_run_cocotb.py`).

The random and directed CPU tests use the `cpu_tb` testbench and
`test_run_cocotb.py` registry targets: `directed_traps`
(pytest-collected, in CI) plus `directed_atomics`, `directed_multicycle`,
`compressed`, and `cpu_random` (registered CLI-only). `directed_atomics` and
`compressed` have been ported to the maintained `DUTInterface` commit-event
helpers and pass; they stay CLI-only pending a decision to add them to CI.
`directed_multicycle` and `cpu_random` still assume in-order fixed latencies
and fail on the OOO core until ported; their ISA coverage is meanwhile gated
by the riscv-tests / arch-compliance / real-program suites. Bare
`make` in `tests/` builds the `Makefile` default (`TOPLEVEL=cpu_tb`,
`COCOTB_TEST_MODULES=cocotb_tests.test_cpu`), which loads only the unported
`cpu_random` module. Prefer registry targets:

Run a cpu_tb suite via the registry:
```bash
# Trap handling (ECALL, EBREAK, MRET) -- ported, runs in CI
./scripts/frost.py cocotb directed_traps
# LR.W/SC.W atomic instructions -- ported, passes, CLI-only (not in CI)
./scripts/frost.py cocotb directed_atomics
# Back-to-back multi-cycle ops -- NOT yet ported to OOO, expected to fail
./scripts/frost.py cocotb directed_multicycle
```

Run a single test function with `--testcase` (sets cocotb's
`COCOTB_TEST_FILTER` to an exact match):
```bash
./scripts/frost.py cocotb directed_traps --testcase test_directed_trap_handling
./scripts/frost.py cocotb directed_atomics --testcase test_directed_lr_sc
```

Run integration tests with real programs (registry targets):
```bash
./scripts/frost.py cocotb hello_world
./scripts/frost.py cocotb hello_world --testcase test_real_program
```

### Memory tier (BRAM vs cached DDR)

Real-program tests run in two memory tiers. The default `bram` tier loads the
whole program into low BRAM. Setting `FROST_COCOTB_MEM_CONFIG=ddr` relinks the
program into the cached DDR region (`0x8000_0000`, behind the L1/L2 cache
hierarchy) so it executes through the L1I fetch path and D-side cache; the
behavioral DDR model loads the program's `sw_ddr.mem` image. Both tiers run as
separate CI jobs (the ddr job adds `-e FROST_COCOTB_MEM_CONFIG=ddr`).

```bash
FROST_COCOTB_MEM_CONFIG=ddr ./scripts/frost.py cocotb coremark
```

In the ddr tier the behavioral DDR persists across reset and `.data` is loaded
in place, so the runner forces `COCOTB_NUM_RUNS=1` (the bram tier keeps its
two-run default to verify reset robustness). `*_fetch_fuzz` and `ddr_*` programs
self-skip in the ddr tier.

`test_real_program.py` honors two env knobs directly: `COCOTB_NUM_RUNS`
(reset-and-rerun count, default 2) and `COCOTB_MAX_CYCLES` (timeout budget;
CoreMark-style benchmarks, linux_boot, and amo_irq_torture have larger
per-app defaults with their own env overrides).

### Using another DUT hierarchy

For a different signal hierarchy, configure the paths:
```python
from config import DUTSignalPaths

custom_paths = DUTSignalPaths(
    regfile_ram_rs1_path="my_cpu.registers.rs1_port.data",
    regfile_ram_rs2_path="my_cpu.registers.rs2_port.data",
)

dut_if = DUTInterface(dut, signal_paths=custom_paths)
```

## Extending the Framework

- **Adding an instruction**: register an encoder/evaluator pair in
  `encoders/op_tables.py`. Instructions in existing operation families are
  picked up from the table; a new format or operation family also needs
  generator and reference-model support.
- **Adding a monitor**: monitors are plain coroutines started by the test —
  see `monitors/monitors.py` for existing examples.
- **Adapting to a different DUT hierarchy**: override signal paths through
  `DUTSignalPaths` (see above) instead of editing test code.
- **Configuration**: shared constants live in `config.py`, per-run behavior in
  `TestConfig`. Semantic type aliases (`Address`, `RegisterIndex`, …) are
  defined in `verification_types.py`, the custom exception hierarchy in
  `exceptions.py`, and RISC-V-specific validation helpers
  (`HardwareAssertions`) in `utils/validation.py`.
