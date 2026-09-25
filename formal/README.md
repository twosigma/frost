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
| `branch_prediction_alias` | The slot-1/slot-2 alias output computed from the base PC, which the fetch stage uses when its XLEN matches `riscv_pkg::XLEN`, equals the generic computation under the stage's base+2/base+4 wiring. Only this output is compared, not the whole controller |
| `branch_prediction_disable` | The prediction-use gates for both slots and slot 2's live/staged target select equal the reference equations, and disabling prediction blocks both the live and the staged path. Predictor outputs are arbitrary |
| `btb_tag_compare` | The grouped BTB tag compare equals full-width tag equality: 55-bit tags for the 256-entry BTB and 59-bit tags for a 16-entry one, with arbitrary RAM outputs |
| `c_ext_buffer_next` | The compressed-instruction buffer's next state equals the reference clear/capture/hold priority |
| `c_ext_state_cofactor` | The same next state with the pending-prediction handoff factored out equals the reference, and a handoff never keeps old-path buffer state. `prediction_release` checks the real producers of these inputs |
| `control_flow_holdoff` | Redirect and reset holdoff next state equals the reference equations |
| `fetch_pc_mux` | The next-fetch-PC mux equals the reference priority and one-hot expressions, for portable and Xilinx-primitive builds, standalone and with `PENDING_HANDOFF_EXCLUDES_SLOT2=1` (`bmc_integrated*`) |
| `fetch_redirect` | The registered fetch-redirect pulse, computed ahead for each prediction outcome, equals the reference priority equation; bounded and unbounded |
| `if_direction_payload` | Dropping the NOP term from the branch-direction payload select changes no non-NOP packet, including stall replay through the real `stall_capture_reg`. Assumes a flush on the first cycle, which initializes the saved-NOP bit |
| `pc_holdoff_cofactor` | The three fetch-holdoff outputs equal their reference equations. `pc_holdoff_tag` covers the prediction holdoffs |
| `pc_holdoff_tag` | While a prediction is pending, its captured predecessor-PC tag equals its PC minus 2, and outside reset the prediction holdoffs equal their reference equations; unbounded, at XLEN 32, 64, and 72, including address wraparound. Assumes only that the pending-prediction valid bit starts clear, its reset value |
| `pc_increment_holdoff` | Both sequential next PCs equal the reference per-size candidates with holdoff and NOP selection, for portable and Xilinx-primitive builds |
| `pc_pending_capture` | The pending-prediction valid bit's next state equals the reference clear/set/hold priority |
| `pc_register_mux` | The architectural-PC mux equals the reference nested priority, in the same configurations as `fetch_pc_mux` |
| `prediction_handoff` | `prediction_release` with `PENDING_HANDOFF_EXCLUDES_SLOT2=1`, the setting the fetch stage uses |
| `prediction_metadata_output` | Each packet's BTB-taken bit equals the reference priority, and while a prediction is saved or pending, a packet it does not belong to never reports taken. `prediction_metadata_tracker` checks the sequential behavior |
| `prediction_metadata_tracker` | A pending prediction's saved PC and target stay unchanged until their packet consumes them or a reset or redirect kills them, plus the tracker's own validity and payload checks. See below |
| `prediction_release` | Pending-prediction outputs are masked while nothing is pending, a ready handoff raises both prediction holdoffs, and the holdoff outputs, predecessor-PC tags, `pc_reg[1]` replica, and lower-parcel lookup geometry match their reference relations. See below |
| `ras_checkpoint` | The return-address stack's next pointer and count equal the reference equations |
| `rvc_predecode` | The fill-time RV64C expansion and illegal flag equal the reference decompressor (`rvc_decompressor`) for all 65,536 16-bit parcels |

`prediction_release` runs the real `pc_controller` and `c_ext_state`
together. The harness replaces the PC-increment calculator with one whose
outputs are unconstrained, which admits every real PC movement and more, and
it makes predictor requests arbitrary. It assumes only a reset on the first
cycle; later resets and stalled redirects are free. `prediction_handoff` runs
the same harness with the fetch stage's parameter setting. Both have `bmc`,
`cover`, and ABC PDR `prove` tasks.

`prediction_metadata_tracker` models the registered predictor target, which
may change while fetch runs and holds during a stall, and leaves the pending
and output PCs arbitrary, so the proof covers both the packet a prediction
belongs to and a real older packet at another PC. PCs are 8 bits wide. It
assumes a reset on the first cycle and these relations, which the fetch
stage guarantees: saved values are replayed only during a registered stall;
the live target is used only when it is aligned with the output packet, no
stall is registered, and no registered or pending prediction exists; and a
reset cycle inserts a NOP and uses neither saved nor live metadata.

### Decode, rename, and dispatch

| Target | Checks |
| --- | --- |
| `decoded_bundle_queue` | FIFO order and payload preservation against an independent queue model, unbounded, at depths 4 and 2 (`prove_depth2`), with covers for empty bypass, full, wraparound, simultaneous push and pop, and flush of a nonempty queue. See below |
| `dispatch_admission` | Bundle and slot-2 admission equal the reference equations. `bmc_queued` checks the CPU's setting (`SLOT2_VALID_FROM_BUNDLE=1`) and assumes the decoded-bundle queue's guarantee that slot-2 valid equals the packet's not-NOP bit whenever dispatch is valid |
| `instr_operand_classifier` | Decode's direct operand-class fields equal classification through the instruction decoder's operation enum, for every instruction bit pattern, injected NOPs, illegal flags, and fetch faults |
| `register_alias_table` | x0 is never renamed; a rename records its ROB tag; an INT commit clears a mapping only if the mapping still holds the committing tag; reset clears mappings and checkpoints; a full flush clears the checkpoints and, unless a checkpoint restore coincides, the mappings; a reclaim-all restore frees every checkpoint |

`decoded_bundle_queue` uses an 8-bit symbolic payload, so the check does not
depend on decode fields. The proof also covers the registered copy of the
head entry and a 3-bit registered shadow, which must equal the same slice of
the output packet; the harness ties the shadow input to the payload's low
bits. It assumes an initial reset, that the consumer pops only a valid
bundle, that the producer never replaces a bundle before it is accepted, and
that the producer's announced next shadow value (`i_shadow_next`) arrives on
the next cycle. In simulation the last three are assertions.

### Reservation stations and the Tomasulo wrapper

| Target | Checks |
| --- | --- |
| `mem_wakeup_merge` | An early load wakeup keeps both registered CDB broadcasts and puts the load on at most one idle lane. Assumes the load's tag is not on a valid registered lane; `tomasulo_wrapper` asserts that instead, after its initial reset. Whether the load is accepted and broadcast later is the caller's responsibility |
| `reservation_station` | Dispatch, wakeup, issue, and flush properties at the module defaults and with the INT station's features. See below |
| `rs_alloc_parallel` | The parallel search for the first and second free entries equals the reference serial search at depths 4, 8, 16, and 32, including zero or one free entry |
| `rs_dispatch_defer` | Dispatch's six CDB-deferral decisions (three sources in each of two slots) equal the reference equations, with and without insertion-time repair (`bmc_repair`) |
| `rs_issue2_selector` | The INT station's balanced second-issue-port selector (the lowest ready non-branch entry other than the first ready entry) equals a serial reference scan at 16 entries |
| `rs_issue_clear` | The second issue port's one-hot entry clear equals the reference indexed clear: single issue at depth 16, dual issue at depths 4 and 32, and the INT station's parameters at depth 8 and at depth 16 with an 8-entry window |
| `rs_pretag_cofactor` | The pre-issue ROB tag, computed ahead for each of the four combinations of the two CDB valid bits, equals the reference priority select, including the idle case, in two station configurations (`bmc`, `bmc_tag_indexed`). The MEM station, its only production user, adds raw-wakeup candidates; `rs_raw_pretag` checks that form |
| `rs_raw_pretag` | With the real early-wakeup merger in front, the pre-issue tag selected from eight raw-wakeup candidates equals the MEM station's reference winner |
| `tomasulo_wrapper` | The back end together (ROB, RAT, six stations, CDB arbiter, and memory queues): commit clears a rename only if no newer write renamed the register, a full flush or reset empties every structure, each station's copy of the CDB matches the bus, and the stations' ROB-tag rule holds with the real ROB allocator. See below |

`reservation_station` checks the module's default parameters at BMC depth
12. No production station uses exactly those defaults; `tomasulo_wrapper`
checks all six stations with their production parameters. The `*_tag_indexed`
tasks turn on the INT station's features at 8 entries, with BMC depth 7;
that enables properties the defaults leave inactive. Both have depth-20 cover
tasks. Standalone, the station assumes a reset, a legal dispatch environment
(for example, no dispatch during a partial flush or into a full station),
and, for the INT features, that a dispatched ROB tag is not already live in
the station and that two dispatches in one cycle carry different tags. The
deferred CDB delivery checks stop short of the final write of the broadcast
value into the source-value array; directed cocotb tests and simulation
assertions cover that step.

`tomasulo_wrapper` replaces those assumptions with the real allocator. It
builds every station with `FORMAL_STANDALONE_ENV=0`, which keeps the
station's assertions, drops its standalone assumptions, and turns the tag
rule into an assertion. The INT station has its real 16 entries and 8-entry
second-issue window. Dispatch uses the single-slot bus
(`SPLIT_RS_DISPATCH=0`), so the stations and memory queues never receive two
dispatches in one cycle. The CPU uses split two-slot dispatch; the standalone
`reservation_station` tasks cover two dispatches into one station. Besides a
reset and legal back-pressure, rename, and checkpoint inputs, the environment
assumes that dispatch comes with an allocation and uses that cycle's
allocated ROB tag, that a partial flush names a live ROB entry, and that
address translation is off; the `tlb` and `ptw` targets and the `vm_test`
simulation cover translation. At depth 4 the proof does not reach ROB tag
wraparound; simulation covers tag reuse. `fmul_repair_bmc` enables the FMUL
dispatch done repair, as the CPU does (`ENABLE_DISPATCH_DONE_REPAIR=1`), and
assumes that dispatch's repair channels carry the pending FMUL instruction's
source readiness and tags.

### Load and store queues

| Target | Checks |
| --- | --- |
| `load_queue` | Allocation and back-pressure, dependency cleanup, memory issue, router cancellation, staged AMOs, and CDB broadcast, with busy-port load preparation on and off (`*_no_prepare_busy`). Uses the module defaults, without the pre-issue candidate compares and store-forwarding path the CPU enables (`lq_prematch_cofactors` and `lq_ram_payload` check those), and assumes each address update follows its pre-issue look-ahead and live entries hold distinct ROB tags. `prove_pre_match` proves, unbounded and with no assumptions, that the split pre-issue match registers equal a direct registered compare |
| `load_queue_amo_compute` | AMO capture of operands and memory tier, the result of every AMO except MIN and MAX (whose selection `load_queue` checks), kill on reset or flush, coherence blocking, and stable write data, checked over 4 cycles. See below |
| `lq_alloc_mask` | The parallel first and second allocation masks, cyclic from the cursor, equal the reference binary search and capacity checks at depths 4, 8, and 16 |
| `lq_cached_flags` | Cached-slot invalidation and LR-suppression next state equals the reference priority equations |
| `lq_cached_hold` | Cached-slot hold next state equals the reference reduction over the full slot mask |
| `lq_capacity` | The full and full-for-two flags, built from grouped free-entry terms, equal comparisons of the entry count |
| `lq_l0_cache` | The L0 load cache at 128 and 256 entries: MMIO never hits, a hit needs a valid entry with a matching tag, a fill then hits with its data, and a flush or DMA line invalidation clears entries (invalidations from stores and AMO writes are only covered, not asserted). Covers the cache alone, not the coherence of executed loads through retirement |
| `lq_prematch_cofactors` | Registering a tag compare for each of four pre-issue candidates (eight in `*_raw`, the CPU's setting) and selecting afterward equals registering the compare against the selected tag; bounded and unbounded. A simulation assertion checks that the separate scalar tag input equals the selected candidate |
| `lq_ram_payload` | The load-result RAM's two write ports equal the reference mux: enables always match, and address and data match whenever enabled. Default, store-forwarding (`bmc_forward`), and forwarding-without-L0 (`bmc_forward_only`) builds, with arbitrary RAM and cache outputs. A separate assertion shows that a cache hit never coincides with a staged AMO at the ROB head, so the payload select can ignore that case |
| `lq_response_bypass` | The load-response bypass pulse equals the reference pulse qualified by full acceptance. It omits the reference's age comparison, which the separate partial-flush guard makes redundant |
| `lq_tag_order` | ROB-tag age order and the full-window boundary equal the reference computed in wider arithmetic, for all tags |
| `sq_committed_empty` | Committed-empty next state equals the reference equation over reset, full flush, and registered and same-cycle commits |
| `sq_live_count` | The live store count's next value equals the reference arithmetic for each of the three allocation outcomes and for the selected result |
| `sq_repair_mmio` | The early-address repair's two parallel MMIO flags equal MMIO classification of the full-width base-plus-immediate sum, including overflow |
| `store_queue` | Live-count consistency, write prerequisites (committed, address and data valid), in-flight bounds, forwarding, and that committed stores survive a partial flush. Formal builds replace the forwarding unit's balanced winner tree with a linear selector, because Yosys mishandles the tree's array of structs, so the tree itself is not proved. Assumes, among other input rules, no allocation while the post-flush tail pullback is pending and no pulse on the combinational commit inputs during a flush (registered commits may overlap one) |

`load_queue_amo_compute` starts from arbitrary state, with no reset or
admission assumptions, so it includes AMO states the queue cannot normally
reach. It makes no claim about scheduling, interrupts, or liveness. Its
script counts the named checks it relies on (`p_local_*`, `cover_local_*`,
and `p_lq_*_free_tree_*`): adding or renaming one of those means updating the
count, while other assertions in `load_queue.sv` do not affect it.

### ROB, CSRs, traps, and recovery

| Target | Checks |
| --- | --- |
| `csr_commit_cofactor` | On every edge, most CSR storage (not `mstatus`, `mie`, `fflags`, `frm`, or the debug CSRs), both counters, and the translation-invalidate request equal a reference model of their reset, trap-entry, and CSR-write transitions, from arbitrary state; unbounded. `prove` covers all inputs. `prove_integrated` and `prove_perf_off` use the CPU's setting, in which a CSR commit never coincides with a trap or xRET; that is a premise of the property, not an assumption |
| `csr_file` | CSR and privilege updates on traps, xRETs, and debug entry and exit, plus counters, `fflags`, and FS state, with the profiling counters present and absent (`bmc_perf_off`, the top-level default). Assumes that traps, xRETs, and CSR writes never coincide with each other, that FP-state updates never coincide with a CSR write, that privilege and debug transitions are legal, and that trap PCs are 2-byte aligned |
| `mispredict_capture` | While misprediction recovery is pending, the captured recovery payload equals a register loaded only on a mispredicted commit; bounded and unbounded |
| `reorder_buffer` | Occupancy and pointers, allocation into free entries, commit only of a done head entry, serializer control of traps, fences, CSR writes, and translation drains, and flush and reset. Assumes legal dispatch and completion traffic, including no CDB completion for an entry allocated in the previous cycle or for a head the serializer owns. BMC depth 12 does not reach a full buffer with pointer wraparound |
| `rob_control_next` | Per-entry done, exception, and replay next state equals the reference indexed writes, including reset, allocation coinciding with completion, and stale tags |
| `rob_retire_stall` | Retirement strobes and every performance event equal a reference built from the serializer's full commit stall, with the real serializer wiring |
| `rob_start_cofactor` | CSR and xRET start signals equal the reference equations, the head mask stays one-hot, and CSR and xRET entries are never marked for CDB bypass; unbounded. Assumes an initial reset, with arbitrary payload RAM and serializer outputs |
| `trap_unit` | Traps, interrupts, xRETs, and debug entry: mutual exclusion, priority (debug over M over S), targets, nothing taken while the pipeline is stalled, and waiting for committed stores to drain. Assumes the start events are mutually exclusive |

### Execution units and CDB

| Target | Checks |
| --- | --- |
| `alu_shift_hint` | An ALU given the precomputed shift-amount hint matches one without it, and both match an independent shift and rotate reference. `rs_issue2_shamt` simulation covers how the station captures and holds the hint |
| `cdb_arbiter` | The two-lane grant tree equals a reference priority scan. Grants are one-hot per lane, disjoint, at most two, and only to valid requesters, and a kill clears both CDB valid bits and the visible grants. Assumes each ALU's early value equals its completion value |
| `divider_prefix` | Each divider stage equals two steps of full-width restoring division, at 64 and 32 bits. Assumes a bound on each stage's incoming remainder; see below |
| `fp_add_shim` | FP add, compare, classify, sign-inject, and convert pipeline: busy only while an operation is in flight, results carry their tag, and an operation flushed before its completion cycle produces no output |
| `fp_div_shim` | FP divide and square-root control: busy tracks occupancy, results carry their tag, a new operation never overwrites a held result, and a squashed operation never completes, except on the full-flush cycle itself, where the CDB arbiter's kill suppresses it. The arithmetic unit is replaced by a model with arbitrary latency, results, and flags |
| `fp_fma_align` | FMA alignment shift amounts equal max-exponent subtraction for all exponents, at single and double precision |
| `fp_mul_shim` | FP multiply and FMA pipeline: queue and result-FIFO counts stay in range, credits are conservative, and each payload FIFO's count matches its source |
| `fp_mul_shim_order` | The FP multiply shim with the tag-order proof: an arbitrary operation's tag leaves its subunit's tag queue in the cycle its own result leaves the subunit (11 cycles for a multiply, 16 for an FMA), after every older one, and the result ring presents it with its tag and source after every older entry |
| `fp_payload_read` | The FP multiply shim's two payload-RAM prefetch addresses equal the reference pointer-plus-pop expressions, including pointer wraparound |
| `fu_cdb_adapter` | The FU-to-CDB holding register: pass-through, hold under back-pressure with a stable payload, a clear on a grant with no new result behind it, on a full flush, or on a partial flush that squashes the held result, and no stale output after a squash. Checks the default combinational output, not the registered output (`REGISTER_OUTPUT=1`) of the DIV and FP adapters. Assumes full and partial flushes never coincide |
| `fu_cdb_adapter_payload_no_refill` | The adapter with `ALLOW_GRANT_REFILL_PAYLOAD_WRITE=0`, as the two ALU adapters use it. Assumes the FU never presents a result while one is held; the wrapper guarantees this by gating issue |
| `int_muldiv_shim` | Every tracked MUL or DIV operation sits in the pipeline for its width (full or short word), the shared FIFO credits hold under back-pressure and flushes, and each surviving completion takes its result from the matching pipeline (`prove_alignment*`). Runs with short word paths on and off (`*_fallback`). Assumes a reset on the first cycle only. Arithmetic values and liveness are out of scope |
| `mul_completion_tag` | Passing the MUL result's tag through unqualified on invalid cycles, instead of zeroing it, changes no adapter state, valid result, or arbiter input. Assumes one initial reset |

`divider_prefix` proves the narrowed divider stage by stage. Each stage
assumes that its incoming remainder fits in the bits consumed so far and
proves the same bound for its outgoing remainder. Every transaction starts
with a zero remainder, including division by zero, so the per-stage results
chain into a proof for every valid result. Stale data left in the pipeline
after reset need not satisfy the bound, because reset clears every valid bit.

### Memory system and coherence

| Target | Checks |
| --- | --- |
| `cache_mshr_payload` | Per-entry MSHR data and byte-strobe next state equals the reference indexed fill and store merge, including fills that coincide with W-stage stores, in a 256-byte cache with 8-byte lines |
| `coherence_observation` | The load queue's coherence port tracks one arbitrary ROB tag's observations through retirement, flush, and tag reuse, and replays it when DMA invalidates its line. See below |
| `coherence_replay_compare` | DMA-invalidation replay masks, computed with chunked compares against local copies of the invalidated line, equal full-width line equality, at XLEN 32, 64, and 66. Assumes one initial reset |
| `data_mem_request_router` | Device reads are staged and accepted only after committed stores drain, a flush cancels an unaccepted device read, read enables match acceptances, and a blocked request keeps its address. Assumes the load queue presents no new read while one is held |
| `data_mem_response_mux` | Load data selected among BRAM, MMIO, and cached DDR equals the reference selection at 32 and 64 bits, for portable and Xilinx LUT5 builds |
| `dmmu_mmio` | The DMMU's MMIO classification and its stage-2 MMIO bit's next value equal the reference resolve-and-hold logic, and the DTLB's per-entry device-window bit equals the window decode of the PPN it selects |
| `immu_bare` | With translation off (Bare), the IMMU's physical addresses and fault flags equal the reference for every PC. The XLEN 32 and 72 variants check only Bare mode and width conversion, not Sv39 |
| `immu_page_offset` | Translation preserves the page offset, and the visible physical addresses equal the reference; unbounded. The ITLB is replaced by arbitrary outputs, including answers a real ITLB could not give. Assumes one initial reset |
| `line_arbiter_grant` | Three-port cache line arbiter grants equal the reference starvation-priority rule, for portable and Xilinx-primitive builds |
| `line_port_axi_bridge` | Line port to AXI: AR, AW, and W hold steady until accepted, through a CPU reset as well, and are low through the AXI side's reset, which drops them; read responses carry the right ID, stale read responses are dropped, and in-flight IDs are tracked. Write responses have no ID or stale-response assertions. Assumes unique in-flight IDs |
| `low_bram_presenter_tier` | `low_bram_fetch_presenter` presents the same low-BRAM fetch responses with and without separate address retargeting. Assumes reset on the first two cycles; see below |
| `ptw` | Page-table walker against a reference PTE classification: one outstanding read, always to DDR, the right result for a valid leaf, a page fault only for a reason the PTEs give, never a misalignment fault, and no response for a discarded walk. The cause of an access fault is not checked. Assumes a response arrives only for an outstanding read |
| `sc_head_query` | The coherence match for the store-conditional at the ROB head, built from parallel per-entry compares, equals a direct 32-byte-line compare of its address, from arbitrary table state |
| `tlb` | Lookup, insert, and invalidate-all: a watched entry stays intact and every matching lookup hits it, no port hits while no entry is valid, and invalidate-all clears everything, in the DTLB shape (16 entries, 3 ports) and the ITLB shape (8 entries, 2 ports) |

`coherence_observation` follows an arbitrary ROB tag, so it covers all 32 at
XLEN 64: the pending observation, its table entry and line, cleanup on
retirement or flush, and the registered replay mask. It assumes an initial
reset and that neither commit lane retires a tag observed in the current or
previous cycle. The real load queue observes a load before it completes,
broadcasts, and retires, but this proof does not establish that timing. Later
resets, flushes, head tags, and DMA inputs are unconstrained, and repeated
observations may even use different lines. Because the replay mask is
registered, it can name an observation that was cleared on the same edge;
ROB acceptance and allocation timing must keep such a mask from affecting the
tag's next user. That integration, DMA progress, and atomic exclusion are
outside this target. `prove_unrestricted` drops the timing assumption,
keeping only the initial reset, and still proves flush cleanup, commit
cleanup when no observation overlaps, and that a pending write takes priority
over a coinciding commit. The covers reach both commit lanes, full and
partial flushes, circular tag order, a long-lived observation, tag reuse with
a changed line, and replay from both the pending register and the table.

`low_bram_presenter_tier` compares response validity, addresses, PC, faults,
and data, bounded and unbounded (ABC PDR). The comparison holds only while
PA0[31] is clear in the current and previous cycles. When it is set, the
high-address provider must own the fetch and mask the low responses. The
proof assumes a reset on the first two cycles, which clears arbitrary memory
history; later resets and all fetch controls are unconstrained.

### Peripherals

| Target | Checks |
| --- | --- |
| `async_fifo` | The NIC's clock-crossing FIFO with two unrelated free-running clocks: occupancy bound, conservative credits, ready margin, no underflow, Gray-coded pointers, and in-order, intact delivery of a watched word, at 4 entries of 4 bits. Both resets are held for the first six steps and then released; the registers start at their reset values, because a clock may have no edge during the reset window |

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
