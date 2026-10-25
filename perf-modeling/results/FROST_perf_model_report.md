# FROST Performance Model — Configuration Study (aligned to FROST cpu_top + soc_top)

## Decision

For the model's workload mix on FROST's single-channel 512-bit AXI memory architecture, the best evaluated configuration is **l2_mshr_12**. Its comparative geomean cycle ratio is **0.895** versus the RTL baseline (lower is better). The recommended model configuration is therefore **L2 MSHR = 12** with FROST's 64-byte/512-bit AXI boundary and single-channel DDR endpoint. Retain L1D MSHR = 8 because the current cached-load and L1D ID ownership are both eight-slot bounded. In implementation, stage 8 MSHRs first if it materially lowers Fmax/area risk, then validate the 12-slot endpoint against RTL traces and synthesis.

This is an evidence-backed *model recommendation*, not a claim that the RTL already achieves the reported absolute cycle counts. The candidate remains subject to RTL waveform comparison, synthesis/Fmax/area review, and controller-timing calibration.

## Source-proven baseline

- FROST main pinned at `410aa8f3e866fffb078fc8f7fd3672866d83d131` (22 October 2026): `platform_top.sv` composes `cpu_top.sv` and `soc_top.sv` across a single 6-bit-ID, 512-bit (64B) AXI4 boundary.
- `cpu_top`: two-wide OOO, 32-entry ROB, 8-entry LQ/SQ, 16 KiB L1I, 128 KiB L1D, 2 MiB L2, 4-way caches, L1D MSHR 8, L2 MSHR 4, L2 writeback slots 2, prefetch enabled.
- L1 uses 32-byte lines; the sector adapter feeds a 64-byte L2 and a 512-bit, single-beat AXI boundary. Cache lower IDs are `{type, slot}` and pending fills reserve their victim ways.
- `soc_top`: `soc_axi_slave.sv` decodes physical DDR addresses (`0x8000_0000..`) to a single 5-bit-ID, 512-bit DDR AXI port (connected in simulation to `axi_behavioral_memory.sv` with `LATENCY=30`, `NUM_SLOTS=max(L2MaxSlots, 8)`) and routes low BRAM/MMIO accesses to a single local port.

## Sweep result

| Candidate | Geomean cycles / baseline | Mean cycles | Mean IPC | L2-MSHR backpressure |
|---|---:|---:|---:|---:|
| l2_mshr_12 | 0.895 | 15785.3 | 0.263 | 0 |
| l2_mshr_12_wb_4 | 0.895 | 15785.3 | 0.263 | 0 |
| l2_mshr_8 | 0.925 | 16015.5 | 0.258 | 1377 |
| l2_mshr_8_wb_4 | 0.925 | 16015.5 | 0.258 | 1377 |
| l2_mshr_8_prefetch_off | 0.943 | 16078.7 | 0.238 | 1377 |
| rtl_baseline | 1.000 | 16746.0 | 0.245 | 19908 |

| Workload | Baseline cycles | Recommended cycles | Delta |
|---|---:|---:|---:|
| redis_kv | 6891 | 6866 | -0.4% |
| http_api | 16144 | 16144 | +0.0% |
| faas_cold | 37934 | 37934 | +0.0% |
| linux_service | 24438 | 24438 | +0.0% |
| memory_stress | 12002 | 6340 | -47.2% |
| coremark | 3067 | 2990 | -2.5% |

The baseline has 19908 modeled L2-MSHR backpressure events across the workload set. Enlarging L2 concurrency is a more focused next RTL experiment than enlarging L1D MSHRs: the latter cannot exceed eight without changing the existing four-bit L1D `{type, slot}` ownership/ID contract and is not useful beyond the 8-entry load queue in this model.

## Low-hanging-fruit refinements

1. **Take L2 MSHR from 4 to 12 only after a staged 8-slot RTL build.** The five-bit DDR-facing `{type, slot}` contract can encode up to 16 slots of each type; the model shows lower L2 miss-slot pressure. Check URAM/route/Fmax and response/waiter ordering.
2. **Keep the L2 writeback-slot count at 2 for the recommendation.** The 2-versus-4 paired candidates did not change this workload mix, so four slots have no demonstrated benefit here; revisit under a verified dirty-eviction trace.
3. **Keep the existing L1D MSHR count for this pass.** Its eight slots align with the 8-entry cached-load/LQ resource and the four-bit local downstream ID envelope.
4. **Calibrate before optimizing prefetch policy.** The model keeps the existing stream prefetcher enabled, but its benefit/risk requires traces showing useful-prefetch rate, L2 waiter pressure, and AXI/DDR queue occupancy.

## What the executable model contains

- Explicit `CpuTopModel` (`cpu_top.sv`) and `SocTopModel` (`soc_top.sv`) separation joined by `SocTopPort` across the 6-bit-ID, 512-bit AXI4 boundary.
- Resource-bounded pipeline, ROB/RS/LQ/SQ ownership, CDB pressure, non-speculative stores and branch-recovery penalty.
- Independent L1I/L1D, L2 sector adaptation, MSHR victim reservation/coalescing, writeback slots, transaction-ID checks and valid/ready-style backpressure.
- `soc_axi_slave` physical address decode (DDR vs. local BRAM/MMIO) and a swappable single-channel 512-bit AXI DDR controller (`SingleChannelDdrController`) aligned with `axi_behavioral_memory.sv`.
- Deterministic Redis-like key-value, HTTP/API, FaaS cold-start, Linux-service and memory-stress generators, plus self-tests and a repeatable sweep.

## Calibration and interpretation limits

The cache stage latencies, PLRU/bimodal details, workload instruction mixes, and branch rates are explicit modelling assumptions. Treat sweep results as comparative sensitivity directions until calibrated against Verilator RTL traces.
