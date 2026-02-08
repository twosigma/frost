# Formal Verification

Formal verification uses SMT solvers to mathematically prove that properties hold for **all possible inputs** across bounded time windows. Unlike simulation (which tests specific input sequences), formal verification is exhaustive within its bounds.

## Tools

| Tool | Purpose |
|------|---------|
| **SymbiYosys (sby)** | Formal verification frontend - orchestrates Yosys + solvers |
| **Yosys** | RTL synthesis and preparation for SMT encoding |
| **Z3** | SMT solver (bounded model checking engine) |

## How It Works

Assertions are embedded directly in the RTL inside `ifdef FORMAL` blocks. These compile away during normal synthesis and simulation, but SymbiYosys defines `FORMAL` automatically, activating the assertions for formal proofs.

Each `.sby` file defines a verification target with two tasks:

- **BMC (Bounded Model Checking)** -- proves all `assert` properties hold for N clock cycles, across all possible input combinations
- **Cover** -- proves all `cover` properties are reachable (i.e., the scenarios aren't dead code)

## Targets

| Target | SBY File | Module | Properties |
|--------|----------|--------|------------|
| **hru** | `hru.sby` | `hazard_resolution_unit` | Stall/flush mutex, reset behavior, stale flush prevention, trap override, load-use hazard correctness, MMIO bounds, CSR stall limits, output consistency |

## Running

```bash
# Run all formal targets (via pytest)
pytest tests/test_run_formal.py

# Standalone runner
./tests/test_run_formal.py
./tests/test_run_formal.py --target hru
./tests/test_run_formal.py --task bmc
./tests/test_run_formal.py --verbose

# Direct SymbiYosys invocation
cd formal/
sby -f hru.sby bmc      # Prove assertions (~2 sec)
sby -f hru.sby cover    # Prove reachability (<1 sec)
```

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

1. Add `ifdef FORMAL` assertions to the RTL module
2. Create an `.sby` file in `formal/` (see `hru.sby` as template)
3. Add a `FormalTarget` entry in `tests/test_run_formal.py`:

```python
FORMAL_TARGETS = [
    FormalTarget("hru.sby", "Hazard resolution unit"),
    FormalTarget("new_module.sby", "Description of new module"),
]
```

## Yosys SVA Limitations

Yosys supports a subset of SystemVerilog Assertions. Key constraints:

- Use immediate assertions inside `always @(posedge clk)` blocks
- Use `!a || b` for implication (not `a |-> b` which is concurrent-only)
- Use `$past(signal)` for sequential properties
- No hierarchical references (`u_sub.signal`) -- assertions must be inside the module
- Use `initial assume(i_rst)` to ensure registers start in a known state

## File Organization

```
formal/
├── README.md       # This file
├── .gitignore      # Ignores sby working directories (*_bmc/, *_cover/)
└── hru.sby         # Hazard resolution unit verification config
```

Assertions live in the RTL files themselves (inside `ifdef FORMAL` blocks), not in separate files.
