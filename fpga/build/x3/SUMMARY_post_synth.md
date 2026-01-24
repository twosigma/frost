# FROST FPGA Build Summary: x3 (post_synth)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | 0.006 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.104 ns |
| THS (Hold) | -587.077 ns (13178 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.006 ns |
| Data Path Delay | 2.908 ns |
| Logic Delay | 1.285 ns |
| Route Delay | 1.623 ns |
| Logic Levels | 8 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_0_0/CLKBWRCLK`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/pc_controller_inst/o_pc_reg[10]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 15089 | 1029600 | 1.47% |
| Registers | 8935 | 2059200 | 0.43% |
| Block RAM | 21.5 | 2112 | 1.02% |
| DSPs | 8 | 1320 | 0.61% |
