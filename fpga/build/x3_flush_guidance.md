# Diagnostic X3 flush guidance

This helper is diagnostic only. The normal build does not call it, and the
former two-placement flush-guidance candidate is retired. Production candidates
run exactly one placement; the examples below describe isolated diagnostics.

`x3_flush_guidance.tcl` requests placement-time replication of the registered
full-flush broadcast. It reads the current optimized design only. The caller
owns placement directives, clock uncertainty, checkpoint generation/import and
the final timing gate; the helper opens no files other than its audit output.

The source is `full_flush_side_effect_kill_q` in
`hw/rtl/cpu_and_mem/cpu/cpu_ooo/branch_recovery/misprediction_flush_controller.sv`.
The RTL already requests `max_fanout=64`. This helper adds exactly two physical
properties on the exact FDRE's immediate Q net:

```tcl
set_property MAX_FANOUT_MODE CLOCK_REGION $flush_q_net
set_property FORCE_MAX_FANOUT 64 $flush_q_net
```

These are placer replication requests, not a guarantee of a particular replica
count or final fanout. There are no hand-created registers, assigned sites,
REUSE_STATUS changes, clock overrides or external reference inputs.

For an isolated diagnostic, use both calls in the same Vivado session:

```tcl
source [file join $script_directory x3_flush_guidance.tcl]
set flush_state [::frost_x3_flush_guidance::prepare $before_audit]
# Caller runs its chosen placement here.
set flush_result [::frost_x3_flush_guidance::verify $after_audit]
```

`prepare` resolves the exact unplaced FDRE and Q net, checks its C/CE/D/R
connections, INIT/inversions and actual CPU clock (`clock_from_mmcm`, 3.333 ns),
and captures its current complete leaf sink set. Conflicting fanout requests,
DONT_TOUCH, fixed placement and packing constraints reject before writes.
Existing `KEEP=yes` on the RTL register is preserved; it is compatible with
this replication request. Only the two physical properties are written, each
with immediate readback. A partial property-update failure is fatal and cannot
produce a prepared state.

`verify` follows each original sink to its actual post-place FDRE/Q driver.
Names and historical replica counts do not prove equivalence. Every discovered
driver must retain the captured C/CE/D/R source identities, direct CPU clock,
INIT and exposed inversion properties. Constants are compared by their native
GND/VCC primitive role. The complete output partitions must be disjoint and
exactly cover the original sinks. The original FDRE is also checked if it
survives, including when all captured sinks have moved to replicas. Existing
driver/ancestor protection properties remain unchanged. A single unchanged
driver is a valid observed result, reported as such.

The audit preserves the captured signature, original sinks, property requests,
actual driver partitions and per-sink ownership. Queries are bounded to at most
1,024 current sink leaves and their drivers, plus the original hierarchy and
four input drivers. No global clock/reset load census or broad property dump
is performed. Unexpected renamed, missing or added sink leaves cause a failed
verification rather than an assumed equivalent mapping.

The retired historical experiment saved the first placement as guidance,
reopened its optimized input, imported that guidance with `TimingClosure`, and
ran a second placement. That sequence is not a supported production recipe.
The helper's `VERIFIED` marker establishes register/ownership preservation,
not timing closure or eligibility for production promotion.

Test the actual helper with the repository's Docker image:

```sh
./scripts/frost.py run pytest tests/test_x3_flush_guidance.py -q
```

These finite mock-netlist tests cover property writes/readback, current clock
and protection guards, actual replica discovery, register-input changes,
complete sink ownership and the failure policy. They do not simulate Vivado's
placement or establish a timing benefit.
