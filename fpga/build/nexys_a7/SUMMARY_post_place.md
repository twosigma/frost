# FROST FPGA Build Summary: nexys_a7 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 0.512 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.248 ns |
| THS (Hold) | -16.072 ns (151 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.512 ns |
| Data Path Delay | 10.811 ns |
| Logic Delay | 1.932 ns |
| Route Delay | 8.879 ns |
| Logic Levels | 10 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/forward_source_reg_1_from_ma_reg/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/register_write_data_ma_reg[24]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 9648 | 63400 | 15.22% |
| Registers | 6047 | 126800 | 4.77% |
| Block RAM | 21.5 | 135 | 15.93% |
| DSPs | 4 | 240 | 1.67% |
