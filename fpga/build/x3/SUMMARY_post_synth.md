# FROST FPGA Build Summary: x3 (post_synth)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | -0.317 ns |
| TNS (Setup) | -118.071 ns (557 failing) |
| WHS (Hold) | -0.104 ns |
| THS (Hold) | -960.902 ns (20694 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.317 ns |
| Data Path Delay | 3.231 ns |
| Logic Delay | 0.555 ns |
| Route Delay | 2.676 ns |
| Logic Levels | 13 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/fpu_inst/sqrt_inst_d/result_exp_reg[2]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/fpu_inst/sqrt_inst_d/is_inexact_apply_reg/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28135 | 1029600 | 2.73% |
| Registers | 16839 | 2059200 | 0.82% |
| Block RAM | 37.5 | 2112 | 1.78% |
| DSPs | 28 | 1320 | 2.12% |
