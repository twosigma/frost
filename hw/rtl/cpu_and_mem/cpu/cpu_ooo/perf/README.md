# Performance counters

FROST can be built with hardware profiling counters that software reads
through custom machine-mode CSRs. They count dispatch and stall causes, how
often the front end and dispatch achieve 2-wide operation, why the ROB head
waits, back-end pressure and occupancy, and cache traffic. One CSR write
freezes every counter at the same cycle, so any region can be measured as the
difference of two snapshots. `perf_counter_aggregator.sv` holds the top-level
and cache counters and the read mux, and
[`tomasulo_perf_counters.sv`](../../tomasulo/tomasulo_wrapper/perf/tomasulo_perf_counters.sv)
holds the back-end counters. This page is the reference for the build option,
the CSR protocol, the counter numbering, and the C API.

## Build option

`PERF_COUNTERS=1` includes the counters and the `mperf*` CSR state. On the
FPGA, `build.py --perf-counters` or `--no-perf-counters` chooses; the default
is off at the rated clock and on in divided-clock builds. The setting is fixed
at synthesis, so a resumed build keeps its checkpoint's setting. Simulation
targets that need the counters, such as `coremark_profile` and
`tomasulo_perf`, build with `-GPERF_COUNTERS=1`.

Without the counters, every `mperf*` CSR reads 0, `mperfsel` and `mperfctl`
ignore writes, and writes to the read-only ones still trap. The C library then
sees no counters, every delta is 0, and reports print
`Profiling counters: absent`. The `perf_off_test` program and the `csr_file`
formal task `bmc_perf_off` check this configuration.

Taking a snapshot runs code before the timed region, which can change
predictor state, so compare scores only between runs built with the same
setting.

## CSR interface

| CSR | Address | Access | Purpose |
|-----|---------|--------|---------|
| `mperfsel` | `0x7C0` | RW | Global counter index to read (0–129) |
| `mperfctl` | `0x7C1` | W | Bit 0 = take a snapshot; bit 1 = read the preceding cache snapshot (reads as 0) |
| `mperfdata` | `0xFC0` | R | Selected counter, low 32 bits |
| `mperfdatah` | `0xFC1` | R | Selected counter, high 32 bits |
| `mperfcount` | `0xFC2` | R | Number of counters (130; 0 without `PERF_COUNTERS`) |

Every counter is 64 bits wide and free-running, and only reset clears it.
Each cycle a counter adds 0 or 1, except a `sum` counter, which adds a value
such as an occupancy. Each increment passes through a register in the owning
block, so a live total lags its events by a cycle; snapshot deltas are exact.

Reads return a snapshot, never a live value, so take a snapshot first:

1. Write `mperfctl` with bit 0 set. `csr_file` turns the write into a
   one-cycle capture pulse. The top-level, cache, and back-end blocks all
   register it the same way, so every counter is captured on the same cycle,
   one cycle after the pulse.
2. For each counter, write its index to `mperfsel` and read `mperfdata` and
   `mperfdatah`. Both halves come from the same frozen snapshot, so no
   high/low re-read loop is needed.

The cache block also keeps the snapshot before the current one: each capture
moves the cache block's current snapshot into a preceding bank. Every
`mperfctl` write sets the bank select from bit 1. While it is set, indices
106–129 read the preceding bank; indices 0–105 are unaffected. Bit 1 alone
does not take a snapshot. Software can therefore snapshot both ends of a timed
region and read both sets of cache counters afterward.

The read path has three registers: the selector and the read data each pass
through one in the aggregator, and `csr_file` registers its read data again.
A counter therefore reaches `mperfdata` three cycles after `mperfsel` changes.
Software cannot observe this, because CSR instructions execute one at a time
at commit, so a `csrw mperfsel` / `csrr mperfdata` pair cannot outrun it.

In `cpu_ooo`, the aggregator also picks the 32-bit half before its output
register (`PreselectCsrHalf`), and `csr_file` returns that half for both
`mperfdata` and `mperfdatah` (`UsePerfCsrHalf`). The pick uses the raw commit
address that the commit bus registers on the same edge; selecting with any
other copy of the address would return the wrong half.

The counters decode only the low 8 bits of `mperfsel`: indices 130–255 read 0,
and larger values wrap.

## Numbering contract

The global index space is three blocks placed end to end:

| Block | Global indices | Defined in | Local index |
|-------|----------------|------------|-------------|
| Top level | 0–41, `[0, PerfTopCounterCount)` | `perf_counter_aggregator.sv` | Same as global |
| Back end (wrapper) | 42–105, `[PerfWrapperBase, PerfCacheBase)` | `tomasulo_perf_counters.sv` | Global − 42 |
| Cache | 106–129, `[PerfCacheBase, PerfCounterCount)` | `perf_counter_aggregator.sv` | Global − 106 |

`PerfWrapperBase = PerfTopCounterCount` = 42 and
`PerfCacheBase = PerfTopCounterCount + PerfWrapperCounterCount` = 106.
Counter indices and block bases are a software interface: add new counters
without renumbering existing ones.

No shared enum defines the numbering. These files each hold their own copy
and must change together:

1. `hw/rtl/cpu_and_mem/cpu/cpu_ooo/perf/perf_counter_aggregator.sv`
   (`PerfTopCounterCount`, `PerfWrapperCounterCount`,
   `PerfCacheCounterCount`, the bases, and the `Perf*` localparams)
2. `hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/perf/tomasulo_perf_counters.sv`
   (`WrapperPerfCounterCount` and the wrapper-local `Perf*` localparams)
3. `sw/lib/include/tomasulo_profile.h`
   (`TOMASULO_PROFILE_COUNTER_COUNT`, `TOMASULO_PROFILE_LEGACY_COUNTER_COUNT`,
   `TOMASULO_PROFILE_CACHE_COUNTER_COUNT`, and the
   `tomasulo_profile_counter_idx` enum)
4. `verif/cocotb_tests/cpu_ooo/perf/test_perf_counter_aggregator.py`
   (the block counts and bases, `PERF_COUNTER_COUNT`, and the `PERF_*`
   constants)

## Counter reference

The Type column is `cycle` (adds 1 in every cycle a condition holds), `event`
(adds 1 per occurrence), or `sum` (adds a value every cycle). The Name column
is the C enum name from `tomasulo_profile.h` without its `TOMASULO_PERF_`
prefix. The RTL localparams use CamelCase names (`PerfDispatchFire`,
`PerfCacheL1iAccess`), some spelled differently, so match them by index.

### Top level 0–22: dispatch, stalls, serialization

Sources: `dispatch.sv` (`o_status`), `ooo_pipeline_control.sv`,
`frontend_validity_tracker.sv`, and the ROB commit and empty signals.

| Idx | Name | Type | Increments when |
|-----|------|------|-----------------|
| 0 | `DISPATCH_FIRE` | event | Slot 1 dispatched (`rob_alloc_req.alloc_valid`): one per instruction dispatched through slot 1 |
| 1 | `DISPATCH_STALL` | cycle | A valid bundle at the dispatch input could not fire (`dispatch_status.stall`) |
| 2 | `FRONTEND_BUBBLE` | cycle | No instruction at the dispatch input and nothing else to blame: no reset, flush, post-flush holdoff, dispatch stall, or CSR or control-flow serialization |
| 3 | `FLUSH_RECOVERY` | cycle | A pipeline flush is active (`flush_pipeline`: trap, xRET, FENCE-class, or misprediction recovery) |
| 4 | `POST_FLUSH_HOLDOFF` | cycle | The fetch settle window after a pipeline flush (`post_flush_holdoff_q != 0`) |
| 5 | `CSR_SERIALIZE` | cycle | The front end is held for a CSR instruction, from the cycle after it dispatches until it commits and any register result is written back |
| 6 | `CONTROL_FLOW_SERIALIZE` | cycle | An unpredicted indirect jump is held in the front end while an older branch or jump is unresolved (registered `front_end_cf_serialize_stall`) |
| 7 | `DISPATCH_STALL_ROB_FULL` | cycle | A valid slot-1 instruction is present and the ROB is full |
| 8 | `DISPATCH_STALL_INT_RS_FULL` | cycle | A valid slot-1 instruction targets the INT RS and it is full |
| 9 | `DISPATCH_STALL_MUL_RS_FULL` | cycle | Same, MUL RS |
| 10 | `DISPATCH_STALL_MEM_RS_FULL` | cycle | Same, MEM RS |
| 11 | `DISPATCH_STALL_FP_RS_FULL` | cycle | Same, FP RS |
| 12 | `DISPATCH_STALL_FMUL_RS_FULL` | cycle | Same, FMUL RS |
| 13 | `DISPATCH_STALL_FDIV_RS_FULL` | cycle | Same, FDIV RS |
| 14 | `DISPATCH_STALL_LQ_FULL` | cycle | A valid slot-1 instruction needs an LQ entry and the LQ is full |
| 15 | `DISPATCH_STALL_SQ_FULL` | cycle | A valid slot-1 instruction needs an SQ entry and the SQ is full |
| 16 | `DISPATCH_STALL_CHECKPOINT_FULL` | cycle | A valid slot-1 instruction needs a branch checkpoint and none is free |
| 17 | `NO_RETIRE_NOT_EMPTY` | cycle | Nothing committed while the ROB is not empty and no flush is active |
| 18 | `ROB_EMPTY` | cycle | The ROB is empty and no flush is active |
| 19 | `PREDICTION_DISABLED` | cycle | Branch prediction is suppressed because a CSR instruction is in flight (from the cycle after it dispatches until it commits), while the static disable input is off |
| 20 | `PRED_FENCE_BRANCH` | cycle | The highest-priority unpredicted control-flow instruction in PD or ID is a conditional branch |
| 21 | `PRED_FENCE_JAL` | cycle | Same, a JAL |
| 22 | `PRED_FENCE_INDIRECT` | cycle | Same, an indirect jump (JALR) |

Counters 7–16 each require a valid slot-1 instruction that needs the resource
in question. Several can fire in the same cycle, so they overlap rather than
partition counter 1. A cycle in which only slot 2 blocks the bundle counts in
1 but in none of 7–16; it lands in 35–39 instead.

Counters 20–22 are one-hot: each cycle counts at most one instruction,
choosing ID over PD and, within a stage, indirect over JAL over branch. They
only observe; nothing gates prediction on them.

### Top level 23–41: 2-wide width funnel

Sources: `if_stage.sv` `o_width_events`, with kill causes from
`instruction_aligner.sv` (23–31); `dispatch.sv` `o_status.slot2_*` (32–39);
and registered observers in `reservation_station.sv` (the MEM_RS instance,
40) and `tomasulo_wrapper.sv` (41).

The IF events (23–31) are registered at the IF boundary, so they arrive one
cycle after the bundle or redirect they describe. Totals are unaffected; only
same-cycle alignment with other counters shifts.

| Idx | Name | Type | Increments when |
|-----|------|------|-----------------|
| 23 | `IF_DELIVER1` | event | IF handed PD a real slot-1 instruction (once per accepted handoff) |
| 24 | `IF_DELIVER2` | event | That handoff also carried a real slot-2 instruction (a subset of 23) |
| 25 | `IF_S2KILL_S1_NATIVE_CTRL` | event | 1-wide handoff: slot 1 is native 32-bit control flow (branch, JAL, JALR), which ends the bundle |
| 26 | `IF_S2KILL_S1_NATIVE_SERIALIZE` | event | 1-wide handoff: slot 1 is a native serializing instruction (SYSTEM, MISC-MEM, or AMO), which never leads a pair |
| 27 | `IF_S2KILL_S1_CTRL` | event | 1-wide handoff: slot 1 is compressed control flow, which ends the bundle |
| 28 | `IF_S2KILL_S2_CLASS` | event | 1-wide handoff: the slot-2 candidate is a class excluded from slot 2 (native SYSTEM, MISC-MEM, AMO, or FP compute) |
| 29 | `IF_S2KILL_WINDOW_LIMIT` | event | 1-wide handoff: the slot-2 candidate is a 32-bit instruction starting in the upper half of the second word, which cannot fit the 64-bit window |
| 30 | `IF_S2KILL_TRANSIENT` | event | 1-wide handoff: transient aligner-buffer or window state, such as a parity-unsafe window read, kept slot 2 out |
| 31 | `IF_SLOT2_PRED_TAKEN` | event | A slot-2 BTB taken prediction was accepted. Each costs one fetch bubble, because fetch has already requested the next sequential window |
| 32 | `DISPATCH_FIRE_2` | event | Slot 2 dispatched (`rob_alloc_req_2.alloc_valid`): one per instruction dispatched through slot 2 |
| 33 | `DISPATCH_SLOT2_PRESENT` | cycle | A real slot-2 instruction is at the dispatch input |
| 34 | `DISPATCH_SLOT2_FP_SERIALIZED` | cycle | A slot-2 instruction targets an FP-compute RS (FP, FMUL, or FDIV); these never dispatch in slot 2 |
| 35 | `DISPATCH_SLOT2_BLOCK_S1_BRANCH` | cycle | Slot 2 alone holds the bundle: slot 1 is a branch or jump |
| 36 | `DISPATCH_SLOT2_BLOCK_ROB_FULL2` | cycle | Slot 2 alone holds the bundle: no ROB room for two |
| 37 | `DISPATCH_SLOT2_BLOCK_RS_FULL2` | cycle | Slot 2 alone holds the bundle: slot 2's RS room check failed |
| 38 | `DISPATCH_SLOT2_BLOCK_LSQ_FULL2` | cycle | Slot 2 alone holds the bundle: slot 2's LQ or SQ room check failed |
| 39 | `DISPATCH_SLOT2_BLOCK_CKPT` | cycle | Slot 2 alone holds the bundle: no checkpoint free for a slot-2 branch |
| 40 | `MEM_RS_TWO_READY_ONE_ISSUED` | cycle | MEM_RS issued while two or more entries had all operands ready, so its single issue port was the limit (registered in the RS, one cycle late) |
| 41 | `CDB_OVERSUBSCRIBED` | cycle | Three or more FU completions requested the two-lane CDB, so at least one had to wait (registered in the wrapper, one cycle late) |

The IF 2-wide rate is 24 / 23. Counters 25–30 are mutually exclusive. Their
sum equals the 1-wide handoffs (23 − 24), except for handoffs held 1-wide by a
pending slot-1 prediction, which can go uncounted.

The dispatch 2-wide rate is 32 / 0, and the number of instructions
dispatched is 0 + 32.

Counters 35–39 count only cycles in which slot 1 could fire but slot 2 cannot
(`slot2_only_block`), so the whole bundle waits. Their causes can overlap when
several room checks fail at once.

### Wrapper 42–51: ROB head-wait

Source: `reorder_buffer.sv` `o_perf_events`. All count cycles in which the ROB
head is valid but not done and no full flush is active. Counters 43–51
partition 42 by the head's class, in priority order: branch, AMO or LR,
store, then RS type.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 42 | 0 | `HEAD_WAIT_TOTAL` | cycle | The ROB head is valid but not done (waiting for its result) |
| 43 | 1 | `HEAD_WAIT_INT` | cycle | …and the head is an INT-RS operation (not a branch, store, or AMO) |
| 44 | 2 | `HEAD_WAIT_BRANCH` | cycle | …and the head is a branch or jump |
| 45 | 3 | `HEAD_WAIT_MUL` | cycle | …and the head is a MUL-RS operation (multiply or divide) |
| 46 | 4 | `HEAD_WAIT_MEM_LOAD` | cycle | …and the head is a load (INT or FP): a MEM-RS operation that is not a store or AMO |
| 47 | 5 | `HEAD_WAIT_MEM_STORE` | cycle | …and the head is a store (including FP stores and SC) |
| 48 | 6 | `HEAD_WAIT_MEM_AMO` | cycle | …and the head is an AMO or LR |
| 49 | 7 | `HEAD_WAIT_FP` | cycle | …and the head is an FP-RS (FP add class) operation |
| 50 | 8 | `HEAD_WAIT_FMUL` | cycle | …and the head is an FMUL-RS operation |
| 51 | 9 | `HEAD_WAIT_FDIV` | cycle | …and the head is an FDIV-RS operation |

### Wrapper 52–56: commit blocked in the serializing FSM

Source: `reorder_buffer.sv`. All count cycles in which the head is done but the
serializing FSM holds commit, attributed by class.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 52 | 10 | `COMMIT_BLOCKED_CSR` | cycle | The head is a CSR operation, or the FSM is in CSR execute or translation drain |
| 53 | 11 | `COMMIT_BLOCKED_FENCE` | cycle | The head is FENCE or FENCE.I, or the FSM is draining the SQ |
| 54 | 12 | `COMMIT_BLOCKED_WFI` | cycle | The head is WFI, or the FSM is in the WFI wait state |
| 55 | 13 | `COMMIT_BLOCKED_MRET` | cycle | The head is an xRET (MRET, SRET, or DRET), or the FSM is in MRET execute |
| 56 | 14 | `COMMIT_BLOCKED_TRAP` | cycle | The head has an exception, or the FSM is in the trap wait state |

### Wrapper 57–62: FU back-pressure

Sources: RS `fu_ready` and `empty` status and the MEM `fu_cdb_adapter`.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 57 | 15 | `INT_BACKPRESSURE` | cycle | The INT RS is not empty while its FU is not ready (issue blocked downstream) |
| 58 | 16 | `MUL_BACKPRESSURE` | cycle | Same, MUL RS. MUL and DIV share the muldiv shim, so there is no separate DIV counter |
| 59 | 17 | `MEM_RESULT_BACKPRESSURE` | cycle | The MEM FU has a valid result while the MEM CDB adapter still holds an earlier one awaiting a CDB grant |
| 60 | 18 | `FP_ADD_BACKPRESSURE` | cycle | Same as 57, FP RS |
| 61 | 19 | `FMUL_BACKPRESSURE` | cycle | Same as 57, FMUL RS |
| 62 | 20 | `FDIV_BACKPRESSURE` | cycle | Same as 57, FDIV RS |

### Wrapper 63–66: memory / queue activity

Sources: `store_queue.sv`, `load_queue.sv`.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 63 | 21 | `MEM_DISAMBIGUATION_WAIT` | cycle | A load's SQ check is valid but not all older store addresses are known yet |
| 64 | 22 | `SQ_COMMITTED_PENDING` | cycle | The SQ holds committed stores not yet written to memory |
| 65 | 23 | `SQ_MEM_WRITE_FIRE` | event | The SQ launched a store write to memory |
| 66 | 24 | `LQ_MEM_READ_FIRE` | event | The LQ launched a load read on the memory port |

### Wrapper 67–75: occupancy sums

Each adds the structure's current entry count every cycle. Average occupancy
is the delta divided by the elapsed cycles.

| Idx | Local | Name | Type | Adds each cycle |
|-----|-------|------|------|-----------------|
| 67 | 25 | `ROB_OCCUPANCY_SUM` | sum | ROB entry count |
| 68 | 26 | `LQ_OCCUPANCY_SUM` | sum | LQ entry count |
| 69 | 27 | `SQ_OCCUPANCY_SUM` | sum | SQ entry count |
| 70 | 28 | `INT_RS_OCCUPANCY_SUM` | sum | INT RS entry count |
| 71 | 29 | `MUL_RS_OCCUPANCY_SUM` | sum | MUL RS entry count |
| 72 | 30 | `MEM_RS_OCCUPANCY_SUM` | sum | MEM RS entry count |
| 73 | 31 | `FP_RS_OCCUPANCY_SUM` | sum | FP RS entry count |
| 74 | 32 | `FMUL_RS_OCCUPANCY_SUM` | sum | FMUL RS entry count |
| 75 | 33 | `FDIV_RS_OCCUPANCY_SUM` | sum | FDIV RS entry count |

### Wrapper 76–83: L0 cache, widen-commit, head-load split

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 76 | 34 | `LQ_L0_HIT` | event | A load completed through the L0 cache |
| 77 | 35 | `LQ_L0_FILL` | event | An L0 line was filled from a memory response |
| 78 | 36 | `HEAD_AND_NEXT_DONE` | cycle | Commit fired while the entry behind the head was also valid and done; an upper bound on 2-wide retirement |
| 79 | 37 | `HEAD_WAIT_LOAD_OUTSTANDING` | cycle | `HEAD_WAIT_MEM_LOAD` with an LQ memory response in flight (real memory latency) |
| 80 | 38 | `HEAD_WAIT_LOAD_NO_OUTSTANDING` | cycle | `HEAD_WAIT_MEM_LOAD` with no memory response in flight (split by 84–88) |
| 81 | 39 | `HEAD_PLUS_ONE_DONE` | cycle | The entry behind the head is valid and done, whether or not commit fires (no full flush active). 81 − 78 measures finished work waiting behind a stalled head |
| 82 | 40 | `COMMIT_2_OPPORTUNITY` | event | The full 2-wide commit gate passed: commit firing, head+1 done, hazard exclusions clear |
| 83 | 41 | `COMMIT_2_FIRE_ACTUAL` | event | A 2-wide commit fired: 82 gated by the slot-2 accept input, which `cpu_ooo` holds high except while a debug single step is armed, so outside single-step 83 = 82 |

The L0 hit rate is 76 / (76 + 66), and 79 + 80 = 46.

### Wrapper 84–93: head-load decomposition

Source: `load_queue.sv` head-load diagnostics. Every row also requires
`HEAD_WAIT_MEM_LOAD` with no memory response in flight. Counters 84–88 are
sub-buckets of 80, and 89–93 partition 86.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 84 | 42 | `HEAD_LOAD_ADDR_PENDING` | cycle | The head load is in the LQ but its address is not computed yet (waiting on rs1 or MEM_RS) |
| 85 | 43 | `HEAD_LOAD_SQ_DISAMBIG` | cycle | The address is known, but the load waits on SQ disambiguation |
| 86 | 44 | `HEAD_LOAD_BUS_BLOCKED` | cycle | Ready to issue, but blocked by the bus, arbitration, or the pipeline (split by 89–93) |
| 87 | 45 | `HEAD_LOAD_CDB_WAIT` | cycle | The data is in the LQ, waiting to enter the CDB stage |
| 88 | 46 | `HEAD_LOAD_POST_LQ` | cycle | The LQ entry is already freed; the result is in the CDB pipeline on its way to the ROB |
| 89 | 47 | `HEAD_LOAD_BB_ISSUED` | cycle | Bus-blocked: the load has issued, and its response was accepted but its entry has not cleared |
| 90 | 48 | `HEAD_LOAD_BB_BUS_BUSY` | cycle | Bus-blocked: the memory bus is busy |
| 91 | 49 | `HEAD_LOAD_BB_AMO` | cycle | Bus-blocked: an AMO in the LQ has not finished (approximate: any unfinished AMO counts) |
| 92 | 50 | `HEAD_LOAD_BB_SQ_WAIT` | cycle | Bus-blocked: in the `sq_check` stage, before phase 2 |
| 93 | 51 | `HEAD_LOAD_BB_STAGING` | cycle | Bus-blocked: everything else (before `sq_check` capture, a pending response drop, and similar; split by 102–105) |

### Wrapper 94–97: head-INT decomposition

Source: the INT RS head-query port. These partition 43 by where the head's
operation is.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 94 | 52 | `HEAD_INT_OPERAND_WAIT` | cycle | The head operation is in the INT RS with operands not yet ready |
| 95 | 53 | `HEAD_INT_RS_READY_NOT_ISSUED` | cycle | It is in the RS with its operands ready, waiting to be picked or being picked this cycle (the entry leaves the RS on the issue edge) |
| 96 | 54 | `HEAD_INT_STAGE2` | cycle | It has left RS storage and sits in the RS's stage-2 issue register |
| 97 | 55 | `HEAD_INT_POST_RS` | cycle | It has left the RS entirely and is in the FU or CDB path |

### Wrapper 98–105: widen-commit blocker taxonomy + staging catch-all split

Sources: `reorder_buffer.sv` (98–101) and `load_queue.sv` (102–105).
Counters 98–101 count only cycles in which commit fires and head+1 is valid
and done, and they partition the hazard-blocked gap:
98 + 99 + 100 + 101 = 78 − 82. Counters 102–105 partition 93.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 98 | 56 | `COMMIT_2_BLOCKED_HEAD_SERIAL` | cycle | The head fails the 2-wide check: a serializing operation, an exception, or a mispredicted branch |
| 99 | 57 | `COMMIT_2_BLOCKED_NEXT_SERIAL` | cycle | Head+1 is a serializing operation (CSR, FENCE, FENCE.I, WFI, xRET, AMO, LR, SC) or has an exception, and is not a branch |
| 100 | 58 | `COMMIT_2_BLOCKED_NEXT_BRANCH_MISPRED` | cycle | Head+1 is a mispredicted branch, including one early recovery already handled |
| 101 | 59 | `COMMIT_2_BLOCKED_NEXT_BRANCH_CORRECT` | cycle | Head+1 is a branch with no misprediction that the gate still refused. Correctly predicted branches can retire in slot 2, so this should stay near 0; a steady nonzero count points to a problem in slot-2 branch retirement |
| 102 | 60 | `HEAD_LOAD_BBS_OTHER_IN_STAGING` | cycle | `HEAD_LOAD_BB_STAGING`, and the single `sq_check` staging register holds a different load (the cost of one staging pipe) |
| 103 | 61 | `HEAD_LOAD_BBS_LAUNCH_GATED` | cycle | `HEAD_LOAD_BB_STAGING`, and the head load is staged with phase 2 armed but its launch is still gated (response-drop window, launch qualifiers) |
| 104 | 62 | `HEAD_LOAD_BBS_SLOW_OUTSTANDING` | cycle | `HEAD_LOAD_BB_STAGING`, staging is free, and the LQ's cached-launch hold is set. Every row here also requires no memory response in flight, so the hold can only come from the router holding a cached response |
| 105 | 63 | `HEAD_LOAD_BBS_CAPTURE_GAP` | cycle | `HEAD_LOAD_BB_STAGING`, staging is free, and a cached slot is available, but the head load has not been captured yet (a selector or capture-recycle bubble) |

### Cache hierarchy 106–129: cache traffic, fetch stalls, miss latency, concurrency

Sources: the registered event bundle from each `frost_cache` instance (L1I,
L1D, and L2) and the fetch-miss stall from `fetch_provider.sv`. Each is
registered at its source, so it lags the cache or fetch state it observes by a
cycle, on top of the counter's own increment register. Totals and snapshot
deltas are unaffected.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 106 | 0 | `L1I_ACCESS` | event | A request fires at the L1I upstream port (`i_up_req_valid && o_up_req_ready`), for the currently needed line or the fetch provider's next-line prefetch |
| 107 | 1 | `L1I_HIT` | event | An L1I access hits at the tag stage |
| 108 | 2 | `L1I_MISS` | event | An L1I access misses at the tag stage |
| 109 | 3 | `L1I_WRITEBACK` | event | A counted miss evicts a dirty L1I victim (counted at the tag decision, not when the writeback leaves). The L1I is read-only, so this is normally 0 |
| 110 | 4 | `L1D_ACCESS` | event | A demand request fires at the L1D upstream port |
| 111 | 5 | `L1D_HIT` | event | An L1D access hits at the tag stage |
| 112 | 6 | `L1D_MISS` | event | An L1D access misses at the tag stage |
| 113 | 7 | `L1D_WRITEBACK` | event | A counted miss evicts a dirty L1D victim (counted at the tag decision, not when the writeback leaves) |
| 114 | 8 | `L2_ACCESS` | event | A request fires at the L2 upstream port from the L1s, the page-table walker, or the DMA sequencer: L1I fills and prefetches, L1D fills, walker reads, DMA traffic, and dirty-victim writebacks |
| 115 | 9 | `L2_HIT` | event | An L2 access hits at the tag stage |
| 116 | 10 | `L2_MISS` | event | An L2 access misses at the tag stage |
| 117 | 11 | `L2_WRITEBACK` | event | A counted miss evicts a dirty L2 victim (counted at the tag decision, not when the writeback leaves) |
| 118 | 12 | `L1I_FETCH_MISS_STALL` | cycle | Fetch is in the cached tier, its window is not ready, and an L1I miss is outstanding (any miss, including a next-line prefetch). Pipeline stalls, low-BRAM fetch, fills discarded by `fence.i`, and prefetch misses behind a ready window do not count |
| 119 | 13 | `L1D_MISS_CYCLES_SUM` | sum | The number of L1D miss-status slots in use this cycle (`miss_outstanding`, `cache_perf_pkg::MissOutstandingBits` wide, at most `NUM_MSHR`) |
| 120 | 14 | `L2_MISS_CYCLES_SUM` | sum | The number of L2 miss-status slots in use this cycle |
| 121 | 15 | `L1I_HIT_UNDER_MISS` | event | An L1I hit resolved while at least one L1I miss was outstanding |
| 122 | 16 | `L1D_HIT_UNDER_MISS` | event | Same, L1D |
| 123 | 17 | `L2_HIT_UNDER_MISS` | event | Same, L2 |
| 124 | 18 | `L1D_SLOT_FULL_STALL` | cycle | The L1D tag stage held a miss because every miss-status slot, or every writeback slot a dirty victim needed, was busy |
| 125 | 19 | `L2_SLOT_FULL_STALL` | cycle | Same, L2 |
| 126 | 20 | `L1D_CONFLICT_STALL` | cycle | The L1D tag stage held a request because of a line in transition: a pending miss at its index that it could neither merge into nor wait on, or, for a store hit, a copy of its line still in a writeback slot |
| 127 | 21 | `L2_CONFLICT_STALL` | cycle | Same, L2 |
| 128 | 22 | `L1D_MISS_OVERLAP_CYCLES` | cycle | Two or more L1D miss-status slots were in use |
| 129 | 23 | `L2_MISS_OVERLAP_CYCLES` | cycle | Two or more L2 miss-status slots were in use |

Access accounting is an exact partition:

```text
HIT + MISS = ACCESS
```

`ACCESS` counts the request at the upstream port, and `HIT` or `MISS` counts
its tag decision later, so their pulses need not line up in a given cycle.
Once every accepted request has resolved, the totals satisfy the identity
exactly. The hit rate is `HIT / ACCESS`.

Maintenance traffic and coherence probes are not accesses: the reset tag
sweep, the L1D `fence.i` writeback-all walk, the L1I invalidate-all walk, and
probes add nothing to `ACCESS`, `HIT`, or `MISS`. `WRITEBACK` counts only
dirty victims evicted by counted misses. L1I accesses, hits, and misses, and
the L2 traffic they cause, include next-line prefetches;
`L1I_FETCH_MISS_STALL` counts only cycles in which the fetch window is also
not ready. The maintenance marking crosses the L1 arbiter, so L1D walk traffic
and the victim writebacks it causes are excluded from the L2 counts as well.

`miss_outstanding` is the number of the cache's miss-status slots in use,
not counting maintenance. A miss that allocates takes a slot when its
allocation lands and releases it once its fill has been written and answered.
A request that merges into or waits on an in-flight miss to the same line
counts in `MISS` but takes no slot. The miss sums integrate the slot count over
time, so dividing by the miss count gives slot-cycles per miss:

```text
L1D_MISS_CYCLES_SUM / L1D_MISS
L2_MISS_CYCLES_SUM  / L2_MISS
```

When every miss allocates its own slot, this is the average miss latency in
cycles. Merged and waiting requests pull the quotient below the latency of the
misses that allocate.

The cache unit benches also build the hierarchy without an L2 (`HAS_L2=0`).
There the L2 event bundle is tied to 0, so every L2 counter (114–117, 120,
123, 125, 127, 129) reads 0. Full-system builds always include the L2
(`HAS_L2=1`). With `ENABLE_CACHED_TIER=0`, all cache counters read 0.

## Using the counters from software

`sw/lib/include/tomasulo_profile.h` wraps the CSR protocol;
`sw/lib/src/tomasulo_profile_cache.c` holds the cache-counter reads and
report.

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

Before its first capture, a snapshot object must be zero-initialized, passed
to `tomasulo_profile_init_snapshot()`, or bound with
`tomasulo_profile_bind_cache_counters()`. A capture preserves the binding
field across samples, so an uninitialized automatic object would carry a
garbage value that later gets used as the cache-counter array address.

`tomasulo_profile_take_snapshot()` writes 1 to `mperfctl`, records
`rdcycle64()` and `rdinstret64()`, then reads indices 0–105 through `mperfsel`,
`mperfdata`, and `mperfdatah`.

`tomasulo_profile_read_cache_pair()` reads the current (end) and preceding
(start) cache snapshots into the two bound 24-entry arrays. It reads only the
counters `mperfcount` reports and zeroes the rest, so a build without the full
cache bank cannot leave stale values there, and the report prints "n/a"
instead of differences of counters that do not exist. Call it after the end
snapshot and before the next one, which advances both cache banks. Reading the
cache counters only after the timed region keeps extra CSR reads out of the
code before it.

`tomasulo_profile_delta(&start, &stop, idx)` returns one counter's delta,
indexed by the `TOMASULO_PERF_*` enum.

`tomasulo_profile_print_report()` prints the full breakdown: front-end
progress, the 2-wide width funnel, dispatch stalls, retirement, back-end
pressure, cache activity and hit rates, L1I fetch-miss stalls, average miss
latency, diagnostics, and average occupancy, with raw hex values and
percentages. In the tree, `sw/apps/coremark` (`core_portme.c`) snapshots
around the timed region and prints the full report, and `sw/apps/tomasulo_perf`
prints a brief report for each micro-benchmark.

## Verification

The `perf_counter_aggregator` cocotb bench checks event counting, snapshots,
the preceding cache bank, and out-of-range selects; `perf_csr_half` checks the
CSR read path against a plain full-width read. `perf_off_test` and the
`csr_file` task `bmc_perf_off` check the build without counters. Cache benches
check hit and miss accounting, maintenance exclusion, and zero L2 counters in
the L1-only configuration.

See the [test runner](../../../../../../tests/README.md) for commands and the
[formal guide](../../../../../../formal/README.md) for proof scope and assumptions.
