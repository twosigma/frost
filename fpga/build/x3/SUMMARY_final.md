# FROST FPGA Build Summary: x3 (final)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 300.030 MHz |
| Clock Period | 3.333 ns |
| WNS (Setup) | 0.000 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.002 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.000 ns |
| Data Path Delay | 2.821 ns |
| Logic Delay | 0.927 ns |
| Route Delay | 1.894 ns |
| Logic Levels | 9 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ma_stage_inst/o_from_ma_to_wb_reg[regfile_write_data][16]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/data_memory/gen_port_a_byte_logic[1].memory_reg_3_0_1/WEA[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 29053 | 1029600 | 2.82% |
| Registers | 19284 | 2059200 | 0.94% |
| Block RAM | 68.5 | 2112 | 3.24% |
| DSPs | 28 | 1320 | 2.12% |
