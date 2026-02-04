# FROST FPGA Build Summary: x3 (post_place_physopt)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 300.030 MHz |
| Clock Period | 3.333 ns |
| WNS (Setup) | -0.328 ns |
| TNS (Setup) | -215.827 ns (1973 failing) |
| WHS (Hold) | -0.192 ns |
| THS (Hold) | -7.109 ns (114 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.328 ns |
| Data Path Delay | 2.698 ns |
| Logic Delay | 0.725 ns |
| Route Delay | 1.973 ns |
| Logic Levels | 9 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/o_from_ex_to_ma_reg[data_memory_address][16]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/data_memory/gen_port_a_byte_logic[1].memory_reg_2_0_6/WEA[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 29443 | 1029600 | 2.86% |
| Registers | 19466 | 2059200 | 0.95% |
| Block RAM | 68.5 | 2112 | 3.24% |
| DSPs | 28 | 1320 | 2.12% |
