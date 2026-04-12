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

## Two commit views

The ROB exposes both a combinational and a registered commit bus.
The combinational view feeds the same-cycle misprediction detection
in `cpu_ooo.sv`'s commit flush controller; the registered view feeds
the slower downstream consumers (RAT clear, SQ commit). Splitting
them keeps the misprediction-detect path short without forcing every
consumer onto a combinational path.

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

## Verification

Cocotb unit tests cover allocation, CDB writes, branch updates,
serializing instructions, partial and full flush, and edge cases
(simultaneous alloc + commit, full buffer, etc.). Inline `` `ifdef
FORMAL `` properties prove pointer invariants, allocation/commit
correctness, and the serializing FSM transitions.
