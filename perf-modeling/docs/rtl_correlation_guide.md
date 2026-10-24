# FROST Performance Model — RTL Correlation & Trace Extraction Guide

This document describes the methodology for capturing cycle-accurate microarchitectural and memory traces from FROST Verilator RTL simulations, validating trace contracts, and correlating hardware RTL measurements against the fast architectural performance model.

---

## 1. Overview & Objectives

The FROST performance model provides an ultra-fast (>100x trace replay, >7,000x analytical simulation) cycle-approximate simulator of the FROST platform (`platform_top` = `cpu_top` + `soc_top`). To ensure that architectural recommendations and design space exploration reflect actual hardware behavior, the model is calibrated directly against cycle-accurate Verilator RTL simulation traces.

Key objectives:
1. **Zero Intrusion**: Probes monitor RTL simulation state without perturbing DUT timing, changing clocking, or altering synthesizable RTL (`hw/rtl/`).
2. **Deterministic & Reproducible**: Every benchmark run records full provenance (`manifest.json` with commit SHA, binary checksums, compiler flags, seeds, and execution wall-time).
3. **Structured Trace Contract**: Simulation events are emitted as JSONL records adhering to a strict schema (`calibration/trace_schema.json`), validated automatically by `calibration/trace_contract.py`.

---

## 2. Trace Contract & Event Schema

Traces are formatted as line-delimited JSON (JSONL). The first line is always a `meta` event describing the simulation environment. Subsequent records document accepted handshakes and microarchitectural state on each simulation clock cycle.

### Standard Trace Events

| Event | Required Fields | RTL Observation Point | Purpose |
|---|---|---|---|
| `meta` | `version`, `commit`, `clock_frequency_hz` | Testbench initialization | Trace provenance & clock frequency |
| `dispatch` | `cycle`, `uops` | `dbg_rob_alloc_valid` & ready | Accepted dispatch / ROB allocations (1 or 2 uops) |
| `retire` | `cycle`, `uops` | `dbg_commit_valid` & ready | Accepted retirement / commit (1 or 2 uops) |
| `cache_request` | `cycle`, `cache`, `address`, `is_write`, `request_id` | L1I / L1D / L2 input | Cache access requests |
| `cache_response` | `cycle`, `cache`, `request_id`, `ok` | L1I / L1D / L2 output | Cache completion / data return |
| `mshr_allocate` | `cycle`, `cache`, `slot`, `line_address` | Cache MSHR entry allocation | Track miss concurrency & slot occupancy |
| `mshr_release` | `cycle`, `cache`, `slot` | Cache MSHR completion | Miss resolution |
| `axi_request` | `cycle`, `axi_id`, `address`, `is_write`, `bytes` | `o_axi_arvalid` / `o_axi_awvalid` | 512-bit (64-byte) single-beat AXI transactions |
| `axi_response` | `cycle`, `axi_id`, `ok` | `i_axi_rvalid` / `i_axi_bvalid` | AXI read/write completions from DDR/memory |
| `backpressure` | `cycle`, `resource`, `reason` | Stall signals (`dbg_dispatch_stall`, etc.) | Identifies specific architectural bottleneck cycles |

All cycle stamps represent CPU-clock cycles (not wall time).

---

## 3. How to Extract Traces from Verilator RTL

Trace extraction is integrated into the cocotb test harness (`verif/cocotb_tests/test_real_program.py`). When the target environment variables are set, the testbench activates the calibration monitors exclusively for the timed region of the benchmark.

### Example: CoreMark Trace Extraction
```bash
FROST_CALIBRATION_TRACE_PATH=perf-modeling/results/coremark/coremark_timed.jsonl \
FROST_CALIBRATION_COUNTERS_PATH=perf-modeling/results/coremark/pipeline_counters.json \
FROST_CALIBRATION_MANIFEST_PATH=perf-modeling/results/coremark/manifest.json \
FROST_CALIBRATION_TARGET_RUN=2 \
FROST_CALIBRATION_START_PC=0x5848 \
FROST_CALIBRATION_STOP_PC=0x584c \
FROST_GIT_COMMIT=$(git rev-parse HEAD) \
./scripts/frost.py cocotb coremark
```

### Example: Tomasulo Microarchitectural Benchmark Suite
```bash
FROST_CALIBRATION_TRACE_PATH=perf-modeling/results/tomasulo_perf/tomasulo_perf_timed.jsonl \
FROST_CALIBRATION_COUNTERS_PATH=perf-modeling/results/tomasulo_perf/pipeline_counters.json \
FROST_CALIBRATION_MANIFEST_PATH=perf-modeling/results/tomasulo_perf/manifest.json \
FROST_CALIBRATION_TARGET_RUN=1 \
FROST_GIT_COMMIT=$(git rev-parse HEAD) \
./scripts/frost.py cocotb tomasulo_perf
```

### Example: DDR Memory-Level Parallelism (MLP) Stress Test
```bash
FROST_CALIBRATION_TRACE_PATH=perf-modeling/results/ddr_mlp_test/ddr_mlp_timed.jsonl \
FROST_CALIBRATION_COUNTERS_PATH=perf-modeling/results/ddr_mlp_test/pipeline_counters.json \
FROST_CALIBRATION_MANIFEST_PATH=perf-modeling/results/ddr_mlp_test/manifest.json \
FROST_CALIBRATION_TARGET_RUN=1 \
FROST_GIT_COMMIT=$(git rev-parse HEAD) \
./scripts/frost.py cocotb ddr_mlp_test
```

---

## 4. Validating Trace Integrity & Calibration

After capturing an RTL trace, run the validation tool to check contract compliance and calculate correlation metrics:

```bash
python3 perf-modeling/tools/run_calibration.py \
    --trace perf-modeling/results/coremark/coremark_timed.jsonl \
    --out perf-modeling/results/coremark/calibration.json \
    --rtl-commit $(git rev-parse HEAD) \
    --model-run perf-modeling/results/coremark/model_coremark_output.json
```

The script:
1. Validates every record against `trace_schema.json`.
2. Verifies monotonic cycle progression and transaction ID integrity.
3. Compares hardware pipeline counters against model output counters (IPC, retired uops, cycles).
4. Emits a structured `calibration.json` report documenting discrepancies, correlation accuracy, and timing.

---

## 5. Directory Structure & Deliverables

Every calibrated benchmark directory in `perf-modeling/results/<benchmark>/` contains:
- `manifest.json`: Toolchain versions, binary SHA256 hashes, command-line arguments, hardware clock, timed cycle window, and wall-clock execution time.
- `<benchmark>_timed.jsonl`: Cycle-accurate JSONL event trace captured during the timed benchmark region.
- `pipeline_counters.json`: Cycle and uop counts, IPC, dispatch/commit distributions, and AXI transaction totals directly measured from RTL.
- `calibration.json`: Output from `run_calibration.py` comparing RTL vs. performance model.
