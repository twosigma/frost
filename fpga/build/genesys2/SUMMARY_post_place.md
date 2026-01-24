# FROST FPGA Build Summary: genesys2 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 0.237 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.248 ns |
| THS (Hold) | -19.055 ns (298 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.237 ns |
| Data Path Delay | 5.631 ns |
| Logic Delay | 2.101 ns |
| Route Delay | 3.530 ns |
| Logic Levels | 7 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_2_1/CLKARDCLK`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_2_1/DIADI[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 14954 | 203800 | 7.34% |
| Registers | 9481 | 407600 | 2.33% |
| Block RAM | 21.5 | 445 | 4.83% |
| DSPs | 8 | 840 | 0.95% |
