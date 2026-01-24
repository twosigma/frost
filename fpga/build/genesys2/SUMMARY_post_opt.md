# FROST FPGA Build Summary: genesys2 (post_opt)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 1.553 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.165 ns |
| THS (Hold) | -74.027 ns (3644 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 1.553 ns |
| Data Path Delay | 5.334 ns |
| Logic Delay | 0.690 ns |
| Route Delay | 4.644 ns |
| Logic Levels | 9 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/fpu_inst/fma_inst/valid_reg_reg/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_0_0/WEA[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 15170 | 203800 | 7.44% |
| Registers | 9481 | 407600 | 2.33% |
| Block RAM | 21.5 | 445 | 4.83% |
| DSPs | 8 | 840 | 0.95% |
