# Load Queue

The LQ tracks every in-flight load from dispatch through memory access
to CDB broadcast. It also owns the L0 data cache, the LR/SC
reservation register, and the AMO read-modify-write path. Loads allocate in
program order at dispatch, with independent slot-1 and slot-2 allocation ports
for 2-wide bundles, and free the cycle their result is captured into
`cdb_stage`, one or more cycles ahead of the actual CDB broadcast.

## Design overview

The hard part of an OOO load queue is deciding *when* a load may
issue. The LQ uses conservative disambiguation: a load can't issue
to memory until every older store address is known. If a matching
older store turns up that covers the load's bytes, the LQ pulls the
data from the SQ via store-to-load forwarding and skips memory
entirely — the SQ supplies the aligned-dword memory image and a local
`load_unit` instance applies word/half/byte extraction and sign
extension for integer loads, mirroring the L0 hit path. Otherwise it
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
fire when their entry is the oldest in flight — and, like AMOs, they
additionally wait for the SQ's existing `o_committed_empty` status. A
committed MMIO store's effect exists only at the device until it drains, and
address-based disambiguation cannot order the pair when the device aliases
one register behind two addresses (the SiFive CLINT window). On the cached
tier the drain can lag commit by write-port arbitration, so ROB-head alone is
not enough. Waiting for the full committed queue is conservative: unrelated
older committed BRAM/cached stores can delay the MMIO load too, but the rule
adds no second SQ-wide reduction or status path. Once the load is at the ROB
head, its side-effect-free SQ probe and phase-2 preparation may run while that
queue drains. A physically isolated final gate holds the memory-read pulse
until `o_committed_empty` is true. A misalignment exception may complete
inside the LQ earlier because it performs no device access; the trap unit's
independent committed-store drain gate still prevents architectural trap entry
until the queue is empty.

Known open gap (surfaced by an independent review of the drain gate,
2026-08-15): the MMIO read pulse is irrevocable at launch, but an interrupt
can be taken between an MMIO load's launch and its commit; the flush kills
the load and the handler's `mret` re-executes it — a duplicate device read,
destructive for clear-on-read/FIFO-pop registers (UART RX, FIFOs). AMOs are
protected by the trap unit's AMO interrupt shield (`i_amo_at_head`); MMIO
loads need the analogous shield covering launch through head advance, plus a
directed test. No test currently hits this window; recorded here pending a
dedicated fix.

Dword loads (FLD and RV64 LD) complete through the same size-keyed path in a
single beat: the 64-bit data tier
([docs/rv64/m1_data_tier.md](../../../../../docs/rv64/m1_data_tier.md))
returns the aligned dword at `addr[31:3]` and the entry's FLEN-wide
data slot captures it whole. The old 32-bit-bus two-phase FLD machinery
(per-entry phase bit, split lo/hi data halves, `+4` re-issue) is gone.

The per-entry AMO opcode is compacted from the 8-bit `instr_op_e` to a 4-bit
semantic code and stored in per-entry FFs. Accepted slot-1 and slot-2
allocations first capture their distinct index/code pairs in a one-cycle write
stage, so late allocation enables do not fan into the per-entry write decoder.
The accepted bits are staged too, ensuring an unaccepted candidate cannot
write when its candidate index aliases an accepted allocation. This delay is
hidden by the required address-update and SQ-check phases before an AMO can
issue. The staged indexed writes need neither replicated RAM banks nor a
live-value table. The selected code and `rs2` are snapshotted at AMO read
launch alongside the issued address. At response, SWAP/ADD/XOR/AND/OR produce
a registered, comparator-free result. MIN/MAX instead register the exact
old-versus-`rs2` selection predicate plus both held operands and a narrow
MIN/MAX identity bit; `.W` compares the low 32 bits (signed or unsigned as
specified) even on RV64, while `.D` compares all 64 bits. `AMO_WRITE_ACTIVE`
starts on the next cycle exactly as before and selects the MIN/MAX operand with
one shallow register-fed mux; other operations use the normal result register.
Thus neither the queue select nor a compare-carry-to-wide-result cone reaches
the memory BRAM's write pins, and memory-side stalls hold the entire request
until `write_done` without changing AMO latency. Payload capture is explicitly
`AMO_IDLE`-qualified as a local invariant, so even an invalid overlapping
response cannot overwrite a stalled active request.

## L0 cache

The L0 is a 128-entry direct-mapped cache with dword-granule (aligned
8-byte) lines, filled one full beat per memory response, implemented
inside the LQ by [`lq_l0_cache.sv`](lq_l0_cache.sv).
It's a hit-path optimization: loads check it in parallel with SQ
disambiguation, and a hit returns the result the same cycle — every
load size is eligible, including FLD (the line carries the whole
dword). Stores invalidate their containing dword line on commit (the
SQ pulses an invalidate back to the LQ), and AMO write-completion
invalidates the AMO's line too; both share the single invalidate
port. That keeps the cache coherent without needing a write-through
path of its own.

Three things the cache intentionally *doesn't* do:

- **No flush on branch mispredict.** The L0 holds only architectural
  state (committed stores invalidate, loads fill with memory's view),
  so there's nothing speculative to throw away. Leaving cached lines
  hot across mispredict recovery roughly doubles the steady-state hit
  rate on CoreMark (36.5% → 72.4%). For the same reason, an ordinary
  non-MMIO response that arrives exactly with a partial flush may still
  fill L0 even when its killed LQ owner discards the completion. Full
  flushes, already-pending stale-response drains, LR/AMO responses, and
  responses made stale by a store/AMO invalidation remain ineligible.
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

Older-AMO blocking uses an exact registered physical dependency bitmap, not
ring position: the sparse queue reuses reclaimed holes after flushes, so a
position-based prefix-OR could let a younger load slip past a pending AMO and
read the pre-AMO memory value. Row `i` records the still-pending AMO slots that
are architecturally older than entry `i`. A one-cycle mirror of the physical
valid bits detects each newly-live generation; its ROB-tag comparisons update
only the bitmap FFs, while completion, flush, and physical-slot reuse
permanently prune the old source identity. A separate registered row reduction
drives the selector directly, removing the former live `ROB head → age
subtractors → min tree → compares` cone from both issue selection and
`sq_check` capture.

The allocation stage supports both ports and compares tags rather than
assuming physical or request order, including sparse/adversarial tag layouts.
Legal allocation comes from the ROB tail, so a newly allocated AMO cannot be
older than an entry already resident in `sq_check`; the registered update is
therefore complete before that entry can need a new dependency. A head AMO is
admitted to the head-priority scans whenever the SQ committed queue is empty —
at ROB head everything else in the LQ is younger (and fenced), so preemption is
always safe; this subsumed the old 512-cycle deadlock breaker, which has been
removed.

The sparse allocator's `tail_ptr` is only a free-search cursor, not occupancy or
age state. It advances when the registered valid-generation detector observes
the prior cycle's allocation. The newly valid entries already make a
back-to-back search skip those slots, so the one-cycle cursor lag changes only
the next physical search origin: allocation capacity and two-wide throughput
are unchanged.

The ROB-head priority scan admits **every** head load class, including MMIO
and LR (AMOs are additionally admitted only when the committed queue is
empty). The normal stored-address scan redundantly admits an MMIO entry only
when it is also at the ROB head; the dedicated head result always wins the
final selector, so this restores the prior Boolean shape without changing
selection or cycle timing. A same-cycle address update may still stage an MMIO
load before it reaches the head. In every case, the
downstream final-effect gate holds the memory launch until the full committed
queue becomes empty; SQ disambiguation itself may run early because it has no
device or architectural side effect. A no-read misalignment completion can
also run early, while architectural trap entry remains protected by the trap
unit's drain gate. The scan starts at the ring head
`head_idx` (`= head_ptr`) rather than at the ROB-head entry's physical slot,
so without head-priority an eligible ROB-head MMIO/LR load can
lose the single `sq_check` staging slot to a ring-earlier younger load; if
that younger load is fenced behind an un-drainable (uncommitted,
non-forwardable) older store it camps there indefinitely and starves the head
(the `call_stress` UART poll-load wedge). Admitting the head is safe and live:
the head is the oldest architectural load, so it can only be fenced by
committed — hence draining — older stores, never by the younger wrong-path
stores that create the hog; `sq_check_replace` evicts the younger staged entry
and the MMIO/LR-only-at-head issue gates keep store→load ordering correct.

The registered ROB-head match is one-hot because live ROB tags are unique.
Head eligibility preserves that one-hot physical-entry mask through selection
and exports it directly to the `sq_check` capture controller. The found bit is
a reduction of the eligible mask, while index and tag are encoded in parallel
from the registered head-match mask before eligibility. There is no serial
physical-entry priority scan and no index-to-one-hot decode on the capture
feedback path. This is cycle-identical to the old scan while keeping
`lq_addr_valid` out of both the payload-identity encoder and its old long
priority ripple.

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
  path, as do DOUBLE-size memory responses; L0-hit and forwarded FLDs
  bypass (both deliver the full 64-bit payload in a single probe).

## Back-to-back issue

In steady state the LQ issues one load per cycle: the historical
`launch_mem_issue_attempt` cone is gated only by the flush pulses,
`i_mem_bus_busy`, and the cached-tier `slow_outstanding` bit, not by the
previous launch's `mem_outstanding`. The actual read pulse adds one explicit
terminal LUT that blocks MMIO while committed stores drain. Making
back-to-back issue work without dropping results required three coupled pieces
— the priority encoder masks out entries already in flight, SQ-check capture
fires the same cycle the previous candidate attempts to launch, and `lq_data`
port 0 is reserved for the memory response while port 1 handles cache hits / SQ
forwards / AMO writes (they can't collide on the same port anymore).

## Issued-entry snapshot

The response handler reads from a flat snapshot of the issued load's
attributes (addr / size / FP / LR / AMO / MMIO / sign_ext / rob_tag), not from
the per-entry LUTRAMs indexed by `issued_idx`. Only an accepted memory-read
pulse captures the snapshot and sets its issued/outstanding validity state; a
terminally blocked MMIO attempt cannot overwrite an older fast response's
identity. Removing the `lq_*[issued_idx]` read path takes the LQ entry array out
of the `data_memory` read-address cone. The AMO-only operation and `rs2` fields
are captured with the same snapshot; the response edge consumes only those
values and the returned old value before the serialized write phase. For
MIN/MAX the wide comparison terminates at a one-bit predicate FF; the active
write phase holds old/`rs2` locally and performs only the final mux.

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
stay in flip-flops. The compact 4-bit AMO operation code also stays in
per-entry FFs; a one-cycle request stage accepts both distinct allocation
writes without putting their live enables on the per-entry decoder. The wider
per-entry payloads ride in distributed RAM, read only after their valid bit is
set: the address and the AMO `rs2` operand (both single-port). AMO launch
snapshots the exact issued address plus the operation and `rs2`, so the
response side needs no extra queue read port. The address-update CAM
matches against `rob_tag`, not the address itself; the resolved address is then
written into the address LUTRAM.

The 64-bit load-result payload lives in one FLEN-wide 2-write-port
LUTRAM: port 0 is reserved for memory response, port 1 handles cache
hits, SQ forwards, and AMO write-completion. The two ports let a memory
response for the previously-issued load and a cache hit on the
newly-captured load land in the same cycle without colliding. DOUBLE
loads store the full beat; every other load stores its extracted (or,
for FLW, addressed-word) value zero-extended, with NaN-boxing applied
at CDB broadcast.

Allocation metadata has separate slot-1 and slot-2 write paths. When both slots
allocate loads, slot 1 takes the older free entry and slot 2 takes the next free
entry; when only slot 2 is a load, it takes the first free entry.

Both alloc enables carry the ROB's flush gate (`!i_flush_all &&
!i_flush_en`): dispatch presents alloc requests un-flush-gated (on
trap/MRET/FENCE.I pulse cycles a straggler's fire legitimately
coincides with the flush), so the LQ must reach the ROB's reject verdict on
the same cycle. Without the gate, a partial-flush-cycle alloc wrote a ghost
entry: the alloc arm runs after the invalidate loop in the same `always_ff`
(last-write-wins), leaving a valid entry whose tag the ROB never allocated —
a slot leak, then a duplicate-tag pair once the rewound tail re-issued the
tag.

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
cases, address update, every load size, SQ forwarding, MMIO ordering,
single-beat FLD, FLW NaN-boxing, partial and full flush, AMO read-modify-write,
LR/SC reservation, and constrained-random stress. Inline formal properties prove
pointer invariants, issue prerequisites, MMIO ordering, and flush behavior.
