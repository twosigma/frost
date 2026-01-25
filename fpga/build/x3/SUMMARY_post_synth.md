# FROST FPGA Build Summary: x3 (post_synth)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | -0.199 ns |
| TNS (Setup) | -28.687 ns (266 failing) |
| WHS (Hold) | -0.104 ns |
| THS (Hold) | -955.515 ns (20595 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.199 ns |
| Data Path Delay | 3.113 ns |
| Logic Delay | 1.355 ns |
| Route Delay | 1.758 ns |
| Logic Levels | 9 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_2_0_1/CLKBWRCLK`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/pc_controller_inst/o_pc_reg_reg[10]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28597 | 1029600 | 2.78% |
| Registers | 16931 | 2059200 | 0.82% |
| Block RAM | 37.5 | 2112 | 1.78% |
| DSPs | 28 | 1320 | 2.12% |
