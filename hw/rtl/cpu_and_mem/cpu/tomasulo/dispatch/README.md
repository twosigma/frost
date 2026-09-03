# Dispatch

Dispatch renames and allocates up to two decoded instructions per cycle from
the in-order front-end into the Tomasulo back-end.

For each firing slot it allocates a ROB entry, looks up the source operands in
the RAT, renames the destination, routes the instruction to its reservation
station, checks LQ/SQ room for memory operations, and allocates a checkpoint
for branches and jumps. The LQ and SQ entries themselves are allocated by the
wrapper from the MEM_RS packet. The module is mostly combinational: the bundle
fire decision and the dispatch packets are same-cycle functions of the ID
pipeline registers and the Tomasulo resource status. The only local sequential
state is the registered done-repair request path for already-completed sources
(bypass valid/tag channels 1 to 6).

## 2-wide bundle rules

Slot 1 is the anchor. Slot 2 fires only when slot 1 also fires, slot 2 is
valid, slot 1 is not a branch or jump, slot 2 is not an FP-compute op, and
every targeted structure has room for the bundle. The bundle fires or stalls
as a unit, so slot 2 never appears downstream alone.

An FP-compute op is one that targets the FP, FMUL, or FDIV RS; FP loads and
stores go to MEM_RS and may sit in slot 2. The fetch-stage instruction aligner
keeps FP-compute ops out of slot 2, so the PC advances past slot 1 alone and
the FP op arrives later as slot 1. Dispatch backs this up by forcing
`dispatch_valid_2` low for an FP-compute slot 2, so slot 1 fires alone.

Slot 2 always checks the wrapper's `i_rob_full_for_2`, since both slots take a
ROB entry. For the RS, LQ, and SQ it uses the "full for 2" status when slot 1
targets the same structure and the plain full status otherwise. The checkpoint
check is the plain `i_checkpoint_available`: slot 1 control flow terminates
the bundle, so a 2-wide cycle allocates at most one checkpoint and the
single-save-per-cycle checkpoint pool is enough. If slot 2 is the branch or
jump, dispatch flags the save as a slot-2 save (`o_checkpoint_save_for_slot2`)
so the RAT snapshot folds in slot 1's same-cycle rename.

## Source operands

For each source slot, dispatch reads the INT or FP RAT according to the
`uses_fp_rs1/2/3` flags pre-decoded in ID, then turns the RAT result into an
RS operand:

- A source that is not renamed takes its value from the regfile passthrough,
  and the RS entry is marked ready.
- A renamed source sends the ROB tag to the RS, and dispatch also emits a
  registered done-repair request. The wrapper checks the ROB one cycle later
  and wakes the RS if that tag had already completed before dispatch.
- A slot-2 source that reads slot 1's destination in the same bundle is
  overridden with slot 1's newly allocated ROB tag. The RAT lookup happened
  before slot 1's rename write, so without the override the slot-2 source
  would be stale.

For FP instructions with `rm = DYN`, dispatch substitutes the current `frm` CSR
value into the RS entry, capturing the rounding mode in program order so later
`frm` writes do not affect in-flight FP ops.

## Stalls

Any exhausted back-end resource stalls dispatch: ROB full, target RS full, LQ
full for loads, LR, and AMOs, SQ full for stores and SC, or no checkpoint
available for a branch or jump. The early back-end recovery hold (`i_hold`)
blocks the fire gate the same way. `o_status` carries independent per-cause
flags for slot 1 (any combination may assert in one cycle) and `slot2_block_*`
bits for cycles where slot 2 alone holds the bundle, so the perf counter
aggregator (`../../cpu_ooo/perf/perf_counter_aggregator.sv`) can count each
cause without re-deriving the conditions.

`o_stall` is the validity-qualified dispatch backpressure
(`dispatch_valid && !bundle_fire_ok`): it asserts only while a valid presented
bundle is blocked. The qualifier has to stay. Pipeline control registers
`o_stall` into `replay_after_dispatch_stall_q`, whose replay pulse overrides
`id_stall_q` and re-validates the held ID image, so this source must mean "a
valid dispatch was blocked". A resource-only form
(`!i_flush && !bundle_resource_ok`) once broke this: a valid instruction X
dispatched while another front-end stall held ID; the next cycle `id_stall_q`
invalidated X; X's now-stale decoded resource was full, so the resource-only
stall manufactured a replay pulse that re-validated X once room returned, and
X allocated twice. The fire gate (`slot1_can_fire`, `dispatch_fire`, the RS
writes) keeps the `dispatch_valid` qualifier, and `o_status.stall` reports the
same qualified value, so the dispatch-backpressure perf counter counts real
backpressure only.

If the `replay -> id_valid -> o_stall` timing cone has to be re-closed, split
the signals: a resource-only term may drive only the high-fanout front-end
hold, while the replay pulse keeps the validity-qualified term. Or add a
one-entry ID-to-dispatch skid buffer. A registered stall without capture
capacity is not enough.

## RS routing

Most instructions route to one of six reservation stations by opcode; the
routing table is in [`../README.md`](../README.md) under "Instruction →
reservation station routing". Dispatch emits per-RS packets for slot 1 and
slot 2, with only the selected RS family's `valid` bit asserted for each slot.
JAL, WFI, MRET, SRET, DRET, and PAUSE skip the RS (`rs_type == RS_NONE`): they
allocate a ROB entry only, and the ROB handles them at commit. JAL is marked
done at allocation, since its link and target are known then; WFI and the
xRETs go through the ROB's serializing FSM (see "Serializing instructions" in
the same README).
