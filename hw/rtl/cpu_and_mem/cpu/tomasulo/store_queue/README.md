# Store Queue

The SQ holds in-flight stores from dispatch until the ROB commits them, at
which point the head entry writes to memory. It has independent slot-1 and
slot-2 allocation ports for 2-wide dispatch. Stores are non-speculative:
nothing leaves the SQ until commit, so flushed speculative stores never reach
the bus.

## Design overview

Two concerns dominate the design: forwarding and ordering.

**Forwarding.** A younger load may need data from an older store
that's still in the SQ. When the LQ asks the SQ to disambiguate a
load address, the SQ scans all entries combinationally for a
matching older store. A load forwards when the newest conflicting
store fully covers its bytes: FLD from an exact-address FSD (full
64-bit payload), or any byte/half/word load whose byte mask is a
subset of the store's byte mask within one word (either word of a
DOUBLE store counts as fully written). For covered loads the SQ
delivers a *memory-image word* — sub-word store data shifted to its
memory byte lanes — and the LQ applies the load's own byte/half
extraction and sign extension. If the newest conflicting store does
not cover the load's bytes, or some older store address isn't known
yet, the SQ tells the LQ to wait. The scan is combinational but the
result (`match`, `can_forward`, `data`, and `o_sq_all_older_addrs_known`)
is registered, so the LQ sees it one cycle after raising
`i_sq_check_valid`; this breaks the MEM_RS → SQ scan → LQ → BRAM path.

The forwarding scan itself (per-entry qualification, newest-match priority
select, and the output register) lives in
[`sq_forwarding_unit.sv`](sq_forwarding_unit.sv). It reads the SQ entry-array
state plus a per-entry forwarding-data mirror from `store_queue.sv`. The scan
registers the winning entry index, extraction mode, and byte offset alongside
`match` / `can_forward`; the mirrored payload is selected and formatted after
that boundary during the LQ's existing consume cycle. This preserves the
one-cycle probe result while keeping the address CAM and winner tree off the 64
payload D-pins. The drain side still reads the canonical `sq_data` LUTRAM at
`drain_idx_q`.

The scan's same-cycle committed-store guard consumes the trap-cone-free
`i_commit_valid_scan/_scan_2` pulses (the wrapper builds them from the
commit-bus pipeline's pre-flush-mask valids) instead of the architectural
commit pulses. They differ only on the full-flush cycle, whose captured
probe result is structurally unconsumable under the capture-then-kill
contract (see the load_queue README); keeping the flush mask off the scan
keeps the registered trap/MRET pulse off the forwarding capture's D-pins.
The architectural consumers below (`sq_committed`, committed-empty, the
flush-exemption mask) keep the masked pulses — a squashed store must never
latch committed state.

Two ordering subtleties in the scan:

- *Older-than-load qualification* uses ROB-tag age (`tag − head`, valid
  across the live 32-entry window) with a committed override — a committed
  store is older than any executing load by construction.
- *Newest-match winner selection* ranks conflicting entries by **SQ
  ring-slot distance from `head_idx`**, not by ROB-tag age. Committed
  entries can sit undrained after their ROB tag has been reused by a
  younger lap, which makes tag-based age rank them as youngest when they
  are in fact the oldest — the load would then forward a stale value.
  Slot order is allocation order (= program order) and never wraps.

`can_forward` is refused for MMIO stores and for store-conditionals: an SC
may fail at drain time and write nothing, so its data must never reach a
younger load early. The load then waits for the SC to drain and reads
memory.

**Ordering.** Stores drain to memory in program order. The drain is
driven by a registered drain cursor (`drain_idx_q`) — the first entry
in ring order that is valid and not yet launched (`!sq_sent`) — which
fires when that entry is committed (by the ROB) and has its address
and data ready. The cursor never skips program order: if the oldest
undrained entry isn't ready, nothing fires. FSD on the 32-bit bus
takes two phases (low word at addr, high word at addr+4); the entry
has a phase bit and isn't freed until both writes complete.

## Registered memory-write outputs

The memory-write outputs (`o_mem_write_en`, `_addr`, `_data`,
`_byte_en`, `_is_mmio`, `_is_cached`) are driven from registers rather
than straight off the drain-cursor mux. Post-synth the `head_ptr →
drain_ready → BRAM address` combinational path was the dominant
timing cone; breaking it at the SQ source keeps that cone
register-bounded and cuts hundreds of ps of setup slack.

## Pipelined drain

Plain fast-tier stores (BRAM, non-MMIO, non-FSD) complete exactly one
cycle after their bus cycle — the router's `sq_write_done_fast` is the
write-enable delayed one cycle — so consecutive plain drains overlap:
a new launch is allowed while the previous write's done is still in
flight, sustaining one store per cycle through a committed backlog.
The bookkeeping:

- `sq_sent` is set at **launch** (fire cycle) for completing writes, so
  the drain cursor moves to the next entry immediately; the done side
  only frees entries (`sq_valid` clear) and advances the FSD phase.
- A 2-bit in-flight counter plus a 2-deep in-order metadata FIFO
  (entry index + completes flag, popped one per done) replace the old
  single `write_outstanding` bit. Dones arrive in launch order on the
  single write port, so FIFO slot 0 is always the oldest in-flight
  write. If a done stalls, the occupancy bound in the launch gate
  self-throttles the drain instead of overflowing the FIFO.
- Cached / MMIO / FSD writes stay strictly single-outstanding
  (`write_inflight_special`): they only launch through the legacy
  serial gate, and nothing else launches until their done. A
  multi-cycle cached write therefore back-pressures the drain
  naturally, exactly as before.
- `head_ptr` keeps its freed-at-done semantics. Capacity is the ring
  window (`tail_ptr - head_ptr`), so the head may only pass entries
  whose writes have fully completed — the drain cursor exists
  precisely so launches can run ahead of frees without touching the
  capacity model. Entries stay valid (and visible to load
  disambiguation) until their done.

The registered `o_mem_write_is_mmio` flag lets `data_mem_request_router.sv`
(under `cpu_ooo/memory_if/`) gate the BRAM byte-write-enable at the SQ
source instead of recomputing the MMIO address range on the muxed
data-memory address — that recomputation used to pull the LQ issue cone
into the BRAM write enable whenever no store was firing. The parallel
`o_mem_write_is_cached` flag (set when the committed store's address
falls in the cached DDR region `[0x8000_0000, 0xC000_0000)`) is
registered the same way, so the router can steer the store's
byte-write enables to the cached tier — and mask them off the BRAM —
without the late address-range test reaching the BRAM write-enable
cone. Cached drains take the serial arm of the launch gate (see
"Pipelined drain" above) and hold it until the router pulses
`i_mem_write_done`, so a multi-cycle cached write back-pressures the
drain naturally instead of needing a separate busy-stretch.

## 2-wide allocation: pure ring tail

Allocation is strictly at the ring tail: slot 1 takes `tail_ptr`, slot 2 takes
`tail_ptr + 1`, and the tail advances past whatever was consumed. Ring
position therefore always encodes program order, which the head-ordered drain
depends on. (An earlier design searched forward from the tail for the first
free slot, so a younger store could land in a partial-flush hole at a ring
position the head reaches before older live entries — committed stores then
stranded behind a younger uncommitted hole-filler, and same-address stores
could drain out of program order.) The registered `o_dispatch_full_for_2`
back-pressure (see below) lets dispatch block a two-store bundle when only one
slot remains while still allowing a single-store dispatch to proceed.

A partial flush kills a program-order suffix of the window. The flush cycle
only clears the per-entry valid bits while both pointers hold; one cycle
later the tail is pulled back to just past the youngest survivor, recomputed
entirely from registered state (rotate `sq_valid` so the head maps to index
0, take the highest set offset, add back). Retiming the pullback keeps the
late ROB commit/flush cone off the pointer D/CE pins — computing it in the
flush cycle was an 18-LUT-level path at 300 MHz. Flush-cycle allocs are
suppressed structurally: the slot alloc enables carry the ROB's flush gate
(`!i_flush_all && !i_flush_en`), so a dispatch presented on the pulse cycle
(the trap-cycle straggler handshake) is rejected by the SQ on the
same cycle the ROB rejects it — previously it set `sq_valid` without a tail
advance, a ghost outside the ring window. The deferred pullback cycle is
safe: dispatch cannot allocate again that soon after a flush (an `$error`
tripwire in the RTL checks it), and capacity reads conservatively in the
meantime. Head advancement uses the
same rotate → tree-encode → add-back form over `sq_valid` to skip-advance
past freed entries, collapsing onto the tail when the window empties.

Capacity is the ring window (`tail_ptr - head_ptr`), not the live popcount:
with pure tail allocation a slot is reusable only once the head has passed
it, so rare mid-window holes (failed-SC discards) keep consuming capacity
until the head walks over them. `o_full` and `o_full_for_2` are exact
combinational window-capacity status. The CPU dispatch path instead consumes
the registered `o_dispatch_full` / `o_dispatch_full_for_2` back-pressure,
which adds same-cycle allocations to the window but deliberately takes no
same-cycle credit for drains, flushes, or SC discards — the head advances the
cycle after a drain completes, so an early credit would let dispatch send a
store the SQ must refuse (a silently lost store). Back-pressure is therefore
only ever conservatively long, never short.

Live occupancy is maintained separately in an exact event counter. Accepted
slot-1/slot-2 allocations increment it; a union of partial-flush, failed-SC,
and completed-drain removal masks decrements it, so overlapping removal causes
cannot double-count an entry. The counter updates on the same edge as
`sq_valid`, making `o_count` / `o_dispatch_count` and `o_empty` /
`o_dispatch_empty` exact immediately after that edge with no added issue
latency. This registered status boundary keeps the `sq_valid` reduction tree
out of the LQ empty-bypass and cache-read launch cone.

## Widen-commit slot 2

The SQ accepts a parallel slot-2 commit port
(`i_commit_valid_2`, `i_commit_rob_tag_2`, plus a combinational twin
used only for the committed-empty trap view — see "Same-cycle commit
hazard" below). Slot 2 only ever retires plain stores — SC / AMO are
forced onto slot 1 by the ROB's widen-commit hazard gate — so there's
no SC-discard path sharing.
Forwarding scans both slot 1 and slot 2 commits in the same cycle.
The wrapper now actually drives the combinational twin
(`i_commit_valid_comb_2` / `i_commit_rob_tag_comb_2`, previously tied to
`1'b0`); without it a full-flush trap (e.g. a machine-timer IRQ) could
observe committed-empty and drop a head+1 store the SQ has not yet seen on
the registered commit path.

## Same-cycle commit hazard

When a flush arrives one cycle after a store's raw commit pulse — partial-flush
misprediction recovery and full-flush trap / MRET / FENCE.I drains alike — the
SQ sees the *registered* commit view in the flush cycle while `sq_committed` is
still one NBA behind, so the flush could otherwise wipe out a store that just
committed. The partial-flush kill (`flush_kill_base`) therefore excludes
entries matching the registered commit ports.

A commit pulse landing *in* the flush cycle itself cannot happen: the ROB gates
`commit_ready_early` — and with it the raw store-commit pulses that drive
`i_commit_valid_comb/_comb_2` — with `!i_flush_en && !i_flush_all` on the same
flush nets this kill runs under. The kill therefore takes no combinational
commit guard (it used to, before the ROB-side gating made the race
structurally impossible); a simulation assertion and a matching formal assume
pin that invariant. The combinational commit ports remain in use for the
committed-empty trap view (see "Widen-commit slot 2" above).

## SC discard

If a store-conditional fails (the LR reservation was lost), the ROB
sends an SC discard signal to the SQ to drop the SC's entry without
writing memory. The reservation register itself lives in the LQ.

## Storage strategy

Hybrid FF + LUTRAM, same idea as the LQ. Control fields stay in
flip-flops for parallel CAM-style scan; the 64-bit data payload
lives in a single LUTRAM instance read by the drain side at
`drain_idx_q`, plus a per-entry flip-flop mirror written in parallel
for forwarding. The scan qualifies entries from the FF fields and
registers only compact winner metadata. The next cycle selects the
write-once mirror while the LQ consumes the registered result — no
LUTRAM read and no extra cycle on the forwarding path.

The forwarding-check address arrives on two functionally-identical
ports, `i_sq_check_addr` and `i_sq_check_addr_b` (a `dont_touch`'d
LQ-side replica). Entries in the lower half compare against the
first, the upper half against the second, so the per-entry CARRY8
compare chains split across two physical anchor points instead of
fanning out from one source FF.

## Verification

Cocotb tests cover allocation including 2-wide cases, address/data update,
every store size, FSD two-phase, store-to-load forwarding, MMIO bypass,
partial/full flush, SC discard, same-edge drain removal plus 2-wide allocation,
overlapping flush/discard removal, back-to-back pipelined drains (per-cycle bus
sampling in `drain_pipelined_writes`), and constrained random. Inline
formal properties cover pointer/live-count consistency across allocation and
all removal causes, write prerequisites
(asserted on the staged on-bus entry), the in-flight bound and
specials-fly-alone discipline, the committed-survives-flush invariant, and
forwarding; a cover property witnesses two writes in flight
(`cover_pipelined_drain`).
