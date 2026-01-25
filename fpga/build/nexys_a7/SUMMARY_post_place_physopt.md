# FROST FPGA Build Summary: nexys_a7 (post_place_physopt)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 0.007 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.344 ns |
| THS (Hold) | -14.766 ns (183 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.007 ns |
| Data Path Delay | 12.395 ns |
| Logic Delay | 2.649 ns |
| Route Delay | 9.746 ns |
| Logic Levels | 12 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/forward_source_reg_1_from_wb_reg/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ma_stage_inst/o_from_ma_to_wb_reg[regfile_write_data][2]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28183 | 63400 | 44.45% |
| Registers | 18890 | 126800 | 14.90% |
| Block RAM | 68.5 | 135 | 50.74% |
| DSPs | 28 | 240 | 11.67% |
