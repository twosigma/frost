# FU CDB Adapter

One-deep holding register that sits between a functional unit and the CDB
arbiter. Provides back-pressure signaling, zero-latency combinational
pass-through when the arbiter grants immediately, and pipeline flush support.

## Ports

| Port | Dir | Type | Description |
|------|-----|------|-------------|
| `i_clk` | in | logic | Clock |
| `i_rst_n` | in | logic | Active-low reset |
| `i_fu_result` | in | `fu_complete_t` | FU result (level signal) |
| `o_fu_complete` | out | `fu_complete_t` | To CDB arbiter |
| `i_grant` | in | logic | CDB arbiter grant |
| `o_result_pending` | out | logic | Back-pressure to RS |
| `i_flush` | in | logic | Pipeline flush |

## State Machine

- **IDLE**: Pass-through from `i_fu_result` to `o_fu_complete`
- **PENDING**: Output from held register, waiting for grant
