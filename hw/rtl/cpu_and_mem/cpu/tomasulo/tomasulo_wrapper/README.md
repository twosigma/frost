# Tomasulo Wrapper

The wrapper instantiates every OOO back-end submodule — ROB, RAT, the
six reservation stations, LQ, SQ, CDB arbiter, FU shims, CDB adapters
— and wires them together behind a single set of ports for
`cpu_ooo.sv`. It also contains a few pieces of inline glue logic that
straddle module boundaries and don't fit cleanly into any one
submodule.

## Why it's not a passive harness

If the wrapper were just module instantiations, the rest of this README
wouldn't exist. The interesting parts are below.

### FMUL operand-repair queue

The FMUL_RS is the only RS that takes 3 source operands (for FMA).
Adding a third dispatch port to the ROB bypass network just for FMUL
would have been wasteful, so when an FMA dispatch arrives at a full
FMUL_RS, the wrapper buffers it in a one-entry queue right outside
the RS. When a slot opens up, the wrapper replays the buffered
entry — re-fetching the bypass values for all three sources from
dedicated FMUL bypass ports on the ROB so any operand that completed
while the entry was queued gets a fresh value.

### SC state machine

Store-conditional execution is split between MEM_RS issue and
ROB-head commit. The MEM_RS issues the SC like a normal store; the
LQ holds the LR reservation register and snoops every SQ memory
write to invalidate it on a matching address. The SC fires only when
its ROB entry reaches the head and the SQ is committed-empty. Its
result is just `~reservation_valid`. On failure, the wrapper sends
a discard signal to the SQ to drop the SC's entry without writing
memory.

### Commit and CDB pipelining

Both the ROB commit bus and the CDB broadcast are registered into
local copies (`commit_bus_q`, `cdb_bus`) before being routed to the
downstream consumers. The valid bits are split out from the payload
and registered separately so a full flush only fans a narrow reset
into a one-bit register instead of the wide payload — a Vivado
synthesis trick to keep flush fanout under control.

The combinational versions are still exposed for the same-cycle
misprediction-detect path in `cpu_ooo.sv` and for FU adapters that
need to clear their hold registers on the same cycle as a grant.

### Dispatch routing

A small case statement on `i_rs_dispatch.rs_type` decodes the
incoming dispatch into per-RS valid signals. All six RS instances
share the same dispatch payload bus — only the valid strobe is
gated. This keeps the routing fanout small and lets the dispatch
unit emit a single struct.

### Flush coordination

The wrapper accepts three flush flavors and forwards them to every
submodule with a consistent ROB head tag for age comparisons:
partial flush (`i_flush_en` + `i_flush_tag`) for branch
mispredictions, full flush (`i_flush_all`) for traps and FENCE.I,
and an early-recovery qualifier (`i_early_recovery_flush`) that
tells the RAT to apply checkpoint restore atomically with the
partial flush.

## What it instantiates

One ROB, one RAT, six RS instances at the depths in
[`../README.md`](../README.md), one LQ (with the L0 cache inside),
one SQ, one CDB arbiter, seven CDB adapters (one per FU slot), and
the four FU shims (`int_alu_shim`, `int_muldiv_shim`, the three FP
shims). The MEM adapter has `ALLOW_GRANT_REFILL=0` so SC commit
ordering can serialize correctly; the others allow back-to-back
refill.

## Verification hooks

Each FU slot has a test-injection input that lets cocotb drive
synthetic completions into the wrapper without exercising the FU
shims, useful for unit-testing the CDB / RS / ROB interaction in
isolation. About 30 live performance counters are exposed, with a
snapshot capture interface for end-of-test reporting.
