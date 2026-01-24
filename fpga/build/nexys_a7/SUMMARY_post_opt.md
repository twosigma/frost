# FROST FPGA Build Summary: nexys_a7 (post_opt)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 2.353 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.107 ns |
| THS (Hold) | -5.722 ns (73 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 2.353 ns |
| Data Path Delay | 9.388 ns |
| Logic Delay | 2.013 ns |
| Route Delay | 7.375 ns |
| Logic Levels | 11 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/o_from_ex_to_ma_reg[data_memory_address][10]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_0_0/WEA[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 15135 | 63400 | 23.87% |
| Registers | 9481 | 126800 | 7.48% |
| Block RAM | 21.5 | 135 | 15.93% |
| DSPs | 8 | 240 | 3.33% |
