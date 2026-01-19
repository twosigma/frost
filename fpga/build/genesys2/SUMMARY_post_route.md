# FROST FPGA Build Summary: genesys2 (post_route)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 0.935 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.057 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.935 ns |
| Data Path Delay | 6.510 ns |
| Logic Delay | 2.492 ns |
| Route Delay | 4.018 ns |
| Logic Levels | 9 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_2_0/CLKBWRCLK`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/pc_controller_inst/o_pc_reg[29]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 9720 | 203800 | 4.77% |
| Registers | 6047 | 407600 | 1.48% |
| Block RAM | 21.5 | 445 | 4.83% |
| DSPs | 4 | 840 | 0.48% |
