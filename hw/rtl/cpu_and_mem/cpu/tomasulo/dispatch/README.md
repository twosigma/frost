# Dispatch

Dispatch moves instructions from the in-order front end into the
out-of-order back end. Each cycle it takes a bundle of up to two decoded
instructions and, for each one it fires, allocates a ROB entry, looks up its
sources in the RAT, renames its destination, sends it to a reservation
station, and saves a checkpoint if it is a branch or jump. It also checks LQ
and SQ room for memory operations; the wrapper allocates those entries from
the MEM_RS packet. When a needed resource is full, the bundle waits.

Bundles come from the head of the decoded queue that ID fills
(`DECODED_QUEUE_DEPTH`, four bundles by default), or straight from the ID
pipeline register when the queue is disabled. Dispatch is combinational apart
from the registered done-repair request (see
[Source operands](#source-operands)): the fire decision and every packet are
same-cycle functions of the bundle and the back end's resource status.
[`dispatch.sv`](dispatch.sv) is instantiated in `cpu_ooo.sv`, beside the
[Tomasulo back end](../README.md) it feeds.

## 2-wide bundle rules

Slot 2 fires only when slot 1 does, and a bundle fires or stalls as a unit.
If a valid slot 2 lacks room in a structure it needs, the whole bundle waits
and is presented again next cycle, so slot 2 never reaches the back end
alone. Slot 1 control flow ends a bundle: the front end never pairs an
instruction behind a slot-1 branch or jump, and dispatch refuses such a slot 2
as well. A bundle therefore holds at most one branch or jump, and only slot 2
of a pair can be one.

FP-compute ops (bound for the FP, FMUL, or FDIV station) stay out of slot 2;
FP loads and stores go to MEM_RS and may use either slot. The instruction
aligner advances past slot 1 alone when the next instruction is an
FP-compute op, so that op arrives later as slot 1. Dispatch backs this up by
treating an FP-compute slot 2 as absent, so slot 1 fires alone.

Slot 2's room checks account for slot 1. The ROB check always uses
`i_rob_full_for_2`. A station, the LQ, or the SQ uses its "full for 2" status
when slot 1 needs the same structure, and its plain full status otherwise.
The checkpoint check is plain `i_checkpoint_available`, since a bundle saves
at most one checkpoint. When slot 2 is the branch,
`o_checkpoint_save_for_slot2` tells the RAT to include slot 1's same-cycle
rename in the snapshot.

With the decoded queue (the default), cpu_ooo sets `SLOT2_VALID_FROM_BUNDLE`,
and dispatch takes slot 2's presence from the bundle's `is_real` bit (a real
instruction rather than a bubble) instead of `i_valid_2`. The queue drives
`i_valid_2 == i_valid && is_real`, and an assertion checks it.

## Source operands

Each source reads the INT or FP RAT, as the `uses_int_rs*` and `uses_fp_rs*`
flags from ID select, and becomes an RS operand:

- A source that is not renamed is ready, with its value from the register
  file (passed through the RAT). Its tag is meaningless and must not take
  part in wakeup or done repair.
- A renamed source carries the producer's ROB tag and waits for the CDB. The
  producer may have broadcast already, so dispatch also sends a registered
  done-repair request (channels 1 to 3 for slot 1, 4 to 6 for slot 2). One
  cycle later the wrapper checks whether that ROB entry is done and, if so,
  wakes the RS entry with the ROB's value.
- A slot-2 source that reads slot 1's destination gets slot 1's new ROB tag,
  because the RAT lookup ran before slot 1's rename.

For an FP instruction with `rm = DYN`, dispatch writes the current `frm` into
the RS entry. Every CSR instruction keeps younger instructions out of
dispatch until its CSR write and register writeback are done, so this is the
rounding mode in program order.

## Stalls

Dispatch stalls when a resource it needs is exhausted: the ROB, the target
station, the LQ (loads, LR, AMOs), the SQ (stores, SC), or the checkpoint
pool (branches and jumps). The early back-end recovery hold (`i_hold`)
blocks firing too. `o_status` gives each slot-1 resource its own flag, plus
`slot2_block_*` flags for cycles where slot 2 alone holds the bundle, so the
[counter aggregator](../../cpu_ooo/perf/perf_counter_aggregator.sv) can count
those causes directly. The recovery hold has no flag of its own.

`o_stall` is `dispatch_valid && !bundle_fire_ok`: a valid bundle is blocked.
`o_status.stall` has the same value and feeds the counters. With the decoded
queue, the front end stalls on the queue's full flag, and a bundle leaves the
queue only when it allocates.

Without the queue, pipeline control uses `o_stall` to stall the front end and
replay the blocked ID packet, and there it must stay qualified by validity. A
stall on resource status alone can make an instruction dispatch twice: X
dispatches while another stall holds ID, and the next cycle ID still holds
X's image, now invalid. If X's resource has filled by then, the unqualified
stall replays X as valid, and X dispatches again once room returns. For
timing, a resource-only term may drive the front-end hold, but the replay
must keep the qualified term; registering the stall needs capture capacity,
such as a one-entry ID-to-dispatch skid buffer.

## RS routing

ID pre-decodes each instruction's station (`rs_type`); the table is in the
[back-end overview](../README.md) under "Instruction → reservation station
routing". Dispatch emits one packet per station for each slot and sets
`valid` only on the selected one.

JAL, WFI, MRET, SRET, and DRET have no station (`rs_type == RS_NONE`) and
allocate only a ROB entry. JAL is done at allocation, since its link
address and target are known then. WFI and the xRETs are also done at
allocation and wait at the ROB head in the serializing FSM (see "Serializing
instructions" in the same overview, and in the
[ROB](../reorder_buffer/README.md#serializing-instructions)).

For a fetch-fault pseudo-op, dispatch clears the JAL, JALR, FENCE, FENCE.I,
WFI, and xRET class bits in the ROB request. The faulting page's bytes can
decode as any of them, and a done-at-allocation class would let the entry
retire before its fault arrived.

## PC-derived immediates

The RS immediate word carries values ID precomputes from the PC, so the ALU
never needs the PC:

| Instruction | `imm` carries |
|-------------|---------------|
| Conditional branch | `branch_target_precomputed`, the taken target |
| AUIPC | PC + U-immediate |
| JALR | The link address; the 12-bit offset travels in `jalr_imm` |
| Fetch-fault pseudo-op | The xtval: the PC, or PC + 2 when only the second halfword of a page-straddling instruction faulted |

A conditional branch also gets `predicted_target_ok`: ID's comparison of its
target with the prediction, from the same source as `predicted_target` (the
RAS if it predicted, else the BTB). Branch resolution checks this one bit
instead of comparing addresses, and a simulation check compares it with the
full comparison for every dispatched conditional branch predicted taken.
JALR compares its computed target with `predicted_target` at execute.

The INT station keeps `pc`, `link_addr`, and `predicted_target` in a
ROB-tag-indexed side RAM for branch resolution and early recovery (see the
[reservation station](../reservation_station/README.md)). The ROB request
carries its own copies of the PC, link address, and targets for commit-time
recovery and predictor training.

## Verification

The `dispatch` cocotb target covers stalls, station routing, source
resolution and renaming, two-slot bundles, checkpoints, immediates, and
rounding modes. The `dispatch_admission` formal target checks the bundle
admission equations with `SLOT2_VALID_FROM_BUNDLE` off and on.

See the [test runner](../../../../../../tests/README.md) for commands and the
[formal guide](../../../../../../formal/README.md) for proof scope and assumptions.
