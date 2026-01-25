# FROST FPGA Build Summary: nexys_a7 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | -0.430 ns |
| TNS (Setup) | -11.556 ns (78 failing) |
| WHS (Hold) | -0.344 ns |
| THS (Hold) | -14.766 ns (183 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.430 ns |
| Data Path Delay | 12.086 ns |
| Logic Delay | 3.957 ns |
| Route Delay | 8.129 ns |
| Logic Levels | 10 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/data_memory/gen_port_a_byte_logic[1].memory_reg_0_0_3/CLKARDCLK`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/data_memory/gen_port_a_byte_logic[1].memory_reg_0_0_3/DIADI[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28157 | 63400 | 44.41% |
| Registers | 18890 | 126800 | 14.90% |
| Block RAM | 68.5 | 135 | 50.74% |
| DSPs | 28 | 240 | 11.67% |
