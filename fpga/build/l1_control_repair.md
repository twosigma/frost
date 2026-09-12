# L1D completion repair in a fresh X3 build

`l1_control_repair.tcl` applies an exact, function-preserving transformation to
an **unplaced optimized netlist**. It needs only the current design and its
compiled-in recipe; it reads no experimental checkpoint, model or saved report.
The caller owns `opt_design`, placement, constraints and the timing gate.

The RTL origins are the T decision (`t_done`) and T acceptance (`t_accept`) in
`hw/rtl/lib/cache/frost_cache.sv`, followed by the T payload/control capture in
the Stage A/T/W register block. The hierarchy scope is the L1D `l1_cache`
instance in `frost_cache_hierarchy.sv`. L1I and L2 are outside this repair.

The completion network has four original LUTs and 13 distinct boundary input
pins. The shared input called R3 also feeds the original NODE9's fourth input;
it is one Boolean variable. The transform retains BLOCK, READY and NODE9 for
other consumers, then replaces only the shared VALID LUT. The new network is:

| Node | LUT INIT | Ordered inputs, I0 first |
|---|---|---|
| C | LUT2 `1` | V0, V2 |
| G | LUT5 `F0FFE0EE` | W, R1, B5, V4, X |
| Y | LUT5 `77FF70F0` | B0, B1, W, B2, X |
| FINAL | LUT6 `2020AAA000000000` | C, R2, G, Y, R3, R4 |

This puts R3 and R4 directly into the final LUT. Before editing, the module
reads all original INITs and ordered input drivers, checks the original
output owners, and exhaustively compares the actual four-node graph with the
replacement over 8,192 binary assignments (588 ones). This is a local
combinational equivalence check, not a CPU state or four-state proof.

The final T enable has INIT `0045`: `!I3 && !I0 && (!I2 || I1)`.
Three identical copies distribute its exact 128 CE leaves as 48/42/35/3.
All four inputs are preserved from the current netlist; in particular the
reset driver is captured at runtime, without a historical replica name or a
reset-consumer census. The leaf partition is expressed using logical register
names. No LOC, BEL, pin assignment, placement reuse or clock constraint is set.
The original VALID output has 28 leaves; the three extra T inputs raise it to
31. Final checks preserve source/consumer configuration, every other consumer
input, retained output ownership and the complete CE partition.

The API is:

```tcl
source [file join $script_directory l1_control_repair.tcl]
::frost_l1_control_repair::apply $work_directory/l1_control_repair_audit.tcldict auto
```

Call it on X3 after `opt_design` and before saving `post_opt.dcp`. Automatic
mode returns 0 with `SKIPPED_BEFORE_EDIT` if the synthesized implementation no
longer matches the exact recipe. Strict mode makes that mismatch fatal. Both
modes stop on an unexpected API error or any failure after editing starts;
they never treat a partial transformation as a skipped repair. The audit
records `APPLIED` only after all final checks pass, and retains the actual
preflight input/configuration snapshots for review.

A different synthesis structure therefore remains safe but may lose the timing
benefit. Fresh native placement and the normal build's whole-design timing gate
must establish the result. This module alone does not promise timing closure.

Run its functional/API-policy tests in the repository image:

```sh
./scripts/frost.py run pytest tests/test_l1_control_repair.py -q
```

The tests execute the actual Tcl against an in-memory netlist API, including
successful edits, unexpected owner/source/function/protection rejection,
repeated invocation, a Boolean counterexample and a fatal partial edit. They
are not a Vivado API or placement simulation.
