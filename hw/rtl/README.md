# FROST RTL

This directory holds FROST's synthesizable SystemVerilog: a single-hart
RV64GCB out-of-order CPU, its memory system, and its peripherals. The CPU
schedules with Tomasulo's algorithm, decodes, renames, and commits up to two
instructions per cycle, and runs M, S, and U modes with Sv39 virtual memory.
Around it sit 256 KiB of on-chip BRAM, a three-cache hierarchy over a configurable DDR aperture of
DDR, an APLIC, a RISC-V debug module, and a 10GBASE-R NIC.

The RTL is portable. Defining `FROST_XILINX_PRIMS` selects explicit Xilinx
primitives in a few modules. `FROST_RVFI_DII`, for simulation only, builds
the [TestRIG](../../verif/testrig/README.md) variant, which runs an injected
instruction stream and reports every retired instruction. Board integration
lives in `boards/` and `fpga/`, and `frost.f` lists every source in
compilation order.

## Top-Level Shape

The [CPU and system architecture diagram](../../docs/diagrams/frost-architecture.svg)
shows the datapath, translation, memory tiers, MMIO, and debug interfaces.
The [cache diagram](../../docs/diagrams/cache-hierarchy.svg) expands the
cache hierarchy.

`frost.sv` wraps `platform_top` with reset synchronization, UART clock
crossings, and MMIO FIFOs. `platform_top` connects the reusable
[cpu_top](cpu_top/README.md) to the FROST [soc_top](soc_top/README.md) through
one AXI4 master and an optional coherent-agent ingress. `cpu_top` contains the
pipeline, MMUs, caches and memory-system logic, as one hart (`frost_hart`)
and the shared L2 and AXI master below it (`frost_cluster_memory`). `soc_top`
owns low BRAM, peripheral registers, timers/APLIC, debug transport, NIC, DMA
and the DDR connection. `i_clk` runs SoC logic; `i_clk_div4` runs UART and
programming logic. With the default `ASYNC_CPU_CLOCK=0`, the CPU also uses
`i_clk`. With `ASYNC_CPU_CLOCK=1`, `i_cpu_clk` runs the CPU, coherent bridge,
IMSIC decoder and Debug Module. AXI asynchronous FIFOs and control
synchronizers in `soc_top` connect those domains. The standalone CPU has
one clock; its integrating wrapper owns clock crossings.

| Stage | Main files | Role |
|-------|------------|------|
| IF | `cpu_and_mem/cpu/if_stage/` | 64-bit fetch window, branch prediction, instruction alignment |
| PD | `cpu_and_mem/cpu/pd_stage/` | Compressed-instruction decoding and early branch redirects |
| ID | `cpu_and_mem/cpu/id_stage/` | Decode and prepare up to two instructions for dispatch |

The back end has a 32-entry ROB, separate integer and FP rename tables, four
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
| `platform_top.sv` | FROST CPU/SoC composition |
| `cpu_top/` | Standalone CPU: one hart (`frost_hart.sv`), the shared L2 and outgoing AXI master (`frost_cluster_memory.sv`), and their composition (`cpu_top.sv`) |
| `soc_top/` | FROST memory, peripheral and debug integration |
| `cpu_and_mem/` | Shared pipeline and platform component implementations |
| `cpu_and_mem/imem_predecode.sv` | Low-BRAM instruction memory and predecode metadata |
| `cpu_and_mem/low_bram_fetch_presenter.sv` | Fixed-latency TestRIG and unit-bench fetch presenter |
| `cpu_and_mem/fetch_provider.sv` | Cached and uncached instruction fetch buffers |
| `cpu_and_mem/dma_test_engine.sv`, `dma_test_engine_axi.sv` | Coherent DMA copy/fill engine, and its AXI4 master |
| `cpu_and_mem/hang_triage.sv` | UART diagnostics for hardware hangs (`ENABLE_HANG_TRIAGE=1`; default 0) |
| `cpu_and_mem/debug/` | JTAG transport and RISC-V debug module |
| `cpu_and_mem/cpu/cpu_ooo/` | CPU integration and pipeline control |
| [cpu_and_mem/cpu/tomasulo/](cpu_and_mem/cpu/tomasulo/README.md) | Dispatch, ROB, rename tables, queues, and functional-unit adapters |
| `cpu_and_mem/cpu/if_stage/`, `pd_stage/`, `id_stage/` | Front-end pipeline stages |
| `cpu_and_mem/cpu/mmu/` | Sv39 TLBs and hardware page-table walker |
| `cpu_and_mem/cpu/csr/`, `control/trap_unit.sv` | Privileged state, exceptions, and interrupts |
| `cpu_and_mem/cpu/wb_stage/generic_regfile.sv` | Integer and FP register files |
| `cpu_and_mem/cpu/ex_stage/` | ALU, multiply/divide, FPU, and branch execution |
| [lib/cache/](lib/cache/README.md) | Cache hierarchy (a hart's L1s in `frost_hart_cache.sv`, the shared L2 level in `frost_cluster_cache.sv`), coherence, DDR bridge, and simulation DDR model |
| [lib/axi/](lib/axi/README.md) | AXI4 DMA interconnect, coherent ingress bridge and AXI4-Lite register bridge |
| `lib/` | RAM, FIFO, and clock-domain-crossing primitives |
| [peripherals/imsic/](peripherals/imsic/README.md) | AIA IMSIC with machine and supervisor interrupt files in each CPU, with SoC MSI store decode |
| [peripherals/nic/](peripherals/nic/README.md) | Ethernet NIC with coherent DMA |
| [peripherals/aplic/](peripherals/aplic/README.md) | AIA APLIC with machine and supervisor domains, direct delivery and optional MSI forwarding |
| [net10g/](net10g/README.md) | Portable 10GBASE-R MAC/PCS |
| `peripherals/` | UART transmit and receive blocks |

## Memory Map

| Region | Address | Size | Contents |
|--------|---------|------|----------|
| ROM | `0x0000_0000` | 95 KiB | Code and read-only data (low BRAM) |
| DEBUG | `0x0001_7C00` | 1 KiB | Debug-module execution slice (see [Debug](#debug)); reserved by every linker script that uses low BRAM and written only by the debug module |
| RAM | `0x0001_8000` | 160 KiB | Data, BSS, and stack (low BRAM) |
| MMIO | `0x4000_0000` | 196 KiB | Device registers (table below) |
| APLIC | `0x4400_0000` | 4 MiB | AIA direct and MSI delivery, M and S domains of 32 KiB each |
| IMSIC | `0x4800_0000` | 2 MiB | 4 KiB M and S pages at `0x4800_0000` and `0x4810_0000`, with `0x1000` hart stride |
| DDR | `0x8000_0000` | Configured 1–128 GiB (1 GiB default aperture) | Cached region: `.ddr_text` code, large data, and the heap; software must use the populated size |

Addresses outside the defined regions, including the rest of the device
quadrant `[0x4000_0000, 0x8000_0000)` and addresses at or beyond the
configured DDR end (`0x8000_0000 + 2^FROST_DDR_CAPACITY_LOG2_BYTES`), are
unmapped: a fetch, load, store, or AMO there raises a precise access fault
(cause 1, 5, or 7) and never aliases onto the map. DDR addresses above 4 GiB
remain valid when they are inside the configured aperture. At the default
1 GiB capacity, `0xc000_0000` and higher addresses fault. Fetch also faults
in the low BRAM above its 128 KiB code region `[0, 0x2_0000)`. The one
exception is a store to the rest of the device quadrant with translation off: the
store-issue check covers the whole quadrant, so the store issues and the
device bus ignores it. Under Sv39, a misaligned-address or page fault takes priority over the
access fault; for an untranslated access, the access fault takes priority
over misalignment.

The ROM, DEBUG, and RAM regions divide the 256 KiB low BRAM as the unified
linker script (`sw/common/link.ld`) does. Low BRAM holds separate instruction
and data copies. The data copy covers all 256 KiB; the instruction copy
covers only the first 128 KiB, the code region, which holds ROM, DEBUG, and
the first 32 KiB of RAM. The JTAG loader writes both copies (the instruction
copy only below 128 KiB), but outside Debug Mode CPU stores reach only the
data copy, so code in low BRAM cannot be modified at run time; put
self-modifying code in DDR. Low-BRAM data and instruction accesses cross
the same variable-latency AXI boundary as other CPU requests. FROST enables
Normal read caching: 32-byte fetches fill an 8 KiB direct instruction cache,
and aligned dword data reads fill L0. Stores remain narrow write-through
accesses, and the debug data page bypasses the read cache. The standalone
CPU defaults to strict uncached access with 8-byte instruction fetches.
The CPU computes predecode metadata from the returned bytes. The SoC executes
each local access once and buffers its completion independently of AXI
backpressure; see the [CPU interface](cpu_top/README.md).

Instruction fetch and data accesses both reach the cached region. The
hierarchy has a 128 KiB L1D, a 16 KiB L1I, and a shared 2 MiB L2. All three
are 4-way set-associative with tree pseudo-LRU replacement (the L1D with
bimodal insertion), write-back, and write-allocate, on every target. The L1s
use 32-byte lines; the L2 uses 64-byte lines, each holding two of them, and
moves whole lines to and from DDR as single 512-bit AXI transfers. With
`L2_LINE_BYTES=32` the L2 uses the L1s' line size and the DDR port is 256
bits wide. Cached accesses
have variable latency, and L1 hits proceed while misses are pending. The L1D,
the page-table walker, the L1I, and DMA share the hierarchy in that priority
order, with a bound on DMA starvation, and below them a stream prefetcher
reads ahead of ascending L1D miss streams into the L2. DMA and page-table
walks see dirty L1D data without software cache maintenance. Code fetched from DDR passes through
a buffer of two active lines and six victim lines in front of the L1I. See
the [cache guide](lib/cache/README.md).

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
| `0x4000_0028` | UART_TX_STATUS | Bit 0 is TX ready: at least 64 more bytes fit in the transmit FIFO |
| `0x4000_1000`–`101C` | ns16550a UART face | 16550 register file (word stride) aliasing UART_TX/RX for the Linux 8250 driver |
| `0x4001_0000` | CLINT MSIP | SiFive CLINT alias of MSIP |
| `0x4001_4000`/`4004` | CLINT MTIMECMP_LO/HI | SiFive CLINT alias of MTIMECMP |
| `0x4001_BFF8`/`BFFC` | CLINT MTIME_LO/HI | SiFive CLINT alias of MTIME |
| `0x4002_0000`–`0057` | DMA test engine | Legacy CTRL/ACK/SRC/DST/LEN/MODE/PATTERN/STATUS_ADDR/STATUS_VALUE/LINES plus versioned ABI_CTRL and SRC64/DST64/STATUS_ADDR64 (`dma_test_engine.sv`, `sw/lib/include/dma_engine.h`) |
| `0x4002_1000`–`1038` | Memory error unit | CAPS/STATUS/IRQ_EN/CE_COUNT/UE_COUNT/AXI_RD_ERRS/AXI_WR_ERRS/CE_ADDR/UE_ADDR/AXI_ERR/ECC_POLLS (`memory_error_unit.sv`, `sw/lib/include/memory_error.h`) |
| `0x4003_0000`–`0FFF` | NIC | 4 KiB window: control and status, station address, rings, link and PHY, 64-bit counters (`peripherals/nic/nic_pkg.sv`, `sw/lib/include/nic.h`) |

The UART console runs at 115200 baud, 8N1. For Linux, the same UART also
appears as an ns16550a at `0x4000_1000` (word stride: device tree
`reg-shift=2`, `reg-io-width=4`; `earlycon=uart8250,mmio32`), and the timer
as a SiFive CLINT at `0x4001_0000` (`mtimecmp` at `+0x4000`, `mtime` at
`+0xBFF8`). Both are aliases of the native registers, so the kernel's
standard 8250 and CLINT drivers work without a board-specific driver. The
16550's LSR.THRE and its THRE interrupt follow UART_TX_STATUS, so the 8250
driver's 16-byte burst per THRE always fits, and LSR.TEMT reads 1 only once
every byte written has been sent.

The [APLIC](peripherals/aplic/README.md) implements AIA 1.0 direct and MSI delivery.
Its machine and supervisor domains at `0x4400_0000` and `0x4400_8000`
drive the CPU's IMSIC direct inputs. Each file resets to APLIC delivery;
its registered line supplies `mip.MEIP` or the external contribution to
`mip.SEIP`, which is ORed with the SEIP bit M-mode software can set. Each domain occupies 32 KiB and has one IDC for hart
0. Source identities are 1 for the ns16550 UART, 2 for the external pin,
3 for the DMA test engine, 4 for the NIC, and 5 for the memory error unit.
OpenSBI delegates all five sources to the supervisor domain. Linux configures
them for level-high delivery through the supervisor IMSIC file. Both APLIC
domains reset to direct delivery for programs that do not configure MSIs.
The generated firmware tree links both APLIC domains to their IMSIC nodes.

A `claimi` read returns the identity in bits 25:16 and priority in bits 7:0.
It clears detached and edge-sensitive pending bits; a level-sensitive source
stays pending until the device drops its level. There is no completion write.
The SoC performs claims only on 32-bit reads (see the
[data-tier bus contract](#data-tier-bus-contract)).

The memory error unit counts the DDR controller's corrected and uncorrectable
ECC errors and the error responses DDR returns to the cache hierarchy's AXI
bridge. It keeps the physical address of the latest ECC report of each kind
and the response code and AXI id of the latest error response, and interrupts
for the kinds `IRQ_EN` enables. An error response still completes the
transfer, so a read delivers its data and the report arrives after the
access. On the X3, `boards/x3/x3_ecc_reader.sv` polls the DDR4 controller's
ECC registers about once a millisecond and reports to the unit; on a board
without a reader, `CAPS` bit 0 reads 0 and only the error responses count.

If these addresses change, update `soc_top/soc_top.sv`, the device-window pages
in `riscv_pkg.sv` (`MmioFirstPage` through `ImsicLastPage`), the MMIO `PROVIDE`
symbols in the linker scripts under `sw/` (`sw/common/link.ld`,
`sw/common/link_ddr.ld`, and several app-specific scripts),
`sw/lib/include/mmio.h`, the verification constants in `verif/config.py`, and
the Linux device tree generated by
`linux/buildroot-external/board/frost/frost_boot_image.py`. A simulation
stops at time zero if the device-window pages disagree with the windows in
`soc_top/soc_top.sv` or break the layout the PMA's page decodes assume (see the
check in `soc_top/soc_top.sv`). The debug slice's location is
`riscv_pkg::DebugSliceBase`; every FROST linker script that uses low BRAM
reserves it as the `DEBUG` region.

### Data-tier bus contract

The internal data-side interfaces between the queues, request router and
CPU adapters carry a 64-bit dword container (`riscv_pkg::MemDataBits`) with an 8-lane
byte strobe (`MemStrbBits`). The beat is selected by the configured physical
address bits above bit 2, and byte lane *i* has that same beat address with
byte offset *i*. Producers position data by
`addr[2:0]` and consumers extract by `addr[2:0]`:

- Stores replicate their data across the beat (`{8{byte}}`, `{4{half}}`,
  `{2{word}}`, a dword as is) and the strobe selects the lanes:
  `BYTE = 8'h01 << addr[2:0]`, `HALF = 8'h03 << {addr[2:1], 1'b0}`,
  `WORD = addr[2] ? 8'hF0 : 8'h0F`, `DOUBLE = 8'hFF`
  (`riscv_pkg::mem_strobe_for`). Replication keeps the write-data mux
  shallow; there is no byte-lane shifter.
- Cached reads and optional Normal read-cache fills return the whole beat.
  Strict uncached and Device AXI reads guarantee only the requested byte lanes
  and never fill L0. `load_unit` selects the word by `addr[2]`,
  then the halfword or byte, then sign- or zero-extends. LD and FLD take the
  beat whole.
- MMIO registers sit in their address-matching lanes (a 32-bit register at
  offset +4 occupies lanes [63:32]), so extraction has no MMIO special case.
- A dword access never spans beats, so there is no beat-crossing logic; the
  size-cased misalignment checks cover the 8-byte class (`|addr[2:0]`).
- The load queue's L0 cache and store-to-load forwarding work on dwords. The
  data BRAM's `$readmemh` image is the dword-paired `sw64.mem`
  (`sw/common/make_dword_mem.py`); `sw.mem`, `sw.txt`, and both DDR images
  stay in 32-bit words.
- Cached loads are tagged. The load queue names one of its
  `riscv_pkg::CachedLoadSlots` slots on each cached launch, and the response
  returns it beside the beat, so several cached loads can be in flight and
  complete in any order. Loads of one line share a line request in the
  cached-tier adapter, except LRs and AMOs, and a store closes that sharing
  for every line.
  Uncached Normal and Device reads share one response owner until AXI R is
  consumed. The router arbitrates their completed response with cached beats;
  no later uncached read may overwrite that owner. The outgoing 256/512-bit
  AXI port preserves the original narrow Device size, address and strobes;
  optional Normal read caching widens only eligible reads. See the
  [CPU interface](cpu_top/README.md).

The MMIO bus follows the same rules. The dword-aligned timer pairs, native
and CLINT alias, support 64-bit access: an 8-byte load of `mtime`
(`0x4001_BFF8`) returns the whole counter atomically, and an 8-byte
`mtimecmp` store lands atomically. The 32-bit lo/hi aliases keep their word
behavior. UART and FIFO registers are 32-bit-access-max: a wider store writes
only the addressed word. The APLIC accepts only 32-bit accesses. Byte,
halfword and doubleword writes are ignored; reads of those sizes return zero without side effects. The DMA
test engine, memory error unit, and NIC windows provide 32-bit registers:
a 64-bit load returns an aligned register pair, and a 64-bit store writes
only the upper register. The NIC's RX_BASE64/TX_BASE64 registers and the DMA
engine's SRC64/DST64/STATUS_ADDR64 bank accept complete aligned 64-bit
stores; partial writes to those dwords have no effect. The NIC and DMA
register windows use 64-bit AXI4-Lite. Each block's register bridge buffers
AW and W independently, applies the register access once, and holds its
registered OKAY response until accepted. Other windows use the local MMIO
sequence. Devices take loads and stores only, and
only inside the MMIO, APLIC and IMSIC windows. A load or store elsewhere in the device
quadrant raises an access fault (cause 5 or 7), and so does an AMO, LR, or SC
anywhere in the quadrant (cause 7, 5, or 7); the one exception is an
untranslated store, which the device bus ignores. The device sees neither a read
nor a write, and the [memory map](#memory-map) gives how these faults rank
against misaligned-address and page faults.

IMSIC pages accept only aligned 32-bit stores, at offset 0 for little-endian
identity data or offset 4 for big-endian data. Other sizes and offsets are
ignored. All loads in the 2 MiB window return zero without side effects.
The SoC registers the decoded MSI in the CPU clock domain. With the optional
asynchronous boundary, a FIFO carries the MSI stores to that decoder.

MMIO is strongly ordered: accesses from one hart complete in program order
without fences. Uncached stores retire only after B; reads wait for R. Errors
raise precise access faults. Failed cached reads do not fill caches, and late
errors on buffered cached stores stop the CPU with a sticky fatal indication. A device read waits for committed stores to drain and is
shielded from interrupt replay, so a destructive read (the UART RX pop, a
APLIC claim) happens exactly once. See the
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

The Debug Module registers GO and its target after the instruction slice is
visible. GO stays asserted with a stable target until the hart acknowledges
it. Acknowledgement or module reset clears GO on that clock edge. Command
and resume sequencing waits for the hart's response to this request.

The system reset (the board-level reset, which on X3 follows the clock lock
and DDR readiness, and the image-load reset) also resets the debug module, so
`dmactive`, a pending halt request, and the program buffer do not survive it.
Debug Spec 0.13.2 (section 3.2) resets the module only at power-up and while
`dmactive` is 0; FROST treats these resets as power-up. `ndmreset` resets only
the core. A DMI access that arrives while the system reset is held waits, with
the DTM reporting busy, and is handled when the reset ends, with `dmactive` 0.

`debug_slice_writer` writes the module's words into the slice through the
BRAM programming port. It also mirrors Debug-Mode stores to the low BRAM's
code region into the instruction copy, so software breakpoints and debugger
writes to BRAM code are fetched. For code in DDR, OpenOCD executes `fence.i`,
which publishes its writes. Debug CSRs and `dret` are illegal outside Debug
Mode.

For OpenOCD, GDB, and VS Code use, see the
[FPGA guide](../../fpga/README.md#vs-code-debugging).

## Build and Simulation

The `frost` DDR interconnect reset asserts asynchronously. Its three-stage
release synchronizer feeds a separate register for reset distribution. That
register also asserts asynchronously and releases one clock edge after the
synchronizer. A stopped SoC clock keeps the reset asserted. CPU owners and
the fabric share this reset; CPU-only reset leaves presented AXI requests
to drain through the fabric.

Synchronous resets establish pipeline validity, queue ownership, control
state, and architectural control registers. Cache reset walks clear tags
and replacement state before accepting requests; cache data arrays do not
need clearing. The BTB clears its valid bits, and the return-address stack
clears its occupancy. Direction and TAGE tables provide speculative hints;
their contents affect prediction accuracy rather than architectural state.
Payload RAMs are qualified by ownership or validity, or written before use.
Integer consumers substitute zero for x0; the unwritten register-file row
has an unspecified read value. Software initializes the other integer and
floating-point registers it uses. Program images supply the
instruction and data memories independently of reset.

`platform_top.i_power_on_rst` is an asynchronous power-on request, separate
from system reset. Hold both resets at power-up with the selected CPU clock
running: `i_cpu_clk` when `ASYNC_CPU_CLOCK=1`, otherwise `i_clk`.
The core synchronizes the power-on request before synchronously resetting
the debug transport handshake and the debug module's pending DMI request.
These survive system reset. TCK reset asserts asynchronously, releases after
two TCK edges, and resets the TAP and transport handshake even if TCK is
stopped. TRST_N resets the TAP alone. Either transport domain may release
first: a held TCK produces no request, and a request launched while the core
is held waits for its answer after core reset releases.

The programming-clock domain also synchronizes power-on reset. It clears
instruction-memory staged write enables and blocks writes on the first
reset edge. System reset leaves this programming path available for image
loading. Fetch reset clears metadata readiness and repeated-address history.
FPGA tops tie the power-on request inactive, select `POWER_ON_RESET_ENABLE=0`
to omit its synchronizers, and use configuration-loaded initial values.
`platform_top` enables power-on reset by default. Simulation pulses it
independently of system reset in both ordinary and [random power-up mode](../../tests/README.md#random-power-up-state).
The random mode checks dependencies on initializers and uninitialized storage.

Full-board simulation with power-on reset tied inactive uses configuration
initializers. The DTM ownership assertions arm only after power-on reset in
their respective clock domains, so that configuration does not check DTM
ownership. Transport verification uses a bench that enables and pulses
power-on reset with the core clock running.

Use the [test guide](../../tests/README.md) for simulation, formal, and Yosys
runs in the pinned container, the [FPGA guide](../../fpga/README.md) for
native Vivado builds, and the [ASIC guide](../../asic/README.md) for the
OpenROAD flow. `frost.f` is the system source list and
`cpu_top/cpu_top.f` the standalone CPU's. TestRIG alone compiles
`hw/sim/frost_rvfi_platform.sv`, which provides positional instruction injection
and the fixed-latency pipeline test interface.

Simulation sets parameters with Verilator `-G` overrides. For the `frost`
top, `tests/Makefile` sets the low BRAM to its 256 KiB hardware size
(`SIM_MEM_SIZE_BYTES`), enables the cached tier with the X3 hierarchy, sets
the DDR model's size and latency, and turns on fast cache maintenance
(`SIM_FAST_MAINT=1`). Individual entries in `tests/test_run_cocotb.py` add
their own overrides, such as `-GFETCH_VALID_FUZZ=1` for the fetch-fuzz runs
and DDR latency jitter or reordering for stress runs. The cache unit benches
instantiate `frost_cache_hierarchy` directly, with smaller caches so that
evictions are cheap to reach.

`ASYNC_CPU_CLOCK=1` selects an independent CPU clock on `i_cpu_clk`.
`CLK_FREQ_HZ` describes `i_clk`, including the NIC tick and UART divisors.
The machine timer increments on `i_clk`; the CPU reads coherent snapshots
through its time CSR. The boot address is a static parameter. Reset release
waits for both clocks. Power-on reset leaves these paired system and fabric
resets separate; they establish ownership in the CPU/SoC crossings.
The [SoC guide](soc_top/README.md) describes the crossings and reset ownership.

## Parameters

The main parameters; `frost.sv` documents the rest.

| Module | Parameter | Default | Description |
|--------|-----------|---------|-------------|
| `frost.sv` | `CLK_FREQ_HZ` | Defined in `frost.sv` | SoC clock frequency |
| `frost.sv` | `ASYNC_CPU_CLOCK` | `0` | 1 selects the independent `i_cpu_clk` input and asynchronous CPU boundary |
| `frost.sv` | `MEM_SIZE_BYTES` | `2 ** 18` | Low BRAM size (256 KiB); instruction fetch reaches its first 128 KiB (`riscv_pkg::LowBramCodeAddrBits`) |
| `frost.sv` | `SIM_TIMER_SPEEDUP` | `1` | `mtime` increment per cycle (simulation) |
| `frost.sv` | `CACHED_BASE` | `32'h8000_0000` | Cached-region base address |
| `riscv_pkg.sv` | `FROST_DDR_CAPACITY_LOG2_BYTES` | `30` | Compile-time DDR aperture size as log2 bytes; 30–37 selects 1–128 GiB and derives the physical and AXI-offset widths |
| `frost.sv` | `CACHED_SIZE_BYTES` | `riscv_pkg::DdrCapacityBytes` | Cached-region aperture; keep equal to the package setting so PMA, caches, DMA and AXI agree |
| `frost.sv` | `ENABLE_CACHED_TIER` | `0` | 1 builds the cache hierarchy; simulation sets it with `-G`, and boards with a DDR controller pass 1 |
| `frost.sv` | `L1_CACHE_BYTES` / `L1I_CACHE_BYTES` / `L2_CACHE_BYTES` | `128 KiB` / `16 KiB` / `2 MiB` | L1D, L1I, and L2 sizes |
| `frost.sv` | `L2_PREFETCH` | `1` | 1 builds the L2 stream prefetcher |
| `frost.sv` | `USE_BEHAVIORAL_DDR` | `1` | 1 ends the tier in the simulation DDR model; 0 exports the bridge's AXI master on `o_ddr_axi_*` |
| `frost.sv` | `DDR_MODEL_BYTES` / `DDR_MODEL_LATENCY` | `64 MiB` / `30` | DDR model size and access latency in cycles (simulation) |
| `frost.sv` | `DDR_MODEL_LATENCY_JITTER` / `DDR_MODEL_REORDER` | `0` / `0` | DDR model per-transaction latency jitter, and out-of-order completion across ids (simulation); `FROST_DDR_MODEL_SEED` draws these and the latency for a test run ([tests/README.md](../../tests/README.md#environment-and-output)) |
| `frost.sv` | `SIM_FAST_MAINT` | `0` | Simulation only: 1 selects fast `fence.i` cache maintenance with the same functional effect |
| `frost.sv` | `FETCH_VALID_FUZZ` | `0` | Simulation only: 1 delays local instruction AXI responses to exercise variable fetch latency |
| `frost.sv` | `PERF_COUNTERS` | `0` | 1 builds the `mperf*` profiling counters |
| `frost.sv` | `DEBUG_JTAG_TAP` | `1` | 1 uses the generic TAP on `i_jtag_*`; 0 takes the BSCAN bundle from the board |
| `frost.sv` | `RAW_LOOPBACK` | `1` | 1 builds the NIC's raw TX-to-RX loopback, which needs one clock on both MAC clock ports; 0 for a transceiver's independent clocks |
| `cpu_ooo.sv` | `MMIO_ADDR` | `32'h4000_0000` (`riscv_pkg::MmioWindowAddr`) | MMIO window base; the UART RX data and FIFO pop registers are fixed offsets from it |

The compile-time aperture is an address-transport limit, not a claim that a
board has that much installed DRAM. Bare-metal links retain a safe 1 GiB
usable-DRAM default and accept `FROST_DDR_USABLE_LOG2_BYTES=30..37` in
`sw/common/common.mk`; set it no larger than the installed memory and the RTL
aperture. Linux obtains its usable range from the generated device tree's
`/memory` node (`frost_boot_image.py --mem-size`), whose 64-bit cells support
the same 1–128 GiB matrix. The boot loader must supply the installed size;
neither the CPU PA width nor the 1 GiB default identifies a DIMM's capacity.

## License

Copyright 2026 Two Sigma Open Source, LLC

Licensed under the Apache License, Version 2.0.
