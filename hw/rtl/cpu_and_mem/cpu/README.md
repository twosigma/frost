# FROST CPU

`cpu_ooo.sv` is the top-level RISC-V CPU module. It pairs a 2-wide
in-order front-end (IF / PD / ID, BTB + direction predictor + RAS, RVC) with a
Tomasulo out-of-order back-end (in [`tomasulo/`](tomasulo/README.md)).
The reused functional units (ALU, multiplier, divider, FPU) live under
`ex_stage/` and are wrapped by FU shims for OOO use.

```
   IF → PD → ID → 2-wide dispatch → tomasulo_wrapper → commit → regfiles
                                     (ROB / RAT / RS×6 / LQ+L0$ / SQ / CDB×2)
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
| `data_mem_request_router` | `memory_if/` | Fixed-priority arbiter (SQ writes > AMO writes > LQ reads) for the single external data-memory port, the one-deep blocked-load replay register, and the MMIO load/read sidebands. Also routes accesses to the cached (DDR-backed) tier with handshake completion: cached loads finish on the adapter's read-valid pulse, and a cached store holds the write port busy from its fire until its done pulse, so a queued load can never read past a still-landing store. |
| `cached_tier_adapter` | `memory_if/` | Word↔line adapter between the router and the cache hierarchy (`lib/cache/frost_cache_hierarchy`): converts CPU words to 32 B line transactions, serializes one in flight, and presents read-valid / write-done / write-inflight back to the router. The file lives here, but it is instantiated one level up in `cpu_and_mem.sv` (next to `frost_cache_hierarchy`, per `cpu_and_mem.f`), not inside `cpu_ooo.sv`; `cpu_ooo` only exposes the cached request/completion ports. |
| `ex_comb_synthesizer` | `recovery/` | Synthesizes the `from_ex_comb_t` the IF stage expects (redirect / BTB update / RAS restore), multiplexing the early-recovery, commit-recovery, and correct-branch-commit sources. |
| `perf_counter_aggregator` | `perf/` | The ~23 top-level performance counters (accumulate / snapshot / mux to the CSR read port). |
| `branch_resolution` | `branch_recovery/` | Resolves branch/jump issue from INT_RS (wraps `branch_jump_unit`), with flush/checkpoint suppression of wrong-path issues, and produces the ROB `branch_update`. |
| `early_misprediction_recovery` | `branch_recovery/` | Two-phase fast-recovery FSM: on a checkpointed conditional-branch misprediction it redirects the front-end and restores the RAT immediately, ~13 cycles before the branch would commit. |
| `misprediction_flush_controller` | `branch_recovery/` | Commit-time misprediction detection (vs. already-early-recovered branches), the prioritized flush hierarchy (`flush_all` for trap/MRET/FENCE.I, `flush_en`+tag for partial mispredict flushes), and the checkpoint restore / free / bulk-free-mask machinery. |
| `ooo_pipeline_control` | `pipeline_control/` | Front-end stall / serialization aggregation, the CSR / branch in-flight counters, post-flush BRAM holdoff, the registered trap/MRET pulse + target, the prediction-disable gate, and the `pipeline_ctrl_t` assembly. |

The branch-recovery / commit / `from_ex_comb` submodules share two capture
structs (`mispredict_commit_capture_t`, `correct_branch_commit_capture_t`) that
live in `riscv_pkg` (yosys's `read_verilog -sv` cannot resolve cross-package
type references inside another package's typedef, so a separate `cpu_ooo_pkg`
was not viable).

## What remains inline in cpu_ooo.sv

After the extractions above, `cpu_ooo.sv` is mostly submodule instantiation and
wiring. What is still inline is the glue that is too small or too instance-local
to warrant its own module: the ROB-head bypass read for CSR write data, the
RAT-allocation / checkpoint-save gating around the `tomasulo_wrapper` instance,
the CSR-file and trap-unit commit glue, the reset-done counter, and the
front-end debug mirror taps (`dbg_*`, kept here so cocotb's hierarchical probes
resolve at the `cpu_ooo` level).

The branch-resolution → early-recovery → commit-time-flush cluster (the fast
~2-cycle conditional-branch misprediction path and the prioritized
trap/MRET/FENCE.I/mispredict flush hierarchy) now lives under
[`cpu_ooo/branch_recovery/`](cpu_ooo/). One historical note worth keeping:
BTB-cold JAL sites used to mispredict on every execution; pulling JAL into the
commit-time BTB-update path turns that into a one-time cost per JAL site, and
early recovery does its BTB update unconditionally for the same reason.

### Front-end branch prediction

The front-end has three prediction structures:

- A 256-entry BTB supplies targets, direction counters for BTB hits, and slot-2
  lookup support.
- An 8-entry RAS predicts returns.
- A 1024-entry bimodal direction predictor supplies a conditional-branch
  taken/not-taken prediction independent of BTB hit status.

The decoupled direction predictor lets PD recover useful work from conditional
branches that miss the BTB. IF carries the predicted direction and predict-time
direction index with each fetched branch. If PD sees a conditional branch whose
BTB/RAS path did not already redirect and the carried direction predicts taken,
PD computes the branch target from the decoded immediate and redirects the
front-end immediately. At commit, `cpu_ooo.sv` trains the bimodal table using
the carried predict-time index so replay/stall halfword cases update the same
entry they originally read.

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
| [`cpu_ooo/`](cpu_ooo/)              | **In use**    | `cpu_ooo.sv` (top-level integration) and the OOO-core glue submodules extracted from the top level (see the table above). |
| [`tomasulo/`](tomasulo/README.md)   | **In use**    | The OOO back-end. The wrapper and the larger modules (store/load queues, ROB) now nest their extracted glue/datapath submodules; see its README and the per-module READMEs for everything inside. |
| `if_stage/`, `pd_stage/`, `id_stage/` | **In use**  | Reused front-end stages, including BTB/direction/RAS prediction, PD BTB-miss redirects, and RVC handling. IF now drives a stall-capable, variable-latency fetch seam (NOP bubbles + a 1-deep owed-ask while unserved) so code can run from the cached DDR region as well as low BRAM; the seam's `fetch_provider` (low-BRAM fast path vs. a two-line L1I fetch buffer with predecode-on-fill) lives one level up in `cpu_and_mem/`. |
| `wb_stage/`                         | **In use**    | Only the parameterized regfile is in the OOO build (instantiated twice for INT / FP). |
| `csr/`                              | **In use**    | Zicsr / Zicntr / fcsr. CSR ops are decoded in ID but read and write the CSR at commit through the ROB serializing FSM. |
| `control/trap_unit.sv`               | **In use**    | Machine-mode exception/interrupt handling used by `cpu_ooo.sv`. |
| `ex_stage/`                         | **In use**    | `branch_jump_unit.sv` is instantiated directly at top level. ALU/MUL/DIV/FPU are used via the FU shims in `tomasulo/fu_shims/`. |

`cpu_ooo.f` is the authoritative filelist for what actually gets compiled.
