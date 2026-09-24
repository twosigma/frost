# FROST CPU

`cpu_ooo.sv` pairs a two-wide in-order front-end (IF/PD/ID, BTB, direction
predictor, RAS, RVC) with the [`tomasulo/`](tomasulo/README.md) out-of-order
back-end. Shared functional units under `ex_stage/` connect through OOO shims.

See the shared [CPU and system architecture diagram](../../../../docs/diagrams/frost-architecture.svg)
for the front-end, Sv39 translation, memory interfaces and in-order commit.
The [Tomasulo back-end diagram](../../../../docs/diagrams/tomasulo-backend.svg)
expands register renaming, independent execution paths, result broadcast and
load/store ordering.

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
| `frontend_validity_tracker` | `frontend_control/` | Tracks IF/PD validity, NOP bubbles, and unpredicted control flow. Supplies prediction-fence and serialization hints; dispatch applies the architectural recovery gate. |
| `commit_actions` | `commit/` | Writes INT/FP architectural registers at commit and handles CSR writeback, retirement, and instruction counts. |
| `data_mem_request_router` | `memory_if/` | Arbitrates SQ writes > AMO writes > LQ reads. Device reads are staged and wait for committed stores and interrupt protection; cached requests use tagged completion. A cached store blocks queued reads until its completion. See the [data-tier contract](../../README.md#data-tier-bus-contract). |
| `cached_tier_adapter` | `memory_if/` | Converts CPU beats to 32-byte cache lines, with one tagged read per LQ slot and one store in flight. Queues cached responses behind fast-tier beats. Instantiated beside the cache hierarchy in `cpu_and_mem.sv`. |
| `ex_comb_synthesizer` | `recovery/` | Builds redirects, BTB updates, and RAS restore signals for IF, plus the lower-priority BTB training candidate. |
| `perf_counter_aggregator` | `perf/` | Counts, snapshots, and selects 42 top-level, 24 cache, and 64 wrapper counters when `PERF_COUNTERS=1`. See the [counter reference](cpu_ooo/perf/README.md). |
| `branch_resolution` | `branch_recovery/` | Resolves branch/JAL/JALR packets from INT_RS, validates checkpoint ownership, and updates the ROB. Direct branches use ID's precomputed target comparison; JALR compares its computed target. |
| `early_misprediction_recovery` | `branch_recovery/` | Redirects fetch and restores the RAT for checkpointed conditional-branch mispredictions before commit. |
| `misprediction_flush_controller` | `branch_recovery/` | Handles commit-time mispredictions, full and partial flush priority, and checkpoint restore/free operations. |
| `ooo_pipeline_control` | `pipeline_control/` | Controls front-end stalls, serialization, CSR/branch in-flight state, post-flush holds, trap/MRET redirects, and prediction disable. |
| `decoded_bundle_queue` | `frontend_control/` | Four-bundle fall-through queue between ID and dispatch; preserves held-image ownership, bundle order, prediction metadata and flushes. |

The branch-recovery, commit, and `from_ex_comb` submodules share two capture
structs, `mispredict_commit_capture_t` and `correct_branch_commit_capture_t`,
which live in `riscv_pkg`. A separate `cpu_ooo_pkg` was not viable because
yosys's `read_verilog -sv` cannot resolve cross-package type references inside
another package's typedef.

## What remains inline in cpu_ooo.sv

Inline logic is limited to the ROB-head CSR bypass, RAT/checkpoint gating around
`tomasulo_wrapper`, CSR/trap commit glue, the reset-done counter, the Debug-Mode
single-step engine, and the `dbg_*` mirror taps kept at this hierarchy for cocotb.

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
recovery selects only the final 2-bit write value. The prioritized transaction owns BTB address, tag, target, metadata,
replacement, and counter writes. The update transaction is registered at the prediction
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
post-prediction buffer qualification on their final MUXF8 and consume a
factored no-buffer served-last verdict on the earlier MUXF7. PC-low accepts the
served last word unconditionally; PC-high accepts it only for a compressed
high parcel. If the final buffer select is high, that earlier verdict is
unobservable. This keeps `prediction_holdoff` out of the coverage-size cone.

A no-lead prediction, whose branch packet has already emitted, never arms this
pending state, even for a halfword target. It uses its held registered target
handoff when fetch progress resumes.

## Fetch and translation

`cpu_and_mem` selects low BRAM or `fetch_provider`. IF supports variable latency
with NOP bubbles and a one-deep owed request. Low BRAM's `[0, 64 KiB)` predecode
overlay is one cycle; later windows repeat once. IF explicitly retargets owed
BRAM requests when PC movement invalidates them. The cached provider uses two
active and six victim lines, predecodes on fill, and detects unaccepted redirects.

Each fetched word carries 78 metadata bits: twelve fetch-control predicates
and two complete RVC expansions with illegal flags. The expansion's source
fields retain separate lanes for the early operand lookups. The aligner
selects metadata with its parcel, including buffered and bank-swapped words;
IF preserves the selected metadata through a held response. Low-BRAM init,
programming writes and L1I fills generate the same metadata. The RV64C
predecoder is checked against the runtime decompressor for every parcel.

In the cached configuration, a transition to the high provider need not
retarget the low BRAM's address bits [15:0]. Response ownership masks that
read. The upper physical-address bits still follow the canonical request,
preventing false overlay hits and stale history matches on an immediate
return to low BRAM. PC, fault and publication controls keep the full retarget.

Both providers take recovery, emitted-prediction, resteer, and trap/xRET/fence
epoch retargets. A leading slot-1 prediction is excluded while its branch
response is still owed; slot 2 and no-lead slot 1 have already been accepted.
A non-covering response is squashed and predictor-ineligible, then fetch is
resteered to the owed word.

`if_stage` uses `mmu/immu` to translate the virtual PC into two physical
word addresses and fault flags. Bare/M-mode bypass is combinational. Sv39
exposes only matching `{VA, privilege}` results; PC movement costs one
translation bubble, potentially two at a page crossing, plus any ITLB miss.
The shared read-only PTW supports Svade: software handles A/D-bit faults.

## Directory contents

| Path | Purpose |
|------|---------|
| `cpu_ooo/` | Core integration, commit, recovery, memory routing, profiling |
| [tomasulo/](tomasulo/README.md) | Rename, scheduling, queues, execution adapters, retirement |
| `if_stage/`, `pd_stage/`, `id_stage/` | Prediction, alignment, predecoded RVC expansions, and dual decode. Operand classification runs beside the operation decoder, with legality and injected-NOP/fetch-fault selection applied afterward |
| `mmu/` | 8-entry ITLB, 16-entry DTLB, translation stages, shared PTW |
| `wb_stage/` | Generic INT/FP architectural register files |
| `csr/` | Privileged and FP CSRs; accesses execute at commit |
| `control/trap_unit.sv` | M/S/U traps, delegation, debug entry |
| `ex_stage/` | ALU, multiply/divide, FPU, branch execution |

`cpu_ooo/cpu_ooo.f` is the authoritative CPU source list.

## Timing-sensitive control paths

The fetch-PC mux computes prediction, sequential and non-sequential data
separately. Served-window and progress guards qualify the final requests.
On Xilinx, a LUT6 per bit completes the redirect/resteer/hold word, a LUT4
applies qualified slot 1, and a final LUT6 selects reset, slot 2, sequential
data or that word. Sequential requests override the private non-sequential
word when pending consume/hold arms advance. The architectural-PC mux uses
a LUT5 for staged prediction versus sequential/base data and a final LUT6 for
reset, redirect permission and live prediction. `fetch_pc_mux` and
`pc_register_mux` check the corresponding portable and Xilinx implementations.
The fetch proof also checks the wraparound-safe carry relation used for
`fetch_pc == instruction_pc + 2`.

Fetch increment selection applies redirect/reset holdoff after computing the
run/NOP size candidates. Holdoff logic resolves non-prediction terms before
slot-1/slot-2 flags; pending holdoffs resolve owner readiness and crossing
permission before combining packet-position relations. Pending-prediction
validity and compressed-buffer validity compute both outcomes before their
late selectors. Pending validity gives clear priority over capture; compressed
buffer validity gives pending-target handoff priority over preservation.
`pc_increment_holdoff`, `control_flow_holdoff`, `pc_pending_capture` and
`c_ext_buffer_next` check these transitions against their reference equations.

Both BTB slots split raw and forwarded tag equality into 14-bit partial
comparisons. Pending-predecessor direction selects by packet identity before
NOP qualification; PD vetoes NOP redirects, and stall replay excludes saved
NOP packets.
`if_direction_payload` and an IF integration oracle check that contract.
Prediction ownership assertions sample at the packet-capture edge, after
combinational controls settle. `prediction_metadata_output` checks non-owner
exclusions; the tracker proof checks ownership across pending episodes.

DMMU MMIO classification runs in parallel for TLB and walker candidates, then
follows address-resolution priority. The MMIO quadrant passes the low-32-bit
PMA range check; permissions and nonzero high PPN bits can suppress the flag.
S2 computes both TLB-MMIO outcomes, including hold, before the permission/tier
result selects the next bit. `dmmu_mmio` checks classification and S2 capture.

Commit-time misprediction payload registers refresh every cycle. Recovery,
checkpoint and BTB consumers use them only while the separately qualified
recovery-pending bit is set; `mispredict_capture` checks the valid payload.

`cpu_ooo` enables `csr_file.COMMIT_EXCLUDES_CONTROL_TAKE`: a serialized CSR
commit cannot coincide with a trap, MRET, SRET or DRET take. CPU and CSR
assertions check that boundary. Integrated CSR write guards omit trap
qualification, and translation invalidation compares the completed write
before commit enable. Generic instances retain trap priority.
`csr_commit_cofactor` checks affected state and invalidation after each legal
edge.

FPU multiplier/FMA payload FIFOs precompute incremented read pointers before
the acceptance/flush decision. `fp_payload_read` checks the post-pop prefetch
addresses for arbitrary FIFO state, including pointer wraparound.
