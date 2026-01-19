# FROST FPGA Build Summary: x3 (post_route)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | 0.000 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.000 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.000 ns |
| Data Path Delay | 3.002 ns |
| Logic Delay | 0.891 ns |
| Route Delay | 2.111 ns |
| Logic Levels | 11 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ma_stage_inst/o_from_ma_to_wb_reg[regfile_write_data][9]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/register_write_data_ma_reg[0]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 10257 | 1029600 | 1.00% |
| Registers | 6152 | 2059200 | 0.30% |
| Block RAM | 21.5 | 2112 | 1.02% |
| DSPs | 4 | 1320 | 0.30% |
