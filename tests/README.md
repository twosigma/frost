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
│  │                                Verilator                             │  │ (open-source)  │   │
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
./test_run_cocotb.py tomasulo_test                 # Run CPU correctness test
./test_run_cocotb.py hello_world                   # Run Hello World program
./test_run_cocotb.py isa_test                      # Run ISA compliance tests
./test_run_cocotb.py freertos_demo                 # Run FreeRTOS demo
./test_run_cocotb.py coremark_pro_core             # CoreMark-PRO workload system sim
                                                   # (also: _cjpeg, _linear_alg, _nnet,
                                                   #  _parser, _sha; long-running)

# Reproducibility options
./test_run_cocotb.py cdb_arbiter --random-seed=12345                       # Use specific seed
./test_run_cocotb.py cdb_arbiter --testcase=test_random_multi_fu_stress    # Run specific test function

# Seed sweep (parallel random seed testing)
./test_run_cocotb.py cdb_arbiter --seed-sweep 10          # Run 10 seeds in parallel
./test_run_cocotb.py cdb_arbiter --seed-sweep 20 --max-workers 4          # Limit parallelism
./test_run_cocotb.py cdb_arbiter --seed-sweep 10 --testcase test_random_multi_fu_stress   # Sweep specific test
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
  ./test_run_cocotb.py cdb_arbiter --random-seed=987654321
============================================================
```

Options:
- `--seed-sweep N` - Number of random seeds to test
- `--max-workers W` - Limit parallel workers (default: min(N, cpu_count))
- Can be combined with `--testcase` to sweep a specific test function

**Pytest Usage:**

```bash
pytest test_run_cocotb.py                          # Run all cocotb tests with Verilator
pytest test_run_cocotb.py -k hello_world           # Run a specific test
pytest test_run_cocotb.py -k unit                  # Run Tomasulo unit tests
pytest test_run_cocotb.py -s                       # Show live output
```

**Memory tier for real programs (`FROST_COCOTB_MEM_CONFIG`):**

By default real-program tests are linked whole-program into low BRAM (`bram`). Setting `FROST_COCOTB_MEM_CONFIG=ddr` relinks every app into the cached DDR region, exercising the L1I fetch path and the D-side cached tier:

```bash
FROST_COCOTB_MEM_CONFIG=ddr ./test_run_cocotb.py hello_world
FROST_COCOTB_MEM_CONFIG=ddr pytest test_run_cocotb.py -k test_real_program
```

Tests in `DDR_TIER_EXCLUDE` self-skip in the `ddr` tier: the `*_fetch_fuzz` fetch fuzzers, and the already-DDR-focused `ddr_*` programs (`ddr_test`, `ddr_exec_test`, `ddr_smc_test`, `ddr_heap_test`) whose fixed-address writes a whole-program relocation would clobber. Unit benches are tier-independent and run only once (in the `bram` job).

### `test_arch_compliance.py`

Runs the official [riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test) compliance suite on Frost. Each test compiles an assembly test case, runs it in Verilator simulation, extracts the signature from UART output, and compares it against Spike-generated golden references.

**Supported extensions:** I, M, A, F, D, C, B, K, Zicond, Zifencei, privilege, F_Zcf, D_Zcd, hints (400+ tests total)

**Standalone Usage:**

```bash
# Run all supported extensions
./test_arch_compliance.py --all

# Run specific extensions
./test_arch_compliance.py --extensions I M A

# Run a single test
./test_arch_compliance.py --test rv32i_m/I/src/add-01.S

# Parallel execution
./test_arch_compliance.py --all --parallel 4

# Include tests too large for simulation (hardware validation)
./test_arch_compliance.py --all --no-sim-filter

# Select the memory tier the test runs from (default: ddr)
./test_arch_compliance.py --extensions I --mem-config bram     # code+data+signature in low BRAM
./test_arch_compliance.py --extensions Zifencei --mem-config ddr  # whole test in cached DDR
./test_arch_compliance.py --extensions I --mem-config icache   # code in DDR, data+signature in BRAM
```

**Memory tiers (`--mem-config`):** Each test selects where its code vs data/signature lives, so a failure is attributable to one path. The Makefile knob `MEM_CONFIG` picks the linker script + crt0 boot stub accordingly:
- `bram` - code + data + signature all in low BRAM (pure ISA conformance).
- `icache` - code in DDR (L1I fetch path under test), data + signature in low BRAM (isolates instruction fetch from the D-side cached tier). Diagnostic only; not a CI job.
- `ddr` - code + data + signature in DDR; also exercises the D-side cached tier on every load/store. **This is the default** (`DEFAULT_MEM_CONFIG`).

The pytest entry point honors `FROST_ARCH_MEM_CONFIG` to override the default.

**Pytest Usage:**

```bash
pytest test_arch_compliance.py -v -m slow
```

**Notes:**
- Verilator only
- Tests with >5000 test cases are filtered by default (the 12 slow F/D fused tests, 7K-14K cases each, that take a long time under Verilator). Use `--no-sim-filter` for hardware validation runs
- In CI, runs as a GitHub Actions matrix of extension x memory tier (`[bram, ddr]`), with `fail-fast: false`. Zifencei (fence.i / self-modifying code) is excluded from the `bram` tier — the low-BRAM Harvard split has separate instruction and data memories, so a store reaches only the data BRAM; fence.i's writeback + invalidate apply to the cached DDR tier alone, making it a DDR-tier-only compliance test. Each slow F/D test excluded by the size filter is added back as its own `ddr`-tier job via `test_path`
- In the `bram`/`icache` tiers, a test whose `.text`/`.data` exceeds the 256 KiB low BRAM (96 KiB instruction + 160 KiB data) is reported SKIP rather than FAIL — the `ddr` tier still exercises it
- Low BRAM is sized to match hardware (`-GMEM_SIZE_BYTES=262144`, 256 KiB); the cached DDR region is provided by the behavioral DDR model and preloaded from `sw_ddr.mem`

### `test_riscv_tests.py`

Runs [riscv-tests](https://github.com/riscv-software-src/riscv-tests) ISA tests on Frost. Unlike arch_test (signature-based), these are self-checking: each test prints `<<PASS>>` or `<<FAIL>>` via UART. The tests exercise multi-instruction dependencies, traps, atomics, FP behavior, and 2-wide dispatch/OOO commit cases that arch_test's single-instruction focus does not cover.

**Supported suites:** rv32ui, rv32um, rv32ua, rv32uf, rv32ud, rv32uc, rv32mi, rv32uzba, rv32uzbb, rv32uzbs, rv32uzbkb (126 tests total)

**Standalone Usage:**

```bash
# Run all suites
./test_riscv_tests.py --all

# Run specific suites
./test_riscv_tests.py --suites rv32ui rv32um rv32uf

# Run a single test
./test_riscv_tests.py --test rv32ui/add

# Parallel execution
./test_riscv_tests.py --all --parallel 4

# Select the memory tier (default: bram)
./test_riscv_tests.py --all --mem-config ddr     # run every test from the cached DDR region

# List available tests
./test_riscv_tests.py --list
```

**Memory tiers (`--mem-config`):** `bram` (default) keeps code + data in low BRAM (pure ISA path); `ddr` runs the test from the cached DDR region (exercises the L1I fetch path and the D-side cached tier). The Makefile knob `MEM_CONFIG` selects the linker script (+ ROM boot stub for `ddr`).

**Pytest Usage:**

```bash
pytest test_riscv_tests.py -v -m slow
```

**Notes:**
- Verilator only (skips automatically for non-Verilator sims)
- A small number of tests are skipped in every tier due to architectural incompatibility (M-mode only, misaligned access trapping, RV64-only encodings). See `ISA_SKIP_TESTS` in the script for details.
- `rv32ui/fence_i` is skipped in the `bram` tier only (`ISA_SKIP_TESTS_BRAM`): self-modifying code is meaningful only against the cached DDR L1I, so it runs in `ddr` alone.
- In CI, runs as a suite x memory tier (`[bram, ddr]`) matrix; benchmarks run as a benchmark x memory tier matrix.

### `test_riscv_torture.py`

Runs random instruction torture tests on Frost. A Python-based generator creates random RV32IMAFDC instruction sequences (ALU, multiply/divide, memory, branch, FP, and AMO operations), runs them on Spike to generate golden register signatures, then compares Frost simulation output against those references.

**Standalone Usage:**

```bash
# Run all torture tests
./test_riscv_torture.py --all

# Run a single test
./test_riscv_torture.py --test test_001

# Select the memory tier (default: bram)
./test_riscv_torture.py --all --mem-config ddr     # run from the cached DDR region

# List available tests and reference status
./test_riscv_torture.py --list
```

**Memory tiers (`--mem-config`):** `bram` (default) runs from low BRAM (pure ISA path); `ddr` runs from the cached DDR region (exercises the L1I fetch path and the D-side cached tier). In CI, runs as a memory tier (`[bram, ddr]`) matrix.

**Generating Tests:**

Tests and Spike references are pre-generated and checked in. To regenerate:

```bash
cd sw/apps/riscv_torture
./generate_tests.py --generate --count 20 --seed 42
```

**Pytest Usage:**

```bash
pytest test_riscv_torture.py -v -m slow
```

**Notes:**
- Verilator only (skips automatically for non-Verilator sims)
- Requires Spike (`riscv-isa-sim`) for reference generation only, not for running tests
- FP register signatures are compared exactly against Spike references; integer registers are verified for correct word count only (AMO address computation introduces layout-dependent values)

### `test_run_yosys.py`

Runs Yosys synthesis checks. The generic target intentionally stops after Yosys
coarse synthesis, which verifies vendor-agnostic elaboration, procedural
lowering, memory inference, and structural checks without defining Xilinx
primitives. It does not prove that the full CPU maps all the way to ASIC gates
or a non-Xilinx FPGA fabric. The Xilinx targets still run full Yosys synthesis
for 7-series, UltraScale, and UltraScale+.

**Standalone Usage:**

```bash
./test_run_yosys.py                                # Run all default targets (generic + Xilinx)
./test_run_yosys.py --target generic               # Run only the generic/ASIC coarse synthesis
./test_run_yosys.py --target ice40                 # Run any Yosys synth_* target by name
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
| `test_riscv_tests.py`      | riscv-tests ISA regression runner         |
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

### Environment Variables

| Variable             | Description                                          | Default      |
|----------------------|------------------------------------------------------|--------------|
| `SIM`                | Simulator to use                                     | `verilator`  |
| `COCOTB_TEST_FILTER` | Regex selecting test functions to run (set by `--testcase`) | (all)      |
| `COCOTB_RANDOM_SEED` | Random seed for reproducibility (set by `--random-seed`)    | (random)   |
| `WAVES`              | Generate waveform file (1/0)                         | `0`        |
| `FROST_COCOTB_MEM_CONFIG` | Memory tier for real-program tests (`bram` / `ddr`) | `bram`   |

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

### Other Tools

| Tool       | Purpose                  |
|------------|--------------------------|
| Python     | Test runner              |
| Cocotb     | Verification framework   |
| Yosys      | Open-source synthesis    |
| RISC-V GCC | C cross-compiler         |

## CI Integration

All tests are run automatically in CI (`.github/workflows/ci.yml`). Tests gracefully skip if required tools are not installed.

The arch-compliance, riscv-tests, riscv-torture, and Cocotb real-program suites each run in BOTH a `bram` tier (whole program in low BRAM) AND a `ddr` tier (whole program in the cached DDR region) as separate jobs:

- **Cocotb**: one `bram` job (`Cocotb Tests (Verilator)`, also covers the tier-independent unit benches) and one `ddr` job (`Cocotb Real Programs (Verilator / ddr)`, `FROST_COCOTB_MEM_CONFIG=ddr`, real programs only).
- **Arch compliance**: an extension x memory tier (`[bram, ddr]`) matrix with `fail-fast: false`. Zifencei is excluded from the `bram` tier (DDR-tier-only), and each slow F/D test excluded by the size filter is added as its own `ddr`-tier job. Kept separate from the main Cocotb job to avoid blocking it with long-running FP tests.
- **riscv-tests**: a suite x memory tier matrix (ISA tests) plus a benchmark x memory tier matrix (benchmarks).
- **riscv-torture**: a memory tier (`[bram, ddr]`) matrix.

The `icache` arch config (code in DDR, data + signature in BRAM) is a local diagnostic, not a CI job.

### Test Markers

```python
@pytest.mark.cocotb       # RTL simulation tests
@pytest.mark.synthesis    # Synthesis tests
@pytest.mark.formal       # Formal verification tests
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
