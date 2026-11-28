# CoreMark front-end calibration

BRAM CoreMark replays a binary-bound instruction stream captured alongside
aggregate RTL events. The revised comparison passes the unchanged **10% IPC
tolerance** at **+5.37% IPC**. Constants come from RTL structure or the existing
directed RTL load-chase measurements; no scale factor or fitted penalty is used.

| Comparison | RTL cycles | Replay cycles | Retired instructions | Replay / RTL IPC minus 1 |
|---|---:|---:|---:|---:|
| Reviewed implementation, previous capture | 201,392 | 183,450 | 226,801 | +9.78% |
| Reviewed implementation, fresh capture | 200,797 | 182,373 | 226,801 | +10.10% |
| Revised implementation, fresh capture | 200,797 | 190,556 | 226,801 | +5.37% |

The fresh capture uses RTL commit
`200f339eaf5996a5510cf4e0d96adbd4c22e576c`. It has 1,354 execute corrections,
3,526 PD direction annotations and 581 PD backing annotations. The earlier
capture had 1,485 execute corrections, so the two rows also include predictor
variation. Replaying the fresh stream with the reviewed sources gives
182,373 cycles (+10.10%); all fixes together add 8,183 cycles on that same
input and reduce the gap to +5.37%. This also confirms that the previous
0.22-point margin was insufficient for ordinary predictor variation.
The [same-capture comparison](../results/coremark_bram_calibration/same_capture_comparison.json)
records both source identities. The binary hashes and recorded predictions are retained with the
[comparison](../results/coremark_bram_calibration/calibration.json),
[manifest](../results/coremark_bram_calibration/manifest.json), and
[counters](../results/coremark_bram_calibration/counters.json).

## Review findings and RTL sources

All primary review findings were confirmed. The changes below remove both
optimistic omissions and artificial stalls; they were applied together before
checking the tolerance.

| Finding | Correction and source |
|---|---|
| Multiply omitted the registered CDB edge | `instruction_execution_cycles` now returns 8 for full-width multiply and 5 for word/carryless multiply. `riscv_pkg.sv` defines `MulPipeDepth=6`; `int_muldiv_shim.sv` defines `WordMulDepth=3`. Add one RS stage-2 edge and one `tomasulo_wrapper.sv` `cdb_bus_q` edge. `DIRECT_MUL=1` and `REGISTER_OUTPUT=0` avoid an additional adapter edge, not the CDB edge. |
| BRAM fetch misses were absent | `BramFetchProvider` models the 256-line direct cache with 32-byte lines (`frost_hart.sv` `uncached_fetch`, `NormalFetchBytes`, `NORMAL_FETCH_LINES`; `fetch_provider.sv` `DIRECT_LOOKUP`). Both words of an eight-byte window are checked, including line crossings. Two parity fill slots use IDs 34/35 and share `SocTopModel` with data traffic. Returning fills survive redirects; epochs reject stale publication. |
| Conditional branches used CDB lanes | Conditional branch completion and recovery now bypass CDB arbitration, following `int_alu_shim.sv` `i_issue_writes_cdb_hint`. JALR still writes its link through CDB. All 52,067 conditional branches take the separate path. |
| Partial dispatch and same-cycle free-to-allocate | Dispatch preflights the whole decoded bundle against registered ROB/station/LQ/SQ/checkpoint occupancy. A blocked second slot stalls both. `dispatch.sv` `slot2_can_fire`, `i_rob_full_for_2`, and station `full_for_2` implement this rule. Slot allocation uses the pre-issue valid vector. |
| Wrong INT_RS selection and lifetime | Lowest-index allocation/selection; port 0 scans all 16 slots, port 1 scans only the first 8 and excludes branches. Entries leave at issue. See `riscv_pkg.sv` `IntRsIssue2Window` and `reservation_station.sv` `alloc_idx`, `rs_valid`, `issue_fire`. |
| Shared multiply resources | Four-entry, single-port MUL_RS (`riscv_pkg.sv` `MulRsDepth`), plus `int_muldiv_shim.sv` four live credits and short/full multiply tracker collision exclusion. |
| JAL consumed INT_RS and CDB | JAL uses `RS_NONE`, completes its link at allocation, and launches recovery separately (`dispatch.sv`, `reorder_buffer.sv`, `early_misprediction_recovery.sv` `jal_q_valid`). |
| Checkpoint capacity and execution recovery | Twelve checkpoints, retained until retirement (`riscv_pkg.sv` `NumCheckpoints`, RAT checkpoint-free ports). Selection at T reaches stage 2 at T+1; registered `early_mispredict_active` redirects at T+2, independently of CDB. The following backend partial flush blocks another cycle. |
| Post-window VPI work | `CalibrationTrace.sample` returns immediately in `DONE`, before any commit or instruction reads. Warm-up shadow-register tracking still runs before the window. |
| Capture destination consistency and x0 noise | Capture compares decoded and committed nonzero integer destinations in both directions. It omits x0 sources and represents x0 destinations as null. Legacy streams with x0 remain readable. |
| Missing integration coverage | Fast tests exercise `run_instruction_stream`, `run_workload(..., instruction_trace=...)`, the real calibration CLI with `--instructions`, actual ELF64 program headers, compressed parcels, signed S immediates, branch/JAL/JALR retirement, and aggregate/instruction window alignment. |
| Stale baseline could pass tests | Tests now verify every recorded replay-source SHA-256 against the checked-out source, in addition to binary identity and the 10% gate. |
| Workstation path and artifact collision | Manifest stores the instruction basename. CLI evidence stores repository-relative paths or basenames, including for absolute arguments. Uploads name only the five evidence files and set `overwrite: true`. Documentation uses repository commands, without private harness or transcript references. |

The review's additional small edge cases are also addressed: parcel stop uses
post-pop parcel occupancy but pre-pop-plus-push metadata occupancy, as
`fetch_parcel_queue.sv` `stop_fetch_p`/`stop_fetch_np` specify; queued PD/F1
redirects advance surviving PD/ID work instead of freezing it; a producer
retiring on the dispatch edge still requires registered done-operand repair.

Two source details refine the review's suggested approximation:

- `early_backend_recovery_hold` itself equals `early_mispredict_pending` and
  lasts one cycle. The following `early_backend_recovery_pending` partial
  flush separately prevents dispatch/issue. Replay represents the two blocked
  phases, without describing the named hold signal as two cycles long.
- Five cycles is not the current complete BRAM wide-read service. In
  `soc_top.sv`, acceptance enters state 4; state 4 launches the synchronous
  instruction read; four state-1 cycles collect dwords; state 2 raises the
  response, giving seven acceptance-to-response cycles. Narrow fast reads
  and writes take two. State 3 returns to state 0 after the response handshake,
  adding one cycle before another local request is accepted. Provider miss
  selection and registered window publication add an edge on each side.
  Arbitration can extend these durations; no observed mean is substituted
  for the state machine.

## Data-path corrections and remaining approximations

The old ten-cycle dependent BRAM chase was incorrectly charged entirely as
local-port occupancy. CI now uses two cycles of local service plus eight
cycles for the remainder of that already measured ten-cycle chase
(8,026 cycles for 800 aliasing loads). The remainder is modeled outside the
port; this split preserves the directed measurement without turning an
end-to-end latency into bus occupancy. Its placement as return delay remains
an approximation of the intermediate LQ/router/result stages.

Local stores use the SoC handshake rather than the cached L1D launch interval.
Full aligned dword stores allocate L0, and partial stores update a resident
dword (`lq_l0_cache.sv` `store_update`). INT load wakeup requires room in its
early-token lane merge. MEM has a separate third pre-issue token, gated by
completion ownership; MUL receives registered CDB only
(`tomasulo_wrapper.sv` `int_issue_wakeup`, `mem_rs_pre_issue_raw_valid`,
`mem_rs_early_wakeup_enable`, `u_mul_rs`). The prior unconditional early ALU
wakeup was incorrect. A resident L0 dependent memory chain still takes the
measured three cycles. Trapping, floating-point, atomic and operand-dependent
divider instructions remain unsupported and fail explicitly.

Replay still describes only the architectural path. RTL dispatched 239,424
operations versus 226,801 retired: 12,623 extra operations (5.57% of useful
work) consume resources in RTL but are absent from replay. Wrong-path cache
pollution, speculative fetch requests, predictor validation traffic, exact
CDB arbitration and memory-station selection are not reconstructed. The
pipeline and data caches start empty at the window boundary. These differences
can have opposing effects; the residual cannot be assigned entirely to
wrong-path instructions from instruction counts alone.

| Diagnostic | Fresh RTL | Revised replay |
|---|---:|---:|
| Dispatch 0 / 1 / 2 cycles | 61,375 / 39,420 / 100,002 | 58,590 / 37,131 / 94,835 |
| Backend dispatch stall cycles | 48,067 | 39,173 |
| Mean ROB occupancy | 20.259 | 19.515 |
| BRAM fetch line requests | 555 | 471 |

The dispatch mix and occupancy are substantially closer than the reviewed
37,589 / 64,921 / 80,940 mix and 17.58 mean ROB occupancy. The residual is
**10,241 cycles**, with 4.63 percentage points of margin inside the gate.
The measured comparison is scoped to scalar BRAM CoreMark, not DDR fetch
accuracy or exact cycle equivalence. No constant was selected to reproduce
the review's estimated +6.72%.

## Capture and reproduction

The instruction recorder binds original bytes to executable ELF `PT_LOAD`
segments, decodes operands from expanded instructions, tracks both commit
slots from warm-up, and aligns prediction annotations through accepted decoded
bundles to ROB allocations. A stop-PC commit is included; later cycles perform
no instruction sampling. The fast window test verifies this even for calls
hundreds of thousands of cycles after `DONE`.

The real-program CI shard captures events, counters, manifest and compressed
instructions in its existing simulation. The standalone equivalent uses the
repository's pinned Docker image and cleans the simulation build first:

```bash
FROST_COCOTB_MEM_CONFIG=bram \
FROST_CALIBRATION_TEST=coremark \
FROST_CALIBRATION_TRACE_PATH=tests/calibration/coremark.jsonl \
FROST_CALIBRATION_COUNTERS_PATH=tests/calibration/coremark_counters.json \
FROST_CALIBRATION_MANIFEST_PATH=tests/calibration/coremark_manifest.json \
FROST_INSTRUCTION_TRACE_PATH=tests/calibration/coremark_instructions.jsonl.gz \
./scripts/frost.py pytest \
  -m 'cocotb and cocotb_real_program and not coremark_pro' \
  -k '[coremark] or [coremark_profile]' -v --durations=0

./scripts/frost.py run python3 perf-modeling/tools/run_calibration.py \
  --trace tests/calibration/coremark.jsonl \
  --instructions tests/calibration/coremark_instructions.jsonl.gz \
  --counters tests/calibration/coremark_counters.json \
  --manifest tests/calibration/coremark_manifest.json \
  --baseline perf-modeling/calibration/ci_baseline.json \
  --rtl-commit <capture-commit> --out tests/calibration/coremark_calibration.json
```

Add `--refresh` only after a passing comparison to update the stored figures
and source hashes. The baseline never substitutes for replaying the stream.
The [old synthetic failure](../results/coremark_bram_calibration/before_synthetic.json)
and [reviewed comparison](../results/coremark_bram_calibration/with_scalar_rules.json)
remain historical evidence. The synthetic DDR pressure workload and its
regenerated deterministic fixtures remain separate from instruction replay.

Verification results are recorded with the refreshed comparison. All checks
use the pinned image; the complete fast selection is
`pytest tests -m 'not cocotb and not synthesis and not formal and not slow'`.
