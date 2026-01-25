# FROST FPGA Build Summary: genesys2 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 0.685 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.249 ns |
| THS (Hold) | -24.101 ns (350 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.685 ns |
| Data Path Delay | 6.184 ns |
| Logic Delay | 2.376 ns |
| Route Delay | 3.808 ns |
| Logic Levels | 10 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_0_0_4/CLKARDCLK`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_0_0_4/DIADI[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28329 | 203800 | 13.90% |
| Registers | 19131 | 407600 | 4.69% |
| Block RAM | 37.5 | 445 | 8.43% |
| DSPs | 28 | 840 | 3.33% |
