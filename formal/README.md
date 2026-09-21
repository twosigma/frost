# Formal Verification

The formal targets check properties over all possible inputs within a bounded
window. The targets that define a `prove` task also carry unbounded safety
proofs.

## Tools

| Tool | Purpose |
|------|---------|
| SymbiYosys (sby) | Runs Yosys and the solvers as each `.sby` file directs |
| Yosys | Reads the RTL and prepares it for the solver encoding (SMT2 or BTOR) |
| Boolector / Z3 | SMT solvers behind the `smtbmc` engine; each `.sby` picks one |
| btormc | BTOR model checker behind the `btor` engine; faster on some targets, such as ROB BMC |

## How It Works

Block-local assertions live in `ifdef FORMAL` blocks inside the RTL module
they check. Integration targets add a formal-only harness under `formal/`,
plus a conservative helper abstraction where one is needed. The harness
instantiates the production modules and may carry properties of its own, but
the module-level properties stay in the production RTL. Yosys defines `FORMAL`
per file, only for sources read with `read -formal`. A plain `read` defines
`SYNTHESIS` instead, and no simulation or synthesis flow defines `FORMAL`, so
the blocks compile away everywhere else. Each `.sby` script chooses which
production modules, harnesses, and helpers are read with `-formal`.

Each `.sby` defines some of these tasks:

- `bmc` checks every `assert` for N cycles across all input combinations.
- `cover` finds a trace that reaches each `cover` property.
- `prove` is an unbounded safety proof. `prediction_release`,
  `prediction_handoff`, and `prediction_metadata_tracker` run ABC PDR;
  other targets use their configured temporal-induction engine.

Parameter-shape variants (`bmc_itlb`, `cover_itlb`, `fmul_repair_bmc`) rerun a
task on a `chparam`'d top. `--list-targets` shows which tasks each target
declares.

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

```bash
# List all targets and their supported tasks
./scripts/frost.py formal --list-targets

# See CLI help (includes --target choices)
./scripts/frost.py formal --help
```

## Running

Run formal workflows from the repository root through `./scripts/frost.py`.
The wrapper uses the pinned `frost` image and leaves output directories
writable by your host user.

```bash
# Run all formal targets
./scripts/frost.py formal

# Discover and select targets/tasks
./scripts/frost.py formal --list-targets
./scripts/frost.py formal --target trap_unit
./scripts/frost.py formal --target prediction_release
./scripts/frost.py formal --target prediction_release --task prove
./scripts/frost.py formal --task bmc
./scripts/frost.py formal --verbose

# Direct SymbiYosys invocation
./scripts/frost.py run bash -c 'cd formal && sby -f trap_unit.sby bmc'
./scripts/frost.py run bash -c 'cd formal && sby -f trap_unit.sby cover'
./scripts/frost.py run bash -c 'cd formal && sby -f reorder_buffer.sby bmc'
```

## Property Style

Properties state falsifiable contracts rather than restating the RTL. Most
relate inputs to outputs, either in the same cycle or across clock edges with
`$past()`. `assume` statements rule out input combinations the pipeline cannot
produce, such as `!(trap && mret)`. Wiring guards check that each output port
carries the internal signal it should, which catches cut-and-paste errors.

## Adding Properties to an Existing Module

Add an `ifdef FORMAL` block at the end of the module (before `endmodule`):

```systemverilog
`ifdef FORMAL
  // Assume reset at startup
  initial assume (i_rst);

  // Track $past validity
  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  always @(posedge i_clk) begin
    if (!i_rst) begin
      // Combinational properties (use boolean implication: !a || b)
      my_property: assert (!(signal_a && signal_b));
    end

    // Sequential properties (require f_past_valid)
    if (f_past_valid && !i_rst && $past(!i_rst)) begin
      if ($past(some_condition)) begin
        my_seq_property: assert (!some_signal);
      end
    end
  end

  // Cover properties (prove reachability)
  always @(posedge i_clk) begin
    if (!i_rst) begin
      cover_interesting_case: cover (interesting_condition);
    end
  end
`endif
```

## Adding a New Formal Target

1. Add `ifdef FORMAL` assertions to the RTL module, or create a formal-only
   integration harness when the property spans production modules.
2. Create an `.sby` file in `formal/` (see `trap_unit.sby` for a block-local
   target or `prediction_release.sby` for an integration proof). Read every
   source whose properties must be active with `read -formal -sv`. A plain
   `read -sv` compiles its assertions out, and a proof can then pass
   vacuously.
3. Add a `FormalTarget` entry in `tests/test_run_formal.py`, listing `prove` in
   `tasks` when the `.sby` defines it:

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
- Use `initial assume(i_rst)` so registers start in a known state.

## File organization

```
formal/
├── README.md                               # This file
├── .gitignore                              # Ignores sby working directories
├── *.sby                                   # Formal target configurations
├── prediction_metadata_tracker_formal.sv   # Formal-only harness
├── prediction_release_formal.sv            # Formal-only integration harness
└── prediction_release_pc_increment.sv      # Conservative helper abstraction
```

Formal-only harness and abstraction files live beside their `.sby` target and
are not part of production synthesis.
