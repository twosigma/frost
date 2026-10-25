# FROST Performance Model — RTL Correlation & Trace Extraction Guide

This document describes the methodology for capturing cycle-accurate microarchitectural and memory traces from FROST Verilator RTL simulations, validating trace contracts, and correlating hardware RTL measurements against the fast architectural performance model.

---

## 1. Overview & Objectives

The FROST performance model provides an ultra-fast (>100x trace replay, >7,000x analytical simulation) cycle-approximate simulator of the FROST platform (`platform_top` = `cpu_top` + `soc_top`). To ensure that architectural recommendations and design space exploration reflect actual hardware behavior, the model is calibrated directly against cycle-accurate Verilator RTL simulation traces.

Key objectives:
1. **Zero Intrusion**: Probes monitor RTL simulation state without perturbing DUT timing, changing clocking, or altering synthesizable RTL (`hw/rtl/`).
2. **Deterministic & Reproducible**: Every benchmark run records full provenance (`manifest.json` with commit SHA, binary checksums, compiler version, DDR model seed, and execution wall-time).
3. **Structured Trace Contract**: Simulation events are emitted as JSONL records adhering to a strict schema (`calibration/trace_schema.json`), validated automatically by `calibration/trace_contract.py`.

---

## 2. Trace Contract & Event Schema

Traces are formatted as line-delimited JSON (JSONL). The first line is always a `meta` event describing the simulation environment. Subsequent records document accepted handshakes and microarchitectural state on each simulation clock cycle.

### Standard Trace Events

| Event | Required Fields | RTL Observation Point | Purpose |
|---|---|---|---|
| `meta` | `rtl_commit`, `clock_domain`, `memory_configuration` | Testbench initialization | Trace provenance |
| `dispatch` | `cycle`, `uops` | `dbg_rob_alloc_valid` & ready | Accepted dispatch / ROB allocations (1 or 2 uops) |
| `retire` | `cycle`, `uops` | `dbg_commit_valid` & ready | Accepted retirement / commit (1 or 2 uops) |
| `cache_request` | `cycle`, `cache`, `address`, `is_write`, `request_id` | L1I / L1D / L2 input | Cache access requests |
| `cache_response` | `cycle`, `cache`, `request_id`, `ok` | L1I / L1D / L2 output | Cache completion / data return |
| `mshr_allocate` | `cycle`, `cache`, `slot`, `line_address` | Cache MSHR entry allocation | Track miss concurrency & slot occupancy |
| `mshr_release` | `cycle`, `cache`, `slot`, `line_address` | Cache MSHR completion | Miss resolution |
| `axi_request` | `cycle`, `axi_id`, `address`, `is_write`, `bytes` | `o_axi_arvalid` / `o_axi_awvalid` | 512-bit (64-byte) single-beat AXI transactions |
| `axi_response` | `cycle`, `axi_id`, `ok` | `i_axi_rvalid` / `i_axi_bvalid` | AXI read/write completions from DDR/memory |
| `backpressure` | `cycle`, `resource`, `reason` | Stall signals (`dbg_dispatch_stall`, etc.) | Identifies specific architectural bottleneck cycles |

All cycle stamps represent CPU-clock cycles (not wall time).

---

## 3. How to Extract Traces from Verilator RTL

Trace extraction is integrated into the cocotb test harness (`verif/cocotb_tests/calibration_trace.py`, called from `verif/cocotb_tests/test_real_program.py`). When the target environment variables are set, the testbench activates the calibration monitors exclusively for the timed region of the benchmark. A simulation that lacks a signal the capture reads fails with an error that names the signal.

### Example: CoreMark Trace Extraction
```bash
FROST_CALIBRATION_TRACE_PATH=perf-modeling/results/coremark/coremark_timed.jsonl \
FROST_CALIBRATION_COUNTERS_PATH=perf-modeling/results/coremark/pipeline_counters.json \
FROST_CALIBRATION_MANIFEST_PATH=perf-modeling/results/coremark/manifest.json \
FROST_GIT_COMMIT=$(git rev-parse HEAD) \
./scripts/frost.py cocotb coremark
```

CoreMark's window runs from the return of `start_time` to the entry of `stop_time`, which the capture finds in the program's `sw.S`, so it follows changes of the code layout. `FROST_CALIBRATION_START_PC` and `FROST_CALIBRATION_STOP_PC` override either end; for other programs they set the window, which is otherwise the whole run. Without `FROST_GIT_COMMIT`, the capture takes the commit from git. A relative path in a `FROST_CALIBRATION_*_PATH` variable starts at the repository root.

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
1. Checks every record's fields against the event table in `calibration/trace_contract.py`, which `trace_schema.json` also gives.
2. Verifies that cycles never decrease, that the first record is the `meta` header, and that AXI requests are 64-byte lines.
3. Compares hardware pipeline counters against model output counters (IPC, retired uops, cycles).
4. Emits a structured `calibration.json` report documenting discrepancies, correlation accuracy, and timing.

With `--baseline perf-modeling/calibration/ci_baseline.json`, the script also runs the calibration check that CI applies to CoreMark (see the README's maintainer guide): without `--model-run`, it runs the baseline's model workload; it checks that the trace has the baseline's required event classes, that it agrees with the capture's pipeline counters (`--counters`) and comes from the baseline's program and memory tier (`--manifest`), and that the model's IPC is within the baseline's tolerance of the RTL's. It prints the figures and their deltas and exits with 1 if a check fails; with `--refresh`, a passing check rewrites the baseline's figures.

---

## 5. Directory Structure & Deliverables

Every calibrated benchmark directory in `perf-modeling/results/<benchmark>/` contains:
- `manifest.json`: Toolchain versions, binary SHA256 hashes, memory tier and DDR model settings, simulated clock, timed cycle window, and wall-clock execution time. The commit comes from `FROST_GIT_COMMIT`, or from git when it is unset; the compiler version comes from the program's ELF, the tool versions from cocotb and the simulator, and the clock from the bench's clock period.
- `<benchmark>_timed.jsonl`: Cycle-accurate JSONL event trace captured during the timed benchmark region.
- `pipeline_counters.json`: Cycle and uop counts, IPC, dispatch/commit distributions, and AXI transaction totals directly measured from RTL.
- `calibration.json`: Output from `run_calibration.py` comparing RTL vs. performance model.

## 6. Memory-system resource comparisons

Use the same binary, region, cache state, and memory timing for each RTL comparison point. Compare simulated cycles and retired work. An IPC ratio alone can hide a change in the amount of work. Synthetic kernel micro-operation counts need not equal compiler instruction counts; report that difference with absolute and relative cycle errors.

The DDR kernel generators preserve addresses and dependency structure from the C loop bodies. They omit profiling and surrounding program activity and assume warm fetches and cold data. DDR bench chase addresses assume zero backing data. MLP addresses assume the seeded ring. Match `scale_shift` and `mlp_lines` to the program and record any eviction preparation. `passes` controls reuse within the model, independently of cocotb's reset-and-rerun setting.

The default behavioral DDR endpoint represents the RTL simulation endpoint. The interleaved endpoint describes physical channels with explicit stripe size, queue depth, latency, and service interval. Its reads and writes share each physical channel's bandwidth and one AXI return port. It has no bank or refresh timing. Channel experiments record these settings separately from cache resource counts.

The AXI bridge preserves internal cache IDs until completion. Its pool size bounds live transactions independently of cache miss slots and wire width. It does not renumber or truncate IDs. A width comparison must specify which additional internal IDs can be issued. Production widths are four bits for L1D and five bits for L2 and the DDR port.

Early load wakeup affects dependent memory operations. A nonfaulting accepted load can use an idle registered CDB lane to bypass one modeled memory-wakeup cycle. Two occupied registered lanes suppress the token. Integer dependencies use the ordinary path. The model omits speculative recovery and uncached-store completion arbitration.

Cache replacement uses the RTL tree-PLRU victim walk and skips reserved ways. The insertion LFSR advances with modeled core cycles. Bimodal allocation updates replacement state when its low five bits are zero, while hits always update it. The allocation decision samples this state before the fill. Abstract cache-stage timing can shift the sampling phase relative to RTL, so compare miss counts as well as cycles when evaluating capacity or insertion policy.
