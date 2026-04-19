# FROST

**F**PGA **R**ISC-V **O**pen-sourced in **S**ystemVerilog by **T**woSigma

An out-of-order RISC-V processor implementing **RV32GCB** (G = IMAFD) with a Tomasulo back-end and full machine-mode privilege support for RTOS operation. Achieves 300 MHz on UltraScale+. Designed for FPGA deployment with clean, portable SystemVerilog.

## Why FROST?

There are many RISC-V cores. Here's what makes FROST different:

- **Fully open-source toolchain** — works with Verilator and Yosys. No vendor lock-in or expensive commercial tools required.
- **Native SystemVerilog** — not generated from Chisel or SpinalHDL. Every module is written in native HDL, suitable for understanding and extending.
- **Solid performance** — 2.71 CoreMark/MHz (812 CoreMark at 300 MHz on UltraScale+) from a Tomasulo out-of-order back-end with register renaming, branch prediction (BTB + RAS), an L0 cache, and a fast two-cycle conditional-branch misprediction recovery path.
- **Layered verification** — constrained-random tests, directed tests, real C programs, the official [riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test) compliance suite, [riscv-tests](https://github.com/riscv-software-src/riscv-tests) ISA tests, and random instruction torture tests all run in Cocotb simulation, along with formal verification.
- **Real workloads included** — FreeRTOS demo, CoreMark benchmark, ISA compliance suite, and 400+ architecture compliance tests all run in simulation and on hardware.
- **No vendor primitives** — pure portable RTL that works on any target. Synthesis tested via Yosys for generic (ASIC), Xilinx 7-series, UltraScale, and UltraScale+. Board wrappers provided for Kintex-7 and UltraScale+.
- **Apache 2.0 licensed** — permissive license suitable for commercial and academic use.

## Features

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              FROST RISC-V CPU                                │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   In-order front-end                                                         │
│   ┌────┐   ┌────┐   ┌────┐    dispatch / rename / resource alloc             │
│   │ IF │──>│ PD │──>│ ID │──────────────────────────────┐                    │
│   └────┘   └────┘   └────┘                              │                    │
│     ▲      C-ext     CSR rd                             ▼                    │
│     │      expand                          ┌─────────────────────────────┐   │
│     │                                      │   ROB  (32 entries)         │   │
│     │   ┌─────────────┐                    │   RAT  (INT + FP, 4 ckpts)  │   │
│     │   │ BTB (32×2b) │                    └──────────────┬──────────────┘   │
│     │   │ RAS (8)     │                                   │ issue            │
│     │   └─────────────┘                                   ▼                  │
│     │                          ┌──────────────────────────────────────────┐  │
│     │                          │  6 reservation stations                  │  │
│     │                          │  INT  MUL  MEM  FP  FMUL  FDIV           │  │
│     │                          │  (8)  (4)  (8)  (6)  (4)   (2)           │  │
│     │                          └──────────────┬───────────────────────────┘  │
│     │                                         ▼                              │
│     │                          FU shims (ALU, MUL/DIV, FPU)                  │
│     │                          LQ + L0 cache, SQ                             │
│     │                                         │                              │
│     │                                         ▼                              │
│     │                          CDB (1 lane, fixed priority)                  │
│     │                          broadcasts result; wakes RS, marks ROB done   │
│     │                                         │                              │
│     │                                         ▼                              │
│     │                            commit ──> INT / FP regfiles                │
│     │                                        SQ release, trap, redirect      │
│     │                                                                        │
│     └─── early mispredict recovery (~2 cycles): redirect IF + restore RAT    │
│                                                                              │
│   ┌──────────────────────────┐    ┌─────────────────────────────────────┐    │
│   │ Trap Unit                │    │ Peripherals                         │    │
│   │ (M-mode, mret, wfi,      │    │ UART, mtime/mtimecmp, FIFO0/1       │    │
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

### Architecture Highlights

- **In-order front-end** (IF → PD → ID) with 64-bit instruction fetch, C-extension decompression, and combinational CSR reads at decode
- **Tomasulo out-of-order back-end** with register renaming, dynamic scheduling, in-order commit, and precise exceptions
- **32-entry ROB** unified across INT and FP, with separate INT and FP register alias tables and 4 branch checkpoint slots
- **6 reservation stations** (INT, MUL, MEM, FP, FMUL, FDIV) — long-latency FP divide isolated so it cannot block FP_RS
- **Single-CDB result broadcast** with fixed-priority arbitration (longest-latency wins) and one-deep holding registers per FU
- **Conservative memory disambiguation** — loads gated until older store addresses known, with store-to-load forwarding from the SQ
- **Two-tier branch recovery** — conditional-branch mispredictions use a fast ~2-cycle path (front-end redirect + RAT restore in the same cycle); JALR and exceptions take the slower commit-time path
- **Branch prediction** with 32-entry 2-bit BTB (trained for both conditional branches and JAL), 8-entry return address stack, and a backward-branch-taken static fallback for cold BTB lookups
- **L0 cache** in front of the load queue reduces load-use latency (direct-mapped, write-through)
- **M-mode trap handling** for RTOS support (interrupts and exceptions)
- **CLINT-compatible timer** (mtime/mtimecmp) for preemptive scheduling
- **Harvard architecture** with separate instruction and data memory ports
- **Portable design** — pure generic RTL with no vendor-specific primitives, suitable for any FPGA or ASIC target

## Prerequisites

Validated with these tool versions:

| Category      | Tool              | Version |
|---------------|-------------------|---------|
| **Compiler**  | RISC-V GCC        | 15.2.0  |
| **Testbench** | Cocotb            | 2.0.1   |
| **Simulator** | Verilator         | 5.044   |
| **Synthesis** | Yosys             | 0.60    |
| **Formal**    | SymbiYosys        | 0.62    |
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
- Verilator 5.044 (built from source)
- Yosys 0.60 (built from source)
- SymbiYosys 0.62 + Z3 4.15.0 + Boolector 3.2.4 (formal verification)
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
./tests/test_run_cocotb.py cpu
```

This runs constrained-random instructions through the CPU, verifying each against a software reference model.

## Directory Structure

```
frost/
├── README.md                 # This file
├── hw/                       # Hardware (RTL)
│   ├── rtl/                  # Synthesizable RTL source
│   │   ├── frost.sv          # Top-level module
│   │   ├── frost.f           # File list for synthesis/simulation
│   │   ├── cpu_and_mem/      # CPU core and memory subsystem
│   │   ├── lib/              # Generic FPGA library (RAM, FIFO)
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
./tests/test_run_cocotb.py cpu             # CPU verification
./tests/test_run_cocotb.py hello_world     # Hello World program
./tests/test_run_cocotb.py isa_test        # ISA compliance
./tests/test_run_cocotb.py coremark        # CoreMark benchmark
./tests/test_run_cocotb.py freertos_demo   # FreeRTOS demo

# With waveform output
WAVES=1 ./tests/test_run_cocotb.py cpu
```

### Running Synthesis

```bash
# Open-source synthesis (Yosys)
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
- **Yosys synthesis** — RTL synthesizes cleanly for generic (ASIC), Xilinx 7-series, UltraScale, and UltraScale+ targets
- **Formal verification** — SymbiYosys bounded model checking and k-induction proofs on select modules verify control and datapath invariants for all possible inputs (see `formal/`)

### FPGA Deployment

```bash
# 1. Build bitstream (~15-30 min)
./fpga/build/build.py x3

# 2. Program FPGA
./fpga/program_bitstream/program_bitstream.py x3

# 3. Load software (fast - no re-synthesis)
./fpga/load_software/load_software.py x3 hello_world
./fpga/load_software/load_software.py x3 coremark
./fpga/load_software/load_software.py x3 isa_test
```

## Supported FPGA Boards

| Board              | FPGA                 | CPU Clock |
|--------------------|----------------------|-----------|
| Alveo X3522PV      | UltraScale+ (xcux35) | 300 MHz   |
| Digilent Genesys2  | Kintex-7 (xc7k325t)  | 133 MHz   |


<!-- FPGA_UTILIZATION_START -->

### FPGA Resource Utilization

**Alveo X3522PV** (Virtex UltraScale+ @ 300 MHz)

| Resource | Used | Available | Util% |
|----------|-----:|----------:|------:|
| CLB LUTs | 80,836 | 1,029,600 | 7.8% |
|   LUT as Logic | 68,668 | 1,029,600 | 6.7% |
|   LUT as Distributed RAM | 11,584 | — | — |
|   LUT as Shift Register | 584 | — | — |
| CLB Registers | 58,802 | 2,059,200 | 2.9% |
| Block RAM Tile | 53.5 | 2,112 | 2.5% |
| URAM | 0 | 352 | 0.0% |
| DSPs | 32 | 1,320 | 2.4% |
| CARRY8 | 4,422 | 128,700 | 3.4% |
| F7 Muxes | 6,338 | 514,800 | 1.2% |
| F8 Muxes | 2,336 | 257,400 | 0.9% |
| Bonded IOB | 4 | 364 | 1.1% |
| MMCM | 1 | 11 | 9.1% |
| PLL | 0 | 22 | 0.0% |

**Digilent Genesys2** (Kintex-7 @ 133 MHz)

| Resource | Used | Available | Util% |
|----------|-----:|----------:|------:|
| Slice LUTs | 60,149 | 203,800 | 29.5% |
|   LUT as Logic | 57,120 | 203,800 | 28.0% |
|   LUT as Distributed RAM | 2,476 | — | — |
|   LUT as Shift Register | 553 | — | — |
| Slice Registers | 46,374 | 407,600 | 11.4% |
| Block RAM Tile | 70.5 | 445 | 15.8% |
| DSPs | 40 | 840 | 4.8% |
| F7 Muxes | 915 | 101,900 | 0.9% |
| F8 Muxes | 32 | 50,950 | 0.1% |
| Bonded IOB | 6 | 500 | 1.2% |
| MMCM | 1 | 10 | 10.0% |
| PLL | 0 | 10 | 0.0% |

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
| **ID**          | Instruction Decode + dispatch / rename           |
| **OOO**         | Out-of-order execution                           |
| **Tomasulo**    | OOO scheduling algorithm with register renaming  |
| **ROB**         | Reorder Buffer (32-entry, in-order commit)       |
| **RAT**         | Register Alias Table (INT + FP rename, 4 ckpts)  |
| **RS**          | Reservation Station (per-FU instruction window)  |
| **LQ**          | Load Queue (in-flight loads, L0 cache, MMIO)     |
| **SQ**          | Store Queue (non-speculative, store-to-load fwd) |
| **CDB**         | Common Data Bus (single-lane result broadcast)   |
| **FU**          | Functional Unit (ALU, MUL/DIV, FPU, …)           |
| **L0 Cache**    | Level-0 cache for load-use bypass                |
| **BTB**         | Branch Target Buffer (32-entry branch predictor) |
| **RAS**         | Return Address Stack (8-entry return predictor)  |
| **MMIO**        | Memory-Mapped I/O                                |
| **CLINT**       | Core Local Interruptor (timer/software interrupts) |
| **Cocotb**      | Python-based verification framework              |
