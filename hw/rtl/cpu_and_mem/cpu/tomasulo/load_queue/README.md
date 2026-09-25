# Load Queue

The load queue (LQ) tracks every load, LR and AMO from dispatch until its
result leaves for the CDB. It has eight entries (`riscv_pkg::LqDepth`) and two
allocation ports, one per dispatch slot. For each load it decides when the
load may read memory and where the data comes from: an older store still in
the store queue (SQ), a 128-entry L0 cache that answers in the same cycle, or
one of three memory tiers behind the data-memory router (one-cycle low BRAM,
device registers, and the cached DDR hierarchy). Ordinary loads issue out of
order; device loads, LRs and AMOs wait for the head of the reorder buffer
(ROB). The LQ also holds the LR reservation, runs each AMO's
read-modify-write, and reports loads to the DMA coherence logic.

An entry's life: allocate at dispatch → receive its address → check the SQ →
take a forwarded value, hit the L0, or read memory → move into `cdb_stage` →
free.

The queue is [`load_queue.sv`](load_queue.sv). Issue selection is in
[`lq_issue_selector.sv`](lq_issue_selector.sv), the L0 in
[`lq_l0_cache.sv`](lq_l0_cache.sv), and [`load_unit.sv`](load_unit.sv)
extracts and sign-extends bytes, halfwords and words from a 64-bit beat.

## Parameters

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `DEPTH` | `riscv_pkg::LqDepth` (8) | Queue entries |
| `L0_CACHE_DEPTH` | `riscv_pkg::LqL0Depth` (128) | L0 entries (see [L0 cache](#l0-cache)) |
| `ENABLE_L0_FAST_PATH` | 1 | Complete loads from the L0 |
| `ENABLE_SQ_FORWARD_FAST_PATH` | 0; 1 in the core | Complete loads by store-to-load forwarding. With 0, a load that overlaps an older store waits for it to drain |
| `PREPARE_LOAD_WHILE_BUSY` | `riscv_pkg::PrepareLoadWhileBusy` (1) | Stage the next load while the memory port is busy |
| `PREISSUE_CANDIDATES`, `PREISSUE_SEL_WIDTH` | 0, 2; 1, 3 in the core | Accept 2^`PREISSUE_SEL_WIDTH` candidate look-ahead tags instead of one (early load wakeup) |
| `CACHED_BASE`, `CACHED_SIZE_BYTES` | `0x8000_0000`, 1 GiB | Cached (DDR) region |
| `MMIO_ADDR`, `MMIO_SIZE_BYTES` | The core's MMIO window | Only flags an AMO write as MMIO; the LQ's device rules cover the whole device quadrant |

## Allocation and capacity

Each dispatch slot takes the next free entry at or after `tail_ptr`.
Completed and flushed entries leave holes that allocation refills, so
physical order is not program order: age always comes from ROB tags, and
`tail_ptr` only marks where the free-entry search starts. An entry frees when
its result enters `cdb_stage`, before the CDB broadcast.

Allocation requests on a flush cycle are dropped, as the ROB drops them.
Dispatch does not flush-gate its requests, and accepting one would create an
entry for a ROB tag that was never allocated.

Dispatch sees the registered `o_dispatch_full` and `o_dispatch_full_for_2`,
which take no credit for this cycle's frees or flushes: they may stall
dispatch a cycle longer than needed but never report room that is not there.
`o_full` and `o_full_for_2` are exact.

## Issue

MEM_RS (or the data MMU, under address translation) sends each load's address
with its ROB tag (`i_addr_update`), and a CAM on the entries' ROB tags finds
the entry. The same tag arrives exactly one cycle earlier as a look-ahead
(`i_pre_issue_rob_tag`, or with `PREISSUE_CANDIDATES=1` a set of candidate
tags and a selector), so the LQ can register the match and select the load in
the cycle its address arrives.

[`lq_issue_selector.sv`](lq_issue_selector.sv) scans in ring order from
`head_idx` and finds, in parallel: the first entry holding a result, which
moves into `cdb_stage`; the first entry ready for memory (address known or
arriving, not issued, not staged, not fenced by an older AMO); and the ROB-head
load if it is ready for memory, which wins. A device load may be staged before
it reaches the ROB head, but device loads, LRs and AMOs neither probe the SQ
nor leave the LQ until they are at the head.

### ROB-head priority

Holes make ring order differ from age, so the ROB-head load H gets priority
for the single staging register and evicts a younger staged load
(`sq_check_replace`). Without it the queue can deadlock. Suppose a younger
load Y holds the staging register while it waits on an older store S that
overlaps it but cannot forward (S covers only part of Y, say), and a load Z,
younger than Y but ahead of H in ring order, wins the normal scan every cycle.
Z cannot evict the older Y, so H is never selected. If S has not committed, it
is younger than H, so it cannot commit or drain until H retires, and Y never
leaves. Priority for H is always safe: every store older than H has committed
and drains on its own. A head AMO takes priority only once the committed-store
queue is empty.

### Staging and the SQ check

The staging register (`sq_check_*`) holds the selected load while the SQ
checks it. Disambiguation is conservative: a load reads memory only when every
older store address is known and none overlaps it. The SQ answers in the next
cycle. If the newest overlapping older store covers every byte, the load
extracts its bytes from that store's aligned-dword image with its own
`load_unit`; if it covers only part of the load, the load waits and probes
again; with no overlap, the load completes from the L0 or launches.
Forwarding also needs every older store address known, because an older store
with an unknown address could overlap the load and be newer than the store
the SQ picked. The
[store queue](../store_queue/README.md#store-to-load-forwarding) documents
which stores count. Device loads, LRs and AMOs never forward.

A load staged while the SQ is empty skips the probe. Launch does not wait for
the previous response, and the staging register takes the next load in the
cycle the current one launches, so such low-BRAM loads can launch one per
cycle; a probe costs one more cycle. With `PREPARE_LOAD_WHILE_BUSY=1` a load
may be staged while the memory port is busy (`i_mem_bus_busy`), but the probe,
L0 hit and launch still wait for the port. A staged head AMO does not wait for
younger stores' addresses (`sq_head_amo_clear`), since no store older than it
exists.

### Forwarding results captured on a flush cycle

The SQ's forwarding result register captures under
`o_sq_check_capture_valid`, which is `o_sq_check_valid` without the flush
terms and without the cached-region commit interlock (`sq_commit_check_block`);
this keeps the trap pulse off the wide capture register. On a cycle with no
capture the register reads "addresses not known, no match", so each result is
visible for exactly one cycle. The LQ uses it only through `sq_can_issue`
(which also gates the L0 hit) and `sq_do_forward`, and both require:

- `sq_check_phase2`, which only the fully gated `o_sq_check_valid` sets, or an
  empty SQ on a cycle when nothing is captured. A full flush resets it, and a
  partial flush that kills the staged load clears it, so a result captured on
  either cycle is never used.
- `!sq_commit_interlock`, which applies the commit interlock again where the
  result is used.

This is why the SQ's scan may use unmasked commit pulses on a full-flush
cycle. A partial flush that spares the staged load does not discard that
cycle's result, which is safe: it kills only stores younger than the flush
point, and so younger than the load.

## Memory tiers

| Tier | Addresses | Response | In flight |
|------|-----------|----------|-----------|
| Low BRAM | `0x0000_0000`, 256 KiB | The cycle after launch | One owner; the next launch can overlap its response |
| Device | `addr[31:30] == 2'b01` | The cycle after the router accepts it, at least four cycles after handoff | One, and it blocks every other handoff |
| Cached (DDR) | `CACHED_BASE`, `CACHED_SIZE_BYTES` | Variable: an L1D hit after a few cycles, a miss after a fill round trip | Up to four (`riscv_pkg::CachedLoadSlots`), answered in any order |

Every response is one aligned 64-bit beat (see the
[memory map](../../../../README.md#memory-map) and the
[data-tier bus contract](../../../../README.md#data-tier-bus-contract)).
Low-BRAM and device loads share one fast owner (`mem_outstanding`); each
cached load holds a `cs_*` slot whose id travels with the request
(`o_mem_read_id`) and the response (`i_mem_read_is_cached`, `i_mem_read_id`).
A launch snapshots the load's attributes into its owner, so the response path
does not read the entry's fields. While all four slots are busy, or for a
cycle after the router held a cached response behind a fast one
(`i_cached_resp_held`), a registered hold stops every launch, low-BRAM and
device ones included; L0 hits and forwards continue. The one-cycle hold keeps
back-to-back fast launches from starving the held response.

A flushed cached load's slot is drop-marked (`cs_drop`) and stays busy until
its response arrives, which is then drained. The load's entry frees at once
and may already hold a new load, so a later flush must never judge a
drop-marked slot by its stale index and ROB tag (`cs_flushed` requires
`!cs_drop`). Doing so could clear the issued bit of the entry's new load,
which would launch twice and could hand its second response to the next load
in that entry. Likewise the fast owner's flush kill reads its own snapshot,
not the response-owner mux, so a cached response in the flush cycle cannot
hide it.

## Device loads

Device reads can have side effects (clear-on-read registers, FIFO pops), so a
device load (any address with `addr[31:30] == 2'b01`, mapped or not) runs
exactly once and never speculatively: it leaves the LQ only at the ROB head.
It may probe the SQ and hand off to the
[data-memory router](../../cpu_ooo/memory_if/data_mem_request_router.sv)
while older committed stores still drain, since neither step touches the
device.

The router parks every device request in its one-entry request register and
accepts it only once the request is armed behind the interrupt shield
(below), the write port is free, and every committed store has been written
(`i_sq_committed_empty`). Being at the ROB head is not enough, because older
stores have committed but may not have drained, and matching addresses is not
enough, because a device can expose one register at two addresses (the SiFive
CLINT window aliases the timer registers). The router must use the SQ's
registered status directly; registering it again would leave a cycle in which
it sees an empty queue after a store has committed.

The router's pending bit (`i_mem_request_pending` here) is part of the
wrapper's `i_mem_bus_busy` and stays high through the accept cycle, so no
second handoff can overwrite the parked request. A device load that faults
(see [Completion](#completion)) completes inside the LQ with its exception and
no handoff; the trap unit still waits for the drain before taking the trap.

In practice only an interrupt (or a debug halt request) can flush a parked
device load: xRET, FENCE-class and commit-time recovery cannot pass an
incomplete load at the ROB head, and a partial flush never reaches the oldest
instruction. The router cancels an unaccepted request on the LQ's own full
flush (`i_flush_all`), and the LQ, which still sees the pending bit on that
edge, owes no response. After accept the read has happened and must not be
repeated; that is the shield's job.

### Device-read interrupt shield

An interrupt between accept and commit would flush the load and repeat the
read, and a flush armed on the accept edge arrives too late to cancel it. The
trap unit therefore holds interrupts while `i_device_read_at_head` is set.
cpu_ooo raises this shield from the router's registered device-pending output
and drops it at the next commit, which must be the device load's own: the
load is at the ROB head, and an incomplete head cannot commit.

The router arms a request only after a full pending cycle, tracked in its own
`device_request_pending_q`, so the shield is up before any accept without a
signal from cpu_ooo back into the router:

| Cycle | Event |
|-------|-------|
| N | The LQ hands off the load at the ROB head; the router's pending bit sets at the edge |
| N+1 | `o_device_request_pending` is high; cpu_ooo's `device_read_shield_q` and the router's `device_request_pending_q` set at the edge |
| N+2 | The trap unit sees the shield; `device_accept_armed_q` sets at the edge |
| N+3 | Accept, with interrupts already held; the response arrives at N+4 |

An interrupt taken at N+1 or earlier flushes by N+2, which blocks arming and
cancels the request with no response owed. From N+2 until the load commits,
interrupts wait; exceptions stay enabled. Arming only adds a precondition: the
flush, write-port and drain conditions are checked again at accept.

The shield cannot hang the core: while it defers an interrupt, the trap unit
holds commit only while that interrupt arms (arming the read already required
an empty committed-store queue), so the load commits and the interrupt
follows. A simulation watchdog in cpu_ooo reports a shield held for 4096
cycles.

## L0 cache

The L0 is direct-mapped with 8-byte (dword) lines: valid bits in flip-flops,
tags and data in LUTRAM. The staged load looks it up combinationally
alongside the SQ check, and a hit completes the load in the cycle the SQ
answer allows. Every load size can hit, FLD included. Device loads, LRs and
AMOs never hit or fill.

A memory response fills its line with the whole beat, except on a full-flush
cycle, when the response is being drained (apart from the partial-flush case
below), or when a store or DMA write hit the line while a cached load was in
flight. Each invalidation source has its own port:

| Source | Granule | When |
|--------|---------|------|
| SQ store write | Dword | The cycle the SQ launches the write; a same-cycle hit is suppressed |
| AMO write | Dword | When the write completes |
| DMA write | 32-byte line (four entries, tag-blind) | On the coherence port's invalidation edge; a same-cycle hit is suppressed |

An L0 hit also waits for a free memory port (`!i_mem_bus_busy`), because a
store or AMO write can own the port before its invalidation takes effect.

The L0 is never flushed: stores write memory only after commit and invalidate
their line when they do, and loads fill with what memory returned, so a
mispredict leaves nothing speculative in it. A response that arrives with the
partial flush that kills its load may therefore still fill. A lookup sees a
fill only from the next cycle; forwarding the fill would put the flush logic
on the data-memory read-address path.

`L0_CACHE_DEPTH` comes down from `frost` and must be a power of two from 8 to
2^28: the index must reach above the four-dword DMA line, and the tag
(physical address bits 31 and below) needs at least one bit. Nothing else is
sized from it. Regressions cover 128 and 256 entries; larger sizes have not
been evaluated for resources or timing.

```bash
# CoreMark in simulation with a 256-entry L0
FROST_VERILATOR_EXTRA_ARGS=-GL0_CACHE_DEPTH=256 ./scripts/frost.py cocotb coremark
```

## Atomics

### LR and SC

The LR reservation (`o_reservation_valid`, `o_reservation_addr`) lives here.
An LR reads memory and sets the reservation when its response is accepted.
Devices hold no reservations, so an LR to the device quadrant takes a load
access fault instead, with no read and no reservation. The reservation clears
on any SC commit (`i_sc_clear_reservation`), a store write to the reserved
dword (the SQ's write-launch snoop), a DMA write to its 32-byte line, or a
full flush. An LR in flight when a DMA write hits its line, or whose
response lands on the invalidation edge, sets no reservation. The SC goes
through the SQ;
[`sc_pending_unit`](../tomasulo_wrapper/atomics/sc_pending_unit.sv) decides
success when the SC fires at the ROB head, from the reservation and the SC's
dword.

### AMO sequence

An AMO issues at the ROB head once the SQ has no committed store left to write
(`i_sq_committed_empty`), so no other memory access interleaves with it. Its
read launches like a load. An AMO to the device quadrant never launches: it
takes a store/AMO access fault instead, so AMOs only read and write BRAM and
cached DDR. At the response, SWAP, ADD, XOR, AND and OR capture the old
value and `rs2`, spend a cycle in `AMO_COMPUTE`, and enter
`AMO_WRITE_ACTIVE`; MIN and MAX compare during the capture and enter
`AMO_WRITE_ACTIVE` directly. The write uses the LQ's own port
(`o_amo_mem_write_*`, with registered MMIO and cached-tier flags) and stays
stable until `i_amo_mem_write_done`. Only then does the AMO complete with the
old value, invalidate its L0 line, and release younger loads. `.W` forms
compute on the addressed word and return it sign-extended; the write
replicates the word across the beat.

A flush that cleared `AMO_WRITE_ACTIVE` after the write launched would orphan
the write, and the AMO would then execute a second time. The trap unit
therefore holds interrupts while an AMO occupies the ROB head
(`trap_unit.i_amo_at_head`); exceptions stay enabled, because an AMO faults
before it touches memory. A simulation check reports any full flush that
reaches an active AMO write. A flush that arrives earlier, including in
`AMO_COMPUTE`, cancels the AMO cleanly. `AMO_COMPUTE` has already freed the
response slot but still keeps the line busy for DMA admission.

### Older-AMO fence

An AMO's write is invisible to SQ disambiguation (AMOs allocate no SQ entry),
so the LQ orders younger loads behind pending AMOs itself. Each entry has a
registered dependency row: the entries holding AMOs that are older than it by
ROB tag and have not finished their write. The row is built from ROB tags when
the entry becomes valid, and an AMO's column clears when its write completes.
Ring position cannot replace this: holes are reused, so a younger load can sit
ahead of an older AMO in ring order and would read memory before the AMO wrote
it.

A freed or flushed entry's row and column clear during the cycle the entry
spends invalid, and allocation never reuses an entry on the edge that frees
it, so no stale dependency reaches a new load. A fenced load cannot launch,
forward or hit the L0, and if it is staged it gives up the staging register
(`older_amo_write_pending`) so the AMO can reach the memory port.

## DMA coherence

A DMA agent below the L1D can write memory the core is reading. The wrapper's
[`lq_coherence_port.sv`](../tomasulo_wrapper/coherence/lq_coherence_port.sv)
mirrors the lines the cache hierarchy has admitted for DMA writes (up to
three, `riscv_pkg::DmaCoherenceLocks`), and the
[cache library](../../../../lib/cache/README.md) describes the whole write
sequence. The LQ's part, all on 32-byte lines:

- Admission. The LQ answers busy (`o_coh_query_busy`) for the queried line
  while an AMO or LR on it is staged, holds a cached slot, or is in
  `AMO_COMPUTE` or `AMO_WRITE_ACTIVE`. The port handles SCs.
- Launch hold. A staged AMO or LR on an admitted line does not launch until
  the line is released (`i_coh_block_*`). Admission is decided a cycle behind
  the queue, so a newly staged AMO or LR also waits a cycle for its own
  compare, and `i_coh_admit_pulse` holds every staged AMO or LR while an
  admission answer is presented and for a cycle after it fires. No DMA write
  can land between an atomic's read and its write.
- Invalidation (`i_coh_inval_*`). The LQ clears the line's four L0 entries,
  stops in-flight cached loads of the line from filling and in-flight LRs from
  setting a reservation, and clears a matching reservation. It does not
  squash in-flight loads: reading memory before the DMA write is a legal
  order.
- Observation (`o_coh_observe_*`). Each load in the cached region that hits
  the L0, forwards, or launches (AMOs excluded) reports its ROB tag and
  address, and the port keeps it until the load retires or is flushed. If a
  DMA write then invalidates the line, the ROB replays the load from the head
  (a restart at its own PC, with no architectural side effect). A younger load
  that read the line before the DMA write therefore never retires after an
  older load that read it afterwards, which gives FENCE, acquire and
  same-address ordering without serializing loads.

## Flushes

| | Partial flush (`i_flush_en`, `i_flush_tag`) | Full flush (`i_flush_all`) |
|---|---|---|
| Source | Early branch recovery | Trap, xRET, FENCE-class recovery, or a branch recovered at commit |
| Entries, staged load, `cdb_stage` | Those younger than the flush tag are dropped | All dropped |
| Fast-tier load in flight | If killed, its response is drained, now or later (`drop_mem_response_pending`) | Still parked in the router: canceled, nothing owed. Accepted: response drained, now or later |
| Cached slots | Killed ones drop-marked | All drop-marked, except one still parked in the router, which is freed |
| Reservation | Kept | Cleared |
| L0 | Kept | Kept; a response on this cycle does not fill |

In the core, `i_flush_en` is the registered early-recovery pulse. It matches
the architectural partial flush except on full-flush cycles, so `i_flush_all`
must take priority over `i_flush_en` everywhere. Address updates are not
flush-gated either: one that arrives on a flush cycle may write an entry's
address payload, but the same edge clears or blocks the entry's control state.

## Completion

Results leave through `cdb_stage`, a one-entry register in front of the MEM
CDB adapter (`o_fu_complete`, advanced by `i_result_accepted`). A memory
response, L0 hit or forwarded value goes straight into it when it is free and
the selector is not filling it, and the entry frees at once; otherwise the
result waits in the data RAM. An AMO that does not fault completes through the
data RAM, and nothing enters `cdb_stage` on a partial-flush cycle.

A load that faults (misaligned when `i_trap_misaligned_accesses` is set,
outside the physical memory map, an AMO or LR to the device quadrant, or with
a fault the data MMU parked on the entry) never reaches memory. It completes
from the staging register with its cause (a store/AMO cause for an AMO) and
the faulting address, which becomes the trap value.

## Storage

What the parallel scans and flushes read at once is in flip-flops: control
bits, ROB tag, size, and a 4-bit AMO operation code (the 18 AMO opcodes reduce
to nine operations). The code is written one cycle after allocation, always
before the AMO can launch (checked in simulation). The address and the AMO
`rs2` operand are in LUTRAM, read only after `lq_addr_valid` is set; the
address CAM matches ROB tags, not addresses. Results are in one 64-bit LUTRAM
with two write ports (memory responses on port 0; L0 hits, forwarded values
and AMO completions on port 1), so a response for one load and a hit for the
next can land in the same cycle. A dword load stores the whole beat, other
loads the value `load_unit` extracted and sign- or zero-extended (FLW its raw
word); FLW results are NaN-boxed at the CDB.

## Performance counters

The LQ drives `o_l0_hit`, `o_l0_fill`, `o_mem_outstanding` (a memory response
is owed), and mutually exclusive diagnostics about the load at the ROB head.
The wrapper's counters split the ROB's `head_wait_mem_load` cycles with them:
a response owed, address pending, SQ disambiguation, bus blocked (with finer
causes below it), waiting for the CDB, and already out of the LQ. See the
[counter reference](../../cpu_ooo/perf/README.md).

## Verification

The `load_queue` cocotb suite tests the queue in isolation,
`load_queue_no_prepare_busy` reruns it with `PREPARE_LOAD_WHILE_BUSY=0`, and
`load_queue_sq_forward` with `ENABLE_SQ_FORWARD_FAST_PATH=1`, as in the core.
`lq_l0_cache_128` and `lq_l0_cache_256` test the L0 alone, and
`lq_stale_slot_probe` is a full-core program that drives two partial flushes
and ROB-tag reuse against slow, reordered DDR responses. The wrapper and
router suites (`tomasulo_coherence`, `data_mem_request_router` and others)
check the connected handshakes, and simulation assertions check cached-slot
identity, AMO write stability, the device-read shield, and that every launched
load other than an AMO keeps an owner (the fast owner or a cached slot) until
its data is valid or a flush removes it.

Formally, `load_queue` checks queue invariants from reset,
`load_queue_amo_compute` the AMO datapath with no reset or admission
assumptions, `lq_l0_cache` the L0, and the small `lq_*` targets each prove one
optimized structure equal to its reference form.

```bash
./scripts/frost.py cocotb load_queue
./scripts/frost.py formal --target load_queue
```

See the [test runner](../../../../../../tests/README.md) and the
[formal guide](../../../../../../formal/README.md) for commands, scope and
assumptions.
