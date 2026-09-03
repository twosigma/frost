# Cache library

The cached tier: a direct-mapped write-back line cache used three times (L1D,
L1I, L2), the tagged line protocol its ports speak, the arbiter that merges
line ports, the bridge to the DDR AXI port, and the simulation-only main
memory.

| File | Role |
|------|------|
| `cache_perf_pkg.sv` | Packed per-instance observer types: access/hit/miss/writeback and hit-under-miss pulses, the outstanding-miss count, and the two stall classes |
| `frost_cache.sv` | Direct-mapped, write-back, write-allocate, non-blocking line cache (one module for every level) |
| `frost_cache_hierarchy.sv` | Per-board hierarchy: L1D + walker port + L1I over a tree of 2:1 arbiters, optional URAM-data/URAM-tag L2, fence.i sequencing |
| `line_port_arbiter.sv` | N:1 tagged arbiter; fixed priority by port index, ids prefixed per port |
| `line_port_axi_bridge.sv` | Tagged line port to single-beat AXI4 master; line ids become AXI ids |
| `axi_behavioral_memory.sv` | Simulation-only AXI main memory: concurrent, latency/jitter knobs, optional out-of-order completion |
| `*_test_harness.sv` | cocotb unit-bench tops (hierarchy + bridge + memory; arbiter + bridge + memory) |

## Line protocol

Every port between the CPU-side adapters and the AXI bridge carries one
32-byte line per transaction with a transaction id:

```
request:  valid  ready  write  addr[ADDR_WIDTH]  wdata[256]  wstrb[32]  id[ID_BITS]  maintenance
response: valid  id[ID_BITS]  rdata[256]
```

A request fires on the cycle where `req_valid && req_ready`. The slave captures
the payload at the fire; until then the master holds `req_valid` and a stable
payload. `addr` is a full byte address, used line-aligned. A slave's ready may
depend on the presented request: the bridge, for instance, is ready for a read
while a write's channels are still busy.

`resp_valid` is a one-cycle pulse at least one cycle after the fire, carrying
the request's `id`. `rdata` is the line for reads and don't-care for writes; a
write's response is its completion acknowledgement. There is no response
backpressure: a master only issues what it can sink, so it always has a home
for a response.

A master may have any number of requests in flight, each with an id unique
among its own in-flight requests, and a slave may deliver responses in any
order. Requests to the same line take effect in acceptance order: a write
accepted before a read of that line is visible to the read, and a read
accepted before a write never sees it. The slave is the ordering point for its
level and never relies on the level below for read/write order.

Each arbiter prefixes its port index to the ids it forwards, so the bottom of
the hierarchy sees `{port bits…, local id}` and ids stay unique across every
upstream master without a global plan. Arbiters compose: a tree of them yields
a prefix-free id code whose per-master widths need not be uniform, which is
how the hierarchy fits the walker port. A second hart (Phase 5) is one more
port.

The `maintenance` bit is present on the cache and arbiter ports, not on the
hierarchy's upstream ports or the bridge. It is a passive observer
classification that marks fence.i writeback-all traffic so lower levels
exclude it from their ordinary-traffic counters; it never changes functional
handling.

Partial writes carry byte strobes. A write with all strobes set allocates
without a fetch, the common case for evictions from the level above.

`frost_cache` is non-blocking. A request is accepted into a skid and issues a
tag lookup; the request resolves when that lookup returns after the configured
`TAG_READ_LATENCY`, and its side effects land in a write stage. The one-cycle
L1 tag path streams read hits one per cycle; the delayed L2 tag path serializes
its single T owner. Read data returns with the data array's output. Write hits
and write misses are acknowledged once the cache has ordered them; a miss's
bytes are merged into its fill. Misses occupy `NUM_MSHR` miss-status slots that
fetch downstream concurrently while dirty victims drain from `NUM_WB` writeback
slots. A write to a line whose write-allocate slot is pending merges into it, a
read takes the slot's single waiter seat, and anything else aimed at an index
in transition waits and issues a fresh tag lookup before deciding again. A fill
of a line still sitting in a writeback slot waits for that writeback's
acknowledgement, so the cache never relies on the level below ordering a read
against a write. Its downstream ids are `{type, slot}` (0 = fill of a miss
slot, 1 = writeback slot).

Tag and data storage are selected independently. The L1D and L1I use
one-cycle BRAM tags and BRAM data. The X3 L2 keeps its data in URAM and packs
four logical tag entries into each 72-bit URAM row; its production tag-read
latency is three cycles. This removes the large L2 tag store from BRAM while
leaving the L1 hit path unchanged.

Maintenance (fence.i) starts only once every slot and pipeline stage is
empty. Writeback-all issues each tag lookup and waits for its response before
classifying the line, writes dirty lines back through the writeback slots,
and drains them before `o_maint_busy` falls. Invalidate-all clears the tag
store directly, so it does not depend on tag-read latency.

## Hierarchy shapes

```
Genesys2 (HAS_L2=0):  adapter -> L1D (BRAM) ----------\
                      walker ------------\             arbiter -> bridge -> DDR3 (MIG)
                                          arbiter ----/
                      fetch   -> L1I (BRAM) ---------/
X3       (HAS_L2=1):  adapter -> L1D (BRAM) ----------\
                      walker ------------\             arbiter -> L2 (URAM data + tags) -> bridge -> DDR4
                                          arbiter ----/
                      fetch   -> L1I (BRAM) ---------/
```

The arbiter tree is two 2:1 `line_port_arbiter` instances. Both are pure
combinational pass-throughs, so the pair behaves exactly like a 3:1
fixed-priority arbiter ordered L1D > walker > L1I: data misses stall committed
work, a walk unblocks a load that is stalling commit, and fetch runs ahead
through a buffer. There is no grant lock: a request flows whenever the
downstream is ready, so an L1I fill, a walk, and an L1D transaction can be in
flight together below the arbiters. Both board block designs give the CPU's
AXI master 4-bit ids (`fpga/build/*_ddr_bd.tcl`). The bridge drops any
response whose id is not in flight, which is how a transaction interrupted by
an image-load CPU reset drains harmlessly: the caches' reset tag sweeps last
thousands of cycles, so no new request can reach the bridge before a stale
response has returned.

## The page-table walker port

The hardware page-table walker (Phase 3) attaches as the hierarchy's third
upstream port (`wup`), between the L1D and the L1I in the arbiter tree, on
the same line protocol. The tree's fixed priority and no-grant-lock flow mean
a walk never waits for an L1I fill to complete once it is ready to issue. The
walker's requests carry `maintenance = 0` and are counted as ordinary traffic
by the level they reach.

The tree composes a prefix-free id code inside the same `UP_ID_BITS + 1`
downstream width the two-port shape used: the L1D keeps `{1'b0, UP_ID_BITS-bit
local id}`, the walker gets `{2'b10, local id}` and the L1I `{2'b11, local
id}` with `UP_ID_BITS - 1`-bit local ids. Nothing below the top arbiter
changes: the L2 (or the bridge on the L1-only shape) sees the same id width,
within the 4-bit AXI id space the block designs already provide. The narrower
prefix caps the L1I at 2 miss slots and the walker at 2 concurrent walks. The
L1I loses nothing, since its master, the two-line fetch provider, never has
more than 2 requests in flight.

A walk is a short chain of dependent 8-byte PTE reads, one per level, each a
full-line read on this port; the walker extracts its PTE from the 256-bit
response the way `cached_tier_adapter` extracts a beat. One walker serves both
TLBs behind a requester mux in `cpu_ooo`: the data side wins, and a registered
owner bit steers each response to the TLB that asked. One walk is in flight at
a time, so the port never carries more than one read at once; the 2-bit local
id budget is headroom. Walks are read-only: the A/D bits trap instead of
updating in hardware (Svade), so there is no PTE-write path anywhere in the
fabric.

PTEs live in cacheable memory and a walk reads through the L2 (X3) or DDR
(Genesys2), not through the L1D, so a store to a page table that is still
dirty in the L1D is not visible to a walk until the L1D writes it back. The
architectural `sfence.vma` is the point where software expects its page-table
stores to be visible. The Phase 3 implementation issues an L1D writeback-all
(the existing fence.i maintenance path) before invalidating the TLBs, which
drains every dirty line through the writeback slots before the next walk can
start.

## Benches

`verif/cocotb_tests/cache/test_frost_cache.py` drives tagged transactions on
all three upstream ports (data, instruction, walker) against a byte-granular
reference model (registry: `frost_cache*`, both shapes, fast-maintenance and
out-of-order-memory variants). `test_frost_cache_concurrency.py` keeps several
transactions in flight per port and checks the non-blocking paths: pipelined
hits, hit- and miss-under-miss, merges, waiters, index conflicts, a fill behind
a pending writeback, and fence.i under misses (`frost_cache_concurrency*`).
`test_line_port_arbiter.py` plays two masters with several tagged transactions
in flight each (`line_port_arbiter*`). `test_fence_speed.py` counts fence.i
maintenance cycles at the production L1 geometry under the slow and fast
maintenance paths (`fence_speed_slow`, `fence_speed_fast`; not in the pytest
sweep). `formal/line_port_axi_bridge.sby` proves the bridge's AXI handshake
legality, id conservation and stale-response drop.
