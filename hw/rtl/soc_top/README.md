# FROST SoC wrapper

`platform_top` composes [cpu_top](../cpu_top/README.md) and `soc_top`. `frost` supplies the existing UART, FIFOs, board-facing signals and clock/reset synchronization. `soc_top` owns low instruction/data BRAM, the programming port, Debug Module/transport, timers, PLIC, UART register faces, memory-error registers, NIC and DMA test engine.

`soc_axi_slave` receives the CPU's full physical-address AXI master. Cached DDR addresses go to the existing board DDR port after base subtraction. That private port remains five ID bits wide and uses whole-line beats; requests that cannot be represented there are rejected instead of truncating an ID or address. Other requests pass through a local request/response interface. Each local access executes once, with response buffering independent of AXI backpressure. An error or an instruction fetch to device memory produces no peripheral side effect.

Local instruction reads select the instruction BRAM copy using AxPROT[2]; data reads select the data copy. Programming still writes both copies through the div4 interface, and debug stores still use the slice writer to mirror data into instruction memory. The CPU performs fetch predecode after the AXI response. Normal CPU stores do not silently rewrite the separate instruction copy.

Local completions wait until the memory access or peripheral write/read-consume pulse has executed. Narrow transfers retain their byte enables; the boundary reconstructs the legacy register files' replicated-word write view from AXI's addressed lanes. Device response data is captured before a destructive read consumes UART/FIFO/PLIC state, and holding RVALID does not consume a second item.

A core-only reset leaves the AXI decoder running so it can drain transactions from the old CPU epoch. Fabric reset clears the decoder and its response buffers and also asserts CPU reset, so the CPU cannot retain requests that the fabric has discarded. The behavioral DDR model uses the fabric reset as well, while retaining its memory contents. All CDC for programming, debug transport, NIC, and board I/O remains outside `cpu_top`.

Coherent read errors propagate to the NIC's existing failed-descriptor path.
The DMA test engine aborts a failed transfer, drains its accepted response,
sets ERROR instead of DONE, and does not write success status. Board DDR
errors remain visible through the memory-error counters. A fatal cached-store
error stops the CPU; `platform_top.cpu.o_fatal_error` and `o_fatal_addr` remain
available for platform diagnostics until CPU reset.

`FETCH_VALID_FUZZ=1` delays local instruction completion using the configured
LFSR seed; it never changes a presented AXI response or repeats a memory access.
