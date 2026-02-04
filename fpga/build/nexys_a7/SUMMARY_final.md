# FROST FPGA Build Summary: nexys_a7 (final)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 0.135 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.022 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.135 ns |
| Data Path Delay | 12.129 ns |
| Logic Delay | 2.690 ns |
| Route Delay | 9.439 ns |
| Logic Levels | 12 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/o_from_ex_to_ma_reg[is_load_instruction]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/pc_controller_inst/o_pc_reg[2]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28159 | 63400 | 44.41% |
| Registers | 18878 | 126800 | 14.89% |
| Block RAM | 68.5 | 135 | 50.74% |
| DSPs | 28 | 240 | 11.67% |
