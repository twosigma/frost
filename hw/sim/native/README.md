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

[`frost_native.vlt`](frost_native.vlt) exposes only the internal signals that
[`main.cpp`](main.cpp) accesses: the CPU UART write strobe and byte, three
reset-synchronizer registers, the reorder buffer's retirement-log file
descriptor, and, for `--stats`, four read-only activity signals (below).
Keeping the rest of the hierarchy internal lets Verilator inline and partition
combinational and sequential logic across C++ translation units without VPI
signal tables.

`frost-native` matches unseeded cocotb runs of the same tree cycle for cycle and
byte for byte on `hello_world` and CoreMark in both memory tiers. On every CI
run, `test-native` checks that a live cocotb BRAM `hello_world` run and the
native run agree in cycles and UART bytes, compares DDR `hello_world` and
BRAM CoreMark cycles, ticks, and UART bytes against live cocotb runs, and
checks each program's pass and summary conditions without stored cycle or
tick counts. `test-demo-image` builds `demo/Dockerfile` and runs the packaged
demo container. Running `python3 tests/test_native_sim.py --all` locally
compares all four `hello_world` and CoreMark cases (`bram` and `ddr`) directly
against live unseeded cocotb runs of the same tree.

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
  with selective signal visibility in [`frost_native.vlt`](frost_native.vlt)
  and retirement-trace support compiled in, whereas `tests/Makefile` builds
  `--vpi -o Vtop` with `verilator.cpp`, `hw/sim/sim_assertions.cpp`,
  `-lcocotbvpi_verilator`, `+define+FROST_NO_RETIRE_TRACE` (unless
  `FROST_RETIRE_TRACE=1`), and
  [`frost_cocotb_visibility.vlt`](../frost_cocotb_visibility.vlt) plus
  `-fico-change-detect` (or `--public-flat-rw` when coverage, the
  hang probe, or `FROST_FULL_VISIBILITY=1` are selected).
- `hw/sim/native/Makefile` passes `-O3` to Verilator, whereas `tests/Makefile`
  leaves Verilator at its default HDL optimization level.
- `hw/sim/native/Makefile` passes `--threads $(THREADS)` (and
  `-Wno-UNOPTTHREADS` when `THREADS` is not `1`), whereas `tests/Makefile`
  defaults to single-threaded execution and passes `--threads` with
  `-Wno-UNOPTTHREADS` when `FROST_VERILATOR_THREADS` exceeds `1` in
  selective-visibility `frost` builds.
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

The simulation thread writes and flushes each UART byte to standard output
before testing for the complete stop marker. The summary follows the
configured drain window.

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
| `EXTRA_RUN_ARGS` | empty | Extra flags forwarded to `frost-native` (`--uart-out`, `--summary-json`, `--save`, `--restore`, `--retire-trace`, `--stats`, `--stats-interval`, `--regions`, `--no-assert`) |

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
(`<total> (<active> to stop marker + 10,000 drain)`).

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
`frost-native` binaries (`1`, `4`, and `8` threads), the presenter `frost-show`
([`demo/frost_show.cpp`](../../../demo/frost_show.cpp)), prebuilt `hello_world`
and `coremark` images (`bram` and `ddr`), the ray tracer
([`sw/apps/raytrace`](../../../sw/apps/raytrace), 76x44 and 24x12 pixels) into a small `ubuntu:26.04` container with
no compiler, Python runtime, or repository checkout inside the runtime stage. The demo runs bare-metal programs only: Linux boots in this simulator,
but reaching a shell prompt takes tens of millions of simulated cycles and each
shell command then takes minutes, so an interactive Linux session is not
offered as part of the demo.

Building `frost-demo:local` requires the local `frost` development image
(`docker build -t frost .`) and an initialized CoreMark submodule:

```bash
git submodule update --init --recursive sw/apps/coremark/coremark
docker build -f demo/Dockerfile -t frost-demo:local .
docker run --rm -it -e COLORTERM frost-demo:local
```

[`demo/run_demo.sh`](../../../demo/run_demo.sh) selects 4 simulator threads
when at least 4 effective CPUs are available after CPU affinity and cgroup
`--cpus` limits (`1` otherwise). By default it starts `frost-show`, which runs
two programs in BRAM, each in its own `frost-native` process with `--stats`:

1. The ray tracer (a glossy red sphere and a glossy blue sphere on a cream and teal
   tiled floor under a sunset, one ray a pixel, 8 bits a color channel, in the scene
   header `scene_sunset.inc`) draws its 76x44-pixel picture in the terminal as the
   simulated CPU sends it over the UART: a coarse pass of one pixel in every
   4x4 block first, redrawn in place row by row in full detail when the
   terminal is tall enough, and checks the frame's CRC-32 against its host
   reference. On a terminal a status line under the
   picture, redrawn in place and cut to the terminal's width, shows the pixel
   rows received, an estimate of the time left from the measured simulation
   rate, and, over a recent window of cycles, instructions per cycle, the share
   of branches predicted correctly, reorder-buffer occupancy, and cycles that
   retired two instructions. If the rate measured in the first seconds means
   the full picture would take more than six minutes, `frost-show` says so,
   stops it, and runs the small picture instead; `--full` keeps the full
   picture.
2. CoreMark runs one iteration; once CoreMark has validated its results,
   `frost-show` prints the iteration count, that every CRC was correct, and
   the cycle count by CoreMark's own tick count. It computes no score: the
   published score is in the top-level README.

A table of what the core did in each program (instructions, cycles,
instructions per cycle, dual-retirement share, average reorder-buffer
occupancy of the 32 entries as built, branches and the share predicted
correctly) closes the run. It counts the ray tracer's rendering (without
start-up and without sending the picture's characters) and CoreMark's timed
loop, whose cycles are the ones CoreMark reports; the totals for the whole
programs stay in the lines above and below it. Every figure comes from the
run itself: the UART output or the `--stats` counters. A
failed self-check ends the run with exit status 1 and one sentence.
`frost-show` draws in 24-bit color or in the 256-color palette (the nearest of
the 6x6x6 cube and the gray ramp in CIELAB, no dithering). It decides only from
these, in order: `--truecolor` or `--256` (also accepted by `run_demo.sh`;
`--color auto|truecolor|256|none` is the long form); `NO_COLOR`; the
`COLORTERM` variable (`truecolor` or `24bit`, forwarded into the container by
`docker run -e COLORTERM`); a `TERM` that names direct color (such as
`xterm-direct`); otherwise 256 colors, and on a terminal it then prints one
line under the picture saying how to get full color (not with `--256`). It
never queries the terminal and never changes the terminal's modes. It prints
plain text with no status line, cursor or erase commands, and no color, when
`NO_COLOR` is set (to any non-empty value), `TERM` is not one of the known
cursor-addressable types (xterm and relatives, screen, tmux, rxvt, vt100 and
later, linux, alacritty, kitty, foot, wezterm, ghostty, konsole, gnome, st,
iterm; the terminfo database is not consulted), or the output is not a
terminal. A picture wider than the terminal is scaled down by
a whole factor (averaging blocks of pixels) and all prose is wrapped to the
terminal's width; below the least width a picture can be drawn at (39 columns
for 76x44) one sentence replaces it. A run counts as passed only when the
simulator exited 0, no failure marker appeared and every CoreMark CRC matched;
otherwise `frost-show` says the run failed and exits 1. `--quick` runs
the 24x12 picture instead. `--raw` runs `hello_world`
and the single-iteration CoreMark with their unfiltered UART output and the
runner's summaries, and `--app` runs one of them; `--mem-config` and
`--max-cycles` apply to those:

```bash
docker run --rm -it -e COLORTERM frost-demo:local --quick
docker run --rm -it -e COLORTERM=truecolor frost-demo:local --threads 8
docker run --rm -it frost-demo:local --256
docker run --rm -it frost-demo:local --raw
docker run --rm -it frost-demo:local --threads 1 --app hello_world
docker run --rm -it frost-demo:local --mem-config ddr --app coremark
docker run --rm frost-demo:local --help
```

With `--raw` or `--app`, the entry point joins simulator standard error to
standard output before launching the simulator. UART bytes and summaries share
one container output pipe, so log readers receive the complete UART marker
before the summary.

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
| Retirement trace | Outside synthesis and when `FROST_NO_RETIRE_TRACE` is undefined, `reorder_buffer.sv` opens `retire_trace.log` in an `initial` block and calls `$fwrite(retire_trace_fd, ...)` on each retired instruction. `main.cpp` constructs the model inside a private temporary staging directory, closes `retire_trace_fd` and sets it to `0` before cycle 0 (for descriptor `0`, Verilator discards `$fwrite` output without writing a file), and removes the temporary directory. No `retire_trace.log` is written unless `--retire-trace <path>` is passed; when combined with `--restore`, the trace file is opened after checkpoint deserialization. |
| Activity counters (`--stats <path>`) | Once per `i_clk` cycle after reset releases, `main.cpp` adds up `cpu_ooo`'s retired-instruction, retired-branch and misprediction counts (the inputs of HPM counters 10, 3 and 4) and the reorder buffer's occupancy (`count`). These are existing RTL signals; `frost_native.vlt` makes them readable and nothing in the RTL changes for them. Every `--stats-interval` cycles (default 10,000) and when the run ends it writes one line of cumulative counts: `cycle`, `instructions`, `branches`, `mispredicts`, `rob_occupancy_sum`, `retired0`, `retired1`, `retired2` (cycles that retired zero, one, or two or more instructions), `uart_bytes`, and `final=1` on the last line. The counts start at zero in every process, after `--restore` too. With `--regions <file>` the same counts are also kept over one region of the run and written as `region_cycles`, `region_instructions`, `region_branches`, `region_mispredicts`, `region_rob_occupancy_sum` and `region_retired0` to `region_retired2`, together with `rob_depth` (the reorder buffer's size). The file holds `start <pc>` (counting begins after the cycle in which that PC retires), `end <pc>` (the cycle in which that PC retires is the last one counted; a start and an end that retire in the same cycle bound an empty region), `skip <lo> <hi>` (cycles that end in the retirement of an instruction in the range are left out, the stall before an instruction being charged to it) and `rob_depth <N>`. `frost_native.vlt` also exposes the reorder buffer's head PCs for this (sampled one clock before the registered retirement count they are charged to, so the width, the branch events and the PCs that select the region all come from the same retirement; when the two instructions of a pair fall on different sides of a skipped range, two branch events count one and a single event goes with the first); the program and its timing are not touched. [`demo/make_regions.py`](../../../demo/make_regions.py) writes the file from a program's ELF symbols at image build. The demonstration image's `frost-show` reads these lines for its status line and closing table. |
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

## Verification and Portability

[`tests/test_native_sim.py`](../../../tests/test_native_sim.py) checks that
`hw/sim/native/Makefile` matches `tests/Makefile`'s `frost` top-level
parameters and differs from `tests/Makefile`'s Verilator flags only by the
documented native runner options, exercises RTL assertion, reset-arming, HDL
`$finish`, split success and failure markers, and UART ordering through a
delayed container log relay, and provides two simulation modes
with no stored cycle counts, tick counts, or output hashes:

- **CI mode (`--ci`, run by `test-native` in
  [`.github/workflows/ci.yml`](../../../.github/workflows/ci.yml)):** runs live
  unseeded cocotb simulations of BRAM and DDR `hello_world` and BRAM `coremark`,
  builds the checked 4-thread portable static binary (`ASSERTIONS=1 SAVABLE=0
  PORTABLE=1 STATIC_RUNTIME=1`, or 1 thread when fewer than 4 CPUs are
  available), checks `readelf -d`, verifies cycle-for-cycle, tick-for-tick, and
  byte-for-byte UART equality between the native runner and those three live
  cocotb runs alongside each program's own pass conditions (`Frost: Hello,
  world!`; CoreMark's `2K performance run` banner, all five CRC lines, `"Correct
  operation validated."`, `<<PASS>>`, and a present non-zero tick count) and
  summary invariants, and exercises `demo/run_demo.sh` (`--app hello_world`).
  Alongside `test-native`, `test-demo-image` builds `demo/Dockerfile` into
  `frost-demo:local` and runs the quick demonstration (`--quick`, checking
  its self-check sentences), the unfiltered two-program run (`--raw`, with
  CoreMark's CRC lines) and a single-application invocation (`--threads 1
  --app hello_world`). Neither CI job runs DDR `coremark` or `SAVABLE=1` checkpoints.
- **Full comparison mode (`--all`, the CLI default and the `slow` pytest
  target):** runs live unseeded cocotb simulations of `hello_world` and
  `coremark` in both `bram` and `ddr`, builds the checked native runner,
  verifies cycle-for-cycle, tick-for-tick, and byte-for-byte UART equality
  against those four live cocotb runs alongside the program and summary
  invariants, and verifies `SAVABLE=1` mid-execution and mid-drain checkpoint
  save and restore against the live BRAM `hello_world` run:

```bash
./scripts/frost.py run python3 tests/test_native_sim.py --all
```

Portability scope:

- Tested on x86-64 Linux inside Docker (`frost` development container and
  `frost-demo:local` runtime container on Ubuntu 26.04).
- Not tested natively outside Docker, on `linux/arm64` hosts, on macOS (Docker
  Desktop Linux VMs or Apple Silicon emulation), or on Windows / WSL2.
