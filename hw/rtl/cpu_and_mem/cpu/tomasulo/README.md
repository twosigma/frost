# FROST Tomasulo Out-of-Order Back-End

The Tomasulo back-end provides renaming, speculation, dynamic scheduling,
out-of-order completion, and precise in-order commit for RV64IMACBFD + Zbkb +
Zicond + Zicntr + Zifencei + Zihintpause. Dispatch, RAT, ROB, CDB, and commit
are two-wide. Most
reservation stations issue once per cycle; INT_RS issues twice to two ALUs,
with branches restricted to pipe 0. Up to six stations, or seven operations
including INT's second port, may issue concurrently. Aligned stores bypass the
two-lane CDB. Both lanes support same-cycle RS wakeup; lane 1 is controlled per
instance by `LANE1_ISSUE_BYPASS`.

```
   IF → PD → ID → dispatch        ─► ROB          ┌─► commit ─► regfile / SQ /
                  rename/resource     (32 entries)│             trap entry / redirect
                  allocation         + RAT (INT+FP,
                                      8 ckpts)
                                  │
                                  ▼
                         ┌────────────────────────┐
                         │   6 reservation        │
                         │   stations             │
                         │   INT / MUL / MEM /    │
                         │   FP / FMUL / FDIV     │
                         └─────────┬──────────────┘
                                   │ wake on CDB,
                                   │ issue when ready
                                   ▼
                         FU shims (ALU, MUL/DIV, FP*)
                                   │
                         LQ + L0 cache, SQ
                                   │
                                   ▼
                              CDB (2 lanes)
                          ─ broadcast values & tags
                          ─ wakes RS, marks ROB done
```

## Directory contents

| Submodule                                                          | Role |
|--------------------------------------------------------------------|------|
| [`tomasulo_wrapper/`](tomasulo_wrapper/README.md)                  | Glue: instantiates everything below; back-end integration. Its extracted glue submodules live in `perf/`, `commit_bus/`, `dispatch_routing/`, `store_addr/`, `atomics/` |
| [`../mmu/`](../mmu/)                                               | Sv39 data translation (Phase 3): `dmmu` (the D4 translation stage + 16-entry FA `dtlb`) sits in the wrapper between the AGU adds and the LQ/SQ address updates, bypassed combinationally while translation is inactive; the read-only `ptw` lives in `cpu_ooo` behind a walk seam and reads page tables through the hierarchy's walker port |
| [`dispatch/`](dispatch/README.md)                                  | 2-wide combinational rename + resource allocation hub |
| [`reorder_buffer/`](reorder_buffer/README.md)                      | In-order commit, precise exceptions, serializing instructions |
| [`register_alias_table/`](register_alias_table/README.md)          | INT + FP rename tables, branch checkpoints |
| [`reservation_station/`](reservation_station/README.md)            | Generic RS, instantiated 6× |
| [`load_queue/`](load_queue/README.md)                              | Loads, L0 cache, MMIO, single-beat dwords, LR/AMO |
| [`store_queue/`](store_queue/README.md)                            | Stores, store-to-load forwarding, single-beat drains |
| [`cdb_arbiter/`](cdb_arbiter/README.md)                            | 2-lane CDB priority arbiter |
| [`fu_cdb_adapter/`](fu_cdb_adapter/README.md)                      | One-deep holding register per FU slot |
| [`fu_shims/`](fu_shims/README.md)                                  | Adapters from RS issue to the reused FUs |

Larger modules use these helpers:
`store_queue/sq_forwarding_unit`, `load_queue/lq_issue_selector`,
`reservation_station/rs_issue2_selector`, and
`reorder_buffer/rob_serializer`. `serial_state_e` lives in `riscv_pkg`.
The balanced issue selectors preserve exact priority. Each helper is documented
in its parent's README.

The CPU top-level (`../cpu_ooo/cpu_ooo.sv`) instantiates
`tomasulo_wrapper` plus `dispatch` and the front-end stages; the logic
that straddles the front-end / back-end boundary (early misprediction
recovery, the misprediction flush controller, memory port arbitration,
…) lives in its glue submodules under `../cpu_ooo/branch_recovery/`
and `../cpu_ooo/memory_if/`. See [`../README.md`](../README.md).

## Cross-cutting design notes

The system-level decisions below cut across multiple submodules.
Each submodule's README explains how it implements its piece.

### Conservative memory disambiguation

Loads can execute out of order with respect to *each other*, but a
load is gated until every older store address is known. If a matching
older store is found, the LQ pulls the data from the SQ via
store-to-load forwarding; otherwise the load issues to the L0 cache
or main memory. Stores are non-speculative — they sit in the SQ until
the ROB commits them. MMIO loads are additionally pinned to the ROB
head so their reads can't have speculative side effects.

Aggressive memory speculation with recovery is not implemented; conservative
gating costs IPC on memory-heavy code.

### Two-tier branch recovery

Branches, JAL, and JALR reserve a RAT checkpoint at dispatch (full INT +
FP RAT snapshot + RAS top + valid count, 8 slots).

Conditional-branch mispredictions resolve in `branch_jump_unit` and
trigger a fast two-phase recovery in the `early_misprediction_recovery`
submodule (under `cpu_ooo/branch_recovery/`): the
front-end redirects and the RAT restores in the same cycle, then the
OOO back-end's partial flush fires one cycle later. This cuts the
typical penalty from ~15 cycles to ~2.

JALR mispredictions and exceptions go through the slower commit-time
path because their recovery PC depends on results that may still be
in flight when the fast path would fire. Both paths use the same
age-based partial flush primitive everywhere downstream.

### Serializing instructions

A small FSM in the ROB pins most of these instructions at the commit head
(atomics are instead ordered at LQ/SQ issue, see the last row):

| Class               | Behavior |
|---------------------|----------|
| **WFI**             | Stalls at head until an interrupt is pending. |
| **CSR**             | Read result rides the CDB; the side effect is applied at commit via a `csr_file` handshake. |
| **FENCE / FENCE.I** | Drains the SQ before commit. FENCE.I then enters a cache-sync state (`SERIAL_FENCE_I_SYNC`): it asserts the cache-sync request and holds the head until the hierarchy reports done (L1D writeback-all, then L1I invalidate-all), and pulses the pipeline + fetch-buffer flush so the front-end refills from post-writeback memory. |
| **MRET**            | Hand-shakes with `trap_unit`; redirect PC = `mepc`. |
| **AMO / LR / SC**   | Head-ordered atomics, not stalled by the ROB FSM. AMO and SC fire only at the ROB head with the SQ committed-empty (no older stores in flight) — AMO is gated at LQ issue, SC at the wrapper's reservation check; LR fires at the head. While an AMO owns the head, interrupt delivery is additionally shielded (`trap_unit.i_amo_at_head`, fed by the ROB's `o_head_is_amo`): a trap flush anywhere in the AMO's [write-launch, commit] window would orphan its in-flight memory write (memory mutated by a squashed instruction that then re-executes — a double-applied atomic), so the pending interrupt is held until the AMO commits. Exceptions stay ungated — a faulting AMO never issues its memory ops. Device (MMIO) loads carry the mirror-image shield on the READ side (`trap_unit.i_device_read_at_head`, fed from the router's `o_device_request_pending`): their terminal accept pops a destructive device register, so interrupt delivery is held from before the accept until the load commits, and the router refuses to arm until that hold is established. |

### 2-wide CDB arbitration

The balanced top-two tree preserves fixed priority without serial lane-0
selection and lane-1 exclusion. Live ALU values bypass the payload tree and
are restored by lane/source selects; held ALU and other FU values use the tree.
Registered consumers repeat that restore after Q from existing adapter state.

```
MUL  >  MEM  >  ALU  >  ALU2  >  DIV  >  FP_DIV  >  FP_MUL  >  FP_ADD
```

An unselected FU holds its result in `fu_cdb_adapter`; pipelined FUs also have
credit-managed result FIFOs. The grant vector is 0-, 1-, or 2-hot.

Full-flush CDB suppression is handled centrally at the arbiter via `i_kill`
rather than replicated across every adapter. This suppresses both
broadcast lanes and keeps the broadly-fanned flush signal out of each adapter's
output cone.

Because ROB tags are reused as soon as the tail rewinds, a completion
belonging to a squashed instruction must never reach the CDB after its flush
(a delivery landing two or more cycles after the tag's reallocation would be
indistinguishable from the new instruction's completion — tag ABA). Every
producer therefore kills squashed work at its own boundary: the shims
flush-mark their tag queues / hold buffers / result FIFOs, the adapters
age-kill held and pass-through results, the LQ drops in-flight responses for
squashed loads, and the arbiter kills full-flush cycles. This discipline is
pinned by directed stale-CDB probes in the `tomasulo_wrapper` bench (flush
alignment swept across issue and pipeline depth, killed tag reallocated at
the earliest legal cycle), by an anyconst flushed-tag assert in the
`fp_div_shim` formal target, and by always-on stale-delivery diagnostics in
the wrapper (with producing `fu_type`) and ROB; the one arrival with no
consumer-side defense — the cycle after reallocation — is a fatal sim
tripwire in the ROB (see `reorder_buffer.sv`, drain-window section).

The same tag-reuse argument requires each completion to broadcast exactly
*once*: a duplicate delivery landing after the first one committed the
instruction writes a freed (or eventually reallocated) entry. The MEM slot's
accept therefore mirrors its presentation mux exactly — a presented MEM
result always wins a CDB lane the same cycle (only MUL outranks it and the
CDB is 2-wide), so it pops the LQ `cdb_stage` that cycle
(`lq_result_accepted`); a colliding misaligned-store issue captures into its
registered exception slot in parallel and owns the MEM slot the next cycle.
This is pinned by the single-delivery collision test in the
`tomasulo_wrapper` bench (which reproduces the duplicate the old accept
gating caused roughly once per few hundred thousand cycles of Linux boot).

The allocation side upholds the same argument: the LQ/SQ slot alloc enables
carry the ROB's flush gate (`!i_flush_all && !i_flush_en`), so an alloc
request presented on a flush pulse is suppressed everywhere that cycle.
Dispatch may present a straggler on trap/MRET/FENCE.I pulses because the
front-end kill is edge-delayed. Without this gate, the queue could retain a tag
the ROB rejected and later form a duplicate-tag pair after tail rewind. This is
pinned by ghost-alloc probes in the `tomasulo_wrapper` bench and by
`p_no_alloc_during_flush` asserts in the LQ/SQ formal contracts (which now
leave alloc-valid free during flushes instead of assuming it away).

The deep FP shims (`fp_mul_shim`, `fp_div_shim`) consume a one-cycle
*registered* flush snapshot (pulse + flush tag + head captured on the pulse
cycle) instead of the live broadcast: their per-entry marking fanout was the
dominant post-place failing-path population on x3. The pulse+0 boundary stays
covered by the live-flushed adapters (REGISTER_OUTPUT, so nothing passes
through combinationally), and the FP adapters' full-flush window is extended
one cycle to cover the shim FIFO turnaround; the stale-CDB probes gate this
timing contract end-to-end.

### Instruction → reservation station routing

| RS         | Depth | Instructions |
|------------|-------|--------------|
| `INT_RS`   | 8     | ALU ops, shifts, B-extension, Zicond, conditional branches, JALR, CSR\*, ECALL, EBREAK |
| `MUL_RS`   | 4     | MUL/MULW/MULH\*/DIV\*/REM\* |
| `MEM_RS`   | 8     | All loads, stores, AMO\*, LR.W, LR.D, SC.W, SC.D, FENCE, FENCE.I, SFENCE.VMA |
| `FP_RS`    | 6     | FADD/FSUB, FMIN/FMAX, FEQ/FLT/FLE, FCVT\*, FMV.{X.W,W.X,X.D,D.X}, FCLASS, FSGNJ\* |
| `FMUL_RS`  | 4     | FMUL, FMA (3-source) |
| `FDIV_RS`  | 2     | FDIV, FSQRT (long latency, separate RS so it can't block FP_RS) |
| (none)     | —     | JAL, WFI, MRET, SRET, DRET, PAUSE — ROB-only, no operand wakeup needed |

Mixed INT/FP instructions (FCVT.W.S, FMV.X.W, FLW with INT base, …)
read sources from the appropriate RAT per source slot.

### FP rounding modes

If an FP instruction's `rm` field is `DYN`, dispatch substitutes the
current `frm` CSR value into the RS entry — capturing it in program
order so subsequent `frm` writes don't affect in-flight FP ops.

### 2-wide dispatch

The 64-bit fetch aligner emits one or two compressed/native instructions,
including cross-word pairs. Slot 2 is suppressed after control-flow or
serializing slot 1, for serializing or FP-compute slot 2, and when it would
extend beyond the fetch window.

The bundle fires atomically after checking each target's one- or two-entry
capacity; slot 2 never allocates alone.

Slot 1 control flow terminates the bundle. Slot 2 has its own RAT lookups,
destination rename, ROB allocation, and RS packet. A slot-2 source that reads
slot 1's destination is redirected to slot 1's just allocated ROB tag inside
dispatch, so same-bundle RAW dependencies behave like ordinary renamed
dependencies. Slot 2 also has its own done-repair channels: dispatch registers
slot-2 source tags on channels 4/5/6, and the wrapper repairs already-completed
sources one cycle later just like slot 1. The checkpoint pool remains
single-save-per-cycle because slot 1 branch/jump instructions suppress slot 2;
when slot 2 is the control-flow instruction, the checkpoint snapshot overlays
slot 1's rename.

### 2-wide commit

The ROB retires up to two instructions per cycle. Head and head+1
commit together when both are done and neither is a serializing
instruction (CSR, FENCE, FENCE.I, WFI, MRET, AMO, LR, SC), neither
is an exception, the head isn't mispredicting, and head+1 isn't a
mispredicted (or early-recovered) branch — a correctly-predicted branch may
retire at head+1, using a second checkpoint-free port and held BTB/bimodal
training captures. The INT and FP regfiles both support two write ports via
2-write-port distributed RAM with a Live Value Table that steers
reads to the newer (slot-2) tag on same-register conflicts. The RAT
and SQ each expose parallel slot-2 commit ports so both retires
land in the same cycle.

### Same-cycle bypasses

Two bypass paths shorten commit and completion latency:

- **CDB → head-done bypass.** When either CDB lane targets the ROB head
  (or head+1), the value flows into the commit mux the same cycle
  instead of waiting for the `rob_done[head]` flop to update. Cuts
  one cycle off the common ordinary-completion path. Excluded for
  exception / branch / CSR / FENCE / FENCE.I / WFI / MRET, which still
  use the commit-time serial path.
- **LQ addr-update + completion bypasses.** MEM_RS issues a
  pre-issue look-ahead one cycle early so the LQ's address-update
  CAM match is registered before real issue, making entries appear
  `addr_valid` the same cycle MEM_RS issues. On completion, the LQ
  writes its CDB staging register directly from the memory response
  / L0 hit / SQ-forward data, bypassing the per-entry `data_valid` + priority
  encoder path.
