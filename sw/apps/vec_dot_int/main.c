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
 * Integer dot products at 8, 16, 32 and 64 bits (dot_rvv.S): widening
 * multiply with widening reduction (int8, uint8, mixed-sign int8, int16,
 * int32), wrapping 64-bit multiply, and per-lane multiply-accumulate with
 * a tail-undisturbed vsetvli at every element width. Compared with scalar
 * loops over vector lengths that cover empty, single-element, partial-strip,
 * exact-strip and multi-strip inputs, with extreme-value operands.
 */

#include "vec_test.h"

int64_t dot_i8(const int8_t *a, const int8_t *b, size_t n);
int64_t dot_u8(const uint8_t *a, const uint8_t *b, size_t n);
int64_t dot_su8(const int8_t *a, const uint8_t *b, size_t n);
int64_t dot_i16(const int16_t *a, const int16_t *b, size_t n);
int64_t dot_i32(const int32_t *a, const int32_t *b, size_t n);
int64_t dot_i64(const int64_t *a, const int64_t *b, size_t n);
int64_t dot_i8_vmacc(const int8_t *a, const int8_t *b, size_t n);
int64_t dot_i16_vmacc(const int16_t *a, const int16_t *b, size_t n);
int64_t dot_i32_vmacc(const int32_t *a, const int32_t *b, size_t n);
int64_t dot_i64_vmacc(const int64_t *a, const int64_t *b, size_t n);

#define MAXN 1100
static uint64_t seed = 0xfeedfacecafebeefull;
static union {
    int8_t i8[MAXN];
    int16_t i16[MAXN];
    int32_t i32[MAXN];
    int64_t i64[MAXN];
    uint8_t u8[MAXN];
} a, b;

static unsigned long sizes[8];

static void init_sizes(void)
{
    unsigned long vlenb = vt_vlenb();
    unsigned long v = vlenb; /* e8 m1 elements per register */
    unsigned long list[] = {0, 1, 7, v - 1, v, v + 1, 3 * v + 5, 1000};
    for (unsigned i = 0; i < 8; i++)
        sizes[i] = list[i] > 1000 ? 1000 : list[i];
}

/* Operand mix: random with frequent extremes. */
static int64_t pick(unsigned bits, int is_signed)
{
    uint64_t r = vt_rand(&seed);
    unsigned sel = (unsigned) (r >> 60);
    uint64_t mask = bits == 64 ? ~0ull : ((1ull << bits) - 1);
    uint64_t v = (r >> 8) & mask;
    if (sel == 0)
        v = is_signed ? (1ull << (bits - 1)) : mask; /* most negative / max */
    else if (sel == 1)
        v = is_signed ? ((1ull << (bits - 1)) - 1) & mask : mask;
    else if (sel == 2)
        v = mask; /* -1 or max */
    if (bits < 64 && is_signed && (v >> (bits - 1)) & 1)
        return (int64_t) (v | ~mask);
    return (int64_t) v;
}

static void test_int(void)
{
    for (unsigned s = 0; s < 8; s++) {
        size_t n = sizes[s];
        for (unsigned round = 0; round < 3; round++) {
            for (size_t i = 0; i < n; i++) {
                a.i64[i] = 0;
                b.i64[i] = 0;
            }
            /* int8 */
            for (size_t i = 0; i < n; i++) {
                a.i8[i] = (int8_t) pick(8, 1);
                b.i8[i] = (int8_t) pick(8, 1);
            }
            int32_t w32 = 0;
            for (size_t i = 0; i < n; i++)
                w32 += (int32_t) a.i8[i] * b.i8[i];
            VT_EQ(dot_i8(a.i8, b.i8, n), (int64_t) w32, "dot_i8");
            uint8_t m8 = 0;
            for (size_t i = 0; i < n; i++)
                m8 = (uint8_t) (m8 + (uint8_t) ((uint8_t) a.i8[i] * (uint8_t) b.i8[i]));
            VT_EQ((uint8_t) dot_i8_vmacc(a.i8, b.i8, n), m8, "dot_i8_vmacc");
            uint32_t u32 = 0;
            for (size_t i = 0; i < n; i++)
                u32 += (uint32_t) a.u8[i] * b.u8[i];
            VT_EQ((uint32_t) dot_u8(a.u8, b.u8, n), u32, "dot_u8");
            w32 = 0;
            for (size_t i = 0; i < n; i++)
                w32 += (int32_t) a.i8[i] * (int32_t) b.u8[i];
            VT_EQ(dot_su8(a.i8, b.u8, n), (int64_t) w32, "dot_su8");

            /* int16 */
            for (size_t i = 0; i < n; i++) {
                a.i16[i] = (int16_t) pick(16, 1);
                b.i16[i] = (int16_t) pick(16, 1);
            }
            int64_t w64 = 0;
            for (size_t i = 0; i < n; i++)
                w64 += (int64_t) a.i16[i] * b.i16[i];
            VT_EQ(dot_i16(a.i16, b.i16, n), w64, "dot_i16");
            uint16_t m16 = 0;
            for (size_t i = 0; i < n; i++)
                m16 = (uint16_t) (m16 + (uint16_t) ((uint32_t) (uint16_t) a.i16[i] *
                                                    (uint32_t) (uint16_t) b.i16[i]));
            VT_EQ((uint16_t) dot_i16_vmacc(a.i16, b.i16, n), m16, "dot_i16_vmacc");

            /* int32 */
            for (size_t i = 0; i < n; i++) {
                a.i32[i] = (int32_t) pick(32, 1);
                b.i32[i] = (int32_t) pick(32, 1);
            }
            w64 = 0;
            for (size_t i = 0; i < n; i++)
                w64 = (int64_t) ((uint64_t) w64 + (uint64_t) ((int64_t) a.i32[i] * b.i32[i]));
            VT_EQ(dot_i32(a.i32, b.i32, n), w64, "dot_i32");
            uint32_t m32 = 0;
            for (size_t i = 0; i < n; i++)
                m32 += (uint32_t) a.i32[i] * (uint32_t) b.i32[i];
            VT_EQ((uint32_t) dot_i32_vmacc(a.i32, b.i32, n), m32, "dot_i32_vmacc");

            /* int64 */
            for (size_t i = 0; i < n; i++) {
                a.i64[i] = pick(64, 1);
                b.i64[i] = pick(64, 1);
            }
            uint64_t m64 = 0;
            for (size_t i = 0; i < n; i++)
                m64 += (uint64_t) a.i64[i] * (uint64_t) b.i64[i];
            VT_EQ((uint64_t) dot_i64(a.i64, b.i64, n), m64, "dot_i64");
            VT_EQ((uint64_t) dot_i64_vmacc(a.i64, b.i64, n), m64, "dot_i64_vmacc");
        }
    }
}

int main(void)
{
    vt_enable_vector();
    vt_trap_install();
    init_sizes();
    test_int();
    return vt_finish("vec_dot_int");
}
