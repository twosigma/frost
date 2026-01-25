# FROST FPGA Build Summary: x3 (post_place_physopt)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 300.030 MHz |
| Clock Period | 3.333 ns |
| WNS (Setup) | -0.294 ns |
| TNS (Setup) | -165.395 ns (1712 failing) |
| WHS (Hold) | -0.194 ns |
| THS (Hold) | -10.871 ns (272 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.294 ns |
| Data Path Delay | 2.651 ns |
| Logic Delay | 0.747 ns |
| Route Delay | 1.904 ns |
| Logic Levels | 9 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/o_from_ex_to_ma_reg[fp_dest_reg][4]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/data_memory/gen_port_a_byte_logic[1].memory_reg_2_0_3/WEA[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 29053 | 1029600 | 2.82% |
| Registers | 19284 | 2059200 | 0.94% |
| Block RAM | 68.5 | 2112 | 3.24% |
| DSPs | 28 | 1320 | 2.12% |
