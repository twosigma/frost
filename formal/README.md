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
| `divider_prefix` | Each 32/64-bit divider stage matches two restoring iterations, assuming the incoming remainder's prefix bound; valid transactions start with remainder zero, including division by zero |
| `mul_completion_tag` | MUL adapter behavior with qualified versus unqualified invalid tags; assumes one initial reset edge |
| `coherence_replay_compare` | Invalidation-line copies and replay masks at widths 32, 64, and 66; assumes one initial reset edge |
| `coherence_observation` | Unbounded observation-table ownership, line provenance, retirement/flush cleanup and registered replay timing for all 32 ROB tags at XLEN=64; producer timing contract below |
| `sc_head_query` | Selected SC coherence result versus a full line-address comparison, from arbitrary table state |
| `data_mem_response_mux` | RAM/MMIO/cached payload selection at 32/64 bits, for portable and Xilinx implementations; Xilinx tasks use Yosys's LUT5 model |
| `immu_bare` | Bare-mode physical addresses and verdicts; 32/72-bit variants check width conversion only, not Sv39 at those widths |
| `c_ext_state_cofactor` | Buffer-valid next state from arbitrary inputs and state; producer relationships are checked by `prediction_release` |
| `branch_prediction_disable` | Prediction permissions and live/staged target selection against the original equations, with arbitrary predictor outputs |
| `fetch_redirect` | Redirect priority and registered waveform, with arbitrary controls and initial state |
| `fetch_pc_mux`, `pc_register_mux` | Fetch and architectural-PC priority, including generic and integrated handoff configurations, from arbitrary controls and state |
| `pc_holdoff_cofactor` | Fetch holdoff equations from arbitrary controls and state; temporal integration is covered separately |
| `pc_holdoff_tag` | Prediction holdoffs at widths 32, 64, and 72, including wraparound; assumes initial pending-valid=0, not arbitrary corrupt valid state |
| `branch_prediction_alias` | Public alias outputs under IF's base+2/base+4 wiring; requires the width-equality opt-in guard and does not prove full-controller sequential equivalence |
| `rob_start_cofactor` | ROB head ownership and CSR/xRET starts; assumes initial reset and abstracts payload RAMs and serializer outputs |
| `load_queue_amo_compute` | Four-step AMO operand capture, arithmetic, kill/reset, coherence exclusion, and write stability; no reset/admission assumptions and no scheduler, interrupt, or liveness claim |
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
