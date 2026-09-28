# FU CDB Adapter

`fu_cdb_adapter` is a one-entry holding register between a functional unit
(FU) and the [CDB arbiter](../cdb_arbiter/README.md). The wrapper instantiates
one per FU slot that has a unit, six in all. If the arbiter grants a result on
either lane in the cycle it arrives, the adapter passes it straight through
with no added latency. Otherwise the adapter latches it and presents it every
cycle until it is granted. `o_result_pending` tells the wrapper a result is
waiting. The MUL and MEM instances use `ALWAYS_GRANTED` to keep the pending
flag constant and remove unreachable holding logic.

## Behavior

`result_pending` is the control-state bit in the default configuration:

| State | Input and grant | Action |
|-------|-----------------|--------|
| Idle | No input | Output invalid |
| Idle | Input, granted | Pass it through and stay idle |
| Idle | Input, not granted | Latch it and go pending |
| Pending | Not granted | Keep presenting the held result; ignore any input |
| Pending | Granted, no input | Clear and go idle |
| Pending | Granted, new input | Latch the new input and stay pending (refill) |
| Pending | Flush covers the held result | Clear and go idle |

With `REGISTER_OUTPUT` set there is no pass-through: an idle adapter latches
its input instead and presents it from the pending state the next cycle, so
each result takes one extra cycle. With `ALLOW_GRANT_REFILL` clear, a pending
adapter that is granted always goes idle, and an input that arrives in that
cycle is not taken.

## Parameters

| Parameter | Default | Effect when changed |
|-----------|---------|---------------------|
| `REGISTER_OUTPUT` | 0 | 1: no pass-through; every result spends a cycle in the register. |
| `ALLOW_GRANT_REFILL` | 1 | 0: a granted pending adapter goes idle and does not take a new input in the same cycle. |
| `ALLOW_GRANT_REFILL_PAYLOAD_WRITE` | 1 | 0: `held_result` is written on every valid input, a simpler write enable. Legal only if a valid input never arrives while the adapter is pending. |
| `ALWAYS_GRANTED` | 0 | 1: pending is constant zero. Requires `REGISTER_OUTPUT=0`, `ALLOW_GRANT_REFILL=0`, and a grant for every valid output except when full flush discards it. Simulation asserts that grant contract. |

The wrapper's settings:

| Adapters | `REGISTER_OUTPUT` | `ALLOW_GRANT_REFILL` | `ALLOW_GRANT_REFILL_PAYLOAD_WRITE` | `ALWAYS_GRANTED` |
|----------|-------------------|----------------------|------------------------------------|------------------|
| ALU, ALU2 | 0 | 1 | 0 | 0 |
| MUL, MEM | 0 | 0 | 1 | 1 |
| DIV, FP | 1 | 0 | 1 | 0 |

`REGISTER_OUTPUT` suits the long-latency units, where one more cycle costs
little and the pass-through valid path hurts timing.

Disabling refill keeps the arbiter's grant out of the producers' FIFO and
issue logic. The producers follow a matching rule: a result counts as taken
only when the adapter is idle. The MUL and DIV paths and the LQ hand over a
result only while their adapter is idle (a squashed result is dropped without
waiting), and FP_RS stops issuing while the FP adapter is pending. A granted
adapter therefore drains first and takes the next result the following cycle. The two sides must change together: an adapter that
refilled while its producer waited for idle would take the same result twice.
The MEM slot's store-fault and SC registers do not wait; they rely on the MEM
adapter never being pending (see the
[CDB arbiter](../cdb_arbiter/README.md#priority)).

MUL and MEM are the two highest priorities on the two-lane CDB. Every valid
result from either gets a grant, except on a full flush that discards it.
Their stateful adapters therefore never leave idle after reset. Setting
`ALWAYS_GRANTED` makes that pending bit a constant, removing the holding-state
feedback and held/input payload muxes without changing latency. Both still
apply the same partial-flush age check to incoming results and connect to the
actual grant for the simulation assertion. The `mul_adapter_grant` formal
target proves both instances against the actual arbiter with arbitrary
competing and test-injected results, flushes, and tags. It also retains the
earlier MUL local-grant equivalence check.

The ALU adapters keep refill enabled, but a pending ALU adapter deasserts its
INT RS ready, so the combinational ALU shim never presents a result while the
adapter is pending; the wrapper asserts this. The same guarantee makes
`ALLOW_GRANT_REFILL_PAYLOAD_WRITE=0` legal on both ALU adapters.

## Flushes

A partial flush (`i_flush_en` with `i_flush_tag`, ages measured from
`i_rob_head_tag`) drops a held result younger than the flush point: it is
hidden at once and cleared on the next edge. The same age check hides a
younger result passing through and keeps a refill from taking one, so a
result issued in the flush cycle cannot resurface later. The kill clears only
`valid`. The value, tag, and other fields pass through unchanged, so every
consumer must qualify them with `valid`; the arbiter never grants or selects
an invalid input. This keeps the age compare off the wide value path.

A full flush (`i_flush`) clears `result_pending` on the next edge but leaves
the output alone in the flush cycle. The arbiter's `i_kill` suppresses the
broadcast instead, once for all six adapters.

## Held payload

`held_result` has no reset. It captures every valid input that arrives while
the adapter is idle, even one that is granted or flushed in the same cycle;
`result_pending` alone decides whether the stored payload is visible. This
keeps the grant and the full flush out of the wide register's write enable.

The ALU adapters depend on that capture. `o_held_value` exposes the stored
value, unqualified, and the wrapper uses it twice: as the merge-tree fallback
value for a pending ALU result, and to restore a live ALU value after the CDB
register (see the [CDB arbiter](../cdb_arbiter/README.md#live-alu-values)).
The other adapters leave `o_held_value` unconnected.

## Verification

The `fu_cdb_adapter` cocotb and formal targets cover the default parameters:
pass-through, held results, back-pressure, both flushes, and tag reuse (a
flushed tag never reappears until a new input brings it back).
`fu_cdb_adapter_payload_no_refill` covers `ALLOW_GRANT_REFILL_PAYLOAD_WRITE=0`;
its formal target assumes no input arrives while the adapter is pending, which
the wrapper asserts. The wrapper tests exercise every instance in place.

See the [test runner](../../../../../../tests/README.md) for commands and the
[formal guide](../../../../../../formal/README.md) for proof scope and assumptions.
