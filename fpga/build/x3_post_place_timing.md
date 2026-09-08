# X3 post-place timing validation — 2026-09-07

This records the checkpoint qualified in commit `496c3727`. The default-flow
follow-up below distinguishes its saved-checkpoint evidence from a new build.

The accepted target is WNS >= -0.199 ns after placement at zero added CPU
setup uncertainty, with the CPU period retained at 3.333 ns (300 MHz).
The measured candidate reaches **-0.191 ns**, an 8 ps margin to that target.
It includes two physical LUT input-pin reassignments after `place_design`;
it is not an untouched placer result. No routing or separate
`phys_opt_design` step is included in this result.

## Change and functional contract

The RTL removes a wide PC incrementer from the branch predictor's slot-2
alias comparison. When IF supplies candidate PCs structurally as base+2 and
base+4, the comparator checks the equivalent local carry relationships
between the live PC and the base. Generic callers retain the original
comparison, and IF enables the optimized form only when its PC width matches
the package width. There are no added pipeline stages, stalls, or changed
prediction ownership rules.

The selected placement has one endpoint below -0.199 ns: instruction BRAM
to predecode redirect-target bit 12. Two existing mux LUTs in this cone put
late data on slow physical input pins. Reassigning those data inputs to A6
retains each LUT's logical function, location, and register boundaries.
The two changes are:

| Cell suffix under `cpu_inst/if_stage_inst/c_ext_state_inst/` | Original inputs | Refined inputs |
|---|---|---|
| `u_pd_target_compressed_candidate_i_12` | I1:A6, I2:A4 | I1:A4, I2:A6 |
| `u_pd_target_compressed_candidate_i_2` | I1:A6, I3:A3 | I1:A3, I3:A6 |

These are physical pin assignments, not logical input swaps. The helper
checks the expected mapping and cell properties before making a change.
The rejected predecode register-boundary and KEEP experiments are not part
of the adopted RTL.

## Timing evidence

| Stage | WNS at zero added CPU setup uncertainty (ns) |
|---|---:|
| Original selected raw placement | -0.268 |
| Local-alias RTL, synthesis and Explore opt | +0.070 |
| Local-alias RTL, raw END/0.350 LOW placement | -0.234 |
| Same placement, two physical input-pin refinements | **-0.191** |

The placement recipe uses `ExtraNetDelay_high`, 0.350 ns setup uncertainty
as placer guidance, and `CELL_BLOAT_FACTOR=LOW` on `*u_tomasulo/u_int_rs`.
Reports and the saved placed checkpoint retain the common 0.500 ns scoring
uncertainty: their WNS is -0.691 ns. A separate native reopen removes only
that added CPU setup uncertainty and measures both global and CPU WNS as
-0.191 ns. Generated clocks and existing CDC/IP constraints remain active. Derived
CPU clock uncertainty remains 0.054 ns (TSJ 0.071 ns, DJ 0.082 ns, PE 0,
UU 0 after removing the added setup uncertainty). No custom placer cost-group timing paths remain.

Restoring the original pin maps reproduces -0.234 ns; reapplying both maps
reproduces -0.191 ns. Global hold remains -0.319 ns. The complete DRC report
body is identical before and after refinement, including the expected
unrouted-design findings. These checks do not establish routed closure.

## Regression evidence

All cocotb and formal evidence uses `scripts/frost.py` and the repository's
`frost` image, matching the frozen checkout's CI pins (Verilator 5.052,
cocotb 2.1.0, SymbiYosys 0.68). Vivado 2025.2 runs natively.

- Branch prediction controller: 27 tests; PC controller: 19; IF: 42.
- `csr_test`, including Test 7, passes both software-reset runs.
- `vm_test` case W passes in BRAM (both resets) and DDR.
- `itlb_test` passes in BRAM (both resets) and DDR.
- `csr_file` formal BMC/cover and `tomasulo_wrapper` BMC/cover/fmul repair pass.
- `opensbi_smoke` passes at 5,227,555 cycles. Its DTB contains the current PMU
  event-map node; an older pre-PMU cycle count is not a matched baseline.
- Final `frost.py check`: lint and all 227 fast Python tests pass. The flow
  integration also passes 61 FPGA build tests and 19 Tcl stub cases. A native
  injected failure after both actual remaps restores the original maps, empty
  locks, cell properties, and setup/hold timing exactly.
- The durable `branch_prediction_alias` target exhaustively compares the
  actual public combinational alias outputs under IF's structural wiring.
  Separate width checks cover wraparound and reject the unguarded 32-bit
  counterexample. This is not a full-controller sequential proof.

The alias proof establishes the unchanged combinational behavior responsible
for preserving cycle timing. The physical pin changes add no state or logic.

## Frozen artifacts

The local evidence root is `x3/work_place_goal_20260907/`, relative to this
file. It contains the archived original work directory, immutable source
manifests, exact native invocations, test logs, unsuccessful experiments,
and independent audits. The build used the 225 frozen inputs from baseline
commit `59450b6e` plus the two measured RTL files. Unrelated later documentation
and Linux changes were excluded only after checking the actual build inputs;
all 26 `hello_world` initialization images match the baseline.

| Artifact | SHA-256 |
|---|---|
| Variant1 `post_synth.dcp` | `c325fb2a05f1b9a79b261c6d36e0e2454524f9c8f4de7e54a889a1d4376dedcc` |
| Variant1 `post_opt.dcp` | `7371f90648bd626e879e7f920247eddb839147e93e319380616b891ad0bbcd31` |
| Raw END/0.350 LOW `post_place.dcp` | `be48fdb1013527e51c7db8384722ef6ddb1c507c3fd5472e1304cacc14754d74` |
| Independently audited pin-refinement candidate | `8984c529cf14ab8c6bfdbab2a7c55bbfa4813b843ed48f0c6570d7a2858735f3` |
| Final helper replay `post_place.dcp` | `b6e96dc8f580e2c8da162dfe76f46abafffbe872d5df2e21e7b12e398c5def0f` |
| Final `x3_pd_target_pin_swaps.tcl` | `0a026ff05a20b196be8aafda2747000b18cf76c3439d9666aac31d188b2cab7b` |

The initial refinement's native zero-user timing audit is
`pd_lut3_pin_diagnostic/audit_independent_result.json`; detailed reports are
in the neighboring `audit_independent/` directory. Software and formal logs
are in `rtl_fallback/guards/`, `rtl_fallback/actual_rtl_alias_proof/`, and
`rtl_fallback/integration_review/`.

The source audit for `496c3727` is
`pin_swap_integration/final_main_source_audit.json`.
All 154 measured RTL files match the qualified first candidate. Of the 225
original build inputs, 222 remained byte-identical; only `build.py`,
`build_step.tcl`, and `extract_timing_and_util_summary.py` changed to integrate
the then-opt-in refinement and its provenance. That helper has the exact hash
used by the recorded native replay. Those flow changes did not constitute a
new synthesis or full-placement run: qualification uses the frozen raw placement and the
helper's native replay. The full-placement hook had stub coverage;
it did not separately rerun the placer.

`pd_lut3_pin_diagnostic/final_helper_replay/` preserves the native replay and
rollback commands, full fresh post-place reports, DRC comparison, and frozen
artifact manifest. Whole-design placement comparison confirms identical
names, types, locations, and fixed flags for all 379,226 cells, with exactly
two changed pin-map rows among 197,564 LUTs. The final replay's independent clean-reopen audit also passes at -0.191 ns;
its complete placement and pin-map tables exactly match the first qualified
refinement. All plaintext functional-export content matches the raw design.
Four encrypted vendor-IP blocks produce different ciphertext on export, so
those contents were not compared conclusively. The additional all-property
native graph walk was stopped after a bounded benchmark projected about two
hours for property discovery alone; its partial logs are not passing evidence.

Qualification relies on the exact two-LUT logical INIT/connectivity checks,
whole-design placement/pin-map comparison, matching plaintext export, required
regressions, and native timing/replay/rollback audits. It does not claim full
processor or protected-IP equivalence. This physical refinement retains the
usual reliance on Vivado's logical-to-physical pin mapping and checkpoint
semantics.


The matching synth/opt/refined-place chain is installed in `x3/work/`.
The generated repository README uses an explicit post-place stage override
and records the refinement. Older route, separate-physopt, and final files
in that work directory predate this chain and are not validation evidence
for it. `promotion/main_promoted_manifest.json` records the installed hashes.

## Default-flow follow-up — 2026-09-08

The original opt-in default left the qualified refinement out of ordinary
builds. X3 placement now defaults to `FROST_X3_PD_TARGET_PIN_SWAPS=auto`.
The helper applies only when both recorded LUTs match all eligibility checks;
unmatched placements continue without mutation. Explicit `0` disables the
refinement, and `1` requires a matching implementation.

The attempt runs after temporary placer groups have been removed and CPU
setup scoring has returned to 0.500 ns. Before/after checks compare global
setup WNS and hold WHS. A regression requires exact rollback before auto mode
can continue; failed rollback or missing success-audit output fails the build.
These checks concern worst slack, not a claim that every path improves.

This follow-up changes the build flow only. The measured -0.191 ns checkpoint
above remains the qualified artifact; the user will run the fresh build in
the current worktree. No new synthesis, opt, or placement run is claimed here.
To start at synthesis and stop after placement without quick-route probes:

```bash
FROST_PLACE_QUICK_ROUTE_COUNT=0 ./fpga/build/build.py x3 \
  --start-at synth --stop-after place --keep-temps
```

Validation for the default-flow change is recorded under
`x3/work_pin_auto_20260908/`, relative to this file. `frost.py check` passes
lint and all 262 fast Python tests, including 35 new Tcl execution cases.
Three native cached-checkpoint checks pass: eligible automatic application,
an unmatched seed with no timing query or mutation, and an injected hold-slack
regression followed by exact rollback. The accepted case measures scored WNS
-0.734 to -0.691 ns with WHS unchanged at -0.319 ns; rollback restores the
original real WNS/WHS. The negative test injects a worse reported hold value
after the real remap; it is a control-flow test, not an observed hold regression.
No checkpoint is written by these checks and all input hashes remain unchanged.

The checked helper SHA-256 is
`e33e224275554cdb120f7b2bb03869bc6b6808d0087b01cdaf687b3b8587d2e9`;
the placement script SHA-256 is
`5a13350e9340cfa81ba738bd3de70132774efb327fb129d6ea11c34487ac79a5`.
