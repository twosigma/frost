# FROST FPGA Build Summary: nexys_a7 (post_opt)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | -0.538 ns |
| TNS (Setup) | -1.734 ns (4 failing) |
| WHS (Hold) | -0.107 ns |
| THS (Hold) | -4.386 ns (53 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.538 ns |
| Data Path Delay | 12.855 ns |
| Logic Delay | 3.591 ns |
| Route Delay | 9.264 ns |
| Logic Levels | 19 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/fpu_inst/fma_inst_d/sum_s5a_reg[96]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/fpu_inst/fma_inst_d/lzc_s6_reg[6]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28344 | 63400 | 44.71% |
| Registers | 18873 | 126800 | 14.88% |
| Block RAM | 68.5 | 135 | 50.74% |
| DSPs | 28 | 240 | 11.67% |
