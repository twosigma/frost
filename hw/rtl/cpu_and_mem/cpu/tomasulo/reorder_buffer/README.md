# Reorder Buffer

The ROB is the central commit engine. It tracks every in-flight
instruction from dispatch through commit, providing in-order
retirement, precise exceptions, and the rendezvous point for branch
resolution and exception handling.

## Design

A 32-entry circular buffer with head and tail pointers (extra MSB
wrap bit so full and empty are distinguishable). Allocation is
in-order at dispatch, completion is out-of-order via the CDB
(or directly for plain stores), and commit is in-order at the head.

INT and FP instructions share a single buffer with a `dest_rf` flag
to distinguish them. There's no need for separate INT/FP queues —
the constraint is in-order *commit*, not in-order *execution*.

### Storage strategy

Multi-bit fields (PC, value, dest reg, branch target, exception
cause, FP flags, …) live in distributed RAM. Single-write fields
(written only at allocation) use a 1-write-port LUTRAM; multi-write
fields (allocation + CDB or branch resolution) use a 2-write-port
LUTRAM with a Live Value Table. The 1-bit packed flags
(`valid`, `done`, `exception`, branch flags, etc.) stay in flip-flops
because they need per-entry clear on partial flush.

The `value` field has several read ports — head (for commit), RAT
bypass, three dispatch-time bypass reads, and three more for the
wrapper's FMUL operand-repair queue — implemented as multiple LUTRAM
instances with identical writes and different read addresses.

This saves several thousand FFs vs. a pure-FF design.

## Serializing instructions

A small FSM holds the commit head when the head entry needs external
coordination:

```
SERIAL_IDLE ──► WAIT_SQ      (FENCE / FENCE.I / AMO / SC, drain SQ)
            ├─► CSR_EXEC     (CSR side effect handshake)
            ├─► MRET_EXEC    (MRET handshake with trap_unit)
            ├─► WFI_WAIT     (stall until interrupt pending)
            └─► TRAP_WAIT    (stall until trap_unit takes the trap)
```

Each non-IDLE state asserts `commit_stall`. CSR reads execute
speculatively (their result rides the CDB), but the side effect is
applied only when the entry reaches the head and the `csr_file`
handshake completes — that way a flushed CSR never mutates
architectural state. FENCE.I additionally pulses a one-cycle
pipeline + icache flush after commit.

## Two-wide commit

The ROB retires up to two entries per cycle. When head and head+1 are
both done and both pass a hazard gate, both entries retire in the
same cycle. The hazard gate excludes anything that has to be the
last thing to happen before its commit-time side effect: CSRs,
FENCE / FENCE.I, WFI, MRET, AMO / LR / SC, exceptions, and any
mispredicting head or head+1 branch. That leaves the common case —
two ordinary-completion entries retiring back-to-back.

Slot 2 is a stripped-down sibling of slot 1. It carries only the
regfile retire, store-commit, and RAT clear payload; it never drives
mispredict / checkpoint / redirect paths because the hazard gate
guarantees those conditions can't happen on head+1 when slot 2
fires. Two duplicate RAMs (`_next` variants of the head-meta / pc /
dest / value / predicted-target / checkpoint-id RAMs) give slot 2
its own read ports at `head_idx + 1`.

The regfiles take two write ports (a 2-write-port distributed RAM
with a Live Value Table); when both slots target the same
architectural register, the LVT steers reads to slot 2 since slot 2
holds the newer program-order value. The same-tag priority applies
in the RAT: slot 2's commit wins if both slots write the same reg.

## Same-cycle CDB → head-done bypass

The ordinary-completion path — a CDB broadcast that writes a ROB
entry's `done`, `value`, and `fp_flags` — previously drained for one
cycle before the head could retire, because those fields updated on
the clock edge. The bypass forwards the CDB write directly into the
head commit mux when it targets `head_idx` (or `head_next_idx` for
slot 2), so the head retires the same cycle the arbiter broadcasts.

Excluded cases (exception, branch / JAL / JALR, CSR, FENCE / FENCE.I,
WFI, MRET) fall through to the existing serial / branch-update / trap
paths — the bypass only shortcircuits the ordinary-completion path,
which is the dominant fraction of head-wait cycles.

## Three commit views

The ROB exposes a combinational commit bus (`o_commit_comb`), a
registered commit bus (`o_commit`), and parallel slot 2 variants
(`o_commit_comb_2`, `o_commit_2`). The combinational view feeds the
same-cycle misprediction detection in `cpu_ooo.sv`'s commit flush
controller; the registered view feeds slower downstream consumers
(RAT clear, SQ commit). Splitting them keeps the misprediction-detect
path short without forcing every consumer onto a combinational path.

## Early-recovery flag

When `cpu_ooo.sv` triggers an execute-time partial flush for a
mispredicted conditional branch, it tags the resolving ROB entry as
`early_recovered`. When the entry later reaches the head, the commit
logic skips re-triggering the flush — the recovery has already
happened. Without this flag, every fast-recovered branch would
generate a redundant flush at commit.

## Allocation special cases

Most instructions allocate as not-done and become done via CDB write.
The exceptions:

- **JAL** is marked done at allocation. The link address is
  pre-computed in IF, the target is known at decode, so there's
  nothing to wait for.
- **JALR** has its link address written at allocation but waits for
  `branch_jump_unit` to resolve the target.
- **WFI / FENCE / FENCE.I / MRET** are marked done immediately —
  they have no execution phase, only a commit-time effect handled by
  the serializing FSM.

## Performance counters

The ROB drives several of the wrapper's performance counters
directly: `head_and_next_done` (widen-commit actually fired) and
`head_plus_one_done` (ungated head+1 ready, for the drain-backlog
bucket) come from here, along with `commit_2_opportunity` /
`commit_2_fire_actual` — the gap between those two measures how
often the 2-wide gate is blocked by downstream back-pressure rather
than the hazard gate.

## Verification

Cocotb unit tests cover allocation, CDB writes, branch updates,
serializing instructions, partial and full flush, and edge cases
(simultaneous alloc + commit, full buffer, etc.). Inline `` `ifdef
FORMAL `` properties prove pointer invariants, allocation/commit
correctness, and the serializing FSM transitions.
