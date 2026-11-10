# FROST Performance Modeling & Architectural Exploration

This directory provides a **fast, cycle-approximate architectural performance model of the FROST platform** (`platform_top` = `cpu_top` + `soc_top`).

---

## 1. Objectives & Executive Summary

1. **Simulation Speedup**:
   - Full-system Verilator RTL simulation runs at ~1.7 kHz (simulated cycles per second).
   - The recorded analytical CoreMark run executes at **65,372 simulated cycles/s**. Instruction replay requires instruction records with dependencies; aggregate calibration events are rejected.
   - This speed enables broad design space sweeps and bottleneck sensitivity analyses that would be computationally prohibitive in cycle-accurate RTL.

2. **RTL Cycle Correlation**:
   - CoreMark has an aggregate IPC comparison against RTL. The Tomasulo microarchitectural suite and DDR MLP stress test have validated event captures without model IPC comparisons.
   - The archived CoreMark comparison records model IPC **1.0045**, within **+2.6%** of that capture's **0.9786 IPC** (239,452 RTL cycles). These historical figures precede the current hit-path model; section 12 records its load-kernel calibration.
   - A VCU118 board data set (`results/vcu118_sync10i/`) compares the memory path with sequential, strided, store and chase benchmarks measured on an FPGA build under Linux (section 13).
   - Accurately models FROST-specific microarchitectural structures: the 256-entry Load Queue direct-mapped L0 Data Cache (`lq_l0_cache.sv`) with 1-cycle combinational fast-path bypass, early load wakeup (`EARLY_LOAD_WAKEUP = 1`), and the single-channel 512-bit AXI memory system.

3. **Modular SoC / Core Boundary**:
   - Reflects the structural hierarchy of `platform_top.sv`:
     - `CpuTopModel` (`cpu_top.sv`): 2-wide out-of-order execution engine (ROB, RS, LQ, SQ, L0 D-cache, L1I, coherent L1D, 32B-to-64B sector adapter, and L2 home with its stream prefetch agent).
     - `SocTopModel` (`soc_top.sv`): `soc_axi_slave.sv` physical address decode (local BRAM/MMIO vs. DDR) and a swappable single-channel 512-bit AXI DDR controller (`SingleChannelDdrController`) modeled after `axi_behavioral_memory.sv`.
   - Connected via an explicit 6-bit-ID, 512-bit (64B) AXI4 interface (`SocTopPort`), enabling independent exploration of alternative memory controllers, interconnects, or multi-core fabrics without modifying the CPU core model.
   - The RTL's CPU caches use the coherent hierarchy: an MSI L1D with buffered
     stores and probes, connected to the shared L2 coherence home.
     `L2_NUM_MSHR` sets its fill count, eight on X3, and `L2_PREFETCH` enables
     data and instruction stream prefetching into the home.
     The model's L1D follows the coherent L1D's controller, independent
     load hit path, request endpoints, stream look-ahead and store records,
     and its prefetcher
     follows the home's data prefetch agent (section 8). The L2 and L1I are
     generic line caches, so DDR forecasts need calibration against the
     coherent path.

4. **Zero RTL Modifications**:
   - Strictly modeling software. All synthesizable RTL in `hw/rtl/` remains 100% untouched.

---

## 2. Directory Structure

```
perf-modeling/
├── frost_perf_model.py          # Unified architectural model (CLI: run, memory-run, replay, explore, sweep, audit, selftest, report)
├── memory_workloads.py          # Address and dependency generators for the DDR benchmark kernels
├── board_workloads.py           # Loop bodies of the board memory benchmarks behind a board data set
├── README.md                    # This document
├── docs/
│   └── rtl_correlation_guide.md # Comprehensive guide for RTL correlation and trace capture
├── calibration/
│   ├── trace_schema.json        # JSON Schema for cycle-accurate trace validation
│   ├── trace_contract.py        # Python validator enforcing the trace contract
│   └── ci_baseline.json         # Stored CoreMark figures and tolerance of the CI calibration check
├── tools/
│   ├── run_calibration.py       # Calibration tool: validates traces, compares metrics, generates calibration.json
│   ├── refresh_baseline.py      # Recaptures CoreMark and rewrites the figures in ci_baseline.json
│   ├── board_calibration.py     # Runs a board data set's benchmarks and records the model's residuals
│   └── sweep_memory.py          # Sweeps cache resources and physical-channel service with explicit configurations
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
    ├── coremark_exploration.json             # CoreMark design-variant exploration behind the optimization report
    ├── frost_perf_selftest.json              # Model self-test verification artifact (14/14 checks pass)
    ├── frost_perf_rtl_alignment.json         # Static RTL alignment audit artifact
    ├── frost_perf_sweep.json                 # Baseline configuration parameter sweep
    ├── coremark/                             # Complete CoreMark RTL calibration evidence package
    │   ├── manifest.json                     # Git commit, toolchain, binary checksums, and timing
    │   ├── coremark_timed.jsonl              # 20 MB cycle-accurate JSONL execution trace
    │   ├── pipeline_counters.json            # Hardware-measured stall, dispatch, commit, and AXI counters
    │   ├── calibration.json                  # Model vs RTL correlation comparison record
    │   ├── model_coremark_output.json        # Model's CoreMark workload run, the calibration's --model-run input
    │   └── findings.md                       # Deep-dive bottleneck analysis and reproduction guide
    ├── tomasulo_perf/                        # Tomasulo microarchitectural benchmark suite results
    │   ├── manifest.json
    │   ├── tomasulo_perf_timed.jsonl         # 21 MB cycle-accurate JSONL execution trace
    │   ├── pipeline_counters.json
    │   └── calibration.json
    ├── ddr_mlp_test/                         # DDR memory-level parallelism stress test results
    │   ├── manifest.json
    │   ├── ddr_mlp_timed.jsonl               # 3.7 MB cycle-accurate JSONL execution trace
    │   ├── pipeline_counters.json
    │   └── calibration.json
    └── vcu118_sync10i/                       # VCU118 FPGA board memory benchmarks under Linux
        ├── manifest.json                     # Board, build, clocks, programs and raw result files
        ├── measurements.json                 # Measured figures with their raw result lines
        ├── model_config.json                 # The platform's model configuration (--config-file form)
        └── calibration.json                  # Model figures and residuals from tools/board_calibration.py
```

---

## 3. Correlation Evidence & Performance Telemetry

### Multi-Benchmark Verification Summary

The archived RTL results and model comparison below precede the hit-path extension. They cover three benchmarks under Verilator. CoreMark has a model IPC comparison; the other two captures validate event records:

| Benchmark | Workload Characteristic | Timed RTL Cycles | Retired Uops | Hardware RTL IPC | Calibrated Model IPC | Correlation Delta | Status |
|---|---|---:|---:|---:|---:|---:|:---:|
| **CoreMark** | General compute / integer pipeline | 239,452 | 234,317 | **0.9786** | **1.0045** | **+2.6%** | PASS (CRC verified) |
| **tomasulo_perf** | 14 directed microarchitecture benchmarks | 487,313 | 175,025 | **0.3592** | Not available | Not compared | PASS (14/14 sub-benchmarks) |
| **ddr_mlp_test** | Memory-level parallelism & AXI queueing | 94,010 | 30,427 | **0.3237** | Not available | Not compared | PASS |

### Wall-Time & Simulation Speed Comparison

| Benchmark / Model | Simulated Cycles | Wall-Clock Time | Simulated Cycles / Sec | Micro-Ops / Sec | Relative Speedup |
|---|---:|---:|---:|---:|---:|
| **CoreMark (Verilator RTL)** | 239,452 | 140.40 s | 1,705 cyc/s | 1,668 uop/s | **1.0x (Baseline)** |
| **tomasulo_perf (Verilator RTL)** | 487,313 | 277.67 s | 1,755 cyc/s | 630 uop/s | **1.0x (Baseline)** |
| **ddr_mlp_test (Verilator RTL)** | 94,010 | 56.63 s | 1,660 cyc/s | 537 uop/s | **1.0x (Baseline)** |
| **FROST Perf Model (Aggregate Trace Replay)** | Rejected | Not available | Not available | Not available | Not available |
| **FROST Perf Model (Analytical CoreMark)** | 9,286 | 0.142048 s | **65,372 cyc/s** | **65,667 uop/s** | **38.3x cycle-rate ratio** |

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

The Fast Python Tests job also runs `tests/test_perf_memory.py`, `tests/test_perf_workloads.py`, and `tests/test_perf_sweep.py` (section 12), and `tests/test_calibration_trace.py`, which tests the real-program bench's calibration capture (`verif/cocotb_tests/calibration_trace.py`) on a stand-in DUT.

### Calibration Check in CI

In CI's Real Programs (CoreMark) shard, the BRAM job records a calibration trace of CoreMark's timed region during its CoreMark run, and the next step checks it with `tools/run_calibration.py` against the stored baseline in `calibration/ci_baseline.json`. The check fails if the trace breaks the contract, if it has no dispatch, retirement, AXI request, or AXI response records, if it disagrees with the capture's pipeline counters or comes from another program or memory tier, or if the IPC of the model's `coremark_bram` workload differs from the RTL's by more than the baseline's `ipc_tolerance` (10%). The capture is of the BRAM tier, whose loads and stores take the SoC's local port and never reach the coherent L1D, so `coremark_bram` places its data in low BRAM and runs 1,200 operations like the capture, with no length tuning for a cold start. The baseline's `model_config` sets the two fields that differ from the model's defaults to the captured hardware's values, and `model_config_sources` names where each comes from: `soc.local_bram_read_cycles` 10, measured on the RTL as cycles per load of a dependent pointer chase through BRAM data whose nodes alias in the L0 (8026 cycles for 800 loads), and `l0_cache_depth` 512, the RTL's `NormalLqL0Depth`. Pass or fail, the step prints the model's and the RTL's figures, the delta between their IPCs, and how far each has moved from the stored figures. To run the same check on a local capture:

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

`ModelConfig` supplies the following reference CPU resource defaults.
Board overrides are separate trial configurations. Latencies are model
assumptions expressed in core cycles.

| Resource | Default |
|---|---|
| Dispatch, retirement, CDB width | 2 |
| ROB / integer RS / memory RS entries | 32 / 16 / 8 |
| Load / store queue entries | 8 / 8 |
| L0 data entries | 256 dwords |
| L1I / L1D / L2 capacity | 16 KiB / 128 KiB / 2 MiB |
| Cache associativity | 4 ways |
| L1 / L2 line bytes | 32 / 64 |
| L1D request endpoints / L2 miss slots | 8 / 4 |
| L1D stream look-ahead endpoints / window | 2 / 8 sectors |
| L1D store records / read slots | 4 / 8 |
| L1D / L2 writeback slots | 2 / 2 |
| L2 waiter seats per miss | 2 |
| L2 prefetch streams / identities / distance | 4 / 3 / 8 lines |
| L1D / L2 internal ID bits | 4 / 5 |
| CPU / DDR AXI ID bits | 6 / 5 |
| AXI outstanding transaction limit | 32 |

`cpu_top` passes eight L2 fills (`L2_NUM_MSHR`) and a 512-entry L0 with Normal read caching; the model keeps four L2 miss slots and 256 L0 entries, and a configuration file states the RTL's values, as the board data set does for its fills.

`configs/vcu118_l2_4mib.json` selects the VCU118's 4 MiB L2 through
`--config-file`. It overrides capacity only; the remaining settings retain
the model defaults and do not calibrate the VCU118's memory latency.

Caches reserve a victim way while a fill is pending. Same-line requests share a bounded miss record. The L1D and the L2 write a dirty victim back beside the replacement fill and hold its writeback slot until the lower level acknowledges it, as the L1D's frozen PutM slots and the home's detached victims do. Cache responses are pipelined at one per cycle after their configured latency.

MEM_RS frees an entry when it issues one load or store per cycle (`reservation_station.sv`), and the LQ frees an entry when its result reaches the CDB stage (`load_queue.sv`). An ordinary store is done at issue and retires without waiting for memory. A committed store keeps its SQ entry until it drains: cached stores launch one at a time, at most every `store_drain_cycles`, into the L1D's store records, and the L1D's acknowledgement a cycle later frees the entry (`store_queue.sv`). The SQ is full while the records are, so SQ depth and the records' installation rate set a store stream's throughput.

The L1D follows `coherence_l1d.sv` with `l1d_hit_path=true` by default. Eight `l1d_read_slots` accept at most one new load per cycle, independently of the controller. A load is offered once to the hit port in the following cycle; it samples a tag copy and every way's data together, completes a hit's read slot four cycles after arrival, and uses the normal serialized response port. The port refuses a controller data-bank claim, a same-set array update, or a sector held by buffered stores or frozen writebacks. A refused offer falls back to the controller. The path can answer hits while a miss or store occupies the controller. A hit-port replacement touch yields to an array replacement write, even to another set. `l1d_request_cycles=1` covers MEM_RS launch to L1D arrival, `l1d_response_cycles=2` covers a ready slot to the read response, and `l1d_return_cycles=2` covers the response to the CDB. Thus a dependent cached hit takes nine launch-to-launch cycles, including the four-cycle hit path. These stages apply to cached loads only; BRAM and L0 bypass them.

One controller still serves one operation at a time: in its Idle priority, a grant's installation, the head store, a load, a lent store endpoint, then stream look-ahead. A read selected while the hit path holds it, including a stage-3 hit, uses a tags-only shadow lookup: it neither reads data nor touches replacement state, and answers nothing if either path hits. A double miss uses that lookup to enter the miss path; a shadow whose tags alone hit leaves its read pending for a later normal lookup. A lookup holds the controller for `l1_tag_cycles + 3` cycles (Idle, Lookup, the tag read and the reply), a hit for `l1_data_cycles` more, an acquisition for one more, and an installation or store update for `l1_write_cycles + 2` beyond the lookup; a dirty victim adds its data read and the freeze. `l1d_mshrs` request endpoints carry acquisitions: endpoint 0 the head store's GetM, the others load misses, the lowest free one first. A demand grant answers its load in its lookup cycle; loads that attached to the endpoint look up again after the installation, one of them ahead of the next grant. The hit port sees an installed tag/data image on the array write edge, while the way remains reserved through the controller's update wait. Each endpoint stays live until U, `coherence_release_cycles` after installation. Up to four store records hold committed stores; only the youngest unsealed record combines another store to its sector, a record seals at its head's lookup, and every record installs at the head, with one load endpoint lent to a younger record's GetM. A read of a sector with a buffered store waits. `l1d_hit_path=false` selects the earlier controller-only model. Probes, atomics and maintenance are still outside the workload model.

Stream look-ahead follows `coherence_read_stream.sv`. Three adjacent demand sector misses confirm a stream. Hit-path hits enter a separate two-entry queue, with duplicate tail sectors suppressed; controller reports take priority, overflow drops a hit, and hits advance only a confirmed stream. The cursor runs up to `l1d_lookahead_sectors` sectors past the demand frontier, within a 4 KiB page. Hints use the highest `l1d_lookahead_slots` load endpoints, limited to `l1d_mshrs - 2` so one load endpoint stays demand-only (`PrefetchCount` is 2 for four or more endpoints and 1 for three), and demand may use every load endpoint. A hint waits for its window and an endpoint, takes the controller only when nothing else wants it, and its fill trains the L2 prefetcher like a demand miss. A change of `PrefetchCount` in the RTL is a change of `l1d_lookahead_slots`.

The L2 prefetcher follows the home's data prefetch agent (`coherence_prefetch_agent.sv`, `l2_stream_prefetcher.sv`). Its four-entry stream table trains on every L1D request the L2 accepts, hits included, confirms a stream on two consecutive lines, and requests up to `l2_prefetch_distance` lines after its last line, never past the page. A request loads only while more than a quarter of the L2 miss slots are free and one of `l2_prefetch_inflight` identities is free; the home answers it after one lookup, and its identity returns `coherence_release_cycles` later while any fill continues. The home fills only when two ways of the set are available and, for a valid victim, every writeback slot is free; otherwise, or for a resident or in-flight line, the prefetch does nothing. The instruction prefetch table and the pause beside DMA traffic are not modeled.

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

`tools/sweep_memory.py` records source hashes and complete configurations. Its `x3` group varies one resource at a time from the reference defaults. Its `channels` group crosses channel count, latency, service interval, and L2 miss slots. `--kernels`, `--scale-shift`, `--mlp-lines`, and `--passes` select the measured bodies and their sizes.

The `outstanding` group tests 4, 8, 12, and 16 L2 miss slots. Its feeder
profiles vary L1D miss slots, load queue entries, and prefetch concurrency
and distance. It uses the behavioral endpoint and one or two interleaved
channels with a four-cycle service interval per channel. L1D ID widths
cover each profile's miss slots. These are trial configurations;
`ModelConfig` defaults and the other sweep groups are independent of them.

The `controller` group drives a balanced sequential read stream directly through the AXI bridge and memory endpoint. It isolates the outstanding-transaction budget from CPU dependencies and cache misses. Each read owns an ID until completion. The probe reports average throughput between the first and last response, peak occupancy, and integrated occupancy. It requires at least 256 transactions and eight times the outstanding budget. The complete controller grid requires at least 1,024 transactions per point. Finite response windows can end within a channel burst, so throughput is an estimate of sustained service. Its ideal throughput is `min(1, channels / cycles_per_line)` lines per cycle. The latency-bandwidth product is a lower bound on the required outstanding reads. Channel imbalance, queueing, writes, and CPU issue limits can require a different budget. The `all` group includes the `x3`, `channels`, and `controller` groups.

## 12. Model tests and calibration scope

The Fast Python Tests job collects `tests/test_perf_model.py`, `tests/test_perf_memory.py`, `tests/test_perf_workloads.py`, and `tests/test_perf_sweep.py`. They cover model invariants, deterministic results, trace contracts, calibration checks, memory channel service, AXI ownership, kernel addresses and dependencies, and controller saturation. The JSON files under `results/` are regression fixtures, not independent RTL validation.

```bash
pytest tests/test_perf_model.py tests/test_perf_memory.py tests/test_perf_workloads.py tests/test_perf_sweep.py -q -p no:cacheprovider
```

A model change that alters the stored results regenerates the corresponding JSON files with `run`, `explore`, `sweep`, `selftest`, and `audit`. The CoreMark fixture uses seed 11 and the default configuration. The exploration and sweep fixtures use their command defaults. Wall-clock fields are excluded from regression comparisons.

The report renderers reproduce `results/FROST_perf_model_report.md` and `results/coremark_optimization_report.md` from the corresponding sweep and exploration results. The model tests compare both documents with that output.

CI captures the BRAM CoreMark timed region and compares its observed IPC with the synthetic CoreMark workload. `calibration/ci_baseline.json` names the memory tier, workload, seed, required event classes, and tolerance. A passing comparison is an aggregate calibration check; it does not validate DDR sensitivity or other workloads. `tools/refresh_baseline.py` captures and checks that region before writing the baseline. A baseline refresh accompanies an intentional model or RTL performance change and records its reason in the commit.

The `coremark` workload keeps its data cold in DDR at 3,600 operations, for the memory sweeps. The `coremark_bram` workload's loads and stores to low BRAM bypass the L1D, so with the baseline's configuration it runs at IPC 0.9717 against the capture's 0.9682 (+0.4%).

### L1D hit-path RTL calibration

`results/l1d_hit_path/calibration.json` records load microkernels simulated on
`4d2a20a3` in the pinned `frost` image (Verilator 5.052, cocotb 2.1.0).
Code executes from BRAM and data from cached DDR. Chains traverse 16 nodes
spaced 4 KiB apart, so their dwords alias in the 512-entry L0 while their
sectors remain resident in the L1D. Each chain is warmed for two laps;
the measured body contains 512 loads, interleaved across one, two or four
independent chains. Random loads use 1,024 predetermined 8-byte addresses
in 16 KiB, using seed 12345; the third pass is measured. The model
uses the same addresses and dependencies, warm instruction fetches and L1D
contents, and the RTL's 512-entry L0 and eight L2 fills.

The cycle window runs from the first to the last MEM_RS load launch,
excluding setup and final drain. The one-chain trace sets the path's stage
latencies; chain concurrency and random loads check the resulting throughput.

| Kernel | Loads | RTL cycles | Model cycles | Model / RTL minus 1 |
|---|---:|---:|---:|---:|
| Dependent chain | 512 | 4,599 | 4,599 | 0.0% |
| Two chains | 512 | 2,296 | 2,296 | 0.0% |
| Four chains | 512 | 1,146 | 1,146 | 0.0% |
| Random 16 KiB loads | 1,024 | 1,325 | 1,090 | -17.7% |

All 3,421 sampled RTL hit-path hits, including warm-up, complete their slot
four cycles after L1D arrival. The first three windows contain no L0 hits;
the random window mixes L0 and L1D hits and exposes the model's existing
one-cycle L0 and approximate pipeline scheduling. Its residual remains an
explicit limit; the calibrated L1D stages are not adjusted to fit it. The
unit tests retain the three measured chain spans and exercise shadows,
port refusals, read-slot credit, fill visibility and replays, replacement-write
ordering, and stream-report ordering.

BRAM CoreMark remains exactly 223,556 ticks with matching CRCs. Its newly
captured timed window is 223,549 cycles and 226,801 retired micro-ops. The
CI model workload remains 3,219 cycles and 3,128 retired micro-ops (IPC
0.9717), within 4.22% of that RTL IPC; `calibration/ci_baseline.json` is
unchanged.

## 13. Board calibration data sets

A board data set records benchmarks measured on hardware, with the platform's model configuration. `tools/board_calibration.py` runs each benchmark's loop body from `board_workloads.py`, starting with every cache full of unrelated lines (modified ones behind store streams), measures the steady state once the body's warm-up share has retired, and writes each figure, the model's, and their residual to the set's `calibration.json`. Points marked `fit` set a configuration latency and match by construction; `--fit` searches those latencies again, and `--set FIELD=JSON` overrides a configuration field for a sensitivity study.

```bash
python3 perf-modeling/tools/board_calibration.py \
    --data-set perf-modeling/results/vcu118_sync10i \
    --out perf-modeling/results/vcu118_sync10i/calibration.json
```

The board data set predates the L1D hit path. Its configuration explicitly disables that path and retains the earlier cached-load timing (`l1d_request_cycles=0`, `l1d_response_cycles=1`, `l1d_return_cycles=0`) for the historical controller-only comparison below; these figures do not calibrate the current hit path.

`results/vcu118_sync10i/` holds benchmarks measured on 2026-11-08 on a VCU118 FPGA build of upstream `699b7068` with the board series: CPU at 200 MHz, the SoC, L2 home and DDR4 controller at 100 MHz, under Linux. It is an FPGA platform point: the half-rate home and controller set its latencies, so its absolute figures are not ASIC figures. Its configuration states the RTL's eight home fills, doubles the home's tag stage and C-to-U interval for the half-rate home, and fits two latencies: `l2_data_cycles` (39) to the 256 KiB dependent chain and `ddr.latency_cycles` (148) to the dependent DRAM chase. The board takes 0.54 DTLB misses per chase hop and the model has no page walker, so that DDR latency includes the walks.

| Benchmark | Board | Model | Residual | Role |
|---|---:|---:|---:|---|
| Sequential 8-byte read | 132.2 MB/s | 156.5 MB/s | +18.4% | prediction |
| Strided read, 16 B | 209.4 MB/s | 272.6 MB/s | +30.2% | prediction |
| Strided read, 32 B | 327.5 MB/s | 464.4 MB/s | +41.8% | prediction |
| Strided read, 64 B | 518.1 MB/s | 524.2 MB/s | +1.2% | prediction |
| Strided read, 128 B | 1108.0 MB/s | 868.2 MB/s | -21.6% | prediction |
| Sequential 8-byte write | 97.7 MB/s | 104.0 MB/s | +6.4% | prediction |
| memcpy (int-copy body) | 172.3 MB/s | 149.6 MB/s | -13.2% | prediction |
| memset (int-write body) | 97.6 MB/s | 104.0 MB/s | +6.5% | prediction |
| Dependent DRAM chase | 818.6 ns | 820.2 ns | +0.2% | fit |
| 256 KiB dependent chain | 181.9 ns | 182.0 ns | +0.1% | fit |

In this historical configuration, the L1D's one-at-a-time controller sets the rate of the sector-adjacent streams: a sequential sector takes a missing lookup, three loads that attach to its endpoint and look up again after the installation, the installation and look-ahead lookups. With a lookup every cycle instead, the model reads 249 MB/s sequentially and 397 MB/s at a 16-byte stride. For the same reason, two more look-ahead endpoints add 4% to sequential reads with the home's prefetcher on and 21% with it off, and an LQ of 16 adds nothing without a wider ROB.

With the home's prefetcher on, the model reads the sector-adjacent streams 18% to 42% faster than the board; with it off, 16% to 30% slower. The model's prefetcher follows the RTL's agent, so the board's hides less latency for a reason the model omits. Candidates are the home's lookup bandwidth (one service engine at half the CPU clock takes demand requests, prefetch lookups, writebacks and completions in turn, while the model's L2 takes a lookup every CPU cycle), the prefetch pause beside the board's Ethernet DMA, the identity's GrantAck, C and U round trip across the clock boundary, the registered room flag, and the DDR4 controller's bank, refresh and turnaround timing. Strided reads at 128 bytes, which neither mechanism covers, depend on the endpoints' lifetime; a DDR latency near 105 cycles matches them and leaves the chase short by about 90 cycles for each page walk, but makes the store streams 30% to 37% faster than the board, a second open item.

### Open items

- The model's default local BRAM read is 2 cycles, against 10 measured on the RTL (a dependent pointer chase through BRAM data, with its misses aliased in the L0, takes 10.0 cycles per load). The CI check sets 10 in its baseline.
- The model's dependent L0 hit costs 1 cycle, against the RTL's 3 (the same chase with its nodes resident in the L0 takes 3.0 cycles per load).
