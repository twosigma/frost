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
| `fp_shim` | FP_RS | Iterative FP engine: every F and D compute instruction | 3 to 139, by operation and operands (see below) | 1 |

`int_muldiv_shim` stores each result in a FIFO before presenting it, which
adds at least one cycle, more if earlier results are still waiting.
`int_alu_shim` and `fp_shim` present a result in the cycle the unit produces
it.

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

## fp_shim

`fp_shim` starts each FP_RS issue on one
[`fp_engine`](../../ex_stage/fpu/fp_engine.sv), which runs every F and D
compute instruction (arithmetic, conversions, compares, min/max, classify,
sign injection, and the FMV moves) one at a time on a single shared adder.
One tag register tracks the operation in the engine. `o_fu_busy` is high
whenever the engine is not idle, its result cycle included, and the wrapper
also stops FP_RS while the adapter holds a result, so the engine's one-cycle
result always finds the adapter free.

The engine's latency, from the issue to the result cycle, depends on the
operation and its operands. Operations whose result the decode cycles settle
(NaN, infinity, and zero operands, invalid operations, divide by zero,
out-of-range conversions, FCLASS, sign injection) take 3 cycles. For normal
operands:

| Operation | Single | Double |
|-----------|--------|--------|
| FADD, FSUB | 12 to 34 | 12 to 34 |
| FMUL | 33 to 34 | 62 to 63 |
| FMADD, FMSUB, FNMADD, FNMSUB | 37 to 60 | 66 to 89 |
| FDIV | 49 to 50 | 70 to 71 |
| FSQRT | 58 to 59 | 79 to 80 |
| Conversions between integer and FP | up to 31 | up to 31 |
| FCVT.S.D, FCVT.D.S | 9 | 9 |
| Compares, FMIN, FMAX | 7 | 7 |
| FMV.X.*, FMV.*.X | 5 | 5 |

Subnormal operands and results take longer, because the engine normalizes
them a few bits per cycle. The slowest case found, a double-precision FMA on
subnormal operands, takes 139 cycles.

## Flushes

Every multi-cycle shim takes the full and partial flush inputs. A full flush
squashes everything in flight; a partial flush squashes operations younger
than the flush point, using the same age comparison as the rest of the back
end (`is_younger`, measured from the ROB head).

`int_muldiv_shim` marks the squashed entries in its trackers and FIFOs and
drops their results when they emerge. Its pipelined units have no
mid-pipeline kill, so a squashed operation rides to the end of its pipeline
and is dropped there.

`fp_shim` kills a squashed operation inside the engine (`i_kill`), which is
idle again on the next cycle, so FP_RS can issue without waiting out the rest
of the operation. An issue the same flush covers never starts. A flush on the
result cycle itself is left to the FP adapter, which sees the same flush and
does not keep a squashed result.

## NaN boxing

FP registers are 64 bits wide. `fp_engine` returns single-precision results
NaN-boxed, with the upper 32 bits all ones. Integer results (compares,
FCLASS, conversions to integer, FMV.X.W and FMV.X.D) are not boxed. On input,
the engine unboxes single-precision operands: an operand whose upper 32 bits
are not all ones reads as the canonical NaN, except that FMV.X.W takes the
raw low bits.

## Result FIFO pops

`int_muldiv_shim`'s MUL and DIV FIFOs advance the read pointer on a pop but
leave the slot's `valid` and `flushed` bits set. The FIFO count is the true
occupancy, and the next push to the slot overwrites the stale bits, so any
logic that reads those bits must also check the count.

## Verification

Each shim has a cocotb target of the same name. `int_alu_shim_shift_hint` and
`int_muldiv_shim_full_width` rerun the ALU and MUL/DIV tests with
`USE_SHIFT_AMOUNT_HINT=1` and `SHORT_WORD_OPS=0`, and the `alu_shift_hint`
formal target proves that the ALU gives the same result with a correct hint as
without one. `fp_shim` and `int_muldiv_shim` also have formal targets. The
`int_muldiv_shim` proofs are unbounded: under arbitrary flushes and
back-pressure, and for both `SHORT_WORD_OPS` settings, each completing tracker
entry matches the unit that produced its data, and the credit bounds hold.
The `fp_shim` proof replaces the engine with a model of arbitrary latency and
result; the `fp_engine_equiv` bench checks the engine itself against Berkeley
SoftFloat, results and flags bit for bit.

See the [test runner](../../../../../../tests/README.md) for commands and the
[formal guide](../../../../../../formal/README.md) for proof scope and assumptions.
