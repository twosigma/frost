# FROST Architectural Optimization & Design Refinement Report

**Target Evaluation**: `coremark` (9328 micro-ops simulated)\
**Baseline Performance**: 9741 cycles, **IPC 0.9576**\
**Model Grounding**: FROST `platform_top.sv` (`cpu_top` + `soc_top` single-channel 512-bit AXI memory)

---

## 1. Design Variants Evaluation Summary

| Variant | Cycles | Delta | Speedup | IPC | ROB Stalls | Mem RS Stalls | L2 MSHR Backpressure |
|---|---:|---:|---:|---:|---:|---:|---:|
| `frost_balanced_v2` | 9189 | -552 | **+5.67%** | 1.0151 | 3011 | 0 | 16 |
| `ddr_fast_20cyc` | 9265 | -476 | **+4.89%** | 1.0068 | 3295 | 0 | 1 |
| `core_rob_64` | 9296 | -445 | **+4.57%** | 1.0034 | 174 | 0 | 528 |
| `ddr_slow_45cyc` | 9377 | -364 | **+3.74%** | 0.9948 | 3296 | 0 | 101 |
| `core_expanded_window` | 9445 | -296 | **+3.04%** | 0.9876 | 3241 | 0 | 871 |
| `core_rob_48` | 9453 | -288 | **+2.96%** | 0.9868 | 2502 | 0 | 528 |
| `l2_mshr_12_wb_4` | 9459 | -282 | **+2.89%** | 0.9862 | 3336 | 0 | 0 |
| `l2_mshr_8` | 9506 | -235 | **+2.41%** | 0.9813 | 3357 | 0 | 5 |
| `l2_mshr_8_wb_4` | 9506 | -235 | **+2.41%** | 0.9813 | 3357 | 0 | 5 |
| `core_lq_sq_12` | 9691 | -50 | **+0.51%** | 0.9625 | 4706 | 490 | 867 |
| `baseline` | 9741 | +0 | **+0.00%** | 0.9576 | 3497 | 0 | 528 |
| `early_wakeup_off` | 9741 | +0 | **+0.00%** | 0.9576 | 3497 | 13 | 528 |
| `core_mem_rs_12` | 9741 | +0 | **+0.00%** | 0.9576 | 3497 | 0 | 528 |
| `core_mem_rs_16` | 9741 | +0 | **+0.00%** | 0.9576 | 3497 | 0 | 528 |
| `core_int_rs_24` | 9741 | +0 | **+0.00%** | 0.9576 | 3497 | 0 | 528 |
| `core_int_rs_32` | 9741 | +0 | **+0.00%** | 0.9576 | 3497 | 0 | 528 |
| `l2_waiters_4` | 9741 | +0 | **+0.00%** | 0.9576 | 3497 | 0 | 528 |
| `l2_prefetch_dist_12` | 9741 | +0 | **+0.00%** | 0.9576 | 3497 | 0 | 528 |
| `l2_prefetch_inflight_8` | 9741 | +0 | **+0.00%** | 0.9576 | 3497 | 0 | 528 |
| `l2_prefetch_aggressive` | 9741 | +0 | **+0.00%** | 0.9576 | 3497 | 0 | 528 |
| `l2_prefetch_off` | 10740 | +999 | **-10.26%** | 0.8685 | 3795 | 0 | 885 |
| `l0_fastpath_off` | 26087 | +16346 | **-167.81%** | 0.3576 | 188 | 0 | 528 |

## 2. Identified Hardware Bottlenecks in Current FROST Design

### Bottleneck: `rob` (3497 stall cycles)
- **Diagnosis**: Reorder Buffer (32 entries) fills up while waiting for long-latency instructions.
- **Suggested RTL Refinement**: Increase ROB_DEPTH from 32 to 48 or 64.

### Bottleneck: `l2_mshr` (528 stall cycles)
- **Diagnosis**: L2 MSHR concurrency limit (4 slots) causes backpressure during concurrent cache misses.
- **Suggested RTL Refinement**: Increase L2_NUM_MSHR from 4 to 8, with 4 writeback slots.

## 3. Prioritized Design Recommendations for FROST RTL

1. **Adopt `frost_balanced_v2`**: Yields **+5.67% speedup** (552 cycles saved).
2. **Adopt `ddr_fast_20cyc`**: Yields **+4.89% speedup** (476 cycles saved).
3. **Adopt `core_rob_64`**: Yields **+4.57% speedup** (445 cycles saved).
4. **Adopt `ddr_slow_45cyc`**: Yields **+3.74% speedup** (364 cycles saved).
5. **Adopt `core_expanded_window`**: Yields **+3.04% speedup** (296 cycles saved).
