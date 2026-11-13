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


/*
 * Vector integer arithmetic through the engine. Without vector loads, results
 * are observed through vmv.x.s (element 0), vcpop.m and vfirst.m, and every
 * element is checked through identities: a value built two ways must compare
 * equal (vmsne, then vcpop.m == 0). Element values differ because 64-bit
 * splats are read back at narrower SEW. Instructions are emitted with .insn.
 */

#include <stdint.h>

#include "csr.h"
#include "uart.h"

#define MSTATUS_VS (3ul << 9)
#define VS_INITIAL (1ul << 9)

/* OP-V encodings: funct6, vm, vs2, field 19:15, funct3, vd */
#define OPV(f6, vm, vs2, f15, f3, vd)                                                              \
    ((((f6) << 26) | ((vm) << 25) | ((vs2) << 20) | ((f15) << 15) | ((f3) << 12) | ((vd) << 7) |   \
      0x57))
#define S_(x) #x
#define S(x) S_(x)
#define VINSN(word) __asm__ volatile(".word " S(word)::: "memory")

static int g_ok = 1;
static unsigned long g_vlen;

static void check(const char *name, unsigned long got, unsigned long want)
{
    if (got != want) {
        g_ok = 0;
        uart_printf("[FAIL] %s got=%lx want=%lx\n", name, got, want);
    } else {
        uart_printf("[PASS] %s\n", name);
    }
}

static unsigned long setvl(unsigned long avl, unsigned long vtype)
{
    unsigned long vl;
    __asm__ volatile(".insn r 0x57, 7, 0x40, %0, %1, %2"
                     : "=r"(vl)
                     : "r"(avl), "r"(vtype)
                     : "memory");
    return vl;
}

/* vmv.v.x vd, rs1 with rs1 = a0 (x10) */
static void splat(unsigned long x, int vd)
{
    register unsigned long a0 __asm__("a0") = x;
    switch (vd) {
        case 1:
            __asm__ volatile(".word " S(OPV(0x17, 1, 0, 10, 4, 1))::"r"(a0) : "memory");
            break;
        case 2:
            __asm__ volatile(".word " S(OPV(0x17, 1, 0, 10, 4, 2))::"r"(a0) : "memory");
            break;
        default:
            __asm__ volatile(".word " S(OPV(0x17, 1, 0, 10, 4, 3))::"r"(a0) : "memory");
            break;
    }
}

/* vcpop.m a0, vs2 (unmasked) */
#define VCPOP(vs2)                                                                                 \
    ({                                                                                             \
        register unsigned long r__ __asm__("a0");                                                  \
        __asm__ volatile(".word " S(OPV(0x10, 1, vs2, 0x10, 2, 10)) : "=r"(r__)::"memory");        \
        r__;                                                                                       \
    })
#define VFIRST(vs2)                                                                                \
    ({                                                                                             \
        register unsigned long r__ __asm__("a0");                                                  \
        __asm__ volatile(".word " S(OPV(0x10, 1, vs2, 0x11, 2, 10)) : "=r"(r__)::"memory");        \
        r__;                                                                                       \
    })
#define VMVXS(vs2)                                                                                 \
    ({                                                                                             \
        register unsigned long r__ __asm__("a0");                                                  \
        __asm__ volatile(".word " S(OPV(0x10, 1, vs2, 0, 2, 10)) : "=r"(r__)::"memory");           \
        r__;                                                                                       \
    })

int main(void)
{
    unsigned long v;
    csr_set(mstatus, VS_INITIAL);
    __asm__ volatile("csrr %0, 0xC22" : "=r"(v));
    g_vlen = v * 8;
    uart_printf("VLEN %lu\n", g_vlen);

    const unsigned long a = 0x8877665544332211ul, b = 0x0123456789abcdeful;

    /* SEW 64, LMUL 1: v1 = a, v2 = b */
    unsigned long vl = setvl(~0ul, 0x18);
    check("vl e64 m1", vl, g_vlen / 64);
    splat(a, 1);
    splat(b, 2);
    check("vmv.v.x / vmv.x.s", VMVXS(1), a);

    /* At SEW 8 the bytes differ. v3 = v1 + v2; v4 = v3 - v2; v4 must equal v1. */
    vl = setvl(~0ul, 0x00);
    VINSN(OPV(0x00, 1, 1, 2, 0, 3)); /* vadd.vv v3, v1, v2 */
    VINSN(OPV(0x02, 1, 3, 2, 0, 4)); /* vsub.vv v4, v3, v2 */
    VINSN(OPV(0x19, 1, 4, 1, 0, 5)); /* vmsne.vv v5, v4, v1 */
    check("(a+b)-b == a at SEW 8", VCPOP(5), 0);
    check("element 0 of a+b at SEW 8", VMVXS(3), (unsigned long) (uint8_t) (0x11 + 0xef));
    VINSN(OPV(0x0b, 1, 1, 1, 0, 6)); /* vxor.vv v6, v1, v1 */
    VINSN(OPV(0x18, 1, 6, 0, 3, 7)); /* vmseq.vi v7, v6, 0 */
    check("a^a == 0 everywhere", VCPOP(7), vl);

    /* Unsigned compares against the byte pattern 11 22 .. 88 repeating. */
    /* vmsltu.vx v0, v1, a0 with a0 = 0x45 */
    {
        register unsigned long a0 __asm__("a0") = 0x45;
        __asm__ volatile(".word " S(OPV(0x1a, 1, 1, 10, 4, 0))::"r"(a0) : "memory");
    }
    check("vmsltu.vx count", VCPOP(0), vl / 8 * 4);
    VINSN(OPV(0x1f, 1, 1, 3, 3, 8)); /* vmsgt.vi v8, v1, 3 (signed bytes) */
    check("vmsgt.vi count (bytes 11..77 > 3, 88 negative)", VCPOP(8), vl / 8 * 7);
    check("vfirst.m of the v0 mask", VFIRST(0), 0);
    VINSN(OPV(0x18, 1, 1, 0x08, 3, 9)); /* vmseq.vi v9, v1, 8 : none */
    check("vfirst.m none", VFIRST(9), ~0ul);

    /* Masked add under v0 (bytes < 0x45): those bytes gain b's byte. */
    VINSN(OPV(0x17, 1, 0, 1, 0, 10));   /* vmv.v.v v10, v1 */
    VINSN(OPV(0x00, 0, 10, 2, 0, 10));  /* vadd.vv v10, v10, v2, v0.t */
    VINSN(OPV(0x17, 0, 1, 3, 0, 11));   /* vmerge.vvm v11, v1, v3, v0 */
    VINSN(OPV(0x19, 1, 10, 11, 0, 12)); /* vmsne.vv v12, v10, v11 */
    check("masked add == merge(a+b, a)", VCPOP(12), 0);

    /* Shifts and min/max at SEW 16 and 32 through identities. */
    vl = setvl(~0ul, 0x08);
    VINSN(OPV(0x25, 1, 1, 4, 3, 13));   /* vsll.vi v13, v1, 4 */
    VINSN(OPV(0x28, 1, 13, 4, 3, 14));  /* vsrl.vi v14, v13, 4 */
    VINSN(OPV(0x25, 1, 14, 4, 3, 14));  /* vsll.vi v14, v14, 4 */
    VINSN(OPV(0x19, 1, 14, 13, 0, 15)); /* vmsne.vv v15, v14, v13 */
    check("shift identity at SEW 16", VCPOP(15), 0);
    vl = setvl(~0ul, 0x10);
    VINSN(OPV(0x05, 1, 1, 2, 0, 16));   /* vmin.vv v16, v1, v2 */
    VINSN(OPV(0x07, 1, 1, 2, 0, 17));   /* vmax.vv v17, v1, v2 */
    VINSN(OPV(0x00, 1, 16, 17, 0, 18)); /* vadd.vv v18, v16, v17 */
    VINSN(OPV(0x00, 1, 1, 2, 0, 26));   /* vadd.vv v26, v1, v2 at SEW 32 */
    VINSN(OPV(0x19, 1, 18, 26, 0, 19)); /* vmsne.vv v19, v18, v26 */
    check("min + max == a + b at SEW 32", VCPOP(19), 0);
    check("element 0 of vmin at SEW 32",
          VMVXS(16),
          (unsigned long) (long) (int32_t) ((int32_t) 0x44332211 < (int32_t) 0x89abcdef
                                                ? 0x44332211
                                                : 0x89abcdef));

    /* LMUL 4 group: v20..v23 = a + 5, then minus 5. */
    vl = setvl(~0ul, 0x1a); /* e64, m4 */
    check("vl e64 m4", vl, g_vlen / 64 * 4);
    {
        register unsigned long a0 __asm__("a0") = a;
        __asm__ volatile(".word " S(OPV(0x17, 1, 0, 10, 4, 20))::"r"(a0)
                         : "memory"); /* vmv.v.x v20 */
    }
    VINSN(OPV(0x00, 1, 20, 5, 3, 24));  /* vadd.vi v24, v20, 5 */
    VINSN(OPV(0x03, 1, 24, 5, 3, 28));  /* vrsub.vi v28, v24, 5 : 5 - (a+5) = -a */
    VINSN(OPV(0x00, 1, 28, 20, 0, 28)); /* vadd.vv v28, v28, v20 : 0 */
    VINSN(OPV(0x18, 1, 28, 0, 3, 7));   /* vmseq.vi v7, v28, 0 */
    check("LMUL 4 identity", VCPOP(7), vl);

    uart_printf(g_ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
    return 0;
}
