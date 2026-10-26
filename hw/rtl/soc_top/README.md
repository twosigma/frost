# FROST SoC wrapper

`platform_top` composes [cpu_top](../cpu_top/README.md) and `soc_top`. `frost` supplies the UART, FIFOs, board-facing signals and clock/reset synchronization. `soc_top` owns low instruction/data BRAM, the programming port, Debug Module/transport, timers, APLIC, UART register faces, memory-error registers, NIC and DMA test engine.

`soc_axi_slave` receives the CPU's full physical-address AXI master. Cached DDR addresses go to the board DDR port after base subtraction. That private port is five ID bits wide and uses whole-line beats; requests that cannot be represented there are rejected instead of truncating an ID or address. Other requests pass through a local request/response interface. Each local access executes once, with response buffering independent of AXI backpressure. `LOCAL_USER_ENABLE=1` carries the captured AWUSER field with local writes. The default value is zero and the local user output is zero. A request rejected by the decoder or an instruction fetch to device memory produces no peripheral side effect.

Local instruction reads select the instruction BRAM copy using AxPROT[2]; data reads select the data copy. Programming writes both copies through the div4 interface, and debug stores use the slice writer to mirror data into instruction memory. The CPU performs fetch predecode after the AXI response. Normal CPU stores do not silently rewrite the separate instruction copy.

When an address slot is empty, an accepted AXI address can pass directly to the local port; a stalled request waits in that slot with its owner and payload. Device requests are then registered before address decoding and execution, separating AXI arbitration from peripheral side-effect controls. Completions wait until the memory access or peripheral write/read-consume pulse has executed. Narrow transfers keep their byte enables; the boundary rebuilds the register files' replicated-word write view from AXI's addressed lanes. Device response data is captured before a destructive read consumes UART/FIFO/APLIC state, and holding RVALID does not consume a second item.

The NIC and DMA test engine expose 64-bit AXI4-Lite register slaves.
The local device decoder launches registered AW/W or AR channels for their
windows and waits for B or R. The returned status reaches the CPU response,
and RDATA enters the MMIO read-data register once. Other device windows use
the local side-effect sequence. With the cached tier disabled, the NIC and
DMA windows read zero and writes have no effect.

The AXI4-Lite master and both register bridges use `i_clk` and the SoC-side
resets. With `ASYNC_CPU_CLOCK=1`, CPU requests cross the memory AXI FIFOs
before reaching this register path, and completions return through the
same boundary. The AXI4-Lite channels stay within the SoC clock domain.

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
| Reset | Asynchronous assertion and release only after both domains clock their reset chains |

The CPU time CSR observes a delayed snapshot of the SoC timer. A snapshot
contains one complete timer value, including software writes. MTIP uses the
SoC comparator and crosses as a level. Diagnostic snapshots coalesce
retirement activity and do not provide an instruction trace. The boot
address is constant throughout reset and execution.

The memory FIFOs reset with the fabric. CPU-only reset leaves those FIFOs
and the SoC slave running while the CPU master drains its requests. The
DMA FIFOs, mux, coherent bridge, NIC and engine reset with the CPU epoch.
Each domain leaves reset only after both clocks have advanced their reset
chains. The two domains can leave reset on different edges.
MSI writes that execute while `soc_cpu_rst` is asserted complete without
posting an interrupt. Presented AXI transactions can execute after reset
release and have device side effects, as specified by the CPU's reset-drain
contract.
The Debug Module survives `ndmreset` and resets with the external reset.

Debug CSR operations run beside the CPU. Debug-mode metadata accompanies
each AXI write through AWUSER bit 0; the adapter holds that bit while AW
waits. A debug store to low BRAM receives OKAY only after the slice writer has
mirrored its words into the instruction copy. An external reset that
cancels a pending mirror returns SLVERR while the memory transport drains.
The local slave carries the AWUSER value with its request. CPU-generated
USER values have no other platform meaning.

The board constraints and `asic/constraint.sdc` bound CPU/SoC and CPU/TCK
crossing delays below one period of the faster clock in each pair. These
bounds cover Gray-pointer skew and held payloads. Clock-group exceptions
must not override them. The board constraints define the debug transport
clock when it has no clock constraint.
`boards/x3/constr/cpu_clock_boundary.tcl` applies these conditional
constraints to the synthesized design.

The NIC and the DMA test engine are AXI4 masters with 256-bit data. Each
moves a 32-byte line per beat, except in the engine's burst mode, which uses
four narrow beats per line ([AXI library](../lib/axi/README.md)).
`axi_mux` joins the masters, round-robin per burst, and
`axi_coherent_bridge` turns their bursts into line requests on `cpu_top`'s
coherent ingress ([lib/axi](../lib/axi/README.md)). A burst outside cached
DDR is answered DECERR and an illegal one SLVERR, without a line request.
With `ASYNC_CPU_CLOCK=0`, the NIC, engine, mux and bridge reset with
`rst_core`. The ingress resets with `o_cpu_rst`, which also includes the DDR
interconnect reset. This configuration requires `i_rst` whenever that reset
is held, so a dropped ingress request cannot strand a DMA master. With
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
