# FROST

**F**PGA **R**ISC-V **O**pen-sourced in **S**ystemVerilog by **T**woSigma

FROST is an out-of-order 64-bit RISC-V (RV64GCB) processor for FPGAs. It runs
Debian 13 and FreeRTOS on the Alveo X3522PV, with 10 Gigabit Ethernet and
1 GiB of DDR4. The X3 achieves 1018 CoreMark at 300 MHz (3.39 CoreMark/MHz).

[![FROST CPU, memory, and peripherals on X3](docs/diagrams/frost-architecture.svg)](docs/diagrams/frost-architecture.svg)

## Features

- Two-wide decode, rename, and commit; 32-entry reorder buffer; precise exceptions.
- Two integer ALUs and hardware single- and double-precision floating point.
- Branch prediction with a 256-entry BTB, 1024-entry direction predictor,
  and 8-entry return stack.
- M/S/U privilege modes, Sv39 virtual memory, and Sstc supervisor timers.
- On X3: 256 KiB local BRAM, 16 KiB L1I, 128 KiB L1D, 2 MiB L2, and 1 GiB DDR4.
- UART, CLINT timer, PLIC interrupt controller, and 10GBASE-R NIC with coherent DMA.
- JTAG halt, resume, single-step, and software breakpoints, with a
  [VS Code extension](tools/vscode-frost/README.md).
- Portable SystemVerilog with separate board integrations; Apache 2.0 license.

### Supported RISC-V Extensions

| Extension | Support |
|-----------|---------|
| RV64I | Base 64-bit integer instructions |
| M | Integer multiply and divide |
| A | LR/SC and AMOs, word and doubleword |
| F, D | Single- and double-precision floating point |
| C | Compressed instructions |
| B | Zba, Zbb, Zbs bit manipulation |
| Zicsr, Zicntr, Zifencei | CSR access, base counters, instruction fence |
| Zicond, Zbkb, Zihintpause | Conditional zero, crypto bit manipulation, pause hint |

See the [CPU guide](hw/rtl/cpu_and_mem/cpu/README.md) for the architecture and
[ROADMAP.md](ROADMAP.md) for planned work.

## Prerequisites

Use Docker for simulation, formal verification, open-source synthesis, and
linting. The image pins CI's tools; see [development tooling](docs/tooling.md).
FPGA builds and board tools run on the host and require a separate Vivado
installation (validated with 2025.2), Python 3.12+, and the
[native RISC-V toolchain](docs/tooling.md#shared-risc-v-toolchain).

## Quick Start

From the repository root:

```bash
docker build -t frost .
./scripts/frost.py doctor
./scripts/frost.py cocotb hello_world
```

The simulation compiles the application and prints `Hello, world!`.
The wrapper initializes submodules, cleans simulation builds, and keeps
outputs owned by your user. Use it for all cocotb runs.

```bash
./scripts/frost.py check                   # CI lint and fast Python tests
./scripts/frost.py cocotb directed_traps    # CPU trap and interrupt tests
FROST_COCOTB_MEM_CONFIG=ddr ./scripts/frost.py cocotb hello_world
WAVES=1 ./scripts/frost.py cocotb directed_traps
./scripts/frost.py shell
```

Lint hooks can modify files; review the diff after running `check` or `lint`.
The [test guide](tests/README.md) covers full suites, compliance, formal, and
synthesis checks.

## FPGA Deployment

Run on the host with Vivado and the RISC-V compiler on PATH:

```bash
git submodule update --init --recursive
./fpga/build/build.py x3
./fpga/program_bitstream/program_bitstream.py x3
./fpga/load_software/load_software.py x3 hello_world
```

The loader compiles the app and replaces software without rebuilding the
bitstream. Read the UART console at **115200 baud, 8N1**, or use the
[FROST extension](tools/vscode-frost/README.md#build-and-install-locally).
See the [FPGA guide](fpga/README.md) for target selection, debugging, and
hardware regression, and the [Debian guide](docs/debian_nfsroot.md) to boot Linux.

## Repository Guide

| Path | Contents |
|------|----------|
| [hw/rtl/](hw/rtl/README.md) | CPU, caches, peripherals, hardware interfaces |
| [sw/](sw/README.md) | Bare-metal applications, libraries, memory map, build options |
| [linux/](linux/README.md) | Linux firmware, boot images, and NIC driver |
| [fpga/](fpga/README.md) | Build, programming, loading, and debug tools |
| [boards/](boards/README.md) | X3 integration, pin constraints, adding boards |
| [tests/](tests/README.md) | Test commands and CI coverage |
| [verif/](verif/README.md) | Testbenches, reference models, monitors |
| [formal/](formal/README.md) | Formal targets and properties |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Development conventions and checks |

<!-- FPGA_UTILIZATION_START -->

### FPGA Resource Utilization

**Alveo X3522PV** (Virtex UltraScale+ @ 300 MHz; final report)

| Resource | Used | Available | Util% |
|----------|-----:|----------:|------:|
| CLB LUTs | 173,711 | 1,029,600 | 16.9% |
|   LUT as Logic | 156,756 | 1,029,600 | 15.2% |
|   LUT as Distributed RAM | 15,884 | — | — |
|   LUT as Shift Register | 1,071 | — | — |
| CLB Registers | 109,257 | 2,059,200 | 5.3% |
| Block RAM Tile | 246 | 2,112 | 11.7% |
| URAM | 68 | 352 | 19.3% |
| DSPs | 47 | 1,320 | 3.6% |
| CARRY8 | 2,601 | 128,700 | 2.0% |
| F7 Muxes | 1,962 | 514,800 | 0.4% |
| F8 Muxes | 926 | 257,400 | 0.4% |
| Bonded IOB | 132 | 364 | 36.3% |
| MMCM | 2 | 11 | 18.2% |
| PLL | 3 | 22 | 13.6% |

<!-- FPGA_UTILIZATION_END -->
