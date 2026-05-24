# FROST CPU

`cpu_ooo.sv` is the top-level RISC-V CPU module. It pairs a 2-wide
in-order front-end (IF / PD / ID, branch predictor, RAS, RVC) with a
Tomasulo out-of-order back-end (in [`tomasulo/`](tomasulo/README.md)).
The reused functional units (ALU, multiplier, divider, FPU) live under
`ex_stage/` and are wrapped by FU shims for OOO use.

```
   IF → PD → ID → 2-wide dispatch → tomasulo_wrapper → commit → regfiles
                                     (ROB / RAT / RS×6 / LQ+L0$ / SQ / CDB)
```

## What lives in cpu_ooo.sv

`cpu_ooo` and its private glue submodules live under
[`cpu_ooo/`](cpu_ooo/). The module instantiates the front-end stages, the
dispatch unit, `tomasulo_wrapper`, the CSR file, the trap unit, a standalone
`branch_jump_unit` for combinational branch resolution, and the OOO-core glue
submodules below.

Much of the front-end / back-end integration logic that used to sit inline has
been factored into those submodules (no functional change — pure boundary
moves). What remains inline in `cpu_ooo.sv` is the most tightly
front-end/back-end-coupled control: branch resolution, early-misprediction
recovery, the commit-time misprediction & flush controller, and the
dispatch-stall aggregation core.

### OOO-core glue submodules (`cpu_ooo/`)

| Submodule | Dir | What it does |
|-----------|-----|------------|
| `ooo_register_files` | `register_files/` | INT + FP architectural register files (two write ports for widen-commit) plus the same-cycle write-back bypass feeding ID and dispatch. |
| `frontend_validity_tracker` | `frontend_control/` | Staged IF/PD valid tracking (NOP-bubble filtering), the `id_valid`/`id_valid_2` dispatch enables, and IF/PD/ID (unpredicted) control-flow detection that drives the prediction-fence / serialization hints. |
| `commit_actions` | `commit/` | Widen-commit INT/FP regfile write-port muxing from ROB commit, the delayed CSR writeback, the `csr_commit_fire`/`csr_wb_pending` handshakes, retire valid, and the instret increment. |
| `data_mem_request_router` | `memory_if/` | Fixed-priority arbiter (SQ writes > AMO writes > LQ reads) for the single external data-memory port, the one-deep blocked-load replay register, and the MMIO load/read sidebands. |
| `ex_comb_synthesizer` | `recovery/` | Synthesizes the `from_ex_comb_t` the IF stage expects (redirect / BTB update / RAS restore), multiplexing the early-recovery, commit-recovery, and correct-branch-commit sources. |
| `perf_counter_aggregator` | `perf/` | The ~23 top-level performance counters (accumulate / snapshot / mux to the CSR read port). |
| `cpu_ooo_pkg` | `cpu_ooo/` | Internal capture structs shared between `cpu_ooo` and the recovery / commit / `from_ex_comb` glue. |

## Still inline in cpu_ooo.sv

These blocks remain at the top level because each one consumes signals from
both the in-order front-end and the OOO back-end. They are the natural next
candidates for extraction.

### Early misprediction recovery

A two-phase fast path that triggers as soon as `branch_jump_unit`
resolves a conditional-branch misprediction, instead of waiting for
the branch to retire. Phase 1 redirects the front-end and atomically
restores the RAT from the branch's checkpoint; phase 2 (one cycle
later) drives the partial flush into the OOO back-end. This cuts the
typical conditional-branch misprediction penalty from ~15 cycles to
~2.

JALR mispredictions still go through the slow commit-time path
because the JALR target depends on rs1, which may itself be in
flight. Older unresolved branches retain their checkpoints across
the recovery, so they can still trigger their own recovery if they
later mispredict.

### Commit-time misprediction & flush controller

Detects mispredictions at commit, distinguishes them from branches
already early-recovered, and drives the global flush / checkpoint /
BTB-update machinery into the OOO back-end. Also handles the
exception, MRET, and FENCE.I commit paths, which all funnel into a
prioritized flush hierarchy (`flush_all` for traps and FENCE.I,
`flush_en` + tag for partial mispredict flushes).

A historical note in the inline comments: BTB-cold JAL sites used to
mispredict on every execution, costing thousands of bubbles per
benchmark run. Pulling JAL into the commit-time BTB-update path
turns that into a one-time cost per JAL site. Early recovery does
its BTB update unconditionally for the same reason.

### Pipeline control

The OOO back-end stalls almost exclusively at dispatch, so this
block aggregates the various stall sources (ROB / RS / LQ / SQ /
checkpoint exhaustion) and special-cases the few instructions that
need extra serialization. CSRs block dispatch of any younger
instruction until they commit; an unresolved older branch blocks
fetch of a younger unpredicted JALR/return so the indirect target
prediction stays fresh.

The IF/PD/ID control-flow detection that feeds these serialization/prediction
hints now lives in `frontend_validity_tracker`, and the ~23 performance
counters moved to `perf_counter_aggregator`; the dispatch-stall aggregation
core is what remains here.

### 2-wide dispatch integration

The front-end carries two instruction packets through IF, PD, and ID. Dispatch
then fires slot 1 plus an optional slot 2 as an atomic bundle when the ROB,
target RS, LQ/SQ, and checkpoint pool have room. Slot 1 control flow terminates
the bundle; slot 2 can still be ordinary integer or memory work, or a
BTB-predicted branch/JALR when the slot-2 BTB lookup hits. Native 32-bit slot-2
branches at halfword PCs are supported when the BTB entry was trained for that
instruction size.

## Directory contents

| Path                                | Status        | What it is |
|-------------------------------------|---------------|------------|
| [`cpu_ooo/`](cpu_ooo/)              | **In use**    | `cpu_ooo.sv` (top-level integration), `cpu_ooo_pkg`, and the OOO-core glue submodules extracted from the top level (see the table above). |
| [`tomasulo/`](tomasulo/README.md)   | **In use**    | The OOO back-end. See its README for everything inside. |
| `if_stage/`, `pd_stage/`, `id_stage/` | **In use**  | Reused front-end stages, including the branch predictor and RVC handling. |
| `wb_stage/`                         | **In use**    | Only the parameterized regfile is in the OOO build (instantiated twice for INT / FP). |
| `csr/`                              | **In use**    | Zicsr / Zicntr / fcsr. CSR ops are decoded in ID but read and write the CSR at commit through the ROB serializing FSM. |
| `control/`                          | **Mostly legacy** | Only `trap_unit.sv` is reused. The forwarding/hazard units are in-order leftovers — Tomasulo handles those natively. |
| `ex_stage/`                         | **Repurposed** | `branch_jump_unit.sv` is instantiated directly at top level. ALU/MUL/DIV/FPU are reused via the FU shims in `tomasulo/fu_shims/`. |
| `ma_stage/`, `cache/`               | **Legacy**    | In-order memory access stage and L0 cache. Replaced by the LQ + SQ + `lq_l0_cache` inside `tomasulo/`. Not in `cpu_ooo.f`. |
| `data_mem_arbiter.sv`               | **Legacy**    | Standalone arbiter from the in-order design, still formally verified standalone but not in the OOO build. |

`cpu_ooo.f` is the authoritative filelist for what actually gets compiled.
