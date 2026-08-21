# Reservation Station

A generic reservation station instantiated for INT (8 entries), MUL (4), MEM
(8), FP (6), FMUL (4), and FDIV (2). Each accepts both dispatch slots, tracks
operand readiness, and issues when all required sources are ready.

Eight INT entries cost only 0.125%/0.059% in paired RV64 CoreMark runs versus
12, with identical results and retired-instruction counts. The smaller station
removes a second-issue selector level and halves padded payload storage. Other
entry arrays and port-0 selection scale with the parameter.

INT_RS is additionally built with `DUAL_ISSUE=1`: a second issue port
(`o_issue_2` / `i_fu_ready_2`) with its own selector, payload-RAM copy, and
stage2 pipeline register, feeding the second single-cycle ALU pipe. Its operand
registers capture the effective CDB or resident/repair value on the issue edge,
so ALU2/SQ/CDB launches from register Q. INT port 0 uses the same boundary: its
existing
stage2 operand registers capture the exact former three-arm lane-0/lane-1 CDB
bypass expression on the issue edge and drive the primary ALU directly from Q.
The default-off `CAPTURE_PRIMARY_EFFECTIVE_OPERANDS` retains the late mux for
the other five stations. The canonical port-0 priority encoder remains
unchanged. An independent
balanced tree selects the lowest ready nonbranch entry other than port 0's
global lowest-ready winner. Branches issue only through port 0, which owns the
single `branch_resolution` / ROB branch-update path. Exclusion applies even
when backpressure prevents port 0 from firing, so the two ports can never claim
one entry. The other five stations elaborate with the default `DUAL_ISSUE=0`
and are structurally unchanged.

The wakeup mechanism is a two-lane Tomasulo CDB snoop: each entry compares its
source tags against both broadcast tags every cycle, and a match captures the
value and marks the source ready. Both lanes feed the combinational
same-cycle issue bypass (`LANE1_ISSUE_BYPASS`, default on), so a resident
entry can issue in the same cycle its last operand arrives on either lane,
with the architectural CDB contract keeping the two lane tags distinct. Port 0
in the default mode carries the match and lane values through its stage2 bank
for late selection; both INT ports fold that same selection into their existing
operand-register D inputs. `LANE1_ISSUE_BYPASS` remains a per-instance timing
fallback.

A CDB broadcast coincident with a committed allocation is delivered one cycle
later. The allocated entry records a per-source pending bit and lane selector,
while two shared registers capture the CDB lane values on the same edge. On
the following edge, each pending source receives its selected registered value,
becomes ready, and clears its pending bit. Lane 0 wins a same-tag collision.
While a source is pending, its live issue bypass is suppressed so an immediate
tag-reuse (ABA) broadcast cannot replace the dispatch-cycle value; unrelated
first-resident live matches remain eligible without an added cycle.

Alongside the CDB lanes there is a six-channel done-repair interface
(`i_repair_valid_1..6` / `i_repair_tag_1..6` / `i_repair_value_1..6`):
registered wakeups from dispatch that carry operands whose CDB
broadcast landed before the consumer was dispatched and so were
missed by the live snoop. In the generic mode, a post-insertion repair
snoop CAMs those tags against resident entries every cycle; two
parameters additionally fold repair into the fast paths —
`DISPATCH_REPAIR_BYPASS` lets an entry capture a repaired value at
insertion, and `ISSUE_REPAIR_BYPASS` lets a repair match satisfy the
ready check and supply the value at issue.

The immediate-dispatch stations — INT, MUL, and MEM, which take dispatch
packets directly rather than through the wrapper's one-entry pending stage
like the FP, FMUL, and FDIV families — instead set
`ALLOC_INDEXED_REPAIR=1` with both bypass parameters disabled. Dispatch
and the registered ROB lookup launch together, so each station saves a
one-hot token for the exact entry allocated by slot 1 and/or slot 2.
One cycle later, channels 1/2/3 update that slot-1 entry's fixed source
positions and channels 4/5/6 update the slot-2 entry directly. This has
the same dispatch-to-ready latency as the registered CAM snoop while
removing the six global repair tags from every resident source-value
write-enable cone. Allocation tokens are captured only on committed dispatch
fires and are discarded on either kind of flush.

INT_RS also enables `BROADCAST_FREE_SOURCE_VALUES` together with
`SPECULATIVE_DATA_WRITES`. Every currently-invalid entry is prefilled with
slot 1's source values; when a speculative slot-2 write is possible, its exact
allocation target receives slot 2's values instead. Only `rs_valid` commits an
entry, so the additional free-entry writes are unobservable. This preserves
the existing dispatch and issue latency while replacing the wide value flops'
priority-decoded free-index clock enable with the entry-local invalid bit;
the slot-2 allocation index affects only the selected input data.

INT_RS also enables `ISSUE_CDB_TAG_SHADOW`. A second src1/src2 tag bank is
written through the same speculative allocation indices and clock enables as
the architectural tags. When a speculative slot does not target INT_RS, its
shadow D value is complemented; a committed slot always writes the normal tag,
and the later slot-2 write guarantees the normal value for slot-2-only
dispatch. The two banks therefore differ while entries are invalid and
synthesis cannot merge them, but they are asserted equal whenever an entry is
valid. Only the same-cycle CDB issue-bypass comparisons use the shadow tags.
Sequential ready/value capture and done-repair continue to use the
architectural tags. This separates the low-fanout issue match from the
otherwise-identical match that controls every bit of the source-value write
mux, without changing wakeup or issue latency or adding loads to the
free-entry clock-enable cone.

INT_RS additionally enables `ISSUE_CDB_META_ANCHORS` and receives one narrow,
phase-identical registered `{valid, tag}` copy of each CDB lane from the
wrapper. Only the combinational same-cycle issue/readiness comparisons use
these copies. Sequential resident wakeup and value capture, dispatch-defer
matching/delivery, and captured operand values continue to use the ordinary
complete CDB packets. All other stations leave the parameter off and therefore
use their ordinary CDB metadata directly.

The default-off `BRANCH_PREDICATE_TAG_ANCHOR` parameter adds one more INT-only
physical cut at the existing port-0 stage2 boundary. Five protected FFs capture
the same selected ROB tag under the same `issue_fire` enable as
`stage2_rob_tag`; their output feeds only branch resolution's checkpoint-owner
comparisons and head-relative age predicate. The architectural stage2 tag still
drives `branch_update.tag`, ROB writes, early-recovery capture, and the ALU
adapter. A simulation assertion checks phase identity whenever stage2 is valid,
so the anchor changes fanout and placement but not issue or resolution cycles.

Port 0 selects the lowest-index ready entry; physical index is not strict age.
[`rs_issue2_selector.sv`](rs_issue2_selector.sv) computes only port 1
with a padded pairwise merge tree. Each subtree carries any-ready, first
ready-nonbranch, and first ready-nonbranch after excluding its first ready
entry. The isolated tree preserves the exact serial result while removing the
port-0-index-to-port-1-encoder dependency.

## Storage strategy

Hybrid FF + LUTRAM. Control and operand fields stay in flip-flops
because they need parallel CAM-style access for CDB tag comparison
across all entries. The read-once payload (operation, immediate,
rounding mode, branch target, prediction metadata, CSR address, …)
is written once at dispatch and read once at issue, so it lives in
distributed RAM with dispatch write ports and one issue read port per
issue port (`DUAL_ISSUE` adds a second LUTRAM copy read at `issue_idx_2`).
This avoids keeping the full payload in flip-flops.

The payload RAM has parallel dispatch write ports for slot 1 and slot 2. The RS
reports both `full` and `full_for_2`; dispatch uses the latter when both slots
target the same station.

## Pre-issue look-ahead

Each RS emits `o_pre_issue_rob_tag` and `o_pre_issue_needs_lq` one
cycle before the real issue fires. Only the MEM_RS instance is
wired into a consumer: the LQ uses it to pre-register its
address-update CAM match against the incoming ROB tag, so the
LQ entry's `addr_valid` is observable the same cycle MEM_RS issues
(2 LUT levels at issue instead of 5–6). The port is free on the
other instances.

## INT_RS head-wait diagnostics

The INT_RS instance exposes a small query port (`i_head_query_tag`,
`o_head_query_in_rs`, `o_head_query_rs_ready`, `o_head_query_in_stage2`)
wired from the ROB head tag. The wrapper uses these to partition
`head_wait_int` into four mutually-exclusive sub-buckets
(`operand_wait`, `rs_ready_not_issued`, `stage2`, `post_rs`) so CoreMark
profiling can distinguish a head ALU stalled on a producer from one
stuck behind FU arbitration.

## Partial flush

The partial flush input invalidates entries whose ROB tag is younger
than the flush boundary, using the same age-based comparison as
elsewhere in the back-end. Older entries are preserved.

## Verification

Cocotb covers one- and two-slot dispatch; indexed repair across both slots and
all sources; CDB-over-repair priority; stale-target flush and same-tag ABA
protection; lane wakeup/live bypass; replay coalescing, target reuse, and
partial-flush survivors; issue priority; FU gating; `full_for_2`; and flushes.

Simulation-only lifetime-matched oracles independently retain the former
late-mux result for each issue port and compare it with the captured effective
operand across stalls, flushes, and back-to-back refill. The INT-only branch
predicate tag assertion likewise covers hold, flush-invalid, and refill
behavior at the shared stage2 boundary.

Inline formal properties in the default formal target prove the dispatch /
issue / wakeup / flush invariants, registered CDB lane-value capture,
per-entry pending/lane capture, and pending-to-ready handoff.
The indexed repair response alignment and valid-entry shadow-tag equality properties are
parameter-gated (`ALLOC_INDEXED_REPAIR` and `ISSUE_CDB_TAG_SHADOW` both default
to 0), so they are vacuous in that run and are instead exercised in simulation
by the reservation_station cocotb build's `-G` overrides.

The second-port selector has a direct cocotb reference and a depth-one formal
miter against the serial specification over unconstrained ready/branch inputs.
