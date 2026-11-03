# Arithmetic chains for zero, infinity, NaN, and exact cancellation results.
    .section .init
    .option norvc
    .option norelax
    .globl _start
_start:
    la t0, probe_fail
    csrw mtvec, t0
    li t0, (3 << 13)
    csrs mstatus, t0
    csrw fcsr, zero
    li t0, 0x3ff0000000000000
    fmv.d.x f1, t0
    fmv.d.x f0, zero
    .globl fmul_zero_dep
fmul_zero_dep:
    .rept 64
    fmul.d f0, f0, f1, rne
    .endr
    .globl fmul_zero_dep_end
fmul_zero_dep_end:
    fmv.x.d t0, f0
    bnez t0, probe_fail
    li t0, 0x7ff0000000000000
    fmv.d.x f0, t0
    .globl fadd_inf_dep
fadd_inf_dep:
    .rept 64
    fadd.d f0, f0, f1, rne
    .endr
    .globl fadd_inf_dep_end
fadd_inf_dep_end:
    fmv.x.d t1, f0
    bne t0, t1, probe_fail
    li t0, 0x7ff8000000000000
    fmv.d.x f0, t0
    .globl fadd_nan_dep
fadd_nan_dep:
    .rept 64
    fadd.d f0, f0, f1, rne
    .endr
    .globl fadd_nan_dep_end
fadd_nan_dep_end:
    fmv.x.d t1, f0
    bne t0, t1, probe_fail
    li t0, 0x3ff0000000000000
    fmv.d.x f0, t0
    .globl fsub_zero_dep
fsub_zero_dep:
    .rept 64
    fsub.d f0, f0, f0, rne
    .endr
    .globl fsub_zero_dep_end
fsub_zero_dep_end:
    fmv.x.d t0, f0
    bnez t0, probe_fail
    csrr t0, fflags
    bnez t0, probe_fail
    .globl probe_done
probe_done:
    j probe_done
    .balign 4
    .globl probe_fail
probe_fail:
    j probe_fail
