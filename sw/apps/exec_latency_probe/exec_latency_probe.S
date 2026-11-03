# Arithmetic chains with named instruction ranges for cycle tracing.
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
    li a0, 7
    li a1, 1
    .globl mul_dep
mul_dep:
    .rept 64
    mul a0, a0, a1
    .endr
    .globl mul_dep_end
mul_dep_end:
    li t0, 7
    bne a0, t0, probe_fail
    .globl mulw_dep
mulw_dep:
    .rept 64
    mulw a0, a0, a1
    .endr
    .globl mulw_dep_end
mulw_dep_end:
    bne a0, t0, probe_fail
    .globl mul_ind
mul_ind:
    .rept 64
    mul a2, a0, a1
    .endr
    .globl mul_ind_end
mul_ind_end:
    bne a2, t0, probe_fail

    li t0, 0x3ff0000000000000
    fmv.d.x f0, t0
    fmv.d.x f2, t0
    li t0, 0x3fe0000000000000
    fmv.d.x f1, t0
    .globl fadd_dep
fadd_dep:
    .rept 64
    fadd.d f0, f0, f1, rne
    .endr
    .globl fadd_dep_end
fadd_dep_end:
    fmv.x.d t1, f0
    li t0, 0x4040800000000000
    bne t0, t1, probe_fail
    li t0, 0x3ff0000000000000
    fmv.d.x f0, t0
    li t0, 0x3d70000000000000
    fmv.d.x f3, t0
    .globl fadd_gap_dep
fadd_gap_dep:
    .rept 64
    fadd.d f0, f0, f3, rne
    .endr
    .globl fadd_gap_dep_end
fadd_gap_dep_end:
    fmv.x.d t1, f0
    li t0, 0x3ff0000000040000
    bne t0, t1, probe_fail
    li t0, 0x3ff8000000000000
    fmv.d.x f0, t0
    .globl fmul_dep
fmul_dep:
    .rept 64
    fmul.d f0, f0, f2, rne
    .endr
    .globl fmul_dep_end
fmul_dep_end:
    fmv.x.d t1, f0
    bne t0, t1, probe_fail
    li t0, 0x3ff0000000000000
    fmv.d.x f0, t0
    .globl fma_dep
fma_dep:
    .rept 64
    fmadd.d f0, f0, f2, f1, rne
    .endr
    .globl fma_dep_end
fma_dep_end:
    fmv.x.d t1, f0
    li t0, 0x4040800000000000
    bne t0, t1, probe_fail

    li t0, 0x3ff8000000000000
    fmv.d.x f0, t0
    .globl fadd_ind
fadd_ind:
    .rept 64
    fadd.d f4, f0, f1, rne
    .endr
    .globl fadd_ind_end
fadd_ind_end:
    .globl fmul_ind
fmul_ind:
    .rept 64
    fmul.d f5, f0, f1, rne
    .endr
    .globl fmul_ind_end
fmul_ind_end:
    .globl fma_ind
fma_ind:
    .rept 64
    fmadd.d f6, f0, f1, f1, rne
    .endr
    .globl fma_ind_end
fma_ind_end:
    fmv.x.d t1, f4
    li t0, 0x4000000000000000
    bne t0, t1, probe_fail
    fmv.x.d t1, f5
    li t0, 0x3fe8000000000000
    bne t0, t1, probe_fail
    fmv.x.d t1, f6
    li t0, 0x3ff4000000000000
    bne t0, t1, probe_fail
    csrr t0, fflags
    bnez t0, probe_fail
    .globl probe_done
probe_done:
    j probe_done
    .balign 4
    .globl probe_fail
probe_fail:
    j probe_fail
