# FROST RTL

Synthesizable SystemVerilog for the RV64GCB CPU, memory system, and
peripherals. The RV64-only CPU has Tomasulo out-of-order execution, up to two
instructions per cycle through decode, rename, and commit, M/S/U privilege
modes, and Sv39 virtual memory.

The core uses portable RTL, with optional Xilinx primitive implementations
selected by `FROST_XILINX_PRIMS`. Xilinx board integration lives in `boards/`
and `fpga/`. `frost.f` defines the source list and compilation order.

## Top-Level Shape

The shared [CPU and system architecture diagram](../../docs/diagrams/frost-architecture.svg)
shows the datapath, translation, memory tiers, MMIO and debug interfaces.
The [cache diagram](../../docs/diagrams/cache-hierarchy.svg) expands the tagged
arbiter tree and its X3 L2 configuration.

`frost.sv` wraps `cpu_and_mem.sv` and the UART clock-domain crossings.
`cpu_and_mem` connects the CPU, low BRAM, caches, DDR bridge, MMIO, debug
module, NIC, and DMA test engine. The DDR bridge connects to a behavioral
model in simulation or a board controller on hardware.

| Stage | Main files | Role |
|-------|------------|------|
| IF | `cpu_and_mem/cpu/if_stage/` | 64-bit fetch window, branch prediction, instruction alignment |
| PD | `cpu_and_mem/cpu/pd_stage/` | Compressed-instruction decoding and early branch redirects |
| ID | `cpu_and_mem/cpu/id_stage/` | Decode and prepare up to two instructions for dispatch |

The backend provides a 32-entry ROB, separate integer and FP rename tables,
six reservation stations, load/store queues, and two result-broadcast lanes.
The integer station can issue to two ALUs; other stations issue one operation
each. Branches use the first ALU. Optional `PERF_COUNTERS` support profiling.

See the [CPU guide](cpu_and_mem/cpu/README.md) for front-end integration and
branch prediction, and the [Tomasulo guide](cpu_and_mem/cpu/tomasulo/README.md)
for scheduling, execution, and commit.

Sv39 uses an 8-entry instruction TLB, a 16-entry data TLB, and a shared
read-only page-table walker. It supports 4 KiB, 2 MiB, and 1 GiB pages.
Accessed/dirty bits are managed by software (Svade); an access that needs
them set raises a page fault. There is no ASID tagging: `sfence.vma` and
`satp` writes invalidate both TLBs.

## Directory Map

| Path | Purpose |
|------|---------|
| `frost.sv`, `frost.f` | SoC wrapper and RTL source list |
| `cpu_and_mem/` | CPU, memory, and peripheral integration |
| `cpu_and_mem/imem_predecode.sv` | Low-BRAM instruction memory and predecode metadata |
| `cpu_and_mem/low_bram_fetch_presenter.sv` | Low-BRAM fetch request and response handling |
| `cpu_and_mem/fetch_provider.sv` | Cached instruction fetch buffer and `fence.i` invalidation |
| `cpu_and_mem/plic.sv` | Four-source interrupt controller with M/S contexts |
| `cpu_and_mem/dma_test_engine.sv` | Coherent DMA copy/fill engine |
| `cpu_and_mem/hang_triage.sv` | UART diagnostics for hardware hangs (`ENABLE_HANG_TRIAGE=1`; default 0) |
| `cpu_and_mem/debug/` | JTAG transport and RISC-V debug module |
| `cpu_and_mem/cpu/cpu_ooo/` | CPU integration and pipeline control |
| `cpu_and_mem/cpu/tomasulo/` | Dispatch, ROB, rename tables, queues, and functional-unit adapters |
| `cpu_and_mem/cpu/if_stage/`, `pd_stage/`, `id_stage/` | Front-end pipeline stages |
| `cpu_and_mem/cpu/mmu/` | Sv39 TLBs and hardware page-table walker |
| `cpu_and_mem/cpu/csr/`, `control/trap_unit.sv` | Privileged state, exceptions, and interrupts |
| `cpu_and_mem/cpu/wb_stage/generic_regfile.sv` | Integer and FP register files |
| `cpu_and_mem/cpu/ex_stage/` | ALU, multiply/divide, FPU, and branch execution |
| [lib/cache/](lib/cache/README.md) | Cache hierarchy, coherence, DDR bridge, and simulation model |
| `lib/` | RAM, FIFO, and clock-domain-crossing primitives |
| [peripherals/nic/](peripherals/nic/README.md) | Ethernet NIC with coherent DMA |
| [net10g/](net10g/README.md) | Portable 10GBASE-R MAC/PCS |
| `peripherals/` | UART transmit and receive blocks |

## Memory Map

The low BRAM memory is 256 KiB (95 KiB ROM + the 1 KiB debug slice + 160 KiB
RAM in the unified linker script). Both instruction fetch and data accesses
also reach a 1 GiB cached region served by the cache hierarchy:

| Region | Address | Size | Description |
|--------|---------|------|-------------|
| ROM | `0x0000_0000` | 95 KiB | Code and read-only data (fast BRAM) |
| DEBUG | `0x0001_7C00` | 1 KiB | Debug-module execution slice (park loop, abstract-command and program-buffer words); reserved by every linker script, written only by the debug module |
| RAM | `0x0001_8000` | 160 KiB | Data, BSS, stack (fast BRAM) |
| MMIO | `0x4000_0000` | 196 KiB | UART/FIFOs/timer; plus Linux-facing ns16550a UART (`0x4000_1000`), SiFive CLINT (`0x4001_0000`), the DMA test engine (`0x4002_0000`) and the NIC (`0x4003_0000`) |
| PLIC | `0x4400_0000` | 4 MiB | Platform-level interrupt controller (M and S contexts for hart 0; sources: 1 = ns16550, 2 = the board's external-interrupt pin, 3 = the DMA test engine's completion, 4 = the NIC) |
| DDR | `0x8000_0000` | 1 GiB | Cached region: code (`.ddr_text`), heap and large data (see below) |

MMIO is strongly ordered: accesses from the same hart complete in program
order without fences. Device reads wait for committed stores to drain and
are protected from interrupt replay so destructive reads happen once.
See the [load queue guide](cpu_and_mem/cpu/tomasulo/load_queue/README.md).

The cached tier has separate L1 instruction and data caches backed by a
shared 2 MiB L2 on X3. The L1D, page-table walker, L1I, and DMA ports share
the hierarchy with priority D > walker > I > DMA and bounded DMA starvation.
Coherence logic makes DMA and page-table reads see dirty L1D data without
software cache maintenance. The instruction fetch buffer holds two active
lines and six victim lines.

Low-BRAM data accesses take one cycle. Instruction windows wholly below
64 KiB take one cycle; later windows repeat once for predecode metadata.
Cached accesses have variable latency. The caches use 32-byte lines,
write-back, and write-allocate; L1 hits can proceed while misses are pending.
See the [cache guide](lib/cache/README.md) for timing and transaction details.

`fence.i` drains stores, writes back dirty L1D lines, invalidates L1I, and
flushes the fetch buffer before refetch. Reset invalidates the caches.
`ENABLE_CACHED_TIER=0` removes the hierarchy: cached-region data accesses
return zero and fetch uses low BRAM only. `USE_BEHAVIORAL_DDR=0` connects
the bridge to the board's `o_ddr_axi_*` ports.

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
| `0x4000_1000`–`101C` | ns16550a UART face | 16550 register file (word stride) aliasing UART_TX/RX for the Linux 8250 driver |
| `0x4001_0000` | CLINT MSIP | SiFive CLINT alias of MSIP |
| `0x4001_4000`/`4004` | CLINT MTIMECMP_LO/HI | SiFive CLINT alias of MTIMECMP |
| `0x4001_BFF8`/`BFFC` | CLINT MTIME_LO/HI | SiFive CLINT alias of MTIME |
| `0x4002_0000`–`0024` | DMA test engine | CTRL/ACK/SRC/DST/LEN/MODE/PATTERN/STATUS_ADDR/STATUS_VALUE/LINES (`dma_test_engine.sv`, `sw/lib/include/dma_engine.h`) |
| `0x4003_0000`–`0FFF` | NIC | 4 KiB register window: control/status, station address, rings, link and PHY, 64-bit counters (`peripherals/nic/nic_pkg.sv`, `sw/lib/include/nic.h`) |

The PLIC window (`0x4400_0000`, spec register layout: per-source priorities,
pending, per-context enables at `0x2000 + 0x80*ctx`, threshold and
claim/complete at `0x20_0000 + 0x1000*ctx`) carries both external-interrupt
lines: the machine context drives `mip.MEIP` (the ns16550 interrupt reaches
the core only through the PLIC as source 1) and the supervisor context ORs
into the `mip.SEIP` readback beside the M-mode software-injection bit. The
claim read is destructive and rides the same router device-read shield as
the UART RX pop.

### Debug

The RISC-V debug module (Debug Spec 0.13.2, `cpu_and_mem/debug/`) halts,
inspects, patches, steps and resumes the hart over JTAG. Its transport is
the generic five-bit-IR TAP on `frost`'s `i_jtag_*` pins in simulation and
the portable synthesis targets, and two BSCANE2 USER chains on the FPGA's
own TAP on the boards (`boards/`, `fpga/debug/` for the OpenOCD side).

Halt and single-step requests use the trap machinery to drain stores and
protect atomic operations and device reads. Debug Mode saves `dpc`/`dcsr`,
masks interrupts, and runs commands from the reserved low-BRAM debug slice.
The module supports abstract GPR access and an eight-word program buffer.
Debugger memory access uses that buffer; there is no system-bus access port.

`debug_slice_writer` mirrors debugger writes into low BRAM's instruction
copy. OpenOCD executes `fence.i` to publish DDR code changes. Debug CSRs and
`dret` are illegal outside Debug Mode.

For OpenOCD and VS Code usage, see the [FPGA guide](../../fpga/README.md#vs-code-debugging).

### Data-tier bus contract

Every data-side bus below the load/store queues (BRAM tier, cached tier,
MMIO, router, adapter responses) moves one aligned 64-bit beat per
transaction (`riscv_pkg::MemDataBits`) with an 8-lane byte strobe
(`MemStrbBits`): the beat is the dword at `addr[31:3]`, and byte lane *i* is
byte address `{addr[31:3], i}`. Producers position by `addr[2:0]` and
consumers extract by `addr[2:0]`:

- Store data is replicated across the beat (`{8{byte}}`, `{4{half}}`,
  `{2{word}}`, dword pass-through) and the strobe selects the lanes:
  `BYTE = 8'h01 << addr[2:0]`, `HALF = 8'h03 << {addr[2:1], 1'b0}`,
  `WORD = addr[2] ? 8'hF0 : 8'h0F`, `DOUBLE = 8'hFF`
  (`riscv_pkg::mem_strobe_for`). Replication keeps the write-data mux
  shallow; there is no byte-lane shifter.
- Reads return the full beat; `load_unit` selects the word by `addr[2]`,
  then the half/byte, then sign- or zero-extends. FLD/LD consume the beat.
- MMIO registers appear in their address-matching lanes, so extraction
  needs no MMIO special case (a 32-bit register at offset +4 sits in lanes
  [63:32]).
- A dword access never spans beats, so no crossing logic exists; the
  size-cased misalignment checks cover the 8-byte class (`|addr[2:0]`).
- The L0 cache and store-to-load forwarding work at dword granule, and the
  data BRAM's `$readmemh` image is the dword-paired `sw64.mem`
  (`sw/common/make_dword_mem.py`); every other image and loader format
  stays 32-bit-word.
- Cached-tier loads are tagged: the load queue names one of its
  `riscv_pkg::CachedLoadSlots` slots on each cached launch, the adapter
  carries that id on the line port, and the response returns it
  (`is_cached` + slot id beside the beat), so several cached loads are in
  flight at once and complete in any order. Low-BRAM and MMIO loads keep
  the untagged fixed-latency response, which owns the response port in its
  cycle; a cached response arriving that cycle waits in the adapter.

The MMIO bus rides this contract. The dword-aligned CLINT pairs support
native 64-bit access: an 8-byte load of `mtime` (`0x4001_BFF8`) returns the
whole counter single-copy-atomically, and an 8-byte `mtimecmp` store lands
atomically (the 32-bit lo/hi aliases keep their word semantics). UART and
FIFO registers are 32-bit-access-max: a wider store writes only the
addressed word lanes.

The hardware UART console is configured for 115200 baud, 8 data bits, no
parity, and 1 stop bit (8N1).

For Linux, the same UART is also reachable through a standard
ns16550a register face at `0x4000_1000` (word stride; device-tree
`reg-shift=2`, `reg-io-width=4`; `earlycon=uart8250,mmio32`), and the timer
through a SiFive-CLINT-compatible window at `0x4001_0000` (`mtimecmp` at
`+0x4000`, `mtime` at `+0xBFF8`). Both alias the native registers listed
above onto the same hardware, so the in-tree Linux 8250 console and CLINT
timer drivers work without a board-specific driver.

If these addresses change, update `cpu_and_mem.sv`, `cpu_ooo.sv` parameters,
`sw/common/link.ld`, `sw/lib/include/mmio.h`, and the verification constants in
`verif/config.py`. The debug slice's location is `riscv_pkg::DebugSliceBase`;
every linker script under `sw/` reserves it as the `DEBUG` region.

## Build and Simulation

From the repo root (simulation and synthesis checks run in the pinned
container via the wrapper; Vivado builds run natively):

```bash
# Cocotb/Verilator simulation
./scripts/frost.py cocotb hello_world
./scripts/frost.py cocotb tomasulo_test
./scripts/frost.py cocotb --list-tests    # show all registered tests

# Yosys RTL synthesis checks
./scripts/frost.py synthesis

# Vivado FPGA builds
./fpga/build/build.py x3
```

Yosys runs generic coarse synthesis and full Xilinx UltraScale+ synthesis.
See the [synthesis guide](../../tests/README.md#test_run_yosyspy) for target options.

The top-level simulation file list is `frost.f`; the CPU build file list is
`cpu_and_mem/cpu/cpu_ooo/cpu_ooo.f`.

## Parameters

| Module | Parameter | Default | Description |
|--------|-----------|---------|-------------|
| `frost.sv` | `CLK_FREQ_HZ` | `300000000` | Main CPU clock frequency |
| `frost.sv` | `MEM_SIZE_BYTES` | `2 ** 18` | 256 KiB low BRAM |
| `frost.sv` | `SIM_TIMER_SPEEDUP` | `1` | Multiplies `mtime` increment rate for simulation |
| `frost.sv` | `CACHED_BASE` | `32'h8000_0000` | Cached-region base address |
| `frost.sv` | `CACHED_SIZE_BYTES` | `32'h4000_0000` | Cached-region size (1 GiB) |
| `frost.sv` | `ENABLE_CACHED_TIER` | `0` | 1 instantiates the cache hierarchy (simulation enables via `-G`; boards enable with their DDR controller) |
| `frost.sv` | `L1_CACHE_BYTES` / `L1I_CACHE_BYTES` / `L2_CACHE_BYTES` | `128 KiB` / `16 KiB` / `2 MiB` | Data L1, instruction L1I, and L2 cache sizes |
| `frost.sv` | `USE_BEHAVIORAL_DDR` | `1` | 1 ends the tier in the simulation-only DDR model; 0 exports the bridge's AXI master on `o_ddr_axi_*` |
| `frost.sv` | `DDR_MODEL_BYTES` / `DDR_MODEL_LATENCY` | `64 MiB` / `30` | Behavioral DDR model size and access latency (simulation) |
| `frost.sv` | `FETCH_VALID_FUZZ` | `0` | Simulation-only: 1 wraps the low BRAM in a variable-latency fetch model (LFSR fetch-valid gaps) that mirrors the L1I provider's fetch contract; hardware keeps 0 |
| `cpu_ooo.sv` | `MMIO_ADDR` | `32'h4000_0000` | MMIO base |
| `cpu_ooo.sv` | `MMIO_SIZE_BYTES` | `32'h2C` | MMIO range size; `cpu_and_mem.sv` overrides to `32'h3_1000` (covers the ns16550a face, the CLINT alias, the DMA test engine and the NIC windows) |

Simulation overrides parameters through Verilator generics (`-G`): the test
Makefile enables the cached tier with the X3 hierarchy shape by default
and sets the behavioral DDR model's size/latency and the low BRAM's 256 KiB
hardware size (`SIM_MEM_SIZE_BYTES`). The focused cache unit benches still
drive `frost_cache_hierarchy` directly with `-GHAS_L2={0,1}` to cover its
generic optional topology, while selected fetch-fuzz program runs use a
separate `-GFETCH_VALID_FUZZ=1` build.

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
