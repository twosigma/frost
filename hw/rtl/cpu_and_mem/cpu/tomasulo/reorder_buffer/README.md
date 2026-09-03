# Reorder Buffer

The ROB tracks instructions from dispatch through in-order commit, providing
precise exceptions and branch-recovery state.

## Design

A 32-entry circular buffer with head and tail pointers. Each pointer carries
an extra MSB wrap bit so full and empty are distinguishable. Allocation is
in-order at dispatch, and slot 1 and slot 2 can allocate adjacent entries in
the same cycle. Completion is out of order through the two CDB lanes, or
direct for plain stores. Commit is in-order at the head.

INT and FP entries share the buffer and use `dest_rf` to select the register
file.

### Storage strategy

Multi-bit fields live in distributed RAM: PC, dest reg, predicted target,
checkpoint id, head metadata, value, exception cause, FP flags, branch
target, and the CSR address, op, and write data. Allocation-only fields use
paired allocation write ports for slot 1 and slot 2. Fields the CDB also
updates use multi-write LUTRAMs with a Live Value Table. The value and
FP-flag RAMs have four write ports: alloc slot 1, alloc slot 2, CDB lane 0,
and CDB lane 1. The exception-cause RAM has the same physical ports, but
allocation installs zero or `ExcIllegalInstr` and only a valid exceptional CDB
completion may overwrite it. The branch target is split by producer class
instead: JAL targets arrive on the allocation ports, and resolved
branch/JALR targets arrive on branch update into a plain single-write-port
`sdp_dist_ram`. The head selects between the two, which is cheaper than an
LVT RAM on the branch-update path. The 1-bit packed flags (`valid`, `done`,
`exception`, the branch flags) stay in flip-flops because they need
per-entry clear on partial flush.

The ROB folds the complete CSR/privilege/Debug/FS legality verdict into each
entry's `exception` bit and cause at allocation. That snapshot is exact for
every instruction that can survive to commit: a CSR write stops younger
allocation until its side effect commits, trap, xRET, and Debug-Mode
transitions flush younger work, and hardware FS Dirty-setting only moves FS
away from Off. A normal CDB completion therefore marks the entry done without
clearing its allocation-time exception. An exceptional CDB completion sets the
exception and replaces the cause. Both writes are valid-tag-qualified so a
stale CDB for an invalid tag cannot beat same-cycle reallocation in the cause
RAM's Live Value Table.

The `value` field has nine read ports: head (for commit), head+1 (for
widen-commit), RAT bypass, and six dispatch-time bypass reads (three for
slot-1 sources, three for slot-2 sources). They are implemented as nine
LUTRAM instances with identical writes and different read addresses. The
wrapper's FMUL pending queue consumes the registered slot-1 response on
channels 1/2/3 instead of owning packet-tag-driven read replicas.

The nine `value` instances run their two alloc write ports in the RAM
modules' register-staged LVT mode (`NUM_STAGED_LVT_PORTS(2)`). The late
alloc enables still write the banks in the alloc cycle, but the Live Value
Table update runs one cycle later from staging registers. This keeps the
dispatch-gate cone off every LVT bit of every replica, which was the x3
post-opt WNS. Reads stay cycle-exact through a per-entry effective-LVT
correction inside the RAM modules. The load-bearing case is JAL, which is
done at alloc and whose link value may be read at alloc+1.

## Two-wide allocation

Dispatch provides a primary allocation request and an optional slot-2 request.
Slot 2 only allocates when slot 1 also allocates, and `full_for_2` blocks the
pair when only one ROB entry is free. Slot 1 receives the current tail tag and
slot 2 receives `tail+1`, which preserves program order for later commit and
checkpoint age comparisons.

Dispatch-facing full flags are registered from conservative next occupancy:
they include the current allocation width and exclude same-cycle commit
capacity. The legal request width (zero, one, or two) selects among parallel
current-count thresholds, which keeps the late dispatch valid off both the
high-fanout RAM write enable and a serial add/compare cone. Flushes retain
their exact pointer-derived survivor count. This relies on the allocation
contract, which the RTL asserts: slot 1 is never presented while full or
flushing, and slot 2 implies slot 1 and is never presented while
`full_for_2`.

## Serializing instructions

[`rob_serializer.sv`](rob_serializer.sv) holds the commit head when an entry
needs external coordination:

```
SERIAL_IDLE ──► WAIT_SQ                   (FENCE / FENCE.I SQ drain)
            ├─► FENCE_I_SYNC              (FENCE.I cache sync)
            ├─► CSR_EXEC ──► CSR_TRANSLATION_DRAIN
            │                 (translation-class CSR committed-SQ drain)
            ├─► MRET_EXEC                 (xRET handshake with trap_unit)
            ├─► WFI_WAIT                  (stall until interrupt pending)
            └─► TRAP_WAIT                 (stall until trap_unit takes the trap)
```

WAIT_SQ falls through to IDLE for a plain FENCE once the committed SQ
entries drain. FENCE.I instead advances into FENCE_I_SYNC, or enters it
directly from IDLE if the SQ is already committed-empty.

Each owned state asserts `commit_stall` until its release condition is met.
An ordinary CSR drops the stall on `i_csr_done` and retires on its historical
completion cycle. Translation-class ownership is captured at allocation:
every `satp` access qualifies conservatively, while `mstatus` and `sstatus`
qualify only when the instruction has architectural write intent. When
`i_csr_done` arrives, an owned CSR moves to `CSR_TRANSLATION_DRAIN`
unconditionally, so the one-cycle done handshake is not lost when stores or
a retirement guard still block it. It retires only after the committed SQ is
empty and the normal retirement permit is present (`!i_commit_hold` and no
recovery or flush guard). This drain happens before the CSR's architectural
write and leaves ordinary CSR timing unchanged.

TRAP_WAIT never drops the stall because the trap flush takes over. FENCE.I
holds in FENCE_I_SYNC, driving the level cache-sync request
(`o_fence_i_sync_req` / `i_fence_i_sync_done`) until both sync completion and
the retirement permit are present. The L1D can therefore write back and the
L1I invalidate against post-writeback data before the instruction retires.

Translation-class CSR recovery has three phases. The CSR first retires into a
one-cycle registered shadow. In the following cycle
`o_translation_csr_commit_shadow` and `o_fence_class_flush_event` are
asserted while the registered commit bus writes the CSR file. The full flush
follows one cycle after that. A native FENCE.I/SFENCE.VMA instead produces
the serializer-owned semantic event directly on retirement. For either owner,
`o_fence_i_flush` is the one-cycle registered image of
`o_fence_class_flush_event`, so the historical `o_fence_i_flush` name covers
both native fences and translation-class CSR recovery. The CSR file
separately generates its registered TLB/PTW invalidate request for every
enabled committed `satp` access, or for an `mstatus`/`sstatus` commit whose
result changes SUM, MXR, or MPRV, or changes MPP while MPRV is set. The
ROB's conservative recovery classification does not replace that check.

SFENCE.VMA uses the same cache-sync state, but the serializer also captures a
registered `o_sfence_window` from its next state and the pinned head decode.
That level rises and falls on exactly the same edges as the sync request for an
SFENCE.VMA, stays low for a plain FENCE.I, and keeps the live ROB-head read out
of the TLB/PTW invalidation cone.

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
mispredicting head or head+1 branch. That leaves the common case of
two ordinary-completion entries retiring back-to-back.

Slot 2 is a stripped-down sibling of slot 1. It carries the regfile
retire, store-commit, and RAT clear payload. Because the gate admits
correctly-predicted branches at head+1, it also carries real branch and
checkpoint metadata plus a second correct-branch strobe
(`o_commit_correct_branch_2_raw`) for the slot-2 checkpoint-free /
BTB-training capture. It never drives the mispredict or redirect paths:
the hazard gate guarantees that a mispredicting (or early-recovered)
branch cannot retire on head+1, so slot 2's `misprediction` stays
hardwired 0 and its `redirect_pc` only ever carries the architectural
next-PC of a correctly-predicted branch. A `_next` replica of each head
RAM (head-meta, pc, dest, value, predicted-target, checkpoint-id,
branch-target, exc-cause, fp-flags, csr-*) gives slot 2 its own read
port at `head_idx + 1`.

The regfiles take two write ports (a 2-write-port distributed RAM
with a Live Value Table). When both slots target the same
architectural register, the LVT steers reads to slot 2, which holds
the newer program-order value. The RAT relies on the same ordering:
when both slots write the same register, the RAT holds slot 2's tag,
so slot 1's tag compare misses and slot 2's commit clears the entry.

## Same-cycle CDB → head-done bypass

The bypass forwards either CDB lane directly into the
head commit mux when it targets `head_idx` (or `head_next_idx` for
slot 2), so the head retires the same cycle the arbiter broadcast
reaches the ROB.

Lane 0 and lane 1 carry distinct ROB tags. If both are valid in the same cycle,
the ROB marks two entries done and writes both value / FP-flag payloads through
the parallel CDB write ports. Each lane writes exception state and cause only
when its completion is exceptional; a non-exception completion preserves any
allocation-time legality fault.

Exceptions, branch / JAL / JALR, CSR, FENCE / FENCE.I, WFI, and MRET fall
through to the existing serial / branch-update / trap
paths; the bypass applies only to ordinary completions.

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
logic skips re-triggering the flush, since the recovery has already
happened. Without this flag, every fast-recovered branch would
generate a redundant flush at commit.

## Allocation special cases

Most instructions allocate as not-done and become done via CDB write.
The exceptions:

- JAL is marked done at allocation. The link address is computed in ID
  and the target is known at decode, so there is nothing to wait for.
- JALR has its link address written at allocation but waits for
  `branch_jump_unit` to resolve the target.
- WFI, FENCE, FENCE.I, and MRET are marked done immediately. They have
  no execution phase, only a commit-time effect handled by the
  serializing FSM.

## Performance counters

The ROB drives the cycle-exact `head_wait_total` and the nine-way head-class
partition directly. The final `head_wait_int` and `head_wait_mem_load`
classifications are stored in per-entry FF vectors by both allocation lanes
and selected with the registered one-hot head mask. They are bit-equivalent to
the priority classifier (branch, then AMO/LR, then store, then RS type) while
keeping the head-meta LVT off these high-fanout observer paths. Live
`head_valid`, effective-done (including the same-cycle CDB bypass), and
full-flush gating remain combinational, so the counter event cycles do not
shift.

The ROB also drives `head_and_next_done` (commit fired while head+1 was also
done, an upper bound on widen-commit), `head_plus_one_done` (head+1 done
whether or not commit fires, for the drain-backlog bucket),
`commit_2_opportunity` (the hazard gate passed), and `commit_2_fire_actual`
(the gate plus the master enable and `i_widen_commit_ok`). The gap between
the last two measures how often 2-wide commit is blocked by downstream
back-pressure rather than by the hazard gate.

## Verification

Cocotb (the `reorder_buffer` target in `tests/test_run_cocotb.py`) covers
allocation, dual-lane CDB writes, branch updates, serialization, flushes,
simultaneous allocation/commit, and full-buffer handling. Directed
serializer cases pin the translation CSR's captured done pulse, SQ drain,
commit-hold behavior, event/shadow/final-flush phasing, and the non-writing
`mstatus` exclusion. Inline formal properties, run by
`formal/reorder_buffer.sby`, prove pointer, allocation/commit,
serializer-state ownership, drain, and event-delay invariants.
