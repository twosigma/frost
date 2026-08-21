# CoreMark at lp64: measured rv64-vs-rv32 gap

At 300 MHz, X3 scores ~15% lower on classic CoreMark with rv64 than rv32
(827 vs 977). The cause is **classic CoreMark's lp64 behavior, not compiler
settings or RTL.** Pointer-light CoreMark-PRO is near parity on the same
silicon (−0.7% initially; −0.1% on the current re-armed baselines), indicating
that the core did not slow down at rv64.

## Measured decomposition (cycle-exact simulation, one iteration)

Same registry app, same seeds, both XLENs; Tomasulo profile counters
over the timed region:

| | rv32 | rv64 | delta |
|---|---|---|---|
| Instret | 255,700 | 285,711 | **+11.7%** |
| Cycles | 311,094 | 367,907 | +18.3% (cold; warm hw shows −15.35%) |
| IPC | 0.82 | 0.78 | **−4.6%** |

About two-thirds of the gap comes from extra instructions and one-third from
lower IPC.

## Why the instruction count grows (+11.7%)

CoreMark keeps every datum in 32-bit-or-narrower types (`ee_u32`,
`ee_s16`). On rv64 the compiler must maintain 32-bit semantics inside
64-bit registers: the rv64 binary contains 180 `sext.w` sites (rv32: 0)
plus `zext.h`/`addiw`/`addw` forms that do not exist at ilp32. Hot-loop
code generation is otherwise equivalent: the `core_list_find` inner loops use
the same 4-5
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

## Benchmark policy

The dominant term is 32-bit-semantics churn intrinsic to compiling CoreMark
for lp64; flags move both lanes together, and CoreMark rules forbid source
changes. Use the per-XLEN baseline in
`fpga/hw_regression.py::BASELINE_SCORES` ("x3+rv64"), armed from the
first rv64 silicon measurement. For cross-ISA comparisons, use CoreMark-PRO;
its pointer-light workloads show parity across XLENs.
