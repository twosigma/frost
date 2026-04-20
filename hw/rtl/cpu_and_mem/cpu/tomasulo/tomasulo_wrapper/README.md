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

The `sc_fu_complete` output is registered (`sc_fu_complete_reg`)
before feeding the MEM adapter. The combinational path from
`fence_i_committed` / `mispredict_recovery_pending` through the SC
completion logic into the MEM slot's CDB input was the post-synth
worst-case cone; the register adds one cycle of SC CDB latency
(SC is rare — zero occurrences in CoreMark — so measured perf is
unchanged) in exchange for ~125 ps of WNS. Downstream paths that
observe SC ownership of the MEM adapter (`lq_result_accepted`, the
LQ's adapter-pending hint) consult both the combinational
`sc_fu_complete_valid` and the registered `sc_fu_complete_reg.valid`
so the LQ never loses a result to a same-cycle mux conflict.

### Commit and CDB pipelining

Both the ROB commit bus and the CDB broadcast are registered into
local copies (`commit_bus_q`, `cdb_bus`) before being routed to the
downstream consumers. The valid bits are split out from the payload
and registered separately so a full flush only fans a narrow reset
into a one-bit register instead of the wide payload — a Vivado
synthesis trick to keep flush fanout under control. A parallel
slot-2 register (`commit_bus_2_q`) carries the widen-commit
second-retire payload to RAT / SQ.

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

Full-flush CDB suppression is centralized at the CDB arbiter's
`i_kill` input (driven by a local `cdb_kill` copy) rather than
replicated in each `fu_cdb_adapter`'s output-valid cone. This
moves a broadly-fanned flush signal out of every adapter's critical
path. The DIV, FP_DIV, LQ, and SC `result_accepted` paths are
additionally gated on `!speculative_flush_all` so killed CDB
broadcasts don't retire unclaimed results.

## What it instantiates

One ROB, one RAT, six RS instances at the depths in
[`../README.md`](../README.md), one LQ (with the L0 cache inside),
one SQ, one CDB arbiter, seven CDB adapters (one per FU slot), and
five FU shims (`int_alu_shim`, `int_muldiv_shim`, `fp_add_shim`,
`fp_mul_shim`, `fp_div_shim` — `int_muldiv_shim` drives two adapter
slots). The MEM adapter has `ALLOW_GRANT_REFILL=0` so SC commit
ordering can serialize correctly; the others allow back-to-back
refill.

## Performance counters

The wrapper owns 60 live performance counters, snapshot-captured in
four banks for end-of-test reporting. In rough groups:

- **Head-wait partitions.** The dominant `head_wait_total` bucket
  is decomposed into `Int / Branch / Mul / MemLoad / MemStore /
  MemAmo / Fp / Fmul / Fdiv`. `head_wait_int` is further split into
  four sub-buckets fed by the INT_RS diagnostic port
  (`operand_wait`, `rs_ready_not_issued`, `stage2`, `post_rs`).
  `head_wait_mem_load` is split into five sub-buckets
  (`addr_pending`, `sq_disambig`, `bus_blocked`, `cdb_wait`,
  `post_lq`) and `bus_blocked` is further split into five mutually
  exclusive causes.
- **Commit stalls.** `commit_blocked_{csr, fence, wfi, mret, trap}`
  attribute cycles where the head sits in the serializing FSM.
- **Widen-commit profile.** `head_and_next_done` (2-wide fired),
  `head_plus_one_done` (ungated head+1 done), `commit_2_opportunity`
  (pre-hazard-gate), `commit_2_fire_actual` (post-gate), and a
  four-way `commit_2_blocked` decomposition
  (`head_serial`, `next_serial`, `next_branch_mispred`,
  `next_branch_correct`).
- **FU back-pressure.** One counter per FU adapter for held-result
  cycles.
- **Memory / queue activity.** `mem_disambiguation_wait`,
  `sq_committed_pending`, `sq_mem_write_fire`, `lq_mem_read_fire`,
  `lq_l0_hit`, `lq_l0_fill`.
- **Occupancy sums.** Per-cycle occupancy of ROB, LQ, SQ, and each
  of the six RSes, so the software side can compute average depth.

Snapshot capture fans out via `max_fanout=768`-annotated bank
signals so a single capture-enable strobe doesn't need to drive all
60 counters from one source.

## Verification hooks

Each FU slot has a test-injection input that lets cocotb drive
synthetic completions into the wrapper without exercising the FU
shims, useful for unit-testing the CDB / RS / ROB interaction in
isolation.
