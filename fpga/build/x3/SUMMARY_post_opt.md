# FROST FPGA Build Summary: x3 (post_opt)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 300.030 MHz |
| Clock Period | 3.333 ns |
| WNS (Setup) | -0.214 ns |
| TNS (Setup) | -125.568 ns (1572 failing) |
| WHS (Hold) | -0.104 ns |
| THS (Hold) | -1293.297 ns (27464 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.214 ns |
| Data Path Delay | 3.305 ns |
| Logic Delay | 0.581 ns |
| Route Delay | 2.724 ns |
| Logic Levels | 12 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/forward_source_reg_1_from_wb_reg/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/c_ext_state_inst/o_spanning_buffer_reg[0]/CE`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28687 | 1029600 | 2.79% |
| Registers | 18848 | 2059200 | 0.92% |
| Block RAM | 68.5 | 2112 | 3.24% |
| DSPs | 28 | 1320 | 2.12% |
