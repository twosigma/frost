# FU CDB Adapter

A one-entry holding register between an FU and the two-lane CDB. A result the
arbiter does not grant is latched and re-presented until it is accepted. The
wrapper instantiates one adapter per FU slot.

## What it provides

- `o_result_pending` back-pressures the FU shim and the RS while a result
  waits.
- Zero-latency pass-through when the arbiter grants on either lane in the
  same cycle the FU result arrives. This is the default. Setting the
  `REGISTER_OUTPUT` parameter disables it: every result is captured into the
  register first, and the output stays invalid in the idle cycle. The wrapper
  sets `REGISTER_OUTPUT=1` on the DIV adapter and the three FP adapters (add,
  mul, div): the long-latency or non-critical units where the pass-through
  valid cone hurts timing.
- Partial-flush support. A held result whose tag is younger than the flush
  boundary is dropped, and a same-cycle pass-through of a younger result is
  suppressed locally. The same input-side filter gates the grant-refill
  capture, so a flushed result issued on the flush cycle cannot be captured
  into `held_result` and re-presented after the flush. Without that filter
  the ALU slot did exactly this in CoreMark: the refilled result lost
  arbitration for about 20 cycles and then broadcast to a ROB entry that had
  long since been freed. The kill gates only `o_fu_complete.valid`; the
  payload (value, tag, exception) passes through unsquashed. Every consumer
  qualifies the payload with valid, and the arbiter never grants or
  lane-selects an invalid input, so a killed result's payload is dead data
  and the flush-tag age compare stays off the wide CDB muxes. Full-flush CDB
  suppression lives once at the CDB arbiter's `i_kill` input rather than in
  every adapter, which keeps the broadly-fanned speculative-flush signal out
  of this module's output cone. `i_flush` is still wired in: it clears
  `result_pending` on the next edge, while the combinational output filters
  only partial flushes.

## Behavior

`result_pending` is the only state bit:

- Idle, no input: output invalid.
- Idle, input arrives, granted same cycle: pass through and stay idle. Zero
  latency.
- Idle, input arrives, not granted: latch the input and go pending.
- Pending, granted, no new input: clear and return to idle.
- Pending, granted, new input arrives: latch the new input and stay pending.
  This back-to-back refill is gated by the `ALLOW_GRANT_REFILL` parameter.
  The wrapper sets it to 0 on MUL, DIV, MEM and the three FP adapters so that
  CDB arbitration does not feed back into the FU FIFO and issue cones. Only
  the two integer ALU pipes keep refill enabled. On the MEM adapter the
  setting is also what lets SC commit ordering serialize. With refill
  disabled a grant always clears to idle, even when a new input is present.

`held_result` has no reset and is written on every valid idle input, whether or
not that input is granted or flushed in the same cycle. `result_pending` is the
only visibility bit, so a payload captured on such a cycle stays dormant until
the next pending capture overwrites it. This keeps grant and full flush off the
wide write-enable cone.

`ALLOW_GRANT_REFILL_PAYLOAD_WRITE` controls only how that wide write enable is
implemented; it does not change the `result_pending` state machine. At its
default of 1 the register also captures on the grant-refill cycle (when
`ALLOW_GRANT_REFILL` allows it), so the enable carries `result_pending` and the
CDB grant. Setting it to 0 declares that `i_fu_result.valid` and
`result_pending` never coincide, which lets `i_fu_result.valid` alone serve as
the write enable and removes both pending and grant from the wide CE cone.
Both integer-ALU wrapper instances use this mode: each adapter's pending bit
deasserts the matching INT-RS ready input before the combinational ALU shim
can assert valid, and the wrapper asserts that invariant
(`p_alu_pending_blocks_payload_refill`, `p_alu2_pending_blocks_payload_refill`).

`o_held_value` is an unqualified view of the value field of that same
`held_result` register; it adds no storage and is not a second validity path.
For a valid pending integer-ALU packet the wrapper uses this register Q
directly as the pre-edge merge-tree fallback, instead of routing through the
adapter's pending/live output mux. The wrapper also samples a valid-qualified
live-source selector on the CDB edge and reads the same Q after that edge. A
same-cycle-granted integer-ALU value, which `held_result` captures even though
`result_pending` stays clear, is therefore restored on the registered broadcast
side without another wide live-value register bank. The other adapter
instances leave this port open.

The two "idle, input arrives" cases above assume the default pass-through
mode. With `REGISTER_OUTPUT` set there is no combinational pass-through: a
valid idle input always latches into the register, even if granted that cycle,
and is presented from pending the following cycle, so every result takes one
extra cycle.

## Verification

The `` `ifdef FORMAL `` block asserts every state transition, stability of
tag, value and exception fields while pending, pass-through correctness (and
the registered-output mode's idle-invalid output), the flush semantics, and
that `o_result_pending` mirrors the state bit. A flushed-tag discipline check
watches an arbitrary tag: once a partial or full flush squashes it, as held
state or as a same-cycle input including the grant-refill case, that tag must
not reappear on `o_fu_complete` until a new input re-presents it. Cover
properties reach the multi-cycle pending case, back-to-back grants, and the
squashed-refill case. `formal/fu_cdb_adapter.sby` runs BMC and cover with the
default parameters. `formal/fu_cdb_adapter_payload_no_refill.sby` runs BMC
with `ALLOW_GRANT_REFILL_PAYLOAD_WRITE=0`, assuming the no-input-while-pending
contract and checking that every valid input is captured. The cocotb tests
`fu_cdb_adapter` and `fu_cdb_adapter_payload_no_refill` cover the same two
configurations.
