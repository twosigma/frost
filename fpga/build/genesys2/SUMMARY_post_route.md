# FROST FPGA Build Summary: genesys2 (post_route)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 0.043 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.050 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.043 ns |
| Data Path Delay | 6.807 ns |
| Logic Delay | 0.204 ns |
| Route Delay | 6.603 ns |
| Logic Levels | 0 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/reset_synchronizer_shift_register_reg[2]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/fpu_inst/fma_inst_d/normalized_sum_s7_reg[31]/R`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28329 | 203800 | 13.90% |
| Registers | 19131 | 407600 | 4.69% |
| Block RAM | 37.5 | 445 | 8.43% |
| DSPs | 28 | 840 | 3.33% |
