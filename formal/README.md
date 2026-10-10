# Formal Verification

FROST checks its RTL with [SymbiYosys](https://github.com/YosysHQ/sby) as well
as simulation. The targets cover the fetch stage, the out-of-order back end
(ROB, rename, reservation stations, load and store queues), the execution
units, the MMU and caches, and the NIC's clock-crossing FIFO. Each `.sby` file
in this directory is one target, registered in `FORMAL_TARGETS` in
`tests/test_run_formal.py`, and CI runs every task of every target. Most
properties live in the RTL module they check, under `ifdef FORMAL`. The `.sv`
harnesses in this directory hold the proofs that connect several modules or
compare two instances of one.

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
run with a 40-minute timeout, and `--verbose` prints solver output. SymbiYosys
writes logs and any counterexample trace to `formal/<target>_<task>/`, which
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

## Targets

Grouped by area; `--list-targets` shows each target's tasks.

### Fetch and branch prediction

| Target | Checks |
| --- | --- |
| `branch_prediction_alias` | The slot-1/slot-2 alias output computed from the base PC equals the generic computation under the fetch stage's base+2/base+4 wiring. Only this output is compared |
| `branch_prediction_disable` | The prediction-use gates for both slots, slot 2's target select, and the metadata next state equal the reference equations, disabling prediction blocks both the live and the staged path, and the slot-2 targets' relations to the pending PC equal direct compares |
| `btb_tag_compare` | Grouped BTB lookup and update tag compares equal full-width tag equality, for the 256-entry BTB and a 16-entry one, with arbitrary RAM outputs |
| `c_ext_buffer_next` | The compressed-instruction buffer's next state equals the reference clear/capture/hold priority |
| `c_ext_state_cofactor` | The same next state with the pending-prediction handoff split out equals the reference, and a handoff never keeps old-path buffer state |
| `control_flow_holdoff` | Redirect and reset holdoff next state equals the reference equations |
| `fetch_shadow_capture` | The DDR fetch buffer's eviction shadows hold the same pending tags and payloads as a capture on the slot-write enable, and a per-word slot install writes what a whole-slot install would. Default, one-entry, and no victim store; assumes an initial reset and fill responses that match outstanding requests |
| `fetch_pc_mux` | The next-fetch-PC mux equals the reference priority, for portable and Xilinx-primitive builds, standalone and integrated (`bmc_integrated*`). The proof reads `i_slot2_prediction_used_for_pc` where the mux reads its own copy, `i_slot2_prediction_used_for_fetch_mux`; simulation checks they are equal |
| `fetch_redirect` | The registered fetch-redirect pulse equals the reference priority equation; bounded and unbounded |
| `pc_redirect_catchup_producer` | In the PC controller, the catch-up and default arms are both sequential, and catch-up never coincides with a pending-hold request; unbounded at XLEN 32, 64, and 66 |
| `pc_redirect_catchup_consumer` | Given those producer properties, leaving the catch-up request out of the registered redirect detector does not change its output; unbounded |
| `if_direction_payload` | Dropping the NOP term from the branch-direction payload select changes no non-NOP packet, including stall replay through the real `stall_capture_reg`. Assumes a flush on the first cycle |
| `pc_holdoff_cofactor` | The three fetch-holdoff outputs equal their reference equations |
| `pc_holdoff_tag` | A pending prediction's predecessor-PC tag equals its PC minus 2, and outside reset the prediction holdoffs equal their reference equations; unbounded at XLEN 32, 64, and 72, including wraparound. Assumes the pending bit starts clear |
| `pc_increment_relation` | The local carry relations behind the PC +2/+4/+6/+8 compares, and each sequential `pc_reg` candidate's relation to the pending and fetch PCs, equal full-width arithmetic at XLEN 32 and 64, including wraparound |
| `pc_increment_holdoff` | Both sequential next PCs equal the reference per-size candidates with holdoff and NOP selection, for portable and Xilinx-primitive builds |
| `pc_pending_capture` | The pending-prediction valid bit's next state equals the reference clear/set/hold priority, for both `PENDING_HANDOFF_EXCLUDES_SLOT2` settings |
| `pc_register_mux` | The architectural-PC mux equals the reference priority, in the same configurations as `fetch_pc_mux` |
| `prediction_handoff` | `prediction_release` with `PENDING_HANDOFF_EXCLUDES_SLOT2=1`, the fetch stage's setting |
| `prediction_metadata_output` | Each packet's BTB-taken bit equals the reference priority, and a packet that a saved or pending prediction does not belong to never reports taken |
| `prediction_metadata_tracker` | A pending prediction's saved PC and target hold until their packet consumes them or a reset or redirect kills them, and call and return types always leave with their target. See below |
| `prediction_release` | Pending-prediction outputs are masked while nothing is pending, a ready handoff raises both prediction holdoffs, and the holdoffs, predecessor-PC tags, and lower-parcel lookup match their reference relations. Whenever a prediction will be pending, the registered `pc_reg` relations load next cycle's wide-compare values. See below |
| `ras_checkpoint` | The return-address stack's outputs, next pointer, and count equal the reference equations, and so does every entry write: a push or swap writes its link address, a restore writes the saved top entry back, and nothing else changes |
| `rvc_predecode` | The fill-time RV64C expansion and illegal flag equal the reference decompressor (`rvc_decompressor`) for all 65,536 16-bit parcels |

`prediction_release` runs the real `pc_controller` and `c_ext_state`
together. The harness replaces the PC-increment calculator with one whose PC
outputs are unconstrained, which admits every real PC movement and more, and
makes predictor requests arbitrary. The stand-in's pending-PC relations are
full-width compares of its outputs, which `pc_increment_relation` proves the
real calculator matches. The harness likewise relates both slot-2 targets to
the pending PC by direct compares, as `branch_prediction_disable` proves the
predictor does. It assumes only a reset on the first cycle.
`prediction_handoff` runs the same harness with the fetch stage's parameter
setting. Both have `bmc`, `cover`, and ABC PDR `prove` tasks.

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
| `dispatch_admission` | Bundle and slot-2 admission equal the reference equations, and a firing slot 2 never reads FP source 3 (so done-repair channel 6 stays idle). Assumes only FP_RS ops read FP source 3, which `instr_operand_classifier` checks. `bmc_queued` uses the CPU's `SLOT2_VALID_FROM_BUNDLE=1` and assumes the queue's slot-2 valid rule |
| `instr_operand_classifier` | Decode's operand-class fields equal classification through the decoder's operation enum for every instruction bit pattern, injected NOPs, illegal flags, and fetch faults; only FP_RS ops read FP source 3 |
| `register_alias_table` | x0 is never renamed; a rename records its ROB tag; an INT commit clears a mapping only if the mapping still holds the committing tag; reset clears mappings and checkpoints; a full flush clears the checkpoints and, unless a checkpoint restore coincides, the mappings; a reclaim-all restore frees every checkpoint |

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
| `rs_primary_payload` | INT_RS's grouped port-0 payload read, address, and entry clear equal indexed selection at depths 4, 8, and 16; an unbounded proof compares the grouped payload RAM with a single RAM |
| `rs_issue_clear` | The second issue port's one-hot entry clear equals the indexed clear, for single and dual issue at several depths and with the INT station's window |
| `rs_pretag_cofactor` | The pre-issue ROB tag, computed for each combination of the two CDB valid bits, equals the reference priority select in two station configurations; the export tasks also check the candidate ready vectors |
| `rs_raw_pretag` | With the real early-wakeup merger, the MEM station's look-ahead candidates and ready vectors agree with its issue winner |
| `rs_lq_prematch` | MEM_RS and the LQ connected through the real merger and translation select: every candidate match and the registered selected match equal a direct tag CAM; bounded and unbounded |
| `tomasulo_wrapper` | The back end together (ROB, RAT, four stations, CDB arbiter, and memory queues): commit clears a rename only if no newer write renamed the register, a full flush or reset empties every structure, each station's copy of the CDB matches the bus, and the stations' ROB-tag rule holds with the real ROB allocator. See below |

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
| `lq_l0_cache` | The L0 cache at 128 and 256 entries: MMIO never hits, a hit needs a valid entry with a matching tag, a fill then hits with its data, and a flush or DMA line invalidation clears entries (store and AMO invalidations are covered, not asserted) |
| `lq_prematch_cofactors` | Every candidate match and its registered selection equal a direct tag CAM, for candidate-tag inputs, ready-vector picks, translation, and idle entries; bounded and unbounded |
| `lq_ram_payload` | The load-result RAM's two write ports and the CDB value mux equal the reference priority, in the default, store-forwarding (`bmc_forward`), and forwarding-without-L0 (`bmc_forward_only`) builds. Also shows that a cache hit never coincides with a staged AMO at the ROB head |
| `lq_replace_select` | The staging register's replacement decision equals the reference ROB-head and ring-position comparison at depths 4, 8, and 16 |
| `lq_response_bypass` | The load-response bypass pulse equals the reference pulse qualified by full acceptance; the separate partial-flush guard makes the reference's age comparison redundant |
| `lq_tag_order` | ROB-tag age order and the full-window boundary equal the reference computed in wider arithmetic, for all tags |
| `sq_committed_empty` | Committed-empty next state equals the reference over reset, full flush, and registered and same-cycle commits |
| `sq_live_count` | The live store count's next value equals the reference arithmetic for each allocation outcome |
| `sq_repair_mmio` | The early-address repair's two parallel MMIO flags equal MMIO classification of the full base-plus-immediate sum, including overflow |
| `store_queue` | Live-count consistency, write prerequisites (committed, address and data valid), in-flight bounds, forwarding, and that committed stores survive a partial flush. Formal builds use a linear forwarding selector in place of the balanced tree, which Yosys mishandles, so the tree itself is not proved. Assumes, among other input rules, no allocation while the post-flush tail pullback is pending and no combinational commit pulse during a flush |

`load_queue_amo_compute` starts from arbitrary state, with no reset or
admission assumptions, so it includes AMO states the queue cannot normally
reach. It makes no claim about scheduling, interrupts, or liveness. Its
script counts the named checks it relies on (`p_local_*`, `cover_local_*`,
and `p_lq_*_free_tree_*`): adding or renaming one of those means updating the
count.

### ROB, CSRs, traps, and recovery

| Target | Checks |
| --- | --- |
| `csr_commit_cofactor` | Stored CSR state other than `mstatus`, `mie`, `fflags`, and `frm`, both counters, and the translation-invalidate request equal a reference model of reset, trap and Debug Mode entry, DRET, and CSR writes after each edge, from arbitrary state; the `mstatus`, `mie`, and privilege next state equals the reference's for the same current state. The trap unit's entry enables must match its trap inputs. Unbounded. `prove_integrated` and `prove_perf_off` use the CPU's setting, in which a CSR commit never coincides with a trap or xRET |
| `csr_file` | CSR and privilege updates on traps, xRETs, and debug entry and exit, plus counters, `fflags`, and FS state, with the profiling counters present and absent (`bmc_perf_off`). Assumes traps, xRETs, and CSR writes never coincide, FP-state updates never coincide with a CSR write, privilege and debug transitions are legal, the entry enables match the trap inputs, and trap PCs are 2-byte aligned |
| `mispredict_capture` | While misprediction recovery is pending, the captured recovery payload equals a register loaded only on a mispredicted commit; bounded and unbounded |
| `reorder_buffer` | Occupancy and pointers, allocation into free entries, commit only of a done head, serializer control of traps, fences, CSR writes, and translation drains, and flush and reset. Assumes legal dispatch and completion traffic, including no CDB completion for an entry allocated the previous cycle or for a head the serializer holds. Depth 12 does not reach a full buffer with pointer wraparound |
| `rob_alloc_lvt` | The packed allocation-payload memory equals separate per-field memories; unbounded |
| `rob_bypass_control` | The head's completion bypass equals the OR of the per-lane bypasses, for arbitrary state and CDB inputs |
| `rob_control_next` | Per-entry valid, done, exception, and replay next state equals the reference indexed writes, including reset, allocation coinciding with completion or commit, and stale tags |
| `rob_retire_ready` | Per-entry retirement eligibility (completion, two-wide, misprediction) equals the selected-field expressions, and both head masks stay one-hot; unbounded, assuming an initial reset |
| `rob_retire_stall` | Retirement strobes and every performance event equal a reference built from the serializer's full commit stall |
| `rob_start_cofactor` | CSR and xRET start signals equal the reference equations, the head mask stays one-hot, and CSR and xRET entries never take the CDB bypass; unbounded. Assumes an initial reset |
| `trap_unit` | Traps, interrupts, xRETs, and debug entry: mutual exclusion, priority (debug over M over S), targets, nothing taken while the pipeline is stalled, and waiting for committed stores to drain; the split trap-entry target and take outputs equal the reference ones. Assumes the start events are mutually exclusive. `prove` shows that `csr_file`'s entry enables equal the take and steering outputs from arbitrary state |

### Execution units and CDB

| Target | Checks |
| --- | --- |
| `alu_shift_hint` | An ALU given the precomputed shift amount matches one without it, and both match an independent shift and rotate reference |
| `cdb_arbiter` | The two-lane grant tree equals a reference priority scan. Grants are one-hot per lane, disjoint, at most two, and only to valid requesters, and a kill clears both CDB valid bits and the visible grants. Assumes the ALU value-source rule: a live value belongs to a valid completion and equals its value, and otherwise the fallback value does |
| `divider` | Every result equals the RISC-V result for all operands (signed and unsigned, divide by zero, overflow, and W forms), a result appears one cycle after the last step and stays until taken, a kill frees the divider on the next cycle, and only a start leaves idle, at 8 bits (`bmc_width8`). `prove_width64` proves the step count and remainder bound at 64 bits, unbounded. See below |
| `fp_shim` | Busy exactly while the engine holds an operation, results only while busy and with the tag of the latest operation, a kill frees the engine on the next cycle, and no later result for an operation a flush squashed (a result in the flush cycle itself is the CDB adapter's to drop). The engine is replaced by a model with arbitrary latency, results, and flags. Assumes FP_RS issues only while the shim is not busy |
| `fp_launch_squash` | Both launch modes match a reference launch-gated shim, all with real FP engines: the same busy and completion valid every cycle and the same valid completions; unbounded, assuming equal initial state, no issue while busy, and, with `LAUNCH_SQUASH=1`, the bubble after a flushed issue |
| `fp_launch_squash_rs` | The real FP station with the wrapper's tie-offs leaves the bubble after a flushed issue that `LAUNCH_SQUASH` needs; unbounded |
| `fu_cdb_adapter` | Pass-through, hold under back-pressure with a stable payload, a clear on a grant with no new result behind it, on a full flush, or on a partial flush that squashes the held result, and no stale output after a squash. Covers the default combinational output, not `REGISTER_OUTPUT=1`. Assumes full and partial flushes never coincide |
| `fu_cdb_adapter_payload_no_refill` | The adapter with `ALLOW_GRANT_REFILL_PAYLOAD_WRITE=0`, as the ALU adapters use it. Assumes no result arrives while one is held, which the wrapper guarantees |
| `int_muldiv_shim` | Every tracked multiply sits in the pipeline for its width, the MUL FIFO credits hold under back-pressure and flushes, and each surviving completion takes its product from the matching multiplier. For the divider: `o_div_busy` is high exactly while it is not idle, a completion carries the tag of the latest divide, a kill frees it on the next cycle, and a squashed divide never completes. Runs with the word multiplier on and off (`*_fallback`). Assumes a reset on the first cycle and divides presented only while the divider is idle. Arithmetic values and liveness are out of scope |
| `mul_completion_tag` | Leaving the MUL result's tag unqualified on invalid cycles changes no adapter state, valid result, or arbiter input. Assumes one initial reset |
| `mul_adapter_grant` | With the real CDB arbiter, the MUL adapter's local grant and the always-granted MUL and MEM adapters produce the same completions and pending bits as stateful adapters, under arbitrary competing results, flushes, and tags; unbounded |

`divider` compares results with Verilog division at 8 bits, where division is
cheap for the solver; the divider is the same RTL at every width. A start
reloads all of the divider's state, so an operation behaves the same whatever
came before it, and the 14-cycle bound (one complete operation with arbitrary
operands, kills, and accept delays) covers every operation. The 64-bit
divider runs in the `divider` simulation, against Python integer division.

### Memory system and coherence

| Target | Checks |
| --- | --- |
| `cache_mshr_payload` | Per-entry MSHR data and byte strobes equal the reference indexed fill and store merge, including fills that coincide with stores, on every byte that can be read, in a 256-byte cache with 8-byte lines |
| `coherence_observation` | The load queue's coherence port tracks one arbitrary ROB tag's observations through retirement, flush, and tag reuse, and replays it when DMA invalidates its line. See below |
| `coherence_replay_compare` | DMA-invalidation replay masks built from chunked compares equal full-width line equality at XLEN 32, 64, and 66. Assumes one initial reset |
| `data_mem_request_router` | Device reads are staged and accepted only after committed stores drain, a flush cancels an unaccepted device read, read enables match acceptances, and a blocked request keeps its address. Assumes the load queue presents no new read while one is held |
| `data_mem_response_mux` | Load data selected among BRAM, MMIO, and cached DDR equals the reference selection at 32 and 64 bits, for portable and Xilinx LUT5 builds |
| `dmmu_mmio` | The DMMU's MMIO classification, the DTLB's per-entry device-window, atomic, and permission checks, and the stage-2 address split equal the reference logic |
| `immu_bare` | With translation off, the IMMU's physical addresses and fault flags equal the reference for every PC, and word 1's fault is the PMA check of the next page. The XLEN 32 and 72 variants check only Bare mode and width conversion |
| `immu_page_offset` | Translation preserves the page offset, and the visible physical addresses equal the reference; unbounded. The ITLB is replaced by arbitrary outputs. Assumes one initial reset |
| `line_arbiter_grant` | Three-port line arbiter grants equal the reference starvation-priority rule, for portable and Xilinx-primitive builds |
| `line_port_axi_bridge` | AR, AW, and W hold steady until accepted, also through a CPU reset, and are low through the AXI side's reset, which drops them; read responses carry the right ID, stale read responses are dropped, and in-flight IDs are tracked. Write responses have no ID checks. Assumes unique in-flight IDs |
| `low_bram_presenter_tier` | `low_bram_fetch_presenter` presents the same low-BRAM fetch responses with and without separate address retargeting. See below |
| `ptw` | The page-table walker against a reference PTE classification: one outstanding read, always to DDR, the right result for a valid leaf, a descent only through a pointer the classification accepts, a page fault only for a reason the PTEs give, never a misalignment fault, and no response for a discarded walk. The cause of an access fault is not checked. Assumes a response arrives only for an outstanding read |
| `sc_head_query` | The coherence match for the store-conditional at the ROB head equals a direct 32-byte-line compare of its address, from arbitrary table state |
| `tlb` | Lookup, insert, and invalidate-all: a watched entry stays intact and every matching lookup hits it, no port hits while no entry is valid, invalidate-all clears everything, and the one-hot lookup select returns the lowest matching entry's fields, for the DTLB (16 entries, 3 ports) and ITLB (8 entries, 2 ports) shapes |

`coherence_observation` follows an arbitrary ROB tag, so it covers all 32 at
XLEN 64: the pending observation, its table entry and line, cleanup on
retirement or flush, the registered replay mask, and table payloads that a
flush or reset should have discarded staying invisible. It assumes an initial
reset and that neither commit lane retires a tag observed in the current or
previous cycle; `prove_unrestricted` drops that timing assumption and still
proves flush cleanup, commit cleanup when no observation overlaps, and that a
pending write wins over a coinciding commit. Because the replay mask is
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
| `async_fifo` | The NIC's clock-crossing FIFO with two unrelated free-running clocks: occupancy bound, conservative credits, ready margin, no underflow, Gray-coded pointers, and in-order, intact delivery of a watched word, at 4 entries of 4 bits. Both resets are held for the first six steps; registers start at their reset values, because a clock may have no edge during the reset window |

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

## Yosys SVA Limitations

Yosys supports a subset of SystemVerilog Assertions:

- Use immediate assertions inside `always_comb` or clocked `always` blocks.
- Use `!a || b` for implication. The concurrent form `a |-> b` is not
  available.
- Use `$past(signal)` for sequential properties.
- No hierarchical references (`u_sub.signal`): assertions must sit inside the
  module they check.
