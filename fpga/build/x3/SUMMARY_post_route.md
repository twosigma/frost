# FROST FPGA Build Summary: x3 (post_route)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 300.030 MHz |
| Clock Period | 3.333 ns |
| WNS (Setup) | 0.013 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.011 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.013 ns |
| Data Path Delay | 2.831 ns |
| Logic Delay | 0.735 ns |
| Route Delay | 2.096 ns |
| Logic Levels | 10 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/register_write_data_ma_rs1_reg[18]_lopt_merged/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/data_memory/gen_port_a_byte_logic[1].memory_reg_1_0_7/WEA[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 29443 | 1029600 | 2.86% |
| Registers | 19466 | 2059200 | 0.95% |
| Block RAM | 68.5 | 2112 | 3.24% |
| DSPs | 28 | 1320 | 2.12% |
