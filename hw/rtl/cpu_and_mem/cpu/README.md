# FROST CPU

`cpu_ooo.sv` is the top-level RISC-V CPU module. It pairs an unchanged
in-order front-end (IF / PD / ID, branch predictor, RAS, RVC) with a
Tomasulo out-of-order back-end (in [`tomasulo/`](tomasulo/README.md)).
The reused functional units (ALU, multiplier, divider, FPU) live under
`ex_stage/` and are wrapped by FU shims for OOO use.

```
   IF → PD → ID → dispatch → tomasulo_wrapper → commit → regfiles
                              (ROB / RAT / RS×6 / LQ+L0$ / SQ / CDB)
```

## What lives in cpu_ooo.sv

The module is mostly straightforward instantiation and wiring of the
front-end stages, the dispatch unit, `tomasulo_wrapper`, the CSR file,
the trap unit, and a standalone `branch_jump_unit` for combinational
branch resolution.

What makes it interesting is the inline integration logic that
straddles the front-end / back-end boundary — roughly half of the
file. The blocks below could plausibly become their own modules
later, but currently they live here because each one consumes
signals from both the in-order front-end and the OOO back-end.

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

It also owns the performance counters (~23 of them, banked into
groups to keep readout fanout under control).

### Memory port arbitration

A small fixed-priority arbiter — SQ writes > AMO writes > LQ reads —
multiplexing the single external data memory port. Loads that arrive
while the bus is busy are held in a one-deep request register and
replayed when the bus frees up. The MMIO load-address side-band
strobe is generated here from the data memory address against the
platform's MMIO address range.

### Other inline blocks

`from_ex_comb` synthesis assembles the redirect / BTB-update / RAS-restore
struct that the IF stage expects, multiplexing among the early-recovery,
commit-time-recovery, and correctly-predicted-branch sources.
Commit-time regfile muxing turns ROB commit into INT or FP regfile
writes (with a special case to pull CSR read data from the
combinational `csr_file` read instead of the ROB's value field).

## Directory contents

| Path                                | Status        | What it is |
|-------------------------------------|---------------|------------|
| [`tomasulo/`](tomasulo/README.md)   | **In use**    | The OOO back-end. See its README for everything inside. |
| `if_stage/`, `pd_stage/`, `id_stage/` | **In use**  | Reused front-end stages, including the branch predictor and RVC handling. |
| `wb_stage/`                         | **In use**    | Only the parameterized regfile is in the OOO build (instantiated twice for INT / FP). |
| `csr/`                              | **In use**    | Zicsr / Zicntr / fcsr. CSR reads happen in ID; writes commit through the ROB serializing FSM. |
| `control/`                          | **Mostly legacy** | Only `trap_unit.sv` is reused. The forwarding/hazard units are in-order leftovers — Tomasulo handles those natively. |
| `ex_stage/`                         | **Repurposed** | `branch_jump_unit.sv` is instantiated directly at top level. ALU/MUL/DIV/FPU are reused via the FU shims in `tomasulo/fu_shims/`. |
| `ma_stage/`, `cache/`               | **Legacy**    | In-order memory access stage and L0 cache. Replaced by the LQ + SQ + `lq_l0_cache` inside `tomasulo/`. Not in `cpu_ooo.f`. |
| `data_mem_arbiter.sv`               | **Legacy**    | Standalone arbiter from the in-order design, still formally verified standalone but not in the OOO build. |

`cpu_ooo.f` is the authoritative filelist for what actually gets compiled.
