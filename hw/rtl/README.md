# FROST RTL

This directory contains the synthesizable SystemVerilog for FROST. The current
CPU is an **out-of-order RV64GCB implementation with a 2-wide front-end and
2-wide commit**: a 2-wide in-order IF/PD/ID front-end, Tomasulo register renaming
and dynamic scheduling, out-of-order execution across six function units, and
precise 2-wide in-order commit, with M/U-mode traps and separate
instruction/data memory ports. The core is RV64-only (`riscv_pkg::XLEN` is
64; rv32 support was retired after ROADMAP Phase 1 — see
`docs/rv64/phase1_plan.md` decision D9).

The pipeline width is **asymmetric**. Fetch, decode, rename, ROB allocation,
result writeback, and commit can each move up to two instructions or completions
per cycle. Most reservation stations issue one operation per cycle, but the
INT reservation station is dual-issue, feeding two integer ALU pipes (branches
stay on pipe 0). Result writeback uses a **2-lane common data
bus**: the arbiter grants the top two FU completions in fixed-priority order,
while aligned plain stores bypass the CDB. Lane 0 remains on the same-cycle RS
issue bypass path, and lane 1 now wakes resident consumers in the same cycle
as well (symmetric lane-1 wakeup, `LANE1_ISSUE_BYPASS`, on by default).
Different function units can still execute concurrently — up to six reservation
stations can issue in the same cycle, up to seven operations counting the INT
station's second port — but this is not a fully symmetric 2-issue execution
engine.

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
    data RAM (low 256 KiB BRAM, 1-cycle)
    fetch_provider -> two-line L1I fetch buffer (cached fetch @ 0x8000_0000)
    cached tier @ 0x8000_0000 (1 GiB), frost_cache_hierarchy:
      data: cached_tier_adapter -> L1D (128 KiB BRAM) -\
      instr: L1I (16 KiB BRAM, read-only) ------------- line_port_arbiter
        [-> L2 (2 MiB URAM, X3)] -> line_port_axi_bridge -> DDR AXI port
           (behavioral DDR model in sim; board DDR controller on hardware)
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
| IF | `cpu_and_mem/cpu/if_stage/` | 64-bit fetch window, PC control, BTB + bimodal direction predictor + RAS, slot-2 BTB lookup, RVC parcel alignment, slot-2 RVC decompression (per-candidate, in the aligner) |
| PD | `cpu_and_mem/cpu/pd_stage/` | Slot-1 RVC decompression, instruction selection, PD-stage computed-target redirect for predicted-taken conditional BTB misses, early source extraction and narrow source-hot timing bypasses |
| ID | `cpu_and_mem/cpu/id_stage/` | Decode, immediate generation, branch target precompute, CSR address/zimm extraction (the CSR read/write itself fires at commit), two registered dispatch packets |

The conditional-branch predictor is split between target and direction. The BTB
still supplies targets for BTB hits, while a separate 1024-entry bimodal
direction predictor is trained from committed conditional branches. IF carries
the predicted direction and predict-time direction index with the instruction;
PD uses that direction to compute `PC + imm` and redirect immediately when a
conditional branch misses the BTB but is predicted taken.

The PD timing boundary keeps two late controls off data carry chains without
adding a pipeline stage. At an odd-halfword PC, IF always forms the speculative
native spanning candidate; compressed instructions ignore that value and use
their raw parcel, while native instructions receive the same assembled word as
before. This prevents the sideband size bit from entering PD's branch-target
adder. PD's two protected format-specific target helpers reduce each late cone
to a 13-bit low sum plus the raw two-bit `{immediate sign, low-add carry}`
state. The existing nonstall redirect edge captures both formats' raw low/state
banks and the format-select bit beside separate PC-high `{H,H+1,H-1}` banks;
only shallow registered-data muxes (format select plus high-bank decode)
reconstruct the target during the redirect-to-IF cycle, keeping the format
select off the late carry-to-D cone as well. The redirect valid follows the
same discipline: its registered candidate carries only the early qualifiers
(branch detect, direction, BTB miss, self-suppression), while the late
served-window qualifiers (`ras_predicted`, `sel_nop`) are captured raw into a
veto flop on the same edge and applied one LUT after the flops, keeping the
fetch-provider window chain off the redirect-candidate D input. Simulation
replays both former monolithic registers as oracles and asserts the split
implementations never diverge. Slot-2 early
source addresses similarly register their raw payload bits and use a
synchronous clear for bubbles, flushes, and registered PD redirects, so invalid
slots still expose x0
while the IMEM data path avoids a final NOP mux. The per-word sideband carries
only the six RVC-expanded bits needed by the five current low-IMEM source-field
timing endpoints: `{rs2[1], rs1[2:1]}` for each halfword start. IF aligns these
exact bits with each slot, and PD selectively substitutes them into slot-1
instruction rs1[2:1] and slot-2 early rs1[2:1]/rs2[1]. The instruction and
early-source representations remain bit-identical, with no new stage or
throughput restriction. Instruction delivery and redirect latency are
unchanged.

Slot-2 BTB redirects retain same-cycle priority over a younger slot-1
prediction. They immediately kill that slot-1 PC-register handoff and metadata,
then use the existing registered redirect bubble to quarantine any slot-1
prediction holdoff loaded on the collision edge. The holdoff clears on the
first delivered bubble cycle, so this bookkeeping split adds neither redirect
latency nor an extra front-end bubble.

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
| `cpu_and_mem/imem_predecode.sv` | In use | Instruction RAM with 64-bit fetch (even/odd interleaved BRAM banks, each resource-neutrally split into 28 cold data bits plus the frontend-hot word bits `{15,10,7,6}`), word-local class/bundle and RVC source-hot predecode sideband, a seven-bit narrow replica for high-allows and other hot fields, plus protected helper-isolated 32Kx4 PC-metadata banks carrying `{pairable-native-hi,pairable-compressed-hi,compressed-hi,compressed-lo}` to the IF PC-advance selector; overriding generic sideband bits 6/7 is intended to let synthesis prune those four old launches and keep the net RAMB count unchanged |
| `cpu_and_mem/imem_predecode_line.sv` | In use | Per-line word-local predecode (the `riscv_pkg::imem_make_sideband` shared source) for L1I fill data |
| `cpu_and_mem/fetch_provider.sv` | In use | High-address fetch provider: two-line L1I fetch buffer with owed-ask tracking, edge-aligned registered readiness/tag validation, next-line prefetch, and fence.i invalidate |
| `cpu_and_mem/cpu/cpu_ooo/` | In use | CPU integration top (`cpu_ooo.sv`) for the Tomasulo core, plus the OOO-core glue submodules extracted from it (register files, front-end validity, branch resolution / recovery / flush, commit, pipeline control, memory-port router, from_ex_comb, perf counters) |
| `cpu_and_mem/cpu/tomasulo/` | In use | ROB, RAT, RS, LQ, SQ, 2-lane CDB, dispatch glue, FU shims. Larger modules nest helper submodules: `tomasulo_wrapper/{perf,commit_bus,dispatch_routing,store_addr,atomics}/`, `store_queue/sq_forwarding_unit`, `load_queue/{load_unit,lq_l0_cache,lq_issue_selector}`, `reservation_station/rs_issue2_selector`, `reorder_buffer/rob_serializer` (see the per-module READMEs) |
| `cpu_and_mem/cpu/if_stage/`, `pd_stage/`, `id_stage/` | In use | Reused front-end stages |
| `cpu_and_mem/cpu/csr/` | In use | Zicsr/Zicntr/fcsr support |
| `cpu_and_mem/cpu/wb_stage/generic_regfile.sv` | In use | Parameterized INT/FP regfiles for OOO commit |
| `cpu_and_mem/cpu/ex_stage/` | In use | Shared ALU, multiplier/divider, FPU, and `branch_jump_unit.sv` used by the OOO core and FU shims |
| `cpu_and_mem/cpu/control/trap_unit.sv` | In use | M- and U-mode exception/interrupt handling (traps taken in M-mode) |
| `lib/` | In use | Portable RAM/FIFO/stall helper primitives, plus `lib/cache/` (the `frost_cache` hierarchy, AXI bridge, and behavioral DDR model) and `lib/ram/sdp_ram_byte_en.sv` (row-granular byte-enable RAM with a selectable block/ultra primitive backing the cache data arrays) |
| `peripherals/` | In use | UART TX/RX blocks |

## Memory Map

The low BRAM memory is 256 KiB (96 KiB ROM + 160 KiB RAM in the unified
linker script); the data port additionally reaches a 1 GiB cached region
served by the cache hierarchy:

| Region | Address | Size | Description |
|--------|---------|------|-------------|
| ROM | `0x0000_0000` | 96 KiB | Code and read-only data (fast BRAM) |
| RAM | `0x0001_8000` | 160 KiB | Data, BSS, stack (fast BRAM) |
| MMIO | `0x4000_0000` | 112 KiB | UART/FIFOs/timer; plus Linux-facing ns16550a UART (`0x4000_1000`) and SiFive CLINT (`0x4001_0000`) |
| DDR | `0x8000_0000` | 1 GiB | Cached region: code (`.ddr_text`), heap and large data (see below) |

The whole MMIO window is one strongly ordered I/O region: same-hart accesses
anywhere in it complete in program order with no fences required (the load
queue hands an ROB-head MMIO request to the data-memory router, whose one-entry
hold always stages the device read for one cycle and then keeps it parked until
every committed store has drained). A full flush can cancel that staged request
before terminal accept; the router's pending Q tells the LQ that no response
debt remains.
This is a platform contract, not just an ISA default — the CLINT window aliases
the native timer registers at second addresses, and both bare-metal apps and
Linux's relaxed MMIO accessors depend on cross-address same-device ordering.

The cached tier serves both sides of the core: loads/stores through the
data L1, and instruction fetch through a dedicated 16 KiB L1I
(`L1I_CACHE_BYTES`) fed by `fetch_provider`'s two-line fetch buffer. A 2:1
`line_port_arbiter` (D-side fixed priority) merges the two L1 line ports
into the single downstream port that the L2 — or, on the L1-only shape,
the DDR bridge — sees. The low BRAM range stays 1-cycle. Every MMIO handoff
first spends one cycle in the router hold, may wait additional cycles while
committed stores drain, and returns one cycle after terminal accept. Cached
accesses complete by handshake with variable
latency — an L1 hit in a few cycles, a miss after a writeback/fill round trip
through `frost_cache`
(direct-mapped, 32 B lines, write-back write-allocate, single-outstanding)
and, on X3, the URAM L2, down to the DDR AXI port. `cached_tier_adapter`
converts CPU words to cache lines and serializes one transaction at a time;
`data_mem_request_router` folds the handshake completions into the LQ/SQ
ordering gates so reads never pass an in-flight write; its registered pending
Q also feeds directly back into the LQ bus-busy gate while a device read is
parked.

Stores publish code via `fence.i`: the ROB serializer drains the store
queue, then holds commit while the hierarchy writes back every dirty L1D
line and invalidates the L1I (strictly in that order, so an instruction
fill racing the sync can never survive with stale data), and the commit's
flush pulse drops the fetch buffer before the refetch. The caches
re-invalidate on ANY reset (tag sweep), so a JTAG program reload never
observes stale lines. `ENABLE_CACHED_TIER=0` omits the hierarchy
(cached-region accesses complete with zero data and fetch falls back to
the low-BRAM-only path); `CACHED_HAS_L2` selects the board shape, and
`USE_BEHAVIORAL_DDR=0` routes the bridge's AXI master to the top-level
`o_ddr_axi_*` ports for the board DDR controller instead of the
simulation-only behavioral model.

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

The MMIO bus rides the 64-bit data tier
([docs/rv64/m1_data_tier.md](../../docs/rv64/m1_data_tier.md)): registers
appear in their address-matching lanes of the aligned dword. The
dword-aligned CLINT pairs support native 64-bit access — an 8-byte load of
`mtime` (`0x4001_BFF8`) returns the whole counter single-copy-atomically,
and an 8-byte `mtimecmp` store lands atomically (the 32-bit lo/hi aliases
keep their word semantics). UART and FIFO registers are 32-bit-access-max:
a wider store writes only the addressed word lanes.

The hardware UART console is configured for 115200 baud, 8 data bits, no
parity, and 1 stop bit (8N1).

For no-MMU Linux, the same UART is also reachable through a standard
ns16550a register face at `0x4000_1000` (word stride; device-tree
`reg-shift=2`, `reg-io-width=4`; `earlycon=uart8250,mmio32`), and the timer
through a SiFive-CLINT-compatible window at `0x4001_0000` (`mtimecmp` at
`+0x4000`, `mtime` at `+0xBFF8`). Both alias the native registers listed
above onto the same hardware, so the in-tree Linux 8250 console and CLINT
timer drivers work without a board-specific driver.

If these addresses change, update `cpu_and_mem.sv`, `cpu_ooo.sv` parameters,
`sw/common/link.ld`, `sw/lib/include/mmio.h`, and the verification constants in
`verif/config.py`.

## Build and Simulation

From the repo root (simulation and synthesis checks run in the pinned
container via the wrapper; Vivado builds run natively):

```bash
# Cocotb/Verilator simulation
./scripts/frost.py cocotb hello_world
./scripts/frost.py cocotb tomasulo_test
./scripts/frost.py cocotb --list-tests    # show all registered tests

# Open-source RTL synthesis checks
./scripts/frost.py synthesis

# Vivado FPGA builds
./fpga/build/build.py x3
./fpga/build/build.py genesys2
```

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
| `frost.sv` | `CACHED_HAS_L2` | `1` | 1 splices the 2 MiB URAM L2 between L1 and main memory (X3 shape); 0 is L1-only (Genesys2) |
| `frost.sv` | `L1_CACHE_BYTES` / `L1I_CACHE_BYTES` / `L2_CACHE_BYTES` | `128 KiB` / `16 KiB` / `2 MiB` | Data L1, instruction L1I, and L2 cache sizes |
| `frost.sv` | `USE_BEHAVIORAL_DDR` | `1` | 1 ends the tier in the simulation-only DDR model; 0 exports the bridge's AXI master on `o_ddr_axi_*` |
| `frost.sv` | `DDR_MODEL_BYTES` / `DDR_MODEL_LATENCY` | `64 MiB` / `30` | Behavioral DDR model size and access latency (simulation) |
| `frost.sv` | `FETCH_VALID_FUZZ` | `0` | Simulation-only: 1 wraps the low BRAM in a variable-latency fetch model (LFSR fetch-valid gaps) that mirrors the L1I provider's fetch contract; hardware keeps 0 |
| `cpu_ooo.sv` | `MMIO_ADDR` | `32'h4000_0000` | MMIO base |
| `cpu_ooo.sv` | `MMIO_SIZE_BYTES` | `32'h2C` | MMIO range size; `cpu_and_mem.sv` overrides to `32'h1_C000` (covers the ns16550a face + CLINT alias) |

Simulation overrides parameters through Verilator generics (`-G`): the test
Makefile enables the cached tier with the X3 hierarchy shape by default
(`CACHED_HAS_L2=0` selects the Genesys2 shape), sets the behavioral DDR
model's size/latency, and sizes the low BRAM at the 256 KiB hardware value
(`SIM_MEM_SIZE_BYTES`). The cache unit benches drive `frost_cache_hierarchy`
directly with `-GHAS_L2={0,1}`, and the fetch-fuzz program runs select a
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
