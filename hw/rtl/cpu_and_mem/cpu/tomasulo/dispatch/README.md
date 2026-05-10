# Dispatch

Dispatch is the rename and resource-allocation step that connects the in-order
front-end to the out-of-order back-end. It consumes the primary decoded
instruction plus an optional slot-2 instruction from ID and can allocate a
2-wide bundle into Tomasulo in one cycle.

For each firing slot it allocates a ROB entry, looks up source operands through
the RAT, renames the destination, routes the instruction to the appropriate
reservation station, reserves LQ/SQ entries when needed, and allocates a branch
checkpoint when needed. The module is still mostly combinational: the bundle
fire decision and the dispatch packets are same-cycle functions of the ID
pipeline registers and Tomasulo resource status. The only local sequential
state is the registered done-repair request path for already-completed sources.

## 2-wide bundle rules

Slot 1 is the anchor. Slot 2 can fire only when slot 1 also fires, slot 2 is
valid, slot 1 is not a branch or jump, and every targeted structure has enough
space for the bundle. When both slots target the same resource family, dispatch
uses the "full for 2" status from the wrapper; otherwise each slot uses the
plain full status for its own ROB, RS, LQ, SQ, and checkpoint needs. The whole
bundle fires or stalls together, so downstream state never sees slot 2 without
slot 1.

The checkpoint pool remains single-save-per-cycle. Since slot 1 control flow
terminates the bundle, there can be at most one checkpoint allocation in a
2-wide cycle. If slot 2 is the branch/JALR, dispatch marks the checkpoint as a
slot-2 save so the RAT snapshot includes slot 1's same-cycle rename.

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
branches/JALRs. Slot 2 also checks whether the pair has enough room when both
slots need the same resource. The status output reports the selected stall
reason so `cpu_ooo.sv` can increment per-cause performance counters without
re-deriving the conditions.

## RS routing

Most instructions route to one of six reservation stations based on opcode; the
routing table lives in the cross-cutting section of [`../README.md`](../README.md).
Dispatch emits per-RS packets for slot 1 and slot 2, with only the selected RS
family's `valid` bit asserted for each slot. A handful of instructions (JAL,
WFI, MRET, PAUSE) skip the RS entirely: they allocate a ROB entry and rely on
the ROB's commit-time serializing FSM for their architectural effect.
