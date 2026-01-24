# FROST FPGA Build Summary: nexys_a7 (post_synth)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 2.183 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.107 ns |
| THS (Hold) | -5.722 ns (73 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 2.183 ns |
| Data Path Delay | 9.558 ns |
| Logic Delay | 1.889 ns |
| Route Delay | 7.669 ns |
| Logic Levels | 10 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/pd_stage_inst/o_from_pd_to_id_reg[fp_source_reg_3_early][3]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_0_0/WEA[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 14479 | 63400 | 22.84% |
| Registers | 8924 | 126800 | 7.04% |
| Block RAM | 21.5 | 135 | 15.93% |
| DSPs | 8 | 240 | 3.33% |
