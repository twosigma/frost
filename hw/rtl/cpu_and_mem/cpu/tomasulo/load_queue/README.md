# Load Queue

The LQ tracks loads from dispatch through CDB staging and owns the L0 cache,
LR/SC reservation, and AMO read-modify-write path. Two ports allocate in
program order. Entries free when their result enters `cdb_stage`, before its
CDB broadcast.

## Design overview

The LQ uses conservative disambiguation: a load cannot issue to memory until
every older store address is known. If an older store covers the load's bytes,
the LQ takes the data from the SQ by store-to-load forwarding and skips memory.
The SQ supplies the aligned-dword memory image and a local `load_unit` instance
applies word/half/byte extraction and sign extension for integer loads,
mirroring the L0 hit path. Otherwise the LQ checks the L0 cache. Hits return in
the same cycle; misses issue to memory. Low-BRAM loads return in one cycle.
Loads to the cached (DDR-backed) region complete by handshake with variable
latency: an L1 hit after a few cycles, a miss after a writeback/fill round trip
through the cache hierarchy. The LQ consumes the router's read-valid pulse. Up
to `riscv_pkg::CachedLoadSlots` (4) cached loads are in flight at once, each in
a slot whose id tags the request and its response; responses may return in any
order. MMIO stays on the fixed fast response path after terminal accept, but
every device handoff first spends one cycle in the router's pending register
and one further cycle arming behind the device-read interrupt shield, and may
wait longer while committed stores drain. That pending Q feeds directly back
into the wrapper's LQ bus-busy gate. On full flush it also distinguishes a
still-unaccepted request, which the router cancels without response debt, from
an accepted request whose coincident response must be drained or whose delayed
response must remain owed.

The SQ forwarding result register follows a capture-then-kill contract: it is
captured first and killed afterwards rather than gated at capture. Gating at
capture cost timing, because the flush terms and the commit_en-derived
`sq_commit_check_block` term carried the registered trap/MRET pulse into every
capture bit's D. Its capture enable is the trap-cone-free
`o_sq_check_capture_valid`. A result captured on a flushed or commit-blocked
cycle cannot be consumed, because `sq_check_phase2` advances only from the
fully-gated `o_sq_check_valid`, and every consumer of the captured result
requires phase-2 lineage plus `!sq_commit_interlock`, which re-applies the
commit block at the decision point.

The same contract covers the capture's data cone. The forwarding scan's
same-cycle committed-store guard consumes trap-cone-free "scan" commit pulses
(`store_queue.i_commit_valid_scan/_scan_2`), which the wrapper builds from the
commit-bus pipeline's pre-flush-mask valids. They differ from the architectural
pulses only on the full-flush cycle, where the scan may treat a squashed store
commit as visible, and the capture of that cycle is unconsumable as above.
Architectural SQ commit consumers (`sq_committed`, `committed_empty`, the
flush-exemption mask) keep the masked pulses.

The staged SQ-check payload follows the same full-flush rule one level
upstream. Its capture/replace gate keeps the selective partial-flush block but
omits full flush: that edge resets all SQ-check control bits and all LQ-valid
bits, so the newly captured payload is dead. With translation active, the DMMU
supplies separate LQ and SQ raw S2 capture pulses ahead of its
recovery/full-flush kills. The SQ pulse can update only hidden address/data
payload; the canonical killed pulse still governs SQ visibility, ROB
completion, SC, and fault side effects. This keeps the registered
trap/xRET/FENCE-class flush out of both queues' payload-storage enables without
weakening any consumer gate.

At the wrapper seam, the LQ takes the registered early-recovery pulse directly
as its partial-flush enable. It equals the canonical partial term on every
cycle without an effective full flush. On the cycles where they differ, the
full-flush input resets or suppresses every architecturally visible
transition; a payload capture may differ internally on that edge, but its
valid/control state is cleared before observation. This keeps the full-flush
priority decode out of the SQ-check capture cone without changing the queue's
observable flush behavior.

The AMO write phase is protected upstream. A full flush would clear
`AMO_WRITE_ACTIVE` while the launched write is still in flight and orphan it:
memory would carry the side effect of a squashed AMO that then re-executes.
Rather than dropping the write in the LQ, the trap unit shields interrupt
delivery while an AMO owns the ROB head (`trap_unit.i_amo_at_head`), so no
interrupt flush can land inside the AMO's [write-launch, commit] window. A sim
tripwire in the LQ `$error`s if any future flush source reaches an active AMO
write.

MMIO loads are a further case. Their reads can have side effects
(clear-on-read registers, status pulses), so they cannot issue speculatively.
The LQ pins MMIO loads to the ROB head: they leave the LQ only when their entry
is the oldest in flight. It hands the request to the data-memory router, which
owns the irreversible boundary. The router's one-entry request register always
captures the device address before acceptance. The terminal gate then consumes
only registered pending/address state, the local port blockers, and the SQ's
`o_committed_empty` status; every read enable, MMIO valid/pulse, destructive
sideband, and fast-response-valid seed derives from that one decision. The
pending output feeds directly back into the wrapper's LQ `i_mem_bus_busy`
expression and stays high through the terminal-accept cycle, so a younger
handoff cannot overwrite either the held router address or the LQ's
issued-response snapshot. Reset or the LQ's full-owner flush class suppresses
acceptance and cancels a still-pending request.

A committed MMIO store takes effect only at the device, and only once it
drains. Address-based disambiguation cannot order the pair when the device
aliases one register behind two addresses (the SiFive CLINT window). On the
cached tier the drain can lag commit by write-port arbitration, so ROB-head
alone is not enough. Waiting for the whole committed queue is conservative:
unrelated older committed BRAM/cached stores can delay the MMIO load too, but
the rule adds no second SQ-wide reduction or status path. The router gates the
full LQ device quadrant (`addr[31:30] == 2'b01`), including unmapped device
space, with a physically isolated terminal LUT. It consumes the SQ's
already-registered, same-cycle-commit-pessimistic status directly; registering
that status again would create a stale-high release cycle. A misalignment
exception completes inside the LQ without a router handoff because it performs
no device access; the trap unit's independent committed-store drain gate still
prevents architectural trap entry until the queue is empty.

An already-armed trap/xRET/FENCE-class flush can overlap the mandatory router
stage. The router consumes the same full-owner flush class as the LQ,
suppresses terminal accept, and clears pending. At that edge the LQ still
observes pending high, so it clears `mem_outstanding` without arming a response
debt that can never arrive. If pending is already low, acceptance happened: a
coincident fixed MMIO response is drained without updating an entry or L0,
while a delayed cached response transfers to `drop_mem_response_pending` until
it arrives. xRET, FENCE-class recovery, and commit recovery otherwise cannot
pass an incomplete ROB-head device owner, and early branch recovery is partial
and preserves it. Reset provides the same pre-accept cancellation. A partial
branch flush cannot kill the parked owner because it left the LQ only at ROB
head, older than the branch being recovered.

### Device-read interrupt shield

An interrupt between terminal accept and commit could re-execute an irrevocable
clear-on-read or FIFO-pop access. Pre-accept flush cancellation does not cover
that window because a flush armed on the accept edge arrives after the effect.
The trap unit therefore blocks interrupts while
`i_device_read_at_head` is set. `cpu_ooo` raises the shield from registered
router pending and drops it at the next commit, necessarily the owning load:
device reads leave the LQ only at ROB head, and an incomplete head cannot
commit.

The router waits one full pending cycle before arming, using only local
`device_request_pending_q → device_accept_armed_q` state. Because `cpu_ooo`
derives the shield from the same pending output, the hold is established
without a feedback path into the router:

| cycle | event |
| --- | --- |
| N | LQ launches at the ROB head; the router's pending Q sets at the edge |
| N+1 | `o_device_request_pending` high → `device_read_shield_q` and the router's `device_request_pending_q` both set |
| N+2 | shield visible to the trap unit; `device_accept_armed_q` sets |
| N+3 | terminal accept, with interrupt delivery already held |

An interrupt taken through N+1 produces an N+2 flush that blocks arming and
cancels pending without response debt. Interrupts are held from N+2 through
load commit.

Arming adds only a precondition: flush, write-port ownership, and committed-store
drain are re-evaluated at accept. Exceptions remain enabled; misalignment
completes inside the LQ without a router handoff.

The shield is bounded: arming requires `i_sq_committed_empty`, and the pending
interrupt is already latched, so `o_trap_drain_wait` does not hold commit. The
load commits, the shield drops, and the interrupt follows. A cpu_ooo watchdog
errors after 4096 shielded cycles.

Dword loads (FLD and RV64 LD) complete through the same size-keyed path in a
single beat: the 64-bit data tier
(the data-tier bus contract in [hw/rtl/README.md](../../../../README.md))
returns the aligned dword at `addr[31:3]` and the entry's FLEN-wide
data slot captures it whole. The old 32-bit-bus two-phase FLD machinery
(per-entry phase bit, split lo/hi data halves, `+4` re-issue) is gone.

The per-entry AMO opcode is compacted from the 8-bit `instr_op_e` to a 4-bit
semantic code and stored in per-entry FFs. Accepted slot-1 and slot-2
allocations first capture their distinct index/code pairs in a one-cycle write
stage, so late allocation enables do not fan into the per-entry write decoder.
The accepted bits are staged too, so an unaccepted candidate cannot write when
its candidate index aliases an accepted allocation. The address-update and
SQ-check phases an AMO must pass before it can issue hide this delay. The
staged indexed writes need neither replicated RAM banks nor a live-value table.
The selected code and `rs2` are snapshotted at AMO read launch alongside the
issued address. At response, SWAP/ADD/XOR/AND/OR produce a registered,
comparator-free result. MIN/MAX instead register independent raw unsigned
`{equal, old-less-than-rs2}` relations for `.W` and `.D`, both held operands,
and narrow unsigned/MAX mode bits. `.W` compares exactly the low 32 bits even
on RV64; `.D` compares all 64 bits. Width selection and signed ordering are
reconstructed only from registered state. Preservation attributes keep the
four relation bits and two mode bits as that boundary through synthesis and
equivalent-register removal. The equality bit preserves the strict-comparison
tie behavior in which either MIN or MAX selects `rs2`. `AMO_WRITE_ACTIVE`
starts on the next cycle as before and performs a short relation decode plus
the operand mux; other operations use the normal result register. Neither the
queue select nor a compare-carry-to-wide-result cone reaches the memory BRAM's
write pins, and memory-side stalls hold the entire request until `write_done`
without changing AMO latency. Payload capture is `AMO_IDLE`-qualified as a
local invariant, so even an invalid overlapping response cannot overwrite a
stalled active request.

## L0 cache

The L0 is a 128-entry direct-mapped cache with dword-granule (aligned 8-byte)
lines, filled one full beat per memory response, implemented inside the LQ by
[`lq_l0_cache.sv`](lq_l0_cache.sv). It is a hit-path optimization: loads check
it in parallel with SQ disambiguation, and a hit returns the result the same
cycle. Every load size is eligible, including FLD, because the line carries the
whole dword. The SQ invalidates a store's containing dword line when it
launches the store's memory write, and AMO write completion invalidates the
AMO's line. The two sources use separate invalidate ports so the late AMO
write-done acknowledge is not muxed in front of the tag read and compare; AMO
serialization keeps them mutually exclusive, which the LQ asserts. That keeps
the cache coherent without a write-through path of its own.

Three things the cache does not do:

- Flush on branch mispredict. The L0 holds only architectural state (committed
  stores invalidate as they drain, loads fill with memory's view), so there is
  nothing speculative to throw away. Leaving cached lines hot across mispredict
  recovery roughly doubles the steady-state hit rate on CoreMark
  (36.5% → 72.4%). For the same reason, an ordinary non-MMIO response that
  arrives exactly with a partial flush may still fill L0 even when its killed
  LQ owner discards the completion. Full flushes, already-pending
  stale-response drains, LR/AMO responses, and responses made stale by a
  store/AMO invalidation remain ineligible.
- Fill from a full-flush-cycle response. Trap/xRET/FENCE-class full flushes
  keep existing L0 lines hot, but a memory response that arrives on the flush
  cycle is treated as a drained response for a killed load and may not install
  a new L0 line.
- Bypass a same-cycle fill into the lookup. Forwarding the in-flight fill into
  a same-cycle lookup dragged the back-end flush cone (`i_flush_en` →
  `accept_mem_response` → fill → bypass → hit → `o_mem_read_en`) into
  `data_memory`'s address read pin. A same-cycle hit on the just-filled line
  becomes a one-cycle-delayed hit instead; the LUTRAM is current next cycle
  regardless.

## Issue selection

The parallel issue-selection scan lives in
[`lq_issue_selector.sv`](lq_issue_selector.sv), extracted from
`load_queue.sv`. It finds the oldest CDB-ready entry (Phase A), builds the
memory-issue eligibility masks with MMIO/LR/AMO head gating and older-AMO
blocking (Phase B), and produces the explicit ROB-head priority result. It
exports `issue_cdb_idx` to address the LQ data LUTRAM read, which stays in
`load_queue.sv`.

Older-AMO blocking uses an exact registered physical dependency bitmap rather
than ring position: the sparse queue reuses reclaimed holes after flushes, so a
position-based prefix-OR could let a younger load slip past a pending AMO and
read the pre-AMO memory value. Row `i` records the still-pending AMO slots that
are architecturally older than entry `i`. A one-cycle mirror of the physical
valid bits detects each newly-live generation; its ROB-tag comparisons update
only the bitmap FFs. AMO completion prunes its source column on the event edge.
Destination free and partial flush instead invalidate the physical identity
first; the next maintenance edge clears its destination row and source column.
The block may therefore remain conservatively high for one cycle only while
that row is invalid. Allocation cannot reuse a slot on its flush/free edge, so
the complete invalid gap drains old-generation state before a new identity can
issue. A separate registered row reduction drives the selector directly. This
removes both the former live `ROB head → age subtractors → min tree → compares`
issue cone and load-result-free/recovery-age control from dependency-register
D. AMO write completion remains a direct source-column prune.

The allocation stage supports both ports and compares tags rather than
assuming physical or request order, including sparse/adversarial tag layouts.
Legal allocation comes from the ROB tail, so a newly allocated AMO cannot be
older than an entry already resident in `sq_check`; the registered update is
therefore complete before that entry can need a new dependency. A head AMO is
admitted to the head-priority scans whenever the SQ committed queue is empty.
At ROB head everything else in the LQ is younger (and fenced), so preemption is
always safe. This subsumed the old 512-cycle deadlock breaker, which has been
removed.

The sparse allocator's `tail_ptr` is a free-search cursor, not occupancy or
age state. It advances when the registered valid-generation detector observes
the prior cycle's allocation. The newly valid entries already make a
back-to-back search skip those slots, so the one-cycle cursor lag changes only
the next physical search origin: allocation capacity and two-wide throughput
are unchanged. A balanced merge tree finds the first two free entries in
tail-relative order; this keeps paired allocation off a serial found-bit
cascade while preserving the sparse-hole policy exactly.

The ROB-head priority scan admits every head load class, including MMIO and
LR; AMOs are admitted only when the committed queue is also empty. The normal
stored-address scan redundantly admits an MMIO entry only when it is also at
the ROB head. The dedicated head result always wins the final selector, so
this restores the prior Boolean shape without changing selection or cycle
timing. A same-cycle address update may still stage an MMIO load before it
reaches the head. In every case the LQ handoff occurs only at ROB head; the
downstream router always parks that request for one cycle, then keeps it
parked until the full committed queue becomes empty. A flush in that
pre-accept window cancels the request without response debt. SQ disambiguation
and the handoff itself may run early because neither has a device or
architectural side effect. A no-read misalignment completion stays inside the
LQ, while architectural trap entry remains protected by the trap unit's drain
gate.

The scan starts at the ring head `head_idx` (`= head_ptr`) rather than at the
ROB-head entry's physical slot. Without head priority, an eligible ROB-head
MMIO/LR load can lose the single `sq_check` staging slot to a ring-earlier
younger load. If that younger load is fenced behind an un-drainable
(uncommitted, non-forwardable) older store, it camps there indefinitely and
starves the head (the `call_stress` UART poll-load wedge). Admitting the head
is safe and live. The head is the oldest architectural load, so only
committed, and therefore draining, older stores can fence it, never the
younger wrong-path stores that create the hog. `sq_check_replace` evicts the
younger staged entry, the MMIO/LR-only-at-head issue gates preserve
non-speculation, and the router's terminal accept gate preserves store→device
ordering.

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

Two bypass paths each shave a cycle off the load critical latency.

- Same-cycle `addr_valid` bypass. MEM_RS emits a pre-issue look-ahead one
  cycle before the real issue (`o_pre_issue_rob_tag` + `o_pre_issue_needs_lq`).
  The LQ pre-registers the CAM match against that tag, so the entry appears
  addr-valid the same cycle MEM_RS issues (`entry_addr_valid_now`). This
  removes the flop between RS issue and SQ disambiguation.
- `cdb_stage` completion bypass. On a memory response, L0 fast-path hit, or SQ
  forward, the LQ writes `cdb_stage` directly from the response, cache, or
  forward data path instead of routing through `lq_data_valid` and a priority
  encoder. The entry frees and the CDB broadcast arms the same cycle. AMOs
  stay on the standard path, as do DOUBLE-size memory responses; L0-hit and
  forwarded FLDs bypass, since both deliver the full 64-bit payload in a
  single probe.

## Back-to-back issue

In steady state the LQ issues one low-BRAM load per cycle. The historical
`launch_mem_issue` cone is gated only by the flush pulses, `i_mem_bus_busy`,
and the registered cached launch hold, not by the previous launch's
`mem_outstanding`. The hold covers two cases: every slot in flight, or the
router holding a cached response behind a fast beat for a cycle, so
back-to-back fast launches cannot starve it. A cached AMO needs no window of
its own: it issues only at the ROB head (older loads retired), and a pending
AMO fences every younger load (`older_amo_block`) until its write completes,
so no other load is in flight during its response or write phase. Every MMIO
request instead raises the router's registered pending Q, which independently
enters `i_mem_bus_busy` and blocks the next handoff through the terminal-accept
cycle. The Q clears on that accept edge; the fixed fast response arrives the
following cycle and may overlap a new handoff. Low-BRAM traffic therefore
keeps the original back-to-back cadence, while MMIO pays the mandatory staging
cycle.

Back-to-back issue without dropped results took three coupled pieces: the
priority encoder masks out entries already in flight, SQ-check capture fires
the same cycle the previous candidate launches, and `lq_data` port 0 is
reserved for the memory response while port 1 handles cache hits, SQ forwards,
and AMO writes, so they cannot collide on the same port.

## Issued-entry snapshot and cached load slots

The response handler reads from a flat snapshot of the issued load's
attributes (addr / size / FP / LR / AMO / MMIO / sign_ext / rob_tag), not from
the per-entry LUTRAMs indexed by `issued_idx`. A fast-tier (low-BRAM/MMIO)
handoff captures the `fast_*` snapshot and sets `mem_outstanding`. A cached
handoff captures the same attributes into a free entry of the `cs_*` slot
table (`o_mem_read_id` names the slot), and the response brings the slot id
back (`i_mem_read_is_cached` / `i_mem_read_id`). The `issued_*` signals the
handler consumes are a mux: the answering slot's entry for a cached response,
the fast snapshot otherwise. Each slot carries its own flush-kill (`cs_drop`:
a partial flush marks the younger slots, a full flush all of them, and a
marked slot's response is drained and frees it) and its own
store-invalidation bit for the L0 fill guard. The fast owner's flush kill is
evaluated from the fast snapshot, never from the response-owner mux, so a
cached response landing in the flush cycle cannot hide it. A cached load still
parked in the router when a full flush cancels it is freed outright rather
than drop-marked: the router reports it pending, and no response will come.
Every MMIO request is protected by the router pending feedback during its
mandatory stage and any drain wait; after terminal accept, its fixed response
may share a cycle with the next handoff because the response state updates
precede and are overridden by the new-owner updates. Removing the
`lq_*[issued_idx]` read path takes the LQ entry array out of the `data_memory`
read-address cone. The AMO-only operation and `rs2` fields are captured with
the same snapshot; the response edge consumes only those values and the
returned old value before the serialized write phase. For MIN/MAX the
width-specific magnitude and equality comparisons terminate at raw-relation
FFs. The active write phase holds old/`rs2` locally and performs the
registered width/sign/mode decode plus the final operand mux.

## Atomics

The LR reservation register lives in the LQ. LR sets it on completion; SC
clears it; any SQ write to the reserved address clears it via a snoop. SC
succeeds if the reservation is still valid when SC reaches the ROB head. AMO
uses a separate memory write port on the LQ for the write half of the
read-modify-write. The AMO fires from the ROB head with the SQ
committed-empty, so nothing else can interleave.

AMO writes are invisible to SQ disambiguation (AMOs never allocate SQ
entries), so the LQ enforces their ordering itself. The AMO write fence
(`older_amo_write_pending`) holds any staged load younger than an AMO that has
not yet completed its memory write (`lq_data_valid` for an AMO covers read +
write). The fence blocks launch, SQ forwarding, and the L0 fast path, and a
fenced staged load releases SQ-check staging instead of camping, so the head
AMO reaches the memory port immediately. A staged head AMO itself issues
without waiting for younger stores' addresses (`sq_head_amo_clear`): with the
committed queue empty, no older SQ store can exist.

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
!i_flush_en`). Dispatch presents alloc requests un-flush-gated: on
trap/xRET/FENCE-class pulse cycles a straggler's fire can coincide with the
flush, so the LQ must reach the ROB's reject verdict on the same cycle.
Without the gate, a partial-flush-cycle alloc wrote a ghost entry: the alloc
arm runs after the invalidate loop in the same `always_ff` (last-write-wins),
leaving a valid entry whose tag the ROB never allocated. That was a slot leak,
then a duplicate-tag pair once the rewound tail re-issued the tag.

The registered dispatch back-pressure flags use a conservative reservation
count. They include each raw slot request that would fit the pre-edge exact
occupancy, but take no same-edge credit for an entry completion or partial
flush. Actual allocation remains flush-gated as above. The registered flags
can therefore over-stall dispatch for one cycle after a free, flush, or
flush-cycle phantom reservation, but they never advertise capacity that the
exact `o_full` / `o_full_for_2` mask does not have. This removes the shared
completion/recovery cone from the dispatch-status flops without risking a
stale-low capacity decision.

## Performance counters

The LQ emits pulses for the wrapper's performance counters so the head-load
wait bucket, historically a large fraction of CoreMark idle time, can be
attributed. L0 hits and fills are counted directly. The head-load wait is
split into five sub-buckets (`addr_pending`, `sq_disambig`, `bus_blocked`,
`cdb_wait`, `post_lq`), and the `bus_blocked` bucket is further split into
five mutually exclusive causes (`bb_issued`, `bb_bus_busy`, `bb_amo`,
`bb_sq_wait`, `bb_staging`). The `bb_staging` catch-all is itself decomposed
into four mutually exclusive sub-causes (`bbs_other_in_staging`,
`bbs_launch_gated`, `bbs_slow_outstanding`, `bbs_capture_gap`). The wrapper's
parent counter `head_wait_mem_load` stays live alongside the decomposition.

## Verification

Cocotb tests cover allocation including slot-2-only and paired slot-1/slot-2
cases, address update, every load size, SQ forwarding, mandatory MMIO staging,
the high-to-low drain-status race, pending-request flush cancellation versus
accepted-response debt, single-beat FLD, FLW NaN-boxing, partial and full flush,
partial-flush AMO-dependency cleanup through physical-slot reuse, AMO
read-modify-write including `.W`/`.D` signed/unsigned extrema, exact equality,
hostile ignored `.W` upper halves, and held writes, conservative
dispatch-backpressure release after frees and flush-cycle requests, LR/SC
reservation, and constrained-random stress. Bounded inline LQ checks cover
pointer invariants, issue prerequisites,
cached-response ownership, dependency-row cleanup, and the cancellation/debt
truth table; wrapper/router checks cover registered-pending feedback, request
conservation, held-address stability, terminal drain qualification, and the
requirement that no read side effect precede acceptance.
