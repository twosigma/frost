# Register Alias Table

The RAT maps architectural registers (x0–x31, f0–f31) to in-flight
ROB tags. It's read by dispatch on every cycle to look up source
operands, written by dispatch to rename destinations, and cleared
by ROB commit when the architectural value catches up.

INT and FP have separate tables, both with the same `{valid, tag}`
entry format. x0 is hardwired — reads always return zero, writes
are silently ignored.

Up to five sources are looked up per cycle: rs1 + rs2 from INT, plus
fs1 + fs2 + fs3 from FP for FMA. Each lookup returns either the
regfile value (if the architectural register is current) or the ROB
tag of the producing instruction (if it's renamed and still in flight).

## Branch checkpoints

Speculation needs a way to roll back the rename state. Every branch
or JALR reserves a checkpoint at dispatch that snapshots the full
INT RAT, FP RAT, and RAS state (top-of-stack pointer + valid count).
On misprediction, the checkpoint atomically replaces the active RAT
in a single cycle.

There are 8 checkpoint slots. With 4–8 branches typically in flight
at a time, exhaustion is rare; when it happens dispatch stalls until
a slot frees. The checkpoint snapshots themselves live in distributed
RAM — saving roughly a thousand flip-flops compared to keeping them
in registers — while the active RATs stay in FFs because they need
parallel lookup, parallel CDB-driven invalidation, and bulk parallel
overwrite on restore.

## Stale rename detection

When the ROB recycles a tag (allocation wraps), an in-flight rename
that points at the old generation could otherwise look valid. The
RAT consumes the ROB's per-entry valid vector and treats any lookup
whose tag points at an invalid entry as architectural rather than
renamed. Checkpoints additionally capture an alloc-generation bit so
restore can reject snapshot entries whose tag has wrapped since the
checkpoint was taken.

This is the kind of subtle correctness bug that's invisible until a
particular branch-heavy code path with deep ROB occupancy hits the
wraparound; the formal proof catches it.

## Widen-commit slot 2

The RAT accepts a parallel slot-2 commit port
(`i_commit_valid_2`, `i_commit_dest_valid_2`, `_dest_rf_2`,
`_dest_reg_2`, `_tag_2`) alongside the primary commit port so the
ROB's 2-wide commit can clear both renames in a single cycle. The
slot-2 clear block mirrors slot 1 and uses the same tag-compare
guard: a slot only clears the RAT entry if its tag still matches
(a younger dispatch that has re-renamed the register is preserved).

When both slots target the same architectural register, the ROB's
widen-commit hazard gate guarantees slot 2 carries the newer value;
slot 1's tag compare necessarily misses (slot 2's rename has since
replaced the entry), so only slot 2's clear takes effect. The
existing rename-over-commit priority also still holds — a
simultaneous dispatch writing the same register wins over both
slot clears.

## Bulk free

In addition to per-checkpoint free (driven by ROB commit on a
correctly-predicted branch), the RAT accepts a bulk free mask that
clears multiple checkpoint slots in one cycle. The wrapper uses
this when a partial flush wipes out a contiguous range of younger
speculative branches at once — every flushed branch's checkpoint
gets reclaimed without going through the per-slot port.

## Verification

Cocotb tests cover lookup, rename, commit clear, checkpoint
save/restore/free, x0 invariants, and bulk reclaim. Inline formal
properties prove the x0 invariant, the rename / commit / restore
state transitions, and the absence of double-allocation.
