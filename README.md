# FROST

**F**PGA **R**ISC-V **O**pen-sourced in **S**ystemVerilog by **T**woSigma

An out-of-order 64-bit RISC-V processor implementing **RV64GCB** (G = IMAFD)
with a Tomasulo back-end and Machine + User (M/U) privilege modes. It runs
no-MMU Linux and RTOS workloads at 300 MHz on Alveo X3 and 133.33 MHz on
Digilent Genesys2. The core is portable SystemVerilog designed for FPGAs.

## Why FROST?

- **Open-source verification flow** — Verilator and Yosys cover simulation,
  formal, and RTL synthesis checks. Production FPGA builds target Xilinx
  boards through Vivado.
- **Native SystemVerilog**
- **Performance** — 827 CoreMark at 300 MHz (2.76 CoreMark/MHz; the retired rv32 build of the same core scored 977, 3.26/MHz — the difference is the lp64 ABI on this benchmark: CoreMark keeps its data in 32-bit types, so the rv64 binary spends ~12% more instructions on 32-bit semantics (`sext.w`/`addiw` forms), and its 16-byte list nodes double the footprint of the pointer chase). From a Tomasulo out-of-order back-end with 2-wide dispatch/rename, 2-wide commit, branch prediction (BTB + bimodal direction predictor + RAS), an L0 cache, and a fast two-cycle conditional-branch misprediction recovery path.
- **Layered verification** — constrained-random tests, directed tests, real C programs, the official [riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test) compliance suite, [riscv-tests](https://github.com/riscv-software-src/riscv-tests) ISA tests, and random instruction torture tests all run in Cocotb simulation, along with formal verification.
- **Real workloads included** — all nine official EEMBC CoreMark-PRO workloads
  use the DDR cache hierarchy on both boards. The FreeRTOS demo, CoreMark, ISA
  compliance suite, and 260+ architecture compliance tests also run in
  simulation and on hardware.
- **Boots 64-bit no-MMU Linux** — an in-tree Buildroot flow (`linux/`) builds a no-MMU M-mode Linux image (lp64d hard-float ABI); CI builds it from source (`build-frost-linux`), boots it in cocotb RTL simulation (`linux-boot-cocotb`), and runs it through full userspace in QEMU (`linux-boot-qemu`), where a boot-time stress payload (timer storm + signals, vfork/exec, futex, LR/SC contention) must pass before the login prompt. The image boots on X3 hardware; `fpga/linux_boot_soak.py` scores the same payload across repeated hardware boots.
- **Portable core RTL** — the CPU avoids vendor primitives and passes generic
  Yosys coarse synthesis plus full 7-series, UltraScale, and UltraScale+
  targets. Board wrappers cover Kintex-7 and UltraScale+.
- **Apache 2.0 licensed** — permissive license suitable for commercial and academic use.

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
│     │                          │  (16) (4)  (8)  (6)  (4)   (2)           │  │
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
│   │ (M/U traps, mret, wfi,   │    │ UART (+ ns16550a face), FIFO0/1     │    │
│   │  interrupts, exceptions) │    │ CLINT timer (mtime/mtimecmp, msip)  │    │
│   └──────────────────────────┘    └─────────────────────────────────────┘    │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Supported RISC-V Extensions

**ISA: RV64GCB** (G = IMAFD) plus additional extensions — **200+ instructions**.

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
| **User Mode**    | U-mode privilege (ecall traps to M-mode)       |

### Architecture Highlights

- **In-order front-end** (IF → PD → ID) with a 64-bit-wide instruction fetch window, C-extension decompression, dual decode packets, and CSR decode (the CSR access itself is serialized and executed at commit). 2-wide bundle formation pairs any non-control, non-serializing slot-1 with a following instruction (RVC+RVC, RVC+32b, 32b+RVC, and 32b+32b shapes, PC advancing up to +8); the remaining structural 1-wide cases are a slot-2 that would start a serializing (CSR/MISC-MEM/AMO) or native FP-compute instruction, and a misaligned 32b+32b pair spanning beyond the fetch window
- **Tomasulo out-of-order back-end** with register renaming, dynamic scheduling, in-order commit, and precise exceptions
- **2-wide dispatch/rename** — allocates up to two ROB entries per cycle, with intra-bundle RAW handling, second-slot resource checks, and branch checkpointing
- **32-entry ROB** unified across INT and FP, with separate INT and FP register alias tables and 8 branch checkpoint slots
- **2-wide commit** — retires up to two ROB entries per cycle (head + head+1) through 2-write-port INT/FP regfiles; correctly-predicted branches retire in either slot (a second checkpoint-free port plus held BTB/bimodal training captures serve head+1)
- **6 reservation stations** (INT, MUL, MEM, FP, FMUL, FDIV) — long-latency FP divide isolated so it cannot block FP_RS; the INT station is dual-issue, feeding two single-cycle ALU pipes (branches steer to pipe 0, which owns branch resolution)
- **2-lane CDB result broadcast** — grants the top two FU completions per cycle with fixed-priority arbitration tuned for common integer traffic (`MUL > MEM > ALU > ALU2 > DIV > FP_DIV > FP_MUL > FP_ADD`) and one-deep holding registers per FU
- **Conservative memory disambiguation** — loads gated until older store addresses known, with store-to-load forwarding from the SQ
- **Two-tier branch recovery** — conditional-branch mispredictions use a fast ~2-cycle path (front-end redirect + RAT restore in the same cycle); JALR and exceptions take the slower commit-time path
- **Branch prediction** with a 256-entry 2-bit BTB (trained for conditional branches and JAL, with slot-2 lookup support), 1024-entry bimodal direction predictor, 8-entry return address stack, and PD-stage computed-target redirects for conditional BTB misses predicted taken
- **L0 cache** inside the load queue reduces load-use latency (direct-mapped, word-granular, read-fill; stores invalidate the matching word entry)
- **Machine + User (M/U) privilege modes** for RTOS support — traps from both modes are taken in M-mode (interrupts and exceptions)
- **CLINT-compatible timer** (mtime/mtimecmp) for preemptive scheduling
- **Harvard architecture** with separate instruction and data memory ports
- **Write-back cache hierarchy over DDR** — a 1 GiB cached region at `0x8000_0000` served by recursive line-port caches (`frost_cache`: direct-mapped, 32 B lines, write-back/write-allocate, non-blocking — L1 hits stream one per cycle past outstanding misses, and stores are acknowledged once the L1D has ordered them). On every board, instruction fetch runs through a read-only L1I (16 KiB on X3, 128 KiB on Genesys2) and data through a 128 KiB L1D — so code can execute from DDR, not just from low BRAM — with the L1D, page-table walker, and L1I merged by a tagged tree of two 2:1 line-port arbiters (fixed priority D > walker > I, several transactions in flight). On UltraScale+ a 2 MiB UltraRAM L2 with serialized three-cycle tag lookups is spliced in below that tree; the hierarchy reaches the board's DDR (DDR3 on Genesys2, DDR4 on X3) through a single-beat AXI bridge with multiple outstanding transactions
- **One memory map everywhere** — software sees the same layout on every board and in simulation: a 256 KiB uncached BRAM region for code/data/stack plus the 1 GiB cached region for execute-from-DDR code, heap, and large data. Low-BRAM data accesses are 1-cycle; instruction windows wholly in `[0, 16 KiB)` are also 1-cycle, while later code windows repeat once to register their timing-facing predecode metadata. The hierarchy shape is opaque to software

## Prerequisites

The Docker image provides every validated tool below except Vivado; simulation,
formal verification, and linting need no host tool installation.

| Category      | Tool              | Version |
|---------------|-------------------|---------|
| **Compiler**  | RISC-V GCC        | 15.2.0  |
| **Testbench** | Cocotb            | 2.0.1   |
|               | pytest            | 9.1.1   |
| **Simulator** | Verilator         | 5.050   |
| **Synthesis** | Yosys             | 0.64    |
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
scan deliberately skips `./hw`. The hook cache lives at
`$XDG_CACHE_HOME/frost/container` when that variable is set, or at
`~/.cache/frost/container` otherwise.

## Running Code-Quality Checks

Run the `Lint` and `Fast Python Tests` CI gates with:

```bash
./scripts/frost.py check
```

`check` runs both gates even if the first fails so one invocation reports all
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
`cpu_random` target: its harness plumbing is OOO-aware (register-file hierarchy
paths, LVT-aware banked-RAM reads), but its scoreboard still assumes single-wide
in-order retirement with fixed fetch-to-writeback offsets and needs a
commit-indexed redesign before it passes on the current core. Randomized
coverage is meanwhile provided by the Spike-referenced torture runner.

## Directory Structure

```
frost/
├── README.md                 # This file
├── hw/                       # Hardware (RTL)
│   ├── rtl/                  # Synthesizable RTL source
│   │   ├── frost.sv          # Top-level module
│   │   ├── frost.f           # File list for synthesis/simulation
│   │   ├── cpu_and_mem/      # CPU core and memory subsystem
│   │   ├── lib/              # Generic FPGA library (RAM, FIFO, cache)
│   │   └── peripherals/      # UART, etc.
│   └── sim/                  # Simulation-only files (testbenches)
├── sw/                       # Software
│   ├── common/               # Build infrastructure (linker, startup)
│   ├── lib/                  # Libraries (uart, string, timer, etc.)
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
├── linux/                    # Buildroot no-MMU Linux image build (submodule + external tree)
├── verif/                    # Verification infrastructure
│   ├── cocotb_tests/         # Cocotb test cases
│   ├── models/               # Software reference models
│   ├── encoders/             # Instruction encoding
│   └── monitors/             # Runtime verification
├── formal/                   # Formal verification (SymbiYosys)
├── tests/                    # Test runners (pytest integration)
├── scripts/                  # Helper scripts (clang-tidy wrapper, etc.)
├── fpga/                     # FPGA build and programming scripts
│   ├── build/                # Vivado synthesis scripts
│   ├── program_bitstream/    # FPGA programming
│   └── load_software/        # Software loading via JTAG
└── boards/                   # Board-specific wrappers
    ├── x3/                   # Alveo X3522PV
    └── genesys2/             # Digilent Genesys2
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
./fpga/build/build.py genesys2             # Genesys2
```

### CI Test Coverage

CI covers:

- **Directed tests** — M-mode trap/interrupt handling (`directed_traps` on the cpu_tb harness); LR/SC and compressed-instruction coverage is carried by the rv64ua/rv64uc riscv-tests, the arch-compliance suite, and the ddr_atomic_test/c_ext_test programs (the remaining cpu_tb suites are CLI-only: directed_atomics and compressed are ported to the OOO core and pass but are not wired into CI; directed_multicycle and the constrained-random cpu_random still assume in-order fixed latencies and need porting — cpu_random via a commit-indexed scoreboard)
- **Architecture compliance** — the official [riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test) suite (the rv64i_m batches, 260+ tests) across the I, M, A, F, D, C, B, K, Zicond, Zifencei, privilege, D_Zcd, and hints extensions, with signature comparison against Spike golden references (Verilator only, parallelized by extension in CI)
- **ISA pipeline tests** — self-checking tests from [riscv-tests](https://github.com/riscv-software-src/riscv-tests) (166 tests across the eleven rv64 suites: ui/um/ua/uf/ud/uc/mi plus the four Zb* suites), exercising rename, wakeup, CDB arbitration, and OOO commit (Verilator only)
- **Random instruction torture tests** — a randomly generated RV64IMAFDC instruction corpus (20 tests: ALU, multiply/divide, memory, branch, FP, AMO) verified against Spike golden register signatures (Verilator only)
- **C program simulation** — all sample applications (hello_world, coremark, freertos_demo, etc.) run in simulation with pass/fail detection
- **C compilation** — all applications compile successfully with the RISC-V toolchain
- **Yosys synthesis** — RTL passes generic, vendor-agnostic coarse synthesis and full Xilinx 7-series, UltraScale, and UltraScale+ synthesis targets
- **Formal verification** — SymbiYosys bounded model checking plus cover-reachability checks on select modules verify control and datapath invariants over all possible inputs within their bounded windows (see `formal/`)

Most program suites run as separate **memory-tier jobs**: `bram` places the
whole program in low BRAM for ISA checks; `ddr` relocates it to cached DDR to
exercise L1I and the D-side cache. Architecture compliance uses the same
tiers, but omits the slow F/D DDR combinations: F/D BRAM jobs cover FPU
conformance and other DDR jobs cover the caches.

### FPGA Deployment

```bash
# 1. Build bitstream (~30-90 min with the DDR subsystem and timing sweeps)
./fpga/build/build.py x3

# 2. Program FPGA
./fpga/program_bitstream/program_bitstream.py x3

# 3. Load software (fast — no re-synthesis)
./fpga/load_software/load_software.py x3 hello_world
./fpga/load_software/load_software.py x3 coremark
./fpga/load_software/load_software.py x3 isa_test

# CoreMark-PRO workloads (both boards; -v1 = validation, -v0 = performance run
# with calibrated iterations from sw/apps/software_registry.py). Workloads with
# data in the cached region (e.g. radix2's FFT tables) are loaded into DDR over
# JTAG automatically before the low-BRAM image.
./fpga/load_software/load_software.py x3 coremark_pro_core -v1
./fpga/load_software/load_software.py genesys2 coremark_pro_radix2 -v1
```

Use a serial terminal configured for 115200 baud, 8 data bits, no parity, and
1 stop bit (8N1) to view the board UART console.

## Supported FPGA Boards

| Board              | FPGA                 | CPU Clock | Cache hierarchy → main memory               |
|--------------------|----------------------|-----------|---------------------------------------------|
| Alveo X3522PV      | UltraScale+ (xcux35) | 300 MHz   | 128 KiB L1D + 16 KiB L1I → 2 MiB URAM L2 → 1 GiB DDR4 |
| Digilent Genesys2  | Kintex-7 (xc7k325t)  | 133 MHz   | 128 KiB L1D + 128 KiB L1I → 1 GiB DDR3                |

Both boards also carry the 256 KiB uncached low BRAM region and present the
identical software-visible memory map: `[0, 256 KiB)` low BRAM,
`[0x8000_0000, +1 GiB)` cached DDR. Low-BRAM data accesses and instruction
windows wholly below 16 KiB are 1-cycle; later instruction windows repeat once
for registered predecode metadata. The CPU is held in reset until the DDR
controller calibrates, so software never observes an uninitialized main memory.


<!-- FPGA_UTILIZATION_START -->

### FPGA Resource Utilization

**Alveo X3522PV** (Virtex UltraScale+ @ 300 MHz; post-opt report)

| Resource | Used | Available | Util% |
|----------|-----:|----------:|------:|
| CLB LUTs | 186,374 | 1,029,600 | 18.1% |
|   LUT as Logic | 171,354 | 1,029,600 | 16.6% |
|   LUT as Distributed RAM | 13,454 | — | — |
|   LUT as Shift Register | 1,566 | — | — |
| CLB Registers | 136,197 | 2,059,200 | 6.6% |
| Block RAM Tile | 230.5 | 2,112 | 10.9% |
| URAM | 68 | 352 | 19.3% |
| DSPs | 47 | 1,320 | 3.6% |
| CARRY8 | 6,276 | 128,700 | 4.9% |
| F7 Muxes | 616 | 514,800 | 0.1% |
| F8 Muxes | 252 | 257,400 | 0.1% |
| Bonded IOB | 132 | 364 | 36.3% |
| MMCM | 2 | 11 | 18.2% |
| PLL | 3 | 22 | 13.6% |

**Digilent Genesys2** (Kintex-7 @ 133 MHz; final report)

| Resource | Used | Available | Util% |
|----------|-----:|----------:|------:|
| Slice LUTs | 151,669 | 203,800 | 74.4% |
|   LUT as Logic | 138,808 | 203,800 | 68.1% |
|   LUT as Distributed RAM | 11,800 | — | — |
|   LUT as Shift Register | 1,061 | — | — |
| Slice Registers | 104,420 | 407,600 | 25.6% |
| Block RAM Tile | 249 | 445 | 56.0% |
| DSPs | 48 | 840 | 5.7% |
| F7 Muxes | 72 | 101,900 | 0.1% |
| F8 Muxes | 8 | 50,950 | 0.0% |
| Bonded IOB | 77 | 500 | 15.4% |
| MMCM | 3 | 10 | 30.0% |
| PLL | 1 | 10 | 10.0% |

<!-- FPGA_UTILIZATION_END -->

## Roadmap

This is an RV64GCB-only core; rv32 support retired after Phase 1.
[ROADMAP.md](ROADMAP.md)
tracks memory-level parallelism, S-mode and Sv39, mainline MMU Linux, and
system I/O with per-phase exit criteria.

## CPU Internals

The [CPU README](hw/rtl/cpu_and_mem/cpu/README.md) and
[Tomasulo README](hw/rtl/cpu_and_mem/cpu/tomasulo/README.md) describe the OOO
design and cross-cutting decisions. Each Tomasulo submodule also has a README
under `hw/rtl/cpu_and_mem/cpu/tomasulo/`.

## Glossary

| Term            | Definition                                       |
|-----------------|--------------------------------------------------|
| **RV64I**       | RISC-V 64-bit base integer instruction set          |
| **XLEN**        | Register/datapath width — fixed at 64 in FROST      |
| **M extension** | Multiply/divide instructions                     |
| **A extension** | Atomic memory operations (LR/SC, AMO)            |
| **B extension** | Bit manipulation (Zba + Zbb + Zbs)               |
| **C extension** | Compressed 16-bit instructions                   |
| **F extension** | Single-precision floating-point (32-bit IEEE 754)|
| **D extension** | Double-precision floating-point (64-bit IEEE 754)|
| **G extension** | Shorthand for IMAFD                              |
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
| **L1I / L1D**   | Split write-back line caches (16 KiB instruction on X3 / 128 KiB on Genesys2, 128 KiB data) over the cached DDR region, through a shared 2:1 line-port arbiter |
| **L2 Cache**    | 2 MiB UltraRAM line cache below the L1s (UltraScale+ only)        |
| **Cached region** | `[0x8000_0000, +1 GiB)` — code (execute-from-DDR), heap, and large data, behind L1[/L2]→DDR |
| **BTB**         | Branch Target Buffer (256-entry target predictor) |
| **DirPred**     | 1024-entry bimodal branch-direction predictor    |
| **RAS**         | Return Address Stack (8-entry return predictor)  |
| **MMIO**        | Memory-Mapped I/O                                |
| **CLINT**       | Core Local Interruptor (timer/software interrupts) |
| **Cocotb**      | Python-based verification framework              |
