# Test Infrastructure

The scripts in this directory run every FROST regression: cocotb simulations
of RTL blocks, the CPU, and whole programs under Verilator; the
riscv-arch-test, riscv-tests, and torture suites against reference results;
Yosys synthesis; and SymbiYosys proofs. Each `test_*.py` runner in the table
below works as a command-line tool and as a pytest module, and CI runs
everything in the table. The other `test_*.py` files are quick pytest checks
of the repository's scripts and tooling (see [Fast checks](#fast-checks)).
Run everything from the repository root through the pinned `frost` image (see
[tooling setup](../docs/tooling.md)). Vivado builds and the hardware
regression run [natively](../fpga/README.md#hardware-regression) instead.

| Runner | Checks |
|--------|--------|
| [`test_run_cocotb.py`](#test_run_cocotbpy) | Block benches, directed CPU tests, and applications in simulation |
| [`test_arch_compliance.py`](#test_arch_compliancepy) | riscv-arch-test signatures against Spike references |
| [`test_riscv_tests.py`](#test_riscv_testspy) | riscv-tests ISA suites and benchmarks |
| [`test_riscv_torture.py`](#test_riscv_torturepy) | Random RV64IMAFDC programs against Spike references |
| [`test_run_yosys.py`](#test_run_yosyspy) | Portable and Xilinx synthesis |
| [`test_run_formal.py`](#test_run_formalpy) | Formal proofs |
| [`net10g/`](net10g/README.md) | Standalone Ethernet MAC/PCS simulation and synthesis |

The cocotb benches, models, and monitors themselves live in
[`verif/`](../verif/README.md).

## Fast checks

```bash
./scripts/frost.py doctor   # read-only check of Docker, the image, submodules, and file ownership
./scripts/frost.py check    # CI's Lint and Fast Python Tests jobs
```

`check` reports both jobs; `--fail-fast` stops after the first failure. The
lint hooks can modify files, so review the working tree afterward. The
whitespace fixers skip the board captures in `tests/fixtures/*.log`, which
must keep their exact bytes, including terminal escapes, carriage returns,
and trailing whitespace; a test fails if the escapes are cleaned out. To run
only the fast Python tests:

```bash
./scripts/frost.py run pytest tests -m "not cocotb and not synthesis and not formal and not slow" -v
```

## Test runners

### `test_run_cocotb.py`

`TEST_REGISTRY` defines every simulation target: benches for CPU and SoC
blocks, directed CPU tests, and applications from `sw/apps/`, which the
runner compiles first. A failing RTL assertion fails the simulation.

```bash
./scripts/frost.py cocotb --list-tests                                        # every target, with a description
./scripts/frost.py cocotb hello_world                                         # one target
./scripts/frost.py cocotb cdb_arbiter --random-seed 12345                     # reproduce a random seed
./scripts/frost.py cocotb cdb_arbiter --testcase test_random_multi_fu_stress  # one cocotb test function
./scripts/frost.py cocotb cdb_arbiter --seed-sweep 20 --max-workers 4         # 20 seeds, 4 at a time
./scripts/frost.py pytest -m "cocotb and cocotb_unit" -v                      # unit benches collected by pytest
./scripts/frost.py pytest -m "cocotb_real_program and not coremark_pro"       # applications except CoreMark-PRO
```

The `cocotb` and `pytest` shortcuts clean `tests/` first. `--testcase` takes
a regex for the cocotb test function; with pytest, `-k` and `-m` select
registry targets. A seed sweep gives each run its own build directory and
prints a command that reproduces each failing seed.

Whole-CPU simulations, synthesis, and FPGA builds all use the CPU
configuration in `riscv_pkg`. The `tomasulo_wrapper_no_early_load` and
`load_queue_no_prepare_busy` targets cover early load wakeup and busy-port
load preparation turned off, and `coremark_profile` runs CoreMark with the
profiling counters.

Applications run from low BRAM by default. To run them from cached DDR:

```bash
FROST_COCOTB_MEM_CONFIG=ddr ./scripts/frost.py cocotb hello_world
```

Block benches ignore this setting, and so do applications with a fixed
layout, such as `opensbi_smoke`. In the DDR tier, pytest skips the programs
in `DDR_TIER_EXCLUDE`: the DDR probes (`ddr_*`), which already target DDR,
and the fetch fuzzers (`*_fetch_fuzz`), which use their own build.

`debug_test` drives the JTAG debug module directly; `debug_openocd_test` runs
a real OpenOCD session through `remote_bitbang`. Without OpenOCD installed
that target logs a warning and passes; set `FROST_REQUIRE_OPENOCD=1`, as CI
does, to make it fail instead. The
[memory-response tests](../verif/cocotb_tests/cpu_ooo/memory/README.md) cover
the portable and Xilinx builds of the load-data mux.

#### Adding a target

Register a bench in `TEST_REGISTRY`:

```python
"new_feature": CocotbRunConfig(
    python_test_module="cocotb_tests.path.test_new_feature",
    hdl_toplevel_module="new_feature",
    description="New feature unit tests",
),
```

Check discovery with `./scripts/frost.py cocotb --list-tests`, then run
`./scripts/frost.py cocotb new_feature`.

### Compliance and torture runners

The ISA runners below share application and simulator build directories.
Run one at a time, with the default `--parallel 1`, and clean `tests/` before
each invocation:

```bash
./scripts/frost.py run make -C tests clean
./scripts/frost.py run python3 tests/test_arch_compliance.py --all
```

The examples below leave out the clean step. Each runner's pytest entry
point is marked `slow`:

```bash
./scripts/frost.py run bash -c 'cd tests && make clean && exec pytest test_riscv_tests.py -v -m slow'
```

### `test_arch_compliance.py`

Runs the implemented parts of riscv-arch-test and compares each test's
signature, printed over the UART, with a committed Spike reference under
`sw/apps/arch_test/references/`, which mirrors the suite's directory layout.
The extensions are I, M, A, F, D, C, B, K (Zbkb only), Zicond, Zifencei,
privilege, D_Zcd, and hints; Zcf exists only on RV32. The tests come from the
suite's `rv64i_m` directory; F and D also run the tests that RV32 and RV64
share, which the suite keeps under `rv32i_m/F` and `rv32i_m/D`, except the
`*_b15` fused multiply-add sets in subdirectories, which together are too
large to simulate. Every test runs with XLEN=64 and FLEN=64. The filters and
exclusions in the runner define the exact set.

```bash
./scripts/frost.py run python3 tests/test_arch_compliance.py --extensions I M A
./scripts/frost.py run python3 tests/test_arch_compliance.py --test rv64i_m/I/src/addw-01.S
./scripts/frost.py run python3 tests/test_arch_compliance.py --test rv32i_m/F/src/fadd_b1-01.S
./scripts/frost.py run python3 tests/test_arch_compliance.py --extensions I --mem-config icache
./scripts/frost.py run python3 tests/test_arch_compliance.py --extensions F --shard 1/4
```

| Memory tier | Code | Data and signature |
|-------------|------|--------------------|
| `ddr` (default) | DDR | DDR |
| `bram` | BRAM | BRAM |
| `icache` (diagnostic) | DDR | BRAM |

The pytest entry point reads the tier from `FROST_ARCH_MEM_CONFIG`. Extension
runs leave out tests with more than 5,000 cases (`SIM_MAX_TEST_CASES`) unless
you pass `--no-sim-filter`; `--test` runs any one test. In the `bram` and
`icache` tiers, a test too large for low BRAM (95 KiB of code, 1 KiB reserved
for debug, and 160 KiB of data and stack) reports SKIP; the `ddr` tier still
runs it. `--shard K/N` runs part K of N of each selected extension, with the
parts balanced by case count. A selected test with no committed reference
fails; `sw/apps/arch_test/generate_references.py`, run in the frost image,
generates references with the pinned Spike.

CI skips Zifencei in BRAM, because ordinary stores cannot reach the separate
instruction BRAM, and F and D in DDR, to fit the runner time budget; the BRAM
jobs cover FPU conformance, split into shards. The F and D tests that do not
fit low BRAM (the larger `*_b8` and `*_b9` arithmetic sets) and those above
5,000 cases (the `*_b1` fused multiply-adds and the `*_b11` adds and
subtracts) therefore run only locally, for example with
`--test rv32i_m/F/src/fmadd_b1-01.S --mem-config ddr`. `icache` runs only
locally.

Many F and D tests in the pinned suite have malformed data constants (a hex
value run together with decimal digits). The assembler truncates each one with
a warning, so those cases load other operands than their comments name, and
some special cases never run: the fused multiply-add `*_b1` sets, for example,
never multiply infinity by zero with a quiet-NaN addend, a case that
`fp_mul_shim` checks directly.

### `test_riscv_tests.py`

Runs the self-checking riscv-tests ISA suites and benchmarks, which print
`<<PASS>>` or `<<FAIL>>` over the UART. `--list` prints the suites and
benchmarks, `--all` runs every ISA suite, and `--all-benchmarks` every
benchmark.

```bash
./scripts/frost.py run python3 tests/test_riscv_tests.py --suites rv64ui rv64um
./scripts/frost.py run python3 tests/test_riscv_tests.py --test rv64ui/add
./scripts/frost.py run python3 tests/test_riscv_tests.py --all --mem-config ddr
./scripts/frost.py run python3 tests/test_riscv_tests.py --suites rv64ui --mem-config ddr --env v
```

`--mem-config bram` is the default. `--env p` runs the physical variants, with
no kernel and each test in the mode its RVTEST macro selects (user mode for
`rv64u*`). `--env v` runs the user-level suites under the demand-paged Sv39
supervisor in `sw/apps/riscv_tests/env_v/`. The virtual environment needs DDR,
and it sets page-table A and D bits from page faults (Svade).

`ISA_SKIP_TESTS` leaves out tests for behavior FROST does not implement:
misaligned accesses in hardware (`ma_data`), debug triggers, PMP, and hardware
A/D updates. It also leaves out `instret_overflow`, because a write to
`minstret` does not replace the writing instruction's own increment, and
`ma_addr`, which passes and can be re-enabled. In BRAM, `ISA_SKIP_TESTS_BRAM`
also leaves out `fence_i` and `icache-alias`, which need DDR for instruction
storage or page tables.

### `test_riscv_torture.py`

Runs a committed corpus of random RV64IMAFDC programs and compares each
program's register dump with a Spike reference.

```bash
./scripts/frost.py run python3 tests/test_riscv_torture.py --all
./scripts/frost.py run python3 tests/test_riscv_torture.py --test test_001
./scripts/frost.py run python3 tests/test_riscv_torture.py --all --mem-config ddr --paged
```

`bram` is the default tier. `--paged` needs DDR: it runs each program and its
register dump in S-mode through an Sv39 identity map of BRAM, the devices,
and DDR. Translation does not change register state, so the same Spike
references apply. FP registers must match exactly. The integer comparison
skips `sp`, `gp`, `x30` (the AMO address register), and `x31` (the memory
base), which hold layout-dependent addresses.

To regenerate the corpus and references with the pinned compiler and Spike
(the committed corpus uses seed 20260803):

```bash
./scripts/frost.py run python3 sw/apps/riscv_torture/generate_tests.py --generate --count 20 --seed 20260803
```

### `test_run_yosys.py`

Synthesizes `cpu_and_mem` (the CPU, memory system, and NIC, from
`hw/rtl/frost.f`) with portable coarse synthesis (`generic`) and with full
Xilinx UltraScale+ synthesis. Both fail on unresolved modules or latches.
sv2v converts the NIC, MAC, and PCS sources for Yosys first. Generic
synthesis does not check device mapping or timing. Xilinx synthesis has a
two-hour timeout, which `FROST_YOSYS_XILINX_TIMEOUT_SEC` overrides.

```bash
./scripts/frost.py synthesis                    # both targets
./scripts/frost.py synthesis --target generic   # portable synthesis only
```

The standalone Ethernet MAC/PCS has its own
[simulation and synthesis checks](net10g/README.md).

### `test_run_formal.py`

See the [formal guide](../formal/README.md) for the targets, what each one
proves, and its assumptions.

```bash
./scripts/frost.py formal                          # every task of every target
./scripts/frost.py formal --list-targets           # targets and their tasks
./scripts/frost.py formal --target reorder_buffer  # one target
./scripts/frost.py formal --task bmc               # one task on every target that declares it
```

Each target and task is a separate pytest case with a 40-minute timeout;
`--verbose` prints solver output.

## Environment and output

| Variable | Purpose |
|----------|---------|
| `COCOTB_TEST_FILTER` | Test-function regex (set by `--testcase`) |
| `COCOTB_RANDOM_SEED` | Random seed (set by `--random-seed`) |
| `FROST_COCOTB_MEM_CONFIG` | Application memory tier (`bram` default, or `ddr`) |
| `WAVES=1` | Write `dump.fst` waveforms |
| `NUMBER_OF_CPU_CORES` | Parallel Verilator build jobs (default: every core) |
| `COCOTB_MAX_CYCLES` | Cycle budget per application run (default 500,000); some targets set their own |
| `COCOTB_COREMARK_MAX_CYCLES` | CoreMark cycle budget (default 15,000,000) |
| `COCOTB_NUM_RUNS` | Runs per application, with a reset between them (default 2; always 1 in the DDR tier) |

Build products go to `tests/sim_build/`, and cocotb writes JUnit results to
`tests/results.xml`. A `test_run_cocotb.py` run passes only if the simulator
exits cleanly and writes a fresh report with at least one test and no
failures. Before running a runner any way other than the `cocotb` and
`pytest` shortcuts, clean `tests/` yourself
(`./scripts/frost.py run make -C tests clean`). If `doctor` reports a missing
tool or a version that differs from the Dockerfile, rebuild the image. If a
long program runs out of cycles, raise its budget.

## CI Integration

The [CI workflow](../.github/workflows/ci.yml) runs these checks in the
pinned Docker image:

| Suite | Configurations |
| --- | --- |
| Cocotb applications | BRAM and DDR where supported; each CoreMark-PRO workload runs separately |
| Cocotb unit benches, DDR probes, fetch fuzzers, OpenSBI smoke | BRAM only: tier-independent or fixed-layout runs |
| Architecture compliance | BRAM and DDR; excludes Zifencei on BRAM and F/D on DDR; F and D run in BRAM shards |
| riscv-tests | Physical mode in BRAM and DDR, user-level Sv39 tests in DDR, and benchmarks in both |
| Torture | BRAM, DDR, and paged DDR |
| Ethernet | Standalone MAC/PCS simulation and portable synthesis |
| Tooling | Lint, fast Python tests, synthesis, and formal verification |
| Linux | Firmware and root filesystem build, and QEMU boot checks |

The workflow has the exact job filters. The named real-program shards select
applications by name, and the "Runtime and other" shard runs every
application they don't list. When you add an application to a named shard or
remove one, update the "Runtime and other" exclusion list to match, or the
application will run twice or not at all. To see what a filter selects
without running it:

```bash
FROST_COCOTB_MEM_CONFIG=ddr ./scripts/frost.py pytest --collect-only -q \
  -m "cocotb and cocotb_real_program and not coremark_pro" -k '[coremark]'
```

The pytest markers:

| Marker | Selects |
| --- | --- |
| `cocotb` | Simulation targets |
| `cocotb_unit` | Unit benches |
| `cocotb_real_program` | Application tests |
| `coremark_pro` | CoreMark-PRO workloads |
| `synthesis` | Yosys checks |
| `formal` | SymbiYosys checks |
| `slow` | Long-running tests |

The `pytest` shortcut collects only `tests/test_run_cocotb.py`; select the
other markers with `./scripts/frost.py run pytest tests -m <marker>`.
