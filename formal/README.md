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
- `prove` is an unbounded safety proof. The targets that define it,
  `prediction_release` and `prediction_metadata_tracker`, run ABC PDR.

Parameter-shape variants (`bmc_itlb`, `cover_itlb`, `fmul_repair_bmc`) rerun a
task on a `chparam`'d top. `--list-targets` shows which tasks each target
declares.

## Targets

The target list is not duplicated here. Its sources of truth are
`FORMAL_TARGETS` in `tests/test_run_formal.py` and the `.sby` files.

The `prediction_release` target integrates the production `c_ext_state` and
`pc_controller` state machines with a formal-only harness and a conservative
abstraction of `pc_increment_calculator`. It proves that an atomic pending
target handoff cannot leave stale old-path buffer state selectable, and that
pending-state consumers are masked outside a live episode. Its covers reach
both raw-capture cofactors, which keeps the clear-dominance proof from passing
vacuously. It runs `bmc`, `cover`, and an ABC-PDR `prove` task.

The `prediction_metadata_tracker` target follows the same pattern. Its harness
models the registered predictor target and leaves the pending owner and output
PCs arbitrary, so the proof covers both exact-owner replay and a non-owner
predecessor. It proves the tracker's validity equivalence and payload
provenance contract.

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
