# FROST FPGA Build Summary: x3 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 300.030 MHz |
| Clock Period | 3.333 ns |
| WNS (Setup) | -0.501 ns |
| TNS (Setup) | -506.564 ns (2690 failing) |
| WHS (Hold) | -0.194 ns |
| THS (Hold) | -10.857 ns (272 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.501 ns |
| Data Path Delay | 2.866 ns |
| Logic Delay | 0.686 ns |
| Route Delay | 2.180 ns |
| Logic Levels | 10 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/forward_source_reg_1_from_wb_reg/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/data_memory/gen_port_a_byte_logic[1].memory_reg_3_0_5/WEA[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28880 | 1029600 | 2.80% |
| Registers | 19171 | 2059200 | 0.93% |
| Block RAM | 68.5 | 2112 | 3.24% |
| DSPs | 28 | 1320 | 2.12% |
