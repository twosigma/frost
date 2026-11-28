# CoreMark front-end calibration

BRAM CoreMark now replays the binary-bound instruction stream captured in the
same RTL run as the aggregate calibration events. The measured
comparison passes the unchanged **10% IPC tolerance**:

| Measurement | Cycles | Retired instructions | IPC | Replay / RTL IPC minus 1 |
|---|---:|---:|---:|---:|
| RTL after #595 | 201,392 | 226,801 | 1.1262 | — |
| Former synthetic `coremark_bram` | 3,219 | 3,128 | 0.9717 | -13.71% |
| Binary-bound replay | 183,450 | 226,801 | 1.2363 | +9.78% |

The RTL was captured with the CoreMark shard's BRAM configuration, startup
sweep, coverage disabled, one simulator thread, and
`46029156161-test-verilator-0` as the startup, random-start and DDR seed.
Both CoreMark and its profiling test passed, including startup checks.
The image reports Verilator 5.054, cocotb 2.1.0 and GCC 16.2.0.
The checked baseline records the full capture and binary identities.

## Why the synthetic feed could not explain #595

The earlier investigation at `396b4b44b` reproduced CI run 46029156161,
job 140659524095. The analytical workload had not changed since `a78866157`,
yet its gap moved from -8.38% on `5455aacf6` to -13.71% after the RTL's
decoupled front end landed. Its CoreMark instruction lines were all ready
before execution. Setting branch recovery to zero changed neither its
3,219 cycles nor its IPC. There was no modeled fetch delay to remove.

That workload was a pressure pattern, not the compiled program. Aggregate
dispatch/retire/AXI records could not supply the missing architectural
dependencies, instruction lengths, data addresses or prediction decisions.
The replacement changes the workload evidence and represents front-end
structure explicitly; it does not claim that #595 alone speeds up the old
idealized feed. The synthetic DDR `coremark` remains a separate sweep workload.

## Instruction evidence and CI cost

`verif/cocotb_tests/instruction_trace.py` observes production allocation and
retirement, rather than substituting TestRIG's injected instruction platform.
It associates decoded packets by ROB tag, checks bytes against executable ELF
segments, follows architectural integer register writes before the window,
and writes each retired instruction's PC, original bytes/length, sources,
destination, resolved address/size and branch successor. Slot-2 addresses see
slot-1 writeback. Wrong-path allocations are discarded by retirement.

Branch annotations record F0 predictions, PD direction/backing/ITTAGE
redirects and execution correction, including early recovery. Annotations
follow accepted decode bundles before ROB allocation; producer and allocation
checks require the final prediction to agree with the ID packet.
The capture contains 4,195 PD redirects and 1,485 execution corrections;
the aggregate commit-only misprediction counter is 35 and must not stand in
for early recoveries.

CI recaptures in the existing simulation instead of storing a full versioned
stream. This follows compiler, layout and predictor changes without a
second simulation. The stream is about 1.9 MiB compressed for 226,801
instructions. CI retains it with the manifest, aggregate events, counters
and comparison as a three-day artifact. ELF and image SHA-256 hashes bind
the evidence to the binary; the manifest also hashes the compressed stream.
The [separate instruction contract](instruction_capture.md) rejects
truncation, discontinuous PCs, invalid operands, and identity mismatches.

## Front-end structure

`fetch_frontend.py` follows these production rules:

- `if_stage.sv` and `fetch_parcel_queue.sv`: 16 halfword parcels, eight
  metadata entries, registered stop at eight parcels or seven windows,
  with space for the arriving window and one in flight. Metadata remains
  owned until the last parcel of its window drains. Flush clears stop too.
- F0 has its own cursor, independent of decode stall. Eight-byte windows
  start on a word boundary; halfword-offset entry supplies three parcels.
  Taken F0 predictions truncate the window and select the next target.
  A spanning native instruction retains its first parcel across windows;
  a spanning taken branch consumes its tail before taking its target.
- F1 checks provider epoch and served-word identity. Data and synchronous
  prediction lookup overlap. A miss retains the prediction and accepts
  returning data on that cycle, without paying a second predictor stage.
- Drain combines queued and arriving parcels, including zero-cycle empty
  and partial bypass. It issues up to two instructions/four parcels;
  control flow ends slot 1's bundle and serializing operations cannot start
  slot 2. PD/ID feed an actual bounded decoded-bundle queue.
- `fetch_pc_decoupled.sv` arms 1..5 prioritize trap/xRET, fence, execution,
  PD, then F1 validation. Provider retarget is registered. The first four
  clear fetch parcels/F1; PD preserves its branch and older decoded work.
  F1 tag recovery retries the same window, preserving older parcels;
  false-BTB recovery retains validated bytes and resteers younger fetch.

Recorded predictions supply decisions, not observed cycle durations.
Branch recovery waits for the replayed dependency graph. Provider latency
and pipeline stages determine refill delay. CoreMark's BRAM provider has
one-cycle window service; the directed provider tests exercise longer fills.

## Scalar execution needed by the real stream

Using real dependencies exposed two shortcuts in the pressure generators.
They had treated the L0 array's combinational lookup as a one-cycle dependent
load and every arithmetic operation as one cycle. Replay uses the existing
directed resident-chase measurement of three cycles per L0-dependent load.
`reservation_station/README.md` and `reservation_station.sv` specify a
registered stage between selection and functional-unit launch. With the
registered CDB, a combinational ALU takes two selection-to-wakeup cycles.
`multiplier.sv` has six launch-to-result stages; including RS stage 2 gives
seven. `int_muldiv_shim.sv`'s word multiplier and `cl_multiplier.sv` have
three stages, giving four from selection. These are source/measurement
constraints, not an IPC multiplier or a fitted memory-latency reduction.

Replay also follows registered dispatch done repair. The RAT returns a live
producer's tag even after that producer completes. Dispatch registers the tag;
one cycle later the station captures the ROB value. INT/MUL/MEM all disable
`ISSUE_REPAIR_BYPASS`, so selection starts in the second cycle after dispatch.
A dispatch-cycle CDB match has the same deferred delivery. A resident CDB
match still bypasses into selection, and already-retired sources do not need
repair. These rules follow `reservation_station/README.md` and
`tomasulo_wrapper.sv`'s indexed repair wiring; the directed tests distinguish
all four situations. The corrected instruction stream without this behavior
was still +10.90% high, and was rejected without refreshing the baseline.
The remaining scalar correction restricts branches to integer issue port 0;
port 1 accepts only non-branches. Together these source-defined rules produce
183,450 cycles and the passing +9.78% comparison. The replay still uses the
existing approximate station arbitration and shared arithmetic resources;
it does not claim a full implementation of the RTL backend.

The controlled comparisons use the same corrected instruction stream:

| Scalar replay rules | Cycles | IPC gap | Result |
|---|---:|---:|---|
| Execution stages, without registered repair or branch-port restriction | 181,598 | +10.90% | Rejected |
| Add registered operand repair | 182,433 | +10.39% | Rejected |
| Add branch issue-port restriction | 183,450 | +9.78% | Pass |

The [first rejected replay](../results/coremark_bram_calibration/without_scalar_rules.json)
and [repair-only comparison](../results/coremark_bram_calibration/with_operand_repair.json),
followed by the [passing comparison](../results/coremark_bram_calibration/with_scalar_rules.json),
retain the measured figures and implementation hashes. The
[original synthetic failure](../results/coremark_bram_calibration/before_synthetic.json)
preserves the -13.71% starting point.

The calibration keeps its existing 512-entry L0 and measured ten-cycle
local-BRAM read configuration. Synthetic workloads retain their established
abstractions and result fixtures. Replay reports its distinct execution
assumptions in the comparison record.

## Validation and remaining limits

`tests/test_perf_frontend.py` checks run-ahead under decode backpressure,
parcel and metadata stop/capacity, empty and partial bypass, compressed and
spanning instructions, predicted taken paths, all redirect classes and their
priority, stale provider epochs and tags, false BTB validation, and refill
overlapping prediction. It also checks scalar stage constants and the
three-cycle dependent L0 chase. `tests/test_instruction_trace.py` checks
binary/manifest/window binding, architectural renaming, same-cycle register
writes, PD annotation ownership/flush, and malformed/truncated rejection.

The replay cases correspond to existing production fetch-stage checks in
`verif/cocotb_tests/if_stage/test_if_stage.py`:

| Behavior | RTL directed case |
|---|---|
| Run-ahead and registered queue headroom | `test_stall_buffers_in_parcel_queue_and_asserts_stop_fetch`, `test_parcel_queue_wraparound_and_headroom_stress` |
| Empty and partial bypass, compressed and spanning instructions | `test_zero_cycle_empty_bypass_native_pair`, `test_compressed_four_parcel_window_and_queue_draining`, `test_spanning_32bit_instruction_and_partial_bypass` |
| Predicted taken flow and spanning branches | `test_fast_btb_taken_prediction_and_truncation`, `test_spanning_btb_branch_fetches_second_word_then_steers` |
| Trap/xRET, fence, execution and PD redirects | `test_trap_mret_fence_ex_and_pd_redirect_pulse_both_retargets` |
| F1 false hits and stale provider tags | `test_false_btb_interior_halfword_triggers_resteer`, `test_served_word_tag_mismatch_triggers_f1_resteer` |
| Refill overlapping prediction | `test_fetch_gap_and_collapsed_lead_accept`, `test_collapsed_fetch_trap_hold_pause_preserves_fresh_prediction` |

The recorder's queue-lineage test additionally holds a producer under
backpressure and allocates an older branch at the same PC on the cycle a
younger PD override enters ID. Matching redirects by PC alone fails this case.

Only the architectural path has instruction semantics. Incorrect predictions
stop useful fetch until correction; wrong-path execution and cache pollution
are omitted. The replay starts with empty pipeline/data caches at the window
boundary while recorded predictor decisions include the RTL's warm-up. It
retains the existing approximate backend scheduler, store disambiguation
and memory ordering. F1 false-hit and stale-provider cases have directed
coverage, not a claim that every speculative validation event is reconstructed
from the retired stream. Unsupported trapping, FP/atomic and divider behavior
fails explicitly. This is a calibrated cycle approximation for scalar BRAM
CoreMark, not a cycle-exact frontend simulator or DDR calibration.

`run_calibration.py` checks current replay against current measured IPC and
updates `ci_baseline.json` only with `--refresh` after a passing comparison.
It requires the separate stream and manifest for `coremark_bram`, disallows
substituting `--model-run`, and checks that replay retired the same count.
The stored baseline alone cannot make a failing comparison pass.

## Reproducing the final comparison

The clean CI-style recapture used
`2a851a88c9b1f2c7c096e0e06f7b2279c0d18e4a` and reproduced 183,450 replay
cycles against 201,392 RTL cycles. The
[final comparison](../results/coremark_bram_calibration/calibration.json),
[capture manifest](../results/coremark_bram_calibration/manifest.json), and
[aggregate counters](../results/coremark_bram_calibration/counters.json)
retain its binary/stream identities and measured figures. Full streams remain
in `tests/calibration/` locally and in the CI calibration artifact.

All verification ran in `frost:toolchain-linux` through the worktree-aware
`fr16.sh` wrapper, with `make clean` before cocotb builds. The CI selection was:

```bash
pytest tests/test_run_cocotb.py \
  -m 'cocotb and cocotb_real_program and not coremark_pro' \
  -k '[coremark] or [coremark_profile]' -v --durations=0
```

Both tests passed, followed by the workflow's `run_calibration.py` command
with `--instructions`. A separate passing invocation with `--refresh`
updated the baseline. Startup checks passed 33/33 seeds, 2/2 assertion
controls and 1/1 withheld control; the final recapture reused those successes
through the runner's simulator-binary/fixture/seed cache.

The performance, memory, workload, sweep, frontend, capture and contract
tests passed **194 tests**. Production cocotb directed checks passed **51
fetch-stage tests**, **one decoded-queue test**, and **42 reservation-station
tests**. Full pre-commit also passed on the implementation.

The complete CI Fast Python selection passed **4,460 tests**, with three
skipped and 1,947 deselected:

```bash
pytest tests -m 'not cocotb and not synthesis and not formal and not slow' \
  -v --durations=20
```

`pre-commit run --all-files` passed again with the archived evidence included.
Local transcripts are in `tests/calibration/`: `mainci9_verified_capture.log`,
`mainci9_verified_fast.log`, `mainci9_final_source_checks.log`,
`mainci9_rtl_frontend.log`, `mainci9_rtl_repair.log`, and
`mainci9_evidence_precommit.log`.
