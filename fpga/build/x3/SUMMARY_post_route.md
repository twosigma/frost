# FROST FPGA Build Summary: x3 (post_route)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | 0.004 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.011 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.004 ns |
| Data Path Delay | 2.984 ns |
| Logic Delay | 0.891 ns |
| Route Delay | 2.093 ns |
| Logic Levels | 9 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/id_stage_inst/o_from_id_to_ex_reg[source_reg_1_is_x0]_replica_2/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/register_write_data_ma_reg[14]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 16275 | 1029600 | 1.58% |
| Registers | 9627 | 2059200 | 0.47% |
| Block RAM | 21.5 | 2112 | 1.02% |
| DSPs | 8 | 1320 | 0.61% |
