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
 * Vector load and store forms: unit-stride, mask (vlm/vsm), whole register,
 * strided (positive, negative and zero stride), indexed (unordered and
 * ordered, index EEW 8/16/32/64), segments (unit-stride, strided, indexed),
 * fault-only-first (including segments), masked forms, tail and prestart
 * behavior, and precise faults with vstart and mtval.
 *
 * Each case runs a vsetvli and the access in one asm statement, reads back
 * vl, and compares memory or registers against a scalar model. Memory beyond
 * the last element written must keep its guard pattern.
 */

#include "vec_test.h"

#define STR_(x) #x
#define STR(x) STR_(x)

#define GUARD 0xEE
#define SPAN 1024

static uint8_t src[4096] __attribute__((aligned(64)));
static uint8_t dst[4096] __attribute__((aligned(64)));
static uint8_t exp_[4096] __attribute__((aligned(64)));
static uint8_t idx[2048] __attribute__((aligned(64)));
static uint64_t seed = 0x1234567890abcdefull;

#define VCLOB                                                                                      \
    "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", \
        "v15", "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23", "v24", "v25", "v26", "v27", \
        "v28", "v29", "v30", "v31", "memory"

static void init_data(void)
{
    for (unsigned i = 0; i < sizeof src; i++)
        src[i] = (uint8_t) vt_rand(&seed);
}

static void clear_dst(void)
{
    memset(dst, GUARD, sizeof dst);
    memset(exp_, GUARD, sizeof exp_);
}

static void check_mem(const char *what, int line)
{
    vt_checks++;
    if (memcmp(dst, exp_, SPAN) != 0) {
        unsigned i = 0;
        while (dst[i] == exp_[i])
            i++;
        vt_fail_head(what, line);
        if (vt_failures <= VT_FAIL_LIMIT) {
            vt_puts(" first diff at byte ");
            vt_dec(i);
            vt_puts(" got ");
            vt_hex(dst[i]);
            vt_puts(" want ");
            vt_hex(exp_[i]);
            vt_puts("\r\n");
        }
    }
}
#define CHECK_MEM(what) check_mem(what, __LINE__)

static unsigned long vlmax_for(unsigned eew_bytes, unsigned lmul_num, unsigned lmul_den)
{
    return vt_vlenb() / eew_bytes * lmul_num / lmul_den;
}

static unsigned long avl_pick(unsigned i, unsigned long vlmax)
{
    switch (i) {
        case 0:
            return vlmax;
        case 1:
            return vlmax / 2 + 1;
        case 2:
            return 1;
        case 3:
            return vlmax + 5;
        default:
            return vlmax - (vlmax > 1 ? 1 : 0);
    }
}

/* ---------------------------------------------------------------- unit */

#define UNIT_CASE(EEW, LM, LMN)                                                                    \
    static void unit_e##EEW##_m##LM(void)                                                          \
    {                                                                                              \
        unsigned long vlmax = vlmax_for(EEW / 8, LMN, 1);                                          \
        for (unsigned a = 0; a < 5; a++) {                                                         \
            unsigned long avl = avl_pick(a, vlmax), vl;                                            \
            clear_dst();                                                                           \
            __asm__ volatile("vsetvli %0, %1, e" #EEW ", m" #LM ", ta, ma\n\t"                     \
                             "vle" #EEW ".v v8, (%2)\n\t"                                          \
                             "vse" #EEW ".v v8, (%3)\n\t"                                          \
                             : "=&r"(vl)                                                           \
                             : "r"(avl), "r"(src + 8), "r"(dst + 16)                               \
                             : VCLOB);                                                             \
            VT_EQ(vl, avl > vlmax ? vlmax : avl, "unit vl e" #EEW " m" #LM);                       \
            memcpy(exp_ + 16, src + 8, vl * (EEW / 8));                                            \
            CHECK_MEM("unit-stride e" #EEW " m" #LM);                                              \
        }                                                                                          \
    }
UNIT_CASE(8, 1, 1)
UNIT_CASE(8, 8, 8)
UNIT_CASE(16, 1, 1)
UNIT_CASE(16, 2, 2)
UNIT_CASE(32, 1, 1)
UNIT_CASE(32, 4, 4)
UNIT_CASE(64, 1, 1)
UNIT_CASE(64, 8, 8)

/* Fractional LMUL: vle8 at mf2 and vle32 at mf2 use half a register. */
static void unit_fractional(void)
{
    unsigned long vl;
    clear_dst();
    __asm__ volatile("vsetvli %0, %1, e8, mf2, ta, ma\n\t"
                     "vle8.v v8, (%2)\n\t"
                     "vse8.v v8, (%3)\n\t"
                     : "=&r"(vl)
                     : "r"(1000ul), "r"(src), "r"(dst)
                     : VCLOB);
    VT_EQ(vl, vt_vlenb() / 2, "mf2 e8 vl");
    memcpy(exp_, src, vl);
    CHECK_MEM("unit-stride e8 mf2");
    clear_dst();
    __asm__ volatile("vsetvli %0, %1, e32, mf2, ta, ma\n\t"
                     "vle32.v v8, (%2)\n\t"
                     "vse32.v v8, (%3)\n\t"
                     : "=&r"(vl)
                     : "r"(1000ul), "r"(src), "r"(dst)
                     : VCLOB);
    VT_EQ(vl, vt_vlenb() / 8, "mf2 e32 vl");
    memcpy(exp_, src, vl * 4);
    CHECK_MEM("unit-stride e32 mf2");
}

/* EEW in the load differs from the current SEW: the load uses its own EEW. */
static void unit_eew_differs_from_sew(void)
{
    unsigned long vl;
    clear_dst();
    __asm__ volatile("vsetvli %0, %1, e32, m1, ta, ma\n\t"
                     "vle8.v v8, (%2)\n\t" /* EEW 8, EMUL 1/4: elements = vl */
                     "vse8.v v8, (%3)\n\t"
                     : "=&r"(vl)
                     : "r"(1000ul), "r"(src), "r"(dst)
                     : VCLOB);
    VT_EQ(vl, vt_vlenb() / 4, "e32 m1 vl");
    memcpy(exp_, src, vl);
    CHECK_MEM("vle8 under e32 m1");
}

/* Masked unit-stride store: inactive elements leave memory alone. */
static void unit_masked(void)
{
    unsigned long vl;
    uint8_t mask[64];
    for (unsigned i = 0; i < 64; i++)
        mask[i] = (uint8_t) vt_rand(&seed);
    clear_dst();
    /* Store: mask = v0 loaded with vlm.v. */
    __asm__ volatile("vsetvli %0, %1, e32, m1, ta, ma\n\t"
                     "vlm.v v0, (%2)\n\t"
                     "vle32.v v8, (%3)\n\t"
                     "vse32.v v8, (%4), v0.t\n\t"
                     : "=&r"(vl)
                     : "r"(1000ul), "r"(mask), "r"(src), "r"(dst)
                     : VCLOB);
    for (unsigned i = 0; i < vl; i++)
        if ((mask[i / 8] >> (i % 8)) & 1)
            memcpy(exp_ + 4 * i, src + 4 * i, 4);
    CHECK_MEM("masked vse32");
    /* Load: masked-off elements keep the old register value (mask-undisturbed). */
    clear_dst();
    __asm__ volatile("vsetvli %0, %1, e32, m1, tu, mu\n\t"
                     "vlm.v v0, (%2)\n\t"
                     "vmv.v.i v8, -1\n\t"
                     "vle32.v v8, (%3), v0.t\n\t"
                     "vse32.v v8, (%4)\n\t"
                     : "=&r"(vl)
                     : "r"(1000ul), "r"(mask), "r"(src), "r"(dst)
                     : VCLOB);
    for (unsigned i = 0; i < vl; i++) {
        if ((mask[i / 8] >> (i % 8)) & 1)
            memcpy(exp_ + 4 * i, src + 4 * i, 4);
        else
            memset(exp_ + 4 * i, 0xff, 4);
    }
    CHECK_MEM("masked vle32 undisturbed");
}

/* vlm.v / vsm.v move ceil(vl / 8) bytes whatever the SEW. */
static void mask_ls(void)
{
    unsigned long vl;
    for (unsigned a = 0; a < 5; a++) {
        unsigned long avl = avl_pick(a, vlmax_for(1, 1, 1));
        clear_dst();
        __asm__ volatile("vsetvli %0, %1, e8, m1, ta, ma\n\t"
                         "vlm.v v8, (%2)\n\t"
                         "vsm.v v8, (%3)\n\t"
                         : "=&r"(vl)
                         : "r"(avl), "r"(src), "r"(dst)
                         : VCLOB);
        memcpy(exp_, src, (vl + 7) / 8);
        CHECK_MEM("vlm/vsm");
    }
}

/* ---------------------------------------------------------------- whole register */

#define WHOLE_CASE(NF, EEW)                                                                        \
    do {                                                                                           \
        clear_dst();                                                                               \
        __asm__ volatile("vsetvli x0, x0, e8, m1, ta, ma\n\t"                                      \
                         "vl" #NF "re" #EEW ".v v8, (%0)\n\t"                                      \
                         "vs" #NF "r.v v8, (%1)\n\t"                                               \
                         :                                                                         \
                         : "r"(src), "r"(dst)                                                      \
                         : VCLOB);                                                                 \
        memcpy(exp_, src, NF * vt_vlenb());                                                        \
        CHECK_MEM("whole register vl" #NF "re" #EEW);                                              \
    } while (0)

static void whole_register(void)
{
    /* vl = 0 would change nothing for these: they ignore vl and vtype. */
    WHOLE_CASE(1, 8);
    WHOLE_CASE(1, 64);
    WHOLE_CASE(2, 16);
    WHOLE_CASE(4, 32);
    WHOLE_CASE(8, 8);
    WHOLE_CASE(8, 64);
    /* With vl = 0. */
    clear_dst();
    __asm__ volatile("vsetivli x0, 0, e8, m1, ta, ma\n\t"
                     "vl2re8.v v8, (%0)\n\t"
                     "vs2r.v v8, (%1)\n\t"
                     :
                     : "r"(src), "r"(dst)
                     : VCLOB);
    memcpy(exp_, src, 2 * vt_vlenb());
    CHECK_MEM("whole register ignores vl");
}

/* ---------------------------------------------------------------- strided */

#define STRIDE_CASE(EEW, LM, LMN)                                                                  \
    static void stride_e##EEW##_m##LM(void)                                                        \
    {                                                                                              \
        const long strides[] = {EEW / 8 * 3, -(long) (EEW / 8) * 2, 0, EEW / 8, EEW / 8 * 5};      \
        unsigned long vlmax = vlmax_for(EEW / 8, LMN, 1);                                          \
        for (unsigned s = 0; s < 5; s++) {                                                         \
            long stride = strides[s];                                                              \
            unsigned long vl;                                                                      \
            /* Load: base in the middle of src so negative strides stay in range. */               \
            const uint8_t *base = src + 2048;                                                      \
            clear_dst();                                                                           \
            __asm__ volatile("vsetvli %0, %1, e" #EEW ", m" #LM ", ta, ma\n\t"                     \
                             "vlse" #EEW ".v v8, (%2), %3\n\t"                                     \
                             "vse" #EEW ".v v8, (%4)\n\t"                                          \
                             : "=&r"(vl)                                                           \
                             : "r"(vlmax), "r"(base), "r"(stride), "r"(dst)                        \
                             : VCLOB);                                                             \
            for (unsigned i = 0; i < vl; i++)                                                      \
                memcpy(exp_ + i * (EEW / 8), base + (long) i * stride, EEW / 8);                   \
            CHECK_MEM("strided load e" #EEW " m" #LM);                                             \
            /* Store the dense source with a stride. Zero stride writes every element to the       \
             * same place, in no defined order: any one of them may be left there. */              \
            uint8_t *obase = dst + 2048;                                                           \
            clear_dst();                                                                           \
            __asm__ volatile("vsetvli %0, %1, e" #EEW ", m" #LM ", ta, ma\n\t"                     \
                             "vle" #EEW ".v v8, (%2)\n\t"                                          \
                             "vsse" #EEW ".v v8, (%3), %4\n\t"                                     \
                             : "=&r"(vl)                                                           \
                             : "r"(vlmax), "r"(src), "r"(obase), "r"(stride)                       \
                             : VCLOB);                                                             \
            /* exp_ sits at the same offset in its buffer: compare the 2048 + SPAN window. */      \
            for (unsigned i = 0; i < vl; i++)                                                      \
                memcpy(exp_ + 2048 + (long) i * stride, src + i * (EEW / 8), EEW / 8);             \
            vt_checks++;                                                                           \
            {                                                                                      \
                int same = memcmp(dst + 1024, exp_ + 1024, 1024 + 1024) == 0;                      \
                for (unsigned i = 0; stride == 0 && !same && i < vl; i++) {                        \
                    memcpy(exp_ + 2048, src + i * (EEW / 8), EEW / 8);                             \
                    same = memcmp(dst + 1024, exp_ + 1024, 1024 + 1024) == 0;                      \
                }                                                                                  \
                if (!same) {                                                                       \
                    vt_fail_head("strided store e" #EEW " m" #LM, __LINE__);                       \
                    vt_puts("\r\n");                                                               \
                }                                                                                  \
            }                                                                                      \
        }                                                                                          \
    }
STRIDE_CASE(8, 1, 1)
STRIDE_CASE(16, 2, 2)
STRIDE_CASE(32, 1, 1)
STRIDE_CASE(64, 4, 4)

/* ---------------------------------------------------------------- indexed */

/* Data SEW 32, LMUL 1; index EEW 8/16/32/64 with EMUL 1/4, 1/2, 1, 2.
 * Byte offsets form a permutation of the first vl words, reversed. */
#define INDEX_CASE(IEEW, VLOAD, VSTORE, KIND)                                                      \
    static void indexed_##KIND##_i##IEEW(void)                                                     \
    {                                                                                              \
        unsigned long vlmax = vlmax_for(4, 1, 1);                                                  \
        /* Index element width limits the offsets: 8-bit offsets reach 255 bytes. */               \
        unsigned long n = vlmax;                                                                   \
        if (IEEW == 8 && n > 64)                                                                   \
            n = 64; /* 64 words = 256 bytes */                                                     \
        unsigned long vl;                                                                          \
        for (unsigned i = 0; i < 64; i++) {                                                        \
            unsigned long off = (n - 1 - i) * 4; /* reversed */                                    \
            if (i >= n)                                                                            \
                off = 0;                                                                           \
            memcpy(idx + i * (IEEW / 8), &off, IEEW / 8);                                          \
        }                                                                                          \
        clear_dst();                                                                               \
        __asm__ volatile("vsetvli %0, %1, e32, m1, ta, ma\n\t"                                     \
                         "vle" #IEEW ".v v16, (%2)\n\t" /* vle uses its own EEW and EMUL */        \
                         VLOAD " v8, (%3), v16\n\t"                                                \
                         "vse32.v v8, (%4)\n\t"                                                    \
                         : "=&r"(vl)                                                               \
                         : "r"(n), "r"(idx), "r"(src), "r"(dst)                                    \
                         : VCLOB);                                                                 \
        for (unsigned i = 0; i < vl; i++)                                                          \
            memcpy(exp_ + 4 * i, src + (n - 1 - i) * 4, 4);                                        \
        CHECK_MEM(#KIND " load i" #IEEW);                                                          \
        clear_dst();                                                                               \
        __asm__ volatile("vsetvli %0, %1, e32, m1, ta, ma\n\t"                                     \
                         "vle" #IEEW ".v v16, (%2)\n\t"                                            \
                         "vle32.v v8, (%3)\n\t" VSTORE " v8, (%4), v16\n\t"                        \
                         : "=&r"(vl)                                                               \
                         : "r"(n), "r"(idx), "r"(src), "r"(dst)                                    \
                         : VCLOB);                                                                 \
        for (unsigned i = 0; i < vl; i++)                                                          \
            memcpy(exp_ + (n - 1 - i) * 4, src + 4 * i, 4);                                        \
        CHECK_MEM(#KIND " store i" #IEEW);                                                         \
    }
INDEX_CASE(8, "vluxei8.v", "vsuxei8.v", unordered)
INDEX_CASE(16, "vluxei16.v", "vsuxei16.v", unordered)
INDEX_CASE(32, "vluxei32.v", "vsuxei32.v", unordered)
INDEX_CASE(64, "vluxei64.v", "vsuxei64.v", unordered)
INDEX_CASE(8, "vloxei8.v", "vsoxei8.v", ordered)
INDEX_CASE(16, "vloxei16.v", "vsoxei16.v", ordered)
INDEX_CASE(32, "vloxei32.v", "vsoxei32.v", ordered)
INDEX_CASE(64, "vloxei64.v", "vsoxei64.v", ordered)

/* Ordered store with all indices equal: the last element's value remains. */
static void ordered_store_duplicates(void)
{
    unsigned long vl;
    memset(idx, 0, 512);
    clear_dst();
    __asm__ volatile("vsetvli %0, %1, e32, m1, ta, ma\n\t"
                     "vle32.v v16, (%2)\n\t"
                     "vle32.v v8, (%3)\n\t"
                     "vsoxei32.v v8, (%4), v16\n\t"
                     : "=&r"(vl)
                     : "r"(1000ul), "r"(idx), "r"(src), "r"(dst + 8)
                     : VCLOB);
    memcpy(exp_ + 8, src + 4 * (vl - 1), 4);
    CHECK_MEM("vsoxei32 duplicate indices, last wins");
}

/* Masked indexed load with mask-undisturbed. */
static void indexed_masked(void)
{
    unsigned long vl;
    uint8_t mask[64];
    for (unsigned i = 0; i < 64; i++)
        mask[i] = (uint8_t) vt_rand(&seed);
    unsigned long n = vlmax_for(4, 1, 1);
    for (unsigned i = 0; i < n; i++) {
        uint32_t off = (uint32_t) ((i * 7) % n) * 4;
        memcpy(idx + 4 * i, &off, 4);
    }
    clear_dst();
    __asm__ volatile("vsetvli %0, %1, e32, m1, tu, mu\n\t"
                     "vlm.v v0, (%2)\n\t"
                     "vle32.v v16, (%3)\n\t"
                     "vmv.v.i v8, 0\n\t"
                     "vluxei32.v v8, (%4), v16, v0.t\n\t"
                     "vse32.v v8, (%5)\n\t"
                     : "=&r"(vl)
                     : "r"(n), "r"(mask), "r"(idx), "r"(src), "r"(dst)
                     : VCLOB);
    for (unsigned i = 0; i < vl; i++) {
        if ((mask[i / 8] >> (i % 8)) & 1)
            memcpy(exp_ + 4 * i, src + 4 * (((i * 7) % n)), 4);
        else
            memset(exp_ + 4 * i, 0, 4);
    }
    CHECK_MEM("masked indexed load");
}

/* ---------------------------------------------------------------- segments */

/* vlsegNeEEW.v v8, then store the fields to separate arrays with vse.
 * Field f element i comes from memory element i * NF + f. */
#define SEG_CASE(NF, EEW, LM)                                                                      \
    static void seg_##NF##_e##EEW(void)                                                            \
    {                                                                                              \
        unsigned long vlmax = vlmax_for(EEW / 8, 1, 1);                                            \
        unsigned long vl;                                                                          \
        clear_dst();                                                                               \
        __asm__ volatile("vsetvli %0, %1, e" #EEW ", m1, ta, ma\n\t"                               \
                         "vlseg" #NF "e" #EEW ".v v8, (%2)\n\t"                                    \
                         "vsseg" #NF "e" #EEW ".v v8, (%3)\n\t" /* round trip */                   \
                         : "=&r"(vl)                                                               \
                         : "r"(vlmax), "r"(src), "r"(dst)                                          \
                         : VCLOB);                                                                 \
        memcpy(exp_, src, vl * NF * (EEW / 8));                                                    \
        CHECK_MEM("segment round trip nf" #NF " e" #EEW);                                          \
        /* Field order: copy each field register out with vse. */                                  \
        clear_dst();                                                                               \
        uint8_t *d = dst;                                                                          \
        __asm__ volatile("vsetvli %0, %1, e" #EEW ", m1, ta, ma\n\t"                               \
                         "vlseg" #NF "e" #EEW ".v v8, (%2)\n\t"                                    \
                         "vse" #EEW ".v v8, (%3)\n\t"                                              \
                         "vse" #EEW ".v v9, (%4)\n\t"                                              \
                         : "=&r"(vl)                                                               \
                         : "r"(vlmax), "r"(src), "r"(d), "r"(d + 256)                              \
                         : VCLOB);                                                                 \
        for (unsigned i = 0; i < vl; i++) {                                                        \
            memcpy(exp_ + i * (EEW / 8), src + (i * NF + 0) * (EEW / 8), EEW / 8);                 \
            memcpy(exp_ + 256 + i * (EEW / 8), src + (i * NF + 1) * (EEW / 8), EEW / 8);           \
        }                                                                                          \
        vt_checks++;                                                                               \
        if (memcmp(dst, exp_, 512) != 0)                                                           \
            vt_fail_head("segment fields nf" #NF " e" #EEW, __LINE__);                             \
    }
SEG_CASE(2, 8, 1)
SEG_CASE(3, 16, 1)
SEG_CASE(4, 32, 1)
SEG_CASE(5, 64, 1)
SEG_CASE(7, 8, 1)
SEG_CASE(8, 32, 1)

/* Strided and indexed segment forms. */
static void seg_strided_indexed(void)
{
    unsigned long vl;
    unsigned long vlmax = vlmax_for(4, 1, 1);
    /* vlsseg3e32: stride 20 bytes between segments. */
    clear_dst();
    __asm__ volatile("vsetvli %0, %1, e32, m1, ta, ma\n\t"
                     "vlsseg3e32.v v8, (%2), %3\n\t"
                     "vsseg3e32.v v8, (%4)\n\t"
                     : "=&r"(vl)
                     : "r"(vlmax), "r"(src), "r"(20ul), "r"(dst)
                     : VCLOB);
    for (unsigned i = 0; i < vl; i++)
        memcpy(exp_ + 12 * i, src + 20 * i, 12);
    CHECK_MEM("vlsseg3e32");
    /* vssseg2e16: store segments 12 bytes apart. */
    clear_dst();
    unsigned long vl16;
    __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma\n\t"
                     "vlseg2e16.v v8, (%2)\n\t"
                     "vssseg2e16.v v8, (%3), %4\n\t"
                     : "=&r"(vl16)
                     : "r"(vt_vlenb() / 2), "r"(src), "r"(dst), "r"(12ul)
                     : VCLOB);
    for (unsigned i = 0; i < vl16; i++)
        memcpy(exp_ + 12 * i, src + 4 * i, 4);
    CHECK_MEM("vssseg2e16");
    /* vluxseg2ei16 / vsuxseg2ei16 / vloxseg / vsoxseg: indices as byte offsets
     * of each segment, reversed. */
    unsigned long n = vlmax;
    for (unsigned i = 0; i < n; i++) {
        uint16_t off = (uint16_t) ((n - 1 - i) * 8);
        memcpy(idx + 2 * i, &off, 2);
    }
    clear_dst();
    __asm__ volatile("vsetvli %0, %1, e32, m1, ta, ma\n\t"
                     "vle16.v v16, (%2)\n\t"
                     "vluxseg2ei16.v v8, (%3), v16\n\t"
                     "vsseg2e32.v v8, (%4)\n\t"
                     : "=&r"(vl)
                     : "r"(n), "r"(idx), "r"(src), "r"(dst)
                     : VCLOB);
    for (unsigned i = 0; i < vl; i++)
        memcpy(exp_ + 8 * i, src + (n - 1 - i) * 8, 8);
    CHECK_MEM("vluxseg2ei16");
    clear_dst();
    __asm__ volatile("vsetvli %0, %1, e32, m1, ta, ma\n\t"
                     "vle16.v v16, (%2)\n\t"
                     "vlseg2e32.v v8, (%3)\n\t"
                     "vsoxseg2ei16.v v8, (%4), v16\n\t"
                     : "=&r"(vl)
                     : "r"(n), "r"(idx), "r"(src), "r"(dst)
                     : VCLOB);
    for (unsigned i = 0; i < vl; i++)
        memcpy(exp_ + (n - 1 - i) * 8, src + 8 * i, 8);
    CHECK_MEM("vsoxseg2ei16");
}

/* Segment loads with LMUL = 2: field registers v8-v9 and v10-v11. */
static void seg_lmul2(void)
{
    unsigned long vl;
    unsigned long vlmax = vlmax_for(4, 2, 1);
    clear_dst();
    __asm__ volatile("vsetvli %0, %1, e32, m2, ta, ma\n\t"
                     "vlseg2e32.v v8, (%2)\n\t"
                     "vsseg2e32.v v8, (%3)\n\t"
                     : "=&r"(vl)
                     : "r"(vlmax), "r"(src), "r"(dst)
                     : VCLOB);
    memcpy(exp_, src, vl * 8);
    CHECK_MEM("vlseg2e32 m2 round trip");
}

/* ---------------------------------------------------------------- fault-only-first */

/* ptr = end of the mapped page minus k element bytes. Elements k.. fault. */
#define FF_CASE(EEW)                                                                               \
    static void ff_e##EEW(void)                                                                    \
    {                                                                                              \
        uint8_t *page_end = (uint8_t *) VT_FF_END;                                                 \
        unsigned long vlmax = vlmax_for(EEW / 8, 8, 1);                                            \
        const unsigned ks[] = {1, 2, 3, 5};                                                        \
        for (unsigned t = 0; t < 4; t++) {                                                         \
            unsigned k = ks[t];                                                                    \
            if (k >= vlmax)                                                                        \
                continue;                                                                          \
            uint8_t *p = page_end - k * (EEW / 8);                                                 \
            for (unsigned i = 0; i < k * (EEW / 8); i++)                                           \
                p[i] = (uint8_t) (0x40 + i);                                                       \
            unsigned long vl, vlnew;                                                               \
            clear_dst();                                                                           \
            vt_trap_clear();                                                                       \
            __asm__ volatile("vsetvli %0, %2, e" #EEW ", m8, ta, ma\n\t"                           \
                             "vmv.v.i v8, 0\n\t"                                                   \
                             "vle" #EEW "ff.v v8, (%3)\n\t"                                        \
                             "csrr %1, vl\n\t"                                                     \
                             "vse" #EEW ".v v8, (%4)\n\t"                                          \
                             : "=&r"(vl), "=&r"(vlnew)                                             \
                             : "r"(vlmax), "r"(p), "r"(dst)                                        \
                             : VCLOB);                                                             \
            VT_EQ(vl, vlmax, "ff initial vl e" #EEW);                                              \
            VT_EQ(vt_trap_count, 0, "ff past the page does not trap e" #EEW);                      \
            VT_EQ(vlnew, k, "ff truncates vl to the faulting element e" #EEW);                     \
            /* vse stored vl_new elements: the loaded ones. */                                     \
            memcpy(exp_, p, k * (EEW / 8));                                                        \
            CHECK_MEM("ff data e" #EEW);                                                           \
        }                                                                                          \
    }
FF_CASE(8)
FF_CASE(16)
FF_CASE(32)
FF_CASE(64)

/* First element faults: a normal exception, vl unchanged. */
static void ff_first_element(void)
{
    unsigned long vl, vlnew;
    vt_trap_clear();
    uint8_t *p = (uint8_t *) VT_FF_END;
    __asm__ volatile("vsetvli %0, %2, e8, m1, ta, ma\n\t"
                     "vle8ff.v v8, (%3)\n\t"
                     "csrr %1, vl\n\t"
                     : "=&r"(vl), "=&r"(vlnew)
                     : "r"(1000ul), "r"(p)
                     : VCLOB);
    VT_EQ(vt_trap_count, 1, "ff first element traps");
    VT_EQ(vt_trap_cause, 5, "ff first element: load access fault");
    VT_EQ(vt_trap_tval, (unsigned long) p, "ff first element: mtval");
    VT_EQ(vt_trap_vstart, 0, "ff first element: vstart 0");
    VT_EQ(vlnew, vl, "ff first element leaves vl");
}

/* Segment ff: the segment count is truncated to complete segments. */
static void ff_segment(void)
{
    unsigned long vl, vlnew;
    uint8_t *p = (uint8_t *) VT_FF_END - 3 * 8 - 4; /* 3 whole 8-byte segments, then half */
    for (unsigned i = 0; i < 3 * 8 + 4; i++)
        p[i] = (uint8_t) (0x70 + i);
    vt_trap_clear();
    clear_dst();
    __asm__ volatile("vsetvli %0, %2, e32, m1, ta, ma\n\t"
                     "vlseg2e32ff.v v8, (%3)\n\t"
                     "csrr %1, vl\n\t"
                     "vsseg2e32.v v8, (%4)\n\t"
                     : "=&r"(vl), "=&r"(vlnew)
                     : "r"(1000ul), "r"(p), "r"(dst)
                     : VCLOB);
    VT_EQ(vt_trap_count, 0, "segment ff does not trap");
    VT_EQ(vlnew, 3, "segment ff vl is the whole segments that fit");
    memcpy(exp_, p, 3 * 8);
    CHECK_MEM("segment ff data");
}

/* ---------------------------------------------------------------- precise faults */

/* A normal load or store that crosses into the unmapped page traps with
 * vstart = index of the first faulting element and mtval = its address. */
static void precise_faults(void)
{
    uint8_t *page_end = (uint8_t *) VT_FF_END;
    const unsigned k = 3;
    uint8_t *p = page_end - k * 4;
    unsigned long vl;
    /* Load fault. */
    vt_trap_clear();
    __asm__ volatile("vsetvli %0, %1, e32, m1, ta, ma\n\t"
                     "vmv.v.i v8, 0\n\t"
                     "vle32.v v8, (%2)\n\t"
                     : "=&r"(vl)
                     : "r"(8ul), "r"(p)
                     : VCLOB);
    VT_EQ(vt_trap_count, 1, "crossing load traps");
    VT_EQ(vt_trap_cause, 5, "crossing load: load access fault");
    VT_EQ(vt_trap_vstart, k, "crossing load: vstart is the faulting element");
    VT_EQ(vt_trap_tval, (unsigned long) page_end, "crossing load: mtval is the element address");
    /* Store fault: elements below k land in memory. */
    for (unsigned i = 0; i < 12; i++)
        p[i] = 0;
    vt_trap_clear();
    __asm__ volatile("vsetvli %0, %1, e32, m1, ta, ma\n\t"
                     "vle32.v v8, (%3)\n\t"
                     "vse32.v v8, (%2)\n\t"
                     : "=&r"(vl)
                     : "r"(8ul), "r"(p), "r"(src)
                     : VCLOB);
    VT_EQ(vt_trap_count, 1, "crossing store traps");
    VT_EQ(vt_trap_cause, 7, "crossing store: store access fault");
    VT_EQ(vt_trap_vstart, k, "crossing store: vstart");
    VT_EQ(vt_trap_tval, (unsigned long) page_end, "crossing store: mtval");
    VT_EQ(memcmp(p, src, 12), 0, "elements below vstart were stored");
    /* Strided and indexed forms report the faulting element. */
    vt_trap_clear();
    __asm__ volatile("vsetvli %0, %1, e8, m1, ta, ma\n\t"
                     "vlse8.v v8, (%2), %3\n\t"
                     : "=&r"(vl)
                     : "r"(8ul), "r"(page_end - 2 * 16), "r"(16ul)
                     : VCLOB);
    VT_EQ(vt_trap_count, 1, "strided crossing load traps");
    VT_EQ(vt_trap_vstart, 2, "strided crossing load: vstart");
    VT_EQ(vt_trap_tval, (unsigned long) page_end, "strided crossing load: mtval");
    /* A masked-off faulting element does not trap. */
    vt_trap_clear();
    uint8_t m = 0x07; /* elements 0..2 active; element 3 would fault */
    __asm__ volatile("vsetvli %0, %1, e32, m1, ta, mu\n\t"
                     "vlm.v v0, (%3)\n\t"
                     "vle32.v v8, (%2), v0.t\n\t"
                     : "=&r"(vl)
                     : "r"(8ul), "r"(p), "r"(&m)
                     : VCLOB);
    VT_EQ(vt_trap_count, 0, "masked-off element past the page does not trap");
    /* vstart > 0 starts at that element and clears vstart afterwards. */
    clear_dst();
    vt_trap_clear();
    unsigned long vstart_after;
    __asm__ volatile("vsetvli %0, %2, e32, m1, ta, ma\n\t"
                     "vmv.v.i v8, 0\n\t"
                     "csrw vstart, %3\n\t"
                     "vle32.v v8, (%4)\n\t"
                     "csrr %1, vstart\n\t"
                     "vse32.v v8, (%5)\n\t"
                     : "=&r"(vl), "=&r"(vstart_after)
                     : "r"(8ul), "r"(2ul), "r"(src), "r"(dst)
                     : VCLOB);
    VT_EQ(vstart_after, 0, "vstart cleared after a vector load");
    for (unsigned i = 2; i < vl; i++)
        memcpy(exp_ + 4 * i, src + 4 * i, 4);
    /* Elements below vstart were not written: register held 0, so the store
     * wrote zeros there and memory shows zero where exp_ holds the guard. */
    memset(exp_, 0, 8);
    CHECK_MEM("vle32 with vstart = 2");
}

int main(void)
{
    vt_enable_vector();
    vt_trap_install();
    init_data();

    unit_e8_m1();
    unit_e8_m8();
    unit_e16_m1();
    unit_e16_m2();
    unit_e32_m1();
    unit_e32_m4();
    unit_e64_m1();
    unit_e64_m8();
    unit_fractional();
    unit_eew_differs_from_sew();
    unit_masked();
    mask_ls();
    whole_register();
    stride_e8_m1();
    stride_e16_m2();
    stride_e32_m1();
    stride_e64_m4();
    indexed_unordered_i8();
    indexed_unordered_i16();
    indexed_unordered_i32();
    indexed_unordered_i64();
    indexed_ordered_i8();
    indexed_ordered_i16();
    indexed_ordered_i32();
    indexed_ordered_i64();
    ordered_store_duplicates();
    indexed_masked();
    seg_2_e8();
    seg_3_e16();
    seg_4_e32();
    seg_5_e64();
    seg_7_e8();
    seg_8_e32();
    seg_strided_indexed();
    seg_lmul2();
    ff_e8();
    ff_e16();
    ff_e32();
    ff_e64();
    ff_first_element();
    ff_segment();
    precise_faults();

    return vt_finish("vec_ldst");
}
