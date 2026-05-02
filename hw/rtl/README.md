# FROST RTL

This directory contains the synthesizable SystemVerilog for FROST. The current
CPU is a Tomasulo out-of-order RV32GCB implementation with an in-order
IF/PD/ID front-end, register renaming, dynamic scheduling, precise in-order
commit, machine-mode traps, and separate instruction/data memory ports.

The RTL is intended to stay portable: the core uses generic SystemVerilog and
is built in CI with Verilator for simulation and Yosys for synthesis checks.
Vivado board builds live under `fpga/` and `boards/`.

`frost.f` is the source of truth for file ordering and inclusion.

## Top-Level Shape

```
frost.sv
  cpu_and_mem.sv
    instruction RAM  <---- JTAG/software-load port on clk_div4
    data RAM
    MMIO timer/UART/FIFOs
    cpu_ooo.sv
      IF -> PD -> ID -> dispatch
                         ROB / RAT / RS / LQ / SQ / CDB
                         FU shims around ALU, MUL/DIV, FPU
                         2-wide commit -> INT/FP regfiles
  UART clock-domain crossing FIFOs
```

The front-end is still staged as IF, PD, and ID:

| Stage | Main Files | Role |
|-------|------------|------|
| IF | `cpu_and_mem/cpu/if_stage/` | 64-bit fetch window, PC control, BTB/RAS prediction, RVC parcel alignment |
| PD | `cpu_and_mem/cpu/pd_stage/` | RVC decompression, instruction selection, early source extraction |
| ID | `cpu_and_mem/cpu/id_stage/` | Decode, immediate generation, branch target precompute, CSR reads |

After ID, `dispatch/dispatch.sv` allocates Tomasulo resources and sends work
to `tomasulo/tomasulo_wrapper.sv`. The wrapper owns the ROB, RATs,
reservation stations, load/store queues, CDB arbiter, FU shims, and profiling
counters. See [cpu/README.md](cpu_and_mem/cpu/README.md) and
[cpu/tomasulo/README.md](cpu_and_mem/cpu/tomasulo/README.md) for the detailed
backend notes.

## Directory Map

| Path | Status | Notes |
|------|--------|-------|
| `frost.sv` | In use | Chip-level wrapper around CPU/memory and UART/FIFO CDC |
| `frost.f` | In use | Authoritative RTL file list |
| `cpu_and_mem/` | In use | CPU, RAMs, MMIO timer/UART/FIFO interface |
| `cpu_and_mem/cpu/cpu_ooo.sv` | In use | CPU integration top for the Tomasulo core |
| `cpu_and_mem/cpu/tomasulo/` | In use | ROB, RAT, RS, LQ, SQ, CDB, dispatch glue, FU shims |
| `cpu_and_mem/cpu/if_stage/`, `pd_stage/`, `id_stage/` | In use | Reused front-end stages |
| `cpu_and_mem/cpu/csr/` | In use | Zicsr/Zicntr/fcsr support |
| `cpu_and_mem/cpu/wb_stage/generic_regfile.sv` | In use | Parameterized INT/FP regfiles for OOO commit |
| `cpu_and_mem/cpu/ex_stage/` | Reused/legacy mix | ALU, MUL/DIV, FPU, branch unit reused through shims; old EX-stage wrapper is not in `cpu_ooo.f` |
| `cpu_and_mem/cpu/ma_stage/`, `cache/` | Legacy in-order backend | Replaced in the OOO build by LQ/SQ and `tomasulo/load_queue/lq_l0_cache.sv` |
| `cpu_and_mem/cpu/control/` | Reused/legacy mix | `trap_unit.sv` is reused; old hazard/forwarding logic is legacy |
| `lib/` | In use | Portable RAM/FIFO/stall helper primitives |
| `peripherals/` | In use | UART TX/RX blocks |

## Memory Map

The default hardware memory size is 128 KiB. The common linker script splits it
into 96 KiB ROM and 32 KiB RAM:

| Region | Address | Size | Description |
|--------|---------|------|-------------|
| ROM | `0x0000_0000` | 96 KiB | Code and read-only data |
| RAM | `0x0001_8000` | 32 KiB | Data, BSS, heap, stack |
| MMIO | `0x4000_0000` | 44 B | UART, FIFOs, CLINT-style timer, software interrupt |

MMIO registers:

| Address | Name | Description |
|---------|------|-------------|
| `0x4000_0000` | UART_TX | UART transmit write |
| `0x4000_0004` | UART_RX_DATA | UART receive read, pops one byte |
| `0x4000_0008` | FIFO0 | MMIO FIFO channel 0 |
| `0x4000_000C` | FIFO1 | MMIO FIFO channel 1 |
| `0x4000_0010` | MTIME_LO | Machine timer low word |
| `0x4000_0014` | MTIME_HI | Machine timer high word |
| `0x4000_0018` | MTIMECMP_LO | Timer compare low word |
| `0x4000_001C` | MTIMECMP_HI | Timer compare high word |
| `0x4000_0020` | MSIP | Machine software interrupt pending |
| `0x4000_0024` | UART_RX_STATUS | Bit 0 is data available |
| `0x4000_0028` | UART_TX_STATUS | Bit 0 is can accept byte |

The hardware UART console is configured for 115200 baud, 8 data bits, no
parity, and 1 stop bit (8N1).

If these addresses change, update `cpu_and_mem.sv`, `cpu_ooo.sv` parameters,
`sw/common/link.ld`, `sw/lib/include/mmio.h`, and the verification constants in
`verif/config.py`.

## Build and Simulation

From the repo root:

```bash
# Cocotb/Verilator simulation
./tests/test_run_cocotb.py hello_world
./tests/test_run_cocotb.py cpu

# Open-source synthesis check
./tests/test_run_yosys.py

# Vivado FPGA builds
./fpga/build/build.py x3
./fpga/build/build.py genesys2
```

The top-level simulation file list is:

```bash
sed -n '1,200p' hw/rtl/frost.f
```

The CPU build file list is:

```bash
sed -n '1,200p' hw/rtl/cpu_and_mem/cpu/cpu_ooo.f
```

## Parameters

| Module | Parameter | Default | Description |
|--------|-----------|---------|-------------|
| `frost.sv` | `CLK_FREQ_HZ` | `300000000` | Main CPU clock frequency |
| `frost.sv` | `MEM_SIZE_BYTES` | `2 ** 17` | 128 KiB RAM |
| `frost.sv` | `SIM_TIMER_SPEEDUP` | `1` | Multiplies `mtime` increment rate for simulation |
| `cpu_ooo.sv` | `MMIO_ADDR` | `32'h4000_0000` | MMIO base |
| `cpu_ooo.sv` | `MMIO_SIZE_BYTES` | `32'h2C` | MMIO range size |

Simulation can override memory size through Verilator generics; the test
Makefile currently uses 2 MiB for full-program and compliance workloads.

## Notes for RTL Changes

- Keep `frost.f` and nested `.f` files authoritative.
- Prefer generic RTL over vendor primitives in the core.
- Update the root README, this file, and the relevant submodule README when
  changing architecture-visible behavior.
- Run Verilator tests for functional changes and Yosys/formal checks for shared
  blocks where practical.

## License

Copyright 2026 Two Sigma Open Source, LLC

Licensed under the Apache License, Version 2.0.
