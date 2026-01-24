# FROST FPGA Build Summary: x3 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | -0.870 ns |
| TNS (Setup) | -2172.394 ns (5610 failing) |
| WHS (Hold) | -0.179 ns |
| THS (Hold) | -8.561 ns (157 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.870 ns |
| Data Path Delay | 2.618 ns |
| Logic Delay | 0.549 ns |
| Route Delay | 2.069 ns |
| Logic Levels | 8 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/o_from_ex_to_ma_reg[data_memory_address][11]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_0_1/DINADIN[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 16275 | 1029600 | 1.58% |
| Registers | 9627 | 2059200 | 0.47% |
| Block RAM | 21.5 | 2112 | 1.02% |
| DSPs | 8 | 1320 | 0.61% |
