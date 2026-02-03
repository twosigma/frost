# FROST FPGA Build Summary: genesys2 (post_route)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 0.220 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.034 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.220 ns |
| Data Path Delay | 6.706 ns |
| Logic Delay | 0.223 ns |
| Route Delay | 6.483 ns |
| Logic Levels | 0 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/reset_synchronized_reg_lopt_merged_lopt_replica_4/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/fpu_inst/divider_inst_d/remainder_reg[30]/R`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28189 | 203800 | 13.83% |
| Registers | 18967 | 407600 | 4.65% |
| Block RAM | 68.5 | 445 | 15.39% |
| DSPs | 28 | 840 | 3.33% |
