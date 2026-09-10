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

The target list is not duplicated here. Its sources of truth are
`FORMAL_TARGETS` in `tests/test_run_formal.py` and the `.sby` files.

The `immu_bare` target checks the production IMMU's public Bare outputs against
the original package verdict and physical-address equations. Its one-step BMC
leaves every PC bit arbitrary, including page crossings and address wrap. Local
XLEN 32 and 72 variants check the original package-input extension/truncation
contract; they make no claim about Sv39 support at those widths. The script
prunes unobserved translation state and asserts that no memory or sequential
cells remain in the observed cone.

The `c_ext_state_cofactor` target exhaustively checks the buffer-valid
next-state equation against its original priority logic in one step, with
arbitrary inputs and register state. `C_EXT_STATE_LOCAL_PROOF` excludes only
the separate integration assertions that require legal producer relationships;
`prediction_release` continues to prove those relationships and invariants.

The `prediction_release` target integrates the production `c_ext_state` and
`pc_controller` state machines with a formal-only harness and a conservative
abstraction of `pc_increment_calculator`. It proves that an atomic pending
target handoff cannot leave stale old-path buffer state selectable, and that
pending-state consumers are masked outside a live episode. Its covers reach
both raw-capture cofactors, which keeps the clear-dominance proof from passing
vacuously. It runs `bmc`, `cover`, and an ABC-PDR `prove` task.

The `prediction_handoff` variant enables the integrated IF optimization that
removes the redundant slot-2 veto from pending-target consumption. It restores
the production WCS=0 pending-holdoff mask in the abstract predictor requests.
For WCS=1 it uses the pending-holdoff cofactor, conservatively admitting extra
requests compared with IF's unconditional prediction disable. It proves the
optimized handoff still matches the generic priority equation.
The `branch_prediction_disable` one-step proof separately checks the actual
prediction controller with arbitrary leaf predictor outputs: its selected
disable cofactor blocks both staged and live-fallback slot-2 predictions. It
also compares all four completed slot-2 candidate cofactors and their final
prediction-common, full-validity, RAS, branch, and spanning permission gate
against the original selection equations, including the public live-target
cofactor.
Together these checks establish the structural contract used by IF's opt-in.
The same proof checks the canonical slot-1 PC-use and owner-free live-metadata
candidate cores against their original equations, including all final common,
branch, spanning, and stall gates. Separate unconditional assertions expand
all seven original common guards and both raw-WCS disable inputs, comparing
the actual common cofactors and selected common permission directly. This
checks the kept common precondition core without reusing it in the oracle.
The completed slot-2 permission excludes the late full-validity input; the
original equations still check every permission guard and the final validity
qualification for all four slot-2 outputs.

The `fetch_redirect` target checks the production registered low-provider
redirect helper against the original full NPC selector/reduction expression.
Every non-reset arm condition, sequence flag, load enable, and slot-1 emission
flag is arbitrary, including simultaneous requests and no winning arm. Reset
is the original highest-priority arm and synchronous output clear. The proof
checks both the combinational next value and the original registered waveform
without assumptions on inputs or initial output state; covers exercise slot-2
priority, the leading-slot-1 exception, and a higher-priority redirect. IF also
retains a clocked integration oracle against the actual PC controller's
original selector bus. Three completed scalar cases isolate late prediction
permission without adding a cycle.

The `fetch_pc_mux` one-step proof compares the actual fetch-PC datum with
both the original one-hot reduction and the older serial priority equation,
including the raw-WCS predecessor exception. All external inputs and register
state remain arbitrary, with no reset or captured-tag assumptions. Default
and integrated handoff-parameter tasks both preserve redirects, served-window
recovery, and fetch-progress hold above slot 2, then slot 1, then the completed
prediction-free base. The kept base substitutes `o_pc` for sequential data and
excludes catch-up. The completed non-sequential no-slot-2 datum includes slot 1
and the served-window resteer, which remains below architectural redirects;
raw WCS keeps its separate original effects. An exact ordinary-sequential
request covers winning consume, raw-WCS override and default arms, with
served-window suppression. Both ordinary and catch-up request cores exclude
slot 1; its common veto qualifies their combined request. The separately
completed catch-up permission excludes late NOP and served-window controls,
which qualify its request. When the combined request is true, slot 1 is
absent, so the catch-up core can select `seq_next_pc_plus_2` over ordinary
`seq_next_pc` independently of the late slot-1 veto. This completed sequential
target is kept and reset-free; the combined request remains unpreserved.
Three kept scalar winners encode the original priority of canonical slot 2,
then combined sequential data, then completed non-sequential data. Canonical
slot 2 retains its original redirect, window and progress permission. Reset
clears all three winners, and a three-term masked OR produces the actual
fetch datum. The masks are disjoint for arbitrary controls, and reset never
enters a kept data word.
The calculator preserves its existing run/NOP fetch data cofactors so NOP
selects completed data. These calculator attributes change no equation or
interface; the local mux proof abstracts the calculator outputs.
The original `npc_sel` and
arm observation outputs are unchanged; `o_npc_cond` additionally exposes the
existing raw requests for the registered retarget classifier. KEEP boundaries
add no state or cycle.

The `pc_register_mux` one-step proof checks the architectural PC's retained
nested priority. Both slot-2 requests, the canonical request, and the alias
input remain independent, including inconsistent generic combinations.
Default and integrated handoff-parameter tasks preserve architectural
redirects above aliased live slot 2, then staged slot 2, then pending,
registered, and sequential choices. A completed reset-free datum excludes both
slot-2 requests and substitutes the current architectural PC for sequential
data. An independent earlier-redirect permission lets staged use select its
target below redirects, followed by the aliased-live choice. The exact
sequential winner selects the sequential datum last, so late instruction-size
data bypasses the other selections. Reset remains outermost and outside all
KEEP values.
The original nested priority oracle is unchanged, including generic staged
and aliased-live disagreement.

The `pc_holdoff_cofactor` one-step proof compares all three production pending
fetch holdoff outputs with their original nested equations for arbitrary
controls and register state. `PC_FETCH_HOLDOFF_ONLY` excludes the separate
prediction holdoff equations from that arbitrary-state proof and the local
PC-register mux proof. `PC_HOLDOFF_LOCAL_PROOF` excludes unrelated temporal
integration properties, which remain enabled in both prediction-release targets.

The `pc_holdoff_tag` target uses the actual pending valid/tag producers to prove
that a valid episode retains `prev_pc = pc - 2` modulo XLEN. It assumes only
initial pending-valid=0, the real reset image, and leaves external inputs and
other initial state unconstrained. Temporal induction then proves the three
prediction holdoffs match their original equations after removing redundant
exact-owner readiness. An exact owner cannot equal its captured predecessor,
so the existing non-stale/non-predecessor arm already holds prediction there.
Crossing is then factored into a completed predecessor exception: when a
captured predecessor is not after its owner, it must be before it. A wrapped
predecessor is rejected by the final not-after gate. This removes the separate
before comparator from prediction holdoffs while retaining crossing's exact
exception and leaving fetch readiness unchanged. Induction at widths 32, 64,
and 72 covers modular arithmetic. Cover goals at the default 64-bit width
exercise zero, odd wrapped owners, and wrapped predecessors. This theorem does
not claim equivalence for arbitrary corrupt initial valid state. No handoff
priority or observation cycle changes.

The `prediction_metadata_tracker` target follows the same pattern. Its harness
models the registered predictor target and leaves the pending owner and output
PCs arbitrary, so the proof covers both exact-owner replay and a non-owner
predecessor. It proves the tracker's validity equivalence and payload
provenance contract.

The `branch_prediction_alias` target compares the production controller's
default and optimized public alias outputs under IF's structural base+2/base+4
PC wiring. Both PCs and candidate-valid inputs are arbitrary. The one-step BMC
is exhaustive for this combinational cone: its script prunes unobserved logic
and asserts that no memory or sequential cells remain. It makes no claim about
full-controller sequential equivalence. IF must retain its width-equality
opt-in guard so mismatched IF/package widths use the default comparator.

```bash
# List all targets and their supported tasks
./scripts/frost.py formal --list-targets

# See CLI help (includes --target choices)
./scripts/frost.py formal --help
```

## Running

Run formal workflows from the repository root through `./scripts/frost.py`.
The wrapper runs the pinned `frost` image as your UID and GID with `HOME`
under `/tmp`, so the sby output directories stay writable on the host and the
tool versions match CI.

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

The `rob_start_cofactor` induction proof keeps the production ROB allocation
class and valid flip-flops, one-hot head-mask transitions, and CSR/xRET start
equations. It proves that live CSR/xRET entries exclude CDB bypass, the head
mask stays one-hot, and both starts equal their original `head_ready`
equations on every cycle. Payload RAMs and the serializer instance are
removed before optimization and their outputs become arbitrary; no dispatch,
CDB, or flush traffic assumptions constrain the theorem. Only initial reset
is assumed. The normal ROB simulation and formal targets retain the same
legacy-equation assertions.
