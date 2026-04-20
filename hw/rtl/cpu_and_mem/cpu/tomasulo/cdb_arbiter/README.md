# CDB Arbiter

A purely combinational fixed-priority arbiter that picks one
functional unit completion per cycle for broadcast on the Common
Data Bus. Seven inputs, one winner per cycle, no internal state.

The priority order is longest-latency first, on the principle that a
unit which has already waited 30 cycles for a result shouldn't get
pushed any further by losing arbitration to a single-cycle ALU op:

```
FP_DIV  >  DIV  >  FP_MUL  >  MUL  >  FP_ADD  >  MEM  >  ALU
```

Losers are held in their per-FU `fu_cdb_adapter` and re-presented
the next cycle. The deeply-pipelined units (MUL, DIV, FDIV) have
additional internal result FIFOs to absorb multi-cycle contention.

## Full-flush kill

The arbiter has an `i_kill` input that suppresses both the CDB
broadcast (`o_cdb.valid`) and the `o_grant` vector during
speculative full-flush recovery. The wrapper drives it from a
local `cdb_kill` copy of `speculative_flush_all`. Centralizing the
kill here — rather than replicating it inside every `fu_cdb_adapter`
output cone — keeps the broadly-fanned flush signal from routing
through each adapter's critical path.

A raw pre-kill `o_grant_raw` is also exported so FU shims can still
pop their FIFOs under kill (the entries are being cleared by the
shim's own flush input on the same edge, so popping is harmless).
This avoids pulling `cdb_kill` back into every shim's FIFO
next-state cone.

## Verification

The whole module is small enough to formally verify exhaustively
under SymbiYosys: the `` `ifdef FORMAL `` block proves the priority
order, that at most one FU is granted per cycle, that the broadcast
fields all match the granted FU, and that the cover properties
exercise every grant target and contention scenario.
