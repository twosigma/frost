# Cache library

The cached tier: a direct-mapped write-back line cache used three times (L1D,
L1I, L2), the tagged line protocol its ports speak, the arbiter that merges
line ports, the bridge to the DDR AXI port, and the simulation-only main
memory.

| File | Role |
|------|------|
| `cache_perf_pkg.sv` | Packed per-instance observer types (access/hit/miss/writeback pulses and the outstanding-miss count) |
| `frost_cache.sv` | Direct-mapped, write-back, write-allocate, non-blocking line cache (one module for every level) |
| `frost_cache_hierarchy.sv` | Per-board hierarchy: L1D + walker port + L1I over a tree of 2:1 arbiters, optional URAM L2, fence.i sequencing |
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

- **Fire.** `req_valid && req_ready` in a cycle. The slave captures the
  payload at the fire; the master holds `req_valid` and a stable payload
  until then. `addr` is a full byte address, used line-aligned. A slave's
  ready may depend on the presented request (the bridge, for instance, is
  ready for a read while a write's channels are still busy).
- **Response.** `resp_valid` is a one-cycle pulse at least one cycle after
  the fire, carrying the request's `id`; `rdata` is the line for reads and
  don't-care for writes (a write's response is its completion
  acknowledgement). There is no response backpressure: a master only issues
  what it can sink, so it always has a home for a response.
- **Outstanding transactions.** A master may have any number of requests in
  flight, each with an id unique among its own in-flight requests. A slave
  may deliver responses in any order. Requests to the *same* line take
  effect in acceptance order: a write accepted before a read of that line is
  visible to the read, and a read accepted before a write never sees it —
  the slave is the ordering point for its level and never relies on the
  level below for read/write order.
- **Id composition.** Each arbiter prefixes its port index to the ids it
  forwards, so the bottom of the hierarchy sees `{port bits…, local id}` and
  ids stay unique across every upstream master without a global plan.
  Arbiters compose: a tree of them yields a prefix-free id code whose
  per-master widths need not be uniform (the hierarchy uses exactly this
  for the walker port). A second hart (Phase 5) is one more port.
- **Maintenance provenance.** The `maintenance` bit is a passive observer
  classification (fence.i writeback-all traffic) that travels with each
  request so lower levels exclude it from their ordinary-traffic counters;
  it never changes functional handling.
- **Partial writes** carry byte strobes; a write with all strobes set
  allocates without a fetch (the common case for evictions from the level
  above).

`frost_cache` is non-blocking: a request is accepted into a skid, resolved
in a tag stage one cycle later, and its side effects land in a write stage
the cycle after that. Read hits stream one per cycle and return with the
data array's output; write hits and write misses are acknowledged once the
cache has ordered them (a miss's bytes are merged into its fill); misses
occupy `NUM_MSHR` miss-status slots that fetch downstream concurrently while
dirty victims drain from `NUM_WB` writeback slots. A write to a line whose
write-allocate slot is pending merges into it, a read takes the slot's
single waiter seat, and anything else aimed at an index in transition waits
(re-reading its tag before deciding again). A fill of a line still sitting
in a writeback slot waits for that writeback's acknowledgement, so the cache
never relies on the level below ordering a read against a write. Its
downstream ids are `{type, slot}` (0 = fill of a miss slot, 1 = writeback
slot). Maintenance (fence.i) starts only once every slot and stage is empty,
writes dirty lines back through the writeback slots, and drains them before
`o_maint_busy` falls.

## Hierarchy shapes

```
Genesys2 (HAS_L2=0):  adapter -> L1D (BRAM) ----------\
                      walker ------------\             arbiter -> bridge -> DDR3 (MIG)
                                          arbiter ----/
                      fetch   -> L1I (BRAM) ---------/
X3       (HAS_L2=1):  adapter -> L1D (BRAM) ----------\
                      walker ------------\             arbiter -> L2 (URAM) -> bridge -> DDR4
                                          arbiter ----/
                      fetch   -> L1I (BRAM) ---------/
```

The arbiter tree is two 2:1 `line_port_arbiter` instances; both are pure
combinational pass-throughs, so the pair behaves exactly like a 3:1
fixed-priority arbiter ordered L1D > walker > L1I (data misses stall
committed work; a walk unblocks a load that is stalling commit; fetch runs
ahead through a buffer). There is no grant lock: a request flows whenever
the downstream is ready, so an L1I fill, a walk, and an L1D transaction can
be in flight together below the arbiters. Both board block designs give
the CPU's AXI master 4-bit ids (`fpga/build/*_ddr_bd.tcl`); the bridge drops
any response whose id is not in flight, which is how a transaction
interrupted by an image-load CPU reset drains harmlessly — the caches' reset
tag sweeps last thousands of cycles, so no new request can reach the bridge
before a stale response has returned.

## The page-table walker port

The hardware page-table walker (Phase 3) attaches as the hierarchy's third
upstream port (`wup`), between the L1D and the L1I in the arbiter tree, on
the same line protocol:

- **Port and ids.** The tree composes a prefix-free id code inside the same
  `UP_ID_BITS + 1` downstream width the two-port shape used: the L1D keeps
  `{1'b0, UP_ID_BITS-bit local id}`, the walker gets `{2'b10, local id}`
  and the L1I `{2'b11, local id}` with `UP_ID_BITS - 1`-bit local ids.
  Nothing below the top arbiter changes: the L2 (or the bridge on the
  L1-only shape) sees the same id width, within the 4-bit AXI id space the
  block designs already provide. The narrower prefix caps the L1I at 2
  miss slots — its master, the two-line fetch provider, never has more
  than 2 requests in flight — and the walker at 2 concurrent walks.
- **Traffic.** A walk is a short chain of dependent 8-byte PTE reads, one
  per level, each a full-line read on this port (the walker extracts its
  PTE from the 256-bit response like `cached_tier_adapter` extracts a beat).
  The walker keeps one walk in flight per outstanding translation miss; the
  DTLB and ITLB misses of one hart are therefore at most two walks, and the
  walker may pipeline the two with distinct ids. Walks are read-only: the
  A/D bits trap instead of updating in hardware (Svade), so there is no
  PTE-write path anywhere in the fabric.
- **Coherence with stores.** PTEs live in cacheable memory and a walk reads
  through the L2 (X3) or DDR (Genesys2) — *not* through the L1D — so a
  store to a page table that is still dirty in the L1D is not visible to a
  walk until the L1D writes it back. The architectural `sfence.vma` is the
  point where software expects its page-table stores to be visible; the
  Phase 3 implementation issues an L1D writeback-all (the existing fence.i
  maintenance path) before invalidating the TLBs, which drains every dirty
  line through the writeback slots before the next walk can start.
- **Priority.** The tree's fixed priority puts the walker below the L1D
  and above the L1I, with the same no-grant-lock flow, so a walk never
  waits for an L1I fill to complete once it is ready to issue.
- **Counters.** The walker's requests carry `maintenance = 0` and are
  counted as ordinary traffic by the level they reach.

## Benches

`verif/cocotb_tests/cache/test_frost_cache.py` drives tagged transactions on
all three upstream ports (data, instruction, walker) against a byte-granular
reference model (registry: `frost_cache*`, both shapes, fast-maintenance and
out-of-order-memory variants). `test_line_port_arbiter.py` plays two masters with several
tagged transactions in flight each (`line_port_arbiter*`).
`formal/line_port_axi_bridge.sby` proves the bridge's AXI handshake
legality, id conservation and stale-response drop.
