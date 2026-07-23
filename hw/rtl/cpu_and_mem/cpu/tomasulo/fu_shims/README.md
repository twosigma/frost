# Functional Unit Shims

Each shim is an adapter between a reservation station's issue port and
one of the CPU's shared functional units. It translates the
generic `rs_issue_t` payload into the FU's native interface, tracks
the in-flight ROB tags, handles back-pressure when the CDB is
contended, and emits a `fu_complete_t` for the CDB arbiter via a
`fu_cdb_adapter`.

The underlying ALU, multiplier, divider, and FPU subunits are shared
with the CPU core. The shims are pure plumbing —
no new arithmetic, just out-of-order glue.

## How they vary

The five shims span a wide range of complexity, driven by the
underlying FU's pipeline depth:

- **`int_alu_shim`** is combinational. Its ALU instance disables and
  elaborates out the stateful multiplier/divider hardware because all
  M-extension operations use `int_muldiv_shim`; the remaining ALU is
  essentially a wire with operand-format conversion. The
  result tag flows directly with the data. Conditional branches
  don't write the CDB at all — branch resolution lives in
  `branch_jump_unit` at top level — but JALR writes its
  link address through here. (JAL is `RS_NONE`: it never reaches an
  RS, and its link value is written at ROB allocation instead.)
  The wrapper instantiates two copies of this shim (CDB slots `ALU`
  and `ALU2`) off the dual-issue INT RS's two issue ports;
  branch-class entries are steered to issue port 0, so only the
  first pipe carries branch/JALR traffic.
- **`fp_add_shim`** wraps shallow FPU pipelines (~2–10 cycles) with
  one in-flight op at a time. A single tag register and a one-hot
  subunit selector are enough. NaN-boxes single-precision results.
- **`fp_mul_shim`** fronts the fully pipelined FMUL and FMA units
  (1 op/cycle each; the DSP tiled multiplier's reduction is a fixed
  3-stage tree for both precisions, so results retire in order).
  Each subunit has its own 32-deep shift-register tag queue, and
  completions drain into a shared 16-deep result FIFO held valid
  until the CDB adapter accepts (`i_mul_accepted`). Credit-based
  back-pressure keys `o_fu_busy` off
  `total_occupancy = mult_count + fma_count + fifo_count` (busy at
  FIFO depth − 2, or either tag queue nearly full) so the FIFO can
  never overflow. NaN-boxes single-precision results.
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
  back-pressure prevents overflow. The sqrt datapaths split unpack/LZC
  from subnormal normalization and exponent adjustment at the front;
  this preserves the fixed 36/65-cycle contracts without a wide
  post-compute padding register.

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
the next push to that slot overwrites them. (`fp_mul_shim`'s result
FIFO currently deviates: it clears both bits on pop, which is
functionally equivalent but puts `i_mul_accepted` on the per-slot
write-enable cone — worth revisiting if it shows up in a timing
report.) Clearing on pop would
pull `i_*_accepted` (derived from the CDB adapter's registered
`result_pending` bit and the shim's own FIFO-head valid) into each
FIFO register's next-state logic, hurting timing on the flush cone.
