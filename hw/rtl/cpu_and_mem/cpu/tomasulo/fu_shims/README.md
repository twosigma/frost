# Functional Unit Shims

Each shim translates an RS `rs_issue_t` into an FU-native request, tracks
in-flight ROB tags, handles CDB back-pressure, and emits `fu_complete_t` through
a `fu_cdb_adapter`.

The ALU, multiplier, divider, and FPU subunits live under `ex_stage/`; the
shims add no arithmetic.

## How they vary

Each shim's structure follows the pipeline depth of the FU it wraps.

- `int_alu_shim` is combinational. The ALU is single-cycle and contains no
  multiplier or divider: M-extension ops issue through `int_muldiv_shim`, and
  the shim asserts in simulation that none arrive here. The result tag flows
  with the data and `o_fu_busy` is tied low. Conditional branches do not
  write the CDB; `o_fu_complete.valid` follows the INT RS's predecoded
  `i_issue_writes_cdb_hint`, and branch resolution happens outside the shims,
  in `cpu_ooo`'s `branch_resolution` wrapper around `branch_jump_unit`. JALR
  does write its link address through here. JAL is `RS_NONE`: it never reaches
  an RS, and the ROB writes its link value at allocation. The wrapper
  instantiates two copies of this shim, `u_alu_shim` on CDB slot `FU_ALU` and
  `u_alu2_shim` on `FU_ALU2`, off the dual-issue INT RS's two issue ports. The
  RS steers branch-class entries to issue port 0, so only the first pipe
  carries branch and JALR traffic.
- `fp_add_shim` wraps the shallow FPU pipelines (2 to about 10 cycles) with
  one op in flight at a time: a single `in_flight` bit, a single `tag_reg`,
  and a one-hot `unit_sel_reg` that picks among the adder, compare,
  classify, sign-inject, and convert subunits.
- `fp_mul_shim` fronts the fully pipelined FMUL and FMA units, one op per
  cycle each. The DSP-tiled multiplier pipeline is 3 stages for both
  precisions (`riscv_pkg::dsp_tiled_stages` pads single precision up to the
  double-precision depth), so each unit's results emerge in issue order.
  Each unit has its own 32-entry circular tag queue, and completions drain
  into a shared 16-deep ordering ring that holds its head valid until the
  CDB adapter accepts it (`i_mul_accepted`). The ring keeps tags, source,
  and flush state; each producer's 69-bit value/flags payload sits in its
  own 16-deep block-RAM FIFO. A synchronous head prefetch and a one-entry
  first-word/pop-refill bypass keep the one-result-per-cycle handoff
  without depending on block-RAM read-during-write behavior. `o_fu_busy`
  is credit-based on `total_occupancy = mult_count + fma_count +
  fifo_count`: busy once that reaches 14 (FIFO depth minus 2) or either
  tag queue holds 31 entries, so the FIFO cannot overflow.
- `int_muldiv_shim` drives both the multiplier and the divider off the same
  MUL_RS issue port. Both units are fully pipelined: the multiplier is
  `riscv_pkg::MulPipeDepth` stages deep (6 at XLEN=64) and the divider is
  XLEN/2+1 stages (33). Each path has a shift-register tag queue alongside
  its pipeline and a 4-entry result FIFO, with credit-based back-pressure
  that compares `fifo_count + inflight_count` against the FIFO depth, so at
  most four unflushed ops sit between a path's pipeline and its FIFO. The
  DIV gate is a registered copy computed from the next-state counts, so
  the RS sees a flop; a simulation tripwire checks it against the
  combinational form every cycle.
- `fp_div_shim` has four sub-pipelines (SP/DP divide and SP/DP sqrt), 36
  stages for SP and 65 for DP, each with its own tag queue and a two-deep
  hold buffer at the tail to absorb back-to-back completions. Two entries
  are enough: needing a third would take three ops in one sub-unit on top of
  three higher-priority holds occupied, six credits in all, and the credit
  gate stops issue at the FIFO depth of four. A fixed-priority arbiter drains
  the four hold buffers into a shared 4-entry result FIFO, and the shim goes
  busy once live tag-queue, hold-buffer, and FIFO occupancy together reach
  the FIFO depth. The sqrt datapaths split unpack/LZC from subnormal
  normalization and exponent adjustment at the front, which keeps the fixed
  36/65-cycle contracts without a wide post-compute padding register.

## Common patterns

All multi-cycle shims accept the partial-flush inputs and apply the same
age comparison (`is_younger`) as the rest of the back-end: in-flight tags
younger than the flush boundary are marked flushed in their tag queues, hold
buffers, and FIFOs, and their results are suppressed when they emerge from
the pipeline. The FUs have no mid-pipeline kill, so a flushed entry rides
the pipeline to completion and is dropped at the output.

Every FP-result shim presents single-precision results NaN-boxed, with the
upper 32 bits set to one. `fp_add_shim` and `fp_div_shim` box in the shim;
`fp_mul_shim` receives already-boxed results from `fpu_mult_unit` and
`fpu_fma_unit`.

## Result-FIFO pop convention

The multi-cycle shims (`int_muldiv_shim` MUL/DIV FIFOs, `fp_div_shim`
output FIFO) advance their read pointer on pop and leave the per-slot
`valid` and `flushed` bits alone. `fifo_count` is the occupancy of record;
a stale bit is never consulted until the next push to that slot overwrites
it. Clearing on pop would pull `i_*_accepted` (the wrapper derives it from
the CDB adapter's registered `result_pending` bit and the shim's own
FIFO-head valid) into each FIFO register's next-state logic. Those
registers are already written by the partial-flush age compare, so the
extra fan-in would cost timing on the flush cone. `fp_mul_shim`'s shared
ordering ring deviates: it clears both bits on pop, which is functionally
equivalent but puts `i_mul_accepted` on the per-slot write-enable cone.
That is worth revisiting if it shows up in a timing report.
