# FROST FPGA Build Summary: nexys_a7 (post_place_physopt)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 0.496 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.327 ns |
| THS (Hold) | -14.623 ns (141 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.496 ns |
| Data Path Delay | 11.316 ns |
| Logic Delay | 2.891 ns |
| Route Delay | 8.425 ns |
| Logic Levels | 12 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/l0_cache_inst/data_loaded_from_cache_reg_reg[19]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/data_memory/gen_port_a_byte_logic[1].memory_reg_1_0_0/WEA[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28159 | 63400 | 44.41% |
| Registers | 18878 | 126800 | 14.89% |
| Block RAM | 68.5 | 135 | 50.74% |
| DSPs | 28 | 240 | 11.67% |
