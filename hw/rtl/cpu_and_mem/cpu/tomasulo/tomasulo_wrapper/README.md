# Tomasulo Wrapper

The wrapper instantiates every OOO back-end submodule — ROB, RAT, the
six reservation stations, LQ, SQ, CDB arbiter, FU shims, CDB adapters
— and wires them together behind a single set of ports for
`cpu_ooo.sv`. It also contains a few pieces of inline glue logic that
straddle module boundaries and don't fit cleanly into any one
submodule.

Some of that glue has been factored into private submodules under this
directory. These are pure RTL boundary moves — the logic bodies were copied
verbatim, so the flattened design is unchanged:

| Submodule | Dir | What it holds |
|-----------|-----|---------------|
| `tomasulo_perf_counters` | `perf/` | The 64 back-end performance counters (accumulate / snapshot / four banks / CSR-style readout). |
| `commit_bus_pipeline` | `commit_bus/` | The four `always_ff` that register the combinational ROB commit bus into `commit_bus_q` / `commit_bus_2_q` plus the decomposed `commit_q_*` fields. |
| `sq_early_addr_pipeline` | `store_addr/` | The dual-ported early store-address stage (register dispatch base+imm, add the next cycle off the dispatch critical path) that produces the two SQ early-address update packets. A store whose base is not ready at dispatch becomes a PERSISTENT repair candidate: it waits for its base tag on the dispatch done-repair channels or the live CDB lanes, latches the repaired base if a fresh update owns the SQ port that cycle, and drains on the next free cycle; candidates are evicted by a newer un-ready store on the same slot, killed when MEM_RS issues their store (which also closes the ROB-tag-reuse window), and cleared on flush. |
| `dispatch_rs_router` | `dispatch_routing/` | Combinational decode of the dispatch packet(s) into per-RS dispatch-valid signals (slot 1 + slot 2) and the fast slot-1 "intent" signals. |
| `sc_pending_unit` | `atomics/` | Store-conditional resolution: a per-ROB-tag table of in-flight SCs (allocated at MEM_RS SC issue, freed on fire / flush), the head-match fire/success decode, and the `sc_fu_complete` packet. |

The per-RS dispatch-valid nets in `dispatch_rs_router` carry `(* max_fanout =
32 *)`; the attribute is preserved both in the submodule and on the wrapper-side
receiving nets (where the fanout to the RS instances occurs), so it survives
flattened or hierarchical synthesis.

The SQ early-address pipeline receives one narrow, phase-identical registered
copy of each CDB lane containing only `valid`, `tag`, and the XLEN-wide value.
Those copies capture the arbiter's tree fallback at the normal CDB edge and
restore a selected live integer-ALU value after Q, just like the generic and
INT-RS-local copies described below. They are kept physically distinct so the
SQ repair cone can place locally; they intentionally have no `max_fanout`
attribute and are consumed only by `sq_early_addr_pipeline`.

The remaining inline glue (the store-misalign + MEM-adapter mux around
`sc_pending_unit`, flush coordination, the FMUL repair queue, FU-shim wiring)
stays in the wrapper: it is tightly coupled to the integration and carries
load-bearing synthesis attributes (`max_fanout`, `keep`) whose placement is best
left undisturbed.

## Inline glue logic

The wrapper is not a passive harness: the subsections below describe the
logic that lives here because it straddles submodule boundaries.

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

The FMUL_RS is the only RS that takes 3 source operands (for FMA).
Adding a third dispatch port to the ROB bypass network just for FMUL
would have been wasteful, so every FMA/FMUL dispatch is parked for at
least a cycle in a one-entry queue right outside the RS, and only the
dequeued packet is written into the station. On dequeue (gated on RS
room and on no flush or backend-recovery hold) the wrapper re-fetches
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

Several SCs can be in flight at once: a branch-speculated LR/SC retry
loop issues one SC per speculated iteration, and the MEM_RS may issue
them out of program order. `sc_pending_unit` therefore tracks every
in-flight SC in a small table keyed by ROB tag (depth `NumCheckpoints
+ 1`) and fires the entry whose tag matches the ROB head; a flush drops
only entries younger than the flush boundary, so a surviving older SC
is never lost. This replaced a single pending register plus a
`!(sc_pending && mem_rs_next_is_sc)` issue-serialization gate in
`mem_rs_fu_ready_base`: under speculation a younger SC could take the
register and the gate would then block the older head SC from issuing
at all, so it never fired and `sc_pending` never cleared — Linux
printk's `_prb_commit` cmpxchg on the cached DDR tier deadlocked
exactly that way. The gate is gone; the table makes concurrent SCs safe.

The `sc_fu_complete` output is registered (`sc_fu_complete_reg`)
before feeding the MEM adapter. The combinational path from the
full-flush term `speculative_flush_all` (driven by `i_flush_all` /
`i_flush_after_head_commit`) through the SC completion logic
(`sc_fire_now` → `mem_fu_to_adapter`) into the MEM slot's CDB input
was the post-synth worst-case cone; the register adds one cycle of SC
CDB latency (SC is rare — zero occurrences in CoreMark — so measured
perf is unchanged) in exchange for WNS. The conflict that the
register would otherwise create is avoided at the source instead:
SC is only armed (`sc_fire_now`) when the LQ is not presenting a
result that same cycle, so the downstream paths that observe SC
ownership of the MEM adapter (`lq_result_accepted`, plus the LQ's
driven-but-unread `i_adapter_result_pending` hint — retained for
synthesis stability, see the port comment in load_queue.sv) only need
the registered `sc_fu_complete_reg.valid` and the LQ never loses a
result to a same-cycle mux conflict.

### Commit and CDB pipelining

The ROB commit bus and both CDB broadcast lanes are registered into local
copies (`commit_bus_q`, `cdb_bus_q`, `cdb_bus_2_q`) before being routed to the
downstream consumers. The visible `cdb_bus` / `cdb_bus_2` packets are
same-cycle combinational reconstructions from those Q values. The commit-bus
registers now live in
`commit_bus/commit_bus_pipeline.sv` (the CDB registers stay inline). The
valid bits are split out from the payload
and registered separately so a full flush only fans a narrow reset
into a one-bit register instead of the wide payload — a Vivado
synthesis trick to keep flush fanout under control. A parallel
slot-2 register (`commit_bus_2_q`) carries the widen-commit
second-retire payload to RAT / SQ; the parallel CDB lane-1 register carries the
secondary completion to the ROB and RS wakeup network.

FMUL alone receives the second CDB lane through a tag-local packet. A kept,
`dont_touch`, same-edge five-bit tag FF samples the same arbiter tag as the
generic lane register; the packet retains the generic registered valid, value,
FU type, and exception metadata and substitutes only that copied tag. The copy
has no `max_fanout` constraint and does not duplicate the wide CDB value. An
RTL assertion checks its exact phase identity with the generic tag after reset,
so the anchor changes placement only and adds no wakeup cycle.

INT_RS receives a separate issue-only `{valid, tag}` anchor for each CDB lane.
The two kept, `dont_touch`, same-edge copies total twelve FFs with the current
five-bit ROB tags, carry no `max_fanout` constraint, and feed only the station's
combinational same-cycle readiness/bypass compares. Resident wakeup/value
capture and dispatch-defer logic retain the ordinary INT-local packets, and
operand values are never duplicated by these anchors. RTL assertions check
both lanes against the ordinary INT-local valid/tag registers after reset.
Together with INT port 0's effective-operand capture, this leaves the primary
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

The registered slot-1 payload's `is_fence_i` bit samples the same retiring
FENCE.I predicate as the ROB's registered global flush pulse. `cpu_ooo` reuses
that otherwise-low-fanout payload bit for the early-recovery active-pulse kill,
and the wrapper formal harness checks cycle-for-cycle equality after reset.

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

Dispatch now emits already-routed per-RS packets for slot 1 and slot 2. The
wrapper (via `dispatch_rs_router`) decodes them into the per-RS dispatch-valid
and intent signals, forwards the packets to the matching RS instances, and
supplies each
resource's ordinary full status plus "full for 2" status back to dispatch, so a
2-wide bundle only fires when same-resource pairs have two free entries. The LQ
and SQ receive matching slot-1/slot-2 allocation packets and preserve program
order by assigning slot 1 to the older free entry when both slots allocate.

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

One ROB, one RAT, six RS instances at the depths in
[`../README.md`](../README.md), one LQ (with the L0 cache inside),
one SQ, one 2-lane CDB arbiter, eight CDB adapters (one per FU slot), and
six FU shims (`int_alu_shim` x2 — the dual-issue INT station feeds two
single-cycle integer pipes, branches steered to pipe 0 — plus
`int_muldiv_shim`, `fp_add_shim`, `fp_mul_shim`, `fp_div_shim`;
`int_muldiv_shim` drives two adapter slots). Only the two ALU adapters
keep the default `ALLOW_GRANT_REFILL=1`
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

Before arbitration, the wrapper retains the generic effective packet for each
ALU and also partitions its value into a raw live-shim path and an independent
tree fallback. Adapter-valid while non-pending identifies the live path. The
fallback selects the exposed held-register Q directly when the adapter is
pending and valid, and otherwise selects the test-injection value. The direct
Q source is cycle-identical to the pending arm of the adapter output, but does
not carry that output's pending/live value mux into the merge-tree or registered
fallback D cones. The arbiter carries held and injected values normally, while
a protected lane-local three-arm mux preserves the exact combinational output
used for grant-time observation.

The arbiter also exports both tree fallback values and four valid-qualified
lane/source selectors. At the existing CDB edge the generic, INT-RS-local, and
SQ-local banks capture only those fallbacks plus metadata and the four scalar
selectors. Each integer ALU adapter simultaneously captures its raw shim value
in its existing `held_result`; after Q, domain-local three-arm muxes reconstruct
the registered values from the captured selectors and the two exposed held
values. This moves the live-value restore off every registered CDB value D path
without adding a wide live-value FF bank or changing the broadcast cycle.
Simulation assertions compare each valid reconstructed packet to the exact
prior-edge combinational packet and check generic/INT/SQ phase identity.
Wrapper formal proves that live implies the raw shim value equals the effective
packet and that fallback equals the packet otherwise; the embedded arbiter
proves the recomposed outputs without assuming that contract. Split-RS cocotb
tests exercise injection, live, and held source states for both ALU packets,
with nonzero upper-half results on RV64.

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
