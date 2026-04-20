# FROST Tomasulo Out-of-Order Back-End

The Tomasulo back-end replaces the in-order EX / MA / WB pipeline with
dynamic instruction scheduling, register renaming, speculation, and
out-of-order completion — while preserving precise exceptions and the
existing ISA support (RV32IMACBFD + Zbkb + Zicond + Zicntr + Zihintpause).
The front-end (IF / PD / ID, branch predictor, RAS, RVC) and the
functional units (ALU, multiplier, divider, FPU) are reused unchanged
from the in-order core.

```
   IF → PD → ID → dispatch ──► ROB                ┌─► commit ─► regfile / SQ /
                  rename       (32 entries)       │             trap entry / redirect
                  resource    + RAT (INT+FP,
                  alloc        4 ckpts)
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
                              CDB (1 lane)
                          ─ broadcast value & tag
                          ─ wakes RS, marks ROB done
```

## What's in this directory

| Submodule                                                          | Role |
|--------------------------------------------------------------------|------|
| [`tomasulo_wrapper/`](tomasulo_wrapper/README.md)                  | Glue: instantiates everything below, plus inline routing / SC FSM / commit & CDB pipelining |
| [`dispatch/`](dispatch/README.md)                                  | Combinational rename + resource allocation hub |
| [`reorder_buffer/`](reorder_buffer/README.md)                      | In-order commit, precise exceptions, serializing instructions |
| [`register_alias_table/`](register_alias_table/README.md)          | INT + FP rename tables, branch checkpoints |
| [`reservation_station/`](reservation_station/README.md)            | Generic RS, instantiated 6× |
| [`load_queue/`](load_queue/README.md)                              | Loads, L0 cache, MMIO, FP64 phasing, LR/AMO |
| [`store_queue/`](store_queue/README.md)                            | Stores, store-to-load forwarding, FSD phasing |
| [`cdb_arbiter/`](cdb_arbiter/README.md)                            | Single-lane CDB priority arbiter |
| [`fu_cdb_adapter/`](fu_cdb_adapter/README.md)                      | One-deep holding register per FU slot |
| [`fu_shims/`](fu_shims/README.md)                                  | Adapters from RS issue to the reused FUs |

The CPU top-level (`../cpu_ooo.sv`) instantiates `tomasulo_wrapper`
plus `dispatch` and the front-end stages, and contains a few large
inline blocks that straddle the front-end / back-end boundary
(early misprediction recovery, commit flush controller, memory port
arbitration, …). See [`../README.md`](../README.md).

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

Aggressive memory speculation with mispredict recovery is *not*
implemented. The conservative gating costs IPC on memory-heavy code
but keeps the design simple and provably correct.

### Two-tier branch recovery

Branches and JALRs reserve a RAT checkpoint at dispatch (full INT +
FP RAT snapshot + RAS top + valid count, 4 slots).

Conditional-branch mispredictions resolve in `branch_jump_unit` and
trigger a fast two-phase recovery directly from `cpu_ooo.sv`: the
front-end redirects and the RAT restores in the same cycle, then the
OOO back-end's partial flush fires one cycle later. This cuts the
typical penalty from ~15 cycles to ~2.

JALR mispredictions and exceptions go through the slower commit-time
path because their recovery PC depends on results that may still be
in flight when the fast path would fire. Both paths use the same
age-based partial flush primitive everywhere downstream.

### Serializing instructions

A small FSM in the ROB pins certain instructions at the commit head:

| Class               | Behavior |
|---------------------|----------|
| **WFI**             | Stalls at head until an interrupt is pending. |
| **CSR**             | Read result rides the CDB; the side effect is applied at commit via a `csr_file` handshake. |
| **FENCE / FENCE.I** | Drains the SQ before commit. FENCE.I additionally pulses a one-cycle pipeline + icache flush. |
| **MRET**            | Hand-shakes with `trap_unit`; redirect PC = `mepc`. |
| **AMO / SC**        | Fires only at head with the SQ committed-empty (no older stores in flight). |

### Single-CDB arbitration

One result broadcast per cycle. Fixed priority, longest-latency wins,
so a high-latency unit doesn't get pushed even further by losing
arbitration:

```
FP_DIV  >  DIV  >  FP_MUL  >  MUL  >  FP_ADD  >  MEM  >  ALU
```

Losers latch their result in a one-deep `fu_cdb_adapter` and
re-present it next cycle. Pipelined units (MUL, DIV, FDIV) also
have internal result FIFOs with credit-based back-pressure to absorb
multi-cycle contention.

Full-flush CDB suppression is handled centrally at the arbiter via
an `i_kill` input, rather than replicated across every per-FU
adapter — this keeps the broadly-fanned flush signal out of each
adapter's output cone.

### Instruction → reservation station routing

| RS         | Depth | Instructions |
|------------|-------|--------------|
| `INT_RS`   | 16    | ALU ops, shifts, B-extension, Zicond, conditional branches, JALR, CSR\*, ECALL, EBREAK |
| `MUL_RS`   | 4     | MUL/MULH\*/DIV\*/REM\* |
| `MEM_RS`   | 8     | All loads, stores, AMO\*, LR.W, SC.W, FENCE, FENCE.I |
| `FP_RS`    | 6     | FADD/FSUB, FMIN/FMAX, FEQ/FLT/FLE, FCVT\*, FMV.{X.W,W.X}, FCLASS, FSGNJ\* |
| `FMUL_RS`  | 4     | FMUL, FMA (3-source) |
| `FDIV_RS`  | 2     | FDIV, FSQRT (long latency, separate RS so it can't block FP_RS) |
| (none)     | —     | JAL, WFI, MRET, PAUSE — ROB-only, no operand wakeup needed |

Mixed INT/FP instructions (FCVT.W.S, FMV.X.W, FLW with INT base, …)
read sources from the appropriate RAT per source slot.

### FP rounding modes

If an FP instruction's `rm` field is `DYN`, dispatch substitutes the
current `frm` CSR value into the RS entry — capturing it in program
order so subsequent `frm` writes don't affect in-flight FP ops.

### 2-wide commit

The ROB retires up to two instructions per cycle. Head and head+1
commit together when both are done and neither is a serializing
instruction (CSR, FENCE, FENCE.I, WFI, MRET, AMO, LR, SC), neither
is an exception, the head isn't mispredicting, and head+1 isn't any
branch. The INT and FP regfiles both support two write ports via
2-write-port distributed RAM with a Live Value Table that steers
reads to the newer (slot-2) tag on same-register conflicts. The RAT
and SQ each expose parallel slot-2 commit ports so both retires
land in the same cycle.

### Same-cycle bypasses

Two bypass paths shorten commit and completion latency:

- **CDB → head-done bypass.** When a CDB write targets the ROB head
  (or head+1), the value flows into the commit mux the same cycle
  instead of waiting for the `rob_done[head]` flop to update. Cuts
  one cycle off the common ordinary-completion path. Excluded for
  exception / branch / CSR / FENCE / WFI / MRET, which still use
  the commit-time serial path.
- **LQ addr-update + completion bypasses.** MEM_RS issues a
  pre-issue look-ahead one cycle early so the LQ's address-update
  CAM match is registered before real issue, making entries appear
  `addr_valid` the same cycle MEM_RS issues. On completion, the LQ
  writes its CDB staging register directly from the memory response
  / L0 hit data, bypassing the per-entry `data_valid` + priority
  encoder path.
