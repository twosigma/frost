# FROST Architectural Optimization & Design Refinement Report

**Target Evaluation**: `coremark` (3128 micro-ops simulated)\
**Baseline Performance**: 3067 cycles, **IPC 1.0199**\
**Model Grounding**: FROST `platform_top.sv` (`cpu_top` + `soc_top` single-channel 512-bit AXI memory)

---

## 1. Design Variants Evaluation Summary

| Variant | Cycles | Delta | Speedup | IPC | ROB Stalls | Mem RS Stalls | L2 MSHR Backpressure |
|---|---:|---:|---:|---:|---:|---:|---:|
| `ddr_fast_20cyc` | 2767 | -300 | **+9.78%** | 1.1305 | 0 | 448 | 173 |
| `frost_balanced_v2` | 2981 | -86 | **+2.80%** | 1.0493 | 0 | 544 | 0 |
| `l2_mshr_8` | 2990 | -77 | **+2.51%** | 1.0462 | 0 | 513 | 0 |
| `l2_mshr_8_wb_4` | 2990 | -77 | **+2.51%** | 1.0462 | 0 | 513 | 0 |
| `l2_mshr_12_wb_4` | 2990 | -77 | **+2.51%** | 1.0462 | 0 | 513 | 0 |
| `core_lq_sq_12` | 3036 | -31 | **+1.01%** | 1.0303 | 348 | 911 | 505 |
| `core_expanded_window` | 3054 | -13 | **+0.42%** | 1.0242 | 0 | 524 | 597 |
| `baseline` | 3067 | +0 | **+0.00%** | 1.0199 | 0 | 560 | 333 |
| `core_rob_48` | 3067 | +0 | **+0.00%** | 1.0199 | 0 | 560 | 333 |
| `core_rob_64` | 3067 | +0 | **+0.00%** | 1.0199 | 0 | 560 | 333 |
| `core_mem_rs_12` | 3067 | +0 | **+0.00%** | 1.0199 | 0 | 0 | 337 |
| `core_mem_rs_16` | 3067 | +0 | **+0.00%** | 1.0199 | 0 | 0 | 337 |
| `core_int_rs_24` | 3067 | +0 | **+0.00%** | 1.0199 | 0 | 560 | 333 |
| `core_int_rs_32` | 3067 | +0 | **+0.00%** | 1.0199 | 0 | 560 | 333 |
| `l2_waiters_4` | 3067 | +0 | **+0.00%** | 1.0199 | 0 | 560 | 333 |
| `l2_prefetch_inflight_8` | 3067 | +0 | **+0.00%** | 1.0199 | 0 | 560 | 333 |
| `early_wakeup_off` | 3073 | +6 | **-0.20%** | 1.0179 | 0 | 565 | 293 |
| `l2_prefetch_dist_12` | 3167 | +100 | **-3.26%** | 0.9877 | 0 | 612 | 333 |
| `l2_prefetch_aggressive` | 3167 | +100 | **-3.26%** | 0.9877 | 0 | 612 | 333 |
| `l0_fastpath_off` | 3219 | +152 | **-4.96%** | 0.9717 | 0 | 645 | 333 |
| `l2_prefetch_off` | 3417 | +350 | **-11.41%** | 0.9154 | 0 | 793 | 214 |
| `ddr_slow_45cyc` | 3512 | +445 | **-14.51%** | 0.8907 | 0 | 731 | 501 |

## 2. Identified Hardware Bottlenecks in Current FROST Design

### Bottleneck: `mem_rs` (560 stall cycles)
- **Diagnosis**: Memory Reservation Station (8 entries) limits concurrency under memory dependencies.
- **Suggested RTL Refinement**: Increase MEM_RS_DEPTH from 8 to 12 or 16.

### Bottleneck: `l2_mshr` (333 stall cycles)
- **Diagnosis**: L2 MSHR concurrency limit (4 slots) causes backpressure during concurrent cache misses.
- **Suggested RTL Refinement**: Increase L2_NUM_MSHR from 4 to 8, with 4 writeback slots.

## 3. Prioritized Design Recommendations for FROST RTL

1. **Adopt `ddr_fast_20cyc`**: Yields **+9.78% speedup** (300 cycles saved).
2. **Adopt `frost_balanced_v2`**: Yields **+2.80% speedup** (86 cycles saved).
3. **Adopt `l2_mshr_8`**: Yields **+2.51% speedup** (77 cycles saved).
4. **Adopt `l2_mshr_8_wb_4`**: Yields **+2.51% speedup** (77 cycles saved).
5. **Adopt `l2_mshr_12_wb_4`**: Yields **+2.51% speedup** (77 cycles saved).
