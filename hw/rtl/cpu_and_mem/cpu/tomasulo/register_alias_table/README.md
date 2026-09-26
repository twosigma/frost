# Register Alias Table

The RAT maps architectural registers (x0–x31, f0–f31) to the ROB tags of
their in-flight producers. Dispatch reads sources and writes renames; commit
clears a mapping once the architectural register file holds the value. The
RAT also keeps eight checkpoints of the whole mapping, so a mispredicted
branch can restore it in one cycle. The code is
[`register_alias_table.sv`](register_alias_table.sv).

INT and FP have separate tables with the same `{valid, tag}` entry format.
x0 is hardwired: reads return zero and writes are ignored.

Up to ten sources are looked up per cycle, two INT and three FP for each of
the two dispatch slots. A lookup returns the register-file value when the
architectural register is current, or the producer's ROB tag when the
register is renamed and still in flight.

Slot 1 and slot 2 have separate rename ports. When both rename the same
register, slot 2 wins as the younger producer. Slot 2 can also rename alone,
when slot 1 has no destination. A slot-2 source that reads slot 1's
destination is resolved in [dispatch](../dispatch/README.md); the RAT never
sees that case.

## Branch checkpoints

Every branch, JAL, or JALR reserves a checkpoint at dispatch. The checkpoint
snapshots the full INT and FP RATs, the RAS state (top-of-stack pointer,
valid count, and top entry), and the owning branch's ROB tag and generation
bit (see below). On misprediction, the snapshot replaces the active RAT in a single
cycle.

There are eight checkpoint slots. While all are occupied, a bundle that
contains a branch or jump waits at dispatch; other bundles still dispatch.
Snapshots live in distributed RAM: 8 slots × (64 entries × 7 bits + 77
metadata bits), 4,200 bits that would otherwise be flip-flops. An entry is a
valid bit, a generation bit, and the 5-bit tag. The active RATs stay in
flip-flops because they need parallel lookup, per-entry commit clear, and a
bulk overwrite on restore.

If slot 2 is the control-flow instruction that owns the checkpoint, the
snapshot includes slot 1's same-cycle rename, so recovery returns to the
state just before slot 2.

## Stale rename detection

A lookup reports a register as renamed only if its tag points at a valid ROB
entry (the RAT reads the ROB's per-entry valid vector); otherwise the
consumer takes the register-file value. This covers a mapping whose producer
has already left the ROB, as in the cycle between retirement and the RAT's
commit clear, which arrives on the registered commit bus. The tag field is
meaningful only when `renamed` is set. Dispatch compares the raw tag in
parallel with the renamed check, and source-ready and registered
repair-valid flags qualify every consumer. INT x0 always returns all zeros.

Restoring a checkpoint needs a stronger test, since tags a snapshot names may
have been reallocated by then. cpu_ooo flips a per-entry generation bit
(`rob_entry_epoch`) on every ROB allocation, and a snapshot records it for
each entry and for the owning branch. A restored mapping stays renamed only
if the branch is still in the ROB with its saved generation, the mapped
entry is still valid with its saved generation, and that entry is strictly
older than the branch.

## Widen-commit slot 2

A second commit port (`i_commit_valid_2`, `i_commit_dest_valid_2`,
`_dest_rf_2`, `_dest_reg_2`, `_tag_2`) lets the ROB's two-wide commit clear
both renames in one cycle. Each port clears an entry only if its tag still
matches, so a younger rename of the same register survives. When both slots
target one register, the RAT cannot hold slot 1's tag (slot 2 renamed the
register after it), so only slot 2's clear can take effect. Rename has
priority over commit: a dispatch writing the same register in the same cycle
wins over both clears.

## Bulk free

Besides the two per-checkpoint free ports that two-wide commit needs, a bulk
free mask (`i_checkpoint_flush_free_mask`) clears several checkpoint slots at
once. The misprediction flush controller drives it one cycle after a partial
flush, with every checkpoint younger than the flush point, or every
checkpoint in use after a commit-time recovery that empties the ROB.

## Verification

The `register_alias_table` cocotb target covers two-slot renaming and commit,
checkpoint management, flushes, and x0. The `register_alias_table` formal
target checks rename and commit-clear transitions, reset and flush behavior,
and the x0 invariant.

See the [test runner](../../../../../../tests/README.md) for commands and the
[formal guide](../../../../../../formal/README.md) for proof scope and assumptions.
