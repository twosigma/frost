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
| `pd_stage/` | Slot-1 compressed-instruction expansion, early source fields, the PD branch redirect |
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
`tomasulo_wrapper` (the back end), `csr_file`, `trap_unit`, the page-table
walker (`mmu/ptw`), and these glue submodules from [`cpu_ooo/`](cpu_ooo/):

| Submodule | Directory | Role |
|-----------|-----------|------|
| `ooo_pipeline_control` | `pipeline_control/` | Front-end stalls, CSR and control-flow serialization, in-flight counters, post-flush holdoff, the registered trap and xRET redirect, prediction disable |
| `frontend_validity_tracker` | `frontend_control/` | Marks which IF/PD/ID packets are real instructions and classifies unpredicted control flow ([README](cpu_ooo/frontend_control/README.md)) |
| `decoded_bundle_queue` | `frontend_control/` | Queue of decoded two-instruction bundles between ID and dispatch, four deep by default ([README](cpu_ooo/frontend_control/README.md)) |
| `ooo_register_files` | `register_files/` | INT and FP architectural register files, two write ports each for two-wide commit, and a bypass that forwards a same-cycle commit to ID and dispatch |
| `commit_actions` | `commit/` | Register writes at commit, the delayed CSR writeback, the retire valid, and the instret increment |
| `branch_resolution` | `branch_recovery/` | Resolves conditional branches and JALRs from INT_RS with `branch_jump_unit` and reports them to the ROB, ignoring a branch whose checkpoint was reused. A JAL resolves when the ROB allocates it |
| `early_misprediction_recovery` | `branch_recovery/` | For a mispredicted conditional branch that holds a checkpoint, redirects fetch and restores the RAT the cycle after it resolves, instead of at commit |
| `misprediction_flush_controller` | `branch_recovery/` | Commit-time mispredictions, full and partial flush priority, checkpoint restore and free |
| `ex_comb_synthesizer` | `recovery/` | Builds IF's redirect, BTB-update, and RAS-restore bus from early recovery, commit-time recovery, and correct-branch commits, in that priority |
| `data_mem_request_router` | `memory_if/` | Data-port arbitration (SQ writes, then AMO writes, then LQ reads), staged device reads, tagged completion for the cached tier; see the [data-tier bus rules](../../README.md#data-tier-bus-contract) |
| `cached_tier_adapter` | `memory_if/` | Converts 64-bit data beats to 32-byte cache lines; instantiated in `cpu_and_mem.sv` next to the cache hierarchy |
| `perf_counter_aggregator` | `perf/` | Top-level and cache profiling counters and the counter read mux, present only with `PERF_COUNTERS=1` ([counter reference](cpu_ooo/perf/README.md)) |

The capture structs that the recovery submodules share
(`mispredict_commit_capture_t`, `correct_branch_commit_capture_t`) live in
`riscv_pkg`, because Yosys cannot resolve a cross-package type reference
inside another package's typedef.

`cpu_ooo.sv` itself keeps the logic that ties these blocks together:

- the decoded-queue hookup, including the register copy of the head bundle's
  control fields that dispatch reads;
- a per-ROB-entry table of each branch's predict-time bimodal index, and
  bimodal training at commit;
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
in the same cycle. IF expands a compressed slot-2 instruction itself; PD
expands slot 1 and extracts source registers early; ID decodes both slots.
Decoded bundles wait in the
[decoded bundle queue](cpu_ooo/frontend_control/README.md) until dispatch
renames them.

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
| BTB | 256 entries, direct-mapped, 2-bit counters | Target and direction of conditional branches and JALs | Mispredicted conditional branches and JALs; correctly predicted conditional branches at commit |
| Return address stack | 8 entries | Returns (`jalr x0, 0(ra)` and `c.jr ra`) and the coroutine swap `jalr t0, 0(ra)` | IF: calls (JAL or JALR writing `ra` or `t0`) push, returns pop, a coroutine swap pops then pushes; recovery restores it |
| Bimodal direction predictor | 1024 2-bit counters | Direction of conditional branches that miss the BTB | Each conditional branch at commit |

JALR never enters the BTB. A JALR that the return address stack does not
predict goes unpredicted and recovers at commit if it mispredicts. While an
unpredicted JALR sits in IF, PD, ID, or the decoded queue and an older branch
is unresolved, `ooo_pipeline_control` stalls the front end.

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

A conditional branch that misses the BTB can still be predicted taken. IF
reads the bimodal predictor at the fetch PC and passes the direction, and the
index it read, along with the branch. If PD finds a slot-1 conditional branch
that nothing has redirected yet and the direction is taken, it computes PC +
offset and redirects fetch, at a cost of two bubbles. Commit trains the entry
at the carried index, not at the branch's own PC, because the fetch PC that
read the predictor can differ from the branch PC after a stall replay or at a
halfword boundary. A slot-2 branch's training waits, one deep, for a cycle in
which slot 1 does not train; a newer one replaces it.

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

`cpu_and_mem` feeds IF from one of two providers, chosen by bit 31 of the
window's physical address:

| Provider | Serves | Latency |
|----------|--------|---------|
| Low BRAM (`imem_predecode.sv` through `low_bram_fetch_presenter.sv`) | The 256 KiB low BRAM at address 0 | Without stalls, one cycle for a window entirely inside `[0, 64 KiB)` and two cycles for any other window |
| `fetch_provider.sv` | Cached DDR from `0x8000_0000` | Variable. Two line buffers over the L1I, filled in parallel with next-line prefetch, plus a six-line victim store that returns an evicted line in one cycle instead of an L1I round trip, so short loops re-enter without L1I accesses |

Only the first 64 KiB of low BRAM keeps a LUTRAM copy of the predecode bits
that feed the next-PC logic; elsewhere those bits are recomputed from the
fetched words, which takes the second cycle.

IF tolerates any provider latency. When no valid window arrives, IF emits NOP
bubbles and freezes its PC and per-packet state while the provider keeps
working on the owed request. Redirects retarget the provider, except a slot-1
prediction made before the branch itself reached IF: that branch's window is
still owed and must arrive first.

Every 32-bit word carries 78 bits of predecode metadata: 12 fetch-control
bits (instruction size, pairing, and slot-2 eligibility) and, for each
halfword, the full RV64C expansion with its illegal flag. The expansion's
source-register fields are stored separately so register lookups can start
early. Low-BRAM initialization, debugger and loader writes, and L1I fills all
compute the metadata with `riscv_pkg::imem_make_sideband`, and
`sw/common/generate_imem_predecode_init.py` mirrors it for Vivado init files.

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
armed, commit is one-wide and the front end keeps all-NOP bundles, which FROST
otherwise drops before dispatch, so stepping over a `nop` retires exactly that
`nop`. Because trap entry presets the interrupt resume PC to the trap target, a
stepped instruction that traps halts with `dpc` at the handler's first
instruction, as the specification requires.

## CSR writes

CSR instructions execute one at a time at commit, sequenced by the ROB
serializer (see the [ROB README](tomasulo/reorder_buffer/README.md)). A CSR
commit never coincides with a trap or xRET, and `cpu_ooo` sets `csr_file`'s
`COMMIT_EXCLUDES_CONTROL_TAKE` so the CSR file can rely on that and drop trap
priority from its write path; other `csr_file` instances keep the default.
Simulation assertions in both modules check the rule, and the
`csr_commit_cofactor` formal target checks the CSR state under it.

A CSR instruction that accesses `satp`, or writes `mstatus` or `sstatus`, can
change address translation, so everything after it must be refetched under
the new state. The ROB serializer waits for committed stores to drain and then
retires the CSR. The write lands in `csr_file` the next cycle, from the
registered commit bus, and a full pipeline flush follows one cycle after that.
It is the same FENCE-class flush that FENCE.I uses, so it also drops the fetch
provider's buffered lines. Across those two cycles `cpu_ooo` blocks trap,
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
variable latency closes the gap between the two PCs, never pends. Checked by
`prediction_release`, `prediction_handoff`, `pc_pending_capture`,
`pc_holdoff_tag`, `prediction_metadata_tracker`, and `if_direction_payload`.

### Served-window check and retries

A provider can present a stale window, or one a word behind `pc_reg`.
`served_window_coverage.sv` compares `pc_reg` with the word addresses each
provider registers beside its payload. A window missing any byte of the packet
becomes a NOP bubble, makes no prediction, and resteers fetch to `pc_reg`'s
word. When `pc_reg` is in the upper half of that word, the retry's BTB lookup
names the parcel before it, which is off the program path, so `pc_controller`
flags the lookup, `branch_prediction_controller` ignores that BTB entry, and
IF gives the packet a not-taken direction with its own bimodal index.
`fetch_pc_mux` checks the resteer's priority and `prediction_release` the
retry's lookup address; simulation assertions check the rest.

### Aliased BTB lookups

When the fetch PC equals the slot-2 position (`pc_reg` + 2 or + 4), for
example on the first window after a fetch gap, the slot-1 and slot-2 lookups
name the same instruction, and one branch could get two predictions.
`branch_prediction_controller` gives the alias to slot 2 only. The return
address stack is not gated by this, because its pushes and pops belong to the
older packet that IF registered the cycle before. Checked by
`branch_prediction_alias`, `branch_prediction_disable`, and
`prediction_metadata_output`.

### Return address stack recovery

The stack updates on the edge that captures the next, younger packet, so each
packet carries the state after all older pushes and pops (top of stack and
valid count) as its recovery point. Restoring it keeps an older call pushed
and an older return popped. `ras_checkpoint` checks the next-state equations;
the `return_address_stack`, `ras_test`, and `ras_stress_test` cocotb targets
check the behavior.

### BTB training order

BTB writes come from early recovery, commit-time recovery, and correct-branch
commits, and each is a read-modify-write of a 2-bit counter.
`ex_comb_synthesizer` picks one per cycle in that priority and
`branch_prediction_controller` registers it, so training lands one cycle late
but in order, and back-to-back updates to one entry see each other. A slot-1
correct-branch update that loses its cycle is dropped, and a waiting slot-2
update is replaced by a newer one; both cost accuracy only. Checked by the
`branch_predictor` cocotb bench and reference-model assertions in
`branch_predictor.sv`.

### 4 GiB target limit

The BTB stores the low 32 bits of each target and takes the upper bits from the
branch's own PC, so an entry is valid only if the branch and its target share a
4 GiB region. Control flow that crosses a region boundary always misses the
BTB, so the BTB never supplies a wrong target; a taken crossing conditional
branch can still be predicted by the PD redirect, and a taken crossing JAL
mispredicts. The BTB learns only conditional branches (offsets up to ±4 KiB)
and JALs (up to ±1 MiB), so only code near such a boundary is affected. The
`branch_predictor` cocotb bench covers this; there is no formal target.

## Verification

Most front-end modules and `cpu_ooo` glue submodules have their own cocotb
bench, such as `branch_predictor`, `pc_controller`, `instruction_aligner`,
`fetch_provider`, `immu`, and `decoded_bundle_queue`. Whole-program tests run
the integrated core; the `*_fetch_fuzz` variants, such as
`branch_pred_test_fetch_fuzz`, add random fetch gaps with `FETCH_VALID_FUZZ=1`.
Formal targets cover the PC muxes and holdoffs, the pending-prediction
handoff, predictor aliasing, RV64C predecode (`rvc_predecode` checks every
16-bit parcel against the runtime decompressor), the TLBs and walker, and the
CSR file and trap unit.

See the [test runner](../../../../tests/README.md) for commands and the
[formal guide](../../../../formal/README.md) for proof scope and assumptions.
