# FROST FPGA Build Summary: nexys_a7 (post_route)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 0.398 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.024 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.398 ns |
| Data Path Delay | 12.106 ns |
| Logic Delay | 2.585 ns |
| Route Delay | 9.521 ns |
| Logic Levels | 12 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/forward_source_reg_1_from_wb_reg/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/pc_controller_inst/o_pc_reg[26]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 9648 | 63400 | 15.22% |
| Registers | 6047 | 126800 | 4.77% |
| Block RAM | 21.5 | 135 | 15.93% |
| DSPs | 4 | 240 | 1.67% |
