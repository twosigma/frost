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

Each `.sby` file defines a verification target with tasks:

- **BMC (Bounded Model Checking)** -- proves all `assert` properties hold for N clock cycles, across all possible input combinations
- **Cover** -- proves all `cover` properties are reachable (i.e., the scenarios aren't dead code)
- **Prove (k-induction)** -- unbounded safety proof via k-induction; proves properties hold for all time, not just N cycles. Available for simple state machines (HRU, LR/SC).

## Targets

| Target | SBY File | Module | Tasks | Properties |
|--------|----------|--------|-------|------------|
| **hru** | `hru.sby` | `hazard_resolution_unit` | bmc, cover, prove | Load-use stall contract, branch flush duration, trap override, MMIO termination, CSR bounded, shift register fill, stale flush prevention |
| **lr_sc** | `lr_sc.sby` | `lr_sc_reservation` | bmc, cover, prove | SC clears reservation, LR sets reservation, SC priority over LR, stall preserves state, reset clears all |
| **trap_unit** | `trap_unit.sby` | `trap_unit` | bmc, cover | Trap/MRET mutex (RTL-enforced trap priority), trap needs source, interrupt priority, vectored offsets, re-entry prevention, WFI stall |
| **csr_file** | `csr_file.sby` | `csr_file` | bmc, cover | Trap saves state, MIE/MPIE management, mepc/mtvec alignment, mip reflects inputs, counter increments, fflags sticky |
| **fwd_unit** | `fwd_unit.sby` | `forwarding_unit` | bmc, cover | MA priority over WB, x0 always zero, no-forward uses raw value, reset clears enables, forward requires write |
| **fp_fwd_unit** | `fp_fwd_unit.sby` | `fp_forwarding_unit` | bmc, cover | Reset/flush clear enables, pending self-clearing, stall matches pending, capture bypass requires write enable |
| **cache_hit** | `cache_hit.sby` | `cache_hit_detector` | bmc, cover | MMIO exclusion, non-load exclusion, tag mismatch exclusion, byte/halfword/word valid bit checks |
| **cache_write** | `cache_write.sby` | `cache_write_controller` | bmc, cover | MMIO stores bypass cache, AMO byte enables, stale load prevention, store valid bit merging |
| **data_mem_arb** | `data_mem_arb.sby` | `data_mem_arbiter` | bmc, cover | Priority encoding (FP > AMO write > AMO stall > default), stall gates stores, AMO gets all bytes |

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
sby -f hru.sby prove    # Unbounded induction proof
sby -f lr_sc.sby prove  # LR/SC induction proof
```

## Property Style: Contract-Based

Properties follow contract-style verification rather than tautological restating of RTL:

- **Contract properties** verify input-to-output relationships that are falsifiable -- changing the implementation could break them
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

1. Add `ifdef FORMAL` assertions to the RTL module
2. Create an `.sby` file in `formal/` (see `hru.sby` as template)
3. Add a `FormalTarget` entry in `tests/test_run_formal.py`:

```python
FORMAL_TARGETS = [
    FormalTarget("hru.sby", "Hazard resolution unit", ("bmc", "cover", "prove")),
    FormalTarget("new_module.sby", "Description of new module"),  # bmc + cover only
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
├── README.md               # This file
├── .gitignore              # Ignores sby working directories
├── hru.sby                 # Hazard resolution unit
├── lr_sc.sby               # LR/SC reservation register
├── trap_unit.sby           # Trap unit
├── csr_file.sby            # CSR file
├── fwd_unit.sby            # Forwarding unit
├── fp_fwd_unit.sby         # FP forwarding unit
├── cache_hit.sby           # Cache hit detector
├── cache_write.sby         # Cache write controller
└── data_mem_arb.sby        # Data memory arbiter
```

Assertions live in the RTL files themselves (inside `ifdef FORMAL` blocks), not in separate files.
