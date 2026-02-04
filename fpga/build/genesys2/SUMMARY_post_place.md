# FROST FPGA Build Summary: genesys2 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 0.309 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.328 ns |
| THS (Hold) | -17.211 ns (217 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.309 ns |
| Data Path Delay | 6.337 ns |
| Logic Delay | 2.370 ns |
| Route Delay | 3.967 ns |
| Logic Levels | 10 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/data_memory/gen_port_a_byte_logic[1].memory_reg_0_0_0/CLKARDCLK`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/data_memory/gen_port_a_byte_logic[1].memory_reg_2_0_0/DIADI[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28162 | 203800 | 13.82% |
| Registers | 18908 | 407600 | 4.64% |
| Block RAM | 68.5 | 445 | 15.39% |
| DSPs | 28 | 840 | 3.33% |
