# FROST FPGA Build Summary: x3 (post_route)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | 0.000 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.011 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.000 ns |
| Data Path Delay | 2.620 ns |
| Logic Delay | 0.884 ns |
| Route Delay | 1.736 ns |
| Logic Levels | 9 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/forward_source_reg_1_from_wb_reg_replica/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_1_0_2/WEA[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 29637 | 1029600 | 2.88% |
| Registers | 19251 | 2059200 | 0.93% |
| Block RAM | 37.5 | 2112 | 1.78% |
| DSPs | 28 | 1320 | 2.12% |
