# FROST FPGA Build Summary: nexys_a7 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 0.507 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.246 ns |
| THS (Hold) | -12.281 ns (123 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.507 ns |
| Data Path Delay | 10.430 ns |
| Logic Delay | 4.515 ns |
| Route Delay | 5.915 ns |
| Logic Levels | 10 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_0_0/CLKBWRCLK`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/branch_prediction_controller_inst/ras_inst/link_address_r_reg[15]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 14863 | 63400 | 23.44% |
| Registers | 9481 | 126800 | 7.48% |
| Block RAM | 21.5 | 135 | 15.93% |
| DSPs | 8 | 240 | 3.33% |
