# FROST FPGA Build Summary: x3 (post_opt)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 300.030 MHz |
| Clock Period | 3.333 ns |
| WNS (Setup) | -0.239 ns |
| TNS (Setup) | -170.066 ns (1822 failing) |
| WHS (Hold) | -0.104 ns |
| THS (Hold) | -1292.757 ns (27455 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.239 ns |
| Data Path Delay | 3.330 ns |
| Logic Delay | 0.581 ns |
| Route Delay | 2.749 ns |
| Logic Levels | 12 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/o_from_ex_to_ma_reg[is_load_instruction]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/c_ext_state_inst/o_spanning_buffer_reg[0]/CE`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28854 | 1029600 | 2.80% |
| Registers | 18848 | 2059200 | 0.92% |
| Block RAM | 68.5 | 2112 | 3.24% |
| DSPs | 28 | 1320 | 2.12% |
