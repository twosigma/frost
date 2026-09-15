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
  does write its link address through here; dispatch places it in the
  immediate word, and AUIPC and the fetch-fault pseudo-ops likewise arrive
  with their PC-relative values precomputed by ID in the immediate, so
  neither the shim nor the ALU takes a PC. JAL is `RS_NONE`: it never reaches
  an RS, and the ROB writes its link value at allocation. The wrapper
  instantiates two copies of this shim, `u_alu_shim` on CDB slot `FU_ALU` and
  `u_alu2_shim` on `FU_ALU2`, off the dual-issue INT RS's two issue ports. The
  RS steers branch-class entries to issue port 0, so only the first pipe
  carries branch and JALR traffic. Its ALU shares a combinational shift/rotate
  barrel for each of the full-width and 32-bit word domains, using bit
  reversal for left operations. Narrow operation-control projections are
  checked against every symbolic consuming enum value; no pipeline stage,
  issue latency, or completion latency is added.
  Only `u_alu2_shim` enables `USE_SHIFT_AMOUNT_HINT`: its six-bit
  `i_shift_amount_hint` is captured with the RS's existing issue2 operands.
  The default shim/ALU ignores this port and keeps local amount selection.
  Both use the shared package predicate and unchanged symbolic enum checks.
  `int_alu_shim_shift_hint` runs the existing arithmetic/barrel suite with
  the hint enabled; `alu_shift_hint` compares actual enabled/default ALUs
  for arbitrary binary inputs, without making a physical timing claim.
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
- `fp_div_shim` wraps one `fp_div_sqrt_iter`, which runs FDIV.S/D and
  FSQRT.S/D on a shared iterative datapath, one operation at a time. Latency
  is 36 cycles at single precision and 65 at double, the counts the four
  unrolled pipelines it replaced had, and the shim adds one cycle for its
  result register, so a completion is visible 36 or 65 cycles after issue.
  State is a tag register for the operation in the unit and one result
  register that keeps presenting its result until `i_div_accepted`.
  `o_fu_busy` is exactly those two places occupied, which is why no tag
  queue, hold buffer, arbiter or FIFO is needed: nothing can complete with
  nowhere to go. The unit takes a kill input, so a flush that covers the
  operation in progress drops it where it is.

## Common patterns

All multi-cycle shims accept the partial-flush inputs and apply the same
age comparison (`is_younger`) as the rest of the back-end: in-flight tags
younger than the flush boundary are marked flushed in their tag queues, hold
buffers, and FIFOs, and their results are suppressed when they emerge from
the pipeline. The pipelined FUs have no mid-pipeline kill, so a flushed entry
rides the pipeline to completion and is dropped at the output. The iterative
divide/sqrt unit is the exception: `fp_div_shim` kills it outright, so the
FDIV RS is free again without waiting out the remaining digit steps.

Every FP-result shim presents single-precision results NaN-boxed, with the
upper 32 bits set to one. `fp_add_shim` and `fp_div_shim` box in the shim;
`fp_mul_shim` receives already-boxed results from `fpu_mult_unit` and
`fpu_fma_unit`.

## Result-FIFO pop convention

`int_muldiv_shim`'s MUL and DIV FIFOs advance their read pointer on pop and
leave the per-slot `valid` and `flushed` bits alone. `fifo_count` is the
occupancy of record; a stale bit is never consulted until the next push to
that slot overwrites it. Clearing on pop would pull `i_*_accepted` (the
wrapper derives it from the CDB adapter's registered `result_pending` bit and
the shim's own FIFO-head valid) into each FIFO register's next-state logic.
Those registers are already written by the partial-flush age compare, so the
extra fan-in would cost timing on the flush cone. `fp_mul_shim`'s shared
ordering ring deviates: it clears both bits on pop, which is functionally
equivalent but puts `i_mul_accepted` on the per-slot write-enable cone.
That is worth revisiting if it shows up in a timing report. `fp_div_shim`
holds a single result register rather than a FIFO, and clears it on
acceptance.
