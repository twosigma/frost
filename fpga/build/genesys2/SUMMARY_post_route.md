# FROST FPGA Build Summary: genesys2 (post_route)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 0.836 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.056 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.836 ns |
| Data Path Delay | 5.945 ns |
| Logic Delay | 0.362 ns |
| Route Delay | 5.583 ns |
| Logic Levels | 1 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/reset_synchronizer_shift_register_reg[2]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/fpu_inst/fma_inst/sum_s6_reg[23]/R`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 14954 | 203800 | 7.34% |
| Registers | 9481 | 407600 | 2.33% |
| Block RAM | 21.5 | 445 | 4.83% |
| DSPs | 8 | 840 | 0.95% |
