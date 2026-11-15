# Native RTL Simulation

`hw/sim/native` compiles the full `frost` SystemVerilog SoC from
[`hw/rtl/frost.f`](../../rtl/frost.f) into a standalone C++ Verilator executable
(`frost-native`) with no Python or VPI layer in the simulation loop.

`frost-native` instantiates `frost` with the same parameters as the program
benches in [`tests/Makefile`](../../../tests/Makefile): the two-wide
out-of-order RV64GCB processor, instruction and data MMUs, L0 load-queue cache,
coherent L1 instruction and data caches, shared L2 coherence home, 256 KiB of
on-chip BRAM, behavioral cached DDR4, UART, CLINT timer, APLIC and IMSIC
interrupt controllers, memory error unit, and 10 Gigabit Ethernet subsystem.
[`main.cpp`](main.cpp) drives the clocks and reset sequence identically to
`prepare_program_start` in
[`verif/cocotb_tests/test_real_program.py`](../../../verif/cocotb_tests/test_real_program.py),
loads the compiled `sw.mem`, `sw64.mem`, and `sw_ddr.mem` images, and writes
UART bytes to standard output as the CPU produces them.

[`frost_native.vlt`](frost_native.vlt) exposes only the six internal signals
that [`main.cpp`](main.cpp) accesses: the CPU UART write strobe and byte, three
reset-synchronizer registers, and the reorder buffer's retirement-log file
descriptor. Keeping the rest of the hierarchy internal lets Verilator inline
and partition combinational and sequential logic across C++ translation units
without VPI signal tables.

Because the RTL source list, module parameters, program images, and clock and
reset edges match the cocotb program bench, simulation is cycle-exact with
[`tests/test_run_cocotb.py`](../../../tests/test_run_cocotb.py): UART output
bytes, total simulated cycles, and benchmark tick counts match across both
memory configurations (`bram` and `ddr`). On on-chip BRAM, `hello_world`
finishes in 11,792 cycles and 1-iteration `coremark` finishes in 333,130 cycles
(223,556 CoreMark ticks). On cached DDR, `hello_world` finishes in 12,821
cycles and 1-iteration `coremark` finishes in 410,310 cycles (285,889 CoreMark
ticks).

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
`Hello, world!`, matching the cocotb bench. For other applications, the runner
stops as soon as the UART prints `<<PASS>>`, exits nonzero if the UART prints
`<<FAIL>>`, and stops with a nonzero status if `--max-cycles` is reached first
(default 5,000,000 cycles; `0` disables the cycle limit). Applications with a
custom UART completion string can be run through `make -C hw/sim/native` inside
the `frost` image:

```bash
./scripts/frost.py run make -C hw/sim/native run \
    APP=hello_world MEM_CONFIG=bram THREADS=4 \
    STOP_MARKER="Hello, world!" DRAIN_CYCLES=10000
```

| Make / CLI variable | Default | Meaning |
| --- | --- | --- |
| `APP` | `hello_world` | Application name passed to `sw/apps/compile_app.py` |
| `MEM_CONFIG` / `--mem-config` | `bram` | Memory tier (`bram` or `ddr`) |
| `THREADS` / `--threads` | `1` | Verilator partition and worker thread count |
| `MAX_CYCLES` / `--max-cycles` | `5000000` | Cycle limit (`0` runs without a cycle limit) |
| `STOP_MARKER` | `<<PASS>>` (`Hello, world!` for `hello_world`) | UART substring that marks completion; empty string runs until `MAX_CYCLES` |
| `DRAIN_CYCLES` | `0` (`10000` for `hello_world`) | Extra cycles simulated after `STOP_MARKER` appears |
| `ASSERTIONS` | `1` | Compile SystemVerilog assertions (`1` or `0`) |
| `SAVABLE` | `0` | Compile Verilator `--savable` checkpoint support (`1` or `0`) |
| `PORTABLE` | `0` | Use baseline `-march=x86-64` (`1`) instead of `-march=native` (`0`) |
| `EXTRA_RUN_ARGS` | empty | Extra flags forwarded to `frost-native` (`--uart-out`, `--summary-json`, `--save`, `--restore`, `--retire-trace`, `--no-assert`) |

Verilator embeds the thread partition count into each generated model
(`Vtop::threads()`), so `Makefile` keys each build directory by thread count,
assertion mode, savable mode, and target architecture
(`sim_build/model_t<THREADS>_a<ASSERTIONS>_s<SAVABLE>_<host|x86_64>`).

## What the Numbers Mean

At the end of a run, `frost-native` writes a summary block to standard error
(leaving standard output clean for raw UART bytes):

```text
--- FROST RTL simulation summary ---
Simulated cycles : 333,130
CoreMark ticks   : 223,556
Wall time        : 45.369 s
Simulation speed : 7,343 cycles/s (threads: 4)
```

| Summary field | Meaning |
| --- | --- |
| `Simulated cycles` | Total rising edges of `i_clk` from time zero, including the 20-cycle cold reset sequence before `i_rst_n` releases (when resuming from a checkpoint, the summary also prints how many cycles advanced after restore) |
| `CoreMark ticks` | Value of `Total 64-bit ticks` printed by CoreMark, read from the CPU `mcycle` CSR around the timed CoreMark loop without C startup or UART report printing |
| `Wall time` | Host elapsed time spent in the simulation loop, excluding software and Verilator compilation |
| `Simulation speed` | Simulated clock cycles per host second (`Simulated cycles` divided by `Wall time`, or advanced cycles divided by `Wall time` after `--restore`) |

On every simulated clock cycle, host software evaluates the combinational and
sequential logic of the out-of-order core, MMUs, caches, coherence home,
memories, and peripherals. That software evaluation runs at thousands of
simulated cycles per second on an x86-64 CPU, depending on host processor,
thread count, assertion mode, and cache or DDR activity. Physical FPGA hardware
clocks every flip-flop and SRAM in parallel, so hardware executes the same
RTL many thousands of times faster than software simulation: 333,130 cycles is
tens of seconds in Verilator and well under a millisecond on hardware.

Bare-metal CoreMark prints `Baremetal Coremark 1 iterations, assuming 20000 Hz
FPGA clock` because simulation builds compile CoreMark with `ITERATIONS=1` and
a nominal 20 kHz constant to satisfy CoreMark's minimum-runtime check in a
single iteration. `CoreMark ticks` is the hardware cycle count of that
iteration.

## Standalone Demo Image

[`demo/Dockerfile`](../../../demo/Dockerfile) packages precompiled
`frost-native` binaries (`1`, `4`, and `8` threads) and prebuilt `hello_world`
and `coremark` images (`bram` and `ddr`) into a small `ubuntu:26.04` container
with no compiler, Python runtime, or repository checkout inside the runtime
stage.

With the `frost` toolchain image built locally (`docker build -t frost .`),
build and run the standalone demo image from the repository root:

```bash
docker build -f demo/Dockerfile -t frost-demo:local .
docker run --rm frost-demo:local
```

By default, [`demo/run_demo.sh`](../../../demo/run_demo.sh) selects 4 simulator
threads when at least 4 host CPUs are visible (`1` otherwise), runs
`hello_world` on the RTL, and then runs 1-iteration CRC-checked `coremark`,
printing live UART output and the simulation summary for each run. Options
select the thread partition, memory tier, or workload:

```bash
docker run --rm frost-demo:local --threads 8
docker run --rm frost-demo:local --threads 1 --app hello_world
docker run --rm frost-demo:local --mem-config ddr --app coremark
docker run --rm frost-demo:local --help
```

The demo binaries are compiled with `PORTABLE=1` (`-O3 -march=x86-64`) and link
`libstdc++`, `libgcc`, and `libatomic` statically so they run on baseline
64-bit x86 Linux hosts without host-specific AVX/ISA requirements.

## Assertions, Retirement Trace, and Checkpoints

| Mechanism | Behavior |
| --- | --- |
| Assertions (`ASSERTIONS=1`) | Default for `hw/sim/native/Makefile`, `./scripts/frost.py native`, and `tests/test_native_sim.py`. Verilator compiles immediate and concurrent SystemVerilog assertions (`--assert +define+FROST_SIM_ASSERTIONS`). `main.cpp` disables assertions (`VerilatedContext::assertOn(false)`) before model construction and time-zero evaluation so uninitialized state during cold reset cannot trip assertions, then enables them (`assertOn(true)`) after 18 reset edges, right before `i_rst_n` releases on cycle 20. Pass `--no-assert` to keep runtime assertions disabled in a checked build. `demo/Dockerfile` compiles with `ASSERTIONS=0` because the demo container runs fixed `hello_world` and `coremark` images verified by `tests/test_native_sim.py`, avoiding per-cycle assertion overhead and reducing binary size. |
| Retirement trace | Outside synthesis, `reorder_buffer.sv` opens `retire_trace.log` in an `initial` block and writes one line per retired instruction whenever `retire_trace_fd` is nonzero. `main.cpp` constructs the model inside a private temporary staging directory, closes `retire_trace_fd` and sets it to `0` before cycle 0, and removes the temporary directory. No `retire_trace.log` is written unless `--retire-trace <path>` is passed. |
| Checkpoints (`SAVABLE=1`) | Building with `SAVABLE=1` enables `--save <path>`, `--save-at <cycle>`, and `--restore <path>`. A checkpoint stores the cycle count, simulation time, stop-marker state, accumulated UART bytes, and the serialized `Vtop` model (including BRAM and behavioral DDR contents). `--restore <path>` resumes simulation from that cycle without needing `.mem` files on disk. |

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
`hw/sim/native/Makefile` uses the same `frost` top-level parameters as
`tests/Makefile`, checks the baseline records in
[`exactness_baseline.json`](exactness_baseline.json), builds the checked native
model, and verifies that `hello_world` and `coremark` in both `bram` and `ddr`
match the cocotb flow in UART byte count, UART SHA-256 digest, simulated cycle
count, and CoreMark ticks, as well as checkpoint save/restore equivalence. In
CI, the `test-native` job in
[`.github/workflows/ci.yml`](../../../.github/workflows/ci.yml) builds the
checked model once and runs `python3 tests/test_native_sim.py --ci`
(`hello_world` on BRAM and DDR, plus `coremark` on BRAM).

Portability scope:

- Tested on x86-64 Linux inside Docker (`frost` toolchain container and
  `frost-demo:local` runtime container on Ubuntu 26.04).
- Not tested natively outside Docker, on `linux/arm64` hosts, on macOS (Docker
  Desktop Linux VMs or Apple Silicon emulation), or on Windows / WSL2.
