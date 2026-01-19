# FROST FPGA Build Summary: genesys2 (post_synth)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 1.382 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.165 ns |
| THS (Hold) | -39.420 ns (2114 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 1.382 ns |
| Data Path Delay | 4.914 ns |
| Logic Delay | 3.181 ns |
| Route Delay | 1.733 ns |
| Logic Levels | 4 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/register_write_data_ma_reg[31]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/alu_inst/multiplier_inst/o_product_result_reg/PCIN[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 9174 | 203800 | 4.50% |
| Registers | 5490 | 407600 | 1.35% |
| Block RAM | 21.5 | 445 | 4.83% |
| DSPs | 4 | 840 | 0.48% |
