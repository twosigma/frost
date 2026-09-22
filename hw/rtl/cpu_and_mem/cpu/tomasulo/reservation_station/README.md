# Reservation Station

A generic reservation station instantiated for INT (8 entries), MUL (4), MEM
(8), FP (6), FMUL (4), and FDIV (2). Each accepts both dispatch slots, tracks
operand readiness, and issues when all required sources are ready.

INT_RS is also built with `DUAL_ISSUE=1`: a second issue port (`o_issue_2` /
`i_fu_ready_2`) with its own selector, payload-RAM copy, and stage2 pipeline
register, feeding the second single-cycle ALU pipe. Its operand registers
capture the effective value (CDB, resident, or repair) on the issue edge, so
the second ALU, the SQ, and the CDB all launch from a register Q. INT port 0
uses the same boundary: its existing stage2 operand registers capture the
three-arm lane-0/lane-1 CDB bypass expression on the issue edge and
drive the primary ALU directly from Q. That capture is
`CAPTURE_PRIMARY_EFFECTIVE_OPERANDS`, default off, so the other five stations
keep the late mux. Port 0 keeps its serial priority encoder. A separate
balanced tree selects the lowest ready nonbranch entry other than port 0's
global lowest-ready winner. Branches issue only through port 0, which owns the
single `branch_resolution` / ROB branch-update path. The exclusion holds even
when backpressure keeps port 0 from firing, so the two ports can never claim
one entry. The other five stations elaborate with the default `DUAL_ISSUE=0`
and are structurally unchanged.

The secondary INT bank also captures six effective barrel shift-amount bits
in `o_issue_shift_amount_2`. The selector uses the same
`riscv_pkg::projected_shift_controls` predicate as the ALU, evaluated at
dispatch and kept per entry with immediate bits [5:0]
(`rs_shift_uses_imm`, `rs_shift_imm`), and the exact CDB-selected `src2` D
expression that feeds the wide operand register. The per-entry copies keep
the payload LUTRAM read off this endpoint. It captures on `issue_fire_2` and holds with the
existing packet; reset/flush clear ownership without resetting payload. The
ALU2 hint input removes the immediate/register amount mux after this boundary.
No mode flags, wide operands, priorities, or issue/completion cycles change.
The primary ALU retains local amount selection. This requests a different
logic partition; it adds a selector to the incoming RS D path, so fresh native
placement must check that path as well as any ALU improvement.

`rs_issue2_shamt` exercises all 18 full/word shift/rotate operations across 64
amounts, mismatched `use_imm`, both live CDB lanes, ready-low holds, back-to-back
refill, partial/full flush and reset. A clocked RTL assertion checks amount
identity throughout occupied stage2b cycles. `alu_shift_hint` is a separate
one-step combinational formal comparison of actual hinted/generic ALUs with
arbitrary binary operands/opcodes; it does not prove the RS scheduler or
unbounded capture lifecycle.

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

Port 1 resolves each entry's operands (live CDB lane, else resident or
repair value) before its one-hot select, so the late selector drives only the
final AND-OR into the stage2b operand registers.

`ISSUE2_WINDOW` limits port 1 to entries below that index (0, the default,
means all). Port 0 still sees every entry. Allocation takes the lowest free
index, so the window holds the longest-resident work. The selector's own
first-ready exclusion still equals port 0's winner whenever the window holds a
ready entry, because port 0 picks the lowest ready index overall. The wrapper
sets the window to `riscv_pkg::IntRsDepth` (eight). It changes nothing at the
default depth, and at `INT_RS_DEPTH=16` halves the port-1 selector and muxes.

Port 0 selects the lowest-index ready entry; physical index is not strict
age. [`rs_issue2_selector.sv`](rs_issue2_selector.sv) computes only port 1,
with a padded pairwise merge tree. Each subtree carries any-ready, first
ready-nonbranch, and first ready-nonbranch after excluding its first ready
entry. The isolated tree gives the exact serial result in ceil(log2(DEPTH))
levels without feeding port 0's index into another priority encoder.

## Storage strategy

Hybrid FF + LUTRAM. Control and operand fields stay in flip-flops because
they need parallel CAM-style access for CDB tag comparison and flush scans
across all entries. The read-once payload (operation, immediate, JALR offset,
rounding mode, prediction bits, memory-op flags, CSR address, checkpoint id,
instruction size, branch-class pre-decode) is written once at dispatch and
read once at issue, so it lives in distributed RAM (`mwp_dist_ram`) with two
dispatch write ports, one per slot, and one issue read port per issue port.
`DUAL_ISSUE` adds a second LUTRAM copy read at `issue_idx_2`. The FF valid
bits gate every read, so stale payload behind an invalid entry is harmless.

The payload carries no XLEN-wide branch word. Dispatch reuses `imm` for the
values ID precomputes from the PC: a conditional branch's target, AUIPC's
PC + imm_u, a fetch-fault pseudo-op's xtval, and JALR's link address (JALR's
12-bit offset rides `jalr_imm`). The INT instance keeps the remaining three
words, `pc`, `link_addr` and `predicted_target`, in a 32-entry ROB-tag-indexed
`mwp_dist_ram` (`TAG_INDEXED_BRANCH_PAYLOAD`): both dispatch slots write their
rows at their ROB tags, and port 0 reads the row of its stage2 tag through a
protected same-edge twin, the predicate-anchor pattern, so the architectural
tag's fanout is unchanged. The read feeds only early recovery's capture
registers and branch resolution's JALR target compare; no CDB completion path
starts at the RAM. Port 1 and the other stations drive zeros for the three
fields. The mode relies on ROB allocation never dispatching a tag that is
still live in the station (a resident entry or the stage2 packet). The
standalone formal target has no allocator to derive that from, so it assumes
it; the wrapper target contains the real ROB and asserts it instead
(`FORMAL_STANDALONE_ENV=0`). In simulation the station
checks the property the RAM needs, that a live row is never rewritten with
different contents, which also tolerates benches that hold one dispatch
packet valid across several cycles.
Direct branches carry the ID-computed one-bit `predicted_target_ok` instead
of comparing two XLEN targets at resolution.

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

The `reservation_station` cocotb target covers dispatch, repair, wakeup,
issue, stalls, flushes, and tag reuse. It enables dual-issue storage but holds
port 1 unavailable; `rs_issue2_selector` and `rs_issue2_shamt` check that
port's selection and shift-operand handling separately. The main bench does
not enable `TRUST_DISPATCH_VALID` or `ISSUE_CDB_META_ANCHORS`: it dispatches
into a full station and does not drive the anchor ports.

Formal `bmc`/`cover` tasks check default parameters. The `bmc_tag_indexed`
and `cover_tag_indexed` tasks check the full shipped INT configuration,
including its parameter-gated properties, under a ROB-tag ownership
assumption. The wrapper proof checks ownership against the real allocator.
Simulation assertions also check packet payloads and operands through
stalls, flushes, and refill.

See the [test runner](../../../../../../tests/README.md) for commands and the
[formal guide](../../../../../../formal/README.md) for proof scope and assumptions.
