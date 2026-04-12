# Store Queue

The SQ holds in-flight stores from dispatch until the ROB commits
them, at which point the head entry writes to memory. Stores are
non-speculative: nothing leaves the SQ until commit, so flushed
speculative stores never reach the bus.

## What makes stores interesting

Two things: forwarding and ordering.

**Forwarding.** A younger load may need data from an older store
that's still in the SQ. When the LQ asks the SQ to disambiguate a
load address, the SQ scans all entries combinationally for a
matching older store. If one is found and the sizes are compatible,
the SQ forwards the data directly to the LQ — no memory access. If
the sizes don't match, or some older store address isn't known yet,
the SQ tells the LQ to wait.

**Ordering.** Stores commit in program order from the SQ head. The
head fires when it's both committed (by the ROB) and has its address
and data ready. FSD on the 32-bit bus takes two phases (low word at
addr, high word at addr+4); the entry has a phase bit and isn't
freed until both writes complete.

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
writeback can read different entries on the same cycle.

## Verification

Cocotb tests cover allocation, address/data update, every store
size, FSD two-phase, store-to-load forwarding, MMIO bypass,
partial/full flush, SC discard, and constrained random. Inline
formal properties cover pointer/count consistency, write
prerequisites, the committed-survives-flush invariant, and forwarding.
