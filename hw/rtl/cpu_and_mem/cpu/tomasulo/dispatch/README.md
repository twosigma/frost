# Dispatch

Dispatch renames and allocates up to two decoded instructions from the in-order
front-end into Tomasulo.

For each firing slot it allocates a ROB entry, looks up source operands through
the RAT, renames the destination, routes the instruction to the appropriate
reservation station, reserves LQ/SQ entries when needed, and allocates a branch
checkpoint when needed. The module is mostly combinational: the bundle
fire decision and the dispatch packets are same-cycle functions of the ID
pipeline registers and Tomasulo resource status. The only local sequential
state is the registered done-repair request path for already-completed sources.

## 2-wide bundle rules

Slot 1 is the anchor. Slot 2 can fire only when slot 1 also fires, slot 2 is
valid, slot 1 is not a branch or jump, slot 2 is not an FP-compute op (one
targeting the FP, FMUL, or FDIV RS — FP loads/stores go to MEM_RS and are
allowed), and every targeted structure has enough space for the bundle. An
FP-compute slot 2 is serialized off (`dispatch_valid_2` is forced low); slot 1
still fires alone and slot 2 is re-presented next cycle. When both slots target
the same resource family, dispatch uses the "full for 2" status from the
wrapper; otherwise each slot uses the plain full status for its own ROB, RS, LQ,
SQ, and checkpoint needs. The bundle fires or stalls together, so slot 2 never
appears downstream alone.

The checkpoint pool remains single-save-per-cycle. Since slot 1 control flow
terminates the bundle, there can be at most one checkpoint allocation in a
2-wide cycle. If slot 2 is the branch or jump, dispatch marks the checkpoint
as a slot-2 save so the RAT snapshot includes slot 1's same-cycle rename.

## Source operands

For each source slot, dispatch picks the INT or FP RAT based on opcode flags
pre-decoded in ID. The RAT result is then converted into an RS operand:

- If the source is **not renamed**, the source value comes from the regfile
  passthrough and the RS entry is marked ready.
- If the source is **renamed**, dispatch sends the ROB tag to the RS and also
  emits a registered done-repair request. The wrapper checks the ROB one cycle
  later and wakes the RS if that tag had already completed before dispatch.
- If a slot-2 source reads slot 1's destination in the same bundle, dispatch
  overrides the raw RAT result with slot 1's newly allocated ROB tag. This keeps
  same-bundle RAW dependencies precise even though the RAT lookup happened
  before slot 1's rename write.

For FP instructions with `rm = DYN`, dispatch substitutes the current `frm` CSR
value into the RS entry, capturing the rounding mode in program order so later
`frm` writes do not affect in-flight FP ops.

## Stalls

Any exhausted back-end resource stalls dispatch: ROB full, target RS full, LQ
full for loads/AMOs, SQ full for stores/SCs, or no checkpoint available for
branches and jumps. Slot 2 also checks whether the pair has enough room when
both slots need the same resource. The status output reports independent
per-cause stall flags (any combination may assert in one cycle) so `cpu_ooo.sv` can
increment per-cause performance counters without re-deriving the conditions.

`o_stall` is the **validity-qualified** dispatch backpressure
(`dispatch_valid && !bundle_fire_ok`): it asserts only while a valid presented
bundle is blocked. The stall feeds `replay_after_dispatch_stall_q`, whose replay
pulse overrides
`id_stall_q` and re-validates the held ID image, so a stall asserted for an
invalid/killed bundle can re-validate (and double-allocate) a stale
instruction. A resource-only stall caused this failure. If the
`replay → id_valid → o_stall` timing cone needs re-closing, split the
signals — a resource-only term may drive only the high-fanout front-end
hold while the replay pulse keeps the validity-qualified term — or add a
one-entry ID→dispatch skid buffer; a registered stall without capture
capacity is insufficient. The actual fire/dispatch gate (`slot1_can_fire`,
`dispatch_fire`, RS writes) keeps the `dispatch_valid` qualifier, and
`o_status.stall` reports the same id_valid-qualified value so the
dispatch-backpressure perf counter is unchanged.

## RS routing

Most instructions route to one of six reservation stations based on opcode; the
routing table lives in the cross-cutting section of [`../README.md`](../README.md).
Dispatch emits per-RS packets for slot 1 and slot 2, with only the selected RS
family's `valid` bit asserted for each slot. A handful of instructions (JAL,
WFI, MRET, PAUSE) skip the RS entirely: they allocate a ROB entry and rely on
the ROB's commit-time serializing FSM for their architectural effect.
