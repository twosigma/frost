# FROST FPGA Build Summary: genesys2 (post_synth)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 0.083 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.165 ns |
| THS (Hold) | -49.776 ns (3103 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.083 ns |
| Data Path Delay | 7.244 ns |
| Logic Delay | 1.240 ns |
| Route Delay | 6.004 ns |
| Logic Levels | 17 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/fpu_inst/fma_inst_d/sum_s5a_reg[96]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/fpu_inst/fma_inst_d/lzc_s6_reg[3]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28200 | 203800 | 13.84% |
| Registers | 18496 | 407600 | 4.54% |
| Block RAM | 68.5 | 445 | 15.39% |
| DSPs | 28 | 840 | 3.33% |
