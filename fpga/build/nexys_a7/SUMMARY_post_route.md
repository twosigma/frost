# FROST FPGA Build Summary: nexys_a7 (post_route)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 0.524 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.021 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.524 ns |
| Data Path Delay | 11.429 ns |
| Logic Delay | 2.067 ns |
| Route Delay | 9.362 ns |
| Logic Levels | 10 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/fpu_inst/divider_inst/valid_reg_reg/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_2_3/WEA[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 14863 | 63400 | 23.44% |
| Registers | 9481 | 126800 | 7.48% |
| Block RAM | 21.5 | 135 | 15.93% |
| DSPs | 8 | 240 | 3.33% |
