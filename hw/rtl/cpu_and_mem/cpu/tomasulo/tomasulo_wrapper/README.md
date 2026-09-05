# Tomasulo Wrapper

The wrapper connects the ROB, RAT, six reservation stations, LQ, SQ, CDB,
adapters, and FU shims to `cpu_ooo.sv`. Cross-module glue lives here or in
the private submodules below.

| Submodule | Dir | What it holds |
|-----------|-----|---------------|
| `tomasulo_perf_counters` | `perf/` | The 64 back-end performance counters: accumulate, snapshot into four banks, CSR-style readout. |
| `commit_bus_pipeline` | `commit_bus/` | Registers both combinational ROB commit buses and the decomposed `commit_q_*` fields. |
| `sq_early_addr_pipeline` | `store_addr/` | The dual-ported early store-address stage. It registers the dispatch base and immediate, adds them the next cycle off the dispatch critical path, and produces the two SQ early-address update packets. A store whose base is not ready at dispatch becomes a persistent repair candidate (below). |
| `dispatch_rs_router` | `dispatch_routing/` | Decodes both dispatch packets into per-RS valid and slot-1 intent signals. |
| `sc_pending_unit` | `atomics/` | Store-conditional resolution: a per-ROB-tag table of in-flight SCs (allocated at MEM_RS SC issue, freed on fire or flush), the head-match fire/success decode, and the `sc_fu_complete` packet. |

A repair candidate in `sq_early_addr_pipeline` waits for its base tag on the
dispatch done-repair channels or the live CDB lanes, using an exact balanced
priority tree when several sources match. While it waits, a payload-only
sideband may refresh the still-hidden SQ address; the packet `valid` stays the
only visibility control. If a fresh update owns the SQ port in the cycle the
base arrives, the candidate latches the repaired base and drains on the next
free cycle. A candidate is evicted by a newer un-ready store on the same slot,
killed when MEM_RS issues its store (which also closes the ROB-tag-reuse
window), and cleared on flush.

The per-RS dispatch-valid nets carry `(* max_fanout = 32 *)` both inside
`dispatch_rs_router` and on the wrapper-side receiving nets, where the fanout
to the RS instances happens, so the constraint survives flattened or
hierarchical synthesis.

The SQ early-address pipeline receives one narrow, phase-identical registered
copy of each CDB lane, carrying only `valid`, `tag`, and the XLEN-wide value.
The copies capture the arbiter fallback value at the CDB edge and restore the
live ALU value after Q. They are kept physically distinct, carry no
`max_fanout`, and feed only `sq_early_addr_pipeline`, so its repair cone can
place locally.

The rest of the glue stays inline in the wrapper: the store-misalign and
MEM-adapter mux around `sc_pending_unit`, flush coordination, the FMUL repair
queue, and the FU-shim wiring. It is tightly coupled to the rest and carries
load-bearing synthesis attributes (`max_fanout`, `keep`) whose placement is best
left undisturbed.

## Inline glue logic

### Done-repair locality

Dispatch registers six renamed-source tags for the ROB done/value lookup, but
those tags are not broadcast into every resident RS entry. The INT, MUL, and
MEM stations, which take dispatch packets directly, set
`ALLOC_INDEXED_REPAIR`: each station captures the one-hot entry allocated by
the relevant dispatch slot and writes the returning channel straight into that
entry's fixed source position one cycle later. The repair latency stays
registered, and there is no six-channel global CAM with its wide source-value
write enables.

FP, FMUL, and FDIV packets pass through one-entry wrapper buffers before their
stations, and each buffer folds the dispatch-time done-repair response into
the packet before it crosses into the RS. A one-cycle phase marker
(`*_pending_repair_capture_q`) identifies the response aligned with a newly
captured packet. If an operand is unresolved and its query was valid, the
buffer holds dequeue on that E1 edge, stores the response, and dequeues the
registered payload on E2. FP and FDIV consume channels 1 and 2; FMUL also
consumes channel 3 for its third source. Production dispatch guarantees that
every unresolved FMUL operand has a valid matching query, so FMUL registers
its capture-edge hold verdict directly from the unresolved bits; an
unresolved/no-query standalone stimulus is outside that interface contract.
A packet that is ready at capture—or, for FP/FDIV, has no valid E1 query—keeps
the one-buffer-cycle path and takes no repair hold. Recovery or RS
back-pressure can retain the packet after E1; live CDB updates keep landing
while it waits, and later done-repair queries cannot alias the expired
dispatch query. The three stations therefore use only the two live CDB snoops,
with the global repair ports tied off.

### FMUL operand-repair queue

FMUL_RS is the only station with three sources. Every FMUL/FMA packet spends
at least one cycle in the one-entry queue. The queue launches the registered
dispatch-time ROB queries on channels 1, 2, and 3 and captures each aligned
response into the pending packet. An unresolved packet is held through that E1
edge under the production query-valid contract above, and only the registered
packet reaches the RS on E2. This replaces three packet-tag-driven copies of
the ROB value RAM and the wide live ROB-to-RS path they created. Either CDB
lane can still wake a packet retained by RS back-pressure or recovery; lane 0
has priority over lane 1, and both have priority over an aligned done-repair
response. Dequeue and refill in the same cycle resume only after the one-cycle
response window, so a stale response is never written into the replacement
packet.

The default BRAM CoreMark path is integer-only and never dispatches FMUL, so
the extra hold for queried FMUL operands is cycle-neutral for that benchmark.

### SC state machine

The SC tracking table and its fire/success decode live in
`atomics/sc_pending_unit.sv`. The surrounding store-misalign path and the
MEM-adapter mux stay in the wrapper; the mux feeds the MEM adapter with, in
priority order, the registered SC completion, the registered misaligned-store
fault, and the LQ result.

Store-conditional execution is split between MEM_RS issue and ROB-head commit.
MEM_RS issues the SC like a normal store; the LQ holds the LR reservation
register and snoops every SQ memory write to invalidate it on a matching
address. The SC fires only when its ROB entry reaches the head, the SQ is
committed-empty, and the entry's physical address is known (under data
translation the DMMU fills it one cycle after issue). Its result is
`~sc_success`, where `sc_success` (in `sc_pending_unit`) requires the
reservation to be valid and its address to match the SC's own doubleword, the
RV64A reservation granule. On failure the wrapper sends a discard signal to
the SQ, which drops the SC's entry without writing memory.

Branch speculation can put several SCs in flight out of order, so
`sc_pending_unit` keeps a `NumCheckpoints + 1` entry table keyed by ROB tag
and fires the entry that matches the head; a partial flush drops only the
younger entries. A single pending register deadlocks when a younger SC
occupies it before the older head SC has issued. A single-SC serialization
gate on `mem_rs_fu_ready_base` (since removed) caused exactly this in the
Linux `_prb_commit` cmpxchg; SC issue must not be serialized that way.

`sc_fu_complete_reg` adds one CDB cycle to the SC result but breaks the
full-flush-to-MEM path; CoreMark executes no SCs, so its measured cycle count
is unchanged. `sc_fire_now` is armed only when nothing else is presenting to
the MEM adapter that cycle (no LQ result, no store-fault strobe, adapter not
pending), so the registered handoff cannot lose an LQ completion. Downstream
ownership uses the registered valid. The LQ's `i_adapter_result_pending`
input, which folds in `sc_fu_complete_reg.valid`, is unread inside the LQ but
kept for synthesis stability; the port comment in `load_queue.sv` explains
why.

### Commit and CDB pipelining

The ROB commit buses and both CDB lanes are registered locally. The visible
`cdb_bus` and `cdb_bus_2` packets are same-cycle combinational reconstructions
from those Q values, so the local registration adds no broadcast cycle.
Commit registers live in `commit_bus/commit_bus_pipeline.sv`; CDB registers
stay inline. Valid bits are kept separate from payload so a full flush resets
only the narrow state. Slot 2 feeds RAT and SQ commit, and CDB lane 1 feeds
ROB and RS wakeup.

The FP, FMUL, FDIV, MUL, and MEM stations each receive both CDB lanes through
local, kept tag FFs (`cdb_bus_<rs>_tag`, `cdb_bus_2_<rs>_tag`) while reusing
the generic valid, value, FU type, and exception fields. The copies carry no
`max_fanout`, duplicate no wide data, and are asserted phase-identical after
reset.

INT_RS additionally receives an issue-only `{valid, tag}` anchor per CDB lane
(`int_rs_issue_cdb_valid`/`_tag`, `int_rs_issue_cdb_2_valid`/`_tag`). These
kept same-edge copies carry no `max_fanout` and feed only the station's
combinational same-cycle readiness/bypass compares. Resident wakeup, value
capture, and dispatch-defer logic keep the ordinary INT-local packets, and
operand values are never duplicated. Assertions check phase identity after
reset. Together with effective-operand capture, this leaves the primary ALU
launch directly on its existing stage2 operand Q values with the same
broadcast and issue cycles.

INT stage2 also exports a separate protected five-bit branch-predicate tag
(`o_rs_issue_branch_predicate_tag`). The wrapper forwards this narrow
same-edge twin to `cpu_ooo` without using it locally, and `branch_resolution`
consumes it only for checkpoint-owner matching and head-relative
age/suppression logic. The ordinary issue tag remains the only source of
`branch_update.tag`, ROB write addresses, early-recovery tag capture, and
ALU-adapter tags. Partitioning the consumers this way isolates the long
branch-qualification cone from the architectural tag's broad ROB fanout
without adding a branch-resolution cycle.

The combinational commit versions are still exposed for the same-cycle
misprediction-detect path in `cpu_ooo.sv`, and the CDB grants remain
combinational so FU adapters can clear their hold registers in the same cycle
as a grant.

The registered slot-1 `is_fence_i` bit implies the same-cycle
`o_fence_i_flush` pulse for a native FENCE.I/SFENCE.VMA commit. The converse
does not hold: translation-class CSR recovery shares the final pulse but does
not set the native commit-payload bit. `cpu_ooo` still uses that native bit
for early-recovery pulse kill, and formal checks the one-way implication.

The wrapper forwards the ROB's serializer-owned `o_fence_class_flush_event`,
`o_translation_csr_commit_shadow`, and final `o_fence_i_flush` without
rebuilding their timing from the live commit bus. For a translation-class
CSR, the shadow/event cycle is the registered CSR-file write cycle and the
final pulse follows one cycle later. TLB/PTW invalidation is a separate
CSR-file path: `o_tlb_invalidate` is the OR of the registered SFENCE.VMA sync
window and `i_csr_translation_flush_req` from the CSR file.

The registered valid outputs (`o_commit_bus_q_valid`, `o_commit_bus_2_q_valid`)
are also masked combinationally with `!i_flush_all_wb_mask`. The mask is a
phase-identical alias of the controller's registered full-flush source,
forwarded separately so implementation can replicate its fanout independently
of the shared `i_flush_all` priority/broadcast cone. The valid flops clear on
the flush edge, but downstream consumers still see the previous valid value
during that cycle. Masking immediately stops a commit that overlaps a trap,
xRET, or FENCE-class full flush from performing one more architectural side
effect while the back-end is being squashed.

The wrapper also drives the SQ slot-2 combinational commit guard from the raw
head+1 store-commit pulse (`i_commit_valid_comb_2 = commit_2_store_like_raw`,
`i_commit_rob_tag_comb_2 = commit_bus_2.tag`; these were once tied to
`1'b0`/`'0`). Slot 2 has the same raw-commit race as slot 1:
`commit_bus_2_q_valid` reaches the SQ one cycle late, so without the guard a
full-flush trap such as a machine-timer IRQ could observe
`sq_committed_empty` and squash a store the SQ does not yet own.

### Dispatch routing

`dispatch_rs_router` converts both packets to per-RS valid and slot-1 intent
signals. The per-RS full and full-for-2 capacity outputs are computed in the
wrapper (the FP-family ones also count an occupied pending buffer). LQ and SQ
receive matching allocations and assign slot 1 the older entry.

### Flush coordination

The wrapper accepts four flush inputs and forwards them to every submodule
with a consistent ROB head tag for age comparisons. Partial flush
(`i_flush_en` + `i_flush_tag`) handles branch mispredictions. Full flush
(`i_flush_all`) handles traps, xRET, and FENCE-class recovery (native
FENCE.I/SFENCE.VMA or a translation-class CSR). The commit-time recovery
flush (`i_flush_after_head_commit`) spares the head; it is OR-ed with
`i_flush_all` into the effective full-flush term `speculative_flush_all` and
masks the partial flush in `speculative_flush_en`. The execute-time
early-backend recovery identity (`i_early_recovery_flush`) qualifies the
selective recovery class. RAT checkpoint restoration uses its own
checkpoint-restore interface.

The LQ consumes `i_early_recovery_flush` directly as its partial-flush
identity. In the production recovery controller this equals
`speculative_flush_en` whenever `speculative_flush_all` is low; when the two
differ, the LQ's full-flush input resets or suppresses every architecturally
visible transition. Internal payload captures may differ on that edge, but
their valid and control state is cleared before anything observes them.
Feeding the LQ the registered identity keeps the architectural full-flush
priority cone out of the LQ-to-SQ disambiguation capture path.

Translated DMMU results likewise expose separate pre-kill payload-capture
pulses for loads and stores (`dmmu_out_lq_capture_valid`,
`dmmu_out_sq_capture_valid`). The SQ uses its pulse only to refresh
still-hidden address/data storage; `dmmu_out_valid` remains the sole owner of
SQ valid bits, faults, completion, and SC state. A capture on a recovery edge
is therefore dead once the SQ control array clears, and the wide 8x64
forwarding mirror and drain RAM no longer inherit the full-flush kill cone.

Full-flush CDB suppression is centralized at the CDB arbiter's `i_kill`
input, driven by a local `cdb_kill` copy of `speculative_flush_all`, instead
of being replicated in each `fu_cdb_adapter`'s output-valid cone. That keeps
a broadly fanned flush signal out of every adapter's critical path, so the
per-FU `*_result_accepted` shim-pop signals gate only on adapter-pending and
result-valid, never on `speculative_flush_all`. The SC tracking table is
still cleared wholesale on `speculative_flush_all`, so a killed SC never
fires.

## What it instantiates

The wrapper contains one ROB, one RAT, six RSes, one LQ, one SQ, one two-lane
CDB arbiter, eight `fu_cdb_adapter` instances, and six shims (`int_alu_shim`
x2 and one each of `int_muldiv_shim`, `fp_add_shim`, `fp_mul_shim`,
`fp_div_shim`). The muldiv shim drives two adapter slots (MUL and DIV), and
the MEM adapter takes the LQ/SC/store-fault mux instead of a shim. See
[`../README.md`](../README.md). Only the ALU adapters keep
`ALLOW_GRANT_REFILL=1` (back-to-back single-cycle ALU results); every other
adapter (MUL, DIV, MEM, FP_ADD, FP_MUL, FP_DIV) sets `ALLOW_GRANT_REFILL=0`
so CDB arbitration does not feed back into the FIFO/issue cones (and, for
MEM, so SC commit ordering serializes). The DIV and all three FP adapters
also set `REGISTER_OUTPUT=1`.

Both ALU adapters keep that grant-refill state behavior but set
`ALLOW_GRANT_REFILL_PAYLOAD_WRITE=0`. Each pending bit already deasserts the
matching INT-RS issue-ready input before its combinational ALU shim can assert
valid, so pending and shim-valid cannot coincide. The wrapper asserts both
invariants, and each adapter uses `i_fu_result.valid` alone as the wide
`held_result` write enable; CDB grant and adapter-pending stay confined to
the narrow state logic.

Each ALU value is partitioned into a raw live path and an independent tree
fallback from held Q or test injection. The arbiter exports the fallback
values and lane/source selects; the generic, INT-local, and SQ-local banks
capture them at the CDB edge and reconstruct the value after Q from the
adapters' existing held registers. This keeps live-value restore off the
registered CDB D paths without a new wide register bank or a cycle change.
Assertions, formal contracts, and split-RS tests cover phase identity and the
injected, live, and held sources.

## Performance counters

The wrapper owns 64 live performance counters (in
`perf/tomasulo_perf_counters.sv`), snapshot-captured in four banks for
end-of-test reporting. In rough groups:

- Head-wait partitions. The dominant `head_wait_total` bucket is decomposed
  into `Int / Branch / Mul / MemLoad / MemStore / MemAmo / Fp / Fmul / Fdiv`.
  The ROB stores the final `Int` and `MemLoad` classifications in
  allocation-time FF vectors and reads them with its registered one-hot head
  mask; the live done/bypass/flush qualifier is unchanged, so this is a
  timing-only implementation detail. `head_wait_int` is split further into
  four sub-buckets fed by the INT_RS diagnostic port (`operand_wait`,
  `rs_ready_not_issued`, `stage2`, `post_rs`). `head_wait_mem_load` is first
  split by whether the LQ has a memory response in flight
  (`load_outstanding`, real miss latency, versus `load_no_outstanding`); the
  `load_no_outstanding` half is then split into five sub-buckets
  (`addr_pending`, `sq_disambig`, `bus_blocked`, `cdb_wait`, `post_lq`), and
  `bus_blocked` into five mutually exclusive causes. The `staging` cause is
  itself decomposed into four buckets (`other_in_staging`, `launch_gated`,
  `slow_outstanding`, `capture_gap`) that partition it exactly.
- Commit stalls. `commit_blocked_{csr, fence, wfi, mret, trap}` attribute
  cycles where the head sits in the serializing FSM.
- Widen-commit profile. `head_and_next_done` (a 1-wide commit fired while
  head+1 was also retirable: a missed-2-wide diagnostic),
  `head_plus_one_done` (ungated head+1 done), `commit_2_opportunity`
  (pre-FIFO-back-pressure, hazard gate already applied),
  `commit_2_fire_actual` (2-wide fires), and a four-way `commit_2_blocked`
  decomposition (`head_serial`, `next_serial`, `next_branch_mispred`,
  `next_branch_correct`).
- FU back-pressure. Six counters: `Int`, `Mul`, `FpAdd`, `Fmul`, and `Fdiv`
  count cycles where that RS is non-empty but its `fu_ready` is deasserted
  (issue blocked), and `MemResult` counts cycles where a MEM result is held
  because the MEM adapter is still pending. MUL and DIV share the muldiv
  shim, so there is no separate DIV counter.
- Memory and queue activity. `mem_disambiguation_wait`,
  `sq_committed_pending`, `sq_mem_write_fire`, `lq_mem_read_fire`,
  `lq_l0_hit`, `lq_l0_fill`.
- Occupancy sums. Per-cycle occupancy of the ROB, LQ, SQ, and each of the six
  RSes, so the software side can compute average depth.

Snapshot capture fans out through four per-bank capture registers annotated
`max_fanout = 768`, so one capture-enable strobe does not drive all 64
counters from a single source. The capture lands one cycle after the
`mperfctl` trigger commit, which CSR serialization makes invisible to
software.

## Verification hooks

Each FU slot has a test-injection input (`i_fu_complete_0` through
`i_fu_complete_7`) that lets cocotb drive synthetic completions into the
wrapper without exercising the FU shims, which is how the top-two CDB
arbitration and the CDB/RS/ROB interaction are unit-tested in isolation. The
`tomasulo_wrapper` cocotb target enables the production dispatch done-repair
parameter (`ENABLE_DISPATCH_DONE_REPAIR=1`) and directly covers the
FP/FDIV/FMUL E0 packet capture, E1 registered repair hold, and E2 dequeue. It
also checks the no-bubble initially-ready path, retention under recovery
hold, producer commit on E0, and rejection of a later ABA-shaped same-tag
response after the repair phase expires. FMUL-specific probes cover three
simultaneous source repairs, source 3 after producer commit, both CDB lanes
while held, replacement-packet ownership, the initially-ready no-bubble path,
and an E1 repair/full-flush collision. The `tomasulo_wrapper_split_rs` target
checks the production repair path with split-RS dispatch. FP and FDIV are
two-source, slot-1-only dispatches, so their pending buffers use only
done-repair channels 1 and 2; FMUL uses channel 3 as well, while the INT,
MUL, MEM, and SQ consumers keep all six channels. Capture-phase assertions
check the fixed channel/source alignment and reject a dequeue or refill
during an unresolved FMUL response window. The `fmul_repair_bmc` task of the
`tomasulo_wrapper.sby` formal target enables the production repair parameter
and proves the one-cycle phase, packet retention, CDB priority, and exact
captured values for all three FMUL sources.
