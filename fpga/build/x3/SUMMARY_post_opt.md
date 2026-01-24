# FROST FPGA Build Summary: x3 (post_opt)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | -0.269 ns |
| TNS (Setup) | -9.965 ns (84 failing) |
| WHS (Hold) | -0.104 ns |
| THS (Hold) | -733.083 ns (15751 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.269 ns |
| Data Path Delay | 3.183 ns |
| Logic Delay | 0.581 ns |
| Route Delay | 2.602 ns |
| Logic Levels | 13 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/forward_source_reg_1_from_wb_reg/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/register_write_data_ma_reg[1]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 15761 | 1029600 | 1.53% |
| Registers | 9492 | 2059200 | 0.46% |
| Block RAM | 21.5 | 2112 | 1.02% |
| DSPs | 8 | 1320 | 0.61% |
