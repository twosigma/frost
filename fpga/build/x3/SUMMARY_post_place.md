# FROST FPGA Build Summary: x3 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | 0.018 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.204 ns |
| THS (Hold) | -11.208 ns (180 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.018 ns |
| Data Path Delay | 2.903 ns |
| Logic Delay | 1.441 ns |
| Route Delay | 1.462 ns |
| Logic Levels | 8 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_2_0_1/CLKBWRCLK`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/pc_controller_inst/o_pc_reg_reg[26]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 29637 | 1029600 | 2.88% |
| Registers | 19251 | 2059200 | 0.93% |
| Block RAM | 37.5 | 2112 | 1.78% |
| DSPs | 28 | 1320 | 2.12% |
