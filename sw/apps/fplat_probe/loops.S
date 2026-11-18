/*
 * Copyright (c) 2026 John Goodacre.
 *
 * Timing loops for fplat_probe. Each loop takes a0 = timed groups and
 * a1 = the constant table (doubles at 0(a1), singles at 128(a1)), and
 * returns the cycles of the timed groups (16 bodies per group). A dependent
 * loop chains both operations of its body through f0; a throughput loop's
 * body writes f0..f15 from constant sources. sscratch carries a2 (a trace
 * id) during the timed window.
 */
    .option norvc
    .text

/* Constant slots (index * 8 for doubles, 128 + index * 4 for singles). */
#define K_ONE 0
#define K_C11 1
#define K_INV11 2
#define K_C07 3
#define K_M07 4
#define K_HALF 5
#define K_MHALF11 6
#define K_QUARTER 7
#define K_C15 8

.macro LDK prec, reg, k
.ifc \prec, d
    fld \reg, (\k * 8)(a1)
.else
    flw \reg, (128 + \k * 4)(a1)
.endif
.endm

.macro PROLOGUE
    li t0, 0x6000
    csrs mstatus, t0
.endm

.macro TSTART
    csrw sscratch, a2
    rdcycle t1
1:
.endm

.macro TEND
    addi a0, a0, -1
    bnez a0, 1b
    rdcycle t2
    csrw sscratch, zero
    sub a0, t2, t1
    ret
.endm

/* 16 bodies of two dependent operations. */
.macro TIMED2 i1:req, i2:req
    TSTART
    .rept 16
    \i1
    \i2
    .endr
    TEND
.endm

/* 16 bodies of 16 independent operations: op f0..f15, srcs. */
.macro TIMED16 op:req, srcs:req
    TSTART
    .rept 16
    .irp r, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    \op f\r, \srcs
    .endr
    .endr
    TEND
.endm

.macro DEFS prec
    .global fadd_dep_\prec
fadd_dep_\prec:
    PROLOGUE
    LDK \prec, f0, K_ONE
    LDK \prec, f1, K_C15
    TIMED2 "fadd.\prec f0, f0, f1", "fsub.\prec f0, f0, f1"

    .global fmul_dep_\prec
fmul_dep_\prec:
    PROLOGUE
    LDK \prec, f0, K_ONE
    LDK \prec, f1, K_C11
    LDK \prec, f2, K_INV11
    TIMED2 "fmul.\prec f0, f0, f1", "fmul.\prec f0, f0, f2"

    /* acc = b * c + acc: the dependence runs through the addend. */
    .global fmadd_acc_\prec
fmadd_acc_\prec:
    PROLOGUE
    LDK \prec, f0, K_ONE
    LDK \prec, f1, K_C11
    LDK \prec, f2, K_C07
    LDK \prec, f3, K_M07
    TIMED2 "fmadd.\prec f0, f1, f2, f0", "fmadd.\prec f0, f1, f3, f0"

    /* x = x * c + d, then x = x / c - d / c: through the multiplicand. */
    .global fmadd_mul_\prec
fmadd_mul_\prec:
    PROLOGUE
    LDK \prec, f0, K_ONE
    LDK \prec, f1, K_C11
    LDK \prec, f2, K_HALF
    LDK \prec, f3, K_INV11
    LDK \prec, f4, K_MHALF11
    TIMED2 "fmadd.\prec f0, f0, f1, f2", "fmadd.\prec f0, f0, f3, f4"

    .global fdiv_dep_\prec
fdiv_dep_\prec:
    PROLOGUE
    LDK \prec, f0, K_ONE
    LDK \prec, f1, K_C11
    LDK \prec, f2, K_INV11
    TIMED2 "fdiv.\prec f0, f0, f1", "fdiv.\prec f0, f0, f2"

    /* x = sqrt(x) + 0.25: one pair per body. */
    .global fsqrt_pair_\prec
fsqrt_pair_\prec:
    PROLOGUE
    LDK \prec, f0, K_C15
    LDK \prec, f1, K_QUARTER
    TIMED2 "fsqrt.\prec f0, f0", "fadd.\prec f0, f0, f1"

    .global fadd_thr_\prec
fadd_thr_\prec:
    PROLOGUE
    LDK \prec, f20, K_C11
    LDK \prec, f21, K_C07
    TIMED16 fadd.\prec, "f20, f21"

    .global fmul_thr_\prec
fmul_thr_\prec:
    PROLOGUE
    LDK \prec, f20, K_C11
    LDK \prec, f21, K_C07
    TIMED16 fmul.\prec, "f20, f21"

    .global fmadd_thr_\prec
fmadd_thr_\prec:
    PROLOGUE
    LDK \prec, f20, K_C11
    LDK \prec, f21, K_C07
    LDK \prec, f22, K_HALF
    TIMED16 fmadd.\prec, "f20, f21, f22"
.endm

    DEFS d
    DEFS s

    /* FP load-to-use: each ring node costs fld + fmv.x.d. */
    .global fld_chase
fld_chase:
    PROLOGUE
    mv a3, a1
    TIMED2 "fld f0, 0(a3)", "fmv.x.d a3, f0"

    /* Integer load-to-use on the same ring: two nodes per body. */
    .global ld_chase
ld_chase:
    mv a3, a1
    TIMED2 "ld a3, 0(a3)", "ld a3, 0(a3)"
