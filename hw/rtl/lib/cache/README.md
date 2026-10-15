# Cache library

This is FROST's cached memory tier: one direct-mapped, write-back,
non-blocking line cache used three times (L1D, L1I, and L2), the arbiters
that merge line ports, two sequencers that make DMA and page-table walks
coherent with the L1D, an adapter between the L1s' 32-byte lines and the
L2's 64-byte lines, the bridge to the DDR controller's AXI port, and a
simulation-only DDR model. Every block speaks one tagged line protocol, so
levels stack freely and each level can have several transactions in flight.
Coherence is handled in hardware: DMA and page-table walks see data that is
still dirty in the L1D, and software never flushes a cache for them.

| File | Role |
|------|------|
| `frost_cache.sv` | The line cache, used at every level; the L1D instance also takes per-line coherence probes |
| `frost_cache_hierarchy.sv` | L1D, walker, L1I, and DMA ports over the arbiter tree, the two coherence sequencers sharing one probe path into the L1D, the L2, and `fence.i` sequencing |
| `line_size_adapter.sv` | Places each L1-line request in its sector of a wider L2 line and returns that sector of the response; an outstanding-transaction table holds each request's sector by id |
| `line_port_arbiter.sv` | N:1 tagged arbiter: fixed priority by port index, optional starvation bound, port index prefixed to ids |
| `dma_coherence_sequencer.sv` | Takes each DMA request through the L1D, and each DMA write through the load queue as well, before it reaches the L2 |
| `walker_coherence_sequencer.sv` | Probes the L1D before each page-table walk read reaches the L2; one read in flight |
| `line_port_axi_bridge.sv` | Line port to single-beat AXI4 master; line ids become AXI ids |
| `axi_behavioral_memory.sv` | Simulation-only DDR model: concurrent transactions, latency and jitter settings, optional out-of-order completion |
| `cache_perf_pkg.sv` | Per-cache performance events: access, hit, miss, and writeback pulses, hit-under-miss, the outstanding-miss count, and two stall classes |
| `*_test_harness.sv` | cocotb tops: hierarchy + bridge + memory (with a bench-paced hold on the bridge), and arbiter + bridge + memory |

## Line protocol

Every port between the CPU-side adapters and the AXI bridge carries one line
per transaction, with a transaction id. Lines are 32 bytes from the
CPU-side adapters down to the line-size adapter and 64 bytes from there to
the bridge (`LINE_BYTES` below):

```
request:  valid  ready  write  addr[ADDR_WIDTH]  wdata[8*LINE_BYTES]  wstrb[LINE_BYTES]  id[ID_BITS]  maintenance
response: valid  id[ID_BITS]  rdata[8*LINE_BYTES]
```

- A request fires on a cycle with `req_valid && req_ready`, and the slave
  captures the payload then. Slaves act only on the fire, so a master may
  change or withdraw a request that has not fired. `addr` is a full byte
  address, used line-aligned.
- A slave's ready may depend on the presented request. The bridge, for
  example, accepts a read while a write's channels are still busy.
- `resp_valid` is a one-cycle pulse at least one cycle after the fire,
  carrying the request's id. `rdata` is the line for a read and don't-care
  for a write; a write's response is its completion acknowledgement.
- There is no response backpressure. A master issues only what it can sink,
  so every response has somewhere to go.
- A master may have any number of requests in flight, each with an id unique
  among its own in-flight requests. A slave may respond in any order.
- A cache applies requests to the same line in acceptance order: a write
  accepted before a read of the line is visible to the read, and a read
  accepted before a write never sees it. Each cache is the ordering point for
  its level and never relies on the level below to order a read against a
  write. The AXI bridge gives no such order (it can issue a read while an
  earlier write still waits), so same-line ordering is the hierarchy's job.
- Writes carry byte strobes. A write that sets every strobe of the cache's
  line allocates without fetching it. In the hierarchy no write does: an
  L1D eviction covers half an L2 line, so an L2 that lacks the line fetches
  it and merges the written half (see The L2 line size). Such a write would
  install even while a probe withholds the line's fills (see Probes), so a
  cache with `NUM_PROBE > 0` must not receive one on its upstream port. In
  the hierarchy that is the L1D, whose writes come from `cached_tier_adapter`
  and cover at most one 8-byte beat.
- `maintenance` exists on cache and arbiter ports, not on the hierarchy's
  upstream ports or the bridge. It marks `fence.i` writeback traffic, which
  lower levels leave out of every performance event. It never changes how a
  request is handled.

Masters do use this freedom: the arbiters re-select among their ports every
cycle, and the walker withdraws a read when its walk is discarded. A new slave
must take no action on a request until it fires.

## The line cache

`frost_cache` is one module for every level. The instances differ in size,
line size, storage, and slot counts:

| Instance | Size | Line | Tags | Data | Miss slots | Writeback slots | Probe slots |
|----------|------|------|------|------|------------|-----------------|-------------|
| L1D | 128 KiB | 32 B | Block RAM, 1-cycle read | Block RAM | 4 | 2 | 4 |
| L1I | 16 KiB | 32 B | Block RAM, 1-cycle read | Block RAM | 2 | 2 (unused) | 0 |
| L2 | 2 MiB | 64 B | UltraRAM, four entries per 72-bit row, 3-cycle read | UltraRAM | 4 | 2 | 0 |

The L2's slot counts are the hierarchy's `L2_NUM_MSHR` and `L2_NUM_WB`
parameters. Its downstream ids, `L2_DOWN_ID_BITS` wide (5 on the X3), hold up
to 16 slots of each type.

### Requests and misses

A request enters a one-entry skid and reads its tag. It is decided when the
tag returns (`TAG_READ_LATENCY` cycles), and its side effects land in a write
stage the next cycle.

- A read hit returns data with the data array's output. The L1s' one-cycle
  tags stream one hit per cycle; the L2's delayed tags decide one request at
  a time.
- A write hit writes the strobed bytes and marks the line dirty.
- A miss takes one of `NUM_MSHR` miss-status slots, and the slots fetch from
  the level below concurrently. A dirty victim moves into one of `NUM_WB`
  writeback slots and drains independently.
- A write miss merges its bytes into the fill: the fill supplies only the
  bytes no store has written, including a store that merges in the same
  cycle the fill arrives.
- A write to a line whose write-allocate slot is pending merges into that
  slot, and a read of a line with a pending miss takes the slot's single
  waiter seat. Anything else aimed at an index in transition waits and reads
  its tag again before deciding.

Writes, hits and misses alike, are acknowledged once the cache has ordered
them, so a store miss does not wait for its fill. Hits proceed past pending
misses. Downstream ids are `{type, slot}`: type 0 is the fill of a miss slot,
type 1 a writeback slot.

### Writebacks

A line that still sits in a writeback slot is not fetched or installed again
until that writeback is acknowledged:

- A fill of the line waits before fetching, so the cache never relies on the
  level below to order a read against a write.
- A whole-line write that allocates without a fetch waits before
  installing.
- A store to a copy that a probe left valid and clean waits before dirtying
  it again.

No line therefore ever has two writebacks in flight. The level below, or an
AXI fabric, could apply two writebacks of one line in either order and leave
the older data in memory.

These waits need writebacks to make progress. The downstream request
register takes a pending fill before a pending writeback, because a stalled
load or store is waiting on the fill. Preference alone can starve a
writeback: if the level below accepts slowly, fills that complete and
reallocate between its acceptances keep a fill pending at every load of the
register. So a writeback that has lost `WbStarveLimit` (3) loads to fills
takes the next one, and the writeback slots take turns. A pending writeback
is loaded within 4 loads of the register, and any given slot within
`NUM_WB` times 4 (8 with two slots), however slowly the level below accepts.

The miss slots take turns too. The fill pick starts from the slot after the
last one it loaded, so a fill that can issue is loaded within `NUM_MSHR`
fill loads. A fixed order would let low slots that keep reallocating between
the level below's acceptances starve a fill in a high slot.

### Probes

The L1D (`NUM_PROBE > 0`) takes per-line coherence probes on its upstream
port: read-shaped requests flagged `probe`, of two kinds.

- PROBE_CLEAN writes a dirty copy back and leaves it valid and clean.
- PROBE_INVAL writes a dirty copy back and invalidates it.

A probe returns no data. Its response pulse is the acknowledgement, sent only
after the level below has acknowledged any writeback the probe caused, so the
requester can order its own access behind that writeback. Probes go through
the pipeline like any other request: a probe aimed at a line in transition
waits, one aimed at a line in a writeback slot waits for that writeback, and
a probe never merges or takes a waiter seat.

Each probe holds a probe slot from its decision until the requester releases
it, after the level below has ordered the requester's own access. While a
PROBE_INVAL slot is held, the cache issues no fill of that line. A miss that
follows the invalidation waits in its miss slot and fetches the line after
the release, instead of fetching the old data again. A whole-line write would
install without waiting for the release, and a walk's PROBE_CLEAN could then
write it back ahead of the DMA write, leaving a clean copy older than the
level below's; that is why a probed cache must never receive one (see Line
protocol). A fill of the line allocated before the probe's decision is never
withheld: the probe waits for it and invalidates what it installs.

Pending probe acknowledgements take the response port ahead of ordinary
acknowledgements and hold off new read hits, so a stream of hits cannot
starve them.

### Maintenance

`fence.i` uses two operations, each of which starts only once every slot and
pipeline stage is empty:

- Writeback-all reads each tag, writes dirty lines back through the writeback
  slots, and marks them clean; the lines stay valid. `o_maint_busy` falls
  once those writebacks are acknowledged. The walk covers only the index span
  dirtied since the previous writeback-all.
- Invalidate-all reruns the reset sweep, which clears every tag. It discards
  dirty data, so only the read-only L1I uses it.

The hierarchy runs them in order: the L1D writes back first, then the L1I
invalidates, so an instruction fill racing the sequence cannot leave
pre-writeback data in the freshly invalidated L1I. The L2 needs no
maintenance: it sits below both L1s, so everything the L1D writes back is
visible to L1I fills.

A sequence answers only a request held since it started. A full flush can
take the request away mid-sequence (an interrupt taken while `fence.i`
waits); the sequence still runs to its end, since the sweeps cannot be
aborted, but it finishes without raising done. Stores can reach the L1D
after its writeback walk, so a request raised again gets a fresh sequence.

Maintenance and probes never overlap. Maintenance waits for the probe slots
to empty like any other in-flight work, and a probe waits for maintenance
like any other request, parked in the hierarchy's probe injection register.

Reset runs the sweep too, so every reset, including an image load, discards
stale lines instead of writing them back. `SIM_FAST_MAINT=1` (simulation
only) makes the sweep a one-cycle clear and makes writeback-all visit only
dirty lines, with the same functional effect.

## The hierarchy

`frost_cache_hierarchy` puts the L1D, walker, L1I, and DMA ports over one
arbiter tree into the L2, through the line-size adapter. The L2 is the
ordering point for all traffic below the L1s and drives the AXI bridge.

[![FROST cache hierarchy: L1D, walker, L1I and DMA arbitration through the line-size adapter into the L2 and DDR, each of the walker and DMA ports entering through its own coherence sequencer](../../../../docs/diagrams/cache-hierarchy.svg)](../../../../docs/diagrams/cache-hierarchy.svg)

The diagram shows the X3 configuration. Arrows follow requests; responses
return by id prefix.

The arbiter tree is a 2:1 `line_port_arbiter` (walker over L1I) under a 3:1
one (L1D over that pair over DMA). Both are combinational pass-throughs, so
the tree acts as one 4:1 fixed-priority arbiter ordered L1D, walker, L1I,
DMA. The order follows urgency: L1D misses stall committed work, a walk
unblocks a load that is stalling commit, fetch runs ahead through its
buffer, and DMA drains a device's buffers.

There is no grant lock. A request flows whenever the level below is ready,
so an L1I fill, a walk, an L1D transaction, and a DMA transaction can all be
in flight below the arbiters at once.

The top arbiter bounds starvation (`DMA_STARVATION_LIMIT`, 16 grants). A port
that has watched 16 grants go to other ports while presenting a request wins
over every port that is not starved. Another starved port may win first, so
a port waits at most 17 competing grants. The bound counts grants, not cycles,
so it holds however slowly the L2 accepts, and it gives the DMA port a
progress guarantee under a sustained stream of CPU-side misses.

Each arbiter prefixes its port index to the ids it forwards, so ids stay
unique across all upstream masters without a global plan. The tree yields a
prefix-free code in `UP_ID_BITS + 2` bits:

| Master | Id below the top arbiter | Local id bits (`UP_ID_BITS=3`) |
|--------|--------------------------|--------------------------------|
| L1D | `{2'b00, id}` | 3 |
| Walker | `{2'b01, 1'b0, id}` | 2 |
| L1I | `{2'b01, 1'b1, id}` | 2 |
| DMA port | `{2'b10, id}` | 3 |

The L2 sees those 5 bits. Its own downstream requests carry `{type, slot}`
ids, `L2_DOWN_ID_BITS` wide: 5 on the X3, the AXI id width its DDR block
design provides (`fpga/build/x3_ddr_bd.tcl`). The L1I spends one of its 2
bits on the
fill/writeback type, leaving 2 miss slots, which is all its master, the
two-line fetch buffer, ever uses. The walker keeps one walk in flight and
uses id 0.

The bridge drops any response whose id is not in flight. That is how a
transaction interrupted by an image-load CPU reset drains harmlessly on
hardware, where the DDR controller keeps running through the reset: its
stale response meets a cleared in-flight map. A request the bridge was still
presenting when the reset came stays presented until the controller accepts
it, as AXI requires of a master whose slave is not reset, so a write whose
address was accepted before its data never leaves an orphaned beat behind;
its response is then dropped the same way. A late response would pass for
the response to a new request with the same id, so the reset moves the
in-flight map into a second map of transactions still owed from before it,
which only their responses clear, and the bridge accepts no request until
that map is empty. An image load relies on those transactions completing
promptly in another way: nothing orders the JTAG loader's DDR writes after
the bridge's, so each write the bridge accepted before the reset must land
before the loader's first DDR write.

The interconnect's own reset is different. While it is in reset, AXI
requires every VALID low, so the bridge takes that reset as a second input
(`frost`'s `i_ddr_axi_rst_n`, which X3 drives from the SmartConnect's
CPU-side reset, the CPU clock's lock). It gates the held VALIDs off in the
cycle the reset arrives and drops those beats, so none is presented after the
interconnect restarts. The behavioral DDR model in simulation resets with
the CPU, so there the CPU reset serves as both.

## The L2 line size

The L1s, the walker, and the DMA port use 32-byte lines, and so does
everything above the L2: the arbiters, both coherence sequencers, and the
L1D's probes. The L2 uses 64-byte lines, each holding two 32-byte lines as
its lower and upper halves, so every DDR transfer is one 512-bit beat, the
width of the X3 DDR4 controller's word. The controller runs ECC without a
data mask, so a write of less than a whole word makes it read the word,
merge, and write it back; the L2 writes back only whole lines.

In general `L2_LINE_BYTES` is a power-of-2 multiple of `L1_LINE_BYTES`, and
each L2 line holds that many L1 lines as sectors. With equal line sizes the
adapter below is left out. `frost` and `cpu_and_mem` take `L2_LINE_BYTES`,
64 by default; at 32 the DDR AXI port is 256 bits wide. The X3 top sets 64,
one line per beat of its block design's 512-bit CPU port.

`line_size_adapter` sits between the top arbiter and the L2. Valid and ready
pass straight through, so a request is accepted by the adapter exactly when
the L2 takes it, and the coherence sequencers' arguments, which order DMA
writes and walks by that acceptance, hold as they do with equal lines. Ids
pass through too. The adapter aligns the address to the L2 line and maps
each request onto its sector in three separate parts: the data goes into
every sector, the strobes into the request's sector only, and the response
returns the request's sector of the line. An outstanding-transaction table
with one entry per id records each request's sector when it fires, and the
response, which carries the same id, reads it back. Responses return in any
order. The table needs no reset: an entry is written when its request fires,
and only that request's response reads it.

The adapter holds no request of its own, so it merges none: reads of one L2
line meet in the L2's miss slot, as below. A merge in the adapter would break
the acceptance order. For example, while an L1I read of one half of a line
misses, a DMA write to the other half is accepted and releases the L1D's
withheld read of that half; merged into the L1I read's fill, the L1D read
would return the line from before the write.

With several L1 lines in one, the L2 works as follows:

- Requests to any sector of an L2 line are applied in acceptance order, a
  stronger order than the L1s need.
- Two reads of a missing line share one fill, whether they read one sector
  or two: the first takes the miss slot and the second its single waiter
  seat. A third read of the line waits in the decision stage until the fill
  installs.
- A write never covers a whole L2 line. One that misses, an L1D eviction of
  a line the L2 has lost or a DMA write to a line it lacks, fetches the line
  and merges its bytes into the fill. A write to another sector of the line
  merges into the same miss slot while that slot has no waiter.
- A write to a line whose miss slot is a read's, or holds a waiter, waits in
  the decision stage until the fill installs. The decision stage takes one
  request at a time, so all L2 traffic waits behind it for that fill.
- An eviction writes the whole line, with every strobe set, in one transfer.

Reset clears the L2's tags, 32,768 with 64-byte lines, one per cycle on
hardware.

DMA coherence and atomics work the same with either line size. DMA is
coherent through the DMA port (see The DMA port and coherence); a master
that reaches DDR below the L2 sees neither cache level. AMOs, LR, and SC
execute in the load queue, on low BRAM and cached DDR, and reach the
hierarchy as ordinary reads and writes. An atomic to any other address
faults.

## The page-table walker port

The hardware page-table walker (`ptw.sv`) is the hierarchy's `wup` port,
between the L1D and the L1I in priority. With no grant lock, a ready walk
never waits for an L1I fill to complete. A walk is a chain of dependent
8-byte PTE reads, one per level, each a full-line read on this port; the
walker extracts its PTE from the line response the way
`cached_tier_adapter` extracts a beat. One walker serves both TLBs through a
requester mux in `cpu_ooo`, where the data side wins, and one walk is in
flight at a time. Walks only read: an access that needs a PTE's A or D bit
set takes a page fault (Svade), so there is no PTE write path. Walker reads
carry `maintenance = 0` and count as ordinary traffic.

Page tables live in cacheable DDR, and a page-table store sits dirty in the
L1D like any other store, while the walker reads below the L1D. Software also
publishes page tables without `sfence.vma`: Linux fills a new table, executes
`fence w,w`, stores the pointer to it, and uses the mapping before the
closing `sfence.vma`. A walker that read only the L2 could see the new
pointer (evicted from the L1D) together with the stale table below the L1D
that it points to. That is a translation that never existed, which the
architecture forbids: a walk may return any translation valid since the last
`sfence.vma`, but not a mixture.

`walker_coherence_sequencer` prevents this. Every walk read first sends a
PROBE_CLEAN to the L1D, so a dirty copy is written back and ordered at the
L2 ahead of the read, and stays valid and clean in the L1D. Stores still in
the store queue are not covered, and need not be. They drain to the
L1D in program order, so a walk that sees a later page-table store sees
every earlier one, and a walk that sees neither returns the old translation,
which is still permitted.

`sfence.vma` still runs the L1D writeback-all of the `fence.i` sequence, and
the ROB serializer's SFENCE window (`rob_serializer.sv`) holds both TLBs
invalid and keeps the walker from starting a walk or returning a result for
the whole sequence, so nothing translated under the old tables installs
meanwhile. Walks do not depend on that writeback.

The walker and DMA sequencers share one probe injection register into the
L1D. The walker takes priority for it: with one read in flight it presents at
most one probe per round trip, so it cannot starve the DMA entries. The L1D
has one more probe slot than the DMA sequencer can occupy, so one is always
free for the walker.

Progress: once accepted, a walk read completes on its own.

- The probe waits only on L1D transients that resolve through the L2 (a
  fill or writeback of the line already in flight) and on its reserved probe
  slot.
- The acknowledgement waits only for the level below to acknowledge the
  dirty writeback.
- The issue waits only for the arbiter tree, where the higher-priority L1D
  traffic is finite while the CPU waits on the walk.
- The response is unconditional.

No step waits on the walker, the pipeline, commit, or the store queue, and
walks and cache maintenance cannot deadlock. A probe that arrives while
maintenance is pending waits in the injection register, outside the L1D
pipeline that maintenance drains. A probe that already holds a slot releases
it when its read is accepted, which never waits on maintenance, so a
writeback-all waiting for the probe slots to empty always gets them. A walk
discarded by `sfence.vma` or a `satp` write still consumes its response
(`ptw.sv`).

## The DMA port and coherence

The DMA port (`dma`) is the hierarchy's fourth upstream port and reaches the
top arbiter through `dma_coherence_sequencer`. The L1D is write-back and the
load queue keeps its own dword copies of loaded data, so a DMA agent that
simply joined the tree below the L1D would neither see the CPU's dirty data
nor invalidate the CPU's stale copies. The sequencer therefore takes every
DMA request through the L1D, and every DMA write through the load queue as
well, before the L2 orders it. It holds up to `NUM_DMA_LOCK` (3)
requests between acceptance and response, one per lock entry, and accepts a
new request only when an entry is free and no active entry holds the same
line.

A DMA write goes through five steps:

1. The load queue admits the line: no AMO or SC on it is between its read
   and its write, and the queue starts no AMO, LR, or SC on it until step 4.
2. A PROBE_INVAL writes a dirty L1D copy back and invalidates every copy.
   From the probe's decision until step 4, the L1D issues no fill of the
   line: a miss that fetched before the write is ordered would bring the
   old line back.
3. The load queue drops its dword copies of the line, flags loads of it that
   have executed but not retired for replay, marks in-flight loads of it as
   not-to-fill and in-flight LRs as reservation-suppressed, and clears a
   matching reservation.
4. The write is presented downstream. Its acceptance by the L2 orders it,
   releases the L1D probe slot so that withheld fills fetch the new line,
   and pulses the release to the load queue. Acceptance is enough because
   the L2 applies same-line requests in acceptance order: a withheld fill
   reaches it behind the write.
5. The L2's completion becomes the DMA port's response.

A DMA read sends a PROBE_CLEAN, which writes a dirty copy back and leaves it
valid and clean, then presents the read. The probe slot is released when the
read is accepted, and the response carries the line as ordered behind any
dirty L1D data.

The sequencer guarantees coherence order, not wall-clock order. An
acknowledged write is visible to every CPU load that observes memory after
it. A load that observed memory before the write may still return the old
value afterwards; that is legal in coherence order, and the load queue's
replay of executed-but-unretired loads keeps program-order consequences
correct. Requests to different lines are not ordered with respect to each
other, so an agent orders dependent writes by waiting for responses. Requests
to the same line serialize in acceptance order, because the second waits for
the first's entry to retire.

Progress: a probe waits only on L1D transients that resolve through the L2
and DDR, because a fill of the probed line allocated before the probe's
decision is never withheld. A withheld fill waits only for the release, which
depends on the load queue and the L2 alone. Nothing below the sequencer waits
on the DMA port. The admit and invalidate
handshakes hold a latched request until the load queue answers, so the core
may take several cycles to answer.

## Verification

| Target family | Coverage |
| --- | --- |
| `frost_cache*` | Tagged data, instruction, and walker traffic, maintenance (also on the fast simulation path), out-of-order memory completion, and dirty-L1D walker coherence |
| `frost_cache_concurrency*` | Hits and misses under outstanding misses, merge and waiter paths, writeback and fill progress, and `fence.i` |
| `frost_cache_dma*` | Coherent reads and writes, invalidations, ordering, and concurrent CPU and walker traffic |
| `frost_cache_l2_lines*` | 64-byte L2 lines: both halves of a line sharing one fill and a third reader waiting, write misses that fill and merge in either half, a writeback waiting behind its line's read fill, halves combining in one line, whole-line writebacks, DMA writes changing only their half, L2 ordering across halves, a refill waiting for its line's writeback, `fence.i` into lines the L2 lacks, reset with misses in flight, and every port's misses at once; every AXI transfer checked as one whole-line beat |
| `*_equal_lines` | The data-integrity, concurrency, and DMA suites with 32-byte L2 lines, equal to the L1s', as a control; also DDR load and store, fetch, atomic, DMA, page-table-walk, and `fence.i` programs on the whole system with 32-byte L2 lines and a 256-bit DDR port |
| `*_16x4` | The L2-line, concurrency, and DMA suites with 16 L2 miss slots and 4 writeback slots |
| `line_port_arbiter*` | Arbitration and tagged responses |
| `line_port_axi_bridge` | The bridge across a CPU reset against a slave that keeps running: held beats, AW/W pairing, dropped stale responses, and a reused id held back until the stale response for it has arrived; and across the slave's own reset, which withdraws the held beats |
| `fence_speed_slow`, `fence_speed_fast` | Maintenance latency; CLI-only |
| `dma_envelope_lock3` through `dma_envelope_lock8`, `dma_envelope_lock3_mem30`, `dma_envelope_lock3_big_l2` | DMA throughput and latency by lock count and scenario; CLI-only |
| `l2_slots_4x2`, `l2_slots_8x2`, `l2_slots_16x4` | L2 miss-slot use with every port missing at once, by slot count; CLI-only |

Run a target with `./scripts/frost.py cocotb <target>`; `--list-tests` prints
the exact names. The benches live in
[`verif/cocotb_tests/cache`](../../../../verif/cocotb_tests/cache/). The
full-system programs `dma_torture` and `ptw_coherence_test` check DMA and
walker coherence against the running CPU. Formal targets cover the bridge
(`line_port_axi_bridge`: AXI handshakes, also across a CPU reset, VALIDs low
through the AXI side's reset, id conservation, stale-response drops, and no
request accepted while a response from before a reset is owed), the
line-size adapter (`line_size_adapter`: strobes and data in the request's
sector, and each response returning the sector its request recorded), the
arbiter grant (`line_arbiter_grant`), and the miss-slot byte merge
(`cache_mshr_payload`); see the [formal guide](../../../../formal/README.md).
