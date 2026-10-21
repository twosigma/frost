# CPU integration boundary

`cpu_top` contains the RV64 CPU pipeline, MMUs and page-table walker, L0/L1D/L1I/L2 caches, fetch buffers, coherence sequencing, and outgoing AXI master. It has one clock and no board memory, peripherals, interrupt controller, debug transport, DMA engine, NIC, or power controller. Compile `cpu_top.f` with `ROOT` set to the repository root. `platform_top` connects it to the FROST `soc_top`.

## Clock, reset and boot

All ports are synchronous to the rising edge of `i_clk`. There are no clock crossings in `cpu_top`; the integrating wrapper must synchronize external controls and interrupt levels and provide a coherent snapshot of multibit inputs.

- `i_rst` is the active-high synchronous CPU reset. Hold it for at least two clock edges. Keep the halfword-aligned `i_boot_addr` stable throughout reset; both fetch PCs sample it on reset edges. After release, cache initialization and normal fetch handshakes determine when execution starts. `o_rst_done` clears on reset and rises after 255 rising edges without CPU reset. It is a reset-duration indication; it does not gate execution or indicate fabric idle.
- `i_axi_rst` resets **both sides** of the AXI connection. Assert it together with `i_rst` during initial system reset, and whenever the fabric discards outstanding transactions. Keep `i_rst` asserted for every edge on which `i_axi_rst` is asserted; resetting the transport alone would strand requests still owned by the CPU memory system. It clears ownership and gates outgoing VALID and incoming READY low. Its release must be synchronous to `i_clk`.
- A CPU-only reset does not withdraw an already presented AXI request. The master completes outstanding AW/W/AR handshakes, drains R/B responses from the old CPU epoch, and blocks new requests until that debt is gone. The fabric must continue making progress. A previously accepted device access can still have its side effect during this drain.
- CPU reset invalidates caches and discards their dirty contents. Preserve memory that must survive reset before asserting it. Reset is not a cache writeback operation.
- `o_axi_idle` covers the master's queued requests, fabric transactions, buffered responses, and reset drain. It does not prove that all dirty cache lines have reached memory, and it is not a clock-gating permission by itself.

FROST's SoC combines external reset and the Debug Module's `ndmreset` for CPU reset. The Debug Module survives `ndmreset`. Its board and JTAG clock crossings remain in `soc_top` and `frost`.

## Outgoing AXI4 master

The flat `o_axi_*` / `i_axi_*` ports are one AXI4 master. Addresses are full physical byte addresses; `cpu_top` never subtracts a platform base. Address width is `riscv_pkg::PhysAddrBits`. Data width is `8 * L2_LINE_BYTES` (default 512 bits; 256 bits with 32-byte L2 lines). `AXI_ID_BITS` defaults to 6; supported widths are 6 through 8 bits. AW and W handshake independently.

Every transaction has AxLEN=0, AxBURST=INCR, AxLOCK=0, and WLAST/RLAST=1. A wrapper must preserve AxADDR, AxSIZE, AxCACHE, AxPROT, WSTRB, IDs and RRESP/BRESP. Narrow data accesses use their original byte address and size (1, 2, 4 or 8 bytes). Data and strobes occupy the addressed lanes of the wide bus. Uncached instruction fetch uses aligned 8-byte reads, with no speculative read of a following block beyond the requested instruction window. Device memory is never fetched, prefetched, or line-filled.

| Traffic | AxCACHE | AxPROT[2] | Size |
| --- | --- | --- | --- |
| Shared writeback cache fills/writebacks | `1111` | 0 | One L2 line |
| Uncached Normal data | `0010` | 0 | Original access size |
| Device data | `0000` | 0 | Original access size |
| Uncached instruction memory | `0010` | 1 | 8 bytes |

The cache is a unified physical memory domain below its private levels: a downstream cache fill can serve instruction, data, walker, or coherent-agent requests. Its AXI transactions use the configured `AXI_MEMORY_PROT` (default `011`, privileged and Non-secure). This is the tile's bus security domain, **not** a reflection of the current RISC-V privilege mode. The CPU's MMUs enforce RISC-V permissions before cache access. An external security firewall must trust that domain; translating AxPROT into the hart's current privilege would mislabel outstanding walks and writebacks. Uncached instruction requests set bit 2 on that domain value.

| AXI ID | Owner |
| --- | --- |
| 0–31 | L2 fill/writeback ownership |
| 32 | Uncached data adapter |
| 34–35 | Two uncached instruction fetch slots |

ID 33 and IDs above 35 are unused. An ID stays owned until its CPU-side response is consumed. Different IDs may complete out of order; each response is matched to its owner. ID values do not select cacheability, device behavior, ordering or address routing.

`AXI_USER_BITS` is a positive width, default 1. AWUSER, ARUSER and WUSER are zero. RUSER and BUSER are ignored. A wrapper may omit USER or carry its own metadata without changing CPU semantics. AxQOS and AxREGION are zero. AXI exclusive transactions and ATOP extensions are not used.

Attribute encodings follow the [Arm AXI specification](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf).

## Completion, faults and ordering

Uncached reads and writes complete only on their R or B response. Backpressure has no fixed deadline. A request is presented once and is never retried automatically; holding a response does not repeat a device side effect. Device reads and uncached stores execute at the ROB head behind the existing interrupt/debug shield. Successful uncached store-conditionals also wait for B before retiring. Failed store-conditionals perform no write.

Misaligned loads, stores and atomics trap in the CPU before issuing an AXI
request, including before firmware installs `mtvec`. The standalone interface
does not split misaligned accesses into multiple transactions.

RRESP/BRESP SLVERR and DECERR propagate as access faults for data reads, uncached stores/AMOs, instruction fetch and page-table walks. Read-fill errors never install cache data or an executable fetch-buffer victim. Data-bus faults report zero in `xtval`; instruction and translation faults retain their existing virtual-address reporting. RISC-V permits zero `xtval` for these faults; a physical address must not be reported as though it were the faulting virtual address. See the [privileged architecture](https://docs.riscv.org/reference/isa/priv/machine.html).

Buffered cached stores may already have retired when a writeback or write-allocated refill fails. Such failures retain the dirty cache ownership, assert sticky `o_fatal_error`, record `o_fatal_addr`, and stop further CPU retirement and new side effects. They do not fabricate a precise exception for an instruction that has already retired. The wrapper must handle the fatal indication and eventually reset the CPU; automatic retries are not performed.

Fences cannot pass an uncached store waiting for B. The request router drains older committed stores before a device read. FENCE.I writes L1D back to the shared cache level, invalidates L1I and the fetch buffers, and discards old fetch responses before refetch. Ordinary FENCE orders accesses; it is not a flush of all dirty L2 data to external memory. Agents accessing cached memory must use the coherent ingress below. A noncoherent agent cannot assume that an ordinary fence makes private dirty data visible on AXI.

## Static address map and PMA configuration

The CPU map is a build configuration shared by all modules using `riscv_pkg`. Supply compiler definitions, or set `FROST_CPU_CONFIG` to a quoted header path containing the definitions. A wrapper does not edit CPU RTL to change these values.

| Definition | FROST default | Meaning |
| --- | --- | --- |
| `FROST_PMA_CACHED_BASE` | `0x80000000` | Cached Normal memory, executable and atomic-capable |
| `FROST_DDR_CAPACITY_LOG2_BYTES` | 30 | Size of that region, as a power of two |
| `FROST_PMA_UNCACHED_BASE` | 0 | Uncached Normal memory base |
| `FROST_PMA_UNCACHED_BYTES` | 262144 | Uncached data/atomic-capable size |
| `FROST_PMA_UNCACHED_EXEC_BYTES` | 131072 | Executable prefix of the uncached region |
| `FROST_PMA_DEVICE0_BASE` / `..._BYTES` | `0x40000000` / `0x31000` | First Device region |
| `FROST_PMA_DEVICE1_BASE` / `..._BYTES` | `0x44000000` / `0x400000` | Second Device region |
| `FROST_PMA_LEGACY_DEVICE_STORES` | 1 | Allow the legacy untranslated device-quadrant stores only with the FROST map; set 0 for strict configured regions |
| `FROST_CPU_DEBUG_BASE` | `0x17c00` | Debug execution slice, within executable memory below 4 GiB |

Regions use nonoverlapping, page-aligned half-open intervals; elaboration checks alignment, overflow and overlap. A zero size disables an uncached or Device region. The cached region always has its configured power-of-two size. The executable uncached prefix must fit within its data region. Physical width is derived from the highest region limit, with a minimum of 32 bits and a maximum of 56 bits. Device addresses may be above 4 GiB. There is one cached region and one uncached memory region in this implementation; it is not a runtime-programmable PMA table.

Only the exact default FROST map with `FROST_PMA_LEGACY_DEVICE_STORES=1` retains its legacy allowance for untranslated stores anywhere in `0x40000000..0x80000000`; FROST's SoC ignores writes to unimplemented registers there. Other maps, and builds setting this definition to 0, admit only their configured regions. The optimized FROST store-PMA decoder is bypassed for a different map. Devices permit loads/stores, prohibit instruction fetch and atomics, and bypass every cache including L0. Page tables must reside in the configured cached region; the walker coherently probes L1D and reads through L2.

The generic CPU has no knowledge of UART/FIFO/PLIC register offsets. The FROST SoC's register map and programming interface remain platform-specific. Changing the standalone CPU configuration does not automatically readdress FROST's peripherals or linker scripts.

## Interrupt and debug controls

`i_interrupts` is the packed `riscv_pkg::interrupt_t` value `{meip, mtip, msip}`. `i_seip` supplies supervisor external interrupt pending. These are synchronous level inputs; hold them until the interrupt source is serviced. CSR enables, delegation and privilege determine delivery. Reset clears the CPU's enables, not the external source. `i_mtime` supplies the synchronous 64-bit time value for the time CSR; the wrapper provides any timer and any required coherent clock crossing.

The Debug Module interface uses the core clock:

- `i_dbg_haltreq`: halt-request level; CPU entry is precise at the architectural boundary.
- `i_dbg_go` and `i_dbg_go_addr`: hold the request and 32-bit execution address until `o_dbg_go_taken` pulses. Go releases a parked hart to its debug code.
- `i_dbg_data`: stable 64-bit debug data input. `o_dbg_data_we` is a one-cycle write pulse with `o_dbg_data_wdata`.
- `o_debug_mode` is high throughout Debug Mode; `o_dbg_parked` is high there while no debug command runs. `o_dbg_cmd_err` latches a debug-command exception until the next accepted go or CPU reset. All three clear on CPU reset. Transport and Debug Module state belong outside the tile.

An integration without debug ties the input controls/data low and supplies ordinary executable memory at its boot address. The optional commit and IRQ-status outputs are passive observations, not execution-control handshakes.

## Optional coherent ingress

`ENABLE_COHERENCE=0` is the supported default for an independent CPU. All coherent inputs may be tied low. Regardless of those input values, request-ready, response-valid, response-error, response-ID and response-data remain zero; no inbound traffic enters the hierarchy.

With `ENABLE_COHERENCE=1`, `i_coherent_req_*` / `o_coherent_resp_*` expose the FROST 32-byte line protocol. This is a separate **incoming** interface, not another outgoing CPU memory master and not ACE/CHI. Requests carry full physical addresses, 256-bit data, 32 byte strobes, write/read selection and a 4-bit ID. Hold a request until valid/ready acceptance. Each accepted request produces one response pulse with the same ID, data and an error flag; there is no response-ready signal, so the agent must always be able to consume responses. With L2 prefetch enabled, agents must leave ID bit 3 clear. IDs cannot be reused while outstanding.

CPU reset cancels inbound coherence requests and responses. Reset or reinitialize each connected agent's outstanding-request ownership at the same time; pre-reset ingress requests are not guaranteed a response. Outgoing AXI transactions already presented still drain as described above.

Requests must be aligned to 32 bytes and remain within the configured cached memory region. An invalid address is not accepted and triggers a simulation assertion. Its sequencer probes dirty L1D lines, orders traffic at L2, and coordinates writes with the load queue and reservation/SC windows. FROST connects its NIC and DMA test engine through an arbiter in `soc_top`. External masters accessing cached memory must use this path; bypassing it on the external AXI fabric is noncoherent. AMOs use CPU serialization and this coherence protocol, not AXI exclusives. Uncached atomic memory must be private to the hart or protected by the integrating system from competing noncoherent masters.

## Legacy BRAM-only platform profile

`ENABLE_CACHED_TIER=1` is the supported standalone integration default.
FROST retains `ENABLE_CACHED_TIER=0` for its BRAM-only simulation profile;
that profile instantiates no hierarchy or coherent agents and must not execute
cached memory accesses or page-table walks. Cached data has its historical
zero-read/no-op-write stub in that profile. External integrations should keep
the cached tier enabled even if their boot code resides in uncached memory.

## Verification

Run tests in the pinned repository container:

```sh
./scripts/frost.py cocotb cpu_top_boundary
./scripts/frost.py cocotb cpu_top_custom_map
./scripts/frost.py cocotb cpu_top_strict_map
./scripts/frost.py cocotb soc_axi_slave
./scripts/frost.py cocotb ptw_errors
./scripts/frost.py cocotb cpu_axi_master
./scripts/frost.py cocotb cpu_uncached_adapter
./scripts/frost.py cocotb frost_cache_hierarchy_errors
./scripts/frost.py cocotb fetch_provider_errors
./scripts/frost.py cocotb tomasulo_wrapper_axi
./scripts/frost.py cocotb hello_world
```

The standalone bench executes real instructions while an external AXI model varies channel readiness and response latency. Unit benches separately exercise ownership, reset draining, held responses, cache faults, narrow strobes, and precise uncached store completion.
