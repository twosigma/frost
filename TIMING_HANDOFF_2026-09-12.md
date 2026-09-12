# X3 timing handoff — 2026-09-12

## Status and ownership

Timing closure has **not** been achieved. The target is NIC-enabled X3 at a
3.333 ns CPU period, with **post-place WNS at zero added setup uncertainty
at least −0.200 ns**. The best preserved ordinary placement is **−0.250 ns**.
The earlier approximately −0.200 ns result depended on adjustments between
repeated placements and was not reproduced by the ordinary build.

The user requested this handoff for Fable to take over. Further experiments
were stopped; the already-running coverage-PC placement sweep finished as
the final measurement. Do not interpret this handoff as a successful
timing signoff.

Main working tree: `/home/adam-bagley/fable_frost_slice1`, branch
`phase4-slice1`. Its code baseline is `73ea4135581e92c77c5469b3152b54ec9e37423e`.
The handoff commit changes documentation only. The experimental RTL described
below has **not** been promoted into this tree. Main does not contain the
experimental source used for those results; neither result is validated for
this main baseline.

The Yosys NIC-source-list fix (`9d96dbd3`) and Tcl loader NIC/DMA application
registration (`396a4fc3`) are already committed in main.

The final sweep finished at **2026-09-12 20:48:20 UTC** (16:48:20 EDT).
All 27 candidates failed the native gate; the best was −0.336 ns. Exit code
1 is the expected timing-gate failure, not a crash. No downstream work ran.
The completed clone had no remaining Vivado processes when preservation
began. No further experiments are running or scheduled by this pass.

## Requirements to retain

- Prefer RTL changes. A measured static pblock is acceptable, but do not
  reintroduce repeated placement with adjustments between passes as the
  production flow.
- One ordinary `place_design` per independent candidate. The existing default
  sweep of independent candidates is distinct from the retired iterative flow.
- Do not run post-place physical optimization, routing or later implementation
  on an input below the −0.200 ns post-place gate. Internal phases of one
  `place_design` are part of that placement command.
- The user's experience is that first-route WNS generally needs to be around
  −0.100 ns or better to have a useful chance of closing. This is an
  expectation for later work, not a new scripted gate.
- Preserve real clocks, functionality and timing coverage. Final reproduction
  must come from committed source and the normal command, without an external
  experimental checkpoint or script as a required input. After choosing and
  integrating source, this is the future reproduction command, run from a
  **fresh ordinary clone with no prior build directory**:

  ```bash
  ./fpga/build/build.py x3 --stop-after place
  ```

  The current `slice1/fpga/build/x3/work/` holds the preserved 150 MHz hardware
  outputs. Leave those in place during initial investigation; do not resume
  them as 300 MHz inputs. A future fresh build in `slice1` would overwrite
  those working outputs, so retain the verified backup first.

- A report saying no congestion windows were reported is **not zero
  congestion**. These reports normally list windows at level 5 or above.
- The native gate's strict calculated-slack query decides the −0.200 ns
  boundary. Rounded display text alone does not. `STRICT_BELOW_GATE_PATHS=1`
  is a capped existence query, not the number of failing endpoints.

## Ordinary build flow and safe operation

The main and current experimental trees have identical normal `build.py`,
`build_step.tcl`, L1 repair, post-place gate and downstream checkpoint lineage
code. The default is 27 independent placement candidates with a maximum of
12 Vivado jobs per build. Reporting uses zero added setup uncertainty after
placement; the real CPU period remains 3.333 ns. Quick-route probes default
to zero. The gate preserves the best failure and exits nonzero if none passes.

The production flow no longer does a second placement after L1 or pin-map
adjustments. PC-tail timing groups are timing weights, not pblocks. The
historical pin-refinement helper is diagnostic-only. Preserve the retirement
and documentation cleanup in `165ad57c`, `63a0294b` and `73ea4135`.

Vivado runs natively. Cocotb and formal runs use the repository's `frost`
Docker image and `scripts/frost.py`, with clean builds. Always use a separate
ordinary clone for simulation: `make clean`, firmware compilation and
`build.py` can invalidate another job's inputs in a shared checkout. Never
run two cocotb targets simultaneously in one checkout. `build.py` can rewrite
the generated README utilization table after completed stages; review those
changes.

The 12-job limit is per build, not a global host scheduler. Keep combined
native jobs at or below 12. Full CPU synthesis can create seven children
beside its parent, so reserve eight slots when overlapping it with other
native work. Do not overlap a heavy full-CPU Yosys run with the Vivado sweep;
earlier combined memory pressure caused crashes. Recent isolated validation
used one CPU/compiler worker and an 8 GiB combined memory/swap limit.

Do not delete the dated clones or backups during handoff. The experimental
directories below are ordinary clones, so `git worktree list` does not list
all of them. Their commits may need to be fetched from the local clone before
they are available in the main repository.

## Preserved results

All WNS values below are ns at zero added setup uncertainty after ordinary
placement, except the explicitly marked historical iterative result.
Archive names are under `/home/adam-bagley/fable_frost_backups/`.

| Source / experiment | Best WNS | Scope and archive |
|---|---:|---|
| Historical iterative result | about −0.200 | Adjusted checkpoints between repeated placements; not an ordinary-flow reproduction. `qualified_placement_300mhz_d102_20260912`; retired. |
| V4 `8cff3bc7d7e716330012c59cf43ffcd8d9c1d09c` | **−0.250** | Full 27-candidate sweep; ExtraNetDelay_high at 0.450 ns placement uncertainty; reported congestion level 5. `rtl_v4_single_place_300mhz_20260912` |
| V6 `5d0a547a4897ea6df8598d2bb46e14eb6b50e00f` | −0.338 | Full 27-candidate sweep; did not improve V4. |
| MAX4 `10337a3f0e7b369759df9545d6118b4e775307fd` | −0.297 | Six-candidate screen; `rtl_v9_max4_six_candidate_placement_screen_20260912` |
| Raw parcel replay `f00f4444aba1bda318436d8968145b05a6f1013b` | −0.292 | Six-candidate screen; `rtl_raw_parcel_six_candidate_placement_screen_20260912` |
| Performance selector MAX64 / CF1D `cf1d347300a48532a4902695edb5a312e57d068f` | −0.293 | Six-candidate screen; `rtl_perf_selector_fanout64_six_candidate_placement_screen_20260912` |
| MAX4 target fallback `162c011f75269db5a0a53e0d9db5bd600bb06bd1` | −0.309 | Full 27-candidate sweep, all failed. Best without a reported level-5 window was −0.333. `rtl_max4_target_fallback_default27_placement_20260912` |
| Coverage-PC copy `27a0e00421cc99040ad0b98b09965252dc626a2d` | −0.336 | Full 27-candidate sweep, all failed. ExtraNetDelay_high at 0.450 ns; no reported ≥5 window. `rtl_coverage_word_replica_default27_placement_20260912` |

Direct archive entry points:

- [Final coverage-PC sweep](/home/adam-bagley/fable_frost_backups/rtl_coverage_word_replica_default27_placement_20260912/README.md)
- [Best ordinary V4 sweep](/home/adam-bagley/fable_frost_backups/rtl_v4_single_place_300mhz_20260912/README.md)
- [V4 functional validation](/home/adam-bagley/fable_frost_backups/rtl_v4_functional_validation_20260912/README.md)
- [Last completed target-fallback sweep](/home/adam-bagley/fable_frost_backups/rtl_max4_target_fallback_default27_placement_20260912/README.md)

The best ordinary source is in
`/home/adam-bagley/fable_frost_rtl_timing_v4_20260912`.
The latest experiment is in
`/home/adam-bagley/fable_frost_coverage_word_replica_20260912`.
Newer source did not necessarily yield better placement. Do not choose a
candidate solely by its date or cherry-pick only its last commit: these
experiments contain cumulative dependencies.

V4 is a cumulative 55-file difference from main `73ea4135`. It classifies
indirect instructions before parcel selection, uses existing fast bit-20 and
illegal outputs in slot-1 decompression, compares SC addresses before head
selection, simplifies NIC byte-pack issuance, captures secondary-ALU shift
amounts and preselects the performance CSR's 32-bit half. Normal AMOs gain a
COMPUTE cycle with corresponding protocol tests. Scalar RAM changes protect
storage/read registers and request MAX4 address replication, retaining KEEP
on both address mux anchors. The guarded distribution helper uses three
copies/24 moved loads and excludes SIDEBAND.

V4 predates the later PC+2/RAS rewrites, raw-parcel replay simplification,
target-operand capture, selector MAX64 and coverage-PC bank. Its interfaces,
tests, formal targets and documentation belong with the RTL. The archive's
changed-files record uses base `63a0294b`, hence lists 54 files rather than
55 against main `73ea4135`; preserve main's later diagnostic-only cleanup.

V4's functional evidence is in `rtl_v4_functional_validation_20260912`.
It tested `28b1c7e79d012eba4eb82944482d2e9a3e0f3534`; native V4 `8cff3bc7`
is its verified comment-only child, with that exact diff preserved. Lint and
480 Python tests passed. Full-CPU tests passed for DDR `amo_irq_torture_sim`
and `ddr_atomic_test` (one boot each), plus BRAM `rv64_amo_test`, `isa_test`,
`rv64_smoke`, `csr_test`, `csr_rmw_test` and `tomasulo_perf` (two reset boots
each). This is finite regression evidence, not a separate simulation of the
comment-only child or timing qualification.

Start with each archive's `README.md`, then follow its index and manifest to
the exact source, measured candidates, gates, reports and preserved
checkpoints. The timing archives include source snapshots and patches.
Read these records before reusing a result or overwriting the original
build directory.

The historical d102 archive name contains `qualified`, but that refers to
separate checks on the exact edited checkpoint. Its original raw status
remains `FAILED_OR_UNQUALIFIED_PRESERVED` because of two reuse-property
warnings; the saved native boundary review found no computed setup path below
−0.200 ns. None of that establishes ordinary source reproduction, routing or
hardware validation of that result.

## Final experiment: coverage-PC registers

The parent CF1D screen's best setting was −0.293 ns. Of its 42 endpoint-worst
paths below −0.200 ns, 40 launched from architectural PC bit 14: 32 fetch-PC
data endpoints and eight predecode reset endpoints. The worst path went
through the served-window coverage comparator and PC selection logic.

Commit `27a0e004` adds a 30-bit `coverage_pc_word_q` register bank, captured
from `next_pc_reg[31:2]` under the exact existing `pc_reg_load_en` edge. Only
the two served-window coverage helpers consume it. It adds no pipeline cycle,
independent reset or initialization. The main architectural PC, its existing
bit-1 copy, protected PC adder, full-address fault checks and independent
test oracles remain intact. The RTL adds nominally 30 physical FFs.

Fresh synthesis/optimization was run from this committed source. Its own
post-opt result was −0.086 ns, TNS −1.939 ns, 102 failing endpoints.
The post-opt DCP SHA256 is
`d96faeefeebc97373eca96029fbb476599d714b20ad64adcec1b83fb0378946c`.
These are **unplaced** numbers, not qualification.

The subsequent sweep used the normal default 27 settings, one placement per
candidate, `--jobs 12 --keep-temps`, with inherited `FROST_*` settings removed.
It ran from 19:06:24 to 20:48:20 UTC and failed all 27 native gates.
The selected ExtraNetDelay_high 0.450 result has WNS −0.336 ns, TNS
−1337.093 ns and 11,933 negative endpoints out of 559,587. Of those endpoint
rows, 1,745 are strictly below −0.200 ns. No ≥5 congestion window was reported.
The run did not execute quick-route probes or downstream implementation.
Run metadata and complete stdout are in the clone's
`.git/coverage_word_replica_place_run.json` and
`.git/coverage_word_replica_place_stdout.log`.

The sealed final archive is
[rtl_coverage_word_replica_default27_placement_20260912](/home/adam-bagley/fable_frost_backups/rtl_coverage_word_replica_default27_placement_20260912/README.md).
It contains all 27 raw report sets, selected/canonical placement checkpoints,
fresh synth/opt checkpoints, source snapshot and patch, firmware inputs and
run provenance: 616 indexed files, 739,099,743 bytes. All manifest entries were
independently rehashed successfully after copying. The archive retains the
failed gate and `qualified=false` status.

- `MANIFEST.json` SHA256:
  `bb27c543816c5e2ce209f719e53247d166469bd3b0facf4df9fc2e582c137e57`
- Selected/canonical `post_place.dcp` SHA256:
  `df58b8c53d6366dbc1929a22ee9f2491343031208b5dd83abc5b08823d20db47`
- [Final selected worst path](/home/adam-bagley/fable_frost_backups/rtl_coverage_word_replica_default27_placement_20260912/canonical_work/post_place_gate_worst.rpt)
  and [failing-path CSV](/home/adam-bagley/fable_frost_backups/rtl_coverage_word_replica_default27_placement_20260912/canonical_work/post_place_failing_paths.csv).

Completed functional evidence for this exact source:

| Check | Result | Archive |
|---|---|---|
| Doctor, changed-file lint, PC and IF tests | Doctor 10/10; PC 20/20; IF 43/43 | `rtl_coverage_word_replica_validation_20260912` |
| Actual PC-copy formal invariant and covers | Prove and cover passed; equality after shared capture, three covers | Same module archive |
| Full repository check | Lint and 480 Python tests passed; no autofix source changes | `rtl_coverage_word_cpu_validation_20260912` |
| BRAM branch and PDE programs | Two reset boots each: 15204/14995 and 778127/777810 cycles | Same CPU archive |
| DDR branch program | One repository-forced boot, 27813 cycles, XML 1/1 | `rtl_coverage_word_ddr_branch_validation_20260912` |

These checks used the isolated validation clone, assertions where applicable,
clean builds and the repository Docker image. They are finite functional
evidence, not full ISA/OS validation of every cumulative change or timing
signoff. The saved image identity is
`83938360f1f0c6dad9b4a41fdf6fd057ee72a5952976745f5230b7381b81b793`.
The local copy proof retains the actual PC/copy registers and shared D/enable
logic while using the two existing `control_flow_tracker` and
`pc_increment_calculator` helper abstractions.

Native mapped-register evidence is in
`coverage_word_replica_postopt_readback_20260912`. Preserve its limitations:
the first collector failed a controller-pin query cap; the second completed
but remains **REVIEW** because direct controller output-port labels were not
resolved. Independent analysis of the saved actual connectivity found 30
distinct copy FFs, each with one matching main FF input/configuration
signature, six coverage loads per bit and no other copy loads. All 60 helper
word inputs matched; the main FFs retained their PC-precompute consumers.
No third reader ran. This supports the intended separate-bank/common-load
check, not arbitrary-initial-state or whole-netlist equivalence. The reader
and its launcher are diagnostics, not production dependencies.

## Useful path evidence and untested ideas

For the coverage-copy experiment's selected ExtraNetDelay_high 0.450
setting, WNS was −0.336 ns with 1,745 strict failing endpoints from 138 launch
pins. The worst path was instruction BRAM `memory_odd_cold_reg_0_1` to
predecode slot-1 `source_reg_1[4]`: seven LUT levels, 3.381 ns data delay
(1.307 ns logic including 0.898 ns BRAM clock-to-output; 2.074 ns reported
net delay) and −0.257 ns clock skew. Selection/decode feeding the PD source
field is on that path. The same BRAM launches nine strict misses, so it does
not explain the whole population.

The largest launch-family groups were ALU-to-SQ address/MMIO (292),
flush/recovery (248), LQ/SQ controls (165), decode/RAT/operand selection (151),
fetch PC/IMMU/saved validity (138), RS/CDB (122) and NIC TX unpack (106).
Its 11,933 negative endpoint-worst samples contained no coverage-copy Q
launches; three incoming copy D paths failed from saved-valid control at
−0.286/−0.256/−0.238 ns. Architectural PC launches accounted for 17 strict
misses, and fetch PC for 24. Absence from this endpoint-worst sample is not
a proof that every path through the coverage bank meets timing.

These results give no basis for adding another coverage-PC bank or assuming
a fix to the single worst path would close the design. Use the selected
candidate's preserved `post_place_gate_worst.rpt` and
`post_place_failing_paths.csv` for the exact paths.

Held ideas, **not implemented or measured**:

- Exact V4 has not been tried with plain ExtraNetDelay_high at 0.425 or 0.475
  ns placement uncertainty. Its 0.450 result was −0.250; neighboring measured
  settings were non-monotonic. Existing CLI grids are 50 ps-spaced and append
  an EPPO extra seed. Keep the 0.500 guidance baseline separate from any finer
  experimental setting; changing the baseline changes guidance policy.
  Plain END 0.450/0.425/0.475 receive no PC-tail guidance; END 0.500 does.
  Any successful setting must be committed into normal configuration and
  reproduced from fresh source before claiming success.
- A PC arm-12 base-data cofactor appears redundant under the existing final
  selection. It has a source argument only, no implemented/tested change.
- A compressed bit-19 cofactor was derived but not implemented or measured.
- Dedicated coverage-PC banks for low-BRAM and cached/L1I providers could use
  the same capture edge, but both would have to update on every shared load,
  independent of provider selection. The currently examined placement gives
  no reason to pursue them. Extra D/CE/clock loading and merging/locality
  would require verification. These compare virtual served-window tags;
  preserve the downstream low-provider replay exemption.

Broad fetch pblocks were investigated but not adopted. In the best MAX4
geometry readback, approximately 99.3% of the relevant sites were already
inside the four proposed clock regions, and some failing BRAM sources were
already inside. That is not evidence that a broad fence improves timing.
The geometry archives are `rtl_max4_end450_fetch_geometry_20260912` and
`rtl_raw_parcel_fetch_geometry_20260912`.

## If integrating an experimental source later

The exact `27a0e004` versus `73ea4135` audit found 68 changed paths, including
22 production SV files (one comments-only). Required groups include fetch
classification/replay, PC/RAS, RVC and PD operand capture, scalar RAM
distribution, CSR/performance capture, secondary INT shift hints, AMO/SC
control and NIC packing. Bring their file lists, optional interfaces, test
harnesses, registries and documentation together. Normal AMOs gain their
documented COMPUTE cycle; do not omit its model/test changes.

The production NIC placement helper also differs: DMA/L1I/E04 use three
copies and 24 moved loads, with SIDEBAND explicitly excluded. Its fixtures
must accompany it. Keep main's diagnostic-only pin-refinement cleanup.
Rewrite candidate/unmeasured/rollback prose for the selected final source;
do not copy either README wholesale. Audit the actual chosen candidate again
if using V4 instead of the latest experiment.

One formal distinction matters: `27a0e004` registers the PD operand target
as BMC4 plus cover; `162c011f` used prove plus cover. A separate original
`62900170` induction archive exists at
`rtl_pd_target_operand_induction_validation_20260912`, but it is not an
own-27a0 induction run. Promoting that configuration requires checking exact
harness/RTL identity and running the relevant check.

## Hardware baseline and original handoff

The user ran the nominal 150 MHz CPU / 40 MHz MAC build and reported
**42/42 hardware regression stages passed**, including NIC loopback, DDR,
CoreMark Pro and Linux. That result is preserved in the hardware archive.
Its saved final setup WNS is +0.184 ns and hold WHS is +0.010 ns. It uses
internal NIC loopback; no GTY is instantiated for that loopback build.
Keep this working hardware baseline:

`/home/adam-bagley/fable_frost_backups/slice1_150mhz_hardware_pass_20260910_234243-0400`

The archive records RTL build `21d3fa99` and source snapshot `396a4fc3`.
It uses lowercase `manifest.json` and `SHA256SUMS`.

The main tree's existing `fpga/build/x3/work/` still contains this 150 MHz
build. Its final checkpoint, bitstream and final/post-place reports match the
hardware archive byte-for-byte. `final.dcp` SHA256 is
`9042478740265ace27934cf5c1a340fedd36d9fe0e6f7fb373262bfc30c2d8cd`.
The final report has CPU period 6.666 ns and MAC period 24.997 ns; the saved
post-place report uses 0.500 ns added uncertainty. These are not current
300 MHz gate evidence. Keep them as hardware reference and start 300 MHz
work from fresh synthesis rather than resuming those checkpoints.

Hardware regression evidence belongs to that baseline, not the later
experimental RTL. No board programming was done during this final handoff.

Original incoming note and probe artifacts:

`/home/adam-bagley/.claude/projects/-home-adam-bagley-fable-frost/notes/phase4/slice2_timing_handoff_for_astra.md`

The working investigation history is preserved in
`/home/adam-bagley/fable_frost_repro_20260912/.git/repro_run_status.md`.
It is a chronological scratch record with superseded entries; prefer this
dated handoff and each sealed archive's final records for conclusions.
