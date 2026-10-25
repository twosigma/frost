# FROST Performance Modeling & Architectural Exploration

This directory provides a **fast, cycle-approximate architectural performance model of the FROST platform** (`platform_top` = `cpu_top` + `soc_top`).

---

## 1. Objectives & Executive Summary

1. **Simulation Speedup**:
   - Full-system Verilator RTL simulation runs at ~1.7 kHz (simulated cycles per second).
   - The recorded analytical CoreMark run executes at **75,122 simulated cycles/s**. Instruction replay requires instruction records with dependencies; aggregate calibration events are rejected.
   - This speed enables broad design space sweeps and bottleneck sensitivity analyses that would be computationally prohibitive in cycle-accurate RTL.

2. **RTL Cycle Correlation**:
   - CoreMark has an aggregate IPC comparison against RTL. The Tomasulo microarchitectural suite and DDR MLP stress test have validated event captures without model IPC comparisons.
   - CoreMark model IPC is **1.0199**, correlating within **+4.2%** of the hardware RTL's measured **0.9786 IPC** (239,452 cycles).
   - Accurately models FROST-specific microarchitectural structures: the 256-entry Load Queue direct-mapped L0 Data Cache (`lq_l0_cache.sv`) with 1-cycle combinational fast-path bypass, early load wakeup (`EARLY_LOAD_WAKEUP = 1`), and the single-channel 512-bit AXI memory system.

3. **Modular SoC / Core Boundary**:
   - Reflects the structural hierarchy of `platform_top.sv`:
     - `CpuTopModel` (`cpu_top.sv`): 2-wide out-of-order execution engine (ROB, RS, LQ, SQ, L0 D-cache, L1I, L1D, 32B-to-64B sector adapter, and L2 cache with stream prefetcher).
     - `SocTopModel` (`soc_top.sv`): `soc_axi_slave.sv` physical address decode (local BRAM/MMIO vs. DDR) and a swappable single-channel 512-bit AXI DDR controller (`SingleChannelDdrController`) modeled after `axi_behavioral_memory.sv`.
   - Connected via an explicit 6-bit-ID, 512-bit (64B) AXI4 interface (`SocTopPort`), enabling independent exploration of alternative memory controllers, interconnects, or multi-core fabrics without modifying the CPU core model.

4. **Zero RTL Modifications**:
   - Strictly modeling software. All synthesizable RTL in `hw/rtl/` remains 100% untouched.

---

## 2. Directory Structure

```
perf-modeling/
├── frost_perf_model.py          # Unified architectural model (CLI: run, replay, explore, sweep, audit, selftest, report)
├── README.md                    # This document
├── docs/
│   └── rtl_correlation_guide.md # Comprehensive guide for RTL correlation and trace capture
├── calibration/
│   ├── trace_schema.json        # JSON Schema for cycle-accurate trace validation
│   ├── trace_contract.py        # Python validator enforcing the trace contract
│   └── ci_baseline.json         # Stored CoreMark figures and tolerance of the CI calibration check
├── tools/
│   ├── run_calibration.py       # Calibration tool: validates traces, compares metrics, generates calibration.json
│   └── refresh_baseline.py      # Recaptures CoreMark and rewrites the figures in ci_baseline.json
├── rtl/
│   └── frost_perf_probe.sv      # Simulation-only Verilog event monitor mapping RTL handshakes to JSONL
├── tests/
│   └── test_trace_contract.py   # Automated unit tests for trace validation and ID roundtripping
├── traces/                      # Curated benchmark execution traces (head slices for rapid regression tests)
│   ├── coremark_head5k.jsonl
│   ├── tomasulo_perf_head5k.jsonl
│   └── ddr_mlp_head5k.jsonl
└── results/                     # Calibration evidence packages, reports, and sweep outputs
    ├── multi_benchmark_correlation_report.md # Correlation and wall-time findings across 3 benchmarks
    ├── FROST_perf_model_report.md            # Architectural configuration study and sweep report
    ├── coremark_optimization_report.md       # Design space exploration and bottleneck analysis
    ├── frost_perf_selftest.json              # Model self-test verification artifact (14/14 checks pass)
    ├── frost_perf_rtl_alignment.json         # Static RTL alignment audit artifact
    ├── frost_perf_sweep.json                 # Baseline configuration parameter sweep
    ├── coremark/                             # Complete CoreMark RTL calibration evidence package
    │   ├── manifest.json                     # Git commit, toolchain, binary checksums, and timing
    │   ├── coremark_timed.jsonl              # 20 MB cycle-accurate JSONL execution trace
    │   ├── pipeline_counters.json            # Hardware-measured stall, dispatch, commit, and AXI counters
    │   ├── calibration.json                  # Model vs RTL correlation comparison record
    │   └── findings.md                       # Deep-dive bottleneck analysis and reproduction guide
    ├── tomasulo_perf/                        # Tomasulo microarchitectural benchmark suite results
    │   ├── manifest.json
    │   ├── tomasulo_perf_timed.jsonl         # 21 MB cycle-accurate JSONL execution trace
    │   ├── pipeline_counters.json
    │   └── calibration.json
    └── ddr_mlp_test/                         # DDR memory-level parallelism stress test results
        ├── manifest.json
        ├── ddr_mlp_timed.jsonl               # 3.7 MB cycle-accurate JSONL execution trace
        ├── pipeline_counters.json
        └── calibration.json
```

---

## 3. Correlation Evidence & Performance Telemetry

### Multi-Benchmark Verification Summary

The archived RTL results cover three benchmarks under Verilator. CoreMark has a model IPC comparison; the other two captures validate event records:

| Benchmark | Workload Characteristic | Timed RTL Cycles | Retired Uops | Hardware RTL IPC | Calibrated Model IPC | Correlation Delta | Status |
|---|---|---:|---:|---:|---:|---:|:---:|
| **CoreMark** | General compute / integer pipeline | 239,452 | 234,317 | **0.9786** | **1.0199** | **+4.2%** | PASS (CRC verified) |
| **tomasulo_perf** | 14 directed microarchitecture benchmarks | 487,313 | 175,025 | **0.3592** | Not available | Not compared | PASS (14/14 sub-benchmarks) |
| **ddr_mlp_test** | Memory-level parallelism & AXI queueing | 94,010 | 30,427 | **0.3237** | Not available | Not compared | PASS |

### Wall-Time & Simulation Speed Comparison

| Benchmark / Model | Simulated Cycles | Wall-Clock Time | Simulated Cycles / Sec | Micro-Ops / Sec | Relative Speedup |
|---|---:|---:|---:|---:|---:|
| **CoreMark (Verilator RTL)** | 239,452 | 140.40 s | 1,705 cyc/s | 1,668 uop/s | **1.0x (Baseline)** |
| **tomasulo_perf (Verilator RTL)** | 487,313 | 277.67 s | 1,755 cyc/s | 630 uop/s | **1.0x (Baseline)** |
| **ddr_mlp_test (Verilator RTL)** | 94,010 | 56.63 s | 1,660 cyc/s | 537 uop/s | **1.0x (Baseline)** |
| **FROST Perf Model (Aggregate Trace Replay)** | Rejected | Not available | Not available | Not available | Not available |
| **FROST Perf Model (Analytical CoreMark)** | 3,067 | 0.040827 s | **75,122 cyc/s** | **76,616 uop/s** | **44.1x cycle-rate ratio** |

---

## 4. How to Extract Traces from Verilator RTL

Trace extraction is fully automated and integrated into the FROST test infrastructure (`verif/cocotb_tests/calibration_trace.py`, called from the real-program bench in `verif/cocotb_tests/test_real_program.py`). The monitor activates exclusively during the timed region of the target benchmark and introduces zero simulation timing perturbation.

### Step 1: Execute Simulation with Trace Capture

Run the benchmark using `./scripts/frost.py cocotb <benchmark>` with the calibration environment variables:

```bash
# Example: Capture CoreMark timed-region trace
FROST_CALIBRATION_TRACE_PATH=perf-modeling/results/coremark/coremark_timed.jsonl \
FROST_CALIBRATION_COUNTERS_PATH=perf-modeling/results/coremark/pipeline_counters.json \
FROST_CALIBRATION_MANIFEST_PATH=perf-modeling/results/coremark/manifest.json \
FROST_GIT_COMMIT=$(git rev-parse HEAD) \
./scripts/frost.py cocotb coremark
```

CoreMark's window runs from the return of `start_time` to the entry of `stop_time`, which the capture finds in the program's `sw.S`, so it follows changes of the code layout. `FROST_CALIBRATION_START_PC` and `FROST_CALIBRATION_STOP_PC` override either end; for other programs they set the window, which is otherwise the whole run. Without `FROST_GIT_COMMIT`, the capture takes the commit from git. A relative path in a `FROST_CALIBRATION_*_PATH` variable starts at the repository root.

### Step 2: Validate the Trace and Run Correlation

Validate trace integrity against the schema contract and compute correlation metrics against the model:

```bash
python3 perf-modeling/tools/run_calibration.py \
    --trace perf-modeling/results/coremark/coremark_timed.jsonl \
    --out perf-modeling/results/coremark/calibration.json \
    --rtl-commit $(git rev-parse HEAD) \
    --model-run perf-modeling/results/coremark/model_coremark_output.json
```

---

## 5. Trace Format & Contract Specifications

Traces use line-delimited JSON (`JSONL`). The initial record is a `meta` header, followed by cycle-by-cycle events:

```json
{"cycle": 0, "event": "meta", "source": "frost_perf_probe", "rtl_commit": "411dee2224700a3d9d325a4f2df8bcbe83a9bed5", "clock_domain": "cpu", "memory_configuration": "axi_behavioral_memory"}
{"cycle": 29456, "event": "dispatch", "uops": 2, "source": "rob"}
{"cycle": 29456, "event": "retire", "uops": 2, "source": "rob"}
{"cycle": 29457, "event": "axi_request", "axi_id": 1, "address": 2147483712, "is_write": false, "bytes": 64, "source": "axi"}
{"cycle": 29487, "event": "axi_response", "axi_id": 1, "ok": true, "source": "axi"}
```

### Supported Trace Events

| Event | Mandatory Fields | RTL Source Signal / Handshake |
|---|---|---|
| `dispatch` | `cycle`, `uops` | `dbg_rob_alloc_valid` (ROB allocation of 1 or 2 uops) |
| `retire` | `cycle`, `uops` | `dbg_commit_valid` (ROB retirement of 1 or 2 uops) |
| `cache_request` | `cycle`, `cache`, `address`, `is_write`, `request_id` | L1I / L1D / L2 input request valid-and-ready |
| `cache_response` | `cycle`, `cache`, `request_id`, `ok` | Cache data/completion return |
| `mshr_allocate` | `cycle`, `cache`, `slot`, `line_address` | MSHR entry allocation on cache miss |
| `mshr_release` | `cycle`, `cache`, `slot` | MSHR entry release on fill completion |
| `axi_request` | `cycle`, `axi_id`, `address`, `is_write`, `bytes` | `o_axi_arvalid` / `o_axi_awvalid` (512-bit / 64B transfer) |
| `axi_response` | `cycle`, `axi_id`, `ok` | `i_axi_rvalid` / `i_axi_bvalid` |
| `backpressure` | `cycle`, `resource`, `reason` | Pipeline/dispatch stall (`dbg_dispatch_stall`, `dbg_pipeline_stall`) |

---

## 6. Workflows & Design Space Exploration

### 1. Fast Workload Simulation
Simulate built-in analytical workloads (`coremark`, `redis_kv`, `http_api`, `faas_cold`, `linux_service`, `memory_stress`):
```bash
python3 perf-modeling/frost_perf_model.py run \
    --workload coremark \
    --out perf-modeling/results/coremark/model_coremark_output.json
```

### 2. Trace Replay
Replay instruction records with architectural addresses and backward dependencies against the baseline or an experimental configuration:
```bash
python3 perf-modeling/frost_perf_model.py replay \
    --trace /tmp/instructions.jsonl \
    --config core_expanded_window \
    --out /tmp/replay_output.json
```

### 3. Rapid Design Space Exploration
Evaluate 20+ microarchitectural design variants against a workload or replayed trace to pinpoint bottlenecks and rank optimizations:
```bash
python3 perf-modeling/frost_perf_model.py explore \
    --workload coremark \
    --out perf-modeling/results/coremark_exploration.json \
    --report perf-modeling/results/coremark_optimization_report.md
```

### 4. Configuration Parameter Sweep
Run comprehensive parameter sensitivity sweeps across multiple workloads:
```bash
python3 perf-modeling/frost_perf_model.py sweep \
    --out perf-modeling/results/frost_perf_sweep.json

python3 perf-modeling/frost_perf_model.py report \
    --sweep perf-modeling/results/frost_perf_sweep.json \
    --out perf-modeling/results/FROST_perf_model_report.md
```

---

## 7. Maintainer & Reviewer Guide

### Reviewing this Contribution
Maintainers evaluating this contribution can verify the model with four standard checks:

1. **Run Unit Tests**:
   ```bash
   python3 -m unittest discover perf-modeling/tests
   ```
   *Expected output: All tests pass (`OK`).*

2. **Run Model Architectural Self-Tests**:
   ```bash
   python3 perf-modeling/frost_perf_model.py selftest --out /tmp/selftest.json
   ```
   *Expected output: All 14 microarchitectural assertions pass (ID roundtrip, victim reservation, dirty writebacks, DDR slot scaling, SoC address routing, and determinism).*

3. **Run Static RTL Alignment Audit**:
   ```bash
   python3 perf-modeling/frost_perf_model.py audit --out /tmp/audit.json
   ```
   *Expected output: Emits source-grounded alignment table citing specific `hw/rtl/` files and line ranges for all baseline parameters.*

4. **Verify Synthesizable RTL Isolation**:
   ```bash
   git diff hw/rtl/
   ```
   *Expected output: Completely empty. No synthesizable RTL files are modified.*

CI's Fast Python Tests job runs the unit tests and the self-test through `tests/test_perf_model.py`, which also validates the sample event traces in `traces/`, rejects them as instruction replay, and checks the model output against the self-test, audit, CoreMark run, CoreMark exploration, and sweep results stored in `results/`, apart from wall-clock fields. To run it locally:

```bash
./scripts/frost.py run pytest tests/test_perf_model.py -v
```

A change to the model that moves those results must rewrite them, with the commands in section 6 and these two:

```bash
python3 perf-modeling/frost_perf_model.py selftest --out perf-modeling/results/frost_perf_selftest.json
python3 perf-modeling/frost_perf_model.py audit --out perf-modeling/results/frost_perf_rtl_alignment.json
```

### Calibration Check in CI

In CI's Real Programs (CoreMark) shard, the BRAM job records a calibration trace of CoreMark's timed region during its CoreMark run, and the next step checks it with `tools/run_calibration.py` against the stored baseline in `calibration/ci_baseline.json`. The check fails if the trace breaks the contract, if it has no dispatch, retirement, AXI request, or AXI response records, if it disagrees with the capture's pipeline counters or comes from another program or memory tier, or if the IPC of the model's `coremark` workload differs from the RTL's by more than the baseline's `ipc_tolerance` (10%). Pass or fail, the step prints the model's and the RTL's figures, the delta between their IPCs, and how far each has moved from the stored figures. To run the same check on a local capture:

```bash
./scripts/frost.py run python3 perf-modeling/tools/run_calibration.py \
    --trace tests/calibration/coremark.jsonl \
    --counters tests/calibration/coremark_counters.json \
    --manifest tests/calibration/coremark_manifest.json \
    --baseline perf-modeling/calibration/ci_baseline.json \
    --rtl-commit "$(git rev-parse HEAD)" \
    --out tests/calibration/coremark_calibration.json
```

After an intentional performance change, refresh the stored baseline with one command:

```bash
./scripts/frost.py run python3 perf-modeling/tools/refresh_baseline.py
```

It runs CoreMark in the BRAM tier with the capture on, writing to `tests/calibration/`, applies the same check, and if the check passes, rewrites the RTL's and the model's figures and their delta in `ci_baseline.json`; the tolerance stays. In a git worktree, where git does not work in the container, set `FROST_GIT_COMMIT` to name the commit. If the model's IPC now differs from the RTL's by more than the tolerance, the refresh fails too, and the model's CoreMark workload or configuration needs recalibrating, or the tolerance a deliberate change.

### Adopting, Extending, and Refining the Model

As the FROST design evolves, maintainers can easily keep the performance model synchronized:

- **Modifying Core Parameters**: Adjust `ModelConfig` in `frost_perf_model.py` (`rob_depth`, `mem_rs_depth`, `int_rs_depth`, `lq_depth`, `sq_depth`, `l0_cache_depth`, `l1d_mshrs`, `l2_mshrs`, etc.).
- **Modifying SoC / Interconnect**: Adjust `SocConfig` in `frost_perf_model.py` (`ddr_capacity_bytes`, `local_bram_latency`, address decode boundaries) or plug in a custom `SocTopPort` implementation.
- **Modifying Memory Controller / DDR Timing**: Adjust `DdrConfig` (`latency_cycles`, `num_slots`, reorder jitter) or replace `SingleChannelDdrController`.
- **Adding New Workload Traces**: Supply instruction records with kinds, fetch and data addresses, and dependencies to `--trace`. Cocotb captures selected by `FROST_CALIBRATION_TRACE_PATH` contain aggregate calibration events.

## 8. Memory-system configuration

`ModelConfig` supplies the following production resource defaults. Latencies are model assumptions expressed in core cycles.

| Resource | Default |
|---|---|
| Dispatch, retirement, CDB width | 2 |
| ROB / integer RS / memory RS entries | 32 / 16 / 8 |
| Load / store queue entries | 8 / 8 |
| L0 data entries | 256 dwords |
| L1I / L1D / L2 capacity | 16 KiB / 128 KiB / 2 MiB |
| Cache associativity | 4 ways |
| L1 / L2 line bytes | 32 / 64 |
| L1D / L2 miss slots | 8 / 4 |
| L1D / L2 writeback slots | 2 / 2 |
| L2 waiter seats per miss | 2 |
| L1D / L2 internal ID bits | 4 / 5 |
| CPU / DDR AXI ID bits | 6 / 5 |
| AXI outstanding transaction limit | 32 |

Caches reserve a victim way while a fill is pending. Same-line requests share a bounded miss record. Dirty victims complete their writeback before the replacement fill. Cache responses are pipelined at one per cycle after their configured latency. Stores issue from the ROB head, and the model waits for their cache completion before retirement.

Replacement follows the tree-PLRU walk in `frost_cache.sv`. An invalid unreserved way takes priority; otherwise the walk avoids reserved subtrees. Hits update the tree. An allocation updates it unless bimodal insertion is enabled and the low five bits of the free-running insertion LFSR are nonzero. The LFSR starts at `0xACE1` and uses the RTL's feedback taps. The model samples it at its allocation decision, not at fill completion. `l1d_bimodal_insert` defaults to true; `l2_bimodal_insert` defaults to false. Tag-stage timing is an abstraction, so the insertion phase is not calibrated cycle by cycle to RTL.

`early_load_wakeup` lets an accepted, nonfaulting load wake a dependent memory operation one modeled cycle before its registered memory wakeup. It requires an idle registered CDB lane and supplies at most one early token per cycle, following `mem_wakeup_merge.sv`. Integer consumers use the ordinary dependency path. The model omits uncached-store completion arbitration and speculative recovery.

`axi_id_pool_size` limits the total outstanding AXI transactions. Read and write transactions share this ownership pool. `axi_id_bits` sets the DDR port width and must cover `l2_id_bits`. The bridge carries each internal cache ID unchanged, as `line_port_axi_bridge.sv` does, and releases it on its response, including an error response. It does not renumber IDs. Cache slot counts and internal ID widths are separate fields. Widths beyond the production defaults describe architectural experiments and require corresponding RTL changes.

## 9. Configurable memory controllers

`DdrConfig(controller="behavioral")` selects the default single-channel endpoint. Its read and write queues are independent, and each has `max(num_slots, l2_mshrs, l2_wb_slots, 8)` entries. It models the configurable delay, LFSR jitter, and cross-ID completion reordering of `axi_behavioral_memory.sv`.

`DdrConfig(controller="interleaved")` selects physical channels with address interleaving. `channels` sets their count, and `interleave_bytes` sets the stripe size. The channel is `(DDR_offset // interleave_bytes) % channels`. Each channel has `num_slots` read entries and `num_slots` write entries, independently of the cache resources. Reads and writes share one line of service every `cycles_per_line` core cycles after `latency_cycles` has elapsed. Jitter and reordering use the same controls as the behavioral endpoint.

The shared AXI return port carries at most one read response and one write response per cycle across all physical channels. A second physical channel can increase aggregate service bandwidth only within this port limit. The interleaved controller has no bank, row, refresh, or bus-turnaround model. Its service rate is an explicit experiment input, not a board measurement.

## 10. Workload models and instruction replay

The built-in workloads are synthetic instruction and memory-pressure patterns: `coremark`, `memory_stress`, `redis_kv`, `http_api`, `faas_cold`, and `linux_service`. The CoreMark generator represents selected kernel dependencies and starts with instruction fetches ready. It is not the compiled CoreMark program.

`memory_workloads.py` supplies the three timed bodies of `ddr_mlp_test` and all nine `ddr_bench` kernels. It preserves their data addresses, strides, address-generator seeds, record sectors, accumulator chains, copy dependencies, and serialized chase dependencies. Arithmetic and loop-control operations are representative, not a compiled instruction trace. The MLP ring is prepared and evicted before the modeled region. DDR bench data is zero, matching the behavioral memory's initial contents. Setup, eviction, profiling, UART, and verification are outside the modeled region.

`memory-run` starts with cold data and warm instruction fetches. `--scale-shift` applies the DDR bench's size divisor and defaults to 4. `--mlp-lines` defaults to 512. `--passes` repeats a body while sharing cache contents. A production-cache RTL comparison of the MLP bodies requires an eviction sequence that reaches those caches' capacity or conflicting sets.

`--config-file` on `run` and `memory-run` reads a JSON object with `ModelConfig` fields and nested `ddr` and `soc` objects. Omitted fields use their defaults. For example, `{"axi_id_pool_size": 8, "ddr": {"controller": "interleaved", "channels": 2, "cycles_per_line": 4}}` selects two physical channels with a shared eight-transaction AXI limit.

Instruction replay accepts JSONL records with `kind`, `fetch_address` or `pc`, `data_address`, `depends_on`, and `mispredict`, or CSV records with the equivalent fields. The supported kinds are `alu`, `branch`, `load`, and `store`. IDs are consecutive from zero, and dependencies refer to earlier IDs. Memory operations require a data address. IDs and addresses accept integers or integer strings, including hexadecimal strings. Floating-point numbers and booleans are rejected. Zero addresses are preserved. Unknown kinds, forward dependencies, malformed records, and aggregate calibration events are rejected.

Calibration events contain dispatch and retirement counts and AXI handshakes. They do not contain an architectural instruction stream or its dependencies. They are suitable for trace validation and observed counters, not for reconstructing a program's cache accesses. The stored Tomasulo and DDR MLP calibration files contain observed trace totals and no model comparison. The [correlation guide](docs/rtl_correlation_guide.md) describes capture and comparison.

## 11. Model experiment commands

Run Python commands in the repository's `frost` Docker image. Store experimental measurements and generated reports outside versioned documentation.

```bash
python3 perf-modeling/frost_perf_model.py run --workload coremark --out /tmp/coremark.json
python3 perf-modeling/frost_perf_model.py memory-run --kernel ddr_bench_random_read --config-file /tmp/config.json --out /tmp/random_read.json
python3 perf-modeling/frost_perf_model.py replay --trace /tmp/instructions.jsonl --out /tmp/replay.json
python3 perf-modeling/frost_perf_model.py explore --workload coremark --out /tmp/exploration.json
python3 perf-modeling/frost_perf_model.py sweep --out /tmp/sweep.json
python3 perf-modeling/frost_perf_model.py report --sweep /tmp/sweep.json --out /tmp/report.md
python3 perf-modeling/frost_perf_model.py selftest --out /tmp/selftest.json
python3 perf-modeling/frost_perf_model.py audit --out /tmp/audit.json
python3 perf-modeling/tools/sweep_memory.py --group all --out /tmp/memory_sweep.json
```

`tools/sweep_memory.py` records source hashes and complete configurations. Its `x3` group varies one resource at a time from the production defaults. Its `channels` group crosses channel count, latency, service interval, and L2 miss slots. `--kernels`, `--scale-shift`, `--mlp-lines`, and `--passes` select the measured bodies and their sizes.

The `outstanding` group tests 4, 8, 12, and 16 L2 miss slots. Its feeder
profiles vary L1D miss slots, load queue entries, and prefetch concurrency
and distance. It uses the behavioral endpoint and one or two interleaved
channels with a four-cycle service interval per channel. L1D ID widths
cover each profile's miss slots. These are trial configurations;
`ModelConfig` defaults and the other sweep groups are independent of them.

The `controller` group drives a balanced sequential read stream directly through the AXI bridge and memory endpoint. It isolates the outstanding-transaction budget from CPU dependencies and cache misses. Each read owns an ID until completion. The probe reports average throughput between the first and last response, peak occupancy, and integrated occupancy. It requires at least 256 transactions and eight times the outstanding budget. The complete controller grid requires at least 1,024 transactions per point. Finite response windows can end within a channel burst, so throughput is an estimate of sustained service. Its ideal throughput is `min(1, channels / cycles_per_line)` lines per cycle. The latency-bandwidth product is a lower bound on the required outstanding reads. Channel imbalance, queueing, writes, and CPU issue limits can require a different budget. The `all` group includes all three experiments.

## 12. Model tests and calibration scope

The Fast Python Tests job collects `tests/test_perf_model.py`, `tests/test_perf_memory.py`, `tests/test_perf_workloads.py`, and `tests/test_perf_sweep.py`. They cover model invariants, deterministic results, trace contracts, calibration checks, memory channel service, AXI ownership, kernel addresses and dependencies, and controller saturation. The JSON files under `results/` are regression fixtures, not independent RTL validation.

```bash
pytest tests/test_perf_model.py tests/test_perf_memory.py tests/test_perf_workloads.py tests/test_perf_sweep.py -q -p no:cacheprovider
```

A model change that alters the stored results regenerates the corresponding JSON files with `run`, `explore`, `sweep`, `selftest`, and `audit`. The CoreMark fixture uses seed 11 and the default configuration. The exploration and sweep fixtures use their command defaults. Wall-clock fields are excluded from regression comparisons.

The report renderers reproduce `results/FROST_perf_model_report.md` and `results/coremark_optimization_report.md` from the corresponding sweep and exploration results. The model tests compare both documents with that output.

CI captures the BRAM CoreMark timed region and compares its observed IPC with the synthetic CoreMark workload. `calibration/ci_baseline.json` names the memory tier, workload, seed, required event classes, and tolerance. A passing comparison is an aggregate calibration check; it does not validate DDR sensitivity or other workloads. `tools/refresh_baseline.py` captures and checks that region before writing the baseline. A baseline refresh accompanies an intentional model or RTL performance change and records its reason in the commit.
