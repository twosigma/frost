# FROST FPGA Build Summary: x3 (post_synth)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | 0.038 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.104 ns |
| THS (Hold) | -1152.243 ns (24928 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.038 ns |
| Data Path Delay | 2.502 ns |
| Logic Delay | 0.679 ns |
| Route Delay | 1.823 ns |
| Logic Levels | 9 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/pd_stage_inst/o_from_pd_to_id_reg[instruction][source_reg_1][4]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_0_0_0/WEA[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28438 | 1029600 | 2.76% |
| Registers | 18556 | 2059200 | 0.90% |
| Block RAM | 37.5 | 2112 | 1.78% |
| DSPs | 28 | 1320 | 2.12% |
