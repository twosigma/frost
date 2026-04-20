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
- **Partial-flush support.** Held results whose tag is younger than
  the partial-flush boundary are dropped, and a same-cycle
  pass-through of a younger result is suppressed locally. Full-flush
  CDB suppression lives once in the CDB arbiter's `i_kill` input
  rather than replicated in every adapter, so this module's output
  cone doesn't have to carry the broadly-fanned speculative-flush
  signal. The full-flush `i_flush` input is still wired in — it just
  clears the `result_pending` register on the next edge; the
  combinational output only filters partial flushes.

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
