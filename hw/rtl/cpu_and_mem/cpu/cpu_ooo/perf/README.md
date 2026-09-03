# Performance counters

FROST exposes 130 profiling counters through custom machine CSRs:
42 top-level counters and 24 cache counters in `perf_counter_aggregator.sv`,
plus 64 back-end counters in `tomasulo_perf_counters.sv`. This document
defines their numbering, the CSR protocol, and the software API.

## CSR interface

| CSR | Address | Access | Purpose |
|-----|---------|--------|---------|
| `mperfsel` | `0x7C0` | RW | Global counter index to read (0–129) |
| `mperfctl` | `0x7C1` | W | Bit 0 = snapshot capture; bit 1 = select preceding cache snapshot for reads (reads as 0) |
| `mperfdata` | `0xFC0` | R | Selected counter, low 32 bits |
| `mperfdatah` | `0xFC1` | R | Selected counter, high 32 bits |
| `mperfcount` | `0xFC2` | R | Total number of counters (130) |

Every counter is 64 bits wide and free-running. Each live counter adds 0 or 1
every cycle (occupancy and miss-cycle `sum` counters add the observed value)
and is cleared only by reset. The increment passes through a pipeline
register in its owning block, so live totals lag events by a cycle; snapshot
deltas are exact.

Snapshots are taken on demand. Writing 1 to `mperfctl` bit 0 produces a
single-cycle capture pulse (`csr_file.sv`). Each block registers that pulse
into four `max_fanout`-annotated bank copies (512 in the aggregator, 768 in
`tomasulo_perf_counters`) to keep the CE fanout off the commit cone, so the
copy into the snapshot registers lands one cycle after the pulse. The
top-level, cache, and back-end blocks register the pulse the same way, so the
three blocks form one coherent snapshot. On capture, the cache block also
moves its old current values into a preceding-snapshot bank. Writing
`mperfctl` with bit 1 set selects that preceding bank for indices 106–129; it
has no effect on indices 0–105. Writing 0 selects the current bank again. Bit
1 does not trigger a capture unless bit 0 is also set.

Reads return the snapshot, never the live value, so capture first and then
read. Because `mperfdata` and `mperfdatah` both read the frozen 64-bit
snapshot, the two halves are consistent without a hi/lo re-read loop.

The read path is registered. The selector and the read data each pass through
a register inside the aggregator, and the CSR file registers its read data
once more, so a counter value reaches `mperfdata` three cycles after the
`mperfsel` register updates. Software cannot observe this: CSR instructions
execute serially at commit, so a `csrw mperfsel` / `csrr mperfdata` pair can
never outrun it.

Selecting an out-of-range index (130 or above) reads 0. The selector is 8
bits wide, so 130 counters fit within its 0–255 index space.

## Numbering contract

The global index space is three concatenated blocks:

- top-level block: `[0, PerfTopCounterCount)` = 0–41, owned by
  `perf_counter_aggregator.sv`;
- wrapper block:
  `[PerfWrapperBase, PerfCacheBase)` = 42–105, owned by
  `tomasulo_perf_counters.sv`, addressed there by the wrapper-local index
  (global − 42);
- cache block:
  `[PerfCacheBase, PerfCounterCount)` = 106–129, accumulated by
  `perf_counter_aggregator.sv`.

`PerfWrapperBase = PerfTopCounterCount` is 42 and
`PerfCacheBase = PerfTopCounterCount + PerfWrapperCounterCount` is 106.
The cache counters were appended as a third block so that existing indices
kept their meaning. The 42-counter top block, the 64-counter wrapper block,
and their bases are compatibility invariants: append future families rather
than inserting them.

There is no global enum in `riscv_pkg`. Four places hold independent views of
the numbering and must be audited in lockstep:

1. `hw/rtl/cpu_and_mem/cpu/cpu_ooo/perf/perf_counter_aggregator.sv`
   (`PerfTopCounterCount`, `PerfWrapperCounterCount`,
   `PerfCacheCounterCount`, the bases, and the `Perf*` localparams)
2. `hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/perf/tomasulo_perf_counters.sv`
   (`WrapperPerfCounterCount` + the wrapper-local `Perf*` localparams, both
   unchanged by an appended cache block)
3. `sw/lib/include/tomasulo_profile.h`
   (`TOMASULO_PROFILE_COUNTER_COUNT` + the `tomasulo_profile_counter_idx` enum)
4. `verif/cocotb_tests/cpu_ooo/perf/test_perf_counter_aggregator.py`
   (the three block counts/bases, `PERF_COUNTER_COUNT`, and the `PERF_*`
   constants)

## Counter reference

The Type column is `cycle` (increments every cycle a condition holds),
`event` (one increment per discrete occurrence), or `sum` (adds a value
every cycle). The Name column is the C enum from `tomasulo_profile.h`
with the `TOMASULO_PERF_` prefix dropped; the RTL localparams use the same
names in CamelCase (`PerfDispatchFire`, …).

### Top level 0–22: dispatch, stalls, serialization

Sources: `dispatch.sv` (`o_status`), `ooo_pipeline_control.sv`,
`frontend_validity_tracker.sv`, and the ROB commit/empty signals.

| Idx | Name | Type | Increments when |
|-----|------|------|-----------------|
| 0 | `DISPATCH_FIRE` | event | Slot-1 dispatch fired (`rob_alloc_req.alloc_valid`): one per instruction dispatched through slot 1. |
| 1 | `DISPATCH_STALL` | cycle | Dispatch back-pressure: a valid bundle at the dispatch input could not fire (`dispatch_status.stall`). |
| 2 | `FRONTEND_BUBBLE` | cycle | No instruction at the dispatch input with nothing else to blame: not reset, not flushing, no post-flush holdoff, no dispatch stall, no CSR or control-flow serialization; a pure fetch bubble. |
| 3 | `FLUSH_RECOVERY` | cycle | `flush_pipeline` asserted. |
| 4 | `POST_FLUSH_HOLDOFF` | cycle | Post-flush holdoff window active (`post_flush_holdoff_q != 0`, the BRAM settle window after a full flush). |
| 5 | `CSR_SERIALIZE` | cycle | Front end serialized around a CSR / serializing instruction: one is in flight, its write-back is pending, or one is allocating this cycle. |
| 6 | `CONTROL_FLOW_SERIALIZE` | cycle | An unpredicted indirect control-flow op is held in the front end while an older branch/jump is unresolved (registered `front_end_cf_serialize_stall`). |
| 7 | `DISPATCH_STALL_ROB_FULL` | cycle | Valid slot-1 instruction present and the ROB is full. |
| 8 | `DISPATCH_STALL_INT_RS_FULL` | cycle | Valid slot-1 instruction targets the INT RS and it is full. |
| 9 | `DISPATCH_STALL_MUL_RS_FULL` | cycle | Same, MUL RS. |
| 10 | `DISPATCH_STALL_MEM_RS_FULL` | cycle | Same, MEM RS. |
| 11 | `DISPATCH_STALL_FP_RS_FULL` | cycle | Same, FP RS. |
| 12 | `DISPATCH_STALL_FMUL_RS_FULL` | cycle | Same, FMUL RS. |
| 13 | `DISPATCH_STALL_FDIV_RS_FULL` | cycle | Same, FDIV RS. |
| 14 | `DISPATCH_STALL_LQ_FULL` | cycle | Valid slot-1 instruction needs an LQ entry and the LQ is full. |
| 15 | `DISPATCH_STALL_SQ_FULL` | cycle | Valid slot-1 instruction needs an SQ entry and the SQ is full. |
| 16 | `DISPATCH_STALL_CHECKPOINT_FULL` | cycle | Valid slot-1 instruction needs a branch checkpoint and none is available. |
| 17 | `NO_RETIRE_NOT_EMPTY` | cycle | Nothing committed this cycle while the ROB is non-empty and not flushing. |
| 18 | `ROB_EMPTY` | cycle | ROB empty and not flushing. |
| 19 | `PREDICTION_DISABLED` | cycle | Branch prediction dynamically suppressed (CSR in flight / serializing alloc) while the static disable input is off. |
| 20 | `PRED_FENCE_BRANCH` | cycle | An unpredicted conditional branch in PD/ID is the pick of the prediction-fence classifier. |
| 21 | `PRED_FENCE_JAL` | cycle | Same, unpredicted JAL. |
| 22 | `PRED_FENCE_INDIRECT` | cycle | Same, unpredicted indirect control flow (JALR and similar). |

Counters 7–16 are each gated on a valid slot-1 instruction that needs the
resource in question. Several can fire in the same cycle, so they overlap
rather than partition counter 1. Cycles where only slot 2 blocks the bundle
count in 1 but in none of 7–16; they land in 35–39 instead.

Counters 20–22 are one-hot per cycle (classifier priority: indirect, then
JAL, then branch; ID over PD) and fire only while the prediction fence is
pending.

### Top level 23–41: 2-wide width funnel

Sources: `if_stage.sv` `o_width_events` / `instruction_aligner.sv`
`o_slot2_kill_*` (23–30), `branch_prediction_controller.sv` slot-2 port via
`o_width_events.slot2_pred_taken` (31), `dispatch.sv` `o_status.slot2_*`
(32–39), and the registered back-end observers in `reservation_station.sv`
(`o_perf_two_ready_one_issued`, u_mem_rs instance) and `tomasulo_wrapper.sv`
(CDB request popcount) for 40–41.

The `o_width_events` struct (23–31) is registered at the IF boundary so the
observer logic cannot share LUTs with the slot-2 redirect cluster. These
events therefore reach the aggregator one cycle after the observed
bundle/redirect. Totals are unaffected; only same-cycle alignment against
other counters shifts by one.

| Idx | Name | Type | Increments when |
|-----|------|------|-----------------|
| 23 | `IF_DELIVER1` | event | Accepted IF→PD handoff carrying a real slot-1 instruction (one per handoff, stall-qualified). |
| 24 | `IF_DELIVER2` | event | That handoff also carried a real slot-2 instruction (subset of 23). |
| 25 | `IF_S2KILL_S1_NATIVE_CTRL` | event | 1-wide handoff: slot-1 is native 32-bit control flow (BRANCH/JAL/JALR), so the bundle terminates at slot 1. |
| 26 | `IF_S2KILL_S1_NATIVE_SERIALIZE` | event | 1-wide handoff: slot-1 is a native serializing-class op (never leads a pair; a slot-2 renamed against a serializing slot-1 would never wake). |
| 27 | `IF_S2KILL_S1_CTRL` | event | 1-wide handoff: slot-1 is compressed control flow (bundle terminates at slot 1). |
| 28 | `IF_S2KILL_S2_CLASS` | event | 1-wide handoff: the slot-2 candidate starts an op class excluded from slot 2 (native CSR / MISC-MEM / AMO / FP-compute). |
| 29 | `IF_S2KILL_WINDOW_LIMIT` | event | 1-wide handoff: 64-bit fetch-window limit. The slot-2 candidate sits at NEXT_HI (32-bit slot-1 at an odd halfword) and is itself native 32-bit, so it can never fit the window regardless of BRAM state. |
| 30 | `IF_S2KILL_TRANSIENT` | event | 1-wide handoff: true aligner buffer / BRAM transient state (parity-unsafe `slot2_bram_unsafe` reads, buffer-at-lo punt). |
| 31 | `IF_SLOT2_PRED_TAKEN` | event | Slot-2 BTB predicted-taken accepted (one per event, `!stall`-qualified in BPC). Each occurrence costs one fetch bubble: the redirect applies via `slot2_redirect_q` the next cycle. |
| 32 | `DISPATCH_FIRE_2` | event | Slot-2 dispatch fired (`rob_alloc_req_2.alloc_valid`): one per instruction dispatched through slot 2. |
| 33 | `DISPATCH_SLOT2_PRESENT` | cycle | A real slot-2 instruction is at the dispatch input. |
| 34 | `DISPATCH_SLOT2_FP_SERIALIZED` | cycle | Slot-2 instruction present but targets an FP-compute RS (FP / FMUL / FDIV); these never dispatch in slot 2. |
| 35 | `DISPATCH_SLOT2_BLOCK_S1_BRANCH` | cycle | Slot-2 alone holds the bundle: slot-1 is a branch/jump (bundle terminates). |
| 36 | `DISPATCH_SLOT2_BLOCK_ROB_FULL2` | cycle | Slot-2 alone holds the bundle: no ROB room for 2. |
| 37 | `DISPATCH_SLOT2_BLOCK_RS_FULL2` | cycle | Slot-2 alone holds the bundle: slot-2's RS room check failed. |
| 38 | `DISPATCH_SLOT2_BLOCK_LSQ_FULL2` | cycle | Slot-2 alone holds the bundle: LQ/SQ room check for slot-2 failed. |
| 39 | `DISPATCH_SLOT2_BLOCK_CKPT` | cycle | Slot-2 alone holds the bundle: no checkpoint free for a slot-2 branch. |
| 40 | `MEM_RS_TWO_READY_ONE_ISSUED` | cycle | MEM_RS stage-1 issue fired while two or more entries had all operands ready, so its single issue port was the limiter (registered in the RS; 1-cycle lag). |
| 41 | `CDB_OVERSUBSCRIBED` | cycle | Three or more FU completions requested the 2-lane CDB, so at least one had to hold its result and retry (registered in the wrapper; 1-cycle lag). |

The IF 2-wide rate is 24 / 23. The kill causes 25–30 are mutually exclusive
and partition the 1-wide handoffs (23 − 24). 25 + 26 replace the former
`S1_32BIT` bucket, split by the NativeSerialize sideband bit; 29 + 30 replace
the former `TRANSIENT` bucket, with the fundamental window-limit case split
out from the true transients.

The dispatch 2-wide rate is 32 / 0, and the total number of dispatched
instructions is 0 + 32.

Counters 35–39 all require `slot2_only_block` (slot-1 could have fired). The
individual cause conjuncts can overlap when several room checks fail in the
same cycle.

### Wrapper 42–51: ROB head-wait

Source: `reorder_buffer.sv` `o_perf_events`. All fire on cycles where the
ROB head is valid, not done, and no full flush is in progress; 43–51
partition 42 by the head's class (priority: branch, then AMO/LR, then
store, then RS type).

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 42 | 0 | `HEAD_WAIT_TOTAL` | cycle | ROB head valid but not done (waiting for its result). |
| 43 | 1 | `HEAD_WAIT_INT` | cycle | …and the head is an INT-RS op (not branch/store/AMO). |
| 44 | 2 | `HEAD_WAIT_BRANCH` | cycle | …and the head is a branch/jump. |
| 45 | 3 | `HEAD_WAIT_MUL` | cycle | …and the head is a MUL-RS op (MUL/DIV). |
| 46 | 4 | `HEAD_WAIT_MEM_LOAD` | cycle | …and the head is a MEM-RS op that is not a store or AMO, i.e. a load (INT or FP). |
| 47 | 5 | `HEAD_WAIT_MEM_STORE` | cycle | …and the head is a store (including FP stores and SC). |
| 48 | 6 | `HEAD_WAIT_MEM_AMO` | cycle | …and the head is an AMO or LR. |
| 49 | 7 | `HEAD_WAIT_FP` | cycle | …and the head is an FP-RS (FP add class) op. |
| 50 | 8 | `HEAD_WAIT_FMUL` | cycle | …and the head is an FMUL-RS op. |
| 51 | 9 | `HEAD_WAIT_FDIV` | cycle | …and the head is an FDIV-RS op. |

### Wrapper 52–56: commit blocked in the serializing FSM

Source: `reorder_buffer.sv`. All fire on cycles where the head is ready
(done) but commit is stalled by the serializing FSM, attributed by class.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 52 | 10 | `COMMIT_BLOCKED_CSR` | cycle | Head is a CSR op or the FSM is in CSR execute / translation drain. |
| 53 | 11 | `COMMIT_BLOCKED_FENCE` | cycle | Head is FENCE/FENCE.I or the FSM is draining the SQ. |
| 54 | 12 | `COMMIT_BLOCKED_WFI` | cycle | Head is WFI or the FSM is in the WFI wait state. |
| 55 | 13 | `COMMIT_BLOCKED_MRET` | cycle | Head is MRET or the FSM is in MRET execute. |
| 56 | 14 | `COMMIT_BLOCKED_TRAP` | cycle | Head has an exception or the FSM is in the trap wait state. |

### Wrapper 57–62: FU back-pressure

Sources: RS `fu_ready`/`empty` status and the MEM `fu_cdb_adapter`.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 57 | 15 | `INT_BACKPRESSURE` | cycle | INT RS non-empty while its FU is not ready (issue blocked downstream). |
| 58 | 16 | `MUL_BACKPRESSURE` | cycle | Same, MUL RS. MUL and DIV share the muldiv shim, so there is no separate DIV counter. |
| 59 | 17 | `MEM_RESULT_BACKPRESSURE` | cycle | MEM FU has a valid result while the MEM CDB adapter still holds a previous result pending a CDB grant. |
| 60 | 18 | `FP_ADD_BACKPRESSURE` | cycle | Same as 57, FP RS. |
| 61 | 19 | `FMUL_BACKPRESSURE` | cycle | Same as 57, FMUL RS. |
| 62 | 20 | `FDIV_BACKPRESSURE` | cycle | Same as 57, FDIV RS. |

### Wrapper 63–66: memory / queue activity

Sources: `store_queue.sv`, `load_queue.sv`.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 63 | 21 | `MEM_DISAMBIGUATION_WAIT` | cycle | A load's SQ disambiguation/forwarding check is valid but not all older store addresses are known yet. |
| 64 | 22 | `SQ_COMMITTED_PENDING` | cycle | SQ holds committed stores not yet drained to memory. |
| 65 | 23 | `SQ_MEM_WRITE_FIRE` | event | SQ issued a store write to memory (registered one-cycle pulse per write). |
| 66 | 24 | `LQ_MEM_READ_FIRE` | event | LQ launched a load read on the memory port (one pulse per launch). |

### Wrapper 67–75: occupancy sums

Each adds the structure's current entry count every cycle. Average
occupancy = delta / elapsed cycles.

| Idx | Local | Name | Type | Adds each cycle |
|-----|-------|------|------|-----------------|
| 67 | 25 | `ROB_OCCUPANCY_SUM` | sum | ROB entry count. |
| 68 | 26 | `LQ_OCCUPANCY_SUM` | sum | LQ entry count. |
| 69 | 27 | `SQ_OCCUPANCY_SUM` | sum | SQ entry count. |
| 70 | 28 | `INT_RS_OCCUPANCY_SUM` | sum | INT RS entry count. |
| 71 | 29 | `MUL_RS_OCCUPANCY_SUM` | sum | MUL RS entry count. |
| 72 | 30 | `MEM_RS_OCCUPANCY_SUM` | sum | MEM RS entry count. |
| 73 | 31 | `FP_RS_OCCUPANCY_SUM` | sum | FP RS entry count. |
| 74 | 32 | `FMUL_RS_OCCUPANCY_SUM` | sum | FMUL RS entry count. |
| 75 | 33 | `FDIV_RS_OCCUPANCY_SUM` | sum | FDIV RS entry count. |

### Wrapper 76–83: L0 cache, widen-commit, head-load split

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 76 | 34 | `LQ_L0_HIT` | event | Load completed via the L0 cache fast path. |
| 77 | 35 | `LQ_L0_FILL` | event | L0 line filled from a memory response. |
| 78 | 36 | `HEAD_AND_NEXT_DONE` | cycle | Commit fired while the entry behind head was also valid+done; an upper bound on 2-wide retire. |
| 79 | 37 | `HEAD_WAIT_LOAD_OUTSTANDING` | cycle | `HEAD_WAIT_MEM_LOAD` with an LQ memory response in flight (real memory latency). |
| 80 | 38 | `HEAD_WAIT_LOAD_NO_OUTSTANDING` | cycle | `HEAD_WAIT_MEM_LOAD` with no memory response in flight (decomposed by 84–88). |
| 81 | 39 | `HEAD_PLUS_ONE_DONE` | cycle | Entry behind head valid+done, whether or not commit fires (not flushing). 81 − 78 = done work stacking up behind a stalled head. |
| 82 | 40 | `COMMIT_2_OPPORTUNITY` | event | The full 2-wide commit gate passed: commit firing, head+1 done, hazard exclusions clear. |
| 83 | 41 | `COMMIT_2_FIRE_ACTUAL` | event | A 2-wide commit fired: 82 plus the `EnableWidenCommit` constant and the cpu_ooo slot-2 accept term (`i_widen_commit_ok`). Since the 2-write-port regfile removed the old pending-write FIFO, cpu_ooo ties the accept term high except while debug single-step is armed (`step_armed_q`), so outside single-step 83 = 82. |

L0 hit rate = 76 / (76 + 66), and 79 + 80 = 46.

### Wrapper 84–93: head-load decomposition

Source: `load_queue.sv` head-load diagnostics. Every row is additionally
qualified by `HEAD_WAIT_MEM_LOAD` with no memory response in flight: 84–88
are sub-buckets of 80, and 89–93 further decompose 86 into mutually
exclusive causes.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 84 | 42 | `HEAD_LOAD_ADDR_PENDING` | cycle | Head load is in the LQ but its address is not yet computed (waiting on rs1 / MEM_RS). |
| 85 | 43 | `HEAD_LOAD_SQ_DISAMBIG` | cycle | Address known, blocked on SQ disambiguation. |
| 86 | 44 | `HEAD_LOAD_BUS_BLOCKED` | cycle | Ready to issue, blocked on bus / arbitration / pipeline (split by 89–93). |
| 87 | 45 | `HEAD_LOAD_CDB_WAIT` | cycle | Data ready in the LQ, waiting to enter the CDB stage. |
| 88 | 46 | `HEAD_LOAD_POST_LQ` | cycle | LQ entry already freed; result is in the CDB pipeline on its way to the ROB. |
| 89 | 47 | `HEAD_LOAD_BB_ISSUED` | cycle | Bus-blocked: request already issued, waiting for the response. |
| 90 | 48 | `HEAD_LOAD_BB_BUS_BUSY` | cycle | Bus-blocked: memory bus busy. |
| 91 | 49 | `HEAD_LOAD_BB_AMO` | cycle | Bus-blocked: an older AMO pending blocks the load. |
| 92 | 50 | `HEAD_LOAD_BB_SQ_WAIT` | cycle | Bus-blocked: in the sq_check stage but phase 2 not reached. |
| 93 | 51 | `HEAD_LOAD_BB_STAGING` | cycle | Bus-blocked: catch-all (pre-sq_check capture, drop-pending, and the like). |

### Wrapper 94–97: head-INT decomposition

Source: the INT RS head-query diagnostic port. Sub-buckets of 43, keyed on
where the head's op currently sits.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 94 | 52 | `HEAD_INT_OPERAND_WAIT` | cycle | Head op is in the INT RS with operands not yet ready. |
| 95 | 53 | `HEAD_INT_RS_READY_NOT_ISSUED` | cycle | In the RS and ready, but not picked for issue. |
| 96 | 54 | `HEAD_INT_STAGE2` | cycle | No longer in RS storage; parked in the RS's stage-2 issue register. |
| 97 | 55 | `HEAD_INT_POST_RS` | cycle | Left the RS entirely (not in stage 2 either); in the FU / CDB path. |

### Wrapper 98–105: widen-commit blocker taxonomy + staging catch-all split

Sources: `reorder_buffer.sv` (98–101) and `load_queue.sv` (102–105). 98–101
are gated on commit firing with head+1 valid+done, so these four partition
the hazard-blocked gap: 98 + 99 + 100 + 101 = 78 − 82.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 98 | 56 | `COMMIT_2_BLOCKED_HEAD_SERIAL` | cycle | Head itself is a serial op or a mispredicting branch (fails the head 2-wide check). |
| 99 | 57 | `COMMIT_2_BLOCKED_NEXT_SERIAL` | cycle | Head+1 is a serial op (CSR / FENCE / FENCE.I / WFI / MRET / AMO / LR / SC / exception), not a branch. |
| 100 | 58 | `COMMIT_2_BLOCKED_NEXT_BRANCH_MISPRED` | cycle | Head+1 is a branch that will flush. |
| 101 | 59 | `COMMIT_2_BLOCKED_NEXT_BRANCH_CORRECT` | cycle | Head+1 is a correctly predicted branch the gate still refused (early-recovered leftovers). Correct branches retire in slot 2 now, so this reads ~0; persistent nonzero means the slot-2 branch-retire path regressed. |
| 102 | 60 | `HEAD_LOAD_BBS_OTHER_IN_STAGING` | cycle | `HEAD_LOAD_BB_STAGING` and the single sq_check staging register is occupied by a different load (the one-staging-pipe serialization cost). |
| 103 | 61 | `HEAD_LOAD_BBS_LAUNCH_GATED` | cycle | `HEAD_LOAD_BB_STAGING` and the head load is staged with phase 2 armed but the launch is still gated (drop-response window, launch qualifiers). |
| 104 | 62 | `HEAD_LOAD_BBS_SLOW_OUTSTANDING` | cycle | `HEAD_LOAD_BB_STAGING`, staging free, but every cached load slot is in flight, so no launch can take a credit. |
| 105 | 63 | `HEAD_LOAD_BBS_CAPTURE_GAP` | cycle | `HEAD_LOAD_BB_STAGING`, staging free, a cached slot available: the head load has not been captured yet (selector / capture-recycle bubble). Counters 102–105 partition 93. |

### Cache hierarchy 106–129: cache traffic, fetch stalls, miss latency, concurrency

Sources: the registered observer bundle from each `frost_cache` instance
(L1I, L1D, and optional L2), plus the instruction-fetch progress seam in
`cpu_and_mem.sv`. The per-instance events and miss-outstanding state are
registered inside their source cache before crossing the hierarchy/CPU
boundary; the fetch-miss stall is likewise registered at its
`fetch_provider` source. They therefore have a one-cycle source lag relative
to the cache/fetch state they observe, in addition to the counter accumulator
pipeline. Totals and snapshot deltas are unaffected; only same-cycle
alignment against other counter groups shifts.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 106 | 0 | `L1I_ACCESS` | event | A non-maintenance request fires at the L1I upstream port (`i_up_req_valid && o_up_req_ready`). This includes both a currently required line and the fetch provider's next-line prefetch. |
| 107 | 1 | `L1I_HIT` | event | That L1I access resolves as a valid tag hit at the T-stage tag decision. |
| 108 | 2 | `L1I_MISS` | event | That L1I access resolves as a tag miss at the T-stage tag decision. |
| 109 | 3 | `L1I_WRITEBACK` | event | A counted miss evicts a dirty L1I victim and its writeback request fires downstream. FROST uses L1I read-only, so this is normally 0. |
| 110 | 4 | `L1D_ACCESS` | event | A non-maintenance (architectural demand) request fires at the L1D upstream port. |
| 111 | 5 | `L1D_HIT` | event | That L1D access resolves as a valid tag hit at the T-stage tag decision. |
| 112 | 6 | `L1D_MISS` | event | That L1D access resolves as a tag miss at the T-stage tag decision. |
| 113 | 7 | `L1D_WRITEBACK` | event | A counted miss evicts a dirty L1D victim and its writeback request fires downstream. |
| 114 | 8 | `L2_ACCESS` | event | A non-maintenance request from either L1 or the page-table walker fires at the L2 upstream port. This includes L1I required-line fills and prefetches plus L1D fills and dirty-victim writebacks. |
| 115 | 9 | `L2_HIT` | event | That L2 access resolves as a valid tag hit at the T-stage tag decision. |
| 116 | 10 | `L2_MISS` | event | That L2 access resolves as a tag miss at the T-stage tag decision. |
| 117 | 11 | `L2_WRITEBACK` | event | A counted miss evicts a dirty L2 victim and its writeback request fires downstream. |
| 118 | 12 | `L1I_FETCH_MISS_STALL` | cycle | The high-address front end cannot accept a fetch window because an L1I miss blocks its currently required line. An unrelated pipeline stall, a non-blocking next-line prefetch, and low-BRAM progress after a tier-crossing redirect do not count. |
| 119 | 13 | `L1D_MISS_CYCLES_SUM` | sum | Adds the number of unresolved non-maintenance L1D misses each cycle (the cache's `miss_outstanding` count, `cache_perf_pkg::MissOutstandingBits` wide; up to `NUM_MSHR`). |
| 120 | 14 | `L2_MISS_CYCLES_SUM` | sum | Adds the number of unresolved non-maintenance L2 misses each cycle. |
| 121 | 15 | `L1I_HIT_UNDER_MISS` | event | An L1I hit resolved while at least one L1I miss was outstanding. |
| 122 | 16 | `L1D_HIT_UNDER_MISS` | event | Same, L1D. |
| 123 | 17 | `L2_HIT_UNDER_MISS` | event | Same, L2. |
| 124 | 18 | `L1D_SLOT_FULL_STALL` | cycle | The L1D tag stage held a miss because every miss-status slot, or every writeback slot a dirty victim needed, was busy. |
| 125 | 19 | `L2_SLOT_FULL_STALL` | cycle | Same, L2. |
| 126 | 20 | `L1D_CONFLICT_STALL` | cycle | The L1D tag stage held a request aimed at an index whose line is in transition (a pending miss slot it could neither merge into nor wait on). |
| 127 | 21 | `L2_CONFLICT_STALL` | cycle | Same, L2. |
| 128 | 22 | `L1D_MISS_OVERLAP_CYCLES` | cycle | Two or more non-maintenance L1D misses were outstanding. |
| 129 | 23 | `L2_MISS_OVERLAP_CYCLES` | cycle | Two or more non-maintenance L2 misses were outstanding. |

Access accounting is an exact partition:

```text
HIT + MISS = ACCESS
```

`ACCESS` records the upstream fire, while `HIT`/`MISS` record its later tag
decision, so their pulses need not be cycle-aligned. Once every accepted
request has resolved, the accumulated totals satisfy the identity exactly.
Hit rate is `HIT / ACCESS`.

The reset tag sweep, the L1D `fence.i` writeback-all walk, and the L1I
invalidate-all walk do not increment `ACCESS`, `HIT`, or `MISS`. `WRITEBACK`
counts only dirty victims evicted by counted misses. L1I access/hit/miss and
the corresponding downstream L2 traffic include next-line prefetches;
`L1I_FETCH_MISS_STALL` filters to misses that cost front-end progress.
Maintenance provenance crosses the L1 arbiter, so L1D walk traffic and the
victim writebacks it causes are excluded from the L2 counts as well.

`miss_outstanding` is a per-cycle count of the cache's occupied
non-maintenance miss-status slots: a counted miss takes a slot when its
allocation lands and releases it once its fill has been written and
responded to.

The miss sums integrate that outstanding state over time, so average latency
in cycles is:

```text
L1D average miss latency = L1D_MISS_CYCLES_SUM / L1D_MISS
L2  average miss latency = L2_MISS_CYCLES_SUM  / L2_MISS
```

The focused lower-level hierarchy harness retains `HAS_L2=0` coverage. In that
topology, the `gen_no_l2` branch in `frost_cache_hierarchy.sv` drives the whole
L2 event bundle to 0 rather than leaving it undriven, so every L2-derived index
(114–117, 120, 123, 125, 127, 129) reads 0. Full-system builds fix `HAS_L2=1`;
when `ENABLE_CACHED_TIER=0`, all 24 cache-block counters read 0.

## Using the counters from software

`sw/lib/include/tomasulo_profile.h` wraps the CSR protocol, with the
cache-only report body in `sw/lib/src/tomasulo_profile_cache.c`:

```c
#include "tomasulo_profile.h"

static tomasulo_profile_snapshot_t start, stop;
static uint64_t start_cache[TOMASULO_PROFILE_CACHE_COUNTER_COUNT];
static uint64_t stop_cache[TOMASULO_PROFILE_CACHE_COUNTER_COUNT];

tomasulo_profile_bind_cache_counters(&start, start_cache);
tomasulo_profile_bind_cache_counters(&stop, stop_cache);

tomasulo_profile_take_snapshot(&start);
/* ... region of interest ... */
tomasulo_profile_take_snapshot(&stop);
tomasulo_profile_read_cache_pair(&start, &stop);

tomasulo_profile_print_report("my region", &start, &stop);        /* full */
tomasulo_profile_print_brief_report("my region", &start, &stop);  /* 1 line */
```

A snapshot object must be zero-initialized, passed to
`tomasulo_profile_init_snapshot()`, or bound with
`tomasulo_profile_bind_cache_counters()` before its first capture. Capture
preserves the binding field across repeated samples, so an uninitialized
automatic object would carry a garbage value that later gets used as the
sidecar address.

`tomasulo_profile_take_snapshot()` writes `mperfctl` bit 0, records
`rdcycle64()` / `rdinstret64()`, then reads the unchanged legacy indices
0–105 through `mperfsel` / `mperfdata` / `mperfdatah`.

`tomasulo_profile_read_cache_pair()` drains the end/current and
start/preceding cache snapshots into the bound 24-counter sidecars. Call it
after capturing the end snapshot and before taking another snapshot, since
the next capture advances both cache banks. Deferring those extra CSR reads
keeps the legacy pre-timer sequence byte-for-byte unchanged, so enabling the
cache observers does not perturb the measured benchmark.

`tomasulo_profile_delta(&start, &stop, idx)` returns one counter's delta;
the `TOMASULO_PERF_*` enum names the indices.

`tomasulo_profile_print_report()` prints the full breakdown (front-end
progress, the "2-wide width funnel" section, dispatch stalls, retirement,
back-end pressure, cache-hierarchy activity and hit rates, L1I fetch-miss
stalls, average miss latency, diagnostics, and average occupancy), with raw
hex values and contextual percentages.

Users in the tree: `sw/apps/coremark` (`core_portme.c`) snapshots around
the timed region and prints the full report; `sw/apps/tomasulo_perf`
prints a brief report per micro-benchmark.

## Verification

`verif/cocotb_tests/cpu_ooo/perf/test_perf_counter_aggregator.py` covers
per-counter increment conditions (including width-funnel
and cache events), snapshot capture and freeze-until-next-capture behavior,
the cache preceding-snapshot bank, all three counter-select blocks, and
out-of-range reads.

`verif/cocotb_tests/cache/test_frost_cache.py` covers both hierarchy
shapes. It checks the per-instance `HIT + MISS = ACCESS` partition and known
hit/miss splits, that maintenance does not pollute ordinary-traffic counts,
and that every L2 field is a known 0 in the L1-only shape.
