# Reservation Station

A reservation station holds renamed instructions until their source operands
are available, then issues them to a functional unit. `reservation_station.sv`
is one parameterized module; the
[Tomasulo wrapper](../tomasulo_wrapper/README.md) instantiates it six times.
Each instance accepts up to two instructions per cycle from dispatch, wakes
waiting operands from both lanes of the common data bus (CDB), and issues the
lowest-index ready entry through a stage-2 register. The integer station has a
second issue port that feeds a second ALU.

| Instance | Entries | Issues to |
|----------|---------|-----------|
| INT_RS | 16 (`INT_RS_DEPTH`) | `int_alu_shim` on port 0, a second `int_alu_shim` (ALU2) on port 1 |
| MUL_RS | 4 | `int_muldiv_shim` |
| MEM_RS | 8 | Address generation for the LQ and SQ, through the data MMU when translation is on |
| FP_RS | 6 | `fp_add_shim` |
| FMUL_RS | 4 | `fp_mul_shim` (three sources, for FMA) |
| FDIV_RS | 2 | `fp_div_shim` |

The [routing table](../README.md#instruction--reservation-station-routing)
lists which instructions go to which station.

An entry's life: dispatch writes it into a free slot → its sources become ready
→ issue moves it into the stage-2 register and frees the slot → the functional
unit takes it from stage 2.

## Dispatch

Each instance has two dispatch ports, one per dispatch slot. Slot 1 takes the
lowest-index free entry. Slot 2 takes the next free entry, or the lowest one
when slot 1 is not using this station. The FP-family stations tie slot 2 off,
because dispatch never puts an FP compute op in slot 2.

`o_full` and `o_full_for_2` are registered. `o_full_for_2` means at most one
entry is free; dispatch checks it when both slots target the same station.

A flush has priority over dispatch: in a flush cycle the station accepts no
dispatch and moves no new entry into stage 2.

## Operand wakeup

A source that is not ready at dispatch can get its value three ways.

### From the CDB

Every cycle, each valid entry compares its unready source tags against both
CDB lanes. A match captures the value and sets the source ready at the clock
edge. The same comparison also feeds the ready check directly, so an entry can
issue in the cycle its last operand is broadcast, taking the value straight
from the CDB. Both lanes feed this same-cycle bypass in every instance
(`LANE1_ISSUE_BYPASS`). The two lanes never carry the same tag, so at most one
lane matches a given source.

### During the dispatch cycle

A broadcast that lands in the same cycle as the dispatch write would miss the
new entry, which only becomes resident at the next edge. The station therefore
records a pending bit and a lane select for that source and registers both lane
values. On the following edge the source receives the registered value and
becomes ready. Deferring the capture keeps the CDB comparison out of the
dispatch write path, at the cost of one cycle in this case.

While a source is pending, its same-cycle bypass is disabled. Otherwise a
broadcast that reused the ROB tag in the delivery cycle could issue the entry
with another producer's value (the ABA problem). Tag reuse that fast cannot
happen with the current pipeline depths; the pending bit rules it out by
construction instead of by timing.

### Done repair

Dispatch marks every renamed source not ready, because the RAT does not know
whether its producer has already completed. A producer that completed before
dispatch has already broadcast and will not broadcast again. To catch it,
dispatch registers the tag of every renamed source; one cycle later the wrapper
reads the ROB's done bit and value for each tag and returns them on six repair
channels (`i_repair_*`): channels 1 to 3 for slot 1's sources, 4 to 6 for slot
2's.

A station can consume the channels in three ways:

- By tag match, the module default. Every resident entry compares its source
  tags against all six channels. `DISPATCH_REPAIR_BYPASS` also applies a match
  as the entry is written, and `ISSUE_REPAIR_BYPASS` lets a match satisfy the
  ready check and supply the value at issue.
- By allocation (`ALLOC_INDEXED_REPAIR=1`), used by INT_RS, MUL_RS, and MEM_RS.
  The station remembers the entry each dispatch slot allocated, as a one-hot
  token. One cycle later channels 1 to 3 write that slot-1 entry's sources and
  channels 4 to 6 the slot-2 entry's. The source becomes ready in the same
  cycle as with the tag match, without comparing six tags against every entry.
  Tokens are taken only on dispatches that commit an entry and are dropped on
  any flush. This mode requires both bypass parameters off, which a simulation
  check and a formal assertion enforce.
- Not at all. FP_RS, FMUL_RS, and FDIV_RS tie the channels to zero. Their
  packets wait in a one-entry buffer in the wrapper, which applies the repair
  before the packet enters the station (see
  [FP-family dispatch buffers](../tomasulo_wrapper/README.md#fp-family-dispatch-buffers)).

No production instance uses the tag-match form.

A repair response and a deferred dispatch-cycle delivery can reach the same
source on the same edge. Both then carry the same producer's result, which
simulation asserts.

## Issue

A station's issue port (port 0 on INT_RS) takes the lowest-index ready entry,
chosen by a priority encoder. Index is not age: allocation reuses the lowest
free entry, so a younger instruction can sit below an older one.

An entry issues when it is ready, `i_fu_ready` is high, and the stage-2
register is empty or being emptied this cycle. At the clock edge the entry
moves into stage 2 and its slot frees; the functional unit sees it on
`o_issue` in the next cycle, with `o_issue.valid = stage2_valid && i_fu_ready`.
If `i_fu_ready` drops, stage 2 holds the packet.

## Dual issue (INT_RS)

INT_RS is built with `DUAL_ISSUE=1`, which adds a second issue port
(`o_issue_2`, `i_fu_ready_2`) with its own selector, a second copy of the
payload RAM, and a second stage-2 register. Port 1 feeds ALU2. The rules:

- Port 1 issues the lowest-index ready entry that is not a branch and is not
  port 0's pick. It excludes port 0's pick even when port 0 is stalled and does
  not fire, so the two ports never take the same entry.
- Conditional branches and JALR issue only on port 0, which has the only path
  into branch resolution and the ROB's branch update.
- Port 1 considers only entries below `ISSUE2_WINDOW`, set to eight
  (`riscv_pkg::IntRsIssue2Window`) independently of the 16-entry capacity.
  Port 0 sees every entry. Allocation fills the lowest free entries first, so
  most ready work sits inside the window.

The window does not break the exclusion. The selector sees only the window, so
it computes "port 0's pick" as the lowest ready entry inside it. That equals
port 0's real pick whenever the window holds any ready entry, because port 0
takes the lowest ready index overall. When the window holds none, port 1 has
nothing to issue.

[`rs_issue2_selector.sv`](rs_issue2_selector.sv) computes port 1's pick with a
balanced tree. Each subtree reports whether it holds a ready entry, its first
ready non-branch entry, and its first ready non-branch entry after excluding
its own first ready entry. Merging subtrees pairwise gives the exact serial
answer in log2(window) levels, without feeding port 0's result into a second
priority encoder.

Port 1's stage-2 register captures each operand's final value at issue (live
CDB value, resident value, or repair value), so ALU2 reads its operands straight
from flip-flops. Port 1 also exports a registered six-bit shift amount,
`o_issue_shift_amount_2`: the immediate's low six bits for an immediate shift,
otherwise the low six bits of the final src2 value. The choice uses
`riscv_pkg::projected_shift_controls`, the same decode the ALU uses. ALU2 shifts
by this amount; port 0's ALU derives its own.

## Storage

Fields that every entry must compare or update in parallel live in flip-flops:
valid and ready bits, source tags and values, the ROB tag, and the few bits the
port-1 selector and shift amount need. Fields written once at dispatch and read
once at issue live in a distributed-RAM payload (`mwp_dist_ram`) with one write
port per dispatch slot: the operation, immediate, JALR offset, rounding mode,
prediction bits, memory-op flags, CSR address and immediate, checkpoint ID,
compressed flag, and a branch-class predecode. Port 1 reads its own copy. The
flip-flop valid bits gate every read, so stale payload behind a free entry is
never used.

### Branch payload side RAM (INT_RS)

The per-entry payload carries no 64-bit branch words. Dispatch reuses the
immediate for values ID precomputes from the PC: a conditional branch's target,
AUIPC's `pc + imm`, a fetch-fault pseudo-op's xtval, and JALR's link address
(JALR's 12-bit offset travels in `jalr_imm`). The three remaining words, `pc`,
`link_addr`, and `predicted_target`, live in a 32-row side RAM indexed by ROB
tag (`TAG_INDEXED_BRANCH_PAYLOAD`). Both dispatch slots write their rows at
their own ROB tags, and port 0 reads the row for the tag in its stage-2
register. Their only functional consumers are early misprediction recovery
(the redirect and BTB-update capture) and branch resolution's JALR target
check; conditional branches check their predicted target with the one-bit
`predicted_target_ok` that ID computes. Port 1 and the other stations drive the
three fields to zero.

The side RAM relies on one rule: dispatch never reuses a ROB tag that is still
live in the station, as a resident entry or in stage 2. The rule holds because
an instruction cannot commit, and so free its tag, until it has executed, which
happens as it leaves stage 2; a flush that frees the tag earlier clears the
entry or stage-2 packet on the same edge. So a row is only ever read by the
packet whose dispatch wrote it. The standalone formal target assumes the rule;
the wrapper formal target, which contains the real ROB, asserts it. Simulation
also compares every stage-2 read with a copy of the packet's own three words.

## Pre-issue look-ahead

In the cycle an entry is selected for stage 2, each station outputs its ROB tag
and `needs_lq` bit (`o_pre_issue_rob_tag`, `o_pre_issue_needs_lq`), one cycle
before `o_issue` presents it. Only MEM_RS's are connected: the LQ registers its
address-update tag match from them, so the load's LQ entry reads address-valid
in the same cycle MEM_RS presents the load (see the
[load queue](../load_queue/README.md)). Under data translation the wrapper
substitutes the data MMU's own look-ahead tag.

With early load wakeup, MEM_RS runs with `PREISSUE_VALID_COFACTOR=1` and
`PREISSUE_RAW_WAKEUP=1` and exports eight candidate tags on
`o_pre_issue_rob_tags`: the winner for each combination of the two registered
CDB lane valids and the early-load token, with the actual combination on
`o_pre_issue_sel`. The LQ registers the tag match for all eight candidates and
selects afterwards, which keeps the lane-occupancy select out of its match
path. Whenever an entry is ready, the selected candidate is the tag of the
entry actually chosen, which simulation asserts. `PREISSUE_VALID_COFACTOR=1`
alone gives four candidates, one per pair of lane valids. With it off, every
candidate repeats the single tag and the selector is zero.

## Flushes

A partial flush (`i_flush_en`, `i_flush_tag`) invalidates every entry whose ROB
tag is younger than `i_flush_tag`, measured from `i_rob_head_tag`; older
entries survive. A full flush (`i_flush_all`) empties the station. Both stage-2
registers follow the same rules.

`o_issue.valid` is not masked by a flush in the same cycle, so the packet in
stage 2 is presented in the flush cycle even when the flush kills it; a packet
the flush spares transfers as usual. Consumers must ignore a killed packet, and
the current ones do: the LQ and SQ match it by ROB tag against entries the same
edge removes, CDB results for flushed tags are discarded, and the data MMU
applies the flush-age check itself.

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
| `HAS_SRC3` | 1 | 1 on FMUL, 0 elsewhere | Third source operand, for FMA |
| `DUAL_ISSUE` | 0 | 1 on INT | Second issue port |
| `ISSUE2_WINDOW` | 0 (all entries) | 8 on INT | Port 1 considers only entries below this index |
| `LANE1_ISSUE_BYPASS` | 1 | Default everywhere | CDB lane 1 feeds the same-cycle issue bypass; off, a lane-1 result wakes consumers a cycle later |
| `TAG_INDEXED_BRANCH_PAYLOAD` | 0 | 1 on INT | Branch side RAM; off, port 0 drives `pc`, `link_addr`, and `predicted_target` to zero |
| `TRACK_INT_WRITEBACK_HINT` | 0 | 1 on INT | Drives `o_issue_writes_cdb_hint`, set for every op except conditional branches; `int_alu_shim` raises a completion only when the hint is set |
| `ALLOC_INDEXED_REPAIR` | 0 | 1 on INT, MUL, MEM | Done repair by allocation instead of tag match |
| `DISPATCH_REPAIR_BYPASS` | 1 | 0 on INT, MUL, MEM | Tag-matched repair applies as the entry is written |
| `ISSUE_REPAIR_BYPASS` | 1 | 0 everywhere | Tag-matched repair satisfies the ready check at issue |
| `PREISSUE_VALID_COFACTOR` | 0 | `EARLY_LOAD_WAKEUP` on MEM | Export one look-ahead tag per combination of CDB lane valids (see [Pre-issue look-ahead](#pre-issue-look-ahead)) |
| `PREISSUE_RAW_WAKEUP` | 0 | 1 on MEM | Eight early-wakeup candidates instead of four |
| `DISPATCH_STATUS_RESERVE` | 0 | Default everywhere | Nonzero: register the full flags from the current count with this many entries held back, instead of exactly |
| `FORMAL_STANDALONE_ENV` | 1 | 0 everywhere | Formal only. 1 (standalone target): assume the dispatch rules and the side-RAM tag rule, and enable covers. 0 (wrapper target): drop those assumptions and assert the tag rule against the real ROB |

The parameters below exist for timing. Each changes how the logic is built, not
what the station does.

| Parameter | Default | Wrapper setting | Effect |
|-----------|---------|-----------------|--------|
| `TRUST_DISPATCH_VALID` | 0 | 1 on INT, MEM | Skip the local room check; dispatch valids already include it (simulation asserts the two agree) |
| `SPECULATIVE_DATA_WRITES` | 0 | 1 on INT, MUL, MEM | Write tags and values into the target free entry before dispatch is confirmed; only `rs_valid` commits the entry |
| `BROADCAST_FREE_SOURCE_VALUES` | 0 | 1 on INT | Write slot 1's source values into every free entry and slot 2's into its target; requires speculative writes |
| `ISSUE_CDB_TAG_SHADOW` | 0 | 1 on INT | A second src1/src2 tag bank used only by the same-cycle bypass; equal to the main tags for every valid entry |
| `ISSUE_CDB_META_ANCHORS` | 0 | 1 on INT | The same-cycle bypass compares use separate registered copies of each lane's valid and tag (`i_issue_cdb_*`) |
| `CAPTURE_PRIMARY_EFFECTIVE_OPERANDS` | 0 | 1 on INT | Port 0 registers final src1/src2 values at issue instead of muxing CDB values after stage 2; requires `HAS_SRC3=0` |
| `BRANCH_PREDICATE_TAG_ANCHOR` | 0 | 1 on INT | A separate copy of the stage-2 ROB tag drives `o_branch_predicate_tag` for branch resolution's checkpoint and age compares, while every other consumer uses `o_issue.rob_tag`; off, the output aliases the stage-2 tag |

## Verification

- The `reservation_station` cocotb target builds an eight-entry station with
  dual issue, indexed repair, speculative and broadcast writes, the tag shadow,
  and the branch side RAM. It covers dispatch, deferred dispatch-cycle
  delivery, repair, wakeup, issue, stalls, flushes, and tag reuse. It holds
  port 1 idle, and it leaves `TRUST_DISPATCH_VALID` and
  `ISSUE_CDB_META_ANCHORS` off because it dispatches into a full station and
  does not drive the `i_issue_cdb_*` inputs.
- `rs_issue2_selector` (cocotb and formal) checks port 1's selector against a
  serial reference. `rs_issue2_shamt` (cocotb) checks the port-1 shift amount
  for every shift and rotate operation at all 64 amounts, through CDB capture,
  holds, refill, flushes, and reset.
- The `reservation_station` formal target checks the module defaults (`bmc`,
  `cover`) and the INT configuration at eight entries without the port-1
  window (`bmc_tag_indexed`, `cover_tag_indexed`, which assume the side-RAM tag
  rule). The `tomasulo_wrapper` formal target checks the 16-entry INT station
  and its eight-entry window against the real allocator.
- Small formal targets check restructured logic against a plain reference:
  `rs_alloc_parallel`, `rs_issue_clear`, `rs_dispatch_defer`,
  `rs_pretag_cofactor`, and `rs_raw_pretag`.
- Simulation assertions check operands and payloads through stalls, flushes,
  and refill.

See the [test runner](../../../../../../tests/README.md) for commands and the
[formal guide](../../../../../../formal/README.md) for proof scope and assumptions.
