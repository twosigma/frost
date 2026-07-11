# Load Queue

The LQ tracks every in-flight load from dispatch through memory access
to CDB broadcast. It also owns the L0 data cache, the LR/SC
reservation register, and the AMO read-modify-write path. Loads allocate in
program order at dispatch, with independent slot-1 and slot-2 allocation ports
for 2-wide bundles, and free when their result is broadcast on the CDB.

## What makes loads interesting

The hard part of an OOO load queue is figuring out *when* a load may
issue. The LQ uses conservative disambiguation: a load can't issue
to memory until every older store address is known. If a matching
older store turns up that covers the load's bytes, the LQ pulls the
data from the SQ via store-to-load forwarding and skips memory
entirely — the SQ supplies a memory-image word and a local
`load_unit` instance applies byte/half extraction and sign extension
for integer loads, mirroring the L0 hit path. Otherwise it
checks the L0 cache; on a hit, the result is available the same
cycle, and on a miss it issues to main memory. Main memory is not
uniform: low-BRAM loads return in one cycle, while loads to the
cached (DDR-backed) region complete by handshake with variable
latency — an L1 hit after a few cycles, a miss after a writeback/fill
round trip through the cache hierarchy — and the LQ just consumes the
router's read-valid pulse, so the tiering is invisible here beyond
latency. The single-outstanding `slow_outstanding` gate serializes
cached loads, and a full flush arms the drop-next-response accounting
so an in-flight cached response can never be misattributed to a
post-flush load.

The SQ **forwarding result** register follows a capture-then-kill
contract instead (timing: the flush terms and the commit_en-derived
`sq_commit_check_block` term carried the registered trap/MRET pulse
into every capture bit's D). Its capture enable is the trap-cone-free
`o_sq_check_capture_valid`; a result captured on a flushed or
commit-blocked cycle is structurally unconsumable, because
`sq_check_phase2` advances only from the fully-gated `o_sq_check_valid`
and every consumer of the captured result requires phase-2 lineage plus
`!sq_commit_interlock`, which re-applies the commit block at the
decision point.

The same contract covers the capture's **data** cone: the forwarding
scan's same-cycle committed-store guard consumes trap-cone-free "scan"
commit pulses (`store_queue.i_commit_valid_scan/_scan_2`, built in the
wrapper from the commit-bus pipeline's pre-flush-mask valids). They
differ from the architectural pulses only on the full-flush cycle,
where the scan may treat a squashed store commit as visible — and the
capture of that cycle is unconsumable exactly as above. Architectural
SQ commit consumers (`sq_committed`, `committed_empty`, the
flush-exemption mask) keep the masked pulses.

The AMO **write** phase has the mirror-image protection, but upstream:
a full flush would clear `AMO_WRITE_ACTIVE` while the launched write is
still in flight, orphaning it (memory mutated by a squashed AMO that
then re-executes). Rather than dropping the write here, interrupt
delivery is shielded at the trap unit while an AMO owns the ROB head
(`trap_unit.i_amo_at_head`), so no interrupt flush can land inside the
AMO's [write-launch, commit] window; a sim tripwire in the LQ `$error`s
if any future flush source reaches an active AMO write anyway.

MMIO loads are an additional case. Their reads can have side effects
(clear-on-read registers, status pulses), so they can't be issued
speculatively. The LQ pins MMIO loads to the ROB head — they only
fire when their entry is the oldest in flight.

FP64 loads (FLD) on the 32-bit memory bus need two sequential
accesses, so the entry has a phase bit and the data field is split
lo/hi in the LUTRAM so each phase writes only its half.

## L0 cache

The L0 is a 128-entry direct-mapped cache, filled on memory
response, implemented inside the LQ by [`lq_l0_cache.sv`](lq_l0_cache.sv).
It's a hit-path optimization: loads check it in parallel with SQ
disambiguation, and a hit returns the result the same cycle. Stores
invalidate matching lines on commit (the SQ pulses an invalidate back
to the LQ), and AMO write-completion invalidates the AMO's line too;
both share the single invalidate port. That keeps the cache coherent
without needing a write-through path of its own.

Two things the cache intentionally *doesn't* do:

- **No flush on branch mispredict.** The L0 holds only architectural
  state (committed stores invalidate, loads fill with memory's view),
  so there's nothing speculative to throw away. Leaving cached lines
  hot across mispredict recovery roughly doubles the steady-state hit
  rate on CoreMark (36.5% → 72.4%).
- **No fill from a full-flush-cycle response.** Trap/MRET/FENCE.I full
  flushes keep existing L0 lines hot, but a memory response that arrives
  on the flush cycle is treated as a drained response for a killed load
  and is not allowed to install a new L0 line.
- **No same-cycle fill → lookup bypass.** Forwarding the in-flight
  fill into a same-cycle lookup dragged the back-end flush cone
  (`i_flush_en` → `accept_mem_response` → fill → bypass → hit →
  `o_mem_read_en`) into `data_memory`'s address read pin. A same-cycle
  hit on the just-filled line becomes a one-cycle-delayed hit instead;
  the LUTRAM is current next cycle regardless.

## Issue selection

The parallel issue-selection scan — oldest CDB-ready entry (Phase A),
memory-issue eligibility masks with MMIO/LR/AMO head gating and older-AMO
blocking (Phase B), and the explicit ROB-head priority result — lives in
[`lq_issue_selector.sv`](lq_issue_selector.sv), extracted from
`load_queue.sv`. It exports `issue_cdb_idx` to address the LQ data LUTRAM read,
which stays in `load_queue.sv`.

Older-AMO blocking is decided by ROB-tag age relative to the ROB head, not
by ring position: the sparse queue reuses reclaimed holes after flushes, so
physical position is not allocation order, and a position-based prefix-OR
could let a younger load slip past a pending AMO and read the pre-AMO
memory value. A head AMO is admitted to the head-priority scans whenever
the SQ committed queue is empty — at ROB head everything else in the LQ is
younger (and fenced), so preemption is always safe; this subsumed the old
512-cycle deadlock breaker, which has been removed.

For x3 timing the older-AMO block mask (`blocked_by_amo`) is **registered**
(`blocked_by_amo_phys_q`) so the `lq_rob_tag → age → min-tree → compare` chain
leaves the issue-select → `sq_check` capture-enable cone (the post-opt x3 WNS
limiter). The 1-cycle-stale mask is safe both ways: stale-high only delays a
younger load one cycle, and stale-low is caught live by `older_amo_write_pending`
(below), which blocks issue/forward and releases the staged entry so the scan
re-selects. Over a continuously-valid, addr-valid entry the block is monotonic
(a newly allocated AMO is younger, never older), so no harmful stale-low arises
for an already-selectable entry.

The ROB-head priority scan admits **every** head load class, including MMIO
and LR (only AMO stays gated on the committed queue being empty). The scan
starts at the ring head `head_idx` (`= head_ptr`), not the ROB-head entry's
physical slot, so without head-priority an eligible ROB-head MMIO/LR load can
lose the single `sq_check` staging slot to a ring-earlier younger load; if
that younger load is fenced behind an un-drainable (uncommitted,
non-forwardable) older store it camps there indefinitely and starves the head
(the `call_stress` UART poll-load wedge). Admitting the head is safe and live:
the head is the oldest architectural load, so it can only be fenced by
committed — hence draining — older stores, never by the younger wrong-path
stores that create the hog; `sq_check_replace` evicts the younger staged entry
and the MMIO/LR-only-at-head issue gates keep store→load ordering correct.

## Issue and completion bypasses

Two bypass paths shave a cycle each off the load critical latency:

- **Same-cycle `addr_valid` bypass.** MEM_RS emits a pre-issue
  look-ahead one cycle before the real issue (`o_pre_issue_rob_tag` +
  `o_pre_issue_needs_lq`); the LQ pre-registers the CAM match against
  that tag so the entry appears addr-valid the same cycle MEM_RS issues
  (`entry_addr_valid_now`). Removes the flop between RS issue and SQ
  disambiguation.
- **`cdb_stage` completion bypass.** On a memory response, L0
  fast-path hit, or SQ forward, the LQ writes `cdb_stage` directly
  from the response / cache / forward data path instead of routing
  through `lq_data_valid` + a priority encoder. The entry frees and
  the CDB broadcast arms the same cycle. AMOs stay on the standard
  path, as do two-phase memory FLDs — but a *forwarded* FLD bypasses,
  since the SQ delivers its full 64-bit payload in a single probe.

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

AMO writes are invisible to SQ disambiguation (AMOs never allocate SQ
entries), so the LQ enforces their ordering itself: the AMO write fence
(`older_amo_write_pending`) holds any staged load younger than an AMO that
has not yet completed its memory write (`lq_data_valid` for an AMO covers
read + write). The fence blocks launch, SQ forwarding, and the L0 fast
path, and a fenced staged load releases SQ-check staging instead of
camping so the head AMO reaches the memory port immediately. A staged head
AMO itself issues without waiting for younger stores' addresses
(`sq_head_amo_clear`) — with the committed queue empty no older SQ store
can exist.

## Storage strategy

Hybrid FF + LUTRAM. The per-entry 1-bit control flags, `rob_tag`, and
`size` need parallel CAM-style scan (tag match on address update,
oldest-first issue selection, partial flush invalidation), so they
stay in flip-flops. The wider per-entry payloads ride in distributed
RAM, read only after their valid bit is set: the address (single-port
LUTRAM, replicated for the memory-issue and AMO read ports), the AMO
`rs2` operand (single-port), and the AMO op (2-write-port LUTRAM for
the slot-1/slot-2 alloc ports). The address-update CAM matches against
`rob_tag`, not the address itself; the resolved address is then written
into the address LUTRAM.

The 64-bit load-result payload lives in its own distributed RAM split
lo/hi (to support FLD's two-phase fills), each half in a 2-write-port
LUTRAM: port 0 is reserved for memory response, port 1 handles cache
hits, SQ forwards, and AMO write-completion. The split lets a memory
response for the previously-issued load and a cache hit on the
newly-captured load land in the same cycle without colliding.

Allocation metadata has separate slot-1 and slot-2 write paths. When both slots
allocate loads, slot 1 takes the older free entry and slot 2 takes the next free
entry; when only slot 2 is a load, it takes the first free entry.

## Performance counters

The LQ emits pulses for the wrapper's performance counters so the
head-load wait bucket — historically a large fraction of CoreMark
idle time — can be attributed. L0 hits and fills are counted
directly; the head-load wait is split into five sub-buckets
(`addr_pending`, `sq_disambig`, `bus_blocked`, `cdb_wait`, `post_lq`)
and the `bus_blocked` bucket is further split into five mutually
exclusive causes (`bb_issued`, `bb_bus_busy`, `bb_amo`, `bb_sq_wait`,
`bb_staging`). The `bb_staging` catch-all is itself decomposed into
four mutually exclusive sub-causes (`bbs_other_in_staging`,
`bbs_launch_gated`, `bbs_slow_outstanding`, `bbs_capture_gap`).
The wrapper parent counter `head_wait_mem_load` is
still live alongside the decomposition.

## Verification

Cocotb tests cover allocation including slot-2-only and paired slot-1/slot-2
cases, address update, every load size, SQ forwarding, MMIO ordering, FLD
two-phase, FLW NaN-boxing, partial and full flush, AMO read-modify-write,
LR/SC reservation, and constrained-random stress. Inline formal properties prove
pointer invariants, issue prerequisites, MMIO ordering, and flush behavior.
