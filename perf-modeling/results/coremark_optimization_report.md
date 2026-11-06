# FROST Architectural Optimization & Design Refinement Report

**Target Evaluation**: `coremark` (3128 micro-ops simulated)\
**Baseline Performance**: 4632 cycles, **IPC 0.6753**\
**Model Grounding**: FROST `platform_top.sv` (`cpu_top` + `soc_top` single-channel 512-bit AXI memory)

---

## 1. Design Variants Evaluation Summary

| Variant | Cycles | Delta | Speedup | IPC | ROB Stalls | Mem RS Stalls | L2 MSHR Backpressure |
|---|---:|---:|---:|---:|---:|---:|---:|
| `ddr_fast_20cyc` | 2767 | -1865 | **+40.26%** | 1.1305 | 0 | 448 | 173 |
| `ddr_slow_45cyc` | 3512 | -1120 | **+24.18%** | 0.8907 | 0 | 731 | 501 |
| `frost_balanced_v2` | 4233 | -399 | **+8.61%** | 0.7390 | 0 | 1192 | 50 |
| `l2_mshr_8` | 4402 | -230 | **+4.97%** | 0.7106 | 0 | 1078 | 0 |
| `l2_mshr_8_wb_4` | 4402 | -230 | **+4.97%** | 0.7106 | 0 | 1078 | 0 |
| `l2_mshr_12_wb_4` | 4402 | -230 | **+4.97%** | 0.7106 | 0 | 1078 | 0 |
| `core_lq_sq_12` | 4527 | -105 | **+2.27%** | 0.6910 | 349 | 2209 | 1725 |
| `core_expanded_window` | 4584 | -48 | **+1.04%** | 0.6824 | 0 | 1217 | 2119 |
| `baseline` | 4632 | +0 | **+0.00%** | 0.6753 | 0 | 1228 | 921 |
| `core_rob_48` | 4632 | +0 | **+0.00%** | 0.6753 | 0 | 1228 | 921 |
| `core_rob_64` | 4632 | +0 | **+0.00%** | 0.6753 | 0 | 1228 | 921 |
| `core_mem_rs_12` | 4632 | +0 | **+0.00%** | 0.6753 | 0 | 0 | 921 |
| `core_mem_rs_16` | 4632 | +0 | **+0.00%** | 0.6753 | 0 | 0 | 921 |
| `core_int_rs_24` | 4632 | +0 | **+0.00%** | 0.6753 | 0 | 1228 | 921 |
| `core_int_rs_32` | 4632 | +0 | **+0.00%** | 0.6753 | 0 | 1228 | 921 |
| `l2_waiters_4` | 4632 | +0 | **+0.00%** | 0.6753 | 0 | 1228 | 921 |
| `l2_prefetch_inflight_8` | 4632 | +0 | **+0.00%** | 0.6753 | 0 | 1228 | 921 |
| `early_wakeup_off` | 4639 | +7 | **-0.15%** | 0.6743 | 0 | 1235 | 925 |
| `l0_fastpath_off` | 4784 | +152 | **-3.28%** | 0.6538 | 0 | 1313 | 921 |
| `l2_prefetch_dist_12` | 4871 | +239 | **-5.16%** | 0.6422 | 0 | 1317 | 885 |
| `l2_prefetch_aggressive` | 4871 | +239 | **-5.16%** | 0.6422 | 0 | 1317 | 887 |
| `l2_prefetch_off` | 5567 | +935 | **-20.19%** | 0.5619 | 0 | 1843 | 614 |

## 2. Identified Hardware Bottlenecks in Current FROST Design

### Bottleneck: `mem_rs` (1228 stall cycles)
- **Diagnosis**: Memory Reservation Station (8 entries) limits concurrency under memory dependencies.
- **Suggested RTL Refinement**: Increase MEM_RS_DEPTH from 8 to 12 or 16.

### Bottleneck: `l2_mshr` (921 stall cycles)
- **Diagnosis**: L2 MSHR concurrency limit (4 slots) causes backpressure during concurrent cache misses.
- **Suggested RTL Refinement**: Increase L2_NUM_MSHR from 4 to 8, with 4 writeback slots.

## 3. Prioritized Design Recommendations for FROST RTL

1. **Adopt `ddr_fast_20cyc`**: Yields **+40.26% speedup** (1865 cycles saved).
2. **Adopt `ddr_slow_45cyc`**: Yields **+24.18% speedup** (1120 cycles saved).
3. **Adopt `frost_balanced_v2`**: Yields **+8.61% speedup** (399 cycles saved).
4. **Adopt `l2_mshr_8`**: Yields **+4.97% speedup** (230 cycles saved).
5. **Adopt `l2_mshr_8_wb_4`**: Yields **+4.97% speedup** (230 cycles saved).
