# FROST Architectural Optimization & Design Refinement Report

**Target Evaluation**: `coremark` (9328 micro-ops simulated)\
**Baseline Performance**: 7631 cycles, **IPC 1.2224**\
**Model Grounding**: FROST `platform_top.sv` (`cpu_top` + `soc_top` single-channel 512-bit AXI memory)

---

## 1. Design Variants Evaluation Summary

| Variant | Cycles | Delta | Speedup | IPC | ROB Stalls | Mem RS Stalls | L2 MSHR Backpressure |
|---|---:|---:|---:|---:|---:|---:|---:|
| `ddr_fast_20cyc` | 6940 | -691 | **+9.06%** | 1.3441 | 670 | 0 | 4 |
| `frost_balanced_v2` | 7084 | -547 | **+7.17%** | 1.3168 | 887 | 0 | 0 |
| `ddr_slow_45cyc` | 7119 | -512 | **+6.71%** | 1.3103 | 614 | 0 | 55 |
| `l2_mshr_12_wb_4` | 7126 | -505 | **+6.62%** | 1.3090 | 644 | 0 | 0 |
| `l2_mshr_8` | 7145 | -486 | **+6.37%** | 1.3055 | 674 | 0 | 3 |
| `l2_mshr_8_wb_4` | 7145 | -486 | **+6.37%** | 1.3055 | 674 | 0 | 3 |
| `l2_prefetch_dist_12` | 7579 | -52 | **+0.68%** | 1.2308 | 894 | 0 | 778 |
| `l2_prefetch_aggressive` | 7579 | -52 | **+0.68%** | 1.2308 | 894 | 0 | 778 |
| `core_lq_sq_12` | 7596 | -35 | **+0.46%** | 1.2280 | 2074 | 590 | 831 |
| `core_expanded_window` | 7598 | -33 | **+0.43%** | 1.2277 | 1037 | 0 | 1111 |
| `core_rob_64` | 7608 | -23 | **+0.30%** | 1.2261 | 477 | 0 | 594 |
| `baseline` | 7631 | +0 | **+0.00%** | 1.2224 | 1105 | 0 | 604 |
| `core_mem_rs_12` | 7631 | +0 | **+0.00%** | 1.2224 | 1105 | 0 | 604 |
| `core_mem_rs_16` | 7631 | +0 | **+0.00%** | 1.2224 | 1105 | 0 | 604 |
| `core_int_rs_24` | 7631 | +0 | **+0.00%** | 1.2224 | 1105 | 0 | 604 |
| `core_int_rs_32` | 7631 | +0 | **+0.00%** | 1.2224 | 1105 | 0 | 604 |
| `l2_waiters_4` | 7631 | +0 | **+0.00%** | 1.2224 | 1105 | 0 | 604 |
| `l2_prefetch_inflight_8` | 7631 | +0 | **+0.00%** | 1.2224 | 1105 | 0 | 604 |
| `early_wakeup_off` | 7633 | +2 | **-0.03%** | 1.2221 | 1105 | 13 | 600 |
| `core_rob_48` | 7676 | +45 | **-0.59%** | 1.2152 | 678 | 0 | 594 |
| `l2_prefetch_off` | 8774 | +1143 | **-14.98%** | 1.0631 | 1360 | 0 | 860 |
| `l0_fastpath_off` | 14520 | +6889 | **-90.28%** | 0.6424 | 8459 | 0 | 604 |

## 2. Identified Hardware Bottlenecks in Current FROST Design

### Bottleneck: `rob` (1105 stall cycles)
- **Diagnosis**: Reorder Buffer (32 entries) fills up while waiting for long-latency instructions.
- **Suggested RTL Refinement**: Increase ROB_DEPTH from 32 to 48 or 64.

### Bottleneck: `l2_mshr` (604 stall cycles)
- **Diagnosis**: L2 MSHR concurrency limit (4 slots) causes backpressure during concurrent cache misses.
- **Suggested RTL Refinement**: Increase L2_NUM_MSHR from 4 to 8, with 4 writeback slots.

## 3. Prioritized Design Recommendations for FROST RTL

1. **Adopt `ddr_fast_20cyc`**: Yields **+9.06% speedup** (691 cycles saved).
2. **Adopt `frost_balanced_v2`**: Yields **+7.17% speedup** (547 cycles saved).
3. **Adopt `ddr_slow_45cyc`**: Yields **+6.71% speedup** (512 cycles saved).
4. **Adopt `l2_mshr_12_wb_4`**: Yields **+6.62% speedup** (505 cycles saved).
5. **Adopt `l2_mshr_8`**: Yields **+6.37% speedup** (486 cycles saved).
