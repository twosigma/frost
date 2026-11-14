# Load Queue

The load queue (LQ) tracks every load, LR and AMO from dispatch until its
result leaves for the CDB. It has eight entries (`riscv_pkg::LqDepth`) and two
allocation ports, one per dispatch slot. For each load it decides when the
load may read memory and where the data comes from: an older store still in
the store queue (SQ), a configurable L0 cache that answers in the same cycle, or
one of three memory classes behind the data-memory router (uncached Normal
memory, Device registers, and the cached hierarchy). Ordinary loads issue out of
order; device loads, LRs and AMOs wait for the head of the reorder buffer
(ROB). The LQ also holds the LR reservation, runs each AMO's
read-modify-write, and reports loads to the DMA coherence logic.

An entry's life: allocate at dispatch, receive its address, check the SQ,
take a forwarded value, hit the L0, or read memory, move into `cdb_stage`,
and free.

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
| `PREISSUE_CANDIDATES`, `PREISSUE_SEL_WIDTH` | 0, 2; 1, 3 in the core | Select one of 2^`PREISSUE_SEL_WIDTH` look-ahead matches and register it (early load wakeup) |
| `PREISSUE_READY_PICK`, `PREISSUE_RS_DEPTH` | 0, 8; 1, 8 in the core | Compare RS entry tags first, then select a match using each candidate's ready vector |
| `CACHED_BASE`, `CACHED_SIZE_BYTES` | `0x8000_0000`, 1 GiB | Cached (DDR) region |

FROST passes a 512-entry L0 when Normal read caching is enabled; the raw LQ
and strict CPU profile retain the 128-entry default. Cache depth does not
change the number of in-flight loads or coherence observation entries.

The L0 valid-bit read selects the indexed bit. The selected bit is qualified
by MMIO, store and line-invalidation permissions independently of the tag
comparison. The lookup is combinational. Primitive builds select among up to
32 bits per level within one slice, four-way LUT6 selections feeding MUXF7,
MUXF8 and MUXF9, so a 512-entry L0 takes two levels; they keep the selection
hierarchy and the selector pin assignments.

In the CPU, the staged load's same-sector hold reads registered matches: each
entry keeps its sector and registers its match against every coherent L1D
holder from its next address, and against a store the CPU's write port pushes
into the L1D's store buffer, so a record that turns valid with that push
matches through the pushed line. The staged load keeps its own copy of its
entry's matches, registered with `sq_check_idx` from the next matches of the
entry it takes, so the hold reads no select by the index. These copies read
stored matches for the held index. For the candidate they prepare head data
at the shared head index and gather stored/merged ring data before selecting
the source. Empty rings retain the encoder's index-zero default. Raw head
masks need not be one-hot: head data uses the encoded index even when tags
repeat. Address-update valid and head priority select the prepared candidate
data and write match; capture take then selects a stored or shared update match
at the final selector. Entry flags and payloads keep their encoded writes.
Holder zero changes
only when an atomic starts or ends, and in that cycle the hold covers every
staged load. The raw LQ compares the staged address with the holders directly.

## Allocation and capacity

Each dispatch slot takes the next free entry at or after `tail_ptr`.
Completed and flushed entries leave holes that allocation refills, so
physical order is not program order: age always comes from ROB tags, and
`tail_ptr` only marks where the free-entry search starts. An entry frees when
its result enters `cdb_stage`, before the CDB broadcast. The next valid bits
are the bits kept through the cycle's flushes and frees, ORed with the new
allocations, so the allocation enable, which arrives last from dispatch, meets
them in the final term. A new generation also clears its entry's address-valid,
issued, response-error and forwarded flags: each flag's value from this cycle's
other updates meets the allocation valids and the free-entry masks in one final
gate on the flop's D input.

Allocation requests on a flush cycle are dropped, as the ROB drops them.
Dispatch can present one on a trap, xRET, or FENCE-class flush, because the
front-end kill arrives a cycle late, and accepting it would create an entry
for a ROB tag that was never allocated.

Dispatch sees the registered `o_dispatch_full` and `o_dispatch_full_for_2`,
which take no credit for this cycle's frees or flushes: they may stall
dispatch a cycle longer than needed but never report room that is not there.
`o_full` and `o_full_for_2` are exact.

## Issue

MEM_RS (or the data MMU, under address translation) sends each load's address
with its ROB tag (`i_addr_update`), and a CAM on the entries' ROB tags finds
the entry. The look-ahead arrives exactly one cycle earlier, so the LQ
registers the match and selects the load in the cycle its address arrives.
The scalar mode compares `i_pre_issue_rob_tag`; the candidate mode compares
every candidate and registers the match of the one `i_pre_issue_sel` names,
which arrives early in the cycle. In the core
(`PREISSUE_READY_PICK=1`) the LQ compares its tags against every MEM_RS entry
tag, and each candidate's ready vector picks the compare result of that
candidate's winner (entry 0 when nothing is ready). Under translation it
compares `i_pre_issue_direct_tag` instead.

[`lq_issue_selector.sv`](lq_issue_selector.sv) scans in ring order from
`head_idx` and finds, in parallel: the first entry holding a result, which
moves into `cdb_stage`; the first entry ready for memory (address known or
arriving, not issued, not staged, not fenced by an older AMO or held behind a
vector memory instruction); and the ROB-head load if it is ready for memory and
not held, which wins. A device load may be staged before
it reaches the ROB head, but device loads, LRs and AMOs neither probe the SQ
nor leave the LQ until they are at the head.

The capture, issue and forwarding control banks compute memory candidates for
both SQ drain states in
[`coherent_lq_issue_selector.sv`](coherent_lq_issue_selector.sv). The live
drain flag selects between those results. Each memory scan input combines a
prepared class permission with the entry's valid, issued, data-valid and
in-flight bits. Each combination uses one LUT5 when primitives are enabled.
Each case also reads the
staged load's age at its winning masks, in three-entry groups. The winning
masks are preserved at each group's inputs. Each group uses one LUT6 when
primitives are enabled. The ROB-head entry's age is compared directly from its
tag, since at most one entry matches the head. The selector passes each drain
case's groups and head-candidate flags to the LQ, which forms replacement: the
pending, gate, drain and address-update selects arrive before the groups, so
each case's select meets its groups in one kept term, and the four terms and
the head term meet in one more before the final capture LUTs. Both cases use the same ring order and ROB-head priority. Each entry has a cyclic
precedence mask derived from the queue head. An eligible entry wins when none
of its predecessors is eligible. Scan indices and tags decode from the
winning-entry masks. Selection is combinational. The coherent memory identity
uses the merged ring mask when an address update is valid and the stored mask
otherwise. Eligible ROB-head entries precede the ring scan. The coherent ring
index and ROB tag decode from the selected ring mask. Head matches use the
head selector's index and tag. The pre-issue selector registers a one-hot mask
alongside the candidate matches. Staging capture uses candidate presence
independently of ring ordering. A helper prepares capture and clear outcomes
for launch hold, an unheld miss and an unheld hit. These outcomes include the
staged head match, SQ drain and forwarding permissions, memory-busy and
L0-hit permission, phase and cut hold. Held implies miss, and miss implies
hit, so two bits encode each outcome class. Each pending copy supplies
vacancy independently; candidate presence and the capture gate qualify its
capture outcomes. Fault release has separate qualification for CDB
availability, completion priority, response bypass and launch hold. The
release class, launch hold, L0 hit, qualified fault and replacement meet at
explicit final LUTs in the primitive build, with equivalent portable logic.
Each in-flight mask bit combines capture, clear and partial flush at a final
LUT. Other staged controls select capture values or separately computed hold
values. Replacement selects
stored and arriving age predicates with ROB-head priority. Stored, arriving
and head conditions form separate class permissions. Final eligibility
requires the class permission, a valid row, and clear issued, data-valid and
staged or parked flags. Alignment is evaluated separately for stored
and arriving candidates before the selected result enters the staging
register. The capture helper combines staging validity with issue and forwarding
eligibility in each prepared outcome, with fault eligibility kept separate. An older pending
AMO contributes to both capture and clear. Sector blocking permits capture
and vetoes memory or forwarding release. Fault release requires both cut
and sector permission. Cached-AMO protection qualifies memory and forwarding
release inside each unheld outcome. Address faults, sector blocking and
older-AMO capture permission are independent of that protection. Issue,
forwarding and probes require staging validity; issue and forwarding also
apply the older-AMO veto.

Coherent issue,
forwarding and SQ-probe predicates decode address faults before applying
the cut and same-sector holds. The coherent memory launch computes permission
before applying the L0-hit result. Issue and SQ-probe permission are computed for both
head-match outcomes. Separate expressions cover non-atomic loads and the ROB
head with an empty committed SQ. The head comparison and committed-store drain
select between them. Cached-AMO protection qualifies issue and SQ-probe permission
after this selection.
Forwarding
requires an ordinary load and has no head-match dependency.
Each coherent address slot stores PMA permission, Normal-memory classification
and cache-region classification with its address. Stored and arriving payloads
compute PMA permission before address-source selection. Staging selects the
permission, Normal-memory class and cache-region class from the stored or arriving
address. The arriving address's permission is formed from its uncached,
cached-DDR and device range checks, which meet the source select and the
atomic flag in one final term. The captured Normal-memory class supplies
L0-hit eligibility.
Staging captures misalignment with the address and size. Fault checks apply
the live trap setting to that captured result. The first candidate mask determines which
address source wins ring order. Candidate presence is independent of
that ordering and the selected payload.
The coherent L0 computes lookup permission from validity, memory type and
invalidation independently of the tag comparison. A hit requires both.
Each entry's data-valid update prepares local completion outcomes for the
response-bypass and L0-hit decisions, and separate response eligibility for
both bypass choices. Response acceptance joins the selected local outcome;
an accepted response is never a dropped response. The two allocation valids
then clear the selected free entries. Small preparation logic and explicit
final LUT selectors preserve these decisions in the primitive build. Portable
logic implements the same functions. The result-RAM write enables and these
decisions use the same cycle's lookup and completion signals.

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
and drains on its own. A head AMO or LR takes priority only once the
committed-store queue is empty.

### Staging and the SQ check

The LQ prepares memory launch controls for both committed-store drain
states. The live drain flag selects
those outcomes. Local holds qualify memory launch after drain selection.
Capture and clear classes include the committed-store interlock, pending
validity, per-copy vacancy, candidate presence and local holds. The helper
encodes the held, unheld-miss and unheld-hit outcomes in two bits. Qualified
fault release and replacement join the final hold and hit selection.

The staging register (`sq_check_*`) holds the selected load while the SQ
checks it. Disambiguation is conservative: a load reads memory only when every
older store address is known and none overlaps it. The SQ answers in the next
cycle. If the newest overlapping older store covers every byte and has its
data, the load extracts its bytes from that store's aligned-dword image with
its own `load_unit`; if it covers only part of the load or has no data yet,
the load waits and probes again; with no overlap, the load completes from the
L0 or launches.
Forwarding also needs every older store address known, because an older store
with an unknown address could overlap the load and be newer than the store
the SQ picked. The
[store queue](../store_queue/README.md#store-to-load-forwarding) documents
which stores count. Device loads, LRs and AMOs never forward.

A load staged while the SQ is empty skips the probe. The staging register
can take the next load in the cycle the current one launches; a probe costs
one more cycle. The fixed-latency local-BRAM fixture permits a launch each
cycle, whereas the AXI Normal path keeps its one owner through the response.
With `PREPARE_LOAD_WHILE_BUSY=1` a load may be staged while the memory port
is busy (`i_mem_bus_busy`). The wrapper can separately permit an unrelated L0 hit while an ordinary
Normal store launches or drains, or while an older Normal read waits for its
response. Store disambiguation and same-dword invalidation still apply.
AMOs, precise store launches, recovery, and a pending Device handoff block
this overlap; external read launches still wait for the port. A cache hit
and an older read response can write distinct LQ entries on the same edge,
and both results subsequently reach the CDB.
A staged head AMO does not wait for
younger stores' addresses (`sq_head_amo_clear`), since no store older than it
exists.

### Forwarding results captured on a flush cycle

The SQ's forwarding result register captures under
`o_sq_check_capture_valid`, which is `o_sq_check_valid` without the flush
terms and without the cached-region commit interlock (`sq_commit_check_block`).
On a cycle with no
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
| Normal outside the DDR cache | Configured PMA region (FROST low BRAM) | Optional L0 hit, otherwise variable AXI R latency | One external read until response consumed |
| Device | Configured PMA device regions | Variable AXI R latency after head/shield admission | One, and it blocks every other handoff |
| Cached (DDR) | `CACHED_BASE`, `CACHED_SIZE_BYTES` | Variable: an L1D hit after a few cycles, a miss after a fill round trip | Up to eight (`riscv_pkg::CachedLoadSlots`), answered in any order |

Every response uses an aligned 64-bit container. Optional Normal read-cache
fills return a full dword; strict uncached and Device responses guarantee
only their requested bytes (see the
[memory map](../../../../README.md#memory-map) and the
[data-tier bus contract](../../../../README.md#data-tier-bus-contract)).
Uncached Normal and device loads share one in-flight tracker (`mem_outstanding` and
the `fast_*` registers); each cached load holds a `cs_*` slot whose id travels
with the request (`o_mem_read_id`) and the response (`i_mem_read_is_cached`,
`i_mem_read_id`). The coherent L1D also receives the request kind, size and
ROB tag; the kind distinguishes ordinary loads, LRs and AMOs. A launch
copies the load's attributes into its tracker or slot, so the response
path does not read the entry's fields. While every slot is busy, or for a
cycle after the router held a cached response behind a fast one
(`i_cached_resp_held`), a registered hold stops every launch, low-BRAM and
device ones included; L0 hits and forwards continue. The one-cycle hold keeps
back-to-back fast launches from starving the held response.

L1D stream look-ahead uses coherent request endpoints without allocating
LQ rows, cached response slots or observation entries. A demand may wait on
such an endpoint, but its response ID and observation belong to the demand.
After a fill it repeats the L1D permission lookup. Invalidations cover these
demand observations through retirement and replay them under the same
load-load ordering checks as other cached loads.

A flushed cached load's slot is drop-marked (`cs_drop`) and stays busy until
its response arrives, which is then drained. The load's entry frees at once
and may already hold a new load, so a later flush must never judge a
drop-marked slot by its stale index and ROB tag (`cs_flushed` requires
`!cs_drop`). Doing so could clear the issued bit of the entry's new load,
which would launch twice and could hand its second response to the next load
in that entry. Likewise the fast tracker's flush kill reads its own copy, not the
response mux, so a cached response in the flush cycle cannot hide it.

## Device loads

Device reads can have side effects (clear-on-read registers, FIFO pops), so a
device load (classified by the configured PMA) runs exactly once and
never speculatively: it leaves the LQ only at the ROB head.
It may probe the SQ and hand off to the
[data-memory router](../../cpu_ooo/memory_if/data_mem_request_router.sv)
while older committed stores still drain, since neither step touches the
device. A device-quadrant load outside the MMIO and APLIC windows reads
nothing: it faults instead (see [Completion](#completion)).

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

While the shield defers an interrupt, the trap unit holds commit only while
that interrupt arms. A parked Device read waits for older committed stores
to complete before arming. Progress requires those stores and the read's
memory response to complete. The simulation watchdog in `cpu_ooo` allows
65,536 cycles for the older-store drain, including cache initialization,
and 4,096 cycles for read service and commit after drain. Each counter
accumulates its phase's cycles until reset or shield release.

## L0 cache

`cpu_top` sets `CACHE_UNCACHED_DATA=0`: strict uncached and Device accesses
bypass L0 and cannot fill it, because unused narrow AXI byte lanes are not
valid data. It defaults to 1, which the unit benches use.
The independent `CACHE_NORMAL_MEMORY` option permits caching the configured
Normal region outside the debug slice's 4 KiB page; its AXI adapter fetches
complete aligned dwords. FROST enables this option, while standalone
`cpu_top` defaults it off. Device traffic always bypasses L0.

The L0 is direct-mapped with 8-byte (dword) lines: valid bits in flip-flops,
tags and data in LUTRAM. Above 64 entries the LUTRAMs are split into 64-entry
banks, and each bank's write enable is one gate over bank selects decoded
from the store and fill indices. Store, coherent cut and DMA invalidations
are compared with each cached slot before the response id selects the
single-bit fill kill, which enters the same gate. The staged load looks it up
combinationally alongside the SQ check, and a hit completes the load in the
cycle the SQ answer allows. Every load size can hit, FLD included. Device
loads, LRs and AMOs never hit or fill.

A memory response fills its line with the whole beat, except on a full-flush
cycle, when the response is being drained (apart from the partial-flush case
below), or when a store or DMA write hit the line while the load was in
flight. The Normal response tracker remembers overlapping stores through
the response edge, including same-cycle invalidation, so an old read cannot
replace newer L0 store data. Each invalidation source has its own port:

| Source | Granule | When |
|--------|---------|------|
| SQ store write | Dword | At launch, suppress same-cycle hits; update selected bytes for eligible Normal memory, otherwise invalidate |
| SQ cached cbo.zero | 64-byte block (eight entries, tag-blind) | At launch, suppress same-cycle hits in the block and invalidate it; an in-flight load of the block fills no L0 entry |
| AMO write | Dword | When the write completes |
| DMA write | 32-byte line (four entries, tag-blind) | On the coherence port's invalidation edge; a same-cycle hit is suppressed |

A Normal write-through store updates a matching dword using its byte enables.
A full-dword store may allocate a new entry; a partial miss cannot allocate
unknown bytes. Store updates take the RAM port ahead of a simultaneous read
fill, while AMO and DMA invalidation take priority over both.

An L0 hit waits for a free memory port unless the wrapper explicitly asserts
`i_l0_hit_allowed`. FROST permits hits during an older store's response wait,
after its L0 update, but blocks the launch edge, AMO activity and recovery.
SQ disambiguation still applies to every hit.

The L0 survives pipeline flushes: committed stores invalidate or update their
dword, and filtered successful loads fill with what memory returned, so a
mispredict leaves no speculative store data in it. CPU reset invalidates it.
A response that arrives with the
partial flush that kills its load may therefore still fill. A lookup sees a
fill only from the next cycle; forwarding the fill would put the flush logic
on the data-memory read-address path.

`L0_CACHE_DEPTH` comes down from `frost` and must be a power of two from 8 to
2^28: the index must reach above the four-dword DMA line, and the tag
(physical address bits 31 and below) needs at least one bit. Nothing else is
sized from it. Regressions cover 128, 256 and 512 entries; larger sizes have not
been evaluated for resources or timing.

```bash
# CoreMark in simulation with a 256-entry L0
FROST_VERILATOR_EXTRA_ARGS=-GL0_CACHE_DEPTH=256 ./scripts/frost.py cocotb coremark
```

## Atomics

### LR and SC

The LR reservation (`o_reservation_valid`, `o_reservation_addr`) lives here.
An LR reads memory and sets the reservation when its response is accepted.
Separate registers capture the set event, clear event and held validity.
Their combined output gives clears priority on that same edge. A full flush
clears the reservation on its edge; commit-time branch recovery preserves it.
Like an AMO, it launches at the ROB head once the SQ has no committed store
left to write (`i_sq_committed_empty`), so every store whose write clears the
reservation comes after the LR in program order. An older store to the other
word of the LR's dword does not overlap the LR, so nothing else would hold the
LR until that store writes.
Devices hold no reservations, so an LR to the device quadrant faults instead
(see [Completion](#completion)), with no read and no reservation.
The reservation records the exact physical address and W/D size. Its set
covers the aligned 32-byte sector. Writes and invalidations to that sector
clear it. An invalidation probe supplies its sector address at capture.
Matching response slots suppress LR reservations and L0 fills on that edge
and throughout the cut. Responses on other sectors keep their eligibility.
A trap, xRET or FENCE-class flush clears the reservation; a
branch recovered at commit preserves it. The SC goes through the SQ and
[`sc_pending_unit`](../tomasulo_wrapper/atomics/sc_pending_unit.sv).
Cached SC selection, local Modified-sector classification and the home check
use the exact LR address and size.

### AMO sequence

An AMO issues at the ROB head once the SQ has no committed store left to write
(`i_sq_committed_empty`), so no other memory access interleaves with it. Its
read launches like a load. An AMO to the device quadrant never launches: it
faults instead (see [Completion](#completion)), so AMOs only read and write
BRAM and cached DDR. At the response, SWAP, ADD, XOR, AND and OR capture the
old value and `rs2`, spend a cycle in `AMO_COMPUTE`, and enter
`AMO_WRITE_ACTIVE`; MIN and MAX compare during the capture and enter
`AMO_WRITE_ACTIVE` directly. The write uses the LQ's own port
(`o_amo_mem_write_*`, with a registered cached-tier flag) and stays
stable until `i_amo_mem_write_done`. The request router launches a cached AMO
write from a register armed in the cycle the write appears, so it reaches the
L1D one cycle later than a store would, from a flop. Only then does the AMO complete with the
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
response slot. A cached AMO holds either the L1D service engine or its home
lock through write installation and ownership release. CPU protection also
waits for retirement.

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

### Vector range holds

Vector loads and stores do not pass through the LQ or SQ; the vector unit's
memory table lists them in program order with the physical range each one
touches (up to two pages, as 32-byte sector spans), or an unknown range until
it is computed. [`vec_hold_rows.sv`](../../vector/vec_hold_rows.sv) gives each LQ
entry a second row: the table entries older than it, built in the entry's first
valid cycle like the AMO row (retired table entries count as older without a
tag compare), and cleared bit by bit as table entries finish. An entry is held
while a row entry is live and its range is unknown, the entry's own address is
unknown, or the two ranges share a sector; LRs and AMOs are held by every older
live entry. The hold joins the older-AMO bit in one registered per-entry block,
`issue_block_q`, which the issue selector reads in place of the AMO block
(including for the ROB-head entry, since a retired vector store can still be
writing) and which releases a staged entry like the AMO fence does. With the
table idle the hold is always 0.

## Coherent memory interface

The LQ supplies request kind, size and ROB tag to the coherent L1D. Cached
AMOs require effective ROB-head protection before launch. Arming checks the
staged translation, PMA and alignment results independently of that protection.
Address faults complete through the exception path without arming ownership.
Simulation assertions check the captured exception's ROB tag at trap entry.
An atomic fault can release its context only after local or home ownership ends. LR
records its exact physical address and W/D size with a 32-byte reservation set. An ordinary
store or AMO write to that set, or a matching cut, clears the reservation. A
successful cached SC clears it when its tagged write completes. Other SCs
clear it at commit (`i_sc_clear_reservation`). The delayed-response
suppression flag prevents an invalidated LR from recreating it.

The local cut hold blocks L0 hits, forwarding and memory-read launch during
capture. Returned-load observations remain replayable after their LQ rows
are released. Four registered L1D sector holds name the pending store records,
or a selected atomic while the store records are empty. A matching load is
parked until a holder changes. Other rows remain eligible for issue.

## DMA coherence

A DMA agent below the L1D can write memory the core is reading. The wrapper's
[`lq_coherence_port.sv`](../tomasulo_wrapper/coherence/lq_coherence_port.sv)
has three reusable entries (`riscv_pkg::DmaCoherenceLocks`), but the current
hart uses slot 0 for one coordinated invalidation at a time: the L1D's
invalidation cut clears L0 copies and reservations and marks affected loads
for replay before the L1D acknowledges the home. The
[cache library](../../../../lib/cache/README.md) describes the whole write
sequence. The LQ's part, all on 32-byte lines:

- Admission. The port records the L1D's invalidation cut. The wrapper ties
  the port's LQ busy-query and SC-window inputs low; the home orders DMA
  with LR, AMO and SC requests by sector. `o_coh_query_held` reports
  whether the LQ holds anything for the admitted line: an L0 entry at one
  of its dword indices, a cached load or a reservation on it. With nothing
  held and no live observation, the port answers clean and the L1D skips
  the invalidation.
- Launch hold. A staged AMO or LR on an admitted line does not launch until
  the line is released (`i_coh_block_*`). The admitted-line comparison is
  registered, so a newly staged AMO or LR also waits a cycle for its own
  compare. `i_coh_admit_pulse` holds every staged AMO or LR while an admission
  answer is presented and for a cycle after it fires. The home orders a DMA
  write to the same sector before or after the atomic.
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
| Reservation | Kept | Cleared, except for a branch recovered at commit (`i_full_flush` low) |
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
data RAM, and nothing enters `cdb_stage` on a partial-flush cycle. When
several results are ready, `cdb_stage` takes a queued completion first, then
a memory response, a fault, an SQ forward, and an L0 hit.
The payload mux prepares its nonresponse fault arm independently of the
response decision, then selects a response at the final mux unless a queued
completion has priority. This preserves the same capture edge and result.

The completion-valid output is the stage-valid bit gated by `!i_flush_en`.
Partial-flush tag comparisons determine whether the staged result is discarded.
The wrapper's CDB arbiter suppresses full-flush broadcasts.

Bypass eligibility combines response, fault, forwarding and hit sources
independently of payload priority. Entry release applies completion readiness
and queued-result priority after comparing each completion index. With
`FROST_XILINX_PRIMS`, the source summary and each entry's release use one LUT5.
Allocation has priority over freeing, and reset and full flush clear every
valid bit.
Cached response slots each qualify their live entry and AMO kind before
response selection. The uncached tracker supplies its own qualification.

Bypass payloads use the staged address-fault and
forwarding predicates before cut and sector holds. Staged-load capture applies
those holds; responses and queued completions use their own eligibility.
Value, exception and cause match the qualified selections whenever the
completion stage captures them. The coherent cause selection combines queued
completion and bypass causes before the stage capture enable.

A load that faults (misaligned when `i_trap_misaligned_accesses` is set,
outside the physical memory map, an AMO or LR to the device quadrant, or with
a fault the data MMU parked on the entry) never reaches memory. It completes
from the staging register with its cause (a store/AMO cause for an AMO) and
the faulting address, which becomes the trap value. A parked fault comes
first, and the data MMU ranks misalignment and page faults above access
faults; without translation, the access fault (cause 5, or 7 for an AMO)
outranks misalignment.

With `MEM_RESPONSE_ERRORS=1`, a failed R response completes its matching load
with cause 5, or cause 7 for an AMO. It neither installs L0 data, establishes
an LR reservation nor launches an AMO write. Failed AMO writes also report
cause 7. These bus faults report zero as the trap value because the response
owner stores a physical address. Responses for flushed owners drain without
faulting a newer instruction.

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
`lq_l0_cache_8`, `lq_l0_cache_128`, `lq_l0_cache_256` and `lq_l0_cache_512`
test the L0 alone, including a tag-blind `cbo.zero` block clear against every
word's concurrent lookup and fill. The eight-word case covers an L0 whose
entire capacity is one zero block, and
`lq_stale_slot_probe` is a full-core program that drives two partial flushes
and ROB-tag reuse against slow, reordered DDR responses. The wrapper and
router suites (`tomasulo_coherence`, `data_mem_request_router` and others)
check the connected handshakes, and simulation assertions check cached-slot
identity, AMO write stability, the device-read shield, and that every launched
load other than an AMO stays tracked (by the fast tracker or a cached slot)
until its data is valid or a flush removes it. In coverage builds,
[cover points](../../../../../../tests/README.md#cover-points) count corner
cases such as a DMA write that cancels the LR reservation or hits a load in
flight, and the ROB-head load evicting a younger staged load. The L0's cover
points count a response fill that coincides with a DMA or AMO invalidation,
and a store update that takes the RAM port from a fill at another index.

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

A cached response coincident with a `cbo.zero` block invalidation suppresses
both the L0 RAM fill write and its valid bit for every dword in the block.
`test_cached_response_with_zero_block_does_not_fill_l0` exercises all eight
positions and verifies that a response from the adjacent block still fills.
