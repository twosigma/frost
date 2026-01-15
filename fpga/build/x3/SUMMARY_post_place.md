# FROST FPGA Build Summary: x3 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | -0.932 ns |
| TNS (Setup) | -1443.706 ns (3528 failing) |
| WHS (Hold) | -0.180 ns |
| THS (Hold) | -7.246 ns (125 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.932 ns |
| Data Path Delay | 2.920 ns |
| Logic Delay | 0.662 ns |
| Route Delay | 2.258 ns |
| Logic Levels | 14 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/id_stage_inst/o_from_id_to_ex_reg[source_reg_1_is_x0]_replica_9/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/pc_controller_inst/o_pc_reg[6]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 10339 | 1029600 | 1.00% |
| Registers | 6122 | 2059200 | 0.30% |
| Block RAM | 21.5 | 2112 | 1.02% |
| DSPs | 4 | 1320 | 0.30% |
