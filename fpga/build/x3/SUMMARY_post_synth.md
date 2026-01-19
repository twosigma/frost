# FROST FPGA Build Summary: x3 (post_synth)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | -0.041 ns |
| TNS (Setup) | -1.348 ns (36 failing) |
| WHS (Hold) | -0.104 ns |
| THS (Hold) | -419.777 ns (9412 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.041 ns |
| Data Path Delay | 2.955 ns |
| Logic Delay | 0.778 ns |
| Route Delay | 2.177 ns |
| Logic Levels | 12 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/forward_source_reg_1_from_wb_reg/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/register_write_data_ma_reg[0]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 9453 | 1029600 | 0.92% |
| Registers | 5499 | 2059200 | 0.27% |
| Block RAM | 21.5 | 2112 | 1.02% |
| DSPs | 4 | 1320 | 0.30% |
