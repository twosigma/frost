# FROST

**F**PGA **R**ISC-V **O**pen-sourced in **S**ystemVerilog by **T**woSigma

An out-of-order RISC-V processor implementing **RV32GCB** (G = IMAFD) with a Tomasulo back-end and Machine + User (M/U) privilege modes for RTOS operation. Achieves 300 MHz on UltraScale+. Designed for FPGA deployment with clean, portable SystemVerilog.

## Why FROST?

There are many RISC-V cores. Here's what makes FROST different:

- **Open-source verification flow** — works with Verilator and Yosys for simulation, formal, and RTL synthesis checks. Production FPGA builds currently target Xilinx boards through Vivado.
- **Native SystemVerilog** — not generated from Chisel or SpinalHDL. Every module is written in native HDL, suitable for understanding and extending.
- **Solid performance** — 3.08 CoreMark/MHz (924 CoreMark at 300 MHz on UltraScale+) from a Tomasulo out-of-order back-end with 2-wide dispatch/rename, 2-wide commit, branch prediction (BTB + bimodal direction predictor + RAS), an L0 cache, and a fast two-cycle conditional-branch misprediction recovery path.
- **Layered verification** — constrained-random tests, directed tests, real C programs, the official [riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test) compliance suite, [riscv-tests](https://github.com/riscv-software-src/riscv-tests) ISA tests, and random instruction torture tests all run in Cocotb simulation, along with formal verification.
- **Real workloads included** — all nine official EEMBC CoreMark-PRO workloads (on both supported boards, backed by the DDR cache hierarchy), FreeRTOS demo, CoreMark benchmark, ISA compliance suite, and 400+ architecture compliance tests all run in simulation and on hardware.
- **Portable core RTL** — the CPU core avoids vendor primitives and is checked with generic Yosys coarse synthesis. Full open-source Yosys synthesis is also tested for Xilinx 7-series, UltraScale, and UltraScale+ targets; board wrappers are provided for Kintex-7 and UltraScale+.
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
│     ▲      C-ext     CSR rd                             ▼                    │
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
│     │                          FU shims (ALU, MUL/DIV, FPU)                  │
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
│   │ (M/U traps, mret, wfi,   │    │ UART, mtime/mtimecmp, FIFO0/1       │    │
│   │  interrupts, exceptions) │    │                                     │    │
│   └──────────────────────────┘    └─────────────────────────────────────┘    │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Supported RISC-V Extensions

**ISA: RV32GCB** (G = IMAFD) plus additional extensions — **170+ instructions**

| Extension        | Description                                    |
|------------------|------------------------------------------------|
| **RV32I**        | Base integer instruction set (37 instructions) |
| **M**            | Integer multiply/divide                        |
| **A**            | Atomic memory operations (LR/SC, AMO)          |
| **F**            | Single-precision floating-point (32-bit)       |
| **D**            | Double-precision floating-point (64-bit)       |
| **C**            | Compressed instructions (16-bit encodings)     |
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

- **In-order front-end** (IF → PD → ID) with 64-bit instruction fetch, C-extension decompression, dual decode packets, and combinational CSR reads at decode
- **Tomasulo out-of-order back-end** with register renaming, dynamic scheduling, in-order commit, and precise exceptions
- **2-wide dispatch/rename** — allocates up to two ROB entries per cycle, with intra-bundle RAW handling, second-slot resource checks, and branch checkpointing
- **32-entry ROB** unified across INT and FP, with separate INT and FP register alias tables and 8 branch checkpoint slots
- **2-wide commit** — retires up to two ROB entries per cycle (head + head+1) through 2-write-port INT/FP regfiles
- **6 reservation stations** (INT, MUL, MEM, FP, FMUL, FDIV) — long-latency FP divide isolated so it cannot block FP_RS
- **2-lane CDB result broadcast** — grants the top two FU completions per cycle with fixed-priority arbitration tuned for common integer traffic (`MUL > MEM > ALU > DIV > FP_DIV > FP_MUL > FP_ADD`) and one-deep holding registers per FU
- **Conservative memory disambiguation** — loads gated until older store addresses known, with store-to-load forwarding from the SQ
- **Two-tier branch recovery** — conditional-branch mispredictions use a fast ~2-cycle path (front-end redirect + RAT restore in the same cycle); JALR and exceptions take the slower commit-time path
- **Branch prediction** with a 256-entry 2-bit BTB (trained for conditional branches and JAL, with slot-2 lookup support), 1024-entry bimodal direction predictor, 8-entry return address stack, and PD-stage computed-target redirects for conditional BTB misses predicted taken
- **L0 cache** in front of the load queue reduces load-use latency (direct-mapped, write-through)
- **Machine + User (M/U) privilege modes** for RTOS support — traps from both modes are taken in M-mode (interrupts and exceptions)
- **CLINT-compatible timer** (mtime/mtimecmp) for preemptive scheduling
- **Harvard architecture** with separate instruction and data memory ports
- **Write-back cache hierarchy over DDR** — a 1 GiB cached region at `0x8000_0000` served by recursive line-port caches (`frost_cache`: direct-mapped, 32 B lines, write-back/write-allocate). Both instruction fetch (a 16 KiB read-only L1I) and data (a 128 KiB L1D) run through it on every board — so code can execute from DDR, not just from low BRAM — sharing a 2:1 line-port arbiter (data-side priority), plus a 2 MiB UltraRAM L2 spliced in on UltraScale+, over the board's DDR (DDR3 on Genesys2, DDR4 on X3) through a single-beat AXI bridge
- **One memory map everywhere** — software sees the same layout on every board and in simulation: a 256 KiB fast, uncached BRAM region (code/data/stack, 1-cycle) plus the 1 GiB cached region (execute-from-DDR code, heap, and large data); the hierarchy shape behind it is opaque to software
- **Portable core RTL** — written in generic SystemVerilog with no vendor-specific primitives in the CPU core; CI checks vendor-agnostic elaboration and coarse synthesis, while full FPGA builds are currently Xilinx-focused

## Prerequisites

Validated with these tool versions:

| Category      | Tool              | Version |
|---------------|-------------------|---------|
| **Compiler**  | RISC-V GCC        | 15.2.0  |
| **Testbench** | Cocotb            | 2.0.1   |
| **Simulator** | Verilator         | 5.046   |
| **Synthesis** | Yosys             | 0.64    |
| **Formal**    | SymbiYosys        | 0.63    |
|               | Z3                | 4.15.0  |
|               | Boolector         | 3.2.4   |
| **FPGA**      | Vivado (optional) | 2025.2  |
| **Linting**   | pre-commit        | 4.0     |
|               | clang-format      | 19.0    |
|               | clang-tidy        | 19.0    |
|               | Verible           | 0.0-4051|

## Docker Development Environment

A Docker image is provided with all tools pre-installed for reproducible development:

```bash
# Build the Docker image
docker build -t frost .

# Run interactively (mounts current directory to /workspace)
docker run -it --rm -v $(pwd):/workspace frost

# Inside container, run tests
pytest tests/
./tests/test_run_cocotb.py hello_world
```

The Docker image includes:
- Verilator 5.046 (built from source)
- Yosys 0.64 (built from source)
- SymbiYosys 0.63 + Z3 4.15.0 + Boolector 3.2.4 (formal verification)
- RISC-V GCC 15.2.0 (xPack bare-metal toolchain)
- Python 3.12 with Cocotb 2.0.1 and pytest
- Pre-commit with all linters (clang-format, clang-tidy, Verible, ruff, mypy)

## Setting Up Pre-commit Hooks

Pre-commit hooks run automatically on `git commit` to check code quality:

```bash
# Install hooks (one-time setup, or use Docker)
pre-commit install

# Run all hooks manually
pre-commit run --all-files
```

## Quick Start

Get FROST running in simulation in one command:

```bash
# Run Hello World simulation (compiles automatically)
./tests/test_run_cocotb.py hello_world
```

You should see "Hello, world!" in the output.

### Run the CPU Verification Suite

```bash
make -C tests        # constrained-random regression on the cpu_tb testbench
```

This runs constrained-random instructions through the CPU, verifying each against a software reference model. (The random regression runs on the `cpu_tb` testbench — the `tests/` Makefile default — rather than as a `test_run_cocotb.py` target.)

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
│       ├── arch_test/        # riscv-arch-test compliance (400+ tests)
│       ├── riscv_tests/      # riscv-tests ISA tests (126 tests)
│       ├── riscv_torture/    # Random instruction torture tests (20 tests)
│       ├── coremark/         # CPU benchmark
│       ├── coremark_pro/     # EEMBC CoreMark-PRO suite (DDR-backed heap)
│       ├── freertos_demo/    # FreeRTOS RTOS demo
│       └── ...               # Other applications
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

Applications are compiled automatically when running simulations, loading to FPGA, or building bitstreams. Manual compilation is optional:

```bash
# Compile a specific application
make -C sw/apps/hello_world

# Compile all applications
./sw/apps/build_all_apps.py

# Initialize submodules first for coremark and freertos_demo
git submodule update --init
```

### Running Simulations

```bash
# Using pytest (recommended)
pytest tests/                              # Run all tests
pytest tests/ -s                           # With live output
# Standalone test runner
make -C tests                              # CPU constrained-random verification (cpu_tb)
./tests/test_run_cocotb.py hello_world     # Hello World program
./tests/test_run_cocotb.py isa_test        # ISA compliance
./tests/test_run_cocotb.py coremark        # CoreMark benchmark
./tests/test_run_cocotb.py coremark_pro_core  # CoreMark-PRO workload (all nine:
                                           # _cjpeg/_linear_alg/_loops/_nnet/
                                           # _parser/_radix2/_sha/_zip)
./tests/test_run_cocotb.py ddr_test        # Cached-region (DDR) tier test
./tests/test_run_cocotb.py ddr_heap_test   # Multi-MB malloc through the caches
./tests/test_run_cocotb.py frost_cache     # Cache-hierarchy unit bench (X3 shape)
./tests/test_run_cocotb.py freertos_demo   # FreeRTOS demo

# With waveform output
WAVES=1 make -C tests
```

### Running Synthesis

```bash
# Open-source RTL synthesis checks (Yosys)
./tests/test_run_yosys.py

# FPGA synthesis (Vivado)
./fpga/build/build.py x3                   # Alveo X3
./fpga/build/build.py genesys2             # Genesys2
```

### Pytest Test Coverage

Running `pytest tests/` exercises:

- **CPU verification** — constrained-random instruction sequences validated against Python reference models
- **Directed tests** — atomic operations (LR/SC), trap handling, compressed instructions
- **Architecture compliance** — 400+ tests from the official [riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test) suite across I, M, A, F, D, C, B, K, Zicond, and Zifencei extensions, with signature comparison against Spike golden references (Verilator only, parallelized by extension in CI)
- **ISA pipeline tests** — 126 self-checking tests from [riscv-tests](https://github.com/riscv-software-src/riscv-tests) across rv32ui, rv32um, rv32ua, rv32uf, rv32ud, rv32uc, rv32mi, and B-extension suites, exercising rename, wakeup, CDB arbitration, and OOO commit (Verilator only)
- **Random instruction torture tests** — 20 randomly generated RV32IMAFDC instruction sequences (ALU, multiply/divide, memory, branch, FP, AMO) verified against Spike golden register signatures (Verilator only)
- **C program simulation** — all sample applications (hello_world, coremark, freertos_demo, etc.) run in simulation with pass/fail detection
- **C compilation** — all applications compile successfully with the RISC-V toolchain
- **Yosys synthesis** — RTL passes generic, vendor-agnostic coarse synthesis and full Xilinx 7-series, UltraScale, and UltraScale+ synthesis targets
- **Formal verification** — SymbiYosys bounded model checking and k-induction proofs on select modules verify control and datapath invariants for all possible inputs (see `formal/`)

Most program-level suites run in **two memory tiers as separate CI jobs**: a `bram` tier (whole program in low BRAM — pure ISA correctness) and a `ddr` tier (whole program relocated to the cached DDR region — exercising the L1I fetch path and the D-side cache). Arch compliance keeps the same tier model, but CI skips the very slow F/D DDR permutations because FPU conformance is covered by F/D BRAM jobs and DDR/cache behavior is covered by the other DDR tiers.

### FPGA Deployment

```bash
# 1. Build bitstream (~30-90 min with the DDR subsystem and timing sweeps)
./fpga/build/build.py x3

# 2. Program FPGA
./fpga/program_bitstream/program_bitstream.py x3

# 3. Load software (fast - no re-synthesis)
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
| Digilent Genesys2  | Kintex-7 (xc7k325t)  | 133 MHz   | 128 KiB L1D + 16 KiB L1I → 1 GiB DDR3                 |

Both boards also carry the 256 KiB fast (uncached, 1-cycle) low BRAM region and
present the identical software-visible memory map: `[0, 256 KiB)` fast BRAM,
`[0x8000_0000, +1 GiB)` cached DDR. The CPU is held in reset until the DDR
controller calibrates, so software never observes an uninitialized main memory.


<!-- FPGA_UTILIZATION_START -->

### FPGA Resource Utilization

**Alveo X3522PV** (Virtex UltraScale+ @ 300 MHz)

| Resource | Used | Available | Util% |
|----------|-----:|----------:|------:|
| CLB LUTs | 148,337 | 1,029,600 | 14.4% |
|   LUT as Logic | 138,133 | 1,029,600 | 13.4% |
|   LUT as Distributed RAM | 9,034 | — | — |
|   LUT as Shift Register | 1,170 | — | — |
| CLB Registers | 113,144 | 2,059,200 | 5.5% |
| Block RAM Tile | 240 | 2,112 | 11.4% |
| URAM | 64 | 352 | 18.2% |
| DSPs | 35 | 1,320 | 2.6% |
| CARRY8 | 4,415 | 128,700 | 3.4% |
| F7 Muxes | 208 | 514,800 | 0.0% |
| F8 Muxes | 49 | 257,400 | 0.0% |
| Bonded IOB | 132 | 364 | 36.3% |
| MMCM | 2 | 11 | 18.2% |
| PLL | 3 | 22 | 13.6% |

**Digilent Genesys2** (Kintex-7 @ 133 MHz)

| Resource | Used | Available | Util% |
|----------|-----:|----------:|------:|
| Slice LUTs | 129,281 | 203,800 | 63.4% |
|   LUT as Logic | 120,714 | 203,800 | 59.2% |
|   LUT as Distributed RAM | 7,722 | — | — |
|   LUT as Shift Register | 845 | — | — |
| Slice Registers | 86,734 | 407,600 | 21.3% |
| Block RAM Tile | 189.5 | 445 | 42.6% |
| DSPs | 36 | 840 | 4.3% |
| F7 Muxes | 98 | 101,900 | 0.1% |
| F8 Muxes | 33 | 50,950 | 0.1% |
| Bonded IOB | 77 | 500 | 15.4% |
| MMCM | 3 | 10 | 30.0% |
| PLL | 1 | 10 | 10.0% |

<!-- FPGA_UTILIZATION_END -->

## CPU Internals

For a deeper dive into the OOO design and the cross-cutting decisions that
hold it together, see the CPU README at
[`hw/rtl/cpu_and_mem/cpu/README.md`](hw/rtl/cpu_and_mem/cpu/README.md) and
the Tomasulo back-end README at
[`hw/rtl/cpu_and_mem/cpu/tomasulo/README.md`](hw/rtl/cpu_and_mem/cpu/tomasulo/README.md).
Each Tomasulo submodule (ROB, RAT, dispatch, reservation station, load
queue, store queue, CDB arbiter, FU shims) has its own README under
`hw/rtl/cpu_and_mem/cpu/tomasulo/`.

## Glossary

| Term            | Definition                                       |
|-----------------|--------------------------------------------------|
| **RV32I**       | RISC-V 32-bit base integer instruction set       |
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
| **L1I / L1D**   | Split write-back line caches (16 KiB instruction, 128 KiB data) over the cached DDR region, through a shared 2:1 line-port arbiter |
| **L2 Cache**    | 2 MiB UltraRAM line cache below the L1s (UltraScale+ only)        |
| **Cached region** | `[0x8000_0000, +1 GiB)` — code (execute-from-DDR), heap, and large data, behind L1[/L2]→DDR |
| **BTB**         | Branch Target Buffer (256-entry target predictor) |
| **DirPred**     | 1024-entry bimodal branch-direction predictor    |
| **RAS**         | Return Address Stack (8-entry return predictor)  |
| **MMIO**        | Memory-Mapped I/O                                |
| **CLINT**       | Core Local Interruptor (timer/software interrupts) |
| **Cocotb**      | Python-based verification framework              |
