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
captured first and killed afterwards rather than gated at capture. The flush
and commit-block terms must stay off the wide capture D/enable cone. Its
capture enable is the trap-cone-free
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

Dword loads (FLD and LD) capture one aligned 64-bit response beat; see the
[data-tier contract](../../../../README.md#data-tier-bus-contract).

The per-entry AMO opcode is compacted from the 8-bit `instr_op_e` to a 4-bit
semantic code and stored in per-entry FFs. Accepted slot-1 and slot-2
allocations first capture their distinct index/code pairs in a one-cycle write
stage, so late allocation enables do not fan into the per-entry write decoder.
The accepted bits are staged too, so an unaccepted candidate cannot write when
its candidate index aliases an accepted allocation. The address-update and
SQ-check phases an AMO must pass before it can issue hide this delay. The
staged indexed writes need neither replicated RAM banks nor a live-value table.
The selected code and `rs2` are snapshotted at AMO read launch alongside the
issued address. At response, SWAP/ADD/XOR/AND/OR enter `AMO_COMPUTE` after
capturing the old memory value, `rs2`, compact operation, width, address and
entry index. The MMIO and cached-tier flags are captured from that same issued
address and held with it through compute and write completion. The router uses
these registered flags, so AMO state does not feed a write-address tier decode.
The existing separate 32/64-bit arithmetic functions consume only these registers. One cycle later their result enters `amo_write_data_q` and
`AMO_WRITE_ACTIVE` starts. `.W` uses the selected old word's low 32 bits and
zero-extends the new result; its architectural old-value return still
sign-extends. No additional wide operand or result register is needed.

Normal AMOs spend one response-to-write cycle in `AMO_COMPUTE`; younger loads
wait until the write completes. LR/SC and MIN/MAX use their separate paths.

MIN/MAX register independent raw unsigned `{equal, old-less-than-rs2}`
relations for `.W` and `.D`, both held operands, and narrow unsigned/MAX mode
bits. `.W` compares exactly the low 32 bits even on RV64; `.D` compares all 64
bits. Width selection and signed ordering are reconstructed only from
registered state. Preservation attributes keep the four relation bits and two
mode bits as that boundary. Equality preserves the strict-comparison tie
behavior selecting `rs2`. MIN/MAX enter `AMO_WRITE_ACTIVE` immediately after
the response capture, using registered relation decode and operand selection.

Only `AMO_WRITE_ACTIVE` can launch or complete a write, deliver the old value,
invalidate the L0, or release younger-AMO dependencies. `AMO_COMPUTE` retains
the owner's DMA-coherence exclusion even though its response slot is already
free, and ignores premature `write_done`. Reset/full flush or a partial flush
killing the retained entry cancels an unlaunched compute owner. A younger
partial flush preserves it. The existing upstream ROB-head interrupt shield
and prohibition against flushing a launched write remain unchanged.

Response capture and its state transition are `AMO_IDLE`-qualified: an invalid
overlapping response cannot replace an owner or activate a stale result.
The wide result FF enable depends only on `AMO_COMPUTE`; a canceled compute may
capture dead payload while control cancels it. That value is unobservable and
the next normal owner overwrites it before entering ACTIVE. This keeps
reset/flush/age/valid terms off the result-register enable. Memory-side stalls
retain the entire active write until `write_done`.

## L0 cache

The L0 defaults to a 128-entry direct-mapped cache with dword-granule (aligned 8-byte)
lines, filled one full beat per memory response, implemented inside the LQ by
[`lq_l0_cache.sv`](lq_l0_cache.sv). It is a hit-path optimization: loads check
it in parallel with SQ disambiguation, and a hit returns the result the same
cycle. Every load size is eligible, including FLD, because the line carries the
whole dword. The SQ invalidates a store's containing dword line when it
launches the store's memory write, AMO write completion invalidates the
AMO's line, and a DMA write to a line (the coherence port below) clears the
line's four dword entries tag-blind and suppresses a same-cycle hit on them.
The first two sources use separate invalidate ports so the late AMO
write-done acknowledge is not muxed in front of the tag read and compare; AMO
serialization keeps them mutually exclusive, which the LQ asserts. That keeps
the cache coherent without a write-through path of its own.

`L0_CACHE_DEPTH` is forwarded from `frost` through the CPU to this cache.
Simulation can compare capacities with `FROST_VERILATOR_EXTRA_ARGS=-GL0_CACHE_DEPTH=256`.
The implementation requires a power of two from 8 through 2^28: at least one
index bit above the four-dword coherence line and one physical tag bit.
The regression configurations are 128 and 256 entries; larger values need
their own resource and timing evaluation. Addresses remain canonical physical
32-bit addresses, with the device quadrant excluded from hits.

Changing L0 depth changes neither the eight LQ entries, four cached response
slots, 32 ROB observation slots, nor three DMA admission locks. A line still
invalidates four dword indices in one edge, with no cache scan or response
needed from L0. In-flight fill suppression and the coherence observation table
continue to cover loads after LQ release through retirement. DMA admission
still waits for overlapping AMO/LR/SC ownership; admitted lines hold new
atomic launches while invalidation and the hierarchy's probe/acknowledgement
service progress independently of L0 occupancy. Capacity must not introduce
an admission dependency on a load waiting for that same DMA service.

Three things the cache does not do:

- Flush on branch mispredict. The L0 holds only architectural state (committed
  stores invalidate as they drain, loads fill with memory's view), so there is
  nothing speculative to throw away. An ordinary non-MMIO response that
  arrives exactly with a partial flush may still fill L0 even when its killed
  LQ owner discards the completion. Full flushes, already-pending
  stale-response drains, LR/AMO responses, and responses made stale by a
  store/AMO invalidation remain ineligible.
- Fill from a full-flush-cycle response. Trap/xRET/FENCE-class full flushes
  keep existing L0 lines hot, but a memory response that arrives on the flush
  cycle is treated as a drained response for a killed load and may not install
  a new L0 line.
- Bypass a same-cycle fill into the lookup. Forwarding the in-flight fill into
  a same-cycle lookup would put the back-end flush cone (`i_flush_en` →
  `accept_mem_response` → fill → bypass → hit → `o_mem_read_en`) into
  `data_memory`'s address read pin. A same-cycle hit on the just-filled line
  becomes a one-cycle-delayed hit instead; the LUTRAM is current next cycle
  regardless.

## DMA coherence port

A DMA agent below the L1D reaches the load queue through
`tomasulo_wrapper/coherence/lq_coherence_port.sv`, which mirrors the cache
hierarchy's admitted lines and drives four things here:

- Admission query (`i_coh_query_addr` / `o_coh_query_busy`): a line is
  admitted to a DMA write only while no AMO or LR on it is staged, in flight
  or in its compute/write phases (`sq_check_*`, the cached slots, `amo_write_addr_q`)
  as the port's pipelined check samples the queue; an atomic captured on the
  decision edge is staged when the admission fires and is caught by the
  launch hold below, so an atomic's read and write are never split by the
  DMA write. The port adds the SC window from the wrapper.
- Launch hold (`i_coh_block_*`, `i_coh_admit_pulse`): a staged AMO or LR
  whose line is admitted does not launch until the line is released. The
  hold is registered from the staged address, so a newly staged atomic waits
  one cycle for its own compare, and the pulse the port raises in an
  admission's fire cycle and the cycle after holds every staged AMO/LR
  launch until that compare has caught up; the admission check itself runs
  in the port's pipeline from the queue's registered state, so an atomic
  captured in the decision cycle can be staged when the line is admitted,
  which is exactly the case the first-launch wait covers. An LR whose
  response lands on the invalidation's own edge sets no reservation.
- Invalidation (`i_coh_inval_*`, applied on the edge): the L0's four dword
  entries of the line are cleared, every in-flight cached load of the line
  is marked not-to-fill (`cs_inval`, the same guard a store hit sets), every
  in-flight LR of the line is marked reservation-suppressed
  (`cs_lr_suppress`, so its late response establishes no reservation on the
  pre-write value), and a matching reservation is cleared. The queue does
  not squash the in-flight loads: their values were observed before the DMA
  write and are legal in coherence order.
- Observation event (`o_coh_observe_*`): a cached load that hit the L0,
  took its value from the store queue or launched to the L1D this cycle,
  with its ROB tag and address (the port drops the observation of a load a
  flush kills in that cycle; one older than the flush point stays validated). The port's
  validation table keeps it until the load retires; a DMA write to the line
  in between flags the ROB entry, and the ROB replays the load (a restart at
  its own PC with no architectural side effect) when it reaches the head.
  That is what keeps a younger load that sampled a line before the DMA write
  from retiring after an older load that sampled it afterwards, for every
  FENCE form, acquire and same-address pair, without serializing loads.

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
keeps live ROB-age selection and completion/recovery control off
dependency-register D. AMO write completion remains a direct source-column prune.

The allocation stage supports both ports and compares tags rather than
assuming physical or request order, including sparse/adversarial tag layouts.
Legal allocation comes from the ROB tail, so a newly allocated AMO cannot be
older than an entry already resident in `sq_check`; the registered update is
therefore complete before that entry can need a new dependency. A head AMO is
admitted to the head-priority scans whenever the SQ committed queue is empty.
At ROB head everything else in the LQ is younger (and fenced), so preemption is
always safe.

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
the stored-address result cannot override an eligible head. A same-cycle
address update may still stage an MMIO load before it
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
starves the head. Admitting the head
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
feedback path. This keeps `lq_addr_valid` off the payload-identity encoder
and priority path.

The cached-slot launch hold reduces both possible occupancy masks before
selecting with the late launch decision. Its reset, full-flush, response-held,
and response-release behavior is unchanged; `lq_cached_hold` checks the exact
next-state equation. Invalidation and LR-suppression flags retain their
launch-clear priority, but the Xilinx implementation drives that decision
through D rather than each flag's synchronous-reset input.

## Issue and completion bypasses

Two bypass paths each shave a cycle off the load critical latency.

- Same-cycle `addr_valid` bypass. MEM_RS emits a pre-issue look-ahead one
  cycle before the real issue (`o_pre_issue_rob_tag` + `o_pre_issue_needs_lq`).
  The LQ pre-registers the CAM match against that tag, so the entry appears
  addr-valid the same cycle MEM_RS issues (`entry_addr_valid_now`). This
  removes the flop between RS issue and SQ disambiguation. Tag matches and
  the issue-valid qualifier are captured in parallel and combined after
  their registers, keeping late RS readiness/classification off the CAM
  register inputs. `load_queue:prove_pre_match` proves unrestricted
  equivalence to the original combined register, including reset and flush.
  With `PREISSUE_CANDIDATES=1`, the candidate tag comparisons and their
  `PREISSUE_SEL_WIDTH`-bit selector are registered separately on that same edge. Selecting
  after the edge preserves the exact match and removes late wakeup-valid
  selection from the register inputs. The wrapper enables this with early
  load wakeup with eight candidates (`PREISSUE_SEL_WIDTH=3`), and supplies
  eight identical DMMU tags during translation. The generic default is four
  candidates with a two-bit selector.
  `lq_prematch_cofactors` proves this retiming without assumptions about
  inputs or current queue state; an integration assertion checks the scalar
  tag/candidate interface contract.
- `cdb_stage` completion bypass. On a memory response, L0 fast-path hit, or SQ
  forward, the LQ writes `cdb_stage` directly from the response, cache, or
  forward data path instead of routing through `lq_data_valid` and a priority
  encoder. The entry frees and the CDB broadcast arms the same cycle. LD,
  FLD and LR.D responses bypass with the complete 64-bit beat, as do L0 hits
  and SQ forwards. LR still establishes its reservation at response capture.
  AMOs wait for their write phase. An occupied CDB stage or an older ready
  completion sends the response through the ordinary per-entry data path.

## Back-to-back issue

In steady state the LQ issues one low-BRAM load per cycle. The
`launch_mem_issue` cone is gated only by the flush pulses, `i_mem_bus_busy`,
and the registered cached launch hold, not by the previous launch's
`mem_outstanding`. The hold covers two cases: every slot in flight, or the
router holding a cached response behind a fast beat for a cycle, so
back-to-back fast launches cannot starve it. A cached AMO needs no window of
its own: it issues only at the ROB head (older loads retired), and a pending
AMO fences every younger load (`older_amo_block`) until its write completes,
so no other load is in flight during its response, compute, or write phase. Every MMIO
request instead raises the router's registered pending Q, which independently
enters `i_mem_bus_busy` and blocks the next handoff through the terminal-accept
cycle. The Q clears on that accept edge; the fixed fast response arrives the
following cycle and may overlap a new handoff. Low-BRAM traffic therefore
keeps the original back-to-back cadence, while MMIO pays the mandatory staging
cycle.

Back-to-back issue requires three constraints: the
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
store-invalidation bit for the L0 fill guard.

A drop-marked slot stays dead until its response arrives; its queue index and
ROB tag may already belong to another load. Later partial flushes must not
age-judge that stale identity (`cs_flushed` requires `!cs_drop`). Assertions
and `lq_stale_slot_probe` check:

- A live slot names a valid, issued queue entry with the same ROB tag.
- Live slots never share a queue entry, and a launch cannot reuse one.
- A response completes only its issuing load.
- A staged `sq_check` launch still matches the current entry/tag; the staged
  payload is not independently revalidated after capture.

The fast owner's flush kill is
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

The per-entry allocation pulses are expanded over the two dispatch valids,
which arrive last through the dispatch fire tree. The first free target with
room for one entry is written when either slot allocates, and the second target
with room for two only when both do; both room terms are request-independent
and kept as nets, so each pulse is one gate of the valids against them. Slot 1's
own pulse selects the payload source. Simulation and formal compare the expanded
pulses against the enable-then-steer form they replace.

Dispatch does not flush-gate its allocation requests. Both LQ allocation
enables therefore carry `!i_flush_all && !i_flush_en`, matching the ROB's
rejection on a flush cycle. Otherwise the allocation arm could overwrite
invalidation and leave a queue entry with an unallocated or reused ROB tag.

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

The LQ emits performance events for the wrapper. L0 hits and fills are counted
directly. The head-load wait is
split into five sub-buckets (`addr_pending`, `sq_disambig`, `bus_blocked`,
`cdb_wait`, `post_lq`), and the `bus_blocked` bucket is further split into
five mutually exclusive causes (`bb_issued`, `bb_bus_busy`, `bb_amo`,
`bb_sq_wait`, `bb_staging`). The `bb_staging` catch-all is itself decomposed
into four mutually exclusive sub-causes (`bbs_other_in_staging`,
`bbs_launch_gated`, `bbs_slow_outstanding`, `bbs_capture_gap`). The wrapper's
parent counter `head_wait_mem_load` stays live alongside the decomposition.

## Verification

Cocotb covers allocation, load sizes, forwarding, MMIO acceptance,
flush/response ownership, atomics, and LR/SC. Inline bounded properties check
queue and request invariants; wrapper/router tests check the connected
handshakes and side-effect ordering.

The focused `load_queue_amo_compute` formal target checks the production AMO
datapath over four steps with no reset/admission assumptions. It covers
capture, arithmetic, compute/write transitions, kill/reset, and coherence
exclusion. It does not establish scheduler reachability, interrupt integration,
or unbounded progress. The normal LQ formal target retains its separate
reset-based protocol checks.

See the [test runner](../../../../../../tests/README.md) for commands and the
[formal guide](../../../../../../formal/README.md) for proof scope and assumptions.

### Preparing a load while the shared port is busy

`PREPARE_LOAD_WHILE_BUSY=1` allows the existing candidate-address register to
capture or replace its load while `i_mem_bus_busy` is asserted. This is enabled
by default. Preparation itself neither probes the SQ nor observes memory: the
SQ check and capture outputs, L0-hit consumption, and physical memory handoff
retain their bus-busy gates. Flush, response-debt, age and admission rules
are unchanged. No new request credit or coherence observation is created;
loads remain covered by the existing observation table through retirement.

`load_queue` runs the full LQ suite and a directed test requiring
inert staging during port ownership, no SQ/read/result side effect, and
immediate SQ checking on release. The formal BMC and cover tasks also run
with the default option enabled. `load_queue_no_prepare_busy` and the formal
`bmc_no_prepare_busy`/`cover_no_prepare_busy` tasks cover the reusable module
with preparation disabled. Enabling SQ probes or L0 hits while busy is a
separate, unmerged experiment and is not the meaning of this parameter.

Exact full/full-for-two status reduces free-entry predicates in four-entry
groups, avoiding the numeric popcount adder on allocation controls. The public
count and all admission decisions are unchanged; `lq_capacity` checks equality
against the original count comparisons for every valid mask.

Entry-local allocation pulses use parallel cyclic first/second-free masks for
each possible cursor, selected by the registered tail. Each mask includes its
own room condition. This avoids the rotate/encode/add/decode path before the
control and payload write enables. Binary targets still drive cursor updates
and compact payload indices. `lq_alloc_mask` proves the new masks against the
original search plus capacity checks, including sparse and full states.

The response-to-CDB bypass uses the response-presence predicate without the
partial-flush age comparison. The bypass's existing `!i_flush_en` guard already
excludes every cycle that comparison could kill the owner. Full-flush, stale
response, valid-owner and AMO checks are unchanged. `lq_response_bypass` proves
the final bypass pulse equals the original acceptance-qualified pulse.

Load-result RAM ports retain the full response/forward/cache/AMO write guards.
Their address and data inputs may change while a port is disabled. The SQ data
choice removes shared age/issue qualifiers, then selects the AMO payload only
when neither cache hit nor forwarding fires. `lq_ram_payload` proves all write
enables and every enabled address/data against the original mux, with cache and
forwarding configurations checked separately and no state assumptions.

The integrated early-wakeup MEM_RS uses eight pre-issue candidates from the two
registered CDB valid bits and early-load eligibility. Candidate tag data uses
raw registered CDB/load tags, before the wakeup merger's lane muxes. The LQ
registers all eight CAM outcomes and the three-bit selector on the original
edge; translation replicates the DMMU tag into every candidate. Generic users
retain the four merged-valid candidates. `rs_raw_pretag` checks the real merger
against the RS winner; `lq_prematch_cofactors` proves both four- and eight-way
retiming without an added cycle.
