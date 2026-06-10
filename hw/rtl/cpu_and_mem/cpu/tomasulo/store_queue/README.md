# Store Queue

The SQ holds in-flight stores from dispatch until the ROB commits them, at
which point the head entry writes to memory. It has independent slot-1 and
slot-2 allocation ports for 2-wide dispatch. Stores are non-speculative:
nothing leaves the SQ until commit, so flushed speculative stores never reach
the bus.

## What makes stores interesting

Two things: forwarding and ordering.

**Forwarding.** A younger load may need data from an older store
that's still in the SQ. When the LQ asks the SQ to disambiguate a
load address, the SQ scans all entries combinationally for a
matching older store. If one is found and the sizes are compatible,
the SQ forwards the data to the LQ — no memory access. If
the sizes don't match, or some older store address isn't known yet,
the SQ tells the LQ to wait. The scan is combinational but the
result (`match`, `can_forward`, `data`, and `o_sq_all_older_addrs_known`)
is registered, so the LQ sees it one cycle after raising
`i_sq_check_valid`; this breaks the MEM_RS → SQ scan → LQ → BRAM path.

The forwarding scan itself (per-entry qualification, newest-match priority
select, and the output register) lives in
[`sq_forwarding_unit.sv`](sq_forwarding_unit.sv) — a pure boundary move out of
`store_queue.sv`. It reads the SQ entry-array state and emits the forwarding
read index `o_fwd_match_idx`; the `sq_data` LUTRAM read at that index stays in
`store_queue.sv` and feeds the data back for the registered output.

**Ordering.** Stores commit in program order from the SQ head. The
head fires when it's both committed (by the ROB) and has its address
and data ready. FSD on the 32-bit bus takes two phases (low word at
addr, high word at addr+4); the entry has a phase bit and isn't
freed until both writes complete.

## Registered memory-write outputs

The memory-write outputs (`o_mem_write_en`, `_addr`, `_data`,
`_byte_en`, `_is_mmio`) are driven from registers rather than
straight off the head-pointer mux. Post-synth the `head_ptr →
head_ready → BRAM address` combinational path was the dominant
timing cone; breaking it at the SQ source adds one cycle to the
drain (3 cycles per store instead of 2) but cuts hundreds of ps of
setup slack. SQ-full dispatch stalls remain under 0.2% on CoreMark,
so the extra drain cycle doesn't translate into downstream back-pressure.

The registered `o_mem_write_is_mmio` flag lets `cpu_ooo.sv` gate
the BRAM byte-write-enable at the SQ source instead of recomputing
the MMIO address range on the muxed data-memory address — that
recomputation used to pull the LQ issue cone into the BRAM write
enable whenever no store was firing.

## 2-wide allocation: pure ring tail

Allocation is strictly at the ring tail: slot 1 takes `tail_ptr`, slot 2 takes
`tail_ptr + 1`, and the tail advances past whatever was consumed. Ring
position therefore always encodes program order, which the head-ordered drain
depends on. (An earlier design searched forward from the tail for the first
free slot, so a younger store could land in a partial-flush hole at a ring
position the head reaches before older live entries — committed stores then
stranded behind a younger uncommitted hole-filler, and same-address stores
could drain out of program order.) The `o_full_for_2` output lets dispatch
block a two-store bundle when only one slot remains while still allowing a
single-store dispatch to proceed.

A partial flush kills a program-order suffix of the window. The flush cycle
only clears the per-entry valid bits while both pointers hold; one cycle
later the tail is pulled back to just past the youngest survivor, recomputed
entirely from registered state (rotate `sq_valid` so the head maps to index
0, take the highest set offset, add back). Retiming the pullback keeps the
late ROB commit/flush cone off the pointer D/CE pins — computing it in the
flush cycle was an 18-LUT-level path at 300 MHz. The deferred cycle is safe:
dispatch cannot allocate again that soon after a flush (asserted in the RTL),
and capacity reads conservatively in the meantime. Head advancement uses the
same rotate → tree-encode → add-back form over `sq_valid` to skip-advance
past freed entries, collapsing onto the tail when the window empties.

Capacity is the ring window (`tail_ptr - head_ptr`), not the live popcount:
with pure tail allocation a slot is reusable only once the head has passed
it, so rare mid-window holes (failed-SC discards) keep consuming capacity
until the head walks over them. `o_full`, `o_full_for_2`, `o_empty`, and
`o_count` are exact combinational status for local visibility. The CPU
dispatch path instead consumes the registered `o_dispatch_full` /
`o_dispatch_full_for_2` back-pressure (and `o_dispatch_empty` /
`o_dispatch_count`), which add same-cycle allocations to the window but
deliberately take no same-cycle credit for drains, flushes, or SC discards —
the head advances the cycle after a drain completes, so an early credit
would let dispatch send a store the SQ must refuse (a silently lost store).
Back-pressure is therefore only ever conservatively long, never short.

## Widen-commit slot 2

The SQ accepts a parallel slot-2 commit port
(`i_commit_valid_2`, `i_commit_rob_tag_2`, plus combinational twin
for the same-cycle partial-flush guard). Slot 2 only ever retires
plain stores — SC / AMO are forced onto slot 1 by the ROB's
widen-commit hazard gate — so there's no SC-discard path sharing.
Forwarding scans both slot 1 and slot 2 commits in the same cycle.

## Same-cycle commit hazard

When a partial flush and a ROB commit fire on the same cycle, the
registered commit signal is one cycle behind the flush, which means
the flush could otherwise wipe out a store that's being committed
right then. The SQ takes a combinational commit guard from the ROB
in addition to the registered version, so it can catch in-flight
commits before they're flushed away.

## SC discard

If a store-conditional fails (the LR reservation was lost), the ROB
sends an SC discard signal to the SQ to drop the SC's entry without
writing memory. The reservation register itself lives in the LQ.

## Storage strategy

Hybrid FF + LUTRAM, same idea as the LQ. Control fields stay in
flip-flops for parallel CAM-style scan; the 64-bit data payload
lives in two duplicated LUTRAM instances (identical writes,
different read addresses) so the forwarding scan and the head
writeback can read different entries on the same cycle. The
forwarding scan finds the match index from the FF fields, then reads
`sq_data` from one LUTRAM at that single address.

The forwarding-check address arrives on two functionally-identical
ports, `i_sq_check_addr` and `i_sq_check_addr_b` (a `dont_touch`'d
LQ-side replica). Entries in the lower half compare against the
first, the upper half against the second, so the per-entry CARRY8
compare chains split across two physical anchor points instead of
fanning out from one source FF.

## Verification

Cocotb tests cover allocation including 2-wide cases, address/data update,
every store size, FSD two-phase, store-to-load forwarding, MMIO bypass,
partial/full flush, SC discard, and constrained random. Inline formal
properties cover pointer/count consistency, write prerequisites, the
committed-survives-flush invariant, and forwarding.
