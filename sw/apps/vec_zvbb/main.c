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
 * Zvbb (vandn, vbrev, vbrev8, vrev8, vclz, vctz, vcpop, vrol, vror, vwsll)
 * and Zvbc (vclmul, vclmulh) at every element width they support, checked
 * element by element against scalar models. Operands mix random values with
 * zero, all-ones and single-bit patterns; shift and rotate amounts cover
 * values beyond the element width, which the instructions take modulo SEW.
 */

#include "vec_test.h"

#define N 160
static uint64_t seed = 0x3141592653589793ull;
static uint8_t abuf[N * 8], bbuf[N * 8], obuf[N * 16];

static uint64_t get(const uint8_t *p, unsigned i, unsigned bytes)
{
    uint64_t v = 0;
    memcpy(&v, p + (size_t) i * bytes, bytes);
    return v;
}

static void put(uint8_t *p, unsigned i, unsigned bytes, uint64_t v)
{
    memcpy(p + (size_t) i * bytes, &v, bytes);
}

static uint64_t mask_of(unsigned bits)
{
    return bits == 64 ? ~0ull : (1ull << bits) - 1;
}

static void fill(unsigned bits)
{
    unsigned bytes = bits / 8;
    for (unsigned i = 0; i < N; i++) {
        uint64_t r = vt_rand(&seed), s = vt_rand(&seed);
        uint64_t a = r & mask_of(bits), b = s & mask_of(bits);
        switch (i % 8) {
            case 0:
                a = 0;
                break;
            case 1:
                a = mask_of(bits);
                break;
            case 2:
                a = 1ull << (s % bits);
                break;
            case 3:
                b = (s % (3 * bits));
                break; /* shift amounts above the width */
            default:
                break;
        }
        put(abuf, i, bytes, a);
        put(bbuf, i, bytes, b);
    }
}

static uint64_t rol(uint64_t a, unsigned s, unsigned bits)
{
    s %= bits;
    return s ? ((a << s) | (a >> (bits - s))) & mask_of(bits) : a;
}
static uint64_t ror(uint64_t a, unsigned s, unsigned bits)
{
    s %= bits;
    return s ? ((a >> s) | (a << (bits - s))) & mask_of(bits) : a;
}
static uint64_t brev(uint64_t a, unsigned bits)
{
    uint64_t r = 0;
    for (unsigned i = 0; i < bits; i++)
        r |= ((a >> i) & 1) << (bits - 1 - i);
    return r;
}
static uint64_t brev8(uint64_t a, unsigned bits)
{
    uint64_t r = 0;
    for (unsigned by = 0; by < bits / 8; by++)
        r |= brev((a >> (8 * by)) & 0xff, 8) << (8 * by);
    return r;
}
static uint64_t rev8(uint64_t a, unsigned bits)
{
    uint64_t r = 0;
    for (unsigned by = 0; by < bits / 8; by++)
        r |= ((a >> (8 * by)) & 0xff) << (bits - 8 - 8 * by);
    return r;
}
static uint64_t clz(uint64_t a, unsigned bits)
{
    unsigned n = 0;
    while (n < bits && !((a >> (bits - 1 - n)) & 1))
        n++;
    return n;
}
static uint64_t ctz(uint64_t a, unsigned bits)
{
    unsigned n = 0;
    while (n < bits && !((a >> n) & 1))
        n++;
    return n;
}
static uint64_t cpop(uint64_t a, unsigned bits)
{
    (void) bits;
    unsigned n = 0;
    while (a) {
        n += a & 1;
        a >>= 1;
    }
    return n;
}

/* One vector operation over N elements at SEW = BITS with LMUL = 2. Under
 * BODY, v8 holds a, v10 holds b and the result goes to v12. */
#define VV_CASE(NAME, BITS, INSN, EXPR)                                                            \
    static void NAME##_##BITS(void)                                                                \
    {                                                                                              \
        unsigned bytes = BITS / 8;                                                                 \
        fill(BITS);                                                                                \
        memset(obuf, 0, sizeof obuf);                                                              \
        unsigned long done = 0, vl;                                                                \
        while (done < N) {                                                                         \
            __asm__ volatile("vsetvli %0, %1, e" #BITS ", m2, ta, ma\n\t"                          \
                             "vle" #BITS ".v v8, (%2)\n\t"                                         \
                             "vle" #BITS ".v v10, (%3)\n\t" INSN "\n\t"                            \
                             "vse" #BITS ".v v12, (%4)\n\t"                                        \
                             : "=&r"(vl)                                                           \
                             : "r"(N - done),                                                      \
                               "r"(abuf + done * bytes),                                           \
                               "r"(bbuf + done * bytes),                                           \
                               "r"(obuf + done * bytes)                                            \
                             : "v8", "v9", "v10", "v11", "v12", "v13", "t0", "memory");            \
            done += vl;                                                                            \
        }                                                                                          \
        unsigned bad = 0;                                                                          \
        for (unsigned i = 0; i < N; i++) {                                                         \
            uint64_t a = get(abuf, i, bytes), b = get(bbuf, i, bytes);                             \
            (void) a;                                                                              \
            (void) b;                                                                              \
            uint64_t want = (EXPR) & mask_of(BITS);                                                \
            if (get(obuf, i, bytes) != want) {                                                     \
                if (!bad++) {                                                                      \
                    vt_fail_head(#NAME " e" #BITS, __LINE__);                                      \
                    vt_puts(" elem ");                                                             \
                    vt_dec(i);                                                                     \
                    vt_puts(" a ");                                                                \
                    vt_hex(a);                                                                     \
                    vt_puts(" b ");                                                                \
                    vt_hex(b);                                                                     \
                    vt_puts(" got ");                                                              \
                    vt_hex(get(obuf, i, bytes));                                                   \
                    vt_puts(" want ");                                                             \
                    vt_hex(want);                                                                  \
                    vt_puts("\r\n");                                                               \
                }                                                                                  \
            }                                                                                      \
        }                                                                                          \
        vt_checks++;                                                                               \
    }

#define ALL_WIDTHS(M, NAME, INSN, EXPR)                                                            \
    M(NAME, 8, INSN, EXPR)                                                                         \
    M(NAME, 16, INSN, EXPR)                                                                        \
    M(NAME, 32, INSN, EXPR)                                                                        \
    M(NAME, 64, INSN, EXPR)

ALL_WIDTHS(VV_CASE, vandn_vv, "vandn.vv v12, v8, v10", a & ~b)
ALL_WIDTHS(VV_CASE, vrol_vv, "vrol.vv v12, v8, v10", rol(a, (unsigned) (b % 64), 8 * bytes))
ALL_WIDTHS(VV_CASE, vror_vv, "vror.vv v12, v8, v10", ror(a, (unsigned) (b % 64), 8 * bytes))
ALL_WIDTHS(VV_CASE, vbrev_v, "vbrev.v v12, v8", brev(a, 8 * bytes))
ALL_WIDTHS(VV_CASE, vbrev8_v, "vbrev8.v v12, v8", brev8(a, 8 * bytes))
ALL_WIDTHS(VV_CASE, vrev8_v, "vrev8.v v12, v8", rev8(a, 8 * bytes))
ALL_WIDTHS(VV_CASE, vclz_v, "vclz.v v12, v8", clz(a, 8 * bytes))
ALL_WIDTHS(VV_CASE, vctz_v, "vctz.v v12, v8", ctz(a, 8 * bytes))
ALL_WIDTHS(VV_CASE, vcpop_v, "vcpop.v v12, v8", cpop(a, 8 * bytes))
VV_CASE(vror_vi, 32, "vror.vi v12, v8, 13", ror(a, 13, 32))
VV_CASE(vror_vi, 64, "vror.vi v12, v8, 45", ror(a, 45, 64))
VV_CASE(vrol_vx, 16, "li t0, 21\n\tvrol.vx v12, v8, t0", rol(a, 21, 16))
VV_CASE(vandn_vx, 8, "li t0, 0x3c\n\tvandn.vx v12, v8, t0", a & ~0x3cull)

/* Widening shift left logical: dest elements are 2 * SEW wide, LMUL doubles. */
#define WSLL_CASE(BITS, WBITS)                                                                     \
    static void vwsll_##BITS(void)                                                                 \
    {                                                                                              \
        unsigned bytes = BITS / 8;                                                                 \
        fill(BITS);                                                                                \
        memset(obuf, 0, sizeof obuf);                                                              \
        unsigned long done = 0, vl;                                                                \
        while (done < N) {                                                                         \
            __asm__ volatile("vsetvli %0, %1, e" #BITS ", m1, ta, ma\n\t"                          \
                             "vle" #BITS ".v v8, (%2)\n\t"                                         \
                             "vle" #BITS ".v v9, (%3)\n\t"                                         \
                             "vwsll.vv v12, v8, v9\n\t"                                            \
                             "vsetvli x0, %0, e" #WBITS ", m2, ta, ma\n\t"                         \
                             "vse" #WBITS ".v v12, (%4)\n\t"                                       \
                             : "=&r"(vl)                                                           \
                             : "r"(N - done),                                                      \
                               "r"(abuf + done * bytes),                                           \
                               "r"(bbuf + done * bytes),                                           \
                               "r"(obuf + done * 2 * bytes)                                        \
                             : "v8", "v9", "v12", "v13", "memory");                                \
            done += vl;                                                                            \
        }                                                                                          \
        unsigned bad = 0;                                                                          \
        for (unsigned i = 0; i < N; i++) {                                                         \
            uint64_t a = get(abuf, i, bytes), b = get(bbuf, i, bytes);                             \
            uint64_t want = (a << (b % (2 * BITS))) & mask_of(2 * BITS);                           \
            if (get(obuf, i, 2 * bytes) != want && !bad++) {                                       \
                vt_fail_head("vwsll e" #BITS, __LINE__);                                           \
                vt_puts("\r\n");                                                                   \
            }                                                                                      \
        }                                                                                          \
        vt_checks++;                                                                               \
    }
WSLL_CASE(8, 16)
WSLL_CASE(16, 32)
WSLL_CASE(32, 64)

/* Zvbc: 64-bit carry-less multiply, low and high halves. */
static void clmul128(uint64_t a, uint64_t b, uint64_t *lo, uint64_t *hi)
{
    uint64_t l = 0, h = 0;
    for (unsigned i = 0; i < 64; i++)
        if ((b >> i) & 1) {
            l ^= a << i;
            if (i)
                h ^= a >> (64 - i);
        }
    *lo = l;
    *hi = h;
}

static void test_clmul(void)
{
    fill(64);
    memset(obuf, 0, sizeof obuf);
    unsigned long done = 0, vl;
    uint8_t lo_buf[N * 8], hi_buf[N * 8];
    while (done < N) {
        __asm__ volatile("vsetvli %0, %1, e64, m2, ta, ma\n\t"
                         "vle64.v v8, (%2)\n\t"
                         "vle64.v v10, (%3)\n\t"
                         "vclmul.vv v12, v8, v10\n\t"
                         "vclmulh.vv v14, v8, v10\n\t"
                         "vse64.v v12, (%4)\n\t"
                         "vse64.v v14, (%5)\n\t"
                         : "=&r"(vl)
                         : "r"(N - done),
                           "r"(abuf + done * 8),
                           "r"(bbuf + done * 8),
                           "r"(lo_buf + done * 8),
                           "r"(hi_buf + done * 8)
                         : "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "memory");
        done += vl;
    }
    unsigned bad = 0;
    for (unsigned i = 0; i < N; i++) {
        uint64_t lo, hi;
        clmul128(get(abuf, i, 8), get(bbuf, i, 8), &lo, &hi);
        if ((get(lo_buf, i, 8) != lo || get(hi_buf, i, 8) != hi) && !bad++) {
            vt_fail_head("vclmul/vclmulh", __LINE__);
            vt_puts("\r\n");
        }
    }
    vt_checks++;
    /* vx form. */
    uint64_t x = 0x8000000000000001ull, lo, hi;
    uint64_t vlo, vhi;
    __asm__ volatile("vsetivli x0, 1, e64, m1, ta, ma\n\t"
                     "vle64.v v8, (%2)\n\t"
                     "vclmul.vx v9, v8, %3\n\t"
                     "vclmulh.vx v10, v8, %3\n\t"
                     "vmv.x.s %0, v9\n\t"
                     "vmv.x.s %1, v10\n\t"
                     : "=&r"(vlo), "=&r"(vhi)
                     : "r"(abuf), "r"(x)
                     : "v8", "v9", "v10", "memory");
    clmul128(get(abuf, 0, 8), x, &lo, &hi);
    VT_EQ(vlo, lo, "vclmul.vx");
    VT_EQ(vhi, hi, "vclmulh.vx");
}

int main(void)
{
    vt_enable_vector();
    vt_trap_install();
    seed ^= vt_vlenb();

#define RUN4(n)                                                                                    \
    n##_8();                                                                                       \
    n##_16();                                                                                      \
    n##_32();                                                                                      \
    n##_64();
    RUN4(vandn_vv)
    RUN4(vrol_vv)
    RUN4(vror_vv)
    RUN4(vbrev_v)
    RUN4(vbrev8_v)
    RUN4(vrev8_v)
    RUN4(vclz_v)
    RUN4(vctz_v)
    RUN4(vcpop_v)
    vror_vi_32();
    vror_vi_64();
    vrol_vx_16();
    vandn_vx_8();
    vwsll_8();
    vwsll_16();
    vwsll_32();
    test_clmul();

    return vt_finish("vec_zvbb");
}
