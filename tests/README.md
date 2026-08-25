# Frost Test Infrastructure

This directory contains RTL simulation, formal, and synthesis test runners.

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
│  │ • CPU unit     │ │   ance         │ │ • riscv-tests  │ │ • 20-test      │ │ • Yosys        │ │
│  │   tests        │ │ • riscv-arch-  │ │ • rv64 ISA     │ │   corpus       │ │   synthesis    │ │
│  │ • Real C progs │ │   test         │ │   suites       │ │ • IMAFDC       │ │ • No vendor    │ │
│  │ • Verification │ │ • rv64i_m      │ │ • Benchmarks   │ │ • Spike refs   │ │   IPs          │ │
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

## Reproducible Local Execution

Run these examples from the repository root through `./scripts/frost.py`. The
wrapper uses the pinned `frost` image as the invoking UID/GID with its home
under `/tmp`, keeping artifacts writable by native tools. Its `cocotb` and
`pytest` shortcuts first run `make clean` in `tests/`. After building the image
with `docker build -t frost .`, run the read-only preflight:

```bash
./scripts/frost.py doctor
```

The preflight reports `PASS`, `WARN`, `FAIL`, or dependency-gated `SKIP` and
returns nonzero on failure. It does not modify the checkout, and its artifact
ownership scan skips `./hw`.

## Test Files

### `test_run_cocotb.py`

Runs Cocotb simulations directly or through pytest.

**Target discovery:** `TEST_REGISTRY` in `test_run_cocotb.py` is the canonical
list.

```bash
./scripts/frost.py cocotb --list-tests
./scripts/frost.py cocotb --help
```

**Standalone Usage:**

Applications compile automatically before simulation.

```bash
# Basic usage
./scripts/frost.py cocotb tomasulo_test             # Run CPU correctness test
./scripts/frost.py cocotb hello_world               # Run Hello World program
./scripts/frost.py cocotb isa_test                  # Run ISA compliance tests
./scripts/frost.py cocotb freertos_demo             # Run FreeRTOS demo
./scripts/frost.py cocotb coremark_pro_core         # CoreMark-PRO workload system sim
                                                   # (also: _cjpeg, _linear_alg, _loops,
                                                   #  _nnet, _parser, _radix2, _sha,
                                                   #  _zip; long-running)

# Reproducibility options
./scripts/frost.py cocotb cdb_arbiter --random-seed=12345
./scripts/frost.py cocotb cdb_arbiter --testcase=test_random_multi_fu_stress

# Seed sweep (parallel random seed testing)
./scripts/frost.py cocotb cdb_arbiter --seed-sweep 10
./scripts/frost.py cocotb cdb_arbiter --seed-sweep 20 --max-workers 4
./scripts/frost.py cocotb cdb_arbiter --seed-sweep 10 \
  --testcase test_random_multi_fu_stress
```

**Seed Sweep Mode:**

`--seed-sweep N` runs N random seeds in parallel to find intermittent failures.

Each worker gets an isolated `SIM_BUILD` and `COCOTB_RESULTS_FILE`. App-based
tests compile once and share read-only `sw*.mem` symlinks; this avoids races in
the shared CWD. The summary includes seed status, failure-output tails, and
reproduction commands:

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

The report prints the command as seen inside the container. From the host, run
the same arguments as
`./scripts/frost.py cocotb cdb_arbiter --random-seed=987654321`.

Options:
- `--seed-sweep N` — number of random seeds to test
- `--max-workers W` — limit parallel workers (default: min(N, cpu_count))
- The sweep can be combined with `--testcase` to target a specific test function

**Pytest Usage:**

```bash
./scripts/frost.py pytest                           # Run all pytest-registered Cocotb tests
./scripts/frost.py pytest -k hello_world            # Run a specific test
./scripts/frost.py pytest -k unit                   # Run unit tests
./scripts/frost.py pytest -m "cocotb_real_program and not coremark_pro"
./scripts/frost.py pytest -m "cocotb_real_program and coremark_pro"
./scripts/frost.py pytest -s                        # Show live output
```

**Memory tier for real programs (`FROST_COCOTB_MEM_CONFIG`):**

Real-program tests default to whole-program low BRAM (`bram`). Setting
`FROST_COCOTB_MEM_CONFIG=ddr` relinks each app into cached DDR, exercising L1I
and the D-side cached tier:

```bash
FROST_COCOTB_MEM_CONFIG=ddr ./scripts/frost.py cocotb hello_world
FROST_COCOTB_MEM_CONFIG=ddr ./scripts/frost.py pytest -k test_real_program
```

Tests in `DDR_TIER_EXCLUDE` self-skip in the `ddr` tier: the `*_fetch_fuzz` fetch fuzzers, and the already-DDR-focused `ddr_*` programs (`ddr_test`, `ddr_exec_test`, `ddr_smc_test`, `ddr_heap_test`, `ddr_atomic_test`) whose fixed-address writes a whole-program relocation would clobber. Unit benches are tier-independent and run only once (in the `bram` job).

### `test_arch_compliance.py`

Runs the official [riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test)
suite. Each assembly case runs under Verilator; its UART signature is compared
with a golden reference generated by the image's pinned Spike
(`sw/apps/arch_test/generate_references.py`). References live under
`sw/apps/arch_test/references/rv64i_m/`.

**Supported extensions:** I, M, A, F, D, C, B, K, Zicond, Zifencei, privilege, D_Zcd, hints (260+ tests total). No F_Zcf: RV64C reinterprets the C.FLW/C.FSW slots as C.LD/C.SD, so Zcf is rv32-only.

**Standalone Usage:**

Run `./scripts/frost.py run make -C tests clean` immediately before whichever
parameterized runner invocation you choose below.

```bash
# Run all supported extensions
./scripts/frost.py run python3 tests/test_arch_compliance.py --all

# Run specific extensions
./scripts/frost.py run python3 tests/test_arch_compliance.py --extensions I M A

# Run a single test
./scripts/frost.py run python3 tests/test_arch_compliance.py \
  --test rv64i_m/I/src/addw-01.S

# Include tests too large for simulation (hardware validation)
./scripts/frost.py run python3 tests/test_arch_compliance.py --all --no-sim-filter

# Select the memory tier the test runs from (default: ddr)
./scripts/frost.py run python3 tests/test_arch_compliance.py \
  --extensions I --mem-config bram
./scripts/frost.py run python3 tests/test_arch_compliance.py \
  --extensions Zifencei --mem-config ddr
./scripts/frost.py run python3 tests/test_arch_compliance.py \
  --extensions I --mem-config icache
```

The parameterized architecture, riscv-tests, and torture runners require
serial execution (`--parallel 1`, the default) because they share application
outputs, image links, and simulator paths. A larger worker count fails before
building. Cocotb seed sweeps use isolated paths and support parallel workers.

**Memory tiers (`--mem-config`):** `MEM_CONFIG` selects the linker script and
crt0 stub for code and data/signature placement:
- `bram` — code + data + signature all in low BRAM (pure ISA conformance).
- `icache` — code in DDR (L1I fetch path under test), data + signature in low BRAM (isolates instruction fetch from the D-side cached tier). Diagnostic only; not a CI job.
- `ddr` — code + data + signature in DDR; also exercises the D-side cached tier on every load/store. **This is the default** (`DEFAULT_MEM_CONFIG`).

The pytest entry point honors `FROST_ARCH_MEM_CONFIG` to override the default.

**Pytest Usage:**

```bash
./scripts/frost.py run bash -c \
  'cd tests && make clean && exec pytest test_arch_compliance.py -v -m slow'
```

**Notes:**
- Verilator only
- Tests with >5000 test cases are filtered by default (the slow F/D fused tests, 7K-14K cases each, that take a long time under Verilator). Use `--no-sim-filter` for hardware validation runs
- In CI, runs as a GitHub Actions matrix of extension x memory tier (`[bram, ddr]`) with `fail-fast: false` (`Arch Tests`). Zifencei (fence.i / self-modifying code) is excluded from the `bram` tier — the low-BRAM Harvard split has separate instruction and data memories, so a store reaches only the data BRAM; fence.i's writeback + invalidate apply to the cached DDR tier alone, making it a DDR-tier-only compliance test. The very slow F/D DDR permutations are also excluded in CI; FPU conformance is covered by F/D BRAM jobs, and DDR/cache behavior by the other DDR tiers.
- In the `bram`/`icache` tiers, a test whose `.text`/`.data` exceeds the 256 KiB low BRAM (96 KiB instruction + 160 KiB data) is reported SKIP rather than FAIL — the `ddr` tier still exercises it
- Low BRAM is sized to match hardware (`-GMEM_SIZE_BYTES=262144`, 256 KiB); the cached DDR region is provided by the behavioral DDR model and preloaded from `sw_ddr.mem`

### `test_riscv_tests.py`

Runs self-checking [riscv-tests](https://github.com/riscv-software-src/riscv-tests)
ISA tests, which print `<<PASS>>` or `<<FAIL>>` through UART. They cover
multi-instruction dependencies, traps, atomics, FP behavior, two-wide dispatch,
and OOO commit beyond arch-test's single-instruction focus.

**Supported suites:** rv64ui, rv64um, rv64ua, rv64uf, rv64ud, rv64uc, rv64mi, rv64uzba, rv64uzbb, rv64uzbs, rv64uzbkb (166 tests total)

**Standalone Usage:**

Run `./scripts/frost.py run make -C tests clean` immediately before whichever
runner invocation you choose below.

```bash
# Run all suites
./scripts/frost.py run python3 tests/test_riscv_tests.py --all

# Run specific suites
./scripts/frost.py run python3 tests/test_riscv_tests.py \
  --suites rv64ui rv64um rv64uf

# Run a single test
./scripts/frost.py run python3 tests/test_riscv_tests.py --test rv64ui/add

# Select the memory tier (default: bram)
./scripts/frost.py run python3 tests/test_riscv_tests.py \
  --all --mem-config ddr

# List available tests
./scripts/frost.py run python3 tests/test_riscv_tests.py --list
```

**Memory tiers (`--mem-config`):** `bram` (default) keeps code + data in low BRAM (pure ISA path); `ddr` runs the test from the cached DDR region (exercises the L1I fetch path and the D-side cached tier). The Makefile knob `MEM_CONFIG` selects the linker script (+ ROM boot stub for `ddr`).

**Environments (`--env`):** `p` (default) is the physical environment — the test runs bare in M-mode (the upstream `-p` variants). `v` is the virtual environment (the upstream `-v` variants): the test runs as demand-paged Sv39 user code under the supervisor kernel in `sw/apps/riscv_tests/env_v/` (fetch and data translated, page faults delegated to S-mode, the kernel setting the A/D bits on fault — Svade). `v` requires `--mem-config ddr` (page tables and user frames live in cached DDR) and covers the user-level suites only. The Makefile knob is `ENV`.

```bash
# The -v variants of the base-integer suite
./scripts/frost.py run python3 tests/test_riscv_tests.py \
  --suites rv64ui --mem-config ddr --env v
```

**Pytest Usage:**

```bash
./scripts/frost.py run bash -c \
  'cd tests && make clean && exec pytest test_riscv_tests.py -v -m slow'
```

**Notes:**
- Verilator only (skips automatically for non-Verilator sims)
- A small number of tests are skipped in every tier due to architectural incompatibility (misaligned accesses trap rather than complete, no debug trigger module, no PMP, read-only `mcycle`/`minstret` aliases, hardware A/D-bit updates — `rv64si/dirty` — on an Svade machine). See `ISA_SKIP_TESTS` in the script for details.
- `rv64ui/fence_i` is skipped in the `bram` tier only (`ISA_SKIP_TESTS_BRAM`): self-modifying code is meaningful only against the cached DDR L1I, so it runs in `ddr` alone.
- In CI, runs as a suite x memory tier (`[bram, ddr]`) matrix in the `p` environment plus the user-level suites in `ddr` / `v`; benchmarks run as a benchmark x memory tier matrix.

### `test_riscv_torture.py`

Runs a generated RV64IMAFDC corpus covering ALU, multiply/divide, memory,
branch, FP, and AMO operations, including W-form ALU/MUL, LD/SD/LWU, and `.d`
atomics. A 64-bit Spike run generates the register signatures used to check
Frost simulation.

**Standalone Usage:**

Run `./scripts/frost.py run make -C tests clean` immediately before whichever
runner invocation you choose below.

```bash
# Run all torture tests
./scripts/frost.py run python3 tests/test_riscv_torture.py --all

# Run a single test
./scripts/frost.py run python3 tests/test_riscv_torture.py --test test_001

# Select the memory tier (default: bram)
./scripts/frost.py run python3 tests/test_riscv_torture.py \
  --all --mem-config ddr

# List available tests and reference status
./scripts/frost.py run python3 tests/test_riscv_torture.py --list
```

**Memory tiers (`--mem-config`):** `bram` (default) runs from low BRAM (pure ISA path); `ddr` runs from the cached DDR region (exercises the L1I fetch path and the D-side cached tier).

**Paged environment (`--paged`):** runs the whole test — the random stream and the footer's signature dump — in S-mode under an Sv39 identity map (1 GiB leaves over the low BRAM, the device quadrant and DDR), so every fetch and data access translates through the ITLB/DTLB and the walker. Requires `--mem-config ddr` (the root table lives in `.data`, which must be in cached DDR). The Spike references are unchanged: translation does not alter the architectural register state the signature captures. Makefile knob: `PAGED=1`.

```bash
./scripts/frost.py run python3 tests/test_riscv_torture.py \
  --all --mem-config ddr --paged
```

In CI, runs as a memory tier (`[bram, ddr]`) matrix plus `ddr` paged.

**Generating Tests:**

The corpus and its Spike references are pre-generated and checked in (`tests_rv64/` + `references_rv64/`; the `_rv64` directory names are historical, from when an rv32 corpus existed beside them). To regenerate:

```bash
cd sw/apps/riscv_torture
./generate_tests.py --generate --count 20 --seed 20260803
```

**Pytest Usage:**

```bash
./scripts/frost.py run bash -c \
  'cd tests && make clean && exec pytest test_riscv_torture.py -v -m slow'
```

**Notes:**
- Verilator only (skips automatically for non-Verilator sims)
- Requires Spike (`riscv-isa-sim`) for reference generation only, not for running tests
- FP register signatures are compared exactly against Spike references. The corpus pins AMO addresses to known registers (sp/gp/x30/x31), so all other integer registers are compared against Spike as well

### `test_run_yosys.py`

Runs Yosys synthesis checks. The generic target intentionally stops after Yosys
coarse synthesis, which verifies vendor-agnostic elaboration, procedural
lowering, memory inference, and structural checks without defining Xilinx
primitives. It does not prove that the full CPU maps all the way to ASIC gates
or a non-Xilinx FPGA fabric. The Xilinx targets still run full Yosys synthesis
for 7-series, UltraScale, and UltraScale+.

**Standalone Usage:**

```bash
./scripts/frost.py synthesis                       # Run default targets
./scripts/frost.py synthesis --target generic      # Generic/ASIC coarse synthesis
./scripts/frost.py synthesis --target ice40        # Any Yosys synth_* target
./scripts/frost.py synthesis --verbose             # Show full Yosys output
```

**Pytest Usage:**

```bash
./scripts/frost.py run pytest tests/test_run_yosys.py
```

### `test_run_formal.py`

Runs the SymbiYosys formal targets in `formal/`. The registry is `FORMAL_TARGETS`
inside `test_run_formal.py`: one entry per `.sby` file, each declaring which task
types it supports. Most targets declare `bmc` and `cover`; a few
(`rs_issue2_selector`, `fu_cdb_adapter_payload_no_refill`) are BMC-only. `prove`
(induction) is a recognized task type that no target currently declares.

**Standalone Usage:**

```bash
./scripts/frost.py formal                          # All targets, all declared tasks
./scripts/frost.py formal --list-targets           # Targets, their tasks, and exit
./scripts/frost.py formal --target reorder_buffer  # One target (the .sby stem)
./scripts/frost.py formal --task bmc               # One task type
./scripts/frost.py formal --verbose                # Show full sby output
```

`--task` intersects with each target's declared tuple, so it never forces a task
onto a target that does not support it. Each sby task gets a 40 minute timeout
(`SBY_TASK_TIMEOUT_S`), sized as a hang backstop rather than a performance gate.

**Pytest Usage:**

```bash
./scripts/frost.py run pytest tests/test_run_formal.py
```

Every target x task pair is a separate parametrized case, and the whole
`TestFormalVerification` class carries the `formal` marker; CI selects it with
`pytest tests/ -m formal -v`.

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

### Run Fast Python Tests

This is the non-simulator selection used by CI. It catches ordinary tooling
and helper tests without launching Cocotb, synthesis, or formal jobs. The
exact underlying command is retained here for focused debugging:

```bash
./scripts/frost.py run pytest tests \
  -m "not cocotb and not synthesis and not formal and not slow" -v
```

For the normal local gate, run both this selection and CI's exact lint job:

```bash
./scripts/frost.py check
```

`check` keeps going after the first failed phase so its summary includes both
jobs; use `./scripts/frost.py check --fail-fast` to stop immediately. The lint
hooks include automatic formatters and fixers, so `check` may modify files;
review the working-tree diff. `check` is exactly `./scripts/frost.py lint`
followed by the fast-Python selection shown above.

The full regression is split across simulator, synthesis, formal,
architecture-compliance, and software workflows. Use their dedicated commands
instead of host-native `pytest`.

### Filter by Test Type

```bash
./scripts/frost.py pytest -m cocotb                # Simulation tests only
./scripts/frost.py pytest -m "cocotb and cocotb_unit"
./scripts/frost.py pytest -k hello_world
./scripts/frost.py synthesis
./scripts/frost.py formal
./scripts/frost.py lint
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

- `results.xml` — JUnit-format test results (for CI integration)
- `dump.fst` — FST waveform file (when `WAVES=1`; the Makefile passes `--trace-fst --trace-structs`)

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

CI (`.github/workflows/ci.yml`) runs every category in the pinned image. Missing
required tools are failures rather than silent skips. The `Fast Python Tests`
job runs the default/unmarked tests as the host UID and GID with `HOME=/tmp`,
which also guards the non-root execution model used by `scripts/frost.py`.

The riscv-tests, torture, and Cocotb real-program suites run separate `bram`
(whole program in low BRAM) and `ddr` (whole program in cached DDR) jobs.
Architecture compliance uses both tiers for most extensions; F/D DDR is
disabled because it times out on GitHub-hosted runners:

- **Cocotb**: a `bram` matrix split into non-CoreMark-PRO real programs, unit benches, and CoreMark-PRO real programs, plus one `ddr` job (`Cocotb Real Programs (Verilator / ddr)`, `FROST_COCOTB_MEM_CONFIG=ddr`, real programs only).
- **Arch compliance**: an extension x memory tier (`[bram, ddr]`) matrix (`Arch Tests`) with `fail-fast: false`. Zifencei is excluded from the `bram` tier (DDR-tier-only) and F/D are excluded from the `ddr` tier to keep CI runtime bounded; there is no F_Zcf batch (Zcf is rv32-only). Kept separate from the main Cocotb job to avoid blocking it with long-running FP tests.
- **riscv-tests**: a suite x memory tier matrix (ISA tests, the eleven rv64 suites) plus a benchmark x memory tier matrix (benchmarks).
- **riscv-torture**: a memory tier (`[bram, ddr]`) matrix.
- **Fast Python tests**: default/unmarked tests selected by excluding the
  `cocotb`, `synthesis`, `formal`, and `slow` markers; run non-root in the
  pinned image.

The `icache` arch config (code in DDR, data + signature in BRAM) is a local diagnostic, not a CI job.

### Test Markers

```python
@pytest.mark.cocotb       # RTL simulation tests
@pytest.mark.cocotb_real_program  # Cocotb real-program tests
@pytest.mark.cocotb_unit  # Cocotb unit-bench tests
@pytest.mark.coremark_pro # CoreMark-PRO real-program tests
@pytest.mark.synthesis    # Synthesis tests
@pytest.mark.formal       # Formal verification tests
@pytest.mark.slow         # Long-running tests
```

## Troubleshooting

### "No module named 'cocotb'"

Build or rebuild the pinned image rather than installing Cocotb on the host:

```bash
docker build -t frost .
```

### Verilator incremental build issues

The test runner tracks the toplevel module in `sim_build/.last_toplevel`.
The canonical shortcuts clean automatically; rerun through the wrapper:

```bash
./scripts/frost.py cocotb <test-name>
```

### Tests timing out

For long tests such as coremark and freertos_demo, raise the cycle budget:

```bash
COCOTB_COREMARK_MAX_CYCLES=30000000 ./scripts/frost.py cocotb coremark
COCOTB_MAX_CYCLES=2000000 ./scripts/frost.py cocotb hello_world
```
