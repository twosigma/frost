# CDB Arbiter

Priority-based multiplexer that selects one functional unit completion per cycle
for broadcast on the Common Data Bus (CDB).

## Overview

The CDB arbiter receives completion requests from all 7 functional units and
grants the CDB to exactly one per cycle using fixed-priority arbitration.
Longer-latency FUs get higher priority to avoid further stalling.

## Interface

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `i_clk` | in | 1 | Clock (for formal only) |
| `i_rst_n` | in | 1 | Reset (for formal only) |
| `i_fu_complete[7]` | in | 7×81 | FU completion requests |
| `o_cdb` | out | 84 | CDB broadcast (to RS + ROB) |
| `o_grant[6:0]` | out | 7 | Per-FU grant signals |

## Priority Order

| Priority | FU Type | Latency |
|----------|---------|---------|
| 1 (highest) | FP_DIV | ~32-35 cycles |
| 2 | DIV | 17 cycles |
| 3 | FP_MUL | ~8-9 cycles |
| 4 | MUL | 4 cycles |
| 5 | FP_ADD | ~4-5 cycles |
| 6 | MEM | variable |
| 7 (lowest) | ALU | combinational |

## Verification

- **Formal**: BMC (depth 4) + cover (depth 8) via `formal/cdb_arbiter.sby`
- **Cocotb**: 16 unit tests in `verif/cocotb_tests/tomasulo/cdb_arbiter/`

## Files

- `cdb_arbiter.sv` — RTL + formal assertions
- `cdb_arbiter.f` — filelist
