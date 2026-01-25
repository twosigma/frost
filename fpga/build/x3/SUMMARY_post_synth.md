# FROST FPGA Build Summary: x3 (post_synth)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 300.030 MHz |
| Clock Period | 3.333 ns |
| WNS (Setup) | -0.079 ns |
| TNS (Setup) | -21.940 ns (464 failing) |
| WHS (Hold) | -0.104 ns |
| THS (Hold) | -1141.926 ns (24800 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.079 ns |
| Data Path Delay | 3.170 ns |
| Logic Delay | 0.546 ns |
| Route Delay | 2.624 ns |
| Logic Levels | 12 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/forward_source_reg_1_from_wb_reg/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/c_ext_state_inst/o_spanning_buffer_reg[0]/CE`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28474 | 1029600 | 2.77% |
| Registers | 18481 | 2059200 | 0.90% |
| Block RAM | 68.5 | 2112 | 3.24% |
| DSPs | 28 | 1320 | 2.12% |
