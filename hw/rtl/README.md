# FROST RTL

This directory contains the synthesizable SystemVerilog for FROST. The current
CPU is an **out-of-order RV32GCB implementation with a 2-wide front-end and
2-wide commit**: a 2-wide in-order IF/PD/ID front-end, Tomasulo register renaming
and dynamic scheduling, out-of-order execution across six function units, and
precise 2-wide in-order commit, with machine-mode traps and separate
instruction/data memory ports.

The pipeline width is **asymmetric**. Fetch, decode, rename, ROB allocation,
result writeback, and commit can each move up to two instructions or completions
per cycle, but each reservation station still issues only one operation per
cycle and there is one integer ALU. Result writeback uses a **2-lane common data
bus**: the arbiter grants the top two FU completions in fixed-priority order,
while aligned plain stores bypass the CDB. Lane 0 remains on the same-cycle RS
issue bypass path; lane 1 updates the ROB and registered RS wakeup /
dispatch-capture paths, so a resident consumer wakes one cycle later by design.
Different function units can still execute concurrently — up to six reservation
stations can issue in the same cycle — but this is not a fully symmetric
2-issue execution engine.

The RTL is intended to stay portable: the core uses generic SystemVerilog and
is built in CI with Verilator for simulation plus Yosys for vendor-agnostic
coarse synthesis checks. Full board synthesis is currently Xilinx-focused and
lives under `fpga/` and `boards/`.

`frost.f` is the source of truth for file ordering and inclusion.

## Top-Level Shape

```
frost.sv
  cpu_and_mem.sv
    instruction RAM  <---- JTAG/software-load port on clk_div4
    data RAM
    MMIO timer/UART/FIFOs
    cpu_ooo.sv
      IF -> PD -> ID -> 2-wide dispatch
                         ROB / RAT / RS / LQ / SQ / CDBx2
                         FU shims around ALU, MUL/DIV, FPU
                         2-wide commit -> INT/FP regfiles
  UART clock-domain crossing FIFOs
```

The front-end is still staged as IF, PD, and ID:

| Stage | Main Files | Role |
|-------|------------|------|
| IF | `cpu_and_mem/cpu/if_stage/` | 64-bit fetch window, PC control, BTB + bimodal direction predictor + RAS, slot-2 BTB lookup, RVC parcel alignment |
| PD | `cpu_and_mem/cpu/pd_stage/` | RVC decompression, instruction selection, PD-stage computed-target redirect for predicted-taken conditional BTB misses, early source extraction for both dispatch slots |
| ID | `cpu_and_mem/cpu/id_stage/` | Decode, immediate generation, branch target precompute, CSR reads, two registered dispatch packets |

The conditional-branch predictor is split between target and direction. The BTB
still supplies targets for BTB hits, while a separate 1024-entry bimodal
direction predictor is trained from committed conditional branches. IF carries
the predicted direction and predict-time direction index with the instruction;
PD uses that direction to compute `PC + imm` and redirect immediately when a
conditional branch misses the BTB but is predicted taken.

After ID, `tomasulo/dispatch/dispatch.sv` allocates Tomasulo resources for one
or two instructions per cycle and sends work to
`tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv`. The wrapper owns the ROB,
RATs, reservation stations, load/store queues, CDB arbiter, FU shims, and
profiling counters; its former inline glue now lives in private submodules under
`tomasulo_wrapper/` (see below). See [cpu/README.md](cpu_and_mem/cpu/README.md)
and [cpu/tomasulo/README.md](cpu_and_mem/cpu/tomasulo/README.md) for the detailed
backend notes.

## Directory Map

| Path | Status | Notes |
|------|--------|-------|
| `frost.sv` | In use | Chip-level wrapper around CPU/memory and UART/FIFO CDC |
| `frost.f` | In use | Authoritative RTL file list |
| `cpu_and_mem/` | In use | CPU, RAMs, MMIO timer/UART/FIFO interface |
| `cpu_and_mem/imem_predecode.sv` | In use | Instruction RAM with 64-bit fetch (even/odd interleaved BRAM banks) and predecode sideband |
| `cpu_and_mem/cpu/cpu_ooo/` | In use | CPU integration top (`cpu_ooo.sv`) for the Tomasulo core, plus the OOO-core glue submodules extracted from it (register files, front-end validity, branch resolution / recovery / flush, commit, pipeline control, memory-port router, from_ex_comb, perf counters) |
| `cpu_and_mem/cpu/tomasulo/` | In use | ROB, RAT, RS, LQ, SQ, 2-lane CDB, dispatch glue, FU shims. Larger modules nest their extracted submodules: `tomasulo_wrapper/{perf,commit_bus,dispatch_routing,store_addr,atomics}/`, `store_queue/sq_forwarding_unit`, `load_queue/{load_unit,lq_l0_cache,lq_issue_selector}`, `reorder_buffer/rob_serializer` (each a pure boundary move — see the per-module READMEs) |
| `cpu_and_mem/cpu/if_stage/`, `pd_stage/`, `id_stage/` | In use | Reused front-end stages |
| `cpu_and_mem/cpu/csr/` | In use | Zicsr/Zicntr/fcsr support |
| `cpu_and_mem/cpu/wb_stage/generic_regfile.sv` | In use | Parameterized INT/FP regfiles for OOO commit |
| `cpu_and_mem/cpu/ex_stage/` | In use | Shared ALU, multiplier/divider, FPU, and `branch_jump_unit.sv` used by the OOO core and FU shims |
| `cpu_and_mem/cpu/control/trap_unit.sv` | In use | Machine-mode exception/interrupt handling |
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

# Open-source RTL synthesis checks
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
