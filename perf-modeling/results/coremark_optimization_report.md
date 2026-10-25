# FROST Architectural Optimization & Design Refinement Report

**Target Evaluation**: `coremark` (3128 micro-ops simulated)\
**Baseline Performance**: 3101 cycles, **IPC 1.0087**\
**Model Grounding**: FROST `platform_top.sv` (`cpu_top` + `soc_top` single-channel 512-bit AXI memory)

---

## 1. Design Variants Evaluation Summary

| Variant | Cycles | Delta | Speedup | IPC | ROB Stalls | Mem RS Stalls | L2 MSHR Backpressure |
|---|---:|---:|---:|---:|---:|---:|---:|
| `ddr_fast_20cyc` | 2814 | -287 | **+9.26%** | 1.1116 | 0 | 465 | 169 |
| `frost_balanced_v2` | 3019 | -82 | **+2.64%** | 1.0361 | 0 | 549 | 0 |
| `l2_mshr_8` | 3035 | -66 | **+2.13%** | 1.0306 | 0 | 529 | 0 |
| `l2_mshr_8_wb_4` | 3035 | -66 | **+2.13%** | 1.0306 | 0 | 529 | 0 |
| `l2_mshr_12_wb_4` | 3035 | -66 | **+2.13%** | 1.0306 | 0 | 529 | 0 |
| `core_lq_sq_12` | 3061 | -40 | **+1.29%** | 1.0219 | 348 | 928 | 459 |
| `core_expanded_window` | 3078 | -23 | **+0.74%** | 1.0162 | 0 | 535 | 545 |
| `baseline` | 3101 | +0 | **+0.00%** | 1.0087 | 0 | 568 | 290 |
| `core_rob_48` | 3101 | +0 | **+0.00%** | 1.0087 | 0 | 568 | 290 |
| `core_rob_64` | 3101 | +0 | **+0.00%** | 1.0087 | 0 | 568 | 290 |
| `core_mem_rs_12` | 3101 | +0 | **+0.00%** | 1.0087 | 0 | 0 | 294 |
| `core_mem_rs_16` | 3101 | +0 | **+0.00%** | 1.0087 | 0 | 0 | 294 |
| `core_int_rs_24` | 3101 | +0 | **+0.00%** | 1.0087 | 0 | 568 | 290 |
| `core_int_rs_32` | 3101 | +0 | **+0.00%** | 1.0087 | 0 | 568 | 290 |
| `l2_waiters_4` | 3101 | +0 | **+0.00%** | 1.0087 | 0 | 568 | 290 |
| `l2_prefetch_inflight_8` | 3101 | +0 | **+0.00%** | 1.0087 | 0 | 568 | 290 |
| `early_wakeup_off` | 3114 | +13 | **-0.42%** | 1.0045 | 0 | 581 | 289 |
| `l2_prefetch_dist_12` | 3203 | +102 | **-3.29%** | 0.9766 | 0 | 616 | 290 |
| `l2_prefetch_aggressive` | 3203 | +102 | **-3.29%** | 0.9766 | 0 | 616 | 290 |
| `l2_prefetch_off` | 3442 | +341 | **-11.00%** | 0.9088 | 0 | 791 | 210 |
| `ddr_slow_45cyc` | 3548 | +447 | **-14.41%** | 0.8816 | 0 | 733 | 501 |
| `l0_fastpath_off` | 3795 | +694 | **-22.38%** | 0.8242 | 0 | 805 | 290 |

## 2. Identified Hardware Bottlenecks in Current FROST Design

### Bottleneck: `mem_rs` (568 stall cycles)
- **Diagnosis**: Memory Reservation Station (8 entries) limits concurrency under memory dependencies.
- **Suggested RTL Refinement**: Increase MEM_RS_DEPTH from 8 to 12 or 16.

### Bottleneck: `l2_mshr` (290 stall cycles)
- **Diagnosis**: L2 MSHR concurrency limit (4 slots) causes backpressure during concurrent cache misses.
- **Suggested RTL Refinement**: Increase L2_NUM_MSHR from 4 to 8, with 4 writeback slots.

## 3. Prioritized Design Recommendations for FROST RTL

1. **Adopt `ddr_fast_20cyc`**: Yields **+9.26% speedup** (287 cycles saved).
2. **Adopt `frost_balanced_v2`**: Yields **+2.64% speedup** (82 cycles saved).
3. **Adopt `l2_mshr_8`**: Yields **+2.13% speedup** (66 cycles saved).
4. **Adopt `l2_mshr_8_wb_4`**: Yields **+2.13% speedup** (66 cycles saved).
5. **Adopt `l2_mshr_12_wb_4`**: Yields **+2.13% speedup** (66 cycles saved).
