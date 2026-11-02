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
| `mmu/` | Instruction MMU (8-entry ITLB), data MMU (16-entry DTLB), shared page-table walker |
| `csr/` | CSR file; CSR instructions execute at commit |
| `control/trap_unit.sv` | Traps, delegation, interrupts, Debug Mode entry |
| `ex_stage/` | ALU, multiplier and divider, FPU, branch unit |
| `wb_stage/` | Register file module used for the INT and FP files |
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
| `ooo_register_files` | `register_files/` | INT and FP architectural register files, two write ports each for two-wide commit, and a bypass that forwards a same-cycle commit to dispatch |
| `commit_actions` | `commit/` | Register writes at commit, the delayed CSR writeback, the retire valid, and the instret increment |
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
  read that has already started, the quiet window around
  [translation-changing CSR writes](#csr-writes), and the interrupt resume PC
  (the PC an interrupt saves, which trap entry and xRET preset to their target
  because an interrupt can arrive before the first instruction there retires);
- the page-table walker's request mux, where the data side wins;
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

`pc_controller` picks the next fetch PC in this priority: reset, trap or xRET,
FENCE-class flush (FENCE.I, SFENCE.VMA, or a
[translation-changing CSR write](#csr-writes)), misprediction recovery, PD
redirect, served-window resteer, hold while no window arrives, slot-2
prediction, slot-1 prediction, the pending-prediction and halfword catch-up
cases, then the sequential PC.

### Branch prediction

| Structure | Size | Predicts | Trained by |
|-----------|------|----------|------------|
| BTB | 256 entries, direct-mapped, 2-bit counters | Target and direction of conditional branches, JALs and JALRs; an entry is typed as a call, a return, or both | Mispredicted conditional branches, JALs and JALRs; correctly predicted conditional branches at commit |
| Return address stack | 8 entries | The target of a BTB hit typed as a return (`jalr x0, 0(ra)`, `c.jr ra`) or a coroutine swap (`jalr t0, 0(ra)`) | IF, when it hands PD a packet predicted from a typed entry: a call (JAL or JALR writing `ra` or `t0`) pushes, a return pops, a swap replaces the top; recovery restores it |
| Bimodal direction predictor | 1024 2-bit counters | Direction of slot-1 conditional branches without a taken BTB prediction or a tagged match | Each conditional branch at commit |
| Tagged direction predictor | Two tables of 1024 entries, hashed with 16 and 64 bits of path history; 9-bit tags, 3-bit counters | Direction of slot-1 conditional branches whose lookup matches a tag, either way | Each conditional branch at commit, at the entries its lookup read |

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
Slot 2 has three BTB copies of its own, keyed by the PC of the instruction
before it (+2 and +4, plus a copy rotated by one index for a slot 2 in the
next word). They are read a cycle ahead, so the lookup adds no fetch cycle,
but a taken slot-2 prediction costs one bubble because fetch has already
requested the next sequential window. At a halfword PC, a slot-2 hit predicts
only if the entry was trained for an instruction of the same size. A JAL that
misses the BTB mispredicts once; training at commit makes its next execution
hit.

PD can change the direction fetch followed for a slot-1 conditional branch.
IF reads two direction predictors at the fetch PC and passes their
directions along with the branch. A tagged direction, when the branch's lookup
matches a tag, is used either way; otherwise the bimodal direction can only
turn a branch without a taken BTB prediction (a miss, or a hit predicted
not-taken) to taken. When that direction differs from fetch's, PD redirects
fetch to PC + offset, or for not-taken to the next instruction, at a cost of
two bubbles, and ID gives the branch the new prediction so the branch unit
checks the path fetch now follows. Commit trains the bimodal entry at the
carried index, not at the branch's own PC, because the fetch PC that read the
predictor can differ from the branch PC after a stall replay or at a halfword
boundary. A slot-2 branch's training waits, one deep, for a cycle in which
slot 1 does not train; a newer one replaces it.

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
branches are trained, though PD overrides only slot 1.

### Two-wide fetch and dispatch

IF pairs two instructions only when all of these hold:

- Slot 1 is not control flow (a branch, JAL, JALR, or a compressed form of
  one) and not a native SYSTEM, MISC-MEM, or AMO instruction (CSR accesses,
  ECALL, EBREAK, xRET, WFI, SFENCE.VMA, FENCE, FENCE.I, and atomics including
  LR/SC).
- Slot 2 is not a native SYSTEM, MISC-MEM, AMO, or FP-compute (OP-FP or fused
  multiply-add) instruction. It may be a branch or jump, but only the slot-2
  BTB lookup can predict it; the PD redirect covers slot 1 only.
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
SYSTEM, MISC-MEM, and AMO instructions, and that class never leads a pair.
These instructions also retire alone at the ROB head, which keeps them out of
slot 2. FP-compute instructions stay out of slot 2 to keep FP
reservation-station back-pressure off the slot-1 dispatch path; the next
bundle takes them as slot 1.

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

## Address translation

`if_stage` uses `mmu/immu` to translate the fetch PC into the physical
addresses of the window's two words, with a fault flag for each word. In Bare
mode and in M-mode, translation is a combinational pass-through with no
bubble. Under Sv39 a result is visible only for the exact {virtual PC,
privilege} it was computed for, so each fetch-PC change costs one bubble, a
4 KiB page crossing can cost a second, and an ITLB miss stalls IF until the
walk returns.

The 8-entry ITLB and the data side's 16-entry DTLB share one read-only
page-table walker in `cpu_ooo`; the data side wins when both ask. The walker
never writes PTEs (Svade): a leaf with A=0, or a store to a leaf with D=0,
raises a page fault for software to handle. SFENCE.VMA, `satp` accesses, and
`mstatus`/`sstatus` writes that change translation flush both TLBs and discard
any walk in flight. The [RTL overview](../../README.md) lists the supported
page sizes, and the [cache README](../../lib/cache/README.md) describes the
walker's port into the cache hierarchy.

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
bits. The ROB samples indirect-access legality at allocation. Serialized
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

A CSR instruction that accesses `satp`, or writes `mstatus` or `sstatus`, can
change address translation or `mstatus.FS`, which ID's decode reads, so
everything after it must be refetched under the new state. The ROB serializer
waits for committed stores to drain and then retires the CSR. The write lands
in `csr_file` the next cycle, from the registered commit bus, and a full
pipeline flush follows one cycle after that. It is the same FENCE-class flush
that FENCE.I uses, so it also drops the fetch provider's buffered lines. Across those two cycles `cpu_ooo` blocks trap,
Debug Mode, and xRET takes and ignores exceptions, so no younger instruction
can overwrite the CSR write or act on the old translation. Separately,
`csr_file` raises a one-cycle TLB and walker invalidate for every `satp`
access, and for an `mstatus` or `sstatus` write only when SUM, MXR, or MPRV
changes (or MPP while MPRV is set).

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
`branch_prediction_controller` relates the stack top and each BTB candidate
target to the saved PC before its late selects pick the target.

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
typed BTB entry: a packet squashed in IF, dropped by a flush or a PD redirect,
or held by a stall never pushes or pops, and a stall replay pushes or pops
once. At most one packet of a bundle can, because an instruction predicted
taken ends the bundle. The recovery point that packet and its bundle partner
carry is the stack state before their own operation: the top-of-stack
pointer, the valid count, and the top entry. Restoring it keeps every older
call pushed and every older return popped, and recovery then replays the
mispredicted instruction's own push or pop. IF registers each operation, so
the stack sees it the cycle after PD takes the packet and stores it on that
cycle's edge; meanwhile the stack's outputs apply it to the stored state, so
lookups and recovery points from that cycle on include it.

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
replay comes with the registered stall, a slot-2 prediction kills the
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
update is replaced by a newer one; both cost accuracy only.

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
the older load's access fault. Its registry entry injects the bus errors in
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
