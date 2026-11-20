# FROST SoC wrapper

`platform_top` composes [cpu_top](../cpu_top/README.md) and `soc_top`. `frost` supplies the UART, FIFOs, board-facing signals and clock/reset synchronization. `soc_top` owns low instruction/data BRAM, the programming port, Debug Module/transport, timers, APLIC, UART register faces, memory-error registers, NIC and DMA test engine.

`soc_axi_slave` receives the CPU's full physical-address AXI master. Cached DDR addresses go to the board DDR port after base subtraction. That private port is five ID bits wide and uses whole-line beats; requests that cannot be represented there are rejected instead of truncating an ID or address. Other requests pass through a local request/response interface. Each local access executes once, with response buffering independent of AXI backpressure. `LOCAL_USER_ENABLE=1` carries the captured AWUSER field with local writes. The default value is zero and the local user output is zero. A request rejected by the decoder or an instruction fetch to device memory produces no peripheral side effect.

Local instruction reads select the instruction BRAM copy using AxPROT[2].
Data reads select the data copy. Programming writes both copies through the
div4 interface, and debug stores use the slice writer to mirror data into
instruction memory. The SoC instantiates the instruction memory in data-only
mode. The CPU performs fetch predecode after the AXI response. Normal CPU
stores do not silently rewrite the separate instruction copy.

Coherent builds capture the debug mirror address while its hold slot is empty.
An occupied slot holds its address until the slice writer accepts it. The held
address is selected only while the slot is valid. The coherent debug module
computes dirty-word updates for both debug-request acceptance outcomes. Request
readiness selects the result after reseeding, word clearing and command writes.
Writes to program-buffer and abstract-command words take priority over clearing.
The coherent slice writer counts accepted requests with per-bit carry predicates.
An accepted request toggles each bit whose lower bits are all ones.
Request readiness qualifies the carry predicates. Request validity selects
between the prepared count and the held count.

When an address slot is empty, an accepted AXI address can pass directly to the local port; a stalled request waits in that slot with its owner and payload. Device requests are then registered before address decoding and execution, separating AXI arbitration from peripheral side-effect controls. Completions wait until the memory access or peripheral write/read-consume pulse has executed. Narrow transfers keep their byte enables; the boundary rebuilds the register files' replicated-word write view from AXI's addressed lanes. Device response data is captured before a destructive read consumes UART/FIFO/APLIC state, and holding RVALID does not consume a second item.

The NIC, DMA test engine and optional external peripheral window
(`EXT_AXIL_WINDOW=1`, 16 KiB at `0x4002_4000`-`0x4002_7FFF`) use 64-bit
AXI4-Lite register ports.
The local device decoder launches registered AW/W or AR channels for their
windows and waits for B or R. The returned status reaches the CPU response,
and RDATA enters the MMIO read-data register once. Other device windows use
the local side-effect sequence. With the cached tier disabled, the NIC and
DMA windows read zero and writes have no effect, while `EXT_AXIL_WINDOW=1`
operates in both cached and BRAM-only builds behind an `axil_register_slice`.

The AXI4-Lite master, register bridges and external AXI4-Lite slice use `i_clk`
and `o_soc_rst` (the SoC-side core reset). With `ASYNC_CPU_CLOCK=1`, CPU
requests cross the memory AXI FIFOs before reaching this register path, and
completions return through the same boundary. The AXI4-Lite channels stay
within the SoC clock domain.

Each block's `axil_reg_bridge` selects 32-bit write lanes and aligned read
pairs. Complete eight-byte stores at the NIC's RX_BASE64/TX_BASE64 offsets
and the engine's SRC64/DST64/STATUS_ADDR64 offsets use a separate 64-bit
write enable. Partial stores to those dwords have no effect. The NIC's
software RESET leaves the AXI4-Lite transaction intact. Subsystem reset
clears both register slaves and the master's pending channels; an access
waiting on a reset slave completes with OKAY and zero read data.

FROST enables `cpu_top.CACHE_NORMAL_MEMORY` for BRAM read caching and narrow write-through stores. The local slave also accepts aligned 32-byte instruction reads, assembled from four BRAM dwords before one AXI response. After the first synchronous RAM read, the serializer captures one dword per clock while requesting the next. Wide Device accesses and wide writes are rejected. Narrow BRAM requests access RAM on acceptance and complete after the RAM edge; Device requests go through the registered side-effect sequence. A completed local response can pass directly to AXI when its response slot is empty. AXI backpressure or a previously selected DDR response instead captures it in that slot; neither case repeats the access. The private local read response is as wide as the outgoing AXI data bus, while local writes are a 64-bit value with eight byte strobes.

A core-only reset leaves the AXI decoder running so it can drain transactions from the old CPU epoch. Fabric reset clears the decoder and its response buffers and also asserts CPU reset, so the CPU cannot retain requests that the fabric has discarded. The behavioral DDR model also takes the fabric reset and keeps its memory contents. All clock crossings for programming, debug transport, NIC, board I/O and
the optional CPU clock are outside `cpu_top`.

`ASYNC_CPU_CLOCK=0` connects the CPU and SoC on `i_clk` with direct wires.
The core and NIC reset registers sample the core and fabric reset requests
on each rising edge. A one-edge request asserts CPU reset with
`rst_core` and holds CPU reset for one more edge after `rst_core` drops.
The external DDR reset synchronizer in `frost` captures a request while
this clock is stopped and holds it until the clock advances.
`ASYNC_CPU_CLOCK=1` selects `i_cpu_clk` for the CPU, the coherent bridge,
IMSIC decoder, Debug Module and the core side of the JTAG transport. The
programming port and UART use `i_clk_div4`, derived from `i_clk`.

| Crossing | Transport |
| --- | --- |
| CPU memory master to SoC | One asynchronous FIFO for each of AW, W, B, AR and R, carrying all AXI attributes |
| DMA mux to coherent bridge | Five asynchronous FIFOs between the SoC and CPU clocks |
| Interrupt levels | Two-flop synchronizers for MEIP, SEIP, MTIP and MSIP |
| Writable machine timer | A held 64-bit snapshot with synchronized request and acknowledgement toggles |
| MSI stores | A FIFO of address/data pairs before the CPU-clocked IMSIC decoder; CPU stores reserve space before execution, and APLIC delivery waits for space |
| Debug slice programming | A held request handshake acknowledged after the slice writer completes its BRAM writes |
| Retirement diagnostics | Coherent snapshots of the latest PCs, IRQ status and accumulated retirement activity |
| System and fabric reset | Asynchronous assertion and release only after both domains clock their reset chains |

The CPU time CSR observes a delayed snapshot of the SoC timer. A snapshot
contains one complete timer value, including software writes. MTIP uses the
SoC comparator and crosses as a level. Diagnostic snapshots coalesce
retirement activity and do not provide an instruction trace. The boot
address is constant throughout reset and execution.

The memory FIFOs reset with the fabric. CPU-only reset leaves those FIFOs
and the SoC slave running while the CPU master drains its requests. The
DMA FIFOs, mux, coherent bridge, NIC and engine reset with the CPU epoch.
With independent clocks, each domain leaves reset only after both clocks
have advanced their reset chains. The two domains can leave reset on
different edges.
MSI writes that execute while `soc_cpu_rst` is asserted complete without
posting an interrupt. Presented AXI transactions can execute after reset
release and have device side effects, as specified by the CPU's reset-drain
contract.
The Debug Module survives `ndmreset` and SYSRESET and resets with the external reset.
The SYSRESET register at `0x4002_F000` raises the same core reset. A write
with both low byte strobes set and low 16 data bits `0x7777` holds a request
for 64 `i_clk` cycles; the upper data bits are ignored. Reads return zero.
Byte writes, other low-halfword values and neighbouring addresses do nothing.
A qualifying write reloads the counter. External reset cancels the request;
the core reset it causes does not, so the pulse expires on its own.
The request crosses through the existing reset pairs in asynchronous mode.
BRAM and DDR storage survive, but dirty cache lines are discarded, just as
with `ndmreset`. The CPU restarts at its boot address; software must arrange
any writeback and image restoration needed to boot again. OpenSBI uses the
register through `syscon-reboot` for cold and warm SBI reset requests.
The separate power-on request clears debug transport ownership and the
pending DMI request. Its CPU side uses `i_cpu_clk` in this configuration;
its TCK side asserts asynchronously and can release independently. The
CPU clock runs while power-on reset is held. The [RTL guide](../README.md#build-and-simulation)
describes the power-on contract.

Debug CSR operations run beside the CPU. Debug-mode metadata accompanies
each AXI write through AWUSER bit 0; the adapter holds that bit while AW
waits. A debug store to low BRAM receives OKAY only after the slice writer has
mirrored its words into the instruction copy. An external reset that
cancels a pending mirror returns SLVERR while the memory transport drains.
The local slave carries the AWUSER value with its request. CPU-generated
USER values have no other platform meaning.

When `ASYNC_CPU_CLOCK=1`, `boards/x3/constr/cpu_clock_boundary.tcl` and
`asic/constraint.sdc` bound CPU/SoC crossing delays (Gray-pointer skew and
held payloads) at 0.8 of the faster clock's period. On the X3,
`boards/x3/constr/cpu_clock_boundary.tcl` always defines `cpu_dtm_tck` on the
debug-transport `BSCANE2` primitives and bounds CPU/TCK toggle synchronizer
inputs at 0.8 and held DMI payloads at 1.5 of the faster clock's period
(`asic/constraint.sdc` still bounds CPU/TCK crossings at 0.8 only when the
asynchronous CPU boundary is enabled). Clock-group exceptions must not
override these bounds.

The NIC and the DMA test engine are AXI4 masters with 256-bit data. Each
moves a 32-byte line per beat, except in the engine's burst mode, which uses
four narrow beats per line ([AXI library](../lib/axi/README.md)).
Setting `EXT_DMA_PORTS` above zero appends external 256-bit AXI4 DMA slave
ports (with `EXT_DMA_ID_BITS`-wide IDs) to `axi_mux`, each behind an
`axi_register_slice` on `i_clk` and `o_soc_rst`. Setting `EXTERNAL_MAC=1`
omits the internal `nic_mac_10g` block and exports the primary `nic_engine`'s
core-clock 64-bit AXI4-Stream TX/RX and MAC sideband ports to the SoC
boundary.
`axi_mux` joins the masters, round-robin per burst, and
`axi_coherent_bridge` turns their bursts into line requests on `cpu_top`'s
coherent ingress ([lib/axi](../lib/axi/README.md)). A burst outside cached
DDR is answered DECERR and an illegal one SLVERR, without a line request.
With `ASYNC_CPU_CLOCK=0`, the NIC, engine, mux and bridge reset with
`rst_core`. The ingress samples the same core-reset assertion as the bridge
and discards its pending response before the bridge can reuse the line ID.
An external DDR interconnect reset asserts both registered resets.
Any unfinished DMA transaction, including a request accepted on the
first transport reset edge, is discarded when the owners sample reset.
The SoC cannot undo a completed external write. The memory controller and
its initialization logic determine which bytes survive a board reset.
The alias and peripheral register masters hold presented requests until
acceptance or the reset edge shared with their receivers. With
`ASYNC_CPU_CLOCK=1`, the paired core reset includes the DDR interconnect
reset and resets both sides of the DMA path.

Coherent read errors propagate to the NIC's failed-descriptor path.
The DMA test engine aborts a failed transfer, drains its accepted response,
sets ERROR instead of DONE, and does not write success status. Board DDR
errors show in the memory-error counters. A fatal buffered-store
error stops the CPU; `platform_top.cpu.o_fatal_error` and `o_fatal_addr` hold
the failure for platform diagnostics until CPU reset.

`FETCH_VALID_FUZZ=1` delays local instruction completion using the configured
LFSR seed; it never changes a presented AXI response or repeats a memory access.

The APLIC has five sources and one hart, with direct and MSI delivery. Both
domains reset to direct mode. The four MSI address registers reset to locked
machine and supervisor IMSIC page addresses derived from the decoder bases
and `NUM_HARTS`. Its machine
and supervisor domains occupy 32 KiB at `0x4400_0000` and `0x4400_8000`.
Only 32-bit accesses reach its registers. Other writes are ignored and other
reads return zero without side effects, including reads covering `claimi`.

The IMSIC store decoder covers `[0x4800_0000, 0x4820_0000)`. Hart h's
machine page is `0x4800_0000 + 0x1000*h` and its supervisor page is
`0x4810_0000 + 0x1000*h`. `NUM_HARTS` defaults to one and supports up to
256 pages at each level. Each CPU owns its two 63-identity files and their
CSR ports. The SoC outputs CPU-clocked per-hart valid and level signals and
a shared identity. The CPU registers the identity as a one-hot pending mask.

Only aligned 32-bit stores at offsets 0 and 4 generate MSIs. Byte, halfword
and doubleword stores are ignored. Loads throughout the window return zero
without consuming an interrupt. CPU stores have priority over APLIC MSI
offers on the decoder port. An APLIC address with any bit above bit 31 set
is consumed and dropped before narrowing. The PMA device window permits
translated stores and prohibits instruction fetch, AMO, LR and SC.
