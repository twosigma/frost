# FROST FPGA Build Summary: x3 (post_synth)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 300.030 MHz |
| Clock Period | 3.333 ns |
| WNS (Setup) | -0.122 ns |
| TNS (Setup) | -48.436 ns (533 failing) |
| WHS (Hold) | -0.104 ns |
| THS (Hold) | -1141.153 ns (24783 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.122 ns |
| Data Path Delay | 3.213 ns |
| Logic Delay | 0.546 ns |
| Route Delay | 2.667 ns |
| Logic Levels | 12 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/o_from_ex_to_ma_reg[is_load_instruction]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/c_ext_state_inst/o_spanning_buffer_reg[0]/CE`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28688 | 1029600 | 2.79% |
| Registers | 18482 | 2059200 | 0.90% |
| Block RAM | 68.5 | 2112 | 3.24% |
| DSPs | 28 | 1320 | 2.12% |
