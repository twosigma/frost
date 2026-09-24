# FROST RTL

This directory holds FROST's synthesizable SystemVerilog: a single-hart
RV64GCB out-of-order CPU, its memory system, and its peripherals. The CPU
schedules with Tomasulo's algorithm, decodes, renames, and commits up to two
instructions per cycle, and runs M, S, and U modes with Sv39 virtual memory.
Around it sit 256 KiB of on-chip BRAM, a three-cache hierarchy over 1 GiB of
DDR, a PLIC, a RISC-V debug module, and a 10GBASE-R NIC.

The RTL is portable. Defining `FROST_XILINX_PRIMS` selects explicit Xilinx
primitives in a few modules. Board integration lives in `boards/` and
`fpga/`, and `frost.f` lists every source in compilation order.

## Top-Level Shape

The [CPU and system architecture diagram](../../docs/diagrams/frost-architecture.svg)
shows the datapath, translation, memory tiers, MMIO, and debug interfaces.
The [cache diagram](../../docs/diagrams/cache-hierarchy.svg) expands the
cache hierarchy.

`frost.sv` wraps `cpu_and_mem.sv` with reset synchronization, the UART and
its clock-crossing FIFOs, and the two MMIO FIFOs. `i_clk` runs the CPU and
memories; `i_clk_div4` runs the UART and the BRAM programming port that the
JTAG loader uses.

`cpu_and_mem` connects the CPU, low BRAM, the cache hierarchy and its DDR
bridge, the MMIO devices, the debug module, the NIC, and the DMA test engine.
The bridge ends in a behavioral DDR model in simulation and in the board's
DDR controller on hardware.

| Stage | Main files | Role |
|-------|------------|------|
| IF | `cpu_and_mem/cpu/if_stage/` | 64-bit fetch window, branch prediction, instruction alignment |
| PD | `cpu_and_mem/cpu/pd_stage/` | Compressed-instruction decoding and early branch redirects |
| ID | `cpu_and_mem/cpu/id_stage/` | Decode and prepare up to two instructions for dispatch |

The back end has a 32-entry ROB, separate integer and FP rename tables, six
reservation stations, load and store queues, and two result-broadcast lanes.
The integer station issues to two ALUs, and branches use the first; the other
stations issue one operation per cycle. See the
[CPU guide](cpu_and_mem/cpu/README.md) for the front end and
branch prediction, and the [Tomasulo guide](cpu_and_mem/cpu/tomasulo/README.md)
for scheduling, execution, and commit.

Sv39 translation uses an 8-entry ITLB, a 16-entry DTLB, and one read-only
page-table walker shared by both, with 4 KiB, 2 MiB, and 1 GiB pages.
Software manages the accessed and dirty bits (Svade): an access that needs
one set raises a page fault. TLB entries carry no ASID, so `sfence.vma` and
`satp` writes invalidate both TLBs.

## Directory Map

| Path | Purpose |
|------|---------|
| `frost.sv`, `frost.f` | SoC wrapper and RTL source list |
| `cpu_and_mem/` | CPU, memory, and peripheral integration |
| `cpu_and_mem/imem_predecode.sv` | Low-BRAM instruction memory and predecode metadata |
| `cpu_and_mem/low_bram_fetch_presenter.sv` | Low-BRAM fetch request and response handling |
| `cpu_and_mem/fetch_provider.sv` | Fetch buffer for code in DDR, in front of the L1I |
| `cpu_and_mem/plic.sv` | Four-source interrupt controller with M and S contexts |
| `cpu_and_mem/dma_test_engine.sv` | Coherent DMA copy/fill engine |
| `cpu_and_mem/hang_triage.sv` | UART diagnostics for hardware hangs (`ENABLE_HANG_TRIAGE=1`; default 0) |
| `cpu_and_mem/debug/` | JTAG transport and RISC-V debug module |
| `cpu_and_mem/cpu/cpu_ooo/` | CPU integration and pipeline control |
| [cpu_and_mem/cpu/tomasulo/](cpu_and_mem/cpu/tomasulo/README.md) | Dispatch, ROB, rename tables, queues, and functional-unit adapters |
| `cpu_and_mem/cpu/if_stage/`, `pd_stage/`, `id_stage/` | Front-end pipeline stages |
| `cpu_and_mem/cpu/mmu/` | Sv39 TLBs and hardware page-table walker |
| `cpu_and_mem/cpu/csr/`, `control/trap_unit.sv` | Privileged state, exceptions, and interrupts |
| `cpu_and_mem/cpu/wb_stage/generic_regfile.sv` | Integer and FP register files |
| `cpu_and_mem/cpu/ex_stage/` | ALU, multiply/divide, FPU, and branch execution |
| [lib/cache/](lib/cache/README.md) | Cache hierarchy, coherence, DDR bridge, and simulation DDR model |
| `lib/` | RAM, FIFO, and clock-domain-crossing primitives |
| [peripherals/nic/](peripherals/nic/README.md) | Ethernet NIC with coherent DMA |
| [net10g/](net10g/README.md) | Portable 10GBASE-R MAC/PCS |
| `peripherals/` | UART transmit and receive blocks |

## Memory Map

| Region | Address | Size | Contents |
|--------|---------|------|----------|
| ROM | `0x0000_0000` | 95 KiB | Code and read-only data (low BRAM) |
| DEBUG | `0x0001_7C00` | 1 KiB | Debug-module execution slice (see [Debug](#debug)); reserved by every linker script that uses low BRAM and written only by the debug module |
| RAM | `0x0001_8000` | 160 KiB | Data, BSS, and stack (low BRAM) |
| MMIO | `0x4000_0000` | 196 KiB | Device registers (table below) |
| PLIC | `0x4400_0000` | 4 MiB | Platform-level interrupt controller |
| DDR | `0x8000_0000` | 1 GiB | Cached region: `.ddr_text` code, large data, and the heap |

The ROM, DEBUG, and RAM regions divide the 256 KiB low BRAM as the unified
linker script (`sw/common/link.ld`) does. Low BRAM holds separate instruction
and data copies. The JTAG loader writes both, but outside Debug Mode CPU
stores reach only the data copy, so code in low BRAM cannot be modified at
run time; put self-modifying code in DDR. Low-BRAM data accesses take one
cycle. Fetch windows wholly below 64 KiB also take one cycle; later windows
repeat once for predecode metadata.

Instruction fetch and data accesses both reach the cached region. The
hierarchy has a 128 KiB L1D, a 16 KiB L1I, and a shared 2 MiB L2. All three
are direct-mapped, write-back, and write-allocate with 32-byte lines. Cached
accesses have variable latency, and L1 hits proceed while misses are
pending. The L1D, the page-table walker, the L1I, and DMA share the hierarchy
in that priority order, with a bound on DMA starvation. DMA and page-table
walks see dirty L1D data without software cache maintenance. Code fetched
from DDR passes through a buffer of two active lines and six victim lines in
front of the L1I. See the [cache guide](lib/cache/README.md).

`fence.i` drains stores, writes back dirty L1D lines, invalidates the L1I,
and flushes the fetch buffer before refetch. Reset invalidates the caches.
With `ENABLE_CACHED_TIER=0` there is no hierarchy: cached-region loads return
zero, stores complete without effect, fetch uses low BRAM only, and the NIC
and DMA test engine windows read zero. `USE_BEHAVIORAL_DDR=0` connects the
DDR bridge to the board's `o_ddr_axi_*` ports.

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
| `0x4003_0000`–`0FFF` | NIC | 4 KiB window: control and status, station address, rings, link and PHY, 64-bit counters (`peripherals/nic/nic_pkg.sv`, `sw/lib/include/nic.h`) |

The UART console runs at 115200 baud, 8N1. For Linux, the same UART also
appears as an ns16550a at `0x4000_1000` (word stride: device tree
`reg-shift=2`, `reg-io-width=4`; `earlycon=uart8250,mmio32`), and the timer
as a SiFive CLINT at `0x4001_0000` (`mtimecmp` at `+0x4000`, `mtime` at
`+0xBFF8`). Both are aliases of the native registers, so the kernel's
standard 8250 and CLINT drivers work without a board-specific driver.

The PLIC uses the standard register layout: per-source priorities, the
pending word, per-context enables at `0x2000 + 0x80*ctx`, and threshold and
claim/complete at `0x20_0000 + 0x1000*ctx`. Its four level-triggered sources
are 1, the ns16550 UART; 2, the board's external-interrupt pin; 3, the DMA
test engine; and 4, the NIC. The UART interrupt reaches the core only through
the PLIC. Context 0 (M mode, hart 0) drives `mip.MEIP`. Context 1 (S mode) is
ORed into `mip.SEIP` with the SEIP bit that M-mode software can set. A claim
read is destructive, so the router handles it as a device read like the UART
RX pop (see the [data-tier bus contract](#data-tier-bus-contract)).

If these addresses change, update `cpu_and_mem.sv`, the `MMIO_ADDR` and
`MMIO_SIZE_BYTES` parameters of `cpu_ooo.sv`, the MMIO `PROVIDE` symbols in
the linker scripts under `sw/` (`sw/common/link.ld`,
`sw/common/link_ddr.ld`, and several app-specific scripts),
`sw/lib/include/mmio.h`, the verification constants in `verif/config.py`, and
the Linux device tree generated by
`linux/buildroot-external/board/frost/frost_boot_image.py`. The debug slice's
location is `riscv_pkg::DebugSliceBase`; every FROST linker script that uses
low BRAM reserves it as the `DEBUG` region.

### Data-tier bus contract

Every data-side bus below the load and store queues (the BRAM tier, the
cached tier, MMIO, the request router, and adapter responses) moves one
aligned 64-bit beat per transaction (`riscv_pkg::MemDataBits`) with an 8-lane
byte strobe (`MemStrbBits`). The beat is the dword at `addr[31:3]`, and byte
lane *i* is byte address `{addr[31:3], i}`. Producers position data by
`addr[2:0]` and consumers extract by `addr[2:0]`:

- Stores replicate their data across the beat (`{8{byte}}`, `{4{half}}`,
  `{2{word}}`, a dword as is) and the strobe selects the lanes:
  `BYTE = 8'h01 << addr[2:0]`, `HALF = 8'h03 << {addr[2:1], 1'b0}`,
  `WORD = addr[2] ? 8'hF0 : 8'h0F`, `DOUBLE = 8'hFF`
  (`riscv_pkg::mem_strobe_for`). Replication keeps the write-data mux
  shallow; there is no byte-lane shifter.
- Reads return the whole beat. `load_unit` selects the word by `addr[2]`,
  then the halfword or byte, then sign- or zero-extends. LD and FLD take the
  beat whole.
- MMIO registers sit in their address-matching lanes (a 32-bit register at
  offset +4 occupies lanes [63:32]), so extraction has no MMIO special case.
- A dword access never spans beats, so there is no beat-crossing logic; the
  size-cased misalignment checks cover the 8-byte class (`|addr[2:0]`).
- The load queue's L0 cache and store-to-load forwarding work on dwords. The
  data BRAM's `$readmemh` image is the dword-paired `sw64.mem`
  (`sw/common/make_dword_mem.py`); every other image and loader format stays
  in 32-bit words.
- Cached loads are tagged. The load queue names one of its
  `riscv_pkg::CachedLoadSlots` slots on each cached launch, the adapter
  carries that id on the line port, and the response returns it beside the
  beat, so several cached loads can be in flight and complete in any order.
  Low-BRAM and MMIO loads keep the untagged fixed-latency response, which owns
  the response port in its cycle; a cached response that arrives then waits
  in the adapter.

The MMIO bus follows the same rules. The dword-aligned timer pairs, native
and CLINT alias, support 64-bit access: an 8-byte load of `mtime`
(`0x4001_BFF8`) returns the whole counter atomically, and an 8-byte
`mtimecmp` store lands atomically. The 32-bit lo/hi aliases keep their word
behavior. UART and FIFO registers are 32-bit-access-max: a wider store writes
only the addressed word. The PLIC, DMA test engine, and NIC windows take
32-bit accesses: a 64-bit load returns an aligned register pair, and a 64-bit
store writes only the upper register.

MMIO is strongly ordered: accesses from one hart complete in program order
without fences. A device read waits for committed stores to drain and is
shielded from interrupt replay, so a destructive read (the UART RX pop, a
PLIC claim) happens exactly once. See the
[load queue guide](cpu_and_mem/cpu/tomasulo/load_queue/README.md).

## Debug

The debug module in `cpu_and_mem/debug/` implements the RISC-V Debug Spec
0.13.2: a debugger can halt, inspect, patch, single-step, and resume the hart
over JTAG. In simulation and the portable synthesis targets, the transport is
a generic TAP with a five-bit IR on `frost`'s `i_jtag_*` pins
(`DEBUG_JTAG_TAP=1`). Board builds drive it instead from two BSCANE2 USER
chains on the FPGA's own TAP (`boards/`, with the OpenOCD configuration in
`fpga/debug/`).

Halt and single-step requests use the trap machinery, which drains stores and
protects atomic operations and device reads. Debug Mode saves `dpc` and
`dcsr`, masks interrupts, and runs the module's commands from the reserved
low-BRAM debug slice. The module supports abstract GPR access and an 8-word
program buffer. Debugger memory accesses run through that buffer; there is no
system bus access.

`debug_slice_writer` writes the module's words into the slice through the
BRAM programming port. It also mirrors Debug-Mode stores to low BRAM into the
instruction copy, so software breakpoints and debugger writes to BRAM code
are fetched. For code in DDR, OpenOCD executes `fence.i`, which publishes its
writes. Debug CSRs and `dret` are illegal outside Debug Mode.

For OpenOCD, GDB, and VS Code use, see the
[FPGA guide](../../fpga/README.md#vs-code-debugging).

## Build and Simulation

Use the [test guide](../../tests/README.md) for simulation, formal, and Yosys
runs in the pinned container, and the [FPGA guide](../../fpga/README.md) for
native Vivado builds. `frost.f` is the system source list and
`cpu_and_mem/cpu/cpu_ooo/cpu_ooo.f` the CPU's.
[CONTRIBUTING.md](../../CONTRIBUTING.md) lists the RTL coding rules and the
checks a change needs.

Simulation sets parameters with Verilator `-G` overrides. For the `frost`
top, `tests/Makefile` sets the low BRAM to its 256 KiB hardware size
(`SIM_MEM_SIZE_BYTES`), enables the cached tier with the X3 hierarchy, sets
the DDR model's size and latency, and turns on fast cache maintenance
(`SIM_FAST_MAINT=1`). Individual entries in `tests/test_run_cocotb.py` add
their own overrides, such as `-GFETCH_VALID_FUZZ=1` for the fetch-fuzz runs
and DDR latency jitter or reordering for stress runs. The cache unit benches
instantiate `frost_cache_hierarchy` directly and cover both `HAS_L2=1` and
the L1-only `HAS_L2=0` shape.

## Parameters

The main parameters; `frost.sv` documents the rest.

| Module | Parameter | Default | Description |
|--------|-----------|---------|-------------|
| `frost.sv` | `CLK_FREQ_HZ` | `322265625` | CPU clock frequency |
| `frost.sv` | `MEM_SIZE_BYTES` | `2 ** 18` | Low BRAM size (256 KiB) |
| `frost.sv` | `SIM_TIMER_SPEEDUP` | `1` | `mtime` increment per cycle (simulation) |
| `frost.sv` | `CACHED_BASE` | `32'h8000_0000` | Cached-region base address |
| `frost.sv` | `CACHED_SIZE_BYTES` | `32'h4000_0000` | Cached-region size (1 GiB) |
| `frost.sv` | `ENABLE_CACHED_TIER` | `0` | 1 builds the cache hierarchy; simulation sets it with `-G`, and boards with a DDR controller pass 1 |
| `frost.sv` | `L1_CACHE_BYTES` / `L1I_CACHE_BYTES` / `L2_CACHE_BYTES` | `128 KiB` / `16 KiB` / `2 MiB` | L1D, L1I, and L2 sizes |
| `frost.sv` | `USE_BEHAVIORAL_DDR` | `1` | 1 ends the tier in the simulation DDR model; 0 exports the bridge's AXI master on `o_ddr_axi_*` |
| `frost.sv` | `DDR_MODEL_BYTES` / `DDR_MODEL_LATENCY` | `64 MiB` / `30` | DDR model size and access latency in cycles (simulation) |
| `frost.sv` | `DDR_MODEL_LATENCY_JITTER` / `DDR_MODEL_REORDER` | `0` / `0` | DDR model per-transaction latency jitter, and out-of-order completion across ids (simulation) |
| `frost.sv` | `SIM_FAST_MAINT` | `0` | Simulation only: 1 selects fast `fence.i` cache maintenance with the same functional effect |
| `frost.sv` | `FETCH_VALID_FUZZ` | `0` | Simulation only: 1 inserts pseudo-random gaps into low-BRAM fetch responses to exercise the front end's handling of variable fetch latency |
| `frost.sv` | `PERF_COUNTERS` | `0` | 1 builds the `mperf*` profiling counters |
| `frost.sv` | `DEBUG_JTAG_TAP` | `1` | 1 uses the generic TAP on `i_jtag_*`; 0 takes the BSCAN bundle from the board |
| `frost.sv` | `RAW_LOOPBACK` | `1` | 1 builds the NIC's raw TX-to-RX loopback, which needs one clock on both MAC clock ports; 0 for a transceiver's independent clocks |
| `cpu_ooo.sv` | `MMIO_ADDR` | `32'h4000_0000` | MMIO base |
| `cpu_ooo.sv` | `MMIO_SIZE_BYTES` | `32'h2C` | MMIO range size; `cpu_and_mem.sv` passes `32'h3_1000` to cover the ns16550a face, the CLINT alias, and the DMA test engine and NIC windows |

## License

Copyright 2026 Two Sigma Open Source, LLC

Licensed under the Apache License, Version 2.0.
