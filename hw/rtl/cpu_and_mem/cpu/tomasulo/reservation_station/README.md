# Reservation Station

A generic, parameterized reservation station instantiated six times
with different depths for INT (16), MUL (4), MEM (8), FP (6),
FMUL (4), and FDIV (2) operations. Each instance tracks operand
readiness for its slice of the instruction stream and issues to a
functional unit when both sources (or all three, for FMA) are ready.
Each RS accepts slot-1 and slot-2 dispatch packets so a 2-wide bundle can place
two entries into the same station when there is room.

INT_RS is sized to absorb the bursty ALU arrivals that dominate
CoreMark — CoreMark profiling showed INT RS full ~7% of the time
with average occupancy ~4 at depth 8, so the queue was doubled
without changing any other RS structure. Everything else
(entry array, wakeup network, and port-0 priority encoder) scales by parameter.

INT_RS is additionally built with `DUAL_ISSUE=1`: a second issue port
(`o_issue_2` / `i_fu_ready_2`) with its own selector, payload-RAM copy, and
stage2 pipeline register, feeding the second single-cycle ALU pipe. The
canonical serial port-0 priority encoder remains unchanged. An independent
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
with per-source per-lane bypass masks selecting the captured lane value at
issue time. Lane 1 originally stayed out of the issue cone as an Fmax trade;
with two ALU pipes making dual completions common, the +1-cycle lane-1
wakeup tax outweighed it, and the parameter remains as a per-instance
fallback knob if the wakeup cone becomes the timing limiter again.

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

The immediate INT, MUL, and MEM stations instead set
`ALLOC_INDEXED_REPAIR=1` with both bypass parameters disabled. Dispatch
and the registered ROB lookup launch together, so each station saves a
one-hot token for the exact entry allocated by slot 1 and/or slot 2.
One cycle later, channels 1/2/3 update that slot-1 entry's fixed source
positions and channels 4/5/6 update the slot-2 entry directly. This has
the same dispatch-to-ready latency as the registered CAM snoop while
removing the six global repair tags from every resident source-value
write-enable cone. Allocation tokens are captured only on committed
dispatch fires and are discarded on either kind of flush.

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

Port-0 issue selection is a simple lowest-index priority encode over ready
entries. That's not strict FIFO order, but it's a close enough approximation
for the depths used here that the slightly older entries usually go first
anyway. [`rs_issue2_selector.sv`](rs_issue2_selector.sv) computes only port 1
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
This saves a substantial number of flip-flops compared to keeping
the whole entry in registers.

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

Cocotb tests run with the INT_RS free-entry source-value broadcast and
issue-tag shadows enabled and cover dispatch, slot-2-only dispatch, same-cycle
slot-1/slot-2 dispatch, allocation-indexed repair for both slots and all source
positions, back-to-back target capture, CDB-over-repair priority, stale-target
flush protection, lane-0 CDB wakeup for each source slot, same-cycle lane-0
bypass, dispatch capture from lane 0, issue priority, FU ready gating,
immediate bypass, `full_for_2` gating, and partial/full flush. Inline formal
properties in the default formal target prove the dispatch / issue / wakeup /
flush invariants and indexed-target alignment, and cover both-slots and
slot-2-alone dispatch. The shadow-enabled RTL additionally contains a
valid-entry shadow-tag equality assertion for strengthened formal runs.

The second-port selector additionally has a direct cocotb reference test and a
depth-one formal miter against the original serial specification. Unconstrained
16-bit ready and branch-class inputs make that equivalence proof exhaustive.
