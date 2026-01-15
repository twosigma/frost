# Frost Test Infrastructure

This directory contains the test infrastructure for the Frost RISC-V CPU project, including RTL simulations and synthesis verification.

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            Test Infrastructure                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌───────────────────────────────────┐  ┌─────────────────────────────────┐ │
│  │       test_run_cocotb.py          │  │       test_run_yosys.py         │ │
│  │                                   │  │                                 │ │
│  │  RTL Simulation                   │  │  Synthesis Check                │ │
│  │  • CPU unit tests                 │  │  • Yosys synthesis              │ │
│  │  • Real C programs                │  │  • No vendor IPs                │ │
│  │  • Verification                   │  │                                 │ │
│  └─────────────────┬─────────────────┘  └────────────────┬────────────────┘ │
│                    │                                     │                  │
│                    v                                     v                  │
│  ┌───────────────────────────────────┐  ┌─────────────────────────────────┐ │
│  │           Simulator               │  │            Yosys                │ │
│  │    Icarus/Verilator/Questa        │  │     (open-source synthesis)     │ │
│  └───────────────────────────────────┘  └─────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Test Files

### `test_run_cocotb.py`

Primary test runner for RTL simulations using Cocotb. Supports both standalone execution and pytest integration.

**Available Tests:**

| Test                | Description                                                              |
|---------------------|--------------------------------------------------------------------------|
| `branch_pred_test`  | Branch prediction test suite (45 tests)                                  |
| `ras_test`          | Return Address Stack (RAS) comprehensive test suite                       |
| `ras_stress_test`   | RAS stress test (calls, branches, and function pointers)                  |
| `cpu`               | CPU verification suite (9 testcases: random regression, atomics, traps, compressed) |
| `hello_world`       | Simple "Hello, world!" program                                           |
| `isa_test`          | ISA compliance test suite                                                |
| `coremark`          | Industry-standard CPU benchmark                                          |
| `freertos_demo`     | FreeRTOS RTOS demo with timer interrupts                                 |
| `csr_test`          | CSR and trap handling tests                                              |
| `memory_test`       | Memory allocator test suite                                              |
| `strings_test`      | String library test suite                                                |
| `packet_parser`     | FIX protocol message parser                                              |
| `c_ext_test`        | C extension (compressed instruction) test                                |
| `call_stress`       | Function call stress test                                                |
| `spanning_test`     | Instruction spanning boundary test                                       |
| `print_clock_speed` | Clock speed measurement utility                                          |

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
./test_run_cocotb.py cpu --sim=questa              # Use Questa

# GUI mode (Questa only)
./test_run_cocotb.py cpu --sim=questa --gui        # Open waveform viewer

# Reproducibility options
./test_run_cocotb.py cpu --random-seed=12345       # Use specific seed
./test_run_cocotb.py cpu --testcase=test_random    # Run specific test function
```

**Pytest Usage:**

```bash
pytest test_run_cocotb.py                          # Run all cocotb tests (both simulators)
pytest test_run_cocotb.py -k verilator             # Run with Verilator only
pytest test_run_cocotb.py -k hello_world           # Run specific test (both simulators)
pytest test_run_cocotb.py -k "verilator and hello_world"  # Specific test, one simulator
pytest test_run_cocotb.py -s                       # Show live output
```

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

| File          | Purpose                             |
|---------------|-------------------------------------|
| `conftest.py` | Pytest configuration and fixtures   |
| `Makefile`    | Cocotb simulation build rules       |
| `.gitignore`  | Excludes build artifacts            |

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
./test_run_cocotb.py cpu --sim=questa --gui        # Questa with waveforms
```

### Environment Variables

| Variable      | Description                      | Default    |
|---------------|----------------------------------|------------|
| `SIM`         | Simulator to use                 | `icarus`   |
| `GUI`         | Enable GUI mode (1/0)            | `0`        |
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
| Questa         | Commercial, GUI support     |

### Other Tools

| Tool       | Purpose                  |
|------------|--------------------------|
| Python     | Test runner              |
| Cocotb     | Verification framework   |
| Yosys      | Open-source synthesis    |
| RISC-V GCC | C cross-compiler         |

## CI Integration

All tests are run automatically in CI. Tests gracefully skip if required tools are not installed.

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

### Questa license errors

Ensure your Questa license is configured. The `--gui` flag requires a GUI-capable license.

### Tests timing out

Some tests (coremark, freertos_demo) run for many cycles. Use environment variable for timeouts:
```bash
COCOTB_SCHEDULER_DEBUG=1 ./test_run_cocotb.py coremark
```
