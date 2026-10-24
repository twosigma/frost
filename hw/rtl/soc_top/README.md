# FROST SoC wrapper

`platform_top` composes [cpu_top](../cpu_top/README.md) and `soc_top`. `frost` supplies the UART, FIFOs, board-facing signals and clock/reset synchronization. `soc_top` owns low instruction/data BRAM, the programming port, Debug Module/transport, timers, APLIC, UART register faces, memory-error registers, NIC and DMA test engine.

`soc_axi_slave` receives the CPU's full physical-address AXI master. Cached DDR addresses go to the board DDR port after base subtraction. That private port is five ID bits wide and uses whole-line beats; requests that cannot be represented there are rejected instead of truncating an ID or address. Other requests pass through a local request/response interface. Each local access executes once, with response buffering independent of AXI backpressure. An error or an instruction fetch to device memory produces no peripheral side effect.

Local instruction reads select the instruction BRAM copy using AxPROT[2]; data reads select the data copy. Programming writes both copies through the div4 interface, and debug stores use the slice writer to mirror data into instruction memory. The CPU performs fetch predecode after the AXI response. Normal CPU stores do not silently rewrite the separate instruction copy.

When an address slot is empty, an accepted AXI address can pass directly to the local port; a stalled request waits in that slot with its owner and payload. Device requests are then registered before address decoding and execution, separating AXI arbitration from peripheral side-effect controls. Completions wait until the memory access or peripheral write/read-consume pulse has executed. Narrow transfers keep their byte enables; the boundary rebuilds the register files' replicated-word write view from AXI's addressed lanes. Device response data is captured before a destructive read consumes UART/FIFO/APLIC state, and holding RVALID does not consume a second item.

FROST enables `cpu_top.CACHE_NORMAL_MEMORY` for BRAM read caching and narrow write-through stores. The local slave also accepts aligned 32-byte instruction reads, assembled from four BRAM dwords before one AXI response. After the first synchronous RAM read, the serializer captures one dword per clock while requesting the next. Wide Device accesses and wide writes are rejected. Narrow BRAM requests access RAM on acceptance and complete after the RAM edge; Device requests go through the registered side-effect sequence. A completed local response can pass directly to AXI when its response slot is empty. AXI backpressure or a previously selected DDR response instead captures it in that slot; neither case repeats the access. The private local read response is as wide as the outgoing AXI data bus, while local writes are a 64-bit value with eight byte strobes.

A core-only reset leaves the AXI decoder running so it can drain transactions from the old CPU epoch. Fabric reset clears the decoder and its response buffers and also asserts CPU reset, so the CPU cannot retain requests that the fabric has discarded. The behavioral DDR model also takes the fabric reset and keeps its memory contents. All CDC for programming, debug transport, NIC, and board I/O is outside `cpu_top`.

The NIC and the DMA test engine are AXI4 masters with 256-bit data. Each
moves a 32-byte line per beat, except in the engine's burst mode, which uses
four narrow beats per line ([AXI library](../lib/axi/README.md)).
`axi_mux` joins the masters, round-robin per burst, and
`axi_coherent_bridge` turns their bursts into line requests on `cpu_top`'s
coherent ingress ([lib/axi](../lib/axi/README.md)). A burst outside cached
DDR is answered DECERR and an illegal one SLVERR, without a line request. The
NIC, the engine, the mux and the bridge reset with `rst_core`. The ingress
resets with `o_cpu_rst`, which adds the DDR interconnect's reset, so a
platform must assert `i_rst` whenever it holds that reset; otherwise a line
request the ingress drops would leave the NIC or the engine waiting.

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
CSR ports. The SoC outputs registered per-hart valid and level signals and
a shared identity. The CPU registers the identity as a one-hot pending mask.

Only aligned 32-bit stores at offsets 0 and 4 generate MSIs. Byte, halfword
and doubleword stores are ignored. Loads throughout the window return zero
without consuming an interrupt. CPU stores have priority over APLIC MSI
offers on the decoder port. An APLIC address with any bit above bit 31 set
is consumed and dropped before narrowing. The PMA device window permits
translated stores and prohibits instruction fetch, AMO, LR and SC.
