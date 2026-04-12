# Dispatch

Dispatch is the rename and resource-allocation step that connects the
in-order front-end to the out-of-order back-end. For every valid
decoded instruction it allocates a ROB entry, looks up source operands
through the RAT, renames the destination, routes the instruction to
the appropriate reservation station, and (when needed) reserves an
LQ/SQ entry and a RAT checkpoint.

The whole module is purely combinational. Every output is a same-cycle
function of the registered ID-stage pipeline register and the
combinational RAT/ROB lookups — there's no skid buffer or local state.
All the actual data lives in the modules dispatch is talking to.

## What it does each cycle

The interesting work is in the source operand resolution. For each of
the up to three source slots, dispatch picks the INT or FP RAT based
on per-opcode flags (so FCVT, FMV, FLW etc. correctly mix INT and FP
sources), reads the lookup result, and:

- If the source is **not renamed**, the source value comes from the
  regfile passthrough and the RS entry is marked ready.
- If the source is **renamed and the producing ROB entry is already
  done**, dispatch fetches the value from a ROB bypass read port and
  marks the RS entry ready immediately. This avoids waiting an extra
  cycle for the CDB to wake the source.
- If the source is **renamed and not yet done**, dispatch passes the
  ROB tag to the RS, which will wake on CDB broadcast.

For FP instructions with `rm = DYN`, dispatch substitutes the current
`frm` CSR value into the RS entry — capturing the rounding mode in
program order so subsequent `frm` writes don't affect in-flight FP
ops.

For branches and JALRs, dispatch reserves a RAT checkpoint and
records the current RAS top-of-stack pointer plus valid count for
restoration on misprediction.

## Stalls

Any one of the back-end resources running out stalls the entire
front-end: ROB full, target RS full, LQ full (for loads), SQ full
(for stores or AMOs), no checkpoint available (for branches). The
status output reports the exact reason as a one-hot priority encode
so `cpu_ooo.sv` can increment per-cause stall counters without
re-deriving the conditions.

## RS routing

Most instructions route to one of six reservation stations based on
opcode — the routing table lives in the cross-cutting section of
[`../README.md`](../README.md). A handful of instructions (JAL, WFI,
MRET, PAUSE) have no operand wakeup needs at all and skip the RS
entirely; they only allocate a ROB entry, and their commit-time
behavior is enforced by the ROB's serializing FSM.
