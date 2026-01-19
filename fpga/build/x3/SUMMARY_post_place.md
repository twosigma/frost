# FROST FPGA Build Summary: x3 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | -0.922 ns |
| TNS (Setup) | -1636.937 ns (3770 failing) |
| WHS (Hold) | -0.193 ns |
| THS (Hold) | -10.388 ns (173 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.922 ns |
| Data Path Delay | 2.908 ns |
| Logic Delay | 0.888 ns |
| Route Delay | 2.020 ns |
| Logic Levels | 11 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/forward_source_reg_1_from_wb_reg_replica/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/register_write_data_ma_reg[3]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 10257 | 1029600 | 1.00% |
| Registers | 6152 | 2059200 | 0.30% |
| Block RAM | 21.5 | 2112 | 1.02% |
| DSPs | 4 | 1320 | 0.30% |
