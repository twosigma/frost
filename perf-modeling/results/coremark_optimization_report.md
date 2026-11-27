# FROST Architectural Optimization & Design Refinement Report

**Target Evaluation**: `coremark` (9328 micro-ops simulated)\
**Baseline Performance**: 7054 cycles, **IPC 1.3224**\
**Model Grounding**: FROST `platform_top.sv` (`cpu_top` + `soc_top` single-channel 512-bit AXI memory)

---

## 1. Design Variants Evaluation Summary

| Variant | Cycles | Delta | Speedup | IPC | ROB Stalls | Mem RS Stalls | L2 MSHR Backpressure |
|---|---:|---:|---:|---:|---:|---:|---:|
| `ddr_fast_20cyc` | 6860 | -194 | **+2.75%** | 1.3598 | 784 | 0 | 0 |
| `ddr_slow_45cyc` | 6952 | -102 | **+1.45%** | 1.3418 | 702 | 0 | 0 |
| `core_rob_64` | 6997 | -57 | **+0.81%** | 1.3331 | 370 | 0 | 3 |
| `core_rob_48` | 7010 | -44 | **+0.62%** | 1.3307 | 527 | 0 | 3 |
| `l2_prefetch_inflight_8` | 7024 | -30 | **+0.43%** | 1.3280 | 853 | 0 | 3 |
| `l2_prefetch_aggressive` | 7030 | -24 | **+0.34%** | 1.3269 | 953 | 0 | 3 |
| `l2_mshr_12_wb_4` | 7035 | -19 | **+0.27%** | 1.3259 | 732 | 0 | 0 |
| `l2_prefetch_dist_12` | 7038 | -16 | **+0.23%** | 1.3254 | 825 | 0 | 3 |
| `core_expanded_window` | 7042 | -12 | **+0.17%** | 1.3246 | 1439 | 0 | 0 |
| `core_lq_sq_12` | 7044 | -10 | **+0.14%** | 1.3242 | 1755 | 449 | 0 |
| `baseline` | 7054 | +0 | **+0.00%** | 1.3224 | 762 | 0 | 3 |
| `core_mem_rs_12` | 7054 | +0 | **+0.00%** | 1.3224 | 762 | 0 | 3 |
| `core_mem_rs_16` | 7054 | +0 | **+0.00%** | 1.3224 | 762 | 0 | 3 |
| `core_int_rs_24` | 7054 | +0 | **+0.00%** | 1.3224 | 765 | 0 | 3 |
| `core_int_rs_32` | 7054 | +0 | **+0.00%** | 1.3224 | 765 | 0 | 3 |
| `l2_mshr_8` | 7054 | +0 | **+0.00%** | 1.3224 | 762 | 0 | 3 |
| `l2_mshr_8_wb_4` | 7054 | +0 | **+0.00%** | 1.3224 | 762 | 0 | 3 |
| `l2_waiters_4` | 7054 | +0 | **+0.00%** | 1.3224 | 762 | 0 | 3 |
| `early_wakeup_off` | 7070 | +16 | **-0.23%** | 1.3194 | 762 | 13 | 3 |
| `frost_balanced_v2` | 7172 | +118 | **-1.67%** | 1.3006 | 1534 | 0 | 0 |
| `l2_prefetch_off` | 9139 | +2085 | **-29.56%** | 1.0207 | 1533 | 0 | 0 |
| `l0_fastpath_off` | 13963 | +6909 | **-97.94%** | 0.6681 | 8251 | 0 | 3 |

## 2. Identified Hardware Bottlenecks in Current FROST Design

### Bottleneck: `rob` (762 stall cycles)
- **Diagnosis**: Reorder Buffer (32 entries) fills up while waiting for long-latency instructions.
- **Suggested RTL Refinement**: Increase ROB_DEPTH from 32 to 48 or 64.

## 3. Prioritized Design Recommendations for FROST RTL

1. **Adopt `ddr_fast_20cyc`**: Yields **+2.75% speedup** (194 cycles saved).
2. **Adopt `ddr_slow_45cyc`**: Yields **+1.45% speedup** (102 cycles saved).
3. **Adopt `core_rob_64`**: Yields **+0.81% speedup** (57 cycles saved).
4. **Adopt `core_rob_48`**: Yields **+0.62% speedup** (44 cycles saved).
