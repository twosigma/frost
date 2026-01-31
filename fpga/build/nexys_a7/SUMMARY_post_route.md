# FROST FPGA Build Summary: nexys_a7 (post_route)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 0.078 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.021 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.078 ns |
| Data Path Delay | 11.742 ns |
| Logic Delay | 1.835 ns |
| Route Delay | 9.907 ns |
| Logic Levels | 9 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/pd_stage_inst/o_from_pd_to_id_reg[fp_source_reg_3_early][2]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_3_0_0/WEA[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28222 | 63400 | 44.51% |
| Registers | 19099 | 126800 | 15.06% |
| Block RAM | 37.5 | 135 | 27.78% |
| DSPs | 28 | 240 | 11.67% |
