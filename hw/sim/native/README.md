# Native RTL Simulation

`hw/sim/native` compiles the full `frost` SystemVerilog SoC from
[`hw/rtl/frost.f`](../../rtl/frost.f) into a standalone C++ Verilator executable
(`frost-native`) with no Python or VPI layer in the simulation loop.

`frost-native` instantiates `frost` with the default parameters of
[`tests/Makefile`](../../../tests/Makefile): the two-wide out-of-order RV64GCB
processor, instruction and data MMUs, L0 load-queue cache, coherent L1
instruction and data caches, shared L2 coherence home, 256 KiB of on-chip BRAM,
behavioral AXI memory model, UART, CLINT timer, APLIC and IMSIC interrupt
controllers, memory error unit, and 10 Gigabit Ethernet subsystem.
[`main.cpp`](main.cpp) initializes the idle ports and reset synchronizers to
match `prepare_program_start` in
[`verif/cocotb_tests/test_real_program.py`](../../../verif/cocotb_tests/test_real_program.py),
loads the compiled `sw.mem`, `sw64.mem`, and `sw_ddr.mem` images at time zero
through the RTL `$readmemh` blocks, drives the clocks and cold-reset sequence,
and writes UART bytes to standard output as the CPU produces them.

[`frost_native.vlt`](frost_native.vlt) exposes only the six internal signals
that [`main.cpp`](main.cpp) accesses: the CPU UART write strobe and byte, three
reset-synchronizer registers, and the reorder buffer's retirement-log file
descriptor. Keeping the rest of the hierarchy internal lets Verilator inline
and partition combinational and sequential logic across C++ translation units
without VPI signal tables.

`frost-native` matched the cocotb bench cycle for cycle on `hello_world` and
CoreMark in both tiers (unseeded behavioral AXI memory model). Current recorded
cycle counts, CoreMark tick counts, and UART digests live in
[`exactness_baseline.json`](exactness_baseline.json), which `--update-baseline`
regenerates from unseeded cocotb runs; CI checks BRAM and DDR `hello_world` and
BRAM CoreMark against that file alongside a live cocotb BRAM `hello_world` run.

Both [`tests/Makefile`](../../../tests/Makefile) (`TOPLEVEL=frost`) and
`hw/sim/native/Makefile` (`ASSERTIONS=1`, the default) compile
[`hw/sim/sim_assertions.cpp`](../sim_assertions.cpp) with
`--assert +define+FROST_SIM_ASSERTIONS`, start with runtime assertions disabled
(`+verilator+noassert` in `tests/Makefile`; `VerilatedContext::assertOn(false)`
before model construction in [`main.cpp`](main.cpp)), and arm them at the same
cold-reset boundary by calling `frost_sim_assertions_enable()` right after the
18th rising edge of `i_clk` (rising edge `17`, after `i_power_on_rst` has pulsed
across rising edges `0..7` and `i_clk_div4` has taken its fifth post-release
edge, two `i_clk` cycles before `i_rst_n` releases on rising edge `19`), unless
`--no-assert` or `+verilator+noassert` is passed.

Remaining build and runtime differences from [`tests/Makefile`](../../../tests/Makefile)
and [`tests/test_run_cocotb.py`](../../../tests/test_run_cocotb.py) for the
`frost` top level:

- `hw/sim/native/Makefile` builds a C++ executable (`--cc`, `--exe`, `--MMD`,
  `-o frost-native`, linking `main.cpp` alongside `hw/sim/sim_assertions.cpp`)
  with selective signal visibility in [`frost_native.vlt`](frost_native.vlt),
  whereas cocotb's `Makefile.verilator` builds `--vpi --public-flat-rw -o Vtop`
  with `verilator.cpp`, `hw/sim/sim_assertions.cpp`, and
  `-lcocotbvpi_verilator`.
- `hw/sim/native/Makefile` passes `-O3` to Verilator, whereas `tests/Makefile`
  leaves Verilator at its default HDL optimization level.
- `hw/sim/native/Makefile` passes `--threads $(THREADS)` (and
  `-Wno-UNOPTTHREADS` when `THREADS` is not `1`), whereas `tests/Makefile` runs
  single-threaded without `--threads`.
- `ASSERTIONS=1` (the default) matches `tests/Makefile` by passing
  `--assert +define+FROST_SIM_ASSERTIONS`; setting `ASSERTIONS=0` omits both
  flags and leaves runtime assertions disabled for the whole run, whereas
  `tests/Makefile` always compiles `TOPLEVEL=frost` with them and passes
  `+verilator+noassert` in `COCOTB_PLUSARGS` for initial startup.
- When `SAVABLE=1`, `hw/sim/native/Makefile` passes `--savable`, which
  `tests/Makefile` does not use.
- `hw/sim/native/Makefile` passes `-CFLAGS` (`-march=native`, or
  `-march=x86-64` when `PORTABLE=1`, `-std=c++17 -Wall -Wextra`,
  `-DFROST_COMPILED_THREADS`, and assertion/savable defines), compiles
  `Vtop.mk` with `OPT_FAST=-O3`, `OPT_SLOW=-O0`, and `OPT_GLOBAL=-O2`, and
  links `libstdc++`, `libgcc`, and `libatomic` statically when
  `STATIC_RUNTIME=1`.
- One `frost-native` elaboration uses the `tests/Makefile` default parameters
  across applications, whereas the `hello_world` entry in
  `tests/test_run_cocotb.py` passes `-GCLK_FREQ_HZ=3686400` to check serial TX
  pin timing.
- `frost-native` loads `sw.mem`, `sw64.mem`, and `sw_ddr.mem` at time zero via
  the RTL `$readmemh` `initial` blocks and steps `i_power_on_rst` across rising
  edges `0..7` in C++, whereas cocotb steps through `ReadWrite` and 8 reset
  edges and loads memory after cold reset through `sim_load_image` and a Python
  instruction-memory predecode loader.
- `frost-native` fixes the behavioral AXI memory model latency at
  `DDR_MODEL_LATENCY=80` and uses deterministic power-up state (matching
  unseeded local cocotb runs), whereas CI cocotb jobs draw per-job memory
  timing and startup seeds from `FROST_DDR_MODEL_SEED` and
  `FROST_RANDOM_START_SEED`.

## Running Applications

From the repository root, [`scripts/frost.py`](../../../scripts/frost.py)
compiles the RISC-V application, builds `frost-native` inside the `frost`
Docker image if needed, and runs the simulation:

```bash
./scripts/frost.py native hello_world
./scripts/frost.py native coremark --threads 4
./scripts/frost.py native hello_world --mem-config ddr
./scripts/frost.py native coremark --mem-config ddr --threads 4
```

To run another bare-metal application, pass its name from
[`sw/apps/`](../../../sw/apps/) (any target supported by
[`sw/apps/compile_app.py`](../../../sw/apps/compile_app.py)):

```bash
./scripts/frost.py native isa_test --threads 4
./scripts/frost.py native directed_traps
./scripts/frost.py native ddr_heap_test --mem-config ddr --threads 4
./scripts/frost.py native freertos_demo --max-cycles 2000000
```

`stage-app` compiles the application for `bram` or `ddr` and copies `sw.mem`,
`sw64.mem`, and `sw_ddr.mem` into
`hw/sim/native/sim_build/apps/<app>_<mem_config>/`. All build directories stay
under `hw/sim/native/sim_build`, separate from `tests/sim_build`.

For `hello_world`, the runner stops 10,000 drain cycles after the UART prints
`Hello, world!`, matching the cocotb bench, and reports both the stop-marker
cycle and the drain window in the summary. For other applications, the runner
stops as soon as the UART prints `<<PASS>>`, exits nonzero if the UART prints
`<<FAIL>>`, an HDL assertion fails, or HDL executes `$finish`, and stops with a
nonzero status if `--max-cycles` is reached first (default 5,000,000 cycles; `0`
disables the cycle limit). Applications with a custom UART completion string can
be run through `make -C hw/sim/native` inside the `frost` image:

```bash
./scripts/frost.py run make -C hw/sim/native run \
    APP=hello_world MEM_CONFIG=bram THREADS=4 \
    STOP_MARKER="Hello, world!" DRAIN_CYCLES=10000
```

| Make / CLI variable | Default | Meaning |
| --- | --- | --- |
| `APP` | `hello_world` | Application name passed to `sw/apps/compile_app.py` |
| `MEM_CONFIG` / `--mem-config` | `bram` | Memory tier (`bram` or `ddr`) |
| `THREADS` / `--threads` | `1` (or compiled partition count when invoking `frost-native` directly) | Verilator partition and worker thread count |
| `MAX_CYCLES` / `--max-cycles` | `5000000` | Cycle limit (`0` runs without a cycle limit) |
| `STOP_MARKER` | `<<PASS>>` (`Hello, world!` for `hello_world`) | UART substring that marks completion; empty string runs until `MAX_CYCLES` (HDL `$finish` still exits nonzero) |
| `DRAIN_CYCLES` | `0` (`10000` for `hello_world`) | Extra cycles simulated after `STOP_MARKER` appears |
| `ASSERTIONS` | `1` | Compile SystemVerilog assertions (`1` or `0`) |
| `SAVABLE` | `0` | Compile Verilator `--savable` checkpoint support (`1` or `0`) |
| `PORTABLE` | `0` | Use baseline `-march=x86-64` (`1`) instead of `-march=native` (`0`) |
| `STATIC_RUNTIME` | `0` | Link `libstdc++`, `libgcc`, and `libatomic` statically (`1` or `0`) |
| `EXTRA_RUN_ARGS` | empty | Extra flags forwarded to `frost-native` (`--uart-out`, `--summary-json`, `--save`, `--restore`, `--retire-trace`, `--no-assert`) |

Verilator embeds the thread partition count into each generated model
(`Vtop::threads()`), so `Makefile` keys each build directory by thread count,
assertion mode, savable mode, target architecture, and runtime linkage, and
records the Verilator version and compiler flags in `.build-config`.

## What the Numbers Mean

At the end of a run, `frost-native` writes a summary block to standard error
(leaving standard output clean for raw UART bytes):

```text
--- FROST RTL simulation summary ---
Simulated cycles : <cycles>
CoreMark ticks   : <ticks>
RTL assertions   : enabled after reset
Wall time        : <seconds> s
Simulation speed : <rate> cycles/s (threads: <N>)
```

For runs with a post-marker drain such as `hello_world`, `Simulated cycles`
breaks out the active cycles before the stop marker and the drain window
(`<total> (<active> to stop marker + 10,000 drain)`). Current baseline cycle
and tick counts for `hello_world` and `coremark` in both memory tiers are
stored in [`exactness_baseline.json`](exactness_baseline.json).

| Summary field | Meaning |
| --- | --- |
| `Simulated cycles` | Total rising edges of `i_clk` from time zero, including the 20-cycle cold reset sequence before `i_rst_n` releases (plus any post-marker drain cycles, and advanced cycles when resuming from a checkpoint) |
| `CoreMark ticks` | Value of `Total 64-bit ticks` printed by CoreMark, read from the simulated CPU's `mcycle` CSR around the timed CoreMark loop without C startup or UART report printing |
| `RTL assertions` | Runtime assertion state (`enabled after reset` in checked runs once cold reset completes, `disabled` when `--no-assert` or `+verilator+noassert` is passed, `disabled (not compiled)` when built with `ASSERTIONS=0`) |
| `Wall time` | Host elapsed time spent in the simulation loop, excluding software and Verilator compilation |
| `Simulation speed` | Simulated clock cycles per host second (`Simulated cycles` divided by `Wall time`, or advanced cycles divided by `Wall time` after `--restore`) |

On every simulated clock cycle, host software evaluates the combinational and
sequential logic of the SoC in C++, depending on host processor, thread count,
and memory-tier activity; RTL simulation is far slower than hardware.

Bare-metal CoreMark prints `Baremetal Coremark 1 iterations, assuming 20000 Hz
FPGA clock` because simulation builds compile CoreMark with `ITERATIONS=1` and
a nominal 20 kHz constant to satisfy CoreMark's minimum-time check in a single
iteration. The printed `Total time`, `Iterations/Sec`, and `CoreMark 1.0` score
lines are not meaningful at simulation speed; `CoreMark ticks` (`Total ticks`)
is the simulated CPU's cycle count for that iteration.

## Standalone Demo Image

[`demo/Dockerfile`](../../../demo/Dockerfile) packages checked, portable
`frost-native` binaries (`1`, `4`, and `8` threads) and prebuilt `hello_world`
and `coremark` images (`bram` and `ddr`) into a small `ubuntu:26.04` container
with no compiler, Python runtime, or repository checkout inside the runtime
stage. The demo runs bare-metal programs only: Linux boots in this simulator,
but reaching a shell prompt takes tens of millions of simulated cycles and each
shell command then takes minutes, so an interactive Linux session is not
offered as part of the demo.

Building `frost-demo:local` requires the local `frost` development image
(`docker build -t frost .`) and an initialized CoreMark submodule:

```bash
git submodule update --init --recursive sw/apps/coremark/coremark
docker build -f demo/Dockerfile -t frost-demo:local .
docker run --rm -it frost-demo:local
```

By default, [`demo/run_demo.sh`](../../../demo/run_demo.sh) selects 4 simulator
threads when at least 4 effective CPUs are available after CPU affinity and
cgroup `--cpus` limits (`1` otherwise), runs `hello_world` on the RTL, explains
the single-iteration CoreMark output, and runs CRC-checked `coremark`. Options
select the thread partition, memory tier, or workload:

```bash
docker run --rm -it frost-demo:local --threads 8
docker run --rm -it frost-demo:local --threads 1 --app hello_world
docker run --rm -it frost-demo:local --mem-config ddr --app coremark
docker run --rm frost-demo:local --help
```

The demo binaries are compiled with `ASSERTIONS=1`, `PORTABLE=1`
(`-march=x86-64` across all C++ files, with `-O3` on hot model files and C++
runner sources `main.cpp` and `sim_assertions.cpp`, `-O0` on cold/initializer
files, and `-O2` on the Verilator runtime), and `STATIC_RUNTIME=1` so RTL
checks stay enabled and `libstdc++`, `libgcc`, and `libatomic` are linked
statically for baseline 64-bit x86 Linux hosts.

## Assertions, Retirement Trace, and Checkpoints

| Mechanism | Behavior |
| --- | --- |
| Assertions (`ASSERTIONS=1`) | Default for `hw/sim/native/Makefile`, `./scripts/frost.py native`, `demo/Dockerfile`, and `tests/test_native_sim.py`. Verilator compiles immediate and concurrent SystemVerilog assertions (`--assert +define+FROST_SIM_ASSERTIONS`) and links [`hw/sim/sim_assertions.cpp`](../sim_assertions.cpp), matching `tests/Makefile` (`TOPLEVEL=frost`). `main.cpp` starts every run with `VerilatedContext::assertOn(false)` before model construction and time-zero evaluation so uninitialized state during cold reset cannot trip assertions, then calls `frost_sim_assertions_enable()` after the 18th rising edge of `i_clk` (rising edge `17`, matching `verif/cocotb_tests/test_real_program.py` and `verif/cocotb_tests/sim_assertions.py`), two `i_clk` cycles before `i_rst_n` releases on cycle 20. Pass `--no-assert` or `+verilator+noassert` to keep runtime assertions disabled in a checked build; in an `ASSERTIONS=0` build, assertions are neither compiled nor enabled. |
| Retirement trace | Outside synthesis, `reorder_buffer.sv` opens `retire_trace.log` in an `initial` block and calls `$fwrite(retire_trace_fd, ...)` on each retired instruction. `main.cpp` constructs the model inside a private temporary staging directory, closes `retire_trace_fd` and sets it to `0` before cycle 0 (for descriptor `0`, Verilator discards `$fwrite` output without writing a file), and removes the temporary directory. No `retire_trace.log` is written unless `--retire-trace <path>` is passed; when combined with `--restore`, the trace file is opened after checkpoint deserialization. |
| Checkpoints (`SAVABLE=1`) | Building with `SAVABLE=1` enables `--save <path>`, `--save-at <cycle>`, and `--restore <path>`. A checkpoint stores the cycle count, simulation time, stop-marker state, accumulated UART bytes, and the serialized `Vtop` model (including BRAM and behavioral AXI memory contents). `--restore <path>` resumes simulation from that cycle without needing `.mem` files on disk. If `--save-at <cycle>` is not reached before simulation stops, `frost-native` exits nonzero. |

Example checkpoint save and restore run inside the `frost` image:

```bash
./scripts/frost.py run make -C hw/sim/native build SAVABLE=1 THREADS=4
./scripts/frost.py run make -C hw/sim/native stage-app APP=coremark MEM_CONFIG=bram
./scripts/frost.py run hw/sim/native/sim_build/model_t4_a1_s1_host/frost-native \
    --mem-dir hw/sim/native/sim_build/apps/coremark_bram \
    --threads 4 --max-cycles 150000 --stop "" \
    --save /tmp/coremark_150k.ckpt --save-at 150000
./scripts/frost.py run hw/sim/native/sim_build/model_t4_a1_s1_host/frost-native \
    --restore /tmp/coremark_150k.ckpt --threads 4 --stop "<<PASS>>"
```

## Verification, Baseline Regeneration, and Portability

[`tests/test_native_sim.py`](../../../tests/test_native_sim.py) checks that
`hw/sim/native/Makefile` matches `tests/Makefile`'s `frost` top-level
parameters and differs from `tests/Makefile`'s Verilator flags only by the
documented native runner options, checks the baseline records in
[`exactness_baseline.json`](exactness_baseline.json), exercises RTL assertion,
HDL `$finish`, and split-marker failure paths, builds the checked native model,
and verifies that `hello_world` and `coremark` in both `bram` and `ddr` match
the recorded cocotb values in UART byte count, UART SHA-256 digest, simulated
cycle count, and CoreMark ticks, as well as checkpoint save/restore
equivalence.

In CI, the `test-native` job in
[`.github/workflows/ci.yml`](../../../.github/workflows/ci.yml) runs one live
unseeded cocotb BRAM `hello_world` simulation against
`exactness_baseline.json`, builds the checked 4-thread portable static binary
(`ASSERTIONS=1 SAVABLE=0 PORTABLE=1 STATIC_RUNTIME=1`, or 1 thread when fewer
than 4 CPUs are available), checks `readelf -d`, and runs BRAM and DDR
`hello_world`, BRAM `coremark`, and `demo/run_demo.sh` (`--app hello_world`).
CI does not build `demo/Dockerfile` or the runtime image itself, the 1- and
8-thread demo binaries, DDR `coremark`, or `SAVABLE=1` checkpoints; `--all`
(and the `slow` pytest target) covers DDR `coremark` and checkpoints locally.

When an intentional RTL or software change alters cycle counts, tick counts, or
UART output, regenerate `exactness_baseline.json` from unseeded cocotb runs
with:

```bash
./scripts/frost.py run python3 tests/test_native_sim.py --update-baseline
```

Portability scope:

- Tested on x86-64 Linux inside Docker (`frost` development container and
  `frost-demo:local` runtime container on Ubuntu 26.04).
- Not tested natively outside Docker, on `linux/arm64` hosts, on macOS (Docker
  Desktop Linux VMs or Apple Silicon emulation), or on Windows / WSL2.
