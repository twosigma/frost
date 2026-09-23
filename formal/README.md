# Formal Verification

Run through the pinned Docker image:

```bash
./scripts/frost.py formal --list-targets
./scripts/frost.py formal --target trap_unit
./scripts/frost.py formal --target prediction_release --task prove
./scripts/frost.py formal
```

Each `.sby` selects its engines, parameters, and assumptions. `bmc` checks
assertions to a bounded depth, `cover` finds reachable witnesses, and `prove`
establishes unbounded safety under the stated assumptions. Width/parameter
variants are separate tasks. `--task` filters declared tasks; `--verbose`
shows solver output.

## Targets

Use `--list-targets` for the full list and supported tasks. The registry is
`FORMAL_TARGETS` in `tests/test_run_formal.py`; each `.sby` file defines its
parameters, assumptions, engines, and proof depth.

The focused targets below check local equivalence or integration contracts.
A local combinational check does not establish whole-CPU behavior, timing,
or liveness. These proofs use binary values; they do not cover simulation
X/Z behavior.

| Target | Scope and limits |
| --- | --- |
| `btb_tag_compare` | Full-width tag equality at 55 and 59 bits, with arbitrary RAM outputs |
| `fp_fma_align` | Single/double-precision alignment shift amounts match max-exponent subtraction for arbitrary extended exponents; no arithmetic-input or reset assumptions |
| `divider_prefix` | Each 32/64-bit divider stage matches two restoring iterations, assuming the incoming remainder's prefix bound; valid transactions start with remainder zero, including division by zero |
| `mul_completion_tag` | MUL adapter behavior with qualified versus unqualified invalid tags; assumes one initial reset edge |
| `int_muldiv_shim` | Shared full/word completion ownership and credits, plus separate physical-pipeline alignment proofs, with short word paths enabled and disabled; assumes one initial reset followed by deasserted reset. Arithmetic values and liveness are outside these tasks |
| `mem_wakeup_merge` | Exhaustive combinational preservation and idle-lane injection. Standalone, assumes the staged load never carries a valid registered lane's tag; integrated (`FORMAL_STANDALONE_ENV=0`) that contract is asserted. Accepted-load eligibility and eventual CDB delivery require wrapper integration checks |
| `coherence_replay_compare` | Invalidation-line copies and replay masks at widths 32, 64, and 66; assumes one initial reset edge |
| `coherence_observation` | Unbounded observation-table ownership, line provenance, retirement/flush cleanup and registered replay timing for all 32 ROB tags at XLEN=64; producer timing contract below |
| `sc_head_query` | Selected SC coherence result versus a full line-address comparison, from arbitrary table state |
| `data_mem_response_mux` | RAM/MMIO/cached payload selection at 32/64 bits, for portable and Xilinx implementations; Xilinx tasks use Yosys's LUT5 model |
| `rvc_predecode` | All 65,536 parcel encodings: the stored RV64C expansion and illegal flag equal the runtime decompressor |
| `dispatch_admission` | Legacy and queued admission equations with arbitrary inputs; the queued task assumes the producer's slot-valid contract |
| `c_ext_buffer_next` | Slot-2 buffer next-state outcomes match original clear/capture/hold priority for arbitrary inputs/state |
| `sq_repair_mmio` | Both parallel repair MMIO flags match classification of the original full-width selected-base-plus-immediate sums, including simultaneous/no matches and overflow |
| `dmmu_mmio` | Parallel MMIO classification and the complete S2 MMIO next bit equal original resolution/hold for arbitrary state, with no assumptions |
| `rs_alloc_parallel` | Parallel first/second free indices and found flags equal the original serial search at depths 4/8/16/32, including zero/one free entry; arbitrary occupancy without assumptions |
| `rs_pretag_cofactor` | Four CDB-valid cofactor winners equal the original priority-selected ROB tag, including idle; arbitrary binary inputs/current state with MEM and src3/tag-shadow/meta-anchor configurations, no sequential assumptions |
| `ras_checkpoint` | Return-stack next pointer and count versus the original equations, from arbitrary controls and state |
| `low_bram_presenter_tier` | Low-BRAM response validity, overlay/history and address provenance with separate low-address retargeting; BMC and unbounded ABC-PDR proof, two initial reset edges to drain arbitrary memory history, then arbitrary resets and fetch controls. The high provider must own and mask low responses while PA0[31] is set |
| `instr_operand_classifier` | Exhaustive equivalence to the former ID operation-enum classification for arbitrary instruction bits, injected NOPs, illegal flags and fetch faults; the original instruction decoder supplies legality |
| `immu_page_offset` | Unbounded translated page-offset preservation and visible-PA equality; assumes one reset edge and abstracts ITLB outputs as arbitrary inputs |
| `immu_bare` | Bare-mode physical addresses and verdicts; 32/72-bit variants check width conversion only, not Sv39 at those widths |
| `c_ext_state_cofactor` | Buffer-valid next state from arbitrary inputs and state; producer relationships are checked by `prediction_release` |
| `branch_prediction_disable` | Prediction permissions and live/staged target selection against the original equations, with arbitrary predictor outputs |
| `fetch_redirect` | Redirect priority and registered waveform, with arbitrary controls and initial state |
| `fetch_pc_mux`, `pc_register_mux` | Fetch and architectural-PC priority, including generic and integrated handoff configurations and portable/Xilinx primitive muxes, from arbitrary controls and state |
| `pc_holdoff_cofactor` | Fetch holdoff equations from arbitrary controls and state; temporal integration is covered separately |
| `pc_holdoff_tag` | Prediction holdoffs at widths 32, 64, and 72, including wraparound; assumes initial pending-valid=0, not arbitrary corrupt valid state |
| `branch_prediction_alias` | Public alias outputs under IF's base+2/base+4 wiring; requires the width-equality opt-in guard and does not prove full-controller sequential equivalence |
| `rob_control_next` | Done, exception and replay next states match the original indexed writes for arbitrary current state and inputs, including reset, simultaneous allocation/completion and stale tags; RAM/serializer outputs are unconstrained, no assumptions |
| `rob_retire_stall` | Retirement strobes and the full performance-event vector equal canonical serializer behavior; actual serializer wiring, arbitrary current state/controls, no assumptions |
| `rs_dispatch_defer` | All six dispatch-source deferred-CDB decisions match the original ready-qualified equations, with insertion-time repair enabled and disabled; no assumptions |
| `rs_issue_clear` | Accepted port-2 clear mask equals the former indexed clear; dual issue disabled, depths 4/32, and actual INT parameters at depth 8 and depth 16/window 8, with free RAM outputs and no assumptions |
| `sq_committed_empty` | Committed-empty next state matches the original reset/flush/registered-and-combinational-commit equation for arbitrary inputs and current bits, no assumptions |
| `sq_live_count` | Allocation increments before late removal subtraction equal the original three candidates and exact next count; arbitrary state and controls, no assumptions |
| `pc_pending_capture` | Pending prediction valid matches the original clear/set/hold transition for arbitrary current state, redirects, stalls and bundle-size comparison; no assumptions or initial state |
| `control_flow_holdoff` | Redirect and reset holdoffs match the original next-state equations for arbitrary state and simultaneous prediction/redirect/stall inputs, no assumptions |
| `rob_start_cofactor` | ROB head ownership and CSR/xRET starts; assumes initial reset and abstracts payload RAMs and serializer outputs |
| `load_queue_amo_compute` | Four-step AMO operand and memory-tier capture, arithmetic, kill/reset, coherence exclusion, and write stability; no reset/admission assumptions and no scheduler, interrupt, or liveness claim |
| `load_queue` (`prove_pre_match`) | Unbounded equivalence of the split pre-issue tag/valid registers against the original predicate, without environment assumptions; the separate queue BMC/cover tasks retain their existing scope |
| `lq_prematch_cofactors` | Bounded and unbounded equivalence of registering four or eight candidate CAM results and their selector versus registering the selected-tag CAM; arbitrary inputs/current state, resets and full flushes, no assumptions. Integration checks that the scalar tag equals the selected candidate |
| `if_direction_payload` | Direction payload and stall replay equivalence for non-NOP packets with arbitrary controls/owner matches; assumes one initial flush to initialize saved-NOP state and uses the real stall-capture module |
| `mispredict_capture` | Bounded and unbounded equivalence of the recovery payload while its registered valid is set; arbitrary inputs/reset/flush, no assumptions |
| `line_arbiter_grant` | Generic and Xilinx three-port grants equal the encoded starvation-priority rule for arbitrary request/counter state |
| `lq_alloc_mask` | Parallel cyclic first/second allocation masks equal the original binary target plus capacity checks at depths 4/8/16; arbitrary occupancy, cursor, and flush inputs without assumptions |
| `lq_capacity` | Grouped free-entry predicates equal full/popcount comparisons for arbitrary valid masks |
| `lq_cached_flags` | Invalidation and LR-suppression next state equals the original priority equations; arbitrary inputs/current state |
| `lq_cached_hold` | Cached-slot hold next state versus the original full slot-mask reduction; arbitrary inputs/current state |
| `prediction_metadata_output` | Prediction validity routing versus the original equations, plus saved/active non-owner exclusion; arbitrary controls/current state, with lifecycle behavior checked by `prediction_metadata_tracker` |
| `lq_tag_order` | Exhaustive unsigned tag-age ordering and full-window boundary equivalence to the former extended arithmetic; arbitrary tags, no reset or live-entry assumptions |
| `lq_l0_cache` | Bounded hit, fill and invalidation checks at 128 and 256 entries; this local cache target does not prove coherence of executed loads through retirement |
| `alu_shift_hint` | Hint-enabled and default RV64 ALUs agree when the hint supplies the exact effective shift amount; checked against an independent shift/rotate reference. `rs_issue2_shamt` simulation covers capture and hold |

Integration targets have narrower environment contracts:

- `coherence_observation` tracks an arbitrary ROB tag from external observation
  history through the pending register and validation table. It assumes an
  initial reset edge and that neither commit lane retires a tag observed in
  the current or preceding cycle. The LQ observes before completion/CDB/ROB
  retirement, but this isolated proof does not establish that producer timing.
  Later resets, flushes, head tags and DMA controls are unrestricted; repeated
  observations may even use different lines. Covers exercise both commit
  lanes, full/partial flush, circular tag order, persistence, tag reuse with a
  changed line, and replay from both the pending register and table. A replay
  mask can name an observation cleared at the comparison edge because the
  output is registered. ROB acceptance and allocation timing must keep such
  a mask from affecting a new owner; that integration, DMA progress and atomic
  exclusion are outside this target. `prove_unrestricted` removes the producer
  assumption, retaining only the initial reset, and proves flush cleanup,
  commit cleanup when no observation overlaps, and the pending write's
  priority over a colliding commit.
- `prediction_release` checks the production buffer and PC controllers with
  a conservative PC-increment abstraction. It proves safe pending-target
  handoff and metadata masking under the production producer relationships,
  including repeated resets and stalled redirects. `prediction_handoff`
  checks the optimized handoff under the same contract. Both provide `bmc`,
  `cover`, and ABC-PDR `prove` tasks.
- `prediction_metadata_tracker` proves validity and payload provenance with
  a modeled registered predictor target and arbitrary pending/output PCs.
- `reservation_station` checks the default configuration at BMC depth 12
  and the complete shipped INT configuration with `bmc_tag_indexed` at
  depth 7. Both have depth-20 cover tasks. The INT variant enables properties
  that are inactive at default parameters and assumes ROB-tag ownership.
- `tomasulo_wrapper` checks station ownership against the real allocator.
  Its environment assumes dispatch accompanies allocation, uses that cycle's
  allocated tag, and flushes only to a live ROB entry. Depth 4 does not reach
  tag wraparound; simulation covers reuse after wrap. Station assertions
  remain enabled, with standalone station assumptions disabled.

## Property Style

State input/output, ordering, or temporal contracts that can fail. Guard
`$past()` with a past-valid bit and the relevant reset conditions. Assumptions
must describe inputs the real environment guarantees, and be recorded with
the proof scope. Keep block assertions under `ifdef FORMAL` in their module;
formal-only integration harnesses live beside `.sby` files and stay outside
production synthesis.

## Adding a New Formal Target

1. Add `ifdef FORMAL` assertions to the RTL module, or create a formal-only
   integration harness when the property spans production modules.
2. Create an `.sby` file in `formal/` (see `trap_unit.sby` for a block-local
   target or `prediction_release.sby` for an integration proof). Read every
   source whose properties must be active with `read -formal -sv`. A plain
   `read -sv` compiles its assertions out, and a proof can then pass
   vacuously.
3. Add a `FormalTarget` entry in `tests/test_run_formal.py`, listing `prove` in
   `tasks` when the `.sby` defines it. Register any new task names in
   `SBY_TASKS` so CLI and pytest runs include them:

```python
FORMAL_TARGETS = [
    FormalTarget("trap_unit.sby", "Trap unit"),
    FormalTarget("new_module.sby", "Description of new module"),  # bmc + cover only
    FormalTarget("new_proof.sby", "Unbounded proof", tasks=("bmc", "cover", "prove")),
]
```

## Yosys SVA Limitations

Yosys supports a subset of SystemVerilog Assertions:

- Use immediate assertions inside `always @(posedge clk)` blocks.
- Use `!a || b` for implication. The concurrent form `a |-> b` is not
  available.
- Use `$past(signal)` for sequential properties.
- No hierarchical references (`u_sub.signal`): assertions must sit inside the
  module they check.
- Assume initial reset only when it is part of the target contract; otherwise
  prove the property from arbitrary state.

`decoded_bundle_queue` proves FIFO ordering and arbitrary payload preservation
at depths four and two (`prove`, `prove_depth2`) and covers bypass, full,
wraparound, simultaneous push/pop and live flush (`cover`). Its eight-bit
symbolic payload checks the control independently of decode fields. The proof
also covers the registered head mirror and the three-bit registered shadow,
tied to the payload's low bits, which must equal the output packet's slice.
It assumes an initial reset, legal consumer pops, no producer overwrite before
acceptance, and that the producer's announced next value (`i_shadow_next`)
arrives; integration assertions enforce the last three contracts in simulation.
This is not a proof of whole-core CSR/debug/branch behavior.
`load_queue` also has `bmc_prepare_busy`/`cover_prepare_busy` tasks for inert
candidate preparation while another client owns the memory port.

`cache_mshr_payload` compares per-entry data and strobe next states against the
original indexed fill/store merge for arbitrary inputs and current state,
including simultaneous fills and W-stage operations, without assumptions.

`fetch_pc_mux` checks both the portable final mux and the actual Xilinx LUT6
model in standalone and integrated configurations against the original serial
priority and one-hot arm expressions.

`lq_response_bypass` proves the actual load-response bypass pulse equals the
original full-acceptance-qualified pulse for arbitrary inputs and queue state.
The independent partial-flush guard makes its age comparison redundant.

`lq_ram_payload` checks the actual two RAM ports against the former qualified
mux: write enables always match, and address/data match whenever enabled.
Default, forwarding-enabled and forwarding-only configurations use arbitrary
inputs and state, with no assumptions.

`fp_payload_read` proves both FPU producer RAM prefetch addresses equal the
original pointer-plus-pop expressions for arbitrary inputs and FIFO state,
including pointer wraparound, without assumptions.

`rs_raw_pretag` uses the real early-wakeup merger and proves that the selected
eight-way raw candidate equals the original MEM_RS winner for arbitrary inputs
and state. `lq_prematch_cofactors` covers both selector widths with bounded and
unbounded equivalence against direct selected-tag matching.

The RAM-payload check abstracts RAM/cache outputs as arbitrary inputs and rejects
all initial-state constraints. Four covers reach response, cache, forward and
AMO writes; a separate assertion excludes the AMO-head exception on cache hits.

`pc_increment_holdoff` compares both sequential fetch addresses with the former
per-size holdoff/correction candidates and run/NOP selection. The portable and
Xilinx configurations leave all current inputs independent, with no assumptions.

`csr_commit_cofactor` compares the modified CSR storage and both counters with
old-transition ghost captures from arbitrary actual state, after one edge.
Generic behavior is checked for all inputs; integrated behavior is checked
under the existing CSR-commit/control-take exclusion, expressed as a property
premise rather than an environment assumption. Translation invalidation is
also compared combinationally. Only the ghost-valid bit is initialized.

The `load_queue_amo_compute` harness counts its named AMO assertions and cover
separately from allocator checks. Other production helper checks remain enabled,
but their addition does not invalidate the AMO harness's structural guard.
