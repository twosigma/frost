# FROST FPGA Build Summary: nexys_a7 (post_route)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 0.900 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.030 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.900 ns |
| Data Path Delay | 11.527 ns |
| Logic Delay | 3.099 ns |
| Route Delay | 8.428 ns |
| Logic Levels | 13 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/forward_source_reg_1_from_ma_reg/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/register_write_data_ma_reg[24]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 9245 | 63400 | 14.58% |
| Registers | 5841 | 126800 | 4.61% |
| Block RAM | 21.5 | 135 | 15.93% |
| DSPs | 4 | 240 | 1.67% |
