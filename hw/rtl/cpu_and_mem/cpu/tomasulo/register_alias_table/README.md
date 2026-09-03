# Register Alias Table

The RAT maps architectural registers (x0–x31, f0–f31) to the ROB tags of
their in-flight producers. Dispatch reads sources and writes renames; commit
clears a mapping once the architectural register file holds the value.

INT and FP have separate tables with the same `{valid, tag}` entry format.
x0 is hardwired: reads return zero and writes are ignored.

Up to ten sources are looked up per cycle, two INT and three FP for each of
the two dispatch slots. A lookup returns the regfile value when the
architectural register is current, or the ROB tag of the producing
instruction when the register is renamed and still in flight.

## Branch checkpoints

Speculation needs a way to roll back the rename state. Every branch, JAL, or
JALR reserves a checkpoint at dispatch. The checkpoint snapshots the full INT
RAT, the FP RAT, the RAS state (top-of-stack pointer and valid count), and
the owning branch's ROB tag and epoch. On misprediction, the snapshot
replaces the active RAT in a single cycle.

There are eight checkpoint slots; dispatch stalls when all are occupied.
Snapshots live in distributed RAM, 8 slots × (64 entries × 7 bits + 13
metadata bits), which saves several thousand flip-flops over keeping them in
registers. The active RATs stay in flip-flops because they need parallel
lookup, per-entry commit clear, and a bulk overwrite on restore.

For 2-wide dispatch, slot 1 and slot 2 have separate rename write ports. If
slot 2 is the control-flow instruction that owns the checkpoint, the snapshot
overlays slot 1's same-cycle rename before it is saved, so recovery returns
to the state visible immediately before slot 2.

## Stale rename detection

When the ROB recycles a tag (allocation wraps), an in-flight rename that
points at the old generation could otherwise look valid. The RAT consumes
the ROB's per-entry valid vector and treats any lookup whose tag points at an
invalid entry as architectural rather than renamed.

Checkpoints capture one more bit per snapshot entry, and one for the owning
branch: the ROB allocation generation. Restore rejects a snapshot entry whose
tag has wrapped since the checkpoint was taken, whose tag is not strictly
older than the restoring branch, or whose owner branch has already retired
or been recycled.

## Widen-commit slot 2

A parallel slot-2 commit port (`i_commit_valid_2`, `i_commit_dest_valid_2`,
`_dest_rf_2`, `_dest_reg_2`, `_tag_2`) sits alongside the primary commit
port so the ROB's 2-wide commit can clear both renames in one cycle. The
slot-2 clear mirrors slot 1 and uses the same tag-compare guard: a slot
clears the RAT entry only if its tag still matches, so a younger dispatch
that has re-renamed the register is preserved.

When both slots target the same architectural register, slot 2 (head+1) is
the younger producer in program order, so the RAT holds its tag. Slot 1's
tag compare misses and only slot 2's clear takes effect. Rename still has
priority over commit: a simultaneous dispatch writing the same register wins
over both slot clears.

## Bulk free

Besides the two per-checkpoint free ports that two-wide commit needs, the
RAT accepts a bulk free mask (`i_checkpoint_flush_free_mask`) that clears
several checkpoint slots in one cycle. The misprediction flush controller
drives it when a partial flush kills the branches younger than the flush
point: every flushed branch's checkpoint is reclaimed without going through
a per-slot port.

## Verification

Cocotb tests cover lookup, slot-2 lookup, rename (including overwrite,
slot-2 rename, slot-2-wins collisions, and rename-over-commit precedence),
slot-1/slot-2 commit clear, checkpoint save/restore/free, slot-2 checkpoint
overlay, checkpoint bulk-free masks, checkpoint exhaustion, flush-all,
regfile value passthrough, and x0 invariants. Inline formal properties prove
the x0 invariant, the slot-1 and slot-2 rename state transitions, the INT
commit-clear state transition, and that flush/reset clear the active RATs
and checkpoint valid bits.
