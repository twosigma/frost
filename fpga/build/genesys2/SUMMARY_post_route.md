# FROST FPGA Build Summary: genesys2 (post_route)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 0.183 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.023 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.183 ns |
| Data Path Delay | 7.110 ns |
| Logic Delay | 1.229 ns |
| Route Delay | 5.881 ns |
| Logic Levels | 15 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/o_from_ex_to_ma_reg[is_load_instruction]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/pc_controller_inst/o_pc_reg[2]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28162 | 203800 | 13.82% |
| Registers | 18908 | 407600 | 4.64% |
| Block RAM | 68.5 | 445 | 15.39% |
| DSPs | 28 | 840 | 3.33% |
