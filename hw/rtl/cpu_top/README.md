# CPU integration boundary

`cpu_top` contains the RV64 CPU pipeline, MMUs and page-table walker, L0/L1D/L1I/L2 caches, fetch buffers, coherence sequencing, machine and supervisor IMSIC files, and outgoing AXI master. It has one clock and no board memory, external interrupt controller, debug transport, DMA engine, NIC, or power controller. Compile `cpu_top.f` with `ROOT` set to the repository root. `platform_top` connects it to the FROST `soc_top`.

## Internal structure

`cpu_top` composes one `frost_hart` with one `frost_cluster_memory`.
The hart and shared memory communicate through coherent channels and the
uncached data and instruction ports.

| Module | Contents |
| --- | --- |
| `frost_hart` | `cpu_ooo` with its MMUs, walker, L0 and IMSIC files; the instruction fetch providers; `coherent_hart_cache` with the S/M L1D, L1I, walker bridge and FENCE.I sequencing; and `cpu_uncached_adapter` |
| `frost_cluster_memory` | The DMA ingress queue; `coherence_home` with independent completions, the L2 array and victim ownership; and `cpu_memory_fabric` with its AXI master |

The D/P/R/W/WA/G/C/U channels carry requests, probes, dirty data, grants
and completion ownership. Dirty data merges through L2. `cpu_top` latches
fatal indications and addresses from the hart, shared cache and uncached
adapter. It supplies cache performance events to the hart's counters.
`ENABLE_CACHED_TIER=0` omits the L1 and L2 caches and ties off their channels.

## Clock, reset and boot

All ports are synchronous to the rising edge of `i_clk`. There are no clock crossings in `cpu_top`; the integrating wrapper must synchronize external controls and interrupt levels and provide a coherent snapshot of multibit inputs.

- `i_rst` is the active-high synchronous CPU reset. Hold it for at least two clock edges. Keep the halfword-aligned `i_boot_addr` stable throughout reset; both fetch PCs sample it on reset edges. After release, cache initialization and normal fetch handshakes determine when execution starts. `o_rst_done` clears on reset and rises after 255 rising edges without CPU reset. It is a reset-duration indication; it does not gate execution or indicate fabric idle.
- `i_axi_rst` resets **both sides** of the AXI connection. Assert it together with `i_rst` during initial system reset, and whenever the fabric discards outstanding transactions. Keep `i_rst` asserted for every edge on which `i_axi_rst` is asserted; resetting the transport alone would strand requests still owned by the CPU memory system. It clears ownership and gates outgoing VALID and incoming READY low. Its release must be synchronous to `i_clk`.
- A CPU-only reset does not withdraw an already presented AXI request. The master completes outstanding AW/W/AR handshakes, drains R/B responses from the old CPU epoch, and blocks new requests until that debt is gone. The fabric must continue making progress. A previously accepted device access can still have its side effect during this drain.
- CPU reset invalidates caches and discards dirty lines in the writeback region. The Normal read-cache policy creates no dirty lines. Drain stores and write back cached data that must survive reset before asserting it; reset itself performs no cache writeback.
- CPU reset does not clear the integer or floating-point register files. Apart from hardwired `x0`, software must initialize register values before using them; integration must not assume zeroed GPRs after reset.
- `o_axi_idle` covers the master's queued requests, fabric transactions, buffered responses, and reset drain. It does not prove that all dirty cache lines have reached memory, and it is not a clock-gating permission by itself.

FROST's SoC combines external reset and the Debug Module's `ndmreset` for CPU reset. The Debug Module survives `ndmreset`. Its board and JTAG clock crossings belong to `soc_top` and `frost`.
With `ASYNC_CPU_CLOCK=1`, FROST runs the Debug Module and the core side of
its transport on the CPU clock. Debug data CSR reads and writes therefore
share the same clock. The SoC boundary carries memory and DMA AXI channels
through asynchronous FIFOs, interrupt levels through two-flop synchronizers,
and the writable timer through a snapshot handshake. The standalone CPU's
ports and reset-drain contract are independent of that option.

## Outgoing AXI4 master

The flat `o_axi_*` / `i_axi_*` ports are one AXI4 master. Addresses are full physical byte addresses; `cpu_top` never subtracts a platform base. Address width is `riscv_pkg::PhysAddrBits`. Data width is `8 * L2_LINE_BYTES` (default 512 bits; 256 bits with 32-byte L2 lines). `AXI_ID_BITS` defaults to 6; supported widths are 6 through 8 bits. AW and W handshake independently.

Every transaction has AxLEN=0, AxBURST=INCR, AxLOCK=0, and WLAST/RLAST=1. A wrapper must preserve AxADDR, AxSIZE, AxCACHE, AxPROT, WSTRB, IDs and RRESP/BRESP. Device data accesses and all non-writeback stores use their original byte address and size (1, 2, 4 or 8 bytes). Data and strobes occupy the addressed lanes of the wide bus. With the standalone default `CACHE_NORMAL_MEMORY=0`, uncached Normal data also retains its original size, and instruction fetch uses aligned 8-byte reads without next-block prefetch. The optional Normal read-cache policy is described below. Device memory is never fetched, prefetched, or line-filled.

| Traffic | AxCACHE | AxPROT[2] | Size |
| --- | --- | --- | --- |
| Shared writeback cache fills/writebacks | `1111` | 0 | One L2 line |
| Uncached Normal data | `0010` | 0 | Original access size |
| Device data | `0000` | 0 | Original access size |
| Uncached instruction memory | `0010` | 1 | 8 bytes |
| Optional Normal read-cache data fill | AR `1110` | 0 | Aligned 8 bytes |
| Optional Normal write-through store | AW `0110` | 0 | Original access size |
| Optional Normal instruction-cache fill | AR `1110` | 1 | Aligned 32 bytes |

The cache is a unified physical memory domain below its private levels: a downstream cache fill can serve instruction, data, walker, or coherent-agent requests. Its AXI transactions use the configured `AXI_MEMORY_PROT` (default `011`, privileged and Non-secure). This is the tile's bus security domain, **not** a reflection of the current RISC-V privilege mode. The CPU's MMUs enforce RISC-V permissions before cache access. An external security firewall must trust that domain; translating AxPROT into the hart's current privilege would mislabel outstanding walks and writebacks. Uncached instruction requests set bit 2 on that domain value.

| AXI ID | Owner |
| --- | --- |
| 0–31 | L2 fill/writeback ownership |
| 32 | Normal/Device data adapter, including optional write-through traffic |
| 34–35 | Two Normal instruction fetch slots |

ID 33 and IDs above 35 are unused. An ID stays owned until its CPU-side response is consumed. Different IDs may complete out of order; each response is matched to its owner. ID values do not select cacheability, device behavior, ordering or address routing.

Instruction-fetch IDs belong only to reads. Their ID, data and error status use the master's registered R payload directly. For an accepted owned R response, the fabric captures the word-lane selection with the R payload; this metadata holds with the buffered response. Shared R/B arbitration produces a read-publication flag before fetch-ID decoding. The fetch payload is consumed only when that arbitration publishes its ID.

The R-data payload write condition uses incoming RVALID and either buffer
vacancy or selected-read readiness. Captures during reset or for unowned
responses cannot set read validity. A buffered read holds its data under
backpressure.

An internal request register separates client arbitration from the master's ID and channel availability checks. It holds the complete address, attributes, ID, data and strobes under backpressure and permits simultaneous dequeue and replacement. CPU reset discards this request if it has not reached the master; already presented AXI traffic still drains. `o_axi_idle` includes this register.

On a successful response, the uncached adapter may enqueue its next waiting
request into that register on the same edge. The master releases the previous
ID's ownership before accepting the replacement. Read and write completions
are registered, and held read responses stay stable.

`AXI_USER_BITS` is a positive width, default 1. AWUSER, ARUSER and WUSER are zero. RUSER and BUSER are ignored. A wrapper may omit USER or carry its own metadata without changing CPU semantics. AxQOS and AxREGION are zero. AXI exclusive transactions and ATOP extensions are not used.

Attribute encodings follow the [Arm AXI specification](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf).

## Completion, faults and ordering

External reads and writes complete only on their R or B response. Backpressure has no fixed deadline. A request is presented once and is never retried automatically; holding a response does not repeat a device side effect. Device reads and precise uncached stores execute at the ROB head behind the interrupt/debug shield. Successful uncached store-conditionals and AMOs wait for B before retiring, including when Normal read caching is enabled. Failed store-conditionals perform no write. The optional policy allows ordinary Normal stores to retire into the store queue before B; the queue retains their ownership until the response.

Misaligned loads, stores and atomics trap in the CPU before issuing an AXI
request, including before firmware installs `mtvec`. The standalone interface
does not split misaligned accesses into multiple transactions.

RRESP/BRESP SLVERR and DECERR propagate as access faults for data reads,
precise uncached stores/AMOs, instruction fetch and page-table walks.
Read-fill errors never install cache data or executable instruction-cache
entries. Coherent cached SC access faults report the saved virtual address
in `xtval`. Other data-bus faults report zero. Instruction and translation
faults report the virtual address. RISC-V permits zero `xtval` for these
faults; a physical address must not be reported as though it were the
faulting virtual address. See the
[privileged architecture](https://docs.riscv.org/reference/isa/priv/machine.html).

Buffered cached stores may already have retired when a writeback or write-allocated refill fails. Such failures retain the dirty cache ownership, assert sticky `o_fatal_error`, record `o_fatal_addr`, and stop further CPU retirement and new side effects. They do not fabricate a precise exception for an instruction that has already retired. The wrapper must handle the fatal indication and eventually reset the CPU; automatic retries are not performed.

The same fatal contract applies to a failed B response for an already-retired Normal write-through store. Its adapter ownership is retained, later requests are blocked, and fences cannot complete past the failure. SC/AMO and Device writes remain precise and do not use this buffered-store error path. Retirement and new memory requests are blocked immediately; the internal execution hold is registered one cycle later, and any intervening execution result cannot retire.

Fences cannot pass an uncached store waiting for B. The request router drains older committed stores before a device read. FENCE.I writes L1D back to the shared cache level, invalidates L1I and the fetch buffers, and discards old fetch responses before refetch. Ordinary FENCE orders accesses; it is not a flush of all dirty L2 data to external memory. Agents accessing cached memory must use the coherent ingress below. A noncoherent agent cannot assume that an ordinary fence makes private dirty data visible on AXI.

## Optional Normal read caching and write-through stores

`CACHE_NORMAL_MEMORY=0` is the standalone default. FROST's `platform_top` and `frost` enable it by default to avoid paying an AXI round trip for every BRAM instruction and repeated data load. It applies only to the configured Normal region named by `FROST_PMA_UNCACHED_BASE` / `..._BYTES`; it does not reclassify Device regions or route BRAM through the DDR writeback caches.

With this option, data reads outside the configured debug slice's 4 KiB page fetch an aligned dword into L0. `L0_CACHE_DEPTH` defaults to 256 entries (2 KiB) with this option and 128 entries otherwise; an explicit override selects either profile's capacity. Ordinary stores remain narrow write-through transactions. They update matching L0 bytes; a full-dword store can allocate an entry, but a partial store cannot allocate unknown bytes. A read that overlaps a newer store may complete to its original load but cannot reinstall stale L0 data. Debug-page data accesses bypass this cache and remain precise.

Executable Normal memory uses a direct-mapped instruction cache with `NORMAL_FETCH_LINES` 32-byte lines (default 256 lines, or 8 KiB). Two fill slots serve instruction windows and permitted next-line prefetches. The prefetch address must remain executable under the configured PMA. Branches retain these entries; FENCE.I, CPU reset, and debug GO requests invalidate them and discard old fills.

With Normal instruction caching enabled, `debug_fetch_barrier` captures each debug GO target and issues a registered invalidation pulse before releasing GO to the CPU. The requester makes debug instruction writes visible before asserting GO and holds the request until the CPU acknowledges it. Withdrawal cancels a pending GO; its invalidation may already have occurred. A held request cannot replay after acknowledgement and must drop for a clock edge before another request. CPU reset clears the barrier. The uncached profile connects GO directly to the CPU.

Direct-cache tag comparisons use the line bits above the entry index. A valid entry's low line bits equal that index because each fill writes the entry selected by its own line address. Error records compare their complete line identities.

Each direct-cache word uses local busy and discard copies to qualify its data and predecode write; the tag uses a separate copy. These registers take the fill engine's next state on the same edge as the engine. Reset, invalidation, discarded responses and failed responses suppress every payload write, including writes to invalid entries.

Data and predecode are stored in one bank per word position within a line. The two words of a fetch window have opposite parity, so each bank reads the line index of the word with matching parity. This also applies to windows crossing a line or translated page boundary. Each bank has one asynchronous read address, and a fill writes every bank on the same edge.

Use this option only for memory private to the CPU or externally coordinated with it. The FROST coherent ingress covers the separate writeback region, not these Normal read caches. External data writes require CPU reset before cached data is reused; executable-memory changes require FENCE.I or reset before execution. FROST's programming flow holds the CPU in reset while replacing BRAM contents.

This policy creates no dirty BRAM cache lines. FENCE waits for buffered Normal stores' B responses. FROST's BRAM slave responds only after the RAM write, so a successful fence leaves those BRAM bytes updated. An external AXI fabric may acknowledge write-through traffic at an intermediate buffer; it must preserve ordering with subsequent accesses and drain those buffers before resetting or powering down that fabric. B completion alone does not prove final-memory visibility in such a fabric. Reset can still discard unissued store-buffer entries; software must drain writes whose persistence it requires before requesting CPU reset. Already presented AXI writes drain across CPU-only reset as specified above.

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
| `FROST_PMA_DEVICE2_BASE` / `..._BYTES` | `0x48000000` / `0x200000` | Third Device region |
| `FROST_PMA_LEGACY_DEVICE_STORES` | 1 | Allow the legacy untranslated device-quadrant stores only with the FROST map; set 0 for strict configured regions |
| `FROST_CPU_DEBUG_BASE` | `0x17c00` | Debug execution slice; when debug is used, place it in executable memory below 4 GiB |

Regions use nonoverlapping, page-aligned half-open intervals; elaboration checks alignment, overflow and overlap. A zero size disables an uncached or Device region. The cached region always has its configured power-of-two size. The executable uncached prefix must fit within its data region. Physical width is derived from the highest region limit, with a minimum of 32 bits and a maximum of 56 bits. Device addresses may be above 4 GiB. There is one cached region and one uncached memory region in this implementation; it is not a runtime-programmable PMA table.

Only the exact default FROST map with `FROST_PMA_LEGACY_DEVICE_STORES=1` allows untranslated stores anywhere in `0x40000000..0x80000000`; FROST's SoC ignores writes to unimplemented registers there. Other maps, and builds setting this definition to 0, admit only their configured regions. The optimized FROST store-PMA decoder is bypassed for a different map. Devices permit loads/stores, prohibit instruction fetch and atomics, and bypass every cache including L0. Page tables must reside in the configured cached region; the walker coherently probes L1D and reads through L2.

The generic CPU has no knowledge of UART/FIFO/APLIC register offsets. The FROST SoC's register map and programming interface are platform-specific. Changing the standalone CPU configuration does not automatically readdress FROST's peripherals or linker scripts.

## Interrupt and debug controls

`i_interrupts` is the packed `riscv_pkg::interrupt_t` value `{meip, mtip, msip}`. `i_interrupts.meip` and `i_seip` supply the machine and supervisor APLIC direct lines to the local IMSIC files. These are synchronous level inputs; hold them until the interrupt source is serviced. CSR enables, delegation and privilege determine delivery. Reset clears the CPU's enables, not the external source. `i_mtime` supplies the synchronous 64-bit time value for the time CSR; the wrapper provides any timer and any required coherent clock crossing.

Each hart owns two 63-identity IMSIC files beside `csr_file` in `cpu_ooo`.
`i_msi_valid`, `i_msi_level` and `i_msi_id[10:0]` accept one MSI on each edge,
with level zero for machine and one for supervisor. There is no backpressure.
The ingress registers a one-hot identity per file before updating pending
state. The files register their output lines into the CPU's interrupt inputs.
Reset clears pending and enabled identities and selects APLIC direct delivery
with `eidelivery = 0x40000000` at both levels.

The hart implements `miselect`, `mireg`, `mtopei`, `mtopi`, `mvien`, `mvip`,
`siselect`, `sireg`, `stopei` and `stopi`. Select registers retain values up to
`0x1ff` and map larger writes to `0x1ff`. Their implemented register decodes
are flops written with the selects. Major priorities and `mvien` read zero.
`mtopi` reports the highest pending, enabled, undelegated major interrupt in
MEI, MSI, MTI, SEI, SSI, STI order. `stopi` reports delegated SEI, SSI, STI in
that order. Both report priority 1 and ignore global interrupt enables.
`mvip` exposes the software SSIP and SEIP bits and the software STIP bit while
STCE is clear. A `*topei` write claims its reported identity; a pure read has
no side effect. The [IMSIC guide](../peripherals/imsic/README.md) gives the
indirect register map and simultaneous-event rules.

The Debug Module interface uses the core clock:

- `i_dbg_haltreq`: halt-request level; CPU entry is precise at the architectural boundary.
- `i_dbg_go` and `i_dbg_go_addr`: hold the request and 32-bit execution address until `o_dbg_go_taken` pulses. Go releases a parked hart to its debug code.
- `i_dbg_data`: stable 64-bit debug data input. `o_dbg_data_we` is a one-cycle write pulse with `o_dbg_data_wdata`.
- `o_debug_mode` is high throughout Debug Mode; `o_dbg_parked` is high there while no debug command runs. `o_dbg_cmd_err` latches a debug-command exception until the next accepted go or CPU reset. All three clear on CPU reset. Transport and Debug Module state belong outside the tile.

An integration without debug ties the input controls/data low and supplies ordinary executable memory at its boot address. The optional commit and IRQ-status outputs are passive observations, not execution-control handshakes.

## Optional coherent ingress

`ENABLE_COHERENCE=0` is the supported default for an independent CPU. All coherent inputs may be tied low. Regardless of those input values, request-ready, response-valid, response-error, response-ID and response-data remain zero; no inbound traffic enters the hierarchy.

With `ENABLE_COHERENCE=1`, `i_coherent_req_*` / `o_coherent_resp_*` expose the FROST 32-byte line protocol. This is a separate **incoming** interface, not another outgoing CPU memory master and not ACE/CHI. Requests carry full physical addresses, 256-bit data, 32 byte strobes, write/read selection and a 4-bit ID. Hold a request until valid/ready acceptance. Each accepted request produces one response pulse with the same ID, data and an error flag; there is no response-ready signal, so the agent must always be able to consume responses. IDs cannot be reused while outstanding.

The ingress holds four accepted requests, including the request executing at
the home. It preserves all four ID bits and services requests in acceptance
order. Each response follows the home's completion release. An ID remains
occupied through its external response edge. The queue holds payloads through
backpressure and permits admission while another request executes.

CPU reset clears the ingress queue and cancels inbound requests and responses.
The AXI bridge, mux and both connected masters reset with that ownership.
Requests accepted before reset are not guaranteed a response. Outgoing AXI
transactions already presented drain as described above.

Requests must be aligned to 32 bytes and remain within the configured cached memory region. An invalid address is not accepted and triggers a simulation assertion. Its sequencer probes dirty L1D lines, orders traffic at L2, and coordinates writes with the load queue and reservation/SC windows. FROST connects its NIC and DMA test engine, both AXI4 masters, through `axi_mux` and `axi_coherent_bridge` in `soc_top` ([AXI library](../lib/axi/README.md)). External masters accessing cached memory must use this path; bypassing it on the external AXI fabric is noncoherent. AMOs use CPU serialization and this coherence protocol, not AXI exclusives. Uncached atomic memory must be private to the hart or protected by the integrating system from competing noncoherent masters.

L2 is inside this single-hart `cpu_top`. The outgoing AXI master does not
provide coherence between separate CPU instances.

`frost_hart` contains `coherent_hart_cache`, and `frost_cluster_memory`
contains `coherence_home`. The [cache interface](../lib/cache/README.md#coherent-one-hart-cache-path)
uses S/M permissions for one hart. The home admits nineteen requests and
executes them through one array/probe worker. Eight result credits separate
execution from grant delivery. Identities and way pins last through Release.
There is no E permission or second hart. `ENABLE_COHERENCE` controls DMA
ingress. `ENABLE_CACHED_TIER=0` omits the cache hierarchy.

Reset and fatal handling cover the whole cluster. Debug halt and WFI leave
cache, probe and completion service running.

## BRAM-only profile

`ENABLE_CACHED_TIER=1` is the default. FROST's BRAM-only simulation profile
sets `ENABLE_CACHED_TIER=0`, which builds no L1 or L2 cache and no coherent
agents. That profile must not execute cached memory accesses or page-table
walks; its cached data reads return zero and its cached writes do nothing.
External integrations should keep the cached tier enabled even if their boot
code resides in uncached memory.

## Verification

Run tests in the pinned repository container:

```sh
./scripts/frost.py cocotb cpu_top_boundary
./scripts/frost.py cocotb cpu_top_custom_map
./scripts/frost.py cocotb cpu_top_strict_map
./scripts/frost.py cocotb cpu_top_writethrough
./scripts/frost.py cocotb cpu_top_writethrough_custom_map
./scripts/frost.py cocotb cpu_writethrough_adapter
./scripts/frost.py cocotb load_queue_writethrough
./scripts/frost.py cocotb fetch_provider_direct
./scripts/frost.py cocotb soc_axi_slave
./scripts/frost.py cocotb ptw_errors
./scripts/frost.py cocotb cpu_axi_master
./scripts/frost.py cocotb cpu_memory_fabric
./scripts/frost.py cocotb cpu_uncached_adapter
./scripts/frost.py cocotb frost_cache_hierarchy_errors
./scripts/frost.py cocotb fetch_provider_errors
./scripts/frost.py cocotb fetch_provider_uncached
./scripts/frost.py cocotb tomasulo_wrapper_axi
./scripts/frost.py cocotb hello_world
```

The standalone bench executes real instructions while an external AXI model varies channel readiness and response latency. It checks every aligned byte, halfword, word and dword lane for uncached Normal memory and Device traffic, including retained RAM across reset and exact AXI sizes/attributes. Unit benches separately exercise ownership, reset draining, held responses, cache faults, narrow strobes, and precise uncached store completion. Fetch tests cover replay handoff between cached and uncached memory, including delivery of an instruction-page fault without issuing a memory read.

| Interface requirement | Directed coverage |
| --- | --- |
| Cached traffic and uncached instruction fetch | `cpu_top_boundary` boots real code and exercises the cache; `fetch_provider_uncached` checks memory-tier handoff and page faults |
| Narrow MMIO and side-effecting reads | `cpu_top_boundary` and `cpu_uncached_adapter` check all aligned sizes/lanes, exact attributes/strobes, and one side effect per accepted access |
| Backpressure and response ownership | `cpu_axi_master` and `cpu_memory_fabric` stall channels, reorder responses, and check stable payloads and IDs |
| AXI errors | `cpu_top_boundary` checks precise instruction/data/device faults and a fatal buffered-store failure; `ptw_errors` checks walker failures |
| Ordering and fences | `cpu_top_boundary`, `data_mem_request_router_axi`, and `tomasulo_wrapper_axi` check store draining, delayed B responses, and store-conditional completion |
| Interrupts | `cpu_top_boundary` asserts an interrupt during side-effecting reads and writes and checks that it waits for completion without replaying the access |
| Reset and boot address | `cpu_top_boundary`, `cpu_axi_master`, and `cpu_memory_fabric` distinguish queued cancellation from draining presented transactions, check retained external RAM, and boot at a new address |
| Disabled DMA ingress | `cpu_top_boundary` checks that the disabled ingress remains inactive while outgoing traffic runs |
| Configurable PMA | `cpu_top_custom_map` and `cpu_top_strict_map` check relocated regions and rejection outside the configured device windows |
| Optional Normal read caching | `cpu_top_writethrough` repeats the standalone boundary cases and checks FENCE.I, read faults, precise SC/AMO errors, and fatal buffered writes; `cpu_top_writethrough_custom_map` relocates the regions above 4 GiB |
| Read-cache coherence and fills | `load_queue_writethrough` prevents stale responses from replacing newer store data; `lq_l0_cache_128` / `256` check byte updates and invalidation priority; `fetch_provider_direct` checks hits, conflicts, straddles, late fills and executable-region limits |

The full-platform `debug_openocd_test` additionally checks halt, resume,
single-step, breakpoints, register/memory access, privilege, and reset through
the external Debug Module and transport. Set `FROST_REQUIRE_OPENOCD=1` when
running it to require the OpenOCD and GDB sessions. GDB checks register and
memory access, software breakpoints, and single stepping.
