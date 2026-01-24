# FROST FPGA Build Summary: genesys2 (post_synth)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 1.448 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.165 ns |
| THS (Hold) | -48.115 ns (2604 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 1.448 ns |
| Data Path Delay | 5.439 ns |
| Logic Delay | 0.690 ns |
| Route Delay | 4.749 ns |
| Logic Levels | 9 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/pd_stage_inst/o_from_pd_to_id_reg[instruction][source_reg_2][3]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_0_0/WEA[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 14497 | 203800 | 7.11% |
| Registers | 8924 | 407600 | 2.19% |
| Block RAM | 21.5 | 445 | 4.83% |
| DSPs | 8 | 840 | 0.95% |
