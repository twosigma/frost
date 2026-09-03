# Reservation Station

A generic reservation station instantiated for INT (8 entries), MUL (4), MEM
(8), FP (6), FMUL (4), and FDIV (2). Each accepts both dispatch slots, tracks
operand readiness, and issues when all required sources are ready.

Eight INT entries cost 0.125%/0.059% in paired RV64 CoreMark runs versus 12,
with identical results and retired-instruction counts. The smaller station
removes a second-issue selector level and halves padded payload storage. Other
entry arrays and port-0 selection scale with the parameter.

INT_RS is also built with `DUAL_ISSUE=1`: a second issue port (`o_issue_2` /
`i_fu_ready_2`) with its own selector, payload-RAM copy, and stage2 pipeline
register, feeding the second single-cycle ALU pipe. Its operand registers
capture the effective value (CDB, resident, or repair) on the issue edge, so
the second ALU, the SQ, and the CDB all launch from a register Q. INT port 0
uses the same boundary: its existing stage2 operand registers capture the
former three-arm lane-0/lane-1 CDB bypass expression on the issue edge and
drive the primary ALU directly from Q. That capture is
`CAPTURE_PRIMARY_EFFECTIVE_OPERANDS`, default off, so the other five stations
keep the late mux. Port 0 keeps its serial priority encoder. A separate
balanced tree selects the lowest ready nonbranch entry other than port 0's
global lowest-ready winner. Branches issue only through port 0, which owns the
single `branch_resolution` / ROB branch-update path. The exclusion holds even
when backpressure keeps port 0 from firing, so the two ports can never claim
one entry. The other five stations elaborate with the default `DUAL_ISSUE=0`
and are structurally unchanged.

Wakeup is a two-lane Tomasulo CDB snoop: each entry compares its source tags
against both broadcast tags every cycle, and a match captures the value and
marks the source ready. Both lanes also feed the combinational same-cycle
issue bypass (`LANE1_ISSUE_BYPASS`, default on), so a resident entry can issue
in the cycle its last operand arrives on either lane. The CDB contract keeps
the two lane tags distinct, so the lane-0 and lane-1 bypass masks are mutually
exclusive per source. In the default mode port 0 carries the match and lane
values through its stage2 bank for late selection; both INT ports fold that
selection into the D inputs of their operand registers. `LANE1_ISSUE_BYPASS`
is a per-instance timing fallback; no instance currently turns it off.

A CDB broadcast that lands in the same cycle as a committed allocation is not
resolved into the dispatch write. It is delivered one cycle later, which keeps
the tag-match cone and the raw CDB value nets off every entry's wide value mux
on the dispatch path. The allocated entry records a per-source pending bit and
lane selector, and two shared registers capture both CDB lane values on the
same edge. On the following edge each pending source receives its selected
registered value, becomes ready, and clears its pending bit. Lane 0 wins a
same-tag collision. While a source is pending, its live issue bypass is
suppressed, so an immediate tag-reuse (ABA) broadcast cannot replace the
dispatch-cycle value. Unrelated first-resident live matches remain eligible
without an added cycle.

Alongside the CDB lanes there is a six-channel done-repair interface
(`i_repair_valid_1..6` / `i_repair_tag_1..6` / `i_repair_value_1..6`). These
are registered wakeups from dispatch that carry operands whose CDB broadcast
landed before the consumer was dispatched, so the live snoop missed them. In
the generic mode a post-insertion repair snoop CAMs those tags against
resident entries every cycle. Two parameters fold repair into the fast paths
as well: `DISPATCH_REPAIR_BYPASS` lets an entry capture a repaired value at
insertion, and `ISSUE_REPAIR_BYPASS` lets a repair match satisfy the ready
check and supply the value at issue.

The FP, FMUL, and FDIV instances tie all six repair inputs to zero. Their
dispatch packets pass through the wrapper's one-entry pending stage, which
holds a packet with unresolved queried operands through the aligned ROB-done
response and merges the result before the packet crosses into the station.

The immediate-dispatch stations (INT, MUL, and MEM) take dispatch packets
directly rather than through that pending stage. They set
`ALLOC_INDEXED_REPAIR=1` with both bypass parameters disabled (a simulation
elaboration check errors if either is left on). Dispatch and the registered
ROB lookup launch together, so each station saves a one-hot token for the
exact entry allocated by slot 1 and/or slot 2. One cycle later, channels 1/2/3
update that slot-1 entry's fixed source positions and channels 4/5/6 update
the slot-2 entry directly. Dispatch-to-ready latency is the same as the
registered CAM snoop, and the six global repair tags leave every resident
source-value write-enable cone. Allocation tokens are captured only on
committed dispatch fires and are discarded on either kind of flush.

INT_RS also enables `BROADCAST_FREE_SOURCE_VALUES` together with
`SPECULATIVE_DATA_WRITES`. Every currently-invalid entry is prefilled with
slot 1's source values; when a speculative slot-2 write is possible, its exact
allocation target receives slot 2's values instead. Only `rs_valid` commits an
entry, so the extra free-entry writes are unobservable. Dispatch and issue
latency are unchanged. What changes is the wide value flops' clock enable: the
priority-decoded free index is replaced by the entry-local invalid bit, and
the slot-2 allocation index affects only the selected input data.

INT_RS also enables `ISSUE_CDB_TAG_SHADOW`. A second src1/src2 tag bank is
written through the same speculative allocation indices and clock enables as
the architectural tags. When a speculative slot does not target INT_RS, its
shadow D value is complemented; a committed slot always writes the normal tag,
and the later slot-2 write guarantees the normal value for slot-2-only
dispatch. The two banks therefore differ while entries are invalid, so
synthesis cannot merge them, but they are asserted equal whenever an entry is
valid. Only the same-cycle CDB issue-bypass comparisons use the shadow tags.
Sequential ready/value capture and done-repair keep using the architectural
tags. This separates the low-fanout issue match from the otherwise-identical
match that controls every bit of the source-value write mux, without changing
wakeup or issue latency or adding loads to the free-entry clock-enable cone.

INT_RS also enables `ISSUE_CDB_META_ANCHORS` and receives one narrow,
phase-identical registered `{valid, tag}` copy of each CDB lane from the
wrapper (`i_issue_cdb_valid` / `i_issue_cdb_tag` and `i_issue_cdb_2_valid` /
`i_issue_cdb_2_tag`). Only the combinational same-cycle issue and readiness
comparisons use these copies. Sequential resident wakeup and value capture,
dispatch-defer matching and delivery, and captured operand values keep using
the complete CDB packets. The other stations leave the parameter off and use
their ordinary CDB metadata directly.

`BRANCH_PREDICATE_TAG_ANCHOR`, default off and enabled on INT_RS, adds one
more physical cut at the port-0 stage2 boundary. Five protected FFs capture
the same selected ROB tag under the same `issue_fire` enable as
`stage2_rob_tag`; their output, `o_branch_predicate_tag`, feeds only branch
resolution's checkpoint-owner comparisons and head-relative age predicate.
The architectural stage2 tag still drives `branch_update.tag`, ROB writes,
early-recovery capture, and the ALU adapter. A simulation assertion checks
phase identity whenever stage2 is valid, so the anchor changes fanout and
placement but not issue or resolution cycles.

Port 0 selects the lowest-index ready entry; physical index is not strict
age. [`rs_issue2_selector.sv`](rs_issue2_selector.sv) computes only port 1,
with a padded pairwise merge tree. Each subtree carries any-ready, first
ready-nonbranch, and first ready-nonbranch after excluding its first ready
entry. The isolated tree gives the exact serial result in ceil(log2(DEPTH))
levels without feeding port 0's index into another priority encoder.

## Storage strategy

Hybrid FF + LUTRAM. Control and operand fields stay in flip-flops because
they need parallel CAM-style access for CDB tag comparison and flush scans
across all entries. The read-once payload (operation, immediate, rounding
mode, PC, branch target, prediction metadata, memory-op flags, CSR address,
checkpoint id, branch-class pre-decode) is written once at dispatch and read
once at issue, so it lives in distributed RAM (`mwp_dist_ram`) with two
dispatch write ports, one per slot, and one issue read port per issue port.
`DUAL_ISSUE` adds a second LUTRAM copy read at `issue_idx_2`. The FF valid
bits gate every read, so stale payload behind an invalid entry is harmless.

The RS reports both `full` and `full_for_2`; dispatch uses the latter when
both slots target the same station.

## Pre-issue look-ahead

Each RS emits `o_pre_issue_rob_tag` and `o_pre_issue_needs_lq` one cycle
before the real issue fires. Only the MEM_RS instance has a consumer: the LQ
uses the pair to pre-register its address-update CAM match against the
incoming ROB tag, so the LQ entry's `addr_valid` is observable in the same
cycle MEM_RS issues (2 LUT levels at issue instead of 5–6). When address
translation is active, the wrapper substitutes the DMMU's equivalent
`o_pre_rob_tag` / `o_pre_needs_lq` hints. The port is unconnected on the
other instances.

## INT_RS head-wait diagnostics

The INT_RS instance exposes a small query port (`i_head_query_tag`,
`o_head_query_in_rs`, `o_head_query_rs_ready`, `o_head_query_in_stage2`)
driven from the ROB head tag. The wrapper's perf counters use it to split
`head_wait_int` into four mutually exclusive sub-buckets (`operand_wait`,
`rs_ready_not_issued`, `stage2`, `post_rs`), so CoreMark profiling can tell a
head ALU op stalled on a producer from one stuck behind FU arbitration.

## Partial flush

The partial flush input invalidates entries whose ROB tag is younger than the
flush boundary, using the same head-relative age comparison as the rest of
the back-end. Older entries survive.

## Verification

The `reservation_station` cocotb test covers one- and two-slot dispatch;
indexed repair across both slots and all sources; CDB-over-repair priority;
stale-target flush and same-tag ABA protection; lane wakeup and live bypass;
replay coalescing, target reuse, and partial-flush survivors; issue priority;
FU gating; `full_for_2`; and flushes. Its build passes `-G` overrides
(`ALLOC_INDEXED_REPAIR=1`, both repair bypasses off,
`SPECULATIVE_DATA_WRITES=1`, `BROADCAST_FREE_SOURCE_VALUES=1`,
`ISSUE_CDB_TAG_SHADOW=1`) that the module defaults leave off.

Simulation-only oracles, one per issue port and matched to the stage2
lifetime, recompute the former late-mux result and compare it with the
captured effective operand across stalls, flushes, and back-to-back refill.
The INT-only branch predicate tag assertion likewise covers hold,
flush-invalid, and refill behavior at the shared stage2 boundary.

Inline formal properties in the default formal target
(`reservation_station.sby`) prove the dispatch, issue, wakeup, and flush
invariants, registered CDB lane-value capture, per-entry pending/lane capture,
and pending-to-ready handoff. The indexed-repair response-alignment and
valid-entry shadow-tag-equality properties are parameter-gated
(`ALLOC_INDEXED_REPAIR` and `ISSUE_CDB_TAG_SHADOW` both default to 0), so
they are vacuous in that run; the cocotb build's `-G` overrides exercise those
features in simulation instead.

The second-port selector has a direct cocotb reference test
(`rs_issue2_selector`) and a depth-one formal miter (`rs_issue2_selector.sby`)
against the serial specification over unconstrained ready/branch inputs.
