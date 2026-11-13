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
 * Floating-point dot products (dot_fp_rvv.S): float32 and float64 with an
 * ordered reduction (bit-exact against a scalar loop) and with per-lane
 * vfmacc (bit-exact against a scalar model of the lanes using fused
 * multiply-add), float16 with vfmacc and vfwmacc (Zvfh) and with
 * vfwcvt.f.f.v only (Zvfhmin). Float16 operands are small integers built
 * from bit patterns, so every sum is exact and the checks do not depend on
 * scalar float16 support. Build with -ffp-contract=off. Define VT_NO_ZVFH to
 * skip the Zvfh kernels on a Zvfhmin-only target.
 */

#include "vec_test.h"

float dot_f32_ord(const float *a, const float *b, size_t n);
float dot_f32_fma(const float *a, const float *b, size_t n);
double dot_f64_ord(const double *a, const double *b, size_t n);
double dot_f64_fma(const double *a, const double *b, size_t n);
unsigned long dot_f16_fma(const uint16_t *a, const uint16_t *b, size_t n);
float dot_f16_fwma(const uint16_t *a, const uint16_t *b, size_t n);
float dot_f16_widen(const uint16_t *a, const uint16_t *b, size_t n);
unsigned long f32_to_f16_sum(float x);

#define MAXN 1100
static uint64_t seed = 0x0badc0ffee0ddf00ull;
static float fa[MAXN], fb[MAXN];
static double da[MAXN], db[MAXN];
static uint16_t ha[MAXN], hb[MAXN];

static uint32_t bits32(float x)
{
    uint32_t u;
    memcpy(&u, &x, 4);
    return u;
}

static uint64_t bits64(double x)
{
    uint64_t u;
    memcpy(&u, &x, 8);
    return u;
}

static uint16_t int_to_f16(int v)
{
    unsigned sign = v < 0;
    unsigned mag = (unsigned) (v < 0 ? -v : v);
    if (mag == 0)
        return 0;
    int p = 31 - __builtin_clz(mag);
    unsigned mant = p <= 10 ? (mag << (10 - p)) & 0x3ff : (mag >> (p - 10)) & 0x3ff;
    return (uint16_t) ((sign << 15) | ((unsigned) (p + 15) << 10) | mant);
}

static void test_f32(unsigned long n)
{
    unsigned long lanes = vt_vlenb() / 4;
    for (unsigned long i = 0; i < n; i++) {
        fa[i] = (float) ((int) (vt_rand(&seed) % 4001) - 2000) * 0.0173f;
        fb[i] = (float) ((int) (vt_rand(&seed) % 4001) - 2000) * 0.00371f;
    }
    volatile float acc = 0.0f;
    for (unsigned long i = 0; i < n; i++) {
        volatile float p = fa[i] * fb[i];
        acc = acc + p;
    }
    VT_EQ(bits32(dot_f32_ord(fa, fb, n)), bits32(acc), "dot_f32_ord");
    float lane[64] = {0};
    for (unsigned long i = 0; i < n; i++)
        lane[i % lanes] = __builtin_fmaf(fa[i], fb[i], lane[i % lanes]);
    float sum = 0.0f;
    for (unsigned long j = 0; j < lanes; j++)
        sum = sum + lane[j];
    VT_EQ(bits32(dot_f32_fma(fa, fb, n)), bits32(sum), "dot_f32_fma");
}

static void test_f64(unsigned long n)
{
    unsigned long lanes = vt_vlenb() / 8;
    for (unsigned long i = 0; i < n; i++) {
        da[i] = (double) ((long) (vt_rand(&seed) >> 14) - (1l << 49)) * 3.1e-9;
        db[i] = (double) ((long) (vt_rand(&seed) >> 14) - (1l << 49)) * 7.7e-10;
    }
    volatile double acc = 0.0;
    for (unsigned long i = 0; i < n; i++) {
        volatile double p = da[i] * db[i];
        acc = acc + p;
    }
    VT_EQ(bits64(dot_f64_ord(da, db, n)), bits64(acc), "dot_f64_ord");
    double lane[64] = {0};
    for (unsigned long i = 0; i < n; i++)
        lane[i % lanes] = __builtin_fma(da[i], db[i], lane[i % lanes]);
    double sum = 0.0;
    for (unsigned long j = 0; j < lanes; j++)
        sum = sum + lane[j];
    VT_EQ(bits64(dot_f64_fma(da, db, n)), bits64(sum), "dot_f64_fma");
}

static void test_f16(unsigned long n)
{
    int sum = 0;
    for (unsigned long i = 0; i < n; i++) {
        int x = (int) (vt_rand(&seed) % 7) - 3;
        int y = (int) (vt_rand(&seed) % 7) - 3;
        ha[i] = int_to_f16(x);
        hb[i] = int_to_f16(y);
        sum += x * y;
    }
#ifndef VT_NO_ZVFH
    VT_EQ(dot_f16_fma(ha, hb, n) & 0xffff, sum == 0 ? 0 : int_to_f16(sum), "dot_f16_fma");
    VT_EQ(bits32(dot_f16_fwma(ha, hb, n)), bits32((float) sum), "dot_f16_fwma");
#endif
    VT_EQ(bits32(dot_f16_widen(ha, hb, n)), bits32((float) sum), "dot_f16_widen (Zvfhmin)");
    VT_EQ(f32_to_f16_sum((float) sum) & 0xffff, int_to_f16(sum), "vfncvt.f.f.w (Zvfhmin)");
}

int main(void)
{
    vt_enable_vector();
    vt_trap_install();
    unsigned long v = vt_vlenb();
    unsigned long sizes[] = {0, 1, 5, v / 8, v / 4, v / 4 + 1, v / 2 + 3, 3 * v + 1, 400};
    for (unsigned i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
        unsigned long n = sizes[i];
        for (unsigned round = 0; round < 3; round++) {
            test_f32(n);
            test_f64(n);
            if (n <= 100)
                test_f16(n);
        }
    }
    /* A few exact-result sanity checks on f16 conversion helpers. */
    VT_EQ(int_to_f16(1), 0x3c00, "f16 1.0");
    VT_EQ(int_to_f16(-3), 0xc200, "f16 -3.0");
    VT_EQ(int_to_f16(2048), 0x6800, "f16 2048");
    return vt_finish("vec_dot_fp");
}
