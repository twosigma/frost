# CoreMark at lp64: the measured rv64-vs-rv32 gap

X3 silicon at 300 MHz scores classic CoreMark ~15% lower on the rv64
build than the rv32 build (827 vs 977). This document records the
root-cause investigation so the gap is not re-litigated: **it is an
inherent property of classic CoreMark compiled for lp64, not a
compilation-settings or RTL problem.** CoreMark-PRO, whose workloads are
not pointer-dense, sits near parity (−0.7%) on the same silicon — the
strongest single piece of evidence that the core itself did not get
slower at rv64.

## Measured decomposition (cycle-exact simulation, one iteration)

Same registry app, same seeds, both XLENs; Tomasulo profile counters
over the timed region:

| | rv32 | rv64 | delta |
|---|---|---|---|
| Instret | 255,700 | 285,711 | **+11.7%** |
| Cycles | 311,094 | 367,907 | +18.3% (cold; warm hw shows −15.35%) |
| IPC | 0.82 | 0.78 | **−4.6%** |

The gap is therefore ~2/3 "the compiler emits more instructions" and
~1/3 "each instruction retires a little slower".

## Why the instruction count grows (+11.7%)

CoreMark keeps every datum in 32-bit-or-narrower types (`ee_u32`,
`ee_s16`). On rv64 the compiler must maintain 32-bit semantics inside
64-bit registers: the rv64 binary contains 180 `sext.w` sites (rv32: 0)
plus `zext.h`/`addiw`/`addw` forms in the hot mnemonic mix that simply
do not exist at ilp32. Hot-loop codegen quality is otherwise
EQUIVALENT: the `core_list_find` inner loops are the same 4-5
instructions on both XLENs (retire-trace verified, symbol-scoped, both
lanes), with the same single spill.

## Why IPC drops (−4.6%)

`list_head` is two pointers: 8 bytes at ilp32, 16 at lp64. The list
bench is a serial pointer chase (measured IPC ≈ 0.45-0.47 inside the
find loops on both XLENs), so doubling the node footprint doubles the
cache lines the chase walks and adds load-use stalls. The logical work
is identical — both lanes produce the same crclist/crcmatrix/crcstate
(0xe714/0x1fd7/0x8e3a) — only the bytes moved differ.

## Hypotheses tested and eliminated

- **Missing ISA extensions at rv64**: no — both lanes compile with the
  identical `-march=<xlen>imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_
  zicond_zbkb_zihintpause` string (common.mk composes one string for
  both).
- **`-mcmodel=medany` overhead** (rv64-only flag, needed globally for
  DDR-linked apps): no — a medlow rebuild changes instret by ONE
  instruction (0x45c0f → 0x45c0e); linker relaxation already covers the
  globals.
- **Worse hot-loop codegen**: no — symbol-scoped retire traces of
  `core_bench_list` show equivalent loop bodies.
- **Different logical workload at lp64**: no — validation CRCs match
  exactly.

## What would move the number (and why we don't)

The dominant term is 32-bit-semantics churn, which is intrinsic to
compiling this benchmark for lp64; flags move both lanes together.
Source-level changes are forbidden by CoreMark run rules. The honest
treatment is the per-XLEN baseline in
`fpga/hw_regression.py::BASELINE_SCORES` ("x3+rv64"), armed from the
first rv64 silicon measurement. For cross-ISA marketing-style
comparisons prefer CoreMark-PRO, which is pointer-light and shows the
core at parity across XLENs.
