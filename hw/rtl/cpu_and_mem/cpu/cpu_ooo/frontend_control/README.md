# Frontend validity and decoded bundles

These two `cpu_ooo` submodules sit between the in-order front end and
dispatch. `frontend_validity_tracker` decides which packets in IF, PD, and ID
are real instructions. `decoded_bundle_queue` lets decode run ahead of
dispatch by buffering decoded two-instruction bundles. The
[CPU README](../../README.md) shows where they fit in the front end.

## Validity tracker

A two-stage valid chain (`if_valid_q`, `pd_valid_q`) follows packets from IF
to ID, so the NOP bubbles after a flush or reset, including the one-cycle
post-flush holdoff, never reach dispatch. A bundle is valid if either slot
holds a real instruction, so a `c.nop` in slot 1 still carries its slot-2
instruction. Dispatch, not the tracker, applies the recovery kill.

The tracker also finds unpredicted control flow. An unpredicted indirect jump
in slot 1 of IF (while a stall holds it there), PD, or ID feeds the
control-flow serialization stall in `ooo_pipeline_control`, which holds the
front end while a conditional branch or JALR is unresolved. That stall only
limits wrong-path fetch past the jump; recovery does not depend on it. The PD
and ID per-class signals (conditional branch, JAL, indirect) feed only
[profiling counters](../perf/README.md) 20–22.

## Decoded bundle queue

The queue holds decoded bundles from ID until dispatch takes them. Its depth
is the `DECODED_QUEUE_DEPTH` parameter, default `riscv_pkg::DecodedQueueDepth`
(4). A nonzero depth must be a power of two of at least 2. Depth 0 removes the
queue: ID feeds dispatch directly, dispatch back-pressure stalls the front
end, and ID replays its held bundle when the stall clears. One exception
applies in that mode: if an unrelated stall already held ID when a CSR
dispatched, ID still holds that CSR, so `ooo_pipeline_control` releases it
with one cycle in which ID advances but nothing dispatches. Otherwise the CSR
would dispatch twice. With the queue, the consumed bit below covers this
case.

| Case | Behavior |
|------|----------|
| Queue empty | The bundle in ID's output register reaches dispatch in the same cycle; the queue stores it only if dispatch does not take it |
| Queue full | `o_full` comes from registered occupancy, so dispatch has no combinational ready path back to fetch. A full queue refuses a new bundle even in a cycle when dispatch pops one, and the front end stalls on a full queue rather than on dispatch back-pressure |
| Dispatch | Pops a whole bundle when slot 1 allocates its ROB entry (`rob_alloc_req.alloc_valid`); slot 2, if present, fires in the same cycle |
| Flush | Any pipeline flush (trap, xRET, FENCE-class, or misprediction recovery, early or at commit) empties the queue, as does reset |

ID's output register can hold one bundle for several cycles while an
unrelated front-end stall keeps ID from advancing. A consumed bit records that
the queue has already accepted that bundle, so it is never enqueued twice; the
bit clears when ID advances. ID must not advance past a valid bundle the queue
has not accepted, and an assertion checks this.

Queued bundles hold decode results and prediction metadata, not operand
values. Dispatch reads the register files and RAT with the head bundle's
register fields in the cycle it dispatches, so renaming always sees every
older instruction. After a CSR dispatches, dispatch takes nothing more from
the queue until the CSR has committed and any register result is written back,
because a CSR's CDB broadcast carries only its write operand.

The queue drops all-NOP bundles, except while a debug single step is armed
(`step_armed_fe_q`), so that stepping over a `nop` retires exactly that `nop`.
A dropped NOP never retires, and neither does a NOP in slot 2, which is never
valid, so `instret` counts neither.
It also reports any queued unpredicted JALR (`o_indirect_pending`) to the
control-flow serialization stall. For timing, dispatch reads a flop copy of
the head bundle rather than the queue RAM, and takes its narrow control fields
from a register (`o_shadow`) loaded a cycle early from ID's next-cycle value
(`o_from_id_to_ex_next`).

## Verification

The `decoded_bundle_queue` formal target proves FIFO order, payload
preservation, the consumed-bit rule, occupancy, and flush behavior at depths 2
and 4 with an 8-bit symbolic payload. It assumes an initial reset, legal pops,
and no producer overwrite before acceptance. The `decoded_bundle_queue` and
`decoded_bundle_queue_depth2` cocotb targets run randomized traffic with
bypass, wraparound, full queues, held bundles, reset, and flushes of live
entries. Assertions in `cpu_ooo` check the integration rules in whole-core
simulation.

See the [test runner](../../../../../../tests/README.md) for commands and the
[formal guide](../../../../../../formal/README.md) for proof scope and assumptions.
