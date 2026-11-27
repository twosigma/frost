# CoreMark front-end calibration gap

The BRAM CoreMark calibration in CI run 46029156161, job 140659524095,
fails its unchanged 10% IPC tolerance after the decoupled front end landed
in #595. The capture was reproduced at
`201e1911850c0185b96cd8f0fddce651666f08d0` (see the local manifest for the
full capture identity). The current synthetic workload has no modeled fetch
delay to remove, so adding the new RTL structures does not by itself explain
the missing performance.

The reproduction used the repository's Docker image, `make clean` in
`tests/`, and the CoreMark shard's pytest selection and environment from
`.github/workflows/ci.yml`: BRAM, startup sweep enabled, coverage disabled,
one simulator thread, and `46029156161-test-verilator-0` for the startup,
random-start and DDR seeds. The manifest records Verilator 5.054, cocotb
2.1.0 and GCC 16.2.0. `FROST_CALIBRATION_TEST=coremark` restricts capture to
the ordinary run; the profiling-enabled run has no IPC comparison.

| Measurement | Cycles | Retired micro-ops | IPC |
|---|---:|---:|---:|
| Reproduced RTL timed region | 201,392 | 226,801 | 1.1262 |
| Existing `coremark_bram`, seed 11, CI configuration | 3,219 | 3,128 | 0.9717 |
| Same workload with branch recovery set to zero | 3,219 | 3,128 | 0.9717 |

The model-to-RTL delta is **-13.71%**. Zero recovery is a diagnostic only;
it changes neither the default configuration nor the baseline. The original
run counts two recovery-stall cycles, no instruction-fetch stalls, 1,379
load-queue dispatch stalls and 4,824 local-load backpressure attempts.
The latter counts attempts by waiting loads, not distinct stalled cycles.

`run_calibration.py` reruns the workload and compares its current IPC with
the capture's IPC. Stored figures are historical comparisons, so merely
refreshing them cannot make this check pass.

## What the current model represents

In `frost_perf_model.py`, `run_workload` marks every CoreMark instruction line
ready before execution. `FrostPipeline._dispatch` then reads the next
micro-op directly from the workload, subject to dispatch width and back-end
resource limits. `_issue_fetches` looks ahead by
`decoded_queue_bundles * dispatch_width`; there is no decoded-bundle storage
or independent fetch/decode cursor. For this warm workload, that look-ahead
has no work to do. `_drain_cdb` implements a misprediction as a fixed dispatch
pause without squashing younger instructions.

Thus this is neither the old coupled RTL front end nor the new decoupled
one. Its front-end supply is already idealized. Giving the parcel queue an
IPC multiplier, increasing dispatch width, or reducing a memory latency to
compensate would not implement #595.

The workload itself is a 3,128-micro-op synthetic pressure pattern; the
capture records 226,801 retired micro-ops from the real binary. `MicroOp` has no
instruction length, opcode, predictor source or prediction target. The
synthetic PCs can skip instructions without an intervening branch. Neither
these fields nor architectural register dependencies and data addresses can
be recovered from the aggregate dispatch, retirement and AXI event records
that `run_calibration.py` consumes.

## RTL requirements for a future front-end implementation

The source at the reproduced revision establishes these requirements:

- `if_stage/if_stage.sv` instantiates `fetch_parcel_queue` with **16 halfword
  parcels**, **8 window metadata entries**, a parcel stop threshold of **8**
  and a metadata stop threshold of **7**. The queue module's standalone
  metadata threshold defaults to 6; the production instance overrides it.
  Backpressure is registered and leaves room for arriving and in-flight
  windows. Flush clears counts, pointers and the stop signal.
- F0 uses its own PC and can run while decode stalls. It looks up the fast
  BTB and direction tables alongside the backing BTB, TAGE, ITTAGE and
  translation. The sequential window is eight bytes starting on a word
  boundary; a halfword-offset entry has three useful parcels. Fast taken
  predictions steer F0 before decode.
- F1 holds the request and predictor metadata, checks the served-word tag,
  validates the predicted instruction boundary and type, and pushes up to
  four parcels with one metadata record. A false fast-BTB prediction or
  served-tag mismatch can resteer fetch. A spanning 32-bit instruction and
  spanning branch retain state across windows.
- Drain has zero-cycle empty and partial bypass and consumes one or two
  eligible instructions, up to four parcels, only when PD accepts. Pairing
  can cross a window boundary; instruction size, slot eligibility, faults
  and control flow constrain it. Capacity must be counted in parcels and
  windows, not just micro-ops.
- `fetch_pc_decoupled.sv` prioritizes trap/xRET, fence, execute recovery, PD
  redirect, then F1 validation resteer before ordinary F0 progress. The
  first four flush the parcel queue and F0/F1 state; F1 resteer has its own
  validation and recovery behavior. Provider retarget pulses are registered.
- A provider miss can overlap predictor lookup: `collapsed_armed_q` retains
  a prediction while waiting and permits acceptance on the returning data
  cycle. A refill must not unconditionally pay a second predictor stage.
  `fetch_provider.sv` supplies the served-word tags and retarget handshake;
  those stages and the provider's actual miss latency determine refill cost.

These are front-end structures to model and test, not evidence for a
numerical speedup over the current idealized CoreMark feed.

## Evidence needed to resolve the calibration

First supply an instruction stream tied to the compiled CoreMark binary:
dynamic PCs, instruction bytes/lengths, architectural source and destination
registers, resolved data addresses, and branch outcomes. Record or explicitly
model which prediction tier redirects each branch. Keep that instruction
evidence separate from the existing aggregate event contract.

Then validate the front end on directed cases: run-ahead under decode
backpressure, parcel and metadata saturation, empty/partial bypass,
compressed and spanning instructions, predicted taken flow, each redirect
class, stale provider replies, and refill with predictor overlap. Compare
the same workload and memory configuration before and after the change.
Refresh `ci_baseline.json` only from a passing measured comparison, retaining
the 10% tolerance. The current investigation leaves its values unchanged.

CI currently configures only `coremark` as a `calibration_test` in
`tests/ci_verilator.py`. The other archived calibration programs validate
event traces; they have no CI IPC tolerance comparison.

## Local reproduction results

Both selected cocotb tests (`coremark` and `coremark_profile`) passed,
including the seeded startup checks. The subsequent calibration command
failed with the exact CI delta and event counts: 140,047 dispatch records,
128,705 retirement records, 11,665 AXI requests and 11,664 AXI responses.
The capture's counters and manifest agreed with the trace; only the IPC
comparison failed.

The full Fast Python Tests selection passed in the same image: **4,408
passed, 3 skipped, 1,947 deselected**. This includes all **124** tests from
`tests/test_perf*.py`, covering the architectural self-test, the tests under
`perf-modeling/tests/`, stored result reproduction, exploration and sweeps,
memory behavior, instruction replay and the calibration comparator.

The trace, counters, manifest, comparison record (`coremark_before.json`),
capture script (`mainci9_capture.sh`) and diagnostic script/results
(`mainci9_diagnose.py`, `mainci9_diagnosis.json`) are retained in the
reproduction worktree's ignored `tests/calibration/` directory. Run the
scripts from the repository root inside the same Docker image. They leave
the checked-in baseline unchanged; the capture script deliberately exits
with the failing calibration command's status.
