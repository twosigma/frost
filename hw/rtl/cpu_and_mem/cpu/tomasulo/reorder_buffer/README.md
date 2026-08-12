# Reorder Buffer

The ROB is the central commit engine. It tracks every in-flight
instruction from dispatch through commit, providing in-order
retirement, precise exceptions, and the rendezvous point for branch
resolution and exception handling.

## Design

A 32-entry circular buffer with head and tail pointers (extra MSB
wrap bit so full and empty are distinguishable). Allocation is
in-order at dispatch, with slot 1 and slot 2 able to allocate adjacent entries
in the same cycle. Completion is out-of-order via the two CDB lanes (or directly
for plain stores), and commit is in-order at the head.

INT and FP instructions share a single buffer with a `dest_rf` flag
to distinguish them. There's no need for separate INT/FP queues —
the constraint is in-order *commit*, not in-order *execution*.

### Storage strategy

Multi-bit fields (PC, value, dest reg, branch target, exception
cause, FP flags, …) live in distributed RAM. Allocation-only fields
use paired allocation write ports for slot 1 and slot 2; fields also
updated by the CDB use multi-write LUTRAMs with a Live Value Table.
The ordinary CDB-updated value / exception-cause / FP-flag RAMs
have four write ports: alloc slot 1, alloc slot 2, CDB lane 0, and CDB lane 1.
The branch target is split by producer class instead — JAL targets on the
allocation ports, resolved branch/JALR targets on branch update into a plain
single-write-port `sdp_dist_ram` — and selected at the head, which is cheaper
than paying for an LVT RAM on the branch-update path. The 1-bit packed flags
(`valid`, `done`, `exception`, branch flags, etc.) stay in flip-flops
because they need per-entry clear on partial flush.

The `value` field has several read ports — head (for commit), head+1
(for widen-commit), RAT bypass, six dispatch-time bypass reads (three
for slot-1 sources, three for slot-2 sources), and three more for the
wrapper's FMUL operand-repair queue — implemented as multiple LUTRAM
instances with identical writes and different read addresses.

The twelve `value` instances run their two alloc write ports in the
RAM modules' register-staged LVT mode (`NUM_STAGED_LVT_PORTS(2)`):
the late alloc enables still write the banks in the alloc cycle, but
the Live Value Table update runs one cycle later from staging
registers, keeping the dispatch-gate cone off every LVT bit of every
replica (this was the x3 post-opt WNS). Reads stay cycle-exact via a
per-entry effective-LVT correction inside the RAM modules — the
load-bearing case is JAL, done at alloc, whose link value may be read
at alloc+1.

This saves several thousand FFs vs. a pure-FF design.

## Two-wide allocation

Dispatch provides a primary allocation request and an optional slot-2 request.
Slot 2 only allocates when slot 1 also allocates, and `full_for_2` blocks the
pair when only one ROB entry is free. Slot 1 receives the current tail tag;
slot 2 receives `tail+1`, preserving program order for later commit and
checkpoint age comparisons.

Dispatch-facing full flags are registered from conservative next occupancy:
they include the current allocation width but intentionally exclude same-cycle
commit capacity. The legal request width (zero, one, or two) selects among
parallel current-count thresholds, keeping the late dispatch valid off both the
high-fanout RAM write enable and a serial add/compare cone. Flushes retain their
exact pointer-derived survivor count. This relies on the enforced allocation
contract: slot 1 is never presented while full or flushing, and slot 2 implies
slot 1 and is never presented while `full_for_2`.

## Serializing instructions

A small FSM (extracted to [`rob_serializer.sv`](rob_serializer.sv) as a pure
boundary move; its `serial_state_e` type moved to `riscv_pkg` so the ROB and
the submodule share it) holds the commit head when the head entry needs external
coordination:

```
SERIAL_IDLE ──► WAIT_SQ       (FENCE / FENCE.I, drain committed SQ entries)
            ├─► FENCE_I_SYNC  (FENCE.I cache sync, once the SQ is drained)
            ├─► CSR_EXEC      (CSR side effect handshake)
            ├─► MRET_EXEC     (MRET handshake with trap_unit)
            ├─► WFI_WAIT      (stall until interrupt pending)
            └─► TRAP_WAIT     (stall until trap_unit takes the trap)
```

WAIT_SQ falls through to IDLE for a plain FENCE once the committed SQ
entries drain, but FENCE.I instead advances into FENCE_I_SYNC (entering
it directly from IDLE if the SQ is already committed-empty).

Each non-IDLE state asserts `commit_stall` until its handshake completes;
on the completing cycle the stall drops while still in that state, so the
held entry retires and the FSM returns to IDLE the next cycle. Two states
are exceptions: WAIT_SQ holds the stall for a FENCE.I and advances into
FENCE_I_SYNC instead, and TRAP_WAIT never drops it — the trap flush takes
over. CSR reads execute speculatively (their result rides the CDB), but
the side effect is applied only when the entry reaches the head and the
`csr_file` handshake completes — that way a flushed CSR never mutates
architectural state. FENCE.I holds in FENCE_I_SYNC driving a level
cache-sync request (`o_fence_i_sync_req` / `i_fence_i_sync_done`) so the
L1D writes back and the L1I invalidates against post-writeback data
before commit; on commit it then pulses a one-cycle pipeline + icache
flush (`o_fence_i_flush`).

AMO / LR / SC have no serial state of their own: their store ordering
is enforced at LQ issue time (the load waits for the ROB head plus a
committed-empty SQ), so once the CDB marks the entry done it commits
through the ordinary path.

When the head exception fires, the ROB exports the head entry's value
slot as `o_trap_value` alongside `o_trap_pc` / `o_trap_cause`. For a
misaligned load/store the load_queue / SQ path parks the faulting
address in that otherwise-unused value slot, so `cpu_ooo` can mux it
into `mtval`.

## Two-wide commit

The ROB retires up to two entries per cycle. When head and head+1 are
both done and both pass a hazard gate, both entries retire in the
same cycle. The hazard gate excludes anything that has to be the
last thing to happen before its commit-time side effect: CSRs,
FENCE / FENCE.I, WFI, MRET, AMO / LR / SC, exceptions, and any
mispredicting head or head+1 branch. That leaves the common case —
two ordinary-completion entries retiring back-to-back.

Slot 2 is a stripped-down sibling of slot 1. It carries the regfile
retire, store-commit, and RAT clear payload, and — since the gate
admits correctly-predicted branches at head+1 — real branch and
checkpoint metadata plus a second correct-branch strobe
(`o_commit_correct_branch_2_raw`) for the slot-2 checkpoint-free /
BTB-training capture. It still never drives mispredict / redirect
paths: the hazard gate guarantees a mispredicting (or early-recovered)
branch can't retire on head+1, so slot 2's `misprediction` stays
hardwired 0 and its `redirect_pc` only ever carries the architectural
next-PC of a correctly-predicted branch. A `_next` replica of each head RAM (head-meta, pc, dest, value,
predicted-target, checkpoint-id, branch-target, exc-cause, fp-flags,
csr-*) gives slot 2 its own read port at `head_idx + 1`.

The regfiles take two write ports (a 2-write-port distributed RAM
with a Live Value Table); when both slots target the same
architectural register, the LVT steers reads to slot 2 since slot 2
holds the newer program-order value. The same-tag priority applies
in the RAT: slot 2's commit wins if both slots write the same reg.

## Same-cycle CDB → head-done bypass

The ordinary-completion path — a CDB broadcast that writes a ROB
entry's `done`, `value`, and `fp_flags` — previously drained for one
cycle before the head could retire, because those fields updated on
the clock edge. The bypass forwards either CDB lane directly into the
head commit mux when it targets `head_idx` (or `head_next_idx` for
slot 2), so the head retires the same cycle the arbiter broadcast
reaches the ROB.

Lane 0 and lane 1 carry distinct ROB tags. If both are valid in the same cycle,
the ROB marks two entries done and writes both value / exception / FP flag
payloads through the parallel CDB write ports.

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

The ROB drives the cycle-exact `head_wait_total` and nine-way head-class
partition directly. The final `head_wait_int` and `head_wait_mem_load`
classifications are stored in per-entry FF vectors by both allocation lanes
and selected with the registered one-hot head mask. They are bit-equivalent to
the priority classifier (branch, then AMO/LR, then store, then RS type), while
avoiding the head-meta LVT on these high-fanout observer paths. Live
`head_valid`, effective-done (including same-cycle CDB bypass), and full-flush
gating remains combinational, so the counter event cycles do not shift.

The ROB also drives `head_and_next_done` (commit fired while head+1 was also
done — a widen-commit upper bound; the actual fire count is
`commit_2_fire_actual`) and
`head_plus_one_done` (ungated head+1 ready, for the drain-backlog
bucket) come from here, along with `commit_2_opportunity` /
`commit_2_fire_actual` — the gap between those two measures how
often the 2-wide gate is blocked by downstream back-pressure rather
than the hazard gate.

## Verification

Cocotb unit tests cover allocation, dual-lane CDB writes, branch updates,
serializing instructions, partial and full flush, and edge cases
(simultaneous alloc + commit, full buffer, etc.). Inline `` `ifdef
FORMAL `` properties prove pointer invariants, allocation/commit
correctness, and the serializing FSM transitions.
