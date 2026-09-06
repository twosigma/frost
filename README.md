# FROST

**F**PGA **R**ISC-V **O**pen-sourced in **S**ystemVerilog by **T**woSigma

FROST is an out-of-order 64-bit RISC-V processor. It implements RV64GCB
(G = IMAFD) with a Tomasulo back-end, M/S/U privilege modes with trap
delegation, and Sv39 virtual memory. It runs no-MMU Linux and RTOS workloads at
300 MHz on the Alveo X3. The core is portable SystemVerilog written for FPGAs.

## Why FROST?

- Open-source verification flow. Verilator and Yosys cover simulation, formal,
  and RTL synthesis checks. Production FPGA builds target Xilinx boards through
  Vivado.
- Native SystemVerilog.
- Performance: 986 CoreMark at 300 MHz (3.29 CoreMark/MHz), measured on X3 FPGA.
  The core uses a Tomasulo out-of-order back-end with 2-wide dispatch/rename and commit,
  branch prediction (BTB, bimodal direction predictor, RAS), an L0 cache, and a
  two-cycle conditional-branch misprediction recovery path.
- Layered verification. Directed tests, real C programs, the official
  [riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test)
  compliance suite, [riscv-tests](https://github.com/riscv-software-src/riscv-tests)
  ISA tests, and Spike-referenced random instruction torture tests all run in
  cocotb simulation, alongside formal verification.
- Real workloads. All nine official EEMBC CoreMark-PRO workloads use the X3 DDR
  cache hierarchy. The FreeRTOS demo, CoreMark, and the ISA test
  application run in simulation and on hardware; the 260+ riscv-arch-test
  compliance tests run in simulation.
- 64-bit no-MMU Linux. An in-tree Buildroot flow (`linux/`) builds a no-MMU
  M-mode Linux image with the lp64d hard-float ABI. CI builds it from source
  (`build-frost-linux`), boots it in cocotb RTL simulation
  (`linux-boot-cocotb`), and runs it through full userspace in QEMU
  (`linux-boot-qemu`), where a boot-time stress payload (timer storm with
  signals, vfork/exec, futex, LR/SC contention) must pass before the login
  prompt. The image boots on X3 hardware, and `fpga/linux_boot_soak.py` scores
  the same payload across repeated hardware boots.
- Portable core RTL. The CPU avoids vendor primitives and passes generic Yosys
  coarse synthesis plus a full UltraScale+ synthesis target. The board
  integration keeps board-specific wrappers separate from the common Xilinx
  subsystem.
- Apache 2.0 license, suitable for commercial and academic use.

## Features

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              FROST RISC-V CPU                                │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   In-order front-end                                                         │
│   ┌────┐   ┌────┐   ┌────┐    2-wide dispatch / rename / resource alloc      │
│   │ IF │──>│ PD │──>│ ID │──────────────────────────────┐                    │
│   └────┘   └────┘   └────┘                              │                    │
│     ▲      C-ext     CSR dec                            ▼                    │
│     │      expand                          ┌─────────────────────────────┐   │
│     │                                      │   ROB  (32 entries)         │   │
│     │   ┌────────────────┐                 │   RAT  (INT + FP, 8 ckpts)  │   │
│     │   │ BTB 256×2b     │                 └──────────────┬──────────────┘   │
│     │   │ DirPred 1024×2b│                                │ issue            │
│     │   │ RAS 8          │                                ▼                  │
│     │   └────────────────┘     ┌──────────────────────────────────────────┐  │
│     │                          │  6 reservation stations                  │  │
│     │                          │  INT  MUL  MEM  FP  FMUL  FDIV           │  │
│     │                          │  (8)  (4)  (8)  (6)  (4)   (2)           │  │
│     │                          └──────────────┬───────────────────────────┘  │
│     │                                         ▼                              │
│     │                          FU shims (ALU x2, MUL/DIV, FPU)               │
│     │                          LQ + L0 cache, SQ                             │
│     │                                         │                              │
│     │                                         ▼                              │
│     │                          CDB (2 lanes, fixed priority)                 │
│     │                          broadcasts results; wakes RS, marks ROB done  │
│     │                                         │                              │
│     │                                         ▼                              │
│     │                            commit ──> INT / FP regfiles                │
│     │                                        SQ release, trap, redirect      │
│     │                                                                        │
│     └─── early mispredict recovery (~2 cycles): redirect IF + restore RAT    │
│                                                                              │
│   ┌──────────────────────────┐    ┌─────────────────────────────────────┐    │
│   │ Trap Unit                │    │ Peripherals                         │    │
│   │ (M/S/U traps, delegation,│    │ UART (+ ns16550a face), FIFO0/1     │    │
│   │  mret/sret, wfi,         │    │ CLINT timer (mtime/mtimecmp, msip)  │    │
│   │  interrupts, exceptions) │    │ PLIC (hart 0 M and S contexts)      │    │
│   └──────────────────────────┘    └─────────────────────────────────────┘    │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Supported RISC-V Extensions

**ISA: RV64GCB** (G = IMAFD) plus the extensions below, over 200 instructions.

| Extension        | Description                                    |
|------------------|------------------------------------------------|
| **RV64I**        | Base integer instruction set, including the W-suffixed 32-bit-result ops |
| **M**            | Integer multiply/divide                        |
| **A**            | Atomic memory operations (LR/SC, AMO; word and doubleword) |
| **F**            | Single-precision floating-point (32-bit)       |
| **D**            | Double-precision floating-point (64-bit)       |
| **C**            | Compressed instructions (16-bit encodings, RV64C recoding: C.ADDIW/C.LD/C.SD) |
| **B**            | Bit manipulation (B = Zba + Zbb + Zbs)         |
| **Zicsr**        | CSR access instructions                        |
| **Zicntr**       | Base counters (cycle, time, instret)           |
| **Zifencei**     | Instruction fence                              |
| **Zicond**       | Conditional zero                               |
| **Zbkb**         | Bit manipulation for crypto                    |
| **Zihintpause**  | Pause hint for spin-wait loops                 |
| **Machine Mode** | M-mode privilege (mret, wfi, ecall, ebreak)    |
| **Supervisor Mode** | S-mode privilege: sret, medeleg/mideleg trap delegation, Sv39 translation (satp, sfence.vma), Sstc (stimecmp) |
| **User Mode**    | U-mode privilege (ecall traps to M-mode, or to S-mode when delegated) |

### Architecture Highlights

- In-order front-end (IF, PD, ID) with a 64-bit instruction fetch window,
  C-extension decompression, dual decode packets, and CSR decode. The CSR
  access itself is serialized and executed at commit. Bundle formation pairs
  any non-control, non-serializing slot-1 instruction with the one that
  follows it (RVC+RVC, RVC+32b, 32b+RVC, and 32b+32b, with the PC advancing up
  to +8). The remaining 1-wide cases are a slot-2 that would start a
  serializing (CSR, MISC-MEM, AMO) or native FP-compute instruction, and a
  misaligned 32b+32b pair that would span beyond the fetch window.
- Tomasulo out-of-order back-end with register renaming, dynamic scheduling,
  in-order commit, and precise exceptions.
- 2-wide dispatch and rename: up to two ROB entries per cycle, with
  intra-bundle RAW handling, second-slot resource checks, and branch
  checkpointing.
- 32-entry ROB shared by INT and FP, with separate INT and FP register alias
  tables and 8 branch checkpoint slots.
- 2-wide commit: up to two ROB entries per cycle (head and head+1) through
  INT and FP register files with two write ports each. Correctly predicted
  branches retire in either slot; a second checkpoint-free port and held
  BTB/bimodal training captures serve head+1.
- Six reservation stations (INT, MUL, MEM, FP, FMUL, FDIV). Long-latency FP
  divide has its own station so it cannot block FP_RS. The INT station issues
  two operations per cycle to two single-cycle ALU pipes; branches steer to
  pipe 0, which owns branch resolution.
- 2-lane CDB result broadcast. Fixed-priority arbitration tuned for common
  integer traffic (`MUL > MEM > ALU > ALU2 > DIV > FP_DIV > FP_MUL > FP_ADD`)
  grants the top two FU completions per cycle, with a one-deep holding
  register per FU.
- Conservative memory disambiguation: a load waits until every older store
  address is known, and takes its data from the SQ by store-to-load
  forwarding when an older store covers its bytes.
- Two-tier branch recovery. A mispredicted conditional branch takes a fast
  path of about two cycles that redirects the front-end and restores the RAT
  in the same cycle. JALR mispredictions and exceptions take the slower
  commit-time path.
- Branch prediction with a 256-entry 2-bit BTB (trained for conditional
  branches and JAL, with slot-2 lookup), a 1024-entry bimodal direction
  predictor, an 8-entry return address stack, and PD-stage computed-target
  redirects for conditional branches that miss the BTB but are predicted
  taken.
- L0 cache inside the load queue, cutting load-use latency: 128 entries,
  direct-mapped, dword-granular, filled from load responses. A store
  invalidates its dword line when its memory write launches.
- M/S/U privilege modes with trap delegation, for RTOS and supervisor
  software: traps enter M-mode through mtvec, or S-mode through stvec when
  medeleg/mideleg delegate them.
- Sv39 virtual memory: an 8-entry ITLB in the fetch stage, a 16-entry DTLB
  ahead of the load and store queues, and a hardware page-table walker that
  reads page tables through its own port on the cache hierarchy.
- CLINT-compatible timer (mtime/mtimecmp) for preemptive scheduling, and a
  PLIC with M and S contexts for hart 0 whose sources are the ns16550 UART
  and the board's external-interrupt pin.
- Separate instruction and data memory ports (Harvard).
- Write-back cache hierarchy over DDR. A 1 GiB cached region at `0x8000_0000`
  is served by `frost_cache` instances: direct-mapped, 32 B lines, write-back
  and write-allocate, non-blocking, so L1 hits stream one per cycle past
  outstanding misses and stores are acknowledged once the L1D has ordered
  them. On X3, a 16 KiB read-only L1I serves instruction fetch and a 128 KiB
  L1D serves data, so code can execute from DDR as well as from low BRAM. The
  L1D, page-table walker, and L1I merge through a tagged tree of two 2:1
  line-port arbiters (fixed priority D > walker > I) with several transactions
  in flight. A 2 MiB UltraRAM L2 with a serialized three-cycle tag lookup sits
  below that tree. The hierarchy reaches X3's DDR4 through a single-beat AXI
  bridge that keeps multiple transactions outstanding.
- One memory map everywhere. Software sees the same layout across board
  integrations and simulation: a 256 KiB uncached BRAM region for code, data,
  and stack, the MMIO window at `0x4000_0000`, the PLIC at `0x4400_0000`, and
  the 1 GiB cached region for execute-from-DDR code, heap, and large data.
  Low-BRAM data accesses take one cycle. Instruction windows wholly inside
  `[0, 64 KiB)` also take one cycle; later code windows repeat once to register
  their timing-facing predecode metadata. The hierarchy shape is invisible to
  software.

## Prerequisites

The Docker image provides every validated tool below except Vivado, so
simulation, formal verification, and linting need no host tool installation.

| Category      | Tool              | Version |
|---------------|-------------------|---------|
| **Compiler**  | RISC-V GCC        | 15.2.0  |
| **Testbench** | Cocotb            | 2.0.1   |
|               | pytest            | 9.1.1   |
| **Simulator** | Verilator         | 5.050   |
| **Synthesis** | Yosys             | 0.64    |
|               | sv2v              | 0.0.13  |
| **Formal**    | SymbiYosys        | 0.63    |
|               | Z3                | 4.15.0  |
|               | Boolector         | 3.2.4   |
| **FPGA**      | Vivado (optional) | 2025.2  |
| **Linting**   | pre-commit        | 4.6.0   |
|               | clang-format      | 19.1.6  |
|               | clang-tidy        | 18.1.3  |
|               | Verible           | 0.0-4051|

## Docker Development Environment

Build the Docker image once, then use the repository wrapper. It keeps
container outputs owned by the invoking UID/GID:

```bash
# Build the Docker image
docker build -t frost .

# Diagnose the local Docker/image/submodule setup
./scripts/frost.py doctor

# Run a clean Hello World cocotb simulation
./scripts/frost.py cocotb hello_world

# Open an interactive shell when needed
./scripts/frost.py shell
```

The Docker image includes:
- Verilator, Yosys, SymbiYosys, Z3, and Boolector built from source at the
  versions pinned above, plus the xPack bare-metal RISC-V GCC toolchain and
  Python 3.12 with Cocotb and pytest
- Pre-commit plus system clang-tidy/Verible; pinned Ruff, mypy, and
  clang-format hook environments install on the first lint run and are cached

`doctor` is a read-only preflight. It reports each diagnostic as `PASS`,
`WARN`, `FAIL`, or dependency-gated `SKIP`, then returns a nonzero status if
any check failed. It checks Docker access, image compatibility, submodules,
the persistent hook cache, and generated-artifact ownership. The ownership
scan skips `./hw`. The hook cache lives at `$XDG_CACHE_HOME/frost/container`
when that variable is set, or at `~/.cache/frost/container` otherwise.

## Running Code-Quality Checks

Run the `Lint` and `Fast Python Tests` CI gates with:

```bash
./scripts/frost.py check
```

`check` runs both gates even if the first fails, so one invocation reports all
fast feedback; pass `--fail-fast` to stop at the first failure. This is not the
full simulator/formal/synthesis regression. The lint hooks include automatic
formatters and fixers, so `check` may modify files; review the resulting diff.
Use `./scripts/frost.py lint` when you only want the lint phase.

## Quick Start

```bash
# Run Hello World simulation (compiles automatically)
./scripts/frost.py cocotb hello_world
```

The output should include "Hello, world!".

### Run the CPU Verification Suite

```bash
./scripts/frost.py pytest                  # all pytest-registered cocotb targets
./scripts/frost.py cocotb directed_traps   # directed M-mode trap/interrupt tests
```

The pytest run covers the registry's unit benches and real programs. The
riscv-tests, riscv-arch-test, and torture matrices have dedicated runners; see
`tests/README.md` for their pinned-container commands. The legacy
constrained-random `cpu_tb` regression is registered as the CLI-only
`cpu_random` target. Its harness plumbing is OOO-aware (register-file hierarchy
paths, LVT-aware banked-RAM reads), but its scoreboard still assumes
single-wide in-order retirement with fixed fetch-to-writeback offsets, and it
needs a commit-indexed redesign before it passes on the current core. Until
then the Spike-referenced torture runner provides the randomized coverage.

## Directory Structure

```
frost/
├── README.md                 # This file
├── hw/                       # Hardware (RTL)
│   ├── rtl/                  # Synthesizable RTL source
│   │   ├── frost.sv          # Top-level module
│   │   ├── frost.f           # File list for synthesis/simulation
│   │   ├── cpu_and_mem/      # CPU core, memory subsystem, PLIC, debug module
│   │   ├── lib/              # Generic FPGA library (RAM, FIFO, cache)
│   │   └── peripherals/      # UART receiver and transmitter
│   └── sim/                  # Simulation-only files (testbenches)
├── sw/                       # Software
│   ├── common/               # Build infrastructure (linker, startup)
│   ├── lib/                  # Bare-metal runtime library (uart, string, sprintf, timer, trap)
│   └── apps/                 # Applications
│       ├── hello_world/      # Simple test program
│       ├── isa_test/         # ISA compliance suite
│       ├── arch_test/        # riscv-arch-test compliance (260+ tests)
│       ├── riscv_tests/      # riscv-tests ISA tests (rv64 suites)
│       ├── riscv_torture/    # Random instruction torture tests (20-test corpus)
│       ├── coremark/         # CPU benchmark
│       ├── coremark_pro/     # EEMBC CoreMark-PRO suite (DDR-backed heap)
│       ├── freertos_demo/    # FreeRTOS RTOS demo
│       └── ...               # Other applications
├── linux/                    # Linux image build: Buildroot + OpenSBI submodules, external tree, firmware helper
├── verif/                    # Verification infrastructure
│   ├── cocotb_tests/         # Cocotb test cases
│   ├── models/               # Software reference models
│   ├── encoders/             # Instruction encoding
│   └── monitors/             # Runtime verification
├── formal/                   # Formal verification (SymbiYosys)
├── tests/                    # Test runners (pytest integration)
├── scripts/                  # Container wrapper (frost.py) and clang-tidy wrapper
├── fpga/                     # FPGA build and programming scripts
│   ├── build/                # Vivado synthesis scripts
│   ├── program_bitstream/    # FPGA programming
│   └── load_software/        # Software loading via JTAG
└── boards/                   # Board-specific wrappers
    └── x3/                   # Alveo X3522PV
```

## User Guide

### Building Software

Simulations, FPGA loading, and bitstream builds compile applications
automatically. To compile manually:

```bash
# Compile a specific application
./scripts/frost.py run make -C sw/apps/hello_world

# Compile all applications
./scripts/frost.py run python3 sw/apps/build_all_apps.py

# Container workflows (./scripts/frost.py ...) initialize all submodules
# automatically. For native (non-container) builds, initialize them first:
git submodule update --init --recursive
```

### Running Simulations

```bash
./scripts/frost.py cocotb directed_traps   # Directed M-mode trap/interrupt tests
./scripts/frost.py cocotb hello_world      # Hello World program
./scripts/frost.py cocotb isa_test         # ISA compliance application
./scripts/frost.py cocotb coremark         # CoreMark benchmark
./scripts/frost.py cocotb coremark_pro_core  # CoreMark-PRO (also _cjpeg,
                                             # _linear_alg, _loops, _nnet,
                                             # _parser, _radix2, _sha, _zip)
./scripts/frost.py cocotb ddr_test         # Cached-region (DDR) tier test
./scripts/frost.py cocotb ddr_heap_test    # Multi-MB malloc through the caches
./scripts/frost.py cocotb frost_cache      # Cache-hierarchy unit bench (X3 shape)
./scripts/frost.py cocotb freertos_demo    # FreeRTOS demo

# Generate waveforms for one selected test
WAVES=1 ./scripts/frost.py cocotb directed_traps
```

### Running Synthesis

```bash
# Open-source RTL synthesis checks (Yosys)
./scripts/frost.py synthesis

# FPGA synthesis (Vivado)
./fpga/build/build.py x3                   # Alveo X3
```

### CI Test Coverage

CI covers:

- Directed tests: M-mode trap/interrupt handling (`directed_traps` on the
  cpu_tb harness). LR/SC and compressed-instruction coverage comes from the
  rv64ua/rv64uc riscv-tests, the arch-compliance suite, and the
  ddr_atomic_test/c_ext_test programs. The other cpu_tb suites are CLI-only:
  directed_atomics and compressed are ported to the OOO core and pass but are
  not wired into CI; directed_multicycle and the constrained-random cpu_random
  still assume in-order fixed latencies and need porting (cpu_random via a
  commit-indexed scoreboard).
- Architecture compliance: the official
  [riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test) suite
  (the rv64i_m batches, 260+ tests) across the I, M, A, F, D, C, B, K, Zicond,
  Zifencei, privilege, D_Zcd, and hints extensions, with signature comparison
  against Spike golden references (Verilator only, one CI job per extension
  and memory tier).
- ISA pipeline tests: self-checking tests from
  [riscv-tests](https://github.com/riscv-software-src/riscv-tests) (172 tests
  in the DDR tier across the twelve rv64 suites: ui/um/ua/uf/ud/uc/mi/si plus
  the four Zb* suites; the BRAM tier skips two that need cached DDR),
  exercising rename, wakeup, CDB arbitration, and OOO commit. The user-level
  suites also run under the paged `v` environment on the DDR tier (Verilator
  only).
- Random instruction torture tests: a randomly generated RV64IMAFDC
  instruction corpus (20 tests: ALU, multiply/divide, memory, branch, FP, AMO)
  checked against Spike golden register signatures (Verilator only).
- C program simulation: the registered applications (hello_world, coremark,
  freertos_demo, and the rest) run in simulation with pass/fail detection.
- C compilation: every application compiles with the RISC-V toolchain.
- Standalone Ethernet: the [Ethernet MAC/PCS job](.github/workflows/ci.yml) runs the
  isolated MAC/PCS cocotb suite and portable coarse synthesis through `frost`,
  independently of the CPU test registry.
- Yosys synthesis: the RTL passes generic, vendor-agnostic coarse synthesis
  and a full Xilinx UltraScale+ synthesis target matching X3's hierarchy.
- Formal verification: SymbiYosys bounded model checking plus
  cover-reachability checks on selected modules verify control and datapath
  invariants over all inputs within their bounded windows (see `formal/`).

Most program suites run as separate memory-tier jobs: `bram` places the whole
program in low BRAM for ISA checks; `ddr` relocates it to cached DDR to
exercise the L1I and the D-side cache. Architecture compliance uses the same
tiers but skips three jobs: the slow F and D DDR batches (the F/D BRAM jobs
cover FPU conformance and the other DDR jobs cover the caches) and the
Zifencei BRAM batch, whose self-modifying code needs cached DDR because low
BRAM is Harvard.

### FPGA Deployment

```bash
# 1. Build bitstream (~30-90 min with the DDR subsystem and timing sweeps)
./fpga/build/build.py x3

# 2. Program FPGA
./fpga/program_bitstream/program_bitstream.py x3

# 3. Load software (fast, no re-synthesis)
./fpga/load_software/load_software.py x3 hello_world
./fpga/load_software/load_software.py x3 coremark
./fpga/load_software/load_software.py x3 isa_test

# CoreMark-PRO workloads (-v1 = validation, -v0 = performance run
# with calibrated iterations from sw/apps/software_registry.py). Workloads with
# data in the cached region (e.g. radix2's FFT tables) are loaded into DDR over
# JTAG automatically before the low-BRAM image.
./fpga/load_software/load_software.py x3 coremark_pro_core -v1
./fpga/load_software/load_software.py x3 coremark_pro_radix2 -v1
```

Use a serial terminal configured for 115200 baud, 8 data bits, no parity, and
1 stop bit (8N1) to view the board UART console.

## Supported FPGA Boards

| Board              | FPGA                 | CPU Clock  | Cache hierarchy → main memory               |
|--------------------|----------------------|------------|---------------------------------------------|
| Alveo X3522PV      | UltraScale+ (xcux35) | 300 MHz    | 128 KiB L1D + 16 KiB L1I → 2 MiB URAM L2 → 1 GiB DDR4 |

Board integrations preserve the same software-visible memory map so another
target can be added without changing software. X3 carries a 256 KiB uncached
low BRAM region at `[0, 256 KiB)` and cached DDR at
`[0x8000_0000, +1 GiB)`. Low-BRAM data accesses and instruction
windows wholly below 64 KiB take one cycle; later instruction windows repeat
once for registered predecode metadata. The CPU is held in reset until the DDR
controller calibrates, so software never observes uninitialized main memory.


<!-- FPGA_UTILIZATION_START -->

### FPGA Resource Utilization

**Alveo X3522PV** (Virtex UltraScale+ @ 300 MHz; post-route report)

| Resource | Used | Available | Util% |
|----------|-----:|----------:|------:|
| CLB LUTs | 187,527 | 1,029,600 | 18.2% |
|   LUT as Logic | 170,473 | 1,029,600 | 16.6% |
|   LUT as Distributed RAM | 15,644 | — | — |
|   LUT as Shift Register | 1,410 | — | — |
| CLB Registers | 137,288 | 2,059,200 | 6.7% |
| Block RAM Tile | 230.5 | 2,112 | 10.9% |
| URAM | 68 | 352 | 19.3% |
| DSPs | 47 | 1,320 | 3.6% |
| CARRY8 | 6,329 | 128,700 | 4.9% |
| F7 Muxes | 1,962 | 514,800 | 0.4% |
| F8 Muxes | 926 | 257,400 | 0.4% |
| Bonded IOB | 132 | 364 | 36.3% |
| MMCM | 2 | 11 | 18.2% |
| PLL | 3 | 22 | 13.6% |

<!-- FPGA_UTILIZATION_END -->

## Roadmap

FROST is an RV64GCB-only core; rv32 support was retired after Phase 1.
[ROADMAP.md](ROADMAP.md) lists the phases from the RV64 substrate through
S-mode and Sv39 with MMU Linux, system I/O with a stock distribution, SMP,
and RV64 performance parity with the former RV32 design, each with its exit
criteria.

## CPU Internals

The [CPU README](hw/rtl/cpu_and_mem/cpu/README.md) and
[Tomasulo README](hw/rtl/cpu_and_mem/cpu/tomasulo/README.md) describe the OOO
design and cross-cutting decisions. Each Tomasulo submodule also has a README
under `hw/rtl/cpu_and_mem/cpu/tomasulo/`.

## Glossary

| Term            | Definition                                       |
|-----------------|--------------------------------------------------|
| **RV64I**       | RISC-V 64-bit base integer instruction set          |
| **XLEN**        | Register/datapath width, fixed at 64 in FROST       |
| **M extension** | Multiply/divide instructions                     |
| **A extension** | Atomic memory operations (LR/SC, AMO)            |
| **B extension** | Bit manipulation (Zba + Zbb + Zbs)               |
| **C extension** | Compressed 16-bit instructions                   |
| **F extension** | Single-precision floating-point (32-bit IEEE 754)|
| **D extension** | Double-precision floating-point (64-bit IEEE 754)|
| **G extension** | Shorthand for IMAFD                              |
| **Sv39**        | 39-bit virtual addressing with three-level page tables (satp, ITLB/DTLB, page-table walker) |
| **IF**          | Instruction Fetch stage                          |
| **PD**          | Pre-Decode stage (C extension decompression)     |
| **ID**          | Instruction Decode feeding 2-wide dispatch       |
| **OOO**         | Out-of-order execution                           |
| **Tomasulo**    | OOO scheduling algorithm with register renaming  |
| **ROB**         | Reorder Buffer (32-entry, in-order commit)       |
| **RAT**         | Register Alias Table (INT + FP rename, 8 ckpts)  |
| **RS**          | Reservation Station (per-FU instruction window)  |
| **LQ**          | Load Queue (in-flight loads, L0 cache, MMIO)     |
| **SQ**          | Store Queue (non-speculative, store-to-load fwd) |
| **CDB**         | Common Data Bus (2-lane result broadcast)        |
| **FU**          | Functional Unit (ALU, MUL/DIV, FPU, …)           |
| **L0 Cache**    | Level-0 cache for load-use bypass                |
| **L1I / L1D**   | Split write-back line caches (16 KiB instruction, 128 KiB data on X3) over the cached DDR region, merged with the page-table walker port through a tree of 2:1 line-port arbiters |
| **L2 Cache**    | 2 MiB UltraRAM line cache below the L1s on X3        |
| **Cached region** | `[0x8000_0000, +1 GiB)`: code (execute-from-DDR), heap, and large data, behind L1→L2→DDR |
| **BTB**         | Branch Target Buffer (256-entry target predictor) |
| **DirPred**     | 1024-entry bimodal branch-direction predictor    |
| **RAS**         | Return Address Stack (8-entry return predictor)  |
| **MMIO**        | Memory-Mapped I/O                                |
| **CLINT**       | Core Local Interruptor (timer/software interrupts) |
| **PLIC**        | Platform-Level Interrupt Controller (external interrupts, M and S contexts) |
| **Cocotb**      | Python-based verification framework              |
