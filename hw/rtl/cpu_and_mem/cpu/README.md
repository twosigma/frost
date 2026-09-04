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
page-table walker, and the glue submodules in the table below. The single
`mmu/ptw` instance serves both the data MMU inside the wrapper and the
instruction MMU inside `if_stage`; the data side wins the requester mux (see
`mmu/`). `branch_jump_unit` is instantiated inside the `branch_resolution`
submodule, not at top level.

### OOO-core glue submodules (`cpu_ooo/`)

| Submodule | Dir | What it does |
|-----------|-----|------------|
| `ooo_register_files` | `register_files/` | INT and FP architectural register files, each with two write ports for widen commit, plus the same-cycle write-back bypass that feeds ID and dispatch. |
| `frontend_validity_tracker` | `frontend_control/` | Staged IF/PD valid tracking that filters NOP bubbles, the preflush `id_valid` candidates with their recovery-qualified debug companions, and detection of unpredicted control flow in IF/PD/ID, which drives the prediction-fence and serialization hints. Dispatch owns the sole architectural recovery gate. |
| `commit_actions` | `commit/` | Muxes ROB commit onto the INT/FP regfile write ports for widen commit, applies the delayed CSR writeback, and drives the `csr_commit_fire`/`csr_wb_pending` handshakes, retire valid, and the instret increment. |
| `data_mem_request_router` | `memory_if/` | Fixed-priority arbiter (SQ writes > AMO writes > LQ reads) for the single external data-memory port, with a one-deep held-load register and the MMIO load/read sidebands. Every device-quadrant handoff captures in that register first. Its physically isolated terminal accept gate then waits for every committed store to drain and for the device read to be armed (`device_request_pending_q` -> `device_accept_armed_q`, two arming cycles derived from local state), so an irrevocable device read cannot outrun the trap unit's interrupt hold. Arming only adds a precondition: every live blocker is re-evaluated in the accept cycle. MMIO and destructive-read effects derive only from registered pending/address state; low-BRAM and cached reads keep their live bypass. The pending Q feeds back into the wrapper's LQ bus-busy gate, which blocks a second handoff, and lets a full flush cancel a still-unaccepted request without arming response debt. The router also serves the cached (DDR-backed) tier with handshake completion: cached loads carry the load queue's slot id and finish on the adapter's slot-tagged read-valid (several may be in flight; fast-tier beats take the response port first), and a cached store holds the write port busy from its fire until its done pulse, so a queued load cannot read past a store that is still landing. |
| `cached_tier_adapter` | `memory_if/` | Beat/line adapter between the router and the cache hierarchy (`lib/cache/frost_cache_hierarchy`). It converts CPU beats to 32 B line transactions, keeps one tagged read per load-queue slot (`riscv_pkg::CachedLoadSlots`) and one store in flight, queues read responses while the router holds them behind the fast tier's fixed-latency beat, and presents read-valid+slot, write-done, and write-inflight back to the router. The file lives here, but `cpu_and_mem.sv` instantiates it one level up, next to `frost_cache_hierarchy` (see `cpu_and_mem.f`); `cpu_ooo` only exposes the cached request and completion ports. |
| `ex_comb_synthesizer` | `recovery/` | Builds the prioritized `from_ex_comb_t` the IF stage expects (redirect, BTB update, RAS restore) and, in parallel, a lower-priority PC/outcome candidate for the BTB counter read-modify-write that does not depend on the early-recovery qualifier. |
| `perf_counter_aggregator` | `perf/` | Accumulates the 42 top-level and 24 cache-hierarchy performance counters, snapshots them alongside the 64 wrapper-owned counters, keeps the previous cache snapshot for deferred software readback, and muxes the three-block global index space onto the CSR read port. Counter definitions are in [`perf/README.md`](cpu_ooo/perf/README.md). |
| `branch_resolution` | `branch_recovery/` | Resolves the registered branch/JAL/JALR payload from INT_RS (wrapping `branch_jump_unit`) in parallel with flush and checkpoint-owner validation, and applies that validation only at the architectural ROB `branch_update`. |
| `early_misprediction_recovery` | `branch_recovery/` | Two-phase fast-recovery FSM. On a checkpointed conditional-branch misprediction it redirects the front-end and restores the RAT at once, about 13 cycles before the branch would commit. The wide redirect/BTB payload flops capture an inert issue-local superset; only the fully qualified misprediction launches recovery. Its late FENCE.I active-pulse gate uses the phase-equivalent registered commit payload bit, which keeps both global qualification broadcasts out of the payload and active timing cones. |
| `misprediction_flush_controller` | `branch_recovery/` | Commit-time misprediction detection (as distinct from branches already recovered early), the prioritized flush hierarchy (`flush_all` for trap/xRET/FENCE-class recovery, `flush_en` plus tag for partial mispredict flushes), and the checkpoint restore, free, and bulk-free-mask machinery. Its replicated full-flush kill register is fed by the serializer-owned native-fence/translation-CSR event. |
| `ooo_pipeline_control` | `pipeline_control/` | Front-end stall and serialization aggregation, the CSR and branch in-flight counters, the post-flush BRAM holdoff, the registered trap/MRET pulse and target, the prediction-disable gate, and `pipeline_ctrl_t` assembly. Successful CSR allocation is captured by the local ID-stall owner so the live in-flight bit does not feed dispatch allocation. CSR release distinguishes the normal younger-ID replay from an allocation cycle already held by fetch translation; the latter gets one advance-only cycle so the same CSR cannot dispatch twice. |

The branch-recovery, commit, and `from_ex_comb` submodules share two capture
structs, `mispredict_commit_capture_t` and `correct_branch_commit_capture_t`,
which live in `riscv_pkg`. A separate `cpu_ooo_pkg` was not viable because
yosys's `read_verilog -sv` cannot resolve cross-package type references inside
another package's typedef.

## What remains inline in cpu_ooo.sv

Inline logic is limited to the ROB-head CSR bypass, RAT/checkpoint gating around
`tomasulo_wrapper`, CSR/trap commit glue, the reset-done counter, the Debug-Mode
single-step engine with its parked/command bookkeeping (Phase 3 M3), and the
`dbg_*` mirror taps kept at this hierarchy for cocotb.

Debug Mode (RISC-V Debug Spec 0.13.2) spans three other modules. `csr/csr_file`
owns `dcsr`, `dpc`, `dscratch0`, `dscratch1`, and the `ddata` shadow of the
debug module's data0/data1; it records entry state, installs M privilege, and
restores `dcsr.prv` on `dret`, clearing MPRV when the new privilege is below M
(as Spike does). `control/trap_unit` adds the D take class: halt requests, step
completion, the debug module's `go` redirect, `ebreak` routing per
`dcsr.ebreak*`, CSR-free re-parks for exceptions taken in Debug Mode, and the
M/S interrupt mask. The reorder buffer routes `DRET` through the MRET serial
path with an `is_dret` sideband and gates it and the debug CSRs on the live
Debug-Mode bit. The step engine in `cpu_ooo` arms on `dret` with `dcsr.step`,
retires one instruction, and raises the halt for the next head. While a step is
armed, widen commit is off and the validity tracker allocates user NOP bundles,
which FROST otherwise never retires; once the stepped instruction retires, the
registered commit hold stops the next one. Trap entry also seeds the interrupt
resume PC with the trap target, so a stepped instruction that traps halts at
its handler, and an M-target interrupt taken in the shadow of a delegated entry
saves the handler's PC.

The branch-resolution, early-recovery, and commit-time-flush cluster (the fast
~2-cycle conditional-branch misprediction path and the prioritized
trap/xRET/FENCE-class/mispredict flush hierarchy) lives under
[`cpu_ooo/branch_recovery/`](cpu_ooo/branch_recovery/). Commit-time JAL updates
make a BTB-cold JAL a one-time miss; early recovery also updates the BTB
unconditionally.

Translation-class CSR recovery is owned by the ROB serializer rather than
reconstructed from the CSR-file write pulse. After the CSR handshake it drains
committed stores, retires under the normal permit, and registers a shadow/event
that aligns with the registered commit-bus write into `csr_file`; the full
pipeline flush follows one cycle later. `cpu_ooo` quiesces trap, Debug, and xRET
takes and suppresses exception presentation across the shadow and final-flush
cycles, preventing stale younger control effects from racing the CSR update.
The CSR file independently emits the registered TLB/PTW invalidate request:
conservative for `satp`, and change-sensitive for `mstatus`/`sstatus`.

### Front-end branch prediction

The front-end has three prediction structures:

- A 256-entry BTB supplies targets, direction counters for BTB hits, and slot-2
  lookup support. Three single-address images hold entries keyed by their +2
  predecessor, +4 predecessor, and a one-index rotation of the +2 predecessor.
  With normal one-cycle fetch service, every image reads the live fetch word
  index and serves it one cycle later; the rotated +2 image serves the
  successor word without an `A+1` RAM address on the fetch-PC cone. A repeated
  slow response outside the low-memory overlay collapses that lead and uses
  the served window's live metadata, keeping the same images aligned. Payloads
  occupy separate block-RAM primitives. Each exact tag is captured from a
  single-read distributed-RAM copy, keeping every full tag comparison off the
  block-RAM clock-to-output path. Full-entry same-edge forwarding preserves
  replacement and counter state.
- An 8-entry RAS predicts returns.
- A 1024-entry bimodal direction predictor supplies a conditional-branch
  taken/not-taken prediction independent of BTB hit status.

BTB counter training keeps two canonical update-read copies with identical
writes. One copy is addressed by the independently formed lower-priority
commit/recovery transaction; the other is addressed directly by the captured
early-mispredict PC. Neither read address depends on the early-active
qualifier. Both saturating-counter results are computed in parallel, and early
recovery selects only the final 2-bit write value. The original prioritized
transaction remains the sole source of BTB writes, so the write edge,
address, tag, target, metadata, replacement policy, and counter hysteresis are
unchanged. The whole update transaction is registered once at the prediction
controller before it reaches the BTB, so training lands one cycle after the
commit or recovery event that produced it; consecutive updates keep their
relative order, and only a lookup made in that one cycle sees the pre-update
entry.

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
the bundle; slot 2 may still be ordinary integer or memory work, or a
BTB-predicted branch/JALR when the staged slot-2 BTB lookup hits. Native 32-bit
slot-2 branches at halfword PCs are supported when the BTB entry was trained
for that size. IF keeps canonical one-hot +2/+4 candidate identity for packet
validity and PC advance, while BPC receives an exact holdoff/flush cofactor of
those bits. BPC resolves a live slot-1 alias at this candidate boundary, before
the full slot-2 packet-valid gate, so late packet-shape and served-window logic
cannot feed backward into live BTB selection. Full slot-2 validity remains
required for a staged redirect and is restored before a live result can
transfer to an emitted slot. This ownership does not gate RAS operations: RAS
classification describes an older registered packet. Its call may push while
the younger slot-2 redirect proceeds, and its return takes priority over that
redirect so prediction and pop remain paired.

Because the older RAS operation commits on the edge that captures the younger
IF bundle, both younger slots carry its post-operation `{tos, valid_count}` as
their recovery entry state. A later recovery therefore retains an older call
and does not resurrect an older return. A globally blocked timing candidate
may still look owner-like, but it cannot clear the registered direction/index
snapshot; only an emitted slot 2 or an enabled one-wide pending-owner case can.

The one-cycle-ahead BTB stage matches instruction-memory latency and adds no
fetch cycle. It covers +2 at the staged base or successor word index and +4 at
the staged base index. Any other relationship is a BTB miss unless the first
live response after an unstalled fetch-invalid gap has collapsed the lookup
onto an emitted slot-2 PC. In that case a staged miss may transfer the live hit,
target, and direction metadata to slot 2. PC equality alone does not qualify
the transfer because it is ordinary one-request lookahead under fixed latency.
At fixed lead, only a taken live alias is candidate-owned by slot 2: an agreeing
staged image has already redirected, while a staged miss or disagreement
resolves normally without transferring the live verdict or creating a future
slot-1 owner. BTB target payloads remain 32 bits; target-valid rows restore
upper bits from their exactly matched branch/predecessor PC, and control flow
crossing a 4-GiB region remains a BTB miss.

A served-window retry for a high-half architectural target temporarily backs
the fetch lookup up to the containing word's low parcel. `pc_controller`
registers that exact resteer event, blocks the preceding parcel's BTB row, and
neutralizes its direction result through provider gaps and NOP holdoffs. A
conditional target therefore carries conservative not-taken direction
metadata paired with its own predict-time index. The existing +2 sequential
arm then reconverges fetch and `pc_reg` after the real target bundle emits,
without a live XLEN-wide same-word comparator or an added fetch cycle.

Slot-1 predictions that redirect fetch before `pc_reg` reaches the predicted
branch use a one-deep pending packet. Its saved metadata carries the exact
branch PC as well as the target. A slow served-window recovery may release the
immediately preceding instruction first; that packet carries no BTB metadata
and cannot consume the pending packet, while its direction bit and
predict-time index remain paired in the pre-arm snapshot. Its release advances
`pc_reg` to the pending owner atomically even during the registered prediction
holdoff; a later variable-latency served-window retry therefore cannot replay
the predecessor. If that retry rejects the release, its halfword-crossing
witness freezes with `pc_reg` so the owner cannot skip the still-owed packet.
An unblocked, non-buffer-stale exact owner already present in a covering window
on the first pending-active prediction-holdoff cycle consumes the registered
metadata and target handoff atomically; this avoids both an extra bubble and
dispatching the branch again on a later replay. A blocked first owner instead
saves that metadata. The saved prediction is replayed only when the live or
stall-replayed IF packet has the exact owner PC and the handoff is ready; that
owner PC also restores the bimodal predict-time index after intervening lookups
overwrite the normal one-cycle snapshot, so commit trains the original row.
The pending-owner bundle is strictly one-wide. If the predecessor bundle would
place the owner in slot 2, it stays withheld for the slot-1 handoff; once the
owner is in slot 1, the sequential sibling is killed as wrong-path even if
stale bytes make the owner look non-control. The same gate controls slot-2
packet validity, staged prediction eligibility, and PC advance.

PC-critical size, pairability, and slot-2-start timing replicas cross the fetch
seam in physical `{odd,even}` word order. Low BRAM exposes registered parity
lanes directly; `fetch_provider` converts the cached positional pair on the
payload-capture edge. IF can therefore select provider and `pc_reg` word parity
without a post-register bank-select mux.

Served-window acceptance is packet-shape aware. A lagging `S=P-1` response can
serve an unbuffered high-parcel RVC as a one-wide packet, but IF bubbles and
resteers high-parcel native and buffered packets because they require word
`P+1`; otherwise the parity aligner could use predecessor bytes for the native
spanning half or buffered slot 2. The provider-local coverage trees keep the
post-prediction buffer qualification on their final MUXF8 and consume a `B=0`
instruction-size cofactor on the earlier MUXF7. If the final buffer select is
low, that cofactor equals canonical PC-advance size; if it is high, size is
unobservable. This removes `prediction_holdoff` from the coverage size cone
without changing acceptance.

A no-lead prediction, whose branch packet has already emitted, never arms this
pending state, even for a halfword target. It uses its held registered target
handoff when fetch progress resumes.

## Directory contents

| Path                                | Status        | What it is |
|-------------------------------------|---------------|------------|
| [`cpu_ooo/`](cpu_ooo/)              | In use        | `cpu_ooo.sv` (top-level integration) and the OOO-core glue submodules extracted from the top level (see the table above). |
| [`tomasulo/`](tomasulo/README.md)   | In use        | The OOO back-end. The wrapper and the larger modules (store/load queues, ROB) nest their extracted glue/datapath submodules; see its README and the per-module READMEs for everything inside. |
| `if_stage/`, `pd_stage/`, `id_stage/` | In use      | Reused front-end stages, including BTB/direction/RAS prediction, PD BTB-miss redirects, and RVC handling. IF drives a stall-capable, variable-latency fetch seam (NOP bubbles plus a one-deep owed ask while unserved) so code can run from cached DDR as well as low BRAM. The low-BRAM source has a one-cycle `[0, 16 KiB)` metadata overlay and an exact one-repeat presenter above it; because that presenter has no PC-movement detector, IF explicitly retargets it when movement invalidates its owed request. When the cached tier is enabled, `fetch_provider` supplies a two-line L1I fetch buffer with predecode-on-fill for the cached region and detects ordinary unaccepted redirects from PC movement. Both providers take landed recovery, already-emitted-prediction, resteer, and trap/xRET/FENCE epoch retargets. A leading slot-1 prediction is excluded from those retargets so it cannot abandon the branch response still owed to `pc_reg`; slot 2 and no-lead slot 1 are included because their branch packet was already accepted. A valid response whose served window does not cover `pc_reg` is predictor-ineligible as well as squashed; fetch is then resteered to the owed word. `cpu_and_mem.sv`, one level up, selects the sources. The fetch PC is virtual: the instruction MMU (`mmu/immu`, instantiated in `if_stage`) resolves the registered selected VA into the window's two physical word addresses and fault flags. Bare/M-mode fetch is a combinational, no-bubble bypass. Sv39 exposes only a matching `{VA, privilege}`-tagged result, so each PC movement costs one translation bubble (possibly a second at a 4 KiB crossing) and an ITLB miss holds the front end longer. The seam carries the physical pair beside the virtual PC. |
| `mmu/`                              | In use        | Sv39 translation: `dtlb` (the generic fully-associative superpage-aware TLB, instantiated as the 16-entry DTLB and the 8-entry ITLB), `dmmu` (the data-side translation stage inside the wrapper), `immu` (the Bare bypass and tagged selected-VA fetch result in `if_stage`), and `ptw` (the read-only walker, Svade). |
| `wb_stage/`                         | In use        | Only the parameterized regfile is in the OOO build (instantiated twice for INT / FP). |
| `csr/`                              | In use        | Zicsr / Zicntr / fcsr. CSR ops are decoded in ID but read and write the CSR at commit through the ROB serializing FSM. The CSR file emits the registered TLB/PTW invalidate request, while the ROB independently owns conservative translation-class drain and pipeline recovery. |
| `control/trap_unit.sv`               | In use        | M/S/U exception/interrupt handling with delegation (traps taken in M or S) used by `cpu_ooo.sv`. |
| `ex_stage/`                         | In use        | `branch_jump_unit.sv` is instantiated inside `cpu_ooo/branch_recovery/branch_resolution.sv`. ALU/MUL/DIV/FPU are used via the FU shims in `tomasulo/fu_shims/`. |

`cpu_ooo.f` is the authoritative filelist for what gets compiled.
