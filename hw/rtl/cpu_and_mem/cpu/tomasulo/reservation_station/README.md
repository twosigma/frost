# Reservation Station

A reservation station holds renamed instructions until their source operands
are available, then issues them to a functional unit. `reservation_station.sv`
is one parameterized module, and the
[Tomasulo wrapper](../tomasulo_wrapper/README.md) instantiates it four times.
Each instance accepts up to two instructions per cycle from dispatch, wakes
waiting operands from both lanes of the common data bus (CDB), and issues the
lowest-index ready entry through a stage-2 register. The integer station has a
second issue port for a second ALU.

| Instance | Entries | Issues to |
|----------|---------|-----------|
| INT_RS | 16 (`INT_RS_DEPTH`) | `int_alu_shim` on port 0, a second `int_alu_shim` (ALU2) on port 1 |
| MUL_RS | 4 | `int_muldiv_shim` |
| MEM_RS | 8 | Address generation for the LQ and SQ, through the data MMU when translation is on |
| FP_RS | 2 (`riscv_pkg::FpRsDepth`) | `fp_shim` (three sources, for FMA) |

The [routing table](../README.md#reservation-station-routing)
lists which instructions go to which station.

An entry's life: dispatch writes it into a free slot, its sources become
ready, issue moves it into the stage-2 register and frees the slot, and the
functional unit takes it from stage 2.

## Dispatch

Each instance has two dispatch ports, one per dispatch slot. Slot 1 takes the
lowest-index free entry. Slot 2 takes the next free entry, or the lowest one
when slot 1 is not using this station. FP_RS ties slot 2 off, because
dispatch never puts an FP compute op in slot 2.

`o_full` and `o_full_for_2` are registered. `o_full_for_2` means at most one
entry is free; dispatch checks it when both slots target the same station.

A flush has priority over dispatch: in a flush cycle the station accepts no
dispatch and moves no new entry into stage 2.

## Operand wakeup

A source that is not ready at dispatch gets its value in one of three ways.

### From the CDB

Every cycle, each valid entry compares its unready source tags against both
CDB lanes. A match captures the value and sets the source ready at the clock
edge. The same comparison feeds the ready check, so an entry can issue in the
cycle its last operand is broadcast, taking the value straight from the CDB.
Both lanes feed this bypass in every instance (`LANE1_ISSUE_BYPASS`). The two
lanes never carry the same tag, so at most one lane matches a given source.

### During the dispatch cycle

A broadcast in the dispatch cycle would miss the new entry, which becomes
resident only at the next edge. The station records a pending bit and a lane
select for that source and registers both lane values; on the next edge the
source takes the registered value and becomes ready. This case costs a cycle,
and in exchange the CDB compare stays out of the dispatch write.

While a source is pending, its same-cycle bypass is off. Otherwise a
broadcast that reused the ROB tag in the delivery cycle could issue the entry
with another producer's value. Current pipeline depths cannot reuse a tag
that quickly; the pending bit rules it out regardless.

### Done repair

Dispatch marks every renamed source not ready, because the RAT does not know
whether the producer has completed, and a producer that completed before
dispatch will not broadcast again. Dispatch therefore registers the tag of
every renamed source, and one cycle later the wrapper reads the ROB's done bit
and value for each tag and returns them on six repair channels (`i_repair_*`):
1 to 3 for slot 1's sources, 4 to 6 for slot 2's.

A station consumes the channels in one of three ways:

- By tag match, the module default: every resident entry compares its source
  tags against all six channels. `DISPATCH_REPAIR_BYPASS` also applies a match
  as the entry is written, and `ISSUE_REPAIR_BYPASS` lets a match satisfy the
  ready check and supply the value at issue. No production instance uses this
  form.
- By allocation (`ALLOC_INDEXED_REPAIR=1`), on INT_RS, MUL_RS, and MEM_RS. The
  station remembers the entry each dispatch slot allocated, as a one-hot
  token, and one cycle later channels 1 to 3 write that slot-1 entry's sources
  and channels 4 to 6 the slot-2 entry's. The source becomes ready in the same
  cycle as with a tag match, without comparing six tags against every entry.
  Tokens are taken only on dispatches that commit an entry and are dropped on
  any flush. This mode requires both bypass parameters off.
- Not at all: FP_RS ties the channels to zero. Its packets wait in a
  one-entry buffer in the wrapper, which applies the repair before the packet
  enters the station (see the
  [FP dispatch buffer](../tomasulo_wrapper/README.md#fp-dispatch-buffer)).

A repair response and a deferred dispatch-cycle delivery can reach the same
source on the same edge, and both then carry the same producer's result
(simulation asserts this). In allocation-indexed stations the two share one
data bus per slot and source, and the deferred delivery takes priority over
live CDB, repair, and dispatch writes.

## Issue

A station's issue port (port 0 on INT_RS) takes the lowest-index ready entry.
Index is not age: allocation reuses the lowest free entry, so a younger
instruction can sit below an older one. INT_RS finds that entry in two
levels, the lowest ready entry in each group of four and then the lowest
group that has one, which gives the same index as a serial priority encoder.

An entry issues when it is ready, `i_fu_ready` is high, and the stage-2
register is empty or being emptied this cycle. At the clock edge the entry
moves into stage 2 and its slot frees; the functional unit sees it on
`o_issue` in the next cycle, with `o_issue.valid = stage2_valid && i_fu_ready`.
If `i_fu_ready` drops, stage 2 holds the packet.

## Divide gate (MUL_RS)

MUL_RS feeds a pipelined multiplier and a divider that takes one operation at
a time. `i_fu_ready` covers only the multiplier, since lowering it for a
waiting divide would also stop the multiplies behind it. Instead MUL_RS
(`DIVIDE_ISSUE_GATE=1`) keeps a divide bit per entry, which stage 2 carries,
and treats a divide entry as not ready while `i_divider_busy` is high or stage
2 holds a divide. Multiplies issue past waiting divides.

A presented divide therefore always finds the divider idle: a divide enters
stage 2 only while the divider is idle and no other divide is in stage 2, and
the divider leaves idle only by starting the divide that stage 2 presents. The
stage-2 term covers the cycle a divide leaves stage 2, when the busy input is
still low. The gate requires `DUAL_ISSUE=0`. Waiting divides still hold
entries, so a station full of divides stops dispatch.

## Dual issue (INT_RS)

INT_RS is built with `DUAL_ISSUE=1`, which adds a second issue port
(`o_issue_2`, `i_fu_ready_2`) with its own selector, a second copy of the
payload RAM, and a second stage-2 register. Port 1 feeds ALU2.

- Port 1 issues the lowest-index ready entry that is not a branch and is not
  port 0's pick. It excludes port 0's pick even when port 0 is stalled, so the
  two ports never take the same entry.
- Conditional branches and JALR issue only on port 0, which has the only path
  into branch resolution and the ROB's branch update.
- Port 1 considers only entries below `ISSUE2_WINDOW`, which is eight
  (`riscv_pkg::IntRsIssue2Window`); port 0 sees all 16. Allocation fills the
  lowest free entries first, so most ready work sits inside the window.

The window does not break the exclusion. Inside the window, "port 0's pick" is
the lowest ready entry there, which equals port 0's real pick whenever the
window holds a ready entry; when it holds none, port 1 has nothing to issue.

[`rs_issue2_selector.sv`](rs_issue2_selector.sv) computes port 1's pick with a
balanced tree. Each subtree reports whether it holds a ready entry, its first
ready non-branch entry, and its first ready non-branch entry other than its
own first ready entry. Merging pairs of subtrees gives the serial answer in
log2(window) levels.

Port 1's stage-2 register captures each operand's final value at issue (CDB
lane 0, then lane 1, then the resident or repair value), so ALU2 reads its
operands straight from flip-flops. Port 1 also registers a six-bit shift
amount, `o_issue_shift_amount_2`: the immediate's low six bits for an
immediate shift, otherwise the low six bits of the final src2 value, decoded
by `riscv_pkg::projected_shift_controls` as in the ALU. ALU2 shifts by this
amount; port 0's ALU derives its own.

## Storage

Fields that every entry compares or updates in parallel live in flip-flops:
valid and ready bits, source tags and values, the ROB tag, and the few bits
the port-1 selector and shift amount need. Fields written once at dispatch and
read once at issue live in a distributed-RAM payload with one write port per
dispatch slot: the operation, immediate, JALR offset, rounding mode,
prediction bits, memory-op flags, CSR address and immediate, checkpoint ID,
compressed flag, and a branch-class predecode. Port 1 reads its own copy, and
INT_RS splits port 0's copy into groups of four entries that follow the
two-level issue select. The valid bits gate every read, so stale payload
behind a free entry is never used.

### Branch payload side RAM (INT_RS)

The per-entry payload carries no 64-bit branch words. Dispatch reuses the
immediate for values ID precomputes from the PC: a conditional branch's
target, AUIPC's `pc + imm`, a fetch-fault pseudo-op's xtval, and JALR's link
address (JALR's 12-bit offset travels in `jalr_imm`). The remaining three
words, `pc`, `link_addr`, and `predicted_target`, live in a 32-row side RAM
indexed by ROB tag (`TAG_INDEXED_BRANCH_PAYLOAD`). Both dispatch slots write
their rows at their own ROB tags, and port 0 reads the row for the tag in its
stage-2 register. Only early misprediction recovery (the redirect and BTB
update) and branch resolution's JALR target check use them; a conditional
branch checks its predicted target with the one-bit `predicted_target_ok`
that ID computes. Port 1 and the other stations drive the three fields to
zero.

The side RAM relies on one rule: dispatch never reuses a ROB tag that is still
live in the station, as a resident entry or in stage 2. It holds because an
instruction cannot commit, and so free its tag, until it has executed, which
happens as it leaves stage 2; a flush that frees the tag earlier clears the
entry or stage-2 packet on the same edge. A row is therefore read only by the
packet whose dispatch wrote it. The standalone formal target assumes the
rule, and the wrapper formal target, which contains the real ROB, asserts it.

## Pre-issue look-ahead

In the cycle an entry is selected for stage 2, each station outputs its ROB
tag and `needs_lq` bit (`o_pre_issue_rob_tag`, `o_pre_issue_needs_lq`), a
cycle before `o_issue` presents it. Only MEM_RS's are connected: the LQ
registers its address-update tag match from them, so the load's LQ entry is
address-valid in the cycle MEM_RS presents the load (see the
[load queue](../load_queue/README.md)). Under data translation the wrapper
substitutes the data MMU's look-ahead tag.

With early load wakeup, MEM_RS's winner depends on which registered CDB lanes
and early-load token are valid, and those arrive late. MEM_RS
(`PREISSUE_VALID_COFACTOR`, `PREISSUE_RAW_WAKEUP`, `PREISSUE_READY_EXPORT`)
therefore exports a ready vector for each of the eight combinations on
`o_pre_issue_ready`, plus its entry tags on `o_pre_issue_entry_tags`, and
`o_pre_issue_sel` names the actual combination. The LQ compares its own tags
against the entry tags, finds each candidate's match from its ready vector,
and selects with `o_pre_issue_sel` after registering. With both lanes valid
the token changes nothing, so candidates 3 and 7 share a vector.

## Flushes

A partial flush (`i_flush_en`, `i_flush_tag`) invalidates every entry whose
ROB tag is younger than `i_flush_tag`, measured from `i_rob_head_tag`; older
entries survive. A full flush (`i_flush_all`) empties the station. Both
stage-2 registers follow the same rules.

`o_issue.valid` is not masked by a flush in the same cycle, so the packet in
stage 2 is presented in the flush cycle even when the flush kills it; a
packet the flush spares transfers as usual. Consumers must ignore a killed
packet, and the current ones do: the LQ and SQ match it by ROB tag against
entries the same edge removes, CDB results for flushed tags are discarded,
and the data MMU applies the flush-age check itself.

## Diagnostics

Every instance answers a ROB-tag query (`i_head_query_tag`) with whether it
holds that tag, whether that entry is ready, and whether the tag is in a
stage-2 register. The wrapper queries with the ROB head tag and feeds INT_RS's
answers to the [performance counters](../../cpu_ooo/perf/README.md), which
split `head_wait_int` into operand wait, ready but not issued, in stage 2, and
past the station. `o_perf_two_ready_one_issued` flags cycles where port 0
issued while another entry was also ready; the wrapper exports it for MEM_RS.

## Parameters

| Parameter | Default | Wrapper setting | Effect |
|-----------|---------|-----------------|--------|
| `DEPTH` | 8 | Per instance (table above) | Number of entries |
| `HAS_SRC3` | 1 | 1 on FP, 0 elsewhere | Third source operand, for FMA |
| `DUAL_ISSUE` | 0 | 1 on INT | Second issue port |
| `ISSUE2_WINDOW` | 0 (all entries) | 8 on INT | Port 1 considers only entries below this index |
| `LANE1_ISSUE_BYPASS` | 1 | Default everywhere | CDB lane 1 feeds the same-cycle issue bypass; off, a lane-1 result wakes consumers a cycle later |
| `TAG_INDEXED_BRANCH_PAYLOAD` | 0 | 1 on INT | Branch side RAM; off, port 0 drives `pc`, `link_addr`, and `predicted_target` to zero |
| `DIVIDE_ISSUE_GATE` | 0 | 1 on MUL | A divide entry is not ready while `i_divider_busy` is high or stage 2 holds a divide; requires `DUAL_ISSUE=0` |
| `TRACK_INT_WRITEBACK_HINT` | 0 | 1 on INT | Drives `o_issue_writes_cdb_hint`, set for every op except conditional branches; `int_alu_shim` raises a completion only when it is set |
| `ALLOC_INDEXED_REPAIR` | 0 | 1 on INT, MUL, MEM | Done repair by allocation instead of tag match |
| `DISPATCH_REPAIR_BYPASS` | 1 | 0 on INT, MUL, MEM | Tag-matched repair applies as the entry is written |
| `ISSUE_REPAIR_BYPASS` | 1 | 0 everywhere | Tag-matched repair satisfies the ready check at issue |
| `PREISSUE_VALID_COFACTOR` | 0 | `EARLY_LOAD_WAKEUP` on MEM | One look-ahead winner per combination of CDB lane valids |
| `PREISSUE_RAW_WAKEUP` | 0 | 1 on MEM | Eight look-ahead candidates (lane valids and the early-load token) instead of four |
| `PREISSUE_READY_EXPORT` | 0 | `EARLY_LOAD_WAKEUP` on MEM | Export the candidate ready vectors and entry tags to the LQ |
| `DISPATCH_STATUS_RESERVE` | 0 | Default everywhere | Nonzero: register the full flags from the current count with this many entries held back, instead of exactly |
| `FORMAL_STANDALONE_ENV` | 1 | 0 everywhere | Formal only. 1 (standalone target): assume the dispatch rules and the side-RAM tag rule, and enable covers. 0 (wrapper target): assert the tag rule against the real ROB instead |

These parameters change how the logic is built for timing, not what the
station does:

| Parameter | Default | Wrapper setting | Effect |
|-----------|---------|-----------------|--------|
| `TRUST_DISPATCH_VALID` | 0 | 1 on INT, MEM | Skip the local room check; dispatch valids already include it (simulation asserts the two agree) |
| `SPECULATIVE_DATA_WRITES` | 0 | 1 on INT, MUL, MEM | Write tags and values into the target free entry before dispatch is confirmed; only `rs_valid` commits the entry |
| `BROADCAST_FREE_SOURCE_VALUES` | 0 | 1 on INT | Write slot 1's source values into every free entry and slot 2's into its target; requires speculative writes |
| `ISSUE_CDB_TAG_SHADOW` | 0 | 1 on INT | A second src1/src2 tag bank used only by the same-cycle bypass; equal to the main tags for every valid entry |
| `ISSUE_CDB_META_ANCHORS` | 0 | 1 on INT | The same-cycle bypass compares use separate registered copies of each lane's valid and tag (`i_issue_cdb_*`) |
| `CAPTURE_PRIMARY_EFFECTIVE_OPERANDS` | 0 | 1 on INT | Port 0 registers final src1/src2 values at issue instead of muxing CDB values after stage 2; requires `HAS_SRC3=0` |
| `BRANCH_PREDICATE_TAG_ANCHOR` | 0 | 1 on INT | A copy of the stage-2 ROB tag drives `o_branch_predicate_tag` for branch resolution's checkpoint and age compares; off, the output is the stage-2 tag |

## Verification

- The `reservation_station` cocotb bench builds an eight-entry station with
  dual issue, indexed repair, speculative and broadcast writes, the tag
  shadow, and the branch side RAM, and covers dispatch, deferred delivery,
  repair, wakeup, issue, stalls, flushes, and tag reuse. It holds port 1 idle
  and leaves `TRUST_DISPATCH_VALID` and `ISSUE_CDB_META_ANCHORS` off.
- `rs_issue2_selector` (cocotb and formal) checks port 1's selector against a
  serial reference, and `rs_issue2_shamt` checks its shift amount.
- The `reservation_station` formal target checks the module defaults and the
  INT configuration; the `tomasulo_wrapper` target checks the 16-entry INT
  station against the real allocator; `rs_divide_gate` checks MUL_RS's divide
  gate against a divider model. Smaller targets check the restructured
  select, repair, and look-ahead logic against plain references.

See the [test runner](../../../../../../tests/README.md) for commands and the
[formal guide](../../../../../../formal/README.md) for proof scope and assumptions.
