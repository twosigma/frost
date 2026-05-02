# Functional Unit Shims

Each shim is an adapter between a reservation station's issue port and
one of the in-order core's functional units. It translates the
generic `rs_issue_t` payload into the FU's native interface, tracks
the in-flight ROB tags, handles back-pressure when the CDB is
contended, and emits a `fu_complete_t` for the CDB arbiter via a
`fu_cdb_adapter`.

The underlying ALU, multiplier, divider, and FPU subunits are reused
unchanged from the in-order FROST core. The shims are pure plumbing —
no new arithmetic, just out-of-order glue.

## How they vary

The five shims span a wide range of complexity, driven by the
underlying FU's pipeline depth:

- **`int_alu_shim`** is combinational. The ALU has no state, so the
  shim is essentially a wire with operand-format conversion. The
  result tag flows directly with the data. Conditional branches
  don't write the CDB at all — branch resolution lives in
  `branch_jump_unit` at top level — but JAL and JALR write their
  link addresses through here.
- **`fp_add_shim`** and **`fp_mul_shim`** wrap shallow FPU pipelines
  (~2–14 cycles) with one in-flight op at a time. A single tag
  register and a one-hot subunit selector are enough. Both NaN-box
  single-precision results.
- **`int_muldiv_shim`** drives both the multiplier and the divider
  off the same MUL_RS issue port. Both units are fully pipelined:
  the multiplier is 4-stage with up to 4 in-flight multiplies, the
  divider is 17-stage with up to 17 in-flight divisions. Each path
  has its own shift-register tag queue alongside the pipeline and a
  4-entry result FIFO, both with credit-based back-pressure keyed
  off `total_occupancy = fifo_count + inflight_count` to prevent
  FIFO overflow.
- **`fp_div_shim`** is the most complex. It has four sub-pipelines
  (SP/DP × divide/sqrt) with 36 or 65 stages each, each with its own
  tag queue and a two-deep hold buffer at the tail to absorb
  back-to-back completions. A fixed-priority arbiter drains the four
  hold buffers into a shared 4-entry result FIFO. Credit-based
  back-pressure prevents overflow.

## Common patterns

All shims emit `fu_complete_t` and feed `fu_cdb_adapter` instances
in `tomasulo_wrapper`. All multi-cycle shims accept partial-flush
inputs and apply the same age-based comparison used elsewhere in the
back-end: in-flight tags younger than the flush boundary are marked
flushed in their tag queues / hold buffers / FIFOs, and their
results are suppressed when they emerge from the pipeline. The
underlying FUs don't support mid-pipeline kill, so flushed entries
ride the pipeline to completion and get dropped at the output.

Single-precision FP results are NaN-boxed (upper 32 bits set to 1)
in every shim that produces FP results.

## Result-FIFO pop convention

The multi-cycle shims (`int_muldiv_shim` MUL/DIV FIFOs, `fp_div_shim`
output FIFO) advance their read pointer on pop but intentionally do
not clear the per-slot `valid` / `flushed` bits. `fifo_count` is the
authoritative occupancy tracker — the stale bits are ignored until
the next push to that slot overwrites them. Clearing on pop would
pull `i_*_accepted` (which depends on the cross-FU CDB arbiter grant
cone, which depends on `mispredict_recovery_pending`) into each
FIFO register's next-state logic, which previously surfaced as
~140 ps of WNS.
