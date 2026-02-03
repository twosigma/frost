# FROST FPGA Build Summary: nexys_a7 (post_route)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 0.035 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.011 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.035 ns |
| Data Path Delay | 11.878 ns |
| Logic Delay | 3.457 ns |
| Route Delay | 8.421 ns |
| Logic Levels | 16 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/id_stage_inst/o_from_id_to_ex_reg[source_reg_1_is_x0]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/data_memory/gen_port_a_byte_logic[1].memory_reg_2_0_6/WEA[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 28183 | 63400 | 44.45% |
| Registers | 18890 | 126800 | 14.90% |
| Block RAM | 68.5 | 135 | 50.74% |
| DSPs | 28 | 240 | 11.67% |
