# Load Queue

The LQ tracks every in-flight load from dispatch through memory access
to CDB broadcast. It also owns the L0 data cache, the LR/SC
reservation register, and the AMO read-modify-write path. Loads
allocate in program order at dispatch and free when their result is
broadcast on the CDB.

## What makes loads interesting

The hard part of an OOO load queue is figuring out *when* a load may
issue. The LQ uses conservative disambiguation: a load can't issue
to memory until every older store address is known. If a matching
older store turns up, the LQ pulls the data from the SQ via
store-to-load forwarding and skips memory entirely. Otherwise it
checks the L0 cache; on a hit, the result is available the same
cycle, and on a miss it issues to main memory.

MMIO loads are an additional case. Their reads can have side effects
(clear-on-read registers, status pulses), so they can't be issued
speculatively. The LQ pins MMIO loads to the ROB head — they only
fire when their entry is the oldest in flight.

FP64 loads (FLD) on the 32-bit memory bus need two sequential
accesses, so the entry has a phase bit and the data field is split
lo/hi in the LUTRAM so each phase writes only its half.

## L0 cache

The L0 is a 128-entry direct-mapped write-through cache, preserved
from the in-order core but moved inside the LQ. It's a hit-path
optimization: loads check it in parallel with SQ disambiguation, and
a hit returns the result the same cycle. Stores invalidate matching
lines on commit (the SQ pulses an invalidate back to the LQ), which
keeps the cache coherent without needing a write-through path of its
own.

Two things the cache intentionally *doesn't* do:

- **No flush on branch mispredict.** The L0 holds only architectural
  state (committed stores invalidate, loads fill with memory's view),
  so there's nothing speculative to throw away. Leaving cached lines
  hot across mispredict recovery roughly doubles the steady-state hit
  rate on CoreMark (36.5% → 72.4%).
- **No same-cycle fill → lookup bypass.** Forwarding the in-flight
  fill into a same-cycle lookup dragged the back-end flush cone into
  `data_memory`'s write-enable path. A same-cycle hit on the just-filled
  line becomes a one-cycle-delayed hit instead; the LUTRAM is current
  next cycle regardless.

## Issue and completion bypasses

Two bypass paths shave a cycle each off the load critical latency:

- **Same-cycle `addr_valid` bypass.** MEM_RS emits a pre-issue
  look-ahead one cycle before the real issue (`o_pre_issue_rob_tag` +
  `o_pre_issue_needs_lq`); the LQ pre-registers the CAM match against
  that tag so the entry appears addr-valid the same cycle MEM_RS issues
  (`entry_addr_valid_now`). Removes the flop between RS issue and SQ
  disambiguation.
- **`cdb_stage` completion bypass.** On a memory response or L0
  fast-path hit, the LQ writes `cdb_stage` directly from the response /
  cache data path instead of routing through `lq_data_valid` + a
  priority encoder. The entry frees and the CDB broadcast arms the
  same cycle. AMO and FLD stay on the standard path.

## Back-to-back issue

In steady state the LQ issues one load per cycle: `launch_mem_issue`
is gated only by `i_mem_bus_busy` (not the previous launch's
`mem_outstanding`). Making this work without dropping results required
five coupled pieces — the priority encoder masks out the entries
already in-flight, SQ-check capture fires the same cycle the previous
candidate launches, and `lq_data` port 0 is reserved for the memory
response while port 1 handles cache hits / SQ forwards / AMO writes
(they can't collide on the same port anymore).

## Issued-entry snapshot

The response handler reads from a flat snapshot of the issued load's
attributes (addr / size / FP / LR / AMO / MMIO / sign_ext / fp64_phase /
rob_tag) captured at launch, not from the per-entry LUTRAMs indexed by
`issued_idx`. Removing the `lq_*[issued_idx]` read path takes the LQ
entry array out of the `data_memory` address cone.

## Atomics

The LR reservation register lives in the LQ. LR sets it on
completion; SC clears it; any SQ write to the reserved address
clears it via a snoop. SC succeeds if the reservation is still valid
when SC reaches the ROB head. AMO uses a separate memory write port
on the LQ for the write half of the read-modify-write — the AMO
fires from the ROB head with the SQ committed-empty so nothing else
can interleave.

## Storage strategy

Hybrid FF + LUTRAM. Control fields and the address need parallel
CAM-style scan (for tag match on address update, oldest-first issue
selection, partial flush invalidation), so they stay in flip-flops.
The 64-bit data payload lives in distributed RAM split lo/hi (to
support FLD's two-phase fills), each half in a 2-write-port LUTRAM:
port 0 is reserved for memory response, port 1 handles cache hits,
SQ forwards, and AMO write-completion. The split lets a memory
response for the previously-issued load and a cache hit on the
newly-captured load land in the same cycle without colliding.

## Performance counters

The LQ emits pulses for the wrapper's performance counters so the
head-load wait bucket — historically a large fraction of CoreMark
idle time — can be attributed. L0 hits and fills are counted
directly; the head-load wait is split into five sub-buckets
(`addr_pending`, `sq_disambig`, `bus_blocked`, `cdb_wait`, `post_lq`)
and the `bus_blocked` bucket is further split into five mutually
exclusive causes (`bb_issued`, `bb_bus_busy`, `bb_amo`, `bb_sq_wait`,
`bb_staging`). The wrapper parent counter `head_wait_mem_load` is
still live alongside the decomposition.

## Verification

Cocotb tests cover allocation, address update, every load size,
SQ forwarding, MMIO ordering, FLD two-phase, FLW NaN-boxing, partial
and full flush, AMO read-modify-write, LR/SC reservation, and
constrained-random stress. Inline formal properties prove pointer
invariants, issue prerequisites, MMIO ordering, and flush behavior.
