# Tomasulo Wrapper

The wrapper connects the ROB, RAT, six reservation stations, LQ, SQ, CDB,
adapters, and FU shims to `cpu_ooo.sv`. Cross-module glue remains here or in
private submodules below.

| Submodule | Dir | What it holds |
|-----------|-----|---------------|
| `tomasulo_perf_counters` | `perf/` | The 64 back-end performance counters (accumulate / snapshot / four banks / CSR-style readout). |
| `commit_bus_pipeline` | `commit_bus/` | Registers both combinational ROB commit buses and decomposed `commit_q_*` fields. |
| `sq_early_addr_pipeline` | `store_addr/` | The dual-ported early store-address stage (register dispatch base+imm, add the next cycle off the dispatch critical path) that produces the two SQ early-address update packets. A store whose base is not ready at dispatch becomes a PERSISTENT repair candidate: it waits for its base tag on the dispatch done-repair channels or the live CDB lanes, latches the repaired base if a fresh update owns the SQ port that cycle, and drains on the next free cycle; candidates are evicted by a newer un-ready store on the same slot, killed when MEM_RS issues their store (which also closes the ROB-tag-reuse window), and cleared on flush. |
| `dispatch_rs_router` | `dispatch_routing/` | Decodes both dispatch packets into per-RS valid and slot-1 intent signals. |
| `sc_pending_unit` | `atomics/` | Store-conditional resolution: a per-ROB-tag table of in-flight SCs (allocated at MEM_RS SC issue, freed on fire / flush), the head-match fire/success decode, and the `sc_fu_complete` packet. |

The per-RS dispatch-valid nets in `dispatch_rs_router` carry `(* max_fanout =
32 *)`; the attribute is preserved both in the submodule and on the wrapper-side
receiving nets (where the fanout to the RS instances occurs), so it survives
flattened or hierarchical synthesis.

The SQ early-address pipeline receives one narrow, phase-identical registered
copy of each CDB lane containing only `valid`, `tag`, and the XLEN-wide value.
They capture the arbiter fallback at the CDB edge and restore live ALU values
after Q. Kept physically distinct and without `max_fanout`, they serve only
`sq_early_addr_pipeline` so its repair cone can place locally.

Remaining inline glue (the store-misalign + MEM-adapter mux around
`sc_pending_unit`, flush coordination, the FMUL repair queue, FU-shim wiring)
stays in the wrapper: it is tightly coupled to the integration and carries
load-bearing synthesis attributes (`max_fanout`, `keep`) whose placement is best
left undisturbed.

## Inline glue logic

### Done-repair locality

Dispatch registers six renamed-source tags for the ROB done/value lookup, but
those tags are not broadcast into every resident RS entry. The immediate INT,
MUL, and MEM stations use `ALLOC_INDEXED_REPAIR`: each station captures the
one-hot entry allocated by the relevant dispatch slot and writes the returning
channel directly to that entry's fixed source position one cycle later. This
preserves the registered repair latency while avoiding a six-channel global
CAM and its wide source-value write enables.

FP, FMUL, and FDIV already pass through one-entry wrapper buffers before their
stations. FP and FDIV repair the buffered packet while it waits and also form a
same-cycle repaired dequeue view; FMUL rereads ROB done/value by the buffered
packet's own tags at dequeue. Their resident stations therefore use only the
two live CDB snoops and have the global repair ports tied off. The original
sequential FP/FDIV pending repair remains active so a response is retained when
recovery or back-pressure blocks dequeue.

### FMUL operand-repair queue

FMUL_RS alone takes three sources. Rather than add a third dispatch-time ROB
bypass port, every FMUL/FMA packet spends at least one cycle in a one-entry
queue. On dequeue (with RS room and no flush/recovery hold), the wrapper re-fetches
the bypass values for all three sources from dedicated FMUL bypass
ports on the ROB, so any operand that completed while the entry was
queued gets a fresh value.

### SC state machine

The SC tracking table and its fire/success decode live in
`atomics/sc_pending_unit.sv`; the surrounding store-misalign path and MEM-adapter
mux described below stay in the wrapper.

Store-conditional execution is split between MEM_RS issue and
ROB-head commit. The MEM_RS issues the SC like a normal store; the
LQ holds the LR reservation register and snoops every SQ memory
write to invalidate it on a matching address. The SC fires only when
its ROB entry reaches the head and the SQ is committed-empty. Its
result is `~sc_success`, where `sc_success` (in `sc_pending_unit`)
requires the reservation to be valid *and* its address to match the
SC's own reservation granule (a doubleword, the RV64A granule). On
failure, the wrapper sends a discard signal to the SQ to drop
the SC's entry without writing memory.

Branch speculation may put several out-of-order SCs in flight.
`sc_pending_unit` therefore uses a `NumCheckpoints + 1` table keyed by ROB tag
and fires the head match; partial flush drops only younger entries. A single
pending register can deadlock when a younger SC occupies it before the older
head SC issues. The former `mem_rs_fu_ready_base` serialization gate caused
exactly this in Linux `_prb_commit` cmpxchg; SC issue must not be serialized
that way.

`sc_fu_complete_reg` adds one CDB cycle but breaks the full-flush-to-MEM path;
measured CoreMark is unaffected because it executes no SCs. `sc_fire_now` is
armed only when the LQ is not presenting a result, so the
registered handoff cannot lose an LQ completion. Downstream ownership uses the
registered valid; the unread LQ pending hint is retained for synthesis
stability as documented in `load_queue.sv`.

### Commit and CDB pipelining

The ROB commit buses and both CDB lanes are registered locally. The visible
`cdb_bus` and `cdb_bus_2` packets are same-cycle combinational reconstructions
from those Q values, so registration adds no broadcast cycle. Commit registers
live in `commit_bus/commit_bus_pipeline.sv`; CDB registers remain inline. Valid
bits are separate from payload so full flush resets only narrow state. Slot 2
feeds RAT/SQ commit, and CDB lane 1 feeds ROB/RS wakeup.

FMUL receives lane 1 through a local, kept tag FF while reusing generic valid,
value, FU type, and exception fields. The copy has no `max_fanout`, duplicates
no wide data, and is asserted phase-identical after reset.

INT_RS receives a separate issue-only `{valid, tag}` anchor for each CDB lane.
The kept same-edge copies carry no `max_fanout` and feed only the station's
combinational same-cycle readiness/bypass compares. Resident wakeup/value
capture and dispatch-defer logic retain the ordinary INT-local packets, and
operand values are never duplicated. Assertions check phase identity after
reset. Together with effective-operand capture, this leaves the primary
ALU launch directly on its existing stage2 operand Q values while retaining the
same broadcast and issue cycles.

INT stage2 also exports a separate protected five-bit branch-predicate tag.
The wrapper forwards this narrow same-edge twin to `cpu_ooo` without using it
locally. `branch_resolution` consumes it only for checkpoint-owner matching and
head-relative age/suppression logic. The ordinary issue tag remains the sole
source of `branch_update.tag`, ROB write addresses, early-recovery tag capture,
and ALU-adapter tags. This consumer partition isolates the long branch
qualification cone from the architectural tag's broad ROB fanout without
adding a branch-resolution cycle.

The combinational commit versions are still exposed for the same-cycle
misprediction-detect path in `cpu_ooo.sv`, and the CDB grants remain
combinational so FU adapters can clear their hold registers on the same cycle as
a grant.

The slot-1 `is_fence_i` bit matches the ROB's registered FENCE.I flush pulse.
`cpu_ooo` reuses it for early-recovery pulse kill; formal checks cycle identity.

The registered valid outputs (`o_commit_bus_q_valid`, `o_commit_bus_2_q_valid`)
are additionally masked combinationally with `!i_flush_all_wb_mask` — a
dedicated, bit-identical flat recompute of the full-flush term
(`misprediction_flush_controller.o_flush_all_flat`), kept off the shared
`i_flush_all` priority/broadcast cone for timing. The valid flops
clear on the flush edge, but downstream consumers still observe the previous
valid value during that same cycle; masking immediately prevents a commit that
overlaps a trap / MRET / FENCE.I full flush from performing one more
architectural side effect while the back-end is being squashed.

The wrapper also drives the SQ slot-2 combinational commit guard from the raw
head+1 store-commit pulse (`i_commit_valid_comb_2 = commit_2_store_like_raw`,
`i_commit_rob_tag_comb_2 = commit_bus_2.tag`; previously tied to `1'b0`/`'0`).
Slot 2 has the same raw-commit race as slot 1: `commit_bus_2_q_valid` reaches the
SQ one cycle late, so without this a full-flush trap (e.g. a machine-timer IRQ)
could observe `sq_committed_empty` and squash a store the SQ has not yet owned.

### Dispatch routing

`dispatch_rs_router` converts both packets to per-RS valid and intent signals
and returns each resource's one- and two-entry capacity. LQ and SQ receive
matching allocations and assign slot 1 the older entry.

### Flush coordination

The wrapper accepts four flush inputs and forwards them to every
submodule with a consistent ROB head tag for age comparisons:
partial flush (`i_flush_en` + `i_flush_tag`) for branch
mispredictions, full flush (`i_flush_all`) for traps and FENCE.I, a
commit-time recovery flush (`i_flush_after_head_commit`) that spares
the head and is OR-ed with `i_flush_all` into the effective full-flush
term `speculative_flush_all` (while masking the partial flush in
`speculative_flush_en`), and an early-recovery qualifier
(`i_early_recovery_flush`) that tells the RAT to apply checkpoint
restore atomically with the partial flush.

Full-flush CDB suppression is centralized at the CDB arbiter's
`i_kill` input (driven by a local `cdb_kill` copy, itself just
`speculative_flush_all`) rather than replicated in each
`fu_cdb_adapter`'s output-valid cone. This moves a broadly-fanned
flush signal out of every adapter's critical path, so the per-FU
`*_result_accepted` shim-pop signals stay off the flush cone — they
gate only on adapter-pending / result-valid, not on
`speculative_flush_all`. The SC tracking table is still cleared
wholesale on `speculative_flush_all` so a killed SC never fires.

## What it instantiates

The wrapper contains one ROB, one RAT, six RSes, one LQ, one SQ, one two-lane
CDB arbiter, and eight adapters for six shims (`int_alu_shim` x2 and one each
of `int_muldiv_shim`, `fp_add_shim`, `fp_mul_shim`, `fp_div_shim`); muldiv
drives two adapter slots. See [`../README.md`](../README.md). Only the ALU
adapters keep `ALLOW_GRANT_REFILL=1`
(back-to-back single-cycle ALU results); every other adapter (MUL,
DIV, MEM, FP_ADD, FP_MUL, FP_DIV) sets `ALLOW_GRANT_REFILL=0` so CDB
arbitration does not feed back into the FIFO/issue cones (and, for
MEM, so SC commit ordering serializes correctly). The DIV and all
three FP adapters additionally set `REGISTER_OUTPUT=1`.

Both ALU adapters keep that grant-refill state behavior but set
`ALLOW_GRANT_REFILL_PAYLOAD_WRITE=0`. Each pending bit already deasserts the
matching INT-RS issue-ready input before its combinational ALU shim can assert
valid, so pending and shim-valid cannot coincide. The wrapper asserts both
invariants, and each adapter uses `i_fu_result.valid` alone as the wide
`held_result` write enable; CDB grant and adapter-pending remain confined to
the narrow state logic.

Each ALU value is partitioned into a raw live path and an independent tree
fallback from held Q or test injection. The arbiter exports fallback values and
lane/source selects; generic, INT-local, and SQ-local banks capture them at the
CDB edge and reconstruct the value after Q from the adapters' existing held
registers. This keeps live-value restore off registered CDB D paths without a
new wide register bank or cycle change. Assertions, formal contracts, and
split-RS tests cover phase identity plus injected, live, and held sources.

## Performance counters

The wrapper owns 64 live performance counters (in
`perf/tomasulo_perf_counters.sv`), snapshot-captured in four banks for
end-of-test reporting. In rough groups:

- **Head-wait partitions.** The dominant `head_wait_total` bucket
  is decomposed into `Int / Branch / Mul / MemLoad / MemStore /
  MemAmo / Fp / Fmul / Fdiv`. The ROB stores the final `Int` and
  `MemLoad` classifications in allocation-time FF vectors and reads them with
  its registered one-hot head mask; their live done/bypass/flush qualifier is
  unchanged, so this is a timing-only implementation detail. `head_wait_int`
  is further split into
  four sub-buckets fed by the INT_RS diagnostic port
  (`operand_wait`, `rs_ready_not_issued`, `stage2`, `post_rs`).
  `head_wait_mem_load` is first split by whether the LQ has a memory
  response in flight (`load_outstanding` for real miss latency vs
  `load_no_outstanding`); the `load_no_outstanding` half is then split
  into five sub-buckets (`addr_pending`, `sq_disambig`, `bus_blocked`,
  `cdb_wait`, `post_lq`), and `bus_blocked` is further split into five
  mutually exclusive causes. The `staging` cause is itself
  sub-decomposed into four buckets (`other_in_staging`,
  `launch_gated`, `slow_outstanding`, `capture_gap`) that partition
  it exactly.
- **Commit stalls.** `commit_blocked_{csr, fence, wfi, mret, trap}`
  attribute cycles where the head sits in the serializing FSM.
- **Widen-commit profile.** `head_and_next_done` (1-wide commit
  fired while head+1 was also retirable — a missed-2-wide diagnostic),
  `head_plus_one_done` (ungated head+1 done), `commit_2_opportunity`
  (pre-FIFO-back-pressure, hazard-gate already applied),
  `commit_2_fire_actual` (actual 2-wide fire count), and a
  four-way `commit_2_blocked` decomposition
  (`head_serial`, `next_serial`, `next_branch_mispred`,
  `next_branch_correct`).
- **FU back-pressure.** Six counters: `Int`, `Mul`, `FpAdd`, `Fmul`,
  and `Fdiv` count cycles where that RS is non-empty but its
  `fu_ready` is deasserted (issue blocked), and `MemResult` counts
  cycles where a MEM result is held because the MEM adapter is still
  pending. (MUL and DIV share the muldiv shim, so there is no separate
  DIV counter.)
- **Memory / queue activity.** `mem_disambiguation_wait`,
  `sq_committed_pending`, `sq_mem_write_fire`, `lq_mem_read_fire`,
  `lq_l0_hit`, `lq_l0_fill`.
- **Occupancy sums.** Per-cycle occupancy of ROB, LQ, SQ, and each
  of the six RSes, so the software side can compute average depth.

Snapshot capture fans out via `max_fanout=768`-annotated bank
signals so a single capture-enable strobe doesn't need to drive all
64 counters from one source.

## Verification hooks

Each FU slot has a test-injection input that lets cocotb drive
synthetic completions into the wrapper without exercising the FU
shims, useful for unit-testing the top-two CDB arbitration and the CDB / RS /
ROB interaction in isolation. The wrapper test target enables the production
dispatch done-repair parameter and directly covers FP/FDIV responses both on
the dequeue cycle and while recovery holds the pending packet. The split-
dispatch target also checks the production FP recovery-hold behavior. Because
FP and FDIV are two-source, slot-1-only dispatches, their pending buffers use
only done-repair channels 1/2 for both combinational dequeue and held-packet
updates; INT, MUL, MEM, and SQ consumers retain all six channels. Simulation-
only capture-phase assertions check the channel-1/source-1 and
channel-2/source-2 alignment and reject any response visible only on an omitted
channel without adding synthesized state.
