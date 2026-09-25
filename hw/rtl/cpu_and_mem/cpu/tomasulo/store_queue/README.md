# Store Queue

The SQ holds stores from dispatch until they are written to memory. It has
eight entries (`riscv_pkg::SqDepth`) and two allocation ports. Stores write
memory only after they commit, in program order, so no store reaches the bus
speculatively. The SQ also answers the load queue's store-to-load forwarding
checks.

An entry's life: allocate at dispatch → receive address and data → commit →
write memory → free.

## Store-to-load forwarding

Before a load reads memory, the LQ asks the SQ whether an older store overlaps
it. The scan, in [`sq_forwarding_unit.sv`](sq_forwarding_unit.sv), works at
dword granularity, following the
[data-tier bus contract](../../../../README.md#data-tier-bus-contract): two
accesses conflict when they fall in the same aligned dword and their byte
masks intersect.

| Outcome | When | The load then |
|---------|------|---------------|
| Forward | The newest conflicting older store covers every byte the load reads | Takes the store's aligned-dword image and extracts its bytes, as for a memory response |
| Wait | That store covers only some of the bytes, or an older store's address is unknown | Checks again later |
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
entry is committed and has its address and data, and it never skips ahead.
Every store is a single 64-bit beat: sub-dword data is replicated across the
beat and the byte strobe selects the lanes. The write outputs are registered,
including `is_mmio` and `is_cached` flags that let the memory router steer the
write without decoding the address again. Launching a write also invalidates
the store's line in the load queue's L0 cache.

Plain BRAM stores complete one cycle after launch, so a backlog of them drains
at one per cycle, with up to two writes in flight. Completions carry no tag,
so the memory side must return them in launch order: each one frees the
oldest in-flight write. A cached or MMIO store
launches only when no other write is in flight, and nothing else launches until
it completes. A cached write completes once the L1D has ordered it, so a store
miss does not hold up the drain for the line fill.

An entry is freed when its write completes, not when it launches, and stays
visible to forwarding until then.

## Commit and flush

Stores commit through two ports, one per ROB commit slot. Slot 2 retires only
plain stores; the ROB keeps SCs and AMOs on slot 1. The committed-empty
status is a register. Each commit port has a combinational twin
(`i_commit_valid_comb*`) that feeds it directly, so the status turns
non-empty at the edge that ends the commit cycle, when the registered commit
arrives, and a fence, SC, trap, or device read never sees an empty committed
queue while a just-committed store is still on its way in.

A partial flush removes uncommitted stores younger than the flush point; the
commit-time recovery flush removes all uncommitted stores. Committed stores
survive both, and the tail moves back over the removed entries one cycle
later. A flush can arrive one cycle after a store's commit pulse, before the
entry's committed bit is set, so the flush also spares entries that match the
registered commit ports. The ROB never commits in a flush cycle.

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
sends four identical copies of the check address (`i_sq_check_addr` and its
`_b`, `_c`, `_d` twins), each compared against two entries, to keep the compare
logic local.

## Verification

The `store_queue` cocotb target covers two-wide allocation, updates,
forwarding, pipelined drain, flushes, and SC discard. Inline formal properties
check live-count consistency, write prerequisites, in-flight bounds,
forwarding, and that committed stores survive a partial flush.

See the [test runner](../../../../../../tests/README.md) for commands and the
[formal guide](../../../../../../formal/README.md) for proof scope and assumptions.
