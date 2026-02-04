# FROST FPGA Build Summary: x3 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 300.030 MHz |
| Clock Period | 3.333 ns |
| WNS (Setup) | -0.675 ns |
| TNS (Setup) | -1414.923 ns (4981 failing) |
| WHS (Hold) | -0.192 ns |
| THS (Hold) | -7.298 ns (121 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.675 ns |
| Data Path Delay | 3.060 ns |
| Logic Delay | 0.618 ns |
| Route Delay | 2.442 ns |
| Logic Levels | 9 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/fpu_inst/adder_inst_s/valid_reg_reg_lopt_merged_replica/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/data_memory/gen_port_a_byte_logic[1].memory_reg_0_0_5/WEA[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 29145 | 1029600 | 2.83% |
| Registers | 19292 | 2059200 | 0.94% |
| Block RAM | 68.5 | 2112 | 3.24% |
| DSPs | 28 | 1320 | 2.12% |
