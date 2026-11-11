# Store Queue

The SQ holds stores from dispatch until they are written to memory. It has
eight entries (`riscv_pkg::SqDepth`) and two allocation ports. Stores write
cached memory after commit, in program order. With `PRECISE_UNCACHED=1`
(as in `cpu_top`), Device and strict uncached stores execute at the ROB head
with the interrupt and debug shield armed, and retire only after the AXI B
response. `CACHE_NORMAL_MEMORY=1` permits ordinary stores to the configured
Normal read-cache region to commit before draining as narrow write-through
transactions. SC and debug-page stores remain precise. The SQ also answers
the load queue's store-to-load forwarding checks.

A cached or buffered Normal entry is allocated, receives its address/data,
commits, writes memory and frees. A precise entry waits at the ROB head, writes memory, then sends
a successful or faulting completion to the ROB; it never launches speculatively.

## Store-to-load forwarding

Before a load reads memory, the LQ asks the SQ whether an older store overlaps
it. The scan, in [`sq_forwarding_unit.sv`](sq_forwarding_unit.sv), works at
dword granularity, following the
[data-tier bus contract](../../../../README.md#data-tier-bus-contract): two
accesses conflict when they fall in the same aligned dword and their byte
masks intersect.

| Outcome | When | The load then |
|---------|------|---------------|
| Forward | The newest conflicting older store covers every byte the load reads and has its data | Takes the store's aligned-dword image and extracts its bytes, as for a memory response |
| Wait | That store covers only some of the bytes or has no data yet, or an older store's address is unknown | Checks again later |
| No conflict | No older store overlaps | Reads the L0 cache or memory |

The result is registered: the LQ sees it one cycle after presenting the
check (`i_sq_check_capture_valid`).

Two ordering rules decide which stores count:

- A store is older than the load by ROB-tag age, and a committed store is
  always older.
- Among conflicting stores, the newest is decided by ring position (allocation
  order), not by ROB-tag age. A committed store can still be waiting to drain
  after its ROB tag has been reused, and tag age would then rank it newest and
  forward stale data.

MMIO stores and store-conditionals never forward. An SC can fail and write
nothing, so a load behind it waits for the SC to drain and then reads memory.
A cbo.zero entry conflicts with every load in its 64-byte block, whatever
the load's bytes, and never forwards: the load waits until the block's write
frees the entry, then reads the zeros from memory. A younger store
covering the load still forwards over the older block.

On a full-flush cycle the scan can treat a squashed store's commit as visible.
This is harmless because the LQ discards any forwarding result captured on a
full-flush cycle (see the [load queue](../load_queue/README.md)). Committed-state
tracking uses the flush-masked commit pulses.

## Allocation and capacity

Stores always allocate at the tail: slot 1, or slot 2 on its own, takes the
tail entry, and slot 2 takes the next one when both slots allocate. Ring order
is therefore program order. The SQ never refills a hole left by a discarded
SC, because a younger store would then drain before an older one. The hole
holds its capacity until the head passes it.

Dispatch uses the registered `o_dispatch_full` and `o_dispatch_full_for_2`
flags. They count this cycle's allocations but give no credit for this cycle's
drains, flushes, or SC discards, so they err only on the side of stalling;
early credit would let dispatch send a store the SQ cannot accept. `o_full`
and `o_full_for_2` give the exact combinational status, and a separate counter
drives `o_count` and `o_empty`.

Addresses arrive from the early-address pipeline or from MEM_RS issue, and
data from MEM_RS issue, matched to entries by ROB tag. If both address sources
update an entry in the same cycle, the MEM_RS update wins. With translation on,
an early address is captured only together with a successful translation.

A payload can be written before its valid bit is set: the early-address
pipeline keeps refreshing a waiting store's address until its base register
resolves. Forwarding and the drain read a payload only after its valid bit is
set.

## Draining to memory

A drain cursor points at the oldest entry not yet sent. It launches when that
entry is eligible and has its address and data, and it never skips ahead.
Cached and buffered Normal entries require commit; precise uncached entries require ROB-head
permission and the shield.
Entry, ordering and FIFO checks prepare launch and cursor completion before
coherent store credit arrives. Credit qualifies the cached arm last.
Each stored address is classified in parallel with cursor selection. Aligned
power-of-two cached regions use a mask comparison; other maps retain the
general range comparison, including empty or wrapping ranges.
Each entry prepares its cached serial, uncached serial, buffered overlap and
precise serial decisions independently of its address class. The cursor and
entry-specific conditions are included before the class bits select those decisions.
A precise uncommitted entry is uncached and cannot use buffered overlap, so
its permission does not pass through the overlapping launch checks. Shared
ROB-head permission and shield checks qualify the precise arm after its
per-entry decisions have been reduced. Uncached
completion includes the last-beat decision before address classification;
every cached launch completes its entry. These are the same launch and
completion conditions with no added state or cycles.
Every store is a single 64-bit beat: sub-dword data is replicated across the
beat and the byte strobe selects the lanes. A `cbo.zero` entry keeps `rs1`
as its address. A cached block drains as one write at the naturally aligned
block base, with zero data, every strobe set and `o_coherent_write_zero`, which
the L1D takes as the whole block (see the
[cache library](../../../../lib/cache/README.md#line-scope-cbozero)); its
launch invalidates the block's eight L0 dwords (`o_cache_invalidate_block`)
and clears an LR reservation on either sector, and its completion frees the
entry. An uncached (BRAM) block drains as eight zero beats with every strobe
set, at the block base plus 0, 8, ... 56. Its entry stays the drain cursor
through all eight launches; each beat takes a completion-FIFO slot and
invalidates its L0 dword, and only the eighth beat's completion frees the
entry. The beat counter prepares its local next value before coherent credit
selects advance or hold. Its fixed-width increment wraps after the eighth
uncached beat; a cached zero write restarts it immediately.
A precise uncached block reports its completion, and any beat's error,
with the eighth response. The write outputs are registered,
including `is_mmio` and `is_cached` flags that let the memory router steer the
write without decoding the address again. `o_mem_write_buffered` identifies
an ordinary Normal store that has already retired; this distinguishes its
late fatal AXI error from a precise SC/AMO failure. Launching a write also
invalidates its L0 dword, or updates its selected bytes when the optional
Normal read-cache policy applies.

With `PRECISE_UNCACHED=0`, plain BRAM stores complete one
cycle after launch with up to two writes in flight. In `cpu_top`, every
Normal/Device store keeps its SQ entry until B. A precise store's
SLVERR/DECERR becomes cause 7; successful SC completion is likewise delayed
until B. A failed buffered Normal store retains ownership and raises the
tile's fatal indication. Completions carry no tag,
so the memory side must return them in launch order: each one frees the
oldest in-flight write. A cached or MMIO store
launches only when no other write is in flight, and nothing else launches until
it completes. A cached write completes once the L1D has ordered it, so a store
miss does not hold up the drain for the line fill.

Cached ordinary stores complete when captured in one of the L1D's four ordered
sector records. Each scalar receives an acknowledgement, including scalars
that combine with the youngest unsealed record. Available launch credit permits
another cached ordinary store while accepted bytes await installation.
Aggregate pending covers all four records in
committed-empty and fence, Device, trap and serializer drains. Normal/MMIO
writes and SC wait for every buffered ordinary store to install. Cached SC
writes carry their selected ROB tag and complete only after the conditional
cache update. The selected context
blocks younger retirement through that write, including flush-producing
instructions.

An entry is freed when its write completes, not when it launches, and stays
visible to forwarding until then.

## Commit and flush

Cached and buffered Normal stores commit through two ports, one per ROB
commit slot. Precise uncached stores report completion before retirement
and free their SQ owner after B. Slot 2 retires only
plain stores; the ROB keeps SCs and AMOs on slot 1. The committed-empty
base status is a register, with copies for its distant consumers (the ROB,
the trap unit, and the LQ). Each output is qualified with
pending ordinary stores, the selected SC write and the registered cached
write strobe. Each commit port has a combinational copy
(`i_commit_valid_comb*`) that feeds it directly, so the status turns
non-empty at the edge that ends the commit cycle, when the registered commit
arrives, and a fence, SC, trap, or device read never sees an empty committed
queue while a just-committed store is still on its way in.

A partial flush removes uncommitted stores younger than the flush point; the
commit-time recovery flush removes all uncommitted stores. Committed stores
survive both, and the tail moves back over the removed entries one cycle
later. The flush also spares entries that match the registered commit ports,
whose committed bits are not yet set. The core does not depend on that guard:
no store retires in the cycle before either flush, and the ROB never commits
in a flush cycle.

A full flush (trap, xRET, or FENCE-class recovery) empties the SQ. Those events
first wait for committed stores to drain, so no committed write is lost.

Allocation requests in a flush cycle are dropped, as the ROB drops them.
Dispatch can present one on a trap cycle because the front-end kill arrives a
cycle late; accepting it would leave an entry for a ROB tag that was never
allocated. In the following cycle, while the tail moves back, dispatch must
not allocate at all. The SQ does not block this itself; the front end's
refill delay after a flush guarantees it, and a simulation check flags any
violation.

When a store-conditional fails, the ROB signals an SC discard and the SQ drops
the entry without writing memory. The LR reservation lives in the LQ.

## Storage

Control fields are flip-flops, because the address CAM, the forwarding scan,
and flushes read every entry at once. Store data lives in a LUTRAM read by the
drain, plus a per-entry flip-flop copy read by the forwarding path. The LQ
sends four identical copies of the check address (`i_sq_check_addr` and
`_b`, `_c`, `_d`), each compared against two entries.

## Verification

The `store_queue` cocotb target covers two-wide allocation, updates,
forwarding, pipelined drain, flushes, and SC discard. Inline formal properties
check live-count consistency, write prerequisites, in-flight bounds,
forwarding, and that committed stores survive a partial flush.

See the [test runner](../../../../../../tests/README.md) for commands and the
[formal guide](../../../../../../formal/README.md) for proof scope and assumptions.
