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
valid, slot 1 is not a branch or jump, slot 2 is not an FP-compute op (one
targeting the FP, FMUL, or FDIV RS — FP loads/stores go to MEM_RS and are
allowed), and every targeted structure has enough space for the bundle. An
FP-compute slot 2 is serialized off (`dispatch_valid_2` is forced low); slot 1
still fires alone and slot 2 is re-presented next cycle. When both slots target
the same resource family, dispatch uses the "full for 2" status from the
wrapper; otherwise each slot uses the plain full status for its own ROB, RS, LQ,
SQ, and checkpoint needs. The whole
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
slots need the same resource. The status output reports independent per-cause
stall flags (any combination may assert in one cycle) so `cpu_ooo.sv` can
increment per-cause performance counters without re-deriving the conditions.

For x3 timing, `o_stall` (which drives the front-end hold `frontend_stall` and
the replay handshake) is computed from the **resource-only** availability
(`bundle_resource_ok`) — the same resource checks but **without** the live
`i_valid`/`id_valid` qualifier — so it settles from the registered resource-full
flags and registered-bundle-derived needs instead of the late
`replay → id_valid → o_stall` chain (the post-opt WNS limiter). Dropping the
validity qualifier can only assert *extra* stalls (a presented bundle that needs
a full resource while `id_valid=0`); each merely holds the front-end, which is
always safe — the consume engine freezes and re-presents the head, and
`replay_after_dispatch_stall_q` registers this same `o_stall` so the replay pulse
stays consistent with `id_stall_q` (no bundle dropped or duplicated). The actual
fire/dispatch gate (`slot1_can_fire`, `dispatch_fire`, RS writes) keeps the
`dispatch_valid` qualifier, and `o_status.stall` keeps the real id_valid-qualified
value so the dispatch-backpressure perf counter is unchanged.

## RS routing

Most instructions route to one of six reservation stations based on opcode; the
routing table lives in the cross-cutting section of [`../README.md`](../README.md).
Dispatch emits per-RS packets for slot 1 and slot 2, with only the selected RS
family's `valid` bit asserted for each slot. A handful of instructions (JAL,
WFI, MRET, PAUSE) skip the RS entirely: they allocate a ROB entry and rely on
the ROB's commit-time serializing FSM for their architectural effect.
