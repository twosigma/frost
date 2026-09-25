# Functional Unit Shims

A shim connects a reservation station's issue port to a functional unit (FU).
It turns the RS's `rs_issue_t` into the unit's native ports, tracks the ROB
tags of operations in flight, applies flushes and back-pressure, and packs each
result into a `fu_complete_t` for the slot's
[`fu_cdb_adapter`](../fu_cdb_adapter/README.md). The arithmetic itself lives
in [`ex_stage/`](../../ex_stage/); the shims add none. How much a shim tracks
depends on how many operations its unit can have in flight.

| Shim | RS | Units | Unit latency (cycles) | In flight |
|------|----|-------|-----------------------|-----------|
| `int_alu_shim` (two copies) | INT_RS | ALU | 0 (combinational) | n/a |
| `int_muldiv_shim` | MUL_RS | Multiplier and divider, plus 32-bit word versions | MUL 6, MULW 3, DIV/REM 33, word DIV/REM 17 | Up to 4 per path |
| `fp_add_shim` | FP_RS | FP add, compare, classify, sign-inject, convert | 1 to 10 | 1 |
| `fp_mul_shim` | FMUL_RS | FP multiply, fused multiply-add | FMUL 11, FMA 16 | Up to 14, counting queued results |
| `fp_div_shim` | FDIV_RS | Iterative FP divide and square root | 36 single, 65 double | 1 |

`int_muldiv_shim`, `fp_mul_shim`, and `fp_div_shim` store each result (in a
FIFO, a ring, or a result register) before presenting it, which adds at least
one cycle, more if earlier results are still waiting. `int_alu_shim` and
`fp_add_shim` present a result in the cycle the unit produces it.

## int_alu_shim

The wrapper instantiates two copies on the dual-issue INT RS: `u_alu_shim` on
issue port 0 (CDB slot `FU_ALU`) and `u_alu2_shim` on port 1 (`FU_ALU2`). The
ALU is single-cycle and has no multiplier or divider; M-extension operations
go to `int_muldiv_shim`, and the shim asserts in simulation that none arrive
here. The tag travels with the data and `o_fu_busy` is tied low. Back-pressure
comes from the adapter: a pending ALU adapter deasserts its RS ready.

The RS sends conditional branches and JALR only to port 0, so only
`u_alu_shim` sees them. Conditional branches do not write the CDB:
`o_fu_complete.valid` follows the RS's predecoded `i_issue_writes_cdb_hint`,
and the branch itself resolves in `cpu_ooo`'s `branch_resolution` wrapper
around `branch_jump_unit`. JALR does complete here with its link address. ID
precomputes that address, AUIPC's result, and the fetch-fault `xtval`, and
dispatch places them in the immediate word, so neither the shim nor the ALU
needs the PC. JAL never reaches an RS; the ROB writes its link value at
allocation.

The shim also completes ECALL, EBREAK, illegal instructions, and fetch faults
as exceptions, and sends a CSR instruction's write operand to the CDB; the CSR
itself is read and written at commit.

`u_alu2_shim` sets `USE_SHIFT_AMOUNT_HINT`: the RS precomputes the shift
amount for port 1, and the ALU uses it instead of selecting one itself. The
hint must equal the amount the ALU would have selected.

## int_muldiv_shim

One MUL_RS issue port drives both the multiplier and the divider. Both are
pipelined and accept one operation per cycle. The multiplier takes
`riscv_pkg::MulPipeDepth` cycles (6 at XLEN=64) and the divider XLEN/2+1
(33). Dedicated 32-bit units cut MULW to 3 cycles and DIVW, DIVUW, REMW, and
REMUW to 17; every word result is sign-extended.

Each path has one tag tracker, a shift register as deep as its full-width
unit, and one 4-entry result FIFO, both shared by the two widths. A word
operation enters the tracker partway down, at the stage that lines up with its
shorter unit, so both widths leave through the same tail. If a live
full-width operation is about to pass that stage, the word operation waits;
full-width operations are never held up by it. This busy term depends on the
opcode, which is safe because the RS presents its registered opcode
independently of `ready`, so there is no ready/valid loop.

Back-pressure is credit-based. FIFO occupancy plus unflushed operations in
flight never exceeds the FIFO depth, so each path holds at most four live
operations and its FIFO cannot overflow. The shim has a single `o_fu_busy`, so
a full MUL path also stops divides, and the reverse. A FIFO pops when its
adapter takes the head, or on its own when the head is flushed.

The MUL completion's tag is unspecified while `valid` is low, so the adapter
must use it only with `valid`. `SHORT_WORD_OPS=0` sends word operations
through the full-width units instead; only the tests and formal proofs use it.

## fp_add_shim

`fp_add_shim` drives five FP units: add/subtract (10 cycles), convert (5),
compare (3), classify (1), and sign-inject (1). Only one operation is in
flight at a time, so a single `in_flight` bit and one tag register track it,
and a one-hot `unit_sel_reg` selects which unit's result to present.
`o_fu_busy` is `in_flight`, and the wrapper also stops FP_RS while the adapter
holds a result, so the unit's one-cycle result pulse always finds the adapter
free. A flush that covers the operation sets a `flushed` bit; the result is
dropped when it emerges, and the shim stays busy until then.

## fp_mul_shim

`fp_mul_shim` fronts the pipelined FMUL and FMA units, each accepting one
operation per cycle. FMUL takes 11 cycles and FMA 16 at both precisions,
because the DSP-tiled mantissa multiplier has three stages for single and
double precision (`riscv_pkg::dsp_tiled_stages` pads single precision up to
the double-precision depth). Each unit therefore completes in issue order and
keeps its tags in a 16-entry circular queue.

Completions from both units enter a shared 16-entry ordering ring, which
presents its head until the adapter accepts it (`i_mul_accepted`). The ring
holds the tag, source unit, and flush state. Each unit's 69-bit value and
flags payload sits in its own 16-entry block-RAM FIFO; the RAMs prefetch the
next head, and a one-entry bypass register covers a result that becomes the
head as it is written, so the shim can hand over one result per cycle.
`o_fu_busy` rises when operations in flight plus ring occupancy reach 14 (the
ring depth minus 2). That also keeps each tag queue and the ring at 14 entries
or fewer, so nothing can overflow.

## fp_div_shim

`fp_div_shim` wraps one `fp_div_sqrt_iter`, which runs FDIV.S/D and FSQRT.S/D
on a shared iterative datapath, one operation at a time. An operation
occupies the unit for 36 cycles at single precision and 65 at double. A tag
register tracks the operation in the unit, and a result register then holds
its output until the adapter takes it (`i_div_accepted`). `o_fu_busy` is high
while either is occupied, so a result always has somewhere to go and no queue
is needed.

## Flushes

Every multi-cycle shim takes the full and partial flush inputs. A full flush
squashes everything in flight; a partial flush squashes operations younger
than the flush point, using the same age comparison as the rest of the back
end (`is_younger`, measured from the ROB head). Each shim clears or marks the
squashed entries wherever it tracks them (trackers, tag queues, FIFOs, the
ring, result registers) and drops their results when they emerge. The
pipelined units have no mid-pipeline kill, so a squashed operation rides to
the end of its pipeline and is dropped there.

The iterative divider is the exception: `fp_div_shim` kills the operation
inside the unit (`i_kill`), so FDIV_RS is free again without waiting out the
remaining iterations. An operation the flush already covers never starts, and
a held result the flush covers is cleared (a partial flush also hides it in
the flush cycle).

`fp_mul_shim` and `fp_div_shim` see flushes one cycle late. To keep the widely
fanned flush off their timing paths, the wrapper registers the flush pulse
together with the flush tag and ROB head from the pulse cycle, and these shims
compare ages against those registered values. Their adapters cover the flush
cycle itself. They see the live flush, so their partial-flush check drops a
squashed result; `REGISTER_OUTPUT` keeps any result from passing straight
through; and their full flush lasts one extra cycle to discard a result the
shim presents before its own clear lands. Squashed entries count against the
credits one cycle longer, which only adds back-pressure.

## NaN boxing

FP registers are 64 bits wide. Every FP-result shim presents single-precision
results NaN-boxed, with the upper 32 bits all ones: `fp_add_shim` and
`fp_div_shim` box in the shim, and `fp_mul_shim` receives boxed results from
`fpu_mult_unit` and `fpu_fma_unit`. Integer results (compares, FCLASS,
conversions to integer, FMV.X.W and FMV.X.D) are not boxed. On input, the
shims unbox single-precision operands: an operand whose upper 32 bits are not
all ones reads as the canonical NaN, except that FMV.X.W takes the raw low
bits.

## Result FIFO pops

`int_muldiv_shim`'s MUL and DIV FIFOs advance the read pointer on a pop but
leave the slot's `valid` and `flushed` bits set. The FIFO count is the true
occupancy, and the next push to the slot overwrites the stale bits, so any
logic that reads those bits must also check the count. `fp_mul_shim`'s
ordering ring clears both bits on a pop, and `fp_div_shim` clears its single
result register when the adapter takes it.

## Verification

Each shim has a cocotb target of the same name. `int_alu_shim_shift_hint` and
`int_muldiv_shim_full_width` rerun the ALU and MUL/DIV tests with
`USE_SHIFT_AMOUNT_HINT=1` and `SHORT_WORD_OPS=0`, and the `alu_shift_hint`
formal target proves that the ALU gives the same result with a correct hint as
without one. The FP shims and `int_muldiv_shim` also have formal targets. The
`int_muldiv_shim` proofs are unbounded: under arbitrary flushes and
back-pressure, and for both `SHORT_WORD_OPS` settings, each completing tracker
entry matches the unit that produced its data, and the credit bounds hold.

See the [test runner](../../../../../../tests/README.md) for commands and the
[formal guide](../../../../../../formal/README.md) for proof scope and assumptions.
