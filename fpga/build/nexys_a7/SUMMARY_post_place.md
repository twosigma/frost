# FROST FPGA Build Summary: nexys_a7 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 1.003 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.250 ns |
| THS (Hold) | -14.726 ns (209 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 1.003 ns |
| Data Path Delay | 10.540 ns |
| Logic Delay | 4.081 ns |
| Route Delay | 6.459 ns |
| Logic Levels | 11 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_0_0_5/CLKARDCLK`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_3_0_5/DIADI[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28222 | 63400 | 44.51% |
| Registers | 19099 | 126800 | 15.06% |
| Block RAM | 37.5 | 135 | 27.78% |
| DSPs | 28 | 240 | 11.67% |
