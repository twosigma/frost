# Tomasulo Wrapper

The wrapper connects the ROB, RAT, six reservation stations, LQ, SQ, CDB,
adapters, and FU shims to `cpu_ooo.sv`. Cross-module glue lives here or in
the private submodules below.

| Submodule | Dir | What it holds |
|-----------|-----|---------------|
| `tomasulo_perf_counters` | `perf/` | The 64 back-end performance counters: accumulate, snapshot into four banks, CSR-style readout. Left out when the wrapper's `PERF_COUNTERS` parameter is 0 (the production build). |
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

FMUL adds a third source/query channel to the pending-buffer contract above.
CDB lane 0 has priority over lane 1, and both beat aligned done-repair data.
Dequeue/refill waits until the response window has passed so an old query
cannot update a replacement packet. Only the registered repaired packet enters
the RS; no packet-tag-driven ROB read replicas are needed.

### SC state machine

The SC tracking table and its fire/success decode live in
`atomics/sc_pending_unit.sv`. The surrounding store-misalign path and the
MEM-adapter mux stay in the wrapper; the mux feeds the MEM adapter with, in
priority order, the registered misaligned-store fault, the registered SC
completion, and the LQ result. The fault register cannot hold (a second fault
can follow it one cycle later under data translation); the SC completion
register holds while a fault is presenting, and the unit does not fire while
a completion waits.

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

Out-of-order issue requires a `NumCheckpoints + 1` table keyed by ROB tag;
a single pending slot can deadlock when a younger SC arrives before the head
SC. Partial flush removes only younger entries.

`sc_fu_complete_reg` adds one CDB cycle and holds behind registered store
faults. Fire requires no LQ result, store-fault strobe, pending MEM adapter,
or waiting SC completion. A fault captured on the fire edge takes priority
next cycle; the SC result waits. Use only the registered fault strobe here
to keep live address/misalignment/PMA logic off the SC table's write path.
The strobe also kills the faulting SC entry, regardless of allocation timing.

Release assertions require an idle adapter, a same-cycle MEM grant, and exactly
one broadcast of the SC tag. Wrapper tests cover store-fault collisions and
CDB contention. `i_adapter_result_pending` remains an unused LQ compatibility
port; its source comment records the physical constraint on removing it.

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
not set the native commit-payload bit, and its extra register puts the pulse a
cycle after that CSR has already left `commit_bus_q`. `cpu_ooo` still uses the
native bit for early-recovery pulse kill. Formal checks the one-way implication
plus the exact equality that survives once the translation flavor is subtracted
with `o_translation_csr_commit_shadow`.

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
`i_commit_rob_tag_comb_2 = commit_bus_2.tag`). Slot 2 has the same raw-commit race as slot 1:
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
forwarding mirror and drain RAM avoid the full-flush kill cone.

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

With `PERF_COUNTERS=1`, `perf/tomasulo_perf_counters.sv` owns 64 counters for
head waits, commit stalls, FU pressure, memory activity, and occupancy.
See the [counter reference](../../cpu_ooo/perf/README.md) for indices and
partition rules. Four capture banks with `max_fanout=768` snapshot one cycle
after the trigger, aligned with the top-level and cache banks.

## Verification hooks

Inputs `i_fu_complete_0` through `i_fu_complete_7` let tests inject
completions without running FU shims. The `tomasulo_wrapper` and
`tomasulo_wrapper_split_rs` cocotb targets enable
`ENABLE_DISPATCH_DONE_REPAIR=1` and check repair capture/hold/dequeue,
CDB priority, recovery, and same-tag reuse. The `fmul_repair_bmc` formal task
checks repair timing and captured values for all three FMUL operands.

See the [test runner](../../../../../../tests/README.md) for commands and the
[formal guide](../../../../../../formal/README.md) for proof scope and assumptions.
