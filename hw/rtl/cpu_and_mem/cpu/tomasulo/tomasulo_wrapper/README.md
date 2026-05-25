# Tomasulo Wrapper

The wrapper instantiates every OOO back-end submodule — ROB, RAT, the
six reservation stations, LQ, SQ, CDB arbiter, FU shims, CDB adapters
— and wires them together behind a single set of ports for
`cpu_ooo.sv`. It also contains a few pieces of inline glue logic that
straddle module boundaries and don't fit cleanly into any one
submodule.

Some of that glue has been factored into private submodules under this
directory. These are pure RTL boundary moves — the logic bodies were copied
verbatim, so the flattened design is unchanged:

| Submodule | Dir | What it holds |
|-----------|-----|---------------|
| `tomasulo_perf_counters` | `perf/` | The 60 back-end performance counters (accumulate / snapshot / four banks / CSR-style readout). |
| `commit_bus_pipeline` | `commit_bus/` | The four `always_ff` that register the combinational ROB commit bus into `commit_bus_q` / `commit_bus_2_q` plus the decomposed `commit_q_*` fields. |
| `sq_early_addr_pipeline` | `store_addr/` | The dual-ported early store-address stage (register dispatch base+imm, add the next cycle off the dispatch critical path) that produces the two SQ early-address update packets. |
| `dispatch_rs_router` | `dispatch_routing/` | Combinational decode of the dispatch packet(s) into per-RS dispatch-valid signals (slot 1 + slot 2) and the fast slot-1 "intent" signals. |
| `sc_pending_unit` | `atomics/` | Store-conditional resolution: the SC pending-register FSM (set at MEM_RS SC issue, cleared on fire / flush / age), its rob_tag+addr capture, the fire/success decode, and the `sc_fu_complete` packet. |

The per-RS dispatch-valid nets in `dispatch_rs_router` carry `(* max_fanout =
32 *)`; the attribute is preserved both in the submodule and on the wrapper-side
receiving nets (where the fanout to the RS instances occurs), so it survives
flattened or hierarchical synthesis.

The remaining inline glue (the store-misalign + MEM-adapter mux around
`sc_pending_unit`, flush coordination, the FMUL repair queue, FU-shim wiring)
stays in the wrapper: it is tightly coupled to the integration and carries
load-bearing synthesis attributes (`max_fanout`, `keep`) whose placement is best
left undisturbed.

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

The SC pending FSM and its fire/success decode live in
`atomics/sc_pending_unit.sv`; the surrounding store-misalign path and MEM-adapter
mux described below stay in the wrapper.

Store-conditional execution is split between MEM_RS issue and
ROB-head commit. The MEM_RS issues the SC like a normal store; the
LQ holds the LR reservation register and snoops every SQ memory
write to invalidate it on a matching address. The SC fires only when
its ROB entry reaches the head and the SQ is committed-empty. Its
result is just `~reservation_valid`. On failure, the wrapper sends
a discard signal to the SQ to drop the SC's entry without writing
memory.

The `sc_fu_complete` output is registered (`sc_fu_complete_reg`)
before feeding the MEM adapter. The combinational path from the
full-flush term `speculative_flush_all` (driven by `i_flush_all` /
`i_flush_after_head_commit`) through the SC completion logic
(`sc_fire_now` → `mem_fu_to_adapter`) into the MEM slot's CDB input
was the post-synth worst-case cone; the register adds one cycle of SC
CDB latency (SC is rare — zero occurrences in CoreMark — so measured
perf is unchanged) in exchange for WNS. The conflict that the
register would otherwise create is avoided at the source instead:
SC is only armed (`sc_fire_now`) when the LQ is not presenting a
result that same cycle, so the downstream paths that observe SC
ownership of the MEM adapter (`lq_result_accepted`, the LQ's
`i_adapter_result_pending` hint) only need the registered
`sc_fu_complete_reg.valid` and the LQ never loses a result to a
same-cycle mux conflict.

### Commit and CDB pipelining

Both the ROB commit bus and the CDB broadcast are registered into
local copies (`commit_bus_q`, `cdb_bus`) before being routed to the
downstream consumers. The commit-bus registers now live in
`commit_bus/commit_bus_pipeline.sv` (the CDB registers stay inline). The
valid bits are split out from the payload
and registered separately so a full flush only fans a narrow reset
into a one-bit register instead of the wide payload — a Vivado
synthesis trick to keep flush fanout under control. A parallel
slot-2 register (`commit_bus_2_q`) carries the widen-commit
second-retire payload to RAT / SQ.

The combinational versions are still exposed for the same-cycle
misprediction-detect path in `cpu_ooo.sv` and for FU adapters that
need to clear their hold registers on the same cycle as a grant.

### Dispatch routing

Dispatch now emits already-routed per-RS packets for slot 1 and slot 2. The
wrapper (via `dispatch_rs_router`) decodes them into the per-RS dispatch-valid
and intent signals, forwards the packets to the matching RS instances, and
supplies each
resource's ordinary full status plus "full for 2" status back to dispatch, so a
2-wide bundle only fires when same-resource pairs have two free entries. The LQ
and SQ receive matching slot-1/slot-2 allocation packets and preserve program
order by assigning slot 1 to the older free entry when both slots allocate.

### Flush coordination

The wrapper accepts three flush flavors and forwards them to every
submodule with a consistent ROB head tag for age comparisons:
partial flush (`i_flush_en` + `i_flush_tag`) for branch
mispredictions, full flush (`i_flush_all`) for traps and FENCE.I,
and an early-recovery qualifier (`i_early_recovery_flush`) that
tells the RAT to apply checkpoint restore atomically with the
partial flush.

Full-flush CDB suppression is centralized at the CDB arbiter's
`i_kill` input (driven by a local `cdb_kill` copy, itself just
`speculative_flush_all`) rather than replicated in each
`fu_cdb_adapter`'s output-valid cone. This moves a broadly-fanned
flush signal out of every adapter's critical path, so the per-FU
`*_result_accepted` shim-pop signals stay off the flush cone — they
gate only on adapter-pending / result-valid, not on
`speculative_flush_all`. The pending SC register is still cleared on
`speculative_flush_all` so a killed SC never fires.

## What it instantiates

One ROB, one RAT, six RS instances at the depths in
[`../README.md`](../README.md), one LQ (with the L0 cache inside),
one SQ, one CDB arbiter, seven CDB adapters (one per FU slot), and
five FU shims (`int_alu_shim`, `int_muldiv_shim`, `fp_add_shim`,
`fp_mul_shim`, `fp_div_shim` — `int_muldiv_shim` drives two adapter
slots). Only the ALU adapter keeps the default `ALLOW_GRANT_REFILL=1`
(back-to-back single-cycle ALU results); every other adapter (MUL,
DIV, MEM, FP_ADD, FP_MUL, FP_DIV) sets `ALLOW_GRANT_REFILL=0` so CDB
arbitration does not feed back into the FIFO/issue cones (and, for
MEM, so SC commit ordering serializes correctly). The DIV and all
three FP adapters additionally set `REGISTER_OUTPUT=1`.

## Performance counters

The wrapper owns 60 live performance counters (in
`perf/tomasulo_perf_counters.sv`), snapshot-captured in four banks for
end-of-test reporting. In rough groups:

- **Head-wait partitions.** The dominant `head_wait_total` bucket
  is decomposed into `Int / Branch / Mul / MemLoad / MemStore /
  MemAmo / Fp / Fmul / Fdiv`. `head_wait_int` is further split into
  four sub-buckets fed by the INT_RS diagnostic port
  (`operand_wait`, `rs_ready_not_issued`, `stage2`, `post_rs`).
  `head_wait_mem_load` is first split by whether the LQ has a memory
  response in flight (`load_outstanding` for real miss latency vs
  `load_no_outstanding`); the `load_no_outstanding` half is then split
  into five sub-buckets (`addr_pending`, `sq_disambig`, `bus_blocked`,
  `cdb_wait`, `post_lq`), and `bus_blocked` is further split into five
  mutually exclusive causes.
- **Commit stalls.** `commit_blocked_{csr, fence, wfi, mret, trap}`
  attribute cycles where the head sits in the serializing FSM.
- **Widen-commit profile.** `head_and_next_done` (1-wide commit
  fired while head+1 was also retirable — a missed-2-wide diagnostic),
  `head_plus_one_done` (ungated head+1 done), `commit_2_opportunity`
  (pre-FIFO-back-pressure, hazard-gate already applied),
  `commit_2_fire_actual` (actual 2-wide fire count), and a
  four-way `commit_2_blocked` decomposition
  (`head_serial`, `next_serial`, `next_branch_mispred`,
  `next_branch_correct`).
- **FU back-pressure.** Six counters: `Int`, `Mul`, `FpAdd`, `Fmul`,
  and `Fdiv` count cycles where that RS is non-empty but its
  `fu_ready` is deasserted (issue blocked), and `MemResult` counts
  cycles where a MEM result is held because the MEM adapter is still
  pending. (MUL and DIV share the muldiv shim, so there is no separate
  DIV counter.)
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
