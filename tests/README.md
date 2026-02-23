# Frost Test Infrastructure

This directory contains the test infrastructure for the Frost RISC-V CPU project, including RTL simulations and synthesis verification.

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                Test Infrastructure                                              │
├─────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                 │
│  ┌────────────────┐ ┌────────────────┐ ┌────────────────┐ ┌────────────────┐ ┌────────────────┐ │
│  │test_run_cocotb │ │test_arch_comp- │ │test_riscv_     │ │test_riscv_     │ │test_run_yosys  │ │
│  │          .py   │ │  liance.py     │ │    tests.py    │ │  torture.py    │ │          .py   │ │
│  │ RTL Simulation │ │ Arch Compli-   │ │ ISA Pipeline   │ │ Random Instr   │ │ Synthesis      │ │
│  │ • CPU unit     │ │   ance         │ │ • riscv-tests  │ │ • 20 random    │ │ • Yosys        │ │
│  │   tests        │ │ • riscv-arch-  │ │ • 126 tests    │ │   tests        │ │   synthesis    │ │
│  │ • Real C progs │ │   test         │ │ • 11 suites    │ │ • RV32IMAFDC   │ │ • No vendor    │ │
│  │ • Verification │ │ • 400+ tests   │ │ • Benchmarks   │ │ • Spike refs   │ │   IPs          │ │
│  └───────┬────────┘ └───────┬────────┘ └───────┬────────┘ └───────┬────────┘ └───────┬────────┘ │
│          │                  │                  │                  │                  │          │
│          v                  v                  v                  v                  v          │
│  ┌──────────────────────────────────────────────────────────────────────┐  ┌────────────────┐   │
│  │                            Simulator                                 │  │     Yosys      │   │
│  │                       Icarus/Verilator                               │  │ (open-source)  │   │
│  └──────────────────────────────────────────────────────────────────────┘  └────────────────┘   │
│                                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
```

## Test Files

### `test_run_cocotb.py`

Primary test runner for RTL simulations using Cocotb. Supports both standalone execution and pytest integration.

**Target Discovery (single source of truth):**

The canonical test list lives in `TEST_REGISTRY` inside `test_run_cocotb.py`, not this README.

```bash
./test_run_cocotb.py --list-tests
./test_run_cocotb.py --help
```

**Standalone Usage:**

Applications are compiled automatically before simulation—no manual build step required.

```bash
# Basic usage
./test_run_cocotb.py cpu                           # Run CPU verification test
./test_run_cocotb.py hello_world                   # Run Hello World program
./test_run_cocotb.py isa_test                      # Run ISA compliance tests
./test_run_cocotb.py freertos_demo                 # Run FreeRTOS demo

# Specify simulator
./test_run_cocotb.py cpu --sim=verilator           # Use Verilator
./test_run_cocotb.py cpu --sim=icarus              # Use Icarus Verilog
./test_run_cocotb.py cpu --sim=verilator           # Use Verilator

# Reproducibility options
./test_run_cocotb.py cpu --random-seed=12345       # Use specific seed
./test_run_cocotb.py cpu --testcase=test_random    # Run specific test function

# Seed sweep (parallel random seed testing)
./test_run_cocotb.py cpu --sim=verilator --seed-sweep 10          # Run 10 seeds in parallel
./test_run_cocotb.py cpu --seed-sweep 20 --max-workers 4          # Limit parallelism
./test_run_cocotb.py cpu --seed-sweep 10 --testcase test_random   # Sweep specific test
```

**Seed Sweep Mode:**

The `--seed-sweep N` flag runs N simulations in parallel, each with a different random seed. This is useful for finding intermittent failures in randomized tests. After all runs complete, a summary report shows which seeds passed and which failed, along with commands to reproduce any failures:

```
============================================================
SEED SWEEP REPORT
============================================================
Total runs: 10
Passed: 9
Failed: 1

Passing seeds: [123456789, 234567890, ...]
Failing seeds: [987654321]

To reproduce a failure, run:
  ./test_run_cocotb.py cpu --sim=verilator --random-seed=987654321
============================================================
```

Options:
- `--seed-sweep N` - Number of random seeds to test
- `--max-workers W` - Limit parallel workers (default: min(N, cpu_count))
- Can be combined with `--testcase` to sweep a specific test function

**Pytest Usage:**

```bash
pytest test_run_cocotb.py                          # Run all cocotb tests (both simulators)
pytest test_run_cocotb.py -k verilator             # Run with Verilator only
pytest test_run_cocotb.py -k hello_world           # Run specific test (both simulators)
pytest test_run_cocotb.py -k "verilator and hello_world"  # Specific test, one simulator
pytest test_run_cocotb.py -s                       # Show live output
```

### `test_arch_compliance.py`

Runs the official [riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test) compliance suite on Frost. Each test compiles an assembly test case, runs it in Verilator simulation, extracts the signature from UART output, and compares it against Spike-generated golden references.

**Supported extensions:** I, M, A, F, D, C, B, K, Zicond, Zifencei (400+ tests total)

**Standalone Usage:**

```bash
# Run all supported extensions
./test_arch_compliance.py --sim verilator --all

# Run specific extensions
./test_arch_compliance.py --sim verilator --extensions I M A

# Run a single test
./test_arch_compliance.py --sim verilator --test rv32i_m/I/src/add-01.S

# Parallel execution
./test_arch_compliance.py --sim verilator --all --parallel 4

# Include tests too large for simulation (hardware validation)
./test_arch_compliance.py --sim verilator --all --no-sim-filter
```

**Pytest Usage:**

```bash
pytest test_arch_compliance.py -v --sim verilator -m slow
```

**Notes:**
- Verilator only (too slow for Icarus, skips automatically for non-Verilator sims)
- Tests with >5000 test cases are filtered by default (12 tests with 7K-14K cases that take >30 min each). Use `--no-sim-filter` for hardware validation runs
- In CI, runs as 10 parallel jobs (one per extension) via GitHub Actions matrix strategy
- Simulation uses 2MB memory override (`-GMEM_SIZE_BYTES=2097152`) to fit large test data sections

### `test_riscv_tests.py`

Runs [riscv-tests](https://github.com/riscv-software-src/riscv-tests) ISA tests on Frost. Unlike arch_test (signature-based), these are self-checking: each test prints `<<PASS>>` or `<<FAIL>>` via UART. The tests exercise forwarding, bypassing, and pipeline hazards that arch_test's single-instruction focus doesn't cover.

**Supported suites:** rv32ui, rv32um, rv32ua, rv32uf, rv32ud, rv32uc, rv32mi, rv32uzba, rv32uzbb, rv32uzbs, rv32uzbkb (126 tests total)

**Standalone Usage:**

```bash
# Run all suites
./test_riscv_tests.py --sim verilator --all

# Run specific suites
./test_riscv_tests.py --sim verilator --suites rv32ui rv32um rv32uf

# Run a single test
./test_riscv_tests.py --sim verilator --test rv32ui/add

# Parallel execution
./test_riscv_tests.py --sim verilator --all --parallel 4

# List available tests
./test_riscv_tests.py --list
```

**Pytest Usage:**

```bash
pytest test_riscv_tests.py -v --sim verilator -m slow
```

**Notes:**
- Verilator only (skips automatically for non-Verilator sims)
- A small number of tests are skipped due to architectural incompatibility (Harvard architecture, M-mode only, misaligned access trapping). See `ISA_SKIP_TESTS` in the script for details.

### `test_riscv_torture.py`

Runs random instruction torture tests on Frost. A Python-based generator creates random RV32IMAFDC instruction sequences (ALU, multiply/divide, memory, branch, FP, and AMO operations), runs them on Spike to generate golden register signatures, then compares Frost simulation output against those references.

**Standalone Usage:**

```bash
# Run all torture tests
./test_riscv_torture.py --sim verilator --all

# Run a single test
./test_riscv_torture.py --sim verilator --test test_001

# List available tests and reference status
./test_riscv_torture.py --sim verilator --list
```

**Generating Tests:**

Tests and Spike references are pre-generated and checked in. To regenerate:

```bash
cd sw/apps/riscv_torture
./generate_tests.py --generate --count 20 --seed 42
```

**Pytest Usage:**

```bash
pytest test_riscv_torture.py -v --sim verilator -m slow
```

**Notes:**
- Verilator only (skips automatically for non-Verilator sims)
- Requires Spike (`riscv-isa-sim`) for reference generation only, not for running tests
- FP register signatures are compared exactly against Spike references; integer registers are verified for correct word count only (AMO address computation introduces layout-dependent values)

### `test_run_yosys.py`

Runs Yosys synthesis to verify the design can be synthesized without errors. Uses open-source tools only (no Xilinx IP cores).

**Standalone Usage:**

```bash
./test_run_yosys.py                                # Run synthesis
./test_run_yosys.py --verbose                      # Show full Yosys output
```

**Pytest Usage:**

```bash
pytest test_run_yosys.py                           # Run synthesis test
```

## Configuration Files

| File                       | Purpose                                   |
|----------------------------|-------------------------------------------|
| `conftest.py`              | Pytest configuration and fixtures         |
| `Makefile`                 | Cocotb simulation build rules             |
| `test_arch_compliance.py`  | riscv-arch-test compliance runner         |
| `test_riscv_tests.py`      | riscv-tests ISA pipeline test runner      |
| `test_riscv_torture.py`    | Random instruction torture test runner    |
| `.gitignore`               | Excludes build artifacts                  |

## Running Tests

### Run All Tests

```bash
# From this directory
pytest

# From project root
pytest tests/

# With live output
pytest -s
```

### Filter by Test Type

```bash
pytest -m cocotb                                   # Simulation tests only
pytest -m synthesis                                # Synthesis tests only
pytest -k "not slow"                               # Skip slow tests
```

### Simulator Selection

By default, pytest runs each cocotb test with both Icarus and Verilator simulators
(parametrized via `CI_SIMULATORS`). Use `-k` to filter by simulator:

```bash
pytest test_run_cocotb.py -k verilator             # Verilator only (fastest)
pytest test_run_cocotb.py -k icarus                # Icarus Verilog only
pytest test_run_cocotb.py                          # Both simulators (default)
```

You can combine `-k` with test name filters:

```bash
pytest test_run_cocotb.py -k "verilator and hello_world"  # Specific test, one simulator
pytest test_run_cocotb.py -k "verilator and not coremark" # Skip slow tests
```

For standalone execution, use `--sim` directly:

```bash
./test_run_cocotb.py cpu --sim=verilator           # Verilator
./test_run_cocotb.py cpu --sim=icarus              # Icarus Verilog
./test_run_cocotb.py cpu --sim=verilator           # Verilator
```

### Environment Variables

| Variable      | Description                      | Default    |
|---------------|----------------------------------|------------|
| `SIM`         | Simulator to use                 | `icarus`   |
| `TESTCASE`    | Specific test function to run    | (all)      |
| `RANDOM_SEED` | Random seed for reproducibility  | (random)   |
| `WAVES`       | Generate waveform file (1/0)     | `0`        |

## Test Output

### Simulation Build Artifacts

The `sim_build/` directory contains compiled simulation files:

```
sim_build/
├── Vtop                    # Verilator executable
├── Vtop*.cpp               # Generated C++ files
├── *.o                     # Object files
└── .last_toplevel          # Tracks toplevel for incremental builds
```

### Test Results

- `results.xml` - JUnit-format test results (for CI integration)
- `dump.vcd` / `dump.fst` - Waveform files (when `WAVES=1`)

## Requirements

See the [main README](../README.md#prerequisites) for validated tool versions.

### Simulators (choose one or more)

| Simulator      | Notes                       |
|----------------|-----------------------------|
| Icarus Verilog | Default, widely available   |
| Verilator      | Fastest, incremental builds |

### Other Tools

| Tool       | Purpose                  |
|------------|--------------------------|
| Python     | Test runner              |
| Cocotb     | Verification framework   |
| Yosys      | Open-source synthesis    |
| RISC-V GCC | C cross-compiler         |

## CI Integration

All tests are run automatically in CI. Tests gracefully skip if required tools are not installed.

Architecture compliance tests run as 10 parallel GitHub Actions jobs (one per extension) using a matrix strategy with `fail-fast: false`, so all extensions are tested even if one fails. These are separate from the main Cocotb test job to avoid blocking it with long-running FP tests.

### Test Markers

```python
@pytest.mark.cocotb       # RTL simulation tests
@pytest.mark.synthesis    # Synthesis tests
@pytest.mark.slow         # Long-running tests
```

## Troubleshooting

### "No module named 'cocotb'"

Install Cocotb:
```bash
pip install cocotb
```

### Verilator incremental build issues

The test runner tracks the toplevel module in `sim_build/.last_toplevel`. If you see stale build issues, clean the build:
```bash
make clean
```

### Tests timing out

Some tests (coremark, freertos_demo) run for many cycles. Use environment variable for timeouts:
```bash
COCOTB_SCHEDULER_DEBUG=1 ./test_run_cocotb.py coremark
```
