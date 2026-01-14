# FROST FPGA Build Summary: nexys_a7 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 0.388 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.249 ns |
| THS (Hold) | -14.926 ns (159 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.388 ns |
| Data Path Delay | 10.860 ns |
| Logic Delay | 4.038 ns |
| Route Delay | 6.822 ns |
| Logic Levels | 16 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/forward_source_reg_1_from_ma_reg/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/pc_controller_inst/o_pc_reg_reg[30]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 9245 | 63400 | 14.58% |
| Registers | 5841 | 126800 | 4.61% |
| Block RAM | 21.5 | 135 | 15.93% |
| DSPs | 4 | 240 | 1.67% |
