# Performance counters

FROST exposes 97 profiling counters through machine-mode custom CSRs. This
directory holds `perf_counter_aggregator.sv`, which owns the counter index
space: it accumulates the 37 top-level (front-end / dispatch) counters,
muxes in the 60 back-end counters owned by
`../../tomasulo/tomasulo_wrapper/perf/tomasulo_perf_counters.sv`, and drives
the CSR read port. This README documents the whole counter space — both
blocks — plus the CSR access protocol and the software API.

## CSR interface

| CSR | Address | Access | Purpose |
|-----|---------|--------|---------|
| `mperfsel` | `0x7C0` | RW | Global counter index to read (0–96) |
| `mperfctl` | `0x7C1` | W | Bit 0 = snapshot capture (reads as 0) |
| `mperfdata` | `0xFC0` | R | Selected counter, low 32 bits |
| `mperfdatah` | `0xFC1` | R | Selected counter, high 32 bits |
| `mperfcount` | `0xFC2` | R | Total number of counters (97) |

How it works:

- **64-bit, free-running.** Each live counter adds 0/1 (occupancy counters
  add the occupancy value) every cycle and is cleared only by reset. The
  increment passes through one pipeline register (`perf_top_inc_q` /
  `perf_inc_q`), so a live total lags its event by a couple of cycles;
  snapshot deltas are exact.
- **Snapshot on demand.** Writing 1 to `mperfctl` bit 0 produces a
  single-cycle capture pulse (`csr_file.sv`). Both blocks copy every live
  counter into snapshot registers on that same cycle (each block fans the
  pulse out through four `max_fanout`-annotated bank copies, all driven by
  the one pulse), so the 97 values form one coherent snapshot.
- **Reads return the snapshot, never the live value.** Capture first, then
  read. Because `mperfdata`/`mperfdatah` both read the frozen 64-bit
  snapshot, the two halves are consistent without a hi/lo re-read loop.
- **Registered read path.** The selector and the read data are each
  registered inside the aggregator (plus the CSR-file read register), so a
  counter value reaches `mperfdata` two cycles after `mperfsel` changes.
  This is invisible to software: CSR instructions execute serially at
  commit, so a `csrw mperfsel` / `csrr mperfdata` pair can never outrun it.
- Selecting an out-of-range index (≥ 97) reads 0.

## Numbering contract

The global index space is two concatenated blocks:

- top-level block: `[0, PerfTopCounterCount)` = 0–36, owned by
  `perf_counter_aggregator.sv`;
- wrapper block: `[PerfTopCounterCount, PerfCounterCount)` = 37–96, owned by
  `tomasulo_perf_counters.sv`, addressed there by the wrapper-local index
  (global − 37).

`PerfWrapperBase = PerfTopCounterCount`, so **adding a top-level counter
shifts every wrapper index**. There is no global enum in `riscv_pkg`; four
places hold independent copies of the numbering and must be updated in
lockstep:

1. `hw/rtl/cpu_and_mem/cpu/cpu_ooo/perf/perf_counter_aggregator.sv`
   (`PerfTopCounterCount` + the `Perf*` localparams)
2. `hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/perf/tomasulo_perf_counters.sv`
   (`WrapperPerfCounterCount` + the wrapper-local `Perf*` localparams)
3. `sw/lib/include/tomasulo_profile.h`
   (`TOMASULO_PROFILE_COUNTER_COUNT` + the `tomasulo_profile_counter_idx` enum)
4. `verif/cocotb_tests/cpu_ooo/perf/test_perf_counter_aggregator.py`
   (`PERF_TOP_COUNTER_COUNT` / `PERF_COUNTER_COUNT` + the `PERF_*` constants)

## Counter reference

Column key: **Type** is `cycle` (increments every cycle a condition holds),
`event` (one increment per discrete occurrence), or `sum` (adds a value
every cycle). The **Name** column is the C enum from `tomasulo_profile.h`
with the `TOMASULO_PERF_` prefix dropped; the RTL localparams use the same
names in CamelCase (`PerfDispatchFire`, …).

### Top level 0–22: dispatch, stalls, serialization

Sources: `dispatch.sv` (`o_status`), `ooo_pipeline_control.sv`,
`frontend_validity_tracker.sv`, and the ROB commit/empty signals.

| Idx | Name | Type | Increments when |
|-----|------|------|-----------------|
| 0 | `DISPATCH_FIRE` | event | Slot-1 dispatch fired (`rob_alloc_req.alloc_valid`) — one per instruction dispatched through slot 1. |
| 1 | `DISPATCH_STALL` | cycle | Dispatch back-pressure: a valid bundle at the dispatch input could not fire (`dispatch_status.stall`). |
| 2 | `FRONTEND_BUBBLE` | cycle | No instruction at the dispatch input with nothing else to blame: not reset, not flushing, no post-flush holdoff, no dispatch stall, no CSR or control-flow serialization — a pure fetch bubble. |
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
| 22 | `PRED_FENCE_INDIRECT` | cycle | Same, unpredicted indirect control flow (JALR etc.). |

Notes:

- 7–16 are each gated on a valid slot-1 instruction that actually needs the
  resource; several can fire in the same cycle, so they overlap rather than
  partition counter 1. Cycles where only slot-2 blocks the bundle count in
  1 but in none of 7–16 — they land in 32–36 instead.
- 20–22 are one-hot per cycle (classifier priority: indirect > JAL >
  branch, ID over PD) and only fire while the prediction fence is pending.

### Top level 23–36: 2-wide width funnel

Sources: `if_stage.sv` `o_width_events` / `instruction_aligner.sv`
`o_slot2_kill_*` (23–28) and `dispatch.sv` `o_status.slot2_*` (29–36).

| Idx | Name | Type | Increments when |
|-----|------|------|-----------------|
| 23 | `IF_DELIVER1` | event | Accepted IF→PD handoff carrying a real slot-1 instruction (one per handoff, stall-qualified). |
| 24 | `IF_DELIVER2` | event | That handoff also carried a real slot-2 instruction (subset of 23). |
| 25 | `IF_S2KILL_S1_32BIT` | event | 1-wide handoff: slot-1 is a native 32-bit instruction. |
| 26 | `IF_S2KILL_S1_CTRL` | event | 1-wide handoff: slot-1 is compressed control flow (bundle terminates at slot 1). |
| 27 | `IF_S2KILL_S2_CLASS` | event | 1-wide handoff: the slot-2 candidate starts an op class excluded from slot 2 (native CSR / MISC-MEM / AMO / FP-compute). |
| 28 | `IF_S2KILL_TRANSIENT` | event | 1-wide handoff: aligner buffer / BRAM transient state. |
| 29 | `DISPATCH_FIRE_2` | event | Slot-2 dispatch fired (`rob_alloc_req_2.alloc_valid`) — one per instruction dispatched through slot 2. |
| 30 | `DISPATCH_SLOT2_PRESENT` | cycle | A real slot-2 instruction is at the dispatch input. |
| 31 | `DISPATCH_SLOT2_FP_SERIALIZED` | cycle | Slot-2 instruction present but targets an FP-compute RS (FP / FMUL / FDIV); these never dispatch in slot 2. |
| 32 | `DISPATCH_SLOT2_BLOCK_S1_BRANCH` | cycle | Slot-2 alone holds the bundle: slot-1 is a branch/jump (bundle terminates). |
| 33 | `DISPATCH_SLOT2_BLOCK_ROB_FULL2` | cycle | Slot-2 alone holds the bundle: no ROB room for 2. |
| 34 | `DISPATCH_SLOT2_BLOCK_RS_FULL2` | cycle | Slot-2 alone holds the bundle: slot-2's RS room check failed. |
| 35 | `DISPATCH_SLOT2_BLOCK_LSQ_FULL2` | cycle | Slot-2 alone holds the bundle: LQ/SQ room check for slot-2 failed. |
| 36 | `DISPATCH_SLOT2_BLOCK_CKPT` | cycle | Slot-2 alone holds the bundle: no checkpoint free for a slot-2 branch. |

Ratios and partitions:

- IF 2-wide rate = 24 / 23. The kill causes 25–28 are mutually exclusive
  and partition the 1-wide handoffs (23 − 24).
- Dispatch 2-wide rate = 29 / 0; total dispatched instructions = 0 + 29.
- 32–36 all require `slot2_only_block` (slot-1 could have fired); the
  individual cause conjuncts can overlap when several room checks fail in
  the same cycle.

### Wrapper 37–46: ROB head-wait

Source: `reorder_buffer.sv` `o_perf_events`. All fire on cycles where the
ROB head is valid, not done, and no full flush is in progress; 38–46
partition 37 by the head's class (priority: branch, then AMO/LR, then
store, then RS type).

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 37 | 0 | `HEAD_WAIT_TOTAL` | cycle | ROB head valid but not done (waiting for its result). |
| 38 | 1 | `HEAD_WAIT_INT` | cycle | …and the head is an INT-RS op (not branch/store/AMO). |
| 39 | 2 | `HEAD_WAIT_BRANCH` | cycle | …and the head is a branch/jump. |
| 40 | 3 | `HEAD_WAIT_MUL` | cycle | …and the head is a MUL-RS op (MUL/DIV). |
| 41 | 4 | `HEAD_WAIT_MEM_LOAD` | cycle | …and the head is a MEM-RS op that is not a store or AMO — i.e. a load (INT or FP). |
| 42 | 5 | `HEAD_WAIT_MEM_STORE` | cycle | …and the head is a store (including FP stores and SC). |
| 43 | 6 | `HEAD_WAIT_MEM_AMO` | cycle | …and the head is an AMO or LR. |
| 44 | 7 | `HEAD_WAIT_FP` | cycle | …and the head is an FP-RS (FP add class) op. |
| 45 | 8 | `HEAD_WAIT_FMUL` | cycle | …and the head is an FMUL-RS op. |
| 46 | 9 | `HEAD_WAIT_FDIV` | cycle | …and the head is an FDIV-RS op. |

### Wrapper 47–51: commit blocked in the serializing FSM

Source: `reorder_buffer.sv`. All fire on cycles where the head is ready
(done) but commit is stalled by the serializing FSM, attributed by class.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 47 | 10 | `COMMIT_BLOCKED_CSR` | cycle | Head is a CSR op or the FSM is in CSR execute. |
| 48 | 11 | `COMMIT_BLOCKED_FENCE` | cycle | Head is FENCE/FENCE.I or the FSM is draining the SQ. |
| 49 | 12 | `COMMIT_BLOCKED_WFI` | cycle | Head is WFI or the FSM is in the WFI wait state. |
| 50 | 13 | `COMMIT_BLOCKED_MRET` | cycle | Head is MRET or the FSM is in MRET execute. |
| 51 | 14 | `COMMIT_BLOCKED_TRAP` | cycle | Head has an exception or the FSM is in the trap wait state. |

### Wrapper 52–57: FU back-pressure

Sources: RS `fu_ready`/`empty` status and the MEM `fu_cdb_adapter`.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 52 | 15 | `INT_BACKPRESSURE` | cycle | INT RS non-empty while its FU is not ready (issue blocked downstream). |
| 53 | 16 | `MUL_BACKPRESSURE` | cycle | Same, MUL RS. (MUL and DIV share the muldiv shim — there is no separate DIV counter.) |
| 54 | 17 | `MEM_RESULT_BACKPRESSURE` | cycle | MEM FU has a valid result while the MEM CDB adapter still holds a previous result pending a CDB grant. |
| 55 | 18 | `FP_ADD_BACKPRESSURE` | cycle | Same as 52, FP RS. |
| 56 | 19 | `FMUL_BACKPRESSURE` | cycle | Same as 52, FMUL RS. |
| 57 | 20 | `FDIV_BACKPRESSURE` | cycle | Same as 52, FDIV RS. |

### Wrapper 58–61: memory / queue activity

Sources: `store_queue.sv`, `load_queue.sv`.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 58 | 21 | `MEM_DISAMBIGUATION_WAIT` | cycle | A load's SQ disambiguation/forwarding check is valid but not all older store addresses are known yet. |
| 59 | 22 | `SQ_COMMITTED_PENDING` | cycle | SQ holds committed stores not yet drained to memory. |
| 60 | 23 | `SQ_MEM_WRITE_FIRE` | event | SQ issued a store write to memory (registered one-cycle pulse per write). |
| 61 | 24 | `LQ_MEM_READ_FIRE` | event | LQ launched a load read on the memory port (one pulse per launch). |

### Wrapper 62–70: occupancy sums

Each adds the structure's current entry count every cycle. Average
occupancy = delta / elapsed cycles.

| Idx | Local | Name | Type | Adds each cycle |
|-----|-------|------|------|-----------------|
| 62 | 25 | `ROB_OCCUPANCY_SUM` | sum | ROB entry count. |
| 63 | 26 | `LQ_OCCUPANCY_SUM` | sum | LQ entry count. |
| 64 | 27 | `SQ_OCCUPANCY_SUM` | sum | SQ entry count. |
| 65 | 28 | `INT_RS_OCCUPANCY_SUM` | sum | INT RS entry count. |
| 66 | 29 | `MUL_RS_OCCUPANCY_SUM` | sum | MUL RS entry count. |
| 67 | 30 | `MEM_RS_OCCUPANCY_SUM` | sum | MEM RS entry count. |
| 68 | 31 | `FP_RS_OCCUPANCY_SUM` | sum | FP RS entry count. |
| 69 | 32 | `FMUL_RS_OCCUPANCY_SUM` | sum | FMUL RS entry count. |
| 70 | 33 | `FDIV_RS_OCCUPANCY_SUM` | sum | FDIV RS entry count. |

### Wrapper 71–78: L0 cache, widen-commit, head-load split

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 71 | 34 | `LQ_L0_HIT` | event | Load completed via the L0 cache fast path. |
| 72 | 35 | `LQ_L0_FILL` | event | L0 line filled from a memory response. |
| 73 | 36 | `HEAD_AND_NEXT_DONE` | cycle | Commit fired while the entry behind head was also valid+done — upper bound on 2-wide retire. |
| 74 | 37 | `HEAD_WAIT_LOAD_OUTSTANDING` | cycle | `HEAD_WAIT_MEM_LOAD` with an LQ memory response in flight (real memory latency). |
| 75 | 38 | `HEAD_WAIT_LOAD_NO_OUTSTANDING` | cycle | `HEAD_WAIT_MEM_LOAD` with no memory response in flight (decomposed by 79–83). |
| 76 | 39 | `HEAD_PLUS_ONE_DONE` | cycle | Entry behind head valid+done, whether or not commit fires (not flushing). 76 − 73 = done work stacking up behind a stalled head. |
| 77 | 40 | `COMMIT_2_OPPORTUNITY` | event | The full 2-wide commit gate passed: commit firing, head+1 done, hazard exclusions clear. |
| 78 | 41 | `COMMIT_2_FIRE_ACTUAL` | event | A 2-wide commit actually fired (77 plus the master enable and the pending-write FIFO back-pressure term). 77 − 78 = throttled by FIFO pressure. |

Notes: L0 hit rate = 71 / (71 + 61). 74 + 75 = 41.

### Wrapper 79–88: head-load decomposition

Source: `load_queue.sv` head-load diagnostics. Every row is additionally
qualified by `HEAD_WAIT_MEM_LOAD` with no memory response in flight — 79–83
are sub-buckets of 75, and 84–88 further decompose 81 into mutually
exclusive causes.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 79 | 42 | `HEAD_LOAD_ADDR_PENDING` | cycle | Head load is in the LQ but its address is not yet computed (waiting on rs1 / MEM_RS). |
| 80 | 43 | `HEAD_LOAD_SQ_DISAMBIG` | cycle | Address known, blocked on SQ disambiguation. |
| 81 | 44 | `HEAD_LOAD_BUS_BLOCKED` | cycle | Ready to issue, blocked on bus / arbitration / pipeline (split by 84–88). |
| 82 | 45 | `HEAD_LOAD_CDB_WAIT` | cycle | Data ready in the LQ, waiting to enter the CDB stage. |
| 83 | 46 | `HEAD_LOAD_POST_LQ` | cycle | LQ entry already freed; result is in the CDB pipeline on its way to the ROB. |
| 84 | 47 | `HEAD_LOAD_BB_ISSUED` | cycle | Bus-blocked: request already issued, waiting for the response. |
| 85 | 48 | `HEAD_LOAD_BB_BUS_BUSY` | cycle | Bus-blocked: memory bus busy. |
| 86 | 49 | `HEAD_LOAD_BB_AMO` | cycle | Bus-blocked: an older AMO pending blocks the load. |
| 87 | 50 | `HEAD_LOAD_BB_SQ_WAIT` | cycle | Bus-blocked: in the sq_check stage but phase 2 not reached. |
| 88 | 51 | `HEAD_LOAD_BB_STAGING` | cycle | Bus-blocked: catch-all (pre-sq_check capture, drop-pending, etc.). |

### Wrapper 89–92: head-INT decomposition

Source: the INT RS head-query diagnostic port. Sub-buckets of 38, keyed on
where the head's op currently sits.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 89 | 52 | `HEAD_INT_OPERAND_WAIT` | cycle | Head op is in the INT RS with operands not yet ready. |
| 90 | 53 | `HEAD_INT_RS_READY_NOT_ISSUED` | cycle | In the RS and ready, but not picked for issue. |
| 91 | 54 | `HEAD_INT_STAGE2` | cycle | No longer in RS storage; parked in the RS's stage-2 issue register. |
| 92 | 55 | `HEAD_INT_POST_RS` | cycle | Left the RS entirely (not in stage 2 either); in the FU / CDB path. |

### Wrapper 93–96: widen-commit blocker taxonomy

Source: `reorder_buffer.sv`. All gated on commit firing with head+1
valid+done, so these four partition the hazard-blocked gap:
93 + 94 + 95 + 96 = 73 − 77.

| Idx | Local | Name | Type | Increments when |
|-----|-------|------|------|-----------------|
| 93 | 56 | `COMMIT_2_BLOCKED_HEAD_SERIAL` | cycle | Head itself is a serial op or a mispredicting branch (fails the head 2-wide check). |
| 94 | 57 | `COMMIT_2_BLOCKED_NEXT_SERIAL` | cycle | Head+1 is a serial op (CSR / FENCE / FENCE.I / WFI / MRET / AMO / LR / SC / exception), not a branch. |
| 95 | 58 | `COMMIT_2_BLOCKED_NEXT_BRANCH_MISPRED` | cycle | Head+1 is a branch that will flush. |
| 96 | 59 | `COMMIT_2_BLOCKED_NEXT_BRANCH_CORRECT` | cycle | Head+1 is a correctly predicted branch — no flush needed, only a BTB/RAS update from slot 2. |

## Using the counters from software

`sw/lib/include/tomasulo_profile.h` wraps the CSR protocol:

```c
#include "tomasulo_profile.h"

static tomasulo_profile_snapshot_t start, stop;

tomasulo_profile_take_snapshot(&start);
/* ... region of interest ... */
tomasulo_profile_take_snapshot(&stop);

tomasulo_profile_print_report("my region", &start, &stop);        /* full */
tomasulo_profile_print_brief_report("my region", &start, &stop);  /* 1 line */
```

- `tomasulo_profile_take_snapshot()` writes `mperfctl` bit 0, records
  `rdcycle64()` / `rdinstret64()`, then reads all `mperfcount` counters
  through `mperfsel` / `mperfdata` / `mperfdatah`.
- `tomasulo_profile_delta(&start, &stop, idx)` returns one counter's delta;
  the `TOMASULO_PERF_*` enum names the indices.
- `tomasulo_profile_print_report()` prints the full breakdown (front-end
  progress, the "2-wide width funnel" section, dispatch stalls, retirement,
  back-end pressure, diagnostic counters, average occupancies), with raw
  values in hex and percentages of elapsed cycles.

Users in the tree: `sw/apps/coremark` (`core_portme.c`) snapshots around
the timed region and prints the full report; `sw/apps/tomasulo_perf`
prints a brief report per micro-benchmark.

## Verification

`verif/cocotb_tests/cpu_ooo/perf/test_perf_counter_aggregator.py` unit-tests
the aggregator: per-counter increment conditions (including the width-funnel
events), snapshot capture and freeze-until-next-capture behavior, and the
top/wrapper counter select and data path.
