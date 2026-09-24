# FROST

**F**PGA **R**ISC-V **O**pen-sourced in **S**ystemVerilog by **T**woSigma

FROST is an out-of-order 64-bit RISC-V (RV64GCB) processor written in
SystemVerilog for FPGAs. It runs at **322.265625 MHz** on the Alveo X3522PV,
with Debian 13, FreeRTOS, 10 Gigabit Ethernet and 1 GiB of DDR4.

## Why FROST?

- **Performance:** **3.91 CoreMark/MHz** with profile-guided optimization (PGO).
- **Full Debian Linux:** Debian 13 with its stock riscv64 kernel, systemd,
  and a root filesystem served over NFS. [Setup guide](docs/debian_nfsroot.md).
- **10 Gigabit Ethernet:** an integrated NIC with a Linux driver and coherent DMA.
- **Real workloads:** FreeRTOS and all nine EEMBC CoreMark-PRO benchmarks.
- **Open-source tools:** Verilator for simulation, Yosys for synthesis checks,
  and SymbiYosys for formal verification, all included in the Docker image.
  Full FPGA bitstreams require proprietary Vivado on the host.
- **Portable RTL:** generic SystemVerilog with separate board integrations.
- **VS Code support:** program the FPGA, load software, debug, and use the
  serial console with the [FROST extension](tools/vscode-frost/README.md).
- **Apache 2.0 license** for commercial and academic use.

## Features

[![FROST architecture: two-wide out-of-order CPU, Sv39 translation, X3 cache hierarchy, and system peripherals](docs/diagrams/frost-architecture.svg)](docs/diagrams/frost-architecture.svg)

The diagram shows the X3 configuration. Click to view it at full size.

### Supported RISC-V Extensions

**ISA: RV64GCB** (G = IMAFD) plus the extensions below, over 200 instructions.

| Extension        | Description                                    |
|------------------|------------------------------------------------|
| **RV64I**        | Base 64-bit integer instruction set |
| **M**            | Integer multiply/divide                        |
| **A**            | Atomic memory operations (LR/SC, AMO; word and doubleword) |
| **F**            | Single-precision floating-point (32-bit)       |
| **D**            | Double-precision floating-point (64-bit)       |
| **C**            | Compressed instructions (16-bit encodings) |
| **B**            | Bit manipulation (B = Zba + Zbb + Zbs)         |
| **Zicsr**        | CSR access instructions                        |
| **Zicntr**       | Base counters (cycle, time, instret)           |
| **Zifencei**     | Instruction fence                              |
| **Zicond**       | Conditional zero                               |
| **Zbkb**         | Bit manipulation for crypto                    |
| **Zihintpause**  | Pause hint for spin-wait loops                 |
| **Machine Mode** | M-mode privilege (mret, wfi, ecall, ebreak)    |
| **Supervisor Mode** | S-mode privilege, trap delegation, Sv39 virtual memory, Sstc timers |
| **User Mode**    | U-mode privilege and system calls |

### Architecture Highlights

- Tomasulo out-of-order execution with 2-wide decode, rename, and commit,
  a 32-entry reorder buffer, and precise exceptions.
- Six reservation stations, two integer ALUs, and hardware single- and
  double-precision floating point.
- Branch prediction with a 256-entry BTB, 1024-entry direction predictor,
  and 8-entry return stack; roughly two-cycle conditional-branch recovery.
- Sv39 virtual memory with hardware page-table walks and separate instruction
  and data TLBs.
- Separate instruction and data ports. On X3: 16 KiB L1I, 128 KiB L1D,
  2 MiB L2, and a load-queue L0 cache. DMA is coherent with the data caches.
- 256 KiB of local BRAM and 1 GiB of cached DDR, with the same [memory map](sw/README.md#memory-map)
  in simulation and on hardware.
- UART, CLINT-compatible timer, PLIC interrupt controller, and 10GBASE-R Ethernet.
- JTAG debugging with halt, resume, and single-step.

See the [RTL guide](hw/rtl/README.md) and
[CPU internals](hw/rtl/cpu_and_mem/cpu/README.md) for implementation details.

## Prerequisites

The Docker image includes RISC-V GCC and tools for simulation, open-source
synthesis, formal verification, and linting. Full FPGA bitstreams require
proprietary Vivado, installed separately on the host. Tool versions:

| Category | Tool | Version |
|----------|------|---------|
| **Image** | Ubuntu | 26.04 |
| **Runtime** | Python | 3.14.7 (native scripts support 3.12+) |
| | Node.js / npm | 26.9.0 / 12.0.2 |
| **Compiler** | Native GCC / G++ | 16.2.0 |
| | Clang / clang-tidy / clang-format | 23.1.1 |
| | RISC-V GCC for bare metal, OpenSBI and Linux (Bootlin musl) | 15.3.0 (2026.08-1) |
| | pip / setuptools / wheel | 26.2.1 / 84.0.0 / 0.48.0 |
| **Build** | CMake / Meson / Ninja | 4.4.3 / 1.12.0 / 1.13.2 |
| | Buildroot / OpenSBI | 2026.08 / 1.9 |
| **Testbench** | Cocotb / pytest / pytest-cov | 2.1.0 / 9.1.1 / 7.1.0 |
| **Simulator** | Verilator / QEMU | 5.052 / 11.1.1 |
| | Spike | `02b1dc182164bb73b19b050676dd89f0834f8b2e` |
| **Synthesis** | Yosys / sv2v | 0.69 / 0.0.13 |
| **Formal** | SymbiYosys / Z3 / Boolector | 0.69 / 5.1.0 / 3.2.4 |
| **Debug** | OpenOCD | 0.12.0 |
| **FPGA** | Vivado (native, separately installed and validated) | 2025.2 |
| **Linting** | pre-commit / Ruff / mypy | 4.6.2 / 0.16.8 / 2.3.1 |
| | Verible | 0.0-4294-gc1d8f5e8 |
| **CLI** | Click | 8.5.0 |
| **Extension** | TypeScript / vsce | 7.0.2 / 4.0.0 |

Pins were checked against upstream stable releases on 2026-09-21; see the
[tooling update notes](docs/tooling.md) for sources, compatibility constraints,
and validation commands. Ubuntu supplies the remaining system utilities and
libraries with its current security updates.

## Docker Development Environment

Build the Docker image once, then use the repository wrapper. It keeps
container outputs owned by the invoking UID/GID:

```bash
# Build the Docker image
docker build -t frost .

# Check the local setup (read-only)
./scripts/frost.py doctor

# Run a clean Hello World cocotb simulation
./scripts/frost.py cocotb hello_world

# Open an interactive shell when needed
./scripts/frost.py shell
```

The wrapper initializes submodules automatically. Use it for all cocotb runs
to match CI's tools and clean stale simulation builds.

## Running Code-Quality Checks

Run the `Lint` and `Fast Python Tests` CI gates with:

```bash
./scripts/frost.py check
```

The lint hooks may modify files; review the resulting diff. Use
`./scripts/frost.py lint` for lint alone, or add `--fail-fast` to `check` to
stop after the first failing phase. Simulation and formal checks run separately;
see the [test guide](tests/README.md).

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

This runs unit tests and real programs. See the [test guide](tests/README.md)
for ISA compliance suites, randomized instruction tests, and individual targets.

## Directory Structure

| Directory | Contents |
|-----------|----------|
| [hw/rtl/](hw/rtl/README.md) | CPU, caches, peripherals, and reusable hardware blocks |
| [sw/](sw/README.md) | Bare-metal libraries, applications, and benchmarks |
| [linux/](linux/README.md) | Linux boot images, firmware, and NIC driver |
| [fpga/](fpga/README.md) | FPGA build, programming, and software-loading tools |
| [boards/](boards/README.md) | Board wrappers and pin constraints |
| [tests/](tests/README.md) | Test runners |
| [verif/](verif/README.md) | Cocotb tests, reference models, and monitors |
| [formal/](formal/README.md) | Formal verification |
| [tools/vscode-frost/](tools/vscode-frost/README.md) | VS Code extension |
| [scripts/](scripts/) | Docker wrapper and development tools |

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
./scripts/frost.py cocotb coremark_pro_core # CoreMark-PRO core workload
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
./fpga/build/build.py x3 --cpu-base-clock-hz 322265625
```

### CI Test Coverage

CI runs RISC-V compliance suites, Spike-referenced random instruction tests,
C programs, peripheral tests, synthesis checks, and formal verification.
See the [test guide](tests/README.md#ci-integration) for coverage and commands.

### FPGA Deployment

```bash
# 1. Build bitstream (~30-90 min with the DDR subsystem and timing sweeps)
./fpga/build/build.py x3 --cpu-base-clock-hz 322265625

# 2. Program FPGA
./fpga/program_bitstream/program_bitstream.py x3

# 3. Load software (fast, no re-synthesis)
export FROST_CPU_CLK_HZ=322265625
./fpga/load_software/load_software.py x3 hello_world
./fpga/load_software/load_software.py x3 coremark
./fpga/load_software/load_software.py x3 isa_test

# CoreMark-PRO (-v1 = validation, -v0 = performance)
./fpga/load_software/load_software.py x3 coremark_pro_core -v1
./fpga/load_software/load_software.py x3 coremark_pro_radix2 -v1
```

Use a serial terminal configured for 115200 baud, 8 data bits, no parity, and
1 stop bit (8N1) to view the board UART console, or use the extension's
integrated **FROST Serial** terminal below.

### VS Code Extension

The [FROST FPGA Debugger](tools/vscode-frost/README.md) provides programming,
software loading, source breakpoints, stepping, register inspection, and a
serial console. Follow its [installation guide](tools/vscode-frost/README.md#build-and-install-locally),
then run **FROST: Configure Target** from the Command Palette.

## Supported FPGA Boards

| Board              | FPGA                 | CPU Clock  | Cache hierarchy → main memory               |
|--------------------|----------------------|------------|---------------------------------------------|
| Alveo X3522PV      | UltraScale+ (xcux35) | 322.27 MHz | 128 KiB L1D + 16 KiB L1I → 2 MiB URAM L2 → 1 GiB DDR4 |

See the [board guide](boards/README.md) for pinouts, clocking, and adding a board.

<!-- FPGA_UTILIZATION_START -->

### FPGA Resource Utilization

**Alveo X3522PV** (Virtex UltraScale+; 322.27 MHz, counters off)

| Resource | Used | Available | Util% |
|----------|-----:|----------:|------:|
| CLB LUTs | 187,812 | 1,029,600 | 18.2% |
|   LUT as Logic | 169,295 | 1,029,600 | 16.4% |
|   LUT as Distributed RAM | 17,218 | — | — |
|   LUT as Shift Register | 1,299 | — | — |
| CLB Registers | 114,206 | 2,059,200 | 5.5% |
| Block RAM Tile | 360 | 2,112 | 17.1% |
| URAM | 68 | 352 | 19.3% |
| DSPs | 51 | 1,320 | 3.9% |
| CARRY8 | 2,735 | 128,700 | 2.1% |
| F7 Muxes | 1,962 | 514,800 | 0.4% |
| F8 Muxes | 926 | 257,400 | 0.4% |
| Bonded IOB | 132 | 364 | 36.3% |
| MMCM | 2 | 11 | 18.2% |
| PLL | 3 | 22 | 13.6% |

<!-- FPGA_UTILIZATION_END -->

## Roadmap

See [ROADMAP.md](ROADMAP.md) for current work and planned features, including SMP.

## CPU Internals

The [CPU README](hw/rtl/cpu_and_mem/cpu/README.md) and
[Tomasulo README](hw/rtl/cpu_and_mem/cpu/tomasulo/README.md) describe the OOO
design and cross-cutting decisions. Each Tomasulo submodule also has a README
under `hw/rtl/cpu_and_mem/cpu/tomasulo/`.
