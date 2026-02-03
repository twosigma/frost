# FROST FPGA Build Summary: genesys2 (post_place_physopt)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 0.265 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.351 ns |
| THS (Hold) | -21.109 ns (180 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.265 ns |
| Data Path Delay | 6.416 ns |
| Logic Delay | 2.419 ns |
| Route Delay | 3.997 ns |
| Logic Levels | 11 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/data_memory/gen_port_a_byte_logic[1].memory_reg_2_0_6/CLKARDCLK`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/data_memory/gen_port_a_byte_logic[1].memory_reg_3_0_6/DIADI[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28189 | 203800 | 13.83% |
| Registers | 18967 | 407600 | 4.65% |
| Block RAM | 68.5 | 445 | 15.39% |
| DSPs | 28 | 840 | 3.33% |
