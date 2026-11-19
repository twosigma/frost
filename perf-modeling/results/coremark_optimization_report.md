# FROST Architectural Optimization & Design Refinement Report

**Target Evaluation**: `coremark` (9328 micro-ops simulated)\
**Baseline Performance**: 7145 cycles, **IPC 1.3055**\
**Model Grounding**: FROST `platform_top.sv` (`cpu_top` + `soc_top` single-channel 512-bit AXI memory)

---

## 1. Design Variants Evaluation Summary

| Variant | Cycles | Delta | Speedup | IPC | ROB Stalls | Mem RS Stalls | L2 MSHR Backpressure |
|---|---:|---:|---:|---:|---:|---:|---:|
| `ddr_fast_20cyc` | 6930 | -215 | **+3.01%** | 1.3460 | 670 | 0 | 0 |
| `ddr_slow_45cyc` | 7004 | -141 | **+1.97%** | 1.3318 | 712 | 0 | 0 |
| `core_rob_64` | 7030 | -115 | **+1.61%** | 1.3269 | 224 | 0 | 3 |
| `core_expanded_window` | 7036 | -109 | **+1.53%** | 1.3258 | 999 | 0 | 0 |
| `frost_balanced_v2` | 7084 | -61 | **+0.85%** | 1.3168 | 887 | 0 | 0 |
| `core_rob_48` | 7092 | -53 | **+0.74%** | 1.3153 | 429 | 0 | 3 |
| `l2_prefetch_inflight_8` | 7115 | -30 | **+0.42%** | 1.3110 | 765 | 0 | 3 |
| `l2_prefetch_aggressive` | 7120 | -25 | **+0.35%** | 1.3101 | 865 | 0 | 3 |
| `l2_mshr_12_wb_4` | 7126 | -19 | **+0.27%** | 1.3090 | 644 | 0 | 0 |
| `l2_prefetch_dist_12` | 7128 | -17 | **+0.24%** | 1.3086 | 737 | 0 | 3 |
| `baseline` | 7145 | +0 | **+0.00%** | 1.3055 | 674 | 0 | 3 |
| `core_mem_rs_12` | 7145 | +0 | **+0.00%** | 1.3055 | 674 | 0 | 3 |
| `core_mem_rs_16` | 7145 | +0 | **+0.00%** | 1.3055 | 674 | 0 | 3 |
| `core_int_rs_24` | 7145 | +0 | **+0.00%** | 1.3055 | 677 | 0 | 3 |
| `core_int_rs_32` | 7145 | +0 | **+0.00%** | 1.3055 | 677 | 0 | 3 |
| `l2_mshr_8` | 7145 | +0 | **+0.00%** | 1.3055 | 674 | 0 | 3 |
| `l2_mshr_8_wb_4` | 7145 | +0 | **+0.00%** | 1.3055 | 674 | 0 | 3 |
| `l2_waiters_4` | 7145 | +0 | **+0.00%** | 1.3055 | 674 | 0 | 3 |
| `early_wakeup_off` | 7147 | +2 | **-0.03%** | 1.3052 | 674 | 13 | 3 |
| `core_lq_sq_12` | 7179 | +34 | **-0.48%** | 1.2993 | 1794 | 590 | 0 |
| `l2_prefetch_off` | 8692 | +1547 | **-21.65%** | 1.0732 | 1338 | 0 | 0 |
| `l0_fastpath_off` | 14046 | +6901 | **-96.59%** | 0.6641 | 8018 | 0 | 3 |

## 2. Identified Hardware Bottlenecks in Current FROST Design

### Bottleneck: `rob` (674 stall cycles)
- **Diagnosis**: Reorder Buffer (32 entries) fills up while waiting for long-latency instructions.
- **Suggested RTL Refinement**: Increase ROB_DEPTH from 32 to 48 or 64.

## 3. Prioritized Design Recommendations for FROST RTL

1. **Adopt `ddr_fast_20cyc`**: Yields **+3.01% speedup** (215 cycles saved).
2. **Adopt `ddr_slow_45cyc`**: Yields **+1.97% speedup** (141 cycles saved).
3. **Adopt `core_rob_64`**: Yields **+1.61% speedup** (115 cycles saved).
4. **Adopt `core_expanded_window`**: Yields **+1.53% speedup** (109 cycles saved).
5. **Adopt `frost_balanced_v2`**: Yields **+0.85% speedup** (61 cycles saved).
