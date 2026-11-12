# Formal Verification

FROST checks its RTL with [SymbiYosys](https://github.com/YosysHQ/sby) as well
as simulation. The targets cover the fetch stage, the out-of-order back end
(ROB, rename, reservation stations, load and store queues), the execution
units, the MMU and caches, the NIC's clock-crossing FIFO, the APLIC, and the
IMSIC. Each `.sby` file in this directory is one target, registered in
`FORMAL_TARGETS` in `tests/test_run_formal.py`, and CI runs every task of every
target. Most properties live in the RTL module they check, under
`ifdef FORMAL`. The `.sv` harnesses in this directory hold the proofs that
connect several modules or compare two instances of one.

Run through the pinned Docker image:

```bash
./scripts/frost.py formal --list-targets                            # targets, their tasks, and task descriptions
./scripts/frost.py formal --target trap_unit                        # every task of one target
./scripts/frost.py formal --target prediction_release --task prove  # one task of one target
./scripts/frost.py formal --task bmc                                # one task on every target that declares it
./scripts/frost.py formal                                           # everything, as CI runs it
```

| Task | Checks |
| --- | --- |
| `bmc` | Every assertion holds on every trace up to the script's depth |
| `cover` | Every cover statement is reachable |
| `prove` | Every assertion holds in all reachable states (k-induction or ABC PDR) |

Other task names are parameter or width variants of these, such as
`bmc_xlen32` or `bmc_xilinx`. Each target and task is a separate SymbiYosys
run. The runner's default timeout is 40 minutes. `csr_file:bmc`,
`csr_file:bmc_perf_off`, and `reorder_buffer:bmc` each have 90 minutes.
`coherent_hart_cache:coh_hart_maint_prove`, `coh_hart_maint_four_bmc`, and
`coherence_store_boundary:cover_four` have 120 minutes.
`coherence_store_boundary:bmc_four` has 300 minutes and `bmc_intervening`
has 240 minutes. `coherence_l1d:coh_l1d_bmc` has 180 minutes at depth 40;
`coh_l1d_multi_bmc` has 300 minutes at depth 40.
`coh_l1d_zero_bmc` has 180 minutes at depth 40 and `coh_l1d_zero_multi_bmc` has
300 minutes at depth 30.
`coh_l1d_stream_free_bmc` has 180 minutes; `coh_l1d_stream_bmc`,
`coh_l1d_stream_hold_bmc`, `coh_l1d_stream_free_nostore_bmc` and
`coh_l1d_stream_free_nostore_hold_bmc` have 60 minutes each.
`coherence_array:coh_array_port_bmc` has 40 minutes and
`coh_array4_port_bmc` has 100 minutes at depth 24. The L1D, store and
hit-port allowances match in the SBY configurations and the runner.
Individual SBY tasks can set shorter limits.

The following data and store BMC allowances round twice the measured
runtime up to five-minute increments. Measurements ran beside one other
formal job. Word variants share their word-0 representative's allowance;
the listed L1D store-data BMCs keep depth 40.

| Target | Task | SBY and runner timeout (seconds / minutes) |
| --- | --- | --- |
| `coherence_l1d` | `coh_l1d_data_bmc`, `coh_l1d_data1_bmc`, `coh_l1d_data2_bmc`, `coh_l1d_data3_bmc` | 3,900 / 65 each |
| `coherence_l1d` | `coh_l1d_multi_data0_bmc` through `coh_l1d_multi_data3_bmc` | 4,200 / 70 each |
| `coherence_l1d` | `coh_l1d_store_payload_bmc` | 900 / 15 |
| `coherence_l1d` | `coh_l1d_store_grant_bmc` | 1,200 / 20 |
| `coherence_l1d` | `coh_l1d_store_multi_payload_bmc` | 1,800 / 30 |
| `coherence_l1d` | `coh_l1d_store_multi_grant_bmc` | 3,600 / 60 |
| `coherence_l1d` | `coh_l1d_ways_data_bmc` | 5,100 / 85 |
| `coherence_store_boundary` | `bmc_amo_same` | 3,300 / 55 |
| `coherence_store_boundary` | `bmc_amo_other` | 4,800 / 80 |
| `coherence_store_boundary` | `bmc_sc` | 3,600 / 60 |
| `coherence_store_home` | `bmc_siblings` | 1,800 / 30 |
| `coherence_store_home` | `bmc_rows` | 2,100 / 35 |
| `coherence_store_home` | `bmc_conflict` | 2,400 / 40 |
| `coherence_store_home` | `bmc_pressure` | 2,700 / 45 |

CI assigns the CSR profiling-on, CSR profiling-off and reorder-buffer tasks
to separate jobs with 120-minute limits. These jobs also run selected
local-atomic tasks, and the CSR profiling-on job runs the L1D local ownership
proofs. The hart maintenance proof, its ownership induction, the scripted
and store-free eight-endpoint L1D stream control BMCs, and their independent
unbounded payload proof share a job with a 330-minute limit.
The free-input stream BMC with stores shares a 330-minute job with the
four-way hit-port array BMC. The four-record boundary BMC and the
intervening-load boundary BMC each have a 330-minute job of their own.

The L1D control job runs `coh_l1d_bmc` alone with a 200-minute limit, and
the L1D multi-endpoint job runs `coh_l1d_multi_bmc` alone with a 330-minute
limit. The L1D zero multi-endpoint job runs `coh_l1d_zero_multi_bmc` alone
with a 330-minute limit. Three Coherence L1D data jobs run the four single-endpoint word tasks
(330 minutes), the four multi-endpoint word tasks (330 minutes), and the
payload, grant and four-way data tasks (270 minutes). Their task allowances
sum to 260, 280 and 210 minutes, respectively, at most 85% of each job.
The L1D and bridges job runs the remaining L1D tasks and AXI bridge targets
with a 330-minute limit. The scheduled local real-array checks run in
three parallel 30-minute jobs: `coh_l1d_local_data_bmc` checks arbitrary-byte
preservation and deferred probe data; `coh_l1d_local_hold_bmc` checks the
grant multiplexer, local image, load payload and reply holds; and
`coh_l1d_local_control_bmc` checks every remaining assertion. Each uses
ABC BMC3, keeps depth 80 and its 1,200-second SBY limit, and assumes
nothing from the other partitions. Data and hold use CaDiCaL; control uses
BMC3's default solver. Fast tests require the same
model as the scheduled local cover, complementary assertion selections,
and exactly one CI job per task.

The 42-cycle scripted stream checks are also partitioned: `coh_l1d_stream_bmc`
keeps every assertion except four wide payload identities and holds, which
`coh_l1d_stream_hold_bmc` checks. Both retain the original scripted model,
interface assumptions, depth 42 and 3,600-second limit, with no assumptions
between groups. Fast tests enforce that match and complete property coverage.
The hold task uses CaDiCaL in a parallel 75-minute job; the control task stays
in the hart maintenance job with BMC3's default solver.

The free-input, no-store stream checks use the same partition at depth 24:
`coh_l1d_stream_free_nostore_hold_bmc` checks those four payload holds in a
parallel 75-minute job, and `coh_l1d_stream_free_nostore_bmc` keeps every
other assertion in the hart maintenance job. Both retain the original
no-store input constraint and 3,600-second limit. The fast model tests cover
both stream variants and reject extra assumptions, cutpoints and input ties.

The independent `coh_l1d_stream_outlier_prove` also proves all four shared
payload assertions without a depth bound. Its free-input, stores-enabled
model includes the scripted and no-store specializations; none of the BMCs
assumes its facts. Each stream control BMC retains 322 assertions, and the
payload tasks retain the complementary four. Count guards require all 326
checks before selection. Fast tests pin the complete contracts, source
specialization, registration, shard membership and allowances.

The store-boundary AMO flow job runs `bmc_amo_same` and `bmc_amo_other`
with a 180-minute limit. SC, owner, fatal, load and cover tasks share the
240-minute store-boundary job. The store-home job runs its four BMCs and
covers with a 240-minute limit. For these store jobs, the measured BMC
allowances plus twice main's remaining case times use about 75%, 74% and
73% of the limits, respectively. Two coherent-array equivalence jobs run
the `coherence_array_equiv` tasks, the five four-way tasks in one and the
other eight in the other, each with a 120-minute limit. The Coherence job
runs the other coherence tasks, including the hart maintenance covers,
with a 240-minute limit. The Other tasks job has a 240-minute limit.
Job limits include image setup.

`coherence_store_boundary:bmc_four` runs to depth **114** with the L1D hit
path. The depth-120 sizing run reached frame 117 before its 18,000-second
timeout; frame 113 took about four hours beside one other formal job.
`cover_four` keeps its depth of 120 and reaches the handoff cover at frame
57 and the drain cover at frame 92, leaving at least 22 frames before the
BMC depth. Restoring the BMC to depth 120 is an open
[verification item](../ROADMAP.md#verification).

The CI jobs collect `tests/test_run_formal.py` and
`tests/test_pa_bridge_mutation.py` through `./scripts/frost.py run pytest`
with `-m formal` and a task filter. The two AXI address-truncation mutation
checks run in the Other tasks job. To inspect a job's selection without
running the solver, add `--collect-only -q` and its `-k` filter. The
`./scripts/frost.py pytest` shortcut collects only cocotb tests.

The CSR BMC tasks use depth 20 and the ROB BMC task uses depth 12. The hart
maintenance composition uses ABC PDR with depth 32 and assumes 284 facts
proved by an independent 8-step induction on the same model. The induction
has a 20-minute SBY and runner timeout and assumes no properties from the
composition task. The maintenance covers use depth 160 and a
20-minute SBY timeout. The runner's timeout controls wall-clock allowance;
proof depths and engines come from each SBY file.
`--verbose` prints solver output, and timeouts retain the last 40 captured
log lines. SymbiYosys writes logs and any counterexample trace to
`formal/<target>_<task>/`, which
git ignores. Formal values are two-state, so these checks do not cover X or Z
behavior in simulation.

## Two kinds of target

Property targets check a module's own assertions, usually with `bmc` from
reset to a fixed depth plus `cover`, and a few with an unbounded `prove`. The
module's `assume` statements model its inputs, usually a reset on the first
cycle followed by a legal input protocol. The tables note the assumptions and
limits most likely to matter; the module's `ifdef FORMAL` block states its
full environment.

Equivalence targets check logic that is written in a restructured form to
meet the 322 MHz CPU clock: computed ahead for each value of a late signal,
split into parallel scans, or built from Xilinx LUT primitives. The proof
keeps a plain reference expression beside the fast one, under a proof define
in the module (for example `SQ_LIVE_COUNT_LOCAL_PROOF`) or in a harness here,
and asserts that the two are equal. Unless a table says otherwise, these
targets make no assumptions. Inputs are arbitrary on every cycle, registers
start in arbitrary state, and the scripts cut out RAMs and submodules whose
contents don't matter, which leaves their outputs arbitrary too. Most run as
depth-1 BMC. Because the start state is unconstrained, that single step
covers every state, reachable or not, so it proves a combinational or
next-state identity outright rather than to a bound. Many scripts also pin
the number of assertions with `select -assert-count` and reject assumptions
and initial values with `select -assert-none`, so a proof cannot pass with
its properties compiled out.

### Primitive twins

The FPGA build defines `FROST_XILINX_PRIMS`, which swaps portable logic for Xilinx
LUT, MUXF, FDRE and CARRY8 instances. Simulation, most formal tasks and the ASIC
flow compile only the portable branch, so nothing else would notice the two
drifting apart. A primitive-twin target (`*_twin.sby`, plus the `xilinx` tasks in
the older pins proofs) compares them directly. Its script reads the module twice,
once as shipped and once with the macro defined and Yosys's `xilinx/cells_sim.v`
primitive models, flattens both (memories become registers, enable and reset
flops are unmapped), and pairs registers and nets by name with `equiv_make`.
`equiv_simple` then proves that every equivalence point whose cone holds a
primitive cell has the same value in both forms, for any input and any state in
which the paired registers agree. A register that `equiv_make` cannot pair by name keeps independent
state in the two copies, and any compared point that depends on it stays unproven
and fails the task. Undefined constants are set to zero in
both forms and initial values are dropped, so the comparison is two-state.
Cells that come from the primitive models carry a `from_prim` attribute so the
selection follows the primitives and not a hand-written signal list.

Each task also fixes a floor on the number of points it compares with
`select -assert-min`. A primitive whose output folds to a constant leaves no cell
to find, and the floor turns that into a failure instead of a pass over nothing.
Change the floor when an RTL edit adds or removes compared signals. A twin task
passes the placeholder design in `prim_twin_done.sv` to SymbiYosys after the
comparison, because the comparison itself runs in the Yosys script and ends in
`equiv_status -assert`.

`tests/test_prim_twins.py` lists every `FROST_XILINX_PRIMS` block in `hw/rtl` and
fails on one that no registered check covers.

CI runs these comparisons in a formal shard of their own, `Primitive forms`,
which takes the `*_twin` targets and the read select's `xilinx` tasks.

## Targets

Grouped by area; `--list-targets` shows each target's tasks.

### Fetch and branch prediction

| Target | Checks |
| --- | --- |
| `branch_prediction_alias` | The slot-1/slot-2 alias output computed from the base PC equals the generic computation under the fetch stage's base+2/base+4 wiring. Only this output is compared |
| `branch_prediction_disable` | The prediction-use gates for both slots, slot 2's target select, and the metadata next state equal the reference equations, disabling prediction blocks both the live and the staged path, and the slot-2 targets' relations to the pending PC equal direct compares |
| `slot2_prediction_capture` | A staged candidate and its payload share the first-stall capture edge and remain stable during the stall. Replay requests need a valid capture, consumption requires release, and reset or recovery cancels the capture. Assumes an initial reset; packet ownership is supplied by IF's replay input |
| `backing_btb` | At 8 entries in two and four ways, with arbitrary lookups, packets, updates, refreshes and resets after an initial reset: each slot's hit, size, return type and target equal a lookup of a mirror of the sets at the slot's own PC, so both lookup images and the update array match every write, image 1 one set ahead; a slot 2 in the word after the last set and every read during reset or the sweep miss; a request in stage B holds its set's current value and one in stage C its current entries; a refresh changes only replacement state; and every cleared set holds each valid tag once. The `prove` tasks prove the training invariants for all reachable states, with training reading the mirror in place of the update array |
| `btb_pending_relation` | Slot-2 relation selection matches the raw per-candidate target at 1/3/8 index bits, including arbitrary payloads, controls and uncovered rows; supplies the relation contract used by `branch_prediction_disable` |
| `btb_tag_compare` | Grouped BTB lookup and update tag compares equal full-width tag equality, for the 256-entry BTB and a 16-entry one, with arbitrary RAM outputs |
| `c_ext_buffer_next` | The compressed-instruction buffer's next state equals the reference clear/capture/hold priority |
| `pd_backing_redirect` | `pd_stage` with arbitrary packets, backing BTB results and pipeline control after an initial reset. A backing redirect fires only for its slot's registered JAL or JALR of the entry's size, with that slot's fast-taken prediction, bubble and fetch fault clear; a slot-2 redirect has a valid slot 2; a push or pop comes only with the redirect of a call or return, and a refresh names the redirecting slot's PC. The qualified redirect, its direction and its full-width target equal PD's reference models, and a backing redirect whose entry type matches its instruction takes the decoded-rule target. PD's simulation checks run only when their operands are known, which Yosys evaluates as false, so the formal block restates them. Assumes that IF's RV64C expansions and target candidates match the packet's instruction, that a slot-2 backing hit lies in slot 1's 4 GiB region, as `backing_btb` checks, and that a valid slot 2 follows a slot 1 that is not a conditional branch |
| `c_ext_state_cofactor` | The same next state with the pending-prediction handoff split out equals the reference, and a handoff never keeps old-path buffer state |
| `control_flow_holdoff` | Redirect and reset holdoff next state equals the reference equations |
| `debug_fetch_barrier` | GO follows a sampled invalidation, preserves the captured target, and cannot replay after acknowledgement. Withdrawal cancels GO, reset clears pending work, and a held request reaches GO. Assumes an initial reset and acknowledgements only for presented GO requests |
| `debug_go_pipeline` | The Debug Module's registered GO identifies one command or resume source, holds its target while unacknowledged, and clears on acknowledgement or module reset. The sequencer leaves GO on acknowledgement, and a pending source reaches the output. Assumes an initial reset and acknowledgements only for presented GO; the proof covers the GO stage and sequencer, not the hart or slice writer |
| `early_backend_hold` | After the first edge, the combined backend hold equals the early-recovery hold OR independently sampled fatal stop, for arbitrary inputs and initial state. Reset, flush and overlapping fatal/recovery requests are covered. Unbounded, with no input assumptions; the proof covers the hold registers, not the branch-resolution contract |
| `fetch_shadow_capture` | The DDR fetch buffer's eviction shadows hold the same pending tags and payloads as a capture on the slot-write enable, and a per-word slot install writes what a whole-slot install would. Default, one-entry, and no victim store. Grouped direct-cache writes match whole-line captures, including invalid entries after their first write and coincident clears or errors. In the four-entry direct configuration, hit comparisons match complete stored tags under the asserted valid-entry index invariant. Banked word selection matches independent line reads, including line-crossing windows; assumes an initial reset and fill responses that match outstanding requests |
| `fetch_pc_mux` | The next-fetch-PC mux equals the reference priority, for portable and Xilinx-primitive builds, standalone and integrated (`bmc_integrated*`). The proof reads `i_slot2_prediction_used_for_pc` where the mux reads its own copy, `i_slot2_prediction_used_for_fetch_mux`; simulation checks they are equal |
| `served_window_coverage` | Fetch-window coverage equals full-address comparisons for every packet/buffer case, with 30/62-bit word tags and portable/Xilinx implementations |
| `fetch_redirect` | The registered fetch-redirect pulse equals the reference priority equation; bounded and unbounded |
| `pc_redirect_catchup_producer` | In the PC controller, the catch-up and default arms are both sequential, and catch-up never coincides with a pending-hold request; unbounded at XLEN 32, 64, and 66 |
| `pc_redirect_catchup_consumer` | Given those producer properties, leaving the catch-up request out of the registered redirect detector does not change its output; unbounded |
| `if_direction_payload` | Dropping the NOP term from the branch-direction payload select changes no non-NOP packet, including stall replay through the real `stall_capture_reg`. Assumes a flush on the first cycle |
| `pc_holdoff_cofactor` | The three fetch-holdoff outputs equal their reference equations |
| `pc_holdoff_tag` | A pending prediction's predecessor-PC tag equals its PC minus 2, and outside reset the prediction holdoffs equal their reference equations; unbounded at XLEN 32, 64, and 72, including wraparound. Assumes the pending bit starts clear |
| `pc_increment_relation` | The local carry relations behind the PC +2/+4/+6/+8 compares, and the relations of `pc_reg` and of the sequential next `pc_reg` to the pending and fetch PCs, equal full-width arithmetic at XLEN 32 and 64, including wraparound. The next `pc_reg`'s relations come in two versions: as selected without the served-window check, and as a NOP |
| `pc_increment_holdoff` | Both sequential next PCs equal the reference per-size candidates with holdoff and NOP selection, and the sequential next `pc_reg`, its miss and pending relations, and their pinned selects equal their portable form, for portable and Xilinx-primitive builds |
| `pc_pending_capture` | The pending-prediction valid bit's next state equals the reference clear/set/hold priority, for both `PENDING_HANDOFF_EXCLUDES_SLOT2` settings |
| `pc_register_mux` | The architectural-PC mux equals the reference priority, and the parallel advance select and pinned selects of the registered `pc_reg` relations equal their portable form, in the same configurations as `fetch_pc_mux` |
| `prediction_handoff` | `prediction_release` with `PENDING_HANDOFF_EXCLUDES_SLOT2=1`, the fetch stage's setting |
| `prediction_metadata_output` | Each packet's BTB-taken bit equals the reference priority, and a packet that a saved or pending prediction does not belong to never reports taken |
| `prediction_metadata_tracker` | A pending prediction's saved PC and target hold until their packet consumes them or a reset or redirect kills them, and call and return types always leave with their target. See below |
| `prediction_release` | Pending-prediction outputs are masked while nothing is pending, a ready handoff raises both prediction holdoffs, and the holdoffs, predecessor-PC tags, and lower-parcel lookup match their reference relations. Whenever a prediction will be pending, the registered `pc_reg` relations load next cycle's wide-compare values. In `bmc`, the instruction buffer takes only `pc_reg`'s word. See below |
| `ras_checkpoint` | The return-address stack's outputs, next pointer, and count equal the reference equations, and so does every entry write: a push or swap writes its link address, a restore writes the saved top entry back, and nothing else changes |
| `rvc_predecode` | The fill-time RV64C expansion and illegal flag equal the reference decompressor (`rvc_decompressor`) for all 65,536 16-bit parcels |
| `branch_predictor_twin` | The branch predictor's slot-2 payload and relation selects (LUT6 per bit) equal their portable form. Portable and Xilinx-primitive builds are compared with Yosys equivalence checking (see Primitive twins); the primitive form of every LUT in the cone equals the portable form for any state and input |
| `pc_controller_twin` | The fetch-PC mux, architectural next-PC mux, pending-relation selects, the sequential-PC calculator's selects and relations, and the control-flow tracker's halfword step equal their portable forms, with and without the slot-2 pending-handoff exclusion. Portable and Xilinx-primitive builds are compared with Yosys equivalence checking (see Primitive twins); the primitive form of every LUT in the cone equals the portable form for any state and input |
| `control_flow_tracker_twin` | The tracker's halfword-next LUT6 equals its portable form |
| `pd_target_candidate_twin` | The predecode target adder (CARRY8 with LUT2, LUT3, LUT5 and LUT6 helpers) and its saved-XOR select equal their portable form |

`prediction_release` runs the real `pc_controller`, `c_ext_state`, and
`slot2_prediction_capture` together. The harness replaces the PC-increment calculator with one whose PC
outputs are unconstrained, which admits every real PC movement and more, and
makes predictor requests arbitrary. The stand-in's next `pc_reg` is one of two
unconstrained values, the NOP one when the NOP select is set, and its
pending-PC relations are full-width compares of those values, which
`pc_increment_relation` proves the real calculator matches. The harness likewise relates both slot-2 targets to
the pending PC by direct compares, as `branch_prediction_disable` proves the
predictor does. A staged candidate captures those relations with its target
and the saved packet. Replay can redirect during registered stall, including
release without a live response. Assertions check the saved packet PC and
pending-PC relations throughout the held candidate's lifetime. Replay
permission gates the capture outputs without changing its state. Derived
invariants check the registered prediction metadata and the pending-PC
relation and crossing replicas. Reset and recovery cancel the candidate.
`c_ext_state` gets the raw window mismatch and a squash that includes it, as
in the fetch stage. Each live word it sees carries an identity: `pc_reg`'s
word when the window covers `pc_reg`, an arbitrary word otherwise. The `bmc`
task checks that whenever the instruction buffer is valid holding a word it
has just taken, the word is `pc_reg`'s, or on a stall replay the snapshot's.
The check is bounded only: the snapshot word is internal to `c_ext_state`, so
induction could start from a snapshot that does not match its PC.
The harness assumes only a reset on the first cycle.
`prediction_handoff` runs the same harness with the fetch stage's parameter
setting. Both have `bmc`, `cover`, and SMT k-induction `prove` tasks.

`prediction_metadata_tracker` models the registered predictor target, which
may change while fetch runs and holds during a stall, and leaves the pending
and output PCs arbitrary (8 bits wide), so the proof covers both the packet a
prediction belongs to and an older packet at another PC. It assumes a reset
on the first cycle and three rules the fetch stage guarantees: saved values
are replayed only during a registered stall; the live target is used only
when it is aligned with the output packet and no stall, registered
prediction, or pending prediction exists; and a reset cycle inserts a NOP and
uses no metadata. Each call and return type is tied to its target's low two
bits, so a type taken from a different source than its target would show.

### Decode, rename, and dispatch

| Target | Checks |
| --- | --- |
| `decoded_bundle_queue` | FIFO order and payload against an independent queue model, unbounded, at depths 4 and 2 (`prove_depth2`), with covers for bypass, full, wraparound, simultaneous push and pop, and flush of a nonempty queue. See below |
| `dispatch_admission` | Bundle, slot-2, station and checkpoint admission equal the reference equations, and a firing slot 2 never reads FP source 3 (so done-repair channel 6 stays idle). Assumes only FP_RS ops read FP source 3, which `instr_operand_classifier` checks. `bmc_queued` uses the CPU's `SLOT2_VALID_FROM_BUNDLE=1` and assumes the queue's slot-2 valid rule |
| `instr_operand_classifier` | Decode's operand-class fields equal classification through the decoder's operation enum for every instruction bit pattern, injected NOPs, illegal flags, and fetch faults; only FP_RS ops read FP source 3 |
| `register_alias_table` | x0 is never renamed; a rename records its ROB tag; an INT commit clears a mapping only if the mapping still holds the committing tag; reset clears mappings and checkpoints; a full flush clears the checkpoints and, unless a checkpoint restore coincides, the mappings; a reclaim-all restore frees every checkpoint |
| `decoded_bundle_queue_twin` | The producer stall select and the shadow-next select (LUT3, LUT5 per bit) equal their portable form with the split shadow stall and four late copies |

`decoded_bundle_queue` uses an 8-bit symbolic payload, so the check does not
depend on decode fields. It also covers the registered head copy and a 3-bit
registered shadow tied to the payload's low bits. It assumes an initial
reset, pops only of a valid bundle, no producer overwrite before acceptance,
and that the announced next shadow value (`i_shadow_next`) arrives on the next
cycle; simulation asserts the last three. The split shadow select that
`cpu_ooo` enables (`SPLIT_SHADOW_STALL`) is checked in simulation only.

### Reservation stations and the Tomasulo wrapper

| Target | Checks |
| --- | --- |
| `mem_wakeup_merge` | An early load wakeup keeps both registered CDB broadcasts and takes at most one idle lane. Assumes the load's tag is not on a valid registered lane, which `tomasulo_wrapper` asserts |
| `reservation_station` | Dispatch, wakeup, issue, and flush properties at the module defaults and with the INT station's features. See below |
| `rs_alloc_parallel` | The parallel search for the first and second free entries equals the serial search at depths 4, 8, 16, and 32 |
| `rs_divide_gate` | MUL_RS's divide gate against a divider model that is busy from the cycle after a presented, unsquashed divide until an arbitrary later cycle: a divide in stage 2 never coexists with a busy divider; unbounded |
| `rs_dispatch_defer` | Dispatch's six CDB-deferral decisions equal the reference equations, with and without insertion-time repair (`bmc_repair`) |
| `rs_issue2_selector` | The second issue port's balanced selector equals a serial scan at 16 entries |
| `rs_indexed_deferred_fold` | In allocation-indexed stations, the allocation tokens are one-hot and cover every pending delivery, and the shared repair/deferred buses and factored selects give the same write enables and data as the serial priority; unbounded at the INT, MEM, and MUL sizes and with three sources. It removes the payload RAMs and output logic, so it covers the write decisions, not the whole station |
| `rob_link_value_ram` | The three-bank ROB value memory equals the four-bank one under the one-branch-allocation rule and, for head ports, one-hot read addresses; unbounded at 32 x 64 |
| `rob_link_dispatch` | Dispatch never allocates slot 2 behind a slot-1 branch, the rule the shared link bank needs, in all four bundle-valid and register-value configurations |
| `sq_live_result_select` | The early store address and MMIO flag equal the reference priority with the live CDB sums selected last |
| `rs_primary_payload` | INT_RS's grouped port-0 payload read, address, and entry clear equal indexed selection at depths 4, 8, and 16; an unbounded proof compares grouped payload RAMs and opcode registers with a single RAM |
| `rs_issue_clear` | The second issue port's one-hot entry clear equals the indexed clear, for single and dual issue at several depths and with the INT station's window |
| `rs_pretag_cofactor` | The pre-issue ROB tag, computed for each combination of the two CDB valid bits, equals the reference priority select in two station configurations; the export tasks also check the candidate ready vectors |
| `rs_raw_pretag` | With the real early-wakeup merger, the MEM station's look-ahead candidates and ready vectors agree with its issue winner |
| `rs_lq_prematch` | MEM_RS and the LQ connected through the real merger and translation select: every candidate match and the registered selected match equal a direct tag CAM; bounded and unbounded |
| `tomasulo_wrapper` | The back end together (ROB, RAT, four stations, CDB arbiter, and memory queues): commit clears a rename only if no newer write renamed the register, a full flush or reset empties every structure, each station's copy of the CDB matches the bus, and the stations' ROB-tag rule holds with the real ROB allocator. See below |
| `reservation_station_twin` | The indexed source-write selects (LUT5 and LUT3) in the INT-station configuration equal their portable form. Portable and Xilinx-primitive builds are compared with Yosys equivalence checking (see Primitive twins); the primitive form of every LUT in the cone equals the portable form for any state and input |

`reservation_station` checks the module's default parameters at BMC depth
12; no production station uses exactly those defaults. The `*_tag_indexed`
tasks turn on the INT station's features at 8 entries, with BMC depth 7. Both
have depth-20 cover tasks. Standalone, the station assumes a reset, a legal
dispatch environment (for example, no dispatch during a partial flush or into
a full station), and, for the INT features, that a dispatched ROB tag is not
already live in the station and that two dispatches in one cycle carry
different tags. The deferred CDB delivery checks stop short of the final
write of the broadcast value; directed cocotb tests and simulation assertions
cover that step.

`tomasulo_wrapper` replaces those assumptions with the real allocator. It
builds every station with `FORMAL_STANDALONE_ENV=0`, which keeps the
station's assertions, drops its standalone assumptions, and turns the tag
rule into an assertion. The INT station has its real 16 entries and 8-entry
second-issue window. Dispatch uses the single-slot bus
(`SPLIT_RS_DISPATCH=0`), so no station receives two dispatches in one cycle;
the standalone `reservation_station` tasks cover that case. Besides a reset
and legal back-pressure, rename, and checkpoint inputs, the environment
assumes that dispatch comes with an allocation and uses that cycle's ROB tag,
that a partial flush names a live ROB entry, and that address translation is
off (the `tlb` and `ptw` targets and `vm_test` cover translation). At depth 4
the proof does not reach ROB tag wraparound; simulation covers tag reuse.
`fp_repair_bmc` enables the FP dispatch done repair, as the CPU does, and
assumes the repair channels carry the pending FP instruction's source
readiness and tags.

### Load and store queues

| Target | Checks |
| --- | --- |
| `load_queue` | Allocation and back-pressure, dependency cleanup, memory issue, router cancellation, staged AMOs, and CDB broadcast, with busy-port load preparation on and off (`*_no_prepare_busy`). Uses the module defaults (`lq_prematch_cofactors` and `lq_ram_payload` check the CPU's pre-issue compares and store forwarding) and assumes each address update follows its look-ahead and live entries hold distinct ROB tags. `prove_pre_match` proves the split pre-issue match registers equal a direct registered compare |
| `load_queue_amo_compute` | AMO capture of operands and memory tier, the result of every AMO except MIN and MAX (which `load_queue` checks), kill on reset or flush, coherence blocking, and stable write data, over 4 cycles. See below |
| `lq_alloc_mask` | The parallel first and second allocation masks equal the reference search and capacity checks at depths 4, 8, and 16 |
| `lq_cached_flags` | Cached-slot invalidation and LR-suppression next state equals the reference priority equations |
| `lq_cached_hold` | Cached-slot hold next state equals the reference reduction over the full slot mask |
| `lq_capacity` | The full and full-for-two flags equal comparisons of the entry count |
| `lq_l0_cache` | The L0 cache at 128 and 256 entries: MMIO never hits, a hit needs a valid matching tag, an admitted fill then hits with its data, byte-enabled store updates replace exactly the selected bytes and preserve the others, and flush/DMA invalidation clears entries. Store updates take priority over fills; AMO/DMA invalidation overrides them. The balanced store/AMO tag comparisons and preselected update-invalidation predicates equal their direct reference expressions. Store and AMO invalidation reachability is covered |
| `lq_l0_lookup` | Valid-bit selection and permission equal direct indexed lookup for arbitrary valid bits, index and invalidation inputs at 8, 16, 32, 128, 256 and 512 entries. Portable and primitive (LUT6 with MUXF7, MUXF8 and MUXF9) implementations are proved without state or assumptions |
| `lq_prematch_cofactors` | Every candidate match and its registered selection equal a direct tag CAM, for candidate-tag inputs, ready-vector picks, translation, and idle entries; bounded and unbounded |
| `lq_ram_payload` | The load-result RAM's two write ports and the CDB value mux equal the reference priority, in the default, store-forwarding (`bmc_forward`), forwarding-without-L0 (`bmc_forward_only`), and CPU-settings (`bmc_core`) builds. The CPU settings enable response errors, Normal-memory caching and pre-issue ready selection. Also shows that a cache hit never coincides with a staged AMO at the ROB head |
| `lq_capture` | Monotonicity holds for the capture and clear producer choices. Coherent capture enables, clear decisions, completion validity, bypass eligibility, entry release, and staged control next state equal the reference for arbitrary current state at depths 4, 8, and 16. Forwarding and L0 variants and the primitive implementation are included; result validity, allocation, sector matching and memory launch equal their reference equations |
| `lq_age_groups` | Entry eligibility and grouped age selection equal their direct equations for every pin-input combination, including tails padded with zeros, in portable and primitive implementations |
| `lq_capture_pins` | Capture-class, in-flight-mask, bypass-source, entry-release, staged-match, ring-gather and candidate-source choices equal independent Boolean references for every pin-input combination; portable and primitive implementations |
| `lq_result_valid` | Every entry's result-valid next-state wire and register D equal the completion and allocation reference equations for arbitrary current state and inputs at depths 4, 8, and 16. Eight-entry tasks also cover disabling either or both of forwarding and L0 completion, and the primitive LUT implementations. Acceptance implies not-drop through the DUT producer equations. RAM outputs and register state are unconstrained; the DUT supplies all combinational control relationships |
| `lq_result_pins` | Local-completion, response-acceptance and allocation LUT INITs and portable equations equal independent references for every pin-input combination |
| `lq_sector_copy` | The staged load's registered sector and holder matches equal its entry's registered matches at `sq_check_idx` after every edge, from any state, for arbitrary takes, raw address matches and stored sectors; candidate source/index and entry/staged match producers remain connected; portable and FDRE index cells; unbounded |
| `lq_replace_select` | The staging register's replacement decision equals the reference ROB-head and ring-position comparison at depths 4, 8, and 16 |
| `lq_response_bypass` | The load-response bypass pulse equals the reference pulse qualified by full acceptance; the separate partial-flush guard makes the reference's age comparison redundant |
| `lq_tag_order` | ROB-tag age order and the full-window boundary equal the reference computed in wider arithmetic, for all tags |
| `sq_committed_empty` | Committed-empty next state equals the reference over full flush and registered and same-cycle commits. All four final outputs include pending coherent stores, the selected SC write and an arriving cached write |
| `sq_live_count` | The live store count's next value equals the reference arithmetic for each allocation outcome |
| `sq_repair_mmio` | The early-address repair's two parallel MMIO flags equal MMIO classification of the full base-plus-immediate sum, including overflow |
| `store_queue` | Live-count consistency, write prerequisites (committed, address and data valid), in-flight bounds, forwarding, and that committed stores survive a partial flush. A cached cbo.zero entry leaves as one write at its block base, marked for the L1D and for a block-wide L0 invalidation, and that write completes it. An uncached entry's beat count belongs to the drain cursor's unsent zero entry; each zero beat writes eight zero bytes with every strobe inside the entry's block, and only the eighth beat completes the entry. Formal builds use a linear forwarding selector in place of the balanced tree, which Yosys mishandles, so the tree itself is not proved. Assumes, among other input rules, no allocation while the post-flush tail pullback is pending and no combinational commit pulse during a flush |
| `store_queue_twin` | The write launch, write completion, in-flight special and final selects equal their portable forms |

`load_queue_amo_compute` starts from arbitrary state, with no reset or
admission assumptions, so it includes AMO states the queue cannot normally
reach. It makes no claim about scheduling, interrupts, or liveness. Its
script counts the named checks it relies on (`p_local_*`, `cover_local_*`,
and `p_lq_*_free_tree_*`): adding or renaming one of those means updating the
count.

### ROB, CSRs, traps, and recovery

| Target | Checks |
| --- | --- |
| `csr_commit_cofactor` | Stored CSR state other than `mstatus`, `mie`, `fflags`, and `frm`, architectural counters, and the translation-invalidate request equal a reference model of reset, trap and Debug Mode entry, DRET, and CSR writes after each edge, from arbitrary state; the `mstatus`, `mie`, and privilege next state equals the reference's for the same current state. The trap unit's entry enables must match its trap inputs. Unbounded. `prove_integrated` and `prove_perf_off` use the CPU's setting, in which a CSR commit never coincides with a trap or xRET |
| `csr_sscofpmf` | Sscofpmf, per HPM counter 3..10: OF is sticky, set on a wrap and changed only by a wrap or an `mhpmevent` write; a counter write installs the CSR result and never overflows; otherwise the counter adds its staged count and the wrap is exactly the 64-bit unsigned overflow; `mcountinhibit`, a deselected event, a counter write, or the xINH bit of the event's privilege stage zero, and an uninhibited event stages its input, with inhibition reconstructed independently from sampled xINH bits and event privilege; an independent classification gives counters 3, 4 and 10 the previous cycle's privilege; `mhpmevent` writes install OF, xINH and the selector; VSINH, VUINH and WPRI read zero. Each request is exactly a wrap with old OF clear, and their independently referenced OR registers once. LCOFIP equals a software write through `mip` or delegated `sip`, or its old value, with the registered hardware request taking priority. Unbounded, from arbitrary state, with no assumptions; `prove_integrated` uses the CPU's commit setting, and `prove_perf_off` also disables the profiling counters while retaining architectural HPM behavior |
| `csr_file` | AIA indirect-register legality, one-hot select storage, write-intent claims, virtual pending aliases and exact major-interrupt priority; CSR and privilege updates on traps, xRETs, and debug entry and exit, plus counters, `fflags`, and FS state, with the profiling counters present and absent (`bmc_perf_off`). Assumes traps, xRETs, and CSR writes never coincide, FP-state updates never coincide with a CSR write, privilege and debug transitions are legal, the entry enables match the trap inputs, and trap PCs are 2-byte aligned |
| `mispredict_capture` | The pending recovery payload matches a capture gated by a mispredicted commit. The frontend recovery copy matches the recovery pulse, and the frontend flush matches the pipeline flush; bounded and unbounded |
| `reorder_buffer` | Occupancy and pointers, allocation into free entries, commit only of a done head, serializer control of traps, fences, CSR writes, and translation drains, and flush and reset. Assumes legal dispatch and completion traffic, including no CDB completion for an entry allocated the previous cycle or for a head the serializer holds, no branch allocation of a serializing class, and a held-result mask (`i_result_held`) that marks at most one entry and a done one only if it is an unexceptional branch (simulation checks the same contract). Depth 12 does not reach a full buffer with pointer wraparound |
| `rob_alloc_lvt` | The packed allocation-payload memory equals separate per-field memories; unbounded |
| `rob_bypass_control` | The head's completion bypass equals the OR of the per-lane bypasses, for arbitrary state and CDB inputs |
| `rob_control_next` | Per-entry valid, done, exception, and replay next state equals the reference indexed writes, including allocation coinciding with completion or commit, and stale tags |
| `rob_retire_ready` | Per-entry retirement eligibility (completion, two-wide, misprediction) equals the selected-field expressions, and both head masks stay one-hot; unbounded, assuming an initial reset |
| `rob_retire_stall` | Retirement strobes and every performance event equal a reference built from the serializer's full commit stall |
| `rob_start_cofactor` | CSR and xRET start signals equal the reference equations, the head mask stays one-hot, and CSR and xRET entries never take the CDB bypass; unbounded. Assumes an initial reset |
| `trap_unit` | Traps, interrupts, xRETs, and debug entry: mutual exclusion, priority (debug over M over S), current pending/enable/delegation for each winning cause (including LCOFI), targets, nothing taken while the pipeline is stalled, and waiting for committed stores to drain; the split trap-entry target and take outputs equal the reference ones. Assumes the start events are mutually exclusive. `prove` shows that `csr_file`'s entry enables equal the take and steering outputs, and that a post-CSR selection refresh cannot consume an architectural interrupt, from arbitrary state |
| `csr_file_twin` | The fetch-return privilege select (LUT6, LUT4) equals its portable form |

### Execution units and CDB

| Target | Checks |
| --- | --- |
| `alu_shift_hint` | An ALU given the precomputed shift amount matches one without it, and both match an independent shift and rotate reference |
| `cdb_arbiter` | The two-lane grant tree equals a reference priority scan. Grants are one-hot per lane, disjoint, at most two, and only to valid requesters, and a kill clears both CDB valid bits and the visible grants. Assumes the ALU value-source rule: a live value belongs to a valid completion and equals its value, and otherwise the fallback value does |
| `divider` | Results equal RISC-V division and remainder at 8 bits, including signed, unsigned, divide by zero, overflow and W forms (`bmc_width8`). At 64 bits, `prove_width64` proves setup and recurrence control, held completion and cancellation, unbounded. Arithmetic values and a global latency bound at 64 bits are outside that proof. See below |
| `fp_shim` | Busy exactly while the engine holds an operation, results only while busy and with the tag of the latest operation, a kill frees the engine on the next cycle, and no later result for an operation a flush squashed (a result in the flush cycle itself is the CDB adapter's to drop). The engine is replaced by a model with arbitrary latency, results, and flags. Assumes FP_RS issues only while the shim is not busy |
| `fp_launch_squash` | Both launch modes match a reference launch-gated shim, all with real FP engines: the same busy and completion valid every cycle and the same valid completions, with initialized integer-conversion stage registers in the inductive relation; unbounded, assuming equal initial state, no issue while busy, and, with `LAUNCH_SQUASH=1`, the bubble after a flushed issue |
| `fp_launch_squash_rs` | The real FP station with the wrapper's tie-offs leaves the bubble after a flushed issue that `LAUNCH_SQUASH` needs; unbounded |
| `fu_cdb_adapter` | Pass-through, hold under back-pressure with a stable payload, a clear on a grant with no new result behind it, on a full flush, or on a partial flush that squashes the held result, and no stale output after a squash. Covers the default combinational output, not `REGISTER_OUTPUT=1`. Assumes full and partial flushes never coincide |
| `fu_cdb_adapter_payload_no_refill` | The adapter with `ALLOW_GRANT_REFILL_PAYLOAD_WRITE=0`, as the ALU adapters use it. Assumes no result arrives while one is held, which the wrapper guarantees |
| `cl_multiplier` | All three result slices equal a full polynomial product over GF(2), with three registered stages and reset-cleared valid bits |
| `int_muldiv_shim` | Every tracked integer or carry-less multiply aligns with its unit pipeline. MUL FIFO credits hold under back-pressure and flushes. Carry-less tracker entries preserve the issue tag, and the FIFO input selects the carry-less result. For the divider: `o_div_busy` is high exactly while it is not idle, a completion carries the tag of the latest divide, a kill frees it on the next cycle, and a squashed divide never completes. Runs with the word multiplier on and off (`*_fallback`) and direct completion enabled (`*_direct`). Independent per-source live histories check exact surviving completions and tags through flushes and tag reuse. Direct output payloads select the aligned arithmetic result. Assumes a reset on the first cycle and divides presented only while the divider is idle. Arithmetic values, the FIFO output sequence, and liveness are out of scope |
| `mul_completion_tag` | Leaving the MUL result's tag unqualified on invalid cycles changes no adapter state, valid result, or arbiter input. Assumes one initial reset |
| `mul_adapter_grant` | With the real CDB arbiter, the MUL adapter's local grant and the always-granted MUL and MEM adapters produce the same completions and pending bits as stateful adapters, under arbitrary competing results, flushes, and tags; unbounded |
| `fp_engine_twin` | The normalisation any-bit and partial-select LUTs equal their portable form |

`divider` compares results with Verilog division at 8 bits, where division is
cheap for the solver; the divider uses the same RTL at both widths. A start
captures the operands and operation flags. Preparation and alignment initialize
the recurrence before it consumes them. The 14-cycle bound includes a complete
8-bit operation, with arbitrary operands, kills and accept delays inside that
window. The 64-bit `divider` simulation checks Python integer division and
cycle counts, including early termination and setup cancellation.

### Memory system and coherence

| Target | Checks |
| --- | --- |
| `cpu_axi_payload` | After either reset is sampled, an occupied R buffer equals a reference payload captured only on owned R acceptance. Unbounded at 64-byte data width and six-bit IDs, with arbitrary initial hardware state and no input assumptions. Covers read stalls, replacement, B arbitration, unowned responses and reset with a buffered read; ownership and drain correctness are outside this payload proof |
| `axi_coherent_bridge` | Safety properties of the AXI4 slave against a reference built from the AXI4 burst rules: B, R and the line request low after a reset edge, B and R held until accepted, at most one accepted B per AW, each presented B in AW order with its id and its code (the classification, or SLVERR after an ingress error on one of its lines), and only after its last W beat and every line write it sealed has been answered; R in AR order with its id and RLAST on beat ARLEN + 1, error bursts answering their code with zero data. Each line write carries exactly the bytes of its segment, each from the last beat that strobed it. For an arbitrary byte whose line every read response returns with one value and error bit, every R beat covering it returns that value or SLVERR. Line requests are aligned, inside the region, held until accepted, and use only ids not in flight. Unbounded: invariants tie the reference to the bridge's tables, W engine, assembly register, issue walker, segment queue, read buffer and ids, with induction depth 3. In formal builds the read buffer is a register array with `sdp_dist_ram`'s behavior, so the invariants can name its entries. `prove` and `cover` use 8-byte lines on a 16-bit bus with two bursts and two ids per direction, `prove_full_width` a 64-bit bus with one beat per line, and `prove_soc` `soc_top`'s 256-bit bus and 32-byte lines with four bursts and ids per direction; all with 16-bit addresses. `prove_soc8_0` through `prove_soc8_3` check all assertions with `soc_top`'s eight bursts and eight line IDs per direction. Every assertion is checked in one partition. All four tasks are required: each assumes only the preceding cycle's assertion results, so a first failure remains admissible in its owning partition. `bmc_soc` checks that capacity to depth 8. `cover_soc` reaches full read and write occupancy, pointer wrap, draining and reuse of every line ID. Its read traces hold RREADY low through full occupancy and a valid R response, return the last allocated line before the first, and reuse an ID while earlier requests remain live. The cover driver uses single-beat traffic; its restrictions apply only to covers. Assumes initial reset, an AXI master that holds its requests until accepted, and an ingress that answers only ids in flight, a cycle or more later. Eventual completion and starvation freedom are not proved; the `axi_coherent_bridge`, `axi_coherent_bridge_64` and `axi_coherent_bridge_32` cocotb benches check completion with timeouts, including reads under sustained writes |
| `axil_reg_bridge` | Unbounded AXI4-Lite channel stability, independent AW/W capture, response conservation, reset cancellation with nothing presented and no register write after a reset edge, aligned read pairs, and equivalence of write offsets, lane selection and wide-write enables to the SoC register expressions. `prove` uses the NIC bank, `prove_engine` the DMA bank, and `cover` exercises channel skew, partial wide writes, response stalls and reset. Assumes a master that holds each request until accepted |
| `axi_mux` | Unbounded, with three ports and with `soc_top`'s two: no READY or VALID on the request channels in reset; a downstream AW or AR handshake is exactly one port's handshake, with that port's payload and its index in the id's top bits; W beats come only from the port of the oldest AW granted whose beats are not all in; B and R reach the port their id names, with that port's READY; and the downstream VALIDs hold until accepted. Assumes masters that hold their requests until accepted and a slave that answers only bursts it accepted |
| `cache_mshr_payload` | Per-entry MSHR data and byte strobes equal the reference indexed fill and store merge, including fills that coincide with stores, on every byte that can be read, in a 256-byte cache with 8-byte lines |
| `coherence_store_buffer` | Four ordered combining records conserve accepted scalar stores, byte masks and acknowledgements under address-independent delayed launch credit. Unbounded induction checks a watched byte, sealed payload stability and the 32-contributor limit; covers full occupancy and simultaneous acceptance, sealing and installation. A 48-cycle case checks 33 writes to one younger byte behind a delayed head, saturation, successor allocation and complete ordered drain. A cbo.zero write's lower record and its twin hold the block's zeros, sealed: the twin follows its lower record, readiness stays low while it waits for a record, and the write's done follows its allocation; covers reach a twin waiting on a full buffer, a twin allocated beside a pop and a twin at the head |
| `coherence_read_stream` | Inductive three-miss confirmation, cancellation and cursor bounds at 56-bit physical addresses, with demands and second-input hits arbitrary; covers concurrent advance/consume, a second-input advance and page-end saturation |
| `coherence_store_boundary` | Reduced ordered stores, loads and atomics with production SQ, router, LQ and L1D; two LQ entries, eight L0 words, core preissue/forwarding controls and an externally supplied SC reservation. Checks acknowledgement routing, launch credit, drain and complete load values through 80 cycles, intervening-load values through 140 cycles, and atomic exclusion through retirement and release through 140 cycles. The four-record configuration uses three request endpoints and checks completion identities through 114 cycles; its depth-120 covers require a younger store grant before the head grant, followed by load completion or store and endpoint drain. Same-sector AMO checks require four tasks without cross-partition assumptions: flow, ownership, fatal persistence induction and a fatal-status check at frame 139. Different-sector AMOs require flow/ownership, fatal persistence and frame-139 tasks. The model resets once and has no environment assumptions. An earlier fatal sample persists to the final checked sample. Run the fatal checks through `test_run_formal.py`, which requires a completed frame-139 evaluation. Fast tests require both obligations in the registry and one CI shard per formal case. The same-sector prefix installs Modified data and covers local AMO release; it cannot reach the home write lookup without a probe or replacement. The different-sector prefix permits the second older store on either sector, covering both a resident target and a home acquisition. Its home cover reaches the AtomicWriteOp lookup and release. Covers also reach load staging at capture, acknowledgement, promotion and drain; the fence target checks maintenance ordering |
| `coherent_local_atomic` | Reduced production SQ, router, LQ, L1D, atomic guard and MEM completion path check local installation, reservation lifetime and bounded service through 100 cycles. LR creates the SC reservation; SC installation clears it. An unrelated same-set grant and invalidating probe compete with the local owner while a control-entry request is pending. The reduced program supplies translated, nonfaulting operands, ready prefix-store home channels and up to eight finite competing MEM completions, with no reset or fatal stop. Retirement eligibility is modeled with production hold equations; this is not a whole-CPU liveness proof. Covers local release, SC retirement before installation and control requests in each phase. Retirement and completion excerpts have source-equality checks |
| `coherent_local_owners` | Abstract two-owner contract proves exclusive Modified permission, installation before peer observation, and invalidation cuts for reservations and observations surviving private eviction. Assumes the shared home routes cuts to all CPU holders before conflicting permission; it does not instantiate a second hart or its routing |
| `coherence_l1d` | Control and store-data checks run through 40 cycles with one or three endpoints. Control checks also run with eight endpoints and look-ahead in eight tasks: a 42-cycle task that issues the stream cover's scripted loads with stores off and no replies for 24 cycles and arbitrary replies afterwards; a matching 42-cycle task for its four wide payload identity and hold assertions; a 32-cycle task with arbitrary inputs and stores that leaves out four assertions; two matching 24-cycle tasks with arbitrary inputs and no stores, one for the four payload holds and one for every other assertion; an 8-step induction with arbitrary inputs and stores that proves the read ownership lemmas, a lookup's read staying valid and unready until the lookup or the hit path answers it, the registered kind of the selected read outside a shadow lookup the hit path answers, and that a lookup of a slot whose hit the hit path holds is a shadow; and two unbounded PDR proofs with arbitrary inputs and stores. The first PDR proof assumes the induction's lemmas and covers most other control assertions, and the second independently covers the four shared payload checks without a depth bound: the grant multiplexer, local image, load payload and reply holds. The induction reads the first PDR proof's model and assumes nothing from it. The 42-, 32- and 24-frame control BMCs retain 322 checks, and the independent outlier proof covers their four complementary payload checks on a free-input, stores-enabled model that includes the scripted and no-store specializations. The matching 42- and 24-frame payload BMCs also check those four assertions at their original bounds. The BMCs assume no outlier facts. The PDR proofs leave out the pairwise distinctness of live endpoint lines, the store-record address and acquisition checks, the prefetch window and prefetch acquisition window checks, the atomic exclusion checks, the hit path's slot and answer checks, the 32-cycle pending-probe bound and a few smaller ones, which only the bounded tasks check. The arbitrary-input tasks retain their shorter bounds; the eight-endpoint stream behavior is first reachable at cycles 28 to 37, so the scripted task is the one that reaches it. The 32-cycle pending-probe service bound is not reachable in the bounded eight-endpoint tasks; the one- and three-endpoint tasks check both through 40 cycles. The scripted task's optional fourth load falls at cycle 48, after its depth. The two scripted tasks have complementary assertion selections and assume nothing from each other. The read-status reference places a load endpoint's answer in its grant's first lookup cycle and a hit-path answer in its fourth stage. The control tasks check that the hit path holds valid, unanswered load slots, that its answer is the slot's only completion, and that a lookup of a slot whose hit it holds is a shadow; the bounded tasks also check that the shadow's tag result agrees with the hit path's. The store-data tasks check that a hit-path answer of the watched sector holds its byte as of the hit path's read edge, and a word-0 data task runs with four ways and three endpoints. A 40-cycle free-input cover task reaches a hit-path answer, a shadow lookup that answers nothing, a shadow miss that acquires, and the hit path's refusals for a sector holder, a probe and the array. Checks that the answer goes to an eligible read, once per acquisition, run in simulation. Separate conflict proofs check both address-selector values against an independent reference with arbitrary controller state, and each control task uses the guarded identity from its matching conflict proof. Stream tasks check speculative endpoint isolation and cover demand attachment, two speculative endpoints, LR/AMO admission beside hint acceptance, and used, empty or cancelled demand opportunities between buffered grants. Grant-turn covers use three endpoints and include a held probe reply. Local ownership induction uses arbitrary array responses and checks service exclusion, saved identity/image and installation before release, with one or four ways. Ownership induction also proves local and SC lookup address identities. Sector induction checks the registered conflict sample and admission beside live endpoints under those two unbounded facts. Each sector task requires its matching owner task; their parameters, inputs, cutpoints and interface assumptions match. Ownership induction assumes twelve facts that the `coh_l1d_local*_owned_prove` tasks prove by 8-step induction: a failed read's slot is still owned on the cycle after its grant; an atomic's pending write data, its write update, its grant and endpoint 0's AMO or SC acquisition belong to the atomic in service; the local phases serve a local atomic, which stays active and in service; a failed local SC holds no grant or write; and a read lookup's registered kind is its read's. Those tasks also prove endpoint 0's phase across a remote atomic, the read ownership lemmas and a lookup's read staying valid and unready, with the same cutpoints and interface assumptions, and assume nothing from the owner or sector tasks. Fast tests enforce the model match, task registration and CI membership. Three independent 80-cycle scheduled real-array tasks check arbitrary-byte preservation and deferred probe data, wide payload identities and holds, and every other assertion. They share the original schedule and interface assumptions, with no cross-partition assumptions; their assertion selections are complementary, so new assertions enter the control task. Covers reach local SC failure, completed installation and a probe reply after release. Selected-SC reservation stability is an interface assumption here; the local CPU composition derives it from LR and the production clear paths. Five tasks drive cbo.zero writes (`ZERO_WRITES`); the others hold the zero write low. With one and three endpoints, the zero BMCs check that a GetMZero starts from a lower zero record whose twin follows it and whose upper sector no endpoint, frozen PutM or older record holds, so the registered sample still matches; that a twin never acquires through look-ahead; that a GrantMZero owes exactly the twin of its own lower record; that while the twin is owed it is the head, its endpoint is live without Done (endpoint 0 keeping its write-back reservation) and only `TwinOp` installs it; that `TwinOp` writes Modified zeros over the whole sector at the twin's address, once; and that its victim takes a slot that holds nothing. The depth-40 zero payload task checks the five store payload properties with zero writes, without repeating or assuming the zero-control properties. The zero-control task retains every zero-line property at depth 40. A fast model check preserves the input model, property selections and depth. The covers reach a twin installation, a twin installation that freezes a Modified victim, a look-ahead GetMZero, a twin waiting on a full buffer and a lower record that falls back to GetM. The single-endpoint task checks all four covers with the SMT bounded cover engine and Yosys witness replay, to depth 80 within 2400 seconds. Queries begin at frame 48 because the dirty-victim event requires several completed transactions; every initial state, input constraint and transition from reset remains in the model. Its cover-only public-input profile leaves scalar and zero writes, addresses and grant/release scheduling free, with loads, maintenance, probes and atomics idle and consumers ready. Each cover has a store-only scenario; the profile narrows only the existential search. The safety tasks retain unrestricted inputs. The tied ports lose only their input flags before the constants are connected, so the backend cannot alias a constant to a free input. The fast model check preserves reset and the interface assumptions, permits only the listed input bindings, and rejects hidden constraints, cutpoints, removed covers and changes to the query window. An independent guard pins all three zero-safety models, including their sources, scripts, engines and bounds, and rejects cover-only bindings, SMT constraints, reset changes and assumption removal |
| `coherent_hart_cache` | Unbounded maintenance composition with abstract private caches and one, two or four scalar stores. `coh_hart_maint_owned_prove` proves 263 auxiliary invariants and 21 original assertions by 8-step induction without assumptions. They cover image transfers, scalar provenance, request and fill identity, invalidation epochs and walker response/drain phases. `coh_hart_maint_prove` reads the same model, assumes those 284 facts and proves the remaining 88 original assertions by PDR. Together the tasks retain every original assertion. Fast tests enforce the model match, independent lemma selection, task registration and CI membership. A separate deterministic 240-cycle schedule supplies 67 scalars, holds installation until four records are occupied, and checks drain, fence completion and instruction/PTW publication of the distinct final scalar. Covers require all four records, fence completion and both consumers |
| `coherence_store_home` | Production L1D and home preserve a watched byte through sibling sectors, distinct rows and a conflicting home set with the younger row resident. The pressure schedule holds two dirty victims and endpoint releases before a load grant and probing DMA read complete. The DMA consumer checks demand, grant, completion and release identities. Bounded safety and progress checks use deterministic delayed memory responses; covers require completed consumers |
| `coherence_home_select` | Combinational equivalence against serial reference selectors of circular priority with READY preference over twenty-one positions, the last of which picks a slot it is given, and of three-seat waiter admission over twenty-four slots |
| `coherence_home_completions` | Unbounded ownership checks for three identities and two result credits, including distinct live identities, same-sector predecessors (released at U, or at a DMA predecessor's result; prefetches neither wait nor order), grants that rotate among the result buffers, held G/U payloads, retry credit return and way pins through U. Parked work keeps its identity and predecessors while releasing image credit. READY work has priority over fresh eligible work. The prefetch slots' place in the work rotation offers an eligible slot whenever it can be picked. `coh_completions_pairs_prove` keeps request addresses in an eight-bit window and checks that a prefetch's no-fill flag covers every live demand for its block. The partition tasks keep one of three slots for prefetches, or two of four, and assume the consumer takes a prefetch slot's G when it is presented; with two, the cover reaches the prefetch rotation passing over an offered prefetch slot. A forward gives a parked primary with no predecessors the forward buffer, its pin and its result on one edge. Assumes initial reset and legal worker pin/retry, park, wake and forward events, a forward's result carrying its slot's identity and address, with no prefetch parked, as the composed home proves. Cover tasks reach a full result pool, independent completion while other work remains live, a prefetch dispatched with no fill, a prefetch slot's G, a forwarded G, and a forward beside an engine's result. The IF-pair cover tracks admission order and reaches a younger G before the older G and a younger U before the older U |
| `coherence_home_forward_pins` | Per-fill forward choice equals the first ready fill in the preferred mask, else the first ready fill, for arbitrary ready/preference masks at one, three and eight fills; portable and primitive implementations |
| `coherence_home` | Unbounded control ownership checks cover three completions, two engines and two fill controls over eight sectors with 32-byte lines and sixteen sectors with 64-byte lines, using one way and zero payload data. An independent scoreboard tracks accepted memory IDs through responses. Assumes initial reset, persistent fatal stop and responses for owed IDs. Unbounded victim checks preserve frozen bytes, address ownership and held memory payloads through B. Victim recall controls have distinct reserved slots. Directed cover traces reach delayed success and error responses. `coh_home_control_partition_prove` repeats the 32-byte control proof with one of the three completion slots kept for prefetches. Two bounded tasks check every assertion for 14 cycles from reset with four ways and three fill controls, one of them with the registered tag array; k-induction does not close with four ways. In the same configuration, `coh_home_prefetch_cover` reaches a prefetch allocation, a prefetch that allocates nothing for a block a demand holds, a prefetch fill that gains a demand seat or fails, a prefetch held back by the fill reserve, and a prefetch fill that installs; the last two take more than the bounded tasks' 14 cycles. A cover task on the control harness reaches a successful memory response that moves its fill from FillMemory to installation on the next cycle, a waiter seated on the edge the array accepts the installation, two waiters woken before the installation completes, a primary forwarded while its fill is in FillInstall, and a forwarded G taken before the installation completes. Each successful fill wakes its seated waiters once, a seated waiter's decision takes its completion pin only from a ready fill, and a pending primary is a parked GetS, LoadReserved or GetM of its fill's block in the recorded sector, with the identity its fill recorded, which no success wake names. Fill addresses are block aligned and live slot addresses are sector aligned, so a forward's result carries its primary's address. With zero payload data these proofs do not reach the forwarded bytes. `coh_home_wb_prove`, on free data, checks that a watched byte of a fill's memory response stays in its image and that a forward offers it at the same offset of the primary's sector; the home and cluster benches compare grants with memory. Array and engine byte-value properties have separate unbounded proofs. GetMZero is a legal hart request in every control task. With 64-byte lines it orders behind and ahead of requests to either sector of its line, and a GetMZero that allocates a fill makes a zero fill, which sends no memory read, holds a zero image until it installs Modified, is its GetMZero primary's fill, and forwards GrantMZero with 64-byte lines; `coh_home_wb_prove` tracks the zero image as the watched byte |
| `coherence_home_engine` | Unbounded byte-value checks in both line geometries select dirty probe data over the resident snapshot and apply DMA byte enables last. Checks held probe, acknowledgement, update and result payloads. Assumes initial reset, legal dispatch and decision events, and responses to launched array operations. Covers coincident dirty reply/data and failed SC completion |
| `coherence_home_array` | Unbounded watched-byte preservation across independent read and masked-update ports in both RAM forms. Checks held tag decisions, physical-row hazards and bounded service under continuous read/write contention without tag updates. A held tag-only update has bounded service when the response receiver is ready. The block RAM task watches an arbitrary byte; the registered RAM tasks cover each of the 64 byte lanes. Assumes initial reset, legal ways and claims of available tag decisions. Covers overlap on all three ports |
| `coherence_array` | Bounded byte-value and held-response checks in block RAM and UltraRAM, with one and four ways, through 32 cycles except 24 for four ways in block RAM, including replies that need no data and leave in the first data-read cycle, with covers for such a reply held into Reply and followed by a lookup or by a data write to the read row. Separate data-selection tasks prove equality with the selected-way-state expression at one/four ways and 32/56-bit addresses. They cut state before sequential optimization and assume neither reset nor unique tags; duplicate matches, exclusions, both skip flags and visits are arbitrary. With the hit port, one- and four-way tasks check its tag copy and returned bytes against the values written before its read edge, and that it never reads the banks beside a data-reading lookup or a write to its set; a four-way cover reaches a port hit beside a tags-only lookup and after a write to its set |
| `coherence_array_plru` | Unbounded equality of replacement state sampled by each lookup against a reference that writes hit touches at tag selection; a no-touch lookup's hit leaves it unchanged. Uses four ways and two sets in block RAM and UltraRAM configurations, and with bimodal insertion, where an insertion updates the state on `i_update_touch` or one LFSR value in 32. Checks deferred hit address/data and exclusion from request/update acceptance. Assumes first-edge reset and legal ways; later resets, updates and reply stalls are arbitrary. Each insertion and hit touch writes the bits on its way's path into the current state, in the reference as in the per-bit RAMs, so no insertion depends on the last lookup's replacement snapshot. Covers hit touches during data service and replies, a following lookup in the same set, a no-touch hit, and an insertion updated by `i_update_touch`. A task with the hit port adds its touches, which write when the array writes no replacement state and are dropped otherwise; in the reference, a controller hit of the same set applies after the port's touch. Its covers reach a port touch beside a controller hit and a dropped one |
| `coherence_array_equiv` | `coherence_array` against `coherence_array_reference`, the same array with one data RAM of `{way, set}` rows read from an input register after the tag decision and a replacement RAM written whole from the lookup's copy: control outputs equal on every cycle through 30 cycles in block RAM and 40 in UltraRAM with one way, and through 24 and 20 with four ways, where each frame takes longer, also with bimodal insertion. Inputs are arbitrary after a first-cycle reset, except that an insertion names the way of the last lookup response, which the L1D asserts for each grant installation. Separate tasks compare response data in one byte lane each (0 and 31 with one way, 0 and 17 with four, 5 in UltraRAM), in rows written since reset, since the data RAMs have no initial contents; every lane has the same logic, and a fixed lane keeps the proof's data to that lane. Two one-way tasks run arbitrary hit-port reads beside the lookups, comparing control outputs and byte lane 0. A cover reaches a compared data hit and an insertion |
| `coherence_dma_ingress` | Four or eight independent request lifetimes preserve opaque IDs until the later of the response and U; each request responds once, a read after its G and a write after its U, and a U's slot that has not responded responds on the next cycle. Requests issue in acceptance order; full keys match reordered grants and releases. The composed arbiters assert their sender hold contracts and captured-payload equality. Reset clears all ownership. `coh_dma_ingress_soc_prove` proves eight credits; `coh_dma_ingress_soc_cover` fills the queue, wraps both pointers, drains every credit, and reuses an ID both with and without other requests in flight. Its cover driver uses writes with matching G and U packets; the proof assumes initial reset and aligned requests |
| `coherence_control` (`coh_reader_*`, `coh_ptw_reader_*`, `coh_ingress_prove`) | IF slots 0 and 1 and PTW slots 0 and 1 register one data/error response per G and hold their identity through U. Default readers and source-2 line bridges respond after U. Payloads and reader IDs remain associated under D/C stalls; response debt forbids duplicates. Covers exercise errors, stalled completion tails, fatal stop and reset in each active phase. Assumes initial reset, aligned requests and read-only hart requests. Early readers assume a valid G for their waiting q carries the demand's address, as checked by the home completion target. The maintenance composition asserts this address contract at the bridge without that assumption |
| `coherence_control` (`coh_arbiter_prove`, `coh_arbiter24_prove`) | Captured payloads equal the selected input at each valid presentation. Selection matches circular priority at three and twenty-four inputs. Assumes initial reset and held input payloads until acceptance |
| `coherence_prefetch_agent` | Unbounded ownership proofs at 32- and 64-byte line sizes with the default three data identities and the instruction identity, plus one- and two-identity data tables beside it and a four-identity data table without it. Checks D and C stability, address and identity matching, Error completion, pause behavior, each table's identity bounds against its endpoints, free-slot admission against an occupancy count, no two live identities on one line, and identity retention until U. Successor detection and page-offset prediction are checked against full-width addition. Only initial reset is assumed; G/U inputs, training, room, pause and backpressure are arbitrary. Composed arbiters assert their producer hold contracts. Covers through 40 cycles reach four live identities, errors, dropped duplicates from both tables, release and reset. Fill semantics and full-home progress are checked by the integration benches |
| `coherence_prefetch_pause` | An independent bitmap of eight DMA identities and a seven-cycle activity history check the admission pause. Assumes responses name live identities and admissions use free identities or simultaneous release. Covers reach eight outstanding lines, simultaneous identity reuse and return to idle |
| `coherence_endpoints` | Unbounded held-payload, identity lifetime, completion ordering, keyed cancellation, and fatal-data retention properties for the request, home, PutM, and queue endpoints. Assumes initial reset, held service results under backpressure, and masked ordinary W selection after absorption. Cover tasks reach ordinary completion and absorbed cancellation. The wide home task uses 56-bit addresses and 16 fill identities. The pending-mask tasks prove equality with an admission-clear reference and an empty mask in Idle and SendU at both address widths, assuming only an initial reset. Their cover reaches release after an absorption. The request phase tasks compare encoded and local phase updates against an independent encoded reference under arbitrary binary inputs after initial reset. Equality includes all outputs during invalid and reset cycles, payload registers and phase occupancy. They prove one-hot occupancy for data slots 0 and 7 and PTW slot 0 at 32/56 bits, excluding internal state corruption, and cover a complete request lifecycle. These are endpoint safety proofs, not a proof of a cache coherence sequencer or arbitration progress |
| `coherence_control` (`coh_c_payload_prove`, `coh_c_payload_wide_prove`) | Completion payload equality outside reset at 50 and 74 bits with arbitrary phase selections and payloads. No one-hot or peer assumption is imposed. Endpoint tasks separately check phase-selection and channel-valid qualification |
| `coherence_control` (`coh_atomic_select_prove`, `coh_atomic_select_wide_prove`, `coh_atomic_pair_prove`, `coh_atomic_pair_wide_prove`) | Arbitrary-input atomic source qualification and unbounded equality of guard active state, retired state and active tags at five and nine tag bits. The paired guards assume first-edge reset. Invalid candidate tags are unqualified |
| `coherence_control` (`coh_grant_select*_prove`) | Grant validity, selected index, one-hot selection, read failure and packet attributes equal a credit-qualified priority scan for two, four and eight candidates, for arbitrary binary inputs; unbounded. Idle packet attributes come from endpoint zero. X/Z equivalence is outside this check |
| `coherence_control` (`coh_read_owners*_prove`) | The read ownership mask equals an indexed endpoint scan for one, three, four and eight endpoints, including duplicate slot indices. Endpoint zero excludes stores and SC; nonzero endpoints exclude stores and installed requests. Arbitrary binary inputs; unbounded |
| `coherence_control` (`coh_miss_credit*_prove`) | Shared writeback permission and retry credits equal the per-kind reference for one, three, four and eight endpoints. Arbitrary binary inputs; unbounded. Caller wiring and X/Z semantics are outside this helper proof |
| `coherence_control` (`coh_read_select*_prove`) | Circular read selection, selected address and eligible load-miss reduction equal a direct reference at 32-bit and 64-bit addresses, for portable and Xilinx-primitive (`*_xilinx_prove`) builds. Availability also equals the OR of qualified physical entries. The reference assumes each forwarded address matches the slot mask and stored or buffered-write address; binary inputs |
| `coherence_read_payload` | Unbounded equality of every read-slot payload and all buffered-write exports with independent reference storage, using eight slots with 42-bit and 74-bit payload vectors. The harness assumes first-edge reset. Later resets, allocation inputs and payloads are arbitrary, including consecutive same-slot writes and payload changes without allocation. Stored slots use the reference buffer's prior mask and payload. Field packing is outside this check |
| `coherent_debug_request_count` | Unbounded binary request-count equality at eight and four bits, including reset, holds and modulo wrap. Assumes initial reset. Writer request wiring and completion synchronization are outside this helper proof |
| `coherent_rs_control` | Combinational equality of allocation and repair target masks, the selected ready vector, primary opcode mask, second-issue outputs, immediate-use, ROB-tag and writeback-hint selection, clear mask, shift amount, next count and active flush count with direct reservation-station expressions. The configurations use eight entries with three sources and lane-1 bypass disabled, sixteen integer entries with an eight-entry window, eight entries with a five-entry window, five entries with a partial primary group, and four multiply-station entries. Local state is arbitrary without environment assumptions. Sequential station lifetime and X/Z equivalence are outside this check |
| `coherent_rs_issue2_selector` | Unrestricted valid, index and one-hot equality against tree and serial selection at two, three, five, eight and sixteen entries. Ready and branch inputs are arbitrary. Reservation-station readiness decoding is outside the helper proof |
| `coherent_rs_payload` | Unbounded binary payload equality with two-write banked storage for every row at four, eight and sixteen entries, with seven-bit data and a 125-bit sixteen-entry case. Writes are arbitrary, including same-row write collisions. Storage has zero initial contents. The station's winner-mask contract and general X/Z equivalence are outside the helper proof |
| `coherent_rs_capacity` | Unrestricted count and full-flag equality against modular issue/dispatch arithmetic at four, eight and sixteen entries. Counts, issue bits, dispatch bits and flush counts are arbitrary. Reservation-station event decoding is outside the helper proof |
| `debug_dirty_next` | Unrestricted equality of all sixteen dirty-word next-state bits against indexed clearing and set-mask priority. Reseeding, clear index, readiness and set masks are arbitrary. Debug-module event decoding is outside this helper proof |
| `debug_store_mirror_hold` | Unbounded validity and occupied-address equality against capture-on-push storage at 15, 16 and 32 address bits. Assumes initial reset; push, pop, address changes and later resets are arbitrary |
| `coherent_cpu` | Local SC ownership and LQ control invariants, including selected memory identity, staging permission and next state, launch, forwarding, SQ probes, cut holds, captured completion payloads and reservation clearing. The LQ tasks use eight entries and default preissue settings, with forwarding and Normal-cache variants. Combined forwarding and Normal-cache tasks cover both settings of preparation while memory is busy. Standalone selector equality covers four, eight and sixteen entries. SC classification also uses aligned, unaligned, non-power-of-two, empty and wrapping region configurations. These are local invariants, not whole-CPU transaction proofs |
| `coherent_l0` | Unrestricted valid-state equality at 128 and 256 entries, plus eight-step cache checks and twelve-step hit and invalidation covers. The cache tasks assume an initial reset without reassertion and agreement between the fill and RAM-write controls. Explicit collision coverpoints are not enabled by these tasks |
| `cache_way_choice` | In any register state of a 256-byte, 4-way cache with 8-byte lines: an allocation that completes takes a way outside the tag stage's ownership mask (built from its registered set matches; simulation checks allocations against the miss slots themselves), the completion that one-cycle tags factor by the compare's outcome equals its reference form, a lone hit names its way, the way an access touches is never the next pseudo-LRU victim, and the victim walk restricted to the unowned ways picks one of them, the pseudo-LRU way whenever that one is unowned. Also runs direct-mapped and with delayed UltraRAM tags. The checks are combinational, so the depth is one cycle |
| `coherence_observation` | The load queue's coherence port tracks one arbitrary ROB tag's observations through retirement, flush, and tag reuse, and replays it when DMA invalidates its line. See below |
| `coherence_replay_compare` | DMA-invalidation replay masks built from chunked compares equal full-width line equality at XLEN 32, 64, and 66. Assumes one initial reset |
| `data_mem_request_router` | Device reads are staged and accepted only after committed stores drain, a flush cancels an unaccepted device read, read enables match acceptances, and a blocked request keeps its address. Assumes the load queue presents no new read while one is held |
| `data_mem_response_mux` | Load data selected among BRAM, MMIO, and cached DDR equals the reference selection at 32 and 64 bits, for portable and Xilinx LUT5 builds |
| `dmmu_mmio` | One-step combinational checks of the DMMU's S1 MMIO classification, DTLB device-window, atomic and permission verdicts, and candidate address split and fault selection against reference logic. For arbitrary DTLB contents, the hit and walk-leaf permission verdicts use the live SUM, MXR and effective privilege, so no entry carries a permission from the state it was filled under |
| `dmmu_capture` | Bounded and inductive checks of S2 capture, packet fields, one-cycle bypass, last-page invalidation and the preceding LQ tag/valid pair. A last-page bypass grants an access only when the live SUM, MXR and privilege equal those captured and permit it. Assumes initial reset and permits arbitrary issue order, flushes and permission controls, and arbitrary TLB answers whose clean-hit verdict is a hit with no fault, as the DTLB's own checks prove. Covers LQ/SQ bypass and a bypass concurrent with a killed S1 resolution. Does not prove leaf provenance or downstream memory responses |
| `immu_bare` | With translation off, the IMMU's physical addresses and fault flags equal the reference for every PC, and word 1's fault is the PMA check of the next page. Capacity tasks select 1, 64, and 128 GiB explicitly. The XLEN 32 and 72 variants check only Bare mode and width conversion |
| `immu_page_offset` | Translation preserves the live page offset. Crossing windows use the captured second page, which equals a reference selecting its fault VA before capture. Intra-page windows share word 0's translation and faults; unbounded. The ITLB is replaced by arbitrary outputs within its output contract: its PPNs are its stored PPN parts with the lookup or next VPN's low bits joined for the hit's superpage size, the parts are zero where those bits go, and the gigapage and megapage flags are exclusive. Assumes one initial reset |
| `immu_memo` | Svvptc: the fault memo clears on every full flush and every 64-clock epoch. A completed registered refusal also expires within 64 clocks, including on a wrong path that never traps; a flush drops even a coincident response, and a known first-word fault completes a crossing window without waiting for its neighbor, including when its response coincides with expiry beside a warm faulting neighbor. An unknown neighbor stays marked faulting with the first word's cause and its own virtual page. Unbounded checks track memo and completed registered-fault ages independently and prove that each is bounded by the free-running epoch. Memo fills require a walk accepted after the last full flush. ITLB and walker answers are arbitrary. Assumes one initial reset |
| `immu_successor` | Superpage successor eligibility, physical page and PMA verdict equal the selected-leaf reference for arbitrary ITLB contents and walk state. Combinational equivalence without environment assumptions |
| `line_arbiter_grant` | Two- and three-port line arbiter grants equal the reference starvation-priority rule, for portable and Xilinx-primitive builds |
| `line_port_axi_bridge` | At the 64-byte width used below the L2, AR, AW, and W hold steady until accepted, also through a CPU reset, and are low through the AXI side's reset, which drops them; read responses carry the right ID, stale read responses are dropped, and in-flight IDs are tracked. Against a reference that splits owed transactions at each reset, no request is accepted while one from before a reset is owed, so every forwarded read or write response answers a request made since the reset. Each forwarded response carries the error bit of the R or B it came from, also a B held while R responses pass it. BMC and cover tasks check the default, 64 GiB, and 128 GiB address widths. Assumes unique in-flight IDs |
| `line_size_adapter` | A request goes to its sector of the wider L2 line: aligned address, data copied into every sector, strobes only in its sector, id and kind unchanged. For an arbitrary id, a response returns the sector recorded when that id's request fired, through the outstanding-transaction table. Assumes ids unique among requests in flight and one response per request |
| `lq_normal_fill_policy` | Classifying the uncached snapshot before response selection equals classifying the selected response address, for strict, Normal read-cache, and legacy policies; arbitrary state, no assumptions |
| `low_bram_presenter_tier` | `low_bram_fetch_presenter` presents the same low-BRAM fetch responses with and without separate address retargeting. See below |
| `ptw` | Bounded reference-PTE classification and independent root-to-leaf read-address checks, including cache hits. Shadow cache entries take their tag from the accepted request and their pointer from the independently selected response PTE. Cached pointers from an arbitrary stable watched line equal its valid non-leaf PTEs; discard clears both arrays, fills are valid and tags unique. Checks use two entries per array at depth 24, one entry at depth 40 for replacement, and no cache at depth 16; depth-64 covers reach replacement in both arrays. Assumes responses only for outstanding reads and the port contract that a new root context requires a discard. The cause of an access fault is not checked |
| `sc_head_query` | The coherence match and cached/uncached classification for the store-conditional at the ROB head equal direct comparisons of its selected address, from arbitrary table state |
| `tlb` | Lookup, insert, and invalidate-all: a watched entry stays intact and every matching lookup hits it, no port hits while no entry is valid, invalidate-all clears everything, and the one-hot lookup select returns the lowest matching entry's fields. The DTLB uses 16 entries and 3 ports; the ITLB uses 16 entries and 2 ports with fetch permission, PMA and superpage-successor checks, data verdicts disabled, and the PPN select tree, whose PPN parts (the output contract `immu_page_offset` assumes) equal the selected entry's |
| `uncached_read_capture` | The factored uncached-read pending-bit update preserves enqueue, downstream handoff, and reset priority from arbitrary state, with no assumptions |
| `coherence_home_twin` | The home's probe-address match, writeback reply-capture select, and forward turn selects equal their portable form, at one way with two fills, four ways with three fills, and 40-bit addresses. Portable and Xilinx-primitive builds are compared with Yosys equivalence checking (see Primitive twins); the primitive form of every LUT in the cone equals the portable form for any state and input |
| `coherence_home_engine_twin` | The engine's probe-reply match (LUT6) equals its portable form at 32-byte and 64-byte lines and at 40-bit addresses, where all five address groups enter the LUT |
| `coherence_l1d_twin` | The L1D acquisition-endpoint select (LUT3 per bit) equals its portable form with one and three miss slots. The read selector is compared by `coherence_control` |
| `cached_tier_adapter_twin` | The read-slot valid, live, sent and open next-state LUTs equal their portable form, with and without split read requests |
| `data_mem_request_router_twin` | The MMIO drain-accept gate (LUT4) equals its portable form |
| `dmmu_twin` | The last-capture select (LUT4) equals its portable form |
| `immu_twin` | The physical-address-valid select (LUT5) equals its portable form |

`coherence_observation` follows an arbitrary ROB tag, so it covers all 32 at
XLEN 64: the pending observation, its table entry and line, cleanup on
retirement or flush, the registered replay mask, and table payloads that a
flush or reset should have discarded staying invisible. It assumes an initial
reset and that neither commit lane retires a tag observed in the current or
previous cycle; `prove_unrestricted` drops that timing assumption and still
proves flush cleanup, commit cleanup when no observation overlaps, and that a
pending write wins over a coinciding commit. A clean admission sees no live or
pending observation of its line. Because the replay mask is
registered, it can name an observation cleared on the same edge; ROB
acceptance and allocation timing keep such a mask from affecting the tag's
next user, which this target does not check.

`low_bram_presenter_tier` compares response validity, addresses, PC, faults,
and data, bounded and unbounded (ABC PDR), while PA0[31] is clear in the
current and previous cycles; when it is set, the DDR provider serves the
fetch and masks the low responses. It assumes a reset on the first two
cycles, which clears arbitrary memory history.

### Peripherals

| Target | Checks |
| --- | --- |
| `imsic_file` | The interrupt-file properties of `imsic` below, proved for one file in the CPU's configuration: 63 identities, APLIC delivery, and the select and identity decodes the CPU registers beside `*iselect` and its MSI ingress, which must match the binary select and identity. |
| `imsic` | In each interrupt file, `*topei` is the lowest identity that was pending, enabled and under a nonzero threshold a cycle earlier, or zero when there was none, and after a cycle without a claim or register write it is still such an identity; the interrupt line is set exactly when `eidelivery` was 1 and such an identity existed a cycle earlier, or follows the APLIC's line with `0x40000000`; `*ireg` reads match the spec's register map and only the odd selects from `0x81` are illegal; and each pending and enable bit, `eithreshold` and `eidelivery` take exactly the update the cycle's claim, register write and MSI give, so an MSI sets only its bit and a claim clears only the reported one. Each file receives exactly the valid stores to its own page, with their identity. Reset is held in the first cycle; inputs are arbitrary afterwards. `bmc`, `prove` and `cover` use two harts and 63 identities, `prove_harts3` and `cover_harts3` three harts and 191 identities without APLIC delivery, `prove_ids511` one hart with 511 identities, and `bmc_ids2047` one hart with 2047 identities to depth 3, which checks the decode of 11-bit identities, every register read, and single writes. No identity is both pending and enabled within that depth, so at 2047 identities the lowest-candidate search and claims rest on the unbounded proofs at the smaller sizes, which use the same per-word logic, and on the cocotb shape `imsic_limits` |
| `async_fifo` | The NIC's clock-crossing FIFO with two unrelated free-running clocks: occupancy bound, conservative credits, ready margin, no underflow, Gray-coded pointers, and in-order, intact delivery of a watched word, at 4 entries of 4 bits. The `limit_bmc` and `limit_cover` tasks add the runtime occupancy limit (`DYNAMIC_LIMIT = 1`) with a constant limit between the margin and the depth: the writer never takes occupancy past the limit less the margin, and the cover shows it stalling at a limit below the RAM's capacity. Both resets are held for the first six steps; registers start at their reset values, because a clock may have no edge during the reset window |
| `aplic` | The APLIC's `topi` is a pending, enabled candidate of its domain and hart under the threshold, and no candidate has a smaller priority number or the same one and a lower identity. Pending bits follow each source mode's rules, including the cycle of a mode change, with a set winning over a clear; `sourcecfg`, `target`, `domaincfg` and the IDC registers follow their write rules; delegation starts the child's configuration at zero; a write to the supervisor domain changes nothing the root holds; reset leaves the documented state; the interrupt pins follow IE, `idelivery`, `iforce` and the candidates; and every word of the window reads as the spec's register map gives. Reset is held in the first cycle; inputs are arbitrary afterwards. `bmc`, `prove` and `cover` use three sources, two harts and two priority bits, `prove_one_hart` one of each, `prove_wide` 33 sources, and `prove_three_harts` three harts with 8-bit priorities. MSI tasks check source eligibility, snapshot addresses and data, stable offers, selection retirement, pending conservation, cyclic arbitration, address WARL and locking, and generator writes and completion. `msi_bmc` (depth 12), `msi_prove` and `msi_cover` use three sources and two harts with 56-bit addresses; `msi_prove_32` uses three harts with 32-bit addresses; `msi_prove_locked` uses one source and one hart with locked reset addresses; `msi_prove_wide` uses 33 sources; and `msi_prove_four_harts` uses four harts with 56-bit addresses. Each MSI prove task uses depth 5 induction |

## Property Style

- Assert properties that can fail: input/output relations, ordering, and
  temporal behavior.
- Guard `$past()` with a past-valid bit and the relevant reset conditions.
- An assumption must describe something the real environment guarantees.
  Record it with the target's entry in this README.
- Assume an initial reset only when the property needs it; otherwise prove
  it from arbitrary state.
- Keep block properties under `ifdef FORMAL` in their module. Harnesses that
  span modules live here beside their `.sby` files and are never synthesized.

## Adding a New Formal Target

1. Add `ifdef FORMAL` assertions to the RTL module, or create a formal-only
   integration harness when the property spans production modules.
2. Create an `.sby` file in `formal/` (see `trap_unit.sby` for a block-local
   target or `prediction_release.sby` for an integration proof). Read every
   source whose properties must be active with `read -formal -sv`. A plain
   `read -sv` compiles its assertions out, and a proof can then pass
   vacuously.
3. Add a `FormalTarget` entry in `tests/test_run_formal.py`, listing `prove` in
   `tasks` when the `.sby` defines it. Register any new task names in
   `SBY_TASKS` so CLI and pytest runs include them; the fast Python tests fail
   if a declared task is missing from `SBY_TASKS`:

```python
FORMAL_TARGETS = [
    FormalTarget("trap_unit.sby", "Trap unit"),
    FormalTarget("new_module.sby", "Description of new module"),  # bmc + cover only
    FormalTarget("new_proof.sby", "Unbounded proof", tasks=("bmc", "cover", "prove")),
]
```

4. Add a row to the matching table above, with any assumptions or scope
   limits.
5. A new `ifdef FROST_XILINX_PRIMS` block in `hw/rtl` needs a primitive-twin
   task (see Primitive twins) or an entry in `NOT_COVERED` in
   `tests/test_prim_twins.py`, with the reason. Copy a `*_twin.sby`, list the
   module's sources and parameters, and set the `select -assert-min` floor to the
   `Found N $equiv cells` count in the first verbose run's log.

## Yosys SVA Limitations

Yosys supports a subset of SystemVerilog Assertions:

- Use immediate assertions inside `always_comb` or clocked `always` blocks.
- Use `!a || b` for implication. The concurrent form `a |-> b` is not
  available.
- Use `$past(signal)` for sequential properties.
- No hierarchical references (`u_sub.signal`): assertions must sit inside the
  module they check.
