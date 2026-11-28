//    Copyright 2026 Two Sigma Open Source, LLC
//
//    Licensed under the Apache License, Version 2.0 (the "License");
//    you may not use this file except in compliance with the License.
//    You may obtain a copy of the License at
//
//        http://www.apache.org/licenses/LICENSE-2.0
//
//    Unless required by applicable law or agreed to in writing, software
//    distributed under the License is distributed on an "AS IS" BASIS,
//    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//    See the License for the specific language governing permissions and
//    limitations under the License.

// Vector microbenchmark kernels for measuring engine throughput, latency,
// overlap, scalar transfer cost, i32 dot product, and m1 memcpy.

    .text

// Helper macro: repeat a single instruction 16 times
.macro REP16 insn:vararg
    \insn
    \insn
    \insn
    \insn
    \insn
    \insn
    \insn
    \insn
    \insn
    \insn
    \insn
    \insn
    \insn
    \insn
    \insn
    \insn
.endm

// Helper macro: repeat a single instruction 8 times
.macro REP8 insn:vararg
    \insn
    \insn
    \insn
    \insn
    \insn
    \insn
    \insn
    \insn
.endm

// uint64_t bench_vadd_m1_vl4(unsigned iters, uint64_t *out_elem0)
// Runs 16 * iters dependent vadd.vv at e32, m1, vl=4. Returns elapsed cycles.
    .globl  bench_vadd_m1_vl4
    .type   bench_vadd_m1_vl4, @function
bench_vadd_m1_vl4:
    vsetivli zero, 4, e32, m1, ta, ma
    vmv.v.i v8, 0
    vmv.v.i v16, 1
    csrr    t1, cycle
1:  REP16   vadd.vv v8, v8, v16
    addi    a0, a0, -1
    bnez    a0, 1b
    csrr    t2, cycle
    vmv.x.s t0, v8
    sd      t0, 0(a1)
    sub     a0, t2, t1
    ret
    .size   bench_vadd_m1_vl4, . - bench_vadd_m1_vl4

// uint64_t bench_vadd_m4_vl4(unsigned iters, uint64_t *out_elem0)
// Runs 16 * iters dependent vadd.vv at e32, m4, vl=4. Returns elapsed cycles.
    .globl  bench_vadd_m4_vl4
    .type   bench_vadd_m4_vl4, @function
bench_vadd_m4_vl4:
    vsetivli zero, 4, e32, m4, ta, ma
    vmv.v.i v8, 0
    vmv.v.i v16, 1
    csrr    t1, cycle
1:  REP16   vadd.vv v8, v8, v16
    addi    a0, a0, -1
    bnez    a0, 1b
    csrr    t2, cycle
    vmv.x.s t0, v8
    sd      t0, 0(a1)
    sub     a0, t2, t1
    ret
    .size   bench_vadd_m4_vl4, . - bench_vadd_m4_vl4

// uint64_t bench_vadd_m8_vl4(unsigned iters, uint64_t *out_elem0)
// Runs 16 * iters dependent vadd.vv at e32, m8, vl=4. Returns elapsed cycles.
    .globl  bench_vadd_m8_vl4
    .type   bench_vadd_m8_vl4, @function
bench_vadd_m8_vl4:
    vsetivli zero, 4, e32, m8, ta, ma
    vmv.v.i v8, 0
    vmv.v.i v16, 1
    csrr    t1, cycle
1:  REP16   vadd.vv v8, v8, v16
    addi    a0, a0, -1
    bnez    a0, 1b
    csrr    t2, cycle
    vmv.x.s t0, v8
    sd      t0, 0(a1)
    sub     a0, t2, t1
    ret
    .size   bench_vadd_m8_vl4, . - bench_vadd_m8_vl4

// uint64_t bench_vadd_indep(unsigned iters, uint64_t *out_elem0)
// Runs 16 * iters independent vadd.vv at e32, m1, vl=4 across 8 distinct
// destinations (v1..v8). Returns elapsed cycles.
    .globl  bench_vadd_indep
    .type   bench_vadd_indep, @function
bench_vadd_indep:
    vsetivli zero, 4, e32, m1, ta, ma
    vmv.v.i v9, 3
    vmv.v.i v10, 4
    csrr    t1, cycle
1:  vadd.vv v1, v9, v10
    vadd.vv v2, v9, v10
    vadd.vv v3, v9, v10
    vadd.vv v4, v9, v10
    vadd.vv v5, v9, v10
    vadd.vv v6, v9, v10
    vadd.vv v7, v9, v10
    vadd.vv v8, v9, v10
    vadd.vv v1, v9, v10
    vadd.vv v2, v9, v10
    vadd.vv v3, v9, v10
    vadd.vv v4, v9, v10
    vadd.vv v5, v9, v10
    vadd.vv v6, v9, v10
    vadd.vv v7, v9, v10
    vadd.vv v8, v9, v10
    addi    a0, a0, -1
    bnez    a0, 1b
    csrr    t2, cycle
    vmv.x.s t0, v8
    sd      t0, 0(a1)
    sub     a0, t2, t1
    ret
    .size   bench_vadd_indep, . - bench_vadd_indep

// uint64_t bench_vadd_dep(unsigned iters, uint64_t *out_elem0)
// Runs 16 * iters dependent vadd.vv at e32, m1, vl=4 (RAW chain on v1).
    .globl  bench_vadd_dep
    .type   bench_vadd_dep, @function
bench_vadd_dep:
    vsetivli zero, 4, e32, m1, ta, ma
    vmv.v.i v1, 0
    vmv.v.i v9, 1
    csrr    t1, cycle
1:  REP16   vadd.vv v1, v1, v9
    addi    a0, a0, -1
    bnez    a0, 1b
    csrr    t2, cycle
    vmv.x.s t0, v1
    sd      t0, 0(a1)
    sub     a0, t2, t1
    ret
    .size   bench_vadd_dep, . - bench_vadd_dep

// uint64_t bench_vadd_vmu_overlap(unsigned iters, const int32_t *src, uint64_t *out_elem0)
// Runs iters iterations of: one vle32.v into v0 followed by two independent
// vadd.vv on v4 and v7 (reading v5, v6). Measures engine+VMU overlap.
    .globl  bench_vadd_vmu_overlap
    .type   bench_vadd_vmu_overlap, @function
bench_vadd_vmu_overlap:
    vsetivli zero, 4, e32, m1, ta, ma
    vmv.v.i v4, 0
    vmv.v.i v5, 2
    vmv.v.i v6, 3
    vmv.v.i v7, 0
    csrr    t1, cycle
1:  vle32.v v0, (a1)
    vadd.vv v4, v5, v6
    vadd.vv v7, v5, v6
    addi    a0, a0, -1
    bnez    a0, 1b
    csrr    t2, cycle
    vmv.x.s t0, v4
    sd      t0, 0(a2)
    sub     a0, t2, t1
    ret
    .size   bench_vadd_vmu_overlap, . - bench_vadd_vmu_overlap

// uint64_t bench_vwmacc_vl4(unsigned iters, uint64_t *out_elem0)
// Runs 8 * iters 4-element vwmacc.vv at e32, m1, vl=4 (accumulating into e64 v4..v5).
    .globl  bench_vwmacc_vl4
    .type   bench_vwmacc_vl4, @function
bench_vwmacc_vl4:
    vsetivli zero, 4, e64, m2, ta, ma
    vmv.v.i v4, 0
    vsetivli zero, 4, e32, m1, ta, ma
    vmv.v.i v1, 3
    vmv.v.i v2, 5
    csrr    t1, cycle
1:  REP8    vwmacc.vv v4, v1, v2
    addi    a0, a0, -1
    bnez    a0, 1b
    csrr    t2, cycle
    vsetivli zero, 4, e64, m2, ta, ma
    vmv.x.s t0, v4
    sd      t0, 0(a1)
    sub     a0, t2, t1
    ret
    .size   bench_vwmacc_vl4, . - bench_vwmacc_vl4

// uint64_t bench_vwmul_vl4(unsigned iters, uint64_t *out_elem0)
// Runs 8 * iters 4-element vwmul.vv at e32, m1, vl=4.
    .globl  bench_vwmul_vl4
    .type   bench_vwmul_vl4, @function
bench_vwmul_vl4:
    vsetivli zero, 4, e32, m1, ta, ma
    vmv.v.i v1, 3
    vmv.v.i v2, 7
    csrr    t1, cycle
1:  REP8    vwmul.vv v4, v1, v2
    addi    a0, a0, -1
    bnez    a0, 1b
    csrr    t2, cycle
    vsetivli zero, 4, e64, m2, ta, ma
    vmv.x.s t0, v4
    sd      t0, 0(a1)
    sub     a0, t2, t1
    ret
    .size   bench_vwmul_vl4, . - bench_vwmul_vl4

// uint64_t bench_vmacc_vl4(unsigned iters, uint64_t *out_elem0)
// Runs 8 * iters 4-element vmacc.vv at e32, m1, vl=4.
    .globl  bench_vmacc_vl4
    .type   bench_vmacc_vl4, @function
bench_vmacc_vl4:
    vsetivli zero, 4, e32, m1, ta, ma
    vmv.v.i v4, 0
    vmv.v.i v1, 3
    vmv.v.i v2, 5
    csrr    t1, cycle
1:  REP8    vmacc.vv v4, v1, v2
    addi    a0, a0, -1
    bnez    a0, 1b
    csrr    t2, cycle
    vmv.x.s t0, v4
    sd      t0, 0(a1)
    sub     a0, t2, t1
    ret
    .size   bench_vmacc_vl4, . - bench_vmacc_vl4

// uint64_t bench_vredsum_vl4(unsigned iters, uint64_t *out_elem0)
// Runs 8 * iters 4-element vredsum.vs at e32, m1, vl=4.
    .globl  bench_vredsum_vl4
    .type   bench_vredsum_vl4, @function
bench_vredsum_vl4:
    vsetivli zero, 4, e32, m1, ta, ma
    vmv.v.i v1, 2
    vmv.s.x v3, zero
    csrr    t1, cycle
1:  REP8    vredsum.vs v3, v1, v3
    addi    a0, a0, -1
    bnez    a0, 1b
    csrr    t2, cycle
    vmv.x.s t0, v3
    sd      t0, 0(a1)
    sub     a0, t2, t1
    ret
    .size   bench_vredsum_vl4, . - bench_vredsum_vl4

// uint64_t bench_vredsum_e64_vl4(unsigned iters, uint64_t *out_elem0)
// Runs 8 * iters 4-element vredsum.vs at e64, m2, vl=4 (the dot_i32 reduction).
    .globl  bench_vredsum_e64_vl4
    .type   bench_vredsum_e64_vl4, @function
bench_vredsum_e64_vl4:
    vsetivli zero, 4, e64, m2, ta, ma
    vmv.v.i v4, 2
    vmv.s.x v31, zero
    csrr    t1, cycle
1:  REP8    vredsum.vs v31, v4, v31
    addi    a0, a0, -1
    bnez    a0, 1b
    csrr    t2, cycle
    vmv.x.s t0, v31
    sd      t0, 0(a1)
    sub     a0, t2, t1
    ret
    .size   bench_vredsum_e64_vl4, . - bench_vredsum_e64_vl4

// uint64_t bench_vmv_xs_idle(unsigned iters, uint64_t *out_sum)
// Runs 8 * iters back-to-back vmv.x.s + dependent scalar add with backend idle.
    .globl  bench_vmv_xs_idle
    .type   bench_vmv_xs_idle, @function
bench_vmv_xs_idle:
    vsetivli zero, 4, e32, m1, ta, ma
    vmv.v.i v1, 5
    li      t3, 0
    csrr    t1, cycle
1:  vmv.x.s t0, v1
    add     t3, t3, t0
    vmv.x.s t0, v1
    add     t3, t3, t0
    vmv.x.s t0, v1
    add     t3, t3, t0
    vmv.x.s t0, v1
    add     t3, t3, t0
    vmv.x.s t0, v1
    add     t3, t3, t0
    vmv.x.s t0, v1
    add     t3, t3, t0
    vmv.x.s t0, v1
    add     t3, t3, t0
    vmv.x.s t0, v1
    add     t3, t3, t0
    addi    a0, a0, -1
    bnez    a0, 1b
    csrr    t2, cycle
    sd      t3, 0(a1)
    sub     a0, t2, t1
    ret
    .size   bench_vmv_xs_idle, . - bench_vmv_xs_idle

// uint64_t bench_vmv_xs_behind_vec(unsigned iters, uint64_t *out_sum)
// Measures vmv.x.s reading independent v1 behind an unrelated multi-group vadd
// writing v8..v11 (m4, vl=16 at e32), plus scalar work consuming t0.
    .globl  bench_vmv_xs_behind_vec
    .type   bench_vmv_xs_behind_vec, @function
bench_vmv_xs_behind_vec:
    vsetivli zero, 4, e32, m1, ta, ma
    vmv.v.i v1, 7
    vsetivli zero, 16, e32, m4, ta, ma
    vmv.v.i v8, 0
    vmv.v.i v16, 1
    li      t3, 0
    csrr    t1, cycle
1:  vadd.vv v8, v8, v16
    vmv.x.s t0, v1
    add     t3, t3, t0
    addi    a0, a0, -1
    bnez    a0, 1b
    csrr    t2, cycle
    sd      t3, 0(a1)
    sub     a0, t2, t1
    ret
    .size   bench_vmv_xs_behind_vec, . - bench_vmv_xs_behind_vec

// int64_t dot_i32_scalar_asm(const int32_t *a, const int32_t *b, size_t n)
    .globl  dot_i32_scalar_asm
    .type   dot_i32_scalar_asm, @function
dot_i32_scalar_asm:
    li      t0, 0
    beqz    a2, 2f
1:  lw      t1, 0(a0)
    lw      t2, 0(a1)
    mul     t1, t1, t2
    add     t0, t0, t1
    addi    a0, a0, 4
    addi    a1, a1, 4
    addi    a2, a2, -1
    bnez    a2, 1b
2:  mv      a0, t0
    ret
    .size   dot_i32_scalar_asm, . - dot_i32_scalar_asm

// int64_t dot_i32_rvv_vwmacc(const int32_t *a, const int32_t *b, size_t n)
// Accumulates widening products across strips with vwmacc.vv (tu, ma),
// then one final e64 vredsum.vs and vmv.x.s.
    .globl  dot_i32_rvv_vwmacc
    .type   dot_i32_rvv_vwmacc, @function
dot_i32_rvv_vwmacc:
    vsetvli zero, zero, e64, m2, ta, ma
    vmv.v.i v4, 0
1:  beqz    a2, 2f
    vsetvli t0, a2, e32, m1, tu, ma
    vle32.v v0, (a0)
    vle32.v v1, (a1)
    vwmacc.vv v4, v0, v1
    slli    t1, t0, 2
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetvli zero, zero, e64, m2, ta, ma
    vmv.s.x v31, zero
    vredsum.vs v31, v4, v31
    vmv.x.s a0, v31
    ret
    .size   dot_i32_rvv_vwmacc, . - dot_i32_rvv_vwmacc

// int64_t dot_i32_rvv_vwmul(const int32_t *a, const int32_t *b, size_t n)
// Same shape as sw/apps/vec_dot_int/dot_rvv.S: vwmul + vredsum per strip.
    .globl  dot_i32_rvv_vwmul
    .type   dot_i32_rvv_vwmul, @function
dot_i32_rvv_vwmul:
    vsetivli zero, 1, e64, m1, ta, ma
    vmv.s.x v31, zero
1:  beqz    a2, 2f
    vsetvli t0, a2, e32, m1, ta, ma
    vle32.v v0, (a0)
    vle32.v v1, (a1)
    vwmul.vv v2, v0, v1
    vsetvli zero, t0, e64, m2, ta, ma
    vredsum.vs v31, v2, v31
    slli    t1, t0, 2
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetivli zero, 1, e64, m1, ta, ma
    vmv.x.s a0, v31
    ret
    .size   dot_i32_rvv_vwmul, . - dot_i32_rvv_vwmul

// int32_t dot_i32_rvv_vmacc(const int32_t *a, const int32_t *b, size_t n)
    .globl  dot_i32_rvv_vmacc
    .type   dot_i32_rvv_vmacc, @function
dot_i32_rvv_vmacc:
    vsetvli t0, zero, e32, m1, ta, ma
    vmv.v.i v4, 0
1:  beqz    a2, 2f
    vsetvli t0, a2, e32, m1, tu, ma
    vle32.v v0, (a0)
    vle32.v v1, (a1)
    vmacc.vv v4, v0, v1
    slli    t1, t0, 2
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetvli t0, zero, e32, m1, ta, ma
    vmv.s.x v31, zero
    vredsum.vs v31, v4, v31
    vmv.x.s a0, v31
    ret
    .size   dot_i32_rvv_vmacc, . - dot_i32_rvv_vmacc

// void memcpy_m1_rvv(void *dst, const void *src, size_t n)
    .globl  memcpy_m1_rvv
    .type   memcpy_m1_rvv, @function
memcpy_m1_rvv:
    beqz    a2, 2f
1:  vsetvli t0, a2, e8, m1, ta, ma
    vle8.v  v0, (a1)
    add     a1, a1, t0
    sub     a2, a2, t0
    vse8.v  v0, (a0)
    add     a0, a0, t0
    bnez    a2, 1b
2:  ret
    .size   memcpy_m1_rvv, . - memcpy_m1_rvv

// void memcpy_scalar_asm(void *dst, const void *src, size_t n_bytes_mult8)
    .globl  memcpy_scalar_asm
    .type   memcpy_scalar_asm, @function
memcpy_scalar_asm:
    beqz    a2, 2f
1:  ld      t0, 0(a1)
    sd      t0, 0(a0)
    addi    a1, a1, 8
    addi    a0, a0, 8
    addi    a2, a2, -8
    bnez    a2, 1b
2:  ret
    .size   memcpy_scalar_asm, . - memcpy_scalar_asm
