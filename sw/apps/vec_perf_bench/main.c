/*
 *    Copyright 2026 Two Sigma Open Source, LLC
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

/**
 * Vector engine microbenchmark suite.
 *
 * Measures and self-checks:
 *  - vadd.vv at e32 vl=4 with LMUL m1, m4, m8
 *  - independent vs dependent vadd.vv at e32 m1 vl=4
 *  - vadd.vv overlapped with an independent vle32.v
 *  - 4-element vwmacc.vv, vwmul.vv, vmacc.vv, vredsum.vs (e32 m1 and e64 m2)
 *  - vmv.x.s when backend is idle and behind an independent multi-group vadd
 *  - 64-element i32 dot product (scalar, vwmacc, vwmul+vredsum, vmacc)
 *  - 256-byte memcpy at m1 (RVV vs scalar) for reference
 */

#include "vec_test.h"

uint64_t bench_vadd_m1_vl4(unsigned iters, uint64_t *out_elem0);
uint64_t bench_vadd_m4_vl4(unsigned iters, uint64_t *out_elem0);
uint64_t bench_vadd_m8_vl4(unsigned iters, uint64_t *out_elem0);
uint64_t bench_vadd_indep(unsigned iters, uint64_t *out_elem0);
uint64_t bench_vadd_dep(unsigned iters, uint64_t *out_elem0);
uint64_t bench_vadd_vmu_overlap(unsigned iters, const int32_t *src, uint64_t *out_elem0);
uint64_t bench_vwmacc_vl4(unsigned iters, uint64_t *out_elem0);
uint64_t bench_vwmul_vl4(unsigned iters, uint64_t *out_elem0);
uint64_t bench_vmacc_vl4(unsigned iters, uint64_t *out_elem0);
uint64_t bench_vredsum_vl4(unsigned iters, uint64_t *out_elem0);
uint64_t bench_vredsum_e64_vl4(unsigned iters, uint64_t *out_elem0);
uint64_t bench_vmv_xs_idle(unsigned iters, uint64_t *out_sum);
uint64_t bench_vmv_xs_behind_vec(unsigned iters, uint64_t *out_sum);

int64_t dot_i32_scalar_asm(const int32_t *a, const int32_t *b, size_t n);
int64_t dot_i32_rvv_vwmacc(const int32_t *a, const int32_t *b, size_t n);
int64_t dot_i32_rvv_vwmul(const int32_t *a, const int32_t *b, size_t n);
int32_t dot_i32_rvv_vmacc(const int32_t *a, const int32_t *b, size_t n);

void memcpy_m1_rvv(void *dst, const void *src, size_t n);
void memcpy_scalar_asm(void *dst, const void *src, size_t n);

#define DOT_N 64
#define COPY_N 256

static int32_t dot_a[DOT_N] __attribute__((aligned(64)));
static int32_t dot_b[DOT_N] __attribute__((aligned(64)));
static uint8_t copy_src[COPY_N] __attribute__((aligned(64)));
static uint8_t copy_dst[COPY_N] __attribute__((aligned(64)));
static uint8_t copy_ref[COPY_N] __attribute__((aligned(64)));

static inline uint64_t rdcycle(void)
{
    uint64_t c;
    __asm__ volatile("csrr %0, cycle" : "=r"(c)::"memory");
    return c;
}

static void print_x10(uint64_t num, uint64_t den)
{
    uint64_t tenths = (num * 10 + den / 2) / den;
    vt_dec(tenths / 10);
    vt_putc('.');
    vt_dec(tenths % 10);
}

static void report_op(const char *name, uint64_t cyc_short, uint64_t cyc_long, uint64_t delta_ops)
{
    uint64_t delta = cyc_long - cyc_short;
    vt_puts("BENCH ");
    vt_puts(name);
    vt_puts(": ");
    print_x10(delta, delta_ops);
    vt_puts(" cyc/op (delta=");
    vt_dec(delta);
    vt_puts("/");
    vt_dec(delta_ops);
    vt_puts(" raw=");
    vt_dec(cyc_short);
    vt_puts(")\r\n");
}

static void report_kernel(const char *name, uint64_t cyc, uint64_t units, const char *unit_name)
{
    vt_puts("BENCH ");
    vt_puts(name);
    vt_puts(": ");
    vt_dec(cyc);
    vt_puts(" cyc (");
    print_x10(cyc, units);
    vt_puts(" cyc/");
    vt_puts(unit_name);
    vt_puts(")\r\n");
}

int main(void)
{
    vt_enable_vector();
    vt_trap_install();

    unsigned long vlen = vt_vlenb() * 8;
    vt_puts("vec_perf_bench VLEN=");
    vt_dec(vlen);
    vt_puts("\r\n");

    uint64_t seed = 0x123456789abcdef0ull;
    for (size_t i = 0; i < DOT_N; i++) {
        dot_a[i] = (int32_t) ((int64_t) (vt_rand(&seed) & 0xFFFFu) - 32768);
        dot_b[i] = (int32_t) ((int64_t) (vt_rand(&seed) & 0xFFFFu) - 32768);
    }
    for (size_t i = 0; i < COPY_N; i++) {
        copy_src[i] = (uint8_t) (vt_rand(&seed) & 0xFFu);
        copy_dst[i] = 0;
        copy_ref[i] = 0;
    }

    uint64_t out = 0;
    uint64_t t1, t2;

    /* Item 4: vadd at vl=4 for m1, m4, m8 (16 ops/iter; delta = 32 ops). */
    bench_vadd_m1_vl4(1, &out);
    t1 = bench_vadd_m1_vl4(1, &out);
    VT_EQ(out, 16, "vadd_m1_vl4");
    t2 = bench_vadd_m1_vl4(3, &out);
    VT_EQ(out, 48, "vadd_m1_vl4_long");
    report_op("vadd_m1_vl4", t1, t2, 32);

    bench_vadd_m4_vl4(1, &out);
    t1 = bench_vadd_m4_vl4(1, &out);
    VT_EQ(out, 16, "vadd_m4_vl4");
    t2 = bench_vadd_m4_vl4(3, &out);
    VT_EQ(out, 48, "vadd_m4_vl4_long");
    report_op("vadd_m4_vl4", t1, t2, 32);

    bench_vadd_m8_vl4(1, &out);
    t1 = bench_vadd_m8_vl4(1, &out);
    VT_EQ(out, 16, "vadd_m8_vl4");
    t2 = bench_vadd_m8_vl4(3, &out);
    VT_EQ(out, 48, "vadd_m8_vl4_long");
    report_op("vadd_m8_vl4", t1, t2, 32);

    /* Item 3: independent vs dependent vadd, plus engine+VMU overlap. */
    bench_vadd_indep(1, &out);
    t1 = bench_vadd_indep(1, &out);
    VT_EQ(out, 7, "vadd_indep");
    t2 = bench_vadd_indep(3, &out);
    VT_EQ(out, 7, "vadd_indep_long");
    report_op("vadd_indep", t1, t2, 32);

    bench_vadd_dep(1, &out);
    t1 = bench_vadd_dep(1, &out);
    VT_EQ(out, 16, "vadd_dep");
    t2 = bench_vadd_dep(3, &out);
    VT_EQ(out, 48, "vadd_dep_long");
    report_op("vadd_dep", t1, t2, 32);

    bench_vadd_vmu_overlap(2, dot_a, &out);
    t1 = bench_vadd_vmu_overlap(2, dot_a, &out);
    VT_EQ(out, 5, "vadd_vmu_overlap");
    t2 = bench_vadd_vmu_overlap(10, dot_a, &out);
    VT_EQ(out, 5, "vadd_vmu_overlap_long");
    report_op("vadd_vmu_overlap", t1, t2, 8);

    /* Item 5: 4-element vwmacc, vwmul, vmacc, vredsum (8 ops/iter; delta = 16 ops). */
    bench_vwmacc_vl4(1, &out);
    t1 = bench_vwmacc_vl4(1, &out);
    VT_EQ(out, 8 * 15, "vwmacc_vl4");
    t2 = bench_vwmacc_vl4(3, &out);
    VT_EQ(out, 24 * 15, "vwmacc_vl4_long");
    report_op("vwmacc_vl4", t1, t2, 16);

    bench_vwmul_vl4(1, &out);
    t1 = bench_vwmul_vl4(1, &out);
    VT_EQ(out, 21, "vwmul_vl4");
    t2 = bench_vwmul_vl4(3, &out);
    VT_EQ(out, 21, "vwmul_vl4_long");
    report_op("vwmul_vl4", t1, t2, 16);

    bench_vmacc_vl4(1, &out);
    t1 = bench_vmacc_vl4(1, &out);
    VT_EQ(out, 8 * 15, "vmacc_vl4");
    t2 = bench_vmacc_vl4(3, &out);
    VT_EQ(out, 24 * 15, "vmacc_vl4_long");
    report_op("vmacc_vl4", t1, t2, 16);

    bench_vredsum_vl4(1, &out);
    t1 = bench_vredsum_vl4(1, &out);
    VT_EQ(out, 8 * 8, "vredsum_vl4");
    t2 = bench_vredsum_vl4(3, &out);
    VT_EQ(out, 24 * 8, "vredsum_vl4_long");
    report_op("vredsum_vl4", t1, t2, 16);

    bench_vredsum_e64_vl4(1, &out);
    t1 = bench_vredsum_e64_vl4(1, &out);
    VT_EQ(out, 8 * 8, "vredsum_e64_vl4");
    t2 = bench_vredsum_e64_vl4(3, &out);
    VT_EQ(out, 24 * 8, "vredsum_e64_vl4_long");
    report_op("vredsum_e64_vl4", t1, t2, 16);

    /* Item 6: vmv.x.s idle and behind an unrelated multi-group vadd. */
    bench_vmv_xs_idle(1, &out);
    t1 = bench_vmv_xs_idle(1, &out);
    VT_EQ(out, 8 * 5, "vmv_xs_idle");
    t2 = bench_vmv_xs_idle(3, &out);
    VT_EQ(out, 24 * 5, "vmv_xs_idle_long");
    report_op("vmv_xs_idle", t1, t2, 16);

    bench_vmv_xs_behind_vec(2, &out);
    t1 = bench_vmv_xs_behind_vec(2, &out);
    VT_EQ(out, 2 * 7, "vmv_xs_behind_vec");
    t2 = bench_vmv_xs_behind_vec(10, &out);
    VT_EQ(out, 10 * 7, "vmv_xs_behind_vec_long");
    report_op("vmv_xs_behind_vec", t1, t2, 8);

    /* i32 dot product (64 elements, warmed in L1D). */
    int64_t ref_dot = dot_i32_scalar_asm(dot_a, dot_b, DOT_N);
    uint64_t c0 = rdcycle();
    int64_t got_sc = dot_i32_scalar_asm(dot_a, dot_b, DOT_N);
    uint64_t c1 = rdcycle();
    VT_EQ(got_sc, ref_dot, "dot_i32_scalar");
    report_kernel("dot_i32_scalar", c1 - c0, DOT_N, "elem");

    (void) dot_i32_rvv_vwmacc(dot_a, dot_b, DOT_N);
    c0 = rdcycle();
    int64_t got_vwmacc = dot_i32_rvv_vwmacc(dot_a, dot_b, DOT_N);
    c1 = rdcycle();
    VT_EQ(got_vwmacc, ref_dot, "dot_i32_rvv_vwmacc");
    report_kernel("dot_i32_vwmacc", c1 - c0, DOT_N, "elem");

    (void) dot_i32_rvv_vwmul(dot_a, dot_b, DOT_N);
    c0 = rdcycle();
    int64_t got_vwmul = dot_i32_rvv_vwmul(dot_a, dot_b, DOT_N);
    c1 = rdcycle();
    VT_EQ(got_vwmul, ref_dot, "dot_i32_rvv_vwmul");
    report_kernel("dot_i32_vwmul", c1 - c0, DOT_N, "elem");

    (void) dot_i32_rvv_vmacc(dot_a, dot_b, DOT_N);
    c0 = rdcycle();
    int32_t got_vmacc = dot_i32_rvv_vmacc(dot_a, dot_b, DOT_N);
    c1 = rdcycle();
    VT_EQ((uint32_t) got_vmacc, (uint32_t) ref_dot, "dot_i32_rvv_vmacc");
    report_kernel("dot_i32_vmacc", c1 - c0, DOT_N, "elem");

    /* Reference memcpy at m1 (256 bytes, warmed in L1D). */
    memcpy_scalar_asm(copy_ref, copy_src, COPY_N);
    c0 = rdcycle();
    memcpy_scalar_asm(copy_ref, copy_src, COPY_N);
    c1 = rdcycle();
    report_kernel("memcpy_scalar", c1 - c0, COPY_N / 16, "16B");

    memcpy_m1_rvv(copy_dst, copy_src, COPY_N);
    c0 = rdcycle();
    memcpy_m1_rvv(copy_dst, copy_src, COPY_N);
    c1 = rdcycle();
    VT_EQ(memcmp(copy_dst, copy_ref, COPY_N), 0, "memcpy_m1_rvv");
    report_kernel("memcpy_m1_rvv", c1 - c0, COPY_N / 16, "16B");

    return vt_finish("vec_perf_bench");
}
