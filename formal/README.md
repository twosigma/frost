# Formal Verification

Formal verification checks properties over **all possible inputs** within
bounded time windows and, for selected safety targets, with unbounded proofs.

## Tools

| Tool | Purpose |
|------|---------|
| **SymbiYosys (sby)** | Formal verification frontend — orchestrates Yosys + solvers |
| **Yosys** | RTL synthesis and preparation for SMT encoding |
| **Boolector / Z3** | SMT solvers (the `smtbmc` engine; each `.sby` selects one) |
| **btormc** | BTOR model checker (the `btor` engine; faster on some targets, e.g. ROB BMC) |

## How It Works

Block-local assertions normally live in RTL `ifdef FORMAL` blocks. Integration
targets may instead add a formal-only harness and conservative helper
abstractions under `formal/`, while still checking properties attached to the
production modules. `FORMAL` is not a global define: Yosys sets it per file,
only for sources read with `read -formal`; a plain `read` gets `SYNTHESIS`
instead, so those blocks compile away during normal synthesis and simulation.
Each `.sby` selects which production modules, harnesses, and helpers are read
with formal properties enabled.

Each `.sby` target defines these tasks:

- **BMC (Bounded Model Checking)** — checks every `assert` for N cycles across
  all input combinations
- **Cover** — finds traces reaching each `cover` property
- **Prove** — optional unbounded safety proof using the engine selected by the
  target. `prediction_release` uses ABC PDR.

## Targets

The target list is not duplicated here. Its sources of truth are
`FORMAL_TARGETS` in `tests/test_run_formal.py` and the `.sby` files.

The `prediction_release` target integrates the production `c_ext_state` and
`pc_controller` state machines with a formal-only harness and conservative PC
increment abstraction. It proves that an atomic pending target handoff cannot
leave stale old-path buffer state selectable, that both raw-capture cofactors
are reachable, and that pending-state consumers are masked outside a live
episode. It runs BMC, cover, and unbounded ABC-PDR proof tasks.

```bash
# List all targets and their supported tasks
./scripts/frost.py formal --list-targets

# See CLI help (includes --target choices)
./scripts/frost.py formal --help
```

## Running

Run formal workflows from the repository root through `./scripts/frost.py`.
The wrapper uses the pinned `frost` image as the invoking user's UID and GID
with its home under `/tmp`, so proof artifacts remain writable outside the
container and the tool versions match CI.

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

## Property Style: Contract-Based

Properties state falsifiable contracts rather than restating the RTL:

- **Contract properties** verify input-to-output relationships
- **Sequential contracts** use `$past()` to verify state transitions across clock edges
- **Structural constraints** use `assume` to model impossible input combinations (e.g., `!(trap && mret)`)
- **Wiring guards** verify output port assignments match internal signals (catch cut-paste errors)

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
   source whose properties must be active with `read -formal -sv`; a plain
   `read -sv` compiles its assertions out and can make a proof pass vacuously.
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

Yosys supports a subset of SystemVerilog Assertions. Key constraints:

- Use immediate assertions inside `always @(posedge clk)` blocks
- Use `!a || b` for implication (not `a |-> b` which is concurrent-only)
- Use `$past(signal)` for sequential properties
- No hierarchical references (`u_sub.signal`) — assertions must be inside the module
- Use `initial assume(i_rst)` to ensure registers start in a known state

## File organization

```
formal/
├── README.md                            # This file
├── .gitignore                           # Ignores sby working directories
├── *.sby                                # Formal target configurations
├── prediction_release_formal.sv         # Formal-only integration harness
└── prediction_release_pc_increment.sv   # Conservative helper abstraction
```

Block-local assertions generally live in RTL `ifdef FORMAL` blocks. Formal-only
integration and abstraction files live beside their `.sby` target and are not
part of production synthesis.
