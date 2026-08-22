# Cache library

The cached tier: a direct-mapped write-back line cache used three times (L1D,
L1I, L2), the tagged line protocol its ports speak, the arbiter that merges
line ports, the bridge to the DDR AXI port, and the simulation-only main
memory.

| File | Role |
|------|------|
| `cache_perf_pkg.sv` | Packed per-instance observer types (access/hit/miss/writeback pulses and the outstanding-miss count) |
| `frost_cache.sv` | Direct-mapped, write-back, write-allocate, non-blocking line cache (one module for every level) |
| `frost_cache_hierarchy.sv` | Per-board hierarchy: L1D + L1I over a 2:1 arbiter, optional URAM L2, fence.i sequencing |
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
  ids stay unique across every upstream master without a global plan. A
  page-table walker (Phase 3) or a second hart (Phase 5) is one more port.
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
Genesys2 (HAS_L2=0):  adapter -> L1D (BRAM) -\
                                               arbiter -> bridge -> DDR3 (MIG)
                      fetch   -> L1I (BRAM) -/
X3       (HAS_L2=1):  adapter -> L1D (BRAM) -\
                                               arbiter -> L2 (URAM) -> bridge -> DDR4
                      fetch   -> L1I (BRAM) -/
```

The arbiter gives the data side fixed priority (its misses stall committed
work; fetch runs ahead through a buffer). There is no grant lock: a request
flows whenever the downstream is ready, so an L1I fill and an L1D transaction
can be in flight together below the arbiter. Both board block designs give
the CPU's AXI master 4-bit ids (`fpga/build/*_ddr_bd.tcl`); the bridge drops
any response whose id is not in flight, which is how a transaction
interrupted by an image-load CPU reset drains harmlessly — the caches' reset
tag sweeps last thousands of cycles, so no new request can reach the bridge
before a stale response has returned.

## Benches

`verif/cocotb_tests/cache/test_frost_cache.py` drives tagged transactions on
both upstream ports against a byte-granular reference model (registry:
`frost_cache*`, both shapes, fast-maintenance and out-of-order-memory
variants). `test_line_port_arbiter.py` plays two masters with several
tagged transactions in flight each (`line_port_arbiter*`).
`formal/line_port_axi_bridge.sby` proves the bridge's AXI handshake
legality, id conservation and stale-response drop.
