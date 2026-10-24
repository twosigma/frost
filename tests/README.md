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
| [`test_testrig.py`](#test_testrigpy) | Random instruction sequences against the Sail RISC-V model, one instruction at a time (TestRIG) |
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
whitespace fixers skip the board UART captures in `tests/fixtures/*.log`,
which must keep their exact bytes. To run only the fast Python tests:

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

Within a pytest run, a target reuses generated files only when its build
settings match, and the files of a failed Verilator build are removed before
the next target. pytest collects the applications grouped by their Verilator
arguments, in registry order within each group, so a run builds each
configuration once.

Whole-CPU simulations, synthesis, and FPGA builds all use the CPU
configuration in `riscv_pkg`. The `tomasulo_wrapper_no_early_load` and
`load_queue_no_prepare_busy` targets cover early load wakeup and busy-port
load preparation turned off, `load_queue_sq_forward` runs the load-queue bench
with store-to-load forwarding on, as the core builds it, and `coremark_profile`
runs CoreMark with the profiling counters.

Applications run from low BRAM by default. To run them from cached DDR:

```bash
FROST_COCOTB_MEM_CONFIG=ddr ./scripts/frost.py cocotb hello_world
```

Block benches ignore this setting, and so do applications with a fixed
layout, such as `opensbi_smoke`. In the DDR tier, pytest skips the programs
in `DDR_TIER_EXCLUDE`: the DDR probes (`ddr_*`), which already target DDR,
the fetch fuzzers (`*_fetch_fuzz`), which use their own build, and
`ecc_scrub_test` and `cache_counters_openocd`, whose programs run from BRAM
in either tier.
`served_window_resteer_fetch_fuzz` turns off the optional Normal read caches
so that its loop meets the SoC's AXI instruction-delay model. Each reset run
must see both injected AXI delays and predicted-target fetch waits and finish
all 2,000 iterations with correct counts and sums. Because the AXI provider
holds its delayed request, the program does not require a stale-window
resteer; the `if_stage` bench supplies stale window tags directly and checks
rejection, retry, and delayed-target handling.

In the BRAM tier an application runs twice, with a reset in between. The
second run starts from what the first leaves for the reset to clear, such as
dirty L1D and L2 lines, interrupt enables and pending interrupts, a CLINT
compare, the NIC or the DMA test engine set up, a fatal writeback stop with
the memory-error log set, and FPU state, and with the branch predictor's
tables trained, which the reset does not clear. The DDR tier runs each
application once, because its first run changes its image in DDR. Entries
with `rerun_after_reset=False` run once in both tiers; a new entry keeps the
two runs.

`freertos_demo` runs twice in BRAM to check that its private linker script
and startup code reinitialize the kernel, heap, and application state.

| Entries that run once | Reason |
| --- | --- |
| `coremark_pro_loops`, `coremark_pro_nnet`, `lq_stale_slot_probe` | Run time |
| `opensbi_smoke` | OpenSBI keeps its boot state in `.data`, so a reset without a reload is a warm boot to it |
| `amo_irq_torture_sim`, `coremark`, `coremark_profile`, `coremark_pro_core`, `coremark_pro_linear_alg`, `coremark_pro_radix2`, `itlb_test` (and its aperture variants), `pde_return_hazard`, `restore_window_stress`, `sprintf_test`, `tick_torture_sim`, `tomasulo_perf`, `wfi_lost_tick`, `window_skip_repro` | Each kind of state it leaves for the reset is also left by a shorter application that runs twice, and where CI collects its coverage, its second run reaches no coverage point that another application misses |

Entries with `nic_mac_clocks=False` run as on a board with no NIC link
clock: both MAC clocks absent and their clock-OK levels low, so the NIC keeps
its MAC domains in reset ([NIC](../hw/rtl/peripherals/nic/README.md#reset-and-clock-domains)),
and the simulation saves the evaluations of the MAC clocks' edges. They are
the applications that never touch the NIC's registers, DMA, interrupt, or
link status, and a run fails if such an application loads or stores in the
NIC's register window. The NIC programs, `opensbi_smoke`, and
`pma_fault_test`, which loads from the NIC's window to check a PMA boundary,
keep the clocks. The standalone `linux_*` instruction-pattern tests run
without them. Registry entries default to keeping the clocks.

`debug_test` drives the JTAG debug module directly; `debug_openocd_test` runs
a real OpenOCD session through `remote_bitbang`, and `cache_counters_openocd`
reads the cache profiling counters that way with `fpga/debug/cache_counters.py`.
Without OpenOCD installed those targets log a warning and pass; set
`FROST_REQUIRE_OPENOCD=1`, as CI does, to make them fail instead. The
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
signature with a committed Spike reference under
`sw/apps/arch_test/references/`, which mirrors the suite's directory layout.
At the end of a test, `RVMODEL_HALT` (`sw/apps/arch_test/model_test.h`)
prints `<<PASS>>` over the UART, and the bench then reads the signature from
the data copy of low BRAM. The `bram` and `icache` tiers keep the signature
there. The `ddr` tier keeps it in DDR, behind the write-back L1D and L2, so
`RVMODEL_HALT` first copies it to the top of low BRAM with ordinary loads and
stores. A fence before the marker waits until every store has reached the
BRAM. Each test runs once; the application jobs cover reset and rerun in the
BRAM tier. Both startup stubs initialize `a4`, which the pinned suite's
`RVTEST_INIT_GPRS` omits but its hints signatures record. This makes the
initial state match Spike without assuming GPRs clear on reset.
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
./scripts/frost.py run python3 tests/test_arch_compliance.py --extensions F D --mem-config bram --shard 1/3
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
instruction BRAM, and F and D in DDR, to save runner time; the BRAM jobs
cover FPU conformance. The F and D tests that do not fit low BRAM (the larger
`*_b8` and `*_b9` arithmetic sets) and those above 5,000 cases (the `*_b1`
fused multiply-adds and the `*_b11` adds and subtracts) therefore run only
locally, for example with
`--test rv32i_m/F/src/fmadd_b1-01.S --mem-config ddr`. `icache` runs only
locally. Each CI job runs a group of extensions in one tier, and three jobs
share F and D through `--shard K/3`, so that no job runs much longer than an
hour. `FROST_ARCH_SIM_TIMEOUT_SEC=1200` fails a hung test there after 20
minutes; the runner's default limit of an hour is sized for the largest
tests in DDR. The F and D jobs run without coverage, and the others collect
line coverage and cover points.

In many of the pinned F and D sources, most `NAN_BOXED` data constants run
the intended hex value together with its own decimal digits, less the first:
`0x7f7fffff` appears as `0x7f7fffff139095039`. The assembler would truncate
each one with a warning, so those cases would load other operands than their
comments name. `sw/apps/arch_test/repair_constants.py` restores the intended
values. The FROST build and `generate_references.py` both compile the
repaired copy, so the committed references come from it too.

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
misaligned accesses in hardware (`ma_data`), debug triggers (`breakpoint`),
PMP (`pmpaddr`), and hardware A/D updates (`dirty`). In BRAM,
`ISA_SKIP_TESTS_BRAM` also leaves out `fence_i` and `icache-alias`, which need
DDR for instruction storage or page tables.

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

### `test_testrig.py`

Runs [TestRIG](../verif/testrig/README.md): QuickCheckVEngine sends random
instruction sequences to the Sail RISC-V model and to the simulated SoC over
RVFI-DII and compares each retired instruction's destination register, store,
next PC, trap, and privilege mode. The `rvfi_dii` entry of the test registry
builds the SoC with the simulation-only injection harness, and the image
provides Sail and the engine.

```bash
./scripts/frost.py run python3 tests/test_testrig.py
./scripts/frost.py run python3 tests/test_testrig.py --include '^(mem|pte)$' --tests 500
./scripts/frost.py run python3 tests/test_testrig.py --trace tests/testrig_failures/failure-<time>.S
./scripts/frost.py run python3 tests/test_testrig.py --trace-dir verif/testrig/traces
./scripts/frost.py run python3 tests/test_testrig.py --atomics 200
```

Each run draws new sequences. `--atomics` replays random A-extension tests
from `verif/testrig/atomics.py` in place of the engine's templates, from a
seed the runner prints. A mismatch is shrunk to a short counterexample
in `tests/testrig_failures/`, which `--trace` replays; the logs and the
engine's coverage table go to `tests/testrig_logs/`. The pytest entry point
replays the saved counterexamples in `verif/testrig/traces/`.

### `test_run_yosys.py`

Synthesizes `platform_top` (the CPU tile, SoC memory system, and NIC, from
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

Each target and task is a separate pytest case. The timeout is 40 minutes,
except for `csr_file:bmc`, `csr_file:bmc_perf_off`, and `reorder_buffer:bmc`,
which have 90 minutes each. `--verbose` prints solver output.

## Environment and output

| Variable | Purpose |
|----------|---------|
| `COCOTB_TEST_FILTER` | Test-function regex (set by `--testcase`) |
| `COCOTB_RANDOM_SEED` | Random seed (set by `--random-seed`) |
| `FROST_COCOTB_MEM_CONFIG` | Application memory tier (`bram` default, or `ddr`) |
| `FROST_DDR_MODEL_SEED` | Draws the DDR model's latency (1 to 80 cycles), latency jitter, and out-of-order completion for whole-SoC builds from this string, and prints the draw. A setting the target pins, in its registry entry, in `FROST_VERILATOR_EXTRA_ARGS`, or with `DDR_MODEL_LATENCY`, keeps its value |
| `WAVES=1` | Write `dump.fst` waveforms |
| `FROST_COVERAGE=1` | Build with line coverage and the cover points (see [Coverage](#coverage)) |
| `FROST_COVERAGE_TOGGLE` | With `FROST_COVERAGE=1`: `0` disables toggle coverage, `1` collects the default set, and `control` selects control signals |
| `FROST_COVERAGE_DIR` | Where each run writes its coverage file (default `tests/coverage`; a relative path starts at the repository root) |
| `NUMBER_OF_CPU_CORES` | Parallel Verilator build jobs (default: every core; a seed sweep divides them among its workers) |
| `COCOTB_MAX_CYCLES` | Cycle budget per application run (default 500,000); some targets set their own |
| `COCOTB_COREMARK_MAX_CYCLES` | CoreMark and CoreMark-PRO cycle budget (default 15,000,000; the registry sets 20,000,000 for `coremark_pro_loops`) |
| `COCOTB_COREMARK_PROGRESS_INTERVAL` | CoreMark progress diagnostics interval in cycles (default 500,000); `0` disables the optional per-cycle Python observer, as CI does for CoreMark-PRO |
| `COCOTB_NUM_RUNS` | Runs per application, with a reset between them (default 2; 1 in the DDR tier and for entries with `rerun_after_reset=False`) |
| `FROST_CALIBRATION_TRACE_PATH` | Records a calibration trace of one run for the [performance model](../perf-modeling/README.md); the other `FROST_CALIBRATION_*` variables choose the run, the window, and more output files |
| `FROST_CALIBRATION_TEST` | Limits the calibration capture to the runs of the registry test it names |
| `FROST_NIC_MAC_CLOCKS` | `0` runs an application without the NIC's MAC clocks and with their clock-OK levels low, as entries with `nic_mac_clocks=False` do |
| `SIM_FAST_MAINT` | Fast `fence.i` cache maintenance in whole-SoC simulation (default 1; hardware uses the full sweeps, as `0` does) |

Build products go to `tests/sim_build/`, and cocotb writes JUnit results to
`tests/results.xml`. A `test_run_cocotb.py` run passes only if the simulator
exits cleanly and writes a fresh report with at least one test and no
failures. Before running a runner any way other than the `cocotb` and
`pytest` shortcuts, clean `tests/` yourself
(`./scripts/frost.py run make -C tests clean`). If `doctor` reports a missing
tool or a version that differs from the Dockerfile, rebuild the image. If a
long program runs out of cycles, first measure a complete passing run with
an extended limit, then set its budget with headroom.

## Coverage

`FROST_COVERAGE=1` builds each simulation with Verilator line coverage, which
counts statement blocks and the arms of every `if` and `case`, and with the
[cover points](#cover-points) in the RTL. `FROST_COVERAGE_TOGGLE=1` adds
toggle coverage, which counts each bit's rises and falls, for every signal
of at most 256 bits, Verilator's default limit, counting the elements of
unpacked arrays. `FROST_COVERAGE_TOGGLE=control` limits it to control
signals of at most 8 bits: scalar ports and scalar registers written by
nonblocking assignments whose names match the patterns in
[coverage_toggle.json](coverage_toggle.json), and enum state registers. It
leaves out clocks, formal, debug, reference and coverage bookkeeping, and
`hw/sim/`, as well as data buses, memories, counters and combinational
temporaries. Other declarations on a source line with a selected signal or
a covered statement are included too, within the same limit. To select
them, `coverage_toggle.py` elaborates the design and writes a Verilator
configuration file, `coverage_control.vlt`, into the simulation build
directory. Neither toggle setting changes line coverage or the cover
points.

The runners above and TestRIG all take the switches. Each run writes a file
named after its test to `tests/coverage/`, or to `FROST_COVERAGE_DIR`, and
the files collect there until you delete them: the clean step of the
`cocotb` and `pytest` shortcuts leaves them. `coverage_report.py` merges
them into a report:

```bash
FROST_COVERAGE=1 FROST_COVERAGE_TOGGLE=1 ./scripts/frost.py cocotb load_queue
FROST_COVERAGE=1 FROST_COVERAGE_TOGGLE=control ./scripts/frost.py pytest -k '[dma_torture] or [nic_loopback]'
FROST_COVERAGE=1 ./scripts/frost.py run python3 tests/test_testrig.py --tests 20
./scripts/frost.py run python3 tests/coverage_report.py report tests/coverage
```

The report goes to `tests/coverage_report/`. `coverage.dat` is the merged
data, which `verilator_coverage` reads, and `coverage.info` holds its line and
branch coverage in lcov format, with paths relative to the repository root,
for `genhtml` or an editor. `summary.md` gives the totals, each module's
line, branch, and toggle coverage, and every cover point with its hits, in
all runs and in whole-SoC runs (the programs, the ISA suites, and TestRIG),
naming the cover points that no run hits and those that only unit benches
hit. A module's figures combine every parameter set it was built with.
A toggle point is one direction of one bit. The report counts each point
once, adding its hits across runs, and its whole-SoC toggle figures use
only the points that whole-SoC builds collected. A point that a run
collected but never hit is uncovered, and a point that no run collected is
left out of the total, so whole-SoC figures from the control set cover
control signals only.
`--annotate` also writes copies of the sources with each line's count.
`merge` combines files without the report:

```bash
./scripts/frost.py run python3 tests/coverage_report.py merge tests/coverage --output all.dat
```

Coverage slows the build and the simulation. For `hello_world` on the whole
SoC, compiled with four jobs:

| Build | Build time | Simulation time | Coverage file |
| --- | --- | --- | --- |
| Without coverage | 55 s | 5.2 s | |
| `FROST_COVERAGE=1` | 100 s | 6.6 s | 3.8 MB |
| `FROST_COVERAGE=1 FROST_COVERAGE_TOGGLE=1` | 115 s | 29.7 s | 160 MB |

With `FROST_COVERAGE_TOGGLE=control`, CoreMark simulates about a quarter
slower than with `FROST_COVERAGE=1` alone.

### Cover points

Cover points mark microarchitectural corner cases that a test can pass
without reaching. Each is a `cover property` named `cover_<event>`, with a
comment that describes it, inside `` `ifndef SYNTHESIS `` and
`` `ifdef FROST_COVERAGE ``. Only a `FROST_COVERAGE=1` build defines
`FROST_COVERAGE`, so synthesis, the formal targets, and simulations without
coverage never see the cover points. The count of a module with several
instances, such as the L1D, L1I, and L2 instances of `frost_cache`, adds up
all of them.

| Module | Cover point | Event |
| --- | --- | --- |
| `lq_coherence_port` | `cover_dma_write_replays_load` | A DMA write invalidates a line that an executed, unretired load read, and the load is flagged for replay |
| `lq_coherence_port` | `cover_dma_write_replays_pending_observation` | The same, for a load whose observation is still in the port's pipeline register |
| `lq_coherence_port` | `cover_dma_admission_waits_for_atomic` | A DMA write's admission waits for an AMO or LR between its read and its write |
| `lq_coherence_port` | `cover_dma_admission_waits_for_sc` | A DMA write's admission waits for an SC at the ROB head or still draining |
| `lq_coherence_port` | `cover_sc_held_by_dma_write` | An SC at the ROB head waits because a DMA write holds its line |
| `load_queue` | `cover_dma_write_clears_reservation` | A DMA write to the reserved line cancels the LR reservation |
| `load_queue` | `cover_dma_write_hits_lr_in_flight` | A DMA write to the line of an LR in flight, which then sets no reservation |
| `load_queue` | `cover_dma_write_hits_load_in_flight` | A DMA write to the line of a cached load in flight, whose data then does not fill the L0 |
| `load_queue` | `cover_head_load_evicts_staged_load` | The ROB-head load takes the staging register from a younger staged load |
| `load_queue` | `cover_staged_load_yields_to_amo` | A staged load gives up the staging register to an older AMO that has not written |
| `load_queue` | `cover_load_waits_for_unforwardable_store` | A load overlaps an older store that cannot forward to it, so it waits |
| `load_queue` | `cover_cached_load_slots_full` | Every cached-load slot is busy, so no load launches |
| `load_queue` | `cover_flushed_cached_load_drained` | The response of a flushed cached load arrives and is drained |
| `load_queue` | `cover_cached_response_held` | The router holds a cached response behind a low-BRAM or device response |
| `dispatch` | `cover_store_waits_for_full_sq` | A store waits at dispatch, in either slot, because the store queue is full |
| `dispatch` | `cover_load_waits_for_full_lq` | A load waits at dispatch, in either slot, because the load queue is full |
| `data_mem_request_router` | `cover_flush_cancels_parked_device_read` | A full flush cancels a device read parked before accept |
| `trap_unit` | `cover_memory_order_replay_taken` | A memory-order replay restarts the load at the ROB head |
| `trap_unit` | `cover_interrupt_waits_for_device_read` | An armed interrupt waits while a device read is at the ROB head |
| `trap_unit` | `cover_interrupt_waits_for_amo` | An armed interrupt waits while an AMO is at the ROB head |
| `frost_cache` | `cover_read_takes_waiter_seat` | A read of a line with a pending miss takes a waiter seat |
| `frost_cache` | `cover_read_takes_later_waiter_seat` | A second read joins a miss slot that already has a waiter (the L2) |
| `frost_cache` | `cover_read_waits_for_waiter_seat` | A read waits because every seat of its line's miss slot is taken |
| `frost_cache` | `cover_miss_waits_for_way` | A miss waits because a miss slot owns every way of its set |
| `frost_cache` | `cover_write_merges_into_miss` | A write merges into the pending write-allocate miss of its line |
| `frost_cache` | `cover_fill_waits_for_writeback` | A miss waits to fetch until a writeback of its own line is acknowledged |
| `frost_cache` | `cover_writeback_takes_starvation_turn` | A writeback takes the request register from a pending fill on its starvation turn |
| `frost_cache` | `cover_fill_withheld_by_probe` | A held PROBE_INVAL withholds the fill of a miss on its line (the L1D) |
| `frost_cache` | `cover_probe_waits_for_writeback` | A probe waits for a writeback of its line (the L1D) |
| `frost_cluster_cache` | `cover_demand_read_meets_prefetch` | An L1D read reaches the L2 while the prefetcher's read of the same L2 line is outstanding |
| `line_port_arbiter` | `cover_starved_port_granted` | A port that waited through the starvation limit wins over a request of higher priority |
| `frost_cache` | `cover_write_merge_on_fill` | A store merges into its miss slot on the successful fill-response edge |
| `frost_cache` | `cover_waiter_on_fill` | A reader attaches to its miss slot on the successful fill-response edge |
| `frost_cache` | `cover_fill_retries_tag_lookup` | A fill installation crosses a delayed tag response for the same set and forces a retry |
| `frost_cache` | `cover_read_error_with_waiter` | A failed read fill has an attached reader that must also receive the error |
| `lq_l0_cache` | `cover_dma_invalidation_overrides_fill` | DMA invalidation clears the four indexed dwords while a response fills one of them |
| `lq_l0_cache` | `cover_amo_invalidation_overrides_fill` | AMO invalidation and a response fill target the same dword |
| `lq_l0_cache` | `cover_store_update_displaces_fill` | A store update takes the RAM port from a response fill at another index |
| `dmmu` | `cover_tlb_hit_with_walk_response` | A DTLB hit resolves an operation while a matching walker response arrives |
| `dmmu` | `cover_stale_walk_fault_with_live_op` | A walker fault arrives while a live operation holds a different VPN |
| `dmmu` | `cover_flush_on_walk_response` | Recovery kills the operation on its matching walker-response edge |
| `ptw` | `cover_discard_on_read_accept` | A PTE read is accepted on the edge that discards its walk |
| `ptw` | `cover_discard_on_read_response` | A PTE read response arrives on the edge that discards its walk |
| `ptw` | `cover_interior_pte_read_error` | A PTE read fails after the walker follows a valid parent pointer |
| `trap_unit` | `cover_interrupt_over_memory_replay` | An interrupt takes priority over a pending memory-order replay |
| `trap_unit` | `cover_wfi_wakes_without_enabled_interrupt` | A raw pending source wakes WFI while neither interrupt class is latched |
| `imsic_file` | `cover_msi_reasserts_claimed_identity` | An MSI sets the identity that a same-cycle claim clears |
| `imsic_file` | `cover_msi_over_eip_clear` | An MSI sets a pending bit that a same-cycle CSR write clears |

Only the load queue's unit bench reaches two of them, because the whole SoC
never builds the state they check. For `cover_dma_write_hits_lr_in_flight`,
the coherence port admits a DMA write only when no LR on its line is in
flight, and the load queue holds LR launches on the line until the write is
released. For `cover_staged_load_yields_to_amo`, dispatch allocates
load-queue entries in program order, so a load's older AMOs are already
pending when it is allocated, and a load blocked by one is never staged.

Three cover points can be reached only from their unit benches. The trap
unit's WFI point checks its standalone interface: `cpu_ooo` ties that
interface's start input low and handles WFI in the ROB. In the integrated
core an AMO cannot meet an L0 fill: older loads have responded before the
AMO reaches the ROB head, younger loads wait for its write, its own read
does not fill the L0, and a response whose saved drop flag is set cannot
fill it. The data MMU's hit with a matching walk response checks a
defensive priority: the shared walker serves one request at a time, the
data MMU requests a walk only on a miss, and only a successful data-walk
response installs a DTLB entry.

To add one, write the `cover property` in its module's cover-point block,
or start one at the end of the module, and add a row here.

## CI Integration

The [CI workflow](../.github/workflows/ci.yml) runs these checks in the
pinned Docker image, except the ASIC flow, which runs in its own image:

| Suite | Configurations |
| --- | --- |
| Cocotb applications | BRAM and DDR where supported; the four longest CoreMark-PRO workloads run in jobs of their own and the other five share one |
| Cocotb unit benches, DDR probes, fetch fuzzers, programs on the SRAM macros, OpenSBI smoke | BRAM only: tier-independent or fixed-layout runs |
| Physical address apertures | Software boundary, fetch, translation, DMA, and NIC checks at 1, 64, and 128 GiB; generic synthesis at 1 and 128 GiB |
| Architecture compliance | BRAM and DDR, in groups of extensions; excludes Zifencei on BRAM and F/D on DDR; F and D share three BRAM shards without coverage; the other groups collect coverage |
| riscv-tests | Physical mode in BRAM and DDR, user-level Sv39 tests in DDR, and benchmarks in both; each job runs a group of suites or benchmarks on one Verilator build |
| Torture | BRAM, DDR, and paged DDR |
| TestRIG | Four jobs at the default 1 GiB aperture with new random sequences against Sail, each with 100 per template from the engine's templates and 200 from the A-extension generator; the first also replays the saved counterexamples |
| Ethernet | Standalone MAC/PCS simulation and portable synthesis |
| Tooling | Lint, fast Python tests, synthesis, and formal verification |
| ASIC flow | [OpenROAD](../asic/README.md) from synthesis to GDS on Nangate45, with OpenRAM's SRAM macros, in four chained jobs |
| Linux | Firmware and root filesystem build; QEMU boots with 256 MiB and with 3 GiB to check Linux memory use above 4 GiB |
| Coverage | One job merges the coverage of the simulating jobs into a report |

The software aperture tests also have registry entries for 2, 4, 8, 16,
and 32 GiB, available through `./scripts/frost.py cocotb <test_name>`.
The AXI bridge unit tests cover all eight power-of-two capacities in CI.
The standalone `test_ddr_width_config.sv` and `test_ptw_high_addr.sv`
harnesses are not registered with the test runners or invoked by CI.

Every job that simulates the whole SoC draws its own DDR model timing:
the workflow sets `FROST_DDR_MODEL_SEED` from the run ID, the job, and its
matrix index. A failing test's output names the draw, and rerunning the job
repeats it.

In the BRAM job of the CoreMark shard, the `coremark` test also records a
calibration trace of CoreMark's timed region for the performance model in
[`perf-modeling/`](../perf-modeling/README.md#calibration-check-in-ci), and
a step after the tests checks it against the model. The step fails if the
trace breaks its contract, lacks a required event class, or gives an IPC that
differs from the model's by more than the tolerance in
`perf-modeling/calibration/ci_baseline.json`, and it prints the figures and
deltas either way.

The simulating jobs build with `FROST_COVERAGE=1`, except the CoreMark-PRO
workloads, the F and D architecture-test jobs, and the riscv-tests
benchmarks: long runs of compute code, which line coverage would slow by about
a third while adding little that the other jobs miss. The unit-bench job also
sets `FROST_COVERAGE_TOGGLE=1`. Toggle coverage stays out of the whole-SoC
jobs, which the full set would slow about sixfold, and the control set is
for local runs. Each job merges its files into a `coverage-job-*` artifact,
and the Coverage Report job merges those into the
`coverage-report` artifact (the [report](#coverage) with annotated sources)
and shows its summary on the job's page, after the other jobs finish, failed
ones included.

The workflow has the exact job filters. The named real-program shards select
applications by name, and the "Runtime and other" shard runs every
application they don't list. The shards are sized so that each job takes
about an hour or less on a CI runner, except the jobs of the longest
CoreMark-PRO workloads, which run one workload each. When you add an
application to a named shard or remove one, update the "Runtime and other"
exclusion list to match, or the application will run twice or not at all. To
see what a filter selects without running it:

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
