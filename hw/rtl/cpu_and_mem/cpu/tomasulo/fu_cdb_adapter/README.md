# FU CDB Adapter

A one-deep holding register between a functional unit and the 2-lane CDB
arbiter. When the FU produces a result and the arbiter can't grant either CDB
lane the same cycle (because two higher-priority FUs are also completing), the
adapter latches the result and re-presents it on subsequent cycles until
granted. The wrapper instantiates one per FU slot.

## What it provides

- **Back-pressure** to the FU shim / RS via `o_result_pending`, so
  the RS stalls new issues while a result is waiting for CDB access.
- **Zero-latency pass-through** when the arbiter grants on either lane in the same
  cycle the FU result arrives — no register on the common case. This
  is the default; setting the `REGISTER_OUTPUT` parameter disables it
  so every result is captured into the register first (output stays
  invalid in the idle cycle). The wrapper uses `REGISTER_OUTPUT=1`
  for the long-latency / non-critical FUs (DIV, FP add/mul/div) where
  the pass-through valid cone hurts timing.
- **Partial-flush hygiene (state only — the output is not filtered
  here).** Held state never survives a partial flush: a held result
  whose tag is younger than the flush boundary is dropped from the
  register, and the same input filter gates the grant-refill capture,
  so a flushed result issued on the flush cycle can't be latched as
  held state. The combinational `o_fu_complete` presents un-killed:
  partial-flush broadcast suppression is centralized at the registered
  CDB bus valids in `tomasulo_wrapper` (one age compare per lane on
  the arbiter winner's tag), and full-flush suppression lives once in
  the CDB arbiter's `i_kill` input — so this module's output cone
  carries neither the broadly-fanned speculative-flush signal nor the
  flush-tag age compare. A doomed result may therefore still win a
  grant on the flush cycle; the grant just frees this adapter's slot,
  and no consumer ever observes the masked broadcast. The full-flush
  `i_flush` input is still wired in — it clears the `result_pending`
  register on the next edge.

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
  `ALLOW_GRANT_REFILL` parameter — the wrapper sets it to 0 for every
  adapter except the two integer ALU pipes, e.g. on the MEM adapter
  so SC commit ordering can serialize correctly. With refill
  disabled, a grant
  always clears to idle even if a new input is present.)

The two "idle, input arrives" cases above assume the default
pass-through mode. When `REGISTER_OUTPUT` is set there is no
combinational pass-through: a valid idle input always latches into
the register (even if granted that cycle) and is presented from
PENDING the following cycle, so results take one extra cycle.

## Verification

The module's state space is small enough to verify exhaustively with
formal methods. The `` `ifdef FORMAL `` block proves all the
state transitions, the tag/value/exception stability while pending,
the pass-through correctness (and the registered-output mode's
idle-invalid output), the flush semantics, and the back-pressure
invariants — plus cover properties for the multi-cycle pending case
and back-to-back grants.
