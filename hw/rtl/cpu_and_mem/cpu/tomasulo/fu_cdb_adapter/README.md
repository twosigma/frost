# FU CDB Adapter

A one-deep holding register between a functional unit and the CDB
arbiter. When the FU produces a result and the arbiter can't grant
the CDB the same cycle (because a higher-priority FU is also
completing), the adapter latches the result and re-presents it on
subsequent cycles until granted. The wrapper instantiates one per
FU slot.

## What it provides

- **Back-pressure** to the FU shim / RS via `o_result_pending`, so
  the RS stalls new issues while a result is waiting for CDB access.
- **Zero-latency pass-through** when the arbiter grants on the same
  cycle the FU result arrives — no register on the common case.
- **Flush support**, both full and partial. Held results whose tag
  is younger than the partial-flush boundary are dropped, and the
  output is gated combinationally on full flush so the arbiter
  doesn't see one extra cycle of stale `valid` while the
  `result_pending` register catches up. (Without that gate, phantom
  grants would propagate down a long critical path through the
  arbiter into the FP_DIV shim's FIFO logic — a real bug, found
  during timing closure.)

## Behavior

There's one state bit (`result_pending`):

- **Idle, no input**: output invalid.
- **Idle, input arrives, granted same cycle**: pass through; stay
  idle. Zero latency.
- **Idle, input arrives, not granted**: latch the input, transition
  to pending.
- **Pending, granted, no new input**: clear; back to idle.
- **Pending, granted, new input arrives**: latch the new input;
  stay pending. (This back-to-back behavior is gated by the
  `ALLOW_GRANT_REFILL` parameter — the wrapper sets it to 0 for the
  MEM adapter so SC commit ordering can serialize correctly.)

## Verification

The whole reason this module is small enough to be slightly
interesting is that its state space is also small enough to formally
verify exhaustively. The `` `ifdef FORMAL `` block proves all the
state transitions, the tag/value/exception stability while pending,
the pass-through correctness, the flush semantics, and the
back-pressure invariants — plus cover properties for the
multi-cycle pending case and back-to-back grants.
