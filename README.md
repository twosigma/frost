# FROST

**F**PGA **R**ISC-V **O**pen-sourced in **S**ystemVerilog by **T**woSigma

A 6-stage pipelined RISC-V processor implementing **RV32GCB** (G = IMAFD) with full machine-mode privilege support for RTOS operation. Achieves 300 MHz on UltraScale+. Designed for FPGA deployment with clean, portable SystemVerilog.

## Why FROST?

There are many RISC-V cores. Here's what makes FROST different:

- **Fully open-source toolchain** — works with Verilator, Icarus Verilog, and Yosys. No vendor lock-in or expensive commercial tools required.
- **Clean, readable SystemVerilog** — not generated from Chisel or SpinalHDL. Every module is hand-written with extensive documentation, suitable for teaching, learning, and extending.
- **Practical performance** — 1.76 CoreMark/MHz (527 CoreMark at 300 MHz on UltraScale+) with branch prediction (BTB + RAS), L0 cache, and full data forwarding.
- **Layered verification** — constrained-random tests, directed tests, and real C programs all run in Cocotb simulation with pass/fail markers. Bugs that slip past one layer get caught by another. More accessible than SystemVerilog/UVM.
- **Real workloads included** — FreeRTOS demo, CoreMark benchmark, and ISA compliance suite all run in simulation and on hardware.
- **No vendor primitives** — pure portable RTL that works on any target. Synthesis tested via Yosys for generic (ASIC), Xilinx 7-series, UltraScale, and UltraScale+. Board wrappers provided for Artix-7, Kintex-7, and UltraScale+.
- **Apache 2.0 licensed** — permissive license suitable for commercial and academic use.

## Features

```
┌───────────────────────────────────────────────────────────────────────────┐
│                            FROST RISC-V CPU                               │
├───────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                         6-Stage Pipeline                            │  │
│  │  ┌────┐   ┌────┐   ┌────┐   ┌────┐   ┌────┐   ┌────┐                │  │
│  │  │ IF │──>│ PD │──>│ ID │──>│ EX │──>│ MA │──>│ WB │                │  │
│  │  └────┘   └────┘   └────┘   └────┘   └────┘   └────┘                │  │
│  │    │        │                  │        │                           │  │
│  │    │   C-extension      ┌──────┴────────┴──────┐                    │  │
│  │    │   decompression    │   Forwarding Unit    │                    │  │
│  │    │                    └──────────────────────┘                    │  │
│  │    v                                                                │  │
│  │  ┌──────────────┐   ┌─────────────┐   ┌──────────────────────┐      │  │
│  │  │  L0 Cache    │   │  Regfile    │   │      Trap Unit       │      │  │
│  │  │ (load-use    │   │  (32x32)    │   │  (M-mode interrupts  │      │  │
│  │  │  bypass)     │   │             │   │   and exceptions)    │      │  │
│  │  └──────────────┘   └─────────────┘   └──────────────────────┘      │  │
│  │                                                                     │  │
│  │  ┌──────────────┐                                                   │  │
│  │  │     BTB      │  (32-entry 2-bit saturating counter predictor)    │  │
│  │  └──────────────┘                                                   │  │
│  │  ┌──────────────┐                                                   │  │
│  │  │     RAS      │  (8-entry return address stack)                   │  │
│  │  └──────────────┘                                                   │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                           Peripherals                               │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌──────────────┐   │  │
│  │  │    UART    │  │   mtime/   │  │   FIFO0    │  │    FIFO1     │   │  │
│  │  │  (TX/RX)   │  │  mtimecmp  │  │            │  │              │   │  │
│  │  └────────────┘  └────────────┘  └────────────┘  └──────────────┘   │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
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

- **6-stage pipeline** with full data forwarding (IF → PD → ID → EX → MA → WB)
- **Branch prediction** with 32-entry 2-bit BTB and 8-entry return address stack (0-cycle penalty for correct predictions)
- **L0 cache** reduces load-use stalls (direct-mapped, write-through)
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
|               | Icarus Verilog    | 12.0    |
|               | Questa (optional) | 2023.1  |
| **Synthesis** | Yosys             | 0.60    |
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
- Icarus Verilog 12.0
- Yosys 0.60 (built from source)
- RISC-V GCC toolchain
- Cocotb and Python dependencies
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
│       ├── coremark/         # CPU benchmark
│       ├── freertos_demo/    # FreeRTOS RTOS demo
│       └── ...               # Other applications
├── verif/                    # Verification infrastructure
│   ├── cocotb_tests/         # Cocotb test cases
│   ├── models/               # Software reference models
│   ├── encoders/             # Instruction encoding
│   └── monitors/             # Runtime verification
├── tests/                    # Test runners (pytest integration)
├── scripts/                  # Helper scripts (clang-tidy wrapper, etc.)
├── fpga/                     # FPGA build and programming scripts
│   ├── build/                # Vivado synthesis scripts
│   ├── program_bitstream/    # FPGA programming
│   └── load_software/        # Software loading via JTAG
└── boards/                   # Board-specific wrappers
    ├── x3/                   # Alveo X3522PV
    ├── genesys2/             # Digilent Genesys2
    └── nexys_a7/             # Digilent Nexys A7
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
pytest tests/ --sim=verilator              # Use Verilator

# Standalone test runner
./tests/test_run_cocotb.py cpu             # CPU verification
./tests/test_run_cocotb.py hello_world     # Hello World program
./tests/test_run_cocotb.py isa_test        # ISA compliance
./tests/test_run_cocotb.py coremark        # CoreMark benchmark
./tests/test_run_cocotb.py freertos_demo   # FreeRTOS demo

# With specific simulator
./tests/test_run_cocotb.py cpu --sim=verilator
./tests/test_run_cocotb.py cpu --sim=questa --gui
```

### Running Synthesis

```bash
# Open-source synthesis (Yosys)
./tests/test_run_yosys.py

# FPGA synthesis (Vivado)
./fpga/build/build.py x3                   # Alveo X3
./fpga/build/build.py genesys2             # Genesys2
./fpga/build/build.py nexys_a7             # Nexys A7
```

### Pytest Test Coverage

Running `pytest tests/` exercises:

- **CPU verification** — constrained-random instruction sequences validated against Python reference models
- **Directed tests** — atomic operations (LR/SC), trap handling, compressed instructions
- **C program simulation** — all sample applications (hello_world, coremark, freertos_demo, etc.) run in simulation with pass/fail detection
- **C compilation** — all applications compile successfully with the RISC-V toolchain
- **Yosys synthesis** — RTL synthesizes cleanly for generic (ASIC), Xilinx 7-series, UltraScale, and UltraScale+ targets

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
| Digilent Nexys A7  | Artix-7 (xc7a100t)   | 80 MHz    |


<!-- FPGA_UTILIZATION_START -->

### FPGA Resource Utilization

**Alveo X3522PV** (Virtex UltraScale+ @ 300 MHz)

| Resource | Used | Available | Util% |
|----------|-----:|----------:|------:|
| CLB LUTs | 29,433 | 1,029,600 | 2.9% |
|   LUT as Logic | 27,965 | 1,029,600 | 2.7% |
|   LUT as Distributed RAM | 1,168 | — | — |
|   LUT as Shift Register | 300 | — | — |
| CLB Registers | 18,963 | 2,059,200 | 0.9% |
| Block RAM Tile | 68.5 | 2,112 | 3.2% |
| URAM | 0 | 352 | 0.0% |
| DSPs | 28 | 1,320 | 2.1% |
| CARRY8 | 745 | 128,700 | 0.6% |
| F7 Muxes | 307 | 514,800 | 0.1% |
| F8 Muxes | 0 | 257,400 | 0.0% |
| Bonded IOB | 4 | 364 | 1.1% |
| MMCM | 1 | 11 | 9.1% |
| PLL | 0 | 22 | 0.0% |

**Digilent Genesys2** (Kintex-7 @ 133 MHz)

| Resource | Used | Available | Util% |
|----------|-----:|----------:|------:|
| Slice LUTs | 28,094 | 203,800 | 13.8% |
|   LUT as Logic | 26,491 | 203,800 | 13.0% |
|   LUT as Distributed RAM | 1,308 | — | — |
|   LUT as Shift Register | 295 | — | — |
| Slice Registers | 18,500 | 407,600 | 4.5% |
| Block RAM Tile | 68.5 | 445 | 15.4% |
| DSPs | 28 | 840 | 3.3% |
| F7 Muxes | 307 | 101,900 | 0.3% |
| F8 Muxes | 0 | 50,950 | 0.0% |
| Bonded IOB | 6 | 500 | 1.2% |
| MMCM | 1 | 10 | 10.0% |
| PLL | 0 | 10 | 0.0% |

**Digilent Nexys A7** (Artix-7 @ 80 MHz)

| Resource | Used | Available | Util% |
|----------|-----:|----------:|------:|
| Slice LUTs | 28,066 | 63,400 | 44.3% |
|   LUT as Logic | 26,464 | 63,400 | 41.7% |
|   LUT as Distributed RAM | 1,308 | — | — |
|   LUT as Shift Register | 294 | — | — |
| Slice Registers | 18,476 | 126,800 | 14.6% |
| Block RAM Tile | 68.5 | 135 | 50.7% |
| DSPs | 28 | 240 | 11.7% |
| F7 Muxes | 327 | 31,700 | 1.0% |
| F8 Muxes | 0 | 15,850 | 0.0% |
| Bonded IOB | 4 | 210 | 1.9% |
| MMCM | 1 | 6 | 16.7% |
| PLL | 0 | 6 | 0.0% |

<!-- FPGA_UTILIZATION_END -->

## In-Progress: Tomasulo Out-of-Order Execution

An out-of-order execution backend using the Tomasulo algorithm is under active development. This implementation will add dynamic instruction scheduling while preserving the existing front-end (IF/PD/ID) and ISA support.

Key components being built:
- **Reorder Buffer (ROB)** — Unified INT/FP, in-order commit, precise exceptions
- **Register Alias Tables** — Separate INT and FP RATs with checkpoint support
- **Reservation Stations** — INT, MUL, MEM, FP, FMUL, FDIV
- **Load/Store Queues** — Memory disambiguation, store-to-load forwarding

The Tomasulo RTL implementation is being developed in a separate directory alongside the existing in-order pipeline:
`hw/rtl/cpu_and_mem/cpu/tomasulo/`

Once complete, it may replace the in-order processor or remain as an alternative configuration.

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
| **G extension** | Shorthand for IMAFD                               |
| **IF**          | Instruction Fetch stage                          |
| **PD**          | Pre-Decode stage (C extension decompression)     |
| **ID**          | Instruction Decode stage                         |
| **EX**          | Execute stage                                    |
| **MA**          | Memory Access stage                              |
| **WB**          | Write Back stage                                 |
| **L0 Cache**    | Level-0 cache for load-use bypass                |
| **BTB**         | Branch Target Buffer (32-entry branch predictor) |
| **RAS**         | Return Address Stack (8-entry return predictor)   |
| **MMIO**        | Memory-Mapped I/O                                |
| **CLINT**       | Core Local Interruptor (timer/software interrupts) |
| **Cocotb**      | Python-based verification framework              |
