# FROST CPU

The FROST CPU is an RV64 core with an in-order front end that fetches,
predicts, and decodes up to two instructions per cycle, and a Tomasulo back end
that renames them in order, executes them out of order, and retires them in
program order. `cpu_ooo/cpu_ooo.sv` is the top level. The sections below
describe the front end, instruction address translation, Debug Mode, and the
glue in `cpu_ooo`; renaming, the reservation stations, the load and store
queues, and commit are in the [back-end README](tomasulo/README.md).

The [CPU and system architecture diagram](../../../../docs/diagrams/frost-architecture.svg)
shows the front end, Sv39 translation, the memory interfaces, and in-order
commit. The [back-end diagram](../../../../docs/diagrams/tomasulo-backend.svg)
expands renaming, execution, result broadcast, and load/store ordering.

## Directory contents

| Path | Contents |
|------|----------|
| [`cpu_ooo/`](cpu_ooo/) | `cpu_ooo.sv` and its glue submodules |
| [`tomasulo/`](tomasulo/README.md) | Back end: dispatch, rename tables, reservation stations, load and store queues, ROB |
| `if_stage/` | Fetch PC control, branch prediction, instruction alignment |
| `pd_stage/` | Slot-1 instruction from the native word or its predecoded RVC expansion, early source fields, the PD branch redirect |
| `id_stage/` | Decode for both slots |
| `mmu/` | Instruction MMU (16-entry ITLB), data MMU (16-entry DTLB), 512-entry second-level TLB with a 32-entry superpage side array, shared page-table walker |
| `misaligned/` | Misaligned-access engine (`ma_engine`) and its checks (`ma_pkg`) |
| `csr/` | CSR file; CSR instructions execute at commit |
| `control/trap_unit.sv` | Traps, delegation, interrupts, Debug Mode entry, and the no-CSR take that starts the misaligned-access engine |
| `ex_stage/` | ALU, multiplier and divider, FPU, branch unit |
| `wb_stage/` | Register file module used for the INT and FP files |
| `vector/` | Vector unit datapath blocks (see [Vector state](#vector-state)) |
| `riscv_pkg.sv` | Shared parameters, types, and predecode functions |

`cpu_ooo/cpu_ooo.f` is the authoritative CPU source list.

## Inside cpu_ooo

`cpu_ooo.sv` instantiates the IF, PD, and ID stages, `dispatch`,
`tomasulo_wrapper` (the back end), `csr_file`, two IMSIC interrupt files,
`trap_unit`, the page-table
walker (`mmu/ptw`), and these glue submodules from [`cpu_ooo/`](cpu_ooo/):

| Submodule | Directory | Role |
|-----------|-----------|------|
| `ooo_pipeline_control` | `pipeline_control/` | Front-end stalls, CSR and control-flow serialization, unresolved-branch tracking, post-flush holdoff, the registered trap and xRET redirect, prediction disable |
| `frontend_validity_tracker` | `frontend_control/` | Marks which IF/PD/ID packets are real instructions and classifies unpredicted control flow ([README](cpu_ooo/frontend_control/README.md)) |
| `decoded_bundle_queue` | `frontend_control/` | Queue of decoded two-instruction bundles between ID and dispatch, four deep by default ([README](cpu_ooo/frontend_control/README.md)) |
| `ooo_register_files` | `register_files/` | INT and FP architectural register files, two write ports each for two-wide commit, and a bypass that forwards a same-cycle commit to dispatch; with `EXTRA_READ_PORT`, one more read port on each file for the misaligned-access engine |
| `commit_actions` | `commit/` | Register writes at commit, the delayed CSR writeback, the misaligned-access engine's load result on port 0, the retire valid, and the instret increment |
| `branch_resolution` | `branch_recovery/` | Resolves conditional branches and JALRs from INT_RS with `branch_jump_unit` and reports them to the ROB, ignoring a branch whose checkpoint was reused. A JAL resolves when the ROB allocates it |
| `early_misprediction_recovery` | `branch_recovery/` | For a mispredicted conditional branch that holds a checkpoint, redirects fetch and restores the RAT the cycle after it resolves, instead of at commit |
| `misprediction_flush_controller` | `branch_recovery/` | Commit-time mispredictions, full and partial flush priority, checkpoint restore and free |
| `tage_history` | `branch_recovery/` | The tagged direction predictor's path history and its restores, the saved lookup of each conditional branch, and training at commit |
| `ex_comb_synthesizer` | `recovery/` | Builds IF's redirect, BTB-update, and RAS-restore bus from early recovery, commit-time recovery, and correct-branch commits, in that priority |
| `data_mem_request_router` | `memory_if/` | Data-port arbitration (SQ writes, then AMO writes, then LQ reads), staged device reads, tagged completion for the cached tier; see the [data-tier bus rules](../../README.md#data-tier-bus-contract) |
| `perf_counter_aggregator` | `perf/` | Top-level and cache profiling counters and the counter read mux, present only with `PERF_COUNTERS=1` ([counter reference](cpu_ooo/perf/README.md)) |

The tagged cached reads and stores connect directly to `coherent_hart_cache`
in `frost_hart.sv`.

`cpu_ooo.sv` itself keeps the logic that ties these blocks together:

- the decoded-queue hookup, including the register copy of the head bundle's
  control fields that dispatch reads;
- a per-ROB-entry table of each branch's predict-time bimodal index, and
  bimodal training at commit;
- the `tage_history` hookup: the branches PD hands to ID, the registered
  dispatch allocations, the commit taps, and a simulation check that each
  committing branch trains from the entry PD saved for it;
- branch checkpoint bookkeeping: which branch holds each checkpoint, and
  freeing the checkpoints of flushed branches;
- the registered write enables and addresses for the register-file bypass;
- commit and trap glue: the commit hold while a trap or xRET waits, the
  interrupt shields that stop an interrupt from re-executing an AMO or device
  read that has already started, the hold that keeps a new device access from
  starting while an interrupt take is armed, the quiet window around
  [translation-changing CSR writes](#csr-writes), and the interrupt resume PC
  (the PC an interrupt saves, which trap entry and xRET preset to their target
  because an interrupt can arrive before the first instruction there retires);
- the page-table walker's request select (`walk_request_select.sv` and the
  misaligned-access engine's turn);
- the Debug Mode single-step engine and the status bits the debug module
  reads;
- a reset-done counter, and the `dbg_*` signals that cocotb tests read.

## Front end

### Pipeline

IF receives a 64-bit window each cycle: the 32-bit word at the fetch PC and
the word after it. It cuts up to two instructions from the window, assembling
a 32-bit instruction that starts in the upper half of a word from both words
in the same cycle. Compressed instructions are expanded when their words are
written to instruction memory or filled into the L1I (see
[Instruction fetch providers](#instruction-fetch-providers)): IF builds slot 2
from that predecoded RV64C expansion, PD does the same for slot 1 and extracts
source registers early, and ID decodes both slots. Decoded bundles wait in the
[decoded bundle queue](cpu_ooo/frontend_control/README.md) until dispatch
renames them. While `mstatus.FS` is Off, ID decodes every F/D instruction as
illegal, so it reaches dispatch as an illegal-instruction marker and never
touches memory or FP state; the [CSR-write flush](#csr-writes) keeps that
decode in step with FS.

IF keeps two PCs. The fetch PC (`o_pc`) addresses instruction memory and the
slot-1 BTB lookup. `pc_reg` is the PC of the packet IF emits, normally one
cycle behind. A taken slot-1 prediction moves the fetch PC to the target at
once, and `pc_reg` follows one cycle later, after the branch itself has been
emitted; a taken slot-2 prediction moves both PCs at once. A two-instruction
bundle advances `pc_reg` by 4, 6, or 8 bytes, a single instruction by 2 or 4.

The architectural-PC mux receives raw live slot-2 validity and staged/live
cofactors separately. The Xilinx implementation keeps saved replay in its
no-live arm and applies raw live validity in the final F7. The
complete staged select is replay OR (valid AND staged cofactor); the complete
live select is valid AND live cofactor. Redirect and live/staged priorities
remain the same.

Reset loads both PCs with the boot address at their flops. `pc_controller`
picks the next fetch PC in this priority: trap or xRET, FENCE-class flush
(FENCE.I, SFENCE.VMA, or a
[translation-changing CSR write](#csr-writes)), misprediction recovery, PD
redirect, served-window resteer, hold while no window arrives, slot-2
prediction, slot-1 prediction, the pending-prediction and halfword catch-up
cases, then the sequential PC.

### Branch prediction

| Structure | Size | Predicts | Trained by |
|-----------|------|----------|------------|
| BTB | 256 entries, direct-mapped, 2-bit counters | Target and direction of conditional branches, JALs and JALRs; an entry is typed as a call, a return, or both | Mispredicted conditional branches, JALs and JALRs; correctly predicted conditional branches at commit |
| Backing BTB | 1024 entries, two-way set-associative | Target of a JAL or JALR the BTB did not predict taken, through a PD redirect | Mispredicted JALs and JALRs at commit; each PD redirect it serves refreshes its entry's replacement state |
| Return address stack | 8 entries | The target of a BTB hit typed as a return (`jalr x0, 0(ra)`, `c.jr ra`) or a coroutine swap (`jalr t0, 0(ra)`), and of a backing BTB redirect for one | IF, when it hands PD a packet predicted from a typed entry, and for a backing BTB redirect: a call (JAL or JALR writing `ra` or `t0`) pushes, a return pops, a swap replaces the top; recovery restores it |
| Bimodal direction predictor | 1024 2-bit counters | Direction of slot-1 conditional branches without a taken BTB prediction or a tagged match | Each conditional branch at commit |
| Tagged direction predictor | Two tables of 1024 entries, hashed with 16 and 64 bits of path history; 9-bit tags, 3-bit counters | Direction of conditional branches in either slot whose lookup matches a tag, either way | Each conditional branch at commit, at the entries its lookup read |

A return is predicted like any BTB hit, from the lookup at its fetch PC, but
its entry is typed, so its target is the top of the return address stack
while the stack holds an entry (the BTB target, the return's last target,
otherwise). Any other JALR, such as an indirect call through a function
pointer, predicts the target it had when it last trained the BTB. A JALR that
is not predicted resolves as mispredicted, because a JALR is always taken, and
recovers when it commits, as does a JALR predicted with the wrong target. While an unpredicted JALR is in the front end (slot 1 of IF, PD, or
ID, or the decoded queue) and a conditional branch or JALR is unresolved,
`ooo_pipeline_control` stalls the front end to limit wrong-path fetch.

The BTB is indexed by PC[9:2]. Its tags include PC[1], so a lookup at one
halfword of a word never hits an entry trained for the other. A hit predicts
taken when the upper counter bit is set. The slot-1 lookup reads the fetch PC.
To track a pending prediction, slot-2 raw rows and the forwarded payload each form their five-bit
PC relation and apply return typing before coverage selects a row. An uncovered
row relates a zero low target in the served PC's upper region. The controller
receives the selected relation alongside the unchanged target outputs.

Slot 2 has three BTB copies of its own, keyed by the PC of the instruction
before it (+2 and +4, plus a copy rotated by one index for a slot 2 in the
next word). They are read a cycle ahead, so the lookup adds no fetch cycle,
but a taken slot-2 prediction costs one bubble because fetch has already
requested the next sequential window (plus PD's redirect bubbles if a tagged
match vetoes it there). At a halfword PC, a slot-2 hit predicts
only if the entry was trained for an instruction of the same size. A JAL that
misses both the BTB and the backing BTB mispredicts once; training at commit
makes its next execution hit.

BTB tags are fetch PCs, with no ASID or translation mode, and nothing
corrects a taken hit on an instruction that is not control flow: PD and the
branch unit check only branches and jumps. So the BTB clears every entry in
the full-flush cycle of each event after which the code or the address space
under an entry may differ: FENCE.I, SFENCE.VMA, a `satp` write, a trap, xRET
or Debug Mode entry that switches fetch between bare (M-mode) and Sv39
addresses, and every take into or within Debug Mode, since a go runs
program-buffer and abstract-command words the debug module may have
rewritten. The clear lasts four cycles, which drops training still in flight
from the old code.
`mstatus` and `sstatus` writes, and takes that stay on one side of that
switch, keep the BTB. Code changed without FENCE.I, or a valid executable
mapping replaced without SFENCE.VMA, is not covered (see the
[roadmap](../../../../ROADMAP.md#possible-future-work)).

PD can change the direction fetch followed for a conditional branch in either
slot, and redirects a JAL or JALR that the BTB did not predict taken when the
backing BTB holds it (see [Backing BTB](#backing-btb)).
IF reads two direction predictors at the fetch PC and passes their
directions along with the packet. For slot 1, a tagged direction, when the
branch's lookup matches a tag, is used either way; otherwise the bimodal
direction can only turn a branch without a taken BTB prediction (a miss, or
a hit predicted not-taken) to taken. Slot 2 uses the tagged predictor only
(it has no bimodal lookup): a tagged match can turn a slot-2 branch without a
taken BTB prediction to taken, or veto a taken slot-2 BTB prediction after
its fetch bubble. When the chosen direction differs from fetch's, PD
redirects fetch to PC + offset, or for not-taken to the next instruction, at
a cost of two bubbles, and ID gives the branch the new prediction so the
branch unit checks the path fetch follows. Commit trains the bimodal entry
at the carried index, not at the branch's own PC, because the fetch PC that
read the predictor can differ from the branch PC after a stall replay or at
a halfword boundary. A slot-2 branch's training waits, one deep, for a cycle
in which slot 1 does not train; a newer one replaces it.

The tagged predictor (`tage_predictor`) follows TAGE. T1 hashes the branch's
word address with the newest 16 bits of the global path history, T2 with all
64. Each table is two 512-entry banks split by PC[2], so one lookup reads both
words of the fetch window; the lookup registers and is compared with the tags
the next cycle. The longer-history table whose tag matches provides the
direction. Every taken control-flow instruction shifts bits [3:2] of its
target into the history. The lookup history follows fetch: `tage_history`
pushes the target the cycle after `pc_controller` loads a predicted one, and
each redirect restores the history to its point in the program. The
controller captures push and restore events with the PC load and captures
zero for a held PC. A trap, xRET, FENCE-class flush, or commit-time recovery
takes the history of the retired instructions. Early recovery or a PD
redirect takes the branch's own lookup history, plus its target when taken.
A served-window resteer, which only variable-latency fetch produces,
leaves the history unchanged, so when one returns fetch to a branch already
predicted taken, the branch is looked up again with its own target in the
history. That costs accuracy, not correctness.

When PD passes a conditional branch to ID, its lookup (indices, tags, which
tables matched, the alternate direction, and the history) goes to a 64-entry
circular buffer. Dispatch sees the branches in the same order, so it gives the
branch the same index from a pointer of its own and records it by ROB tag;
every flush that drops branches in between rewinds both pointers to the same
entry. Commit trains from that entry, one branch per cycle with the same
slot-2 hold. The provider's counter moves toward the outcome, and when the
provider and the alternate direction disagree, its usefulness bit records
whether the provider was right. A mispredicted branch allocates a weak entry
in the first table above its provider (T1, then T2) whose entry is not useful,
or clears those usefulness bits when every candidate is useful. Slot-2
branches are trained the same way, from the prediction left after any PD
override.

### Backing BTB

`backing_btb` is a second BTB level with 1024 entries in two ways (four for
measurement, through `riscv_pkg::BackingBtbWays`). It holds jumps, calls and
returns only: the BTB updates of JALs and JALRs train it, so it holds every
jump that has mispredicted unless replacement has since taken it, or an
update was dropped because the update one stage ahead writes the same set.
Every hit predicts taken. A correctly predicted jump sends no update, so a
PD redirect that the backing BTB serves refreshes its entry instead, making
it the most recently used way of its set. Its sets are indexed
by the PC's word, like the BTB. An entry's tag holds the PC bits above the
index and PC[1], with its size and whether it was trained on a return; the
target is kept in a separate array. A miss allocates an invalid way or the
way the set's replacement state names; a target in another 4 GiB region
invalidates the entry, as in the BTB. Reset clears one set per cycle, and
the backing BTB makes no predictions until every set is clear.

The lookup follows the fetch PC: the set of `o_pc`'s word, and the set after
it for a slot 2 in the next word, read on the edge that requests the window.
When IF serves that window the next cycle, the registered tags are compared
with the packet's PC, so a packet whose set was not read gets no backing hit,
and neither does a slot 2 in the word after the last set. The hit, size and
type come from the registered tags, and the target from the target array
read on the same edge. IF passes PD each slot's hit, size, type and target,
kept across stall replay like the packet. PD registers a candidate for a
slot-1 or slot-2 JAL or JALR whose backing entry has the instruction's size.
When the slot's BTB prediction was not taken, the candidate fires the PD
redirect, which costs the PD redirect's two bubbles instead of a
misprediction recovery, ID gives the instruction the prediction, and IF
passes the instruction's PC to the backing BTB as a refresh. The ROB checks
a JAL's target at allocation, and the branch unit a JALR's at execution, as
for any prediction. The instruction's own encoding, by the rules recovery
uses, names its return address stack operation: a call pushes its link
address, a return pops, and a coroutine swap does both. An entry trained on
a return targets the top entry of the packet's recovery point while the
stack holds an entry, and its stored target otherwise; an entry whose type
does not match the instruction at its PC costs only a misprediction. IF
performs the operation once, in the redirect's first cycle (see [Return
address stack recovery](#return-address-stack-recovery)). A build that
disables branch prediction gets no backing redirects. A jump the backing BTB
predicts is not copied into the BTB: its correct prediction sends no update,
so the BTB keeps the entry in that slot, and the jump costs the PD redirect
for as long as that entry stays.

### Two-wide fetch and dispatch

IF pairs two instructions only when all of these hold:

- Slot 1 is not control flow (a branch, JAL, JALR, or a compressed form of
  one) and not a native SYSTEM, MISC-MEM, or AMO instruction (CSR accesses,
  ECALL, EBREAK, xRET, WFI, SFENCE.VMA, FENCE, FENCE.I, and atomics including
  LR/SC). The Zimop may-be-operations (SYSTEM with funct3 100) are the
  exception: they write zero to rd and touch no other state, so they pair
  like an integer instruction, in either slot.
- Slot 2 is not a native SYSTEM (other than a may-be-operation), MISC-MEM,
  AMO, FP-compute (OP-FP or fused multiply-add) or vector instruction (OP-V,
  or LOAD-FP and STORE-FP with a vector width). It may be a branch or jump:
  the slot-2 BTB lookup, the tagged direction predictor (through a PD
  redirect), or the backing BTB can predict it, while the bimodal fallback
  covers slot 1 only.
- Slot 2 fits in the window. A 32-bit slot 2 that would start in the upper
  half of the second word does not.
- No transient condition intervenes, such as an unsafe window read, an
  instruction-buffer case the aligner does not pair, or a
  [pending prediction](#pending-prediction-handoff) that needs a one-wide
  packet.

A CSR instruction reads and writes its CSR at commit, and its CDB broadcast
carries only its write operand, so dispatch holds everything younger until the
CSR's result is written back. A slot-2 partner would slip past that hold. The
predecode puts CSR accesses in one serializing class with the other native
SYSTEM instructions (all but the may-be-operations), MISC-MEM, and AMO
instructions, and that class never leads a pair.
These instructions also retire alone at the ROB head, which keeps them out of
slot 2. FP-compute instructions stay out of slot 2 to keep FP
reservation-station back-pressure off the slot-1 dispatch path, and vector
instructions so that at most one reaches the ROB per cycle; the next bundle
takes them as slot 1.

Dispatch treats a bundle as a unit: slot 2 fires only with slot 1, and if slot
2 lacks a resource the whole bundle waits. Because slot-1 control flow ends a
bundle, a cycle allocates at most one branch checkpoint. The
[dispatch README](tomasulo/dispatch/README.md) has the resource checks, and
the [ROB README](tomasulo/reorder_buffer/README.md) covers two-wide commit.

### Instruction fetch providers

`frost_hart` feeds IF from two instances of `fetch_provider`, selected using the
configured physical-memory attributes:

| Provider | Serves | Response |
|----------|--------|----------|
| Uncached, 8-byte blocks | Executable uncached Normal memory | Narrow AXI reads, two owned slots, no victim cache or next-block prefetch |
| Optional Normal cache, 32-byte lines | Same Normal region with `CACHE_NORMAL_MEMORY=1` | Two AXI fill slots and a direct-mapped cache, 256 lines by default |
| Cached, 32-byte lines | Executable cached Normal memory | Two buffers over L1I, next-line prefetch and a six-line victim store |

FROST low BRAM sits behind the SoC AXI slave. Both providers generate their
predecode metadata from returned instruction bytes. A bus error creates an
instruction access fault and never installs a victim entry. Device regions
cannot be fetched. FROST enables the optional Normal cache; its entries survive
branches and invalidate on FENCE.I, reset, and debug GO requests. The
[debug GO contract](../../cpu_top/README.md#optional-normal-read-caching-and-write-through-stores)
orders invalidation before CPU acceptance. Next-line prefetches must remain
executable under the configured PMA. The standalone
CPU defaults to strict uncached access. The fixed-latency `low_bram_fetch_presenter`
serves only the positional TestRIG fixture and component tests.

IF tolerates any provider latency. When no valid window arrives, IF emits NOP
bubbles and freezes its PC and per-packet state while the provider keeps
working on the owed request. Redirects retarget the provider, except a slot-1
prediction made before the branch itself reached IF: that branch's window is
still owed and must arrive first.

Every 32-bit word carries 80 bits of predecode metadata: 12 fetch-control
bits (instruction size, pairing, and slot-2 eligibility) and, for each
halfword, the full RV64C expansion with its illegal flag and whether an
indirect jump (JALR, C.JR, C.JALR) starts there. The expansion's
source-register fields are stored separately, and PD takes a compressed
instruction's register fields from them. CPU fetch fills compute the metadata with
`riscv_pkg::imem_make_sideband`, and
`sw/common/generate_imem_predecode_init.py` mirrors it for the
instruction-memory metadata arrays that component tests use.

### Operation encoding

`id_stage/instr_decoder.sv` maps each instruction to an eight-bit
`riscv_pkg::instr_op_e` value, while `id_stage/instr_operand_classifier.sv`
extracts its reservation station, register-operand flags and serialization
flags directly from the 32-bit instruction word in parallel. Explicit anchors
in `instr_op_e` (`ROL = 8'd76` and `ADDIW = 8'd170`) hold `ROL..RORI` and
`SLLIW..RORIW` at the ordinals `riscv_pkg::projected_shift_controls` decodes by
bit position, while `SLL..SRAI` precede any folded member. New members are
appended after the last member so an insertion or deletion never disturbs the
shift ordinals (an insertion among the word shifts or a deletion ahead of
`SRAI` compiles and is caught only by `alu.sv`'s simulation assertions and the
`alu_shift_hint` formal check).

Operations use one `instr_op_e` value per operation across widths and CSR
source forms when width, sign or CSR operation travels in fields already
carried to the consumer (`mem_size`, `mem_signed`, `rm`, `imm`, the ROB's
`csr_op` field, or `vec_unit`'s per-tag instruction copy). Scalar integer and
floating-point loads and stores, load-reserved, store-conditional and each
atomic read-modify-write function share one operation across widths and
signedness, taking width from `mem_size` (`funct3[1:0]`) and, for integer loads
and `LR`, load sign from `mem_signed` (`!funct3[2]`, zero for floating-point
loads and AMOs). Register and immediate CSR accesses use two operations
(`CSR_REG` and `CSR_IMM`); dispatch writes `funct3` into the ROB entry's
`csr_op` field (clearing `csr_op[1:0]` when a set or clear form has `rs1` or
`uimm` equal to zero), and `csr_file` reads `rob_commit.csr_op` at commit.
Vector instructions use class operations (`VARITH`, `VARITH_X`, `VTOX`,
`VLOAD`, `VSTORE`), with `vec_unit` keeping its own per-tag instruction copy
written at allocation from `from_id_to_ex.instruction`. Scalar floating-point
compute operations are the next candidates for folding, as they differ by
`funct7` and `rs2`, which the floating-point reservation station can carry in
its unused immediate.

## Address translation

`if_stage` uses `mmu/immu` to translate the fetch PC into the physical
addresses of the window's two words, with a fault flag for each word. In Bare
mode and in M-mode, translation is a combinational pass-through with no
bubble. Under Sv39 the virtual page and privilege tag permit intra-page
fetches to use the live offset without a bubble. A window crossing a 4 KiB
boundary also requires an exact PC tag. A page or privilege change costs one
capture cycle; a crossing can need another cycle for its next-page sample.
An ITLB miss stalls IF until the walk returns. Each ITLB entry checks fetch
permissions, PMA and the superpage successor before winner selection. The
instruction-side instance disables unused data permission and PMA verdicts.
Walk responses supply a separate successor candidate. A window within one page
uses word 0's physical page and faults for both words.
The word-1 address uses the sampled next-page VA on a fault from the separate
page lookup. A captured selector chooses that address. A crossing window's
word-1 page is captured as the hit's stored PPN bits and its superpage size,
and the sampled next-page VA supplies a superpage's low page bits when the
address is read. The first-word fault is the last verdict the ITLB settles, so
the registers that take it on a capture (word 1's fault and its cause, the
VA-placeholder select and the neighbor-miss flag) form their clear, capture or hold choice,
the crossing and the next-page verdict first, and take the first-word fault
and the superpage successor in one final LUT each.

The data MMU caches the last clean page translation and its permissions.
A matching eligible access enters the result stage in one cycle. Other
accesses use the lookup stage followed by the result stage. Reset, full flush,
translation disable and TLB invalidation clear the last-page buffer.
The issue VA is the base-plus-offset sum. The lookup stage's advance, which
depends on the DTLB hit, and the skid choice for the lookup stage each select
between a held VA and that sum in one LUT per bit after the full sum, so
neither enters the adder's operands.

The 16-entry ITLB and the data side's 16-entry DTLB share one read-only
page-table walker in `cpu_ooo`. `walk_request_select` picks the requester from
registered state: the data side while its S1 holds an op without a walk, the
instruction side otherwise. An instruction request that the data side turned
away, in a cycle where the port was ready and the data op did not ask, goes
first in the next cycle.
The misaligned-access engine, which runs at the ROB head with the data MMU
empty, takes the port while it asks. The walker
never writes PTEs (Svade): a leaf with A=0, or a store to a leaf with D=0,
raises a page fault for software to handle. SFENCE.VMA, `satp` accesses, and
`mstatus` writes that change MPRV (or MPP under MPRV) discard any walk in
flight and clear the walker's pointer cache; which TLB entries they remove
is described under "Address-space IDs and SFENCE.VMA" below.

A 4-way, 128-set second-level TLB (`l2tlb.sv`, 512 entries, 2 MiB of 4 KiB
pages, block RAM) sits between the two MMUs and the walker. An L1 TLB miss
that hits there is answered two cycles after the request fires, in place of
a walk of one to three dependent line reads; a miss reaches the walker one
cycle later than it would without the array. It stores the clean 4 KiB
translations that the walker returns. Clean 2 MiB and 1 GiB leaves go to a
32-entry fully associative superpage side array beside it (`SP_ENTRIES`):
tags, ASIDs, global bits and levels in flops, compared level-masked in the
same cycle as the block RAM ways, and PPNs and permissions in distributed RAM,
read in the next cycle, so a superpage hit answers three cycles after the
request fires for any page of its region. Neither array holds negative
entries, so a PTE that changes from invalid to valid is seen without
SFENCE.VMA (Svvptc). SUM and MXR stay out of the entries, so toggling them
needs no flush. `cpu_ooo` takes `L2TLB_SETS` (0 removes both arrays; any
other value must be a power of two, as must the way count).

### Address-space IDs and SFENCE.VMA

`satp.ASID` is nine bits wide (ASIDLEN = 9): writing all ones to the field and
reading it back, the way Linux probes it, returns `0x1FF`. Every L1 and L2 TLB
entry carries the ASID it was installed under and the leaf's global bit (the
walker ORs the bit over the levels it descended). A lookup matches an entry of
its own ASID, or a global entry under any ASID.

- A `satp` write that changes the ASID leaves every entry in place, so a
  context switch between two address spaces whose pages are resident walks
  nothing. The walker's pointer cache is untagged and still empties.
- A `satp` write that changes the root under the same ASID flushes every
  entry, for software that never assigns ASIDs. An `mstatus` write that
  changes MPRV (or MPP under MPRV) flushes every entry.
- SFENCE.VMA reads rs1 (the virtual address) and rs2 (the ASID) exactly as the
  privileged spec defines. rs1 = x0 and rs2 = x0 flush everything; rs1 only
  flushes the entries covering that page in every ASID, global included;
  rs2 only flushes the entries of that ASID that are not global; both flush
  the non-global entries of that ASID covering that page. A superpage entry
  covers every page it maps.
- The operands travel with the SFENCE.VMA: dispatch tags the instruction with
  which registers are not x0, the MEM_RS holds it for rs1 and rs2 and hands
  both to the ROB when it issues, and the ROB serializer keeps the instruction
  at the head until they have arrived. The ROB exports the head's filter for
  the length of the SFENCE window.
- In the second-level TLB, a page flush (with or without an ASID) reads one
  set, an ASID flush without a page scans all 128 sets, and flush-all clears
  the valid bits in one cycle. The superpage
  side array applies the flush's filter to all its entries in the flush's
  first cycle; a page flush removes the superpage whose region holds the page.
  While a flush runs the arrays accept no request.

Svpbmt. The walker checks a leaf's PBMT field (PTE bits 62:61) against
`menvcfg.PBMTE`, sampled when the walk starts: with PBMTE clear any nonzero PBMT is a
page fault, and with it set PBMT 3 in a leaf and any nonzero PBMT in a non-leaf are
page faults, as are bit 63 (no Svnapot) and bits 60:54. An NC or IO leaf over
cached DDR answers the PPN of the uncached alias of DDR (riscv_pkg "Svpbmt":
bit 30 for DDR up to 1 GiB, bit c for a 2^c-byte window of c >= 32, which
leaves its top 2 GiB without an alias and makes an NC or IO leaf there an
access fault). A 2 GiB DDR window has no alias in the current 32-bit physical
map, so NC and IO leaves over DDR raise an access fault in that configuration,
including the VCU118's 2 GiB map. Page-permission faults take precedence over
this PMA refusal. Device mappings are unaffected. The alias
window is not in the PMA map (an untranslated
access or a PMA leaf there faults as before); an NC or IO leaf over it is a
device page in the DTLB's per-entry checks and the walk-response checks, so
the DMMU classifies the op MMIO, the load queue's PMA check accepts the window
for MMIO entries. NC/IO loads over the DDR alias or low BRAM issue at the
ROB head and bypass L0, L1D and store forwarding. The router selects
parking, committed-store draining and interrupt shielding by the physical
device quadrant, so these memory loads do not wait for committed stores to
drain. An interrupt or debug halt can flush an accepted load and cause it
to perform another read after resumption. All such targets are idempotent
memory. Alias stores retire after their bus response; NC/IO low-BRAM stores
are buffered and can retire before their response. Device registers retain
the full device mechanism regardless of PBMT. soc_top sends an
alias access as one single-beat transfer of the real DDR address through the
coherent DMA port, so the home probes the L1D and merges dirty data first:
the transfer observes the cacheable copy of the same frame. Switching
between cacheable and uncached views requires the Svpbmt sequence
`fence iorw, iorw; cbo.flush; fence iorw, iorw`, with the flush naming that
location. The
walk response carries the field (`ptw_resp_t.pbmt`); the second-level TLB
(4 KiB array and superpage array), the DTLB and the ITLB store it and return
it on a hit. Over low BRAM, which has no alias, the DTLB's per-entry checks
and the walk-response checks apply the field: the page is MMIO and refuses
AMOs. AMO, LR, SC, `cbo.zero` and vector loads and stores on an NC or IO page
are access faults, and so is an instruction fetch (PMA overrides the Svpbmt
chapter permits). The walk cache holds only pointers, whose PBMT field must be
zero.

On the X3, a misaligned NC/IO load or store to a DDR alias raises a load or
store access fault (cause 5 or 7); one to low BRAM or device registers raises
an address-misaligned exception (cause 4 or 6). The VCU118 has no hardware
misaligned-access engine:
misaligned loads and stores raise cause 4 or 6 before translation, including
NC/IO accesses, for firmware to handle. Aligned NC/IO DDR accesses on its
2 GiB map raise cause 5 or 7 because the map has no alias.

The walker keeps a walk cache of upper-level pointers: 16 level-1 pointers
(the level-0 table of a 2 MiB region) and 4 root pointers (the level-1 table
of a 1 GiB region). A walk looks both up in two registered cycles (tag
compare, then select) and starts
at level 0 or level 1 on a hit, so it makes one or two dependent line reads
instead of three. Only a valid non-leaf PTE that a walk descends through fills
it; an invalid or faulting PTE never does (Svvptc), and the walk invalidate
empties it. The cache is on the miss path only. The instruction MMU expires
its fault memo and completed registered refusals every 64 clocks, so wrong-path faults
cannot retain invalid PTEs indefinitely. Full flushes drop verdicts even
when a response arrives on the flush edge. A clean retarget captured exactly
as an old refusal expires retries one clock later; held clean translations
remain valid. A known first-word fault completes a crossing window
without waiting for a missing neighbor, so slow refused walks cannot
alternate indefinitely as negative-cache entries expire. A partial result is
not expired, preserving a first-page response that arrives on the expiry
edge beside a warm faulting neighbor. The [RTL overview](../../README.md) lists the supported
page sizes, and the [cache README](../../lib/cache/README.md) describes the
walker's port into the cache hierarchy.

## Misaligned accesses

`misaligned/ma_engine.sv` performs one misaligned plain load or store in
cacheable DDR as one or two 32-byte sector transactions. `cpu_ooo`
instantiates it when the `MISALIGNED_HW` parameter is set (default off; the
X3 build and the simulation default set it), which needs the cached tier;
elaboration rejects it without one.
Without the engine, every misaligned access raises the address-misaligned
exception.

With the engine, a plain load or store whose address-misaligned exception
reaches the ROB head is an assist. LR, SC and AMOs keep the exception, and
so does any access in Debug Mode, which parks as before. The
trap unit takes an assist like a memory replay, without CSR effects: it
flushes the pipeline, redirects fetch to the instruction after the access and
starts the engine with the head's address, size, sign, register numbers and
FP flag. While the engine runs, dispatch is held, so nothing younger enters
the ROB, and interrupts and halt requests wait behind the same shield as an
AMO. The engine reads a store's data through an extra read port on each
register file, translates through the page-table walker when translation is
on, and makes its sector requests on the hart's line client. A load's result
is written through commit port 0, one cycle after completion, and the access
counts as one retired instruction (`minstret` and a single step). Half- and
single-precision FP loads are NaN-boxed to 64 bits; FP stores transfer the
low bits for their access size. If a part faults, the engine's exception is taken as the instruction's own, with its
cause and trap value, and `mepc` or `sepc` holds the access's PC.

An access is split at the first sector boundary it crosses. `ma_pkg` checks
each part in architectural order: page fault, then access fault (a physical
address outside the map), then region. Only cached DDR is served; another
mapped region gives the address-misaligned exception. The lower part's
verdict is decided first. The trap value is the original virtual address,
except for a page or access fault of the upper part, which reports the upper
part's first byte (the page base when the access crosses a page). The engine
issues no memory request until both parts have passed, so a faulting store
writes nothing. It then issues the lower sector's request before the upper
one and waits for both responses. A load response error gives a load access
fault whose trap value is the first byte of the lowest failed part: the
original virtual address when the lower part failed, otherwise the upper
part's first byte. A store response error and a hart stop are terminal at
once, with no further request. A hart stop also makes an idle engine busy
until reset. The registered dispatch hold samples the stop on the same edge
as the engine, so neither dispatch slot allocates in that terminal state.
`lib/line_align.sv` moves the access between register order and the two
sectors.

## Debug Mode

FROST implements Debug Mode from the RISC-V Debug Specification 0.13.2. The
[RTL overview](../../README.md#debug) describes the debug module and its JTAG
transport. Inside the CPU the work is divided like this:

| Module | Debug Mode role |
|--------|-----------------|
| `csr/csr_file.sv` | Holds `dcsr`, `dpc`, `dscratch0`, `dscratch1`, and `ddata` (the debug module's data0/data1). On entry it saves `dpc` and `dcsr.cause`/`prv` and switches to M privilege; `dret` restores `dcsr.prv` and clears MPRV when returning below M |
| `control/trap_unit.sv` | Treats Debug Mode as a third trap target: halt requests and step completion (ahead of all interrupts), the debug module's `go` redirect, `ebreak` routing by `dcsr.ebreakm/s/u`, and re-parking without CSR side effects on any exception in Debug Mode. Masks M and S interrupts in Debug Mode and while a step is armed |
| ROB | Runs `dret` through the MRET path, and raises illegal-instruction for `dret` or a debug CSR outside Debug Mode |
| `cpu_ooo.sv` | The single-step engine, and the status the debug module reads (`o_debug_mode`, `o_dbg_parked`, `o_dbg_cmd_err`, a snoop of low-BRAM stores) |

A `dret` with `dcsr.step` set arms a single step. The first retirement after
that (a commit, an xRET, or a trap that does not enter Debug Mode) completes
the step, and the trap unit halts before the next instruction. While a step is
armed, commit is one-wide, and a `wfi` runs as a `nop`, so a step over the
instruction before a `wfi` halts at the `wfi`. Because trap entry presets the
interrupt resume PC to the trap target, a stepped instruction that traps halts
with `dpc` at the handler's first instruction, as the specification requires.

## AIA interrupt files

The machine and supervisor IMSIC files live beside the CSR file inside
`cpu_ooo`. Each has 63 identities and a registered MSI ingress. APLIC direct
lines pass through at reset. The CSR file implements Smaia and Ssaia,
including exact major-interrupt selection in `mtopi` and `stopi`, read-only
zero major priorities and `mvien`, and `mvip` aliases of software pending
bits. The Sscofpmf local counter-overflow interrupt (13) has the lowest
default priority in both; `mvip` bit 13 reads zero because `mvien` bit 13
does. Interrupt takes recheck the selected source's current pending bit,
local enable and delegation, so a `mip` or `sip` clear already in the CSR
commit path cancels a stale registered request. A registered post-CSR window
also refreshes interrupt cause and vector selection before a take, so a write
enabling a higher-priority source cannot enter under the old priority. The
window retains the interrupt's commit hold, including when committed stores
are already drained. It does not stall ordinary CSR retirement, exceptions,
debug entry or xRET. The ROB samples
indirect-access legality at allocation. Serialized
select writes prevent a younger access from using stale legality. The files
report `*topei` and their lines from their registers a cycle late. CSR commits
never come in consecutive cycles, which a simulation assertion checks, so
every CSR access sees the effect of the one before it.
See the [CPU interface](../../cpu_top/README.md#interrupt-and-debug-controls).

## CSR writes

CSR instructions execute one at a time at commit, sequenced by the ROB
serializer (see the [ROB README](tomasulo/reorder_buffer/README.md)). A CSR
commit never coincides with a trap or xRET, and `cpu_ooo` sets `csr_file`'s
`COMMIT_EXCLUDES_CONTROL_TAKE` so the CSR file can rely on that and drop take
priority from its write paths; simulation assertions in both modules check the
rule. Trap entry updates the CSRs through one-hot enables from `trap_unit` (an
M-side save, an S-side save, or Debug Mode entry), which it builds beside the
take decision rather than from it.

Fetch translation is registered from the next `satp` mode and privilege,
so it changes on the same edge as a CSR write, trap or return. In the integrated
profile, the CSR file prepares that complete flag for MRET, SRET and neither
return, then selects with the return inputs while preserving write, debug
and trap priority.

A CSR instruction that accesses `satp`, or writes `mstatus` or `sstatus`, can
change address translation or `mstatus.FS`, which ID's decode reads, so
everything after it must be refetched under the new state. The ROB serializer
waits for committed stores to drain and then retires the CSR. The write lands
in `csr_file` the next cycle, from the registered commit bus, and a full
pipeline flush follows one cycle after that. It is the same FENCE-class flush
that FENCE.I uses, so it also drops the fetch provider's buffered lines. Across those two cycles `cpu_ooo` blocks trap,
Debug Mode, and xRET takes and ignores exceptions, so no younger instruction
can overwrite the CSR write or act on the old translation. Separately,
`csr_file` raises a one-cycle translation-changed pulse (it drops the MMUs'
registered results and discards the walker's walk) for every `satp` access, and
for an `mstatus` write only when MPRV changes (or MPP while MPRV is set). A
second pulse asks the TLBs to drop every entry when the `satp` root changes
under the same ASID, or MPRV changes. SUM and MXR changes keep the TLBs: entries hold the raw leaf
permissions, and every lookup applies the live SUM, MXR and effective
privilege, so the full flush alone retires the old permission state. Linux
toggles SUM around every user copy, so this keeps both TLBs warm across
syscalls.

## Vector state

With `VECTOR=1`, `csr_file` holds the vector state: `mstatus.VS` (bits 10:9,
with its `sstatus` view), `vstart`, `vxsat`, `vxrm`, `vcsr`, and the read-only
`vl`, `vtype` and `vlenb`. VS resets to Off and has the four FS states. While it
is Off, the ROB marks every vector CSR access illegal at allocation; writing
`mstatus` or `sstatus` is followed by the full flush described above, so no
younger instruction keeps a legality decision made under the old VS. A write
to `vstart`, `vxsat`, `vxrm` or `vcsr` sets VS to Dirty, and SD is set while
FS or VS is Dirty. A read that does not write, such as `csrr`, leaves VS
unchanged. `vstart` keeps log2(`VLEN`) bits, `vlenb` reads `VLEN/8`, `vl` resets
to 0 and `vtype` to vill.

`vsetvli`, `vsetivli` and `vsetvl` are the vector instructions implemented so
far; every other vector encoding raises illegal-instruction, and while VS is
Off (always, with `VECTOR=0`) ID decodes all of them as illegal, as it does F
and D instructions with FS Off. They dispatch in slot 1 only and go to MUL_RS,
which issues them through its divide gate to the vector-config unit
(`vector/vec_cfg_unit.sv`) in the muldiv shim. The unit computes the new
`vtype` (vill for a reserved or unsupported setting), VLMAX and `vl`
(`min(AVL, VLMAX)`, or VLMAX when rs1 is x0), and returns `vl` to rd on CDB
slot 5. The wrapper keeps the result per ROB tag; when the instruction retires
(never beside a second instruction), the CSR file installs `vtype` and `vl`,
clears `vstart` and sets VS to Dirty. With rs1 = rd = x0 it keeps
`min(vl, VLMAX)` under the new `vtype`, as the specification requires.

The vector integer instructions listed for `vec_engine` below also execute.
ID decodes them as `VARITH` (or `VARITH_X` with a scalar operand), which
dispatch sends to INT_RS only to hand the scalar operand to the ROB; legality
that depends on `vtype` (vill, register-group alignment, mask-destination
overlap, a masked write of v0) is decided at allocation from the `vtype` in
effect at that point, which a tracker beside the rename checkpoints keeps
(vector arithmetic waits at dispatch while a register-form `vsetvl` leaves it
unknown). Masked operations reject v0 as a SEW data source because the
implicit mask has element width 1. A configuration allocation restarts the
three-cycle wait for an empty configuration pipeline before the registered
ROB in-flight indication arrives. The tracker reloads the architectural
`vtype` only after that wait, allowing its retiring CSR update to arrive.
The register-number rules depend on `vtype` only through LMUL, so
`vector/vec_lmul_legality.sv` evaluates them from the instruction bits for
each LMUL class (1 or fractional, 2, 4, 8) before the decoded queue, which
carries the four results beside slot 1; dispatch selects the class of the
tracked `vtype` and adds vill. When one retires, `vec_unit` queues it with
its scalar and the architectural `vl`, `vtype` and `vstart`, and the engine
executes it after commit; the CSR file clears `vstart` and sets VS Dirty.
`vmv.x.s`, `vcpop.m`
and `vfirst.m` execute at the ROB head once the unit is idle and return their
result on CDB slot 6.

ID decodes the unit-stride (one field), whole-register and mask loads and
stores as `VLOAD` and `VSTORE` (illegal with VS Off); they dispatch in slot 1
only with `RS_NONE` and take an entry in the vector memory table
(`vector/vec_vmt.sv`), holding the next one while all four entries are live.
The table lists the vector memory instructions in flight in program order for
the load and store queues' range holds (including 64-byte block holds on
Zicbom entries), marks an entry retired on the edge the ROB head passes it, and
frees entries that a flush removes. Its registered "no live retired entry"
output holds the serializer's FENCE, FENCE.I and SFENCE.VMA drain, the
store-conditional unit's firing and arming, the misaligned-access engine before
its first access, and interrupt and debug-halt takes (`sq_committed_empty_for_trap`).
When one reaches the ROB head and older committed vector work has drained,
`vector/vec_head_mmu.sv` reads `rs1` through the integer register file's extra
read port and checks `vtype` and register-group legality (`vill` except on
whole-register forms, EMUL in `[1/8, 8]`, group alignment, and masked loads to
`v0`), computes the active byte span from `vl`, `vstart` and `v0`, translates
the one or two touched pages on the DMMU's walk-request port (requiring cached
DDR with `PBMT = PMA`), waits for older committed scalar stores (`o_sq_committed_empty`), records
the physical page segments in `vec_vmt`, and completes on CDB slot 6 to retire
alone in slot 1 (`vstart` cleared; VS set Dirty on loads and when `vstart` was
nonzero). Faults are reported precisely at the head (`xtval` holds the first
active byte's virtual address in the faulting page, or the second page's base
when a single element straddles into a faulting second page); if earlier whole
elements lie on a valid first page before a faulting second page, `vec_vmu`
executes those first-page elements before a synchronous machine or supervisor
trap records the first unexecuted element in `vstart`. A partial-load fault in
Debug Mode re-parks without that CSR update and can leave VS Clean after
writing vector registers. After retirement, `vector/vec_vmu.sv` splits the
access into 32-byte sectors across six line-client identities (IDs 2..7) to the
coherence home, freeing the `vec_vmt` entry once all sector responses and VRF
writes finish. A failed sector response after retirement, or during a partial
first-page run ahead of a second-page fault, suppresses any VRF write and
raises a sticky hart fatal error alongside `o_cache_fatal`. The other vector
instructions, and the strided, indexed, segment and fault-only-first loads and
stores, are illegal.

`misa.V` stays clear: `VECTOR_ADVERTISE=1`, which would set it, is rejected at
elaboration while the vector instructions are not implemented, and bare-metal
software enables the state by writing `mstatus.VS`. With `VECTOR=0` the vector CSRs do
not exist and VS reads zero.

The vector unit's datapath blocks live in `vector/` and have unit benches.
`vec_engine` connects `vec_vrf` and `vec_int_lane` to the core.
`vec_int_lane` is one 64-bit integer lane: add, subtract and
reverse subtract, the logical operations and `vandn`, signed and unsigned
minimum and maximum, shifts and rotates, merge and move, the Zvbb bit and byte
reversals and counts, and the eight compares, at SEW 8, 16, 32 or 64. Its
result appears a fixed two cycles after the cycle that takes its input, for
every operation and operand, as Zvkt requires. A 72-bit adder with a
separator bit after each byte serves every element width: a separator inside
an element propagates the carry, one at an element boundary stops it and
yields the element's carry out, which the compares and minimum and maximum
use. Compares write one bit per element to `o_mask`.
`vec_mul_lane` forms each element's full product with the signedness the
operation selects and returns the low or high half, or an accumulate; its full
products feed the widening multiplies. `vec_mask_unit` runs the mask-register
logical operations, `vcpop.m`, `vfirst.m`, `vmsbf.m`, `vmsif.m`, `vmsof.m`,
`viota.m` and `vid.v` as a series of one-cycle steps, 64 mask bits or one
64-bit word of elements each, keeping the running count, the first-bit flag and
the element index from one step of an instruction to the next.
`vec_red_unit` runs the integer reductions and the widening sums the same way,
one 64-bit word of elements per step: inactive elements count as the
operation's identity, elements are extended to 64 bits so one operation
serves every element width, and a three-level tree reduces each word before it
meets the running value.
`vec_xbar` moves bytes within one element group: a crossbar whose output byte
takes any input byte or zero, for the gathers, slides and compress that the
sequencer turns into byte indices, and a rotator for slides by whole bytes and
the alignment of unit-stride data to and from memory.
`vec_clmul_lane` is one 64-bit carry-less multiply lane for `vclmul` and
`vclmulh`. `vec_ghash_group` builds `vghsh.vv` and `vgmul.vv` from four of these
lanes: they form the partial products of the 128-bit operands, and one cycle
folds the 256-bit product back modulo the GCM polynomial.
`vec_aes_group` runs the Zvkned operations on one 128-bit element group: the
encryption and decryption rounds, round zero, and both key-schedule steps,
with S-box lookups, ShiftRows and the round key, and MixColumns or
InvMixColumns in three fixed cycles, so the timing does not depend on the data.
`vec_sha2_group` runs `vsha2ms`, `vsha2cl` and `vsha2ch` on one element group of
four 32-bit (SHA-256) or 64-bit (SHA-512) words: each round's sums use
carry-save adders and one carry adder, and the two rounds, like the message
schedule's two dependent word pairs, take four fixed cycles.
`vec_vrf` is the vector register file: its depth, width and numbers of read and
write ports are parameters, so it serves an architectural file or a larger
physical one. Every write port has its own storage copy for every read port,
and a live-value table records per byte which port wrote it last; reads are
registered and see the file before that edge's writes, and when two ports write
one byte together the higher-numbered port wins.

`vec_fma` is the vector unit's fused multiply-add for one IEEE 754 format,
chosen by its exponent and fraction widths (FP16, FP32 or FP64). It computes
multiply-add, multiply and add with a single rounding in any of the five
rounding modes and returns the fflags bits, with canonical NaNs and tininess
detected after rounding; the sequencer forms the vector forms by choosing
operands and signs. Its fixed latency is fourteen cycles. The unit bench checks
it bit for bit against Berkeley SoftFloat.

`vec_fp_misc` holds the same format's non-arithmetic operations: the
comparisons behind `vmfeq`, `vmflt` and `vmfle` (with `vmfne`, `vmfgt` and
`vmfge` formed by inverting or swapping), `vfmin` and `vfmax`, the three sign
injections and `vfclass`, with the fflags each raises. Its latency is one
cycle.

The conversions are three blocks, each parameterized by its source and
destination widths so one source serves every same-width, widening and
narrowing form: `vec_f2i` converts a format to signed or unsigned integers of
a given width with the RISC-V saturating results, `vec_i2f` converts integers
to a format, and `vec_f2f` converts between two formats, exactly when
widening and with rounding (including round to odd for `vfncvt.rod.f.f`) when
narrowing. Their latencies are five, seven and eight cycles.

`vec_fdivsqrt` is one iterative unit per format shared by `vfdiv`, `vfrdiv`
and `vfsqrt`: after normalizing subnormal operands it runs a restoring digit
recurrence through one subtractor, one result bit per cycle, and rounds like
the other blocks. It takes one operation at a time, signals when it is free,
and returns each result a fixed P + 10 cycles later (P is the format's
precision: 21, 34 and 63 cycles for FP16, FP32 and FP64).

`vec_engine` puts the register file and the integer lanes together and
executes committed vector instructions one at a time, register group by
register group, with no overlap between instructions yet: the single-width
integer arithmetic, logical, minimum and maximum, shift and Zvbb operations,
the integer compares into a mask register, `vmerge` and `vmv.v.*`. Only active
body elements are written (the register file's byte enables), so tail and
inactive elements stay undisturbed. A read port and a byte-enabled write port
serve the memory side.

## Subtle cases

These front-end hazards are easy to reintroduce. The code comments at each
site have the details.

### Pending-prediction handoff

A slot-1 prediction is made at the fetch PC, before `pc_reg` reaches the
branch. When the branch sits in the upper half of a word, the target is a
halfword address, or `pc_reg` would otherwise step past the branch, the
prediction must wait for that exact packet through stalls, bubbles, and slow
windows, or it attaches to a neighbor. `pc_controller` holds a one-deep
pending {branch PC, target} pair and `prediction_metadata_tracker` holds the
metadata. Only the packet at the saved PC consumes them; it is emitted
one-wide, and its bimodal index is recomputed from that PC. A prediction made
while the branch's own packet is already being emitted, which happens when
variable latency closes the gap between the two PCs, never pends.

`pc_controller` registers how `pc_reg` relates to the saved PC one edge early,
which keeps the wide compares out of the PC loop. For a slot-2 redirect,
`branch_prediction_controller` relates the live BTB target and stack top.
`branch_predictor` relates each raw or forwarded staged payload, then applies
coverage to the candidate relations. The controller selects the position and
applies the RAS relation in one final gate when the entry is a return and the
stack is nonempty.

The controller supplies staged and live slot-2 target cofactors, with the
live cofactor including the slot-1 alias check. Staged taken bits and the live
fallback join parallel candidate qualifiers before common prediction permission.
Separate sums for each slot-2 position let the live cofactor select the decoded
+4 position with permission and ownership. IF passes full live validity and
saved replay separately; pc_reg applies validity in the final data select.
The shifted BTB payloads retain their one-gate row/forwarding selection for
target data. Pending-PC relations use parallel raw-payload comparisons and
select the relation after those same masks arrive.

The prediction-metadata valid flag precomputes hold/load and the PD redirect's
non-target permission. In the Xilinx implementation, the wide PD target match,
flush and slot-2 suppression meet in one final LUT6. Same-target stalled PD
redirects retain metadata under the same taken/valid conditions as before.

### Stalled slot-2 predictions

A validated staged slot-2 candidate is captured with its packet on the first
stall edge, including its target, call/return type, and pending-PC relations.
The BTB may read other rows during the stall. Releasing the saved packet uses
the captured candidate once, redirects fetch, and marks that packet predicted
taken. A held packet makes no RAS operation. Reset, flush, PD redirect,
execute recovery, trap, xRET, and FENCE-class redirects cancel the candidate;
prediction disable blocks its consumption.

### Served-window check and retries

A provider can present a stale window, or one a word behind `pc_reg`.
`served_window_coverage.sv` compares `pc_reg` with the word addresses each
provider registers beside its payload. A window missing any byte of the packet
becomes a NOP bubble, makes no prediction, and resteers fetch to `pc_reg`'s
word. When `pc_reg` is in the upper half of that word, the retry's BTB lookup
names the parcel before it, which is off the program path, so `pc_controller`
flags the lookup, `branch_prediction_controller` ignores that BTB entry, and
IF gives the packet a not-taken direction with its own bimodal index. With
the fixed-latency test provider no program reaches the resteer; the
`served_window_resteer_fetch_fuzz` test reaches it under the fetch-latency
fuzz.

### Aliased BTB lookups

When the fetch PC equals the slot-2 position (`pc_reg` + 2 or + 4), for
example on the first window after a fetch gap, the slot-1 and slot-2 lookups
name the same instruction, and one branch could get two predictions.
`branch_prediction_controller` gives the alias to slot 2 only, so a typed
entry's push or pop also happens once, with the packet that carries the
prediction.

### Return address stack recovery

The stack moves only when PD takes a packet whose used prediction came from a
typed BTB entry, or when PD redirects a call or return for the backing BTB: a
packet squashed in IF, dropped by a flush or a PD redirect, or held by a
stall never pushes or pops, and a stall replay pushes or pops once. At most
one packet of a bundle can, because an instruction predicted taken ends the
bundle. The recovery point that packet and its bundle partner carry is the
stack state before their own operation: the top-of-stack pointer, the valid
count, and the top entry. Restoring it keeps every older call pushed and
every older return popped, and recovery then replays the mispredicted
instruction's own push or pop. IF registers each operation, so the stack
sees it the cycle after PD takes the packet and stores it on that cycle's
edge; meanwhile the stack's outputs apply it to the stored state, so lookups
and recovery points from that cycle on include it. A backing BTB redirect's
operation takes the same registers in the redirect's first cycle, in which
IF accepts no packet, so the stack sees it one cycle later than a typed
BTB prediction's; the packets in IF and PD in the meantime are wrong-path
ones that the redirect drops. The operation happens once even when a stall
holds the redirect, and a flush in that first cycle drops it; a later flush
that squashes the instruction leaves its recovery restore to undo it.

The restore also writes the recovery point's top entry back. A wrong path
that pops and then pushes overwrites that entry: a mispredicted branch just
before a return, whose wrong path returns and runs into the caller's next
call, would otherwise leave the correct path's return predicting that call's
link address. An entry below the top that a deeper wrong path overwrites (two
pops, then a push) stays damaged. A restore that replays a call writes two
neighboring entries on one edge, the restored top and the pushed link address
above it, so the entries alternate between two distributed-RAM banks by
pointer parity.

A typed lookup reads the top of the stack before any operation in the same
cycle. That is safe because no younger lookup's prediction survives a cycle
in which PD takes a typed packet: registered slot-1 metadata implies the
prediction holdoff, a pending-prediction handoff blocks prediction, a stall
replay blocks live lookup predictions, a slot-2 prediction kills the
same-cycle slot-1 prediction, and a collapsed-lead packet carries its own
lookup. if_stage asserts this, and branch_prediction_controller asserts that
no operation is pending in a restore cycle, which would replace it, or in the
cycle after: IF accepts no packet in the flush or the redirect bubble.

### BTB training order

BTB writes come from early recovery, commit-time recovery, and correct-branch
commits, and each is a read-modify-write of a 2-bit counter.
`ex_comb_synthesizer` picks one per cycle in that priority and
`branch_prediction_controller` registers it, so training lands one cycle late
but in order, and back-to-back updates to one entry see each other. A slot-1
correct-branch update that loses its cycle is dropped, and a waiting slot-2
update is replaced by a newer one; both cost accuracy only. The backing BTB
registers the selected update when it trains a JAL or JALR, and otherwise a
refresh, reads its set, finds its way, and writes the set two cycles after
the BTB writes; a refresh that misses writes nothing. A request that reads
the set being written takes the written set, and one to the same set as an
update in the stage ahead of it is dropped, which costs accuracy only.

### 4 GiB target limit

The BTB stores the low 32 bits of each target and takes the upper bits from
the branch's own PC, so a stored target is usable only if the branch and its
target share a 4 GiB region. Training with a target in another region
invalidates the entry, so the BTB never supplies a wrong target: a taken
crossing conditional branch can still be predicted by the PD redirect, and a
crossing JAL mispredicts. A return that hits a valid entry predicts from the
return address stack while the stack holds an entry, and the stack holds
full-width addresses, so a crossing return can still be predicted.
Conditional branches (offsets up to ±4 KiB) and JALs (up to ±1 MiB) cross a
boundary only near one.

## Verification

The [simulation cover points](../../../../tests/README.md#cover-points)
of the page-table walker count a walk discarded on the edge that accepts
or answers its PTE read, and a bus error on an interior PTE read. Those of
the data MMU count a matching walker response that arrives with a TLB hit
or on a recovery flush, and a walker fault that arrives while the live
operation holds a different VPN. Those of the trap unit count an interrupt
that takes priority over a memory-order replay, and WFI woken by a raw
pending source with no interrupt latched.

`ptw_bus_fault_test` makes PTE reads fail at both interior levels and
checks the load and store access faults that result, their trap values
and PCs, and that access succeeds once the mapping is repaired. Two loads
of adjacent L1D sectors then share one failed L2 fill, and the test checks
the older load's access fault and its address in `mtval`. `sstvala_fault_test`
checks the address of every bus-response access fault software can provoke
in simulation, in each privilege mode, delegated and not, bare and through
Sv39. Its registry entry injects the bus errors in
the simulated DDR model.

`ptw_recovery_test` sweeps the cycle in which a branch resolves while a
load on its predicted path walks the page table for an unmapped page. Each
case first runs the branch not taken with a mapped load, to train the
predictor, and then taken; the taken target loads from a mapped page, with
or without an SFENCE.VMA first. The test checks the loaded data and that no
wrong-path page fault reaches the trap handler.

`timer_replay_test` sweeps a timer deadline across a coherent DMA write
that invalidates a speculative load, so that some deadlines bring the
interrupt to the ROB head with the load's memory-order replay. Older
divides hold retirement, and committed stores delay the replay at the ROB
head. The test checks one interrupt per transfer, its cause and saved
privilege mode, the stored data, and the DMA result.

The unit benches check the outcome of each of these cases at the module's
interface. The programs reach them in the whole SoC and check the architectural results,
and the [coverage report](../../../../tests/README.md#coverage) shows
whether they still reach them.

Most front-end modules and `cpu_ooo` glue submodules have their own cocotb
bench, such as `branch_predictor`, `pc_controller`, `instruction_aligner`,
`fetch_provider`, `immu`, and `decoded_bundle_queue`. Whole-program tests run
the integrated core; the `*_fetch_fuzz` variants, such as
`branch_pred_test_fetch_fuzz`, add random fetch gaps with `FETCH_VALID_FUZZ=1`.
The `if_stage` tests also cover a PD redirect arriving during a fetch gap
after a BTB prediction: the redirect bubble must survive the gap and stalls,
and the first target bundle must be emitted exactly once.
Formal targets cover the PC muxes and holdoffs, the pending-prediction
handoff, predictor aliasing, RV64C predecode (`rvc_predecode` checks every
16-bit parcel against the reference decompressor), the TLBs and walker, and the
CSR file and trap unit.

See the [test runner](../../../../tests/README.md) for commands and the
[formal guide](../../../../formal/README.md) for proof scope and assumptions.
