# FROST CPU

`cpu_ooo.sv` pairs a two-wide in-order front-end (IF/PD/ID, BTB, direction
predictor, RAS, RVC) with the [`tomasulo/`](tomasulo/README.md) out-of-order
back-end. Shared functional units under `ex_stage/` connect through OOO shims.

```
   IF → PD → ID → 2-wide dispatch → tomasulo_wrapper → commit → regfiles
                                     (ROB / RAT / RS×6 / LQ+L0$ / SQ / CDB×2)
```

## What lives in cpu_ooo.sv

`cpu_ooo` and its private glue submodules live under
[`cpu_ooo/`](cpu_ooo/). The module instantiates the front-end stages, the
dispatch unit, `tomasulo_wrapper`, the CSR file, the trap unit, the Sv39
page-table walker (`mmu/ptw`, shared by the data MMU inside the wrapper
and the instruction MMU inside `if_stage` through a data-side-first
requester mux; see `mmu/`), and the OOO-core glue submodules below
(`branch_jump_unit` is instantiated inside the `branch_resolution`
submodule, not at top level).

### OOO-core glue submodules (`cpu_ooo/`)

| Submodule | Dir | What it does |
|-----------|-----|------------|
| `ooo_register_files` | `register_files/` | INT + FP architectural register files (two write ports for widen-commit) plus the same-cycle write-back bypass feeding ID and dispatch. |
| `frontend_validity_tracker` | `frontend_control/` | Staged IF/PD valid tracking (NOP-bubble filtering), the `id_valid`/`id_valid_2` dispatch enables, and IF/PD/ID (unpredicted) control-flow detection that drives the prediction-fence / serialization hints. |
| `commit_actions` | `commit/` | Widen-commit INT/FP regfile write-port muxing from ROB commit, the delayed CSR writeback, the `csr_commit_fire`/`csr_wb_pending` handshakes, retire valid, and the instret increment. |
| `data_mem_request_router` | `memory_if/` | Fixed-priority arbiter (SQ writes > AMO writes > LQ reads) for the single external data-memory port, the one-deep held-load register, and the MMIO load/read sidebands. Every device-quadrant handoff first captures in that register; its physically isolated terminal accept gate then waits for every committed store to drain and for the device read to be armed (`device_request_pending_q` -> `device_accept_armed_q`, two arming cycles derived from purely local state), so an irrevocable device read can never outrun the trap unit's interrupt hold. Arming only adds a precondition: every live blocker is still re-evaluated in the accept cycle. MMIO and destructive-read effects derive only from registered pending/address state, while low-BRAM/cached reads retain their live bypass. The pending Q feeds directly back into the wrapper's LQ bus-busy gate, preventing a second handoff, and lets a full flush cancel a still-unaccepted request without arming response debt. The router also routes accesses to the cached (DDR-backed) tier with handshake completion: cached loads carry the load queue's slot id and finish on the adapter's slot-tagged read-valid (several in flight, fast-tier beats take the response port first), and a cached store holds the write port busy from its fire until its done pulse, so a queued load can never read past a still-landing store. |
| `cached_tier_adapter` | `memory_if/` | Beat↔line adapter between the router and the cache hierarchy (`lib/cache/frost_cache_hierarchy`): converts CPU beats to 32 B line transactions, keeps one tagged read per load-queue slot (`riscv_pkg::CachedLoadSlots`) and one store in flight, queues read responses (the router holds them behind the fast tier's fixed-latency beat), and presents read-valid+slot / write-done / write-inflight back to the router. The file lives here, but it is instantiated one level up in `cpu_and_mem.sv` (next to `frost_cache_hierarchy`, per `cpu_and_mem.f`), not inside `cpu_ooo.sv`; `cpu_ooo` only exposes the cached request/completion ports. |
| `ex_comb_synthesizer` | `recovery/` | Synthesizes the prioritized `from_ex_comb_t` the IF stage expects (redirect / BTB update / RAS restore) and, in parallel, an early-independent lower-priority PC/outcome candidate for the BTB counter RMW. |
| `perf_counter_aggregator` | `perf/` | Accumulates the 42 top-level and 15 cache-hierarchy performance counters, snapshots them alongside the 64 wrapper-owned counters, retains the preceding cache snapshot for deferred software readback, and muxes the three-block global index space to the CSR read port. |
| `branch_resolution` | `branch_recovery/` | Resolves branch/jump issue from INT_RS (wraps `branch_jump_unit`), with flush/checkpoint suppression of wrong-path issues, and produces the ROB `branch_update`. |
| `early_misprediction_recovery` | `branch_recovery/` | Two-phase fast-recovery FSM: on a checkpointed conditional-branch misprediction it redirects the front-end and restores the RAT immediately, ~13 cycles before the branch would commit. Its late FENCE.I active-pulse gate uses the phase-equivalent registered commit payload bit, keeping the global FENCE.I flush broadcast out of that timing cone. |
| `misprediction_flush_controller` | `branch_recovery/` | Commit-time misprediction detection (vs. already-early-recovered branches), the prioritized flush hierarchy (`flush_all` for trap/MRET/FENCE.I, `flush_en`+tag for partial mispredict flushes), and the checkpoint restore / free / bulk-free-mask machinery. |
| `ooo_pipeline_control` | `pipeline_control/` | Front-end stall / serialization aggregation, the CSR / branch in-flight counters, post-flush BRAM holdoff, the registered trap/MRET pulse + target, the prediction-disable gate, and the `pipeline_ctrl_t` assembly. |

The branch-recovery / commit / `from_ex_comb` submodules share two capture
structs (`mispredict_commit_capture_t`, `correct_branch_commit_capture_t`) that
live in `riscv_pkg` (yosys's `read_verilog -sv` cannot resolve cross-package
type references inside another package's typedef, so a separate `cpu_ooo_pkg`
was not viable).

## What remains inline in cpu_ooo.sv

Inline logic is limited to the ROB-head CSR bypass, RAT/checkpoint gating around
`tomasulo_wrapper`, CSR/trap commit glue, reset-done counter, and `dbg_*` mirror
taps kept at this hierarchy for cocotb.

The branch-resolution → early-recovery → commit-time-flush cluster (the fast
~2-cycle conditional-branch misprediction path and the prioritized
trap/MRET/FENCE.I/mispredict flush hierarchy) now lives under
[`cpu_ooo/branch_recovery/`](cpu_ooo/branch_recovery/). Commit-time JAL updates make a BTB-cold
JAL a one-time miss; early recovery also updates the BTB unconditionally.

### Front-end branch prediction

The front-end has three prediction structures:

- A 256-entry BTB supplies targets, direction counters for BTB hits, and slot-2
  lookup support.
- An 8-entry RAS predicts returns.
- A 1024-entry bimodal direction predictor supplies a conditional-branch
  taken/not-taken prediction independent of BTB hit status.

BTB counter training keeps two canonical update-read copies with identical
writes. One copy is addressed by the independently formed lower-priority
commit/recovery transaction; the other is addressed directly by the captured
early-mispredict PC. Neither read address depends on the early-active
qualifier. Both saturating-counter results are computed in parallel, and early
recovery selects only the final 2-bit write value. The original prioritized
transaction remains the sole source of actual writes, so the write edge,
address, tag, target, metadata, replacement policy, and counter hysteresis are
unchanged.

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
| `if_stage/`, `pd_stage/`, `id_stage/` | **In use**  | Reused front-end stages, including BTB/direction/RAS prediction, PD BTB-miss redirects, and RVC handling. IF now drives a stall-capable, variable-latency fetch seam (NOP bubbles + a 1-deep owed-ask while unserved) so code can run from the cached DDR region as well as low BRAM; the two fetch sources — the low-BRAM fast path and, when the cached tier is enabled, `fetch_provider` (a two-line L1I fetch buffer with predecode-on-fill for the cached region) — are selected in `cpu_and_mem.sv`, one level up. The fetch PC is virtual: the instruction MMU (`mmu/immu`, instantiated in `if_stage`) translates it into the window's two physical word addresses and fault flags on the PC path itself (zero hit latency; an ITLB miss stalls the front end), and the seam carries that physical pair beside the virtual PC. |
| `mmu/`                              | **In use**    | Sv39 translation: `dtlb` (the generic fully-associative superpage-aware TLB, instantiated as the 16-entry DTLB and the 8-entry ITLB), `dmmu` (the data-side translation stage inside the wrapper), `immu` (the fetch-side PA shadows in `if_stage`), and `ptw` (the read-only walker, Svade). |
| `wb_stage/`                         | **In use**    | Only the parameterized regfile is in the OOO build (instantiated twice for INT / FP). |
| `csr/`                              | **In use**    | Zicsr / Zicntr / fcsr. CSR ops are decoded in ID but read and write the CSR at commit through the ROB serializing FSM. |
| `control/trap_unit.sv`               | **In use**    | M/S/U exception/interrupt handling with delegation (traps taken in M or S) used by `cpu_ooo.sv`. |
| `ex_stage/`                         | **In use**    | `branch_jump_unit.sv` is instantiated inside `cpu_ooo/branch_recovery/branch_resolution.sv`. ALU/MUL/DIV/FPU are used via the FU shims in `tomasulo/fu_shims/`. |

`cpu_ooo.f` is the authoritative filelist for what actually gets compiled.
